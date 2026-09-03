unit Crash.ThreadCapture;

{ Process-wide POSIX service for taking a raw stack snapshot of an explicitly
  registered application thread.

  The capture signal handler is process-global; registrations and fixed raw
  slots are per thread. The handler performs no allocation, formatting, locks
  or Delphi TLS access. Callers own policy (freeze detection, report limits,
  thread names and EL formatting); this unit owns only signal/slot lifetime and
  raw unwind.

  Supported runtime backends:
    Linux x86-64, Android ARM64, macOS x86-64/ARM64.
  Other targets compile to fail-soft stubs. }

interface

uses
  System.SysUtils;

const
  CRASH_THREAD_CAPTURE_MAX_FRAMES = 64;
  CRASH_THREAD_CAPTURE_RAW_WORDS = 128;
  CRASH_THREAD_CAPTURE_SLOT_COUNT = 64;

type
  TCrashThreadNativeIdentity = record
    PThread: UInt64;
    KernelThread: UInt64;
  end;

  TCrashThreadCaptureHandle = Pointer;

  TCrashThreadCaptureOutcome = (
    tcoCaptured,
    tcoTimedOut,
    tcoThreadGone,
    tcoUnavailable,
    tcoFailed
  );

  TCrashThreadCaptureStopReason = (
    tcsrNone,
    tcsrEnd,
    tcsrBoundsNone,
    tcsrStackPointerOutside,
    tcsrFramePointerZero,
    tcsrFramePointerOutside,
    tcsrFramePointerMisaligned,
    tcsrFramePointerNonMonotonic,
    tcsrFrameInvalidCode,
    tcsrFrameLimit
  );

  TCrashThreadRawTrace = record
    InterruptedIP: UIntPtr;
    Addresses: TArray<UIntPtr>;
    BoundsAvailable: Boolean;
    FPFrameCount: Integer;
    RawFrameCount: Integer;
    RawInnerFrameCount: Integer;
    StopReason: TCrashThreadCaptureStopReason;
  end;

  { Calm-path callback used by Crash.Signals. A newly acquired/released capture
    signal changes the sa_mask required by already-installed fault handlers. }
  TCrashThreadCaptureSignalRefreshProc = procedure;

function CrashThreadCaptureAcquire: Boolean;
procedure CrashThreadCaptureRelease;
function CrashThreadCaptureAvailable: Boolean;
function CrashThreadCaptureSignalNumber: Integer;
procedure CrashThreadCaptureSetSignalRefresh(
  const AProc: TCrashThreadCaptureSignalRefreshProc);

function CrashCurrentPThreadIdent: UInt64;
function CrashCurrentKernelThreadIdent: UInt64;
function CrashCurrentThreadNativeIdentity: TCrashThreadNativeIdentity;
function CrashThreadCaptureContextInstructionPointer(AContext: Pointer): UInt64;

function CrashThreadCaptureRegisterCurrentThread(
  out AHandle: TCrashThreadCaptureHandle): Boolean;
procedure CrashThreadCaptureUnregisterCurrentThread(
  var AHandle: TCrashThreadCaptureHandle);
function CrashThreadCaptureCapture(const AHandle: TCrashThreadCaptureHandle;
  const AWaitMS: Integer; out ATrace: TCrashThreadRawTrace):
  TCrashThreadCaptureOutcome;
function CrashThreadCaptureStopReasonText(
  const AReason: TCrashThreadCaptureStopReason): String;
function CrashThreadCaptureFormatDiagnostics(const AThreadID: UInt64;
  const ATrace: TCrashThreadRawTrace): String;

{$IFDEF AUTOTESTS}
function CrashThreadCaptureCurrentSignalBlocked: Boolean;
function CrashThreadCaptureTestIdentityMatches(
  const AHandle: TCrashThreadCaptureHandle;
  const APThread, AKernelThread: UInt64): Boolean;
function CrashThreadCaptureTestSetKernelIdentity(
  const AHandle: TCrashThreadCaptureHandle;
  const AKernelThread: UInt64): Boolean;
function CrashThreadCaptureTestQuarantine(
  const AHandle: TCrashThreadCaptureHandle): Boolean;
function CrashThreadCaptureTestLiveSlotCount: Integer;
function CrashThreadCaptureTestLiveSlotSummary: String;
function CrashThreadCaptureTestResetQuarantined(
  const AHandle: TCrashThreadCaptureHandle): Boolean;
procedure CrashThreadCaptureTestResetAllQuarantined;
procedure CrashThreadCaptureTestBoundedWalk(const AStackLow, AStackHigh,
  AStackPointer, AFramePointer: UIntPtr; out AFPCount, ARawWordCount: Integer;
  out ARawBase, AFirstRawWord: UIntPtr;
  out AStopReason: TCrashThreadCaptureStopReason);
function CrashThreadCaptureTestX86FFCall(const ABytes: TBytes): Boolean;
function CrashThreadCaptureTestARM64Call(const AInstruction: UInt32): Boolean;
function CrashThreadCaptureTestMergeRules: Boolean;
function CrashThreadCaptureTestSetContextOverride(
  const AHandle: TCrashThreadCaptureHandle; const AStackLow, AStackHigh,
  AStackPointer, AFramePointer: UIntPtr): Boolean;
function CrashThreadCaptureTestHandlerStackAddress(
  const AHandle: TCrashThreadCaptureHandle): UIntPtr;
function CrashThreadCaptureTestActionUsesAltStack: Boolean;
{$ENDIF}

implementation

{$IF (Defined(LINUX) and Defined(CPUX64)) or
     (Defined(ANDROID) and Defined(CPUARM64)) or
     (Defined(MACOS) and not Defined(IOS) and
       (Defined(CPUX64) or Defined(CPUARM64)))}
  {$DEFINE CRASH_THREADCAP}
{$ENDIF}

{$IF Defined(LINUX) or Defined(ANDROID)}
  {$DEFINE CRASH_THREADCAP_LINUXLIKE}
{$ENDIF}

{$IF Defined(CRASH_THREADCAP)}

uses
  System.Classes,
  System.Math,
  System.SyncObjs,
  Crash.Modules,
  Posix.Base,
  Posix.Signal,
  Posix.Pthread,
  Posix.String_,
  Posix.SysTypes;

const
  SLOT_FREE        = 0;
  SLOT_IDLE        = 1;
  SLOT_ARMED       = 2;
  SLOT_CAPTURING   = 3;
  SLOT_CAPTURED    = 4;
  SLOT_POISONED    = 5;
  SLOT_QUARANTINED = 6;

  CAPTURE_WAIT_QUANTUM_MS = 1;

  {$IF Defined(LINUX) and Defined(CPUX64)}
  SYS_GETTID = 186;
  {$ELSEIF Defined(ANDROID) and Defined(CPUARM64)}
  SYS_GETTID = 178;
  {$ENDIF}

type
  PCrashUIntPtr = ^UIntPtr;
  PCrashThreadCaptureSlot = ^TCrashThreadCaptureSlot;
  TCrashThreadCaptureSlot = record
    State: Integer;       // atomic SLOT_* state; published after identity fields
    Closing: Integer;     // atomic: no new request may arm this slot
    OwnerRefs: Integer;   // calm path, protected by GServiceLock
    PThreadIdent: UInt64;
    KernelIdent: UInt64;
    StackLow: UIntPtr;
    StackHigh: UIntPtr;
    StackBoundsOK: Integer;
    InterruptedIP: UInt64;
    InterruptedSP: UIntPtr;
    InterruptedFP: UIntPtr;
    Count: Integer;
    Addrs: array [0..CRASH_THREAD_CAPTURE_MAX_FRAMES - 1] of UIntPtr;
    AddrStackPos: array [0..CRASH_THREAD_CAPTURE_MAX_FRAMES - 1] of UIntPtr;
    RawBaseSP: UIntPtr;
    RawWordCount: Integer;
    RawWords: array [0..CRASH_THREAD_CAPTURE_RAW_WORDS - 1] of UIntPtr;
    StopReason: TCrashThreadCaptureStopReason;
    {$IFDEF AUTOTESTS}
    TestContextOverride: Integer;
    TestStackPointer: UIntPtr;
    TestFramePointer: UIntPtr;
    TestHandlerStackAddress: UIntPtr;
    {$ENDIF}
  end;

  TCrashTraceCandidate = record
    StackPos: UIntPtr;
    Address: UIntPtr;
    IsRaw: Boolean;
  end;
  TCrashTraceCandidates = TArray<TCrashTraceCandidate>;

  TCrashTimespec = record
    tv_sec: Int64;
    tv_nsec: Int64;
  end;
  PCrashTimespec = ^TCrashTimespec;

var
  GSlots: array [0..CRASH_THREAD_CAPTURE_SLOT_COUNT - 1] of TCrashThreadCaptureSlot;
  GServiceLock: TCriticalSection;
  GCoordinatorLock: TCriticalSection;
  GAcquireCount: Integer = 0;
  GActive: Integer = 0;
  GCaptureSignal: Integer = -1;
  GPrevAction: sigaction_t;
  GHavePrevAction: Boolean = False;
  GRefreshProc: TCrashThreadCaptureSignalRefreshProc = nil;
  GExecutableRanges: TCrashExecutableRanges;
  GExecutableRangesTick: UInt64 = 0;

