unit Crash.Signals;

{ POSIX signal-based CPU snapshot for hardware exceptions (SIGSEGV/SIGFPE/SIGILL/SIGBUS).

  Part of the Crash Reporter library - standalone, EurekaLog-compatible
  crash/exception reporting for Delphi cross-platform targets.

  A Pascal `raise` goes through the language runtime, not through a signal -
  there are no CPU registers to grab for it, and we don't need them there
  (the call stack comes from Crash.CallStack). Hardware exceptions (access
  violation, divide by zero, illegal opcode) are delivered on POSIX through
  signals - by the kernel, with a ucontext that holds every register and the
  exact fault location. Those are what we snapshot.

  Chain logic:
    1. Install: sigaction(SIGSEGV/SIGFPE/SIGILL/SIGBUS) -> our handler, prev
       saved in GOldHandlers[SigNum].
    2. Signal caught -> the handler writes registers + 256 bytes of stack near
       RSP into the pre-allocated global GSignalSnapshot.
    3. Restore: sigaction(SigNum, @GOldHandlers[SigNum], nil) - put the Pascal
       RTL handler back.
    4. Return from the handler. RIP/PC is still on the faulting instruction,
       the CPU re-executes it, the kernel re-raises the signal - now it is
       handled by the Pascal RTL, which converts it into a Pascal exception
       that propagates up to the call-stack walker and then to the reporter,
       which builds the .el and pulls in the snapshot.

  Async-signal-safety:
    Inside the handler - only Move (memcpy is signal-safe), an atomic flag
    write, and sigaction. No allocations, no formatting, no logging.

  Scope:
    - Linux x86-64.
    - macOS x86-64 (Intel) + ARM64 (Apple Silicon).
    - Android ARM64 (aarch64 ucontext snapshot).
    - Everything else (32-bit ARM, iOS, Windows) - the API compiles to no-op
      stubs. }

interface

procedure CrashInstallSignalHandlers;
function  CrashHasSignalSnapshot: Boolean;

// Returns the address of a PRIMARY hardware fault (RIP/PC) when one was captured
// AND it lies in the executable's own range (not a shared-lib / unwinder
// "secondary" fault). Lets the reporter re-insert the faulting frame -- which the
// signal "return + RTL re-raise" model drops from the libc backtrace -- back into
// the call stack. Read-only: does NOT consume the snapshot, so a later
// CrashTakeAndFormatSnapshots still emits the Registers section. Returns False for
// a soft Pascal `raise` (no signal -> no snapshot) and for syslib/secondary faults.
function  CrashPrimaryFaultAddr(out AAddr: UIntPtr): Boolean;

// The return address of the faulting frame's CALLER, read from the captured stack
// snapshot at [FP+8] (standard x86_64/ARM64 frame record: [FP]=saved FP,
// [FP+8]=saved return address). Lets the reporter splice the faulting frame into
// its REAL position -- right before the caller -- instead of at the very top.
// Bounded read from the 256-byte snapshot (never faults). False if that slot is
// outside the captured window (a large local frame) -> caller falls back to top.
function  CrashPrimaryFaultCallerAddr(out ACaller: UIntPtr): Boolean;

// Takes the snapshot from the global and formats BOTH blocks:
//   ARegistersSection  - EL-compatible "Registers:" + registers + Stack/Memory Dump.
//   ASignalInfoSection - our own metadata (Signal/Code/Fault addr/Invocations/Note)
//     as a separate "Crash Signal Info:" section - the EL Viewer does not parse
//     it, but the text is human-readable and does not interfere with parsing of
//     the Registers section.
// Resets the Captured/InvocationCount flags. If there was no snapshot, both ''.
procedure CrashTakeAndFormatSnapshots(out ARegistersSection, ASignalInfoSection: String);

type
  { CPU registers captured by the macOS Mach handler (Crash.MacOS.MachExc) and
    handed to CrashRecordMacOSSnapshot. Mirrors x86_thread_state64. }
  TCrashMacOSRegs = record
    Rax, Rbx, Rcx, Rdx, Rdi, Rsi, Rbp, Rsp: UInt64;
    R8, R9, R10, R11, R12, R13, R14, R15:    UInt64;
    Rip, Rflags, Cs:                         UInt64;
  end;

