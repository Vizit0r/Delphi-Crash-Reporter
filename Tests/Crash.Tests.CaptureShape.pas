unit Crash.Tests.CaptureShape;

// Copyright (c) 2026 Vizit0r. BSD 2-Clause license (see LICENSE.txt).
//
// Shape of a real registered-thread capture: what the bounded FP/raw walker
// returns for threads parked in the kernel (TEvent.WaitFor, Sleep) and for a
// busy thread. Unlike CrashExtendedThreads this one also runs on Android.
//
//   S1  PAC-signed saved LR is stripped before validation (ARM64 only)
//   S2  syscall-stub LR rules on a synthetic code buffer
//   S3  event waiter: the frame-record chain reaches the owning Execute
//   S4  event waiter: ARM64 adds the syscall caller from LR
//   S5  sleeper: the frame-record chain reaches the owning Execute
//   S6  sleeper: ARM64 adds the syscall caller from LR
//   S7  busy frameless leaf: its caller (Execute) comes from LR on ARM64
//   S8  busy function that spills LR: a stale LR is never listed

interface

{$IFDEF AUTOTESTS}

uses
  System.SysUtils;

type
  TCrashCaptureShape_AllInOne = class
  public
    class function AutoTest(out OutLines: TArray<string>): Boolean; static;
  end;

{$ENDIF}

implementation

{$IFDEF AUTOTESTS}

{$IF (Defined(LINUX) and Defined(CPUX64)) or
     (Defined(ANDROID) and Defined(CPUARM64)) or
     (Defined(MACOS) and not Defined(IOS) and
       (Defined(CPUX64) or Defined(CPUARM64)))}
  {$DEFINE CRASH_CAPTURE_SHAPE_RUNTIME}
{$ENDIF}

uses
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  Crash.Reporter,
  Crash.ThreadCapture,
  Crash.Tests.Registry,
  Crash.Tests.Progress
  {$IF Defined(CRASH_CAPTURE_SHAPE_RUNTIME)}
  , Posix.Dlfcn
  {$ENDIF};

const
  TEST_NAME = 'CrashCaptureShape';

{$IF Defined(CRASH_CAPTURE_SHAPE_RUNTIME)}

const
  READY_TIMEOUT_MS = 5000;
  CAPTURE_WAIT_MS = 1000;
  PARK_SETTLE_MS = 200;
  FRAMED_SAMPLES = 40;

type
  TShapeMode = (smEvent, smSleep, smBusyLeaf, smBusyFramed);

  TShapeWorker = class(TThread)
  private
    FMode: TShapeMode;
    FReady: Integer;
    FRelease: Integer;
    FHandle: TCrashThreadCaptureHandle;
    FEvent: TEvent;
    FSpin: UInt64;
    procedure ParkInEvent;
    procedure ParkInSleep;
    procedure SpinBusy;
    function MixStep(const AValue: UInt64): UInt64;
    procedure SpinFramed;
  public
    ErrorText: String;
    constructor Create(const AMode: TShapeMode);
    destructor Destroy; override;
    function Ready: Boolean;
    procedure ReleaseThread;
    property CaptureHandle: TCrashThreadCaptureHandle read FHandle;
  protected
    procedure Execute; override;
  end;

  TShapeMethod = procedure of object;
  TShapeBoolMethod = function: Boolean of object;

constructor TShapeWorker.Create(const AMode: TShapeMode);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FMode := AMode;
  FEvent := TEvent.Create(nil, True, False, '');
  Start;
end;

destructor TShapeWorker.Destroy;
begin
  inherited;
  FEvent.Free;
end;

// Execute must stay directly before Ready: [Execute, Ready) is its code range.
procedure TShapeWorker.Execute;
var
  Registered: Boolean;