{$IF Defined(CRASH_THREADCAP_LINUXLIKE)}
function __libc_current_sigrtmin: Integer; cdecl;
  external libc name _PU + '__libc_current_sigrtmin';
function __libc_current_sigrtmax: Integer; cdecl;
  external libc name _PU + '__libc_current_sigrtmax';
function crash_syscall(ANumber: IntPtr): IntPtr; cdecl; varargs;
  external libc name _PU + 'syscall';
function crash_pthread_getattr_np(AThread: pthread_t;
  var AAttr: pthread_attr_t): Integer; cdecl;
  external libc name _PU + 'pthread_getattr_np';
{$ELSEIF Defined(MACOS)}
function pthread_threadid_np(AThread: pthread_t; AThreadID: PUInt64): Integer; cdecl;
  external libc name _PU + 'pthread_threadid_np';
{$ENDIF}

function crash_pthread_sigmask(AHow: Integer; ASet, AOldSet: Psigset_t): Integer; cdecl;
  external libc name _PU + 'pthread_sigmask';
function crash_sigpending(ASet: Psigset_t): Integer; cdecl;
  external libc name _PU + 'sigpending';
{$IF Defined(CRASH_THREADCAP_LINUXLIKE)}
function crash_sigtimedwait(ASet: Psigset_t; AInfo: Psiginfo_t;
  ATimeout: PCrashTimespec): Integer; cdecl;
  external libc name _PU + 'sigtimedwait';
{$ELSEIF Defined(MACOS)}
function crash_sigwait(ASet: Psigset_t; ASig: PInteger): Integer; cdecl;
  external libc name _PU + 'sigwait';
{$ENDIF}

{$IF Defined(MACOS)}
const
  libSystem = '/usr/lib/libSystem.dylib';

function backtrace(ABuffer: PPointer; ASize: Integer): Integer; cdecl;
  external libSystem name 'backtrace';
{$ENDIF}

function CrashCurrentPThreadIdent: UInt64;
begin
  Result := UInt64(NativeUInt(pthread_self));
end;

function CrashCurrentKernelThreadIdent: UInt64;
{$IF Defined(CRASH_THREADCAP_LINUXLIKE)}
begin
  Result := UInt64(crash_syscall(SYS_GETTID));
end;
{$ELSE}
var
  ThreadID: UInt64;
begin
  ThreadID := 0;
  if pthread_threadid_np(pthread_self, @ThreadID) <> 0 then
    ThreadID := 0;
  Result := ThreadID;
end;
{$ENDIF}

function CrashCurrentThreadNativeIdentity: TCrashThreadNativeIdentity;
begin
  Result.PThread := CrashCurrentPThreadIdent;
  Result.KernelThread := CrashCurrentKernelThreadIdent;
end;

function CrashThreadCaptureContextInstructionPointer(AContext: Pointer): UInt64;
begin
  Result := 0;
  if AContext = nil then
    Exit;
  {$IF Defined(LINUX) and Defined(CPUX64)}
  Result := UInt64(Pucontext_t(AContext).uc_mcontext.gregs[REG_RIP]);
  {$ELSEIF Defined(MACOS) and Defined(CPUX64)}
  if Pucontext_t(AContext).uc_mcontext <> nil then
    Result := Pucontext_t(AContext).uc_mcontext^.__ss.__rip;
  {$ELSEIF Defined(MACOS) and Defined(CPUARM64)}
  if Pucontext_t(AContext).uc_mcontext <> nil then
    Result := Pucontext_t(AContext).uc_mcontext^.__ss.__pc;
  {$ELSEIF Defined(ANDROID) and Defined(CPUARM64)}
  Result := UInt64(Pucontext_t(AContext).uc_mcontext.arm_pc);
  {$ENDIF}
end;

function CrashThreadCaptureContextStackPointer(AContext: Pointer): UIntPtr;
begin
  Result := 0;
  if AContext = nil then
    Exit;
  {$IF Defined(LINUX) and Defined(CPUX64)}
  Result := UIntPtr(Pucontext_t(AContext).uc_mcontext.gregs[REG_RSP]);
  {$ELSEIF Defined(MACOS) and Defined(CPUX64)}
  if Pucontext_t(AContext).uc_mcontext <> nil then
    Result := UIntPtr(Pucontext_t(AContext).uc_mcontext^.__ss.__rsp);
  {$ELSEIF Defined(MACOS) and Defined(CPUARM64)}
  if Pucontext_t(AContext).uc_mcontext <> nil then
    Result := UIntPtr(Pucontext_t(AContext).uc_mcontext^.__ss.__sp);
  {$ELSEIF Defined(ANDROID) and Defined(CPUARM64)}
  Result := UIntPtr(Pucontext_t(AContext).uc_mcontext.arm_sp);
  {$ENDIF}
end;

function CrashThreadCaptureContextFramePointer(AContext: Pointer): UIntPtr;
begin
  Result := 0;
  if AContext = nil then
    Exit;
  {$IF Defined(LINUX) and Defined(CPUX64)}
  Result := UIntPtr(Pucontext_t(AContext).uc_mcontext.gregs[REG_RBP]);
  {$ELSEIF Defined(MACOS) and Defined(CPUX64)}
  if Pucontext_t(AContext).uc_mcontext <> nil then
    Result := UIntPtr(Pucontext_t(AContext).uc_mcontext^.__ss.__rbp);
  {$ELSEIF Defined(MACOS) and Defined(CPUARM64)}
  if Pucontext_t(AContext).uc_mcontext <> nil then
    Result := UIntPtr(Pucontext_t(AContext).uc_mcontext^.__ss.__fp);
  {$ELSEIF Defined(ANDROID) and Defined(CPUARM64)}
  Result := UIntPtr(Pucontext_t(AContext).uc_mcontext.regs[29]);
  {$ENDIF}
end;

function CrashThreadCaptureStopReasonText(
  const AReason: TCrashThreadCaptureStopReason): String;
begin
  case AReason of
    tcsrEnd: Result := 'end';
    tcsrBoundsNone: Result := 'bounds-none';
    tcsrStackPointerOutside: Result := 'sp-outside';
    tcsrFramePointerZero: Result := 'fp-zero';
    tcsrFramePointerOutside: Result := 'fp-outside';
    tcsrFramePointerMisaligned: Result := 'fp-misaligned';
    tcsrFramePointerNonMonotonic: Result := 'fp-nonmonotonic';
    tcsrFrameInvalidCode: Result := 'fp-invalid-code';
    tcsrFrameLimit: Result := 'frame-limit';
  else
    Result := 'none';
  end;
end;

function CrashThreadCaptureFormatDiagnostics(const AThreadID: UInt64;
  const ATrace: TCrashThreadRawTrace): String;
var
  BoundsText: String;
begin
  if (ATrace.StopReason = tcsrNone) and (not ATrace.BoundsAvailable) and
     (ATrace.FPFrameCount = 0) and (ATrace.RawFrameCount = 0) then
    Exit('');
  if ATrace.BoundsAvailable then
    BoundsText := 'ok'
  else
    BoundsText := 'none';
  Result := 'thread ' + UIntToStr(Cardinal(AThreadID)) +
    ': bounds=' + BoundsText +
    ' fp-frames=' + IntToStr(ATrace.FPFrameCount) +
    ' raw-frames=' + IntToStr(ATrace.RawFrameCount) +
    ' raw-inner=' + IntToStr(ATrace.RawInnerFrameCount) +
    ' stop=' + CrashThreadCaptureStopReasonText(ATrace.StopReason);
end;

function TryGetCurrentThreadStackBounds(out ALow, AHigh: UIntPtr): Boolean;
{$IF Defined(CRASH_THREADCAP_LINUXLIKE)}
var
  Attr: pthread_attr_t;
  StackBase: Pointer;
  StackSize: size_t;
  Marker: Byte;
begin
  Result := False;
  ALow := 0;
  AHigh := 0;
  FillChar(Attr, SizeOf(Attr), 0);
  if crash_pthread_getattr_np(pthread_self, Attr) <> 0 then
    Exit;
  try
    StackBase := nil;
    StackSize := 0;
    if pthread_attr_getstack(Attr, StackBase, StackSize) <> 0 then
      Exit;
    if (StackBase = nil) or (StackSize < 2 * SizeOf(Pointer)) then
      Exit;
    ALow := UIntPtr(StackBase);
    if UIntPtr(StackSize) > High(UIntPtr) - ALow then
      Exit;
    AHigh := ALow + UIntPtr(StackSize);
    if (UIntPtr(@Marker) < ALow) or (UIntPtr(@Marker) >= AHigh) then
    begin
      ALow := 0;
      AHigh := 0;
      Exit;
    end;
    Result := True;
  finally
    pthread_attr_destroy(Attr);
  end;
end;
{$ELSE}
begin
  ALow := 0;
  AHigh := 0;
  Result := False;
end;
{$ENDIF}

function SlotState(const ASlot: PCrashThreadCaptureSlot): Integer;
begin
  Result := TInterlocked.CompareExchange(ASlot.State, 0, 0);
end;

function SlotMatchesIdentity(const ASlot: PCrashThreadCaptureSlot;
  const AIdentity: TCrashThreadNativeIdentity): Boolean;
