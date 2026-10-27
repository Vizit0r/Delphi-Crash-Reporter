unit Crash.Tests.ChildProcess;

// ===========================================================================
//  CrashChildProcess - fatal faults that end the process, checked from the
//  outside. The runner starts ITSELF as a child (--crash-child=<kind>
//  --report-dir=<dir>); the child initializes the reporter for that directory
//  and dies of the requested fault; the parent then reads the .el it left.
//
//    K1  unhandled raise on the main thread: the .el names the exception class,
//        its message and the raising routine; no Registers section
//    K2  null write (SIGSEGV): EAccessViolation with the Registers and Crash
//        Signal Info sections; the stack reaches the faulting code
//    K3  a hardware fault swallowed on the SAME thread, then a raise: the
//        report is a plain raise - no Registers, no Crash Signal Info
//    K4  the same with the fault swallowed on a WORKER thread
//    K5  stack overflow (Linux): the child dies without an in-process report;
//        the next start in the same directory recovers the committed raw
//        block as an ERawHardwareFault report
//
//  Needs the standalone runner (CrashTests): it sets CrashTestChildExe and
//  calls CrashTestRunChildIfRequested before anything else. Inside a host
//  application the test is not registered (ctkRunnerOnly).
//
//  Outside Linux x64 / macOS - SKIP.
//
//  Copyright (c) 2026 Vizit0r. BSD 2-Clause license (see LICENSE.txt).
// ===========================================================================

interface

{$IFDEF AUTOTESTS}

uses
  System.SysUtils;

var
  { Path of the runner executable; '' = the host cannot start a child. }
  CrashTestChildExe: String = '';

{ Call first in the runner. When the command line asks for a child scenario,
  runs it and returns True (the caller then just exits; ExitCode is set).
  Fatal scenarios do not return. }
function CrashTestRunChildIfRequested: Boolean;

type
  TCrashChildProcess_AllInOne = class
  public
    class function AutoTest(out OutLines: TArray<string>): Boolean; static;
  end;

{$ENDIF}

implementation

{$IFDEF AUTOTESTS}

uses
  System.Classes,
  System.IOUtils,
  System.Generics.Collections,
  {$IF (Defined(LINUX) and Defined(CPUX64)) or (Defined(MACOS) and not Defined(IOS))}
  Posix.Base,
  Posix.SysTypes,
  Posix.Unistd,
  Posix.Fcntl,
  Posix.SysWait,
  Posix.Signal,
  {$ENDIF}
  Crash.Reporter,
  Crash.Tests.Registry,
  Crash.Tests.Progress;

const
  TEST_NAME = 'CrashChildProcess';
  ARG_CHILD = '--crash-child=';
  ARG_DIR   = '--report-dir=';
  CHILD_RAISE_MESSAGE = 'crash-child raise';

type
  ECrashChildTest = class(Exception);

{$REGION 'Child side'}

procedure CrashChildNullWrite;
// The faulting store sits in its own routine that also makes a call, so it has
// a frame of its own (a frameless fault is not catchable on every target).
var
  P: PInteger;
begin
  P := nil;
  if Length(ParamStr(0)) >= 0 then
    P^ := 42;
end;

procedure CrashChildSwallowFault;
begin
  try
    CrashChildNullWrite;
  except
    // swallowed on purpose: the scenario is a handled hardware fault
  end;
end;

procedure CrashChildSwallowFaultOnRegisteredWorker;
// Registered like a host's worker: on macOS hardware faults arrive through Mach
// and are snapshotted only on registered threads, so an unregistered worker
// would leave nothing to retire and K4 would pass without the defence.
begin
  TCrashReporter.RegisterCurrentThread('CrashChildWorker', 0);
  try
    CrashChildSwallowFault;
  finally
    TCrashReporter.UnregisterCurrentThread;
  end;
end;

function CrashChildBurnStack(N: Integer): Integer;
// Unbounded recursion with a 4 KB frame; the result feeds back so nothing is
// optimized away.
var
  Pad: array[0..511] of NativeInt;
begin
  Pad[0] := N;
  Pad[High(Pad)] := N + 1;
  Result := CrashChildBurnStack(N + 1) + Pad[0] + Pad[High(Pad)];
end;

procedure CrashChildTrigger(const AKind: String);
var
  W: TThread;
