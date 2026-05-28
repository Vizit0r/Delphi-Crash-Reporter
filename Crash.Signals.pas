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
    - Everything else (Linux ARM, Android, iOS, Windows) - the API compiles to
      no-op stubs. }

interface

procedure CrashInstallSignalHandlers;
function  CrashHasSignalSnapshot: Boolean;

// Takes the snapshot from the global and formats BOTH blocks:
//   ARegistersSection  - EL-compatible "Registers:" + registers + Stack/Memory Dump.
//   ASignalInfoSection - our own metadata (Signal/Code/Fault addr/Invocations/Note)
//     as a separate "Crash Signal Info:" section - the EL Viewer does not parse
//     it, but the text is human-readable and does not interfere with parsing of
//     the Registers section.
// Resets the Captured/InvocationCount flags. If there was no snapshot, both ''.
procedure CrashTakeAndFormatSnapshots(out ARegistersSection, ASignalInfoSection: String);

implementation

{$IF (Defined(LINUX) and Defined(CPUX64)) or
     (Defined(MACOS) and (Defined(CPUX64) or Defined(CPUARM64)))}
  {$DEFINE CRASH_SIGCAP}
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
  TSnapshotKind = (skNone, skLinuxX64, skMacOSX64, skMacOSArm64);

  TSignalSnapshot = packed record
    Captured:      Integer;                         // atomic flag: 0=empty, 1=valid
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

function ExtractFaultAddr(SigInfo: Psiginfo_t): UInt64; inline;
begin
  Result := 0;
  if SigInfo = nil then Exit;
  {$IF Defined(LINUX)}
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

  if TInterlocked.CompareExchange(GSignalSnapshot.Captured, 1, 0) = 0 then
  begin
    GSignalSnapshot.SignalNum := SigNum;
    if SigInfo <> nil then
    begin
      GSignalSnapshot.SignalCode := SigInfo.si_code;
      GSignalSnapshot.FaultAddr  := ExtractFaultAddr(SigInfo);
    end;
    CaptureFromUContext(Context);
    CopyStackTop(GetStackPointer);
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
  {$IF Defined(LINUX)}
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
  {$IF Defined(LINUX)}
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
    {$IF Defined(LINUX)}
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

function GuessSnapshotIsSecondary(RIP: UInt64): Boolean; inline;
// Heuristic: on Linux/macOS x86-64 the exe is mapped into the lower half of the
// address space (<= ~4 GiB here), shared libs/mmap into the upper half
// (>= ~0x7000_0000_0000). If the snapshotted RIP is in the shared-lib range,
// our handler fired not on the primary faulting instruction in our code but
// already inside the Pascal RTL stack unwinder / call-stack reader. In that
// case the primary crash went straight to the Pascal RTL SignalConverter, which
// overwrote our sigaction before the fault.
begin
  Result := RIP >= UInt64($700000000000);
end;

{$IF Defined(CPUX64)}
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
      skMacOSArm64:
      begin
        {$IF Defined(CPUARM64)}
        // ARM64 - EL has no defined format for ARM, emit a compact list of two.
        for I := 0 to 14 do
          SB.AppendFormat('X%-2d: %s   X%-2d: %s',
            [I*2, Hex16(S.X[I*2]), I*2+1, Hex16(S.X[I*2+1])]).Append(CRLF);
        SB.AppendFormat('X28: %s   FP : %s', [Hex16(S.X[28]), Hex16(S.Fp)]); SB.Append(CRLF);
        SB.AppendFormat('LR : %s   SP : %s', [Hex16(S.Lr),    Hex16(S.Sp)]); SB.Append(CRLF);
        SB.AppendFormat('PC : %s   CPSR: %.8x', [Hex16(S.Pc), S.Cpsr]);      SB.Append(CRLF);
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
    {$IF Defined(CPUX64)}
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
    if GuessSnapshotIsSecondary(RIP) then
    begin
      SB.Append('  Note       : RIP in shared-lib range - this is a SECONDARY signal'); SB.Append(CRLF);
      SB.Append('               (caught inside the Pascal RTL / call-stack unwinder).'); SB.Append(CRLF);
      SB.Append('               Primary crash details are in section 2 (Exception).'); SB.Append(CRLF);
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
begin
  ARegistersSection := '';
  ASignalInfoSection := '';
  if not TakeSnapshot(S) then Exit;
  ARegistersSection  := FormatRegistersSection(S);
  ASignalInfoSection := FormatSignalInfoSection(S);
end;

{$ELSE}  // not CRASH_SIGCAP -> no-op stubs

procedure CrashInstallSignalHandlers;            begin end;
function  CrashHasSignalSnapshot: Boolean;       begin Result := False; end;
procedure CrashTakeAndFormatSnapshots(out ARegistersSection, ASignalInfoSection: String);
begin
  ARegistersSection := '';
  ASignalInfoSection := '';
end;

{$IFEND}

end.