begin
  Result := (ASlot.PThreadIdent = AIdentity.PThread) and
    (ASlot.KernelIdent = AIdentity.KernelThread);
end;

function SlotFromHandle(const AHandle: TCrashThreadCaptureHandle):
  PCrashThreadCaptureSlot;
var
  I: Integer;
begin
  Result := nil;
  if AHandle = nil then
    Exit;
  for I := 0 to High(GSlots) do
    if AHandle = Pointer(@GSlots[I]) then
      Exit(@GSlots[I]);
end;

procedure ResetSlot(const ASlot: PCrashThreadCaptureSlot);
begin
  TInterlocked.Exchange(ASlot.State, SLOT_FREE);
  ASlot.Closing := 0;
  ASlot.OwnerRefs := 0;
  ASlot.PThreadIdent := 0;
  ASlot.KernelIdent := 0;
  ASlot.StackLow := 0;
  ASlot.StackHigh := 0;
  ASlot.StackBoundsOK := 0;
  ASlot.InterruptedIP := 0;
  ASlot.InterruptedSP := 0;
  ASlot.InterruptedFP := 0;
  ASlot.Count := 0;
  ASlot.RawBaseSP := 0;
  ASlot.RawWordCount := 0;
  ASlot.StopReason := tcsrNone;
  {$IFDEF AUTOTESTS}
  ASlot.TestContextOverride := 0;
  ASlot.TestStackPointer := 0;
  ASlot.TestFramePointer := 0;
  ASlot.TestHandlerStackAddress := 0;
  {$ENDIF}
end;

procedure CaptureBoundedStack(const ASlot: PCrashThreadCaptureSlot;
  const ASP, AFP: UIntPtr);
var
  AlignedSP, FP, PreviousFP, ReturnAddress, AvailableWords: UIntPtr;
  I: Integer;
begin
  ASlot.InterruptedSP := ASP;
  ASlot.InterruptedFP := AFP;
  ASlot.Count := 0;
  ASlot.RawBaseSP := 0;
  ASlot.RawWordCount := 0;
  ASlot.StopReason := tcsrNone;

  if ASlot.StackBoundsOK = 0 then
  begin
    ASlot.StopReason := tcsrBoundsNone;
    Exit;
  end;
  if (ASlot.StackHigh <= ASlot.StackLow) or
     (ASlot.StackHigh - ASlot.StackLow < 2 * SizeOf(Pointer)) then
  begin
    ASlot.StopReason := tcsrBoundsNone;
    Exit;
  end;
  if (ASP < ASlot.StackLow) or (ASP >= ASlot.StackHigh) then
  begin
    ASlot.StopReason := tcsrStackPointerOutside;
    Exit;
  end;

  if ASP > High(UIntPtr) - (SizeOf(Pointer) - 1) then
    AlignedSP := ASlot.StackHigh
  else
    AlignedSP := (ASP + SizeOf(Pointer) - 1) and
      not UIntPtr(SizeOf(Pointer) - 1);
  if AlignedSP < ASlot.StackHigh then
  begin
    AvailableWords := (ASlot.StackHigh - AlignedSP) div SizeOf(Pointer);
    if AvailableWords > CRASH_THREAD_CAPTURE_RAW_WORDS then
      AvailableWords := CRASH_THREAD_CAPTURE_RAW_WORDS;
    ASlot.RawBaseSP := AlignedSP;
    ASlot.RawWordCount := Integer(AvailableWords);
    for I := 0 to ASlot.RawWordCount - 1 do
      ASlot.RawWords[I] := PCrashUIntPtr(AlignedSP +
        UIntPtr(I) * SizeOf(Pointer))^;
  end;

  FP := AFP;
  if FP = 0 then
  begin
    ASlot.StopReason := tcsrFramePointerZero;
    Exit;
  end;
  while ASlot.Count < CRASH_THREAD_CAPTURE_MAX_FRAMES do
  begin
    if (FP < ASP) or (FP < ASlot.StackLow) or
       (FP > ASlot.StackHigh - 2 * SizeOf(Pointer)) then
    begin
      ASlot.StopReason := tcsrFramePointerOutside;
      Exit;
    end;
    if (FP and UIntPtr(SizeOf(Pointer) - 1)) <> 0 then
    begin
      ASlot.StopReason := tcsrFramePointerMisaligned;
      Exit;
    end;

    PreviousFP := PCrashUIntPtr(FP)^;
    ReturnAddress := PCrashUIntPtr(FP + SizeOf(Pointer))^;
    if ReturnAddress = 0 then
    begin
      ASlot.StopReason := tcsrEnd;
      Exit;
    end;
    ASlot.Addrs[ASlot.Count] := ReturnAddress;
    ASlot.AddrStackPos[ASlot.Count] := FP + SizeOf(Pointer);
    Inc(ASlot.Count);

    if PreviousFP = 0 then
    begin
      ASlot.StopReason := tcsrEnd;
      Exit;
    end;
    if PreviousFP <= FP then
    begin
      ASlot.StopReason := tcsrFramePointerNonMonotonic;
      Exit;
    end;
    if (PreviousFP and UIntPtr(SizeOf(Pointer) - 1)) <> 0 then
    begin
      ASlot.StopReason := tcsrFramePointerMisaligned;
      Exit;
    end;
    if PreviousFP > ASlot.StackHigh - 2 * SizeOf(Pointer) then
    begin
      ASlot.StopReason := tcsrFramePointerOutside;
      Exit;
    end;
    FP := PreviousFP;
  end;
  ASlot.StopReason := tcsrFrameLimit;
end;

procedure CrashThreadCaptureSignalHandler(ASigNum: Integer;
  ASigInfo: Psiginfo_t; AContext: Pointer); cdecl;
var
  Identity: TCrashThreadNativeIdentity;
  Slot: PCrashThreadCaptureSlot;
  I, State: Integer;
begin
  Identity := CrashCurrentThreadNativeIdentity;
  if (Identity.PThread = 0) or (Identity.KernelThread = 0) then
    Exit;

  for I := 0 to High(GSlots) do
  begin
    Slot := @GSlots[I];
    State := SlotState(Slot);
    if (State <> SLOT_ARMED) and (State <> SLOT_POISONED) then
      Continue;
    if not SlotMatchesIdentity(Slot, Identity) then
      Continue;

    if State = SLOT_POISONED then
    begin
      TInterlocked.CompareExchange(Slot.State, SLOT_IDLE, SLOT_POISONED);
      Exit;
    end;
    if TInterlocked.CompareExchange(Slot.State, SLOT_CAPTURING,
         SLOT_ARMED) <> SLOT_ARMED then
    begin
      // The coordinator may have won the exact timeout boundary with
      // Armed -> Poisoned after State was read above. This delivery is the
      // single late signal: consume it instead of leaving the slot blind.
      if SlotState(Slot) = SLOT_POISONED then
        TInterlocked.CompareExchange(Slot.State, SLOT_IDLE, SLOT_POISONED);
      Exit;
    end;

    Slot.InterruptedIP :=
      CrashThreadCaptureContextInstructionPointer(AContext);
    {$IFDEF AUTOTESTS}
    Slot.TestHandlerStackAddress := UIntPtr(@State);
    {$ENDIF}
    {$IF Defined(MACOS)}
    Slot.Count := backtrace(PPointer(@Slot.Addrs[0]),
      CRASH_THREAD_CAPTURE_MAX_FRAMES);
    if Slot.Count < 0 then
      Slot.Count := 0;
    {$ELSE}
    {$IFDEF AUTOTESTS}
    if TInterlocked.CompareExchange(Slot.TestContextOverride, 0, 0) <> 0 then
      CaptureBoundedStack(Slot, Slot.TestStackPointer, Slot.TestFramePointer)
    else
    {$ENDIF}
      CaptureBoundedStack(Slot,
        CrashThreadCaptureContextStackPointer(AContext),
        CrashThreadCaptureContextFramePointer(AContext));
    {$ENDIF}
    TInterlocked.Exchange(Slot.State, SLOT_CAPTURED);
    Exit;
  end;
end;

procedure SetHandlerInAction(var AAction: sigaction_t); inline;
begin
  {$IF Defined(CRASH_THREADCAP_LINUXLIKE)}
  AAction._u.sa_sigaction := CrashThreadCaptureSignalHandler;
  {$ELSE}
  AAction.__sigaction_handler.sa_sigaction := CrashThreadCaptureSignalHandler;
  {$ENDIF}
end;

function ActionIsOurs(const AAction: sigaction_t): Boolean; inline;
var
  Stored: NativeUInt;
begin
  {$IF Defined(CRASH_THREADCAP_LINUXLIKE)}
  Stored := NativeUInt(@AAction._u.sa_sigaction);
  {$ELSE}
  Stored := NativeUInt(@AAction.__sigaction_handler.sa_sigaction);
  {$ENDIF}
  Result := Stored = NativeUInt(@CrashThreadCaptureSignalHandler);
end;

function CaptureSignalIsFree(const ASig: Integer): Boolean;
var
  Current: sigaction_t;
