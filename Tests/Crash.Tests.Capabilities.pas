unit Crash.Tests.Capabilities;

{ State tests for the opt-in reporter capabilities.

  Copyright (c) 2026 Vizit0r. BSD 2-Clause license (see LICENSE.txt). }

interface

{$IFDEF AUTOTESTS}

uses
  System.SysUtils,
  Crash.Tests.Registry;

type
  TCrashCapabilities_AllInOne = class
  public
    class function AutoTest(out OutLines: TArray<string>): Boolean; static;
  end;

{$ENDIF}

implementation

{$IFDEF AUTOTESTS}

uses
  System.Classes,
  System.Generics.Collections,
  Crash.Breadcrumbs,
  Crash.CallStack,
  Crash.ELFormat,
  Crash.Reporter,
  Crash.Tests.Progress;

const
  TEST_NAME = 'CrashCapabilities';
  CRLF = #13#10;

function FixtureSanitizer(
  const AArguments: TArray<String>): String;
begin
  Result := 'approved' + #13#10 + StringOfChar('x', 5000);
end;

function FailingSanitizer(
  const AArguments: TArray<String>): String;
begin
  raise Exception.Create('fixture sanitizer failure');
end;

function Step_P1_DefaultPrivacyAndExplicitOptIn: Boolean;
var
  Arguments: TArray<String>;
begin
  Arguments := TArray<String>.Create('/safe', '/secret=value', 'positional');
  Result := CrashAutoTestFormatParameters(Arguments, nil, False) = '';
  Result := Result and
    (CrashAutoTestFormatParameters(Arguments, nil, True) =
      '/safe /secret=value positional');
end;

function Step_P2_AllowList: Boolean;
var
  Arguments, AllowList: TArray<String>;
begin
  Arguments := TArray<String>.Create('/safe', '/secret=value',
    '--mode=quiet', 'positional', '-SAFE=second');
  AllowList := TArray<String>.Create('safe', '/mode');
  Result := CrashAutoTestFormatParameters(Arguments, AllowList, False) =
    '/safe --mode=quiet -SAFE=second';
end;

function Step_P3_CallbackPrecedenceAndFailPrivate: Boolean;
var
  Text: String;
