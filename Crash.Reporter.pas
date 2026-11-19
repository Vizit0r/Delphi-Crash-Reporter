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
  decides how to surface them (stderr, log, dialog, server).

  Copyright (c) 2026 Vizit0r. BSD 2-Clause license (see LICENSE.txt). }

interface

uses
  Crash.CallStack,      // TCrashReport, TCrashReportSection(s)
  Crash.Freeze,         // TCrashFreezeInfo / TCrashFreezeReportProc (freeze detector)
  Crash.ReportNaming,   // TCrashSanitizeParametersProc
  Crash.Restart,        // TCrashRestartNotice
  Crash.ThreadRegistry, // TCrashMachState, TCrashThreadCoverage
  Crash.Upload;         // TCrashUploadCompleteProc

type
  { Shows a modal dialog with the full report text for non-fatal exceptions.
    Blocks until the user closes it. If nil, non-fatal exceptions fall back to a
    brief stderr message. Not called for fatal (csFatalProc) - the process is
    dying, only a brief stderr line is printed. }
  TCrashShowDialogProc = reference to procedure(const AReportText: String);

  { Completion callback for a background upload. It is queued to the main
    thread; the transport worker never calls host/UI code directly. }
  TCrashUploadCompleteProc = Crash.Upload.TCrashUploadCompleteProc;

  { Optional: returns extra free-form text appended to the report as a trailing
    section (e.g. "what the app was doing"). Called at report time. }
  TCrashCollectContextProc = reference to function: String;

  { Optional privacy hook. Receives ParamStr(1..N) as separate values and
    returns the exact single-line text allowed into Application/1.4. An
    exception fails private and emits an empty field. }
  TCrashSanitizeParametersProc = Crash.ReportNaming.TCrashSanitizeParametersProc;

  { Optional last-step veto. Called with the fully-built report (message, class,
    stack, source) right before it is persisted/surfaced. Return False to drop the
    report entirely; True (or a nil callback) keeps it. Runs in the crash path -
    keep it cheap and robust. An exception raised by the filter is swallowed and
    the report is KEPT: a faulty filter must never suppress a real crash. }
  TCrashReportFilterProc = reference to function(const AReport: TCrashReport): Boolean;

  { Optional: extra files for a non-fatal report (logs, state dumps). Called
    synchronously on the reporting thread, only for csHandled / csOnException /
    csAcquired reports - never for fatal, freeze or recovered ones.
    AReport.ExceptionObject is valid during the call. Write the files into
    ATempDir (it exists, the library deletes it later) or name existing files
    by full path, and return them in AFiles. With at least one file the report
    is written as a ".elp" zip package (BugReport.el + the files) instead of a
    plain ".el". Keep it bounded: it runs in the reporting path, and an
    exception raised here is swallowed (the report goes out without files). }
  TCrashCollectAttachmentsProc = reference to procedure(
    const AReport: TCrashReport; const ATempDir: String;
    var AFiles: TArray<String>);

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
      only on targets with capture support (Linux x86-64, macOS, Android
      ARM64); elsewhere the flag is accepted and ignored. Report-only: the
      frozen thread is never aborted. The host must call TCrashFreeze.Ping
      from the watched (main) loop, otherwise detection stays dormant; pings
      from other threads are ignored. }
    FreezeDetection: Boolean;
    { Capture registered application threads in addition to the exception/frozen
      thread. Default False in the standalone library; the host opts in. }
    ExtendedThreads: Boolean;
    { Maximum number of additional registered threads included in one report.
      <=0 selects the default 32; 1..128 is exact; larger values clamp to 128. }
    ExtendedThreadsMax: Integer;
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
    { Extra files for non-fatal reports, see TCrashCollectAttachmentsProc.
      nil -> always a plain .el. }
    OnCollectAttachments: TCrashCollectAttachmentsProc;
  end;


{ A config pre-filled with sensible defaults. Override the fields you need. }
function DefaultCrashConfig: TCrashConfig;

type
  TCrashMachState = Crash.ThreadRegistry.TCrashMachState;

const
  cmsNotRequired = Crash.ThreadRegistry.cmsNotRequired;
  cmsUnavailable = Crash.ThreadRegistry.cmsUnavailable;
  cmsInstalled = Crash.ThreadRegistry.cmsInstalled;