begin
  FillChar(Current, SizeOf(Current), 0);
  if sigaction(ASig, nil, @Current) <> 0 then
    Exit(False);
  {$IF Defined(CRASH_THREADCAP_LINUXLIKE)}
  Result := not Assigned(Current._u.sa_handler);
  {$ELSE}
  Result := not Assigned(Current.__sigaction_handler.sa_handler);
  {$ENDIF}
end;

function ChooseCaptureSignal: Integer;
{$IF Defined(CRASH_THREADCAP_LINUXLIKE)}
var
  RtMin, RtMax, Sig: Integer;
begin
  Result := -1;
  RtMin := __libc_current_sigrtmin;
  RtMax := __libc_current_sigrtmax;
  if RtMin <= 0 then
    Exit;
  for Sig := RtMin + 5 to RtMax do
    if CaptureSignalIsFree(Sig) then
      Exit(Sig);
end;
{$ELSE}
begin
  if CaptureSignalIsFree(SIGUSR2) then
    Result := SIGUSR2
  else
    Result := -1;
end;
{$ENDIF}

procedure InvokeRefresh(const AProc: TCrashThreadCaptureSignalRefreshProc);
begin
  if not Assigned(AProc) then
    Exit;
  try
    AProc;
  except
    // Signal-mask refresh is best-effort on a calm path. Capture ownership is
    // still valid; callers observe availability separately.
  end;
end;

function HasLiveSlots: Boolean;
var
  I: Integer;
begin
  for I := 0 to High(GSlots) do
    if SlotState(@GSlots[I]) <> SLOT_FREE then
      Exit(True);
  Result := False;
end;

function CrashThreadCaptureAcquire: Boolean;
var
  Action: sigaction_t;
  Sig: Integer;
  Refresh: TCrashThreadCaptureSignalRefreshProc;
begin
  Result := False;
  GCoordinatorLock.Enter;
  try
    GServiceLock.Enter;
    try
      if GAcquireCount > 0 then
      begin
        Inc(GAcquireCount);
        Exit(TInterlocked.CompareExchange(GActive, 0, 0) <> 0);
      end;

      // A contract-violating release with live/quarantined slots deliberately
      // keeps our disposition installed: a delayed pending RT signal must not
      // hit SIG_DFL. A later acquire reuses that retained handler instead of
      // saving our own action as the "previous" disposition.
      if GHavePrevAction and (GCaptureSignal >= 0) then
      begin
        FillChar(Action, SizeOf(Action), 0);
        if (sigaction(GCaptureSignal, nil, @Action) = 0) and
           ActionIsOurs(Action) then
        begin
          GAcquireCount := 1;
          TInterlocked.Exchange(GActive, 1);
          Exit(True);
        end;
        Exit;
      end;

      Sig := ChooseCaptureSignal;
      if Sig < 0 then
        Exit;
      FillChar(Action, SizeOf(Action), 0);
      SetHandlerInAction(Action);
      Action.sa_flags := SA_SIGINFO or SA_RESTART;
      {$IF Defined(CRASH_THREADCAP_LINUXLIKE)}
      Action.sa_flags := Action.sa_flags or SA_ONSTACK;
      {$ENDIF}
      sigemptyset(Action.sa_mask);
      FillChar(GPrevAction, SizeOf(GPrevAction), 0);
      if sigaction(Sig, @Action, @GPrevAction) <> 0 then
        Exit;

      GCaptureSignal := Sig;
      GHavePrevAction := True;
      GAcquireCount := 1;
      TInterlocked.Exchange(GActive, 1);
      Refresh := GRefreshProc;
      Result := True;
    finally
      GServiceLock.Leave;
    end;
  finally
    GCoordinatorLock.Leave;
  end;
  InvokeRefresh(Refresh);
end;

procedure CrashThreadCaptureRelease;
var
  Current: sigaction_t;
  Refresh: TCrashThreadCaptureSignalRefreshProc;
  LiveSlots: Boolean;
begin
  GCoordinatorLock.Enter;
  try
    GServiceLock.Enter;
    try
      if GAcquireCount <= 0 then
        Exit;
      Dec(GAcquireCount);
      if GAcquireCount > 0 then
        Exit;

      LiveSlots := HasLiveSlots;
      if GHavePrevAction and (not LiveSlots) then
      begin
        GHavePrevAction := False;
        FillChar(Current, SizeOf(Current), 0);
        if (sigaction(GCaptureSignal, nil, @Current) = 0) and
           ActionIsOurs(Current) then
          sigaction(GCaptureSignal, @GPrevAction, nil);
      end;
      TInterlocked.Exchange(GActive, 0);
      if not LiveSlots then
        GCaptureSignal := -1;
      Refresh := GRefreshProc;
    finally
      GServiceLock.Leave;
    end;
  finally
    GCoordinatorLock.Leave;
  end;
  InvokeRefresh(Refresh);
end;

function CrashThreadCaptureAvailable: Boolean;
begin
  Result := TInterlocked.CompareExchange(GActive, 0, 0) <> 0;
end;

function CrashThreadCaptureSignalNumber: Integer;
begin
  Result := TInterlocked.CompareExchange(GCaptureSignal, 0, 0);
end;

procedure CrashThreadCaptureSetSignalRefresh(
  const AProc: TCrashThreadCaptureSignalRefreshProc);
var
  CallNow: Boolean;
begin
  GServiceLock.Enter;
  try
    GRefreshProc := AProc;
    CallNow := Assigned(AProc) and CrashThreadCaptureAvailable;
  finally
    GServiceLock.Leave;
  end;
  if CallNow then
    InvokeRefresh(AProc);
end;

function DrainCurrentPendingSignal(const ASig: Integer): Boolean;
var
  OneSignal, OldMask, Pending: sigset_t;
  {$IF Defined(CRASH_THREADCAP_LINUXLIKE)}
  WaitTime: TCrashTimespec;
  {$ENDIF}
  Consumed: Integer;
begin
  Result := False;
  if ASig < 0 then
    Exit(True);
  FillChar(OneSignal, SizeOf(OneSignal), 0);
  FillChar(OldMask, SizeOf(OldMask), 0);
  FillChar(Pending, SizeOf(Pending), 0);
  sigemptyset(OneSignal);
  sigaddset(OneSignal, ASig);
  if crash_pthread_sigmask(SIG_BLOCK, @OneSignal, @OldMask) <> 0 then
    Exit;
  try
    if crash_sigpending(@Pending) <> 0 then
      Exit;
    if sigismember(Pending, ASig) <> 1 then
      Exit(True);
    {$IF Defined(CRASH_THREADCAP_LINUXLIKE)}
    FillChar(WaitTime, SizeOf(WaitTime), 0);
    Consumed := crash_sigtimedwait(@OneSignal, nil, @WaitTime);
    Result := Consumed = ASig;
    {$ELSE}
    Consumed := 0;
    Result := (crash_sigwait(@OneSignal, @Consumed) = 0) and
      (Consumed = ASig);
    {$ENDIF}
  finally
    if crash_pthread_sigmask(SIG_SETMASK, @OldMask, nil) <> 0 then
      Result := False;
  end;
end;

function CrashThreadCaptureRegisterCurrentThread(
  out AHandle: TCrashThreadCaptureHandle): Boolean;
var
  Identity: TCrashThreadNativeIdentity;
  Collisions: array [0..CRASH_THREAD_CAPTURE_SLOT_COUNT - 1] of
    PCrashThreadCaptureSlot;
  Existing, Slot: PCrashThreadCaptureSlot;
  CollisionCount, I, J: Integer;
  Drained: Boolean;
  WasCollision, ExistingQuarantined, BoundsOK: Boolean;
  StackLow, StackHigh: UIntPtr;
