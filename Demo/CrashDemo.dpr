program CrashDemo;

{ Standalone smoke test for the Crash Reporter library.

  Uses ONLY Crash.* units - no Stealth.*, no FMX. Its sole purpose is to prove
  the library is self-contained: if this links and produces a valid .el on a
  bare console target, nothing inside Crash\ secretly depends on the host app.

  Build:  Linux64 (Release) via CrashDemo.dproj.
  Run:    ./CrashDemo --crash=segv|fpe|callbad|callhigh|stackoverflow|raise
          CRASH_NO_UPLOAD=1 keeps the .el on disk and skips any network. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  {$IF Defined(LINUX)}
  Posix.SysMman,
  {$IFEND}
  Crash.Reporter,
  Crash.CallStack;

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

procedure TriggerCrash(const AKind: String);
type
  TProc0 = procedure; cdecl;
var
  P:     PInteger;
  A, B:  Integer;
  HighP: Pointer;
begin
  if AKind = 'segv' then
  begin
    P := nil;
    P^ := 42;                       // null write -> SIGSEGV
  end
  else if AKind = 'fpe' then
  begin
    A := 100; B := 0;
    A := A div B;                   // integer divide by zero
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
    {$IFEND}
  end
  else if AKind = 'stackoverflow' then
    // Stack exhaustion SIGSEGV. The handler itself runs on the alternate signal
    // stack (sigaltstack, registered at Init); whether the RTL conversion that
    // follows can still produce a full .el on the exhausted stack is exactly
    // what this trigger lets you observe.
    Writeln(BurnStack(1))
  else if AKind = 'raise' then
    raise Exception.Create('test raise from CrashDemo')
  else
    Writeln(ErrOutput, 'CrashDemo: unknown crash kind "', AKind,
      '", expected segv|fpe|callbad|callhigh|stackoverflow|raise');
end;

var
  Cfg:  TCrashConfig;
  Kind: String;
  Arg:  String;
  I:    Integer;
begin
  Cfg := DefaultCrashConfig;
  Cfg.AppName         := 'CrashDemo';
  Cfg.AppVersion      := '0.0.0.1';
  Cfg.CompilationTime := FormatDateTime('dd.mm.yyyy hh:nn:ss', Now);
  Cfg.SaveToFile      := True;
  Cfg.UploadEnabled   := False;     // pure local test; never phones home
  TCrashReporter.Init(Cfg);
  TCrashReporter.SurfacePendingToStderr;

  Kind := '';
  for I := 1 to ParamCount do
  begin
    Arg := ParamStr(I);
    if Arg.StartsWith('--crash=') then
      Kind := Copy(Arg, Length('--crash=') + 1, MaxInt)
    else if Arg = '--crash' then
      Kind := 'segv';
  end;

  if Kind = '' then
  begin
    Writeln('CrashDemo - Crash Reporter standalone smoke test.');
    Writeln('Usage: CrashDemo --crash=segv|fpe|callbad|callhigh|stackoverflow|raise');
    Writeln('Reporter Active = ', BoolToStr(TCrashReporter.Active, True));
    Exit;
  end;

  Writeln(ErrOutput, 'CrashDemo: triggering --crash=', Kind, ' ...');
  Flush(ErrOutput);
  TriggerCrash(Kind);
end.
