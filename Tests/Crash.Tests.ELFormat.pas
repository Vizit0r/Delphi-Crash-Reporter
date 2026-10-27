unit Crash.Tests.ELFormat;

// ===========================================================================
//  ELFormat - deterministic golden coverage of the EurekaLog-compatible
//  text layout produced by Crash.ELFormat.
//
//  Copyright (c) 2026 Vizit0r. BSD 2-Clause license (see LICENSE.txt).
// ===========================================================================

interface

{$IFDEF AUTOTESTS}

uses
  System.SysUtils,
  Crash.Tests.Registry;

type
  TELFormat_AllInOne = class
  public
    class function AutoTest(out OutLines: TArray<string>): Boolean; static;
  end;

{$ENDIF}

implementation

{$IFDEF AUTOTESTS}

uses
  System.Classes,
  System.DateUtils,
  System.Generics.Collections,
  System.TimeSpan,
  Crash.CallStack,
  Crash.ELFormat,
  Crash.Tests.Progress;

const
  TEST_NAME = 'ELFormat';
  CRLF = #13#10;
  FIXTURE_MODULES_TEXT =
    'fixture module table top' + #13#10 +
    '|Handle|Name|' + #13#10 +
    'fixture module table middle' + #13#10 +
    '|0000000000400000|CrashFixture.exe|' + #13#10 +
    'fixture module table bottom' + #13#10;

function MakeFrame(const ACodeAddress, ARoutineAddress, AModuleAddress: UIntPtr;
  const ALineNumber, ARoutineLineNumber: Integer; const ARoutineName,
  AModuleName, ASourceFile: String; const ANameTrusted: Boolean): TCrashStackEntry;
begin
  Result.Clear;
  Result.CodeAddress := ACodeAddress;
  Result.RoutineAddress := ARoutineAddress;
  Result.ModuleAddress := AModuleAddress;
  Result.LineNumber := ALineNumber;
  Result.RoutineLineNumber := ARoutineLineNumber;
  Result.RoutineName := ARoutineName;
  Result.ModuleName := AModuleName;
  Result.SourceFile := ASourceFile;
  Result.NameTrusted := ANameTrusted;
end;

function SplitCRLF(const AText: String): TArray<String>;
var
  Lines: TList<String>;
  StartPos, BreakPos: Integer;
begin
  Lines := TList<String>.Create;
  try
    StartPos := 1;
    repeat
      BreakPos := Pos(CRLF, AText, StartPos);
      if BreakPos = 0 then
      begin
        Lines.Add(Copy(AText, StartPos, MaxInt));
        Break;
      end;
      Lines.Add(Copy(AText, StartPos, BreakPos - StartPos));
      StartPos := BreakPos + Length(CRLF);
    until StartPos > Length(AText);
    if (AText <> '') and AText.EndsWith(CRLF) then
      Lines.Add('');
    Result := Lines.ToArray;
  finally
    Lines.Free;
  end;
end;

function ExpectedELDate(const AWhen: TDateTime): String;
const
  DayShort: array[1..7] of String =
    ('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat');
  MonShort: array[1..12] of String =
    ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
     'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec');
var
  Y, M, D, H, N, S, Ms: Word;
  OffsetMinutes: Integer;
  OffsetSign: Char;
begin
  DecodeDate(AWhen, Y, M, D);
  DecodeTime(AWhen, H, N, S, Ms);
  OffsetMinutes := Round(
    TTimeZone.Local.GetUtcOffset(AWhen).TotalMinutes);
  if OffsetMinutes >= 0 then
    OffsetSign := '+'
  else
    OffsetSign := '-';
  OffsetMinutes := Abs(OffsetMinutes);
  Result := Format('%s, %d %s %d %.2d:%.2d:%.2d %s%.2d%.2d',
    [DayShort[DayOfWeek(AWhen)], D, MonShort[M], Y, H, N, S,
     OffsetSign, OffsetMinutes div 60, OffsetMinutes mod 60]);
end;

function ExpectedModulesAnchorGolden(const AStartTime,
  AExceptionTime: TDateTime): TArray<String>;