type
  { Actual calm-path coverage verdict for one registered thread. }
  TCrashThreadCoverage = Crash.ThreadRegistry.TCrashThreadCoverage;

  TCrashStatus = record
    Active: Boolean;
    SignalHandlersInstalled: Boolean;
    FreezeDetectorActive: Boolean;
    ExtendedThreadsEnabled: Boolean;
    ExtendedThreadsAvailable: Boolean;
    RegisteredThreadCount: Integer;
    MainThread: TCrashThreadCoverage;
    CurrentThread: TCrashThreadCoverage;
    Threads: TArray<TCrashThreadCoverage>;
  end;

  { What a previous run left behind when RestartOnFreeze replaced a frozen
    instance (see Crash.Restart). }
  TCrashRestartNotice = Crash.Restart.TCrashRestartNotice;

{$IFDEF AUTOTESTS}
{ The exact anti-cascade transition used by HandleReport, exposed so state
  tests can prove that a second capture is not allowed to create a file. }
function CrashAutoTestTryClaimReport(var AAlreadyReported: Boolean): Boolean;
function CrashAutoTestAcceptInitialConfig(var AInstalled: Boolean;
  var ACurrent: TCrashConfig; const AIncoming: TCrashConfig): Boolean;
function CrashAutoTestSetExtendedCaptureOverride(
  const AEnabled: Boolean): Boolean;
function CrashAutoTestSetExtendedThreadsMax(const AValue: Integer;
  out APrevious: Integer): Boolean;
function CrashAutoTestCaptureExtendedThreads(const APrimaryThreadID: UInt64;
  out AThreads: TArray<TCrashThreadStack>; out AOmitted: Integer;
  out ATotalMS, AMaxThreadMS: UInt64): Boolean;
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
    class function RegisterCurrentThread(const AName: String = '';
      const AGroupID: UInt64 = 0):
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

    { Report an exception the host CAUGHT and keeps running after - the
      "report and continue" of a keep-alive except block. Call it inside the
      except block (the raise-point stack is attached to the exception there).
      Handled like any non-fatal report: filter, attachments, dialog or
      background upload. AException is an Exception instance (TObject keeps
      SysUtils out of this interface); anything else is ignored. No-op on
      Windows and before Init. }
    class procedure ReportHandled(const AException: TObject); static;
  end;

implementation

uses
  System.Classes,
  System.SyncObjs,
  System.IOUtils,
  System.Generics.Collections,
  Crash.ELFormat,
  Crash.MacOS.Symbols,
  Crash.Android.Symbols,
  Crash.Linux.Symbols,
  Crash.Breadcrumbs,
  Crash.Pending,
  Crash.RawFallback,
  Crash.RawRecovery,
  Crash.Signals,
  Crash.ThreadCapture,
  System.SysUtils;

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
  Result.ExtendedThreads := False; // standalone library is conservative
  Result.ExtendedThreadsMax := 0;  // <=0 selects the default 32
  Result.FreezeTimeoutMS := 30000;
  Result.RestartOnFreeze := False; // opt in - see the field comment
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

function CrashAcceptInitialConfig(var AInstalled: Boolean;
  var ACurrent: TCrashConfig; const AIncoming: TCrashConfig): Boolean;
begin
  Result := not AInstalled;
  if not Result then
    Exit;
  ACurrent := AIncoming;
  AInstalled := True;
end;

{$IFDEF AUTOTESTS}
function CrashAutoTestAcceptInitialConfig(var AInstalled: Boolean;
  var ACurrent: TCrashConfig; const AIncoming: TCrashConfig): Boolean;
begin
  Result := CrashAcceptInitialConfig(AInstalled, ACurrent, AIncoming);
end;
{$ENDIF}

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
    FRegistry: TCrashThreadRegistry;
    FExtendedCaptureOwned: Boolean;
    FBreadcrumbs: TCrashBreadcrumbStore;
    FOperationLifetime: ICrashOperationLifetime;
    FInstanceID: UInt64;
    FAttachDir: String;              // temp dir of the current report's attachments
    FAttachFiles: TArray<String>;    // non-empty -> the current report is a .elp package
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
    procedure ResetAlreadyReported;
    procedure CollectAttachments(const AReport: TCrashReport);
    procedure CleanupStaleAttachDirs;
    procedure HandleReport(const AReport: TCrashReport);
    procedure DoHandleReport(const AReport: TCrashReport);
    function ExtendedCaptureOperational: Boolean;
    function CaptureExtendedThreads(var AReport: TCrashReport;
      const APrimaryThreadID: UInt64;
      const ABoundedRegistry: Boolean): Integer;
    procedure ExtendFreezeReport(var AReport: TCrashReport);
    procedure InstallFreezeDetector;
    procedure HandleFreezeCapture(const AReport: TCrashReport;
      const AFrozenForMS: Int64);
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
  {$IFDEF AUTOTESTS}
  GAutoTestExtendedCaptureEnabled: Integer;
  GAutoTestExtendedCaptureOwned: Boolean;
  {$ENDIF}

