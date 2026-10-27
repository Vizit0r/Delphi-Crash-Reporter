unit Crash.Tests.Pending;

// Pure state tests for Crash.Pending marker and selection contracts.
//
// Copyright (c) 2026 Vizit0r. BSD 2-Clause license (see LICENSE.txt).

interface

{$IFDEF AUTOTESTS}

uses
  System.SysUtils,
  Crash.Tests.Registry;

type
  TCrashPending_AllInOne = class
  public
    class function AutoTest(out OutLines: TArray<string>): Boolean; static;
  end;

{$ENDIF}

implementation

{$IFDEF AUTOTESTS}

uses
  System.Classes,
  System.Generics.Collections,
  System.IOUtils,
  System.SyncObjs,
  Crash.Pending,
  Crash.Reporter,
  Crash.Tests.Progress;

const
  TEST_NAME = 'CrashPending';

function NewFixtureDir: String;
begin
  Result := TPath.Combine(TPath.GetTempPath,
    'CrashTestsPending_' + TPath.GetRandomFileName);
  ForceDirectories(Result);
end;

function Step_P1_PathMapping: Boolean;
var
  ReportPath, MarkerPath: String;
begin
  ReportPath := TPath.Combine('fixture', 'Crash_WIN_DEADBEEF.el');
  MarkerPath := CrashPendingMarkerPath(ReportPath);
  Result := MarkerPath = TPath.Combine('fixture', 'Crash_WIN_DEADBEEF.pending');
  Result := Result and (CrashPendingReportPath(MarkerPath) = ReportPath);
end;

function Step_P2_CreateValidateDelete: Boolean;
var
  Dir, ReportPath, MarkerPath: String;
begin
  Dir := NewFixtureDir;
  try
    ReportPath := TPath.Combine(Dir, 'Crash_WIN_12345678.el');
    MarkerPath := CrashPendingMarkerPath(ReportPath);
    TFile.WriteAllText(ReportPath, 'fixture report', TEncoding.Unicode);
    Result := CrashWritePendingMarker(ReportPath) and
      TFile.Exists(MarkerPath) and CrashHasPendingMarker(ReportPath);
    CrashDeleteReportAndPendingMarker(ReportPath);
    Result := Result and (not TFile.Exists(ReportPath)) and
      (not TFile.Exists(MarkerPath));
  finally
    if TDirectory.Exists(Dir) then
      TDirectory.Delete(Dir, True);
  end;
end;

function Step_P3_FailClosedMarkers: Boolean;
var
  Dir, ReportPath, MarkerPath: String;
begin
  Dir := NewFixtureDir;
  try
    ReportPath := TPath.Combine(Dir, 'Crash_WIN_87654321.el');
    MarkerPath := CrashPendingMarkerPath(ReportPath);
    Result := not CrashWritePendingMarker(ReportPath);
    TFile.WriteAllText(ReportPath, 'fixture report', TEncoding.Unicode);
    TFile.WriteAllText(MarkerPath, 'UNKNOWN_MARKER', TEncoding.UTF8);
    Result := Result and (not CrashHasPendingMarker(ReportPath));
    TFile.WriteAllText(MarkerPath, '', TEncoding.UTF8);
    Result := Result and CrashHasPendingMarker(ReportPath);
  finally
    if TDirectory.Exists(Dir) then
      TDirectory.Delete(Dir, True);
  end;
end;

function Step_P4_MixedPartition: Boolean;
begin
  Result :=
    CrashShouldUploadPending(True, False, True) and
    (not CrashShouldUploadPending(True, False, False)) and
    CrashShouldUploadPending(True, True, True) and
    CrashShouldUploadPending(True, True, False) and
    (not CrashShouldUploadPending(False, True, True));
end;

function ContainsPath(const APaths: TArray<String>; const APath: String): Boolean;
var
  Path: String;
begin
  for Path in APaths do
    if Path = APath then
      Exit(True);
  Result := False;
end;

