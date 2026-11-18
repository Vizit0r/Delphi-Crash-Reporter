unit Crash.ThreadRegistry;

{ Calm-path registry of application threads that asked for crash coverage
  (TCrashReporter.RegisterCurrentThread), and the extended-thread collector
  that samples them into a report: candidate selection by group (Own, Global,
  Foreign), per-thread and total time budgets, and capture leases that keep a
  registration alive while its stack is being taken.

  Copyright (c) 2026 Vizit0r. BSD 2-Clause license (see LICENSE.txt). }

interface

uses
  System.SyncObjs,
  System.Generics.Collections,
  Crash.CallStack,
  Crash.Signals,
  Crash.ThreadCapture;

type
  TCrashMachState = (
    cmsNotRequired,
    cmsUnavailable,
    cmsInstalled
  );

  { Actual calm-path coverage verdict for one registered thread. }
  TCrashThreadCoverage = record
    Registered: Boolean;
    ThreadID: UInt64;
    Name: String;
    GroupID: UInt64;
    ExtendedCaptureAvailable: Boolean;
    AltStack: TCrashAltStackState;
    MachHandler: TCrashMachState;
  end;

  TCrashThreadRegistry = class
  strict private
    type
      TRegistration = class
      public
        Coverage: TCrashThreadCoverage;
        NativeIdentity: TCrashThreadNativeIdentity;
        Sequence: UInt64;
        Closing: Boolean;
        UnregisterWaiting: Boolean;
        CaptureLeaseCount: Integer;
        CaptureHandle: TCrashThreadCaptureHandle;
      end;
  private
    FLock: TCriticalSection;
    FRegistrations: TObjectList<TRegistration>;
    FSequence: UInt64;
    FInstanceID: UInt64;
    {$IFDEF AUTOTESTS}
    FAutoTestMaxThreadMS: UInt64;
    {$ENDIF}
    function TryEnter(const ATimeoutMS: Integer): Boolean;
    function EnterForCapture(const ABounded: Boolean): Boolean;
    function FindLocked(const AThreadID, ASequence: UInt64): TRegistration;
    procedure SweepClosedLocked;
  public
    // AInstanceID tells this registry apart from a later one at the same address.
    constructor Create(const AInstanceID: UInt64);
    destructor Destroy; override;
    { Cover the calling thread: alt stack, macOS Mach observer and, when
      ACaptureOperational, a capture slot. Idempotent per thread. }
    function RegisterCurrentThread(const AName: String; const AGroupID: UInt64;
      const ACaptureOperational: Boolean): TCrashThreadCoverage;
    { Undo RegisterCurrentThread for the calling thread if it registered with
      ACurrent; always drops the thread's alt stack. }
    class procedure UnregisterCurrentThread(const ACurrent: TCrashThreadRegistry);
    function OwnsCurrentThread: Boolean;
    function ThreadName(const AThreadID: UInt64; const AFallback: String): String;
    procedure Snapshot(out AThreads: TArray<TCrashThreadCoverage>;
      out ACurrent: TCrashThreadCoverage);
    { Sample the registered threads other than APrimaryThreadID into
      AReport.ExtendedThreads; returns how many eligible threads the limit
      left out. ABounded caps every registry lock wait (freeze path). }
    function CaptureExtendedThreads(var AReport: TCrashReport;
      const APrimaryThreadID: UInt64; const ABounded: Boolean;
      const AConfiguredMax: Integer; const AOperational: Boolean): Integer;
    {$IFDEF AUTOTESTS}
    property AutoTestMaxThreadMS: UInt64 read FAutoTestMaxThreadMS
      write FAutoTestMaxThreadMS;
    {$ENDIF}
  end;

function CrashCurrentThreadIdentity: UInt64;
// <=0 -> the default 32; above the hard limit 128 -> 128.
function CrashEffectiveExtendedThreadsMax(const AConfigured: Integer): Integer;
// Report-safe thread name: no separators, bounded, never empty.
function CrashSanitizeThreadName(const AName: String): String;

implementation

uses
  System.SysUtils,
  System.Classes,
  Crash.ThreadCapture.Trace
  {$IF Defined(MACOS) and Defined(CPUX64)}
  , Crash.MacOS.MachExc
  {$ENDIF}
  {$IF Defined(MSWINDOWS)}
  , Winapi.Windows
  {$ELSE}
  , Posix.Pthread
  {$ENDIF};

const
  CRASH_EXTENDED_DEFAULT_THREADS = 32;
  CRASH_EXTENDED_HARD_MAX_THREADS = 128;
  CRASH_EXTENDED_THREAD_WAIT_MS = 100;
  CRASH_EXTENDED_TOTAL_BUDGET_MS = 1000;
  CRASH_EXTENDED_MIN_WAIT_MS = 2;
  CRASH_EXTENDED_LOCK_BUDGET_MS = 10;
  CRASH_EXTENDED_NAME_MAX_CHARS = 128;

type
  TCrashThreadCandidateTier = (tctOwn, tctGlobal, tctForeign);

  TCrashThreadCandidate = record
    ThreadID: UInt64;
    Name: String;
    GroupID: UInt64;
    Sequence: UInt64;
    Tier: TCrashThreadCandidateTier;
  end;

threadvar
  GCoverageRegistry: Pointer;
  GCoverageInstanceID: UInt64;
  GCoverageRegistration: Pointer;

function CrashCurrentThreadIdentity: UInt64;
begin
  {$IF Defined(MSWINDOWS)}
  Result := UInt64(GetCurrentThreadId);
  {$ELSE}
  Result := UInt64(NativeUInt(pthread_self));
  {$ENDIF}
end;

function CrashRegisterMachForCurrentThread: TCrashMachState;
begin
  {$IF Defined(MACOS) and Defined(CPUX64)}
  if CrashInstallMacOSMachHandlerForCurrentThread then
    Result := cmsInstalled
  else
    Result := cmsUnavailable;
  {$ELSE}
  Result := cmsNotRequired;
  {$ENDIF}
end;

function CrashEffectiveExtendedThreadsMax(const AConfigured: Integer): Integer;
begin
  if AConfigured <= 0 then
    Exit(CRASH_EXTENDED_DEFAULT_THREADS);
  if AConfigured > CRASH_EXTENDED_HARD_MAX_THREADS then
    Exit(CRASH_EXTENDED_HARD_MAX_THREADS);
  Result := AConfigured;
end;

function CrashSanitizeThreadName(const AName: String): String;
begin
  Result := StringReplace(AName, ';', '.', [rfReplaceAll]);
  Result := StringReplace(Result, #13, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #10, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #9, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, '|', ' ', [rfReplaceAll]);
  Result := StringReplace(Result, '=', ' ', [rfReplaceAll]);
  if Length(Result) > CRASH_EXTENDED_NAME_MAX_CHARS then
    SetLength(Result, CRASH_EXTENDED_NAME_MAX_CHARS);
  if Trim(Result) = '' then
    Result := 'Worker';
end;

{ TCrashThreadRegistry }

constructor TCrashThreadRegistry.Create(const AInstanceID: UInt64);
begin
  inherited Create;
  FInstanceID := AInstanceID;
  FLock := TCriticalSection.Create;
  FRegistrations := TObjectList<TRegistration>.Create(True);
end;

destructor TCrashThreadRegistry.Destroy;
begin
  FreeAndNil(FRegistrations);
  FreeAndNil(FLock);
  inherited;
end;

function TCrashThreadRegistry.TryEnter(const ATimeoutMS: Integer): Boolean;
var
  Deadline: UInt64;
begin
  Deadline := TThread.GetTickCount64 + UInt64(ATimeoutMS);
  repeat
    if FLock.TryEnter then
      Exit(True);
    if TThread.GetTickCount64 >= Deadline then
      Exit(False);
    TThread.Sleep(1);
  until False;
end;

function TCrashThreadRegistry.EnterForCapture(const ABounded: Boolean): Boolean;
begin
  if ABounded then
    Exit(TryEnter(CRASH_EXTENDED_LOCK_BUDGET_MS));
  FLock.Enter;
  Result := True;
end;

function TCrashThreadRegistry.FindLocked(const AThreadID,
  ASequence: UInt64): TRegistration;
var
  Registration: TRegistration;
begin
  for Registration in FRegistrations do
    if (Registration.Coverage.ThreadID = AThreadID) and
       (Registration.Sequence = ASequence) then
      Exit(Registration);
  Result := nil;
end;

procedure TCrashThreadRegistry.SweepClosedLocked;
var
  I: Integer;
begin
  for I := FRegistrations.Count - 1 downto 0 do
    if FRegistrations[I].Closing and
       (not FRegistrations[I].UnregisterWaiting) and
       (FRegistrations[I].CaptureLeaseCount = 0) then
      FRegistrations.Delete(I);
end;

function TCrashThreadRegistry.OwnsCurrentThread: Boolean;
begin
  Result := (GCoverageRegistry = Pointer(Self)) and
    (GCoverageInstanceID = FInstanceID);
end;

function TCrashThreadRegistry.RegisterCurrentThread(const AName: String;
  const AGroupID: UInt64; const ACaptureOperational: Boolean): TCrashThreadCoverage;
var
  Registration, Existing: TRegistration;
  NativeIdentity: TCrashThreadNativeIdentity;
  CaptureHandle: TCrashThreadCaptureHandle;
begin
  Result := Default(TCrashThreadCoverage);
  Result.ThreadID := CrashCurrentThreadIdentity;
  // Fast idempotent path. The TLS owner prevents an abandoned registration with
  // a recycled native identity being mistaken for this caller.
  if OwnsCurrentThread and (GCoverageRegistration <> nil) then
  begin
    FLock.Enter;
    try
      Existing := TRegistration(GCoverageRegistration);
      if (FRegistrations.IndexOf(Existing) >= 0) and
         (not Existing.Closing) then
        Exit(Existing.Coverage);
    finally
      FLock.Leave;
    end;
  end;

  Result.Registered := True;
  Result.Name := CrashSanitizeThreadName(AName);
  Result.GroupID := AGroupID;
  Result.AltStack := CrashRegisterAltStackForCurrentThread;
  Result.MachHandler := CrashRegisterMachForCurrentThread;
  NativeIdentity := CrashCurrentThreadNativeIdentity;
  CaptureHandle := nil;
  if ACaptureOperational then
    CrashThreadCaptureRegisterCurrentThread(CaptureHandle);
  Result.ExtendedCaptureAvailable := CaptureHandle <> nil;

  Registration := TRegistration.Create;
  Registration.Coverage := Result;
  Registration.NativeIdentity := NativeIdentity;
  Registration.CaptureHandle := CaptureHandle;
  FLock.Enter;
  try
    // A dead owner can leave a calm-path record behind. The capture service has
    // already resolved a pthread_t collision using the second kernel identity;
    // invalidate the registry record so a lease result cannot inherit its name.
    for Existing in FRegistrations do
      if (not Existing.Closing) and
         ((Existing.Coverage.ThreadID = Result.ThreadID) or
          ((NativeIdentity.PThread <> 0) and
           (Existing.NativeIdentity.PThread = NativeIdentity.PThread))) then
      begin
        Existing.Closing := True;
        Existing.CaptureHandle := nil;
      end;
    SweepClosedLocked;
    Inc(FSequence);
    Registration.Sequence := FSequence;
    FRegistrations.Add(Registration);
  finally
    FLock.Leave;
  end;
  GCoverageRegistry := Pointer(Self);
  GCoverageInstanceID := FInstanceID;
  GCoverageRegistration := Registration;
end;

class procedure TCrashThreadRegistry.UnregisterCurrentThread(
  const ACurrent: TCrashThreadRegistry);
var
  Registry: TCrashThreadRegistry;
  Registration: TRegistration;
  CaptureHandle: TCrashThreadCaptureHandle;
  Leases: Integer;
  Found: Boolean;
begin
  Registry := TCrashThreadRegistry(GCoverageRegistry);
  Registration := TRegistration(GCoverageRegistration);
  CaptureHandle := nil;
  Found := False;
  if (Registry <> nil) and (Registry = ACurrent) and
     (GCoverageInstanceID = Registry.FInstanceID) and
     (Registration <> nil) then
  begin
    Registry.FLock.Enter;
    try
      if Registry.FRegistrations.IndexOf(Registration) >= 0 then
      begin
        Found := True;
        Registration.Closing := True;
        Registration.UnregisterWaiting := True;
        CaptureHandle := Registration.CaptureHandle;
      end;
    finally
      Registry.FLock.Leave;
    end;

    if Found then
    begin
      // At most the currently running bounded capture holds a lease. Do not free
      // its owned record/slot until the coordinator has published its verdict.
      repeat
        Registry.FLock.Enter;
        try
          Leases := Registration.CaptureLeaseCount;
        finally
          Registry.FLock.Leave;
        end;
        if Leases = 0 then
          Break;
        TThread.Sleep(1);
      until False;

      if CaptureHandle <> nil then
        CrashThreadCaptureUnregisterCurrentThread(CaptureHandle);
      Registry.FLock.Enter;
      try
        Registry.FRegistrations.Remove(Registration);
      finally
        Registry.FLock.Leave;
      end;
    end;
  end;
  GCoverageRegistry := nil;
  GCoverageInstanceID := 0;
  GCoverageRegistration := nil;
  CrashUnregisterAltStackForCurrentThread;
end;

function TCrashThreadRegistry.ThreadName(const AThreadID: UInt64;
  const AFallback: String): String;
var
  I: Integer;
begin
  Result := AFallback;
  if not TryEnter(CRASH_EXTENDED_LOCK_BUDGET_MS) then
    Exit;
  try
    for I := FRegistrations.Count - 1 downto 0 do
      if (not FRegistrations[I].Closing) and
         (FRegistrations[I].Coverage.ThreadID = AThreadID) then
        Exit(FRegistrations[I].Coverage.Name);
  finally
    FLock.Leave;
  end;
end;

procedure TCrashThreadRegistry.Snapshot(out AThreads: TArray<TCrashThreadCoverage>;
  out ACurrent: TCrashThreadCoverage);
var
  Registration: TRegistration;
  Count, I: Integer;
begin
  AThreads := nil;
  ACurrent := Default(TCrashThreadCoverage);
  FLock.Enter;
  try
    Count := 0;
    for Registration in FRegistrations do
      if not Registration.Closing then
        Inc(Count);
    SetLength(AThreads, Count);
    I := 0;
    for Registration in FRegistrations do
      if not Registration.Closing then
      begin
        AThreads[I] := Registration.Coverage;
        Inc(I);
      end;
    if OwnsCurrentThread and (GCoverageRegistration <> nil) and
       (FRegistrations.IndexOf(TRegistration(GCoverageRegistration)) >= 0) then
      ACurrent := TRegistration(GCoverageRegistration).Coverage;
  finally
    FLock.Leave;
  end;
end;

function TCrashThreadRegistry.CaptureExtendedThreads(var AReport: TCrashReport;
  const APrimaryThreadID: UInt64; const ABounded: Boolean;
  const AConfiguredMax: Integer; const AOperational: Boolean): Integer;
var
  Candidates: array [0..CRASH_EXTENDED_HARD_MAX_THREADS - 1] of
    TCrashThreadCandidate;
  SeenForeignGroups: array [0..CRASH_EXTENDED_HARD_MAX_THREADS - 1] of
    UInt64;
  CandidateCount, EligibleCount, EffectiveLimit, OwnCount, GlobalCount,
    OwnQuota, GlobalQuota, RemainingSlots, SeenForeignCount, I, WaitMS,
    MaxDepth: Integer;
  Candidate: TCrashThreadCandidate;
  Registration, CurrentRegistration: TRegistration;
  Handle: TCrashThreadCaptureHandle;
  Trace: TCrashThreadRawTrace;
  Outcome: TCrashThreadCaptureOutcome;
  PrimaryGroupID: UInt64;
  Deadline, OwnDeadline, CaptureDeadline, NowTick, Remaining: UInt64;
  LeaseHeld, StillOwned, HasGlobalReserve: Boolean;
  {$IFDEF AUTOTESTS}
  CaptureStart, CaptureElapsed: UInt64;
  {$ENDIF}

  function IsEligible(const ARegistration: TRegistration): Boolean;
  begin
    Result := (not ARegistration.Closing) and
      (ARegistration.Coverage.ThreadID <> APrimaryThreadID);
  end;

  procedure AddCandidate(const ARegistration: TRegistration;
    const ATier: TCrashThreadCandidateTier);
  begin
    if CandidateCount >= EffectiveLimit then
      Exit;
    Candidates[CandidateCount].ThreadID :=
      ARegistration.Coverage.ThreadID;
    Candidates[CandidateCount].Name := ARegistration.Coverage.Name;
    Candidates[CandidateCount].GroupID := ARegistration.Coverage.GroupID;
    Candidates[CandidateCount].Sequence := ARegistration.Sequence;
    Candidates[CandidateCount].Tier := ATier;
    Inc(CandidateCount);
  end;

  function ForeignGroupSeen(const AGroupID: UInt64): Boolean;
  var
    K: Integer;
  begin
    for K := 0 to SeenForeignCount - 1 do
      if SeenForeignGroups[K] = AGroupID then
        Exit(True);
    Result := False;
  end;

  function CandidateAlreadySelected(const ASequence: UInt64): Boolean;
  var
    K: Integer;
  begin
    for K := 0 to CandidateCount - 1 do
      if Candidates[K].Sequence = ASequence then
        Exit(True);
    Result := False;
  end;
begin
  Result := 0;
  AReport.ExtendedThreads := nil;
  AReport.ExtendedThreadsOmitted := 0;
  AReport.PrimaryGroupID := 0;
  if not AOperational then
    Exit;

  CandidateCount := 0;
  EligibleCount := 0;
  OwnCount := 0;
  GlobalCount := 0;
  SeenForeignCount := 0;
  EffectiveLimit := CrashEffectiveExtendedThreadsMax(AConfiguredMax);
  if not EnterForCapture(ABounded) then
    Exit;
  try
    PrimaryGroupID := 0;
    for Registration in FRegistrations do
      if (not Registration.Closing) and
         (Registration.Coverage.ThreadID = APrimaryThreadID) then
      begin
        PrimaryGroupID := Registration.Coverage.GroupID;
        Break;
      end;
    AReport.PrimaryGroupID := PrimaryGroupID;

    for Registration in FRegistrations do
      if IsEligible(Registration) then
      begin
        Inc(EligibleCount);
        if PrimaryGroupID <> 0 then
        begin
          if Registration.Coverage.GroupID = PrimaryGroupID then
            Inc(OwnCount)
          else if Registration.Coverage.GroupID = 0 then
            Inc(GlobalCount);
        end;
      end;

    // GroupID=0 is the compatibility path: first N registrations, unchanged.
    if PrimaryGroupID = 0 then
    begin
      for Registration in FRegistrations do
        if IsEligible(Registration) then
          AddCandidate(Registration, tctGlobal);
    end
    else
    begin
      // Reserve candidate slots for one Own and up to two Global entries,
      // then fill Own, Global and finally the best-effort Foreign tail.
      RemainingSlots := EffectiveLimit;
      OwnQuota := 0;
      if (OwnCount > 0) and (RemainingSlots > 0) then
      begin
        OwnQuota := 1;
        Dec(RemainingSlots);
      end;
      GlobalQuota := GlobalCount;
      if GlobalQuota > 2 then
        GlobalQuota := 2;
      if GlobalQuota > RemainingSlots then
        GlobalQuota := RemainingSlots;
      Dec(RemainingSlots, GlobalQuota);
      I := OwnCount - OwnQuota;
      if I > RemainingSlots then
        I := RemainingSlots;
      Inc(OwnQuota, I);
      Dec(RemainingSlots, I);
      I := GlobalCount - GlobalQuota;
      if I > RemainingSlots then
        I := RemainingSlots;
      Inc(GlobalQuota, I);

      for Registration in FRegistrations do
        if IsEligible(Registration) and
           (Registration.Coverage.GroupID = PrimaryGroupID) and
           (CandidateCount < OwnQuota) then
          AddCandidate(Registration, tctOwn);

      I := 0;
      for Registration in FRegistrations do
        if IsEligible(Registration) and
           (Registration.Coverage.GroupID = 0) and
           (I < GlobalQuota) then
        begin
          AddCandidate(Registration, tctGlobal);
          Inc(I);
        end;

      // First Foreign pass: oldest representative of every distinct group.
      for Registration in FRegistrations do
      begin
        if CandidateCount >= EffectiveLimit then
          Break;
        if IsEligible(Registration) and
           (Registration.Coverage.GroupID <> 0) and
           (Registration.Coverage.GroupID <> PrimaryGroupID) and
           (not ForeignGroupSeen(Registration.Coverage.GroupID)) then
        begin
          SeenForeignGroups[SeenForeignCount] :=
            Registration.Coverage.GroupID;
          Inc(SeenForeignCount);
          AddCandidate(Registration, tctForeign);
        end;
      end;

      // Second Foreign pass: remaining entries in registration order.
      for Registration in FRegistrations do
      begin
        if CandidateCount >= EffectiveLimit then
          Break;
        if IsEligible(Registration) and
           (Registration.Coverage.GroupID <> 0) and
           (Registration.Coverage.GroupID <> PrimaryGroupID) and
           (not CandidateAlreadySelected(Registration.Sequence)) then
          AddCandidate(Registration, tctForeign);
      end;
    end;
  finally
    FLock.Leave;
  end;
  if EligibleCount > CandidateCount then
    Result := EligibleCount - CandidateCount;
  AReport.ExtendedThreadsOmitted := Result;
  if CandidateCount = 0 then
    Exit;

  SetLength(AReport.ExtendedThreads, CandidateCount);
  Deadline := TThread.GetTickCount64 + CRASH_EXTENDED_TOTAL_BUDGET_MS;
  HasGlobalReserve := False;
  if PrimaryGroupID <> 0 then
    for I := 0 to CandidateCount - 1 do
      if Candidates[I].Tier = tctGlobal then
      begin
        HasGlobalReserve := True;
        Break;
      end;
  OwnDeadline := Deadline;
  if HasGlobalReserve then
    OwnDeadline := Deadline - CRASH_EXTENDED_THREAD_WAIT_MS;
  for I := 0 to CandidateCount - 1 do
  begin
    Candidate := Candidates[I];
    AReport.ExtendedThreads[I].ThreadID := Candidate.ThreadID;
    AReport.ExtendedThreads[I].Name := Candidate.Name;
    AReport.ExtendedThreads[I].GroupID := Candidate.GroupID;
    AReport.ExtendedThreads[I].State := ctcsCaptureFailed;
    AReport.ExtendedThreads[I].CallStack := nil;
    AReport.ExtendedThreads[I].CaptureDiagnostics := '';
    Handle := nil;
    LeaseHeld := False;

    CaptureDeadline := Deadline;
    if HasGlobalReserve and (Candidate.Tier = tctOwn) then
      CaptureDeadline := OwnDeadline;
    NowTick := TThread.GetTickCount64;
    if NowTick >= CaptureDeadline then
    begin
      AReport.ExtendedThreads[I].State := ctcsBudgetExceeded;
      Continue;
    end;

    if not EnterForCapture(ABounded) then
      Continue;
    try
      Registration := FindLocked(Candidate.ThreadID, Candidate.Sequence);
      if (Registration = nil) or Registration.Closing then
        AReport.ExtendedThreads[I].State := ctcsThreadGone
      else if Registration.CaptureHandle = nil then
        AReport.ExtendedThreads[I].State := ctcsSignalUnavailable
      else
      begin
        Inc(Registration.CaptureLeaseCount);
        Handle := Registration.CaptureHandle;
        LeaseHeld := True;
      end;
    finally
      FLock.Leave;
    end;
    if not LeaseHeld then
      Continue;

    try
      NowTick := TThread.GetTickCount64;
      if NowTick >= CaptureDeadline then
      begin
        AReport.ExtendedThreads[I].State := ctcsBudgetExceeded;
        Continue;
      end;
      Remaining := CaptureDeadline - NowTick;
      if Remaining < CRASH_EXTENDED_MIN_WAIT_MS then
      begin
        AReport.ExtendedThreads[I].State := ctcsBudgetExceeded;
        Continue;
      end;
      WaitMS := CRASH_EXTENDED_THREAD_WAIT_MS;
      if Remaining < UInt64(WaitMS) then
        WaitMS := Integer(Remaining);
      {$IFDEF AUTOTESTS}
      CaptureStart := TThread.GetTickCount64;
      {$ENDIF}
      Outcome := CrashThreadCaptureCapture(Handle, WaitMS, Trace);
      {$IFDEF AUTOTESTS}
      CaptureElapsed := TThread.GetTickCount64 - CaptureStart;
      if CaptureElapsed > FAutoTestMaxThreadMS then
        FAutoTestMaxThreadMS := CaptureElapsed;
      {$ENDIF}
    finally
      // The lease protects only the raw request/result hand-off. Release it
      // before symbolization so unregister never waits on resolver work.
      FLock.Enter;
      try
        CurrentRegistration := FindLocked(Candidate.ThreadID,
          Candidate.Sequence);
        StillOwned := (CurrentRegistration <> nil) and
          (CurrentRegistration = Registration);
        if Registration.CaptureLeaseCount > 0 then
          Dec(Registration.CaptureLeaseCount);
        if not StillOwned then
        begin
          AReport.ExtendedThreads[I].State := ctcsThreadGone;
          AReport.ExtendedThreads[I].CallStack := nil;
          Trace := Default(TCrashThreadRawTrace);
        end;
        SweepClosedLocked;
      finally
        FLock.Leave;
      end;
    end;
    if not StillOwned then
      Continue;

    case Outcome of
      tcoCaptured:
        begin
          AReport.ExtendedThreads[I].CaptureDiagnostics :=
            CrashThreadCaptureFormatDiagnostics(Candidate.ThreadID, Trace);
          MaxDepth := TCrashCapture.MaxCallStackDepth;
          if MaxDepth < 0 then
            MaxDepth := 0;
          if Length(Trace.Addresses) > MaxDepth then
            SetLength(Trace.Addresses, MaxDepth);
          try
            AReport.ExtendedThreads[I].CallStack :=
              TCrashCapture.SymbolizeAddressList(Trace.Addresses);
            AReport.ExtendedThreads[I].State := ctcsCaptured;
          except
            AReport.ExtendedThreads[I].CallStack := nil;
            AReport.ExtendedThreads[I].State := ctcsCaptureFailed;
          end;
        end;
      tcoTimedOut:
        AReport.ExtendedThreads[I].State := ctcsTimedOut;
      tcoThreadGone:
        AReport.ExtendedThreads[I].State := ctcsThreadGone;
      tcoUnavailable:
        AReport.ExtendedThreads[I].State := ctcsSignalUnavailable;
    else
      AReport.ExtendedThreads[I].State := ctcsCaptureFailed;
    end;
  end;
end;

end.