constructor TCrashReporterImpl.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FInstanceID := UInt64(TInterlocked.Increment(GReporterInstanceSeq));
  FRegistry := TCrashThreadRegistry.Create(FInstanceID);
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
  TCrashFreeze.OnExtendCapture := nil;
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
  FreeAndNil(FRegistry);
  if FExtendedCaptureOwned then
  begin
    CrashThreadCaptureRelease;
    FExtendedCaptureOwned := False;
  end;
  FreeAndNil(FLock);
  inherited;
end;

{$IFDEF AUTOTESTS}
function CrashAutoTestSetExtendedCaptureOverride(
  const AEnabled: Boolean): Boolean;
begin
  if AEnabled then
  begin
    if TInterlocked.CompareExchange(
      GAutoTestExtendedCaptureEnabled, 0, 0) <> 0 then
      Exit(GAutoTestExtendedCaptureOwned and CrashThreadCaptureAvailable);
    GAutoTestExtendedCaptureOwned := CrashThreadCaptureAcquire;
    if GAutoTestExtendedCaptureOwned then
      TInterlocked.Exchange(GAutoTestExtendedCaptureEnabled, 1);
    Exit(GAutoTestExtendedCaptureOwned);
  end;

  TInterlocked.Exchange(GAutoTestExtendedCaptureEnabled, 0);
  if GAutoTestExtendedCaptureOwned then
  begin
    CrashThreadCaptureRelease;
    GAutoTestExtendedCaptureOwned := False;
  end;
  Result := True;
end;

function CrashAutoTestSetExtendedThreadsMax(const AValue: Integer;
  out APrevious: Integer): Boolean;
var
  Reporter: TCrashReporterImpl;
begin
  APrevious := 0;
  Reporter := GReporter;
  Result := (Reporter <> nil) and Reporter.FInstalled;
  if not Result then
    Exit;
  Reporter.FLock.Enter;
  try
    APrevious := Reporter.FConfig.ExtendedThreadsMax;
    Reporter.FConfig.ExtendedThreadsMax := AValue;
  finally
    Reporter.FLock.Leave;
  end;
end;

function CrashAutoTestCaptureExtendedThreads(const APrimaryThreadID: UInt64;
  out AThreads: TArray<TCrashThreadStack>; out AOmitted: Integer;
  out ATotalMS, AMaxThreadMS: UInt64): Boolean;
var
  Reporter: TCrashReporterImpl;
  Report: TCrashReport;
  Started: UInt64;
begin
  AThreads := nil;
  AOmitted := 0;
  ATotalMS := 0;
  AMaxThreadMS := 0;
  Reporter := GReporter;
  Result := (Reporter <> nil) and Reporter.FInstalled and
    (TInterlocked.CompareExchange(
      GAutoTestExtendedCaptureEnabled, 0, 0) <> 0) and
    GAutoTestExtendedCaptureOwned;
  if not Result then
    Exit;

  Report := Default(TCrashReport);
  Reporter.FRegistry.AutoTestMaxThreadMS := 0;
  Started := TThread.GetTickCount64;
  AOmitted := Reporter.CaptureExtendedThreads(Report, APrimaryThreadID, False);
  ATotalMS := TThread.GetTickCount64 - Started;
  AMaxThreadMS := Reporter.FRegistry.AutoTestMaxThreadMS;
  AThreads := Report.ExtendedThreads;
end;
{$ENDIF}

function TCrashReporterImpl.ExtendedCaptureOperational: Boolean;
begin
  Result := FConfig.ExtendedThreads and FExtendedCaptureOwned;
  {$IFDEF AUTOTESTS}
  if not Result then
    Result := (TInterlocked.CompareExchange(
      GAutoTestExtendedCaptureEnabled, 0, 0) <> 0) and
      GAutoTestExtendedCaptureOwned;
  {$ENDIF}
  Result := Result and CrashThreadCaptureAvailable;
