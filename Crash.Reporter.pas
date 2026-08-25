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
  Crash.CallStack, // TCrashConfig, TCrashReport, TCrashReportSection(s)
  Crash.Freeze;    // TCrashFreezeInfo / TCrashFreezeReportProc (freeze detector)

type
  { Shows a modal dialog with the full report text for non-fatal exceptions.
    Blocks until the user closes it. If nil, non-fatal exceptions fall back to a
    brief stderr message. Not called for fatal (csFatalProc) - the process is
    dying, only a brief stderr line is printed. }
  TCrashShowDialogProc = reference to procedure(const AReportText: String);

  { Optional: returns extra free-form text appended to the report as a trailing
    section (e.g. "what the app was doing"). Called at report time. }
  TCrashCollectContextProc = reference to function: String;

  { Optional last-step veto. Called with the fully-built report (message, class,
    stack, source) right before it is persisted/surfaced. Return False to drop the
    report entirely; True (or a nil callback) keeps it. Runs in the crash path -
    keep it cheap and robust. An exception raised by the filter is swallowed and
    the report is KEPT: a faulty filter must never suppress a real crash. }
  TCrashReportFilterProc = reference to function(const AReport: TCrashReport): Boolean;

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
      "<ExeBaseName>_<PLATFORM>_". }
    FileNamePrefix: String;
    { Boot-recovery scan prefix (the scan matches "<prefix>*.el"). Empty ->
      FileNamePrefix. Set a STABLE prefix (no version token) when FileNamePrefix
      embeds an app version, so reports written by a previous version are still
      picked up after an update. }
    ScanFileNamePrefix: String;
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
    { Optional last-step veto: return False to drop a report (e.g. user-initiated
      Ctrl-C / EControlC, or other known-benign exceptions). nil -> keep all. }
    OnFilterReport: TCrashReportFilterProc;
    { Report sections to OMIT entirely (header + body vanish). Default [] = full
      report. Application, Exception and Call Stack are never omittable (the first
      two carry the core crash info; the EL Viewer needs the Call Stack as the
      report's structural anchor) and are intentionally absent from
      TCrashReportSection. Use AllOptionalCrashReportSections to strip everything
      but those three. }
    DisabledSections: TCrashReportSections;
    { Directory for the .el reports (both writing and the boot-recovery scan).
      Empty -> platform default: on Android/iOS the app's private documents dir
      (TPath.GetDocumentsPath - the package dir is read-only); on macOS the
      directory NEXT TO the .app bundle (never inside it - writing into a bundle
      breaks code signing, fails on read-only install locations, and is invisible
      to users); the executable's own directory on Linux/Windows. Trailing path
      delimiter optional. }
    ReportDir: String;
    { Freeze (hang) detection - see Crash.Freeze. Default False (opt in): keep
      it off until the detector has proven itself on the target app. Active
      only on targets with capture support (currently Linux x86-64); elsewhere
      the flag is accepted and ignored. Report-only: the frozen thread is
      never aborted. The host must call TCrashFreeze.Ping from the watched
      (main) loop, otherwise detection stays dormant. }
    FreezeDetection: Boolean;
    { No-heartbeat threshold before a freeze report is captured. Default 30000. }
    FreezeTimeoutMS: Integer;
    { Fired (on the WATCHDOG thread) after a freeze report is handled - lets
      the host log/notify. Keep it cheap and thread-safe. }
    OnFreezeReport: TCrashFreezeReportProc;
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

    { Init-time verdict: True when Init's Mach thread registration succeeded
      (vacuously True on targets without a Mach layer). Reflects ONLY the
      registration made at Init - it does not track the watcher's later
      lifetime, and it says nothing about other threads' coverage. False =
      main-thread hardware-fault reports lack the Registers section (their
      Crash Signal Info section says so too). }
    class function MainThreadMachCovered: Boolean; static;

    { Enable the freeze detector after Init (e.g. from a CLI switch parsed
      later in startup). Equivalent to Init with FreezeDetection=True; no-op
      when the reporter is not installed. Must be called on the watched
      (main) thread - it is the capture target. }
    class procedure EnableFreezeDetection(const ATimeoutMS: Integer); static;
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
  Crash.MacOS.MachExc,
  Crash.Android.Symbols,
  {$IF Defined(MSWINDOWS)}
  Winapi.Windows,
  {$ENDIF}
  {$IF not Defined(MSWINDOWS)}
  Posix.Unistd, // getpid(), fork(), execv()
  Posix.Stdlib,
  Posix.SysTypes,
  Posix.Base,
  {$ENDIF}
  System.SysUtils;

function DefaultCrashConfig: TCrashConfig;
begin
  Result := Default(TCrashConfig);
  Result.SaveToFile := True;
  Result.UploadEnabled := False;
  Result.UploadFieldName := 'el_upload_file_0';
  Result.UploadPendingOnStartup := False;
  Result.AllowRestart := True;
  Result.FreezeDetection := False; // opt in - see the field comment
  Result.FreezeTimeoutMS := 30000;
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
  {$ENDIF}
end;

type
  TCrashReporterImpl = class
  private
    FConfig: TCrashConfig;
    FInstalled: Boolean;
    FLock: TCriticalSection;
    FAlreadyReported: Boolean;  // anti-cascade: the capture hook can fire 2-3 times for one raise (ExceptProc + ExceptionAcquired + fallback). Reset after processing (non-fatal).
    FCrashFilePath: String;     // computed once so cascade calls don't fight over different names
    FExceptionID: String;       // EL-style BugID of the current report; the .el file-name token (set in HandleReport before WriteToFile)
    FPendingReports: TArray<String>;
    FAppStartTime: TDateTime;   // captured in Init for the Up Time field
    FMachMainThreadCovered: Boolean; // Init-time Mach registration verdict (main thread only; NOT a live watcher status)
    function EffectiveFileNamePrefix: String;
    function EffectiveScanPrefix: String;
    function EffectiveReportDir: String;
    function BuildCrashFilePath: String;
    procedure WriteCrashBriefToConsole(const AReport: TCrashReport;
      const ATerminating: Boolean);
    procedure ConsoleLine(const S: String);
    procedure WriteToFile(const AText: String);
    function WriteReportTextToUniqueFile(const AText: String;
      var APath: String): Boolean;
    procedure ResetAlreadyReported;
    procedure HandleReport(const AReport: TCrashReport);
    procedure DoHandleReport(const AReport: TCrashReport);
    procedure InstallFreezeDetector;
    procedure HandleFreezeCapture(const AReport: TCrashReport;
      const AFrozenForMS: Int64);
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
  FMachMainThreadCovered := True; // no verdict yet - only Init's registration may flip it
  FAppStartTime := Now; // "close enough to process start"
end;

destructor TCrashReporterImpl.Destroy;
begin
  // Stop the freeze watchdog BEFORE the singleton goes away: its capture and
  // suppress hooks are closures over Self.
  TCrashFreeze.Shutdown;
  TCrashFreeze.OnCapture := nil;
  TCrashFreeze.OnExternalSuppress := nil;
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

function TCrashReporterImpl.EffectiveScanPrefix: String;
begin
  if FConfig.ScanFileNamePrefix <> '' then
    Result := FConfig.ScanFileNamePrefix
  else
    Result := EffectiveFileNamePrefix;
end;

function TCrashReporterImpl.EffectiveReportDir: String;
var
  ExeDir: String;
  {$IF Defined(MACOS)}
  ExePath, MacOSDir, ContentsDir, AppDir: String;
  {$ENDIF}
begin
  // 1. Explicit host override always wins.
  if FConfig.ReportDir <> '' then
    Exit(IncludeTrailingPathDelimiter(FConfig.ReportDir));

  {$IF Defined(ANDROID) or Defined(IOS)}
  // 2. Sandboxed mobile: the "exe" lives inside the read-only app package
  // (Android nativeLibraryDir / the iOS bundle), so ParamStr(0)'s directory is
  // not writable. Use the app's private documents dir - always writable, needs
  // no storage permission - which is exactly what a crash reporter wants
  // (it must succeed even when the process is already failing).
  ExeDir := TPath.GetDocumentsPath;
  {$ELSEIF Defined(MACOS)}
  // 2. macOS: if we're inside a .app bundle (.../<X>.app/Contents/MacOS/<exe>),
  // write reports NEXT TO the bundle, never inside it - writing into a bundle
  // breaks code signing, fails on read-only install locations, and is invisible
  // to users (Show Package Contents only). ExpandFileName resolves a relative
  // argv[0] (e.g. ./X launched from inside MacOS/) so the detection still works.
  ExePath     := ExpandFileName(ParamStr(0));
  MacOSDir    := ExcludeTrailingPathDelimiter(ExtractFilePath(ExePath));
  ContentsDir := ExcludeTrailingPathDelimiter(ExtractFilePath(MacOSDir));
  AppDir      := ExcludeTrailingPathDelimiter(ExtractFilePath(ContentsDir));
  if SameText(ExtractFileName(MacOSDir), 'MacOS') and
     SameText(ExtractFileName(ContentsDir), 'Contents') and
     SameText(ExtractFileExt(AppDir), '.app') then
    Exit(IncludeTrailingPathDelimiter(ExtractFilePath(AppDir)));
  ExeDir := ExtractFilePath(ExePath);
  {$ELSE}
  // 3. Linux / Windows: the executable's own directory.
  ExeDir := ExtractFilePath(ParamStr(0));
  {$ENDIF}

  if ExeDir = '' then
    ExeDir := TPath.GetTempPath;
  Result := IncludeTrailingPathDelimiter(ExeDir);
end;

function TCrashReporterImpl.BuildCrashFilePath: String;
var
  Dir, Tail: String;
begin
  Dir := EffectiveReportDir;
  // <prefix><id>.el - prefix (project + platform + version) keeps reports from
  // different builds/targets from merging; the EL-style exception ID (stable
  // BugID) is the uniqueness token, mirroring EurekaLog's "<proj>_<ver>_<id>".
  // The same bug yields the same name (WriteToFile appends a numeric suffix for
  // repeated instances). Fall back to a timestamp if the id is somehow empty, so
  // we never emit "<prefix>.el". .el lets the EurekaLog Viewer open it natively.
  if FExceptionID <> '' then
    Tail := FExceptionID
  else
    Tail := FormatDateTime('yyyymmddhhnnss', Now);
  Result := IncludeTrailingPathDelimiter(Dir) + EffectiveFileNamePrefix + Tail + '.el';
end;

procedure TCrashReporterImpl.ConsoleLine(const S: String);
// Best-effort stderr line: GUI builds may have no console, and a broken stderr
// must never throw out of the crash path.
begin
  if not IsConsole then Exit;
  try
    Writeln(ErrOutput, S);
    Flush(ErrOutput);
  except
  end;
end;

procedure TCrashReporterImpl.WriteCrashBriefToConsole(const AReport: TCrashReport;
  const ATerminating: Boolean);
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
    if ATerminating then
      Writeln(ErrOutput, '*** ', AppLabel, ': unhandled exception, process terminating ***')
    else
      Writeln(ErrOutput, '*** ', AppLabel, ': unhandled exception ***');
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

function TCrashReporterImpl.WriteReportTextToUniqueFile(const AText: String;
  var APath: String): Boolean;
// Shared write core (exception path via WriteToFile, freeze path directly).
// Never clobbers an existing report - appends a numeric suffix instead.
// APath is emptied on failure so "saved to ..." messaging stays honest.
var
  Base, Ext, Cand: String;
  N: Integer;
begin
  if TFile.Exists(APath) then
  begin
    Ext  := ExtractFileExt(APath);
    Base := ChangeFileExt(APath, '');
    N := 2;
    repeat
      Cand := Base + '_' + IntToStr(N) + Ext;
      Inc(N);
    until not TFile.Exists(Cand);
    APath := Cand;
  end;
  try
    // A custom ReportDir may not exist yet; the platform defaults always do.
    ForceDirectories(ExtractFilePath(APath));
    // UTF-16LE + BOM - same encoding as a Windows EL build, so the Viewer
    // accepts it.
    TFile.WriteAllText(APath, AText, TEncoding.Unicode);
    Result := True;
  except
    // Crashing inside a crash handler is the worst outcome. Stay silent.
    APath := '';
    Result := False;
  end;
end;

procedure TCrashReporterImpl.WriteToFile(const AText: String);
begin
  if FCrashFilePath = '' then
    FCrashFilePath := BuildCrashFilePath;
  // Safety net: the file name is stamped per-second (yyyymmddhhnnss), so two
  // distinct reports in the same second (two threads crashing, or a phantom that
  // slipped past the skip above) would collide. The unique-suffix logic in the
  // write core guarantees no real report is ever overwritten by another (the
  // root case - the content-less phantom - is already dropped in HandleReport).
  WriteReportTextToUniqueFile(AText, FCrashFilePath);
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

  try
    DoHandleReport(AReport);
  except
    // Restore the capture state in full before the capture layer swallows this
    // (ReportException ignores handler exceptions): drop a possibly un-consumed
    // snapshot, re-arm the one-shot signal handlers and the reporter - a
    // formatter failure must not degrade every future report of this process.
    CrashDiscardPendingSnapshot;
    CrashInstallSignalHandlers;
    ResetAlreadyReported;
    raise;
  end;
end;

procedure TCrashReporterImpl.DoHandleReport(const AReport: TCrashReport);
var
  Text: String;
  Ctx: TCrashELContext;
  IsFatal: Boolean;
  LocalDialogProc: TCrashShowDialogProc;
begin

  // Skip a content-less "phantom" report. The capture hook fires 2-3x per raise
  // (ExceptProc + ExceptionAcquired + fallback); the anti-cascade above coalesces
  // adjacent ones, but a report following a non-fatal one (which re-armed via
  // ResetAlreadyReported) can slip through with nothing behind it: a nil exception
  // object (CrashMsgNilException), an empty call stack, AND no signal snapshot
  // (the real report already consumed it). Such a report carries nothing
  // actionable and would only overwrite the real .el - drop it, but re-arm first
  // so a genuine later crash in a long-running process is still reported.
  if (AReport.ExceptionMessage = CrashMsgNilException) and
     (Length(AReport.CallStack) = 0) and
     (not CrashHasSignalSnapshot) then
  begin
    ResetAlreadyReported;
    Exit;
  end;

  // Optional host veto: drop this report if the filter returns False. A faulty
  // filter must not suppress a real crash, so on exception we keep the report.
  // Re-arm (like the phantom-skip) so a later genuine crash still reports.
  if Assigned(FConfig.OnFilterReport) then
  begin
    var KeepReport := True;
    try
      KeepReport := FConfig.OnFilterReport(AReport);
    except
      // keep on filter failure
    end;
    if not KeepReport then
    begin
      // Leave the same state as a delivered report: drop the un-consumed
      // hardware snapshot and re-arm the one-shot POSIX handlers.
      CrashDiscardPendingSnapshot;
      CrashInstallSignalHandlers;
      ResetAlreadyReported;
      Exit;
    end;
  end;

  IsFatal := AReport.Source = csFatalProc;
  // ExceptionLocation.CodeAddress keys the snapshot<->exception correlation in
  // CrashTakeAndFormatSnapshots (see Crash.Signals) - a snapshot left behind by
  // a swallowed concurrent/earlier fault must not pose as this exception's
  // Registers section.
  Ctx := CrashDefaultELContext(FAppStartTime, AReport.ExceptionLocation.CodeAddress);
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
  // macOS x86-64 whose Init (main-thread) Mach registration failed: state WHY
  // the Registers section is absent - but only in MAIN-thread reports; the
  // stored verdict says nothing about other threads' coverage.
  if (not FMachMainThreadCovered) and
     (TThread.CurrentThread.ThreadID = MainThreadID) then
  begin
    if Ctx.SignalInfoSection <> '' then
      Ctx.SignalInfoSection := Ctx.SignalInfoSection + #13#10;
    Ctx.SignalInfoSection := Ctx.SignalInfoSection +
      'Mach registration for the Init (main) thread failed - hardware-fault registers are unavailable in this report';
  end;
  Text := CrashBuildELReportText(AReport, Ctx);

  // The .el file name uses the exception's EL-style BugID as its token (see
  // BuildCrashFilePath). Compute it here, where AReport is in hand, before
  // WriteToFile builds the path.
  FExceptionID := CrashGenerateExceptionID(AReport);

  if FConfig.SaveToFile then
    WriteToFile(Text); // un-locked is safe: HandleReport is single-flight via FAlreadyReported

  if IsFatal then
  begin
    // Process is about to die. Brief stderr is the only live signal; the full
    // text is already in the file. FAlreadyReported stays True - cascade calls
    // (RTL cleanup sometimes calls ExceptionAcquired after ExceptProc) are eaten.
    WriteCrashBriefToConsole(AReport, True);
    // EL-style: upload + delete-on-success, otherwise keep the file as-is.
    try
      if TCrashReporter.Upload(Text, ExtractFileName(FCrashFilePath)) then
      begin
        ConsoleLine('Upload: OK (report sent, local file removed)');
        if FCrashFilePath <> '' then
          try TFile.Delete(FCrashFilePath); except end;
      end
      else if FConfig.UploadEnabled then
      begin
        if FCrashFilePath <> '' then
          ConsoleLine('Upload: FAILED - report kept at ' + FCrashFilePath)
        else
          ConsoleLine('Upload: FAILED - report not saved to disk');
      end;
    except
      on E: Exception do
        ConsoleLine('Upload: EXCEPTION ' + E.ClassName + ': ' + E.Message);
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
    {$ENDIF}
  end
  else
  begin
    // No dialog handler (e.g. worker-thread exception in a console target). Behave
    // like the fatal path: brief stderr + try upload + delete-or-keep. The process
    // stays alive here, so the brief must not claim termination.
    WriteCrashBriefToConsole(AReport, False);
    try
      if TCrashReporter.Upload(Text, ExtractFileName(FCrashFilePath)) then
      begin
        ConsoleLine('Upload: OK (report sent, local file removed)');
        if FCrashFilePath <> '' then
          try TFile.Delete(FCrashFilePath); except end;
      end
      else if FConfig.UploadEnabled then
      begin
        if FCrashFilePath <> '' then
          ConsoleLine('Upload: FAILED - report kept at ' + FCrashFilePath)
        else
          ConsoleLine('Upload: FAILED - report not saved to disk');
      end;
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

  if FConfig.FreezeDetection then
    InstallFreezeDetector;

  // Boot-recovery: pick up crash files from previous runs. Done after wiring the
  // handler so any exception during the scan lands in our handler too.
  ScanPendingCrashReports;
end;

procedure TCrashReporterImpl.InstallFreezeDetector;
begin
  // OnExternalSuppress mutes detection while an exception report is in
  // flight: FAlreadyReported spans capture -> write/upload -> dialog close -
  // exactly the window where the main loop may legitimately stall on our own
  // machinery. Unlocked read: advisory polling, a stale value only shifts
  // detection by one watchdog quantum.
  TCrashFreeze.OnExternalSuppress :=
    function: Boolean
    begin
      Result := FAlreadyReported;
    end;
  TCrashFreeze.OnCapture := HandleFreezeCapture;
  TCrashFreeze.Install(FConfig.FreezeTimeoutMS);
end;

procedure TCrashReporterImpl.HandleFreezeCapture(const AReport: TCrashReport;
  const AFrozenForMS: Int64);
// Freeze path - runs on the WATCHDOG thread while the watched (main) thread
// is frozen. Deliberately touches NONE of the exception-path bookkeeping
// (FAlreadyReported / FCrashFilePath / FExceptionID): a freeze report must
// not steal a concurrent crash's file name or anti-cascade state.
var
  Ctx: TCrashELContext;
  Text, Path, FreezeNote: String;
  Info: TCrashFreezeInfo;
begin
  Info := Default(TCrashFreezeInfo);
  Info.FrozenForMS := AFrozenForMS;
  Info.StackCaptured := Length(AReport.CallStack) > 0;

  // ATakeSnapshot=False: a pending hardware snapshot belongs to the exception
  // flow - the freeze report must not consume (or wear) it.
  Ctx := CrashDefaultELContext(FAppStartTime, 0, False);
  if FConfig.AppName <> '' then Ctx.AppName := FConfig.AppName;
  Ctx.AppVersion := FConfig.AppVersion;
  Ctx.CompileTime := FConfig.CompilationTime;
  Ctx.DisabledSections := FConfig.DisabledSections;
  // The report describes the frozen MAIN thread, not the watchdog.
  Ctx.ThreadID := Cardinal(MainThreadID);
  Ctx.ThreadName := 'MAIN';
  FreezeNote :=
    'Freeze Info:' + #13#10 +
    '-------------' + #13#10 +
    Format('  Detected   : no heartbeat from the watched (main) thread for %d ms',
      [AFrozenForMS]) + #13#10 +
    '  Captured by: freeze watchdog (Crash.Freeze); the call stack above is' + #13#10 +
    '               the FROZEN thread''s, captured in place via signal.' + #13#10;
  if not Info.StackCaptured then
    FreezeNote := FreezeNote +
      '  Note       : stack capture FAILED (the frozen thread never ran the' + #13#10 +
      '               capture handler - e.g. parked in uninterruptible I/O);' + #13#10 +
      '               only the freeze fact and duration are reported.' + #13#10;
  if Ctx.SignalInfoSection <> '' then
    Ctx.SignalInfoSection := FreezeNote + #13#10 + Ctx.SignalInfoSection
  else
    Ctx.SignalInfoSection := FreezeNote;

  Text := CrashBuildELReportText(AReport, Ctx);
  Info.BugID := CrashGenerateExceptionID(AReport);

  Path := '';
  if FConfig.SaveToFile then
  begin
    Path := EffectiveReportDir + EffectiveFileNamePrefix + Info.BugID + '.el';
    WriteReportTextToUniqueFile(Text, Path);
  end;
  Info.ReportFile := Path;

  if Path <> '' then
    ConsoleLine(Format('*** freeze detected (%d ms) - report saved to %s ***',
      [AFrozenForMS, Path]))
  else
    ConsoleLine(Format('*** freeze detected (%d ms) ***', [AFrozenForMS]));

  // Same policy as the non-fatal exception path: try to send, delete the
  // local file on success, otherwise leave it for boot recovery.
  try
    if TCrashReporter.Upload(Text, ExtractFileName(Path)) then
    begin
      Info.Uploaded := True;
      if Path <> '' then
        try TFile.Delete(Path); except end;
      Info.ReportFile := '';
      ConsoleLine('Upload: OK (freeze report sent, local file removed)');
    end;
  except
    // Network failure keeps the file on disk; nothing else to do.
  end;

  if Assigned(FConfig.OnFreezeReport) then
  try
    FConfig.OnFreezeReport(Info);
  except
    // A host notification failure must not kill the watchdog.
  end;
end;

function CrashUploadCore(const AUrl, AFieldName, AReportText,
  AFileName: String): Boolean;
// Self-contained multipart POST used by the facade Upload and by the startup
// background worker. Deliberately touches NO reporter-singleton state: the
// worker may still be running while the singleton is torn down at shutdown.
var
  Client: THTTPClient;
  Form: TMultipartFormData;
  Bytes: TBytes;
  Stream: TBytesStream;
  Resp: IHTTPResponse;
  UploadName, FieldName: String;
begin
  Result := False;
  if AUrl = '' then
    Exit;
  // Test/dev escape: env CRASH_NO_UPLOAD=1 -> skip the POST and keep the file,
  // so a local .el can be read without a network side effect.
  if GetEnvironmentVariable('CRASH_NO_UPLOAD') = '1' then Exit;

  // File body bytes - UTF-16LE with BOM, same as the .el on disk.
  Bytes := TEncoding.Unicode.GetPreamble + TEncoding.Unicode.GetBytes(AReportText);

  // Server-side name = on-disk name, so logs/monitoring keep the context.
  if AFileName <> '' then UploadName := AFileName
  else                    UploadName := 'BugReport.el';

  FieldName := AFieldName;
  if FieldName = '' then FieldName := 'el_upload_file_0';

  Stream := TBytesStream.Create(Bytes);
  try
    Client := THTTPClient.Create;
    try
      Client.ConnectionTimeout := 10000;
      Client.ResponseTimeout := 30000;
      Form := TMultipartFormData.Create(True);
      try
        Form.AddStream(FieldName, Stream, False, UploadName, 'application/octet-stream');
        try
          Resp := Client.Post(AUrl, Form);
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

const
  { Startup-recovery upload budget per launch: a long backlog must not hold the
    radio / endpoint for minutes; leftovers go out on the next launches. }
  MaxStartupUploads = 3;

procedure TCrashReporterImpl.ScanPendingCrashReports;
var
  Dir, FilePath, Pattern: String;
  Files: TArray<String>;
  Kept: TList<String>;
begin
  Dir := EffectiveReportDir; // same directory we write to (see BuildCrashFilePath)
  if Dir = '' then
    Exit;
  // The scan prefix keeps different targets in one folder from eating each
  // other's files, while (with a stable host-set ScanFileNamePrefix) still
  // matching reports written by a previous app version.
  Pattern := EffectiveScanPrefix + '*.el';

  Files := nil;
  try
    Files := TDirectory.GetFiles(Dir, Pattern);
  except
    Exit; // directory unavailable - don't fail bootstrap
  end;
  if Files = nil then
    Exit;

  if FConfig.UploadEnabled and FConfig.UploadPendingOnStartup then
  begin
    // Upload OFF the startup path: a slow or offline endpoint must not block
    // launch (up to 10s connect + 30s response PER FILE adds up to an ANR on
    // mobile). Capped per launch; files stay on disk until sent. The worker
    // gets its own COPIES of the config strings and runs entirely on
    // CrashUploadCore - it never touches the singleton, which may already be
    // torn down at shutdown while an upload is still in flight.
    var UploadUrl := FConfig.UploadUrl;
    var UploadField := FConfig.UploadFieldName;
    TThread.CreateAnonymousThread(
      procedure
      var
        I, Attempts: Integer;
        UpFile, UpText: String;
      begin
        Attempts := 0;
        for I := 0 to High(Files) do
        begin
          if Attempts >= MaxStartupUploads then
            Break;
          UpFile := Files[I];
          try
            UpText := TFile.ReadAllText(UpFile, TEncoding.Unicode);
            Inc(Attempts);
            if CrashUploadCore(UploadUrl, UploadField, UpText,
                 ExtractFileName(UpFile)) then
              try TFile.Delete(UpFile); except end; // sent -> remove
          except
            // Unreadable - skip silently; the file stays.
          end;
        end;
      end).Start;
    Exit;
  end;

  // No startup upload: keep the texts for the host to surface (stderr etc.).
  Kept := TList<String>.Create;
  try
    for FilePath in Files do
    begin
      try
        Kept.Add(TFile.ReadAllText(FilePath, TEncoding.Unicode));
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
  // macOS: install our thread-level Mach exception port on the MAIN thread (we
  // run on it here). Captures CPU registers for hardware faults, which the RTL's
  // POSIX-bypassing Mach handler otherwise hides. True on non-Mach targets
  // (nothing to cover); False = MAIN-thread faults will report without the
  // Registers section. Init-time verdict only (see MainThreadMachCovered).
  GReporter.FMachMainThreadCovered := CrashInstallMacOSMachHandlerForCurrentThread;
  if not GReporter.FMachMainThreadCovered then
    GReporter.ConsoleLine('Mach registration for the Init thread failed - main-thread Registers sections will be missing');
  // macOS: build the Pascal-symbol cache from the running Mach-O LC_SYMTAB so the
  // call stack shows real function names (not the nearest dladdr export). No-op
  // elsewhere.
  CrashInitMacOSSymbolCache;
  // Android: load the .gosym side-file (an offline address->name map for the
  // stripped .so) so the call stack shows Pascal names. No-op elsewhere.
  CrashInitAndroidSymbols;
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
  {$ENDIF}
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
begin
  Result := False;
  if (GReporter = nil) or (not GReporter.FConfig.UploadEnabled) or
     (GReporter.FConfig.UploadUrl = '') then
    Exit;
  Result := CrashUploadCore(GReporter.FConfig.UploadUrl,
    GReporter.FConfig.UploadFieldName, AReportText, AFileName);
end;

class function TCrashReporter.MainThreadMachCovered: Boolean;
begin
  Result := (GReporter = nil) or GReporter.FMachMainThreadCovered;
end;

class procedure TCrashReporter.EnableFreezeDetection(const ATimeoutMS: Integer);
begin
  if (GReporter = nil) or (not GReporter.FInstalled) then
    Exit;
  GReporter.FConfig.FreezeDetection := True;
  if ATimeoutMS > 0 then
    GReporter.FConfig.FreezeTimeoutMS := ATimeoutMS;
  GReporter.InstallFreezeDetector;
end;

class function TCrashReporter.CanRestart: Boolean;
begin
  if (GReporter <> nil) and (not GReporter.FConfig.AllowRestart) then
    Exit(False);
  {$IF Defined(MSWINDOWS) or Defined(LINUX) or (Defined(MACOS) and not Defined(IOS))}
  Result := True;
  {$ELSE}
  Result := False; // iOS/Android sandbox - not allowed
  {$ENDIF}
end;

{$IF not Defined(MSWINDOWS)}
// POSIX fork/execv
function fork: pid_t; cdecl; external libc name _PU + 'fork';
function execv(path: MarshaledAString; argv: PMarshaledAString): Integer; cdecl;
  external libc name _PU + 'execv';
{$ENDIF}

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
{$ENDIF}
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
  // Marshal argv BEFORE fork: in the child of a multithreaded process only
  // async-signal-safe calls are allowed until execv - a heap allocation there
  // can deadlock on a lock another thread held at fork time.
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

  ChildPid := fork;
  if ChildPid = 0 then
  begin
    // Child: execv ourselves with the same argv. If execv returns, it failed;
    // _exit, not Halt - unit finalization is not fork-safe either.
    execv(MarshaledAString(@ExePath[0]), @Argv[0]);
    Posix.Unistd._exit(127);
  end;
  // Parent (or fork failed - ChildPid=-1) - exit.
  Halt(0);
  {$ELSE}
  Halt(0);
  {$ENDIF}
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
