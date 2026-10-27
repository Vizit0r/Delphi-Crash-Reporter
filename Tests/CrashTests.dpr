program CrashTests;

{ Standalone console runner of the Crash test suite.

  Usage:
    CrashTests                     run every registered test
    CrashTests --test=<Name> ...   run the named tests (repeatable)
    CrashTests --list              list the registered tests
    CrashTests --summary-only      print only summary and FAIL lines

  Output: '--- <Name> : RUN', the test's lines (INFO= / PASS= / FAIL= /
  WARN=SKIP=), '--- <Name> : PASS|SKIP|FAIL', and a final
  '=== SUMMARY: PASS=x SKIP=y FAIL=z (of n)'.
  Exit code: 0 - nothing failed, 1 - a test failed, 2 - bad command line.

  The reporter is initialized the way a host typically would (extended thread
  capture on, freeze detection report-only, no upload). Tests run on the main
  thread, and nothing pings the host freeze detector: TCrashFreeze.Ping is
  process-wide, so a pinging loop would hide the blocks the freeze test makes.

  Part of the Crash Reporter library - standalone, EurekaLog-compatible
  crash/exception reporting for Delphi cross-platform targets.

  Copyright (c) 2026 Vizit0r. BSD 2-Clause license (see LICENSE.txt). }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.RegularExpressions,
  System.Generics.Collections,
  Crash.CallStack,
  Crash.Reporter,
  Crash.Tests.Registry,
  Crash.Tests.Progress,
  Crash.Tests.GolCodec,
  Crash.Tests.ELFormat,
  Crash.Tests.Pending,
  Crash.Tests.Capabilities,
  Crash.Tests.RawFallback,
  Crash.Tests.HandledFault,
  Crash.Tests.ExtendedThreads,
  Crash.Tests.Freeze,
  Crash.Tests.ChildProcess;

procedure RunTests(const ATests: TArray<TCrashTestEntry>; ASummaryOnly: Boolean;
  out APass, ASkip, AFail: Integer);
var
  E: TCrashTestEntry;
  Lines: TArray<string>;
  L: String;
  Verdict: TCrashTestVerdict;
  SummaryLine: TRegEx;
begin
  APass := 0;
  ASkip := 0;
  AFail := 0;
  SummaryLine := TRegEx.Create('^INFO=[^=]+: PASS=\d+ SKIP=\d+ FAIL=\d+$');
  for E in ATests do
  begin
    Writeln('--- ', E.Name, ' : RUN');
    Flush(Output);
    Verdict := CrashRunTest(E, Lines);
    for L in Lines do
      if (not ASummaryOnly) or L.StartsWith('FAIL=') or SummaryLine.IsMatch(L) then
        Writeln(L);
    Writeln('--- ', E.Name, ' : ', CrashTestVerdictText[Verdict]);
    Flush(Output);
    case Verdict of
      ctvPass: Inc(APass);
      ctvSkip: Inc(ASkip);
      ctvFail: Inc(AFail);
    end;
  end;
end;

procedure InitReporter;
var
  Cfg: TCrashConfig;
begin
  Cfg := DefaultCrashConfig;
  Cfg.AppName := 'CrashTests';
  Cfg.AppVersion := '0.0.0.0';
  Cfg.UploadEnabled := False;
  Cfg.DisabledSections := [crsModules];
  Cfg.ExtendedThreads := True;
  Cfg.FreezeDetection := True;
  Cfg.FreezeTimeoutMS := 30000;
  Cfg.RestartOnFreeze := False;
  TCrashReporter.Init(Cfg);
end;

function SelectTests(out ATests: TArray<TCrashTestEntry>;
  out AList, ASummaryOnly: Boolean): Boolean;
var
  I: Integer;
  Arg, Name: String;
  Names: TList<String>;
  E: TCrashTestEntry;
  Found: Boolean;
  Picked: TList<TCrashTestEntry>;
begin
  Result := True;
  AList := False;
  ASummaryOnly := False;
  Names := TList<String>.Create;
  Picked := TList<TCrashTestEntry>.Create;
  try
    for I := 1 to ParamCount do
    begin
      Arg := ParamStr(I);
      if Arg.StartsWith('--test=') then
        Names.Add(Copy(Arg, Length('--test=') + 1, MaxInt))
      else if Arg = '--list' then
        AList := True
      else if Arg = '--summary-only' then
        ASummaryOnly := True
      else
      begin
        Writeln(ErrOutput, 'unknown argument: ', Arg);
        Result := False;
      end;
    end;
    if Names.Count = 0 then
      Picked.AddRange(CrashRegisteredTests)
    else
      for Name in Names do
      begin
        Found := False;
        for E in CrashRegisteredTests do
          if SameText(E.Name, Name) then
          begin
            Picked.Add(E);
            Found := True;
          end;
        if not Found then
        begin
          Writeln(ErrOutput, 'NOT FOUND: ', Name);
          Result := False;
        end;
      end;
    ATests := Picked.ToArray;
  finally
    Picked.Free;
    Names.Free;
  end;
end;

var
  Tests: TArray<TCrashTestEntry>;
  ListOnly, SummaryOnly: Boolean;
  E: TCrashTestEntry;
  PassCount, SkipCount, FailCount: Integer;
begin
  if CrashTestRunChildIfRequested then
    Exit;
  if not SelectTests(Tests, ListOnly, SummaryOnly) then
  begin
    ExitCode := 2;
    Exit;
  end;
  if ListOnly then
  begin
    for E in CrashRegisteredTests do
      Writeln(E.Name, '  - ', E.Description);
    Exit;
  end;

  InitReporter;
  CrashTestChildExe := ParamStr(0);

  RunTests(Tests, SummaryOnly, PassCount, SkipCount, FailCount);
  Writeln(Format('=== SUMMARY: PASS=%d SKIP=%d FAIL=%d (of %d)',
    [PassCount, SkipCount, FailCount, Length(Tests)]));
  if FailCount > 0 then
    ExitCode := 1;
end.
