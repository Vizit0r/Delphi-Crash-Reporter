unit Crash.Tests.Freeze;

// ===========================================================================
//  Crash.Freeze - the freeze (hang) detector. Report-only, off by default.
//
//  Observables (each defence has its own step):
//    A0  Shutdown stops a watchdog the host installed (it watches the main
//        thread); Install then re-arms on the test's OWN thread
//    A1  BeginLongOperation mutes detection (a block longer than the timeout
//        is not captured); A1b/A1c - SetSuspended (mobile background): an
//        idempotent flag mutes the span, and clearing it re-stamps the
//        heartbeat (no false report in the window between the wake-up and the
//        first tick of the ping timer)
//    A2  a blocked thread is caught: EFrozenApplication, duration >= the
//        timeout, the frozen thread's stack names the beacon routine
//    A3  once pings resume the watchdog re-arms (second episode)
//    A4  the report gate is released BEFORE OnCapture: a concurrent crash in
//        the formatting/upload window keeps its report (single-flight flag free)
//    A6  a stop of the WHOLE process (the watchdog overslept the timeout) is a
//        grace, not a freeze; A6b - after such a pause the detector still
//        catches an episode; A6c - pings from another thread (a host UI
//        timer) do not mask a freeze of the watched thread
//    A5  a host-owned signal is never taken: Linux/Android - the detector arms on the
//        next free one (the foreign handler survives, Shutdown returns SIG_DFL
//        to the signal it took), macOS - an occupied SIGUSR2 is a diagnosed
//        Install refusal
//    B*  end-to-end through the reporter (enabled as a host would):
//        EnableFreezeDetection -> .el on disk (EFrozenApplication + the
//        Freeze Info section)
//    C*  the RestartOnFreeze contract without the restart itself (it replaces
//        the process; Demo/CrashDemo --freeze is the live run): the notice file
//        lies outside the *.el boot scan + roundtrip, the loop-guard env mark
//        (set/consume), spawn confirmation catches an execv failure (C6), the
//        replacement inherits no fd (C7), fail-closed without a pipe (C8), the
//        sweep fallbacks mark a live fd (C9, in a forked child), a finite
//        rlim_cur is passed without a cap and infinity/overflow fail closed
//        (C10)
//    D*  freeze BugID normalization (synthetic): a sample at a different depth
//        gives one ID, another call path another ID, exception grouping is
//        untouched; D5 - the Android shape (.so + empty ParamStr(0)) by address
//
//  The test watches its OWN thread: Install arms on the calling thread and the
//  beacon blocks that same thread with a busy loop. Fresh .el files are removed
//  in finally - otherwise the next run's boot recovery would pick them up as
//  pending crash reports.
//
//  Outside Linux x64 / Android ARM64 / macOS - SKIP (the detector compiles to
//  stubs there).
//
//  Copyright (c) 2026 Vizit0r. BSD 2-Clause license (see LICENSE.txt).
// ===========================================================================

interface

{$IFDEF AUTOTESTS}

uses
  System.SysUtils,
  Crash.Tests.Registry;

type
  TCrashFreeze_AllInOne = class
  public
    class function AutoTest(out OutLines: TArray<string>): Boolean; static;
  end;

{$ENDIF}

implementation

{$IF (Defined(LINUX) and Defined(CPUX64)) or
     (Defined(ANDROID) and Defined(CPUARM64)) or
     (Defined(MACOS64) and not Defined(IOS))}
  {$DEFINE CRASH_TEST_FREEZE}
{$ENDIF}
{$IF Defined(LINUX) or Defined(ANDROID)}
  {$DEFINE CRASH_TEST_LINUXLIKE}
{$ENDIF}

{$IFDEF AUTOTESTS}

uses
  System.Classes,
  System.SyncObjs,
  System.IOUtils,
  System.Generics.Collections,
  {$IFDEF CRASH_TEST_FREEZE}
  Posix.Base,
  Posix.Signal,
  Posix.Pthread,
  Posix.SysTypes,
  Posix.Unistd,
  Posix.Fcntl,
  Posix.Errno,
  Posix.SysWait,
  {$IF Defined(ANDROID)}
  Posix.String_, // expands the inline sigemptyset
  {$ENDIF}
  Crash.CallStack,
  Crash.ELFormat,
  Crash.Freeze,
  Crash.Signals,
  Crash.ThreadCapture,
  Crash.Reporter,
  {$ENDIF}
  Crash.Tests.Progress;

const
  TEST_NAME = 'CrashFreeze';

{$IFDEF CRASH_TEST_FREEZE}

const
  C_TIMEOUT_MS = 1500; // detection timeout in the test
  C_BLOCK_MS   = 4000; // artificial block (> timeout + watchdog quantum)
  C_POLL_MS    = 5000; // ceiling for waiting on asynchronous observables
  C_STALL_MS   = 3000; // A6: added to the watchdog's sleep (> timeout)
  {$IF Defined(ANDROID)}
  C_BIN_DIR    = '/system/bin/';
  {$ELSE}
  C_BIN_DIR    = '/bin/';
  {$ENDIF}

var
  GCapturedFlag:   Integer = 0;
  GCapturedReport: TCrashReport; // valid only while GCapturedFlag=1
  GCapturedForMS:  Int64 = 0;
  GGateFreeInCapture: Integer = 0; // A4: report gate free inside OnCapture
  GForeignPingStop: Integer = 0;   // A6c: stops the foreign pinger

{$IFDEF CRASH_TEST_LINUXLIKE}
// The same signal choice as Crash.Freeze (contract: rtmin+5).
function __libc_current_sigrtmin: Integer; cdecl;
  external libc name _PU + '__libc_current_sigrtmin';
{$ENDIF}

// C9 runs the sweep fallbacks in a forked child - the parent's fd table is
// left alone.
function fork: pid_t; cdecl; external libc name _PU + 'fork';
function TestPThreadSigMask(AHow: Integer; ASet, AOldSet: Psigset_t): Integer; cdecl;
  external libc name _PU + 'pthread_sigmask';

type
  // struct rlimit for C8 (the RTL has no Posix.SysResource).
  TTestRLimit = record
    rlim_cur: UInt64;
    rlim_max: UInt64;
  end;

  TCaptureStressTarget = class(TThread)
  private
    FBusy: Boolean;
    FReady: Integer;
    FStopRequested: Integer;
    FRegistrationOK: Boolean;
    FSignalMaskOK: Boolean;
    FHandle: TCrashThreadCaptureHandle;
    FNativeIdentity: TCrashThreadNativeIdentity;
    FReRegisterRequested: Integer;
    FReRegisterDone: Integer;
    FReRegistrationOK: Boolean;
    FSpinValue: UInt64;
  protected
    procedure Execute; override;
  public
    constructor Create(const ABusy: Boolean);
    function IsReady: Boolean;
    function IsReRegisterDone: Boolean;
    procedure RequestReRegister;
    procedure RequestStop;
    property CaptureHandle: TCrashThreadCaptureHandle read FHandle;
    property NativeIdentity: TCrashThreadNativeIdentity read FNativeIdentity;
    property RegistrationOK: Boolean read FRegistrationOK;
    property ReRegistrationOK: Boolean read FReRegistrationOK;
    property SignalMaskOK: Boolean read FSignalMaskOK;
  end;

const
  TEST_RLIMIT_NOFILE = {$IF Defined(MACOS)} 8 {$ELSE} 7 {$ENDIF};

function getrlimit(resource: Integer; var rlp: TTestRLimit): Integer; cdecl;
  external libc name _PU + 'getrlimit';
// var, not const: a cdecl const record on Linux x64 travels by value in
// registers (C struct ABI) while libc expects a pointer - that gives EFAULT.
function setrlimit(resource: Integer; var rlp: TTestRLimit): Integer; cdecl;
  external libc name _PU + 'setrlimit';

