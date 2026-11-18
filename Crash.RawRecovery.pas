unit Crash.RawRecovery;

{ Startup recovery of committed raw fallback slots: a previous process that
  died before it could write a full .el left a binary block (registers, IP,
  fault address); this unit turns each one into an EL report, unless a full
  .el carrying the same Raw Capture Key already exists, and then removes the
  slot. Also identifies the current image for raw-slot preparation.

  Copyright (c) 2026 Vizit0r. BSD 2-Clause license (see LICENSE.txt). }

interface

uses
  Crash.CallStack,
  Crash.RawFallback;

type
  TCrashReportPathForID = reference to function(const ABugID: String): String;

  TCrashRawRecoveryContext = record
    ReportDir: String;   // with a trailing delimiter
    ScanPrefix: String;  // reports and raw slots match "<prefix>*"
    AppName: String;     // used when the raw block names no application
    CompilationTime: String; // gates rebasing to an identical build
    DisabledSections: TCrashReportSections;
    AppStartTime: TDateTime;
    PathForID: TCrashReportPathForID; // report path for a BugID
  end;

procedure CrashRecoverRawFallbackReports(const AContext: TCrashRawRecoveryContext);
function CrashELContainsRawCaptureKey(const AFilePath,
  ACaptureKey: String): Boolean;
{ Load base, size and build-id of the image raw addresses are relative to:
  the Android .so, else the main executable. Size 0 = unknown. }
procedure CrashCurrentImage(out ABase, ASize: UInt64;
  out AImageID: TCrashRawImageID);

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.DateUtils,
  Crash.ELFormat,
  Crash.Modules,
  Crash.Android.Symbols,
  Crash.Pending,
  Crash.Signals;

function CrashModuleSizeForBase(const ABase: UInt64;
  out ASize: UInt64): Boolean;
var
  Modules: TModuleInfoArray;
  M: TModuleInfo;
begin
  Result := False;
  ASize := 0;
  if ABase = 0 then
    Exit(False);
  Modules := CrashEnumerateModules;
  for M in Modules do
    if M.BaseAddr = ABase then
    begin
      ASize := M.Size;
      Exit(ASize <> 0);
    end;
end;

procedure CrashCurrentImage(out ABase, ASize: UInt64;
  out AImageID: TCrashRawImageID);
var
  AndroidModuleBase: UInt64;
  AndroidImageID: TCrashAndroidBuildID;
begin
  FillChar(AImageID, SizeOf(AImageID), 0);
  if CrashAndroidGetBuildID(AndroidImageID) then
    Move(AndroidImageID, AImageID, SizeOf(AImageID));
  AndroidModuleBase := UInt64(CrashAndroidModuleBase);
  if AndroidModuleBase <> 0 then
    ABase := AndroidModuleBase
  else
    ABase := UInt64(TCrashCapture.MainModuleAddress);
  if not CrashModuleSizeForBase(ABase, ASize) then
    ASize := 0;
end;

function CrashELContainsRawCaptureKey(const AFilePath,
  ACaptureKey: String): Boolean;
var
  Text: String;
begin
  Result := False;
  if (AFilePath = '') or (ACaptureKey = '') then
    Exit;
  try
    Text := TFile.ReadAllText(AFilePath, TEncoding.Unicode);
    Result := Pos('Raw Capture Key: ' + ACaptureKey, Text) > 0;
  except
  end;
end;

function WriteRecoveredRawReport(const AContext: TCrashRawRecoveryContext;
  const ARaw: TCrashRawRecord): Boolean;
var
  Report: TCrashReport;
  Ctx: TCrashELContext;
  Text, Path: String;
  IP, FaultAddr, ThreadID: UInt64;
  CurrentImageBase, CurrentImageSize: UInt64;
  RebasedIP, ModuleOffset, RoutineOffset, CapturedImageEnd: UInt64;
  SignalNum, SignalCode: Integer;
  Rebased: Boolean;
  CurrentImageID: TCrashRawImageID;
  Address: array[0..0] of UIntPtr;