function Step_P5_FilePartitionAndOrphanCleanup: Boolean;
var
  Dir, MarkedReport, UnmarkedReport, OrphanMarker: String;
  Files, UploadFiles, SurfaceFiles, Markers: TArray<String>;
begin
  Dir := NewFixtureDir;
  try
    MarkedReport := TPath.Combine(Dir, 'Crash_WIN_MARKED.el');
    UnmarkedReport := TPath.Combine(Dir, 'Crash_WIN_UNMARKED.el');
    OrphanMarker := TPath.Combine(Dir, 'Crash_WIN_ORPHAN.pending');
    TFile.WriteAllText(MarkedReport, 'marked', TEncoding.Unicode);
    TFile.WriteAllText(UnmarkedReport, 'unmarked', TEncoding.Unicode);
    CrashWritePendingMarker(MarkedReport);
    TFile.WriteAllText(OrphanMarker, CRASH_PENDING_SIGNATURE, TEncoding.UTF8);
    Files := [MarkedReport, UnmarkedReport];
    CrashPartitionPendingFiles(Files, True, False, UploadFiles, SurfaceFiles);
    Result := (Length(UploadFiles) = 1) and
      ContainsPath(UploadFiles, MarkedReport) and
      (Length(SurfaceFiles) = 1) and
      ContainsPath(SurfaceFiles, UnmarkedReport);
    Markers := [CrashPendingMarkerPath(MarkedReport), OrphanMarker];
    CrashCleanupOrphanPendingMarkers(Markers);
    Result := Result and TFile.Exists(CrashPendingMarkerPath(MarkedReport)) and
      (not TFile.Exists(OrphanMarker));
  finally
    if TDirectory.Exists(Dir) then
      TDirectory.Delete(Dir, True);
  end;
end;

function WaitUntilMissing(const APath1, APath2: String;
  const ATimeoutMS: Cardinal): Boolean;
var
  Deadline: UInt64;
begin
  Deadline := TThread.GetTickCount64 + ATimeoutMS;
  repeat
    if (not TFile.Exists(APath1)) and (not TFile.Exists(APath2)) then
      Exit(True);
    Sleep(10);
  until TThread.GetTickCount64 >= Deadline;
  Result := (not TFile.Exists(APath1)) and (not TFile.Exists(APath2));
end;

function Step_P6_AsyncSuccessFailure: Boolean;
var
  Dir, ReportPath, MarkerPath: String;
  TransportDone: TEvent;
begin
  Dir := NewFixtureDir;
  TransportDone := TEvent.Create(nil, True, False, '');
  try
    ReportPath := TPath.Combine(Dir, 'Crash_WIN_ASYNC_OK.el');
    MarkerPath := CrashPendingMarkerPath(ReportPath);
    TFile.WriteAllText(ReportPath, 'success report', TEncoding.Unicode);
    CrashWritePendingMarker(ReportPath);
    Result := CrashAutoTestQueueUpload('success report', ReportPath,
      function(const AUrl, AFieldName, AText, AFileName: String): Boolean
      begin
        TransportDone.SetEvent;
        Result := True;
      end);
    Result := Result and (TransportDone.WaitFor(2000) = wrSignaled) and
      WaitUntilMissing(ReportPath, MarkerPath, 2000);

    TransportDone.ResetEvent;
    ReportPath := TPath.Combine(Dir, 'Crash_WIN_ASYNC_FAIL.el');
    MarkerPath := CrashPendingMarkerPath(ReportPath);
    TFile.WriteAllText(ReportPath, 'failure report', TEncoding.Unicode);
    CrashWritePendingMarker(ReportPath);
    Result := Result and CrashAutoTestQueueUpload('failure report', ReportPath,
      function(const AUrl, AFieldName, AText, AFileName: String): Boolean
      begin
        TransportDone.SetEvent;
        Result := False;
      end);
    Result := Result and (TransportDone.WaitFor(2000) = wrSignaled);
    Sleep(20);
    Result := Result and TFile.Exists(ReportPath) and TFile.Exists(MarkerPath);
  finally
    TransportDone.Free;
    if TDirectory.Exists(Dir) then
      TDirectory.Delete(Dir, True);
  end;