begin
  if AKind = 'raise' then
    raise ECrashChildTest.Create(CHILD_RAISE_MESSAGE)
  else if AKind = 'segv' then
    CrashChildNullWrite
  else if AKind = 'stale' then
  begin
    CrashChildSwallowFault;
    raise ECrashChildTest.Create(CHILD_RAISE_MESSAGE + ' after a swallowed fault');
  end
  else if AKind = 'foreign' then
  begin
    W := TThread.CreateAnonymousThread(CrashChildSwallowFaultOnRegisteredWorker);
    W.FreeOnTerminate := False;
    W.Start;
    W.WaitFor;
    W.Free;
    raise ECrashChildTest.Create(CHILD_RAISE_MESSAGE + ' after a worker swallowed a fault');
  end
  else if AKind = 'stackoverflow' then
    Writeln(CrashChildBurnStack(1))
  else if AKind = 'recover' then
    // Init already recovered whatever the previous child left; exit cleanly.
  else
  begin
    Writeln(ErrOutput, 'unknown --crash-child kind: ', AKind);
    ExitCode := 2;
  end;
end;

function CrashTestRunChildIfRequested: Boolean;
var
  I: Integer;
  Arg, Kind, Dir: String;
  Cfg: TCrashConfig;
begin
  Kind := '';
  Dir := '';
  for I := 1 to ParamCount do
  begin
    Arg := ParamStr(I);
    if Arg.StartsWith(ARG_CHILD) then
      Kind := Copy(Arg, Length(ARG_CHILD) + 1, MaxInt)
    else if Arg.StartsWith(ARG_DIR) then
      Dir := Copy(Arg, Length(ARG_DIR) + 1, MaxInt);
  end;
  Result := Kind <> '';
  if not Result then
    Exit;
  Cfg := DefaultCrashConfig;
  Cfg.AppName := 'CrashTestsChild';
  Cfg.AppVersion := '0.0.0.0';
  Cfg.ReportDir := Dir;
  Cfg.SaveToFile := True;
  Cfg.UploadEnabled := False;
  TCrashReporter.Init(Cfg);
  ExitCode := 0;
  CrashChildTrigger(Kind);
end;

{$ENDREGION}

{$IF (Defined(LINUX) and Defined(CPUX64)) or (Defined(MACOS) and not Defined(IOS))}

{$REGION 'Parent side'}

const
  CHILD_TIMEOUT_MS = 20000;

type
  TChildRun = record
    Started, Reaped, TimedOut: Boolean;
    Status: Integer;
    function Describe: String;
  end;

function TChildRun.Describe: String;
begin
  if not Started then
    Result := 'not started'
  else if TimedOut then
    Result := 'timed out (killed)'
  else if not Reaped then
    Result := 'not reaped'
  else if WIFEXITED(Status) then
    Result := 'exit ' + IntToStr(WEXITSTATUS(Status))
  else if WIFSIGNALED(Status) then
    Result := 'signal ' + IntToStr(WTERMSIG(Status))
  else
    Result := 'status ' + IntToStr(Status);
end;

function RunChild(const AKind, ADir: String): TChildRun;
var
  Args: TArray<TBytes>;
  ArgV: TArray<MarshaledAString>;
  LogPath: TBytes;
  Pid, R: pid_t;
  Fd, I: Integer;
  St: Integer;
  Deadline: UInt64;
