program CrashDemo;

{ Standalone smoke test for the Crash Reporter library.

  Uses ONLY Crash.* units - no host-app units, no FMX. Its sole purpose is to prove
  the library is self-contained: if this links and produces a valid .el on a
  bare console target, nothing inside Crash\ secretly depends on the host app.

  Build:  Linux64 (Release) via CrashDemo.dproj.
  Run:    ./CrashDemo --crash=segv|fpe|callbad|callhigh|stackoverflow|raise|stale|foreign
          CRASH_NO_UPLOAD=1 keeps the .el on disk and skips any network. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  {$IF Defined(LINUX)}
  Posix.SysMman,
  {$ENDIF}
  Crash.Reporter,
  Crash.CallStack;

var
  { Process start, for the 'fpe' divisor below. }
  GProcessStart: TDateTime;

function BurnStack(N: Integer): Integer;
// Unbounded recursion with a fat frame (4 KB) - exhausts an 8 MB stack in ~2000
// frames. The result feeds back into the caller so nothing gets optimised away.
var
  Pad: array[0..511] of NativeInt;
begin
  Pad[0] := N;
  Pad[High(Pad)] := N + 1;
  Result := BurnStack(N + 1) + Pad[0] + Pad[High(Pad)];
end;

procedure DoNullWrite;
// Kept OUT of SwallowHardwareFault on purpose: Delphi-Linux exception tables are
// call-site based (LLVM/Itanium ABI), so a hardware fault raised at a NON-call
// instruction is not covered by ITS OWN frame's try - it only becomes catchable
// one frame up, at the covered CALL instruction. Faulting inside a callee is
// also what real code does.
var
  P: PInteger;
begin
  P := nil;
  P^ := 42;
end;

procedure SwallowHardwareFault;
// A hardware fault whose Pascal exception is CAUGHT by the app: the crash-lib
// handler has already snapshotted it (and uninstalled itself, one-shot), but no
// report is written - the snapshot stays PENDING. This is the precondition of
// the CDFC1215 mixed-context report: the next reported exception used to
// inherit that snapshot as its own Registers section.
begin
  try
    DoNullWrite;
  except
    on E: Exception do
      Writeln(ErrOutput, 'CrashDemo: swallowed ', E.ClassName,
        ' (snapshot now pending, no report written)');
  end;
end;

procedure TriggerCrash(const AKind: String);
type
  TProc0 = procedure; cdecl;
var
  P:     PInteger;
  A:     Integer;
  {$IF Defined(LINUX)}
  HighP: Pointer;
  {$ENDIF}
  W:     TThread;
begin
  if AKind = 'segv' then
  begin
    P := nil;
    P^ := 42;                       // null write -> SIGSEGV
  end
  else if AKind = 'fpe' then
  begin
    // Divide by a RUNTIME zero: the whole-day part of this process's uptime.
    // It is 0 for a fresh start, yet nothing in the value's provenance lets
    // the compiler prove that - so the division survives into the binary.
    // Even so this yields NO Registers section: Delphi emits an unconditional
    // zero guard (`call System._IntDivByZero` right before the `idiv`, checked
    // in the disassembly), so the RTL raises in software and the CPU never
    // faults. A float divide does reach the CPU, but FP exceptions are masked
    // on the POSIX targets, so it merely yields +Inf. In short: SIGFPE /
    // EXC_ARITHMETIC cannot be provoked from plain Delphi code - the handlers
    // for them only ever fire on faults from foreign code.
    A := 100;
    A := A div Trunc(Now - GProcessStart);
    Writeln(A);
  end
  else if AKind = 'callbad' then
    TProc0(Pointer(NativeUInt($DEAD)))()   // call into unmapped LOW memory (fetch fault, RIP < 0x700000000000)
  else if AKind = 'callhigh' then
  begin
    // Wild jump to a HIGH but MAPPED address. mmap with PROT_READ (no PROT_EXEC)
    // returns a page in the upper mmap region (>= 0x7000_0000_0000 on x86-64
    // Linux) that is readable but NON-executable -> calling into it is an
    // instruction-FETCH fault (si_addr == RIP). Being MAPPED + readable, the RTL
    // unwinder reads it WITHOUT a secondary fault -> a single clean report that
    // mirrors the production wild-jump .el (a jump into a loaded, non-exec library
    // region). Before the FaultAddr==RIP fix this was misclassified "secondary"
    // and its Registers section was dropped; now it must stay primary. (An
    // UNMAPPED high target instead double-faults inside the unwinder and the
    // secondary report overwrites the primary one - a separate scenario.)
    {$IF Defined(LINUX)}
    HighP := mmap(nil, 4096, PROT_READ, MAP_PRIVATE or $20, -1, 0);  // $20 = MAP_ANONYMOUS (Linux)
    if (HighP <> nil) and (HighP <> Pointer(-1)) then
      TProc0(HighP)()
    else
      Writeln(ErrOutput, 'CrashDemo: mmap failed, cannot run callhigh');
    {$ELSE}
    TProc0(Pointer(NativeUInt($7E00DEAD0000)))();
    {$ENDIF}
  end
  else if AKind = 'stackoverflow' then
    // Stack exhaustion SIGSEGV. The handler itself runs on the alternate signal
    // stack (sigaltstack, registered at Init); whether the RTL conversion that
    // follows can still produce a full .el on the exhausted stack is exactly
    // what this trigger lets you observe.
    Writeln(BurnStack(1))
  else if AKind = 'raise' then
    raise Exception.Create('test raise from CrashDemo')
  else if AKind = 'stale' then
  begin
    // Snapshot<->exception correlation, SAME-thread case: the swallowed fault
    // leaves a pending snapshot on this thread, then a soft raise at a DIFFERENT
    // address writes the report. Expect NO "Registers:" section and the "STALE
    // snapshot" note (+ lowercase forensic dump) in Crash Signal Info.
    SwallowHardwareFault;
    raise Exception.Create('soft raise after a swallowed hardware fault (stale-snapshot test)');
  end
  else if AKind = 'foreign' then
  begin
    // Snapshot<->exception correlation, FOREIGN-thread case (the CDFC1215
    // scenario): a worker's hardware fault is swallowed on the worker, then the
    // main thread's raise writes the report. Expect NO "Registers:" section and
    // the "captured on ANOTHER thread" note (+ lowercase dump) in Signal Info.
    W := TThread.CreateAnonymousThread(SwallowHardwareFault);
    W.FreeOnTerminate := False;
    W.Start;
    W.WaitFor;
    W.Free;
    raise Exception.Create('main-thread raise after a worker''s swallowed fault (foreign-snapshot test)');
  end
  else
    Writeln(ErrOutput, 'CrashDemo: unknown crash kind "', AKind,
      '", expected segv|fpe|callbad|callhigh|stackoverflow|raise|stale|foreign');
end;

var
  Cfg:    TCrashConfig;
  Kind:   String;
  Filter: String;
  DoWait: Boolean;
  Arg:    String;
  I:      Integer;
begin
  Kind   := '';
  GProcessStart := Now;
  Filter := '';
  DoWait := False;
  for I := 1 to ParamCount do
  begin
    Arg := ParamStr(I);
    if Arg.StartsWith('--crash=') then
      Kind := Copy(Arg, Length('--crash=') + 1, MaxInt)
    else if Arg = '--crash' then
      Kind := 'segv'
    else if Arg.StartsWith('--filter=') then
      Filter := Copy(Arg, Length('--filter=') + 1, MaxInt)
    else if Arg = '--wait' then
      DoWait := True;
  end;

  Cfg := DefaultCrashConfig;
  Cfg.AppName         := 'CrashDemo';
  Cfg.AppVersion      := '0.0.0.1';
  Cfg.CompilationTime := FormatDateTime('dd.mm.yyyy hh:nn:ss', Now);
  Cfg.SaveToFile      := True;
  Cfg.UploadEnabled   := False;     // pure local test; never phones home

  // Demonstrate the host veto (TCrashConfig.OnFilterReport):
  //   --filter=drop    -> drop every report
  //   --filter=byclass -> drop by exception class (here: the --crash=raise test Exception)
  // A clean Ctrl-C (EControlC) is dropped by the library itself, before the filter -
  // run --wait and press Ctrl-C to see that no report is written.
  if Filter = 'drop' then
    Cfg.OnFilterReport :=
      function(const AReport: TCrashReport): Boolean
      begin
        Result := False;
      end
  else if Filter = 'byclass' then
    Cfg.OnFilterReport :=
      function(const AReport: TCrashReport): Boolean
      begin
        Result := AReport.ExceptionClassName <> 'Exception';
      end;

  TCrashReporter.Init(Cfg);
  TCrashReporter.SurfacePendingToStderr;

  if Kind <> '' then
  begin
    Writeln(ErrOutput, 'CrashDemo: triggering --crash=', Kind, ' ...');
    Flush(ErrOutput);
    TriggerCrash(Kind);
  end
  else if DoWait then
  begin
    Writeln('CrashDemo: waiting - press Ctrl-C; the library drops EControlC, so no report is written ...');
    Flush(Output);
    while True do
      Sleep(200);
  end
  else
  begin
    Writeln('CrashDemo - Crash Reporter standalone smoke test.');
    Writeln('Usage: CrashDemo [--crash=segv|fpe|callbad|callhigh|stackoverflow|raise|stale|foreign]');
    Writeln('                 [--filter=drop|byclass] [--wait]');
    Writeln('Reporter Active = ', BoolToStr(TCrashReporter.Active, True));
  end;
end.
