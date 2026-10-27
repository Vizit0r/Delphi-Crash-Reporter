unit Crash.Tests.Registry;

{ Registry and runner of the Crash test suite.

  Each test unit registers its body in its initialization section. A body
  returns its log lines (see Crash.Tests.Progress for the line protocol) and a
  Boolean result. The standalone runner (CrashTests.dpr) runs the registry; a
  host application with its own test framework can enumerate it and register
  the same bodies there.

  Part of the Crash Reporter library - standalone, EurekaLog-compatible
  crash/exception reporting for Delphi cross-platform targets.

  Copyright (c) 2026 Vizit0r. BSD 2-Clause license (see LICENSE.txt). }

interface

{$IFDEF AUTOTESTS}

uses
  System.SysUtils,
  System.Generics.Collections;

type
  TCrashTestProc = reference to function(out OutLines: TArray<string>): Boolean;

  TCrashTestKind = (
    ctkInProcess,  // runs inside any host process
    ctkRunnerOnly  // needs the standalone runner (it spawns the runner as a child)
  );

  TCrashTestEntry = record
    Name: String;
    Description: String;
    Tags: TArray<String>;
    Kind: TCrashTestKind;
    Proc: TCrashTestProc;
  end;

  TCrashTestVerdict = (ctvPass, ctvSkip, ctvFail);

procedure CrashRegisterTest(const AName, ADescription: String;
  const ATags: TArray<String>; const AProc: TCrashTestProc;
  const AKind: TCrashTestKind = ctkInProcess);

{ Registered tests in registration order. }
function CrashRegisteredTests: TArray<TCrashTestEntry>;

{ Runs one body. An escaping exception becomes a FAIL line. The verdict is FAIL
  when the body returned False or logged a FAIL line, SKIP when it accounted
  nothing but skips, PASS otherwise. }
function CrashRunTest(const AEntry: TCrashTestEntry;
  out ALines: TArray<string>): TCrashTestVerdict;

const
  CrashTestVerdictText: array[TCrashTestVerdict] of String = ('PASS', 'SKIP', 'FAIL');

{$ENDIF}

implementation

{$IFDEF AUTOTESTS}

var
  GTests: TList<TCrashTestEntry>;

procedure CrashRegisterTest(const AName, ADescription: String;
  const ATags: TArray<String>; const AProc: TCrashTestProc;
  const AKind: TCrashTestKind);
var
  E: TCrashTestEntry;
begin
  if GTests = nil then
    GTests := TList<TCrashTestEntry>.Create;
  E.Name := AName;
  E.Description := ADescription;
  E.Tags := ATags;
  E.Kind := AKind;
  E.Proc := AProc;
  GTests.Add(E);
end;

function CrashRegisteredTests: TArray<TCrashTestEntry>;
begin
  if GTests = nil then
    Result := nil
  else
    Result := GTests.ToArray;
end;

function CrashRunTest(const AEntry: TCrashTestEntry;
  out ALines: TArray<string>): TCrashTestVerdict;
var
  Ok, AnyFail, AnyPass, AnySkip: Boolean;
  L: String;
  Tail: TList<string>;
begin
  ALines := nil;
  try
    Ok := AEntry.Proc(ALines);
  except
    on E: Exception do
    begin
      Tail := TList<string>.Create;
      try
        Tail.AddRange(ALines);
        Tail.Add(Format('FAIL=EXCEPTION %s: %s', [E.ClassName, E.Message]));
        ALines := Tail.ToArray;
      finally
        Tail.Free;
      end;
      Ok := False;
    end;
  end;
  AnyFail := False;
  AnyPass := False;
  AnySkip := False;
  for L in ALines do
    if L.StartsWith('FAIL=') then
      AnyFail := True
    else if L.StartsWith('PASS=') then
      AnyPass := True
    else if L.StartsWith('WARN=SKIP=') then
      AnySkip := True;
  if AnyFail or not Ok then
    Result := ctvFail
  else if AnySkip and not AnyPass then
    Result := ctvSkip
  else
    Result := ctvPass;
end;

initialization

finalization
  FreeAndNil(GTests);

{$ENDIF}

end.
