unit CrashDemo.Runtime;

interface

uses
  System.Classes;

type
  TCrashDemoWorker = class(TThread)
  protected
    procedure Execute; override;
  public
    constructor Create;
  end;

procedure CrashDemoInitialize;
procedure CrashDemoShutdown;
procedure CrashDemoResetArtifacts;
function CrashDemoReportDir: String;
function CrashDemoStatusText: String;

procedure CrashDemoTriggerSoftwareRaise;
procedure CrashDemoTriggerAccessViolation;
procedure CrashDemoTriggerStackOverflow;
procedure CrashDemoTriggerFreeze;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.StrUtils,
  System.TypInfo,
  Crash.Signals,
  Crash.Reporter;

var
  GConfig: TCrashConfig;
  GReportDir: String;
  GConfigReady: Boolean;
  GStarted: Boolean;

procedure PrepareConfig;
var
  AppDir: String;
begin
  if GConfigReady then
    Exit;

  AppDir := TPath.Combine(TPath.GetDocumentsPath, 'CrashDemoFMX');
  GReportDir := TPath.Combine(AppDir, 'CrashReports');

  GConfig := DefaultCrashConfig;
  GConfig.AppName := 'CrashDemoFMX';
  GConfig.AppVersion := '1.0.0';
  GConfig.CompilationTime := FormatDateTime('yyyy-mm-dd hh:nn:ss', Now);
  GConfig.ReportDir := GReportDir;
  GConfig.SaveToFile := True;
  GConfig.UploadEnabled := False;
  GConfig.FileNameTemplate := '{App}_{Platform}_{Version}_{BugID}.el';
  GConfig.FreezeDetection := True;
  GConfig.FreezeTimeoutMS := 10000;
  GConfig.RestartOnFreeze := False;
  GConfig.OnShowDialog := nil;
  GConfigReady := True;
end;

procedure CrashDemoInitialize;
begin
  if GStarted then
    Exit;
  PrepareConfig;
  TDirectory.CreateDirectory(GReportDir);
  TCrashReporter.Init(GConfig);
  GStarted := TCrashReporter.Active;
  TCrashReporter.AddBreadcrumb('lifecycle', 'started');
end;

procedure CrashDemoShutdown;
begin
  if not GStarted then
    Exit;
  TCrashReporter.Shutdown;
  GStarted := False;
end;

function IsCrashArtifact(const AFileName: String): Boolean;
var
  LowerName: String;
begin
  LowerName := LowerCase(AFileName);
  Result := EndsText('.el', LowerName) or
            EndsText('.pending', LowerName) or
            EndsText('.crashraw', LowerName) or
            ContainsText(LowerName, '.el.tmp.') or
            EndsText('freeze_restart.notice', LowerName);
end;

procedure DeleteCrashArtifacts;
var
  FileName: String;
begin
  if not TDirectory.Exists(GReportDir) then
    Exit;
  for FileName in TDirectory.GetFiles(GReportDir) do
    if IsCrashArtifact(ExtractFileName(FileName)) then
      TFile.Delete(FileName);
end;

procedure CrashDemoResetArtifacts;
begin
  CrashDemoShutdown;
  try
    DeleteCrashArtifacts;
  finally
    CrashDemoInitialize;
  end;
end;

function CrashDemoReportDir: String;
begin
  PrepareConfig;
  Result := GReportDir;
end;

function CoverageText(const AName: String;
  const ACoverage: TCrashThreadCoverage): String;
begin
  if not ACoverage.Registered then
    Exit(AName + ': not registered');
  Result := Format('%s: id=%d name=%s alt=%s mach=%s',
    [AName, ACoverage.ThreadID, ACoverage.Name,
     GetEnumName(TypeInfo(TCrashAltStackState), Ord(ACoverage.AltStack)),
     GetEnumName(TypeInfo(TCrashMachState), Ord(ACoverage.MachHandler))]);
end;

function CrashDemoStatusText: String;
var
  Status: TCrashStatus;
begin
  Status := TCrashReporter.GetStatus;
  Result := Format(
    'Active: %s' + sLineBreak +
    'Signal handlers: %s' + sLineBreak +
    'Freeze detector: %s' + sLineBreak +
    'Registered threads: %d' + sLineBreak +
    '%s' + sLineBreak +
    '%s',
    [BoolToStr(Status.Active, True),
     BoolToStr(Status.SignalHandlersInstalled, True),
     BoolToStr(Status.FreezeDetectorActive, True),
     Status.RegisteredThreadCount,
     CoverageText('Main', Status.MainThread),
     CoverageText('Current', Status.CurrentThread)]);
end;

procedure CrashDemoTriggerSoftwareRaise;
begin
  raise Exception.Create('test raise from CrashDemoFMX');
end;

procedure CrashDemoTriggerAccessViolation;
var
  P: PInteger;
begin
  P := nil;
  P^ := 42;
end;

function BurnStack(const ADepth: Integer): NativeInt;
var
  Pad: array[0..511] of NativeInt;
begin
  Pad[0] := ADepth;
  Pad[High(Pad)] := ADepth + 1;
  Result := BurnStack(ADepth + 1) + Pad[0] + Pad[High(Pad)];
end;

procedure CrashDemoTriggerStackOverflow;
begin
  if BurnStack(1) = 0 then
    raise Exception.Create('unreachable stack-overflow result');
end;

procedure CrashDemoTriggerFreeze;
var
  Deadline: UInt64;
begin
  Deadline := TThread.GetTickCount64 + 15000;
  while TThread.GetTickCount64 < Deadline do
    ;
end;

constructor TCrashDemoWorker.Create;
begin
  inherited Create(True);
  FreeOnTerminate := False;
end;

procedure TCrashDemoWorker.Execute;
var
  I: Integer;
begin
  TCrashReporter.RegisterCurrentThread('DemoWorker');
  try
    TCrashReporter.AddBreadcrumb('worker', 'registered');
    { Keep coverage visible in the status panel before provoking the fault. }
    for I := 1 to 15 do
    begin
      if Terminated then
        Exit;
      Sleep(50);
    end;
    CrashDemoTriggerAccessViolation;
  finally
    TCrashReporter.UnregisterCurrentThread;
  end;
end;

end.
