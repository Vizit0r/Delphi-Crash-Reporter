unit Crash.Tests.ExtendedThreads;

// Copyright (c) 2026 Vizit0r. BSD 2-Clause license (see LICENSE.txt).

interface

{$IFDEF AUTOTESTS}

uses
  System.SysUtils,
  Crash.Tests.Registry;

type
  TCrashExtendedThreads_AllInOne = class
  public
    class function AutoTest(out OutLines: TArray<string>): Boolean; static;
  end;

{$ENDIF}

implementation

{$IFDEF AUTOTESTS}

{$IF (Defined(LINUX) and Defined(CPUX64)) or
     (Defined(MACOS) and not Defined(IOS) and
       (Defined(CPUX64) or Defined(CPUARM64)))}
  {$DEFINE CRASH_EXTENDED_RUNTIME_TEST}
{$ENDIF}

uses
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  Crash.CallStack,
  Crash.Freeze,
  Crash.Modules,
  Crash.Reporter,
  Crash.Signals,
  Crash.ThreadCapture,
  Crash.Tests.Progress
  {$IF Defined(CRASH_EXTENDED_RUNTIME_TEST)}
  , Posix.Base,
  Posix.Signal,
  Posix.SysMman,
  Posix.Unistd
  {$ENDIF};

const
  TEST_NAME = 'CrashExtendedThreads';

{$IF Defined(CRASH_EXTENDED_RUNTIME_TEST)}

const
  RESPONSIVE_WORKER_COUNT = 34;
  BLOCKED_WORKER_COUNT = 12;
  CAPTURE_LIMIT = 32;
  HARD_CAPTURE_LIMIT = 128; // ExtendedThreadsMax clamp
  WORKER_READY_TIMEOUT_MS = 5000;
  {$IF Defined(MACOS)}
  TEST_MAP_ANONYMOUS = $1000;
  {$ELSE}
  TEST_MAP_ANONYMOUS = $20;
  {$ENDIF}

function TestPThreadSigMask(AHow: Integer; ASet, AOldSet: Psigset_t): Integer;
  cdecl; external libc name _PU + 'pthread_sigmask';

type
  PTestUIntPtr = ^UIntPtr;
  TTestThreadProcedure = procedure of object;
  TTestThreadBooleanFunction = function: Boolean of object;

  TExtendedCaptureWorker = class(TThread)
  private
    FName: String;
    FGroupID: UInt64;
    FBlockCaptureSignal: Boolean;
    FReady: Integer;
    FRelease: Integer;
  public
    Coverage: TCrashThreadCoverage;
    ErrorText: String;
    constructor Create(const AName: String;
      const ABlockCaptureSignal: Boolean; const AGroupID: UInt64 = 0);
    function Ready: Boolean;
    procedure ReleaseThread;
    property WorkerName: String read FName;
  protected
    procedure Execute; override;
  end;

  TGuardCaptureWorker = class(TThread)
  private
    FReady: Integer;
    FRelease: Integer;
    FHandle: TCrashThreadCaptureHandle;
    FAltLow: UIntPtr;
    FAltHigh: UIntPtr;
  public
    ErrorText: String;
    constructor Create;
    function Ready: Boolean;
    procedure ReleaseThread;
    property CaptureHandle: TCrashThreadCaptureHandle read FHandle;
    property AltLow: UIntPtr read FAltLow;
    property AltHigh: UIntPtr read FAltHigh;
  protected
    procedure Execute; override;
  end;

constructor TExtendedCaptureWorker.Create(const AName: String;
  const ABlockCaptureSignal: Boolean; const AGroupID: UInt64);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FName := AName;
  FGroupID := AGroupID;
  FBlockCaptureSignal := ABlockCaptureSignal;
  Start;
end;

procedure TExtendedCaptureWorker.Execute;
var
  CaptureMask, OldMask: TCrashSigSet;
  MaskChanged, Registered: Boolean;
  CaptureSignal: Integer;
begin
  MaskChanged := False;
  Registered := False;
  try
    try
      if FBlockCaptureSignal then
      begin
        CaptureSignal := CrashThreadCaptureSignalNumber;
        if CaptureSignal <= 0 then
          raise Exception.Create('capture signal is unavailable');
        CrashSigSetClear(CaptureMask);
        CrashSigSetAdd(CaptureMask, CaptureSignal);
        if TestPThreadSigMask(SIG_BLOCK, @CaptureMask, @OldMask) <> 0 then
          raise Exception.Create('pthread_sigmask(SIG_BLOCK) failed');
        MaskChanged := True;
      end;

      Coverage := TCrashReporter.RegisterCurrentThread(FName, FGroupID);
      Registered := Coverage.Registered;
      TInterlocked.Exchange(FReady, 1);
      while TInterlocked.CompareExchange(FRelease, 0, 0) = 0 do
        TThread.Sleep(1);
    except
      on E: Exception do
        ErrorText := E.ClassName + ': ' + E.Message;
    end;
  finally
    TInterlocked.Exchange(FReady, 1);
    // Deliver a pending late capture while the slot is still owned. Its handler
    // consumes Poisoned -> Idle; unregister can then drain and free the slot.
    if MaskChanged then
      TestPThreadSigMask(SIG_SETMASK, @OldMask, nil);
    if Registered then
      TCrashReporter.UnregisterCurrentThread;
  end;
end;

function TExtendedCaptureWorker.Ready: Boolean;
begin
  Result := TInterlocked.CompareExchange(FReady, 0, 0) <> 0;
end;

procedure TExtendedCaptureWorker.ReleaseThread;
begin
  TInterlocked.Exchange(FRelease, 1);
end;

constructor TGuardCaptureWorker.Create;
begin
  inherited Create(True);
  FreeOnTerminate := False;
  Start;
end;

procedure TGuardCaptureWorker.Execute;
var
  AltStack: stack_t;
  Registered: Boolean;
begin
  Registered := False;
  try
    try
      CrashRegisterAltStackForCurrentThread;
      FillChar(AltStack, SizeOf(AltStack), 0);
      if sigaltstack(nil, @AltStack) <> 0 then
        raise Exception.Create('sigaltstack query failed');
      FAltLow := UIntPtr(AltStack.ss_sp);
      if UIntPtr(AltStack.ss_size) > High(UIntPtr) - FAltLow then
        raise Exception.Create('alt-stack bounds overflow');
      FAltHigh := FAltLow + UIntPtr(AltStack.ss_size);
      if (FAltLow = 0) or (FAltHigh <= FAltLow) then
        raise Exception.Create('alt stack is unavailable');

      Registered := CrashThreadCaptureRegisterCurrentThread(FHandle);
      if not Registered then
        raise Exception.Create('low-level thread registration failed');
      TInterlocked.Exchange(FReady, 1);
      while TInterlocked.CompareExchange(FRelease, 0, 0) = 0 do
        TThread.Sleep(1);
    except
      on E: Exception do
        ErrorText := E.ClassName + ': ' + E.Message;
    end;
  finally
    TInterlocked.Exchange(FReady, 1);
    if Registered then
      CrashThreadCaptureUnregisterCurrentThread(FHandle);
    CrashUnregisterAltStackForCurrentThread;
  end;
end;

function TGuardCaptureWorker.Ready: Boolean;
begin
  Result := TInterlocked.CompareExchange(FReady, 0, 0) <> 0;
end;

procedure TGuardCaptureWorker.ReleaseThread;
begin
  TInterlocked.Exchange(FRelease, 1);
end;

function WorkerName(const APrefix: String; const AIndex: Integer): String;
begin
  Result := APrefix + Format('%2.2d', [AIndex]);
end;

procedure AddReadyWorker(
  const AWorkers: TObjectList<TExtendedCaptureWorker>;
  const AName: String; const ABlockCaptureSignal: Boolean;
  const AGroupID: UInt64);
var
  Worker: TExtendedCaptureWorker;
  Deadline: UInt64;
