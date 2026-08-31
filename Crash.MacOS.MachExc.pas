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

  Message layout uses mach_exc/exception_raise_state_identity with
  MACH_EXCEPTION_CODES (msgh_id 2407). The 64-bit exception codes preserve a
  full fault address; KERN_FAILURE still falls through to the Delphi RTL's
  task-level classic handler. }

interface

{ Install our thread-level Mach exception port on the CURRENT thread. Call once
  per thread to cover, FROM that thread, on a calm path (e.g. startup). The port
  + watcher thread are created on first call (process-wide); later calls just
  register another thread. Returns True when the thread is covered (or there is
  nothing to cover - non-(macOS x86-64) targets); False when setup or the
  thread registration failed. A first-call failure is rolled back in full, and
  a terminal watcher failure tears the setup down and reopens the gate - a
  later call may retry either way. Calls serialize on an internal lock, and a
  registration holds the port for the whole kernel call. }
function CrashInstallMacOSMachHandlerForCurrentThread: Boolean;

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

  // mach_exc.defs subsystem 2405: exception_raise_state_identity is routine
  // 2, hence request id 2407. MACH_EXCEPTION_CODES selects mach_exc instead of
  // the classic exception.defs subsystem and makes both codes signed 64-bit.
  MACH_EXC_RAISE_STATE_IDENTITY_ID = 2407;
  MACH_EXCEPTION_CODES = exception_behavior_t(-2147483648); // 0x80000000
  MACH_EXCEPTION_STATE_IDENTITY =
    EXCEPTION_STATE_IDENTITY or MACH_EXCEPTION_CODES;

  // mach_msg receive: the queued message is larger than rcv_size (mach/message.h).
  MACH_RCV_TOO_LARGE = $10004004;

  // msgh_bits value for a send on a port we hold a send right to
  // (MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0), mach/message.h). Not exposed
  // by Macapi.Mach, which only declares MACH_MSG_TYPE_MAKE_SEND.
  MACH_MSG_TYPE_COPY_SEND = 19;

  // Our own wake-up ping: sent to the watcher's port when a rollback clears
  // the setup, so the watcher leaves its blocking receive and notices that
  // the token is no longer its own. Kept far from any MIG id range, and
  // inside positive Integer range (msgh_id is signed).
  WAKEUP_MSG_ID = $0C0DE001;

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

// Mach thread port -> pthread of the same thread (Darwin-only, libSystem).
// Identity value for the snapshot<->exception correlation in Crash.Signals
// (matches pthread_self at report time). Returns nil for an invalid or already-
// terminated thread. Not wrapped by Posix.Pthread.
function pthread_from_mach_thread_np(thread: mach_port_t): Pointer; cdecl;
  external libc name _PU + 'pthread_from_mach_thread_np';

// SDK-recommended right-by-right release (mach_port_destroy is deprecated as
// "inherently unsafe"): drop the send right we inserted (mach_port_deallocate),
// then the receive right. Not wrapped by Macapi.Mach.
function mach_port_mod_refs(task: mach_port_t; name: mach_port_t;
  right: natural_t; delta: Integer): kern_return_t; cdecl;
  external libc name _PU + 'mach_port_mod_refs';

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

  // Incoming mach_exception_raise_state_identity request (mach_exc.defs).
  TMachExcRequest = packed record
    header:       mach_msg_header_t;
    body:         mach_msg_body_t;
    thread:       mach_msg_port_descriptor_t;
    task:         mach_msg_port_descriptor_t;
    NDR:          NDR_record_t;
    exception:    exception_type_t;
    codeCnt:      mach_msg_type_number_t;
    code:         array[0..1] of Int64;       // mach_exception_data_type_t
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
  GLock:   TCriticalSection; // serializes install/rollback/terminal teardown; created at unit init, never freed (the detached watcher may take it at any point of the process lifetime)
  GToken:  Int64 = 0;        // live-setup token: (generation shl 32) or port; 0 = none. Written only under GLock; watchers read it atomically to detect staleness.
  GGenSeq: Integer = 0;      // monotonic generation source for tokens

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
  // code[1] = the complete 64-bit fault address (MACH_EXCEPTION_CODES).
  Code0  := 0;
  FaultA := 0;
  if Req.codeCnt >= 1 then Code0  := Integer(Req.code[0]);
  if Req.codeCnt >= 2 then FaultA := UInt64(Req.code[1]);

  // Dump the faulting thread's stack SAFELY: vm_read_overwrite returns an error
  // (not a fault) if RSP is unmapped. A raw Move here would crash our watcher
  // thread on a bad RSP. Needed so the EL Viewer renders the Registers section.
  StackBase := TS.ts64.rsp;
  OutCnt    := 0;
  if vm_read_overwrite(mach_task_self, vm_address_t(StackBase), STACK_READ_BYTES,
       vm_address_t(@StackBuf[0]), OutCnt) <> KERN_SUCCESS then
    StackBase := 0; // unreadable - emit registers without a stack dump

  // pthread identity of the FAULTING thread (the exception message carries its
  // Mach port). Crash.Signals matches it against pthread_self at report time -
  // the report is built on the faulting thread - to catch a snapshot that would
  // otherwise be misattributed to another thread's exception. nil (invalid /
  // terminated thread) becomes 0 = "unknown", which disables the check.
  CrashRecordMacOSSnapshot(Regs, SigNum, Code0, FaultA,
    StackBase, @StackBuf[0], Integer(OutCnt),
    UInt64(NativeUInt(pthread_from_mach_thread_np(Req.thread.name))));
