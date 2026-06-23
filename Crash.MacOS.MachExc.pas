unit Crash.MacOS.MachExc;

{ macOS Mach exception handler - captures CPU registers on hardware faults.

  Part of the Crash Reporter library - standalone, EurekaLog-compatible
  crash/exception reporting for Delphi cross-platform targets.

  WHY THIS EXISTS
  ---------------
  On macOS the Pascal RTL traps hardware faults (EXC_BAD_ACCESS / EXC_ARITHMETIC
  / EXC_BAD_INSTRUCTION) through Mach exception ports (task_set_exception_ports),
  NOT through POSIX sigaction. So Crash.Signals' sigaction handler never fires on
  macOS and the .el has no "Registers:" section there.

  WHAT IT DOES
  ------------
  Installs a THREAD-LEVEL Mach exception port on the current thread. The kernel
  delivers an exception to the thread-level port BEFORE the task-level one (the
  RTL's), so we get it first, snapshot the CPU registers from the message's
  thread state, then reply KERN_FAILURE. On KERN_FAILURE the kernel's
  exception_triage falls through to the next port in the hierarchy - the RTL's
  task-level port - which converts the Mach exception into a Pascal exception
  exactly as before. We are a pure PRE-OBSERVER: if anything in our handler is
  wrong, the worst case is that the kernel still falls through to the RTL, i.e.
  current behaviour (no Registers, but a correct Pascal exception). We never make
  a crash worse, and in particular we never abort().

  COVERAGE
  --------
  Only threads on which CrashInstallMacOSMachHandlerForCurrentThread was called
  (the main thread at startup + any host worker threads that opt in). Other
  threads keep the RTL's behaviour - same as today.

  STATUS: x86-64 only. ARM64 path is TODO (the snapshot/format side in
  Crash.Signals already supports skMacOSArm64). No-op stub on every other target.
  Runtime-verified on macOS x86-64 (Intel): a hardware fault yields primary
  registers in the .el (RIP = fault address) and the KERN_FAILURE reply falls
  through to the RTL, which raises the Pascal exception as before.

  Message layout (EXCEPTION_STATE_IDENTITY, msgh_id 2403) mirrors the Delphi RTL
  System.Internal.MachExceptions.MachMsgSend. }

interface

{ Install our thread-level Mach exception port on the CURRENT thread. Call once
  per thread to cover, FROM that thread, on a calm path (e.g. startup). The port
  + watcher thread are created on first call (process-wide); later calls just
  register another thread. No-op on non-(macOS x86-64). }
procedure CrashInstallMacOSMachHandlerForCurrentThread;

implementation

{$IF Defined(MACOS) and Defined(CPUX64)}

uses
  Posix.Base,          // libc
  Macapi.Mach,         // BEFORE Posix.Pthread so the POSIX pthread_* types win
  Posix.SysTypes,
  Posix.Pthread,
  System.SyncObjs,
  Crash.Signals;       // TCrashMacOSRegs + CrashRecordMacOSSnapshot

const
  {$IFDEF UNDERSCOREIMPORTNAME}
  _PU = '_';
  {$ELSE}
  _PU = '';
  {$ENDIF}

  // msgh_id of exception_raise_state_identity (classic, 32-bit codes). Same as
  // the RTL registers (no MACH_EXCEPTION_CODES), so the kernel sends us the
  // identical message format it sends the RTL.
  EXC_RAISE_STATE_IDENTITY_ID = 2403;

  // Map Mach exception types to the POSIX signal numbers our snapshot/format
  // code labels (Crash.Signals.SignalNameOf).
  SIG_SEGV = 11;
  SIG_FPE  = 8;
  SIG_ILL  = 4;

  STACK_READ_BYTES = 256;  // bytes of the faulting thread's stack to snapshot

// thread_set_exception_ports is not wrapped by Macapi.Mach (which only exposes
// task_set_exception_ports). Declare it here.
function thread_set_exception_ports(thread: thread_act_t; mask: exception_mask_t;
  new_port: mach_port_t; behavior: exception_behavior_t;
  new_flavor: thread_state_flavor_t): kern_return_t; cdecl;
  external libc name _PU + 'thread_set_exception_ports';

// Safe cross-thread/cross-task memory read: returns a kern_return_t (NOT a
// fault) when the source range is unmapped. Used to dump the faulting thread's
// stack from our watcher thread without risking a crash on a bad RSP. Not
// wrapped by Macapi.Mach.
function vm_read_overwrite(target_task: vm_map_t; address: vm_address_t;
  size: vm_size_t; data: vm_address_t; var outsize: vm_size_t): kern_return_t; cdecl;
  external libc name _PU + 'vm_read_overwrite';

type
  NDR_record_t = packed record
    mig_vers, if_vers, reserved1, mig_encoding,
    int_rep, char_rep, float_rep, reserved2: UInt8;
  end;

  mach_msg_port_descriptor_t = packed record
    name: mach_port_t;
    pad1: mach_msg_size_t;
    pad2: UInt16;
    disposition: UInt8;
    _type: UInt8;
  end;

  // Incoming exception_raise_state_identity request (matches RTL MachMsgSend).
  TMachExcRequest = packed record
    header:       mach_msg_header_t;
    body:         mach_msg_body_t;
    thread:       mach_msg_port_descriptor_t;
    task:         mach_msg_port_descriptor_t;
    NDR:          NDR_record_t;
    exception:    exception_type_t;
    codeCnt:      mach_msg_type_number_t;
    code:         array[0..1] of Int32;       // 32-bit codes (classic behavior)
    flavor:       Int32;
    old_stateCnt: mach_msg_type_number_t;
    old_state:    array[0..223] of natural_t; // x86_thread_state_t lives here
  end;
  PMachExcRequest = ^TMachExcRequest;

  // MIG error reply (mig_errors.h). Replying with RetCode<>KERN_SUCCESS tells the
  // kernel the exception was NOT handled here, so it proceeds to the next port.
  mig_reply_error_t = packed record
    Head:    mach_msg_header_t;
    NDR:     NDR_record_t;
    RetCode: kern_return_t;
  end;

const
  NDR_record: NDR_record_t = (
    mig_vers: 0; if_vers: 0; reserved1: 0;
    mig_encoding: 0;  // NDR_PROTOCOL_2_0
    int_rep: 1;       // NDR_INT_LITTLE_ENDIAN
    char_rep: 0;      // NDR_CHAR_ASCII
    float_rep: 0;     // NDR_FLOAT_IEEE
    reserved2: 0);

var
  GExcPort:   mach_port_t = 0;
  GInstalled: Integer = 0;   // atomic guard for the one-time port/thread setup

procedure CaptureRequest(const Req: TMachExcRequest);
var
  TS:        Px86_thread_state_t;
  Regs:      TCrashMacOSRegs;
  SigNum, Code0: Integer;
  FaultA:    UInt64;
  StackBase: UInt64;
  StackBuf:  array[0..STACK_READ_BYTES - 1] of Byte;
  OutCnt:    vm_size_t;
begin
  // old_state holds an x86_thread_state_t (header + ts64) because we registered
  // with flavor MACHINE_THREAD_STATE (= x86_THREAD_STATE).
  TS := Px86_thread_state_t(@Req.old_state[0]);
  Regs.Rax := TS.ts64.rax;  Regs.Rbx := TS.ts64.rbx;  Regs.Rcx := TS.ts64.rcx;
  Regs.Rdx := TS.ts64.rdx;  Regs.Rdi := TS.ts64.rdi;  Regs.Rsi := TS.ts64.rsi;
  Regs.Rbp := TS.ts64.rbp;  Regs.Rsp := TS.ts64.rsp;
  Regs.R8  := TS.ts64.r8;   Regs.R9  := TS.ts64.r9;   Regs.R10 := TS.ts64.r10;
  Regs.R11 := TS.ts64.r11;  Regs.R12 := TS.ts64.r12;  Regs.R13 := TS.ts64.r13;
  Regs.R14 := TS.ts64.r14;  Regs.R15 := TS.ts64.r15;
  Regs.Rip := TS.ts64.rip;  Regs.Rflags := TS.ts64.rflags;  Regs.Cs := TS.ts64.cs;

  case Req.exception of
    EXC_BAD_ACCESS:      SigNum := SIG_SEGV;
    EXC_ARITHMETIC:      SigNum := SIG_FPE;
    EXC_BAD_INSTRUCTION: SigNum := SIG_ILL;
  else
    SigNum := 0;
  end;

  // code[0] = kern code (KERN_INVALID_ADDRESS / KERN_PROTECTION_FAILURE / ...).
  // code[1] = fault address, but TRUNCATED to 32 bits in classic behavior. Good
  // enough for a NULL-deref test; full 64-bit needs MACH_EXCEPTION_CODES (TODO).
  Code0  := 0;
  FaultA := 0;
  if Req.codeCnt >= 1 then Code0  := Req.code[0];
  if Req.codeCnt >= 2 then FaultA := UInt64(UInt32(Req.code[1]));

  // Dump the faulting thread's stack SAFELY: vm_read_overwrite returns an error
  // (not a fault) if RSP is unmapped. A raw Move here would crash our watcher
  // thread on a bad RSP. Needed so the EL Viewer renders the Registers section.
  StackBase := TS.ts64.rsp;
  OutCnt    := 0;
  if vm_read_overwrite(mach_task_self, vm_address_t(StackBase), STACK_READ_BYTES,
       vm_address_t(@StackBuf[0]), OutCnt) <> KERN_SUCCESS then
    StackBase := 0; // unreadable - emit registers without a stack dump

  CrashRecordMacOSSnapshot(Regs, SigNum, Code0, FaultA,
    StackBase, @StackBuf[0], Integer(OutCnt));
end;

function ExcWatcherThread(Param: Pointer): Pointer; cdecl;
var
  R:     mach_msg_return_t;
  Req:   TMachExcRequest;
  Reply: mig_reply_error_t;
  Fails: Integer;
begin
  Fails := 0;
  while True do
  begin
    FillChar(Req, SizeOf(Req), 0);
    Req.header.msgh_local_port := GExcPort;
    Req.header.msgh_size := SizeOf(Req);
    R := mach_msg(Req.header, MACH_RCV_MSG or MACH_RCV_LARGE, 0, SizeOf(Req),
                  GExcPort, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    if R <> MACH_MSG_SUCCESS then
    begin
      // Defensive: never abort. A permanently broken port would busy-spin this
      // thread, though - back out after a failure streak (the RTL then handles
      // faults as if we were never here).
      Inc(Fails);
      if Fails >= 100 then
        Exit(nil);
      Continue;
    end;
    Fails := 0;

    // Snapshot registers for the exceptions we asked for. Anything unexpected -
    // skip the capture and still reply-fail so the kernel falls through.
    if Req.header.msgh_id = EXC_RAISE_STATE_IDENTITY_ID then
    try
      CaptureRequest(Req);
    except
      // A faulty capture must never break the fall-through to the RTL.
    end;

    // Reply KERN_FAILURE -> kernel tries the next exception port (the RTL's
    // task-level handler), which raises the Pascal exception as usual.
    FillChar(Reply, SizeOf(Reply), 0);
    Reply.Head.msgh_bits        := Req.header.msgh_bits and $FF;
    Reply.Head.msgh_size        := SizeOf(mig_reply_error_t);
    Reply.Head.msgh_remote_port := Req.header.msgh_remote_port;
    Reply.Head.msgh_local_port  := MACH_PORT_NULL;
    Reply.Head.msgh_id          := Req.header.msgh_id + 100;
    Reply.NDR                   := NDR_record;
    Reply.RetCode               := KERN_FAILURE;
    mach_msg(Reply.Head, MACH_SEND_MSG, SizeOf(mig_reply_error_t), 0,
             MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
  end;
end;

procedure CrashInstallMacOSMachHandlerForCurrentThread;
var
  Task: mach_port_t;
  KR:   kern_return_t;
  Attr: pthread_attr_t;
  Th:   pthread_t;
  Thr:  thread_act_t;
begin
  // One-time: allocate the receive port (+ a send right) and spin the watcher.
  if TInterlocked.CompareExchange(GInstalled, 1, 0) = 0 then
  begin
    Task := mach_task_self;
    KR := mach_port_allocate(Task, MACH_PORT_RIGHT_RECEIVE, GExcPort);
    if KR <> KERN_SUCCESS then begin GExcPort := 0; Exit; end;
    KR := mach_port_insert_right(Task, GExcPort, GExcPort, MACH_MSG_TYPE_MAKE_SEND);
    if KR <> KERN_SUCCESS then begin GExcPort := 0; Exit; end;
    if pthread_attr_init(Attr) <> 0 then begin GExcPort := 0; Exit; end;
    pthread_attr_setdetachstate(Attr, PTHREAD_CREATE_DETACHED);
    if pthread_create(Th, Attr, @ExcWatcherThread, nil) <> 0 then
    begin
      pthread_attr_destroy(Attr);
      GExcPort := 0;
      Exit;
    end;
    pthread_attr_destroy(Attr);
  end;

  if GExcPort = 0 then
    Exit; // setup failed earlier - stay out of the way of the RTL

  // Register THIS thread's exception port (thread-level -> tried before the
  // task-level RTL port). EXCEPTION_STATE_IDENTITY + MACHINE_THREAD_STATE mirror
  // the RTL so the kernel hands us the same message shape it gives the RTL.
  Thr := mach_thread_self;
  thread_set_exception_ports(Thr,
    EXC_MASK_BAD_ACCESS or EXC_MASK_ARITHMETIC or EXC_MASK_BAD_INSTRUCTION,
    GExcPort, EXCEPTION_STATE_IDENTITY, MACHINE_THREAD_STATE);
  mach_port_deallocate(mach_task_self, Thr); // mach_thread_self returns a +1 send right
end;

{$ELSE}  // ---- not macOS x86-64: no-op stub ----

procedure CrashInstallMacOSMachHandlerForCurrentThread;
begin
end;

{$ENDIF}

end.