begin
  Worker := TExtendedCaptureWorker.Create(AName, ABlockCaptureSignal,
    AGroupID);
  AWorkers.Add(Worker);
  Deadline := TThread.GetTickCount64 + WORKER_READY_TIMEOUT_MS;
  while (not Worker.Ready) and (TThread.GetTickCount64 < Deadline) do
    TThread.Sleep(1);
  if not Worker.Ready then
    raise Exception.CreateFmt('%s did not become ready in %d ms',
      [AName, WORKER_READY_TIMEOUT_MS]);
  if Worker.ErrorText <> '' then
    raise Exception.Create(Worker.ErrorText);
end;

function StartWorkers(const APrefix: String; const ACount: Integer;
  const ABlockCaptureSignal: Boolean): TObjectList<TExtendedCaptureWorker>;
var
  I: Integer;
begin
  Result := TObjectList<TExtendedCaptureWorker>.Create(True);
  try
    for I := 0 to ACount - 1 do
    begin
      AddReadyWorker(Result, WorkerName(APrefix, I), ABlockCaptureSignal, 0);
    end;
  except
    for I := 0 to Result.Count - 1 do
      Result[I].ReleaseThread;
    for I := 0 to Result.Count - 1 do
      Result[I].WaitFor;
    Result.Free;
    raise;
  end;
end;

function WaitWorkersReady(const AWorkers: TObjectList<TExtendedCaptureWorker>;
  const ATimeoutMS: Cardinal): Boolean;
var
  Deadline: UInt64;
  I: Integer;
begin
  Deadline := TThread.GetTickCount64 + ATimeoutMS;
  repeat
    Result := True;
    for I := 0 to AWorkers.Count - 1 do
      if not AWorkers[I].Ready then
      begin
        Result := False;
        Break;
      end;
    if Result or (TThread.GetTickCount64 >= Deadline) then
      Exit;
    TThread.Sleep(1);
  until False;
end;

function StopWorkers(const AWorkers: TObjectList<TExtendedCaptureWorker>): String;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to AWorkers.Count - 1 do
    AWorkers[I].ReleaseThread;
  for I := 0 to AWorkers.Count - 1 do
  begin
    AWorkers[I].WaitFor;
    if AWorkers[I].ErrorText <> '' then
    begin
      if Result <> '' then
        Result := Result + '; ';
      Result := Result + AWorkers[I].WorkerName + ': ' +
        AWorkers[I].ErrorText;
    end;
  end;
end;

function ExtendedIndex(const AThreads: TArray<TCrashThreadStack>;
  const AName: String): Integer;
var
  I: Integer;
begin
  for I := 0 to High(AThreads) do
    if AThreads[I].Name = AName then
      Exit(I);
  Result := -1;
end;

function ExtendedIndexByThreadID(const AThreads: TArray<TCrashThreadStack>;
  const AThreadID: UInt64): Integer;
var
  I: Integer;
begin
  for I := 0 to High(AThreads) do
    if AThreads[I].ThreadID = AThreadID then
      Exit(I);
  Result := -1;
end;

function CountPrefix(const AThreads: TArray<TCrashThreadStack>;
  const APrefix: String): Integer;
var
  Thread: TCrashThreadStack;
begin
  Result := 0;
  for Thread in AThreads do
    if Copy(Thread.Name, 1, Length(APrefix)) = APrefix then
      Inc(Result);
end;

function BaselineEligibleCount(const AStatus: TCrashStatus;
  const APrimaryThreadID: UInt64): Integer;
var
  Coverage: TCrashThreadCoverage;
begin
  Result := 0;
  for Coverage in AStatus.Threads do
    if Coverage.ThreadID <> APrimaryThreadID then
      Inc(Result);
end;

function NonWorkerEligibleCount(const AStatus: TCrashStatus;
  const APrimaryThreadID: UInt64; const AWorkerPrefix: String): Integer;
var
  Coverage: TCrashThreadCoverage;
begin
  Result := 0;
  for Coverage in AStatus.Threads do
    if (Coverage.ThreadID <> APrimaryThreadID) and
       (not Coverage.Name.StartsWith(AWorkerPrefix)) then
      Inc(Result);
end;

function WorkersInFirstEligible(const AStatus: TCrashStatus;
  const APrimaryThreadID: UInt64; const AWorkerPrefix: String;
  const ALimit: Integer): Integer;
// Selection follows registration order, and host threads that register while
// the round runs land after workers registered before them.
var
  Coverage: TCrashThreadCoverage;
  Taken: Integer;
begin
  Result := 0;
  Taken := 0;
  for Coverage in AStatus.Threads do
  begin
    if Taken >= ALimit then
      Break;
    if Coverage.ThreadID = APrimaryThreadID then
      Continue;
    Inc(Taken);
    if Coverage.Name.StartsWith(AWorkerPrefix) then
      Inc(Result);
  end;
end;

function EligibleGroupCount(const AStatus: TCrashStatus;
  const APrimaryThreadID, AGroupID: UInt64): Integer;
var
  Coverage: TCrashThreadCoverage;
begin
  Result := 0;
  for Coverage in AStatus.Threads do
    if (Coverage.ThreadID <> APrimaryThreadID) and
       (Coverage.GroupID = AGroupID) then
      Inc(Result);
end;

function EligibleDistinctForeignGroupCount(const AStatus: TCrashStatus;
  const APrimaryThreadID, APrimaryGroupID: UInt64): Integer;
var
  I, J: Integer;
  Seen: Boolean;
begin
  Result := 0;
  for I := 0 to High(AStatus.Threads) do
    if (AStatus.Threads[I].ThreadID <> APrimaryThreadID) and
       (AStatus.Threads[I].GroupID <> 0) and
       (AStatus.Threads[I].GroupID <> APrimaryGroupID) then
    begin
      Seen := False;
      for J := 0 to I - 1 do
        if (AStatus.Threads[J].ThreadID <> APrimaryThreadID) and
           (AStatus.Threads[J].GroupID = AStatus.Threads[I].GroupID) then
        begin
          Seen := True;
          Break;
        end;
      if not Seen then
        Inc(Result);
    end;
end;

function CapturedForeignGroupsAreUnique(
  const AThreads: TArray<TCrashThreadStack>;
  const APrimaryGroupID: UInt64): Boolean;
var
  I, J: Integer;
begin
  Result := True;
  for I := 0 to High(AThreads) do
    if (AThreads[I].GroupID <> 0) and
       (AThreads[I].GroupID <> APrimaryGroupID) then
      for J := 0 to I - 1 do
        if AThreads[J].GroupID = AThreads[I].GroupID then
          Exit(False);
end;

function StackContainsCodeRange(const AStack: TCrashStack;
  const ALowAddress, AHighAddress: UIntPtr): Boolean;
var
  Entry: TCrashStackEntry;
begin
  Result := False;
  for Entry in AStack do
    if (Entry.CodeAddress >= ALowAddress) and
       (Entry.CodeAddress < AHighAddress) then
      Exit(True);
end;

function WorkerExecuteCodeRange(const AWorker: TExtendedCaptureWorker;
  out ALowAddress, AHighAddress: UIntPtr): Boolean;
var
  ExecuteMethod: TTestThreadProcedure;
  ReadyMethod: TTestThreadBooleanFunction;
begin
  ExecuteMethod := AWorker.Execute;
  ReadyMethod := AWorker.Ready;
  ALowAddress := UIntPtr(TMethod(ExecuteMethod).Code);
  AHighAddress := UIntPtr(TMethod(ReadyMethod).Code);
  // Methods are emitted in implementation order (Create, Execute, Ready), so
  // [Execute, Ready) is exactly the Execute body; the guard below turns any
  // reordering into a loud failure instead of a match on foreign code.
  Result := (ALowAddress <> 0) and (AHighAddress > ALowAddress) and
    (AHighAddress - ALowAddress < 65536);
end;

function Step_H1_BoundedGuardAndRawWindow: Boolean;
var
  Region: Pointer;
  PageSize: LongInt;
  LowAddress, HighAddress, SP, FP, RawBase, FirstRaw: UIntPtr;
  FPCount, RawCount: Integer;
  StopReason: TCrashThreadCaptureStopReason;