begin
  Result := [
    'EurekaLog 1.0 00000000000000000000000000000000 00000000000000000000000000000000 0000000000000000000000000000000000000000 00000000000000000000000000000000',
    '',
    'Application:',
    '------------',
    '  1.1 Start Date      : ' + ExpectedELDate(AStartTime),
    '  1.2 Name/Description: CrashFixture.exe',
    '  1.3 Version Number  : 1.2.3.4',
    '  1.4 Parameters      : --fixture --count=2',
    '  1.5 Compilation Date: 2026-08-29 09:30:00',
    '  1.6 Up Time         : 1 hour(s), 2 minute(s), 3 second(s)',
    '',
    'Exception:',
    '----------',
    '  2.1 Date        : ' + ExpectedELDate(AExceptionTime),
    '  2.2 Address     : 0000000000401020',
    'Fixture.Unit | TFixture | RaiseFailure | Line 42[3]',
    '  2.3 Module Name : CrashFixture.exe',
    '  2.4 Module Version: 1.2.3.4',
    '  2.5 Type        : ESyntheticFailure',
    '  2.6 Message     : Synthetic failure',
    '  2.7 ID          : 3A83F8A2',
    '  2.8 Count       : 1',
    '  2.11 Sent       : 0',
    '',
    'User:',
    '-----',
    '  3.2 Name: fixture-user',
    '  3.3 Email: ',
    '',
    'Computer:',
    '---------',
    '  5.1 Name        : fixture-host',
    '  5.9 Display DPI : 144',
    '',
    'Operating System:',
    '-----------------',
    '  6.1 Type                : Fixture OS 1.0',
    '',
    'Steps to reproduce:',
    '-------------------',
    '  8.1 Text: ',
    '',
    'Call Stack Information:',
    '------------------------------------------------------------------------------------------------------------------------------------------------------',
    '|Methods |Details|Stack           |Address         |Module          |Offset          |Source          |Unit        |Class   |Procedure/Method|Line   |',
    '------------------------------------------------------------------------------------------------------------------------------------------------------',
    '|*Exception Thread: ID=321; Parent=0; Priority=0                                                                                                     |',
    '|Class=; Name=Worker                                                                                                                                 |',
    '|DeadLock=0; Wait Chain=                                                                                                                             |',
    '|Comment=                                                                                                                                            |',
    '|----------------------------------------------------------------------------------------------------------------------------------------------------|',
    '|7FFFFFFE|04     |0000000000401020|0000000000401020|CrashFixture.exe|0000000000001020|Fixture.Unit.pas|Fixture.Unit|TFixture|RaiseFailure    |42[3]  |',
    '|7FFF7FFE|04     |0000000000402050|0000000000402050|CrashFixture.exe|0000000000002050|                |            |        |                |0[+$50]|',
    '|----------------------------------------------------------------------------------------------------------------------------------------------------|',
    '------------------------------------------------------------------------------------------------------------------------------------------------------',
    '',
    'Modules Information:',
    '--------------------',
    '',
    'Registers:',
    '----------',
    '  RAX = 0000000000000001',
    '',
    'Crash Signal Info:',
    '------------------',
    '  signal = synthetic',
    '',
    ''
  ];
end;

function ExpectedModulesTextGolden(const AStartTime,
  AExceptionTime: TDateTime): TArray<String>;
var
  Base: TArray<String>;
  Lines: TList<String>;
  I, ModulesIndex: Integer;
begin
  Base := ExpectedModulesAnchorGolden(AStartTime, AExceptionTime);
  ModulesIndex := -1;
  for I := 0 to High(Base) do
    if Base[I] = 'Modules Information:' then
    begin
      ModulesIndex := I;
      Break;
    end;
  Lines := TList<String>.Create;
  try
    for I := 0 to ModulesIndex do
      Lines.Add(Base[I]);
    Lines.Add('fixture module table top');
    Lines.Add('|Handle|Name|');
    Lines.Add('fixture module table middle');
    Lines.Add('|0000000000400000|CrashFixture.exe|');
    Lines.Add('fixture module table bottom');
    Lines.Add('');
    for I := ModulesIndex + 3 to High(Base) do
      Lines.Add(Base[I]);
    Result := Lines.ToArray;
  finally
    Lines.Free;
  end;
