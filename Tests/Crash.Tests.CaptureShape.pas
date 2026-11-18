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
//   S9  __unwind_info lookup on a hand-built section
//   S10 macOS: dyld __unwind_info covers this binary's methods with their mode
//   S11 raw stack scan is windowed by the frame-record chain
//   S12 ARM64: no raw frame below the first record once the top owner stored
//       its record (decoder everywhere, live captures on ARM64)

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
  Crash.ThreadCapture.CallSite,
  Crash.ThreadCapture.Trace,
  Crash.Unwind.CompactUnwind,
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
  Payload: TCrashThreadCapturePayload;
  Map: TCrashCodeMap;
  I: Integer;
  Mark: String;
begin
  AProgress.InfoFmt('%s: %s', [ATag,
    CrashThreadCaptureFormatDiagnostics(0, ATrace)]);
  AProgress.InfoFmt('%s: Execute=[$%x,$%x)', [ATag, UInt64(AExecLow),
    UInt64(AExecHigh)]);
  if CrashThreadCaptureTestLastPayload(AHandle, Payload) then
  begin
    Map := CrashCurrentCodeMap;
    AProgress.InfoFmt('%s: ip=%s lr-decision: %s', [ATag,
      DescribeAddress(Payload.InterruptedIP),
      Map.DescribeLinkDecision(Payload.InterruptedIP)]);
    AProgress.InfoFmt('%s: lr=%s check=%s', [ATag,
      DescribeAddress(Payload.InterruptedLR),
      Map.CheckAddress(Payload.InterruptedLR)]);
    AProgress.InfoFmt('%s: sp=$%x fp=$%x raw-words=%d walker-stop=%s',
      [ATag, UInt64(Payload.InterruptedSP), UInt64(Payload.InterruptedFP),
       Payload.RawWordCount,
       CrashThreadCaptureStopReasonText(Payload.StopReason)]);
    for I := 0 to Payload.Count - 1 do
      AProgress.InfoFmt('%s: record %d: %s check=%s', [ATag, I,
        DescribeAddress(Payload.Addrs[I]), Map.CheckAddress(Payload.Addrs[I])]);
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

// No raw candidate before the first frame-record frame.
function NoRawBelowFirstRecord(const ATrace: TCrashThreadRawTrace): Boolean;
var
  I: Integer;
begin
  Result := True;
  for I := 0 to High(ATrace.Sources) do
    case ATrace.Sources[I] of
      tfsFramePointer: Exit;
      tfsRaw: Exit(False);
    end;
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
    {$IF Defined(CPUX64)}
    // A libc built without frame pointers may leave no usable FP at all; the
    // raw scan alone must then reach Execute.
    if Captured and (Trace.FPFrameCount = 0) and (Trace.StopReason in
       [tcsrFramePointerZero, tcsrFramePointerOutside,
        tcsrFramePointerMisaligned]) then
      AProgress.Account(TraceReaches(Trace, ExecLow, ExecHigh),
        AReachDesc + ' (no FP chain: raw scan)')
    else
    {$ENDIF}
    AProgress.Account(Captured and
      FramePointerReaches(Trace, ExecLow, ExecHigh), AReachDesc);
    {$IF Defined(CPUARM64)}
    AProgress.Account(Captured and Trace.LinkFrameUsed and
      (Length(Trace.Sources) > 1) and (Trace.Sources[1] = tfsLink), ALinkDesc);
    AProgress.Account(Captured and NoRawBelowFirstRecord(Trace),
      'S12: ' + ATag + ': no raw frame below the first frame record');
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
    {$IF Defined(CPUARM64)}
    // The leaf keeps no frame record: only LR knows Execute called it.
    AProgress.Account(Captured and Trace.LinkFrameUsed and
      TraceReaches(Trace, ExecLow, ExecHigh),
      'S7: busy frameless leaf: its caller comes from LR');
    // Execute stored its record before calling the leaf: its dead locals
    // below that record are not frames.
    AProgress.Account(Captured and NoRawBelowFirstRecord(Trace),
      'S12: S7: no raw frame below the first frame record');
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
  SpinStart, IPStart, LRStart, RangeStart: UIntPtr;
  I, Captured, InSpin, InFramed, LinkUsed, Stale: Integer;
  Dumped, KnowsFunctions, HasMode, StaleSample: Boolean;
  Encoding: UInt32;
  Map: TCrashCodeMap;