begin
  Result := False;
  PageSize := sysconf(_SC_PAGESIZE);
  if PageSize <= 0 then
    Exit;
  Region := mmap(nil, NativeUInt(PageSize) * 3, PROT_NONE,
    MAP_PRIVATE or TEST_MAP_ANONYMOUS, -1, 0);
  if Region = MAP_FAILED then
    Exit;
  try
    LowAddress := UIntPtr(Region) + UIntPtr(PageSize);
    HighAddress := LowAddress + UIntPtr(PageSize);
    if mprotect(Pointer(LowAddress), PageSize, PROT_READ or PROT_WRITE) <> 0 then
      Exit;

    SP := HighAddress - 25; // deliberately unaligned; raw base must round up
    FP := HighAddress - 2 * SizeOf(Pointer);
    PTestUIntPtr(HighAddress - 3 * SizeOf(Pointer))^ := UIntPtr($11223344);
    PTestUIntPtr(FP)^ := 0;
    PTestUIntPtr(FP + SizeOf(Pointer))^ := UIntPtr($55667788);
    CrashThreadCaptureTestBoundedWalk(LowAddress, HighAddress, SP, FP,
      FPCount, RawCount, RawBase, FirstRaw, StopReason);
    Result := (FPCount = 1) and (RawCount = 3) and
      (RawBase = HighAddress - 3 * SizeOf(Pointer)) and
      (FirstRaw = UIntPtr($11223344)) and (StopReason = tcsrEnd);
    if not Result then
      Exit;

    // A range smaller than one frame record must fail before High-2*Ptr can
    // underflow or any guard-page read can occur.
    CrashThreadCaptureTestBoundedWalk(LowAddress,
      LowAddress + SizeOf(Pointer), LowAddress, 0,
      FPCount, RawCount, RawBase, FirstRaw, StopReason);
    Result := (FPCount = 0) and (RawCount = 0) and
      (StopReason = tcsrBoundsNone);
  finally
    munmap(Region, NativeUInt(PageSize) * 3);
  end;
end;

function Step_H2_RBPAsGPRIsBounded: Boolean;
var
  StackWords: array [0..159] of UIntPtr;
  LowAddress, HighAddress, SP, FP, RawBase, FirstRaw: UIntPtr;
  FPCount, RawCount: Integer;
  StopReason: TCrashThreadCaptureStopReason;
begin
  FillChar(StackWords, SizeOf(StackWords), 0);
  LowAddress := UIntPtr(@StackWords[0]);
  HighAddress := LowAddress + SizeOf(StackWords);
  SP := UIntPtr(@StackWords[4]);
  FP := UIntPtr(@StackWords[8]);
  StackWords[8] := UIntPtr(@StackWords[10]);
  StackWords[9] := UIntPtr($DEADBEEF);
  StackWords[10] := FP; // second record points backwards: stop after two reads
  StackWords[11] := UIntPtr($CAFEBABE);
  CrashThreadCaptureTestBoundedWalk(LowAddress, HighAddress, SP, FP,
    FPCount, RawCount, RawBase, FirstRaw, StopReason);
  Result := (FPCount = 2) and
    (RawCount = CRASH_THREAD_CAPTURE_RAW_WORDS) and
    (StopReason = tcsrFramePointerNonMonotonic);
end;

function Step_H2a_WalkerBoundaryMatrix: Boolean;
var
  StackWords: array [0..159] of UIntPtr;
  LowAddress, HighAddress, SP, FP, RawBase, FirstRaw: UIntPtr;
  FPCount, RawCount, I: Integer;
  StopReason: TCrashThreadCaptureStopReason;
begin
  Result := False;
  FillChar(StackWords, SizeOf(StackWords), 0);
  LowAddress := UIntPtr(@StackWords[0]);
  HighAddress := LowAddress + SizeOf(StackWords);
  SP := LowAddress;

  // Exactly 64 records, with a valid 65th pointer available, must stop before
  // reading record 65 and report the compile-time frame limit.
  for I := 0 to CRASH_THREAD_CAPTURE_MAX_FRAMES do
  begin
    StackWords[I * 2] := UIntPtr(@StackWords[(I + 1) * 2]);
    StackWords[I * 2 + 1] := UIntPtr($1000 + I);
  end;
  CrashThreadCaptureTestBoundedWalk(LowAddress, HighAddress, SP, SP,
    FPCount, RawCount, RawBase, FirstRaw, StopReason);
  if (FPCount <> CRASH_THREAD_CAPTURE_MAX_FRAMES) or
     (RawCount <> CRASH_THREAD_CAPTURE_RAW_WORDS) or
     (StopReason <> tcsrFrameLimit) then
    Exit;

  CrashThreadCaptureTestBoundedWalk(LowAddress, HighAddress, SP,
    HighAddress, FPCount, RawCount, RawBase, FirstRaw, StopReason);
  if StopReason <> tcsrFramePointerOutside then
    Exit;
  CrashThreadCaptureTestBoundedWalk(LowAddress, HighAddress, SP,
    HighAddress - SizeOf(Pointer), FPCount, RawCount, RawBase, FirstRaw,
    StopReason);
  if StopReason <> tcsrFramePointerOutside then
    Exit;

  FillChar(StackWords, SizeOf(StackWords), 0);
  FP := HighAddress - 2 * SizeOf(Pointer);
  PTestUIntPtr(FP)^ := 0;
  PTestUIntPtr(FP + SizeOf(Pointer))^ := $2000;
  CrashThreadCaptureTestBoundedWalk(LowAddress, HighAddress, SP, FP,
    FPCount, RawCount, RawBase, FirstRaw, StopReason);
  if (FPCount <> 1) or (StopReason <> tcsrEnd) then
    Exit;

  CrashThreadCaptureTestBoundedWalk(LowAddress, HighAddress, SP,
    LowAddress + SizeOf(Pointer) + 1, FPCount, RawCount, RawBase, FirstRaw,
    StopReason);
  if StopReason <> tcsrFramePointerMisaligned then
    Exit;
  CrashThreadCaptureTestBoundedWalk(LowAddress, HighAddress, SP, 0,
    FPCount, RawCount, RawBase, FirstRaw, StopReason);
  if StopReason <> tcsrFramePointerZero then
    Exit;
  CrashThreadCaptureTestBoundedWalk(LowAddress, HighAddress, SP,
    LowAddress + 2 * SizeOf(Pointer), FPCount, RawCount, RawBase, FirstRaw,
    StopReason);
  if (FPCount <> 0) or (StopReason <> tcsrEnd) then
    Exit;

  CrashThreadCaptureTestBoundedWalk(LowAddress, HighAddress,
    LowAddress + 4 * SizeOf(Pointer), LowAddress + 2 * SizeOf(Pointer),
    FPCount, RawCount, RawBase, FirstRaw, StopReason);
  if StopReason <> tcsrFramePointerOutside then
    Exit;
  CrashThreadCaptureTestBoundedWalk(LowAddress, HighAddress, HighAddress,
    LowAddress, FPCount, RawCount, RawBase, FirstRaw, StopReason);
  Result := StopReason = tcsrStackPointerOutside;
end;

function Step_H3_X86CallDecoder: Boolean;
begin
  Result :=
    CrashThreadCaptureTestX86FFCall(TBytes.Create($FF, $D0)) and
    CrashThreadCaptureTestX86FFCall(
      TBytes.Create($48, $FF, $15, 0, 0, 0, 0)) and
    CrashThreadCaptureTestX86FFCall(
      TBytes.Create($41, $FF, $54, $24, $08)) and
    (not CrashThreadCaptureTestX86FFCall(TBytes.Create($FF, $E0))) and
    (not CrashThreadCaptureTestX86FFCall(TBytes.Create($FF)));
end;

function Step_H3a_ARM64CallDecoder: Boolean;
begin
  Result :=
    CrashThreadCaptureTestARM64Call($94000000) and // BL +0
    CrashThreadCaptureTestARM64Call($97FFFFFF) and // BL -4
    CrashThreadCaptureTestARM64Call($D63F0000) and // BLR X0
    CrashThreadCaptureTestARM64Call($D63F03E0) and // BLR XZR
    (not CrashThreadCaptureTestARM64Call($14000000)) and // B +0
    (not CrashThreadCaptureTestARM64Call($D61F0000)); // BR X0
end;

