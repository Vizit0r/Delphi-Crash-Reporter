unit Crash.ReportNaming;

{ Names and identity fields of a report: the executable base name and
  platform tag, the filtered Application/1.4 parameter line, report file-name
  templates and the platform default report directory. Pure functions over
  their arguments.

  Copyright (c) 2026 Vizit0r. BSD 2-Clause license (see LICENSE.txt). }

interface

type
  { Optional privacy hook. Receives ParamStr(1..N) as separate values and
    returns the exact single-line text allowed into Application/1.4. An
    exception fails private and emits an empty field. }
  TCrashSanitizeParametersProc = reference to function(
    const AArguments: TArray<String>): String;

function CrashExeBaseName: String;
// WIN / LINUX / MACOS / ANDROID / IOS.
function CrashPlatformTag: String;

{ Application/1.4 text: the sanitizer wins; otherwise switches named in
  AAllowList ("name", "/name" or "--name"; /name=value keeps the value);
  otherwise every argument when AIncludeAll. Single line, bounded. }
function CrashFormatParameters(const AArguments,
  AAllowList: TArray<String>; const AIncludeAll: Boolean;
  const ASanitizer: TCrashSanitizeParametersProc = nil): String;

function CrashSanitizeFileName(const AValue: String): String;
{ Renders a file-name template with the App, Platform, Version and BugID
  tokens in braces. '' when the template lacks BugID or leaves a brace. }
function CrashRenderFileNameTemplate(const ATemplate, AApp, AVersion,
  ABugID: String): String;
{ The stable part of a template (before Version / BugID) usable as the
  boot-scan prefix; '' when there is none. }
function CrashTemplateScanPrefix(const ATemplate, AApp: String): String;