end;

procedure AppendSignalInfoLine(var ASection: String; const ALine: String);
begin
  if ALine = '' then
    Exit;
  if ASection <> '' then
    ASection := ASection + #13#10;
  ASection := ASection + ALine;
end;

procedure AppendExtendedCaptureDiagnostics(var ASection: String;
  const AReport: TCrashReport);
var
  I: Integer;
begin
  AppendSignalInfoLine(ASection, AReport.PrimaryCaptureDiagnostics);
  for I := 0 to High(AReport.ExtendedThreads) do
    AppendSignalInfoLine(ASection,
      AReport.ExtendedThreads[I].CaptureDiagnostics);
end;

function TCrashReporterImpl.CaptureExtendedThreads(var AReport: TCrashReport;
  const APrimaryThreadID: UInt64;
  const ABoundedRegistry: Boolean): Integer;
begin
  Result := FRegistry.CaptureExtendedThreads(AReport, APrimaryThreadID,
    ABoundedRegistry, FConfig.ExtendedThreadsMax, ExtendedCaptureOperational);
end;

procedure TCrashReporterImpl.ExtendFreezeReport(var AReport: TCrashReport);
begin
  CaptureExtendedThreads(AReport, FMainThreadCoverage.ThreadID, True);
end;

function TCrashReporterImpl.EffectiveFileNamePrefix: String;
begin
  if FConfig.FileNamePrefix <> '' then
    Result := FConfig.FileNamePrefix
  else
    Result := CrashExeBaseName + '_' + CrashPlatformTag + '_';
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
begin
  // An explicit host override always wins.
  if FConfig.ReportDir <> '' then
    Exit(IncludeTrailingPathDelimiter(FConfig.ReportDir));
  Result := CrashDefaultReportDir;
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
    else                          AppLabel := CrashExeBaseName;

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

function TCrashReporterImpl.WriteToFile(const AText: String): Boolean;
begin
  if FCrashFilePath = '' then
    FCrashFilePath := BuildCrashFilePath;
  // Safety net: the file name is stamped per-second (yyyymmddhhnnss), so two
  // distinct reports in the same second (two threads crashing, or a phantom that
  // slipped past the skip above) would collide. The unique-suffix logic in the
  // write core guarantees no real report is ever overwritten by another (the
  // root case - the content-less phantom - is already dropped in HandleReport).
  if Length(FAttachFiles) > 0 then
  begin
    FCrashFilePath := ChangeFileExt(FCrashFilePath, '.elp');
    if CrashWriteReportPackageToUniqueFile(AText, FAttachFiles, FCrashFilePath) then
      Exit(True);
    // A package that cannot be written must not cost the report itself.
    FAttachFiles := nil;
    FCrashFilePath := BuildCrashFilePath;
  end;
  Result := CrashWriteReportTextToUniqueFile(AText, FCrashFilePath);
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
var
  AttachDir: String;
begin
  FLock.Enter;
  try
    FAlreadyReported := False;
    FCrashFilePath := '';
    AttachDir := FAttachDir;
    FAttachDir := '';
    FAttachFiles := nil;
  finally
    FLock.Leave;
  end;
  if AttachDir <> '' then
    try
      TDirectory.Delete(AttachDir, True);
    except
      // A leftover is removed by the next startup scan.
    end;
end;

const
  CRASH_ATTACH_DIR_SUFFIX = '.attach';

procedure TCrashReporterImpl.CollectAttachments(const AReport: TCrashReport);
var
  Dir: String;
  Files, Kept: TArray<String>;
  FilePath: String;
begin
  FAttachDir := '';
  FAttachFiles := nil;
  if not Assigned(FConfig.OnCollectAttachments) then
    Exit;
  if not (AReport.Source in [csHandled, csOnException, csAcquired]) then
    Exit;
  if AReport.IsFreeze then
    Exit;
  Dir := ChangeFileExt(BuildCrashFilePath, '') + '_' +
    ChangeFileExt(TPath.GetRandomFileName, '') + CRASH_ATTACH_DIR_SUFFIX;
  try
    ForceDirectories(Dir);
    FAttachDir := Dir;
    Files := nil;
    FConfig.OnCollectAttachments(AReport, Dir, Files);
    Kept := nil;
    for FilePath in Files do
      if (FilePath <> '') and TFile.Exists(FilePath) then
        Kept := Kept + [FilePath];
    FAttachFiles := Kept;
  except
    // A faulty provider must not break reporting: plain .el.
    FAttachFiles := nil;
  end;