function Step_H3b_MergeRules: Boolean;
begin
  Result := CrashThreadCaptureTestMergeRules;
end;

function Step_H3c_ContextLayoutAndValidation: Boolean;
begin
  Result := CrashThreadCaptureTestContextAccessors and
    CrashThreadCaptureTestValidationRules;
end;

function Step_H4_FaultFreeCodeReads: Boolean;
var
  SourceValue, DestValue: UIntPtr;
  NoAccess: Pointer;
  PageSize: LongInt;
  Ranges: TCrashExecutableRanges;
  I: Integer;
  FoundMapping: Boolean;
begin
  SourceValue := UIntPtr($1234ABCD);
  DestValue := 0;
  Result := CrashTryReadProcessMemory(UIntPtr(@SourceValue), @DestValue,
    SizeOf(SourceValue)) and (DestValue = SourceValue);
  if not Result then
    Exit;
  Ranges := CrashEnumerateReadableExecutableRanges;
  Result := Length(Ranges) > 0;
  for I := 0 to High(Ranges) do
    Result := Result and (Ranges[I].LowAddress < Ranges[I].HighAddress);
  if not Result then
    Exit;

  PageSize := sysconf(_SC_PAGESIZE);
  if PageSize <= 0 then
    Exit(False);
  NoAccess := mmap(nil, PageSize, PROT_NONE,
    MAP_PRIVATE or TEST_MAP_ANONYMOUS, -1, 0);
  if NoAccess = MAP_FAILED then
    Exit(False);
  try
    DestValue := 0;
    if CrashTryReadProcessMemory(UIntPtr(NoAccess), @DestValue,
         SizeOf(DestValue)) then
      Exit(False);

    // An inaccessible mapping must never enter the executable range set.
    if mprotect(NoAccess, PageSize, PROT_EXEC) <> 0 then
      Exit(False);
    Ranges := CrashEnumerateReadableExecutableRanges;
    FoundMapping := False;
    for I := 0 to High(Ranges) do
      if (UIntPtr(NoAccess) >= Ranges[I].LowAddress) and
         (UIntPtr(NoAccess) < Ranges[I].HighAddress) then
      begin
        FoundMapping := True;
        Break;
      end;
    if FoundMapping then
      Exit(False);

    if mprotect(NoAccess, PageSize, PROT_READ or PROT_EXEC) <> 0 then
      Exit(False);
    Ranges := CrashEnumerateReadableExecutableRanges;
    FoundMapping := False;
    for I := 0 to High(Ranges) do
      if (UIntPtr(NoAccess) >= Ranges[I].LowAddress) and
         (UIntPtr(NoAccess) < Ranges[I].HighAddress) then
      begin
        FoundMapping := True;
        Break;
      end;
    {$IF Defined(LINUX)}
    // Linux follows the live mapping permissions from /proc/self/maps.
    Result := FoundMapping;
    {$ELSEIF Defined(MACOS)}
    // macOS deliberately trusts dyld Mach-O segments, not anonymous mappings.
    Result := not FoundMapping;
    {$ELSE}
    Result := False;
    {$ENDIF}
  finally
    munmap(NoAccess, PageSize);
  end;
end;

function Step_H6_RealSignalGuardAltStackAndReset: Boolean;
var
  Worker: TGuardCaptureWorker;
  Region: Pointer;
  PageSize: LongInt;
  LowAddress, HighAddress, SP, FP, HandlerAddress: UIntPtr;
  Trace, ResetTrace: TCrashThreadRawTrace;
  Outcome, ResetOutcome: TCrashThreadCaptureOutcome;
  Deadline: UInt64;
begin
  Result := False;
  PageSize := 0;
  Region := MAP_FAILED;
  Worker := TGuardCaptureWorker.Create;
  try
    Deadline := TThread.GetTickCount64 + WORKER_READY_TIMEOUT_MS;
    while (not Worker.Ready) and (TThread.GetTickCount64 < Deadline) do
      TThread.Sleep(1);
    if (not Worker.Ready) or (Worker.ErrorText <> '') or
       (Worker.CaptureHandle = nil) then
      Exit;

    PageSize := sysconf(_SC_PAGESIZE);
    if PageSize <= 0 then
      Exit;
    Region := mmap(nil, NativeUInt(PageSize) * 3, PROT_NONE,
      MAP_PRIVATE or TEST_MAP_ANONYMOUS, -1, 0);
    if Region = MAP_FAILED then
      Exit;
    LowAddress := UIntPtr(Region) + UIntPtr(PageSize);
    HighAddress := LowAddress + UIntPtr(PageSize);
    if mprotect(Pointer(LowAddress), PageSize,
         PROT_READ or PROT_WRITE) <> 0 then
      Exit;

    SP := HighAddress - 25;
    FP := HighAddress - 2 * SizeOf(Pointer);
    PTestUIntPtr(HighAddress - 3 * SizeOf(Pointer))^ := UIntPtr($11223344);
    PTestUIntPtr(FP)^ := 0;
    PTestUIntPtr(FP + SizeOf(Pointer))^ := UIntPtr($55667788);
    if not CrashThreadCaptureTestSetContextOverride(Worker.CaptureHandle,
         LowAddress, HighAddress, SP, FP) then
      Exit;
    Outcome := CrashThreadCaptureCapture(Worker.CaptureHandle, 1000, Trace);
    HandlerAddress := CrashThreadCaptureTestHandlerStackAddress(
      Worker.CaptureHandle);
    if (Outcome <> tcoCaptured) or (not Trace.BoundsAvailable) or
       (Trace.StopReason <> tcsrFrameInvalidCode) or
       (HandlerAddress < Worker.AltLow) or
       (HandlerAddress >= Worker.AltHigh) then
      Exit;

    // A second real signal with unusable bounds must publish a fresh IP-only
    // payload rather than inheriting the first capture's FP/raw metadata.
    if not CrashThreadCaptureTestSetContextOverride(Worker.CaptureHandle,
         LowAddress, LowAddress + SizeOf(Pointer), LowAddress, 0) then
      Exit;
    ResetOutcome := CrashThreadCaptureCapture(Worker.CaptureHandle, 1000,
      ResetTrace);
    Result := (ResetOutcome = tcoCaptured) and
      (ResetTrace.InterruptedIP <> 0) and
      (Length(ResetTrace.Addresses) = 1) and
      (ResetTrace.FPFrameCount = 0) and
      (ResetTrace.RawFrameCount = 0) and
      (ResetTrace.StopReason = tcsrBoundsNone);
  finally
    if Region <> MAP_FAILED then
      munmap(Region, NativeUInt(PageSize) * 3);
    Worker.ReleaseThread;
    Worker.WaitFor;
    Worker.Free;
  end;
end;

procedure RunStage4PrimitiveTests(const AProgress: TCrashTestProgress);
begin
  AProgress.Account(Step_H1_BoundedGuardAndRawWindow,
    'H1: bounded FP/raw walker stops at guard pages and aligns raw SP');
  AProgress.Account(Step_H2_RBPAsGPRIsBounded,
    'H2: aligned RBP-as-GPR corruption terminates monotonically and at 128 raw words');
  AProgress.Account(Step_H2a_WalkerBoundaryMatrix,
    'H2a: walker covers 64-frame, FP edge, zero, alignment and SP bounds stops');
  AProgress.Account(Step_H3_X86CallDecoder,
    'H3: x86 FF /2 decoder accepts bounded calls and rejects non-call encodings');
  AProgress.Account(Step_H3a_ARM64CallDecoder,
    'H3a: ARM64 BL/BLR masks accept calls and reject B/BR encodings');
  AProgress.Account(Step_H3b_MergeRules,
    'H3b: FP/raw merge orders positions, prefers FP and removes source duplicates');
  AProgress.Account(Step_H3c_ContextLayoutAndValidation,
    'H3c: ucontext layout and executable call-site validation fail closed');
  AProgress.Account(Step_H4_FaultFreeCodeReads,
    'H4: fault-free reads and platform executable-range policy fail closed');
  AProgress.Account(CrashThreadCaptureTestActionUsesAltStack,
    'H5: capture action is installed with SA_ONSTACK');
  AProgress.Account(Step_H6_RealSignalGuardAltStackAndReset,
    'H6: real alt-stack signal respects guard bounds and resets stale payload');
