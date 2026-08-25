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
    - On timeout the watchdog captures the frozen thread's stack IN PLACE:
      pthread_kill with a dedicated realtime signal; the handler runs ON the
      frozen thread, walks the stack with _Unwind_Backtrace into a
      pre-allocated slot (no allocations inside the handler) and publishes it
      atomically. The watchdog symbolizes the addresses and hands a ready
      TCrashReport (class EFrozenApplication) to OnCapture - wired by
      Crash.Reporter, which formats/writes/uploads the .el on the WATCHDOG
      thread (a healthy thread: no async-signal-safety constraints there).
    - Report-only: the frozen thread is never aborted and no exception is
      injected into it (EurekaLog's Windows-only trick; unreliable on POSIX).
      One report per freeze episode; the detector re-arms when pings resume.
      Episodes are capped per process run to bound report noise.
    - SA_RESTART on the capture signal: the frozen thread usually sits in a
      blocking syscall (futex/read); without it the probe would inject EINTR
      into merely-slow code and create bugs of its own.
    - Suppression: BeginLongOperation/EndLongOperation (nestable) mute
      detection across known-legitimate stalls; OnExternalSuppress lets the
      reporter mute it while an exception report/dialog is in flight.

  Scope:
    - Linux x86-64.
    - macOS x86-64 (Intel) + ARM64 (Apple Silicon): same watchdog; the
      capture signal is SIGUSR2 (no realtime signals on macOS) and the
      in-handler walk is libSystem backtrace.
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
  end;

  { Host notification after a freeze report is handled. See TCrashFreezeInfo. }
  TCrashFreezeReportProc = reference to procedure(const AInfo: TCrashFreezeInfo);

  { Hands the captured, symbolized report to the reporting side (wired by
    Crash.Reporter at Init). Runs on the watchdog thread. }
  TCrashFreezeCaptureEvent = reference to procedure(const AReport: TCrashReport;
    const AFrozenForMS: Int64);

type
  { Freeze detector facade. All methods are class (static) methods over a
    single process-wide watchdog. Inactive until Install is called. }
  TCrashFreeze = class
  {$REGION 'Internal Declarations'}
  private class var
    FOnCapture: TCrashFreezeCaptureEvent;
    FOnExternalSuppress: TFunc<Boolean>;
  {$ENDREGION 'Internal Declarations'}
  public
    { Start watching the CALLING thread (call it on the main thread). The
      thread must then call Ping from its loop; detection stays dormant until
      the first ping arrives. Safe to call again - only the timeout updates. }
    class procedure Install(const ATimeoutMS: Integer); static;

    { Stop the watchdog thread (joins it). The signal handler stays installed
      - harmless, nothing sends the signal once the watchdog is gone. }
    class procedure Shutdown; static;

    { Heartbeat. Call from the watched thread's loop; cheap (one atomic
      write), safe at any frequency. No-op until Install. }
    class procedure Ping; static;

    { Mute detection across a known-legitimate stall (nestable). Callable
      from any thread. }
    class procedure BeginLongOperation; static;
    class procedure EndLongOperation; static;

    { True after a successful Install (False on stub targets). }
    class function Active: Boolean; static;

    { Receives the captured report (watchdog thread). Set by Crash.Reporter. }
    class property OnCapture: TCrashFreezeCaptureEvent read FOnCapture write FOnCapture;

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

// bionic shares glibc's realtime-signal probes and sigaction union layout -
// the platform branches below select on this combined symbol (macOS keeps
// its own branches). Mirrors CRASH_LINUXLIKE in Crash.Signals.
{$IF Defined(LINUX) or Defined(ANDROID)}
  {$DEFINE CRASH_FREEZE_LINUXLIKE}
{$ENDIF}

{$IF Defined(CRASH_FREEZECAP)}

uses
  System.Classes,
  System.SyncObjs,
  System.Math,
  Posix.Base,
  Posix.SysTypes, // pthread_t
  Posix.Signal,
  Posix.Pthread,
  Crash.Signals; // CrashContextInstructionPointer