begin
  Result := False;
  Report := Default(TCrashReport);
  if ARaw.PayloadKind = rpkPrimary then
  begin
    IP := CrashRawPrimaryIP(ARaw.Primary);
    FaultAddr := ARaw.Primary.FaultAddr;
    ThreadID := ARaw.Primary.ThreadID;
    SignalNum := ARaw.Primary.SignalNum;
    SignalCode := ARaw.Primary.SignalCode;
    Report.ExceptionClassName := 'ERawHardwareFault';
  end
  else if ARaw.PayloadKind = rpkConcurrent then
  begin
    IP := ARaw.Concurrent.IP;
    FaultAddr := ARaw.Concurrent.FaultAddr;
    ThreadID := ARaw.Concurrent.ThreadID;
    SignalNum := ARaw.Concurrent.SignalNum;
    SignalCode := ARaw.Concurrent.SignalCode;
    Report.ExceptionClassName := 'ERawConcurrentHardwareFault';
  end
  else
    Exit;

  Report.ExceptionMessage := Format(
    'Committed raw fallback recovered signal %d (code=%d, fault=%s)',
    [SignalNum, SignalCode, IntToHex(FaultAddr, SizeOf(Pointer) * 2)]);
  Report.Source := csFatalProc;
  CrashCurrentImage(CurrentImageBase, CurrentImageSize, CurrentImageID);
  Rebased := CrashRawTryRebaseAddress(ARaw, IP, CurrentImageBase,
    CurrentImageSize, CurrentImageID, AContext.CompilationTime,
    RebasedIP, ModuleOffset);
  if Rebased then
    Address[0] := UIntPtr(RebasedIP)
  else
    Address[0] := UIntPtr(IP);
  if IP <> 0 then
    Report.CallStack := TCrashCapture.SymbolizeAddressList(Address);
  if Rebased and (Length(Report.CallStack) > 0) and
     (UInt64(Report.CallStack[0].ModuleAddress) = CurrentImageBase) then
  begin
    { Resolution ran in this process, but the report must retain addresses from
      the crashed process. Keep names/source/line and translate the resolved
      module/routine addresses back to the captured ASLR range. }
    Report.CallStack[0].CodeAddress := UIntPtr(IP);
    Report.CallStack[0].ModuleAddress := UIntPtr(ARaw.ImageBase);
    if UInt64(Report.CallStack[0].RoutineAddress) >= CurrentImageBase then
    begin
      RoutineOffset := UInt64(Report.CallStack[0].RoutineAddress) -
        CurrentImageBase;
      if (RoutineOffset < ARaw.ImageSize) and
         (ARaw.ImageBase <= High(UInt64) - RoutineOffset) then
        Report.CallStack[0].RoutineAddress :=
          UIntPtr(ARaw.ImageBase + RoutineOffset)
      else
        Report.CallStack[0].RoutineAddress := 0;
    end
    else
      Report.CallStack[0].RoutineAddress := 0;
  end;
  if Length(Report.CallStack) > 0 then
    Report.ExceptionLocation := Report.CallStack[0]
  else
  begin
    Report.ExceptionLocation.Clear;
    Report.ExceptionLocation.CodeAddress := UIntPtr(IP);
  end;

  Ctx := CrashDefaultELContext(AContext.AppStartTime, UIntPtr(IP), False);
  if ARaw.InitUnixSeconds > 0 then
    Ctx.StartTime := UnixToDateTime(ARaw.InitUnixSeconds, False);
  try
    Ctx.ExceptionTime := TFile.GetLastWriteTime(ARaw.FilePath);
  except
    Ctx.ExceptionTime := Now;
  end;
  Ctx.AppParameters := '';
  if ARaw.AppName <> '' then
    Ctx.AppName := ARaw.AppName
  else if ARaw.ExeName <> '' then
    Ctx.AppName := ARaw.ExeName
  else if AContext.AppName <> '' then
    Ctx.AppName := AContext.AppName;
  Ctx.AppVersion := ARaw.AppVersion;
  Ctx.CompileTime := ARaw.CompilationTime;
  Ctx.ThreadID := Cardinal(ThreadID);
  Ctx.ThreadName := 'RAW';
  Ctx.DisabledSections := AContext.DisabledSections;
  CrashFormatRecoveredRaw(ARaw, Ctx.CpuSnapshot, Ctx.SignalInfoSection);
  Ctx.SignalInfoSection := Ctx.SignalInfoSection + #13#10 +
    '  Raw Format : v' + IntToStr(ARaw.FormatVersion);
  if ARaw.FormatVersion >= CRASH_RAW_VERSION then
  begin
    if ARaw.ImageBase <= High(UInt64) - ARaw.ImageSize then
      CapturedImageEnd := ARaw.ImageBase + ARaw.ImageSize
    else
      CapturedImageEnd := High(UInt64);
    Ctx.SignalInfoSection := Ctx.SignalInfoSection + #13#10 +
      '  Image Range: ' + IntToHex(ARaw.ImageBase, SizeOf(Pointer) * 2) +
      '..' + IntToHex(CapturedImageEnd, SizeOf(Pointer) * 2);
  end;
  if Rebased then
    Ctx.SignalInfoSection := Ctx.SignalInfoSection + #13#10 +
      '  Rebased    : module offset ' +
      IntToHex(ModuleOffset, SizeOf(Pointer) * 2) + ', current base ' +
      IntToHex(CurrentImageBase, SizeOf(Pointer) * 2) + ', current size ' +
      IntToHex(CurrentImageSize, SizeOf(Pointer) * 2);
  CrashCollectELModules(Ctx);
  Text := CrashBuildELReportText(Report, Ctx);

  Path := AContext.PathForID(CrashGenerateExceptionID(Report));
  Result := CrashWriteReportTextToUniqueFile(Text, Path);
end;

procedure CrashRecoverRawFallbackReports(const AContext: TCrashRawRecoveryContext);
var
  RawPath, ELPath: String;
  RawFiles, ELFiles: TArray<String>;
  Raw: TCrashRawRecord;
  Duplicate: Boolean;
begin
  if (AContext.ReportDir = '') or (not Assigned(AContext.PathForID)) then
    Exit;
  RawFiles := CrashRawEnumerateFiles(AContext.ReportDir, AContext.ScanPrefix);
  if Length(RawFiles) = 0 then
    Exit;
  try
    ELFiles := TDirectory.GetFiles(AContext.ReportDir,
      AContext.ScanPrefix + '*.el');
  except
    ELFiles := nil;
  end;
  for RawPath in RawFiles do
  begin
    if not CrashRawReadBlock(RawPath, Raw) then
    begin
      if CrashRawFileIsAbandoned(RawPath) or CrashRawFileIsStale(RawPath) then
        CrashRawDeleteFile(RawPath);
      Continue;
    end;
    if CrashRawRecordOwnedByLiveProcess(Raw) then
      Continue;
    Duplicate := False;
    for ELPath in ELFiles do
      if CrashELContainsRawCaptureKey(ELPath, Raw.CaptureKey) then
      begin
        Duplicate := True;
        Break;
      end;
    if Duplicate or WriteRecoveredRawReport(AContext, Raw) then
    begin
      CrashRawDeleteFile(RawPath);
      CrashRawDeleteUntouchedSibling(Raw);
    end;
  end;
end;

end.