begin
  Registered := False;
  try
    try
      Registered := CrashThreadCaptureRegisterCurrentThread(FHandle);
      if not Registered then
        raise Exception.Create('low-level thread registration failed');
      TInterlocked.Exchange(FReady, 1);
      case FMode of
        smEvent: ParkInEvent;
        smSleep: ParkInSleep;
        smBusyLeaf: SpinBusy;
        smBusyFramed: SpinFramed;
      end;
    except
      on E: Exception do
        ErrorText := E.ClassName + ': ' + E.Message;
    end;
  finally
    TInterlocked.Exchange(FReady, 1);
    if Registered then
      CrashThreadCaptureUnregisterCurrentThread(FHandle);
  end;
end;

function TShapeWorker.Ready: Boolean;
begin
  Result := TInterlocked.CompareExchange(FReady, 0, 0) <> 0;
end;

procedure TShapeWorker.ParkInEvent;
begin
  FEvent.WaitFor(INFINITE);
end;

procedure TShapeWorker.ParkInSleep;
begin
  while TInterlocked.CompareExchange(FRelease, 0, 0) = 0 do
    TThread.Sleep(20);
end;

procedure TShapeWorker.SpinBusy;
begin
  while TInterlocked.CompareExchange(FRelease, 0, 0) = 0 do
    FSpin := FSpin xor (FSpin shl 7) xor 1;
end;

function TShapeWorker.MixStep(const AValue: UInt64): UInt64;
begin
  Result := AValue xor (AValue shr 3) xor 5;
end;

procedure TShapeWorker.SpinFramed;
var
  I: Integer;
begin
  while TInterlocked.CompareExchange(FRelease, 0, 0) = 0 do
    for I := 1 to 64 do
    begin
      FSpin := MixStep(FSpin);
      FSpin := FSpin xor (FSpin shl 5) xor UInt64(I);
    end;
end;


procedure TShapeWorker.ReleaseThread;
begin
  TInterlocked.Exchange(FRelease, 1);
  FEvent.SetEvent;
end;

function ExecuteCodeRange(const AWorker: TShapeWorker;
  out ALow, AHigh: UIntPtr): Boolean;
var
  ExecuteMethod: TShapeMethod;
  ReadyMethod: TShapeBoolMethod;
begin
  ExecuteMethod := AWorker.Execute;
  ReadyMethod := AWorker.Ready;
  ALow := UIntPtr(TMethod(ExecuteMethod).Code);
  AHigh := UIntPtr(TMethod(ReadyMethod).Code);
  Result := (ALow <> 0) and (AHigh > ALow) and (AHigh - ALow < 65536);
end;

function DescribeAddress(const AAddress: UIntPtr): String;
var
  Info: dl_info;
  Name: String;
begin
  Result := '$' + IntToHex(UInt64(AAddress), 16);
  FillChar(Info, SizeOf(Info), 0);
  if dladdr(NativeUInt(AAddress), Info) = 0 then
    Exit;
  if Info.dli_fname <> nil then
  begin
    Name := ExtractFileName(String(UTF8String(Info.dli_fname)));
    Result := Result + Format(' %s+$%x',
      [Name, UInt64(AAddress) - UInt64(UIntPtr(Info.dli_fbase))]);
  end;
  if Info.dli_sname <> nil then
    Result := Result + Format(' <%s+$%x>', [String(UTF8String(Info.dli_sname)),
      UInt64(AAddress) - UInt64(UIntPtr(Info.dli_saddr))]);
end;

function SourceText(const ASource: TCrashThreadFrameSource): String;
begin
  case ASource of
    tfsInterrupted: Result := 'ip';
    tfsLink: Result := 'lr';
    tfsFramePointer: Result := 'fp';
    tfsRaw: Result := 'raw';
  else
    Result := '?';
  end;
end;

procedure DumpCapture(const AProgress: TCrashTestProgress; const ATag: String;
  const AHandle: TCrashThreadCaptureHandle; const ATrace: TCrashThreadRawTrace;
  const AExecLow, AExecHigh: UIntPtr);
var
  Info: TCrashThreadCaptureTestSlotInfo;
  I: Integer;
  Mark: String;
