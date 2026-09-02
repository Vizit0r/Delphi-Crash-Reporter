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

  TCrashThreadRawTrace = record
    InterruptedIP: UIntPtr;
    Addresses: TArray<UIntPtr>;
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

{$IFDEF AUTOTESTS}
function CrashThreadCaptureCurrentSignalBlocked: Boolean;
function CrashThreadCaptureTestIdentityMatches(
  const AHandle: TCrashThreadCaptureHandle;
  const APThread, AKernelThread: UInt64): Boolean;
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
  PCrashThreadCaptureSlot = ^TCrashThreadCaptureSlot;
  TCrashThreadCaptureSlot = record
    State: Integer;       // atomic SLOT_* state; published after identity fields
    Closing: Integer;     // atomic: no new request may arm this slot
    OwnerRefs: Integer;   // calm path, protected by GServiceLock
    Generation: Integer;  // calm producer generation; not a late-signal token
    PThreadIdent: UInt64;
    KernelIdent: UInt64;
    InterruptedIP: UInt64;
    Count: Integer;
    Addrs: array [0..CRASH_THREAD_CAPTURE_MAX_FRAMES - 1] of UIntPtr;
  end;

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

{$IF Defined(CRASH_THREADCAP_LINUXLIKE)}
function __libc_current_sigrtmin: Integer; cdecl;
  external libc name _PU + '__libc_current_sigrtmin';
function __libc_current_sigrtmax: Integer; cdecl;
  external libc name _PU + '__libc_current_sigrtmax';
function crash_syscall(ANumber: IntPtr): IntPtr; cdecl; varargs;
  external libc name _PU + 'syscall';
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
{$ELSE}
type
  _PUnwind_Context = Pointer;
  _Unwind_Ptr = UIntPtr;
  _Unwind_Reason_code = Integer;
  _Unwind_Trace_Fn = function(AContext: _PUnwind_Context;
    AUserData: Pointer): _Unwind_Reason_code; cdecl;

const
  _URC_NO_REASON = 0;
  _URC_END_OF_STACK = 5;
  {$IF Defined(LINUX)}
  LIB_UNWIND = 'libgcc_s.so.1';
  {$ELSE}
  LIB_UNWIND = 'libunwind.a';
  {$ENDIF}

procedure _Unwind_Backtrace(AFn: _Unwind_Trace_Fn;
  AUserData: Pointer); cdecl;
  external LIB_UNWIND name '_Unwind_Backtrace';
function _Unwind_GetIP(AContext: _PUnwind_Context): _Unwind_Ptr; cdecl;
  external LIB_UNWIND name '_Unwind_GetIP';
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
  ASlot.Generation := 0;
  ASlot.PThreadIdent := 0;
  ASlot.KernelIdent := 0;
  ASlot.InterruptedIP := 0;
  ASlot.Count := 0;
end;

{$IF not Defined(MACOS)}
function CaptureUnwindCallback(AContext: _PUnwind_Context;
  AUserData: Pointer): _Unwind_Reason_code; cdecl;
var
  Slot: PCrashThreadCaptureSlot;
begin
  Slot := PCrashThreadCaptureSlot(AUserData);
  if Slot.Count >= CRASH_THREAD_CAPTURE_MAX_FRAMES then
    Exit(_URC_END_OF_STACK);
  Slot.Addrs[Slot.Count] := UIntPtr(_Unwind_GetIP(AContext));
  Inc(Slot.Count);
  Result := _URC_NO_REASON;
end;
{$ENDIF}

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
    {$IF Defined(MACOS)}
    Slot.Count := backtrace(PPointer(@Slot.Addrs[0]),
      CRASH_THREAD_CAPTURE_MAX_FRAMES);
    if Slot.Count < 0 then
      Slot.Count := 0;
    {$ELSE}
    Slot.Count := 0;
    _Unwind_Backtrace(CaptureUnwindCallback, Slot);
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

      Sig := ChooseCaptureSignal;
      if Sig < 0 then
        Exit;
      FillChar(Action, SizeOf(Action), 0);
      SetHandlerInAction(Action);
      Action.sa_flags := SA_SIGINFO or SA_RESTART;
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

      if GHavePrevAction then
      begin
        GHavePrevAction := False;
        FillChar(Current, SizeOf(Current), 0);
        if (sigaction(GCaptureSignal, nil, @Current) = 0) and
           ActionIsOurs(Current) then
          sigaction(GCaptureSignal, @GPrevAction, nil);
      end;
      TInterlocked.Exchange(GActive, 0);
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
  Collision, Slot: PCrashThreadCaptureSlot;
  I: Integer;
  Drained: Boolean;
begin
  Result := False;
  AHandle := nil;
  if not CrashThreadCaptureAvailable then
    Exit;
  Identity := CrashCurrentThreadNativeIdentity;
  if (Identity.PThread = 0) or (Identity.KernelThread = 0) then
    Exit;

  GCoordinatorLock.Enter;
  try
    Collision := nil;
    GServiceLock.Enter;
    try
      for I := 0 to High(GSlots) do
        if (SlotState(@GSlots[I]) <> SLOT_FREE) and
           (GSlots[I].PThreadIdent = Identity.PThread) then
        begin
          if GSlots[I].KernelIdent = Identity.KernelThread then
          begin
            Inc(GSlots[I].OwnerRefs);
            AHandle := @GSlots[I];
            Exit(True);
          end;
          Collision := @GSlots[I];
          TInterlocked.Exchange(Collision.Closing, 1);
          TInterlocked.Exchange(Collision.State, SLOT_QUARANTINED);
          Break;
        end;
    finally
      GServiceLock.Leave;
    end;

    if Collision <> nil then
    begin
      Drained := DrainCurrentPendingSignal(CrashThreadCaptureSignalNumber);
      GServiceLock.Enter;
      try
        if Drained then
          ResetSlot(Collision);
      finally
        GServiceLock.Leave;
      end;
    end;

    GServiceLock.Enter;
    try
      if not CrashThreadCaptureAvailable then
        Exit;
      Slot := nil;
      for I := 0 to High(GSlots) do
        if SlotState(@GSlots[I]) = SLOT_FREE then
        begin
          Slot := @GSlots[I];
          Break;
        end;
      if Slot = nil then
        Exit;
      Slot.Closing := 0;
      Slot.OwnerRefs := 1;
      Slot.Generation := 0;
      Slot.PThreadIdent := Identity.PThread;
      Slot.KernelIdent := Identity.KernelThread;
      Slot.InterruptedIP := 0;
      Slot.Count := 0;
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

procedure BuildTrace(const ASlot: PCrashThreadCaptureSlot;
  out ATrace: TCrashThreadRawTrace);
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

    Inc(Slot.Generation);
    Slot.InterruptedIP := 0;
    Slot.Count := 0;
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
{$ENDIF}

procedure ForceShutdown;
var
  Current: sigaction_t;
begin
  GCoordinatorLock.Enter;
  try
    GServiceLock.Enter;
    try
      if GHavePrevAction then
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
{$ENDIF}

{$ENDIF}

end.