{ Record a snapshot captured by the macOS Mach exception handler into the same
  global the POSIX path uses, so CrashTakeAndFormatSnapshots emits the Registers
  section. No stack dump is taken (the watcher thread is not the faulting one).
  No-op when signal capture isn't compiled in. }
procedure CrashRecordMacOSSnapshot(const ARegs: TCrashMacOSRegs;
  ASignalNum, ASignalCode: Integer; AFaultAddr: UInt64;
  AStackBase: UInt64; AStackBytes: Pointer; AStackLen: Integer);

implementation

{$IF (Defined(LINUX) and Defined(CPUX64)) or
     (Defined(ANDROID) and Defined(CPUARM64)) or
     (Defined(MACOS) and (Defined(CPUX64) or Defined(CPUARM64)))}
  {$DEFINE CRASH_SIGCAP}
{$IFEND}

// Delphi does NOT define LINUX on Android, but bionic shares Linux's sigaction /
// siginfo / ucontext field names, so the POSIX field-access code below selects on
// this combined symbol (macOS keeps its own branches).
{$IF Defined(LINUX) or Defined(ANDROID)}
  {$DEFINE CRASH_LINUXLIKE}
{$IFEND}

{$IF Defined(CRASH_SIGCAP)}

uses
  System.SysUtils,
  System.SyncObjs,
  Posix.Signal;

const
  STACK_DUMP_BYTES = 256;
  CRLF             = #13#10;

type
  TSnapshotKind = (skNone, skLinuxX64, skMacOSX64, skMacOSArm64, skLinuxArm64);

  TSignalSnapshot = packed record
    Claimed:       Integer;                         // atomic claim: writer wins the slot, fills the fields, THEN publishes
    Captured:      Integer;                         // atomic publish flag: 0=empty, 1=complete (set LAST by the writer)
    InvocationCount: Integer;                       // total times handler was entered (any signal)
    SignalNum:     Integer;
    SignalCode:    Integer;
    FaultAddr:     UInt64;
    Kind:          Integer;                         // TSnapshotKind ordinal
    {$IF Defined(CPUX64)}
    Rax, Rbx, Rcx, Rdx, Rdi, Rsi, Rbp, Rsp: UInt64;
    R8,  R9,  R10, R11, R12, R13, R14, R15: UInt64;
    Rip, Rflags, Cs:                        UInt64;
    {$ELSEIF Defined(CPUARM64)}
    X:      array[0..28] of UInt64;
    Fp, Lr, Sp, Pc: UInt64;
    Cpsr:   UInt32;
    {$IFEND}
    StackBaseAddr: UInt64;
    StackBytes:    array[0..STACK_DUMP_BYTES-1] of Byte;
  end;

var
  GSignalSnapshot: TSignalSnapshot;
  GOldHandlers:    array[1..31] of sigaction_t;
  GInstalled:      Boolean = False;
  GAltStackDone:   Boolean = False;
  GAltStack:       Pointer = nil; // registered with the kernel for process lifetime - never freed

const
  // 64 KB: comfortably above every platform's MINSIGSTKSZ (macOS demands 32 KB;
  // Linux with AVX-512 xsave frames can require ~12 KB).
  ALT_STACK_BYTES = 64 * 1024;
  // SS_DISABLE is absent from Delphi's Linux Posix.Signal, and its value
  // differs per platform (Linux=2, macOS=4).
  ALT_SS_DISABLE  = {$IF Defined(CRASH_LINUXLIKE)}2{$ELSEIF Defined(MACOS)}4{$IFEND};

procedure InstallAltStackOnce;
// Register an alternate signal stack for the CALLING thread (first call only;
// Init runs on the main thread, so that is the covered one). Without it
// SA_ONSTACK is inert and a stack-overflow SIGSEGV kills the process before the
// handler can even start (no room for the kernel's signal frame). With it the
// handler runs and snapshots the registers; whether a full .el follows still
// depends on the RTL conversion surviving on the exhausted original stack.
var
  SS, OldSS: stack_t;
begin
  if GAltStackDone then Exit;
  GAltStackDone := True;
  // Respect a pre-registered alt-stack (host or RTL): it is per-thread state
  // owned by whoever set it.
  FillChar(OldSS, SizeOf(OldSS), 0);
  if (sigaltstack(nil, @OldSS) = 0) and (OldSS.ss_sp <> nil) and
     ((OldSS.ss_flags and ALT_SS_DISABLE) = 0) then
    Exit;
  GetMem(GAltStack, ALT_STACK_BYTES);
  FillChar(SS, SizeOf(SS), 0);
  SS.ss_sp    := GAltStack;
  SS.ss_size  := ALT_STACK_BYTES;
  SS.ss_flags := 0;
  sigaltstack(@SS, nil);
end;

function ExtractFaultAddr(SigInfo: Psiginfo_t): UInt64; inline;
begin
  Result := 0;
  if SigInfo = nil then Exit;
  {$IF Defined(CRASH_LINUXLIKE)}
  Result := UInt64(NativeUInt(SigInfo._sifields._sigfault.si_addr));
  {$ELSEIF Defined(MACOS)}
  Result := UInt64(NativeUInt(SigInfo.si_addr));
  {$IFEND}
end;

procedure CaptureFromUContext(Ctx: Pointer);
// Async-signal-safe: primitive assignments + dereference.
{$IF Defined(LINUX) and Defined(CPUX64)}
var
  UC: Pucontext_t;
begin
  if Ctx = nil then Exit;
  UC := Pucontext_t(Ctx);
  GSignalSnapshot.Kind := Ord(skLinuxX64);
  with GSignalSnapshot, UC.uc_mcontext do
  begin
    R8  := UInt64(gregs[REG_R8]);   R9  := UInt64(gregs[REG_R9]);
    R10 := UInt64(gregs[REG_R10]);  R11 := UInt64(gregs[REG_R11]);
    R12 := UInt64(gregs[REG_R12]);  R13 := UInt64(gregs[REG_R13]);
    R14 := UInt64(gregs[REG_R14]);  R15 := UInt64(gregs[REG_R15]);
    Rdi := UInt64(gregs[REG_RDI]);  Rsi := UInt64(gregs[REG_RSI]);
    Rbp := UInt64(gregs[REG_RBP]);  Rbx := UInt64(gregs[REG_RBX]);
    Rdx := UInt64(gregs[REG_RDX]);  Rax := UInt64(gregs[REG_RAX]);
    Rcx := UInt64(gregs[REG_RCX]);  Rsp := UInt64(gregs[REG_RSP]);
    Rip := UInt64(gregs[REG_RIP]);  Rflags := UInt64(gregs[REG_EFL]);
    Cs  := UInt64(gregs[REG_CSGSFS]) and $FFFF;
  end;
end;
{$ELSEIF Defined(MACOS) and Defined(CPUX64)}
var
  UC: Pucontext_t;
begin
  if Ctx = nil then Exit;
  UC := Pucontext_t(Ctx);
  if UC.uc_mcontext = nil then Exit;
  GSignalSnapshot.Kind := Ord(skMacOSX64);
  with GSignalSnapshot, UC.uc_mcontext^.__ss do
  begin
    Rax := __rax; Rbx := __rbx; Rcx := __rcx; Rdx := __rdx;
    Rdi := __rdi; Rsi := __rsi; Rbp := __rbp; Rsp := __rsp;
    R8  := __r8;  R9  := __r9;  R10 := __r10; R11 := __r11;
    R12 := __r12; R13 := __r13; R14 := __r14; R15 := __r15;
    Rip := __rip; Rflags := __rflags; Cs := __cs;
  end;
end;
{$ELSEIF Defined(MACOS) and Defined(CPUARM64)}
var
  UC: Pucontext_t;
  I:  Integer;
begin
  if Ctx = nil then Exit;
  UC := Pucontext_t(Ctx);
  if UC.uc_mcontext = nil then Exit;
  GSignalSnapshot.Kind := Ord(skMacOSArm64);
  with GSignalSnapshot, UC.uc_mcontext^.__ss do
  begin
    for I := 0 to 28 do X[I] := __x[I];
    Fp := __fp; Lr := __lr; Sp := __sp; Pc := __pc; Cpsr := __cpsr;
  end;
end;
{$ELSEIF Defined(ANDROID) and Defined(CPUARM64)}
var
  UC: Pucontext_t;
  I:  Integer;
begin
  if Ctx = nil then Exit;
  UC := Pucontext_t(Ctx);
  // Android (bionic) aarch64 sigcontext: regs[0..30] = x0..x30, then arm_sp /
  // arm_pc / pstate. uc_mcontext is by value (not a pointer) here. Layout from the
  // RTL android SignalTypes.inc (sigcontext_t / ucontext_t).
  GSignalSnapshot.Kind := Ord(skLinuxArm64);
  for I := 0 to 28 do
    GSignalSnapshot.X[I] := UC.uc_mcontext.regs[I];
  GSignalSnapshot.Fp   := UC.uc_mcontext.regs[29];
  GSignalSnapshot.Lr   := UC.uc_mcontext.regs[30];
  GSignalSnapshot.Sp   := UC.uc_mcontext.arm_sp;
  GSignalSnapshot.Pc   := UC.uc_mcontext.arm_pc;
  GSignalSnapshot.Cpsr := UInt32(UC.uc_mcontext.pstate);
end;
{$IFEND}

function GetStackPointer: UInt64; inline;
begin
  {$IF Defined(CPUX64)}
  Result := GSignalSnapshot.Rsp;
  {$ELSEIF Defined(CPUARM64)}
  Result := GSignalSnapshot.Sp;
  {$ELSE}
  Result := 0;
  {$IFEND}
end;

procedure CopyStackTop(SP: UInt64);
// Async-signal-safe: Move (memcpy) over raw memory. If SP is invalid we get a
// nested SIGSEGV; SIGSEGV is blocked inside the handler by default, so the
// kernel terminates the process immediately. That loses the snapshot, but it
// cannot be guarded against without setjmp/mprotect - a rare stack-overflow case.
begin
  if SP = 0 then Exit;
  GSignalSnapshot.StackBaseAddr := SP;
  Move(Pointer(NativeUInt(SP))^,
       GSignalSnapshot.StackBytes[0],
       STACK_DUMP_BYTES);
end;

procedure CrashSignalHandler(SigNum: Integer; SigInfo: Psiginfo_t;
  Context: Pointer); cdecl;
var
  Restored: sigaction_t;
begin
  TInterlocked.Increment(GSignalSnapshot.InvocationCount);

  if TInterlocked.CompareExchange(GSignalSnapshot.Claimed, 1, 0) = 0 then
  begin
    GSignalSnapshot.SignalNum := SigNum;
    if SigInfo <> nil then
    begin
      GSignalSnapshot.SignalCode := SigInfo.si_code;
      GSignalSnapshot.FaultAddr  := ExtractFaultAddr(SigInfo);
    end;
    CaptureFromUContext(Context);
    CopyStackTop(GetStackPointer);
    // Publish AFTER the fields are complete - a reader keying on Captured=1
    // must never see a half-filled snapshot.
    TInterlocked.Exchange(GSignalSnapshot.Captured, 1);
  end;

  if (SigNum >= Low(GOldHandlers)) and (SigNum <= High(GOldHandlers)) then
  begin
    Restored := GOldHandlers[SigNum];
    sigaction(SigNum, @Restored, nil);
  end;
end;

procedure SetHandlerInAction(var Act: sigaction_t; H: TSigActionHandler); inline;
// The union field has different names on Linux vs macOS - isolate the difference.
begin
  {$IF Defined(CRASH_LINUXLIKE)}
  Act._u.sa_sigaction := H;
  {$ELSEIF Defined(MACOS)}
  Act.__sigaction_handler.sa_sigaction := H;
  {$IFEND}
end;

function PrevIsOurselves(const Prev: sigaction_t): Boolean; inline;
// If the prev handler is already ours (re-install scenario), don't lose the
// original Pascal RTL handler - keep whatever is in GOldHandlers right now.
// IMPORTANT: @Prev._u.sa_sigaction for a procedural field in Delphi yields the
// VALUE of the field (the handler function address), without an extra ^. The
// extra ^ would read machine code at the handler address instead of the address
// itself - then the comparison is always False, the second (ForceQueue) install
// would save OUR handler into GOldHandlers, and restore-prev would loop back
// onto ourselves (self-pingpong -> hang).
var
  Self, Stored: NativeUInt;
begin
  Self := NativeUInt(@CrashSignalHandler);
  {$IF Defined(CRASH_LINUXLIKE)}
  Stored := NativeUInt(@Prev._u.sa_sigaction);
  {$ELSEIF Defined(MACOS)}
  Stored := NativeUInt(@Prev.__sigaction_handler.sa_sigaction);
  {$ELSE}
  Stored := 0;
  {$IFEND}
  Result := Stored = Self;
end;

procedure InstallOne(SigNum: Integer);
var
  Act, Prev: sigaction_t;
begin
  if (SigNum < Low(GOldHandlers)) or (SigNum > High(GOldHandlers)) then Exit;
  FillChar(Act, SizeOf(Act), 0);
  FillChar(Prev, SizeOf(Prev), 0);
  SetHandlerInAction(Act, CrashSignalHandler);
  // SA_ONSTACK pairs with the alternate stack registered in InstallAltStackOnce
  // - without one the handler could not even start on a stack-overflow fault.
  Act.sa_flags := SA_SIGINFO or SA_ONSTACK;
  sigemptyset(Act.sa_mask);
  sigaction(SigNum, @Act, @Prev);
  // Save prev only if it is NOT ourselves (guard against the re-install chain)
  // AND if nothing has been saved yet. The FIRST install catches the Pascal RTL
  // handler (before FMXLinux replaces SIGSEGV with its own stub at FmuxInit).
  // The SECOND (ForceQueue) install already sees the FMXLinux stub as prev - if
  // we saved it, restore-prev would re-fault onto the stub -> pingpong/hang.
  // So we keep the first (Pascal RTL) prev and never overwrite it.
  if not PrevIsOurselves(Prev) then
    {$IF Defined(CRASH_LINUXLIKE)}
    if NativeUInt(@GOldHandlers[SigNum]._u.sa_sigaction) = 0 then
      GOldHandlers[SigNum] := Prev;
    {$ELSE}
    GOldHandlers[SigNum] := Prev;
    {$IFEND}
end;

procedure CrashInstallSignalHandlers;
// Idempotent (re-entry allowed). Called twice at startup (immediately + via
// TThread.ForceQueue once the platform is initialised), and on Linux also after
// every non-fatal crash (re-arm - see the reporter): at the end our handler
// restores prev and thereby removes itself from active, so without a re-install
// the next hardware crash would bypass us (no snapshot). InstallOne keeps the
// FIRST (Pascal RTL) prev and never overwrites it with later (FMXLinux stub)
// ones - see there.
begin
  if not GInstalled then
    FillChar(GSignalSnapshot, SizeOf(GSignalSnapshot), 0);
  GInstalled := True;
  InstallAltStackOnce; // covers the calling thread (main at Init) - see there
  InstallOne(SIGSEGV);
  InstallOne(SIGFPE);
  InstallOne(SIGILL);
  InstallOne(SIGBUS);
end;

function CrashHasSignalSnapshot: Boolean;
begin
  Result := GSignalSnapshot.Captured = 1;
end;

function SignalNameOf(SigNum: Integer): String;
begin
  case SigNum of
    SIGSEGV: Result := 'SIGSEGV';
    SIGFPE:  Result := 'SIGFPE';
    SIGILL:  Result := 'SIGILL';
    SIGBUS:  Result := 'SIGBUS';
    SIGABRT: Result := 'SIGABRT';
  else
    Result := 'signal ' + IntToStr(SigNum);
  end;
end;

function Hex16(V: UInt64): String; inline;
begin
  Result := Format('%.16x', [V]);
end;

function GuessSnapshotIsSecondary(RIP, AFaultAddr: UInt64): Boolean; inline;
// Heuristic: on Linux/macOS x86-64 the exe is mapped into the lower half of the
// address space (<= ~4 GiB here), shared libs/mmap into the upper half
// (>= ~0x7000_0000_0000). A snapshotted RIP in the shared-lib range USUALLY means
// our handler fired not on the primary faulting instruction in our code but
// already inside the Pascal RTL stack unwinder / call-stack reader. In that
// case the primary crash went straight to the Pascal RTL SignalConverter, which
// overwrote our sigaction before the fault.
//
// EXCEPTION - an instruction-fetch fault (FaultAddr = RIP): the CPU faulted
// FETCHING the instruction at RIP, i.e. control flow jumped to a wild address
// (call/jmp through a dangling function pointer, a smashed return address, a
// corrupt vtable). That IS the primary crash even when the target lands in the
// shared-lib range, so it must NOT be suppressed. The unwinder, in contrast,
// faults on a DATA read (RIP = valid libc code, FaultAddr <> RIP). Keeping a
// fetch fault primary preserves its Registers + Stack dump - which hold the bad
// pointer and the caller return addresses needed to locate the call site.
begin
  if (AFaultAddr <> 0) and (AFaultAddr = RIP) then
    Exit(False);
  {$IF Defined(ANDROID)}
  // The x64 "low exe vs high shared-lib" split does NOT hold on Android: our own
  // code lives in the app's own .so, mmap'd high alongside the system libs, so the
  // address-range test would misclassify real faults in our code as secondary and
  // suppress the Registers section. Treat every captured fault as primary here
  // (a module-range check via dladdr could refine this later).
  Result := False;
  {$ELSE}
  Result := RIP >= UInt64($700000000000);
  {$IFEND}
end;

function CrashPrimaryFaultAddr(out AAddr: UIntPtr): Boolean;
// Read-only probe of the captured snapshot (no consume/reset). True only for a
// primary hardware fault in our exe range -- the case where the libc backtrace
// dropped the faulting frame and the reporter should re-insert it.
var
  RIP: UInt64;
begin
  AAddr := 0;
  Result := False;
  if GSignalSnapshot.Captured <> 1 then Exit;     // no signal -> soft raise / nothing
  {$IF Defined(CPUX64)}
  RIP := GSignalSnapshot.Rip;
  {$ELSEIF Defined(CPUARM64)}
  RIP := GSignalSnapshot.Pc;
  {$ELSE}
  RIP := 0;
  {$IFEND}
  if (RIP = 0) or GuessSnapshotIsSecondary(RIP, GSignalSnapshot.FaultAddr) then Exit;  // syslib / unwinder fault
  AAddr := UIntPtr(RIP);
  Result := True;
end;

function CrashPrimaryFaultCallerAddr(out ACaller: UIntPtr): Boolean;
// [FP+8] = caller return address. The snapshot copied StackBytes starting at SP
// (StackBaseAddr=SP), so [FP+8] sits at byte offset (FP - SP) + 8 within it.
var
  FP, SP: UInt64;
  Offset: Integer;
begin
  ACaller := 0;
  Result := False;
  if GSignalSnapshot.Captured <> 1 then Exit;
  {$IF Defined(CPUX64)}
  FP := GSignalSnapshot.Rbp;  SP := GSignalSnapshot.Rsp;
  {$ELSEIF Defined(CPUARM64)}
  FP := GSignalSnapshot.Fp;   SP := GSignalSnapshot.Sp;
  {$ELSE}
  FP := 0;  SP := 0;
  {$IFEND}
  if (FP = 0) or (SP = 0) or (FP < SP) then Exit;
  if (FP - SP) > STACK_DUMP_BYTES then Exit; // also keeps the Integer cast below truncation-safe
  Offset := Integer(FP - SP) + SizeOf(Pointer);
  if (Offset < 0) or (Offset + SizeOf(UInt64) > STACK_DUMP_BYTES) then Exit;
  ACaller := UIntPtr(PUInt64(@GSignalSnapshot.StackBytes[Offset])^);
  Result := ACaller <> 0;
end;

{$IF Defined(CPUX64) or Defined(CPUARM64)}
function ReadStackQword(const S: TSignalSnapshot; ByteOffset: Integer): UInt64; inline;
// Read an 8-byte qword at the given offset in our StackBytes (for column 1 of the dump).
var
  P: PUInt64;
begin
  if (ByteOffset < 0) or (ByteOffset + 8 > Length(S.StackBytes)) then
    Exit(0);
  P := @S.StackBytes[ByteOffset];
  Result := P^;
end;

function ReadStackByte(const S: TSignalSnapshot; ByteOffset: Integer): Byte; inline;
begin
  if (ByteOffset < 0) or (ByteOffset >= Length(S.StackBytes)) then
    Exit(0);
  Result := S.StackBytes[ByteOffset];
end;

function FormatStackDumpRow(const S: TSignalSnapshot; RowIdx: Integer): String;
// One row of the EL CPU dump:
//   '<stack_addr>: <stack_val>   <mem_addr>: XX XX...XX  ASCII'
// Stack column - 16 qwords in reverse order (from stack depth to top).
// Memory column - 16 rows x 16 bytes. We have no dump near RIP, so for the
// memory column we reuse the same stack bytes (16 bytes per row, strictly
// contiguous). An analyst sees the real RIP/RAX separately in the registers and
// won't be confused.
const
  StackDepth = 16;
var
  StackOff:   Integer;
  StackAddr, StackVal, MemAddr: UInt64;
  HexPart, AsciiPart:           String;
  J:                            Integer;
  B:                            Byte;
begin
  // EL: the stack is drawn in reverse, i.e. row0 = deepest (RSP + 15*8),
  // row15 = top of stack (RSP).
  StackOff  := (StackDepth - 1 - RowIdx) * SizeOf(UInt64);
  StackAddr := S.StackBaseAddr + UInt64(StackOff);
  StackVal  := ReadStackQword(S, StackOff);

  // Memory column - 16 rows of 16 contiguous bytes from base.
  MemAddr := S.StackBaseAddr + UInt64(RowIdx * 16);

  HexPart   := '';
  AsciiPart := '';
  for J := 0 to 15 do
  begin
    B := ReadStackByte(S, RowIdx * 16 + J);
    HexPart := HexPart + Format('%.2x ', [B]);
    if (B >= 32) and (B <= 126) then
      AsciiPart := AsciiPart + Char(B)
    else
      AsciiPart := AsciiPart + '.';
  end;

  Result := Format('%s: %s   %s: %s %s',
    [Hex16(StackAddr), Hex16(StackVal), Hex16(MemAddr), HexPart, AsciiPart]);
end;
{$IFEND}

function TakeSnapshot(out S: TSignalSnapshot): Boolean;
// Atomically grab + reset the global snapshot. Returns False if nothing
// was captured.
begin
  Result := GSignalSnapshot.Captured = 1;
  if not Result then Exit;
  S := GSignalSnapshot;
  TInterlocked.Exchange(GSignalSnapshot.Captured, 0);
  TInterlocked.Exchange(GSignalSnapshot.InvocationCount, 0);
  // Reopen the slot LAST - a writer claims only after the copy above is done.
  TInterlocked.Exchange(GSignalSnapshot.Claimed, 0);
end;

function FormatRegistersSection(const S: TSignalSnapshot): String;
// EL-compatible "Registers:" section text. No extra labels - otherwise the EL
// Viewer fails to parse the Stack/Memory Dump.
var
  SB:   TStringBuilder;
  Kind: TSnapshotKind;
  RIP, RSP_, EXP_, STK_: UInt64;
  I:    Integer;
begin
  Kind := TSnapshotKind(S.Kind);

  {$IF Defined(CPUX64)}
  RIP  := S.Rip;
  RSP_ := S.Rsp;
  {$ELSEIF Defined(CPUARM64)}
  RIP  := S.Pc;
  RSP_ := S.Sp;
  {$ELSE}
  RIP  := 0;
  RSP_ := 0;
  {$IFEND}
  EXP_ := RIP;   // ExceptionAddress - same RIP in our snapshot
  STK_ := RSP_;  // StackPoint - same RSP

  SB := TStringBuilder.Create;
  try
    // ===== Section header (EL format) =====
    // IMPORTANT: the EL .el file uses "Registers:" and NOT "CPU:" - "CPU" is
    // only the dialog tab caption (mtDialog_CPUCaption.Val); the section header
    // in the .el is mtCPU_Registers.Val = 'Registers'. The EurekaLog Viewer
    // looks strictly for "Registers:" - "CPU:" shows empty.
    SB.Append('Registers:'); SB.Append(CRLF);
    SB.Append(StringOfChar('-', 45)); SB.Append(CRLF);

    case Kind of
      skLinuxX64, skMacOSX64:
      begin
        {$IF Defined(CPUX64)}
        // EL layout (see ECPUFmtOnly): two registers per line.
        SB.AppendFormat('RAX: %s   RDI: %s', [Hex16(S.Rax), Hex16(S.Rdi)]); SB.Append(CRLF);
        SB.AppendFormat('RBX: %s   RSI: %s', [Hex16(S.Rbx), Hex16(S.Rsi)]); SB.Append(CRLF);
        SB.AppendFormat('RCX: %s   RBP: %s', [Hex16(S.Rcx), Hex16(S.Rbp)]); SB.Append(CRLF);
        SB.AppendFormat('RDX: %s   RSP: %s', [Hex16(S.Rdx), Hex16(S.Rsp)]); SB.Append(CRLF);
        SB.AppendFormat('R8 : %s   R9 : %s', [Hex16(S.R8),  Hex16(S.R9)]);  SB.Append(CRLF);
        SB.AppendFormat('R10: %s   R11: %s', [Hex16(S.R10), Hex16(S.R11)]); SB.Append(CRLF);
        SB.AppendFormat('R12: %s   R13: %s', [Hex16(S.R12), Hex16(S.R13)]); SB.Append(CRLF);
        SB.AppendFormat('R14: %s   R15: %s', [Hex16(S.R14), Hex16(S.R15)]); SB.Append(CRLF);
        SB.AppendFormat('RIP: %s   FLG: %s', [Hex16(S.Rip), Hex16(S.Rflags)]); SB.Append(CRLF);
        SB.AppendFormat('EXP: %s   STK: %s', [Hex16(EXP_),  Hex16(STK_)]); SB.Append(CRLF);
        {$IFEND}
      end;
      skMacOSArm64, skLinuxArm64:
      begin
        {$IF Defined(CPUARM64)}
        // ARM64 - EL has no defined format for ARM, emit a compact list of two.
        // X0..X27 in pairs (loop 0..13: the last pair is X26/X27); X28 + FP, LR/SP,
        // PC/CPSR follow explicitly. NB: 0..13, not 0..14 - X is [0..28], so X[29]
        // would read past the array (onto the Fp field).
        for I := 0 to 13 do
          SB.AppendFormat('X%-2d: %s   X%-2d: %s',
            [I*2, Hex16(S.X[I*2]), I*2+1, Hex16(S.X[I*2+1])]).Append(CRLF);
        SB.AppendFormat('X28: %s   FP : %s', [Hex16(S.X[28]), Hex16(S.Fp)]); SB.Append(CRLF);
        SB.AppendFormat('LR : %s   SP : %s', [Hex16(S.Lr),    Hex16(S.Sp)]); SB.Append(CRLF);
        SB.AppendFormat('PC : %s   CPSR: %.8x', [Hex16(S.Pc), S.Cpsr]);      SB.Append(CRLF);
        // The EL Viewer keeps a CPU section only if it contains 'EAX' or 'RAX'
        // (TLogFile.GetItem_CPU); ARM64 has neither, so this note carries the token.
        SB.Append('EAX/RAX: n/a on ARM64 - added only for EurekaLog Viewer compatibility'); SB.Append(CRLF);
        {$IFEND}
      end;
    else
      SB.Append('(CPU arch not captured - signal info only)'); SB.Append(CRLF);
    end;

    SB.Append(CRLF);

    // ===== Stack / Memory Dump (EL format) =====
    // IMPORTANT: NO stray text between EXP/STK and the "Stack:" header - the EL
    // Viewer strictly expects an empty CRLF and then
    // "Stack:                       Memory Dump:". Our metadata
    // (Signal/Fault/Invocations/Note) goes into a separate "Crash Signal Info:"
    // section at the very end of the .el (see FormatSignalInfoSection).
    {$IF Defined(CPUX64) or Defined(CPUARM64)}
    if S.StackBaseAddr <> 0 then
    begin
      // Header row "Stack:" padded to 36 + "Memory Dump:" (EL ECPUFmt).
      SB.Append('Stack:                              Memory Dump:'); SB.Append(CRLF);
      // Dashes: 34 + 3 spaces + 83 (see EConsts.pas ECPUFmt for CPUX64).
      SB.Append(StringOfChar('-', 34));
      SB.Append('   ');
      SB.Append(StringOfChar('-', 83));
      SB.Append(CRLF);

      for I := 0 to 15 do
      begin
        SB.Append(FormatStackDumpRow(S, I));
        SB.Append(CRLF);
      end;
    end;
    {$IFEND}

    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function FormatSignalInfoSection(const S: TSignalSnapshot): String;
// A separate "Crash Signal Info:" section - outside the EL format, the EL Viewer
// ignores it, but the text is human-readable and useful for diagnostics. Placed
// at the very end of the .el file, after all EL-known sections.
var
  SB:  TStringBuilder;
  RIP: UInt64;
begin
  {$IF Defined(CPUX64)}
  RIP := S.Rip;
  {$ELSEIF Defined(CPUARM64)}
  RIP := S.Pc;
  {$ELSE}
  RIP := 0;
  {$IFEND}

  SB := TStringBuilder.Create;
  try
    SB.Append('Crash Signal Info:'); SB.Append(CRLF);
    SB.Append(StringOfChar('-', 20));  SB.Append(CRLF);
    SB.AppendFormat('  Signal     : %s (code=%d)',
      [SignalNameOf(S.SignalNum), S.SignalCode]); SB.Append(CRLF);
    SB.AppendFormat('  Fault addr : %s', [Hex16(S.FaultAddr)]); SB.Append(CRLF);
    SB.AppendFormat('  Invocations: %d  (signal handler entries since last report)',
      [S.InvocationCount]); SB.Append(CRLF);
    if GuessSnapshotIsSecondary(RIP, S.FaultAddr) then
    begin
      SB.Append('  Note       : RIP in shared-lib range - this is a SECONDARY signal'); SB.Append(CRLF);
      SB.Append('               (caught inside the Pascal RTL / call-stack unwinder).'); SB.Append(CRLF);
      SB.Append('               Registers section omitted - it would show the unwinder,'); SB.Append(CRLF);
      SB.Append('               not the fault. Primary crash details are in section 2.'); SB.Append(CRLF);
    end
    else if (S.FaultAddr <> 0) and (S.FaultAddr = RIP) then
    begin
      SB.Append('  Note       : instruction-fetch fault (FaultAddr = RIP) - control flow'); SB.Append(CRLF);
      SB.Append('               jumped to a wild address (bad function pointer / smashed'); SB.Append(CRLF);
      SB.Append('               return address / corrupt vtable). The faulting frame has no'); SB.Append(CRLF);
      SB.Append('               symbol and the caller is dropped from the backtrace (unwind'); SB.Append(CRLF);
      SB.Append('               breaks at the wild RIP) - read the return addresses in the'); SB.Append(CRLF);
      SB.Append('               Stack dump above to locate the call site.'); SB.Append(CRLF);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

procedure CrashTakeAndFormatSnapshots(out ARegistersSection,
  ASignalInfoSection: String);
var
  S: TSignalSnapshot;
  RIP: UInt64;
begin
  ARegistersSection := '';
  ASignalInfoSection := '';
  if not TakeSnapshot(S) then Exit;
  {$IF Defined(CPUX64)}
  RIP := S.Rip;
  {$ELSEIF Defined(CPUARM64)}
  RIP := S.Pc;
  {$ELSE}
  RIP := 0;
  {$IFEND}
  // Emit the Registers section ONLY for a primary fault. A "secondary" snapshot
  // (RIP in the shared-lib range) is not the crash - it's a benign fault caught
  // inside the Pascal RTL / call-stack unwinder (e.g. _Unwind_Backtrace reading
  // past the top stack frame); its registers are the unwinder's, not the crash's,
  // so they are noise. A primary hardware fault in our own code has RIP in the
  // exe's low range and its registers are kept. The Signal Info block is emitted
  // regardless (small, diagnostic; its Note explains the omission).
  if not GuessSnapshotIsSecondary(RIP, S.FaultAddr) then
    ARegistersSection := FormatRegistersSection(S);
  ASignalInfoSection := FormatSignalInfoSection(S);
end;

procedure CrashRecordMacOSSnapshot(const ARegs: TCrashMacOSRegs;
  ASignalNum, ASignalCode: Integer; AFaultAddr: UInt64;
  AStackBase: UInt64; AStackBytes: Pointer; AStackLen: Integer);
begin
  TInterlocked.Increment(GSignalSnapshot.InvocationCount);
  // Capture only the FIRST exception (as the POSIX handler does) - a later
  // secondary fault must not overwrite the primary registers.
  if TInterlocked.CompareExchange(GSignalSnapshot.Claimed, 1, 0) = 0 then
  begin
    GSignalSnapshot.Kind       := Ord(skMacOSX64);
    GSignalSnapshot.SignalNum  := ASignalNum;
    GSignalSnapshot.SignalCode := ASignalCode;
    GSignalSnapshot.FaultAddr  := AFaultAddr;
    {$IF Defined(CPUX64)}
    GSignalSnapshot.Rax := ARegs.Rax;  GSignalSnapshot.Rbx := ARegs.Rbx;
    GSignalSnapshot.Rcx := ARegs.Rcx;  GSignalSnapshot.Rdx := ARegs.Rdx;
    GSignalSnapshot.Rdi := ARegs.Rdi;  GSignalSnapshot.Rsi := ARegs.Rsi;
    GSignalSnapshot.Rbp := ARegs.Rbp;  GSignalSnapshot.Rsp := ARegs.Rsp;
    GSignalSnapshot.R8  := ARegs.R8;   GSignalSnapshot.R9  := ARegs.R9;
    GSignalSnapshot.R10 := ARegs.R10;  GSignalSnapshot.R11 := ARegs.R11;
    GSignalSnapshot.R12 := ARegs.R12;  GSignalSnapshot.R13 := ARegs.R13;
    GSignalSnapshot.R14 := ARegs.R14;  GSignalSnapshot.R15 := ARegs.R15;
    GSignalSnapshot.Rip := ARegs.Rip;  GSignalSnapshot.Rflags := ARegs.Rflags;
    GSignalSnapshot.Cs  := ARegs.Cs;
    {$IFEND}
    // Stack dump (read SAFELY by the caller, e.g. via vm_read_overwrite). It lets
    // the EL Viewer recognise the full "Registers:" + "Stack:/Memory Dump"
    // section - without the Stack Dump the Viewer's CPU tab stays blank even
    // though the registers are in the .el text.
    GSignalSnapshot.StackBaseAddr := AStackBase;
    if (AStackBase <> 0) and (AStackBytes <> nil) and (AStackLen > 0) then
    begin
      if AStackLen > STACK_DUMP_BYTES then AStackLen := STACK_DUMP_BYTES;
      Move(AStackBytes^, GSignalSnapshot.StackBytes[0], AStackLen);
    end;
    TInterlocked.Exchange(GSignalSnapshot.Captured, 1); // publish after fill
  end;
end;

{$ELSE}  // not CRASH_SIGCAP -> no-op stubs

procedure CrashInstallSignalHandlers;            begin end;
function  CrashHasSignalSnapshot: Boolean;       begin Result := False; end;
function  CrashPrimaryFaultAddr(out AAddr: UIntPtr): Boolean; begin AAddr := 0; Result := False; end;
function  CrashPrimaryFaultCallerAddr(out ACaller: UIntPtr): Boolean; begin ACaller := 0; Result := False; end;
procedure CrashTakeAndFormatSnapshots(out ARegistersSection, ASignalInfoSection: String);
begin
  ARegistersSection := '';
  ASignalInfoSection := '';
end;
procedure CrashRecordMacOSSnapshot(const ARegs: TCrashMacOSRegs;
  ASignalNum, ASignalCode: Integer; AFaultAddr: UInt64;
  AStackBase: UInt64; AStackBytes: Pointer; AStackLen: Integer); begin end;

{$IFEND}

end.