end;

function RaiseCaptureLimit: Integer;
// Selection takes the first N registrations and the round's workers register
// last: in a host with many live registered threads they would fall past the
// default 32. Steps that check their own workers (not the limit) raise it to
// the hard maximum; returns the previous value for RestoreCaptureLimit.
begin
  Result := 0;
  CrashAutoTestSetExtendedThreadsMax(HARD_CAPTURE_LIMIT, Result);
end;

procedure RestoreCaptureLimit(const APrevious: Integer);
var
  Ignored: Integer;
begin
  CrashAutoTestSetExtendedThreadsMax(APrevious, Ignored);
end;

procedure RunOwningFrameRound(const ACoordinator: TCrashThreadCoverage;
  const AProgress: TCrashTestProgress);
const
  PREFIX = 'CrashExtended.Q';
var
  Workers: TObjectList<TExtendedCaptureWorker>;
  Threads: TArray<TCrashThreadStack>;
  Omitted, Index, I, SavedMaxDepth, SavedLimit: Integer;
  ExecuteLow, ExecuteHigh: UIntPtr;
  TotalMS, MaxThreadMS: UInt64;
  CaptureOK, RangeOK, FrameOK: Boolean;
  CleanupError: String;
begin
  Workers := StartWorkers(PREFIX, 1, False);
  SavedMaxDepth := TCrashCapture.MaxCallStackDepth;
  SavedLimit := RaiseCaptureLimit;
  try
    TCrashCapture.MaxCallStackDepth := 16;
    CaptureOK := CrashAutoTestCaptureExtendedThreads(
      ACoordinator.ThreadID, Threads, Omitted, TotalMS, MaxThreadMS);
    Index := ExtendedIndex(Threads, WorkerName(PREFIX, 0));
    RangeOK := WorkerExecuteCodeRange(Workers[0], ExecuteLow, ExecuteHigh);
    FrameOK := CaptureOK and (Index >= 0) and
      (Threads[Index].State = ctcsCaptured) and
      RangeOK and StackContainsCodeRange(Threads[Index].CallStack,
        ExecuteLow, ExecuteHigh);
    if CaptureOK and (Index >= 0) and (not FrameOK) then
      for I := 0 to High(Threads[Index].CallStack) do
        AProgress.InfoFmt('E1a frame %d: address=%x module=%x offset=%x name=%s',
          [I, UInt64(Threads[Index].CallStack[I].CodeAddress),
           UInt64(Threads[Index].CallStack[I].ModuleAddress),
           UInt64(Threads[Index].CallStack[I].CodeAddress -
             Threads[Index].CallStack[I].ModuleAddress),
           Threads[Index].CallStack[I].RoutineName]);
    if CaptureOK and (Index < 0) then
      AProgress.InfoFmt('E1a: worker not selected (listed=%d omitted=%d)',
        [Length(Threads), Omitted]);
    AProgress.Account(FrameOK,
      'E1a: responsive trace reaches the owning Delphi Execute code interval');
  finally
    RestoreCaptureLimit(SavedLimit);
    TCrashCapture.MaxCallStackDepth := SavedMaxDepth;
    CleanupError := StopWorkers(Workers);
    Workers.Free;
    AProgress.Account(CleanupError = '',
      'E1b: owning-frame worker unregisters cleanly');
  end;
end;

procedure RunResponsiveRound(const ACoordinator: TCrashThreadCoverage;
  const AProgress: TCrashTestProgress);
const
  PREFIX = 'CrashExtended.R';
var
  Workers: TObjectList<TExtendedCaptureWorker>;
  Threads, WorkerPrimaryThreads: TArray<TCrashThreadStack>;
  Fresh: TCrashStatus;
  FreezeReport: TCrashReport;
  ExtendCapture: TCrashFreezeExtendCaptureEvent;
  Omitted, WorkerPrimaryOmitted, BaselineEligible, ExpectedSelected,
    ExpectedOmitted, I, Index, CapturedCount, SavedMaxDepth,
    SavedLimit: Integer;
  TotalMS, MaxThreadMS, OtherTotalMS, OtherMaxMS: UInt64;
  OrderOK, CaptureOK, FreezeOK, DiagnosticsOK: Boolean;
  CleanupError: String;
begin
  Workers := StartWorkers(PREFIX, RESPONSIVE_WORKER_COUNT, False);
  SavedMaxDepth := TCrashCapture.MaxCallStackDepth;
  SavedLimit := -1;
  try
    TCrashCapture.MaxCallStackDepth := 3;
    if not WaitWorkersReady(Workers, WORKER_READY_TIMEOUT_MS) then
    begin
      AProgress.Account(False, 'E2: responsive workers became ready');
      Exit;
    end;
    AProgress.Account(True, 'E2: 34 responsive workers registered');

    // Host DCS/IPC workers register asynchronously: count the non-worker
    // baseline right before the capture, not from a pre-round snapshot.
    Fresh := TCrashReporter.GetStatus;
    CaptureOK := CrashAutoTestCaptureExtendedThreads(
      ACoordinator.ThreadID, Threads, Omitted, TotalMS, MaxThreadMS);
    BaselineEligible := NonWorkerEligibleCount(Fresh,
      ACoordinator.ThreadID, PREFIX);
    ExpectedSelected := WorkersInFirstEligible(Fresh, ACoordinator.ThreadID,
      PREFIX, CAPTURE_LIMIT);
    ExpectedOmitted := BaselineEligible + RESPONSIVE_WORKER_COUNT -
      CAPTURE_LIMIT;
    if ExpectedOmitted < 0 then
      ExpectedOmitted := 0;

    OrderOK := CountPrefix(Threads, PREFIX) = ExpectedSelected;
    CapturedCount := 0;
    DiagnosticsOK := True;
    for I := 0 to ExpectedSelected - 1 do
    begin
      Index := ExtendedIndex(Threads, WorkerName(PREFIX, I));
      OrderOK := OrderOK and (Index >= 0);
      if (Index >= 0) and (Threads[Index].State = ctcsCaptured) and
         (Length(Threads[Index].CallStack) > 0) and
         (Length(Threads[Index].CallStack) <= 3) then
      begin
        Inc(CapturedCount);
        DiagnosticsOK := DiagnosticsOK and
          (Pos('bounds=ok', Threads[Index].CaptureDiagnostics) > 0) and
          (Pos('fp-frames=', Threads[Index].CaptureDiagnostics) > 0) and
          (Pos('raw-frames=', Threads[Index].CaptureDiagnostics) > 0) and
          (Pos('raw-inner=', Threads[Index].CaptureDiagnostics) > 0) and
          (Pos('stop=', Threads[Index].CaptureDiagnostics) > 0);
      end;
    end;
    if not (CaptureOK and (Omitted = ExpectedOmitted) and OrderOK) then
    begin
      AProgress.InfoFmt('E3 detail: baseline=%d omitted=%d expectedOmitted=%d ' +
        'selectedR=%d expectedSelected=%d',
        [BaselineEligible, Omitted, ExpectedOmitted, CountPrefix(Threads, PREFIX),
         ExpectedSelected]);
      for I := 0 to High(Fresh.Threads) do
        AProgress.InfoFmt('E3 baseline: %s id=%x',
          [Fresh.Threads[I].Name, Fresh.Threads[I].ThreadID]);
      for I := 0 to High(Threads) do
        AProgress.InfoFmt('E3 captured: %s id=%x state=%d frames=%d',
          [Threads[I].Name, Threads[I].ThreadID, Ord(Threads[I].State),
           Length(Threads[I].CallStack)]);
    end;
    AProgress.Account(CaptureOK and (Omitted = ExpectedOmitted) and OrderOK,
      'E3: 33+ registrations obey the limit and registration order');
    AProgress.Account(CapturedCount = ExpectedSelected,
      'E4: selected worker stacks are captured and limited by MaxCallStackDepth');
    AProgress.Account(DiagnosticsOK and (CapturedCount = ExpectedSelected),
      'E4a: every captured worker exposes bounded FP/raw diagnostics');
    AProgress.Account((ExpectedSelected = 0) or
      ((TotalMS < 150) and (MaxThreadMS < 20)),
      'E5: responsive capture has no fixed 5 ms polling tax ' +
      '(total=' + IntToStr(Int64(TotalMS)) + ' ms, max-thread=' +
      IntToStr(Int64(MaxThreadMS)) + ' ms)');

    // E3-E5 checked the default limit; E6/E7 check the workers themselves.
    SavedLimit := RaiseCaptureLimit;
    WorkerPrimaryOmitted := 0;
    OtherTotalMS := 0;
    OtherMaxMS := 0;
    CaptureOK := CrashAutoTestCaptureExtendedThreads(
      Workers[0].Coverage.ThreadID, WorkerPrimaryThreads,
      WorkerPrimaryOmitted, OtherTotalMS, OtherMaxMS);
    Index := ExtendedIndex(WorkerPrimaryThreads, WorkerName(PREFIX, 1));
    AProgress.Account(CaptureOK and
      (ExtendedIndex(WorkerPrimaryThreads, WorkerName(PREFIX, 0)) < 0) and
      (Index >= 0) and (WorkerPrimaryThreads[Index].State = ctcsCaptured),
      'E6: worker-primary capture excludes the exception worker and keeps a sibling');

    FreezeReport := Default(TCrashReport);
    SetLength(FreezeReport.CallStack, 1);
    FreezeReport.CallStack[0].CodeAddress := UIntPtr($12345678);
    ExtendCapture := TCrashFreeze.OnExtendCapture;
    FreezeOK := Assigned(ExtendCapture);
    if FreezeOK then
    begin
      ExtendCapture(FreezeReport);
      FreezeOK := (Length(FreezeReport.CallStack) = 1) and
        (FreezeReport.CallStack[0].CodeAddress = UIntPtr($12345678)) and
        (CountPrefix(FreezeReport.ExtendedThreads, PREFIX) > 0);
    end;
    AProgress.Account(FreezeOK,
      'E7: freeze extension preserves the primary stack and adds worker blocks');
  finally
    if SavedLimit >= 0 then
      RestoreCaptureLimit(SavedLimit);
    TCrashCapture.MaxCallStackDepth := SavedMaxDepth;
    CleanupError := StopWorkers(Workers);
    Workers.Free;
    AProgress.Account(CleanupError = '',
      'E8: responsive workers unregister cleanly');
  end;
