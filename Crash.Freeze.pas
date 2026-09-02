unit Crash.Freeze;

{ Main-thread freeze (hang) detector - the EurekaLog "anti-freeze" analogue
  for POSIX targets.

  Part of the Crash Reporter library - standalone, EurekaLog-compatible
  crash/exception reporting for Delphi cross-platform targets.

  Model:
    - The host pings from the loop of the thread it wants watched (normally
      the main/UI loop): TCrashFreeze.Ping. A watchdog thread compares the
      monotonic time since the last ping against the configured timeout.
      Detection arms only after the FIRST ping, so a long cold start (data
      files, script compilation) can never count as a freeze.
    - On timeout the watchdog asks Crash.ThreadCapture to capture the frozen
      thread's stack IN PLACE. Its process-global signal handler runs ON the
      frozen thread, walks the stack into a pre-allocated per-thread slot and
      publishes it atomically. The watchdog symbolizes the addresses and hands a ready
      TCrashReport (class EFrozenApplication) to OnCapture - wired by
      Crash.Reporter, which formats/writes/uploads the .el on the WATCHDOG
      thread (a healthy thread: no async-signal-safety constraints there).
    - Report-only: the frozen thread is never aborted and no exception is
      injected into it (EurekaLog's Windows-only trick; unreliable on POSIX).
      Replacing the whole process instead is the reporting side's call
      (TCrashConfig.RestartOnFreeze in Crash.Reporter, after the report).
      One report per freeze episode; the detector re-arms when pings resume.
      Episodes are capped per process run to bound report noise.
    - SA_RESTART on the capture signal: the frozen thread usually sits in a
      blocking syscall (futex/read); without it the probe would inject EINTR
      into merely-slow code and create bugs of its own.
    - Suppression: BeginLongOperation/EndLongOperation (nestable) mute
      detection across known-legitimate stalls; SetSuspended (a flag) covers
      the mobile background, where the host cannot ping at all; and
      OnExternalSuppress lets the reporter mute it while an exception
      report/dialog is in flight.

  Scope:
    - Linux x86-64. The capture signal is the FIRST FREE realtime signal in
      rtmin+5..rtmax (a disposition already claimed by the host is never
      stolen; no free signal = the detector stays inactive).
    - macOS x86-64 (Intel) + ARM64 (Apple Silicon): same watchdog; the
      capture signal is SIGUSR2 (no realtime signals on macOS) - if the host
      already owns SIGUSR2, Install refuses and the detector stays inactive.
      The in-handler walk is libSystem backtrace.
    - Android ARM64: same realtime-signal path as Linux (bionic exports the
      same libc probes); the in-handler walk is libunwind, as the exception
      path uses. Note the OS's own ANR machinery only helps with device
      access - this detector is what makes field hangs reportable.
    - Everything else (Windows, iOS, 32-bit ARM) - no-op stubs (Windows is
      EurekaLog territory). }

interface

uses
  System.SysUtils,
  Crash.CallStack;

type
  { What the reporter tells the host after handling one freeze episode.
    Delivered on the WATCHDOG thread - keep handlers cheap and thread-safe. }
  TCrashFreezeInfo = record
    FrozenForMS: Int64;     // no-heartbeat span at capture time
    BugID: String;          // EL-style id of the report (stack-stable)
    ReportFile: String;     // .el path left on disk ('' = not saved, or uploaded-and-removed)
    Uploaded: Boolean;      // True = delivered to the endpoint (local file removed)
    StackCaptured: Boolean; // False = the frozen thread never ran the capture handler
    Restarting: Boolean;    // True = the reporter replaces the process right after this notification (RestartOnFreeze)
  end;

  { Host notification after a freeze report is handled. See TCrashFreezeInfo. }
  TCrashFreezeReportProc = reference to procedure(const AInfo: TCrashFreezeInfo);

  { Hands the captured, symbolized report to the reporting side (wired by
    Crash.Reporter at Init). Runs on the watchdog thread. }
  TCrashFreezeCaptureEvent = reference to procedure(const AReport: TCrashReport;
    const AFrozenForMS: Int64);

  { Extends the already-symbolized primary report while the report gate is still
    held. Crash.Reporter uses it for optional registered-thread capture. }
  TCrashFreezeExtendCaptureEvent = reference to procedure(
    var AReport: TCrashReport);

type
  { Freeze detector facade. All methods are class (static) methods over a
    single process-wide watchdog. Inactive until Install is called. }
  TCrashFreeze = class
  {$REGION 'Internal Declarations'}
  private class var
    FOnCapture: TCrashFreezeCaptureEvent;
    FOnExtendCapture: TCrashFreezeExtendCaptureEvent;
    FOnExternalSuppress: TFunc<Boolean>;
  {$ENDREGION 'Internal Declarations'}
  public
    { Start watching the CALLING thread (call it on the main thread). The
      thread must then call Ping from its loop; detection stays dormant until
      the first ping arrives. Safe to call again - only the timeout updates. }
    class procedure Install(const ATimeoutMS: Integer); static;

    { Stop the watchdog thread (joins it) and give the capture signal back:
      the pre-Install disposition is restored, unless the host re-claimed the
      signal after Install (then its ownership is left alone). }
    class procedure Shutdown; static;

    { Heartbeat. Call from the watched thread's loop; cheap (one atomic
      write), safe at any frequency. No-op until Install. }
    class procedure Ping; static;

    { Mute detection across a known-legitimate stall (nestable). Callable
      from any thread. }
    class procedure BeginLongOperation; static;
    class procedure EndLongOperation; static;

    { Mute detection while the host is not expected to ping at all - the
      mobile background case. Android/iOS freeze a backgrounded process
      (cgroup freezer / suspended runloop): the heartbeat stops but the
      monotonic clock does not, so on return the whole background span would
      read as one long freeze. Unlike BeginLongOperation this is a FLAG, not
      a counter: lifecycle events arrive unpaired or repeated, and a counter
      would leak suppression and silence the detector for good. Clearing it
      also re-stamps the heartbeat, so the watchdog cannot fire on the gap
      between the wake-up and the ping timer's first tick. }
    class procedure SetSuspended(const AValue: Boolean); static;

    { True after a successful Install (False on stub targets). }
    class function Active: Boolean; static;

    { Receives the captured report (watchdog thread). Set by Crash.Reporter. }
    class property OnCapture: TCrashFreezeCaptureEvent read FOnCapture write FOnCapture;

    class property OnExtendCapture: TCrashFreezeExtendCaptureEvent
      read FOnExtendCapture write FOnExtendCapture;

    { Extra suppression probe polled by the watchdog (True = mute detection).
      Crash.Reporter points it at its report-in-flight flag so a crash
      dialog/upload stalling the main loop is not reported as a freeze. }
    class property OnExternalSuppress: TFunc<Boolean> read FOnExternalSuppress write FOnExternalSuppress;
  end;

implementation

{$IF (Defined(LINUX) and Defined(CPUX64)) or
     (Defined(ANDROID) and Defined(CPUARM64)) or
     (Defined(MACOS) and not Defined(IOS) and (Defined(CPUX64) or Defined(CPUARM64)))}
  {$DEFINE CRASH_FREEZECAP}
{$ENDIF}

{$IF Defined(CRASH_FREEZECAP)}

uses
  System.Classes,
  System.SyncObjs,
  System.Math,
  Crash.ThreadCapture;

const
  CAPTURE_WAIT_MS      = 2000; // how long the watchdog waits for the handler to publish
  CHECK_QUANTUM_MS     = 250;  // watchdog poll period (detection latency <= timeout + quantum)
  MIN_TIMEOUT_MS       = 1000;
  MAX_EPISODES_PER_RUN = 5;    // report-noise cap; later episodes are detected but silent

var
  GWatchedCapture: TCrashThreadCaptureHandle = nil;
  GTimeoutMS:     Int64 = 0;
  GLastPingMS:    Int64 = 0;   // TThread.GetTickCount64 (CLOCK_MONOTONIC: excludes system suspend)
  GSuppress:      Integer = 0;
  GSuspended:     Integer = 0; // host-suspended flag (see SetSuspended); separate from the nestable GSuppress
  GInstalled:     Boolean = False;
  GWatchdog:      TThread = nil;

type
  TFreezeWatchdog = class(TThread)
  private
    FEpisodes: Integer;
    function CaptureAndReport(const AFrozenForMS: Int64): Boolean;
  protected
    procedure Execute; override;
  end;

function TFreezeWatchdog.CaptureAndReport(const AFrozenForMS: Int64): Boolean;
// False = the report gate is busy (an exception report is in flight) - the
// caller retries on the next quantum without starting an episode.
var
  Addrs: TArray<UIntPtr>;
  IP: UIntPtr;
  Report: TCrashReport;
  LocList: TCrashStack;
  Trace: TCrashThreadRawTrace;
begin
  // Cross-thread report gate (the exception path's single-flight flag): never
  // race a crashing thread's resolver state (module readers, line caches).
  // Held ONLY across the probe + symbolization: OnCapture formats/writes/
  // uploads an already-symbolized report and needs no resolver - and holding
  // the gate through a network upload (up to 40 s of timeouts) would make a
  // real concurrent crash drop its report entirely.
  Result := TCrashCapture.TryEnterReportGate;
  if not Result then
    Exit;
  try
    Addrs := nil;
    IP := 0;
    if CrashThreadCaptureCapture(GWatchedCapture, CAPTURE_WAIT_MS,
         Trace) = tcoCaptured then
    begin
      Addrs := Trace.Addresses;
      IP := Trace.InterruptedIP;
    end;

    Report := Default(TCrashReport);
    Report.IsFreeze := True;
    Report.ExceptionClassName := 'EFrozenApplication';
    Report.ExceptionMessage := Format(
      'The application seems to be frozen: no heartbeat from the watched (main) thread for %d ms (timeout: %d ms)',
      [AFrozenForMS, GTimeoutMS]);
    Report.Source := csAcquired; // the process stays alive (report-only detector)
    Report.CallStack := TCrashCapture.SymbolizeAddressList(Addrs);
    Report.ExceptionLocation.Clear;
    if IP <> 0 then
    begin
      LocList := TCrashCapture.SymbolizeAddressList([IP]);
      if Length(LocList) > 0 then
        Report.ExceptionLocation := LocList[0];
    end
    else if Length(Report.CallStack) > 0 then
      Report.ExceptionLocation := Report.CallStack[0];
    if Assigned(TCrashFreeze.OnExtendCapture) then
    try
      TCrashFreeze.OnExtendCapture(Report);
    except
      // Extended diagnostics are optional and must not lose the primary freeze.
      Report.ExtendedThreads := nil;
    end;
  finally
    TCrashCapture.LeaveReportGate;
  end;

  if Assigned(TCrashFreeze.OnCapture) then
  try
    TCrashFreeze.OnCapture(Report, AFrozenForMS);
  except
    // The reporting side must not kill the watchdog.
  end;
end;

procedure TFreezeWatchdog.Execute;
var
  Now64, LastPing, LastAlive, GraceMark, EpisodeStart: Int64;
  InEpisode, Suppressed: Boolean;
  ExternalProbe: TFunc<Boolean>;
begin
  NameThreadForDebugging('CrashFreezeWatchdog');
  GraceMark := 0;
  EpisodeStart := 0;
  InEpisode := False;
  while not Terminated do
  begin
    TThread.Sleep(CHECK_QUANTUM_MS);
    if Terminated then
      Break;
    LastPing := TInterlocked.Read(GLastPingMS);
    if LastPing = 0 then
      Continue; // dormant until the first ping (cold start is not a freeze)
    Now64 := Int64(TThread.GetTickCount64);

    Suppressed := (TInterlocked.CompareExchange(GSuppress, 0, 0) > 0) or
                  (TInterlocked.CompareExchange(GSuspended, 0, 0) <> 0);
    if not Suppressed then
    begin
      ExternalProbe := TCrashFreeze.OnExternalSuppress;
      if Assigned(ExternalProbe) then
      try
        Suppressed := ExternalProbe();
      except
        Suppressed := False;
      end;
    end;
    // After a suppressed stretch the watched thread gets a full timeout to
    // ping again before the elapsed time counts as a freeze.
    if Suppressed then
      GraceMark := Now64;

    if InEpisode then
    begin
      // One report per episode: re-arm only when a ping NEWER than the
      // detection moment proves the thread came back.
      if LastPing > EpisodeStart then
        InEpisode := False;
      Continue;
    end;

    LastAlive := Max(LastPing, GraceMark);
    if (Now64 - LastAlive) < GTimeoutMS then
      Continue;

    // Over the noise cap: the episode is still tracked (one per freeze), just
    // no longer reported.
    if FEpisodes >= MAX_EPISODES_PER_RUN then
    begin
      InEpisode := True;
      EpisodeStart := Now64;
      Continue;
    end;
    // Busy report gate (an exception report is in flight) = retry on the next
    // quantum, the freeze is not going anywhere.
    if not CaptureAndReport(Now64 - LastPing) then
      Continue;
    InEpisode := True;
    EpisodeStart := Now64;
    Inc(FEpisodes);
  end;
end;

{ TCrashFreeze }

class procedure TCrashFreeze.Install(const ATimeoutMS: Integer);
begin
  if GInstalled then
  begin
    GTimeoutMS := Max(Int64(MIN_TIMEOUT_MS), Int64(ATimeoutMS));
    Exit;
  end;
  if not CrashThreadCaptureAcquire then
    Exit;
  if not CrashThreadCaptureRegisterCurrentThread(GWatchedCapture) then
  begin
    CrashThreadCaptureRelease;
    Exit;
  end;
  GTimeoutMS := Max(Int64(MIN_TIMEOUT_MS), Int64(ATimeoutMS));
  TInterlocked.Exchange(GLastPingMS, 0);
  try
    GWatchdog := TFreezeWatchdog.Create(False);
  except
    CrashThreadCaptureUnregisterCurrentThread(GWatchedCapture);
    CrashThreadCaptureRelease;
    Exit;
  end;
  GInstalled := True;
end;

class procedure TCrashFreeze.Shutdown;
var
  W: TThread;
begin
  W := GWatchdog;
  GWatchdog := nil;
  GInstalled := False;
  if W <> nil then
  begin
    W.Terminate;
    W.WaitFor; // returns within one CHECK_QUANTUM_MS (plus a pending capture wait)
    W.Free;
  end;
  if GWatchedCapture <> nil then
  begin
    CrashThreadCaptureUnregisterCurrentThread(GWatchedCapture);
    CrashThreadCaptureRelease;
  end;
end;

class procedure TCrashFreeze.Ping;
begin
  if not GInstalled then
    Exit;
  TInterlocked.Exchange(GLastPingMS, Int64(TThread.GetTickCount64));
end;

class procedure TCrashFreeze.BeginLongOperation;
begin
  TInterlocked.Increment(GSuppress);
end;

class procedure TCrashFreeze.EndLongOperation;
begin
  if TInterlocked.Decrement(GSuppress) < 0 then
    TInterlocked.Exchange(GSuppress, 0); // unmatched End: clamp, never go negative
end;

class procedure TCrashFreeze.SetSuspended(const AValue: Boolean);
begin
  if AValue then
    TInterlocked.Exchange(GSuspended, 1)
  else
  begin
    // Re-stamp BEFORE clearing the flag: the watchdog keeps the grace mark
    // fresh only while it sees the flag, and the process may have been frozen
    // solid (watchdog included) right up to this call. Order matters - clearing
    // first would leave a window where a stale heartbeat is fair game.
    // Untouched when still dormant (no ping yet): arming is the host's call.
    if TInterlocked.Read(GLastPingMS) <> 0 then
      TInterlocked.Exchange(GLastPingMS, Int64(TThread.GetTickCount64));
    TInterlocked.Exchange(GSuspended, 0);
  end;
end;

class function TCrashFreeze.Active: Boolean;
begin
  Result := GInstalled;
end;

initialization

finalization
  TCrashFreeze.Shutdown;

{$ELSE}  // not CRASH_FREEZECAP -> no-op stubs

{ TCrashFreeze }

class procedure TCrashFreeze.Install(const ATimeoutMS: Integer);
begin
end;

class procedure TCrashFreeze.Shutdown;
begin
end;

class procedure TCrashFreeze.Ping;
begin
end;

class procedure TCrashFreeze.BeginLongOperation;
begin
end;

class procedure TCrashFreeze.EndLongOperation;
begin
end;

class procedure TCrashFreeze.SetSuspended(const AValue: Boolean);
begin
end;

class function TCrashFreeze.Active: Boolean;
begin
  Result := False;
end;

{$ENDIF}

end.