begin
  Map := CrashCurrentCodeMap;
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
    KnowsFunctions := Map.FunctionStart(SpinStart, IPStart) and
      (IPStart = SpinStart);
    TThread.Sleep(PARK_SETTLE_MS);
    Captured := 0;
    InSpin := 0;
    InFramed := 0;
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
         Map.FunctionStart(Trace.InterruptedIP, IPStart) and
         (IPStart = SpinStart) then
        Inc(InSpin);
      HasMode := CrashFindCompactFunctionStart(Map.CompactImages,
        Trace.InterruptedIP, RangeStart, Encoding);
      if HasMode and ((Encoding and CRASH_UNWIND_ARM64_MODE_MASK) =
         CRASH_UNWIND_ARM64_MODE_FRAME) then
        Inc(InFramed);
      if not (Trace.LinkFrameUsed and (Length(Trace.Addresses) > 1)) then
        StaleSample := False
      else if KnowsFunctions then
        StaleSample := Map.FunctionStart(Trace.InterruptedIP, IPStart) and
          Map.FunctionStart(Trace.Addresses[1], LRStart) and
          (IPStart = LRStart)
      else if HasMode then
        // Compact unwind: LR is only legitimate inside a frameless range.
        StaleSample := (Encoding and CRASH_UNWIND_ARM64_MODE_MASK) <>
          CRASH_UNWIND_ARM64_MODE_FRAMELESS
      else
        StaleSample := True;
      if StaleSample then
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
    AProgress.InfoFmt(
      'S8: samples=%d ip-in-SpinFramed=%d ip-in-framed=%d lr-used=%d stale=%d',
      [Captured, InSpin, InFramed, LinkUsed, Stale]);
    {$IF Defined(ANDROID) and Defined(CPUARM64)}
    // Samples inside SpinFramed itself make the check non-vacuous.
    AProgress.Account(KnowsFunctions and (InSpin > 0) and (Stale = 0),
      'S8: busy function that spilled LR: no stale LR frame');
    {$ELSEIF Defined(MACOS) and Defined(CPUARM64)}
    // Compact unwind names no exact function; samples in a FRAME range make
    // the check non-vacuous.
    AProgress.Account((InFramed > 0) and (Stale = 0),
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

type
  TShapeCodeWords = array [0..15] of UInt32;

function SyntheticMap(var ACode: TShapeCodeWords): TCrashCodeMap;
begin
  Result := TCrashCodeMap.ForRange(UIntPtr(@ACode[0]),
    UIntPtr(@ACode[0]) + SizeOf(ACode));
end;

// A saved LR carrying a signature above the user VA and in the top byte.
function PointerAuthStrip: Boolean;
var
  Code: TShapeCodeWords;
  Map: TCrashCodeMap;
  Payload: TCrashThreadCapturePayload;
  Trace: TCrashThreadRawTrace;
  ReturnAddress, Signed: UIntPtr;
begin
  Result := False;
  FillChar(Code, SizeOf(Code), 0);
  Code[3] := $94000000; // BL
  Map := SyntheticMap(Code);
  ReturnAddress := UIntPtr(@Code[4]);
  Signed := ReturnAddress or (UIntPtr($5A) shl 56) or (Map.AddressMask + 1);
  if Signed = ReturnAddress then
    Exit;
  FillChar(Payload, SizeOf(Payload), 0);
  Payload.InterruptedIP := $1234;
  Payload.Count := 1;
  Payload.Addrs[0] := Signed;
  Payload.AddrStackPos[0] := 16;
  Payload.StopReason := tcsrEnd;
  CrashBuildThreadTrace(Payload, True, Map, Trace);
  {$IF Defined(CPUARM64)}
  Result := (Trace.StopReason = tcsrEnd) and (Trace.FPFrameCount = 1) and
    (Length(Trace.Addresses) = 2) and (Trace.Addresses[1] = ReturnAddress) and
    (Trace.Sources[1] = tfsFramePointer);
  {$ELSE}
  // No pointer authentication on x86-64: a tagged value stays invalid.
  Result := (Trace.StopReason = tcsrFrameInvalidCode) and
    (Trace.FPFrameCount = 0) and (Length(Trace.Addresses) = 1);
  {$ENDIF}
end;

// Synthetic code has no FDE, so only the syscall-stub rule applies here.
function LinkRegisterRules: Boolean;
var
  Code: TShapeCodeWords;
  Map: TCrashCodeMap;
  Trace: TCrashThreadRawTrace;
  CallerReturn, AfterSvc: UIntPtr;
  {$IF Defined(CPUARM64)}
  OnSvc, Busy: UIntPtr;
  {$ENDIF}

  function Run(const AIP, ALR, AFPAddress: UIntPtr): Boolean;
  var
    Payload: TCrashThreadCapturePayload;
  begin
    FillChar(Payload, SizeOf(Payload), 0);
    Payload.InterruptedIP := AIP;
    Payload.InterruptedLR := ALR;
    Payload.StopReason := tcsrEnd;
    if AFPAddress <> 0 then
    begin
      Payload.Count := 1;
      Payload.Addrs[0] := AFPAddress;
      Payload.AddrStackPos[0] := 16;
    end;
    CrashBuildThreadTrace(Payload, True, Map, Trace);
    Result := (Length(Trace.Addresses) = Length(Trace.Sources)) and
      (Length(Trace.Addresses) > 0) and (Trace.Addresses[0] = AIP) and
      (Trace.Sources[0] = tfsInterrupted);
  end;

begin
  FillChar(Code, SizeOf(Code), 0);
  Code[2] := $94000000;  // caller: BL stub
  Code[8] := $D4000001;  // stub: SVC #0
  Code[12] := $94000000; // busy code: BL (no SVC around)
  Map := SyntheticMap(Code);
  CallerReturn := UIntPtr(@Code[3]);
  AfterSvc := UIntPtr(@Code[9]);
  {$IF Defined(CPUARM64)}
  OnSvc := UIntPtr(@Code[8]);
  Busy := UIntPtr(@Code[14]);
  Result := False;
  // Stopped right after SVC: LR is the caller frame, signed or not.
  if not (Run(AfterSvc, CallerReturn or (UIntPtr($3C) shl 56), 0) and
     Trace.LinkFrameUsed and (Length(Trace.Addresses) = 2) and
     (Trace.Addresses[1] = CallerReturn) and (Trace.Sources[1] = tfsLink)) then
    Exit;
  // Restarted syscall: the PC is back on the SVC itself.
  if not (Run(OnSvc, CallerReturn, 0) and Trace.LinkFrameUsed) then
    Exit;
  // Outside a syscall stub (and without an FDE) LR may be stale: never used.
  if not (Run(Busy, CallerReturn, 0) and (not Trace.LinkFrameUsed) and
     (Length(Trace.Addresses) = 1)) then
    Exit;
  // LR that does not follow a call is rejected.
  if not (Run(AfterSvc, AfterSvc + 4, 0) and (not Trace.LinkFrameUsed)) then
    Exit;
  // The first frame record repeating LR is not listed twice.
  Result := Run(AfterSvc, CallerReturn, CallerReturn) and
    Trace.LinkFrameUsed and (Length(Trace.Addresses) = 2) and
    (Trace.FPFrameCount = 0);
  {$ELSE}
  Result := Run(AfterSvc, CallerReturn, 0) and
    (not Trace.LinkFrameUsed) and (Length(Trace.Addresses) = 1);
  {$ENDIF}
end;

// Raw words share the stack with two frame records: only the one below the
// first record survives, and the one above the last only when the chain broke.
function RawScanWindow: Boolean;
const
  BASE = UIntPtr($1000);
  W = SizeOf(Pointer);
var
  {$IF Defined(CPUX64)}
  Code: array [0..255] of Byte;
  RelativeTarget: Int32;
  {$ELSE}
  Code: array [0..31] of UInt32;
  {$ENDIF}
  Map: TCrashCodeMap;
  Sites: array [0..4] of UIntPtr; // A below, F0/F1 records, B inner, C above
  Payload: TCrashThreadCapturePayload;
  Trace: TCrashThreadRawTrace;
  K: Integer;

  function Build(const ACount: Integer;
    const AStop: TCrashThreadCaptureStopReason): Boolean;
  begin
    FillChar(Payload, SizeOf(Payload), 0);
    Payload.InterruptedIP := $1234;
    Payload.Count := ACount;
    Payload.Addrs[0] := Sites[1];
    Payload.AddrStackPos[0] := BASE + 3 * W;
    Payload.Addrs[1] := Sites[2];
    Payload.AddrStackPos[1] := BASE + 7 * W;
    Payload.RawBaseSP := BASE;
    Payload.RawWordCount := 10;
    Payload.RawWords[1] := Sites[0];
    Payload.RawWords[3] := Sites[1];
    Payload.RawWords[5] := Sites[3];
    Payload.RawWords[9] := Sites[4];
    Payload.StopReason := AStop;
    CrashBuildThreadTrace(Payload, True, Map, Trace);
    Result := (Length(Trace.Addresses) = Length(Trace.Sources)) and
      (Length(Trace.Addresses) > 0) and (Trace.Addresses[0] = $1234);
  end;

  function FrameIs(const AIndex: Integer; const AAddress: UIntPtr;
    const ASource: TCrashThreadFrameSource): Boolean;
  begin
    Result := (AIndex < Length(Trace.Addresses)) and
      (Trace.Addresses[AIndex] = AAddress) and (Trace.Sources[AIndex] = ASource);
  end;

begin
  Result := False;
  FillChar(Code, SizeOf(Code), 0);
  Map := TCrashCodeMap.ForRange(UIntPtr(@Code[0]),
    UIntPtr(@Code[0]) + SizeOf(Code));
  for K := 0 to High(Sites) do
  begin
    {$IF Defined(CPUX64)}
    Sites[K] := UIntPtr(@Code[16 * (K + 1)]);
    Code[16 * (K + 1) - 5] := $E8;
    RelativeTarget := Int32(Int64(UIntPtr(@Code[240])) - Int64(Sites[K]));
    Move(RelativeTarget, Code[16 * (K + 1) - 4], SizeOf(RelativeTarget));
    {$ELSE}
    Code[4 * K + 3] := $94000000; // BL
    Sites[K] := UIntPtr(@Code[4 * K + 4]);
    {$ENDIF}
    if not Map.CallSiteIsValid(Sites[K]) then
      Exit;
  end;

  // Complete chain: the inner and the upper raw word are dead locals.
  if not (Build(2, tcsrEnd) and (Length(Trace.Addresses) = 4) and
     FrameIs(1, Sites[0], tfsRaw) and FrameIs(2, Sites[1], tfsFramePointer) and
     FrameIs(3, Sites[2], tfsFramePointer) and (Trace.RawFrameCount = 1) and
     (Trace.RawDroppedCount = 2)) then
    Exit;
  // Broken chain: the raw scan continues above its last record.
  if not (Build(2, tcsrFramePointerOutside) and
     (Length(Trace.Addresses) = 5) and FrameIs(1, Sites[0], tfsRaw) and
     FrameIs(4, Sites[4], tfsRaw) and (Trace.RawDroppedCount = 1)) then
    Exit;
  // No records at all: every raw word is all there is.
  Result := Build(0, tcsrFramePointerZero) and
    (Length(Trace.Addresses) = 5) and (Trace.RawFrameCount = 4) and
    (Trace.RawDroppedCount = 0) and FrameIs(3, Sites[3], tfsRaw);
end;

function FrameRecordDecoder: Boolean;
begin
  Result :=
    CrashARM64InstructionStoresFrameRecord($A9BF7BFD) and     // stp x29, x30, [sp, #-16]!
    CrashARM64InstructionStoresFrameRecord($A9017BFD) and     // stp x29, x30, [sp, #16]
    not CrashARM64InstructionStoresFrameRecord($A9BF7BF3) and // stp x19, x30, [sp, #-16]!
    not CrashARM64InstructionStoresFrameRecord($A9BF77FD) and // stp x29, x29, [sp, #-16]!
    not CrashARM64InstructionStoresFrameRecord($A9BF7A7D) and // stp x29, x30, [x19, #-16]!
    not CrashARM64InstructionStoresFrameRecord($A8C17BFD) and // ldp x29, x30, [sp], #16
    not CrashARM64InstructionStoresFrameRecord($F81F0FFE);    // str x30, [sp, #-16]!
end;

procedure PutU16(var ABuf: TBytes; const AOffset: Integer; const AValue: UInt16);
begin
  Move(AValue, ABuf[AOffset], SizeOf(AValue));
end;

procedure PutU32(var ABuf: TBytes; const AOffset: Integer; const AValue: UInt32);
begin
  Move(AValue, ABuf[AOffset], SizeOf(AValue));
end;

// A hand-built __unwind_info: one regular page (with a gap entry) and one
// compressed page using a common and a page-local encoding.
function CompactUnwindLookup: Boolean;
const
  BASE = UIntPtr($10000000);
var
  Buf: TBytes;
  Images: TCrashCompactUnwindImages;
  Start: UIntPtr;
  Encoding: UInt32;

  function Expect(const AOffset: UIntPtr; const AStart: UIntPtr;
    const AEncoding: UInt32): Boolean;
  begin
    Result := CrashFindCompactFunctionStart(Images, BASE + AOffset, Start,
      Encoding) and (Start = BASE + AStart) and (Encoding = AEncoding);
  end;

  function Missing(const AOffset: UIntPtr): Boolean;
  begin
    Result := not CrashFindCompactFunctionStart(Images, BASE + AOffset, Start,
      Encoding);
  end;

begin
  SetLength(Buf, 124);
  FillChar(Buf[0], Length(Buf), 0);
  // Header: version, common encodings @28 x1, personalities @32 x0, index @32 x3.
  PutU32(Buf, 0, 1);
  PutU32(Buf, 4, 28);
  PutU32(Buf, 8, 1);
  PutU32(Buf, 12, 32);
  PutU32(Buf, 16, 0);
  PutU32(Buf, 20, 32);
  PutU32(Buf, 24, 3);
  PutU32(Buf, 28, CRASH_UNWIND_ARM64_MODE_FRAME);
  // First level: $1000 -> regular page @68, $2000 -> compressed page @100,
  // sentinel $3000.
  PutU32(Buf, 32, $1000);
  PutU32(Buf, 36, 68);
  PutU32(Buf, 44, $2000);
  PutU32(Buf, 48, 100);
  PutU32(Buf, 56, $3000);
  // Regular page: entries @+8: $1000 frameless, $1100 frame, $1180 no info.
  PutU32(Buf, 68, 2);
  PutU16(Buf, 72, 8);
  PutU16(Buf, 74, 3);
  PutU32(Buf, 76, $1000);
  PutU32(Buf, 80, CRASH_UNWIND_ARM64_MODE_FRAMELESS);
  PutU32(Buf, 84, $1100);
  PutU32(Buf, 88, CRASH_UNWIND_ARM64_MODE_FRAME);
  PutU32(Buf, 92, $1180);
  PutU32(Buf, 96, 0);
  // Compressed page: entries @+12, page encodings @+20 (one).
  PutU32(Buf, 100, 3);
  PutU16(Buf, 104, 12);
  PutU16(Buf, 106, 2);
  PutU16(Buf, 108, 20);
  PutU16(Buf, 110, 1);
  PutU32(Buf, 112, $000000);           // +$000, common encoding 0
  PutU32(Buf, 116, $400 or (1 shl 24)); // +$400, page-local encoding
  PutU32(Buf, 120, CRASH_UNWIND_ARM64_MODE_FRAMELESS or $1000);

  SetLength(Images, 1);
  Images[0].LowAddress := BASE + $1000;
  Images[0].HighAddress := BASE + $3000;
  Images[0].ImageBase := BASE;
  Images[0].UnwindInfo := UIntPtr(@Buf[0]);
  Images[0].UnwindInfoSize := Length(Buf);

  Result :=
    Expect($1050, $1000, CRASH_UNWIND_ARM64_MODE_FRAMELESS) and
    Expect($1100, $1100, CRASH_UNWIND_ARM64_MODE_FRAME) and
    Missing($1190) and
    Expect($2300, $2000, CRASH_UNWIND_ARM64_MODE_FRAME) and
    Expect($2500, $2400, CRASH_UNWIND_ARM64_MODE_FRAMELESS or $1000) and
    Missing($0FFF) and Missing($3000);
  if not Result then
    Exit;
  // A section cut short must fail the lookup, never read past it.
  Images[0].UnwindInfoSize := 90;
  Result := Missing($1050) or (Start = BASE + $1000);
  Images[0].UnwindInfoSize := 70;
  Result := Result and Missing($1050);
end;

{$IF Defined(MACOS)}
// The real __unwind_info of this binary, found through dyld: every known
// method lies in an entry (a range that may also hold earlier functions with
// the same encoding), and that entry carries the frame mode Delphi emits.
function CompactUnwindRealImage(const AProgress: TCrashTestProgress): Boolean;
var
  Images: TCrashCompactUnwindImages;
  Methods: array [0..2] of UIntPtr;
  Start, InnerStart: UIntPtr;
  Encoding, InnerEncoding, Mode: UInt32;
  I: Integer;
  ModeOK: Boolean;
begin
  Images := CrashEnumerateCompactUnwindImages;
  AProgress.InfoFmt('S10: dyld images with __unwind_info: %d', [Length(Images)]);
  Result := Length(Images) > 0;
  Methods[0] := UIntPtr(@TShapeWorker.Execute);
  Methods[1] := UIntPtr(@TShapeWorker.SpinBusy);
  Methods[2] := UIntPtr(@TShapeWorker.SpinFramed);
  for I := 0 to High(Methods) do
  begin
    if not (CrashFindCompactFunctionStart(Images, Methods[I], Start, Encoding) and
       CrashFindCompactFunctionStart(Images, Methods[I] + 4, InnerStart,
         InnerEncoding)) then
    begin
      AProgress.InfoFmt('S10: method %d at $%x: no entry', [I, UInt64(Methods[I])]);
      Result := False;
      Continue;
    end;
    Mode := Encoding and CRASH_UNWIND_ARM64_MODE_MASK;
    {$IF Defined(CPUX64)}
    ModeOK := Mode = $01000000; // UNWIND_X86_64_MODE_RBP_FRAME
    {$ELSE}
    ModeOK := (Mode = CRASH_UNWIND_ARM64_MODE_FRAME) or
      (Mode = CRASH_UNWIND_ARM64_MODE_FRAMELESS);
    {$ENDIF}
    AProgress.InfoFmt('S10: method %d at $%x: entry=$%x (-$%x) encoding=$%.8x',
      [I, UInt64(Methods[I]), UInt64(Start), UInt64(Methods[I] - Start), Encoding]);
    if not ((Start <= Methods[I]) and (InnerStart = Start) and
       (InnerEncoding = Encoding) and ModeOK) then
      Result := False;
  end;
end;
{$ENDIF}

procedure RunCaptureShapeTests(const AProgress: TCrashTestProgress);
begin
  AProgress.Account(CompactUnwindLookup,
    'S9: __unwind_info lookup: regular/compressed pages, gaps, bounds');
  {$IF Defined(MACOS)}
  AProgress.Account(CompactUnwindRealImage(AProgress),
    'S10: dyld __unwind_info covers this binary''s methods with their frame mode');
  {$ENDIF}
  {$IF Defined(CPUARM64)}
  AProgress.Account(PointerAuthStrip,
    'S1: PAC-signed saved LR is stripped and still validated');
  {$ELSE}
  AProgress.Account(PointerAuthStrip,
    'S1: tagged return address stays invalid without pointer auth');
  {$ENDIF}
  AProgress.Account(LinkRegisterRules,
    'S2: LR is a frame only for a thread stopped in a syscall stub');
  AProgress.Account(RawScanWindow,
    'S11: raw scan stays below the first frame record unless the chain broke');
  AProgress.Account(FrameRecordDecoder,
    'S12: ARM64 frame-record store decoder (stp x29, x30 to sp)');

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
