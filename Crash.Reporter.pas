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
  Crash.Freeze,    // TCrashFreezeInfo / TCrashFreezeReportProc (freeze detector)
  Crash.Signals;   // TCrashAltStackState (per-thread hardware-fault coverage)

type
  { Shows a modal dialog with the full report text for non-fatal exceptions.
    Blocks until the user closes it. If nil, non-fatal exceptions fall back to a
    brief stderr message. Not called for fatal (csFatalProc) - the process is
    dying, only a brief stderr line is printed. }
  TCrashShowDialogProc = reference to procedure(const AReportText: String);

  { Completion callback for a background upload. It is queued to the main
    thread; the transport worker never calls host/UI code directly. }
  TCrashUploadCompleteProc = reference to procedure(const ASuccess: Boolean);

  {$IFDEF AUTOTESTS}
  TCrashAutoTestUploadProc = reference to function(const AUrl, AFieldName,
    AReportText, AFileName: String): Boolean;
  {$ENDIF}

  { Optional: returns extra free-form text appended to the report as a trailing
    section (e.g. "what the app was doing"). Called at report time. }
  TCrashCollectContextProc = reference to function: String;

  { Optional privacy hook. Receives ParamStr(1..N) as separate values and
    returns the exact single-line text allowed into Application/1.4. An
    exception fails private and emits an empty field. }
  TCrashSanitizeParametersProc = reference to function(
    const AArguments: TArray<String>): String;

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
    { Application/1.4 is empty by default. True is an explicit legacy opt-in
      that includes every argument when no allowlist/callback is configured. }
    IncludeAppParameters: Boolean;
    { Case-insensitive switch names allowed into 1.4. Entries may be written as
      "name", "/name" or "--name"; /name=value preserves the value. }
    AppParameterAllowList: TArray<String>;
    { Highest-priority parameter policy. nil -> allowlist/include-all rules. }
    OnSanitizeParameters: TCrashSanitizeParametersProc;
    { Persist the .el as a normal local report. Default True. When False, an
      upload-authorized fatal/headless path may still create a delivery artifact;
      it is removed after confirmed upload and retained only on failure. }
    SaveToFile: Boolean;
    { File name prefix; the timestamp + ".el" are appended. Empty ->
      "<ExeBaseName>_<PLATFORM>_". }
    FileNamePrefix: String;
    { Optional filename-only template. Supported tokens are App, Platform,
      Version and BugID in braces. When set, it wins over FileNamePrefix. }
    FileNameTemplate: String;
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
    { On Init, also (re)upload every leftover .el from previous runs. Requires
      UploadEnabled. Default False. Even when False, reports carrying their own
      sibling .pending authorization are retried; unmarked leftovers are surfaced. }
    UploadPendingOnStartup: Boolean;
    { Allow the Restart action (platform-gated at runtime). Default True. }
    AllowRestart: Boolean;
    { GUI dialog provider for non-fatal exceptions. nil -> stderr fallback. }
    OnShowDialog: TCrashShowDialogProc;
    { Optional extra-context provider appended to the report. nil -> none. }
    OnCollectContext: TCrashCollectContextProc;
    { Number of recent host-supplied breadcrumbs retained in memory. Clamped to
      0..256; 0 disables collection. Default 64. }
    BreadcrumbCapacity: Integer;
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
    { Restart the process after a freeze report: a fresh instance is spawned
      with the same command line and the frozen one is terminated WITHOUT unit
      finalization (it is not runnable enough for one) - but ONLY once the
      spawn is confirmed (CreateProcess result / exec-confirmation pipe): a
      failed spawn leaves the frozen instance alive in report-only mode
      rather than killing it with no replacement. A notice file is left
      in the report dir; the next boot reads it (see TakeRestartNotice) so the
      host can tell the user, and that boot also uploads leftover .el files -
      delivering the report is what the restart is for. Loop guard: a run that
      was itself freeze-restarted stays report-only until it has been up for
      FREEZE_RESTART_MIN_UPTIME_MS, so a systematic freeze-on-startup cannot
      restart in a loop. The guard flag travels as an environment mark
      (inherited by the replacement even when the report dir is unwritable
      and no notice could be left); the notice file is the UI/info payload
      only. Gated by CanRestart (AllowRestart + platform; no-op in the
      iOS/Android sandbox). Default False. }
    RestartOnFreeze: Boolean;
    { Fired (on the WATCHDOG thread) after a freeze report is handled - lets
      the host log/notify. Keep it cheap and thread-safe. }
    OnFreezeReport: TCrashFreezeReportProc;
  end;

{ A config pre-filled with sensible defaults. Override the fields you need. }
function DefaultCrashConfig: TCrashConfig;

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
    AltStack: TCrashAltStackState;
    MachHandler: TCrashMachState;
  end;

  { Point-in-time reporter status. Threads contains only callers that really
    registered and have not yet unregistered; direct TThread/vendored workers
    are deliberately not inferred. }
  TCrashStatus = record
    Active: Boolean;
    SignalHandlersInstalled: Boolean;
    FreezeDetectorActive: Boolean;
    RegisteredThreadCount: Integer;
    MainThread: TCrashThreadCoverage;
    CurrentThread: TCrashThreadCoverage;
    Threads: TArray<TCrashThreadCoverage>;
  end;

  { What a previous run left behind when RestartOnFreeze replaced a frozen
    instance. Read (and consumed) from the notice file at Init; the host
    surfaces it via TCrashReporter.TakeRestartNotice - a dialog, a journal
    line, a log entry. }
  TCrashRestartNotice = record
    Found: Boolean;         // False = the previous run did not freeze-restart
    RestartedAt: TDateTime; // when the frozen instance replaced itself
    FrozenForMS: Int64;     // no-heartbeat span of that freeze
    BugID: String;          // EL-style id of the freeze report
    ReportFile: String;     // .el left on disk ('' = uploaded-and-removed, or not saved)
    Uploaded: Boolean;      // True = the report reached the endpoint before the restart
  end;

{ Serialize / parse a freeze-restart notice file - the on-disk contract between
  the frozen instance and its next boot. Public so hosts and tests can inspect
  the file without an actual process restart. Read returns False when the file
  is missing or does not carry the notice signature; neither routine touches
  reporter state, and neither deletes the file. }
procedure CrashWriteRestartNoticeFile(const APath: String;
  const ANotice: TCrashRestartNotice);
function CrashReadRestartNoticeFile(const APath: String;
  out ANotice: TCrashRestartNotice): Boolean;

{ Freeze-restart loop-guard mark in the process ENVIRONMENT - the disk-free
  twin of the notice file. The guard must survive a report dir that cannot be
  written (read-only, full disk, missing), so it rides process inheritance:
  CreateProcess/execv hand the environment to the replacement unconditionally.
  Set returns True only when the mark is verifiably in place (the value is
  read back after the API call) - a False from BOTH channels means the
  restart loop guard cannot be armed at all, and the caller must not restart.
  Consume = read + remove, so later host-spawned children never inherit a
  stale mark. Exposed for tests. }
function CrashSetFreezeRestartEnvMark: Boolean;
function CrashConsumeFreezeRestartEnvMark: Boolean;

{$IFDEF AUTOTESTS}
{ Queue the same transport worker with an injected transport. This avoids a
  live endpoint in state tests while exercising delete/keep and non-blocking
  behavior. }
function CrashAutoTestQueueUpload(const AReportText, AReportPath: String;
  const ATransport: TCrashAutoTestUploadProc;
  const AOnComplete: TCrashUploadCompleteProc = nil): Boolean;
{ The exact anti-cascade transition used by HandleReport, exposed so state
  tests can prove that a second capture is not allowed to create a file. }
function CrashAutoTestTryClaimReport(var AAlreadyReported: Boolean): Boolean;
function CrashAutoTestELContainsRawCaptureKey(const AFilePath,
  ACaptureKey: String): Boolean;
function CrashAutoTestFormatParameters(const AArguments,
  AAllowList: TArray<String>; const AIncludeAll: Boolean;
  const ASanitizer: TCrashSanitizeParametersProc = nil): String;
function CrashAutoTestRenderFileName(const ATemplate, AApp, AVersion,
  ABugID: String): String;
function CrashAutoTestTemplateScanPrefix(const ATemplate, AApp: String): String;
function CrashAutoTestAcceptInitialConfig(var AInstalled: Boolean;
  var ACurrent: TCrashConfig; const AIncoming: TCrashConfig): Boolean;
function CrashAutoTestOperationLifetimeGate: Boolean;
{$ENDIF}

{$IF not Defined(MSWINDOWS)}
{ Spawn AExePath with AArgv (argv[0] included) detached, confirming through a
  CLOEXEC pipe that execv actually started it (a successful exec closes the
  write end - EOF; a failure writes a marker byte first, retried across
  EINTR). Fail-closed at every stage: no confirmation channel (pipe/fcntl
  failure, e.g. fd exhaustion) = no fork at all; a broken read on the channel
  = the child is killed and False (exec state unknown - the caller must keep
  living); an EOF whose child is already a zombie with one of our failure
  exit codes (126 sweep / 127 execv) = False, so a lost marker byte cannot
  masquerade as success. The child marks EVERY inherited fd >= 3
  close-on-exec between fork and execv (close_range, then a raw /proc/self/fd
  walk, then a bounded fcntl sweep - see the fallbacks below), so the
  replacement starts with only stdio - none of the frozen instance's sockets,
  locks or pipes leak into it; a sweep that cannot vouch for the whole table
  aborts the spawn (126) instead of exec'ing with an unknown fd set. False =
  nothing survives the call; the CALLER is alive either way, and a failed
  child is reaped. The building block of Restart, exposed so spawn-failure
  handling stays testable. }
function CrashSpawnDetachedVerified(const AExePath: String;
  const AArgv: TArray<String>): Boolean;

