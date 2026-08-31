unit Crash.Pending;

{ Durable delivery marker helpers for Crash .el reports. }

interface

uses
  System.SysUtils;

const
  CRASH_PENDING_SIGNATURE = 'CRASH_PENDING_V1';
  { Hard cap for reports selected by one startup recovery pass. Files outside
    the returned batch are not opened and their markers stay untouched. }
  CRASH_MAX_STARTUP_UPLOADS = 3;

function CrashPendingMarkerPath(const AReportPath: String): String;
function CrashPendingReportPath(const AMarkerPath: String): String;
function CrashWritePendingMarker(const AReportPath: String): Boolean;
function CrashWriteReportTextToUniqueFile(const AText: String;
  var AReportPath: String): Boolean;
function CrashHasPendingMarker(const AReportPath: String): Boolean;
procedure CrashDeletePendingMarker(const AReportPath: String);
procedure CrashDeleteReportAndPendingMarker(const AReportPath: String);
function CrashShouldUploadPending(const AUploadEnabled, AUploadAll,
  AHasMarker: Boolean): Boolean;
procedure CrashPartitionPendingFiles(const AFiles: TArray<String>;
  const AUploadEnabled, AUploadAll: Boolean;
  out AUploadFiles, ASurfaceFiles: TArray<String>);
function CrashTakeStartupUploadBatch(const AFiles: TArray<String>;
  const AMaxUploads: Integer): TArray<String>;
procedure CrashCleanupOrphanPendingMarkers(const AMarkerFiles: TArray<String>);

implementation

uses
  System.Classes,
  System.Generics.Collections,
  System.IOUtils;

function CrashPendingMarkerPath(const AReportPath: String): String;
begin
  if AReportPath = '' then
    Exit('');
  Result := ChangeFileExt(AReportPath, '.pending');
end;

function CrashPendingReportPath(const AMarkerPath: String): String;
begin
  if AMarkerPath = '' then
    Exit('');
  Result := ChangeFileExt(AMarkerPath, '.el');
end;

function CrashWritePendingMarker(const AReportPath: String): Boolean;
var
  MarkerPath: String;
begin
  Result := False;
  if (AReportPath = '') or (not TFile.Exists(AReportPath)) then
    Exit;
  MarkerPath := CrashPendingMarkerPath(AReportPath);
  try
    TFile.WriteAllText(MarkerPath, CRASH_PENDING_SIGNATURE, TEncoding.UTF8);
    Result := True;
  except
    // The report remains usable even when delivery cannot be armed.
  end;
end;

procedure CrashSelectUniqueReportPath(var AReportPath: String);
var
  Base, Ext, Candidate: String;
  N: Integer;
begin
  if not TFile.Exists(AReportPath) then
    Exit;
  Ext := ExtractFileExt(AReportPath);
  Base := ChangeFileExt(AReportPath, '');
  N := 2;
  repeat
    Candidate := Base + '_' + IntToStr(N) + Ext;
    Inc(N);
  until not TFile.Exists(Candidate);
  AReportPath := Candidate;
end;

function CrashWriteReportTextToUniqueFile(const AText: String;
  var AReportPath: String): Boolean;
var
  Dir, TempPath: String;
begin
  Result := False;
  TempPath := '';
  if AReportPath = '' then
    Exit;
  CrashSelectUniqueReportPath(AReportPath);
  try
    Dir := ExtractFilePath(AReportPath);
    if Dir <> '' then
      ForceDirectories(Dir);
    TempPath := AReportPath + '.tmp.' + TPath.GetRandomFileName;
    TFile.WriteAllText(TempPath, AText, TEncoding.Unicode);
    // Re-check after the write so an ordinary concurrent collision receives a
    // suffix. The final same-directory move publishes only complete UTF-16LE.
    CrashSelectUniqueReportPath(AReportPath);
    TFile.Move(TempPath, AReportPath);
    TempPath := '';
    Result := True;
  except
    AReportPath := '';
  end;
  if TempPath <> '' then
    try TFile.Delete(TempPath); except end;
end;

function CrashHasPendingMarker(const AReportPath: String): Boolean;
var
  MarkerPath, MarkerText: String;
begin
  Result := False;
  MarkerPath := CrashPendingMarkerPath(AReportPath);
  if (MarkerPath = '') or (not TFile.Exists(MarkerPath)) then
    Exit;
  try
    MarkerText := TFile.ReadAllText(MarkerPath, TEncoding.UTF8).Trim;
    Result := (MarkerText = '') or (MarkerText = CRASH_PENDING_SIGNATURE);
  except
    // Unreadable and unknown markers never authorize a network operation.
  end;
end;

procedure CrashDeletePendingMarker(const AReportPath: String);
var
  MarkerPath: String;
begin
  MarkerPath := CrashPendingMarkerPath(AReportPath);
  if MarkerPath = '' then
    Exit;
  try
    if TFile.Exists(MarkerPath) then
      TFile.Delete(MarkerPath);
  except
  end;
end;

procedure CrashDeleteReportAndPendingMarker(const AReportPath: String);
begin
  if AReportPath = '' then
    Exit;
  try
    if TFile.Exists(AReportPath) then
      TFile.Delete(AReportPath);
  except
    Exit; // Keep the marker while the report still exists.
  end;
  CrashDeletePendingMarker(AReportPath);
end;

function CrashShouldUploadPending(const AUploadEnabled, AUploadAll,
  AHasMarker: Boolean): Boolean;
begin
  Result := AUploadEnabled and (AUploadAll or AHasMarker);
end;

procedure CrashPartitionPendingFiles(const AFiles: TArray<String>;
  const AUploadEnabled, AUploadAll: Boolean;
  out AUploadFiles, ASurfaceFiles: TArray<String>);
var
  UploadFiles, SurfaceFiles: TList<String>;
  FilePath: String;
begin
  UploadFiles := TList<String>.Create;
  SurfaceFiles := TList<String>.Create;
  try
    for FilePath in AFiles do
      if CrashShouldUploadPending(AUploadEnabled, AUploadAll,
           CrashHasPendingMarker(FilePath)) then
        UploadFiles.Add(FilePath)
      else
        SurfaceFiles.Add(FilePath);
    AUploadFiles := UploadFiles.ToArray;
    ASurfaceFiles := SurfaceFiles.ToArray;
  finally
    SurfaceFiles.Free;
    UploadFiles.Free;
  end;
end;

function CrashTakeStartupUploadBatch(const AFiles: TArray<String>;
  const AMaxUploads: Integer): TArray<String>;
var
  I, Count: Integer;
begin
  Count := AMaxUploads;
  if Count < 0 then
    Count := 0;
  if Count > Length(AFiles) then
    Count := Length(AFiles);
  SetLength(Result, Count);
  for I := 0 to Count - 1 do
    Result[I] := AFiles[I];
end;

procedure CrashCleanupOrphanPendingMarkers(
  const AMarkerFiles: TArray<String>);
var
  MarkerPath, ReportPath: String;
begin
  for MarkerPath in AMarkerFiles do
  begin
    ReportPath := CrashPendingReportPath(MarkerPath);
    if not TFile.Exists(ReportPath) then
      try TFile.Delete(MarkerPath); except end;
  end;
end;

end.