end;

function Step_P7_QueueIsNonBlocking: Boolean;
var
  Dir, ReportPath: String;
  Gate, Entered, Done: TEvent;
  StartedAt, Elapsed: UInt64;
begin
  Dir := NewFixtureDir;
  Gate := TEvent.Create(nil, True, False, '');
  Entered := TEvent.Create(nil, True, False, '');
  Done := TEvent.Create(nil, True, False, '');
  try
    ReportPath := TPath.Combine(Dir, 'Crash_WIN_BLOCKING.el');
    TFile.WriteAllText(ReportPath, 'blocking report', TEncoding.Unicode);
    CrashWritePendingMarker(ReportPath);
    StartedAt := TThread.GetTickCount64;
    Result := CrashAutoTestQueueUpload('blocking report', ReportPath,
      function(const AUrl, AFieldName, AText, AFileName: String): Boolean
      begin
        Entered.SetEvent;
        Gate.WaitFor(2000);
        Done.SetEvent;
        Result := False;
      end);
    Elapsed := TThread.GetTickCount64 - StartedAt;
    Result := Result and (Elapsed < 250) and
      (Entered.WaitFor(2000) = wrSignaled) and TFile.Exists(ReportPath);
    Gate.SetEvent;
    Result := Result and (Done.WaitFor(2000) = wrSignaled);
    Sleep(20);
  finally
    Gate.SetEvent;
    Done.WaitFor(2000);
    Done.Free;
    Entered.Free;
    Gate.Free;
    if TDirectory.Exists(Dir) then
      TDirectory.Delete(Dir, True);
  end;
end;

function Step_P8_AtomicUnicodeWrite: Boolean;
var
  Dir, FirstPath, SecondPath: String;
  Bytes: TBytes;
  TempFiles: TArray<String>;
begin
  Dir := NewFixtureDir;
  try
    FirstPath := TPath.Combine(Dir, 'Crash_WIN_ATOMIC.el');
    Result := CrashWriteReportTextToUniqueFile('first report', FirstPath);
    Bytes := TFile.ReadAllBytes(FirstPath);
    Result := Result and (Length(Bytes) >= 2) and
      (Bytes[0] = $FF) and (Bytes[1] = $FE) and
      (TFile.ReadAllText(FirstPath, TEncoding.Unicode) = 'first report');

    SecondPath := TPath.Combine(Dir, 'Crash_WIN_ATOMIC.el');
    Result := Result and
      CrashWriteReportTextToUniqueFile('second report', SecondPath) and
      (SecondPath <> FirstPath) and
      (TFile.ReadAllText(FirstPath, TEncoding.Unicode) = 'first report') and
      (TFile.ReadAllText(SecondPath, TEncoding.Unicode) = 'second report');
    TempFiles := TDirectory.GetFiles(Dir, '*.tmp.*');
    Result := Result and (Length(TempFiles) = 0);
  finally
    if TDirectory.Exists(Dir) then
      TDirectory.Delete(Dir, True);
  end;
end;

function Step_P9_StartupLimitKeepsDeferredMarkers: Boolean;
var
  Dir, ReportPath, MarkerPath: String;
  AllFiles, Batch: TArray<String>;
  I: Integer;