{ Fallback levels of the child fd sweep, exposed for tests (safe to run in a
  live process: CLOEXEC only affects future execs). ViaProcFS walks the
  ACTUALLY open descriptors through /proc/self/fd with raw syscalls (no
  range bound); BySweep marks fd 3..AFdLimit-1 via fcntl. Both retry EINTR,
  ignore EBADF and return False when any live descriptor could not be
  marked. }
{$IF Defined(LINUX)}
function CrashMarkFDsCloseOnExecViaProcFS: Boolean;
{$ENDIF}
function CrashMarkFDsCloseOnExecBySweep(const AFdLimit: Integer): Boolean;
{$IF Defined(AUTOTESTS)}
{ Exact finite RLIMIT_NOFILE -> bounded-sweep limit. -1 means the limit cannot
  be represented safely, so an unbounded primitive must succeed or spawn must
  fail closed. Exposed only to regression tests. }
function CrashFdSweepLimitFromRLimit(const ARlimCur: UInt64): Integer;
{$ENDIF}
{$ENDIF}

type
  { Public façade. All methods are class (static) methods backed by a singleton. }
  TCrashReporter = class
  public
    { Install hooks + scan for pending reports. Call once at startup. Idempotent. }
    class procedure Init(const AConfig: TCrashConfig); static;
    { Stop Reporter services on a calm, quiesced host path. Bootstrap signal/RTL
      hooks remain process-global. A later Init creates a fresh runtime. }
    class procedure Shutdown; static;
    class function Active: Boolean; static;
    { Cheap host-owned diagnostic trail. Category/message must already be
      redacted for the application's privacy policy. }
    class procedure AddBreadcrumb(const ACategory, AMessage: String); static;
    class procedure ClearBreadcrumbs; static;
    { Cover the CALLING thread on a calm path. Repeated calls from the same
      thread are idempotent. AName is diagnostic only. }
    class function RegisterCurrentThread(const AName: String = ''):
      TCrashThreadCoverage; static;
    { Final action of a registered worker's try/finally. Owned alt-stack is
      disabled then freed; a borrowed stack is never touched. On macOS the
      thread-level Mach registration disappears with the exiting kernel thread. }
    class procedure UnregisterCurrentThread; static;
    class function GetStatus: TCrashStatus; static;

    { Unmarked/not-upload-authorized reports from previous runs (boot recovery).
      Empties the buffer. Marked reports are handled by the background worker. }
    class function TakePending: TArray<String>; static;
    { Convenience: dumps pending reports to ErrOutput when IsConsole. Idempotent. }
    class procedure SurfacePendingToStderr; static;

    { Explicit synchronous upload API. Internal fatal/freeze/UI paths use the
      durable asynchronous API below. AFileName = the on-disk basename (server
      uses the same name). Returns True on HTTP 2xx. Honours CRASH_NO_UPLOAD=1. }
    class function Upload(const AReportText: String;
      const AFileName: String = ''): Boolean; static;
    { True when the configured transport can accept reports. }
    class function CanUpload: Boolean; static;
    { Persist + mark the current report before starting a background upload.
      Success removes the .el first and its sibling .pending second; failure
      leaves both for startup recovery. Returns False when delivery could not
      be durably armed, or when upload is disabled. }
    class function UploadLastReportAsync(const AReportText: String;
      const AOnComplete: TCrashUploadCompleteProc = nil): Boolean; static;

    { Restart the process with the same parameters, then quit. CanRestart is
      False on sandboxed platforms (iOS/Android) or when AllowRestart=False.
      AHardExit=True quits via _exit/TerminateProcess, skipping unit
      finalization - the freeze path needs that: finalization on the watchdog
      thread would join the watchdog itself and can deadlock on locks the
      frozen main thread still holds. Returns ONLY on spawn failure (False:
      CreateProcess failed / fork or execv did not start the replacement) -
      the caller decides what a live-but-unreplaced process does next. On
      success the call never returns. }
    class function CanRestart: Boolean; static;
    class function Restart(const AHardExit: Boolean = False): Boolean; static;

    { Notice left by a previous run that freeze-restarted itself (see
      TCrashConfig.RestartOnFreeze). Found=False when there is none. Empties
      the stored notice (single consumer); the file itself was already
      consumed at Init. }
    class function TakeRestartNotice: TCrashRestartNotice; static;
    { Full path of the freeze-restart notice file for the current config
      (diagnostics / tests; '' before Init). }
    class function RestartNoticeFilePath: String; static;

    { Basename of the last written .el (so an upload uses the same name). }
    class function LastCrashFileName: String; static;

    { Delete the last written .el and its sibling pending marker. No-op if there
      is no current file. }
    class procedure DeleteLastCrashFile; static;

    { Init-time verdict: True when Init's Mach thread registration succeeded
      (vacuously True on targets without a Mach layer). Reflects ONLY the
      registration made at Init - it does not track the watcher's later
      lifetime, and it says nothing about other threads' coverage. False =
      main-thread hardware-fault reports lack the Registers section (their
      Crash Signal Info section says so too). }
    class function MainThreadMachCovered: Boolean; static;

    { Enable the freeze detector after Init (late opt-in, e.g. from a host
      setting evaluated after startup). Equivalent to Init with
      FreezeDetection=True; no-op when the reporter is not installed. Must be
      called on the watched (main) thread - it is the capture target. }
    class procedure EnableFreezeDetection(const ATimeoutMS: Integer); static;
  end;

implementation

uses
  System.Classes,
  System.SyncObjs,
  System.IOUtils,
  System.DateUtils,
  System.Generics.Collections,
  System.Net.HttpClient,
  System.Net.Mime,
  System.Net.URLClient,
  Crash.ELFormat,
  Crash.MacOS.Symbols,
  Crash.MacOS.MachExc,
  Crash.Android.Symbols,
  Crash.Breadcrumbs,
  Crash.Pending,
  Crash.RawFallback,
  {$IF Defined(MSWINDOWS)}
  Winapi.Windows,
  {$ENDIF}
  {$IF not Defined(MSWINDOWS)}
  Posix.Pthread,
  Posix.Unistd, // getpid(), fork(), execv(), pipe()
  Posix.Stdlib,
  Posix.SysTypes,
  Posix.Base,
  Posix.Fcntl,   // FD_CLOEXEC on the exec-confirmation pipe + the child fd sweep
  Posix.SysWait, // waitpid() for the failed-exec child
  Posix.Signal,  // kill(SIGKILL) when the confirmation channel breaks
  Posix.Errno,
  {$ENDIF}
  System.SysUtils;

type
  TCrashUploadWorkerProc = reference to function(const AUrl, AFieldName,
    AReportText, AFileName: String): Boolean;

  ICrashOperationLifetime = interface
    function Active: Boolean;
    procedure Deactivate;
  end;

  TCrashOperationLifetime = class(TInterfacedObject, ICrashOperationLifetime)
  private
    FActive: Integer;
  public
    constructor Create;
    function Active: Boolean;
    procedure Deactivate;
  end;

function CrashQueueUpload(const AUrl, AFieldName, AReportText,
  AReportPath: String; const AOnComplete: TCrashUploadCompleteProc;
  const ALifetime: ICrashOperationLifetime): Boolean; forward;
function CrashQueueUploadWithTransport(const AUrl, AFieldName, AReportText,
  AReportPath: String; const ATransport: TCrashUploadWorkerProc;
  const AOnComplete: TCrashUploadCompleteProc;
  const ALifetime: ICrashOperationLifetime): Boolean; forward;

function DefaultCrashConfig: TCrashConfig;
begin
  Result := Default(TCrashConfig);
  Result.SaveToFile := True;
  Result.UploadEnabled := False;
  Result.UploadFieldName := 'el_upload_file_0';
  Result.UploadPendingOnStartup := False;
  Result.AllowRestart := True;
  Result.BreadcrumbCapacity := CRASH_BREADCRUMB_DEFAULT_CAPACITY;
  Result.FreezeDetection := False; // opt in - see the field comment
  Result.FreezeTimeoutMS := 30000;
  Result.RestartOnFreeze := False; // opt in - see the field comment
end;

constructor TCrashOperationLifetime.Create;
begin
  inherited Create;
  FActive := 1;
end;

function TCrashOperationLifetime.Active: Boolean;
begin
  Result := TInterlocked.CompareExchange(FActive, 1, 1) = 1;
end;

procedure TCrashOperationLifetime.Deactivate;
begin
  TInterlocked.Exchange(FActive, 0);
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

const
  CRASH_APP_PARAMETERS_MAX_CHARS = 4096;

function CrashSingleLineBounded(const AText: String;
  const AMaxChars: Integer): String;
begin
  Result := StringReplace(AText, #13, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #10, ' ', [rfReplaceAll]);
  if Length(Result) > AMaxChars then
    SetLength(Result, AMaxChars);
end;

function CrashArgumentSwitchName(const AArgument: String;
  const ARequirePrefix: Boolean): String;
var
  P: Integer;
begin
  Result := Trim(AArgument);
  if Result = '' then
    Exit;
  if ARequirePrefix and not CharInSet(Result[1], ['/', '-']) then
    Exit('');
  while (Result <> '') and CharInSet(Result[1], ['/', '-']) do
    Delete(Result, 1, 1);
  P := Pos('=', Result);
  if P > 0 then
    SetLength(Result, P - 1);
  Result := LowerCase(Trim(Result));
end;

function CrashFormatParameters(const AArguments,
  AAllowList: TArray<String>; const AIncludeAll: Boolean;
  const ASanitizer: TCrashSanitizeParametersProc): String;
var
  Allowed, ArgName: String;
  Argument: String;
  Selected: TList<String>;
begin
  Result := '';
  if Assigned(ASanitizer) then
  begin
    try
      Result := ASanitizer(AArguments);
    except
      Result := '';
    end;
    Exit(CrashSingleLineBounded(Result, CRASH_APP_PARAMETERS_MAX_CHARS));
  end;
  if Length(AAllowList) > 0 then
  begin
    Selected := TList<String>.Create;
    try
      for Argument in AArguments do
      begin
        ArgName := CrashArgumentSwitchName(Argument, True);
        if ArgName = '' then
          Continue;
        for Allowed in AAllowList do
          if ArgName = CrashArgumentSwitchName(Allowed, False) then
          begin
            Selected.Add(Argument);
            Break;
          end;
      end;
      Result := String.Join(' ', Selected.ToArray);
    finally
      Selected.Free;
    end;
  end
  else if AIncludeAll then
    Result := String.Join(' ', AArguments);
  Result := CrashSingleLineBounded(Result, CRASH_APP_PARAMETERS_MAX_CHARS);
end;

function CrashCurrentParameters(const AConfig: TCrashConfig): String;
var
  Arguments: TArray<String>;
  I: Integer;
begin
  SetLength(Arguments, ParamCount);
  for I := 1 to ParamCount do
    Arguments[I - 1] := ParamStr(I);
  Result := CrashFormatParameters(Arguments, AConfig.AppParameterAllowList,
    AConfig.IncludeAppParameters, AConfig.OnSanitizeParameters);
end;

function CrashSanitizeFileName(const AValue: String): String;
var
  C: Char;
  I: Integer;
begin
  Result := Trim(AValue);
  for I := 1 to Length(Result) do
  begin
    C := Result[I];
    if (Ord(C) < 32) or CharInSet(C, ['<', '>', ':', '"', '/', '\', '|', '?', '*']) then
      Result[I] := '_';
  end;
end;

function CrashRenderFileNameTemplate(const ATemplate, AApp, AVersion,
  ABugID: String): String;
var
  AppValue: String;
begin
  Result := '';
  if (ATemplate = '') or
     (Pos('{bugid}', LowerCase(ATemplate)) = 0) then
    Exit;
  AppValue := AApp;
  if AppValue = '' then
    AppValue := GetExeBaseName;
  Result := StringReplace(ATemplate, '{App}',
    CrashSanitizeFileName(AppValue), [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, '{Platform}', GetPlatformTag,
    [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, '{Version}',
    CrashSanitizeFileName(AVersion), [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, '{BugID}',
    CrashSanitizeFileName(ABugID), [rfReplaceAll, rfIgnoreCase]);
  if (Pos('{', Result) > 0) or (Pos('}', Result) > 0) then
    Exit('');
  Result := CrashSanitizeFileName(Result);
  if Result = '' then
    Exit;
  if not SameText(ExtractFileExt(Result), '.el') then
    Result := Result + '.el';
end;

function CrashTemplateScanPrefix(const ATemplate, AApp: String): String;
var
  AppValue, LowerTemplate, PrefixTemplate: String;
  BugPos, CutPos, VersionPos: Integer;
begin
  Result := '';
  LowerTemplate := LowerCase(ATemplate);
  BugPos := Pos('{bugid}', LowerTemplate);
  if BugPos = 0 then
    Exit;
  VersionPos := Pos('{version}', LowerTemplate);
  CutPos := BugPos;
  if (VersionPos > 0) and (VersionPos < CutPos) then
    CutPos := VersionPos;
  PrefixTemplate := Copy(ATemplate, 1, CutPos - 1);
  AppValue := AApp;
  if AppValue = '' then
    AppValue := GetExeBaseName;
  Result := StringReplace(PrefixTemplate, '{App}',
    CrashSanitizeFileName(AppValue), [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, '{Platform}', GetPlatformTag,
    [rfReplaceAll, rfIgnoreCase]);
  if (Pos('{', Result) > 0) or (Pos('}', Result) > 0) then
    Exit('');
  Result := CrashSanitizeFileName(Result);
end;

function CrashAcceptInitialConfig(var AInstalled: Boolean;
  var ACurrent: TCrashConfig; const AIncoming: TCrashConfig): Boolean;
begin
  Result := not AInstalled;
  if not Result then
    Exit;
  ACurrent := AIncoming;
  AInstalled := True;
end;

const
  { First line of a freeze-restart notice file; the version tag lets a future
    format change fail closed (an unknown notice reads as not-found). }
  CRASH_RESTART_NOTICE_SIGNATURE = 'CrashRestartNotice v1';

procedure CrashWriteRestartNoticeFile(const APath: String;
  const ANotice: TCrashRestartNotice);
var
  Text: String;
const
  BoolChar: array [Boolean] of Char = ('0', '1');
begin
  // key=value lines; the timestamp is ISO 8601 so the parse never depends on
  // the locale of either run. UTF-8: ReportFile may carry non-ASCII paths.
  Text :=
    CRASH_RESTART_NOTICE_SIGNATURE + #13#10 +
    'restarted_at=' + DateToISO8601(ANotice.RestartedAt, False) + #13#10 +
    'frozen_ms=' + IntToStr(ANotice.FrozenForMS) + #13#10 +
    'bugid=' + ANotice.BugID + #13#10 +
    'report_file=' + ANotice.ReportFile + #13#10 +
    'uploaded=' + BoolChar[ANotice.Uploaded] + #13#10;
  ForceDirectories(ExtractFilePath(APath));
  TFile.WriteAllText(APath, Text, TEncoding.UTF8);
end;

function CrashReadRestartNoticeFile(const APath: String;
  out ANotice: TCrashRestartNotice): Boolean;
var
  Lines: TArray<String>;
  L, Key, Val: String;
  EqPos: Integer;
  DT: TDateTime;
  MS: Int64;
begin
  ANotice := Default(TCrashRestartNotice);
  Result := False;
  if (APath = '') or (not TFile.Exists(APath)) then
    Exit;
  try
    Lines := TFile.ReadAllLines(APath, TEncoding.UTF8);
  except
    Exit; // unreadable = no notice
  end;
  if (Length(Lines) = 0) or (Lines[0].Trim <> CRASH_RESTART_NOTICE_SIGNATURE) then
    Exit;
  // Fields are best-effort: a missing/garbled value keeps its default, the
  // notice itself (signature matched) still counts.
  for L in Lines do
  begin
    EqPos := Pos('=', L);
    if EqPos <= 1 then
      Continue;
    Key := Copy(L, 1, EqPos - 1);
    Val := Copy(L, EqPos + 1, MaxInt);
    if Key = 'restarted_at' then
    begin
      if TryISO8601ToDate(Val, DT, False) then
        ANotice.RestartedAt := DT;
    end
    else if Key = 'frozen_ms' then
    begin
      if TryStrToInt64(Val, MS) then
        ANotice.FrozenForMS := MS;
    end
    else if Key = 'bugid' then
      ANotice.BugID := Val
    else if Key = 'report_file' then
      ANotice.ReportFile := Val
    else if Key = 'uploaded' then
      ANotice.Uploaded := Val = '1';
  end;
  ANotice.Found := True;
  Result := True;
end;

const
  CRASH_FREEZE_RESTART_ENV = 'CRASH_FREEZE_RESTARTED';

function CrashSetFreezeRestartEnvMark: Boolean;
begin
  {$IF Defined(MSWINDOWS)}
  SetEnvironmentVariable(CRASH_FREEZE_RESTART_ENV, '1');
  {$ELSE}
  setenv(CRASH_FREEZE_RESTART_ENV, '1', 1); // can fail (ENOMEM)
  {$ENDIF}
  // Read-back instead of trusting the API result: True = the mark is
  // verifiably in place for inheritance.
  Result := GetEnvironmentVariable(CRASH_FREEZE_RESTART_ENV) = '1';
end;

function CrashConsumeFreezeRestartEnvMark: Boolean;
begin
  Result := GetEnvironmentVariable(CRASH_FREEZE_RESTART_ENV) = '1';
  if not Result then
    Exit;
  {$IF Defined(MSWINDOWS)}
  SetEnvironmentVariable(CRASH_FREEZE_RESTART_ENV, nil);
  {$ELSE}
  unsetenv(CRASH_FREEZE_RESTART_ENV);
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
    FAppStartTick: UInt64;      // monotonic start mark for the freeze-restart loop guard
    FRestartNotice: TCrashRestartNotice; // what the previous run's RestartOnFreeze left behind (consumed via TakeRestartNotice)
    FWasFreezeRestarted: Boolean; // loop-guard flag: this run WAS spawned by RestartOnFreeze (survives TakeRestartNotice)
    FMachMainThreadCovered: Boolean; // Init-time Mach registration verdict (main thread only; NOT a live watcher status)
    FMainThreadCoverage: TCrashThreadCoverage;
    FThreadCoverages: TDictionary<UInt64, TCrashThreadCoverage>;
    FBreadcrumbs: TCrashBreadcrumbStore;
    FOperationLifetime: ICrashOperationLifetime;
    FInstanceID: UInt64;
    function EffectiveFileNamePrefix: String;
    function EffectiveScanPrefix: String;
    function EffectiveReportDir: String;
    function BuildCrashFilePathForID(const ABugID: String): String;
    function BuildCrashFilePath: String;
    function RestartNoticeFilePath: String;
    procedure ReadRestartNoticeAtBoot;
    procedure WriteCrashBriefToConsole(const AReport: TCrashReport;
      const ATerminating: Boolean);
    procedure ConsoleLine(const S: String);
    function WriteToFile(const AText: String): Boolean;
    function EnsureCurrentReportPending(const AText: String): Boolean;
    function WriteReportTextToUniqueFile(const AText: String;
      var APath: String): Boolean;
    procedure ResetAlreadyReported;
    procedure HandleReport(const AReport: TCrashReport);
    procedure DoHandleReport(const AReport: TCrashReport);
    procedure InstallFreezeDetector;
    procedure HandleFreezeCapture(const AReport: TCrashReport;
      const AFrozenForMS: Int64);
    function WriteRecoveredRawReport(const ARaw: TCrashRawRecord): Boolean;
    procedure RecoverRawFallbackReports;
    procedure ScanPendingCrashReports;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Install(const AConfig: TCrashConfig);
    function TakePendingCrashReports: TArray<String>;
  end;

var
  GReporter: TCrashReporterImpl;
  GReporterInstanceSeq: Int64;

threadvar
  GCoverageReporter: Pointer;
  GCoverageReporterInstanceID: UInt64;

constructor TCrashReporterImpl.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FThreadCoverages := TDictionary<UInt64, TCrashThreadCoverage>.Create;
  FInstanceID := UInt64(TInterlocked.Increment(GReporterInstanceSeq));
  FMachMainThreadCovered := True; // no verdict yet - only Init's registration may flip it
  FAppStartTime := Now; // "close enough to process start"
  FAppStartTick := TThread.GetTickCount64;
end;

destructor TCrashReporterImpl.Destroy;
begin
  FInstalled := False;
  if FOperationLifetime <> nil then
    FOperationLifetime.Deactivate;
  // Stop the freeze watchdog BEFORE the singleton goes away: its capture and
  // suppress hooks are closures over Self.
  TCrashFreeze.Shutdown;
  TCrashFreeze.OnCapture := nil;
  TCrashFreeze.OnExternalSuppress := nil;
  TCrashCapture.OnReport := nil;
  CrashRawShutdown(True);
  FConfig.OnShowDialog := nil;
  FConfig.OnCollectContext := nil;
  FConfig.OnSanitizeParameters := nil;
  FConfig.OnFilterReport := nil;
  FConfig.OnFreezeReport := nil;
  FreeAndNil(FBreadcrumbs);
  FOperationLifetime := nil;
  FreeAndNil(FThreadCoverages);
  FreeAndNil(FLock);
  inherited;
end;

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
  else if FConfig.FileNameTemplate <> '' then
  begin
    Result := CrashTemplateScanPrefix(FConfig.FileNameTemplate,
      FConfig.AppName);
    if Result = '' then
      Result := EffectiveFileNamePrefix;
  end
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

function TCrashReporterImpl.BuildCrashFilePathForID(const ABugID: String): String;
var
  Dir, FileName, Tail: String;
begin
  Dir := EffectiveReportDir;
  // <prefix><id>.el - prefix (project + platform + version) keeps reports from
  // different builds/targets from merging; the EL-style exception ID (stable
  // BugID) is the uniqueness token, mirroring EurekaLog's "<proj>_<ver>_<id>".
  // The same bug yields the same name (WriteToFile appends a numeric suffix for
  // repeated instances). Fall back to a timestamp if the id is somehow empty, so
  // we never emit "<prefix>.el". .el lets the EurekaLog Viewer open it natively.
  if ABugID <> '' then
    Tail := ABugID
  else
    Tail := FormatDateTime('yyyymmddhhnnss', Now);
  if FConfig.FileNameTemplate <> '' then
    FileName := CrashRenderFileNameTemplate(FConfig.FileNameTemplate,
      FConfig.AppName, FConfig.AppVersion, Tail)
  else
    FileName := '';
  if FileName = '' then
    FileName := EffectiveFileNamePrefix + Tail + '.el';
  Result := IncludeTrailingPathDelimiter(Dir) + FileName;
end;

function TCrashReporterImpl.BuildCrashFilePath: String;
begin
  Result := BuildCrashFilePathForID(FExceptionID);
end;

function TCrashReporterImpl.RestartNoticeFilePath: String;
begin
  // Scan-prefixed like the .el files (several targets may share one report
  // dir); the '.notice' extension keeps it clear of the '*.el' boot scan.
  Result := EffectiveReportDir + EffectiveScanPrefix + 'freeze_restart.notice';
end;

procedure TCrashReporterImpl.ReadRestartNoticeAtBoot;
var
  Path: String;
begin
  // The env mark is the authoritative loop-guard channel: it reaches this run
  // even when the restarting instance could not write the notice (read-only /
  // full report dir). The notice file adds the UI payload when it exists.
  if CrashConsumeFreezeRestartEnvMark then
    FWasFreezeRestarted := True;
  Path := RestartNoticeFilePath;
  if CrashReadRestartNoticeFile(Path, FRestartNotice) then
  begin
    FWasFreezeRestarted := True; // loop-guard flag; NOT cleared by TakeRestartNotice
    try TFile.Delete(Path); except end; // single delivery
  end;
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
begin
  Result := CrashWriteReportTextToUniqueFile(AText, APath);
end;

function TCrashReporterImpl.WriteToFile(const AText: String): Boolean;
begin
  if FCrashFilePath = '' then
    FCrashFilePath := BuildCrashFilePath;
  // Safety net: the file name is stamped per-second (yyyymmddhhnnss), so two
  // distinct reports in the same second (two threads crashing, or a phantom that
  // slipped past the skip above) would collide. The unique-suffix logic in the
  // write core guarantees no real report is ever overwritten by another (the
  // root case - the content-less phantom - is already dropped in HandleReport).
  Result := WriteReportTextToUniqueFile(AText, FCrashFilePath);
end;

function TCrashReporterImpl.EnsureCurrentReportPending(
  const AText: String): Boolean;
begin
  if (FCrashFilePath = '') or (not TFile.Exists(FCrashFilePath)) then
    if not WriteToFile(AText) then
      Exit(False);
  Result := CrashWritePendingMarker(FCrashFilePath);
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

function CrashTryClaimReport(var AAlreadyReported: Boolean): Boolean;
begin
  Result := not AAlreadyReported;
  if Result then
    AAlreadyReported := True;
end;

{$IFDEF AUTOTESTS}
function CrashAutoTestTryClaimReport(
  var AAlreadyReported: Boolean): Boolean;
begin
  Result := CrashTryClaimReport(AAlreadyReported);
end;
{$ENDIF}

procedure TCrashReporterImpl.HandleReport(const AReport: TCrashReport);
begin
  // Anti-cascade under the lock. Long operations (dialog) happen outside it.
  FLock.Enter;
  try
    if not CrashTryClaimReport(FAlreadyReported) then
      Exit;
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
    CrashRawRotate(False);
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
  ReportPersisted: Boolean;
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
      CrashRawRotate(True);
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
  Ctx.AppParameters := CrashCurrentParameters(FConfig);
  Ctx.DisabledSections := FConfig.DisabledSections;
  if FBreadcrumbs <> nil then
  try
    Ctx.StepsToReproduceText := FBreadcrumbs.SnapshotText;
  except
    // Breadcrumbs are diagnostic-only and cannot break the report.
  end;
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
  CrashCollectELModules(Ctx);
  Text := CrashBuildELReportText(AReport, Ctx);

  // The .el file name uses the exception's EL-style BugID as its token (see
  // BuildCrashFilePath). Compute it here, where AReport is in hand, before
  // WriteToFile builds the path.
  FExceptionID := CrashGenerateExceptionID(AReport);

  ReportPersisted := False;
  if FConfig.SaveToFile then
    ReportPersisted := WriteToFile(Text); // single-flight via FAlreadyReported

  if IsFatal then
  begin
    // Process is about to die. Brief stderr is the only live signal; the full
    // text is already in the file. FAlreadyReported stays True - cascade calls
    // (RTL cleanup sometimes calls ExceptionAcquired after ExceptProc) are eaten.
    WriteCrashBriefToConsole(AReport, True);
    // A terminating process never waits on HTTP. The marker authorizes the
    // next startup to deliver this exact report, even when SaveToFile=False.
    if FConfig.UploadEnabled then
      if EnsureCurrentReportPending(Text) then
      begin
        ReportPersisted := True;
        ConsoleLine('Upload: deferred to startup (report marked pending)')
      end
      else
        ConsoleLine('Upload: deferred delivery could not be persisted');
    // A full .el (normal or delivery artifact) carries the Raw Capture Key and
    // supersedes the binary slot. Otherwise preserve the committed slot for the
    // next startup. Fatal flow never needs a replacement generation.
    CrashRawShutdown(ReportPersisted);
    Exit;
  end;

  // Non-fatal: the process keeps running. Show the dialog if there is a handler.
  // Re-arm: on Linux our signal handler is "one-shot" - after the snapshot it
  // restored prev (Pascal RTL) and thereby removed itself from active. Without a
  // re-install the NEXT hardware crash goes straight to the Pascal RTL, bypassing
  // us -> later .el files would lack the "Registers:" section. This crash's
  // snapshot was already consumed in CrashBuildELReportText above, so re-install
  // is safe; GOldHandlers keeps the original Pascal RTL handler.
  // The one-shot handler is about to be re-armed. Rotate its raw descriptors
  // first: delete the old generation only after full .el persistence; otherwise
  // preserve it for startup recovery and open a fresh generation.
  CrashRawRotate(ReportPersisted);
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
    // No dialog handler (e.g. worker-thread exception in a console target).
    // Persist + mark before the background transport starts; the process stays
    // alive, so the brief must not claim termination.
    WriteCrashBriefToConsole(AReport, False);
    if FConfig.UploadEnabled then
    begin
      if TCrashReporter.UploadLastReportAsync(Text) then
        ConsoleLine('Upload: queued in background (report marked pending)')
      else
        ConsoleLine('Upload: background delivery could not be armed');
    end;
    ResetAlreadyReported;
  end;
end;

procedure TCrashReporterImpl.Install(const AConfig: TCrashConfig);
begin
  // A live runtime is strictly idempotent: a repeated Init never mutates only
  // half of the configuration. Reconfigure is Shutdown + a fresh Init.
  if not CrashAcceptInitialConfig(FInstalled, FConfig, AConfig) then
    Exit;
  FOperationLifetime := TCrashOperationLifetime.Create;
  FBreadcrumbs := TCrashBreadcrumbStore.Create(FConfig.BreadcrumbCapacity);

  // TCrashCapture is created in Crash.CallStack's initialization (it installs
  // ExceptProc / ExceptionAcquired / GetExceptionStackInfoProc). Here we just
  // route its reports to us. Application.OnException is UI-specific and is wired
  // by the host where Application exists (the FMX .dpr).
  TCrashCapture.OnReport := HandleReport;

  // Did the previous run's RestartOnFreeze spawn us? Read (and consume) the
  // notice BEFORE the watchdog exists (its loop guard reads the flag) and
  // BEFORE the pending scan (a freeze-restart boot uploads leftovers
  // regardless of UploadPendingOnStartup - see ScanPendingCrashReports).
  ReadRestartNoticeAtBoot;

  if FConfig.FreezeDetection then
    InstallFreezeDetector;

  // Convert committed slots from previous processes before opening this
  // process's own preallocated files. Recovered .el files then flow through the
  // ordinary surface/upload scan below.
  RecoverRawFallbackReports;

  // Prepare fixed O_CLOEXEC raw slots before hardware signal handlers are
  // installed by Init. No-op on unsupported targets or when persistence and
  // delivery are both disabled.
  CrashRawPrepare(EffectiveReportDir, EffectiveScanPrefix, FConfig.AppName,
    FConfig.AppVersion, FConfig.CompilationTime, GetExeBaseName,
    FConfig.SaveToFile or FConfig.UploadEnabled);

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

const
  { Loop guard for RestartOnFreeze: a run that was itself freeze-restarted must
    stay up this long before it may restart again. Breaks a systematic
    freeze->restart->freeze loop at one extra instance per interval; the guarded
    episode is still fully reported. }
  FREEZE_RESTART_MIN_UPTIME_MS = 10 * 60 * 1000;

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
  Notice: TCrashRestartNotice;
  WillRestart, WroteNotice, EnvMarked, DeliveryArmed, UploadQueued: Boolean;
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
  Ctx.AppParameters := CrashCurrentParameters(FConfig);
  Ctx.DisabledSections := FConfig.DisabledSections;
  if FBreadcrumbs <> nil then
  try
    Ctx.StepsToReproduceText := FBreadcrumbs.SnapshotText;
  except
    // A frozen breadcrumb writer must not hold up freeze reporting.
  end;
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

  CrashCollectELModules(Ctx);
  Text := CrashBuildELReportText(AReport, Ctx);
  Info.BugID := CrashGenerateExceptionID(AReport);

  WillRestart := FConfig.RestartOnFreeze and TCrashReporter.CanRestart and
    ((not FWasFreezeRestarted) or
     (TThread.GetTickCount64 - FAppStartTick >= FREEZE_RESTART_MIN_UPTIME_MS));

  Path := '';
  if FConfig.SaveToFile or FConfig.UploadEnabled then
  begin
    Path := BuildCrashFilePathForID(Info.BugID);
    WriteReportTextToUniqueFile(Text, Path);
  end;
  Info.ReportFile := Path;
  DeliveryArmed := False;
  if FConfig.UploadEnabled and (Path <> '') then
    DeliveryArmed := CrashWritePendingMarker(Path);
  UploadQueued := False;

  if Path <> '' then
    ConsoleLine(Format('*** freeze detected (%d ms) - report saved to %s ***',
      [AFrozenForMS, Path]))
  else
    ConsoleLine(Format('*** freeze detected (%d ms) ***', [AFrozenForMS]));

  // RestartOnFreeze: replace the frozen instance with a fresh one. A pending
  // marker is best-effort here, not a restart prerequisite: the replacement
  // reads the restart notice/env guard and its startup scan authorizes ALL
  // leftovers through FWasFreezeRestarted, including an unmarked freeze .el.
  // The loop-guard channels are armed FIRST:
  // a restart that cannot leave a guard behind would re-create the very
  // restart loop the guard exists to break, so "no channel armed" demotes the
  // episode to report-only. All of it is decided BEFORE the host
  // notification, so Info.Restarting tells the host what actually happens.
  WroteNotice := False;
  if WillRestart then
  begin
    Notice := Default(TCrashRestartNotice);
    Notice.RestartedAt := Now;
    Notice.FrozenForMS := AFrozenForMS;
    Notice.BugID := Info.BugID;
    Notice.ReportFile := Info.ReportFile;
    Notice.Uploaded := Info.Uploaded;
    try
      CrashWriteRestartNoticeFile(RestartNoticeFilePath, Notice);
      WroteNotice := True;
    except
      // Unwritable report dir: the env mark can still carry the guard.
    end;
    EnvMarked := CrashSetFreezeRestartEnvMark;
    if not (WroteNotice or EnvMarked) then
    begin
      WillRestart := False;
      ConsoleLine('*** freeze restart skipped: no loop-guard channel could be armed (report-only) ***');
    end;
  end;
  Info.Restarting := WillRestart;

  if Assigned(FConfig.OnFreezeReport) then
  try
    FConfig.OnFreezeReport(Info);
  except
    // A host notification failure must not kill the watchdog.
  end;

  // Report-only freezes may upload while the watchdog returns immediately.
  // Restarting freezes defer entirely to the replacement process.
  if FConfig.UploadEnabled and DeliveryArmed and (not WillRestart) then
  try
    UploadQueued := CrashQueueUpload(FConfig.UploadUrl,
      FConfig.UploadFieldName, Text, Path, nil, FOperationLifetime);
    if UploadQueued then
      ConsoleLine('Upload: queued in background (freeze report marked pending)');
  except
    // The marker remains for startup recovery.
  end;

  if WillRestart then
  begin
    ConsoleLine('*** replacing the frozen application with a fresh instance (RestartOnFreeze) ***');
    // Hard exit: no unit finalization - it runs on THIS watchdog thread (it
    // would join itself in TCrashFreeze.Shutdown) and can deadlock on locks
    // the frozen main thread still holds. Returns only on spawn failure -
    // then killing ourselves would leave the user with nothing: undo the
    // restart markers and stay alive in report-only mode.
    if not TCrashReporter.Restart(True) then
    begin
      CrashConsumeFreezeRestartEnvMark;
      if WroteNotice then
        try TFile.Delete(RestartNoticeFilePath); except end;
      ConsoleLine('*** restart failed - the frozen instance stays alive (report-only) ***');
      if FConfig.UploadEnabled and DeliveryArmed and (not UploadQueued) then
      try
        if CrashQueueUpload(FConfig.UploadUrl, FConfig.UploadFieldName, Text,
             Path, nil, FOperationLifetime) then
          ConsoleLine('Upload: queued after restart failure');
      except
        // The marker remains for startup recovery.
      end;
    end;
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

function CrashQueueUpload(const AUrl, AFieldName, AReportText,
  AReportPath: String; const AOnComplete: TCrashUploadCompleteProc;
  const ALifetime: ICrashOperationLifetime): Boolean;
begin
  Result := CrashQueueUploadWithTransport(AUrl, AFieldName, AReportText,
    AReportPath, nil, AOnComplete, ALifetime);
end;

function CrashQueueUploadWithTransport(const AUrl, AFieldName, AReportText,
  AReportPath: String; const ATransport: TCrashUploadWorkerProc;
  const AOnComplete: TCrashUploadCompleteProc;
  const ALifetime: ICrashOperationLifetime): Boolean;
var
  UploadUrl, UploadField, UploadText, UploadPath: String;
  CompleteProc: TCrashUploadCompleteProc;
  TransportProc: TCrashUploadWorkerProc;
  Lifetime: ICrashOperationLifetime;
begin
  Result := False;
  if (ALifetime <> nil) and (not ALifetime.Active) then
    Exit;
  // Capture only immutable values. The worker never dereferences GReporter and
  // therefore remains safe if finalization starts while HTTP is still active.
  UploadUrl := AUrl;
  UploadField := AFieldName;
  UploadText := AReportText;
  UploadPath := AReportPath;
  CompleteProc := AOnComplete;
  TransportProc := ATransport;
  Lifetime := ALifetime;
  TThread.CreateAnonymousThread(
    procedure
    var
      Success: Boolean;
    begin
      if Assigned(TransportProc) then
        Success := TransportProc(UploadUrl, UploadField, UploadText,
          ExtractFileName(UploadPath))
      else
        Success := CrashUploadCore(UploadUrl, UploadField, UploadText,
          ExtractFileName(UploadPath));
      if Success then
        CrashDeleteReportAndPendingMarker(UploadPath);
      if Assigned(CompleteProc) and
         ((Lifetime = nil) or Lifetime.Active) then
        TThread.ForceQueue(nil,
          procedure
          begin
            if (Lifetime <> nil) and (not Lifetime.Active) then
              Exit;
            try
              CompleteProc(Success);
            except
              // A completion callback cannot affect delivery state.
            end;
          end);
    end).Start;
  Result := True;
end;

{$IFDEF AUTOTESTS}
function CrashAutoTestQueueUpload(const AReportText, AReportPath: String;
  const ATransport: TCrashAutoTestUploadProc;
  const AOnComplete: TCrashUploadCompleteProc): Boolean;
var
  WorkerTransport: TCrashUploadWorkerProc;
begin
  Result := False;
  if not Assigned(ATransport) then
    Exit;
  WorkerTransport :=
    function(const AUrl, AFieldName, AText, AFileName: String): Boolean
    begin
      Result := ATransport(AUrl, AFieldName, AText, AFileName);
    end;
  try
    Result := CrashQueueUploadWithTransport('autotest://upload', 'fixture',
      AReportText, AReportPath, WorkerTransport, AOnComplete, nil);
  except
    // The test observes a failed queue request directly.
  end;
end;
{$ENDIF}

function CrashELContainsRawCaptureKey(const AFilePath,
  ACaptureKey: String): Boolean;
var
  Text: String;
begin
  Result := False;
  if (AFilePath = '') or (ACaptureKey = '') then
    Exit;
  try
    Text := TFile.ReadAllText(AFilePath, TEncoding.Unicode);
    Result := Pos('Raw Capture Key: ' + ACaptureKey, Text) > 0;
  except
  end;
end;

{$IFDEF AUTOTESTS}
function CrashAutoTestELContainsRawCaptureKey(const AFilePath,
  ACaptureKey: String): Boolean;
begin
  Result := CrashELContainsRawCaptureKey(AFilePath, ACaptureKey);
end;

function CrashAutoTestFormatParameters(const AArguments,
  AAllowList: TArray<String>; const AIncludeAll: Boolean;
  const ASanitizer: TCrashSanitizeParametersProc): String;
begin
  Result := CrashFormatParameters(AArguments, AAllowList, AIncludeAll,
    ASanitizer);
end;

function CrashAutoTestRenderFileName(const ATemplate, AApp, AVersion,
  ABugID: String): String;
begin
  Result := CrashRenderFileNameTemplate(ATemplate, AApp, AVersion, ABugID);
end;

function CrashAutoTestTemplateScanPrefix(const ATemplate, AApp: String): String;
begin
  Result := CrashTemplateScanPrefix(ATemplate, AApp);
end;

function CrashAutoTestAcceptInitialConfig(var AInstalled: Boolean;
  var ACurrent: TCrashConfig; const AIncoming: TCrashConfig): Boolean;
begin
  Result := CrashAcceptInitialConfig(AInstalled, ACurrent, AIncoming);
end;

function CrashAutoTestOperationLifetimeGate: Boolean;
var
  TestResult: Boolean;
begin
  TestResult := False;
  // Unit tests run on a registry worker. Observe ForceQueue from the actual
  // main thread, where CheckSynchronize is legal.
  TThread.Synchronize(nil,
    procedure
    var
      Lifetime: ICrashOperationLifetime;
      Gate, Entered, TransportDone: TEvent;
      CallbackCalled, GateResult: Boolean;
      Deadline: UInt64;
    begin
      Lifetime := TCrashOperationLifetime.Create;
      Gate := TEvent.Create(nil, True, False, '');
      Entered := TEvent.Create(nil, True, False, '');
      TransportDone := TEvent.Create(nil, True, False, '');
      try
        CallbackCalled := False;
        GateResult := Lifetime.Active and CrashQueueUploadWithTransport(
          'autotest://lifetime', 'fixture', 'fixture', 'fixture.el',
          function(const AUrl, AFieldName, AText, AFileName: String): Boolean
          begin
            Entered.SetEvent;
            Gate.WaitFor(2000);
            TransportDone.SetEvent;
            Result := False;
          end,
          procedure(const ASuccess: Boolean)
          begin
            CallbackCalled := True;
          end,
          Lifetime);
        GateResult := GateResult and (Entered.WaitFor(2000) = wrSignaled);
        Lifetime.Deactivate;
        Gate.SetEvent;
        GateResult := GateResult and (not Lifetime.Active) and
          (TransportDone.WaitFor(2000) = wrSignaled);
        // Give the worker time to cross the post-transport gate and pump the
        // main queue. An incorrectly queued callback becomes observable here.
        Deadline := TThread.GetTickCount64 + 250;
        repeat
          CheckSynchronize(0);
          if CallbackCalled then
            Break;
          TThread.Sleep(5);
        until TThread.GetTickCount64 >= Deadline;
        TestResult := GateResult and (not CallbackCalled);
      finally
        Gate.SetEvent;
        TransportDone.WaitFor(2000);
        TransportDone.Free;
        Entered.Free;
        Gate.Free;
      end;
    end);
  Result := TestResult;
end;
{$ENDIF}

function TCrashReporterImpl.WriteRecoveredRawReport(
  const ARaw: TCrashRawRecord): Boolean;
var
  Report: TCrashReport;
  Ctx: TCrashELContext;
  Text, Path: String;
  IP, FaultAddr, ThreadID: UInt64;
  SignalNum, SignalCode: Integer;
  Address: array[0..0] of UIntPtr;
begin
  Result := False;
  Report := Default(TCrashReport);
  if ARaw.PayloadKind = rpkPrimary then
  begin
    IP := CrashRawPrimaryIP(ARaw.Primary);
    FaultAddr := ARaw.Primary.FaultAddr;
    ThreadID := ARaw.Primary.ThreadID;
    SignalNum := ARaw.Primary.SignalNum;
    SignalCode := ARaw.Primary.SignalCode;
    Report.ExceptionClassName := 'ERawHardwareFault';
  end
  else if ARaw.PayloadKind = rpkConcurrent then
  begin
    IP := ARaw.Concurrent.IP;
    FaultAddr := ARaw.Concurrent.FaultAddr;
    ThreadID := ARaw.Concurrent.ThreadID;
    SignalNum := ARaw.Concurrent.SignalNum;
    SignalCode := ARaw.Concurrent.SignalCode;
    Report.ExceptionClassName := 'ERawConcurrentHardwareFault';
  end
  else
    Exit;

  Report.ExceptionMessage := Format(
    'Committed raw fallback recovered signal %d (code=%d, fault=%s)',
    [SignalNum, SignalCode, IntToHex(FaultAddr, SizeOf(Pointer) * 2)]);
  Report.Source := csFatalProc;
  Address[0] := UIntPtr(IP);
  if IP <> 0 then
    Report.CallStack := TCrashCapture.SymbolizeAddressList(Address);
  if Length(Report.CallStack) > 0 then
    Report.ExceptionLocation := Report.CallStack[0]
  else
  begin
    Report.ExceptionLocation.Clear;
    Report.ExceptionLocation.CodeAddress := UIntPtr(IP);
  end;

  Ctx := CrashDefaultELContext(FAppStartTime, UIntPtr(IP), False);
  if ARaw.InitUnixSeconds > 0 then
    Ctx.StartTime := UnixToDateTime(ARaw.InitUnixSeconds, False);
  try
    Ctx.ExceptionTime := TFile.GetLastWriteTime(ARaw.FilePath);
  except
    Ctx.ExceptionTime := Now;
  end;
  Ctx.AppParameters := '';
  if ARaw.AppName <> '' then
    Ctx.AppName := ARaw.AppName
  else if ARaw.ExeName <> '' then
    Ctx.AppName := ARaw.ExeName
  else if FConfig.AppName <> '' then
    Ctx.AppName := FConfig.AppName;
  Ctx.AppVersion := ARaw.AppVersion;
  Ctx.CompileTime := ARaw.CompilationTime;
  Ctx.ThreadID := Cardinal(ThreadID);
  Ctx.ThreadName := 'RAW';
  Ctx.DisabledSections := FConfig.DisabledSections;
  CrashFormatRecoveredRaw(ARaw, Ctx.CpuSnapshot, Ctx.SignalInfoSection);
  CrashCollectELModules(Ctx);
  Text := CrashBuildELReportText(Report, Ctx);

  FExceptionID := CrashGenerateExceptionID(Report);
  Path := BuildCrashFilePath;
  Result := CrashWriteReportTextToUniqueFile(Text, Path);
  FExceptionID := '';
end;

procedure TCrashReporterImpl.RecoverRawFallbackReports;
var
  Dir, Pattern, RawPath, ELPath: String;
  RawFiles, ELFiles: TArray<String>;
  Raw: TCrashRawRecord;
  Duplicate: Boolean;
begin
  Dir := EffectiveReportDir;
  if Dir = '' then
    Exit;
  RawFiles := CrashRawEnumerateFiles(Dir, EffectiveScanPrefix);
  if Length(RawFiles) = 0 then
    Exit;
  Pattern := EffectiveScanPrefix + '*.el';
  try
    ELFiles := TDirectory.GetFiles(Dir, Pattern);
  except
    ELFiles := nil;
  end;
  for RawPath in RawFiles do
  begin
    if not CrashRawReadBlock(RawPath, Raw) then
    begin
      if CrashRawFileIsStale(RawPath) then
        CrashRawDeleteFile(RawPath);
      Continue;
    end;
    Duplicate := False;
    for ELPath in ELFiles do
      if CrashELContainsRawCaptureKey(ELPath, Raw.CaptureKey) then
      begin
        Duplicate := True;
        Break;
      end;
    if Duplicate or WriteRecoveredRawReport(Raw) then
    begin
      CrashRawDeleteFile(RawPath);
      CrashRawDeleteUntouchedSibling(Raw);
    end;
  end;
end;

procedure TCrashReporterImpl.ScanPendingCrashReports;
var
  Dir, FilePath, Pattern, MarkerPattern: String;
  Files, MarkerFiles, UploadFiles, StartupUploadFiles,
    SurfaceFiles: TArray<String>;
  Kept: TList<String>;
  UploadAll: Boolean;
begin
  Dir := EffectiveReportDir; // same directory we write to (see BuildCrashFilePath)
  if Dir = '' then
    Exit;
  // The scan prefix keeps different targets in one folder from eating each
  // other's files, while (with a stable host-set ScanFileNamePrefix) still
  // matching reports written by a previous app version.
  Pattern := EffectiveScanPrefix + '*.el';
  MarkerPattern := EffectiveScanPrefix + '*.pending';

  // A crash between deleting the sent .el and deleting its marker leaves a
  // harmless orphan. Remove it before partitioning the live reports.
  MarkerFiles := nil;
  try
    MarkerFiles := TDirectory.GetFiles(Dir, MarkerPattern);
  except
  end;
  CrashCleanupOrphanPendingMarkers(MarkerFiles);

  Files := nil;
  try
    Files := TDirectory.GetFiles(Dir, Pattern);
  except
    Exit; // directory unavailable - don't fail bootstrap
  end;
  if Files = nil then
    Exit;

  // RestartOnFreeze and the explicit global policy authorize every leftover.
  // In ordinary desktop mode only a valid per-file marker authorizes upload;
  // unmarked reports are still surfaced even when marked neighbours exist.
  UploadAll := FConfig.UploadEnabled and
    (FConfig.UploadPendingOnStartup or FWasFreezeRestarted);
  CrashPartitionPendingFiles(Files, FConfig.UploadEnabled, UploadAll,
    UploadFiles, SurfaceFiles);
  Kept := TList<String>.Create;
  try
    for FilePath in SurfaceFiles do
      try
        Kept.Add(TFile.ReadAllText(FilePath, TEncoding.Unicode));
      except
        // Couldn't read - skip silently; the file stays.
      end;
    FPendingReports := Kept.ToArray;
  finally
    Kept.Free;
  end;

  if Length(UploadFiles) = 0 then
    Exit;

  // Select the bounded batch before starting the worker. Reports outside it
  // are not opened and their .pending markers remain untouched for a later
  // launch, regardless of success/failure inside this batch.
  StartupUploadFiles := CrashTakeStartupUploadBatch(UploadFiles,
    CRASH_MAX_STARTUP_UPLOADS);
  if Length(StartupUploadFiles) = 0 then
    Exit;

  // Upload OFF the startup path. The worker owns immutable copies and never
  // dereferences the reporter singleton during or after finalization.
  var UploadUrl := FConfig.UploadUrl;
  var UploadField := FConfig.UploadFieldName;
  TThread.CreateAnonymousThread(
    procedure
    var
      I: Integer;
      UpFile, UpText: String;
    begin
      for I := 0 to High(StartupUploadFiles) do
      begin
        UpFile := StartupUploadFiles[I];
        try
          UpText := TFile.ReadAllText(UpFile, TEncoding.Unicode);
          if CrashUploadCore(UploadUrl, UploadField, UpText,
               ExtractFileName(UpFile)) then
            CrashDeleteReportAndPendingMarker(UpFile);
        except
          // Unreadable/upload failure: report and marker stay for a later boot.
        end;
      end;
    end).Start;
end;

function TCrashReporterImpl.TakePendingCrashReports: TArray<String>;
begin
  Result := FPendingReports;
  FPendingReports := nil;
end;

{ ---- TCrashReporter façade ---- }

class procedure TCrashReporter.Init(const AConfig: TCrashConfig);
var
  MainCoverage: TCrashThreadCoverage;
  MainAlreadyRegistered, MachMainCovered: Boolean;
begin
  if GReporter = nil then
    GReporter := TCrashReporterImpl.Create;
  GReporter.Install(AConfig);
  GReporter.FLock.Enter;
  try
    MainAlreadyRegistered := GReporter.FMainThreadCoverage.Registered;
  finally
    GReporter.FLock.Leave;
  end;
  if MainAlreadyRegistered then
    Exit;
  // POSIX: capture registers + stack for AV/div0/illegal-instruction before the
  // kernel re-delivers the signal to the Pascal RTL handler. No-op on Windows.
  CrashInstallSignalHandlers;
  // Register the calling MAIN thread through the same calm-path API workers use.
  // This reuses the alt-stack just installed above and adds the existing macOS
  // thread-level Mach observer where required.
  MainCoverage := RegisterCurrentThread('MAIN');
  MachMainCovered := MainCoverage.MachHandler <> cmsUnavailable;
  GReporter.FLock.Enter;
  try
    GReporter.FMainThreadCoverage := MainCoverage;
    GReporter.FMachMainThreadCovered := MachMainCovered;
  finally
    GReporter.FLock.Leave;
  end;
  if not MachMainCovered then
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

class procedure TCrashReporter.Shutdown;
var
  Reporter: TCrashReporterImpl;
begin
  // Calm/quiesced host path by contract. Publish inactivity first so no new
  // façade operation can attach itself to the runtime being dismantled.
  Reporter := GReporter;
  if Reporter = nil then
    Exit;
  GReporter := nil;
  Reporter.Free;
end;

class procedure TCrashReporter.AddBreadcrumb(const ACategory,
  AMessage: String);
var
  Reporter: TCrashReporterImpl;
begin
  Reporter := GReporter;
  if (Reporter = nil) or (not Reporter.FInstalled) or
     (Reporter.FBreadcrumbs = nil) then
    Exit;
  try
    Reporter.FBreadcrumbs.Add(ACategory, AMessage);
  except
    // Diagnostics must never affect the host operation being recorded.
  end;
end;

class procedure TCrashReporter.ClearBreadcrumbs;
var
  Reporter: TCrashReporterImpl;
begin
  Reporter := GReporter;
  if (Reporter = nil) or (Reporter.FBreadcrumbs = nil) then
    Exit;
  try
    Reporter.FBreadcrumbs.Clear;
  except
  end;
end;

class function TCrashReporter.Active: Boolean;
begin
  Result := (GReporter <> nil) and GReporter.FInstalled;
end;

class function TCrashReporter.RegisterCurrentThread(
  const AName: String): TCrashThreadCoverage;
var
  Reporter: TCrashReporterImpl;
  Existing: TCrashThreadCoverage;
begin
  Result := Default(TCrashThreadCoverage);
  Reporter := GReporter;
  if (Reporter = nil) or (not Reporter.FInstalled) then
    Exit;

  Result.ThreadID := CrashCurrentThreadIdentity;
  // Fast idempotent path. The TLS owner prevents a stale dictionary entry from
  // an abnormally exited old thread with a recycled OS identity being trusted.
  if (GCoverageReporter = Pointer(Reporter)) and
     (GCoverageReporterInstanceID = Reporter.FInstanceID) then
  begin
    Reporter.FLock.Enter;
    try
      if Reporter.FThreadCoverages.TryGetValue(Result.ThreadID, Existing) then
        Exit(Existing);
    finally
      Reporter.FLock.Leave;
    end;
  end;

  Result.Registered := True;
  Result.Name := AName;
  Result.AltStack := CrashRegisterAltStackForCurrentThread;
  Result.MachHandler := CrashRegisterMachForCurrentThread;
  Reporter.FLock.Enter;
  try
    Reporter.FThreadCoverages.AddOrSetValue(Result.ThreadID, Result);
  finally
    Reporter.FLock.Leave;
  end;
  GCoverageReporter := Pointer(Reporter);
  GCoverageReporterInstanceID := Reporter.FInstanceID;
end;

class procedure TCrashReporter.UnregisterCurrentThread;
var
  Reporter: TCrashReporterImpl;
  ThreadID: UInt64;
begin
  Reporter := TCrashReporterImpl(GCoverageReporter);
  ThreadID := CrashCurrentThreadIdentity;
  if (Reporter <> nil) and (Reporter = GReporter) and
     (GCoverageReporterInstanceID = Reporter.FInstanceID) then
  begin
    Reporter.FLock.Enter;
    try
      Reporter.FThreadCoverages.Remove(ThreadID);
    finally
      Reporter.FLock.Leave;
    end;
  end;
  GCoverageReporter := nil;
  GCoverageReporterInstanceID := 0;
  CrashUnregisterAltStackForCurrentThread;
end;

class function TCrashReporter.GetStatus: TCrashStatus;
var
  Reporter: TCrashReporterImpl;
  Coverage: TCrashThreadCoverage;
  I: Integer;
  CurrentID: UInt64;
begin
  Result := Default(TCrashStatus);
  Reporter := GReporter;
  if Reporter = nil then
    Exit;
  Result.Active := Reporter.FInstalled;
  Result.SignalHandlersInstalled := CrashSignalHandlersInstalled;
  Result.FreezeDetectorActive := TCrashFreeze.Active;
  CurrentID := CrashCurrentThreadIdentity;
  Reporter.FLock.Enter;
  try
    Result.RegisteredThreadCount := Reporter.FThreadCoverages.Count;
    Result.MainThread := Reporter.FMainThreadCoverage;
    SetLength(Result.Threads, Result.RegisteredThreadCount);
    I := 0;
    for Coverage in Reporter.FThreadCoverages.Values do
    begin
      Result.Threads[I] := Coverage;
      Inc(I);
    end;
    if (GCoverageReporter = Pointer(Reporter)) and
       (GCoverageReporterInstanceID = Reporter.FInstanceID) then
      Reporter.FThreadCoverages.TryGetValue(CurrentID, Result.CurrentThread);
  finally
    Reporter.FLock.Leave;
  end;
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
    CrashDeleteReportAndPendingMarker(GReporter.FCrashFilePath);
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

class function TCrashReporter.CanUpload: Boolean;
begin
  Result := (GReporter <> nil) and GReporter.FConfig.UploadEnabled and
    (GReporter.FConfig.UploadUrl <> '');
end;

class function TCrashReporter.UploadLastReportAsync(const AReportText: String;
  const AOnComplete: TCrashUploadCompleteProc): Boolean;
var
  Reporter: TCrashReporterImpl;
  UploadUrl, UploadField, ReportPath: String;
begin
  Result := False;
  Reporter := GReporter;
  if (Reporter = nil) or (not Reporter.FConfig.UploadEnabled) or
     (Reporter.FConfig.UploadUrl = '') then
    Exit;
  if not Reporter.EnsureCurrentReportPending(AReportText) then
    Exit;
  UploadUrl := Reporter.FConfig.UploadUrl;
  UploadField := Reporter.FConfig.UploadFieldName;
  ReportPath := Reporter.FCrashFilePath;
  try
    Result := CrashQueueUpload(UploadUrl, UploadField, AReportText, ReportPath,
      AOnComplete, Reporter.FOperationLifetime);
  except
    // The durable marker remains for startup recovery.
  end;
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

{$IF Defined(LINUX)}
// close_range(2) via the raw syscall: the libc wrapper only exists in
// glibc 2.34+, and an unresolved import would stop the binary from LOADING on
// older distros - syscall() resolves everywhere, an old kernel just returns
// ENOSYS and the caller falls back to the fcntl loop.
function syscall(ANumber: IntPtr): IntPtr; cdecl; varargs;
  external libc name _PU + 'syscall';

const
  SYS_close_range      = 436; // x86-64
  CLOSE_RANGE_CLOEXEC  = 4;   // mark instead of close
{$ENDIF}

type
  // struct rlimit; rlim_t is 64-bit on every target built here. The RTL has
  // no Posix.SysResource unit, hence the local declaration.
  TCrashRLimit = record
    rlim_cur: UInt64;
    rlim_max: UInt64;
  end;

const
  CRASH_RLIMIT_NOFILE = {$IF Defined(MACOS)} 8 {$ELSE} 7 {$ENDIF};

function getrlimit(resource: Integer; var rlp: TCrashRLimit): Integer; cdecl;
  external libc name _PU + 'getrlimit';

function CrashSetCloseOnExec(const AFd: Integer): Boolean;
// One sweep step. EINTR = retry; EBADF = a hole in the table, fine; any
// other error on a live descriptor means the sweep cannot vouch for it.
var
  RC: Integer;
begin
  repeat
    RC := fcntl(AFd, F_SETFD, FD_CLOEXEC);
  until (RC = 0) or (errno <> EINTR);
  Result := (RC = 0) or (errno = EBADF);
end;

function CrashMarkFDsCloseOnExecBySweep(const AFdLimit: Integer): Boolean;
var
  Fd: Integer;
begin
  Result := True;
  for Fd := 3 to AFdLimit - 1 do
    if not CrashSetCloseOnExec(Fd) then
      Result := False; // keep sweeping - mark as much as possible - but report
end;

function CrashFdSweepLimitFromRLimit(const ARlimCur: UInt64): Integer;
begin
  if ARlimCur <= UInt64(High(Integer)) then
    Result := Integer(ARlimCur)
  else
    Result := -1;
end;

{$IF Defined(LINUX)}
const
  SYS_getdents64     = 217;    // x86-64
  CRASH_O_DIRECTORY  = $10000; // Linux x86-64 O_DIRECTORY
  CRASH_O_CLOEXEC    = $80000; // Linux O_CLOEXEC

function CrashMarkFDsCloseOnExecViaProcFS: Boolean;
// Walk the ACTUALLY open descriptors via /proc/self/fd - raw syscalls only
// (open/getdents64/close; libc readdir allocates and is not
// async-signal-safe). No range bound: any fd number is reached.
var
  DirFd: Integer;
  Buf: array [0..1023] of Byte;
  NRead, Off: IntPtr;
  Name: PAnsiChar;
  Fd: Integer;
  Ok: Boolean;

  function ParseFdName(P: PAnsiChar; out AFd: Integer): Boolean;
  var
    V: Integer;
  begin
    Result := False;
    if P^ = #0 then
      Exit;
    V := 0;
    while P^ <> #0 do
    begin
      if (P^ < '0') or (P^ > '9') then
        Exit; // '.', '..'
      V := V * 10 + (Ord(P^) - Ord('0'));
      Inc(P);
    end;
    AFd := V;
    Result := True;
  end;

begin
  Result := False;
  repeat
    DirFd := Posix.Fcntl.open('/proc/self/fd',
      O_RDONLY or CRASH_O_DIRECTORY or CRASH_O_CLOEXEC);
  until (DirFd >= 0) or (errno <> EINTR);
  if DirFd < 0 then
    Exit;
  Ok := True;
  repeat
    NRead := syscall(SYS_getdents64, IntPtr(DirFd), IntPtr(@Buf[0]),
      IntPtr(SizeOf(Buf)));
    if NRead < 0 then
    begin
      if errno = EINTR then
        Continue;
      Ok := False;
      Break;
    end;
    Off := 0;
    while Off < NRead do
    begin
      // struct linux_dirent64: u64 d_ino; s64 d_off; u16 d_reclen;
      // u8 d_type; char d_name[]
      Name := PAnsiChar(@Buf[Off + 19]);
      if ParseFdName(Name, Fd) and (Fd >= 3) and (Fd <> DirFd) then
        if not CrashSetCloseOnExec(Fd) then
          Ok := False;
      Inc(Off, PWord(@Buf[Off + 16])^);
    end;
  until NRead = 0;
  __close(DirFd);
  Result := Ok;
end;
{$ENDIF}

function CrashChildMarkFDsCloseOnExec(const AFdLimit: Integer): Boolean;
// Runs IN THE CHILD between fork and execv: mark every fd >= 3 close-on-exec
// so the exec'd replacement starts with only stdio (see the interface
// comment). Everything here is async-signal-safe; the sweep limit is read by
// the PARENT before fork and passed in. The confirmation pipe's write end is
// caught too - it is already CLOEXEC, and a failed execv can still write
// into it (CLOEXEC only acts on a successful exec). False = the fd table
// cannot be vouched for; the caller must NOT exec.
begin
  {$IF Defined(LINUX)}
  if syscall(SYS_close_range, IntPtr(3), IntPtr(High(Cardinal)),
       IntPtr(CLOSE_RANGE_CLOEXEC)) = 0 then
    Exit(True);
  if CrashMarkFDsCloseOnExecViaProcFS then
    Exit(True);
  {$ENDIF}
  if AFdLimit < 0 then
    Exit(False); // no exact bound: never run a knowingly incomplete sweep
  Result := CrashMarkFDsCloseOnExecBySweep(AFdLimit);
end;

function CrashSpawnDetachedVerified(const AExePath: String;
  const AArgv: TArray<String>): Boolean;
var
  ChildPid: pid_t;
  ArgBytes: array of TBytes;
  Argv: array of MarshaledAString;
  ExePath: TBytes;
  I, FdLimit, WStatus: Integer;
  RLim: TCrashRLimit;
  Fds: TPipeDescriptors;
  Confirm: Byte;
  N: ssize_t;
begin
  Result := False;
  // Marshal argv BEFORE fork: in the child of a multithreaded process only
  // async-signal-safe calls are allowed until execv - a heap allocation there
  // can deadlock on a lock another thread held at fork time.
  ExePath := TEncoding.UTF8.GetBytes(AExePath);
  SetLength(ExePath, Length(ExePath) + 1); // null-terminate
  SetLength(ArgBytes, Length(AArgv));
  SetLength(Argv, Length(AArgv) + 1); // +1 for the NULL terminator
  for I := 0 to High(AArgv) do
  begin
    ArgBytes[I] := TEncoding.UTF8.GetBytes(AArgv[I]);
    SetLength(ArgBytes[I], Length(ArgBytes[I]) + 1); // null-terminate
    Argv[I] := MarshaledAString(@ArgBytes[I][0]);
  end;
  Argv[Length(AArgv)] := nil;

  // Exact bound for the LAST-RESORT bounded sweep (Linux normally takes
  // close_range or the /proc walk - neither needs one; macOS has no unbounded
  // primitive). A finite representable rlim_cur is the honest limit: no fd at
  // or above it can exist. A failed getrlimit, RLIM_INFINITY or a value beyond
  // Integer cannot be swept completely by this loop, so keep the -1 sentinel:
  // Linux may still succeed through an unbounded level; otherwise the child
  // aborts before execv. Read in the parent because getrlimit is not on the
  // async-signal-safe list.
  FdLimit := -1;
  if getrlimit(CRASH_RLIMIT_NOFILE, RLim) = 0 then
    FdLimit := CrashFdSweepLimitFromRLimit(RLim.rlim_cur);

  // Exec-confirmation channel (see the interface comment). Fail-closed: a
  // spawn we cannot confirm is a spawn we do not attempt - the caller keeps
  // the process alive instead of exiting on a guess.
  if pipe(Fds) <> 0 then
    Exit;
  if fcntl(Fds.WriteDes, F_SETFD, FD_CLOEXEC) <> 0 then
  begin
    __close(Fds.ReadDes);
    __close(Fds.WriteDes);
    Exit;
  end;

  ChildPid := fork;
  if ChildPid = 0 then
  begin
    // Child: detach from the parent's fd table before exec - only stdio and
    // the (CLOEXEC) confirmation pipe may cross into the replacement. A table
    // the sweep cannot vouch for aborts the spawn: marker + _exit(126).
    if not CrashChildMarkFDsCloseOnExec(FdLimit) then
    begin
      Confirm := 2;
      repeat
        N := __write(Fds.WriteDes, @Confirm, 1);
      until (N = 1) or ((N < 0) and (errno <> EINTR));
      Posix.Unistd._exit(126);
    end;
    // If execv returns, it failed - report through the pipe (the write
    // retried across EINTR: a lost marker byte would read as success), then
    // _exit, not Halt: unit finalization is not fork-safe either. (write and
    // _exit are async-signal-safe.)
    execv(MarshaledAString(@ExePath[0]), @Argv[0]);
    Confirm := 1;
    repeat
      N := __write(Fds.WriteDes, @Confirm, 1);
    until (N = 1) or ((N < 0) and (errno <> EINTR));
    Posix.Unistd._exit(127);
  end;
  if ChildPid = -1 then
  begin
    // fork failed - nothing was spawned.
    __close(Fds.ReadDes);
    __close(Fds.WriteDes);
    Exit;
  end;
  __close(Fds.WriteDes);
  repeat
    N := __read(Fds.ReadDes, @Confirm, 1);
  until (N >= 0) or (errno <> EINTR);
  __close(Fds.ReadDes);
  if N < 0 then
  begin
    // The channel broke: exec state UNKNOWN. Fail-closed - this process must
    // keep living, so make the outcome deterministic by taking the child
    // down (it is either a not-yet-exec'd twin or a milliseconds-old
    // replacement that has not touched anything durable yet).
    kill(ChildPid, SIGKILL);
    waitpid(ChildPid, nil, 0);
    Exit;
  end;
  if N > 0 then
  begin
    // Failure marker delivered (sweep=2 / execv=1); reap the child.
    waitpid(ChildPid, nil, 0);
    Exit;
  end;
  // EOF: normally a successful exec closed the CLOEXEC write end. Guard the
  // lost-marker corner - a child that died without managing to deliver its
  // byte also produces an EOF, but by then it is a zombie carrying one of
  // OUR failure exit codes; a live (or differently-exited) child is a real
  // replacement.
  if (waitpid(ChildPid, @WStatus, WNOHANG) = ChildPid) and
     WIFEXITED(WStatus) and
     ((WEXITSTATUS(WStatus) = 126) or (WEXITSTATUS(WStatus) = 127)) then
    Exit;
  Result := True;
end;
{$ENDIF}

class function TCrashReporter.Restart(const AHardExit: Boolean): Boolean;
{$IF Defined(MSWINDOWS)}
var
  SI: TStartupInfo;
  PI: TProcessInformation;
  CmdLine: String;
{$ELSEIF Defined(LINUX) or Defined(MACOS)}
var
  Args: TArray<String>;
  I: Integer;
{$ENDIF}

  procedure QuitSelf;
  // AHardExit skips unit finalization (see the declaration comment); the
  // fallthrough Halt only ever runs in the soft mode.
  begin
    if AHardExit then
    {$IF Defined(MSWINDOWS)}
      TerminateProcess(GetCurrentProcess, 0);
    {$ELSE}
      Posix.Unistd._exit(0);
    {$ENDIF}
    Halt(0);
  end;

begin
  Result := False;
  if not CanRestart then
  begin
    // Restart is disallowed here (not a spawn failure): quit as requested.
    QuitSelf;
    Exit;
  end;

  {$IF Defined(MSWINDOWS)}
  // GetCommandLine, not a ParamStr rebuild: the original quoting survives.
  CmdLine := GetCommandLine;
  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  if not CreateProcess(nil, PChar(CmdLine), nil, nil, False, 0, nil, nil, SI, PI) then
    Exit; // spawn failed - the caller keeps this process alive
  CloseHandle(PI.hProcess);
  CloseHandle(PI.hThread);
  QuitSelf;
  {$ELSEIF Defined(LINUX) or Defined(MACOS)}
  SetLength(Args, ParamCount + 1);
  for I := 0 to ParamCount do
    Args[I] := ParamStr(I);
  if not CrashSpawnDetachedVerified(ParamStr(0), Args) then
    Exit; // spawn failed - the caller keeps this process alive
  QuitSelf;
  {$ELSE}
  QuitSelf;
  {$ENDIF}
end;

class function TCrashReporter.TakeRestartNotice: TCrashRestartNotice;
begin
  if GReporter = nil then
    Exit(Default(TCrashRestartNotice));
  Result := GReporter.FRestartNotice;
  GReporter.FRestartNotice := Default(TCrashRestartNotice);
  // FWasFreezeRestarted stays: the loop guard outlives the notification.
end;

class function TCrashReporter.RestartNoticeFilePath: String;
begin
  if GReporter = nil then Result := ''
  else                    Result := GReporter.RestartNoticeFilePath;
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
