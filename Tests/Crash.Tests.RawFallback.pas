unit Crash.Tests.RawFallback;

// Copyright (c) 2026 Vizit0r. BSD 2-Clause license (see LICENSE.txt).

interface

{$IFDEF AUTOTESTS}

uses
  System.SysUtils,
  Crash.Tests.Registry;

type
  TCrashRawFallback_AllInOne = class
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
  System.IOUtils,
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ELSE}
  Posix.Unistd,
  {$ENDIF}
  Crash.RawFallback,
  Crash.Signals,
  Crash.Reporter,
  Crash.Tests.Progress;

const
  TEST_NAME = 'CrashRawFallback';
  PRIMARY_KEY = 'R2-000004D2-000000000000162E-00000009-0';
  CONCURRENT_KEY = 'R2-000004D2-000000000000162E-00000009-1';
  PRISTINE_KEY = 'R2-000004D2-000000000000162E-0000000A-0';
  ABANDON_KEY = 'R2-000004D2-000000000000162E-0000000A-1';
  ZERO_KEY = 'R2-00002D42-00000000011E38B8-0000000B-0';
  ZERO_KEY_PID = $2D42;
  LEGACY_KEY = 'R1-000004D2-000000000000162E-00000008-0';

function NewFixtureDir: String;
begin
  Result := TPath.Combine(TPath.GetTempPath,
    'CrashTestsRaw_' + TPath.GetRandomFileName);
  ForceDirectories(Result);
end;

procedure LoadBlock(const APath: String; out ABlock: TCrashRawDiskBlockV1);
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    Stream.ReadBuffer(ABlock, SizeOf(ABlock));
  finally
    Stream.Free;
  end;
end;

procedure SaveBlock(const APath: String; const ABlock: TCrashRawDiskBlockV1);
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(APath, fmCreate or fmShareDenyNone);
  try
    Stream.WriteBuffer(ABlock, SizeOf(ABlock));
  finally
    Stream.Free;
  end;
end;

function Step_R1_LayoutAndDescriptors: Boolean;
begin
  Result := (SizeOf(TCrashRawPrimarySnapshot) <= CRASH_RAW_PAYLOAD_BYTES) and
    (SizeOf(TCrashRawConcurrentSnapshot) <= CRASH_RAW_PAYLOAD_BYTES) and
    (CRASH_RAW_VERSION = 2) and
    (SizeOf(TCrashRawHeaderV2) = SizeOf(TCrashRawHeaderV1) + 32) and
    (SizeOf(TCrashRawDiskBlockV1) = SizeOf(TCrashRawDiskBlockV2)) and
    (SizeOf(TCrashRawDiskBlockV2) > CRASH_RAW_PAYLOAD_BYTES) and
    ((not CrashRawSupported) or CrashRawCurrentSlotsPrepared) and
    CrashRawDescriptorsCloseOnExec;
end;

function Step_R2_PrimaryRoundTrip(const ADir: String;
  out ARaw: TCrashRawRecord; out APath: String): Boolean;
begin
  APath := TPath.Combine(ADir, 'Fixture_raw_' + PRIMARY_KEY + '.crashraw');
  Result := CrashRawAutoTestWriteBlock(APath, PRIMARY_KEY, rpkPrimary, True) and
    CrashRawReadBlock(APath, ARaw) and
    (ARaw.PayloadKind = rpkPrimary) and
    (ARaw.CaptureKey = PRIMARY_KEY) and
    (ARaw.Primary.SignalNum = 11) and
    (ARaw.Primary.FaultAddr = $DEADBEEF) and
    (ARaw.FormatVersion = CRASH_RAW_VERSION) and
    (ARaw.ImageBase = $0000007100000000) and
    (ARaw.ImageSize = $02000000) and
    (ARaw.ImageID[0] = 1) and (ARaw.ImageID[15] = 16) and
    (CrashRawPrimaryIP(ARaw.Primary) = $1122334455667788) and
    (CrashRawPrimarySP(ARaw.Primary) = $8877665544332211) and
    (CrashRawPrimaryFP(ARaw.Primary) = $1234567890ABCDEF);
end;

function Step_R3_ConcurrentRoundTrip(const ADir: String): Boolean;
var
  Path: String;
  Raw: TCrashRawRecord;
begin
  Path := TPath.Combine(ADir, 'Fixture_raw_' + CONCURRENT_KEY + '.crashraw');
  Result := CrashRawAutoTestWriteBlock(Path, CONCURRENT_KEY,
    rpkConcurrent, True) and CrashRawReadBlock(Path, Raw) and
    (Raw.PayloadKind = rpkConcurrent) and
    (Raw.CaptureKey = CONCURRENT_KEY) and
    (Raw.Concurrent.SignalNum = 7) and
    (Raw.Concurrent.IP = $1020304050607080) and
    (Raw.Concurrent.ThreadID = 84);