begin
  AProgress.InfoFmt('%s: %s', [ATag,
    CrashThreadCaptureFormatDiagnostics(0, ATrace)]);
  AProgress.InfoFmt('%s: Execute=[$%x,$%x)', [ATag, UInt64(AExecLow),
    UInt64(AExecHigh)]);
  if CrashThreadCaptureTestLastSlot(AHandle, Info) then
  begin
    AProgress.InfoFmt('%s: ip=%s lr-decision: %s', [ATag,
      DescribeAddress(Info.InterruptedIP),
      CrashThreadCaptureTestLinkDecision(Info.InterruptedIP)]);
    AProgress.InfoFmt('%s: lr=%s check=%s', [ATag,
      DescribeAddress(Info.InterruptedLR),
      CrashThreadCaptureTestCheckAddress(Info.InterruptedLR)]);
    AProgress.InfoFmt('%s: sp=$%x fp=$%x raw-words=%d walker-stop=%s',
      [ATag, UInt64(Info.InterruptedSP), UInt64(Info.InterruptedFP),
       Info.RawWordCount, CrashThreadCaptureStopReasonText(Info.StopReason)]);
    for I := 0 to High(Info.FPAddresses) do
      AProgress.InfoFmt('%s: record %d: %s check=%s', [ATag, I,
        DescribeAddress(Info.FPAddresses[I]),
        CrashThreadCaptureTestCheckAddress(Info.FPAddresses[I])]);
  end;
  for I := 0 to High(ATrace.Addresses) do
  begin
    Mark := '';
    if (ATrace.Addresses[I] >= AExecLow) and (ATrace.Addresses[I] < AExecHigh) then
      Mark := ' [Execute]';
    AProgress.InfoFmt('%s: frame %d %-3s %s%s', [ATag, I,
      SourceText(ATrace.Sources[I]), DescribeAddress(ATrace.Addresses[I]), Mark]);
  end;
end;

function FramePointerReaches(const ATrace: TCrashThreadRawTrace;
  const ALow, AHigh: UIntPtr): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(ATrace.Addresses) do
    if (ATrace.Sources[I] = tfsFramePointer) and
       (ATrace.Addresses[I] >= ALow) and (ATrace.Addresses[I] < AHigh) then
      Exit(True);
end;

function WaitReady(const AWorker: TShapeWorker): Boolean;
var
  Deadline: UInt64;
begin
  Deadline := TThread.GetTickCount64 + READY_TIMEOUT_MS;
  while (not AWorker.Ready) and (TThread.GetTickCount64 < Deadline) do
    TThread.Sleep(1);
  Result := AWorker.Ready and (AWorker.ErrorText = '') and
    (AWorker.CaptureHandle <> nil);
end;

procedure RunParkedRound(const AProgress: TCrashTestProgress;
  const AMode: TShapeMode; const ATag, AReachDesc, ALinkDesc: String);
var
  Worker: TShapeWorker;
  Trace: TCrashThreadRawTrace;
  Outcome: TCrashThreadCaptureOutcome;
  ExecLow, ExecHigh: UIntPtr;
  Captured: Boolean;
begin
  Worker := TShapeWorker.Create(AMode);
  try
    if not WaitReady(Worker) then
    begin
      AProgress.Account(False, ATag + ': worker registered (' +
        Worker.ErrorText + ')');
      Exit;
    end;
    // Let the worker reach its parking call before the signal arrives.
    TThread.Sleep(PARK_SETTLE_MS);
    Outcome := CrashThreadCaptureCapture(Worker.CaptureHandle,
      CAPTURE_WAIT_MS, Trace);
    Captured := (Outcome = tcoCaptured) and
      ExecuteCodeRange(Worker, ExecLow, ExecHigh);
    if Captured then
      DumpCapture(AProgress, ATag, Worker.CaptureHandle, Trace, ExecLow,
        ExecHigh)
    else
      AProgress.InfoFmt('%s: capture outcome=%d', [ATag, Ord(Outcome)]);
    AProgress.Account(Captured and
      FramePointerReaches(Trace, ExecLow, ExecHigh), AReachDesc);
    {$IF Defined(CPUARM64)}
    AProgress.Account(Captured and Trace.LinkFrameUsed and
      (Length(Trace.Sources) > 1) and (Trace.Sources[1] = tfsLink), ALinkDesc);
    {$ELSE}
    // x86-64 keeps the return address on the stack: nothing to check.
    AProgress.Info(ALinkDesc + ': n/a on x86-64');
    {$ENDIF}
  finally
    Worker.ReleaseThread;
    Worker.WaitFor;
    Worker.Free;
  end;