begin
  Result := False;
  AHandle := nil;
  Drained := False;
  ExistingQuarantined := False;
  if not CrashThreadCaptureAvailable then
    Exit;
  Identity := CrashCurrentThreadNativeIdentity;
  if (Identity.PThread = 0) or (Identity.KernelThread = 0) then
    Exit;
  BoundsOK := TryGetCurrentThreadStackBounds(StackLow, StackHigh);

  GCoordinatorLock.Enter;
  try
    Existing := nil;
    CollisionCount := 0;
    GServiceLock.Enter;
    try
      for I := 0 to High(GSlots) do
        if (SlotState(@GSlots[I]) <> SLOT_FREE) and
           (GSlots[I].PThreadIdent = Identity.PThread) then
        begin
          if GSlots[I].KernelIdent = Identity.KernelThread then
          begin
            Existing := @GSlots[I];
            ExistingQuarantined :=
              SlotState(Existing) = SLOT_QUARANTINED;
            Continue;
          end;
          Collisions[CollisionCount] := @GSlots[I];
          Inc(CollisionCount);
          TInterlocked.Exchange(GSlots[I].Closing, 1);
          TInterlocked.Exchange(GSlots[I].State, SLOT_QUARANTINED);
        end;
      if Existing <> nil then
      begin
        Inc(Existing.OwnerRefs);
        Existing.StackLow := StackLow;
        Existing.StackHigh := StackHigh;
        Existing.StackBoundsOK := Ord(BoundsOK);
      end;
    finally
      GServiceLock.Leave;
    end;

    if CollisionCount > 0 then
    begin
      Drained := DrainCurrentPendingSignal(CrashThreadCaptureSignalNumber);
      GServiceLock.Enter;
      try
        if Drained then
          for I := 0 to CollisionCount - 1 do
            ResetSlot(Collisions[I]);
      finally
        GServiceLock.Leave;
      end;
    end;

    if ExistingQuarantined then
    begin
      // A repeated registration is made by the same verified owner. It can
      // safely drain its own late signal and make a fail-safe quarantined slot
      // eligible again without changing the stable handle or owner refs.
      if DrainCurrentPendingSignal(CrashThreadCaptureSignalNumber) then
      begin
        GServiceLock.Enter;
        try
          if (SlotState(Existing) = SLOT_QUARANTINED) and
             SlotMatchesIdentity(Existing, Identity) then
          begin
            TInterlocked.Exchange(Existing.Closing, 0);
            Existing.InterruptedIP := 0;
            Existing.InterruptedSP := 0;
            Existing.InterruptedFP := 0;
            Existing.Count := 0;
            Existing.RawBaseSP := 0;
            Existing.RawWordCount := 0;
            Existing.StopReason := tcsrNone;
            TInterlocked.Exchange(Existing.State, SLOT_IDLE);
          end;
        finally
          GServiceLock.Leave;
        end;
      end;
    end;

    if Existing <> nil then
    begin
      AHandle := Existing;
      Exit(True);
    end;

    GServiceLock.Enter;
    try
      if not CrashThreadCaptureAvailable then
        Exit;
      Slot := nil;
      for I := 0 to High(GSlots) do
        if SlotState(@GSlots[I]) = SLOT_FREE then
        begin
          WasCollision := False;
          for J := 0 to CollisionCount - 1 do
            if Collisions[J] = @GSlots[I] then
            begin
              WasCollision := True;
              Break;
            end;
          if not WasCollision then
          begin
            Slot := @GSlots[I];
            Break;
          end;
        end;
      // Under complete slot pressure, reusing a safely drained collision is
      // preferable to failing registration. Normally a collision gets a
      // distinct handle, which also makes stale-handle bugs observable.
      if (Slot = nil) and (CollisionCount > 0) and Drained then
        Slot := Collisions[0];
      if Slot = nil then
        Exit;
      Slot.Closing := 0;
      Slot.OwnerRefs := 1;
      Slot.PThreadIdent := Identity.PThread;
      Slot.KernelIdent := Identity.KernelThread;
      Slot.StackLow := StackLow;
      Slot.StackHigh := StackHigh;
      Slot.StackBoundsOK := Ord(BoundsOK);
      Slot.InterruptedIP := 0;
      Slot.InterruptedSP := 0;
      Slot.InterruptedFP := 0;
      Slot.Count := 0;
      Slot.RawBaseSP := 0;
      Slot.RawWordCount := 0;
      Slot.StopReason := tcsrNone;
      {$IFDEF AUTOTESTS}
      Slot.TestContextOverride := 0;
      Slot.TestStackPointer := 0;
      Slot.TestFramePointer := 0;
      Slot.TestHandlerStackAddress := 0;
      {$ENDIF}
      TInterlocked.Exchange(Slot.State, SLOT_IDLE);
      AHandle := Slot;
      Result := True;
    finally
      GServiceLock.Leave;
    end;
  finally
    GCoordinatorLock.Leave;
  end;
end;

procedure CrashThreadCaptureUnregisterCurrentThread(
  var AHandle: TCrashThreadCaptureHandle);
var
  Slot: PCrashThreadCaptureSlot;
  Identity: TCrashThreadNativeIdentity;
  Drained: Boolean;
begin
  if AHandle = nil then
    Exit;
  GCoordinatorLock.Enter;
  try
    GServiceLock.Enter;
    try
      Slot := SlotFromHandle(AHandle);
      if (Slot = nil) or (SlotState(Slot) = SLOT_FREE) then
      begin
        AHandle := nil;
        Exit;
      end;
      Identity := CrashCurrentThreadNativeIdentity;
      if (Slot.PThreadIdent <> Identity.PThread) or
         (Slot.KernelIdent <> Identity.KernelThread) then
      begin
        // Wrong-thread unregister violates the API contract. Keep the static
        // slot quarantined rather than freeing memory a pending handler may see.
        TInterlocked.Exchange(Slot.Closing, 1);
        TInterlocked.Exchange(Slot.State, SLOT_QUARANTINED);
        AHandle := nil;
        Exit;
      end;
      if Slot.OwnerRefs > 1 then
      begin
        Dec(Slot.OwnerRefs);
        AHandle := nil;
        Exit;
      end;
      TInterlocked.Exchange(Slot.Closing, 1);
    finally
      GServiceLock.Leave;
    end;

    Drained := DrainCurrentPendingSignal(CrashThreadCaptureSignalNumber);
    GServiceLock.Enter;
    try
      if Drained then
        ResetSlot(Slot)
      else
        TInterlocked.Exchange(Slot.State, SLOT_QUARANTINED);
      AHandle := nil;
    finally
      GServiceLock.Leave;
    end;
  finally
    GCoordinatorLock.Leave;
  end;
end;

{$IF Defined(CRASH_THREADCAP_LINUXLIKE)}
type
  TCrashInstructionBytes = array [0..7] of Byte;
  PCrashInstructionBytes = ^TCrashInstructionBytes;

procedure RefreshExecutableRanges;
var
  NowTick: UInt64;
  Ranges: TCrashExecutableRanges;
begin
  NowTick := TThread.GetTickCount64;
  if (Length(GExecutableRanges) > 0) and
     (NowTick - GExecutableRangesTick < 1000) then
    Exit;
  Ranges := nil;
  try
    Ranges := CrashEnumerateReadableExecutableRanges;
  except
    Ranges := nil;
  end;
  GExecutableRanges := Ranges;
  GExecutableRangesTick := NowTick;
end;

function FindExecutableRange(const AAddress: UIntPtr;
  const ASize: NativeUInt): Integer;
var
  I: Integer;
begin
  Result := -1;
  if ASize = 0 then
    Exit;
  for I := 0 to High(GExecutableRanges) do
    if (AAddress >= GExecutableRanges[I].LowAddress) and
       (AAddress < GExecutableRanges[I].HighAddress) and
       (ASize <= GExecutableRanges[I].HighAddress - AAddress) then
      Exit(I);
end;

function X86FFCallEndsAt(const ABytes: Pointer;
  const ALength: Integer): Boolean;
var
  B: PCrashInstructionBytes;
  I, ModRM, ModBits, RMBits, SIB, DispBytes: Integer;
begin
  Result := False;
  if (ABytes = nil) or (ALength < 2) or (ALength > 8) then
    Exit;
  B := PCrashInstructionBytes(ABytes);
  I := 0;
  if (B^[I] >= $40) and (B^[I] <= $4F) then
    Inc(I);
  if (I >= ALength) or (B^[I] <> $FF) then
    Exit;
  Inc(I);
  if I >= ALength then
    Exit;
  ModRM := B^[I];
  Inc(I);
  if ((ModRM shr 3) and 7) <> 2 then
    Exit;
  ModBits := ModRM shr 6;
  RMBits := ModRM and 7;
  DispBytes := 0;
  if ModBits <> 3 then
  begin
    if RMBits = 4 then
    begin
      if I >= ALength then
        Exit;
      SIB := B^[I];
      Inc(I);
      if (ModBits = 0) and ((SIB and 7) = 5) then
        DispBytes := 4;
    end
    else if (ModBits = 0) and (RMBits = 5) then
      DispBytes := 4;
    if ModBits = 1 then
      DispBytes := 1
    else if ModBits = 2 then
      DispBytes := 4;
  end;
  Inc(I, DispBytes);
  Result := I = ALength;
end;

function X86CallSiteIsValid(const AReturnAddress: UIntPtr): Boolean;
var
  Bytes: TCrashInstructionBytes;
  RangeIndex, Available, Offset, InstructionLength: Integer;
  ReadAddress, TargetAddress, DistanceFromRangeLow: UIntPtr;
  RelativeTarget: Int32;
begin
  Result := False;
  RangeIndex := FindExecutableRange(AReturnAddress, 1);
  if RangeIndex < 0 then
    Exit;
  if AReturnAddress <= GExecutableRanges[RangeIndex].LowAddress then
    Exit;
  DistanceFromRangeLow := AReturnAddress -
    GExecutableRanges[RangeIndex].LowAddress;
  if DistanceFromRangeLow > SizeOf(Bytes) then
    Available := SizeOf(Bytes)
  else
    Available := Integer(DistanceFromRangeLow);
  if Available < 2 then
    Exit;
  ReadAddress := AReturnAddress - UIntPtr(Available);
  FillChar(Bytes, SizeOf(Bytes), 0);
  Offset := SizeOf(Bytes) - Available;
  if not CrashTryReadProcessMemory(ReadAddress, @Bytes[Offset], Available) then
    Exit;

  if (Available >= 5) and (Bytes[SizeOf(Bytes) - 5] = $E8) then
  begin
    Move(Bytes[SizeOf(Bytes) - 4], RelativeTarget, SizeOf(RelativeTarget));
    if RelativeTarget >= 0 then
    begin
      if UIntPtr(RelativeTarget) <= High(UIntPtr) - AReturnAddress then
      begin
        TargetAddress := AReturnAddress + UIntPtr(RelativeTarget);
        if FindExecutableRange(TargetAddress, 1) >= 0 then
          Exit(True);
      end;
    end;
    if RelativeTarget < 0 then
      if UIntPtr(-Int64(RelativeTarget)) <= AReturnAddress then
      begin
        TargetAddress := AReturnAddress - UIntPtr(-Int64(RelativeTarget));
        if FindExecutableRange(TargetAddress, 1) >= 0 then
          Exit(True);
      end;
  end;

  for InstructionLength := 2 to Available do
    if X86FFCallEndsAt(@Bytes[SizeOf(Bytes) - InstructionLength],
         InstructionLength) then
      Exit(True);