end;

function Step_R4_CommitLastFailClosed(const ADir: String): Boolean;
var
  Path: String;
  Stage, Commit: Byte;
  Raw: TCrashRawRecord;
begin
  Path := TPath.Combine(ADir, 'uncommitted.crashraw');
  Result := CrashRawAutoTestWriteBlock(Path, PRIMARY_KEY, rpkPrimary, False) and
    CrashRawInspectMarkers(Path, Stage, Commit) and
    (Stage = CRASH_RAW_STAGE_ENTERED) and (Commit = 0) and
    (not CrashRawReadBlock(Path, Raw));
end;

function Step_R5_CorruptHeadersFailClosed(const ADir: String): Boolean;
var
  Path: String;
  Block: TCrashRawDiskBlockV1;
  Raw: TCrashRawRecord;
begin
  Path := TPath.Combine(ADir, 'corrupt.crashraw');
  Result := CrashRawAutoTestWriteBlock(Path, PRIMARY_KEY, rpkPrimary, True);
  LoadBlock(Path, Block);
  Block.Header.Magic[0] := 'X';
  SaveBlock(Path, Block);
  Result := Result and (not CrashRawReadBlock(Path, Raw));

  CrashRawAutoTestWriteBlock(Path, PRIMARY_KEY, rpkPrimary, True);
  LoadBlock(Path, Block);
  Block.Header.Version := CRASH_RAW_VERSION + 1;
  SaveBlock(Path, Block);
  Result := Result and (not CrashRawReadBlock(Path, Raw));

  CrashRawAutoTestWriteBlock(Path, PRIMARY_KEY, rpkPrimary, True);
  LoadBlock(Path, Block);
  Dec(Block.Header.BlockSize);
  SaveBlock(Path, Block);
  Result := Result and (not CrashRawReadBlock(Path, Raw));

  CrashRawAutoTestWriteBlock(Path, PRIMARY_KEY, rpkPrimary, True);
  LoadBlock(Path, Block);
  Dec(Block.Header.PayloadSize);
  SaveBlock(Path, Block);
  Result := Result and (not CrashRawReadBlock(Path, Raw));

  CrashRawAutoTestWriteBlock(Path, PRIMARY_KEY, rpkPrimary, True);
  LoadBlock(Path, Block);
  FillChar(Block.Header.CaptureKey, SizeOf(Block.Header.CaptureKey), 0);
  SaveBlock(Path, Block);
  Result := Result and (not CrashRawReadBlock(Path, Raw));
end;

function Step_R6_PartialBlockFailsClosed(const ADir: String): Boolean;
var
  Path: String;
  Stream: TFileStream;
  B: Byte;
  Raw: TCrashRawRecord;
begin
  Path := TPath.Combine(ADir, 'partial.crashraw');
  B := CRASH_RAW_STAGE_ENTERED;
  Stream := TFileStream.Create(Path, fmCreate or fmShareDenyNone);
  try
    Stream.WriteBuffer(B, 1);
  finally
    Stream.Free;
  end;
  Result := not CrashRawReadBlock(Path, Raw);
end;

function Step_R7_KeyDedup(const ADir: String): Boolean;
var
  Path, Text: String;
begin
  Path := TPath.Combine(ADir, 'Fixture_DEADBEEF.el');
  Text := 'Crash Signal Info:' + #13#10 +
    '  Raw Capture Key: ' + PRIMARY_KEY + #13#10;
  TFile.WriteAllText(Path, Text, TEncoding.Unicode);
  Result := CrashAutoTestELContainsRawCaptureKey(Path, PRIMARY_KEY) and
    (not CrashAutoTestELContainsRawCaptureKey(Path, CONCURRENT_KEY));
end;

function Step_R8_RecoveredFormatting(const ARaw: TCrashRawRecord): Boolean;
var
  RegistersText, SignalText: String;