end;

procedure RunBudgetRound(const ACoordinator: TCrashThreadCoverage;
  const AProgress: TCrashTestProgress);
const
  PREFIX = 'CrashExtended.B';
var
  Workers: TObjectList<TExtendedCaptureWorker>;
  Threads: TArray<TCrashThreadStack>;
  Omitted, I, Index, TimedOutCount, BudgetCount, SavedLimit: Integer;
  TotalMS, MaxThreadMS: UInt64;
  CaptureOK, StatesOK: Boolean;
  CleanupError: String;
begin
  Workers := StartWorkers(PREFIX, BLOCKED_WORKER_COUNT, True);
  SavedLimit := RaiseCaptureLimit;
  try
    if not WaitWorkersReady(Workers, WORKER_READY_TIMEOUT_MS) then
    begin
      AProgress.Account(False, 'E9: signal-blocked workers became ready');
      Exit;
    end;
    AProgress.Account(True, 'E9: signal-blocked workers registered');

    CaptureOK := CrashAutoTestCaptureExtendedThreads(
      ACoordinator.ThreadID, Threads, Omitted, TotalMS, MaxThreadMS);
    TimedOutCount := 0;
    BudgetCount := 0;
    StatesOK := True;
    for I := 0 to BLOCKED_WORKER_COUNT - 1 do
    begin
      Index := ExtendedIndex(Threads, WorkerName(PREFIX, I));
      StatesOK := StatesOK and (Index >= 0);
      if Index >= 0 then
        case Threads[Index].State of
          ctcsTimedOut:
            Inc(TimedOutCount);
          ctcsBudgetExceeded:
            Inc(BudgetCount);
        else
          StatesOK := False;
        end;
    end;
    AProgress.Account(CaptureOK and StatesOK and (TimedOutCount > 0) and
      (BudgetCount > 0),
      'E10: blocked signals yield explicit timeout and total-budget states');
    AProgress.Account((TotalMS >= 800) and (TotalMS <= 1200) and
      (MaxThreadMS <= 110),
      'E11: 100 ms per-thread and 1000 ms total budgets are bounded ' +
      '(total=' + IntToStr(Int64(TotalMS)) + ' ms, max-thread=' +
      IntToStr(Int64(MaxThreadMS)) + ' ms)');
  finally
    RestoreCaptureLimit(SavedLimit);
    CleanupError := StopWorkers(Workers);
    Workers.Free;
    AProgress.Account(CleanupError = '',
      'E12: late signals drain and blocked workers unregister cleanly');
  end;
end;

procedure RunGroupSelectionRound(const AProgress: TCrashTestProgress);
const
  GROUP_OWN = UInt64($2A);
  GROUP_FOREIGN_A = UInt64($A1);
  GROUP_FOREIGN_B = UInt64($B1);
  PRIMARY_NAME = 'CrashExtended.GroupPrimary';
  OWN_0 = 'CrashExtended.GroupOwn0';
  OWN_1 = 'CrashExtended.GroupOwn1';
  GLOBAL_0 = 'CrashExtended.GroupGlobal0';
  FOREIGN_A0 = 'CrashExtended.GroupForeignA0';
  FOREIGN_A1 = 'CrashExtended.GroupForeignA1';
  FOREIGN_B0 = 'CrashExtended.GroupForeignB0';
var
  Workers: TObjectList<TExtendedCaptureWorker>;
  Primary: TExtendedCaptureWorker;
  Status: TCrashStatus;
  Threads: TArray<TCrashThreadStack>;
  SavedMax, PreviousMax, Omitted, OwnCount, GlobalCount,
    ForeignGroupCount, DiversityLimit, ExpectedOmitted: Integer;
  Own0Index, Own1Index, MainIndex, ForeignA0Index, ForeignA1Index,
    ForeignB0Index: Integer;
  TotalMS, MaxThreadMS: UInt64;
  CaptureOK, LimitOK, GroupOK, OrderOK: Boolean;
  CleanupError: String;

  function CaptureAtLimit(const ALimit: Integer): Boolean;
  begin
    Result := CrashAutoTestSetExtendedThreadsMax(ALimit, PreviousMax) and
      CrashAutoTestCaptureExtendedThreads(Primary.Coverage.ThreadID,
        Threads, Omitted, TotalMS, MaxThreadMS);
  end;