end;

function CompareGolden(const AActual, AExpected: TArray<String>;
  const AName: String; const AProgress: TCrashTestProgress): Boolean;
var
  I, CommonCount: Integer;
begin
  Result := False;
  CommonCount := Length(AActual);
  if Length(AExpected) < CommonCount then
    CommonCount := Length(AExpected);
  for I := 0 to CommonCount - 1 do
    if AActual[I] <> AExpected[I] then
    begin
      AProgress.InfoFmt('%s: first mismatch at line %d', [AName, I + 1]);
      AProgress.InfoFmt('expected(%d)=[%s]', [Length(AExpected[I]), AExpected[I]]);
      AProgress.InfoFmt('actual  (%d)=[%s]', [Length(AActual[I]), AActual[I]]);
      Exit;
    end;
  if Length(AActual) <> Length(AExpected) then
  begin
    AProgress.InfoFmt('%s: line count expected=%d actual=%d',
      [AName, Length(AExpected), Length(AActual)]);
    Exit;
  end;
  Result := True;
end;

procedure BuildFixture(out AReport: TCrashReport; out ACtx: TCrashELContext);
begin
  AReport := Default(TCrashReport);
  AReport.ExceptionMessage := 'Synthetic failure';
  AReport.ExceptionClassName := 'ESyntheticFailure';
  AReport.ExceptionLocation := MakeFrame(
    UIntPtr($0000000000401020), UIntPtr($0000000000401000),
    UIntPtr($0000000000400000), 42, 40,
    'Fixture.Unit.TFixture.RaiseFailure', 'CrashFixture.exe',
    'Fixture.Unit.pas', True);
  SetLength(AReport.CallStack, 2);
  AReport.CallStack[0] := AReport.ExceptionLocation;
  AReport.CallStack[1] := MakeFrame(
    UIntPtr($0000000000402050), UIntPtr($0000000000402000),
    UIntPtr($0000000000400000), 0, 0,
    '', 'CrashFixture.exe', '', False);
  AReport.Source := csAcquired;

  ACtx := Default(TCrashELContext);
  ACtx.AppName := 'CrashFixture.exe';
  ACtx.AppVersion := '1.2.3.4';
  ACtx.AppParameters := '--fixture --count=2';
  ACtx.StartTime := EncodeDateTime(2026, 8, 29, 10, 0, 0, 0);
  ACtx.CompileTime := '2026-08-29 09:30:00';
  ACtx.ExceptionTime := EncodeDateTime(2026, 8, 29, 11, 2, 3, 0);
  ACtx.CpuSnapshot :=
    'Registers:' + CRLF +
    '----------' + CRLF +
    '  RAX = 0000000000000001' + CRLF;
  ACtx.SignalInfoSection :=
    'Crash Signal Info:' + CRLF +
    '------------------' + CRLF +
    '  signal = synthetic' + CRLF;
  ACtx.UserName := 'fixture-user';
  ACtx.ComputerName := 'fixture-host';
  ACtx.OSDescription := 'Fixture OS 1.0';
  ACtx.AppDpi := 144;
  ACtx.ThreadID := 321;
  ACtx.ThreadName := 'Worker';
end;

function Step_G1_ModulesAnchor(const AProgress: TCrashTestProgress): Boolean;
var
  Report: TCrashReport;
  Ctx: TCrashELContext;
  Actual, Expected: TArray<String>;
begin
  BuildFixture(Report, Ctx);
  Ctx.DisabledSections := [crsModules];

  Actual := SplitCRLF(CrashBuildELReportText(Report, Ctx));
  Expected := ExpectedModulesAnchorGolden(Ctx.StartTime, Ctx.ExceptionTime);
  Result := CompareGolden(Actual, Expected, 'G1', AProgress);
end;