const
  FREEZE_MAX_FRAMES    = 64;   // raw unwind slots (handler/trampoline frames included)
  CAPTURE_WAIT_MS      = 2000; // how long the watchdog waits for the handler to publish
  CHECK_QUANTUM_MS     = 250;  // watchdog poll period (detection latency <= timeout + quantum)
  MIN_TIMEOUT_MS       = 1000;
  MAX_EPISODES_PER_RUN = 5;    // report-noise cap; later episodes are detected but silent

{ In-handler stack walk, per platform - same choices as Crash.CallStack
  (glibc's backtrace() emits garbage IPs for deep stacks, so Linux goes over
  libgcc; Android64 links the NDK libunwind; macOS backtrace is fine).
  Declarations duplicated here because they are implementation-local there
  and this handler needs a NO-ALLOCATION variant writing into a
  pre-allocated slot. }
{$IF Defined(MACOS)}

const
  libSystem = '/usr/lib/libSystem.dylib';

function backtrace(buffer: PPointer; size: Integer): Integer; cdecl;
  external libSystem name 'backtrace';

{$ELSE} // Linux x64 / Android64: _Unwind_Backtrace

type
  _PUnwind_Context = Pointer;
  _Unwind_Ptr = UIntPtr;
  _Unwind_Reason_code = Integer;

const
  _URC_NO_REASON    = 0;
  _URC_END_OF_STACK = 5;
  {$IF Defined(LINUX)}
  LIB_UNWIND = 'libgcc_s.so.1';
  {$ELSE}
  LIB_UNWIND = 'libunwind.a';
  {$ENDIF}

type
  _Unwind_Trace_Fn = function(context: _PUnwind_Context; userdata: Pointer): _Unwind_Reason_code; cdecl;

procedure _Unwind_Backtrace(fn: _Unwind_Trace_Fn; userdata: Pointer); cdecl;
  external LIB_UNWIND name '_Unwind_Backtrace';
function _Unwind_GetIP(context: _PUnwind_Context): _Unwind_Ptr; cdecl;
  external LIB_UNWIND name '_Unwind_GetIP';

{$ENDIF}

{$IF Defined(CRASH_FREEZE_LINUXLIKE)}
{ glibc/bionic reserve the first few kernel RT signals for the runtime; the
  usable range starts at __libc_current_sigrtmin. Raw SIGRTMIN constants
  would collide. }
function __libc_current_sigrtmin: Integer; cdecl;
  external libc name _PU + '__libc_current_sigrtmin';
function __libc_current_sigrtmax: Integer; cdecl;
  external libc name _PU + '__libc_current_sigrtmax';
{$ENDIF}

type
  { Capture slot, pre-allocated. Claimed/Captured follow the same atomic
    claim-fill-publish protocol as Crash.Signals.TSignalSnapshot; the watchdog
    is the sole consumer and re-opens the slot before each probe. }
  TFreezeTrace = record
    Claimed:       Integer; // atomic claim: the handler wins the slot, fills, THEN publishes
    Captured:      Integer; // atomic publish flag: 0=empty, 1=complete (set LAST)
    InterruptedIP: UInt64;  // exact frozen instruction (ucontext RIP)
    Count:         Integer;
    Addrs:         array [0..FREEZE_MAX_FRAMES - 1] of UIntPtr;
  end;

var
  GTrace:         TFreezeTrace;
  GWatchedThread: pthread_t;
  GTimeoutMS:     Int64 = 0;
  GLastPingMS:    Int64 = 0;   // TThread.GetTickCount64 (CLOCK_MONOTONIC: excludes system suspend)
  GSuppress:      Integer = 0;
  GFreezeSignal:  Integer = -1;
  GInstalled:     Boolean = False;
  GWatchdog:      TThread = nil;

