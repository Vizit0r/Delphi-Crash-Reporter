unit Crash.Tests.HandledReport;

// ===========================================================================
//  CrashHandledReport - the report built for a CAUGHT exception
//  (TCrashCapture.ReportHandled) carries only defined values.
//
//    H1  On a stack left dirty by an earlier call, the report has Source =
//        csHandled, the live exception object, IsFreeze = False,
//        PrimaryGroupID = 0 and ExtendedThreadsOmitted = 0. A garbage
//        IsFreeze skipped the attachments and switched the BugID to the
//        freeze normalization.
//
//  The capture hook (TCrashCapture.OnReport) is swapped for the duration of
//  the step and restored afterwards. Windows has no capture singleton - SKIP.
//
//  Copyright (c) 2026 Vizit0r. BSD 2-Clause license (see LICENSE.txt).
// ===========================================================================

interface

{$IFDEF AUTOTESTS}

uses
  System.SysUtils;

type
  TCrashHandledReport_AllInOne = class
  public
    class function AutoTest(out OutLines: TArray<string>): Boolean; static;
  end;

{$ENDIF}

implementation

{$IFDEF AUTOTESTS}

uses
  System.Generics.Collections,
  Crash.CallStack,
  Crash.Tests.Registry,
  Crash.Tests.Progress;

const
  TEST_NAME = 'CrashHandledReport';

type
  ECrashHandledReportTest = class(Exception);

  TCapturedReport = record
    Got: Boolean;
    Source: TCrashSource;
    ExceptionObject: TObject;
    IsFreeze: Boolean;
    PrimaryGroupID: UInt64;
    ExtendedThreadsOmitted: Integer;
  end;

var
  GCaptured: TCapturedReport;

function DirtyStack: Integer;
// Fills a large frame with $FF so the frames called right after it start on
// non-zero memory.
var
  Pad: array[0..16383] of Byte;
begin
  FillChar(Pad, SizeOf(Pad), $FF);
  Result := Pad[Length(ParamStr(0)) mod Length(Pad)];
end;

function RaiseAndReportHandled: TObject;
begin
  try
    raise ECrashHandledReportTest.Create('handled report fixture');
  except
    on E: Exception do
    begin
      Result := E;
      TCrashCapture.ReportHandled(E);
    end;
  end;
end;

function Step_H1_DefinedFields(const AProgress: TCrashTestProgress): Boolean;
var
  Saved: TCrashReportEvent;
  Raised: TObject;
begin
  Result := False;
  GCaptured := Default(TCapturedReport);
  Saved := TCrashCapture.OnReport;
  TCrashCapture.OnReport :=
    procedure(const AReport: TCrashReport)
    begin
      GCaptured.Got := True;
      GCaptured.Source := AReport.Source;
      GCaptured.ExceptionObject := AReport.ExceptionObject;
      GCaptured.IsFreeze := AReport.IsFreeze;
      GCaptured.PrimaryGroupID := AReport.PrimaryGroupID;
      GCaptured.ExtendedThreadsOmitted := AReport.ExtendedThreadsOmitted;
    end;
  try
    if DirtyStack = 0 then
      AProgress.Info('H1: stack fill read back zero');
    Raised := RaiseAndReportHandled;
  finally
    TCrashCapture.OnReport := Saved;
  end;
  if not GCaptured.Got then
  begin
    AProgress.Fail('H1: ReportHandled produced no report');
    Exit;
  end;
  if (GCaptured.Source <> csHandled) or (GCaptured.ExceptionObject <> Raised) then
  begin
    AProgress.FailFmt('H1: source %d, exception object matches: %s',
      [Ord(GCaptured.Source),
       BoolToStr(GCaptured.ExceptionObject = Raised, True)]);
    Exit;
  end;
  if GCaptured.IsFreeze or (GCaptured.PrimaryGroupID <> 0) or
     (GCaptured.ExtendedThreadsOmitted <> 0) then
  begin
    AProgress.FailFmt('H1: undefined fields: IsFreeze=%s PrimaryGroupID=%u ExtendedThreadsOmitted=%d',
      [BoolToStr(GCaptured.IsFreeze, True), GCaptured.PrimaryGroupID,
       GCaptured.ExtendedThreadsOmitted]);
    Exit;
  end;
  Result := True;
end;

class function TCrashHandledReport_AllInOne.AutoTest(
  out OutLines: TArray<string>): Boolean;
var
  Lines: TList<string>;
  Progress: TCrashTestProgress;
begin
  Lines := TList<string>.Create;
  Progress := TCrashTestProgress.Create(Lines);
  try
    {$IFDEF MSWINDOWS}
    Progress.Skip('no capture singleton on Windows');
    {$ELSE}
    Progress.Account(Step_H1_DefinedFields(Progress),
      'H1: a handled report carries only defined values on a dirty stack');
    {$ENDIF}
    Progress.WriteSummary(TEST_NAME);
    Result := Progress.AllPassed;
    OutLines := Lines.ToArray;
  finally
    Progress.Free;
    Lines.Free;
  end;
end;

initialization
  CrashRegisterTest(
    'CrashHandledReport',
    'A report for a caught exception carries only defined values',
    ['crash', 'handled'],
    TCrashHandledReport_AllInOne.AutoTest
  );

{$ENDIF}

end.