begin
  if not CrashRawSupported then
    Exit(True);
  CrashFormatRecoveredRaw(ARaw, RegistersText, SignalText);
  Result := RegistersText.StartsWith('Registers:' + #13#10) and
    SignalText.Contains('Raw Capture Key: ' + PRIMARY_KEY) and
    SignalText.Contains('committed raw fallback converted during startup') and
    (Pos(#10, SignalText.Replace(#13#10, '')) = 0);
end;

function Step_R9_UntouchedSiblingCleanup(const ADir, APrimaryPath: String;
  const ARaw: TCrashRawRecord): Boolean;
var
  SiblingPath: String;
  Block: TCrashRawDiskBlockV1;
begin
  SiblingPath := TPath.Combine(ADir,
    'Fixture_raw_' + CONCURRENT_KEY + '.crashraw');
  CrashRawAutoTestWriteBlock(SiblingPath, CONCURRENT_KEY,
    rpkConcurrent, False);
  LoadBlock(SiblingPath, Block);
  Block.Stage := 0; // preallocated but never entered by the signal handler
  SaveBlock(SiblingPath, Block);
  CrashRawDeleteUntouchedSibling(ARaw);
  Result := TFile.Exists(APrimaryPath) and (not TFile.Exists(SiblingPath));
end;

function Step_R10_StalePolicy(const ADir: String): Boolean;
var
  FreshPath, OldPath: String;
begin
  FreshPath := TPath.Combine(ADir, 'fresh.crashraw');
  OldPath := TPath.Combine(ADir, 'old.crashraw');
  CrashRawAutoTestWriteBlock(FreshPath, PRIMARY_KEY, rpkPrimary, False);
  CrashRawAutoTestWriteBlock(OldPath, PRIMARY_KEY, rpkPrimary, False);
  TFile.SetLastWriteTime(OldPath, IncDay(Now, -CRASH_RAW_STALE_DAYS - 1));
  Result := (not CrashRawFileIsStale(FreshPath)) and
    CrashRawFileIsStale(OldPath);
end;

function Step_R11_PrefixEnumeration(const ADir: String): Boolean;
var
  MatchPath, OtherPath: String;
  Files: TArray<String>;
  FilePath: String;
  FoundMatch, FoundOther: Boolean;
begin
  MatchPath := TPath.Combine(ADir, 'One_raw_' + PRIMARY_KEY + '.crashraw');
  OtherPath := TPath.Combine(ADir, 'Two_raw_' + PRIMARY_KEY + '.crashraw');
  CrashRawAutoTestWriteBlock(MatchPath, PRIMARY_KEY, rpkPrimary, True);
  CrashRawAutoTestWriteBlock(OtherPath, PRIMARY_KEY, rpkPrimary, True);
  Files := CrashRawEnumerateFiles(ADir, 'One_');
  FoundMatch := False;
  FoundOther := False;
  for FilePath in Files do
  begin
    FoundMatch := FoundMatch or SameText(FilePath, MatchPath);
    FoundOther := FoundOther or SameText(FilePath, OtherPath);
  end;
  Result := FoundMatch and (not FoundOther);
end;

function Step_R12_LiveOwnerRetained(const ADir: String): Boolean;
var
  Path: String;
begin
  Path := TPath.Combine(ADir, 'Fixture_raw_' + PRISTINE_KEY + '.crashraw');
  Result := CrashRawAutoTestWritePristineBlock(Path, PRISTINE_KEY,
      rpkPrimary, 0) and
    (not CrashRawFileIsAbandoned(Path));
end;

function Step_R13_DeadOwnerCollected(const ADir: String): Boolean;
var
  PristinePath, CommittedPath: String;
  PristineCollected, CommittedKept: Boolean;
begin
  PristinePath := TPath.Combine(ADir,
    'Fixture_raw_' + PRISTINE_KEY + '.crashraw');
  CommittedPath := TPath.Combine(ADir,
    'Fixture_raw_' + ABANDON_KEY + '.crashraw');
  Result := CrashRawAutoTestWritePristineBlock(PristinePath, PRISTINE_KEY,
      rpkPrimary, 0) and
    CrashRawAutoTestWriteBlock(CommittedPath, ABANDON_KEY, rpkConcurrent, True);
  if not Result then
    Exit;
  CrashRawAutoTestSetOwnerAliveProbe(
    function(const AProcessID: UInt64): Boolean
    begin
      Result := False;
    end);
  try
    PristineCollected := CrashRawFileIsAbandoned(PristinePath);
    CommittedKept := not CrashRawFileIsAbandoned(CommittedPath);
  finally
    CrashRawAutoTestSetOwnerAliveProbe(nil);
  end;
  Result := PristineCollected and CommittedKept;
end;

function Step_R14_ZeroSlotOwnerFromKey(const ADir: String): Boolean;
var
  Path: String;
  Asked: UInt64;
  Collected: Boolean;
begin
  Path := TPath.Combine(ADir, 'Fixture_raw_' + ZERO_KEY + '.crashraw');
  if not CrashRawAutoTestWriteZeroBlock(Path) then
    Exit(False);
  Asked := 0;
  CrashRawAutoTestSetOwnerAliveProbe(
    function(const AProcessID: UInt64): Boolean
    begin
      Asked := AProcessID;
      Result := False;
    end);
  try
    Collected := CrashRawFileIsAbandoned(Path);
  finally
    CrashRawAutoTestSetOwnerAliveProbe(nil);
  end;
  Result := Collected and (Asked = ZERO_KEY_PID);
end;

function Step_R15_LegacyV1StillReads(const ADir: String): Boolean;
var
  Path: String;
  Raw: TCrashRawRecord;
begin
  Path := TPath.Combine(ADir, 'Fixture_raw_' + LEGACY_KEY + '.crashraw');
  Result := CrashRawAutoTestWriteLegacyV1Block(Path, LEGACY_KEY,
    rpkPrimary, True) and CrashRawReadBlock(Path, Raw) and
    (Raw.FormatVersion = CRASH_RAW_VERSION_V1) and
    (Raw.ImageBase = 0) and (Raw.ImageSize = 0) and
    (Raw.ImageID[0] = 0) and (Raw.ImageID[15] = 0) and
    (Raw.CaptureKey = LEGACY_KEY) and
    (CrashRawPrimaryIP(Raw.Primary) = $1122334455667788);
end;

function Step_R16_V2RebaseContract: Boolean;
var
  Raw: TCrashRawRecord;
  CurrentImageID: TCrashRawImageID;
  Rebased, Offset: UInt64;
  I: Integer;
begin
  Raw := Default(TCrashRawRecord);
  Raw.FormatVersion := CRASH_RAW_VERSION;
  Raw.ImageBase := $0000007100000000;
  Raw.ImageSize := $02000000;
  Raw.CompilationTime := 'same-build';
  for I := Low(Raw.ImageID) to High(Raw.ImageID) do
  begin
    Raw.ImageID[I] := Byte(I + 1);
    CurrentImageID[I] := Byte(I + 1);
  end;
  Result := CrashRawTryRebaseAddress(Raw, Raw.ImageBase + $123456,
    $0000007200000000, $02000000, CurrentImageID, 'runtime-value-can-differ',
    Rebased, Offset) and
    (Offset = $123456) and (Rebased = $0000007200123456);
  Result := Result and not CrashRawTryRebaseAddress(Raw,
    Raw.ImageBase + Raw.ImageSize, $0000007200000000, $02000000,
    CurrentImageID,
    'same-build',
    Rebased, Offset);
  CurrentImageID[15] := $FF;
  Result := Result and not CrashRawTryRebaseAddress(Raw,
    Raw.ImageBase + $123456, $0000007200000000, $02000000, CurrentImageID,
    'same-build', Rebased, Offset);
  CurrentImageID[15] := 16;
  Raw.FormatVersion := CRASH_RAW_VERSION_V1;
  Result := Result and not CrashRawTryRebaseAddress(Raw,
    Raw.ImageBase + $123456, $0000007200000000, $02000000, CurrentImageID,
    'same-build', Rebased, Offset);
  Raw.FormatVersion := CRASH_RAW_VERSION;
  Result := Result and not CrashRawTryRebaseAddress(Raw,
    Raw.ImageBase + $123456, High(UInt64) - $100, $02000000, CurrentImageID,
    'same-build', Rebased, Offset);
  Result := Result and not CrashRawTryRebaseAddress(Raw,
    Raw.ImageBase + $123456, $0000007200000000, 0, CurrentImageID,
    'same-build', Rebased, Offset);
  FillChar(Raw.ImageID, SizeOf(Raw.ImageID), 0);
  FillChar(CurrentImageID, SizeOf(CurrentImageID), 0);
  Result := Result and CrashRawTryRebaseAddress(Raw,
    Raw.ImageBase + $123456, $0000007200000000, $02000000, CurrentImageID,
    'same-build', Rebased, Offset);
  Result := Result and not CrashRawTryRebaseAddress(Raw,
    Raw.ImageBase + $123456, $0000007200000000, $02000000, CurrentImageID,
    'other-build', Rebased, Offset);
end;

function Step_R17_LiveOwnerCommittedKept: Boolean;
// Startup recovery must not take over the committed record of a sibling that
// is still running: it survived a handled fault or is writing its own report.
var
  Raw: TCrashRawRecord;
  Alive, LiveForeign, DeadForeign, OwnPid, NoPid: Boolean;
begin
  Raw := Default(TCrashRawRecord);
  Alive := True;
  CrashRawAutoTestSetOwnerAliveProbe(
    function(const AProcessID: UInt64): Boolean
    begin
      Result := Alive;
    end);
  try
    Raw.ProcessID := $4D2;
    LiveForeign := CrashRawRecordOwnedByLiveProcess(Raw);
    Alive := False;
    DeadForeign := CrashRawRecordOwnedByLiveProcess(Raw);
    Alive := True;
    {$IFDEF MSWINDOWS}
    Raw.ProcessID := GetCurrentProcessId;
    {$ELSE}
    Raw.ProcessID := UInt64(getpid);
    {$ENDIF}
    OwnPid := CrashRawRecordOwnedByLiveProcess(Raw);
    Raw.ProcessID := 0;
    NoPid := CrashRawRecordOwnedByLiveProcess(Raw);
  finally
    CrashRawAutoTestSetOwnerAliveProbe(nil);
  end;
  // No raw fallback on Windows: nothing is ever owned there.
  Result := (LiveForeign = CrashRawSupported) and
    (not DeadForeign) and (not OwnPid) and (not NoPid);
end;

class function TCrashRawFallback_AllInOne.AutoTest(
  out OutLines: TArray<string>): Boolean;
var
  Dir, PrimaryPath: String;
  Raw: TCrashRawRecord;
  Lines: TList<string>;
  Progress: TCrashTestProgress;
begin
  Lines := TList<string>.Create;
  try
    Progress := TCrashTestProgress.Create(Lines);
    Dir := NewFixtureDir;
    try
      Progress.Account(Step_R1_LayoutAndDescriptors,
        'R1: V2 keeps V1 block size, payload fits, live descriptors are CLOEXEC');
      Progress.Account(Step_R2_PrimaryRoundTrip(Dir, Raw, PrimaryPath),
        'R2: committed primary block round-trips registers, IP/SP/FP and key');
      Progress.Account(Step_R3_ConcurrentRoundTrip(Dir),
        'R3: committed concurrent block round-trips its location-only payload');
      Progress.Account(Step_R4_CommitLastFailClosed(Dir),
        'R4: entered-but-uncommitted block is observable and rejected');
      Progress.Account(Step_R5_CorruptHeadersFailClosed(Dir),
        'R5: bad magic/version/sizes/key all fail closed');
      Progress.Account(Step_R6_PartialBlockFailsClosed(Dir),
        'R6: partial file fails closed');
      Progress.Account(Step_R7_KeyDedup(Dir),
        'R7: exact Raw Capture Key deduplicates against UTF-16LE .el text');
      Progress.Account(Step_R8_RecoveredFormatting(Raw),
        'R8: recovered primary formats Registers and correlation metadata');
      Progress.Account(Step_R9_UntouchedSiblingCleanup(Dir, PrimaryPath, Raw),
        'R9: recovered slot removes only its untouched sibling generation');
      Progress.Account(Step_R10_StalePolicy(Dir),
        'R10: fresh incomplete raw is retained and old raw becomes stale');
      Progress.Account(Step_R11_PrefixEnumeration(Dir),
        'R11: startup enumeration stays inside the stable target prefix');
      Progress.Account(Step_R12_LiveOwnerRetained(Dir),
        'R12: never-entered slot of a live owner is retained');
      Progress.Account(Step_R13_DeadOwnerCollected(Dir),
        'R13: dead owner collects the never-entered slot, keeps the committed one');
      Progress.Account(Step_R14_ZeroSlotOwnerFromKey(Dir),
        'R14: never-written zero slot takes its owner from the capture key');
      Progress.Account(Step_R15_LegacyV1StillReads(Dir),
        'R15: legacy committed V1 slot remains readable after the V2 upgrade');
      Progress.Account(Step_R16_V2RebaseContract,
        'R16: V2 rebase is range-, build-identity- and overflow-gated');
      Progress.Account(Step_R17_LiveOwnerCommittedKept,
        'R17: committed record of a live sibling is left to its owner');
      Progress.WriteSummary(TEST_NAME);
      Result := Progress.AllPassed;
    finally
      if TDirectory.Exists(Dir) then
        TDirectory.Delete(Dir, True);
      Progress.Free;
    end;
    OutLines := Lines.ToArray;
  finally
    Lines.Free;
  end;
end;

initialization
  CrashRegisterTest(
    'CrashRawFallback',
    'Crash raw fallback format, corruption and recovery contracts',
    ['crash', 'raw', 'signal', 'recovery'],
    TCrashRawFallback_AllInOne.AutoTest
  );

{$ENDIF}

end.