{$IF not Defined(MACOS)}
function FreezeUnwindCallback(AContext: _PUnwind_Context; AUserData: Pointer): _Unwind_Reason_code; cdecl;
begin
  if GTrace.Count >= FREEZE_MAX_FRAMES then
    Exit(_URC_END_OF_STACK);
  GTrace.Addrs[GTrace.Count] := UIntPtr(_Unwind_GetIP(AContext));
  Inc(GTrace.Count);
  Result := _URC_NO_REASON;
end;
{$ENDIF}

procedure CrashFreezeSignalHandler(SigNum: Integer; SigInfo: Psiginfo_t;
  Context: Pointer); cdecl;
// Runs ON the frozen thread, on its normal stack. Async-signal-safety: atomic
// flag writes, a ucontext read and a stack walk into a pre-allocated slot -
// no allocations, no formatting. The walk is the same one the exception path
// performs in (post-)signal context on each target; it crosses the kernel
// signal frame via its unwind info, so the trace continues into the
// interrupted (frozen) chain - and if it does not, the watchdog still has
// the exact interrupted IP from the ucontext (see BuildAddressList).
begin
  if TInterlocked.CompareExchange(GTrace.Claimed, 1, 0) <> 0 then
    Exit;
  GTrace.InterruptedIP := CrashContextInstructionPointer(Context);
  {$IF Defined(MACOS)}
  GTrace.Count := backtrace(PPointer(@GTrace.Addrs[0]), FREEZE_MAX_FRAMES);
  if GTrace.Count < 0 then
    GTrace.Count := 0;
  {$ELSE}
  GTrace.Count := 0;
  _Unwind_Backtrace(FreezeUnwindCallback, @GTrace);
  {$ENDIF}
  TInterlocked.Exchange(GTrace.Captured, 1);
end;

type
  TFreezeWatchdog = class(TThread)
  private
    FEpisodes: Integer;
    function BuildAddressList(out AInterruptedIP: UIntPtr): TArray<UIntPtr>;
    procedure CaptureAndReport(const AFrozenForMS: Int64);
  protected
    procedure Execute; override;
  end;

function TFreezeWatchdog.BuildAddressList(out AInterruptedIP: UIntPtr): TArray<UIntPtr>;
// Trim our own capture frames from the published slot. The unwind starts
// inside the signal handler: [handler .. libc trampoline] and then - after
// crossing the signal frame - the frozen chain, whose first entry is exactly
// the interrupted RIP from the ucontext. Keep from that match; if the
// unwinder did not cross the signal frame (no match), prepend the RIP to the
// raw trace so the report at least names the frozen instruction.
var
  I, N, StartIdx: Integer;
begin
  AInterruptedIP := UIntPtr(GTrace.InterruptedIP);
  N := Min(GTrace.Count, FREEZE_MAX_FRAMES);
  StartIdx := -1;
  if AInterruptedIP <> 0 then
    for I := 0 to N - 1 do
      if GTrace.Addrs[I] = AInterruptedIP then
      begin
        StartIdx := I;
        Break;
      end;
  if StartIdx >= 0 then
  begin
    SetLength(Result, N - StartIdx);
    for I := StartIdx to N - 1 do
      Result[I - StartIdx] := GTrace.Addrs[I];
  end
  else if AInterruptedIP <> 0 then
  begin
    SetLength(Result, N + 1);
    Result[0] := AInterruptedIP;
    for I := 0 to N - 1 do
      Result[I + 1] := GTrace.Addrs[I];
  end
  else
  begin
    SetLength(Result, N);
    for I := 0 to N - 1 do
      Result[I] := GTrace.Addrs[I];
  end;
end;

procedure TFreezeWatchdog.CaptureAndReport(const AFrozenForMS: Int64);
var
  Addrs: TArray<UIntPtr>;
  IP: UIntPtr;
  Report: TCrashReport;
  LocList: TCrashStack;
  Deadline: UInt64;