end;

function ExcWatcherThread(Param: Pointer): Pointer; cdecl;
var
  R:     mach_msg_return_t;
  Req:   TMachExcRequest;
  Reply: mig_reply_error_t;
  Fails: Integer;
  Port:  mach_port_t;
  MyToken: Int64;

  procedure ShutdownSelf;
  // Release OUR port rights and leave. Once a watcher exists, it is the only
  // code that ever frees this port - that is what keeps the numeric name
  // un-recyclable for as long as the watcher lives, so no stale check-to-use
  // window can make us touch a foreign port. Under GLock, like every other
  // state transition.
  begin
    GLock.Enter;
    try
      if GToken = MyToken then
        TInterlocked.Exchange(GToken, 0); // we were still the live setup
      mach_port_deallocate(mach_task_self, Port);                          // our inserted send right
      mach_port_mod_refs(mach_task_self, Port, MACH_PORT_RIGHT_RECEIVE, -1); // then the receive right
    finally
      GLock.Leave;
    end;
  end;

begin
  // The owner token ((generation shl 32) or port) arrives by value. The
  // watcher recognises itself through it: a cleared/replaced token means an
  // install rolled our setup back and pinged us awake - we then release the
  // rights ourselves and exit.
  MyToken := Int64(Param);
  Port := mach_port_t(MyToken and $FFFFFFFF);
  Fails := 0;
  while True do
  begin
    // Ownership check at the TOP of the iteration. It needs no lock and no
    // check-to-use guarantee: nobody else frees our port, so the name we are
    // about to use is still ours even if the token changes right here.
    if TInterlocked.Read(GToken) <> MyToken then
    begin
      ShutdownSelf;
      Exit(nil);
    end;

    FillChar(Req, SizeOf(Req), 0);
    Req.header.msgh_local_port := Port;
    Req.header.msgh_size := SizeOf(Req);
    R := mach_msg(Req.header, MACH_RCV_MSG or MACH_RCV_LARGE, 0, SizeOf(Req),
                  Port, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    if R <> MACH_MSG_SUCCESS then
    begin
      // MACH_RCV_LARGE leaves an oversized message QUEUED - purge it (a receive
      // without the flag destroys it), or the failure streak below never clears.
      if R = MACH_RCV_TOO_LARGE then
        mach_msg(Req.header, MACH_RCV_MSG, 0, SizeOf(Req), Port,
                 MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
      // Defensive: never abort. A permanently broken port would busy-spin this
      // thread, though - back out after a failure streak, tearing our setup
      // down (registered threads' faults then fall through to the task-level
      // RTL port instead of hanging on an unserviced queue).
      Inc(Fails);
      if Fails >= 100 then
      begin
        // Terminal: clearing the token reopens the gate, so a later install
        // may retry from scratch.
        ShutdownSelf;
        Exit(nil);
      end;
      Continue;
    end;
    Fails := 0;

    // Our own wake-up ping (sent by a rollback): nothing to handle, and no
    // reply is expected - loop round to the ownership check above.
    if Req.header.msgh_id = WAKEUP_MSG_ID then
      Continue;

    // Snapshot registers for the exceptions we asked for. Anything unexpected -
    // skip the capture and still reply-fail so the kernel falls through.
    if Req.header.msgh_id = MACH_EXC_RAISE_STATE_IDENTITY_ID then
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

    // The request descriptors carry +1 send rights for the faulting thread and
    // its task - release them, they leak otherwise (one pair per exception).
    if Req.header.msgh_id = MACH_EXC_RAISE_STATE_IDENTITY_ID then
    begin
      if Req.thread.name <> 0 then
        mach_port_deallocate(mach_task_self, Req.thread.name);
      if Req.task.name <> 0 then
        mach_port_deallocate(mach_task_self, Req.task.name);
    end;
  end;
end;

procedure WakeWatcher(const APort: mach_port_t);
// Ping the watcher out of its blocking receive so it sees the cleared token
// and releases the port itself. We hold a send right on APort, and the queue
// is empty (the watcher is its only consumer and cannot be tearing down while
// we hold GLock), so this never blocks.
var
  Msg: mach_msg_header_t;
begin
  FillChar(Msg, SizeOf(Msg), 0);
  Msg.msgh_bits        := MACH_MSG_TYPE_COPY_SEND;
  Msg.msgh_size        := SizeOf(Msg);
  Msg.msgh_remote_port := APort;
  Msg.msgh_local_port  := MACH_PORT_NULL;
  Msg.msgh_id          := WAKEUP_MSG_ID;
  mach_msg(Msg, MACH_SEND_MSG, SizeOf(Msg), 0, MACH_PORT_NULL,
           MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
end;

function CrashInstallMacOSMachHandlerForCurrentThread: Boolean;
var
  Task: mach_port_t;
  KR:   kern_return_t;
  Attr: pthread_attr_t;
  Th:   pthread_t;
  Thr:  thread_act_t;
  Port: mach_port_t;
  Token: Int64;

  procedure ReleasePort(const AHasSendRight: Boolean);
  begin
    if AHasSendRight then
      mach_port_deallocate(mach_task_self, Port);
    mach_port_mod_refs(mach_task_self, Port, MACH_PORT_RIGHT_RECEIVE, -1);
  end;

begin
  Result := False;
  Port := 0;
  Token := 0;
  // ONE lock serializes setup, rollback, thread registration and the
  // watcher's terminal teardown. Registration thus holds a lease on the port
  // object for the whole thread_set_exception_ports call: a teardown cannot
  // release the rights (and the kernel cannot recycle the name) mid-syscall.
  // The lock never appears on the crash path - the watcher takes it only in
  // its terminal branch.
  GLock.Enter;
  try
    if GToken = 0 then
    begin
      // First setup, or a retry after a rollback / terminal teardown.
      Task := mach_task_self;
      KR := mach_port_allocate(Task, MACH_PORT_RIGHT_RECEIVE, Port);
      if KR <> KERN_SUCCESS then
        Exit;
      KR := mach_port_insert_right(Task, Port, Port, MACH_MSG_TYPE_MAKE_SEND);
      if KR <> KERN_SUCCESS then begin ReleasePort(False); Exit; end;
      if pthread_attr_init(Attr) <> 0 then begin ReleasePort(True); Exit; end;
      // Must be detached: nothing joins this thread, and a joinable one would
      // leak its kernel resources for the process lifetime.
      if pthread_attr_setdetachstate(Attr, PTHREAD_CREATE_DETACHED) <> 0 then
      begin
        pthread_attr_destroy(Attr);
        ReleasePort(True);
        Exit;
      end;
      // Publish the token BEFORE the watcher is born: the watcher recognises
      // itself as live (or stale) by comparing GToken with its own token from
      // its very first receive error on.
      Token := (Int64(TInterlocked.Increment(GGenSeq)) shl 32) or Int64(Port);
      TInterlocked.Exchange(GToken, Token);
      if pthread_create(Th, Attr, @ExcWatcherThread, Pointer(Token)) <> 0 then
      begin
        pthread_attr_destroy(Attr);
        TInterlocked.Exchange(GToken, 0); // no watcher was born - full rollback
        ReleasePort(True);
        Exit;
      end;
      pthread_attr_destroy(Attr);
    end
    else
      Port := mach_port_t(GToken and $FFFFFFFF); // live setup - register on its port

    // Register THIS thread's exception port (thread-level -> tried before the
    // task-level RTL port). EXCEPTION_STATE_IDENTITY + MACHINE_THREAD_STATE
    // use the same state flavor as the RTL. MACH_EXCEPTION_CODES selects the
    // mach_exc request layout; our failure reply deliberately hands control to
    // the RTL's task-level classic handler afterwards.
    Thr := mach_thread_self;
    KR := thread_set_exception_ports(Thr,
      EXC_MASK_BAD_ACCESS or EXC_MASK_ARITHMETIC or EXC_MASK_BAD_INSTRUCTION,
      Port, MACH_EXCEPTION_STATE_IDENTITY, MACHINE_THREAD_STATE);
    mach_port_deallocate(mach_task_self, Thr); // mach_thread_self returns a +1 send right
    if KR <> KERN_SUCCESS then
    begin
      // The thread stays uncovered - report that instead of pretending. A
      // setup born in THIS call is rolled back: clear the token and ping the
      // watcher, which then releases the port ITSELF (never us - that is what
      // keeps the port name un-recyclable while the watcher is alive). An
      // established setup keeps serving its covered threads.
      if Token <> 0 then
      begin
        TInterlocked.Exchange(GToken, 0);
        WakeWatcher(Port);
      end;
      Exit;
    end;
    Result := True;
  finally
    GLock.Leave;
  end;
end;

{$ELSE}  // ---- not macOS x86-64: no-op stub ----

function CrashInstallMacOSMachHandlerForCurrentThread: Boolean;
begin
  Result := True; // nothing to cover on this target
end;

{$ENDIF}

{$IF Defined(MACOS) and Defined(CPUX64)}
initialization
  GLock := TCriticalSection.Create; // process-lifetime (see its declaration)
{$ENDIF}

end.