end;

function ARM64InstructionIsCall(const AInstruction: UInt32): Boolean;
const
  BL_MASK = $FC000000;
  BL_VALUE = $94000000;
  BLR_MASK = $FFFFFC1F;
  BLR_VALUE = $D63F0000;
begin
  Result := ((AInstruction and BL_MASK) = BL_VALUE) or
    ((AInstruction and BLR_MASK) = BLR_VALUE);
end;

function ARM64CallSiteIsValid(const AReturnAddress: UIntPtr): Boolean;
var
  InstructionAddress: UIntPtr;
  Instruction: UInt32;
begin
  Result := False;
  if (AReturnAddress < SizeOf(Instruction)) or
     ((AReturnAddress and 3) <> 0) or
     (FindExecutableRange(AReturnAddress, 1) < 0) then
    Exit;
  InstructionAddress := AReturnAddress - SizeOf(Instruction);
  if FindExecutableRange(InstructionAddress, SizeOf(Instruction)) < 0 then
    Exit;
  Instruction := 0;
  if not CrashTryReadProcessMemory(InstructionAddress, @Instruction,
       SizeOf(Instruction)) then
    Exit;
  Result := ARM64InstructionIsCall(Instruction);
end;

function CallSiteIsValid(const AReturnAddress: UIntPtr): Boolean;
begin
  {$IF Defined(CPUX64)}
  Result := X86CallSiteIsValid(AReturnAddress);
  {$ELSEIF Defined(CPUARM64)}
  Result := ARM64CallSiteIsValid(AReturnAddress);
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

function AddTraceCandidate(var ACandidates: TCrashTraceCandidates;
  const AStackPos, AAddress: UIntPtr; const AIsRaw: Boolean): Boolean;
var
  I, InsertAt: Integer;
begin
  Result := False;
  if (AStackPos = 0) or (AAddress = 0) then
    Exit;
  for I := 0 to High(ACandidates) do
    if ACandidates[I].StackPos = AStackPos then
    begin
      if ACandidates[I].IsRaw and (not AIsRaw) then
      begin
        ACandidates[I].Address := AAddress;
        ACandidates[I].IsRaw := False;
      end;
      Exit;
    end;
  InsertAt := Length(ACandidates);
  for I := 0 to High(ACandidates) do
    if AStackPos < ACandidates[I].StackPos then
    begin
      InsertAt := I;
      Break;
    end;
  SetLength(ACandidates, Length(ACandidates) + 1);
  for I := High(ACandidates) downto InsertAt + 1 do
    ACandidates[I] := ACandidates[I - 1];
  ACandidates[InsertAt].StackPos := AStackPos;
  ACandidates[InsertAt].Address := AAddress;
  ACandidates[InsertAt].IsRaw := AIsRaw;
  Result := True;
end;

procedure CompactTraceCandidates(var ACandidates: TCrashTraceCandidates);
var
  I, OutIndex: Integer;
begin
  OutIndex := 0;
  for I := 0 to High(ACandidates) do
  begin
    // The same saved return address may be found by both sources at adjacent
    // stack positions. Preserve real recursion within one source, but remove
    // a cross-source duplicate after the position-based merge.
    if (OutIndex > 0) and
       (ACandidates[I].Address = ACandidates[OutIndex - 1].Address) and
       (ACandidates[I].IsRaw <> ACandidates[OutIndex - 1].IsRaw) then
      Continue;
    ACandidates[OutIndex] := ACandidates[I];
    Inc(OutIndex);
  end;
  SetLength(ACandidates, OutIndex);
end;

procedure BuildBoundedTrace(const ASlot: PCrashThreadCaptureSlot;
  out ATrace: TCrashThreadRawTrace);
var
  Candidates: TCrashTraceCandidates;
  I, N, OutIndex: Integer;
  Address, StackPos, FirstFPPos, LastFPPos: UIntPtr;
begin
  ATrace := Default(TCrashThreadRawTrace);
  ATrace.InterruptedIP := UIntPtr(ASlot.InterruptedIP);
  ATrace.BoundsAvailable := ASlot.StackBoundsOK <> 0;
  ATrace.StopReason := ASlot.StopReason;
  Candidates := nil;
  RefreshExecutableRanges;

  FirstFPPos := 0;
  LastFPPos := 0;
  N := Min(ASlot.Count, CRASH_THREAD_CAPTURE_MAX_FRAMES);
  for I := 0 to N - 1 do
  begin
    Address := ASlot.Addrs[I];
    StackPos := ASlot.AddrStackPos[I];
    if not CallSiteIsValid(Address) then
    begin
      ATrace.StopReason := tcsrFrameInvalidCode;
      Break;
    end;
    if AddTraceCandidate(Candidates, StackPos, Address, False) then
    begin
      if FirstFPPos = 0 then
        FirstFPPos := StackPos;
      LastFPPos := StackPos;
    end;
  end;

  N := Min(ASlot.RawWordCount, CRASH_THREAD_CAPTURE_RAW_WORDS);
  for I := 0 to N - 1 do
  begin
    Address := ASlot.RawWords[I];
    if not CallSiteIsValid(Address) then
      Continue;
    StackPos := ASlot.RawBaseSP + UIntPtr(I) * SizeOf(Pointer);
    AddTraceCandidate(Candidates, StackPos, Address, True);
  end;

  CompactTraceCandidates(Candidates);
  SetLength(ATrace.Addresses, Length(Candidates) +
    Ord(ATrace.InterruptedIP <> 0));
  OutIndex := 0;
  if ATrace.InterruptedIP <> 0 then
  begin
    ATrace.Addresses[0] := ATrace.InterruptedIP;
    OutIndex := 1;
  end;
  for I := 0 to High(Candidates) do
  begin
    // Exact kernel IP is already the first frame. Avoid the common duplicate
    // where the first saved return address happens to contain the same value.
    if (OutIndex = 1) and (ATrace.InterruptedIP <> 0) and
       (Candidates[I].Address = ATrace.InterruptedIP) then
      Continue;
    ATrace.Addresses[OutIndex] := Candidates[I].Address;
    Inc(OutIndex);
    if Candidates[I].IsRaw then
    begin
      Inc(ATrace.RawFrameCount);
      if (FirstFPPos <> 0) and (Candidates[I].StackPos > FirstFPPos) and
         (Candidates[I].StackPos < LastFPPos) then
        Inc(ATrace.RawInnerFrameCount);
    end
    else
      Inc(ATrace.FPFrameCount);
  end;
  SetLength(ATrace.Addresses, OutIndex);
end;
{$ENDIF}

procedure BuildTrace(const ASlot: PCrashThreadCaptureSlot;
  out ATrace: TCrashThreadRawTrace);
{$IF Defined(CRASH_THREADCAP_LINUXLIKE)}
begin
  BuildBoundedTrace(ASlot, ATrace);
end;
{$ELSE}
var
  I, N, StartIndex: Integer;
begin
  ATrace := Default(TCrashThreadRawTrace);
  ATrace.InterruptedIP := UIntPtr(ASlot.InterruptedIP);
  N := Min(ASlot.Count, CRASH_THREAD_CAPTURE_MAX_FRAMES);
  StartIndex := -1;
  if ATrace.InterruptedIP <> 0 then
    for I := 0 to N - 1 do
      if ASlot.Addrs[I] = ATrace.InterruptedIP then
      begin
        StartIndex := I;
        Break;
      end;
  if StartIndex >= 0 then
  begin
    SetLength(ATrace.Addresses, N - StartIndex);
    for I := StartIndex to N - 1 do
      ATrace.Addresses[I - StartIndex] := ASlot.Addrs[I];
  end
  else if ATrace.InterruptedIP <> 0 then
  begin
    SetLength(ATrace.Addresses, N + 1);
    ATrace.Addresses[0] := ATrace.InterruptedIP;
    for I := 0 to N - 1 do
      ATrace.Addresses[I + 1] := ASlot.Addrs[I];
  end
  else
  begin
    SetLength(ATrace.Addresses, N);
    for I := 0 to N - 1 do
      ATrace.Addresses[I] := ASlot.Addrs[I];
  end;
end;
{$ENDIF}

function CrashThreadCaptureCapture(const AHandle: TCrashThreadCaptureHandle;
  const AWaitMS: Integer; out ATrace: TCrashThreadRawTrace):
  TCrashThreadCaptureOutcome;
var
  Slot: PCrashThreadCaptureSlot;
  Deadline: UInt64;
  State, SigNum, KillResult: Integer;