begin
  // Re-open the slot (this thread is the sole consumer).
  TInterlocked.Exchange(GTrace.Captured, 0);
  TInterlocked.Exchange(GTrace.Claimed, 0);
  Addrs := nil;
  IP := 0;
  if pthread_kill(GWatchedThread, GFreezeSignal) = 0 then
  begin
    // Bounded wait: a thread parked in uninterruptible (D) state never runs
    // the handler - report without a stack rather than hang the watchdog.
    Deadline := TThread.GetTickCount64 + CAPTURE_WAIT_MS;
    while (TInterlocked.CompareExchange(GTrace.Captured, 0, 0) <> 1) and
          (TThread.GetTickCount64 < Deadline) do
      TThread.Sleep(5);
    if TInterlocked.CompareExchange(GTrace.Captured, 0, 0) = 1 then
      Addrs := BuildAddressList(IP);
  end;

  Report := Default(TCrashReport);
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

    Suppressed := TInterlocked.CompareExchange(GSuppress, 0, 0) > 0;
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

    // Cross-thread report gate (the exception path's single-flight flag):
    // never race a crashing thread's resolver/formatter state. Busy gate =
    // retry on the next quantum, the freeze is not going anywhere.
    if not TCrashCapture.TryEnterReportGate then
      Continue;
    InEpisode := True;
    EpisodeStart := Now64;
    Inc(FEpisodes);
    try
      if FEpisodes <= MAX_EPISODES_PER_RUN then
        CaptureAndReport(Now64 - LastPing);
    finally
      TCrashCapture.LeaveReportGate;
    end;
  end;
end;

{ TCrashFreeze }

class procedure TCrashFreeze.Install(const ATimeoutMS: Integer);
var
  Act: sigaction_t;
  {$IF Defined(CRASH_FREEZE_LINUXLIKE)}
  RtMin, RtMax: Integer;
  {$ENDIF}
begin
  if GInstalled then
  begin
    GTimeoutMS := Max(Int64(MIN_TIMEOUT_MS), Int64(ATimeoutMS));
    Exit;
  end;
  {$IF Defined(CRASH_FREEZE_LINUXLIKE)}
  RtMin := __libc_current_sigrtmin;
  RtMax := __libc_current_sigrtmax;
  GFreezeSignal := RtMin + 5; // clear of the runtime-reserved range (below RtMin) and of common RT users at RtMin+0..1
  if (RtMin <= 0) or (GFreezeSignal > RtMax) then
    Exit; // no usable realtime signal - the detector stays inactive
  {$ELSE}
  // macOS has no realtime signals; SIGUSR2 is free here (hardware faults go
  // through Mach exception ports, not this signal, and nothing else in the
  // process claims it).
  GFreezeSignal := SIGUSR2;
  {$ENDIF}

  GWatchedThread := pthread_self; // Install runs on the thread to be watched
  GTimeoutMS := Max(Int64(MIN_TIMEOUT_MS), Int64(ATimeoutMS));
  TInterlocked.Exchange(GLastPingMS, 0);
  FillChar(GTrace, SizeOf(GTrace), 0);

  FillChar(Act, SizeOf(Act), 0);
  // The handler union field has different names on Linux-like vs macOS.
  {$IF Defined(CRASH_FREEZE_LINUXLIKE)}
  Act._u.sa_sigaction := CrashFreezeSignalHandler;
  {$ELSE}
  Act.__sigaction_handler.sa_sigaction := CrashFreezeSignalHandler;
  {$ENDIF}
  // SA_RESTART: see the unit header. No SA_ONSTACK: not a stack-overflow
  // scenario, and the process-wide alternate stack belongs to the crash
  // handlers (Crash.Signals).
  Act.sa_flags := SA_SIGINFO or SA_RESTART;
  sigemptyset(Act.sa_mask);
  if sigaction(GFreezeSignal, @Act, nil) <> 0 then
    Exit;

  GWatchdog := TFreezeWatchdog.Create(False);
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

class function TCrashFreeze.Active: Boolean;
begin
  Result := False;
end;

{$ENDIF}

end.
