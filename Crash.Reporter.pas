unit Crash.Reporter;

{ Public orchestrator of the Crash Reporter library.

  Part of the Crash Reporter library - standalone, EurekaLog-compatible
  crash/exception reporting for Delphi cross-platform targets.

  On non-Windows targets (FMX Linux / macOS / Android / iOS / console) it traps
  unhandled exceptions, builds an EurekaLog-compatible .el report (call stack,
  registers, modules), and - per TCrashConfig - saves it to a file, uploads it
  to a server, and/or shows a modal dialog. On Windows it is a no-op (use
  EurekaLog there).

  Usage:
    var Cfg := DefaultCrashConfig;
    Cfg.AppVersion      := '1.2.3.4';
    Cfg.CompilationTime := '28.05.2026 14:00:00';
    Cfg.UploadEnabled   := True;
    Cfg.UploadUrl       := 'https://example.com/upload.php';
    Cfg.OnShowDialog    := ShowMyDialog;   // optional (GUI only)
    TCrashReporter.Init(Cfg);
    for var R in TCrashReporter.TakePending do
      Writeln(ErrOutput, R);

  Init is called once at startup, before any forms are created. It is idempotent.
  On Init it scans the exe directory for leftover .el files from previous runs;
  depending on the config they are uploaded (and deleted on success) or just
  collected. The collected reports are available via TakePending; the caller
  decides how to surface them (stderr, log, dialog, server). }

interface

uses
  Crash.CallStack; // TCrashConfig, TCrashReport, TCrashReportSection(s)