end;

function TraceReaches(const ATrace: TCrashThreadRawTrace;
  const ALow, AHigh: UIntPtr): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(ATrace.Addresses) do
    if (ATrace.Addresses[I] >= ALow) and (ATrace.Addresses[I] < AHigh) then
      Exit(True);
end;

procedure RunBusyLeafRound(const AProgress: TCrashTestProgress);
var
  Worker: TShapeWorker;
  Trace: TCrashThreadRawTrace;
  Outcome: TCrashThreadCaptureOutcome;
  ExecLow, ExecHigh: UIntPtr;
  Captured: Boolean;
begin
  Worker := TShapeWorker.Create(smBusyLeaf);
  try
    if not WaitReady(Worker) then
    begin
      AProgress.Account(False, 'S7: busy worker registered (' +
        Worker.ErrorText + ')');
      Exit;
    end;
    TThread.Sleep(PARK_SETTLE_MS);
    Outcome := CrashThreadCaptureCapture(Worker.CaptureHandle,
      CAPTURE_WAIT_MS, Trace);
    Captured := (Outcome = tcoCaptured) and
      ExecuteCodeRange(Worker, ExecLow, ExecHigh);
    if Captured then
      DumpCapture(AProgress, 'S7', Worker.CaptureHandle, Trace, ExecLow,
        ExecHigh);
    {$IF Defined(ANDROID) and Defined(CPUARM64)}
    // The leaf keeps no frame record: only LR knows Execute called it.
    AProgress.Account(Captured and Trace.LinkFrameUsed and
      TraceReaches(Trace, ExecLow, ExecHigh),
      'S7: busy frameless leaf: its caller comes from LR');
    {$ELSE}
    AProgress.Account(Captured and TraceReaches(Trace, ExecLow, ExecHigh),
      'S7: busy frameless leaf: its caller is in the trace');
    {$ENDIF}
  finally
    Worker.ReleaseThread;
    Worker.WaitFor;
    Worker.Free;
  end;
end;

// Stale LR = an LR frame in the same function as the interrupted IP: it is the
// return address of a call that already came back.
procedure RunBusyFramedRound(const AProgress: TCrashTestProgress);
var
  Worker: TShapeWorker;
  Trace: TCrashThreadRawTrace;
  Outcome: TCrashThreadCaptureOutcome;
  SpinMethod: TShapeMethod;
  SpinStart, IPStart, LRStart: UIntPtr;
  I, Captured, InSpin, LinkUsed, Stale: Integer;
  Dumped, KnowsFunctions: Boolean;
