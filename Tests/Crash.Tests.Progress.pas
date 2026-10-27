unit Crash.Tests.Progress;

{ Sub-test accounting for one Crash test body.

  A test body logs into a line list and accounts each logical sub-test once:
    Pass(desc)   -> 'PASS=<desc>'         + Inc(Pass)
    Fail(desc)   -> 'FAIL=<desc>'         + Inc(Fail)
    Skip(reason) -> 'WARN=SKIP=<reason>'  + Inc(Skip)
    Info(msg)    -> 'INFO=<msg>'          (no counter change)
    Warn(msg)    -> 'WARN=<msg>'          (no counter change)
  WriteSummary appends 'INFO=<TestName>: PASS=X SKIP=Y FAIL=Z'; AllPassed
  (no failures) is the test result.

  Part of the Crash Reporter library - standalone, EurekaLog-compatible
  crash/exception reporting for Delphi cross-platform targets.

  Copyright (c) 2026 Vizit0r. BSD 2-Clause license (see LICENSE.txt). }

interface

{$IFDEF AUTOTESTS}

uses
  System.SysUtils,
  System.Generics.Collections;

type
  TCrashTestProgress = class
  private
    FLines: TList<string>;
    FPass, FFail, FSkip: Integer;
  public
    constructor Create(const ALines: TList<string>);

    procedure Info(const Msg: string);
    procedure InfoFmt(const Fmt: string; const Args: array of const);
    procedure Warn(const Msg: string);
    procedure WarnFmt(const Fmt: string; const Args: array of const);

    procedure Pass(const Desc: string);
    procedure PassFmt(const Fmt: string; const Args: array of const);
    procedure Fail(const Desc: string);
    procedure FailFmt(const Fmt: string; const Args: array of const);
    procedure Skip(const Reason: string);
    procedure SkipFmt(const Fmt: string; const Args: array of const);

    { Ok=True -> Pass, Ok=False -> Fail, Skipped=True -> Skip (Ok ignored). }
    procedure Account(Ok: Boolean; const Desc: string; Skipped: Boolean = False);

    procedure WriteSummary(const TestName: string);
    function AllPassed: Boolean;

    property Lines: TList<string> read FLines;
    property PassCount: Integer read FPass;
    property FailCount: Integer read FFail;
    property SkipCount: Integer read FSkip;
  end;

{$ENDIF}

implementation

{$IFDEF AUTOTESTS}

constructor TCrashTestProgress.Create(const ALines: TList<string>);
begin
  inherited Create;
  FLines := ALines;
end;

procedure TCrashTestProgress.Info(const Msg: string);
begin
  if Assigned(FLines) then
    FLines.Add('INFO=' + Msg);
end;

procedure TCrashTestProgress.InfoFmt(const Fmt: string; const Args: array of const);
begin
  Info(Format(Fmt, Args));
end;

procedure TCrashTestProgress.Warn(const Msg: string);
begin
  if Assigned(FLines) then
    FLines.Add('WARN=' + Msg);
end;

procedure TCrashTestProgress.WarnFmt(const Fmt: string; const Args: array of const);
begin
  Warn(Format(Fmt, Args));
end;

procedure TCrashTestProgress.Pass(const Desc: string);
begin
  if Assigned(FLines) then
    FLines.Add('PASS=' + Desc);
  Inc(FPass);
end;

procedure TCrashTestProgress.PassFmt(const Fmt: string; const Args: array of const);
begin
  Pass(Format(Fmt, Args));
end;

procedure TCrashTestProgress.Fail(const Desc: string);
begin
  if Assigned(FLines) then
    FLines.Add('FAIL=' + Desc);
  Inc(FFail);
end;

procedure TCrashTestProgress.FailFmt(const Fmt: string; const Args: array of const);
begin
  Fail(Format(Fmt, Args));
end;

procedure TCrashTestProgress.Skip(const Reason: string);
begin
  if Assigned(FLines) then
    FLines.Add('WARN=SKIP=' + Reason);
  Inc(FSkip);
end;

procedure TCrashTestProgress.SkipFmt(const Fmt: string; const Args: array of const);
begin
  Skip(Format(Fmt, Args));
end;

procedure TCrashTestProgress.Account(Ok: Boolean; const Desc: string;
  Skipped: Boolean);
begin
  if Skipped then
    Skip(Desc)
  else if Ok then
    Pass(Desc)
  else
    Fail(Desc);
end;

procedure TCrashTestProgress.WriteSummary(const TestName: string);
begin
  Info(Format('%s: PASS=%d SKIP=%d FAIL=%d', [TestName, FPass, FSkip, FFail]));
end;

function TCrashTestProgress.AllPassed: Boolean;
begin
  Result := FFail = 0;
end;

{$ENDIF}

end.
