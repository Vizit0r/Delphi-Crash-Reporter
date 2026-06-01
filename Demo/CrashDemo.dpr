program CrashDemo;

{ Standalone smoke test for the Crash Reporter library.

  Uses ONLY Crash.* units - no Stealth.*, no FMX. Its sole purpose is to prove
  the library is self-contained: if this links and produces a valid .el on a
  bare console target, nothing inside Crash\ secretly depends on the host app.

  Build:  Linux64 (Release) via CrashDemo.dproj.
  Run:    ./CrashDemo --crash=segv|fpe|callbad|raise
          CRASH_NO_UPLOAD=1 keeps the .el on disk and skips any network. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Crash.Reporter,
  Crash.CallStack;

procedure TriggerCrash(const AKind: String);
type
  TProc0 = procedure; cdecl;
var
  P:    PInteger;
  A, B: Integer;
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
    TProc0(Pointer(NativeUInt($DEAD)))()   // call into unmapped memory
  else if AKind = 'raise' then
    raise Exception.Create('test raise from CrashDemo')
  else
    Writeln(ErrOutput, 'CrashDemo: unknown crash kind "', AKind,
      '", expected segv|fpe|callbad|raise');
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
    Writeln('Usage: CrashDemo --crash=segv|fpe|callbad|raise');
    Writeln('Reporter Active = ', BoolToStr(TCrashReporter.Active, True));
    Exit;
  end;

  Writeln(ErrOutput, 'CrashDemo: triggering --crash=', Kind, ' ...');
  Flush(ErrOutput);
  TriggerCrash(Kind);
end.