begin
  Worker := TShapeWorker.Create(smBusyFramed);
  try
    if not WaitReady(Worker) then
    begin
      AProgress.Account(False, 'S8: busy worker registered (' +
        Worker.ErrorText + ')');
      Exit;
    end;
    SpinMethod := Worker.SpinFramed;
    SpinStart := UIntPtr(TMethod(SpinMethod).Code);
    KnowsFunctions := CrashThreadCaptureTestFunctionStart(SpinStart, IPStart) and
      (IPStart = SpinStart);
    TThread.Sleep(PARK_SETTLE_MS);
    Captured := 0;
    InSpin := 0;
    LinkUsed := 0;
    Stale := 0;
    Dumped := False;
    for I := 1 to FRAMED_SAMPLES do
    begin
      Outcome := CrashThreadCaptureCapture(Worker.CaptureHandle,
        CAPTURE_WAIT_MS, Trace);
      if Outcome <> tcoCaptured then
        Continue;
      Inc(Captured);
      if Trace.LinkFrameUsed then
        Inc(LinkUsed);
      if KnowsFunctions and
         CrashThreadCaptureTestFunctionStart(Trace.InterruptedIP, IPStart) and
         (IPStart = SpinStart) then
        Inc(InSpin);
      if Trace.LinkFrameUsed and (Length(Trace.Addresses) > 1) and
         ((not KnowsFunctions) or
          (CrashThreadCaptureTestFunctionStart(Trace.InterruptedIP, IPStart) and
           CrashThreadCaptureTestFunctionStart(Trace.Addresses[1], LRStart) and
           (IPStart = LRStart))) then
      begin
        Inc(Stale);
        if not Dumped then
        begin
          DumpCapture(AProgress, 'S8', Worker.CaptureHandle, Trace, SpinStart,
            SpinStart + 1);
          Dumped := True;
        end;
      end;
      TThread.Sleep(3);
    end;
    AProgress.InfoFmt('S8: samples=%d ip-in-SpinFramed=%d lr-used=%d stale=%d',
      [Captured, InSpin, LinkUsed, Stale]);
    {$IF Defined(ANDROID) and Defined(CPUARM64)}
    // Samples inside SpinFramed itself make the check non-vacuous.
    AProgress.Account(KnowsFunctions and (InSpin > 0) and (Stale = 0),
      'S8: busy function that spilled LR: no stale LR frame');
    {$ELSE}
    // Without a function index LR is trusted only in a syscall stub.
    AProgress.Account((Captured > 0) and (LinkUsed = 0),
      'S8: busy function: LR is not used outside a syscall stub');
    {$ENDIF}
  finally
    Worker.ReleaseThread;
    Worker.WaitFor;
    Worker.Free;
  end;
end;

procedure RunCaptureShapeTests(const AProgress: TCrashTestProgress);
begin
  {$IF Defined(CPUARM64)}
  AProgress.Account(CrashThreadCaptureTestPointerAuthStrip,
    'S1: PAC-signed saved LR is stripped and still validated');
  {$ELSE}
  AProgress.Account(CrashThreadCaptureTestPointerAuthStrip,
    'S1: tagged return address stays invalid without pointer auth');
  {$ENDIF}
  AProgress.Account(CrashThreadCaptureTestLinkRegisterRules,
    'S2: LR is a frame only for a thread stopped in a syscall stub');

  if not CrashThreadCaptureAcquire then
  begin
    AProgress.Account(False, 'S3: capture service acquired');
    Exit;
  end;
  try
    RunParkedRound(AProgress, smEvent, 'S3',
      'S3: event waiter: frame records reach the owning Execute',
      'S4: event waiter: the syscall caller comes from LR');
    RunParkedRound(AProgress, smSleep, 'S5',
      'S5: sleeper: frame records reach the owning Execute',
      'S6: sleeper: the syscall caller comes from LR');
    RunBusyLeafRound(AProgress);
    RunBusyFramedRound(AProgress);
  finally
    CrashThreadCaptureRelease;
  end;
end;

{$ENDIF}

class function TCrashCaptureShape_AllInOne.AutoTest(
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
      {$IF Defined(CRASH_CAPTURE_SHAPE_RUNTIME)}
      else
        RunCaptureShapeTests(Progress)
      {$ELSE}
      else
        Progress.Skip('registered-thread capture is unavailable on this target')
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
    'CrashCaptureShape',
    'Crash registered-thread capture: frame records, PAC and syscall LR',
    ['crash', 'thread', 'capture', 'posix', 'linux', 'macos', 'android'],
    TCrashCaptureShape_AllInOne.AutoTest
  );

{$ENDIF}

end.