constructor TCaptureStressTarget.Create(const ABusy: Boolean);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FBusy := ABusy;
  Start;
end;

procedure TCaptureStressTarget.Execute;
var
  ReplacementHandle: TCrashThreadCaptureHandle;
  I: Integer;
begin
  FHandle := nil;
  FRegistrationOK := CrashThreadCaptureRegisterCurrentThread(FHandle);
  FNativeIdentity := CrashCurrentThreadNativeIdentity;
  TInterlocked.Exchange(FReady, 1);
  try
    while TInterlocked.CompareExchange(FStopRequested, 0, 0) = 0 do
    begin
      if (TInterlocked.CompareExchange(FReRegisterRequested, 0, 0) <> 0) and
         (TInterlocked.CompareExchange(FReRegisterDone, 0, 0) = 0) then
      begin
        ReplacementHandle := nil;
        FReRegistrationOK :=
          CrashThreadCaptureRegisterCurrentThread(ReplacementHandle);
        if FReRegistrationOK then
        begin
          FHandle := ReplacementHandle;
          FNativeIdentity := CrashCurrentThreadNativeIdentity;
        end;
        TInterlocked.Exchange(FReRegisterDone, 1);
      end;
      if FBusy then
      begin
        for I := 1 to 4096 do
          FSpinValue := (FSpinValue shl 1) xor UInt64(I);
      end
      else
        TThread.Sleep(2);
    end;
  finally
    FSignalMaskOK := FRegistrationOK and
      (not CrashThreadCaptureCurrentSignalBlocked);
    CrashThreadCaptureUnregisterCurrentThread(FHandle);
  end;
end;

function TCaptureStressTarget.IsReRegisterDone: Boolean;
begin
  Result := TInterlocked.CompareExchange(FReRegisterDone, 0, 0) <> 0;
end;

procedure TCaptureStressTarget.RequestReRegister;
begin
  TInterlocked.Exchange(FReRegisterRequested, 1);
end;

function TCaptureStressTarget.IsReady: Boolean;
begin
  Result := TInterlocked.CompareExchange(FReady, 0, 0) <> 0;
end;

procedure TCaptureStressTarget.RequestStop;
begin
  TInterlocked.Exchange(FStopRequested, 1);
end;

procedure TestPrevSigactionHandler(SigNum: Integer; SigInfo: Psiginfo_t;
  Context: Pointer); cdecl;
// A5: a "foreign" handler that owned the signal BEFORE Install. Empty body -
// only its address matters (the observable of the restored disposition).
begin
end;

function TestReportDir: String;
// Where the reporter writes .el files (on mobile the exe dir is read-only).
begin
  if TCrashReporter.Active then
    Exit(ExtractFilePath(TCrashReporter.RestartNoticeFilePath));
  {$IF Defined(ANDROID)}
  Result := IncludeTrailingPathDelimiter(TPath.GetDocumentsPath);
  {$ELSE}
  Result := ExtractFilePath(ParamStr(0));
  {$ENDIF}
end;

function MakeFrame(const AModule, ARoutine: String;
  ARoutineAddr, AModuleAddr, AOffset: UIntPtr): TCrashStackEntry;
// D*: a synthetic frame for the BugID normalization checks. An app frame is
// identified by the module ADDRESS (TCrashCapture.MainModuleAddress), as in
// production.
begin
  Result.Clear;
  Result.ModuleName := AModule;
  Result.RoutineName := ARoutine;
  Result.RoutineAddress := ARoutineAddr;
  Result.CodeAddress := ARoutineAddr + AOffset;
  Result.ModuleAddress := AModuleAddr;
end;

function MakeFreezeReport(const AStack: TCrashStack): TCrashReport;
begin
  Result := Default(TCrashReport);
  Result.IsFreeze := True;
  Result.ExceptionClassName := 'EFrozenApplication';
  Result.CallStack := AStack;
  if Length(AStack) > 0 then
    Result.ExceptionLocation := AStack[0]
  else
    Result.ExceptionLocation.Clear;
end;

procedure Step_D_FreezeBugID(Progress: TCrashTestProgress);
// One logical freeze sampled at different points (vDSO/libc above the RTL
// wrapper, inside the RTL wrapper, right in the loop) gives one ID; another
// call path gives another ID; plain exception grouping is untouched; the
// Android shape (app code in a .so, empty ParamStr(0)) is recognized by the
// module address.
const
  LIBC = '/usr/lib/x86_64-linux-gnu/libc.so.6';
  LIBC_BASE = UIntPtr($700000); // surely not the main module
var
  Exe: String;
  MainMod: UIntPtr;
  R1, R2, R3, R4, R5a, R5b, R6, R7a, R7b: TCrashReport;
  ID1, ID2, ID3, ID4, ID6: String;
begin
  Exe := ParamStr(0);
  MainMod := TCrashCapture.MainModuleAddress;
  if MainMod = 0 then
  begin
    Progress.Skip('D*: TCrashCapture is not initialized (no main module base)');
    Exit;
  end;
  // Sampled in libc above the RTL wrapper above the loop.
  R1 := MakeFreezeReport([
    MakeFrame(LIBC, 'clock_gettime', $7000, LIBC_BASE, $1A),
    MakeFrame(Exe, 'Classes.TThread.GetTickCount64', $5000, MainMod, $2F),
    MakeFrame(Exe, 'Hostapp.MainLoop', $3000, MainMod, $812),
    MakeFrame(Exe, 'Hostapp.Run', $1000, MainMod, $40)]);
  // Sampled in the RTL wrapper (another offset, no libc frame).
  R2 := MakeFreezeReport([
    MakeFrame(Exe, 'Classes.TThread.GetTickCount64', $5000, MainMod, $11),
    MakeFrame(Exe, 'Hostapp.MainLoop', $3000, MainMod, $812),
    MakeFrame(Exe, 'Hostapp.Run', $1000, MainMod, $40)]);
  // Sampled right in the loop (a third offset, no RTL frame at all).
  R3 := MakeFreezeReport([
    MakeFrame(Exe, 'Hostapp.MainLoop', $3000, MainMod, $80B),
    MakeFrame(Exe, 'Hostapp.Run', $1000, MainMod, $40)]);
  // The same loop, but another call site in the caller.
  R4 := MakeFreezeReport([
    MakeFrame(Exe, 'Hostapp.MainLoop', $3000, MainMod, $80B),
    MakeFrame(Exe, 'Hostapp.Run', $1000, MainMod, $55)]);

  ID1 := CrashGenerateExceptionID(R1);
  ID2 := CrashGenerateExceptionID(R2);
  ID3 := CrashGenerateExceptionID(R3);
  ID4 := CrashGenerateExceptionID(R4);
  Progress.Account((ID1 = ID2) and (ID2 = ID3),
    'D1: one hang sampled at three depths yields one BugID');
  Progress.Account(ID4 <> ID3,
    'D2: a different call path yields a different BugID');

  // The exception path (IsFreeze=False) is untouched: an exception has a fixed
  // raise point, and by contract a varying top frame splits the ID.
  R5a := R2;
  R5a.IsFreeze := False;
  R5b := R3;
  R5b.IsFreeze := False;
  Progress.Account(CrashGenerateExceptionID(R5a) <> CrashGenerateExceptionID(R5b),
    'D3: plain exception grouping is untouched by the freeze normalization');

  // Empty stack (capture failed): its own stable bucket.
  R6 := MakeFreezeReport(nil);
  ID6 := CrashGenerateExceptionID(R6);
  Progress.Account((ID6 <> '') and (ID6 = CrashGenerateExceptionID(R6)) and (ID6 <> ID3),
    'D4: stackless freeze falls into its own stable bucket');

  // D5: the Android shape - the module name does NOT match the exe (app code
  // lives in a .so, and ParamStr(0) is empty there), but ModuleAddress is the
  // main module base. Frames must be recognized as app frames BY ADDRESS: a
  // libc sample and a loop sample give one ID (the anchor path, not the
  // foreign fallback - that one keys on the top frame and would split them).
  R7a := MakeFreezeReport([
    MakeFrame(LIBC, 'clock_gettime', $7000, LIBC_BASE, $1A),
    MakeFrame('libHostApp.so', 'Hostapp.MainLoop', $3000, MainMod, $812),
    MakeFrame('libHostApp.so', 'Hostapp.Run', $1000, MainMod, $40)]);
  R7b := MakeFreezeReport([
    MakeFrame('libHostApp.so', 'Hostapp.MainLoop', $3000, MainMod, $80B),
    MakeFrame('libHostApp.so', 'Hostapp.Run', $1000, MainMod, $40)]);
  Progress.Account(CrashGenerateExceptionID(R7a) = CrashGenerateExceptionID(R7b),
    'D5: app frames are recognized by module address (the Android .so shape)');