begin
  Text := CrashAutoTestFormatParameters(
    TArray<String>.Create('/secret=value'),
    TArray<String>.Create('secret'), True, FixtureSanitizer);
  Result := (Length(Text) = 4096) and
    (Pos(#13, Text) = 0) and (Pos(#10, Text) = 0) and
    (Copy(Text, 1, 11) = 'approved  x');
  Result := Result and
    (CrashAutoTestFormatParameters(TArray<String>.Create('/safe'), nil,
      True, FailingSanitizer) = '');
end;

function Step_B1_BoundedRingOrdering: Boolean;
var
  Store: TCrashBreadcrumbStore;
  Items: TArray<TCrashBreadcrumb>;
begin
  Store := TCrashBreadcrumbStore.Create(2);
  try
    Store.Add('one', 'first');
    Store.Add('two', 'second');
    Store.Add('three', 'third');
    Items := Store.Snapshot;
    Result := (Store.Capacity = 2) and (Length(Items) = 2) and
      (Items[0].Sequence = 2) and (Items[0].Category = 'two') and
      (Items[1].Sequence = 3) and (Items[1].Category = 'three');
  finally
    Store.Free;
  end;
end;

function Step_B2_SanitationTextAndClear: Boolean;
var
  Store: TCrashBreadcrumbStore;
  Items: TArray<TCrashBreadcrumb>;
  Text: String;
begin
  Store := TCrashBreadcrumbStore.Create(CRASH_BREADCRUMB_MAX_CAPACITY + 10);
  try
    Store.Add(StringOfChar('c', 60) + #13#10,
      StringOfChar('m', 300) + #13#10);
    Items := Store.Snapshot;
    Text := Store.SnapshotText;
    Result := (Store.Capacity = CRASH_BREADCRUMB_MAX_CAPACITY) and
      (Length(Items) = 1) and
      (Length(Items[0].Category) = CRASH_BREADCRUMB_CATEGORY_CHARS) and
      (Length(Items[0].MessageText) = CRASH_BREADCRUMB_MESSAGE_CHARS) and
      (Pos(#13, Items[0].Category + Items[0].MessageText) = 0) and
      (Pos(#10, Items[0].Category + Items[0].MessageText) = 0) and
      (Pos('#1 +', Text) = 1) and (Pos(' TID=', Text) > 0);
    Store.Clear;
    Result := Result and (Length(Store.Snapshot) = 0) and
      (Store.SnapshotText = '');
  finally
    Store.Free;
  end;
end;

function Step_N1_TemplateAndStablePrefix: Boolean;
var
  FileName, Prefix: String;
begin
  FileName := CrashAutoTestRenderFileName(
    '{App}_{Platform}_{Version}_{BugID}', 'My/App', '1:2', 'DEADBEEF');
  Prefix := CrashAutoTestTemplateScanPrefix(
    '{App}_{Platform}_{Version}_{BugID}', 'My/App');
  Result := (Prefix <> '') and (Copy(Prefix, 1, 7) = 'My_App_') and
    (Copy(FileName, 1, Length(Prefix)) = Prefix) and
    (Copy(FileName, Length(FileName) - Length('_1_2_DEADBEEF.el') + 1,
      MaxInt) = '_1_2_DEADBEEF.el');
end;

function Step_N2_InvalidTemplatesFailClosed: Boolean;
begin
  Result := CrashAutoTestRenderFileName('{App}_{Unknown}_{BugID}',
    'App', '1', 'AABBCCDD') = '';
  Result := Result and
    (CrashAutoTestRenderFileName('{App}_{Version}', 'App', '1',
      'AABBCCDD') = '');
end;

function Step_L1_InitialConfigIsImmutable: Boolean;
var
  Installed: Boolean;
  Current, First, Second: TCrashConfig;
begin
  Installed := False;
  Current := DefaultCrashConfig;
  First := DefaultCrashConfig;
  First.AppVersion := 'first';
  Second := DefaultCrashConfig;
  Second.AppVersion := 'second';
  Result := CrashAutoTestAcceptInitialConfig(Installed, Current, First) and
    Installed and (Current.AppVersion = 'first');
  Result := Result and
    (not CrashAutoTestAcceptInitialConfig(Installed, Current, Second)) and
    (Current.AppVersion = 'first') and
    (Current.BreadcrumbCapacity = CRASH_BREADCRUMB_DEFAULT_CAPACITY);
end;

function Step_L2_ShutdownLifetimeGate: Boolean;
begin
  Result := CrashAutoTestOperationLifetimeGate;
end;

function Step_E1_BreadcrumbTextReachesEL: Boolean;
var
  Report: TCrashReport;
  Context: TCrashELContext;
  Text: String;
begin
  Report := Default(TCrashReport);
  Report.ExceptionClassName := 'EFixture';
  Report.ExceptionMessage := 'fixture';
  Context := Default(TCrashELContext);
  Context.AppName := 'Fixture';
  Context.StepsToReproduceText := 'first' + CRLF + 'second';
  Text := CrashBuildELReportText(Report, Context);
  Result := (Pos('Steps to reproduce:', Text) > 0) and
    (Pos('  8.1 Text: first' + CRLF + 'second' + CRLF, Text) > 0);
end;

function Step_X1_ExtendedThreadsDefaultsAndNames: Boolean;
var
  Config: TCrashConfig;
  Sanitized: String;
begin
  Config := DefaultCrashConfig;
  Sanitized := CrashAutoTestSanitizeThreadName(
    'Worker;bad|name=' + #9 + #13#10);
  Result := (not Config.ExtendedThreads) and
    (Sanitized = 'Worker.bad name    ') and
    (CrashAutoTestSanitizeThreadName(#9#13#10) = 'Worker') and
    (Length(CrashAutoTestSanitizeThreadName(StringOfChar('x', 200))) = 128);
end;

class function TCrashCapabilities_AllInOne.AutoTest(
  out OutLines: TArray<string>): Boolean;
var
  Lines: TList<string>;
  Progress: TCrashTestProgress;
begin
  Lines := TList<string>.Create;
  try
    Progress := TCrashTestProgress.Create(Lines);
    try
      Progress.Account(Step_P1_DefaultPrivacyAndExplicitOptIn,
        'P1: parameters are private by default and all-arguments is explicit');
      Progress.Account(Step_P2_AllowList,
        'P2: allowlist matches switch names case-insensitively');
      Progress.Account(Step_P3_CallbackPrecedenceAndFailPrivate,
        'P3: sanitizer wins, is bounded/single-line and fails private');
      Progress.Account(Step_B1_BoundedRingOrdering,
        'B1: bounded breadcrumbs evict oldest entries and preserve order');
      Progress.Account(Step_B2_SanitationTextAndClear,
        'B2: breadcrumbs are bounded, single-line, rendered and clearable');
      Progress.Account(Step_N1_TemplateAndStablePrefix,
        'N1: filename template is sanitized and derives a stable scan prefix');
      Progress.Account(Step_N2_InvalidTemplatesFailClosed,
        'N2: invalid filename templates fail closed to the legacy path');
      Progress.Account(Step_L1_InitialConfigIsImmutable,
        'L1: repeated Init cannot silently replace the accepted configuration');
      Progress.Account(Step_L2_ShutdownLifetimeGate,
        'L2: shutdown lifetime gate suppresses work after deactivation');
      Progress.Account(Step_E1_BreadcrumbTextReachesEL,
        'E1: breadcrumb text is emitted in EL Steps to reproduce');
      Progress.Account(Step_X1_ExtendedThreadsDefaultsAndNames,
        'X1: standalone extended capture defaults off and thread names are EL-safe');
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
    'CrashCapabilities',
    'Crash privacy, breadcrumbs, naming and lifecycle contracts',
    ['crash', 'privacy', 'breadcrumbs', 'lifecycle'],
    TCrashCapabilities_AllInOne.AutoTest
  );

{$ENDIF}

end.