end;

procedure TCrashReporterImpl.CleanupStaleAttachDirs;
var
  Dir, Stale: String;
begin
  Dir := EffectiveReportDir;
  if (Dir = '') or (not TDirectory.Exists(Dir)) then
    Exit;
  try
    for Stale in TDirectory.GetDirectories(Dir,
        EffectiveScanPrefix + '*' + CRASH_ATTACH_DIR_SUFFIX) do
      try
        TDirectory.Delete(Stale, True);
      except
      end;
  except
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
  Report: TCrashReport;
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

  Report := AReport;
  IsFatal := AReport.Source = csFatalProc;
  // Fatal handlers are one-shot. Re-arm before extending both normal and
  // terminating reports so a real concurrent fault remains diagnosable. The
  // current primary snapshot stays reserved by its Claimed CAS; a second fault
  // therefore publishes into the concurrent slot instead of overwriting it.
  if FConfig.ExtendedThreads then
    CrashInstallSignalHandlers;
  CaptureExtendedThreads(Report, CrashCurrentThreadIdentity, False);
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
    Ctx.ThreadName := FRegistry.ThreadName(CrashCurrentThreadIdentity, 'MAIN')
  else
    Ctx.ThreadName := FRegistry.ThreadName(CrashCurrentThreadIdentity, 'Worker');
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
  AppendExtendedCaptureDiagnostics(Ctx.SignalInfoSection, Report);
  if Report.ExtendedThreadsOmitted > 0 then
  begin
    if Ctx.SignalInfoSection <> '' then
      Ctx.SignalInfoSection := Ctx.SignalInfoSection + #13#10;
    Ctx.SignalInfoSection := Ctx.SignalInfoSection + Format(
      'Extended threads omitted by limit: %d',
      [Report.ExtendedThreadsOmitted]);
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
  Text := CrashBuildELReportText(Report, Ctx);

  // The .el file name uses the exception's EL-style BugID as its token (see
  // BuildCrashFilePath). Compute it here, where AReport is in hand, before
  // WriteToFile builds the path.
  FExceptionID := CrashGenerateExceptionID(Report);
  if not IsFatal then
    CollectAttachments(AReport);

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
  // The early re-arm above already restored the one-shot fault handlers before
  // extended capture. Rotate the raw descriptors now: delete the old generation
  // only after full .el persistence; otherwise preserve it for startup recovery
  // and open a fresh generation. The following second re-arm is idempotent and
  // binds the handlers to that fresh raw generation.
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
var
  ImageBase, ImageSize: UInt64;
  RawImageID: TCrashRawImageID;
begin
  // A live runtime is strictly idempotent: a repeated Init never mutates only
  // half of the configuration. Reconfigure is Shutdown + a fresh Init.
  if not CrashAcceptInitialConfig(FInstalled, FConfig, AConfig) then
    Exit;
  FOperationLifetime := CrashNewOperationLifetime;
  FBreadcrumbs := TCrashBreadcrumbStore.Create(FConfig.BreadcrumbCapacity);
  if FConfig.ExtendedThreads then
    FExtendedCaptureOwned := CrashThreadCaptureAcquire;

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

  { Recovery must see the symbol tables before it tries to symbolize a V2 raw
    address. On Android this also gives us the exact ELF build-id used to gate
    ASLR rebasing; elsewhere the call is a no-op. }
  CrashCurrentImage(ImageBase, ImageSize, RawImageID);

  // Convert committed slots from previous processes before opening this
  // process's own preallocated files. Recovered .el files then flow through the
  // ordinary surface/upload scan below.
  RecoverRawFallbackReports;

  // Prepare fixed O_CLOEXEC raw slots before hardware signal handlers are
  // installed by Init. No-op on unsupported targets or when persistence and
  // delivery are both disabled.
  CrashRawPrepare(EffectiveReportDir, EffectiveScanPrefix, FConfig.AppName,
    FConfig.AppVersion, FConfig.CompilationTime, CrashExeBaseName,
    ImageBase, ImageSize, RawImageID,
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
  TCrashFreeze.OnExtendCapture := ExtendFreezeReport;
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
  Ctx.ThreadName := FRegistry.ThreadName(FMainThreadCoverage.ThreadID, 'MAIN');
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
  AppendExtendedCaptureDiagnostics(Ctx.SignalInfoSection, AReport);
  if AReport.ExtendedThreadsOmitted > 0 then
    Ctx.SignalInfoSection := Ctx.SignalInfoSection + #13#10 + Format(
      'Extended threads omitted by limit: %d',
      [AReport.ExtendedThreadsOmitted]);

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
    CrashWriteReportTextToUniqueFile(Text, Path);
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