begin
  Result := Default(TChildRun);
  // Everything the child touches is prepared before fork: after fork only
  // async-signal-safe calls are allowed until execv.
  SetLength(Args, 3);
  Args[0] := TEncoding.UTF8.GetBytes(CrashTestChildExe + #0);
  Args[1] := TEncoding.UTF8.GetBytes(ARG_CHILD + AKind + #0);
  Args[2] := TEncoding.UTF8.GetBytes(ARG_DIR + ADir + #0);
  SetLength(ArgV, Length(Args) + 1);
  for I := 0 to High(Args) do
    ArgV[I] := MarshaledAString(@Args[I][0]);
  ArgV[High(ArgV)] := nil;
  LogPath := TEncoding.UTF8.GetBytes(TPath.Combine(ADir, 'child.log') + #0);

  Pid := fork;
  if Pid = 0 then
  begin
    Fd := __open(MarshaledAString(@LogPath[0]), O_WRONLY or O_CREAT or O_TRUNC, 420); // 0644
    if Fd >= 0 then
    begin
      dup2(Fd, 1);
      dup2(Fd, 2);
      __close(Fd);
    end;
    execv(ArgV[0], @ArgV[0]);
    _exit(127);
  end;
  if Pid < 0 then
    Exit;
  Result.Started := True;
  Deadline := TThread.GetTickCount64 + CHILD_TIMEOUT_MS;
  repeat
    St := 0;
    R := waitpid(Pid, @St, WNOHANG);
    if R = Pid then
    begin
      Result.Reaped := True;
      Result.Status := St;
      Exit;
    end;
    if R < 0 then
      Exit;
    TThread.Sleep(20);
  until TThread.GetTickCount64 >= Deadline;
  Result.TimedOut := True;
  kill(Pid, SIGKILL);
  waitpid(Pid, @St, 0);
end;

function ReadSingleReport(const ADir: String; out AText, AWhy: String): Boolean;
var
  Files: TArray<String>;
begin
  AText := '';
  Files := TDirectory.GetFiles(ADir, '*.el');
  Result := Length(Files) = 1;
  if Result then
    AText := TFile.ReadAllText(Files[0], TEncoding.Unicode)
  else
    AWhy := Format('%d .el files in the report dir', [Length(Files)]);
end;

procedure DumpChildLog(const AProgress: TCrashTestProgress; const ADir: String);
var
  LogFile, S: String;
begin
  LogFile := TPath.Combine(ADir, 'child.log');
  if not TFile.Exists(LogFile) then
    Exit;
  for S in TFile.ReadAllLines(LogFile) do
    if S.Trim <> '' then
      AProgress.Info('  child: ' + S);
end;

const
  // The per-fault line of the Crash Signal Info section. macOS reports carry
  // that section in every report (a Mach-port note), so its header alone does
  // not mean a fault snapshot was attached.
  FAULT_SIGNAL_LINE = '  Signal     : ';

function Has(const AText, APart: String): Boolean;
begin
  Result := Pos(APart, AText) > 0;
end;

function StackReaches(const AText, ARoutine: String): Boolean;
// macOS symbolization is clamped to the nearest export (no unit routine names),
// so there the honest observable is a frame in the runner's own module.
begin
  {$IF Defined(MACOS)}
  Result := Has(AText, '|' + ExtractFileName(CrashTestChildExe) + '|') or
    Has(AText, '|' + ExtractFileName(CrashTestChildExe) + ' ');
  {$ELSE}
  Result := Has(AText, ARoutine);
  {$ENDIF}
end;

function NewScenarioDir(const ARoot, AKind: String): String;
begin
  Result := TPath.Combine(ARoot, AKind);
  TDirectory.CreateDirectory(Result);
end;

procedure CheckRaiseLike(const AProgress: TCrashTestProgress;
  const ARoot, AKind, AStep, ADesc: String);
// A raise-terminated child: exactly one report of the test exception class,
// no hardware-fault sections.
var
  Dir, Text, Why: String;
  Run: TChildRun;
  Ok: Boolean;
begin
  Dir := NewScenarioDir(ARoot, AKind);
  Run := RunChild(AKind, Dir);
  Ok := Run.Reaped and WIFEXITED(Run.Status) and (WEXITSTATUS(Run.Status) <> 0) and
    ReadSingleReport(Dir, Text, Why) and
    Has(Text, ECrashChildTest.ClassName) and Has(Text, CHILD_RAISE_MESSAGE) and
    Has(Text, 'Call Stack Information:') and StackReaches(Text, 'CrashChildTrigger') and
    (not Has(Text, 'Registers:')) and (not Has(Text, FAULT_SIGNAL_LINE));
  if not Ok then
  begin
    AProgress.InfoFmt('%s diag: child %s; %s', [AStep, Run.Describe, Why]);
    AProgress.InfoFmt('%s diag: class=%s message=%s trigger=%s registers=%s faultsignal=%s',
      [AStep, BoolToStr(Has(Text, ECrashChildTest.ClassName), True),
       BoolToStr(Has(Text, CHILD_RAISE_MESSAGE), True),
       BoolToStr(StackReaches(Text, 'CrashChildTrigger'), True),
       BoolToStr(Has(Text, 'Registers:'), True),
       BoolToStr(Has(Text, FAULT_SIGNAL_LINE), True)]);
    DumpChildLog(AProgress, Dir);
  end;
  AProgress.Account(Ok, AStep + ': ' + ADesc);
end;

procedure Step_K2_NullWrite(const AProgress: TCrashTestProgress; const ARoot: String);
var
  Dir, Text, Why: String;
  Run: TChildRun;
  Ok: Boolean;
begin
  Dir := NewScenarioDir(ARoot, 'segv');
  Run := RunChild('segv', Dir);
  Ok := Run.Reaped and (not Run.TimedOut) and ReadSingleReport(Dir, Text, Why) and
    Has(Text, 'EAccessViolation') and Has(Text, 'Registers:') and
    Has(Text, 'Crash Signal Info:') and StackReaches(Text, 'CrashChildNullWrite');
  if not Ok then
  begin
    AProgress.InfoFmt('K2 diag: child %s; %s', [Run.Describe, Why]);
    AProgress.InfoFmt('K2 diag: av=%s registers=%s signalinfo=%s frame=%s',
      [BoolToStr(Has(Text, 'EAccessViolation'), True),
       BoolToStr(Has(Text, 'Registers:'), True),
       BoolToStr(Has(Text, 'Crash Signal Info:'), True),
       BoolToStr(StackReaches(Text, 'CrashChildNullWrite'), True)]);
    DumpChildLog(AProgress, Dir);
  end;
  AProgress.Account(Ok,
    'K2: a null write leaves an EAccessViolation report with registers and signal info');
end;

procedure Step_K5_StackOverflow(const AProgress: TCrashTestProgress; const ARoot: String);
{$IF Defined(LINUX)}
var
  Dir, Text, Why: String;
  Run, Recover: TChildRun;
  Died, Recovered: Boolean;
begin
  Dir := NewScenarioDir(ARoot, 'stackoverflow');
  Run := RunChild('stackoverflow', Dir);
  Died := Run.Reaped and not (WIFEXITED(Run.Status) and (WEXITSTATUS(Run.Status) = 0));
  Recover := RunChild('recover', Dir);
  Recovered := Recover.Reaped and WIFEXITED(Recover.Status) and
    (WEXITSTATUS(Recover.Status) = 0) and ReadSingleReport(Dir, Text, Why) and
    Has(Text, 'ERawHardwareFault') and Has(Text, 'signal 11');
  if not (Died and Recovered) then
  begin
    AProgress.InfoFmt('K5 diag: overflow child %s, recover child %s; %s',
      [Run.Describe, Recover.Describe, Why]);
    DumpChildLog(AProgress, Dir);
  end;
  AProgress.Account(Died and Recovered,
    'K5: a stack overflow is recovered from the raw block by the next start');
end;
{$ELSE}
begin
  AProgress.Skip('K5: the stack-overflow raw recovery is checked on Linux only');
end;
{$ENDIF}

{$ENDREGION}

class function TCrashChildProcess_AllInOne.AutoTest(out OutLines: TArray<string>): Boolean;
var
  Lines: TList<string>;
  Progress: TCrashTestProgress;
  Root: String;
begin
  Lines := TList<string>.Create;
  Progress := TCrashTestProgress.Create(Lines);
  try
    if CrashTestChildExe = '' then
      Progress.Skip('needs the standalone runner (CrashTests) to start child processes')
    else
    begin
      Root := TPath.Combine(TPath.GetTempPath,
        'CrashTestsChild_' + TPath.GetGUIDFileName);
      TDirectory.CreateDirectory(Root);
      try
        CheckRaiseLike(Progress, Root, 'raise', 'K1',
          'an unhandled raise leaves a report naming the class, message and routine');
        Step_K2_NullWrite(Progress, Root);
        CheckRaiseLike(Progress, Root, 'stale', 'K3',
          'a raise after a swallowed same-thread fault carries no fault sections');
        CheckRaiseLike(Progress, Root, 'foreign', 'K4',
          'a raise after a fault swallowed on a worker carries no fault sections');
        Step_K5_StackOverflow(Progress, Root);
      finally
        try
          TDirectory.Delete(Root, True);
        except
        end;
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

class function TCrashChildProcess_AllInOne.AutoTest(out OutLines: TArray<string>): Boolean;
var
  Lines: TList<string>;
  Progress: TCrashTestProgress;
begin
  Lines := TList<string>.Create;
  Progress := TCrashTestProgress.Create(Lines);
  try
    Progress.Skip('child-process scenarios run on Linux x64 / macOS only');
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
    'CrashChildProcess',
    'Fatal faults in a child process leave the expected .el',
    ['crash', 'child', 'fatal', 'posix'],
    TCrashChildProcess_AllInOne.AutoTest,
    ctkRunnerOnly
  );

{$ENDIF}

end.