end;

procedure FreezeBeacon_BusyBlock(const ADurationMS: Int64);
// Beacon: "hangs" the calling thread with a busy loop (no Sleep, no ping). The
// routine name is the A2 observable: the test looks for it in the stack.
var
  Deadline: UInt64;
begin
  Deadline := TThread.GetTickCount64 + UInt64(ADurationMS);
  while TThread.GetTickCount64 < Deadline do
    ;
end;

function StartForeignPinger: TThread;
// A6c: pings from a thread other than the watched one, as a host UI timer does.
begin
  TInterlocked.Exchange(GForeignPingStop, 0);
  Result := TThread.CreateAnonymousThread(
    procedure
    begin
      while TInterlocked.CompareExchange(GForeignPingStop, 0, 0) = 0 do
      begin
        TCrashFreeze.Ping;
        TThread.Sleep(50);
      end;
    end);
  Result.FreeOnTerminate := False;
  Result.Start;
end;

function MainCaptureSlotEntry: String;
// The test slot-summary entry for the main thread ('' = no slot).
var
  Entry, Key: String;
begin
  Result := '';
  Key := '/p' + IntToHex(UInt64(MainThreadID), 1) + '/k';
  for Entry in CrashThreadCaptureTestLiveSlotSummary.Split([';']) do
    if Pos(Key, Entry) > 0 then
      Exit(Entry.Trim);
end;

function FlagIsSet(var AFlag: Integer): Boolean;
begin
  Result := TInterlocked.CompareExchange(AFlag, 0, 0) <> 0;
end;

function WaitForFlag(var AFlag: Integer; ATimeoutMS: Integer): Boolean;
var
  Deadline: UInt64;
begin
  Deadline := TThread.GetTickCount64 + UInt64(ATimeoutMS);
  while (not FlagIsSet(AFlag)) and (TThread.GetTickCount64 < Deadline) do
    Sleep(20);
  Result := FlagIsSet(AFlag);
end;

function StackHasRoutine(const AStack: TCrashStack; const ANamePart: String): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(AStack) do
    if Pos(ANamePart, AStack[I].RoutineName) > 0 then
      Exit(True);
  Result := False;
end;

function CountExeFrames(const AStack: TCrashStack): Integer;
// How many frames landed in OUR executable module (by the dladdr file name).
var
  ExeName: String;
  I: Integer;
begin
  Result := 0;
  ExeName := ExtractFileName(ParamStr(0));
  for I := 0 to High(AStack) do
    if Pos(ExeName, AStack[I].ModuleName) > 0 then
      Inc(Result);
end;

function DiffNewFiles(const ABefore, AAfter: TArray<String>): TArray<String>;
var
  L: TList<String>;
  S, T: String;
  Known: Boolean;
begin
  L := TList<String>.Create;
  try
    for S in AAfter do
    begin
      Known := False;
      for T in ABefore do
        if SameFileName(S, T) then
        begin
          Known := True;
          Break;
        end;
      if not Known then
        L.Add(S);
    end;
    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

class function TCrashFreeze_AllInOne.AutoTest(out OutLines: TArray<string>): Boolean;
var
  Lines: TList<string>;
  Progress: TCrashTestProgress;
  SavedCapture: TCrashFreezeCaptureEvent;
  SavedSuppress: TFunc<Boolean>;
  ReportDir, FoundFile, ElText, S: String;
  NoticePath, TmpNoticePath: String;
  WrittenN, ReadN: TCrashRestartNotice;
  ElBefore, NewEl: TArray<String>;
  StepOk: Boolean;
  MaskInstalled, TimeoutReportOk: Boolean;
  Deadline: UInt64;
  I: Integer;
  TestSig: Integer;
  CaptureSig: Integer;
  PrevAct, CurAct: sigaction_t;
  CaptureMask, SavedMask: TCrashSigSet;
  CaptureHandle: TCrashThreadCaptureHandle;
  NativeIdentity: TCrashThreadNativeIdentity;
  CollisionIdentity: TCrashThreadNativeIdentity;
  StressCPU, StressSleep: TCaptureStressTarget;
  CollisionTarget: TCaptureStressTarget;
  StressTrace: TCrashThreadRawTrace;
  OldCollisionHandle: TCrashThreadCaptureHandle;
  SelfQuarantineHandle, SelfQuarantineRepeat: TCrashThreadCaptureHandle;
  StressReady, StressMaskOK: Boolean;
  StressCaptured: Integer;
  CollisionCleanupOK: Boolean;
  HostExtendedEnabled: Boolean;
  ProductFreezeWasActive, MainSharesSlot: Boolean;
  DiagRegs, DiagInfo: String;
  DiagIP: UIntPtr;
  DiagLoc: TCrashStack;
  BaselineLiveSlots: Integer;
  LeakFds: TPipeDescriptors;
  LeakByte: Byte;
  NRead: ssize_t;
  SavedRLim, TightRLim: TTestRLimit;
  SweepChild: pid_t;
  SweepVerdict, WStatus: Integer;
  ForeignPinger: TThread;