begin
  LimitOK :=
    (CrashAutoTestEffectiveExtendedThreadsMax(-1) = 32) and
    (CrashAutoTestEffectiveExtendedThreadsMax(0) = 32) and
    (CrashAutoTestEffectiveExtendedThreadsMax(1) = 1) and
    (CrashAutoTestEffectiveExtendedThreadsMax(128) = 128) and
    (CrashAutoTestEffectiveExtendedThreadsMax(129) = 128);
  AProgress.Account(LimitOK,
    'E14: ExtendedThreadsMax uses default 32 and clamps to hard limit 128');

  Workers := TObjectList<TExtendedCaptureWorker>.Create(True);
  SavedMax := 0;
  try
    AddReadyWorker(Workers, PRIMARY_NAME, False, GROUP_OWN);
    Primary := Workers[0];
    Status := TCrashReporter.GetStatus;
    GroupOK := Primary.Coverage.Registered and
      (Primary.Coverage.GroupID = GROUP_OWN) and
      Primary.Coverage.ExtendedCaptureAvailable;

    // Registration order is intentionally mixed. Selection must materialize
    // Own -> Global -> Foreign instead of preserving this mixed order.
    AddReadyWorker(Workers, FOREIGN_A0, False, GROUP_FOREIGN_A);
    AddReadyWorker(Workers, OWN_0, False, GROUP_OWN);
    AddReadyWorker(Workers, FOREIGN_A1, False, GROUP_FOREIGN_A);
    AddReadyWorker(Workers, GLOBAL_0, False, 0);
    AddReadyWorker(Workers, FOREIGN_B0, False, GROUP_FOREIGN_B);
    AddReadyWorker(Workers, OWN_1, False, GROUP_OWN);
    Status := TCrashReporter.GetStatus;
    GroupOK := GroupOK and
      (Workers[1].Coverage.GroupID = GROUP_FOREIGN_A) and
      (Workers[2].Coverage.GroupID = GROUP_OWN) and
      (Workers[4].Coverage.GroupID = 0) and
      (Workers[5].Coverage.GroupID = GROUP_FOREIGN_B) and
      (Workers[6].Coverage.GroupID = GROUP_OWN);
    AProgress.Account(GroupOK,
      'E15: GroupID and capture availability round-trip through registration');

    if not CrashAutoTestSetExtendedThreadsMax(1, SavedMax) then
    begin
      AProgress.Account(False, 'E16: test can set capture candidate limit');
      Exit;
    end;

    CaptureOK := CrashAutoTestCaptureExtendedThreads(
      Primary.Coverage.ThreadID, Threads, Omitted, TotalMS, MaxThreadMS);
    Own0Index := ExtendedIndex(Threads, OWN_0);
    AProgress.Account(CaptureOK and (Length(Threads) = 1) and
      (Own0Index = 0) and (Threads[0].GroupID = GROUP_OWN),
      'E16.1: limit 1 gives its only slot to the first Own thread');

    CaptureOK := CaptureAtLimit(2);
    Own0Index := ExtendedIndex(Threads, OWN_0);
    MainIndex := ExtendedIndexByThreadID(Threads,
      Status.MainThread.ThreadID);
    AProgress.Account(CaptureOK and (Length(Threads) = 2) and
      (Own0Index = 0) and (MainIndex = 1) and
      (Threads[MainIndex].GroupID = 0),
      'E16.2: limit 2 keeps first Own and MAIN as first Global');

    CaptureOK := CaptureAtLimit(3);
    Own0Index := ExtendedIndex(Threads, OWN_0);
    MainIndex := ExtendedIndexByThreadID(Threads,
      Status.MainThread.ThreadID);
    AProgress.Account(CaptureOK and (Length(Threads) = 3) and
      (Own0Index = 0) and (MainIndex = 1) and
      (Threads[2].GroupID = 0),
      'E16.3: limit 3 reserves one Own and two Global slots');

    CaptureOK := CaptureAtLimit(4);
    Own0Index := ExtendedIndex(Threads, OWN_0);
    Own1Index := ExtendedIndex(Threads, OWN_1);
    MainIndex := ExtendedIndexByThreadID(Threads,
      Status.MainThread.ThreadID);
    AProgress.Account(CaptureOK and (Length(Threads) = 4) and
      (Own0Index = 0) and (Own1Index = 1) and (MainIndex = 2) and
      (Threads[3].GroupID = 0),
      'E16.4: limit 4 materializes Own before the two reserved Globals');

    OwnCount := EligibleGroupCount(Status,
      Primary.Coverage.ThreadID, GROUP_OWN);
    GlobalCount := EligibleGroupCount(Status,
      Primary.Coverage.ThreadID, 0);
    ForeignGroupCount := EligibleDistinctForeignGroupCount(Status,
      Primary.Coverage.ThreadID, GROUP_OWN);
    DiversityLimit := OwnCount + GlobalCount + ForeignGroupCount;
    ExpectedOmitted := BaselineEligibleCount(Status,
      Primary.Coverage.ThreadID) - DiversityLimit;
    CaptureOK := CaptureAtLimit(DiversityLimit);
    Own0Index := ExtendedIndex(Threads, OWN_0);
    Own1Index := ExtendedIndex(Threads, OWN_1);
    MainIndex := ExtendedIndexByThreadID(Threads,
      Status.MainThread.ThreadID);
    ForeignA0Index := ExtendedIndex(Threads, FOREIGN_A0);
    ForeignA1Index := ExtendedIndex(Threads, FOREIGN_A1);
    ForeignB0Index := ExtendedIndex(Threads, FOREIGN_B0);
    OrderOK := CaptureOK and (Length(Threads) = DiversityLimit) and
      (Omitted = ExpectedOmitted) and
      (Own0Index = 0) and (Own1Index = 1) and
      (MainIndex = OwnCount) and
      (ForeignA0Index >= OwnCount + GlobalCount) and
      (ForeignB0Index = ForeignA0Index + 1) and
      (ForeignA1Index < 0) and
      CapturedForeignGroupsAreUnique(Threads, GROUP_OWN);
    AProgress.Account(OrderOK,
      'E17: Foreign tail takes one oldest representative per group before repeats');
  finally
    CrashAutoTestSetExtendedThreadsMax(SavedMax, PreviousMax);
    CleanupError := StopWorkers(Workers);
    Workers.Free;
    AProgress.Account(CleanupError = '',
      'E18: grouped workers unregister cleanly');
  end;
end;

procedure RunGroupBudgetRound(const AProgress: TCrashTestProgress);
const
  GROUP_OWN = UInt64($2B);
  PRIMARY_NAME = 'CrashExtended.BudgetPrimary';
  OWN_PREFIX = 'CrashExtended.BudgetOwn';
var
  Workers: TObjectList<TExtendedCaptureWorker>;
  Primary: TExtendedCaptureWorker;
  Status: TCrashStatus;
  Threads: TArray<TCrashThreadStack>;
  SavedMax, PreviousMax, Omitted, I, MainIndex: Integer;
  TotalMS, MaxThreadMS: UInt64;
  CaptureOK: Boolean;
  CleanupError: String;
begin
  Workers := TObjectList<TExtendedCaptureWorker>.Create(True);
  SavedMax := 0;
  try
    AddReadyWorker(Workers, PRIMARY_NAME, False, GROUP_OWN);
    Primary := Workers[0];
    for I := 0 to BLOCKED_WORKER_COUNT - 1 do
      AddReadyWorker(Workers, WorkerName(OWN_PREFIX, I), True, GROUP_OWN);
    Status := TCrashReporter.GetStatus;
    if not CrashAutoTestSetExtendedThreadsMax(32, SavedMax) then
    begin
      AProgress.Account(False, 'E19: test can set grouped budget limit');
      Exit;
    end;
    CaptureOK := CrashAutoTestCaptureExtendedThreads(
      Primary.Coverage.ThreadID, Threads, Omitted, TotalMS, MaxThreadMS);
    MainIndex := ExtendedIndexByThreadID(Threads,
      Status.MainThread.ThreadID);
    AProgress.Account(CaptureOK and (MainIndex >= 0) and
      (Threads[MainIndex].GroupID = 0) and
      (Threads[MainIndex].State <> ctcsBudgetExceeded),
      'E19: blocked Own preserve one bounded attempt for MAIN');
    AProgress.Account((TotalMS >= 800) and (TotalMS <= 1200) and
      (MaxThreadMS <= 110),
      'E20: grouped Own reserve keeps the unchanged 1000 ms total budget');
  finally
    CrashAutoTestSetExtendedThreadsMax(SavedMax, PreviousMax);
    CleanupError := StopWorkers(Workers);
    Workers.Free;
    AProgress.Account(CleanupError = '',
      'E21: grouped blocked workers drain and unregister cleanly');
  end;
end;

procedure RunSlotCapacityRound(const AProgress: TCrashTestProgress);
const
  FILLER_GROUP = UInt64($FD);
  LATE_GROUP = UInt64($FC);
  UNAVAILABLE_GROUP = UInt64($FE);
  FILLER_PREFIX = 'CrashExtended.Slot';
var
  Workers: TObjectList<TExtendedCaptureWorker>;
  BeforeStatus, AfterStatus: TCrashStatus;
  Coverage: TCrashThreadCoverage;
  Threads: TArray<TCrashThreadStack>;
  BaselineAvailable, BaselineLive, ExpectedAvailable, ActualAvailable, WorkerCount,
    I, SavedMax, PreviousMax, Omitted, LateIndex, UnavailableIndex: Integer;
  TotalMS, MaxThreadMS: UInt64;
  CaptureOK, StatusAvailableOK, StatusUnavailableOK: Boolean;
  CleanupError: String;