function Step_G2_ModulesText(const AProgress: TCrashTestProgress): Boolean;
var
  Report: TCrashReport;
  Ctx: TCrashELContext;
  Actual, Expected: TArray<String>;
begin
  BuildFixture(Report, Ctx);
  Ctx.ModulesText := FIXTURE_MODULES_TEXT;
  Actual := SplitCRLF(CrashBuildELReportText(Report, Ctx));
  Expected := ExpectedModulesTextGolden(Ctx.StartTime, Ctx.ExceptionTime);
  Result := CompareGolden(Actual, Expected, 'G2', AProgress);
end;

function Step_G3_DisabledCollection: Boolean;
var
  Ctx: TCrashELContext;
begin
  Ctx := Default(TCrashELContext);
  Ctx.ModulesText := 'must be cleared';
  Ctx.DisabledSections := [crsModules];
  CrashCollectELModules(Ctx);
  Result := Ctx.ModulesText = '';
end;

function ContainsLine(const ALines: TArray<String>; const ALine: String): Boolean;
var
  Line: String;
begin
  for Line in ALines do
    if Line = ALine then
      Exit(True);
  Result := False;
end;

function ContainsLinePrefix(const ALines: TArray<String>;
  const APrefix: String): Boolean;
var
  Line: String;
begin
  for Line in ALines do
    if Line.StartsWith(APrefix) then
      Exit(True);
  Result := False;
end;

function LineIndex(const ALines: TArray<String>; const ALine: String): Integer;
var
  I: Integer;
begin
  for I := 0 to High(ALines) do
    if ALines[I] = ALine then
      Exit(I);
  Result := -1;
end;

function LinePrefixIndexFrom(const ALines: TArray<String>;
  const APrefix: String; const AStart: Integer): Integer;
var
  I: Integer;
begin
  for I := AStart to High(ALines) do
    if ALines[I].StartsWith(APrefix) then
      Exit(I);
  Result := -1;
end;

function Step_G4_AllOptionalDisabled: Boolean;
var
  Report: TCrashReport;
  Ctx: TCrashELContext;
  Lines: TArray<String>;
begin
  BuildFixture(Report, Ctx);
  Ctx.DisabledSections := AllOptionalCrashReportSections;
  Lines := SplitCRLF(CrashBuildELReportText(Report, Ctx));
  Result :=
    ContainsLine(Lines, 'Application:') and
    ContainsLine(Lines, 'Exception:') and
    ContainsLine(Lines, 'Call Stack Information:') and
    (not ContainsLine(Lines, 'User:')) and
    (not ContainsLine(Lines, 'Computer:')) and
    (not ContainsLine(Lines, 'Operating System:')) and
    (not ContainsLine(Lines, 'Steps to reproduce:')) and
    (not ContainsLine(Lines, 'Modules Information:')) and
    (not ContainsLine(Lines, 'Registers:')) and
    (not ContainsLine(Lines, 'Crash Signal Info:'));
end;

function Step_G5_DisabledModulesIgnoreText(const AProgress: TCrashTestProgress): Boolean;
var
  Report: TCrashReport;
  Ctx: TCrashELContext;
  Actual, Expected: TArray<String>;
begin
  BuildFixture(Report, Ctx);
  Ctx.DisabledSections := [crsModules];
  Ctx.ModulesText := FIXTURE_MODULES_TEXT;
  Actual := SplitCRLF(CrashBuildELReportText(Report, Ctx));
  Expected := ExpectedModulesAnchorGolden(Ctx.StartTime, Ctx.ExceptionTime);
  Result := CompareGolden(Actual, Expected, 'G5', AProgress);
end;

function Step_G6_NoRegistersNoAnchor: Boolean;
var
  Report: TCrashReport;
  Ctx: TCrashELContext;
  Lines: TArray<String>;
begin
  BuildFixture(Report, Ctx);
  Ctx.DisabledSections := [crsModules, crsRegisters];
  Lines := SplitCRLF(CrashBuildELReportText(Report, Ctx));
  Result := (not ContainsLine(Lines, 'Modules Information:')) and
            (not ContainsLine(Lines, 'Registers:')) and
            ContainsLine(Lines, 'Crash Signal Info:');