type
  { Shows a modal dialog with the full report text for non-fatal exceptions.
    Blocks until the user closes it. If nil, non-fatal exceptions fall back to a
    brief stderr message. Not called for fatal (csFatalProc) - the process is
    dying, only a brief stderr line is printed. }
  TCrashShowDialogProc = reference to procedure(const AReportText: String);

  { Optional: returns extra free-form text appended to the report as a trailing
    section (e.g. "what the app was doing"). Called at report time. }
  TCrashCollectContextProc = reference to function: String;

  { Everything the host can configure. Fill the fields you care about (start from
    DefaultCrashConfig) and pass to TCrashReporter.Init once at startup. }
  TCrashConfig = record
    { Shown in the report header. Empty -> ExtractFileName(ParamStr(0)). }
    AppName: String;
    { Shown in the report header. Host-supplied (the library has no version of
      its own). Empty -> blank. }
    AppVersion: String;
    { "1.5 Compilation Date" field. Host-supplied free-form string. }
    CompilationTime: String;
    { Persist the .el to disk next to the exe. Default True. }
    SaveToFile: Boolean;
    { File name prefix; the timestamp + ".el" are appended. Empty ->
      "<ExeBaseName>_<PLATFORM>_". Also drives the boot-recovery scan pattern. }
    FileNamePrefix: String;
    { Upload reports to UploadUrl. Default False (don't phone home unless asked). }
    UploadEnabled: Boolean;
    { Full upload endpoint URL (the host builds it). Multipart POST. }
    UploadUrl: String;
    { Multipart field name for the file part. Default 'el_upload_file_0'
      (EurekaLog-compatible). }
    UploadFieldName: String;
    { On Init, also (re)upload leftover .el files from previous runs. Requires
      UploadEnabled. Default False. }
    UploadPendingOnStartup: Boolean;
    { Allow the Restart action (platform-gated at runtime). Default True. }
    AllowRestart: Boolean;
    { GUI dialog provider for non-fatal exceptions. nil -> stderr fallback. }
    OnShowDialog: TCrashShowDialogProc;
    { Optional extra-context provider appended to the report. nil -> none. }
    OnCollectContext: TCrashCollectContextProc;
    { Report sections to OMIT entirely (header + body vanish). Default [] = full
      report. Application, Exception and Call Stack are never omittable (the first
      two carry the core crash info; the EL Viewer needs the Call Stack as the
      report's structural anchor) and are intentionally absent from
      TCrashReportSection. Use AllOptionalCrashReportSections to strip everything
      but those three. }
    DisabledSections: TCrashReportSections;
  end;

{ A config pre-filled with sensible defaults. Override the fields you need. }
function DefaultCrashConfig: TCrashConfig;

type
  { Public façade. All methods are class (static) methods backed by a singleton. }
  TCrashReporter = class
  public
    { Install hooks + scan for pending reports. Call once at startup. Idempotent. }
    class procedure Init(const AConfig: TCrashConfig); static;
    class function Active: Boolean; static;

    { Pending reports from previous runs (boot recovery). Empties the buffer. }
    class function TakePending: TArray<String>; static;
    { Convenience: dumps pending reports to ErrOutput when IsConsole. Idempotent. }
    class procedure SurfacePendingToStderr; static;

    { Upload a report. AFileName = the on-disk basename (server uses the same
      name). Returns True on HTTP 2xx. Honours the env var CRASH_NO_UPLOAD=1
      (skips the POST, keeps the file) for local testing. }
    class function Upload(const AReportText: String;
      const AFileName: String = ''): Boolean; static;

    { Restart the process with the same parameters, then Halt. CanRestart is
      False on sandboxed platforms (iOS/Android) or when AllowRestart=False. }
    class function CanRestart: Boolean; static;
    class procedure Restart; static;

    { Basename of the last written .el (so an upload uses the same name). }
    class function LastCrashFileName: String; static;

    { Delete the last written .el from disk. Call after a successful manual
      Upload (e.g. from the dialog) to mirror the fatal-path "delete on upload
      success" policy. No-op if there is no current file. }
    class procedure DeleteLastCrashFile; static;
  end;

implementation

uses
  System.Classes,
  System.SyncObjs,
  System.IOUtils,
  System.Generics.Collections,
  System.Net.HttpClient,
  System.Net.Mime,
  System.Net.URLClient,
  Crash.ELFormat,
  Crash.Signals,
  Crash.MacOS.Symbols,
  {$IF Defined(MSWINDOWS)}
  Winapi.Windows,
  {$IFEND}
  {$IF not Defined(MSWINDOWS)}
  Posix.Unistd, // getpid(), fork(), execv()
  Posix.Stdlib,
  Posix.SysTypes,
  Posix.Base,
  {$IFEND}
  System.SysUtils;

function DefaultCrashConfig: TCrashConfig;
begin
  Result := Default(TCrashConfig);
  Result.SaveToFile := True;
  Result.UploadEnabled := False;
  Result.UploadFieldName := 'el_upload_file_0';
  Result.UploadPendingOnStartup := False;
  Result.AllowRestart := True;
end;

function GetExeBaseName: String; inline;
begin
  Result := ChangeFileExt(ExtractFileName(ParamStr(0)), '');
end;

function GetPlatformTag: String; inline;
begin
  {$IF Defined(MSWINDOWS)}  Result := 'WIN';
  {$ELSEIF Defined(ANDROID)}Result := 'ANDROID';
  {$ELSEIF Defined(IOS)}    Result := 'IOS';
  {$ELSEIF Defined(MACOS)}  Result := 'MACOS';
  {$ELSEIF Defined(LINUX)}  Result := 'LINUX';
  {$ELSE}                   Result := 'UNKNOWN';
  {$IFEND}
end;

type
  TCrashReporterImpl = class
  private
    FConfig: TCrashConfig;
    FInstalled: Boolean;
    FLock: TCriticalSection;
    FAlreadyReported: Boolean;  // anti-cascade: the capture hook can fire 2-3 times for one raise (ExceptProc + ExceptionAcquired + fallback). Reset after processing (non-fatal).
    FCrashFilePath: String;     // computed once so cascade calls don't fight over different names
    FPendingReports: TArray<String>;
    FAppStartTime: TDateTime;   // captured in Init for the Up Time field
    function EffectiveFileNamePrefix: String;
    function BuildCrashFilePath: String;
    procedure WriteFatalBriefToConsole(const AReport: TCrashReport);
    procedure WriteToFile(const AText: String);
    procedure ResetAlreadyReported;
    procedure HandleReport(const AReport: TCrashReport);
    procedure ScanPendingCrashReports;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Install(const AConfig: TCrashConfig);
    function TakePendingCrashReports: TArray<String>;
  end;

var
  GReporter: TCrashReporterImpl;

constructor TCrashReporterImpl.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FAppStartTime := Now; // "close enough to process start"
end;

destructor TCrashReporterImpl.Destroy;
begin
  TCrashCapture.OnReport := nil;
  FreeAndNil(FLock);
  inherited;
end;

function TCrashReporterImpl.EffectiveFileNamePrefix: String;
begin
  if FConfig.FileNamePrefix <> '' then
    Result := FConfig.FileNamePrefix
  else
    Result := GetExeBaseName + '_' + GetPlatformTag + '_';
end;

function TCrashReporterImpl.BuildCrashFilePath: String;
var
  Dir, Stamp: String;
begin
  Dir := ExtractFilePath(ParamStr(0));
  if Dir = '' then
    Dir := TPath.GetTempPath;
  // <prefix><yyyymmddhhnnss>.el - prefix (project + platform by default) keeps
  // reports from different builds/targets from merging. .el lets the EurekaLog
  // Viewer open it natively.
  Stamp := FormatDateTime('yyyymmddhhnnss', Now);
  Result := IncludeTrailingPathDelimiter(Dir) + EffectiveFileNamePrefix + Stamp + '.el';
end;

procedure TCrashReporterImpl.WriteFatalBriefToConsole(const AReport: TCrashReport);
var
  Loc: TCrashStackEntry;
  AtStr, AppLabel: String;
begin
  if not IsConsole then
    Exit;
  try
    // EL-style brief: one short group of lines - what crashed, where, and where
    // the full report was written. The full stack trace is in the file.
    Loc := AReport.ExceptionLocation;
    if Loc.RoutineName <> '' then
    begin
      AtStr := Loc.RoutineName;
      if Loc.RoutineAddress > 0 then
        AtStr := AtStr + ' + ' + IntToStr(Loc.CodeAddress - Loc.RoutineAddress);
    end
    else
      AtStr := '$' + IntToHex(Loc.CodeAddress, 16);

    if FConfig.AppName <> '' then AppLabel := FConfig.AppName
    else                          AppLabel := GetExeBaseName;

    Writeln(ErrOutput);
    Writeln(ErrOutput, '*** ', AppLabel, ': unhandled exception, process terminating ***');
    Writeln(ErrOutput, 'Exception: ', AReport.ExceptionMessage);
    Writeln(ErrOutput, 'At: ', AtStr);
    if FCrashFilePath <> '' then
      Writeln(ErrOutput, 'Full report saved to: ', FCrashFilePath);
    Writeln(ErrOutput, '*** END ***');
    Flush(ErrOutput);
  except
    // If the console is unavailable (e.g. GUI without an attached console),
    // ignore silently; the file output still works.
  end;
end;

procedure TCrashReporterImpl.WriteToFile(const AText: String);
begin
  if FCrashFilePath = '' then
    FCrashFilePath := BuildCrashFilePath;
  try
    // UTF-16LE + BOM - same encoding as a Windows EL build, so the Viewer
    // accepts it.
    TFile.WriteAllText(FCrashFilePath, AText, TEncoding.Unicode);
  except
    // Crashing inside a crash handler is the worst outcome. Stay silent.
  end;
end;

procedure TCrashReporterImpl.ResetAlreadyReported;
begin
  FLock.Enter;
  try
    FAlreadyReported := False;
    FCrashFilePath := '';
  finally
    FLock.Leave;
  end;
end;

procedure TCrashReporterImpl.HandleReport(const AReport: TCrashReport);
var
  Text: String;
  Ctx: TCrashELContext;
  IsFatal: Boolean;
  LocalDialogProc: TCrashShowDialogProc;
begin
  // Anti-cascade under the lock. Long operations (dialog) happen outside it.
  FLock.Enter;
  try
    if FAlreadyReported then
      Exit;
    FAlreadyReported := True;
  finally
    FLock.Leave;
  end;

  IsFatal := AReport.Source = csFatalProc;
  Ctx := CrashDefaultELContext(FAppStartTime);
  // Overlay the host-supplied identity fields from the config.
  if FConfig.AppName <> '' then Ctx.AppName := FConfig.AppName;
  Ctx.AppVersion := FConfig.AppVersion;
  Ctx.CompileTime := FConfig.CompilationTime;
  Ctx.DisabledSections := FConfig.DisabledSections;
  // Exception thread: HandleReport runs synchronously in the crashing thread
  // (RTL hook -> TCrashCapture.ReportException -> OnReport -> here), so
  // CurrentThread IS the faulting thread - capture its real ID and name.
  Ctx.ThreadID := Cardinal(TThread.CurrentThread.ThreadID);
  // RTL has no readable TThread.Name (naming is set-only via
  // NameThreadForDebugging), so worker threads get a generic label - the real
  // TID is shown on the "*Exception Thread: ID=..." line above.
  if TThread.CurrentThread.ThreadID = MainThreadID then
    Ctx.ThreadName := 'MAIN'
  else
    Ctx.ThreadName := 'Worker';
  // Optional extra-context section provided by the host.
  if Assigned(FConfig.OnCollectContext) then
  try
    var Extra := FConfig.OnCollectContext();
    if Extra <> '' then
    begin
      if Ctx.SignalInfoSection <> '' then
        Ctx.SignalInfoSection := Ctx.SignalInfoSection + #13#10;
      Ctx.SignalInfoSection := Ctx.SignalInfoSection + Extra;
    end;
  except
    // A faulty context provider must not break reporting.
  end;
  Text := CrashBuildELReportText(AReport, Ctx);

  if FConfig.SaveToFile then
    WriteToFile(Text); // WriteToFile locks FCrashFilePath itself

  if IsFatal then
  begin
    // Process is about to die. Brief stderr is the only live signal; the full
    // text is already in the file. FAlreadyReported stays True - cascade calls
    // (RTL cleanup sometimes calls ExceptionAcquired after ExceptProc) are eaten.
    WriteFatalBriefToConsole(AReport);
    // EL-style: upload + delete-on-success, otherwise keep the file as-is.
    try
      if TCrashReporter.Upload(Text, ExtractFileName(FCrashFilePath)) then
      begin
        Writeln(ErrOutput, 'Upload: OK (report sent, local file removed)');
        if FCrashFilePath <> '' then
          try TFile.Delete(FCrashFilePath); except end;
      end
      else if FConfig.UploadEnabled then
        Writeln(ErrOutput, 'Upload: FAILED - report kept at ', FCrashFilePath);
      Flush(ErrOutput);
    except
      on E: Exception do
        Writeln(ErrOutput, 'Upload: EXCEPTION ' + E.ClassName + ': ' + E.Message);
    end;
    Exit;
  end;

  // Non-fatal: the process keeps running. Show the dialog if there is a handler.
  // Re-arm: on Linux our signal handler is "one-shot" - after the snapshot it
  // restored prev (Pascal RTL) and thereby removed itself from active. Without a
  // re-install the NEXT hardware crash goes straight to the Pascal RTL, bypassing
  // us -> later .el files would lack the "Registers:" section. This crash's
  // snapshot was already consumed in CrashBuildELReportText above, so re-install
  // is safe; GOldHandlers keeps the original Pascal RTL handler.
  CrashInstallSignalHandlers;

  LocalDialogProc := FConfig.OnShowDialog;
  if Assigned(LocalDialogProc) then
  begin
    {$IF Defined(LINUX)}
    // ForceQueue (NOT Synchronize) on Linux: show the dialog from a CLEAN
    // main-loop iteration, after the exception-handling stack has fully unwound.
    // Synchronize ran ShowModal immediately INSIDE the nested crash-exception
    // stack (crash -> ExceptProc -> Pascal RTL -> FMX HandleException -> here),
    // and the modal window's first paint from there hung/crashed on FMXLinux+WSLg
    // (~20% of runs). ForceQueue defers the show to the next main-loop iteration
    // when the stack is clean. ResetAlreadyReported moves inside the callback
    // (ForceQueue is async).
    TThread.ForceQueue(nil,
      procedure
      begin
        try
          LocalDialogProc(Text);
        except
          // A dialog exception must not kill the crash reporter.
        end;
        ResetAlreadyReported;
      end);
    {$ELSE}
    try
      TThread.Synchronize(nil,
        procedure
        begin
          try
            LocalDialogProc(Text);
          except
            // A dialog exception must not kill the crash reporter.
          end;
        end);
    finally
      ResetAlreadyReported;
    end;
    {$IFEND}
  end
  else
  begin
    // No dialog handler (e.g. worker-thread exception in a console target). Behave
    // like the fatal path: brief stderr + try upload + delete-or-keep.
    WriteFatalBriefToConsole(AReport);
    try
      if TCrashReporter.Upload(Text, ExtractFileName(FCrashFilePath)) then
      begin
        Writeln(ErrOutput, 'Upload: OK (report sent, local file removed)');
        if FCrashFilePath <> '' then
          try TFile.Delete(FCrashFilePath); except end;
      end
      else if FConfig.UploadEnabled then
        Writeln(ErrOutput, 'Upload: FAILED - report kept at ', FCrashFilePath);
      Flush(ErrOutput);
    except
    end;
    ResetAlreadyReported;
  end;
end;

procedure TCrashReporterImpl.Install(const AConfig: TCrashConfig);
begin
  FConfig := AConfig;
  if FInstalled then
    Exit;
  FInstalled := True;

  // TCrashCapture is created in Crash.CallStack's initialization (it installs
  // ExceptProc / ExceptionAcquired / GetExceptionStackInfoProc). Here we just
  // route its reports to us. Application.OnException is UI-specific and is wired
  // by the host where Application exists (the FMX .dpr).
  TCrashCapture.OnReport := HandleReport;

  // Boot-recovery: pick up crash files from previous runs. Done after wiring the
  // handler so any exception during the scan lands in our handler too.
  ScanPendingCrashReports;
end;

procedure TCrashReporterImpl.ScanPendingCrashReports;
var
  Dir, FilePath, Text, Pattern: String;
  Files: TArray<String>;
  Kept: TList<String>;
  TryUpload: Boolean;
begin
  Dir := ExtractFilePath(ParamStr(0));
  if Dir = '' then
    Exit;
  // Match this build's prefix only: different targets in one folder don't eat
  // each other's files.
  Pattern := EffectiveFileNamePrefix + '*.el';

  Files := nil;
  try
    Files := TDirectory.GetFiles(Dir, Pattern);
  except
    Exit; // directory unavailable - don't fail bootstrap
  end;

  TryUpload := FConfig.UploadEnabled and FConfig.UploadPendingOnStartup;

  Kept := TList<String>.Create;
  try
    for FilePath in Files do
    begin
      try
        Text := TFile.ReadAllText(FilePath, TEncoding.Unicode);
        if TryUpload and TCrashReporter.Upload(Text, ExtractFileName(FilePath)) then
        begin
          try TFile.Delete(FilePath); except end; // sent -> remove
        end
        else
          Kept.Add(Text); // leave the file on disk; surfacing is optional
      except
        // Couldn't read - skip silently; the file stays.
      end;
    end;
    FPendingReports := Kept.ToArray;
  finally
    Kept.Free;
  end;
end;

function TCrashReporterImpl.TakePendingCrashReports: TArray<String>;
begin
  Result := FPendingReports;
  FPendingReports := nil;
end;

{ ---- TCrashReporter façade ---- }

class procedure TCrashReporter.Init(const AConfig: TCrashConfig);
begin
  if GReporter = nil then
    GReporter := TCrashReporterImpl.Create;
  GReporter.Install(AConfig);
  // POSIX: capture registers + stack for AV/div0/illegal-instruction before the
  // kernel re-delivers the signal to the Pascal RTL handler. No-op on Windows.
  CrashInstallSignalHandlers;
  // macOS: build the Pascal-symbol cache from the running Mach-O LC_SYMTAB so the
  // call stack shows real function names (not the nearest dladdr export). No-op
  // elsewhere.
  CrashInitMacOSSymbolCache;
  // Eager-init the LineNumberInfo singleton on a quiet startup path. Otherwise
  // the first .gol read happens during the FIRST exception inside
  // GetCallStackEntry; if loading itself crashes, that's a double-fault inside
  // the RTL exception handler and the process silently terminates with no .el.
  // Loading early surfaces any load problem at startup (easy to reproduce) while
  // the eventual crash path is just a cheap lookup against a populated cache.
  {$IF (Defined(MACOS64) and not Defined(IOS)) or Defined(LINUX)}
  try
    TCrashCapture.GetLineNumberInfo;
  except
    // Surviving an init failure here matters more than line numbers. The reporter
    // still works, just with the "0[+$N]" proxy in the Line column.
  end;
  {$IFEND}
  // The Pascal RTL and some libraries (FMX Linux init, libcurl, ...) may install
  // their own SIGFPE/SIGSEGV sigaction AFTER our Install, clobbering our handler
  // before the first crash. So we re-install via TThread.ForceQueue: it runs on
  // the main thread in the next event-loop iteration, after all other init has
  // finished. The PrevIsOurselves guard in Crash.Signals keeps the original
  // Pascal RTL handler on the repeat.
  TThread.ForceQueue(nil, procedure
  begin
    CrashInstallSignalHandlers;
  end);
end;

class function TCrashReporter.Active: Boolean;
begin
  Result := (GReporter <> nil) and GReporter.FInstalled;
end;

class function TCrashReporter.LastCrashFileName: String;
begin
  if GReporter = nil then Result := ''
  else                    Result := ExtractFileName(GReporter.FCrashFilePath);
end;

class procedure TCrashReporter.DeleteLastCrashFile;
begin
  if (GReporter <> nil) and (GReporter.FCrashFilePath <> '') then
  begin
    try TFile.Delete(GReporter.FCrashFilePath); except end;
    GReporter.FCrashFilePath := '';
  end;
end;

class function TCrashReporter.TakePending: TArray<String>;
begin
  if GReporter <> nil then
    Result := GReporter.TakePendingCrashReports
  else
    Result := nil;
end;

class function TCrashReporter.Upload(const AReportText: String;
  const AFileName: String): Boolean;
var
  Client: THTTPClient;
  Form: TMultipartFormData;
  Bytes: TBytes;
  Stream: TBytesStream;
  Resp: IHTTPResponse;
  UploadName, FieldName: String;
begin
  Result := False;
  if (GReporter = nil) or (not GReporter.FConfig.UploadEnabled) or
     (GReporter.FConfig.UploadUrl = '') then
    Exit;
  // Test/dev escape: env CRASH_NO_UPLOAD=1 -> skip the POST and keep the file,
  // so a local .el can be read without a network side effect.
  if GetEnvironmentVariable('CRASH_NO_UPLOAD') = '1' then Exit;

  // File body bytes - UTF-16LE with BOM, same as the .el on disk.
  Bytes := TEncoding.Unicode.GetPreamble + TEncoding.Unicode.GetBytes(AReportText);

  // Server-side name = on-disk name, so logs/monitoring keep the context.
  if AFileName <> '' then UploadName := AFileName
  else                    UploadName := 'BugReport.el';

  FieldName := GReporter.FConfig.UploadFieldName;
  if FieldName = '' then FieldName := 'el_upload_file_0';

  Stream := TBytesStream.Create(Bytes);
  try
    Client := THTTPClient.Create;
    try
      Client.ConnectionTimeout := 10000;
      Client.ResponseTimeout := 30000;
      Form := TMultipartFormData.Create(True);
      try
        Form.AddStream(FieldName, Stream, UploadName, 'application/octet-stream');
        try
          Resp := Client.Post(GReporter.FConfig.UploadUrl, Form);
          Result := (Resp <> nil) and (Resp.StatusCode >= 200) and (Resp.StatusCode < 300);
        except
          // Network errors must not crash the process. The file is on disk, the
          // report isn't lost.
          Result := False;
        end;
      finally
        Form.Free;
      end;
    finally
      Client.Free;
    end;
  finally
    Stream.Free;
  end;
end;

class function TCrashReporter.CanRestart: Boolean;
begin
  if (GReporter <> nil) and (not GReporter.FConfig.AllowRestart) then
    Exit(False);
  {$IF Defined(MSWINDOWS) or Defined(LINUX) or (Defined(MACOS) and not Defined(IOS))}
  Result := True;
  {$ELSE}
  Result := False; // iOS/Android sandbox - not allowed
  {$IFEND}
end;

{$IF not Defined(MSWINDOWS)}
// POSIX fork/execv
function fork: pid_t; cdecl; external libc name _PU + 'fork';
function execv(path: MarshaledAString; argv: PMarshaledAString): Integer; cdecl;
  external libc name _PU + 'execv';
{$IFEND}

class procedure TCrashReporter.Restart;
{$IF Defined(MSWINDOWS)}
var
  SI: TStartupInfo;
  PI: TProcessInformation;
  CmdLine: String;
{$ELSEIF Defined(LINUX) or Defined(MACOS)}
var
  ChildPid: pid_t;
  ArgList: array of TBytes;
  Argv: array of MarshaledAString;
  ExePath: TBytes;
  I: Integer;
{$IFEND}
begin
  if not CanRestart then
  begin
    Halt(0);
    Exit;
  end;

  {$IF Defined(MSWINDOWS)}
  CmdLine := GetCommandLine;
  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  if CreateProcess(nil, PChar(CmdLine), nil, nil, False, 0, nil, nil, SI, PI) then
  begin
    CloseHandle(PI.hProcess);
    CloseHandle(PI.hThread);
  end;
  Halt(0);
  {$ELSEIF Defined(LINUX) or Defined(MACOS)}
  ChildPid := fork;
  if ChildPid = 0 then
  begin
    // Child: execv ourselves with the same argv. If execv returns, it failed.
    SetLength(ArgList, ParamCount + 1);
    SetLength(Argv, ParamCount + 2); // +1 for the NULL terminator
    for I := 0 to ParamCount do
    begin
      ArgList[I] := TEncoding.UTF8.GetBytes(ParamStr(I));
      SetLength(ArgList[I], Length(ArgList[I]) + 1); // null-terminate
      Argv[I] := MarshaledAString(@ArgList[I][0]);
    end;
    Argv[ParamCount + 1] := nil;
    ExePath := TEncoding.UTF8.GetBytes(ParamStr(0));
    SetLength(ExePath, Length(ExePath) + 1);
    execv(MarshaledAString(@ExePath[0]), @Argv[0]);
    // execv returned -> failure, exit.
    Halt(127);
  end;
  // Parent (or fork failed - ChildPid=-1) - exit.
  Halt(0);
  {$ELSE}
  Halt(0);
  {$IFEND}
end;

class procedure TCrashReporter.SurfacePendingToStderr;
var
  Reports: TArray<String>;
  R: String;
begin
  if not IsConsole then
  begin
    // Still Take, so pending reports don't linger and get re-emitted by an honest
    // consumer later. The files remain on disk, so the data is preserved.
    TakePending;
    Exit;
  end;
  Reports := TakePending;
  if Length(Reports) = 0 then
    Exit;
  try
    for R in Reports do
    begin
      Writeln(ErrOutput, '*** previous-run crash report (boot recovery) ***');
      Writeln(ErrOutput, R);
      Writeln(ErrOutput, '*** END previous-run crash report ***');
    end;
    Flush(ErrOutput);
  except
  end;
end;

initialization

finalization
  FreeAndNil(GReporter);

end.