begin
  BeforeStatus := TCrashReporter.GetStatus;
  BaselineLive := CrashThreadCaptureTestLiveSlotCount;
  BaselineAvailable := 0;
  for I := 0 to High(BeforeStatus.Threads) do
    if BeforeStatus.Threads[I].ExtendedCaptureAvailable then
      Inc(BaselineAvailable);

  ExpectedAvailable := CRASH_THREAD_CAPTURE_SLOT_COUNT - BaselineAvailable;
  if ExpectedAvailable < 0 then
    ExpectedAvailable := 0;
  WorkerCount := ExpectedAvailable + 2;
  Workers := TObjectList<TExtendedCaptureWorker>.Create(True);
  SavedMax := 0;
  try
    // The late trio must sit beyond the old 64-slot boundary.
    if ExpectedAvailable < 67 then
    begin
      AProgress.Account(False,
        'E22: at least three real slots beyond index 64 remain after baseline registrations');
      Exit;
    end;
    for I := 0 to WorkerCount - 1 do
      if I < ExpectedAvailable then
      begin
        if I >= ExpectedAvailable - 3 then
          AddReadyWorker(Workers, WorkerName(FILLER_PREFIX, I), False,
            LATE_GROUP)
        else
          AddReadyWorker(Workers, WorkerName(FILLER_PREFIX, I), False,
            FILLER_GROUP);
      end
      else
        AddReadyWorker(Workers, WorkerName(FILLER_PREFIX, I), False,
          UNAVAILABLE_GROUP);

    ActualAvailable := 0;
    for I := 0 to Workers.Count - 1 do
      if Workers[I].Coverage.ExtendedCaptureAvailable then
        Inc(ActualAvailable);
    if ActualAvailable <> ExpectedAvailable then
      AProgress.InfoFmt('E22 diag: status-available=%d, live before workers=%d, got %d of expected %d free slots',
        [BaselineAvailable, BaselineLive, ActualAvailable, ExpectedAvailable]);
    AProgress.Account((CRASH_THREAD_CAPTURE_SLOT_COUNT = 256) and
      (ActualAvailable = ExpectedAvailable) and
      Workers[64].Coverage.ExtendedCaptureAvailable,
      'E22: real capture pool exposes all 256 slots and crosses the old 64-slot limit');

    AfterStatus := TCrashReporter.GetStatus;
    StatusAvailableOK := False;
    StatusUnavailableOK := False;
    for Coverage in AfterStatus.Threads do
    begin
      if Coverage.ThreadID =
         Workers[ExpectedAvailable - 1].Coverage.ThreadID then
        StatusAvailableOK := (Coverage.GroupID = LATE_GROUP) and
          Coverage.ExtendedCaptureAvailable;
      if Coverage.ThreadID = Workers[WorkerCount - 1].Coverage.ThreadID then
        StatusUnavailableOK := (Coverage.GroupID = UNAVAILABLE_GROUP) and
          (not Coverage.ExtendedCaptureAvailable);
    end;
    AProgress.Account(StatusAvailableOK and StatusUnavailableOK and
      (not Workers[WorkerCount - 2].Coverage.ExtendedCaptureAvailable) and
      (not Workers[WorkerCount - 1].Coverage.ExtendedCaptureAvailable),
      'E23: status exposes groups and availability on both sides of slot exhaustion');

    if not CrashAutoTestSetExtendedThreadsMax(1, SavedMax) then
    begin
      AProgress.Account(False,
        'E24: test can set late-slot capture limit');
      Exit;
    end;
    CaptureOK := CrashAutoTestCaptureExtendedThreads(
      Workers[ExpectedAvailable - 1].Coverage.ThreadID, Threads, Omitted,
      TotalMS, MaxThreadMS);
    LateIndex := ExtendedIndex(Threads,
      Workers[ExpectedAvailable - 3].WorkerName);
    AProgress.Account(CaptureOK and (Length(Threads) = 1) and
      (LateIndex = 0) and (Threads[LateIndex].GroupID = LATE_GROUP) and
      (Threads[LateIndex].State = ctcsCaptured) and
      (Length(Threads[LateIndex].CallStack) > 0),
      'E24: a real slot beyond the old 64-slot limit yields a captured stack');

    CaptureOK := CrashAutoTestCaptureExtendedThreads(
      Workers[WorkerCount - 1].Coverage.ThreadID, Threads, Omitted,
      TotalMS, MaxThreadMS);
    UnavailableIndex := ExtendedIndex(Threads,
      Workers[WorkerCount - 2].WorkerName);
    AProgress.Account(CaptureOK and (Length(Threads) = 1) and
      (UnavailableIndex = 0) and
      (Threads[UnavailableIndex].State = ctcsSignalUnavailable),
      'E25: selected registration without a raw slot reports SignalUnavailable');
  finally
    CrashAutoTestSetExtendedThreadsMax(SavedMax, PreviousMax);
    CleanupError := StopWorkers(Workers);
    Workers.Free;
    AProgress.Account(CleanupError = '',
      'E26: 256-slot capacity workers unregister cleanly');
  end;
end;

procedure RunPOSIXExtendedTests(const AProgress: TCrashTestProgress);
var
  BeforeStatus, BaselineStatus, AfterStatus: TCrashStatus;
  Coordinator: TCrashThreadCoverage;
  CoordinatorWasAdded, OverrideEnabled, HostExtendedEnabled: Boolean;
begin
  HostExtendedEnabled := TCrashReporter.GetStatus.ExtendedThreadsEnabled;
  OverrideEnabled := CrashAutoTestSetExtendedCaptureOverride(True);
  AProgress.Account(OverrideEnabled,
    'E1: test opt-in acquires the shared capture service');
  if not OverrideEnabled then
    Exit;

  CoordinatorWasAdded := False;
  try
    BeforeStatus := TCrashReporter.GetStatus;
    Coordinator := TCrashReporter.RegisterCurrentThread(
      'CrashExtended.Coordinator');
    BaselineStatus := TCrashReporter.GetStatus;
    CoordinatorWasAdded :=
      BaselineStatus.RegisteredThreadCount > BeforeStatus.RegisteredThreadCount;
    RunStage4PrimitiveTests(AProgress);
    RunOwningFrameRound(Coordinator, AProgress);
    RunResponsiveRound(Coordinator, AProgress);
    RunBudgetRound(Coordinator, AProgress);
    RunGroupSelectionRound(AProgress);
    RunGroupBudgetRound(AProgress);
    RunSlotCapacityRound(AProgress);
  finally
    if CoordinatorWasAdded then
      TCrashReporter.UnregisterCurrentThread;
    CrashAutoTestSetExtendedCaptureOverride(False);
    AfterStatus := TCrashReporter.GetStatus;
    AProgress.Account(
      AfterStatus.ExtendedThreadsEnabled = HostExtendedEnabled,
      'E13: test seam restores the configured host capture state');
  end;
end;

{$ENDIF}

class function TCrashExtendedThreads_AllInOne.AutoTest(
  out OutLines: TArray<string>): Boolean;
var
  Lines: TList<string>;
  Progress: TCrashTestProgress;
begin
  Lines := TList<string>.Create;
  try
    Progress := TCrashTestProgress.Create(Lines);
    try
      if not TCrashReporter.Active then
        Progress.Skip('Crash reporter is inactive on this target/configuration')
      {$IF Defined(CRASH_EXTENDED_RUNTIME_TEST)}
      else
        RunPOSIXExtendedTests(Progress)
      {$ELSE}
      else
        Progress.Skip('runtime extended capture is unavailable on this target')
      {$ENDIF};
      Progress.WriteSummary(TEST_NAME);
      Result := Progress.AllPassed;
    finally
      Progress.Free;
    end;
    OutLines := Lines.ToArray;
  finally
    Lines.Free;
  end;
end;

initialization
  CrashRegisterTest(
    'CrashExtendedThreads',
    'Crash registered-thread capture limits, budgets and integration',
    ['crash', 'thread', 'capture', 'budget', 'posix', 'linux', 'macos'],
    TCrashExtendedThreads_AllInOne.AutoTest
  );

{$ENDIF}

end.