begin
  Lines := TList<string>.Create;
  Progress := TCrashTestProgress.Create(Lines);
  try
    SavedCapture := TCrashFreeze.OnCapture;
    SavedSuppress := TCrashFreeze.OnExternalSuppress;
    ReportDir := TestReportDir;
    ElBefore := TDirectory.GetFiles(ReportDir, '*.el');
    HostExtendedEnabled := TCrashReporter.GetStatus.ExtendedThreadsEnabled;
    try
      // A0: a host may already have armed the detector on the MAIN thread; for
      // an isolated check it is shut down here and re-armed on our OWN thread
      // below. Observable: Shutdown really stops the watchdog. Shutdown runs on
      // the owner (main) thread: its capture slot is shared with the MAIN
      // coverage registration, and releasing it from another thread would
      // quarantine the whole slot.
      ProductFreezeWasActive := TCrashFreeze.Active;
      MainSharesSlot :=
        TCrashReporter.GetStatus.MainThread.ExtendedCaptureAvailable;
      if ProductFreezeWasActive then
        TThread.Synchronize(nil,
          procedure
          begin
            TCrashFreeze.Shutdown;
          end);
      Progress.Account(not TCrashFreeze.Active, 'A0: Shutdown leaves no active watchdog');
      // MAIN slot: with coverage - Idle with one reference (state1 = SLOT_IDLE),
      // without coverage - released.
      S := MainCaptureSlotEntry;
      if MainSharesSlot then
        StepOk := Pos('=state1/ref1/', S) > 0
      else
        StepOk := S = '';
      if not StepOk then
        Progress.Info('A0s MAIN slot: ' + S);
      Progress.Account(StepOk,
        'A0s: owner-thread Shutdown keeps the shared MAIN capture slot live');
      BaselineLiveSlots := CrashThreadCaptureTestLiveSlotCount;
      Progress.Account(
        (HostExtendedEnabled and (BaselineLiveSlots > 0)) or
        ((not HostExtendedEnabled) and (BaselineLiveSlots = 0)),
        'A0a: isolated Freeze setup preserves the configured capture baseline');

      TInterlocked.Exchange(GCapturedFlag, 0);
      TCrashFreeze.OnExternalSuppress := nil;
      TCrashFreeze.OnCapture :=
        procedure(const AReport: TCrashReport; const AFrozenForMS: Int64)
        begin
          GCapturedReport := AReport;
          GCapturedForMS := AFrozenForMS;
          TInterlocked.Exchange(GCapturedFlag, 1);
        end;

      TCrashFreeze.Install(C_TIMEOUT_MS);
      Progress.Account(TCrashFreeze.Active, 'A0b: Install arms the watchdog');
      CaptureSig := CrashThreadCaptureSignalNumber;
      Progress.Account(CaptureSig > 0,
        'A0c: common thread-capture service publishes its signal');

      // Late acquire: Crash handlers were installed by CrashSetup before this
      // test recreated the freeze detector. Re-install must put the newly
      // selected capture signal into the central fault-handler mask.
      if CrashSignalHandlersInstalled then
      begin
        FillChar(CurAct, SizeOf(CurAct), 0);
        StepOk := (sigaction(SIGSEGV, nil, @CurAct) = 0) and
          CrashSigSetHas(CurAct.sa_mask, CaptureSig);
        if not StepOk then
        begin
          Progress.InfoFmt('A0d diag: sig=%d flags=$%x handler=%p pending-snapshot=%s',
            [CaptureSig, CurAct.sa_flags,
             {$IFDEF CRASH_TEST_LINUXLIKE} Pointer(@CurAct._u.sa_sigaction)
             {$ELSE} Pointer(@CurAct.__sigaction_handler.sa_sigaction) {$ENDIF},
             BoolToStr(CrashHasSignalSnapshot, True)]);
          if CrashPrimaryFaultAddr(DiagIP) then
          begin
            DiagLoc := TCrashCapture.SymbolizeAddressList([DiagIP]);
            if Length(DiagLoc) > 0 then
              Progress.InfoFmt('A0d diag: fault at %s line %d',
                [DiagLoc[0].RoutineName, DiagLoc[0].LineNumber]);
          end;
          CrashTakeAndFormatSnapshots(0, DiagRegs, DiagInfo);
          for S in DiagInfo.Split([#13#10, #10]) do
            if S.Trim <> '' then
              Progress.Info('A0d diag: ' + S.Trim);
        end;
        Progress.Account(StepOk,
          'A0d: late acquire refreshes capture signal in fault-handler sa_mask');
      end
      else
        Progress.Skip('A0d: Crash fault handlers are inactive on this run');

      // The fixed slot compares both identities. A recycled pthread_t with a
      // new kernel TID must never publish under the dead owner''s name.
      CaptureHandle := nil;
      StepOk := CrashThreadCaptureRegisterCurrentThread(CaptureHandle);
      try
        NativeIdentity := CrashCurrentThreadNativeIdentity;
        StepOk := StepOk and (NativeIdentity.PThread <> 0) and
          (NativeIdentity.KernelThread <> 0) and
          CrashThreadCaptureTestIdentityMatches(CaptureHandle,
            NativeIdentity.PThread, NativeIdentity.KernelThread) and
          (not CrashThreadCaptureTestIdentityMatches(CaptureHandle,
            NativeIdentity.PThread, NativeIdentity.KernelThread + 1));
      finally
        CrashThreadCaptureUnregisterCurrentThread(CaptureHandle);
      end;
      Progress.Account(StepOk,
        'A0e: slot identity requires pthread_t plus kernel thread id');

      // Prototype/stress for the raw service itself. The targets alternate two
      // common healthy states (CPU work and Sleep), while the coordinator
      // repeatedly interrupts both. Each target checks its own signal mask
      // after the series and before unregistering.
      StressCPU := nil;
      StressSleep := nil;
      StressCaptured := 0;
      TCrashFreeze.BeginLongOperation;
      try
        StressCPU := TCaptureStressTarget.Create(True);
        StressSleep := TCaptureStressTarget.Create(False);
        Deadline := TThread.GetTickCount64 + C_POLL_MS;
        repeat
          StressReady := StressCPU.IsReady and StressSleep.IsReady;
          if StressReady or (TThread.GetTickCount64 >= Deadline) then
            Break;
          TThread.Sleep(1);
        until False;
        StressReady := StressReady and StressCPU.RegistrationOK and
          StressSleep.RegistrationOK;
        if StressReady then
          for I := 1 to 32 do
          begin
            if (CrashThreadCaptureCapture(StressCPU.CaptureHandle, 200,
                 StressTrace) = tcoCaptured) and
               (Length(StressTrace.Addresses) > 0) then
              Inc(StressCaptured);
            if (CrashThreadCaptureCapture(StressSleep.CaptureHandle, 200,
                 StressTrace) = tcoCaptured) and
               (Length(StressTrace.Addresses) > 0) then
              Inc(StressCaptured);
          end;
      finally
        if StressCPU <> nil then
          StressCPU.RequestStop;
        if StressSleep <> nil then
          StressSleep.RequestStop;
        if StressCPU <> nil then
          StressCPU.WaitFor;
        if StressSleep <> nil then
          StressSleep.WaitFor;
        StressMaskOK := (StressCPU <> nil) and (StressSleep <> nil) and
          StressCPU.SignalMaskOK and StressSleep.SignalMaskOK;
        StressCPU.Free;
        StressSleep.Free;
        TCrashFreeze.EndLongOperation;
      end;
      Progress.Account(StressReady and (StressCaptured = 64),
        'A0f: repeated capture succeeds for CPU and sleeping workers');
      Progress.Account(StressReady and StressMaskOK,
        'A0g: worker signal masks are restored after capture stress');

      // Fail-safe quarantine is not permanent for a still-live verified owner.
      // A repeated registration drains its own pending service signal and
      // returns the same stable handle to Idle, ready for another capture.
      SelfQuarantineHandle := nil;
      SelfQuarantineRepeat := nil;
      StepOk := CrashThreadCaptureRegisterCurrentThread(SelfQuarantineHandle);
      try
        StepOk := StepOk and
          CrashThreadCaptureTestQuarantine(SelfQuarantineHandle) and
          CrashThreadCaptureRegisterCurrentThread(SelfQuarantineRepeat) and
          (SelfQuarantineRepeat = SelfQuarantineHandle) and
          (CrashThreadCaptureCapture(SelfQuarantineRepeat, 200,
             StressTrace) = tcoCaptured) and
          (Length(StressTrace.Addresses) > 0);
      finally
        CrashThreadCaptureUnregisterCurrentThread(SelfQuarantineRepeat);
        CrashThreadCaptureUnregisterCurrentThread(SelfQuarantineHandle);
      end;
      Progress.Account(StepOk,
        'A0g2: same owner re-registration revives its quarantined slot');

      // The real identity-mismatch branch: the worker's slot gets a spoofed
      // kernel TID, the handler accepts the signal but publishes no foreign
      // stack. A repeated registration of the same live thread must then go
      // through collision reclaim and receive a new working handle.
      OldCollisionHandle := nil;
      CollisionIdentity := Default(TCrashThreadNativeIdentity);
      CollisionTarget := TCaptureStressTarget.Create(False);
      try
        Deadline := TThread.GetTickCount64 + C_POLL_MS;
        while (not CollisionTarget.IsReady) and
              (TThread.GetTickCount64 < Deadline) do
          TThread.Sleep(1);
        OldCollisionHandle := CollisionTarget.CaptureHandle;
        CollisionIdentity := CollisionTarget.NativeIdentity;
        StepOk := CollisionTarget.IsReady and
          CollisionTarget.RegistrationOK and
          CrashThreadCaptureTestSetKernelIdentity(OldCollisionHandle,
            CollisionTarget.NativeIdentity.KernelThread + 1) and
          (CrashThreadCaptureCapture(OldCollisionHandle, 100,
             StressTrace) = tcoTimedOut) and
          (Length(StressTrace.Addresses) = 0);
        Progress.Account(StepOk,
          'A0h: handler rejects an injected kernel-identity mismatch without publishing');

        CollisionTarget.RequestReRegister;
        Deadline := TThread.GetTickCount64 + C_POLL_MS;
        while (not CollisionTarget.IsReRegisterDone) and
              (TThread.GetTickCount64 < Deadline) do
          TThread.Sleep(1);
        StepOk := CollisionTarget.IsReRegisterDone and
          CollisionTarget.ReRegistrationOK and
          (CollisionTarget.CaptureHandle <> OldCollisionHandle) and
          CrashThreadCaptureTestIdentityMatches(CollisionTarget.CaptureHandle,
            CollisionTarget.NativeIdentity.PThread,
            CollisionTarget.NativeIdentity.KernelThread) and
          (CrashThreadCaptureCapture(CollisionTarget.CaptureHandle, 200,
             StressTrace) = tcoCaptured) and
          (Length(StressTrace.Addresses) > 0);
        Progress.Account(StepOk,
          'A0i: same pthread collision is reclaimed into a new capturable handle');
      finally
        CollisionTarget.RequestStop;
        CollisionTarget.WaitFor;
        CollisionTarget.Free;
        // The injected mismatch can intentionally leave the old static slot in
        // fail-safe quarantine when pending-signal drain is inconclusive. The
        // owner is now joined, so the test may reset its synthetic slot without
        // polluting the subsequent disposition-ownership scenario.
        CollisionCleanupOK :=
          CrashThreadCaptureTestResetQuarantined(OldCollisionHandle);
      end;
      Progress.Account(CollisionCleanupOK,
        'A0j: injected collision fixture leaves no quarantined slot behind');
      TCrashFreeze.Ping;

      // A1: suppression. A block longer than the timeout, but under BeginLongOperation.
      TCrashFreeze.BeginLongOperation;
      try
        FreezeBeacon_BusyBlock(C_BLOCK_MS);
      finally
        TCrashFreeze.EndLongOperation;
      end;
      TCrashFreeze.Ping;
      Sleep(600); // give the watchdog a quantum: a false trigger would have surfaced
      Progress.Account(not FlagIsSet(GCapturedFlag),
        'A1: BeginLongOperation suppresses detection');

      // A1b: SetSuspended - the mobile background. A flag, not a counter:
      // unpaired Android lifecycle events must not mute the detector for good,
      // so it is set twice and cleared once - detection must come back.
      TCrashFreeze.SetSuspended(True);
      TCrashFreeze.SetSuspended(True);
      try
        FreezeBeacon_BusyBlock(C_BLOCK_MS);
      finally
        TCrashFreeze.SetSuspended(False);
      end;
      Sleep(600);
      Progress.Account(not FlagIsSet(GCapturedFlag),
        'A1b: SetSuspended mutes the background span');
      // Clearing re-stamps the heartbeat by itself - without a single ping a
      // block shorter than the timeout must not trigger (otherwise the window
      // between the wake-up and the timer's first tick would give a false report).
      FreezeBeacon_BusyBlock(C_TIMEOUT_MS div 2);
      Progress.Account(not FlagIsSet(GCapturedFlag),
        'A1c: clearing SetSuspended re-stamps the heartbeat (no stale-gap report)');

      // A2: capture. A block without suppression - the watchdog must take the stack.
      FreezeBeacon_BusyBlock(C_BLOCK_MS);
      StepOk := WaitForFlag(GCapturedFlag, C_POLL_MS);
      if not StepOk then
        Progress.Info('A2 watchdog: ' + CrashFreezeTestStateText);
      Progress.Account(StepOk, 'A2: freeze episode captured');
      if StepOk then
      begin
        Progress.Account(GCapturedReport.ExceptionClassName = 'EFrozenApplication',
          'A2b: report class is EFrozenApplication');
        Progress.Account(GCapturedForMS >= C_TIMEOUT_MS,
          'A2c: frozen-for duration covers the timeout');
        Progress.Account(Length(GCapturedReport.CallStack) > 0,
          'A2d: frozen thread call stack captured');
        Progress.Account(not CrashThreadCaptureCurrentSignalBlocked,
          'A2f: normal sigreturn leaves capture signal unblocked');
        {$IF Defined(MACOS)}
        // macOS: symbolization (both crash and freeze) is clamped to the nearest
        // export - this binary's LC_SYMTAB cache holds exports only, no unit
        // routine names (checked with a crash .el on the same binary); addresses
        // are resolved offline from Module+Offset and the .map. The honest
        // observable here is that the captured chain reaches OUR module.
        StepOk := CountExeFrames(GCapturedReport.CallStack) >= 2;
        {$ELSE}
        StepOk := StackHasRoutine(GCapturedReport.CallStack, 'FreezeBeacon')
          or (Pos('FreezeBeacon', GCapturedReport.ExceptionLocation.RoutineName) > 0);
        {$ENDIF}
        if not StepOk then
          for I := 0 to High(GCapturedReport.CallStack) do
          begin
            if I >= 12 then
              Break;
            Progress.InfoFmt('frame %d: %s [%s] (addr=%x line=%d)',
              [I, GCapturedReport.CallStack[I].RoutineName,
               ExtractFileName(GCapturedReport.CallStack[I].ModuleName),
               GCapturedReport.CallStack[I].CodeAddress,
               GCapturedReport.CallStack[I].LineNumber]);
          end;
        {$IF Defined(MACOS)}
        Progress.Account(StepOk, 'A2e: frozen chain reaches our executable module');
        {$ELSE}
        Progress.Account(StepOk, 'A2e: stack names the blocking routine (beacon)');
        {$ENDIF}
      end;

      // A3: recovery -> re-arm -> second episode.
      TCrashFreeze.Ping;
      Sleep(600); // the watchdog must see a ping newer than the detection moment
      TInterlocked.Exchange(GCapturedFlag, 0);
      TCrashFreeze.Ping;
      FreezeBeacon_BusyBlock(C_BLOCK_MS);
      Progress.Account(WaitForFlag(GCapturedFlag, C_POLL_MS),
        'A3: watchdog re-arms after recovery (second episode)');

      // A3c/d: timeout must not poison a long-lived thread until re-register.
      // Hold the capture signal across one whole probe: the watchdog reports an
      // empty stack and marks the slot Poisoned. Restoring the mask delivers
      // the one pending signal; the handler consumes Poisoned -> Idle without
      // unwinding, after which the next episode must capture normally.
      TCrashFreeze.Ping;
      Sleep(600);
      TInterlocked.Exchange(GCapturedFlag, 0);
      FillChar(CaptureMask, SizeOf(CaptureMask), 0);
      FillChar(SavedMask, SizeOf(SavedMask), 0);
      CrashSigSetClear(CaptureMask);
      CrashSigSetAdd(CaptureMask, CaptureSig);
      MaskInstalled := TestPThreadSigMask(SIG_BLOCK, @CaptureMask, @SavedMask) = 0;
      TimeoutReportOk := False;
      if MaskInstalled then
      try
        TCrashFreeze.Ping;
        FreezeBeacon_BusyBlock(C_BLOCK_MS);
        TimeoutReportOk := WaitForFlag(GCapturedFlag, C_POLL_MS) and
          (Length(GCapturedReport.CallStack) = 0);
      finally
        TestPThreadSigMask(SIG_SETMASK, @SavedMask, nil);
      end;
      Progress.Account(MaskInstalled and TimeoutReportOk,
        'A3c: blocked capture signal yields a bounded empty-stack report');
      Progress.Account(not CrashThreadCaptureCurrentSignalBlocked,
        'A3d: late delivery consumes Poisoned and restores the signal mask');

      TCrashFreeze.Ping;
      Sleep(600);
      TInterlocked.Exchange(GCapturedFlag, 0);
      TCrashFreeze.Ping;
      FreezeBeacon_BusyBlock(C_BLOCK_MS);
      StepOk := WaitForFlag(GCapturedFlag, C_POLL_MS) and
        (Length(GCapturedReport.CallStack) > 0);
      Progress.Account(StepOk,
        'A3e: timed-out long-lived thread captures again without re-register');

      // A4: the report gate is not held across OnCapture - in the "report is
      // being formatted/written/uploaded" window the single-flight flag must
      // be free, otherwise a concurrent crash from another thread silently
      // loses its WHOLE report (ReportException leaves on a busy gate).
      TCrashFreeze.Ping;
      Sleep(600);
      TInterlocked.Exchange(GCapturedFlag, 0);
      TInterlocked.Exchange(GGateFreeInCapture, 0);
      TCrashFreeze.OnCapture :=
        procedure(const AReport: TCrashReport; const AFrozenForMS: Int64)
        begin
          if TCrashCapture.TryEnterReportGate then
          begin
            TCrashCapture.LeaveReportGate;
            TInterlocked.Exchange(GGateFreeInCapture, 1);
          end;
          TInterlocked.Exchange(GCapturedFlag, 1);
        end;
      TCrashFreeze.Ping;
      FreezeBeacon_BusyBlock(C_BLOCK_MS);
      StepOk := WaitForFlag(GCapturedFlag, C_POLL_MS);
      Progress.Account(StepOk and FlagIsSet(GGateFreeInCapture),
        'A4: report gate released before OnCapture (concurrent crash reportable)');

      TCrashFreeze.Shutdown;
      Progress.Account(not TCrashFreeze.Active, 'A3b: Shutdown deactivates the detector');
      StepOk := CrashThreadCaptureTestLiveSlotCount = BaselineLiveSlots;
      if not StepOk then
      begin
        Progress.InfoFmt('A3f identities: main p%x/k%x collision p%x/k%x',
          [NativeIdentity.PThread, NativeIdentity.KernelThread,
           CollisionIdentity.PThread, CollisionIdentity.KernelThread]);
        Progress.InfoFmt('A3f expected baseline slots: %d',
          [BaselineLiveSlots]);
        Progress.Info('A3f live slots: ' +
          CrashThreadCaptureTestLiveSlotSummary);
      end;
      Progress.Account(StepOk,
        'A3f: Shutdown returns thread-capture slots to the host baseline');

      // A6: the whole process was stopped (docker pause / SIGSTOP / a paused VM)
      // - the watchdog slept together with the watched thread. The seam
      // stretches its sleep by C_STALL_MS while the thread blocks longer: the
      // watchdog wakes up IN THE MIDDLE of the block (window 3250..3500 ms vs
      // 3800) and the ping arrives within <= 550 ms. Without the grace this is
      // a report; without a working seam the 3800 ms block is one too.
      // A fresh Install: the earlier episodes used up MAX_EPISODES_PER_RUN, and
      // under a used-up cap "no report" proves nothing.
      TCrashFreeze.Install(C_TIMEOUT_MS);
      TInterlocked.Exchange(GCapturedFlag, 0);
      TCrashFreeze.Ping;
      Sleep(600);
      TCrashFreeze.Ping;
      CrashFreezeTestStallWatchdogOnce(C_STALL_MS);
      FreezeBeacon_BusyBlock(C_STALL_MS + 800);
      TCrashFreeze.Ping;
      Sleep(600);
      TCrashFreeze.Ping;
      Sleep(600);
      Progress.Account(TCrashFreeze.Active and not FlagIsSet(GCapturedFlag),
        'A6: a whole-process stall (watchdog overslept) is a grace, not a freeze');

      // A6b: the grace is one-shot - the next block is caught as usual (which
      // also proves A6 was not silent because of the episode cap).
      TCrashFreeze.Ping;
      FreezeBeacon_BusyBlock(C_BLOCK_MS);
      Progress.Account(WaitForFlag(GCapturedFlag, C_POLL_MS),
        'A6b: detection resumes after the stall grace');

      // A6c: a foreign thread keeps pinging through the whole block.
      TCrashFreeze.Ping;
      Sleep(600);
      TInterlocked.Exchange(GCapturedFlag, 0);
      TCrashFreeze.Ping;
      ForeignPinger := StartForeignPinger;
      try
        FreezeBeacon_BusyBlock(C_BLOCK_MS);
        StepOk := WaitForFlag(GCapturedFlag, C_POLL_MS);
      finally
        TInterlocked.Exchange(GForeignPingStop, 1);
        ForeignPinger.WaitFor;
        ForeignPinger.Free;
      end;
      if not StepOk then
        Progress.Info('A6c watchdog: ' + CrashFreezeTestStateText);
      Progress.Account(StepOk,
        'A6c: pings from another thread do not mask the watched thread''s freeze');
      TCrashFreeze.Shutdown;

      // A5: coexistence with another process-wide handler. When the host owns
      // the capture lease already, Freeze must reuse it and leave a neighbour
      // untouched. With the standalone default, retain the original selection
      // test: occupied first candidate -> next free signal (or refusal on Mac).
      if HostExtendedEnabled then
      begin
        {$IFDEF CRASH_TEST_LINUXLIKE}
        TestSig := __libc_current_sigrtmin + 20;
        if TestSig = CaptureSig then
          TestSig := __libc_current_sigrtmin + 21;
        FillChar(PrevAct, SizeOf(PrevAct), 0);
        PrevAct._u.sa_sigaction := TestPrevSigactionHandler;
        PrevAct.sa_flags := SA_SIGINFO;
        sigemptyset(PrevAct.sa_mask);
        StepOk := sigaction(TestSig, @PrevAct, nil) = 0;
        if StepOk then
        begin
          TCrashFreeze.Install(C_TIMEOUT_MS);
          FillChar(CurAct, SizeOf(CurAct), 0);
          StepOk := TCrashFreeze.Active and
            (CrashThreadCaptureSignalNumber = CaptureSig) and
            (sigaction(TestSig, nil, @CurAct) = 0) and
            (@CurAct._u.sa_sigaction = @TestPrevSigactionHandler);
          TInterlocked.Exchange(GCapturedFlag, 0);
          TCrashFreeze.Ping;
          FreezeBeacon_BusyBlock(C_BLOCK_MS);
          StepOk := StepOk and WaitForFlag(GCapturedFlag, C_POLL_MS);
          TCrashFreeze.Shutdown;
          FillChar(CurAct, SizeOf(CurAct), 0);
          StepOk := StepOk and
            (CrashThreadCaptureSignalNumber = CaptureSig) and
            (sigaction(TestSig, nil, @CurAct) = 0) and
            (@CurAct._u.sa_sigaction = @TestPrevSigactionHandler);
          FillChar(PrevAct, SizeOf(PrevAct), 0);
          sigemptyset(PrevAct.sa_mask);
          sigaction(TestSig, @PrevAct, nil);
        end;
        {$ELSE}
        TCrashFreeze.Install(C_TIMEOUT_MS);
        StepOk := TCrashFreeze.Active and
          (CrashThreadCaptureSignalNumber = CaptureSig);
        TCrashFreeze.Shutdown;
        StepOk := StepOk and
          (CrashThreadCaptureSignalNumber = CaptureSig);
        {$ENDIF}
      end
      else
      begin
        {$IFDEF CRASH_TEST_LINUXLIKE}
        TestSig := __libc_current_sigrtmin + 5;
        {$ELSE}
        TestSig := SIGUSR2;
        {$ENDIF}
        FillChar(PrevAct, SizeOf(PrevAct), 0);
        {$IFDEF CRASH_TEST_LINUXLIKE}
        PrevAct._u.sa_sigaction := TestPrevSigactionHandler;
        {$ELSE}
        PrevAct.__sigaction_handler.sa_sigaction := TestPrevSigactionHandler;
        {$ENDIF}
        PrevAct.sa_flags := SA_SIGINFO;
        sigemptyset(PrevAct.sa_mask);
        StepOk := sigaction(TestSig, @PrevAct, nil) = 0;
        if StepOk then
        begin
          {$IFDEF CRASH_TEST_LINUXLIKE}
        TCrashFreeze.Install(C_TIMEOUT_MS);
        StepOk := TCrashFreeze.Active;
        // The foreign handler on rtmin+5 is untouched.
        FillChar(CurAct, SizeOf(CurAct), 0);
        StepOk := StepOk and (sigaction(TestSig, nil, @CurAct) = 0) and
          (@CurAct._u.sa_sigaction = @TestPrevSigactionHandler);
        // The detector is really alive on the next signal: an episode is caught.
        TInterlocked.Exchange(GCapturedFlag, 0);
        TCrashFreeze.Ping;
        FreezeBeacon_BusyBlock(C_BLOCK_MS);
        StepOk := StepOk and WaitForFlag(GCapturedFlag, C_POLL_MS);
        TCrashFreeze.Shutdown;
        // The signal taken (next free = rtmin+6) is returned to SIG_DFL.
        FillChar(CurAct, SizeOf(CurAct), 0);
        StepOk := StepOk and
          (sigaction(__libc_current_sigrtmin + 6, nil, @CurAct) = 0) and
          (not Assigned(CurAct._u.sa_handler));
        {$ELSE}
        TCrashFreeze.Install(C_TIMEOUT_MS);
        StepOk := not TCrashFreeze.Active; // an occupied SIGUSR2 = refusal
        // Free it and make sure Install arms now.
        FillChar(CurAct, SizeOf(CurAct), 0);
        sigemptyset(CurAct.sa_mask);
        sigaction(TestSig, @CurAct, nil);
        TCrashFreeze.Install(C_TIMEOUT_MS);
        StepOk := StepOk and TCrashFreeze.Active;
        TCrashFreeze.Shutdown;
        {$ENDIF}
        // Clean up: back to SIG_DFL, the test handler must not stay installed.
        FillChar(PrevAct, SizeOf(PrevAct), 0);
        sigemptyset(PrevAct.sa_mask);
        sigaction(TestSig, @PrevAct, nil);
        end;
      end;
      Progress.Account(StepOk,
        'A5: a host-owned signal is never stolen or released by Freeze');

      // B*: end-to-end through the reporter - a late opt-in
      // (EnableFreezeDetection), equivalent to FreezeDetection in a host setup.
      TCrashFreeze.OnCapture := nil;
      if TCrashReporter.Active then
      begin
        TCrashReporter.EnableFreezeDetection(C_TIMEOUT_MS);
        Progress.Account(TCrashFreeze.Active, 'B1: EnableFreezeDetection arms the detector');
        TCrashFreeze.Ping;
        FreezeBeacon_BusyBlock(C_BLOCK_MS);

        // The watchdog writes the .el - wait for the file with a time ceiling.
        FoundFile := '';
        Deadline := TThread.GetTickCount64 + UInt64(C_POLL_MS);
        repeat
          NewEl := DiffNewFiles(ElBefore, TDirectory.GetFiles(ReportDir, '*.el'));
          if Length(NewEl) > 0 then
          begin
            FoundFile := NewEl[0];
            Break;
          end;
          Sleep(100);
        until TThread.GetTickCount64 >= Deadline;
        Progress.Account(FoundFile <> '', 'B2: freeze .el written to the report dir');
        if FoundFile <> '' then
        begin
          ElText := TFile.ReadAllText(FoundFile, TEncoding.Unicode);
          Progress.Account(Pos('EFrozenApplication', ElText) > 0,
            'B3: .el names EFrozenApplication');
          Progress.Account(Pos('Freeze Info:', ElText) > 0,
            'B4: .el carries the Freeze Info section');
          Progress.Account((Pos('thread ', ElText) > 0) and
            (Pos('bounds=ok', ElText) > 0) and
            (Pos('fp-frames=', ElText) > 0) and
            (Pos('raw-frames=', ElText) > 0) and
            (Pos('stop=', ElText) > 0),
            'B4a: watched-thread bounded-capture diagnostics reach the .el');
        end;
      end
      else
        Progress.Skip('B*: crash reporter is not active in this build');

      // C*: the RestartOnFreeze notice-file contract. The restart itself replaces
      // the process - the test checks what the next start reads.
      if TCrashReporter.Active then
      begin
        NoticePath := TCrashReporter.RestartNoticeFilePath;
        // '.notice' is guaranteed to lie outside the '*.el' boot scan - otherwise
        // recovery would pick the notice up as a "crash report".
        Progress.Account((NoticePath <> '') and NoticePath.EndsWith('.notice'),
          'C1: notice path is set and cannot match the *.el boot scan');
      end
      else
        Progress.Skip('C1: crash reporter is not active in this build');

      TmpNoticePath := ReportDir + 'autotest_freeze_restart.notice';
      WrittenN := Default(TCrashRestartNotice);
      WrittenN.RestartedAt := EncodeDate(2026, 8, 29) + EncodeTime(12, 34, 56, 0);
      WrittenN.FrozenForMS := 45000;
      WrittenN.BugID := 'ABCD1234';
      WrittenN.ReportFile := ReportDir + 'CrashFreeze_test.el';
      WrittenN.Uploaded := False;
      try
        CrashWriteRestartNoticeFile(TmpNoticePath, WrittenN);
        StepOk := CrashReadRestartNoticeFile(TmpNoticePath, ReadN);
        Progress.Account(StepOk, 'C2: notice roundtrip - file written and parsed back');
        if StepOk then
          Progress.Account(
            ReadN.Found and
            (FormatDateTime('yyyymmddhhnnss', ReadN.RestartedAt) =
             FormatDateTime('yyyymmddhhnnss', WrittenN.RestartedAt)) and
            (ReadN.FrozenForMS = WrittenN.FrozenForMS) and
            (ReadN.BugID = WrittenN.BugID) and
            (ReadN.ReportFile = WrittenN.ReportFile) and
            (ReadN.Uploaded = WrittenN.Uploaded),
            'C3: notice roundtrip preserves every field');
      finally
        try
          TFile.Delete(TmpNoticePath);
        except
        end;
      end;
      Progress.Account(
        not CrashReadRestartNoticeFile(ReportDir + 'no_such_file.notice', ReadN),
        'C4: a missing notice file reads as not-found');

      // C5: the loop-guard env channel must work without the disk: set returns
      // True (readback verification), consume=True, a repeated consume is empty
      // (single delivery, descendants do not inherit the mark).
      StepOk := CrashSetFreezeRestartEnvMark;
      StepOk := StepOk and CrashConsumeFreezeRestartEnvMark;
      Progress.Account(StepOk and (not CrashConsumeFreezeRestartEnvMark),
        'C5: freeze-restart env mark - set verified, consumed once, gone after');

      // C6: spawn confirmation (fail-safe RestartOnFreeze): fork succeeds, execv
      // of a non-existent binary does not; the function must return False and
      // the CURRENT process must stay alive (we are the observable).
      Progress.Account(
        not CrashSpawnDetachedVerified('/nonexistent/crash_autotest_no_such_binary',
          ['/nonexistent/crash_autotest_no_such_binary']),
        'C6: spawn confirmation reports execv failure instead of losing the process');

      // C7: the replacement starts with a clean fd table: a pre-opened pipe
      // WITHOUT CLOEXEC must not survive exec. We: pipe -> spawn(/bin/sleep 2) ->
      // close OUR write end -> non-blocking read of the read end: immediate EOF
      // = the child did not carry the write copy away (the fd sweep works); EOF
      // only after ~2 s (when sleep dies) = it did, inheritance was not cut.
      StepOk := pipe(LeakFds) = 0;
      if StepOk then
      begin
        StepOk := CrashSpawnDetachedVerified(C_BIN_DIR + 'sleep', [C_BIN_DIR + 'sleep', '2']);
        if StepOk then
        begin
          __close(LeakFds.WriteDes);
          fcntl(LeakFds.ReadDes, F_SETFL, O_NONBLOCK);
          StepOk := False;
          Deadline := TThread.GetTickCount64 + 1000;
          repeat
            NRead := __read(LeakFds.ReadDes, @LeakByte, 1);
            if NRead = 0 then
            begin
              StepOk := True; // EOF: the write end lives in no process
              Break;
            end;
            if (NRead < 0) and (errno <> EAGAIN) and (errno <> EINTR) then
              Break;
            Sleep(20);
          until TThread.GetTickCount64 >= Deadline;
          // Reap the sleep zombie; at this point the process has no other
          // children (C6 reaped its own inside the function).
          waitpid(-1, nil, 0);
        end;
        __close(LeakFds.ReadDes);
      end;
      Progress.Account(StepOk,
        'C7: replacement does not inherit the parent''s non-CLOEXEC fds');

      // C8: fail-closed confirmation: RLIMIT_NOFILE is squeezed so that pipe()
      // cannot be created - the function must return False (no unconfirmed
      // spawn) and the process must live; the limit is restored.
      // C9: the fd-sweep fallback levels run forcibly (bypassing the
      // close_range fast path) in a FORKED child so the live runner's table is
      // not marked: a pre-opened pipe without CLOEXEC must get the flag
      // (F_GETFD) after every level; the verdict is the child's _exit code.
      StepOk := pipe(LeakFds) = 0;
      if StepOk then
      begin
        SweepChild := fork;
        if SweepChild = 0 then
        begin
          SweepVerdict := 0;
          {$IF Defined(LINUX)}
          if not CrashMarkFDsCloseOnExecViaProcFS then
            SweepVerdict := 1
          else if (fcntl(LeakFds.ReadDes, F_GETFD) and FD_CLOEXEC) = 0 then
            SweepVerdict := 2
          else
            fcntl(LeakFds.ReadDes, F_SETFD, 0); // clear it and check the 2nd level
          {$ENDIF}
          if (SweepVerdict = 0) and (not CrashMarkFDsCloseOnExecBySweep(1024)) then
            SweepVerdict := 3;
          if (SweepVerdict = 0) and
             ((fcntl(LeakFds.ReadDes, F_GETFD) and FD_CLOEXEC) = 0) then
            SweepVerdict := 4;
          Posix.Unistd._exit(SweepVerdict);
        end;
        StepOk := SweepChild > 0;
        if StepOk then
        begin
          waitpid(SweepChild, @WStatus, 0);
          StepOk := WIFEXITED(WStatus) and (WEXITSTATUS(WStatus) = 0);
          if not StepOk then
            Progress.InfoFmt('C9 diag: sweep child status=%d', [WStatus]);
        end;
        __close(LeakFds.ReadDes);
        __close(LeakFds.WriteDes);
      end;
      Progress.Account(StepOk,
        'C9: sweep fallbacks (procfs walk + bounded fcntl) mark a live fd CLOEXEC');

      // C10: regression of the silent cap (formerly 10240 macOS / 1048576
      // Linux). Any finite representable rlim_cur must become the EXACT sweep
      // bound; infinity / Integer overflow must give the -1 sentinel so that
      // after the unbounded levels fail the child ends BEFORE execv.
      StepOk :=
        (CrashFdSweepLimitFromRLimit(10241) = 10241) and
        (CrashFdSweepLimitFromRLimit(1048577) = 1048577) and
        (CrashFdSweepLimitFromRLimit(UInt64(High(Integer))) = High(Integer)) and
        (CrashFdSweepLimitFromRLimit(UInt64(High(Integer)) + 1) = -1) and
        (CrashFdSweepLimitFromRLimit(High(UInt64)) = -1);
      Progress.Account(StepOk,
        'C10: finite rlim_cur is exact; infinity/overflow fail closed');

      StepOk := getrlimit(TEST_RLIMIT_NOFILE, SavedRLim) = 0;
      if not StepOk then
        Progress.InfoFmt('C8 diag: getrlimit failed, errno=%d', [errno])
      else
      begin
        TightRLim := SavedRLim;
        TightRLim.rlim_cur := 4; // new fds would land higher - EMFILE
        StepOk := setrlimit(TEST_RLIMIT_NOFILE, TightRLim) = 0;
        if not StepOk then
          Progress.InfoFmt('C8 diag: setrlimit failed, errno=%d (cur=%d max=%d)',
            [errno, SavedRLim.rlim_cur, SavedRLim.rlim_max])
        else
        try
          StepOk := not CrashSpawnDetachedVerified(C_BIN_DIR + 'true', [C_BIN_DIR + 'true']);
          if not StepOk then
            Progress.Info('C8 diag: spawn returned True under a 4-fd limit');
        finally
          setrlimit(TEST_RLIMIT_NOFILE, SavedRLim);
        end;
      end;
      Progress.Account(StepOk,
        'C8: unobtainable confirmation pipe = fail-closed False, process stays');

      // D*: freeze BugID normalization (deterministic synthetic data).
      Step_D_FreezeBugID(Progress);
    finally
      TCrashFreeze.Shutdown;
      TCrashFreeze.OnCapture := SavedCapture;
      TCrashFreeze.OnExternalSuppress := SavedSuppress;
      // Remove fresh .el files: the next run's boot recovery would pick them up
      // as pending crash reports and pollute other runs.
      try
        for S in DiffNewFiles(ElBefore, TDirectory.GetFiles(ReportDir, '*.el')) do
          try
            TFile.Delete(S);
          except
          end;
      except
      end;
    end;

    Progress.WriteSummary(TEST_NAME);
    Result := Progress.AllPassed;
    OutLines := Lines.ToArray;
  finally
    Progress.Free;
    Lines.Free;
  end;
end;

{$ELSE}

class function TCrashFreeze_AllInOne.AutoTest(out OutLines: TArray<string>): Boolean;
var
  Lines: TList<string>;
  Progress: TCrashTestProgress;
begin
  Lines := TList<string>.Create;
  Progress := TCrashTestProgress.Create(Lines);
  try
    Progress.Skip('freeze detector is stubs on this target (Linux x64 / Android ARM64 / macOS only)');
    Progress.WriteSummary(TEST_NAME);
    Result := Progress.AllPassed;
    OutLines := Lines.ToArray;
  finally
    Progress.Free;
    Lines.Free;
  end;
end;

{$ENDIF}

initialization
  CrashRegisterTest(
    'CrashFreeze',
    'Freeze detector: detection, suppression, re-arm, stall grace, restart contract',
    ['crash', 'freeze', 'watchdog', 'posix'],
    TCrashFreeze_AllInOne.AutoTest
  );

{$ENDIF}

end.