begin
  Dir := NewFixtureDir;
  try
    SetLength(AllFiles, 5);
    for I := 0 to High(AllFiles) do
    begin
      ReportPath := TPath.Combine(Dir,
        Format('Crash_WIN_STARTUP_%d.el', [I + 1]));
      AllFiles[I] := ReportPath;
      TFile.WriteAllText(ReportPath, 'startup report', TEncoding.Unicode);
      if not CrashWritePendingMarker(ReportPath) then
        Exit(False);
    end;

    Batch := CrashTakeStartupUploadBatch(AllFiles,
      CRASH_MAX_STARTUP_UPLOADS);
    Result := Length(Batch) = CRASH_MAX_STARTUP_UPLOADS;
    for I := 0 to High(Batch) do
    begin
      Result := Result and (Batch[I] = AllFiles[I]);
      CrashDeleteReportAndPendingMarker(Batch[I]);
    end;
    for I := 0 to High(AllFiles) do
    begin
      ReportPath := AllFiles[I];
      MarkerPath := CrashPendingMarkerPath(ReportPath);
      if I < CRASH_MAX_STARTUP_UPLOADS then
        Result := Result and (not TFile.Exists(ReportPath)) and
          (not TFile.Exists(MarkerPath))
      else
        Result := Result and TFile.Exists(ReportPath) and
          TFile.Exists(MarkerPath);
    end;
  finally
    if TDirectory.Exists(Dir) then
      TDirectory.Delete(Dir, True);
  end;
end;

function Step_P10_AntiCascadeCreatesOneFile: Boolean;
var
  Dir, ReportPath: String;
  AlreadyReported: Boolean;
  Files: TArray<String>;
begin
  Dir := NewFixtureDir;
  try
    AlreadyReported := False;
    ReportPath := TPath.Combine(Dir, 'Crash_WIN_CASCADE.el');
    Result := CrashAutoTestTryClaimReport(AlreadyReported);
    if Result then
      Result := CrashWriteReportTextToUniqueFile('first report', ReportPath);

    if CrashAutoTestTryClaimReport(AlreadyReported) then
    begin
      ReportPath := TPath.Combine(Dir, 'Crash_WIN_CASCADE_SECOND.el');
      CrashWriteReportTextToUniqueFile('second report', ReportPath);
      Result := False;
    end;
    Files := TDirectory.GetFiles(Dir, '*.el');
    Result := Result and AlreadyReported and (Length(Files) = 1);
    if Length(Files) = 1 then
      Result := Result and
        (TFile.ReadAllText(Files[0], TEncoding.Unicode) = 'first report');
  finally
    if TDirectory.Exists(Dir) then
      TDirectory.Delete(Dir, True);
  end;
end;

class function TCrashPending_AllInOne.AutoTest(
  out OutLines: TArray<string>): Boolean;
var
  Lines: TList<string>;
  Progress: TCrashTestProgress;
begin
  Lines := TList<string>.Create;
  try
    Progress := TCrashTestProgress.Create(Lines);
    try
      Progress.Account(Step_P1_PathMapping,
        'P1: .el maps to a sibling .pending marker');
      Progress.Account(Step_P2_CreateValidateDelete,
        'P2: marker arms delivery and success removes report then marker');
      Progress.Account(Step_P3_FailClosedMarkers,
        'P3: missing report and unknown marker fail closed; empty marker is valid');
      Progress.Account(Step_P4_MixedPartition,
        'P4: per-file marker selection preserves unmarked desktop leftovers');
      Progress.Account(Step_P5_FilePartitionAndOrphanCleanup,
        'P5: mixed directory partitions per file and removes orphan markers');
      Progress.Account(Step_P6_AsyncSuccessFailure,
        'P6: async success deletes both artifacts; failure keeps both');
      Progress.Account(Step_P7_QueueIsNonBlocking,
        'P7: a blocked transport never blocks the caller');
      Progress.Account(Step_P8_AtomicUnicodeWrite,
        'P8: atomic UTF-16LE+BOM write preserves collisions and leaves no temp');
      Progress.Account(Step_P9_StartupLimitKeepsDeferredMarkers,
        'P9: startup limit leaves unattempted reports and markers untouched');
      Progress.Account(Step_P10_AntiCascadeCreatesOneFile,
        'P10: anti-cascade claim permits exactly one report file');
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
    'CrashPending',
    'Crash pending delivery marker contracts',
    ['crash', 'pending', 'delivery'],
    TCrashPending_AllInOne.AutoTest
  );

{$ENDIF}

end.