begin
  ATrace := Default(TCrashThreadRawTrace);
  Result := tcoUnavailable;
  GCoordinatorLock.Enter;
  try
    if not CrashThreadCaptureAvailable then
      Exit;
    Slot := SlotFromHandle(AHandle);
    if Slot = nil then
      Exit;
    State := SlotState(Slot);
    if State = SLOT_FREE then
      Exit;
    if TInterlocked.CompareExchange(Slot.Closing, 0, 0) <> 0 then
    begin
      if State = SLOT_QUARANTINED then
        Exit(tcoFailed);
      Exit(tcoThreadGone);
    end;

    if State = SLOT_CAPTURED then
    begin
      // A handler that was already Capturing at the preceding timeout has now
      // published a stale result. Discard it before arming a fresh request.
      TInterlocked.Exchange(Slot.State, SLOT_IDLE);
      State := SLOT_IDLE;
    end;
    if State <> SLOT_IDLE then
      Exit(tcoFailed);

    Slot.InterruptedIP := 0;
    Slot.InterruptedSP := 0;
    Slot.InterruptedFP := 0;
    Slot.Count := 0;
    Slot.RawBaseSP := 0;
    Slot.RawWordCount := 0;
    Slot.StopReason := tcsrNone;
    {$IFDEF AUTOTESTS}
    Slot.TestHandlerStackAddress := 0;
    {$ENDIF}
    TInterlocked.Exchange(Slot.State, SLOT_ARMED);
    SigNum := CrashThreadCaptureSignalNumber;
    if SigNum < 0 then
    begin
      TInterlocked.CompareExchange(Slot.State, SLOT_IDLE, SLOT_ARMED);
      Exit(tcoUnavailable);
    end;
    KillResult := pthread_kill(pthread_t(NativeUInt(Slot.PThreadIdent)), SigNum);
    if KillResult <> 0 then
    begin
      TInterlocked.CompareExchange(Slot.State, SLOT_IDLE, SLOT_ARMED);
      Exit(tcoThreadGone);
    end;

    Deadline := TThread.GetTickCount64 + UInt64(Max(0, AWaitMS));
    repeat
      State := SlotState(Slot);
      if State = SLOT_CAPTURED then
      begin
        try
          BuildTrace(Slot, ATrace);
          Result := tcoCaptured;
        finally
          TInterlocked.Exchange(Slot.State, SLOT_IDLE);
        end;
        Exit;
      end;
      if TThread.GetTickCount64 >= Deadline then
        Break;
      TThread.Sleep(CAPTURE_WAIT_QUANTUM_MS);
    until False;

    if TInterlocked.CompareExchange(Slot.State, SLOT_POISONED,
         SLOT_ARMED) = SLOT_ARMED then
      Exit(tcoTimedOut);
    if SlotState(Slot) = SLOT_CAPTURED then
    begin
      try
        BuildTrace(Slot, ATrace);
        Result := tcoCaptured;
      finally
        TInterlocked.Exchange(Slot.State, SLOT_IDLE);
      end;
      Exit;
    end;
    // Capturing means the handler claimed the request before the deadline but
    // has not returned. Leave it untouched; a later calm call discards the
    // eventual Captured result. Quarantined/other states are likewise fail-soft.
    Result := tcoTimedOut;
  finally
    GCoordinatorLock.Leave;
  end;
end;

{$IFDEF AUTOTESTS}
function CrashThreadCaptureCurrentSignalBlocked: Boolean;
var
  CurrentMask: sigset_t;
  SigNum: Integer;
begin
  Result := False;
  SigNum := CrashThreadCaptureSignalNumber;
  if SigNum < 0 then
    Exit;
  FillChar(CurrentMask, SizeOf(CurrentMask), 0);
  if crash_pthread_sigmask(SIG_BLOCK, nil, @CurrentMask) <> 0 then
    Exit;
  Result := sigismember(CurrentMask, SigNum) = 1;
end;

function CrashThreadCaptureTestIdentityMatches(
  const AHandle: TCrashThreadCaptureHandle;
  const APThread, AKernelThread: UInt64): Boolean;
var
  Slot: PCrashThreadCaptureSlot;
  Identity: TCrashThreadNativeIdentity;
begin
  Slot := SlotFromHandle(AHandle);
  Identity.PThread := APThread;
  Identity.KernelThread := AKernelThread;
  Result := (Slot <> nil) and (SlotState(Slot) <> SLOT_FREE) and
    SlotMatchesIdentity(Slot, Identity);
end;

function CrashThreadCaptureTestSetKernelIdentity(
  const AHandle: TCrashThreadCaptureHandle;
  const AKernelThread: UInt64): Boolean;
var
  Slot: PCrashThreadCaptureSlot;
begin
  Result := False;
  GCoordinatorLock.Enter;
  try
    GServiceLock.Enter;
    try
      Slot := SlotFromHandle(AHandle);
      if (Slot = nil) or (SlotState(Slot) = SLOT_FREE) then
        Exit;
      Slot.KernelIdent := AKernelThread;
      Result := True;
    finally
      GServiceLock.Leave;
    end;
  finally
    GCoordinatorLock.Leave;
  end;
end;

function CrashThreadCaptureTestQuarantine(
  const AHandle: TCrashThreadCaptureHandle): Boolean;
var
  Slot: PCrashThreadCaptureSlot;
begin
  Result := False;
  GCoordinatorLock.Enter;
  try
    GServiceLock.Enter;
    try
      Slot := SlotFromHandle(AHandle);
      if (Slot = nil) or (SlotState(Slot) = SLOT_FREE) then
        Exit;
      TInterlocked.Exchange(Slot.Closing, 1);
      TInterlocked.Exchange(Slot.State, SLOT_QUARANTINED);
      Result := True;
    finally
      GServiceLock.Leave;
    end;
  finally
    GCoordinatorLock.Leave;
  end;
end;

function CrashThreadCaptureTestLiveSlotCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  GServiceLock.Enter;
  try
    for I := 0 to High(GSlots) do
      if SlotState(@GSlots[I]) <> SLOT_FREE then
        Inc(Result);
  finally
    GServiceLock.Leave;
  end;
end;

function CrashThreadCaptureTestLiveSlotSummary: String;
var
  I: Integer;
begin
  Result := '';
  GServiceLock.Enter;
  try
    for I := 0 to High(GSlots) do
      if SlotState(@GSlots[I]) <> SLOT_FREE then
      begin
        if Result <> '' then
          Result := Result + '; ';
        Result := Result + Format('%d=state%d/ref%d/p%x/k%x',
          [I, SlotState(@GSlots[I]), GSlots[I].OwnerRefs,
           GSlots[I].PThreadIdent, GSlots[I].KernelIdent]);
      end;
  finally
    GServiceLock.Leave;
  end;
end;

function CrashThreadCaptureTestResetQuarantined(
  const AHandle: TCrashThreadCaptureHandle): Boolean;
var
  Slot: PCrashThreadCaptureSlot;
begin
  Result := False;
  GCoordinatorLock.Enter;
  try
    GServiceLock.Enter;
    try
      Slot := SlotFromHandle(AHandle);
      if Slot = nil then
        Exit;
      if SlotState(Slot) = SLOT_FREE then
        Exit(True);
      if (SlotState(Slot) <> SLOT_QUARANTINED) or
         (TInterlocked.CompareExchange(Slot.Closing, 0, 0) = 0) then
        Exit;
      ResetSlot(Slot);
      Result := True;
    finally
      GServiceLock.Leave;
    end;
  finally
    GCoordinatorLock.Leave;
  end;
end;

procedure CrashThreadCaptureTestResetAllQuarantined;
var
  I: Integer;
begin
  GCoordinatorLock.Enter;
  try
    GServiceLock.Enter;
    try
      for I := 0 to High(GSlots) do
        if SlotState(@GSlots[I]) = SLOT_QUARANTINED then
          ResetSlot(@GSlots[I]);
    finally
      GServiceLock.Leave;
    end;
  finally
    GCoordinatorLock.Leave;
  end;
end;

procedure CrashThreadCaptureTestBoundedWalk(const AStackLow, AStackHigh,
  AStackPointer, AFramePointer: UIntPtr; out AFPCount, ARawWordCount: Integer;
  out ARawBase, AFirstRawWord: UIntPtr;
  out AStopReason: TCrashThreadCaptureStopReason);
var
  Slot: TCrashThreadCaptureSlot;
begin
  FillChar(Slot, SizeOf(Slot), 0);
  Slot.StackLow := AStackLow;
  Slot.StackHigh := AStackHigh;
  Slot.StackBoundsOK := Ord((AStackLow <> 0) and (AStackHigh > AStackLow));
  CaptureBoundedStack(@Slot, AStackPointer, AFramePointer);
  AFPCount := Slot.Count;
  ARawWordCount := Slot.RawWordCount;
  ARawBase := Slot.RawBaseSP;
  if Slot.RawWordCount > 0 then
    AFirstRawWord := Slot.RawWords[0]
  else
    AFirstRawWord := 0;
  AStopReason := Slot.StopReason;
end;

function CrashThreadCaptureTestX86FFCall(const ABytes: TBytes): Boolean;
begin
  {$IF Defined(CRASH_THREADCAP_LINUXLIKE) and Defined(CPUX64)}
  Result := (Length(ABytes) > 0) and (Length(ABytes) <= 8) and
    X86FFCallEndsAt(@ABytes[0], Length(ABytes));
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