procedure TCrashReporterImpl.RecoverRawFallbackReports;
var
  Context: TCrashRawRecoveryContext;
begin
  Context := Default(TCrashRawRecoveryContext);
  Context.ReportDir := EffectiveReportDir;
  Context.ScanPrefix := EffectiveScanPrefix;
  Context.AppName := FConfig.AppName;
  Context.CompilationTime := FConfig.CompilationTime;
  Context.DisabledSections := FConfig.DisabledSections;
  Context.AppStartTime := FAppStartTime;
  Context.PathForID := BuildCrashFilePathForID;
  CrashRecoverRawFallbackReports(Context);
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
  CleanupStaleAttachDirs;

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
    Files := TDirectory.GetFiles(Dir, Pattern) +
      TDirectory.GetFiles(Dir, ChangeFileExt(Pattern, '.elp'));
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
        Kept.Add(CrashReadReportText(FilePath));
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
  CrashQueueStartupUploads(FConfig.UploadUrl, FConfig.UploadFieldName,
    StartupUploadFiles);
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
  // Linux: load the .gosym side-file for the routines dladdr cannot name (local
  // symbols of a stripped executable). No-op elsewhere.
  CrashInitLinuxSymbols;
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
  if Reporter.FRegistry.OwnsCurrentThread then
    UnregisterCurrentThread;
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

class function TCrashReporter.RegisterCurrentThread(const AName: String;
  const AGroupID: UInt64): TCrashThreadCoverage;
var
  Reporter: TCrashReporterImpl;
begin
  Result := Default(TCrashThreadCoverage);
  Reporter := GReporter;
  if (Reporter = nil) or (not Reporter.FInstalled) then
    Exit;
  Result := Reporter.FRegistry.RegisterCurrentThread(AName, AGroupID,
    Reporter.ExtendedCaptureOperational);
end;

class procedure TCrashReporter.UnregisterCurrentThread;
var
  Reporter: TCrashReporterImpl;
begin
  Reporter := GReporter;
  if Reporter <> nil then
    TCrashThreadRegistry.UnregisterCurrentThread(Reporter.FRegistry)
  else
    TCrashThreadRegistry.UnregisterCurrentThread(nil);
end;

class function TCrashReporter.GetStatus: TCrashStatus;
var
  Reporter: TCrashReporterImpl;
begin
  Result := Default(TCrashStatus);
  Reporter := GReporter;
  if Reporter = nil then
    Exit;
  Result.Active := Reporter.FInstalled;
  Result.SignalHandlersInstalled := CrashSignalHandlersInstalled;
  Result.FreezeDetectorActive := TCrashFreeze.Active;
  Result.ExtendedThreadsEnabled := Reporter.FConfig.ExtendedThreads;
  Result.ExtendedThreadsAvailable := Reporter.FConfig.ExtendedThreads and
    Reporter.FExtendedCaptureOwned and CrashThreadCaptureAvailable;
  Reporter.FLock.Enter;
  try
    Result.MainThread := Reporter.FMainThreadCoverage;
  finally
    Reporter.FLock.Leave;
  end;
  Reporter.FRegistry.Snapshot(Result.Threads, Result.CurrentThread);
  Result.RegisteredThreadCount := Length(Result.Threads);
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
  Result := CrashUploadReportText(GReporter.FConfig.UploadUrl,
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

class procedure TCrashReporter.ReportHandled(const AException: TObject);
begin
  if (GReporter = nil) or (not GReporter.FInstalled) then
    Exit;
  if AException is Exception then
    TCrashCapture.ReportHandled(Exception(AException));
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
  Result := CrashRestartPlatformSupported;
end;

class function TCrashReporter.Restart(const AHardExit: Boolean): Boolean;
begin
  Result := CrashRestartProcess(AHardExit, CanRestart);
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