{ Platform default report directory, with a trailing delimiter: the app's
  private documents dir on Android/iOS, the directory next to the .app bundle
  on macOS, the executable's own directory elsewhere. }
function CrashDefaultReportDir: String;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.Generics.Collections;

const
  CRASH_APP_PARAMETERS_MAX_CHARS = 4096;

function CrashExeBaseName: String;
begin
  Result := ChangeFileExt(ExtractFileName(ParamStr(0)), '');
end;

function CrashPlatformTag: String;
begin
  {$IF Defined(MSWINDOWS)}  Result := 'WIN';
  {$ELSEIF Defined(ANDROID)}Result := 'ANDROID';
  {$ELSEIF Defined(IOS)}    Result := 'IOS';
  {$ELSEIF Defined(MACOS)}  Result := 'MACOS';
  {$ELSEIF Defined(LINUX)}  Result := 'LINUX';
  {$ELSE}                   Result := 'UNKNOWN';
  {$ENDIF}
end;

function CrashSingleLineBounded(const AText: String;
  const AMaxChars: Integer): String;
begin
  Result := StringReplace(AText, #13, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #10, ' ', [rfReplaceAll]);
  if Length(Result) > AMaxChars then
    SetLength(Result, AMaxChars);
end;

function CrashArgumentSwitchName(const AArgument: String;
  const ARequirePrefix: Boolean): String;
var
  P: Integer;
begin
  Result := Trim(AArgument);
  if Result = '' then
    Exit;
  if ARequirePrefix and not CharInSet(Result[1], ['/', '-']) then
    Exit('');
  while (Result <> '') and CharInSet(Result[1], ['/', '-']) do
    Delete(Result, 1, 1);
  P := Pos('=', Result);
  if P > 0 then
    SetLength(Result, P - 1);
  Result := LowerCase(Trim(Result));
end;

function CrashFormatParameters(const AArguments,
  AAllowList: TArray<String>; const AIncludeAll: Boolean;
  const ASanitizer: TCrashSanitizeParametersProc): String;
var
  Allowed, ArgName: String;
  Argument: String;
  Selected: TList<String>;
begin
  Result := '';
  if Assigned(ASanitizer) then
  begin
    try
      Result := ASanitizer(AArguments);
    except
      Result := '';
    end;
    Exit(CrashSingleLineBounded(Result, CRASH_APP_PARAMETERS_MAX_CHARS));
  end;
  if Length(AAllowList) > 0 then
  begin
    Selected := TList<String>.Create;
    try
      for Argument in AArguments do
      begin
        ArgName := CrashArgumentSwitchName(Argument, True);
        if ArgName = '' then
          Continue;
        for Allowed in AAllowList do
          if ArgName = CrashArgumentSwitchName(Allowed, False) then
          begin
            Selected.Add(Argument);
            Break;
          end;
      end;
      Result := String.Join(' ', Selected.ToArray);
    finally
      Selected.Free;
    end;
  end
  else if AIncludeAll then
    Result := String.Join(' ', AArguments);
  Result := CrashSingleLineBounded(Result, CRASH_APP_PARAMETERS_MAX_CHARS);
end;

function CrashSanitizeFileName(const AValue: String): String;
var
  C: Char;
  I: Integer;
begin
  Result := Trim(AValue);
  for I := 1 to Length(Result) do
  begin
    C := Result[I];
    if (Ord(C) < 32) or CharInSet(C, ['<', '>', ':', '"', '/', '\', '|', '?', '*']) then
      Result[I] := '_';
  end;
end;

function CrashRenderFileNameTemplate(const ATemplate, AApp, AVersion,
  ABugID: String): String;
var
  AppValue: String;
begin
  Result := '';
  if (ATemplate = '') or
     (Pos('{bugid}', LowerCase(ATemplate)) = 0) then
    Exit;
  AppValue := AApp;
  if AppValue = '' then
    AppValue := CrashExeBaseName;
  Result := StringReplace(ATemplate, '{App}',
    CrashSanitizeFileName(AppValue), [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, '{Platform}', CrashPlatformTag,
    [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, '{Version}',
    CrashSanitizeFileName(AVersion), [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, '{BugID}',
    CrashSanitizeFileName(ABugID), [rfReplaceAll, rfIgnoreCase]);
  if (Pos('{', Result) > 0) or (Pos('}', Result) > 0) then
    Exit('');
  Result := CrashSanitizeFileName(Result);
  if Result = '' then
    Exit;
  if not SameText(ExtractFileExt(Result), '.el') then
    Result := Result + '.el';
end;

function CrashTemplateScanPrefix(const ATemplate, AApp: String): String;
var
  AppValue, LowerTemplate, PrefixTemplate: String;
  BugPos, CutPos, VersionPos: Integer;
begin
  Result := '';
  LowerTemplate := LowerCase(ATemplate);
  BugPos := Pos('{bugid}', LowerTemplate);
  if BugPos = 0 then
    Exit;
  VersionPos := Pos('{version}', LowerTemplate);
  CutPos := BugPos;
  if (VersionPos > 0) and (VersionPos < CutPos) then
    CutPos := VersionPos;
  PrefixTemplate := Copy(ATemplate, 1, CutPos - 1);
  AppValue := AApp;
  if AppValue = '' then
    AppValue := CrashExeBaseName;
  Result := StringReplace(PrefixTemplate, '{App}',
    CrashSanitizeFileName(AppValue), [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, '{Platform}', CrashPlatformTag,
    [rfReplaceAll, rfIgnoreCase]);
  if (Pos('{', Result) > 0) or (Pos('}', Result) > 0) then
    Exit('');
  Result := CrashSanitizeFileName(Result);
end;

function CrashDefaultReportDir: String;
var
  ExeDir: String;
  {$IF Defined(MACOS)}
  ExePath, MacOSDir, ContentsDir, AppDir: String;
  {$ENDIF}
begin
  {$IF Defined(ANDROID) or Defined(IOS)}
  // Sandboxed mobile: the "exe" lives inside the read-only app package
  // (Android nativeLibraryDir / the iOS bundle), so ParamStr(0)'s directory is
  // not writable. Use the app's private documents dir - always writable, needs
  // no storage permission - which is exactly what a crash reporter wants
  // (it must succeed even when the process is already failing).
  ExeDir := TPath.GetDocumentsPath;
  {$ELSEIF Defined(MACOS)}
  // macOS: if we're inside a .app bundle (.../<X>.app/Contents/MacOS/<exe>),
  // write reports NEXT TO the bundle, never inside it - writing into a bundle
  // breaks code signing, fails on read-only install locations, and is invisible
  // to users (Show Package Contents only). ExpandFileName resolves a relative
  // argv[0] (e.g. ./X launched from inside MacOS/) so the detection still works.
  ExePath     := ExpandFileName(ParamStr(0));
  MacOSDir    := ExcludeTrailingPathDelimiter(ExtractFilePath(ExePath));
  ContentsDir := ExcludeTrailingPathDelimiter(ExtractFilePath(MacOSDir));
  AppDir      := ExcludeTrailingPathDelimiter(ExtractFilePath(ContentsDir));
  if SameText(ExtractFileName(MacOSDir), 'MacOS') and
     SameText(ExtractFileName(ContentsDir), 'Contents') and
     SameText(ExtractFileExt(AppDir), '.app') then
    Exit(IncludeTrailingPathDelimiter(ExtractFilePath(AppDir)));
  ExeDir := ExtractFilePath(ExePath);
  {$ELSE}
  // Linux / Windows: the executable's own directory.
  ExeDir := ExtractFilePath(ParamStr(0));
  {$ENDIF}

  if ExeDir = '' then
    ExeDir := TPath.GetTempPath;
  Result := IncludeTrailingPathDelimiter(ExeDir);
end;

end.