function CrashThreadCaptureTestARM64Call(const AInstruction: UInt32): Boolean;
begin
  {$IF Defined(CRASH_THREADCAP_LINUXLIKE)}
  Result := ARM64InstructionIsCall(AInstruction);
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

function CrashThreadCaptureTestMergeRules: Boolean;
{$IF Defined(CRASH_THREADCAP_LINUXLIKE)}
var
  Candidates: TCrashTraceCandidates;
begin
  Candidates := nil;
  Result := AddTraceCandidate(Candidates, 32, $2000, False) and
    (not AddTraceCandidate(Candidates, 32, $3000, True)) and
    AddTraceCandidate(Candidates, 16, $1000, True) and
    AddTraceCandidate(Candidates, 24, $2000, True) and
    AddTraceCandidate(Candidates, 48, $4000, False);
  if not Result then
    Exit;
  CompactTraceCandidates(Candidates);
  Result := (Length(Candidates) = 3) and
    (Candidates[0].StackPos = 16) and Candidates[0].IsRaw and
    (Candidates[1].StackPos = 24) and Candidates[1].IsRaw and
    (Candidates[2].StackPos = 48) and (not Candidates[2].IsRaw);
end;
{$ELSE}
begin
  Result := False;
end;
{$ENDIF}

function CrashThreadCaptureTestSetContextOverride(
  const AHandle: TCrashThreadCaptureHandle; const AStackLow, AStackHigh,
  AStackPointer, AFramePointer: UIntPtr): Boolean;
var
  Slot: PCrashThreadCaptureSlot;
begin
  Result := False;
  GCoordinatorLock.Enter;
  try
    GServiceLock.Enter;
    try
      Slot := SlotFromHandle(AHandle);
      if (Slot = nil) or (SlotState(Slot) <> SLOT_IDLE) then
        Exit;
      TInterlocked.Exchange(Slot.TestContextOverride, 0);
      Slot.StackLow := AStackLow;
      Slot.StackHigh := AStackHigh;
      Slot.StackBoundsOK := Ord((AStackLow <> 0) and
        (AStackHigh > AStackLow));
      Slot.TestStackPointer := AStackPointer;
      Slot.TestFramePointer := AFramePointer;
      TInterlocked.Exchange(Slot.TestContextOverride, 1);
      Result := True;
    finally
      GServiceLock.Leave;
    end;
  finally
    GCoordinatorLock.Leave;
  end;
end;

function CrashThreadCaptureTestHandlerStackAddress(
  const AHandle: TCrashThreadCaptureHandle): UIntPtr;
var
  Slot: PCrashThreadCaptureSlot;
begin
  Result := 0;
  GServiceLock.Enter;
  try
    Slot := SlotFromHandle(AHandle);
    if (Slot <> nil) and (SlotState(Slot) <> SLOT_FREE) then
      Result := Slot.TestHandlerStackAddress;
  finally
    GServiceLock.Leave;
  end;
end;

function CrashThreadCaptureTestActionUsesAltStack: Boolean;
var
  Action: sigaction_t;
  SignalNumber: Integer;
begin
  Result := False;
  SignalNumber := CrashThreadCaptureSignalNumber;
  if SignalNumber < 0 then
    Exit;
  FillChar(Action, SizeOf(Action), 0);
  if sigaction(SignalNumber, nil, @Action) <> 0 then
    Exit;
  {$IF Defined(CRASH_THREADCAP_LINUXLIKE)}
  Result := ActionIsOurs(Action) and
    ((Action.sa_flags and SA_ONSTACK) <> 0);
  {$ELSE}
  Result := ActionIsOurs(Action);
  {$ENDIF}
end;
{$ENDIF}

procedure ForceShutdown;
var
  Current: sigaction_t;
begin
  GCoordinatorLock.Enter;
  try
    GServiceLock.Enter;
    try
      if GHavePrevAction and (not HasLiveSlots) then
      begin
        GHavePrevAction := False;
        FillChar(Current, SizeOf(Current), 0);
        if (sigaction(GCaptureSignal, nil, @Current) = 0) and
           ActionIsOurs(Current) then
          sigaction(GCaptureSignal, @GPrevAction, nil);
      end;
      GAcquireCount := 0;
      GCaptureSignal := -1;
      TInterlocked.Exchange(GActive, 0);
      GRefreshProc := nil;
      GExecutableRanges := nil;
      GExecutableRangesTick := 0;
    finally
      GServiceLock.Leave;
    end;
  finally
    GCoordinatorLock.Leave;
  end;
end;

initialization
  GServiceLock := TCriticalSection.Create;
  GCoordinatorLock := TCriticalSection.Create;

finalization
  ForceShutdown;
  GCoordinatorLock.Free;
  GServiceLock.Free;

{$ELSE} // not CRASH_THREADCAP

function CrashThreadCaptureAcquire: Boolean; begin Result := False; end;
procedure CrashThreadCaptureRelease; begin end;
function CrashThreadCaptureAvailable: Boolean; begin Result := False; end;
function CrashThreadCaptureSignalNumber: Integer; begin Result := -1; end;
procedure CrashThreadCaptureSetSignalRefresh(
  const AProc: TCrashThreadCaptureSignalRefreshProc); begin end;
function CrashCurrentPThreadIdent: UInt64; begin Result := 0; end;
function CrashCurrentKernelThreadIdent: UInt64; begin Result := 0; end;
function CrashCurrentThreadNativeIdentity: TCrashThreadNativeIdentity;
begin
  Result := Default(TCrashThreadNativeIdentity);
end;
function CrashThreadCaptureContextInstructionPointer(AContext: Pointer): UInt64;
begin
  Result := 0;
end;
function CrashThreadCaptureRegisterCurrentThread(
  out AHandle: TCrashThreadCaptureHandle): Boolean;
begin
  AHandle := nil;
  Result := False;
end;
procedure CrashThreadCaptureUnregisterCurrentThread(
  var AHandle: TCrashThreadCaptureHandle);
begin
  AHandle := nil;
end;
function CrashThreadCaptureCapture(const AHandle: TCrashThreadCaptureHandle;
  const AWaitMS: Integer; out ATrace: TCrashThreadRawTrace):
  TCrashThreadCaptureOutcome;
begin
  ATrace := Default(TCrashThreadRawTrace);
  Result := tcoUnavailable;
end;
function CrashThreadCaptureStopReasonText(
  const AReason: TCrashThreadCaptureStopReason): String;
begin
  Result := 'none';
end;
function CrashThreadCaptureFormatDiagnostics(const AThreadID: UInt64;
  const ATrace: TCrashThreadRawTrace): String;
begin
  Result := '';
end;
{$IFDEF AUTOTESTS}
function CrashThreadCaptureCurrentSignalBlocked: Boolean;
begin
  Result := False;
end;
function CrashThreadCaptureTestIdentityMatches(
  const AHandle: TCrashThreadCaptureHandle;
  const APThread, AKernelThread: UInt64): Boolean;
begin
  Result := False;
end;
function CrashThreadCaptureTestSetKernelIdentity(
  const AHandle: TCrashThreadCaptureHandle;
  const AKernelThread: UInt64): Boolean;
begin
  Result := False;
end;
function CrashThreadCaptureTestQuarantine(
  const AHandle: TCrashThreadCaptureHandle): Boolean;
begin
  Result := False;
end;
function CrashThreadCaptureTestLiveSlotCount: Integer;
begin
  Result := 0;
end;
function CrashThreadCaptureTestLiveSlotSummary: String;
begin
  Result := '';
end;
function CrashThreadCaptureTestResetQuarantined(
  const AHandle: TCrashThreadCaptureHandle): Boolean;
begin
  Result := False;
end;
procedure CrashThreadCaptureTestResetAllQuarantined;
begin
end;
procedure CrashThreadCaptureTestBoundedWalk(const AStackLow, AStackHigh,
  AStackPointer, AFramePointer: UIntPtr; out AFPCount, ARawWordCount: Integer;
  out ARawBase, AFirstRawWord: UIntPtr;
  out AStopReason: TCrashThreadCaptureStopReason);
begin
  AFPCount := 0;
  ARawWordCount := 0;
  ARawBase := 0;
  AFirstRawWord := 0;
  AStopReason := tcsrBoundsNone;
end;
function CrashThreadCaptureTestX86FFCall(const ABytes: TBytes): Boolean;
begin
  Result := False;
end;
function CrashThreadCaptureTestARM64Call(const AInstruction: UInt32): Boolean;
begin
  Result := False;
end;
function CrashThreadCaptureTestMergeRules: Boolean;
begin
  Result := False;
end;
function CrashThreadCaptureTestSetContextOverride(
  const AHandle: TCrashThreadCaptureHandle; const AStackLow, AStackHigh,
  AStackPointer, AFramePointer: UIntPtr): Boolean;
begin
  Result := False;
end;
function CrashThreadCaptureTestHandlerStackAddress(
  const AHandle: TCrashThreadCaptureHandle): UIntPtr;
begin
  Result := 0;
end;
function CrashThreadCaptureTestActionUsesAltStack: Boolean;
begin
  Result := False;
end;
{$ENDIF}

{$ENDIF}

end.