end;

function Step_G7_MainFreezePlacement: Boolean;
var
  Report: TCrashReport;
  Ctx: TCrashELContext;
  Lines: TArray<String>;
  CallStackPos, FreezePos: Integer;
begin
  BuildFixture(Report, Ctx);
  Report.IsFreeze := True;
  Report.ExceptionMessage := 'Application freeze';
  Report.ExceptionClassName := 'EApplicationFreeze';
  Ctx.ThreadName := 'MAIN';
  Ctx.DisabledSections := [crsModules, crsRegisters];
  Ctx.SignalInfoSection :=
    'Freeze Info:' + CRLF +
    '-------------' + CRLF +
    '  frozen for 5000 ms' + CRLF;
  Lines := SplitCRLF(CrashBuildELReportText(Report, Ctx));
  CallStackPos := LineIndex(Lines, 'Call Stack Information:');
  FreezePos := LineIndex(Lines, 'Freeze Info:');
  Result := ContainsLinePrefix(Lines, '|Class=; Name=MAIN') and
            (CallStackPos >= 0) and (FreezePos > CallStackPos);
end;

function Step_G8_CRLFOnly: Boolean;
var
  Report: TCrashReport;
  Ctx: TCrashELContext;
  Text: String;
  I: Integer;
begin
  BuildFixture(Report, Ctx);
  Ctx.DisabledSections := [crsModules];
  Text := CrashBuildELReportText(Report, Ctx);
  Result := True;
  for I := 1 to Length(Text) do
    if ((Text[I] = #10) and ((I = 1) or (Text[I - 1] <> #13))) or
       ((Text[I] = #13) and ((I = Length(Text)) or (Text[I + 1] <> #10))) then
      Exit(False);
end;

function Step_G9_Deterministic: Boolean;
var
  Report: TCrashReport;
  Ctx: TCrashELContext;
  FirstText, SecondText: String;
begin
  BuildFixture(Report, Ctx);
  Ctx.ModulesText := FIXTURE_MODULES_TEXT;
  FirstText := CrashBuildELReportText(Report, Ctx);
  SecondText := CrashBuildELReportText(Report, Ctx);
  Result := FirstText = SecondText;
end;

function Step_G10_DateFormatAndOffset: Boolean;
var
  Report: TCrashReport;
  Ctx: TCrashELContext;
  Lines: TArray<String>;
begin
  BuildFixture(Report, Ctx);
  Ctx.DisabledSections := [crsModules];
  Lines := SplitCRLF(CrashBuildELReportText(Report, Ctx));
  Result :=
    ContainsLine(Lines, '  1.1 Start Date      : ' +
      ExpectedELDate(Ctx.StartTime)) and
    ContainsLine(Lines, '  2.1 Date        : ' +
      ExpectedELDate(Ctx.ExceptionTime));
end;

function Step_G11_ExtendedThreadGolden(
  const AProgress: TCrashTestProgress): Boolean;
const
  ExpectedComments: array[1..5] of String = (
    'Extended capture timed out',
    'Thread exited during extended capture',
    'Extended capture signal unavailable',
    'Extended capture budget exceeded',
    'Extended capture failed');
var
  Report: TCrashReport;
  Ctx: TCrashELContext;
  Lines: TArray<String>;
  I, SearchFrom, BlockPos, CallPos, TableEnd, RowWidth: Integer;
  BlankRow, Separator: String;
begin
  BuildFixture(Report, Ctx);
  Ctx.DisabledSections := [crsModules, crsRegisters];
  Report.PrimaryGroupID := UInt64($2A);
  SetLength(Report.ExtendedThreads, 6);
  for I := 0 to High(Report.ExtendedThreads) do
  begin
    // Internal pthread_t stays full-width, while EL display follows the same
    // Cardinal truncation as the primary Exception Thread line.
    Report.ExtendedThreads[I].ThreadID :=
      UInt64(High(Cardinal)) + 1 + UInt64(900 + I);
    Report.ExtendedThreads[I].Name := 'Worker.' + IntToStr(I);
    Report.ExtendedThreads[I].GroupID := UInt64($100 + I);
  end;
  Report.ExtendedThreads[0].State := ctcsCaptured;
  Report.ExtendedThreads[0].CallStack := [MakeFrame(
    UIntPtr($0000000000501010), UIntPtr($0000000000501000),
    UIntPtr($0000000000500000), 77, 70,
    'Other.Unit.TWorker.Tick', 'ExtendedFixtureModule.so',
    'Other.Unit.pas', True)];
  Report.ExtendedThreads[1].State := ctcsTimedOut;
  Report.ExtendedThreads[2].State := ctcsThreadGone;
  Report.ExtendedThreads[3].State := ctcsSignalUnavailable;
  Report.ExtendedThreads[4].State := ctcsBudgetExceeded;
  Report.ExtendedThreads[5].State := ctcsCaptureFailed;

  Lines := SplitCRLF(CrashBuildELReportText(Report, Ctx));
  CallPos := LineIndex(Lines, 'Call Stack Information:');
  Result := CallPos >= 0;
  if not Result then
    Exit;
  RowWidth := Length(Lines[CallPos + 1]);
  BlankRow := '|' + StringOfChar(' ', RowWidth - 2) + '|';
  Separator := '|' + StringOfChar('-', RowWidth - 2) + '|';
  SearchFrom := CallPos;
  for I := 0 to High(Report.ExtendedThreads) do
  begin
    BlockPos := LinePrefixIndexFrom(Lines,
      '|Running Thread: ID=' + UIntToStr(900 + I) + ';', SearchFrom);
    Result := Result and (BlockPos > SearchFrom) and
      (Lines[BlockPos - 1] = BlankRow) and
      (Lines[BlockPos - 2] = Separator);
    if BlockPos < 0 then
      Break;
    SearchFrom := BlockPos + 1;
  end;
  Result := Result and
    ContainsLinePrefix(Lines, '|Class=; Name=Worker.0') and
    ContainsLinePrefix(Lines,
      '|Comment=Group=000000000000002A') and
    ContainsLinePrefix(Lines,
      '|Comment=Group=0000000000000100') and
    ContainsLinePrefix(Lines, '|Comment=' + ExpectedComments[1] +
      '; Group=0000000000000101') and
    ContainsLinePrefix(Lines, '|Comment=' + ExpectedComments[2] +
      '; Group=0000000000000102') and
    ContainsLinePrefix(Lines, '|Comment=' + ExpectedComments[3] +
      '; Group=0000000000000103') and
    ContainsLinePrefix(Lines, '|Comment=' + ExpectedComments[4] +
      '; Group=0000000000000104') and
    ContainsLinePrefix(Lines, '|Comment=' + ExpectedComments[5] +
      '; Group=0000000000000105') and
    ContainsLinePrefix(Lines, '|7FFFFFFE|04') and
    (Pos('Tick', CrashBuildELReportText(Report, Ctx)) > 0);

  TableEnd := -1;
  for I := SearchFrom to High(Lines) do
    if Lines[I] = StringOfChar('-', RowWidth) then
    begin
      TableEnd := I;
      Break;
    end;
  Result := Result and (TableEnd > SearchFrom);
  if TableEnd > 0 then
    for I := CallPos + 2 to TableEnd - 1 do
      if Lines[I].StartsWith('|') and (Length(Lines[I]) <> RowWidth) then
        Result := False;
  if not Result then
    AProgress.Info('G11: extended call-stack block structure or shared width mismatch');
end;

function Step_G11a_PrimaryGroupCommentWidth: Boolean;
var
  Report: TCrashReport;
  Ctx: TCrashELContext;
  Lines: TArray<String>;
  CallPos, CommentPos, RowWidth: Integer;
begin
  BuildFixture(Report, Ctx);
  Ctx.DisabledSections := [crsModules, crsRegisters];
  Report.PrimaryGroupID := UInt64($2A);
  Report.ExtendedThreads := nil;
  Lines := SplitCRLF(CrashBuildELReportText(Report, Ctx));
  CallPos := LineIndex(Lines, 'Call Stack Information:');
  CommentPos := -1;
  if CallPos >= 0 then
    CommentPos := LinePrefixIndexFrom(Lines,
      '|Comment=Group=000000000000002A', CallPos);
  Result := (CallPos >= 0) and (CommentPos > CallPos);
  if not Result then
    Exit;
  RowWidth := Length(Lines[CallPos + 1]);
  Result := (Length(Lines[CommentPos]) = RowWidth) and
    Lines[CommentPos].StartsWith(
      '|Comment=Group=000000000000002A');
end;

function Step_G12_ExtendedThreadsDoNotAffectBugID: Boolean;
var
  Report: TCrashReport;
  Ctx: TCrashELContext;
  BaseID: String;
begin
  BuildFixture(Report, Ctx);
  BaseID := CrashGenerateExceptionID(Report);
  Report.PrimaryGroupID := UInt64($2A);
  SetLength(Report.ExtendedThreads, 1);
  Report.ExtendedThreads[0].ThreadID := 999;
  Report.ExtendedThreads[0].Name := 'Different.Worker';
  Report.ExtendedThreads[0].GroupID := UInt64($100);
  Report.ExtendedThreads[0].State := ctcsCaptured;
  Report.ExtendedThreads[0].CallStack := [MakeFrame(
    UIntPtr($70001010), UIntPtr($70001000), UIntPtr($70000000), 1, 1,
    'Foreign.TWorker.OtherPath', 'foreign.so', 'Foreign.pas', True)];
  Result := CrashGenerateExceptionID(Report) = BaseID;
end;

class function TELFormat_AllInOne.AutoTest(
  out OutLines: TArray<string>): Boolean;
var
  Lines: TList<string>;
  Progress: TCrashTestProgress;
begin
  Lines := TList<string>.Create;
  try
    Progress := TCrashTestProgress.Create(Lines);
    try
      Progress.Account(Step_G1_ModulesAnchor(Progress),
        'G1: Registers with disabled Modules keep the empty positional anchor');
      Progress.Account(Step_G2_ModulesText(Progress),
        'G2: supplied ModulesText is emitted without reading process state');
      Progress.Account(Step_G3_DisabledCollection,
        'G3: disabled Modules are not retained by context collection');
      Progress.Account(Step_G4_AllOptionalDisabled,
        'G4: AllOptionalCrashReportSections keeps only mandatory sections');
      Progress.Account(Step_G5_DisabledModulesIgnoreText(Progress),
        'G5: disabled Modules ignore stale text but preserve the CPU anchor');
      Progress.Account(Step_G6_NoRegistersNoAnchor,
        'G6: no Registers means no empty Modules positional anchor');
      Progress.Account(Step_G7_MainFreezePlacement,
        'G7: MAIN freeze metadata follows the call-stack block');
      Progress.Account(Step_G8_CRLFOnly,
        'G8: formatter emits CRLF without bare CR or LF');
      Progress.Account(Step_G9_Deterministic,
        'G9: identical report and context produce identical text');
      Progress.Account(Step_G10_DateFormatAndOffset,
        'G10: fixed dates include independently computed local UTC offset');
      Progress.Account(Step_G11_ExtendedThreadGolden(Progress),
        'G11: extended thread blocks keep EL separators, comments, order and shared widths');
      Progress.Account(Step_G11a_PrimaryGroupCommentWidth,
        'G11a: primary Group comment is emitted and fits the shared frame width');
      Progress.Account(Step_G12_ExtendedThreadsDoNotAffectBugID,
        'G12: primary/running GroupID and extended stacks do not change BugID');
      Progress.WriteSummary(TEST_NAME);
      Result := Progress.AllPassed;
    finally
      Progress.Free;
    end;
    OutLines := Lines.ToArray;
  finally
    Lines.Free;
  end;
end;

initialization
  CrashRegisterTest(
    'ELFormat',
    'Crash .el formatter golden layout',
    ['crash', 'el', 'format', 'golden'],
    TELFormat_AllInOne.AutoTest
  );

{$ENDIF}

end.
