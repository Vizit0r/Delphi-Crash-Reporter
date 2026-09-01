unit Crash.RawFallback;

{ Async-signal-safe raw hardware-fault fallback.

  Calm path: prepares two O_CLOEXEC, fixed-size files and in-memory templates.
  Signal path: copies an already populated snapshot, writes it with bounded raw
  syscalls, fsyncs, and publishes the commit byte last. }

interface

uses
  System.SysUtils;

const
  CRASH_RAW_VERSION_V1 = 1;
  CRASH_RAW_VERSION = 2;
  CRASH_RAW_V1_PAYLOAD_BYTES = 1024;
  { V2 appends the crashed image range and a 16-byte image identity while
    keeping the whole disk block byte-for-byte the same size as V1. }
  CRASH_RAW_PAYLOAD_BYTES = CRASH_RAW_V1_PAYLOAD_BYTES - 32;
  CRASH_RAW_STACK_BYTES = 256;
  CRASH_RAW_SLOT_PRIMARY = 0;
  CRASH_RAW_SLOT_CONCURRENT = 1;
  CRASH_RAW_SLOT_COUNT = 2;
  CRASH_RAW_STAGE_ENTERED = $51;
  CRASH_RAW_COMMIT = $A5;
  CRASH_RAW_STALE_DAYS = 7;

type
  TCrashRawImageID = array[0..15] of Byte;

  TCrashRawSnapshotKind = (
    skNone,
    skLinuxX64,
    skMacOSX64,
    skMacOSArm64,
    skLinuxArm64
  );

  { This is both the live preallocated signal slot and the raw payload.
    Keep packed and version the outer block before changing its layout. }
  TCrashRawPrimarySnapshot = packed record
    Claimed: Integer;
    Captured: Integer;
    InvocationCount: Integer;
    SignalNum: Integer;
    SignalCode: Integer;
    FaultAddr: UInt64;
    ThreadID: UInt64;
    Kind: Integer;
    {$IF Defined(CPUX64)}
    Rax, Rbx, Rcx, Rdx, Rdi, Rsi, Rbp, Rsp: UInt64;
    R8, R9, R10, R11, R12, R13, R14, R15: UInt64;
    Rip, Rflags, Cs: UInt64;
    {$ELSEIF Defined(CPUARM64)}
    X: array[0..28] of UInt64;
    Fp, Lr, Sp, Pc: UInt64;
    Cpsr: UInt32;
    {$ENDIF}
    StackBaseAddr: UInt64;
    StackBytes: array[0..CRASH_RAW_STACK_BYTES - 1] of Byte;
  end;

  TCrashRawConcurrentSnapshot = packed record
    Claimed: Integer;
    Captured: Integer;
    Epoch: Integer;
    SignalNum: Integer;
    SignalCode: Integer;
    FaultAddr: UInt64;
    IP: UInt64;
    ThreadID: UInt64;
  end;

  TCrashRawPayloadKind = (
    rpkNone,
    rpkPrimary,
    rpkConcurrent
  );

  TCrashRawHeaderV1 = packed record
    Magic: array[0..7] of AnsiChar;
    Version: UInt16;
    HeaderSize: UInt16;
    BlockSize: UInt32;
    PayloadSize: UInt32;
    PayloadKind: Byte;
    SlotIndex: Byte;
    Platform: Byte;
    Architecture: Byte;
    ProcessID: UInt64;
    InitTick: UInt64;
    InitUnixSeconds: Int64;
    Generation: UInt32;
    Reserved: UInt32;
    CaptureKey: array[0..47] of AnsiChar;
    AppName: array[0..63] of AnsiChar;
    AppVersion: array[0..47] of AnsiChar;
    CompilationTime: array[0..47] of AnsiChar;
    ExeName: array[0..63] of AnsiChar;
  end;

  TCrashRawDiskBlockV1 = packed record
    Stage: Byte;
    Header: TCrashRawHeaderV1;
    Payload: array[0..CRASH_RAW_V1_PAYLOAD_BYTES - 1] of Byte;
    Commit: Byte;
  end;

  { V2 carries the crashed process's main-image range. The common prefix is
    intentionally identical to TCrashRawHeaderV1 so old slots remain readable. }
  TCrashRawHeaderV2 = packed record
    Magic: array[0..7] of AnsiChar;
    Version: UInt16;
    HeaderSize: UInt16;
    BlockSize: UInt32;
    PayloadSize: UInt32;
    PayloadKind: Byte;
    SlotIndex: Byte;
    Platform: Byte;
    Architecture: Byte;
    ProcessID: UInt64;
    InitTick: UInt64;
    InitUnixSeconds: Int64;
    Generation: UInt32;
    Reserved: UInt32;
    CaptureKey: array[0..47] of AnsiChar;
    AppName: array[0..63] of AnsiChar;
    AppVersion: array[0..47] of AnsiChar;
    CompilationTime: array[0..47] of AnsiChar;
    ExeName: array[0..63] of AnsiChar;
    ImageBase: UInt64;
    ImageSize: UInt64;
    ImageID: TCrashRawImageID;
  end;

  TCrashRawDiskBlockV2 = packed record
    Stage: Byte;
    Header: TCrashRawHeaderV2;
    Payload: array[0..CRASH_RAW_PAYLOAD_BYTES - 1] of Byte;
    Commit: Byte;
  end;

  TCrashRawRecord = record
    FilePath: String;
    CaptureKey: String;
    AppName: String;
    AppVersion: String;
    CompilationTime: String;
    ExeName: String;
    ProcessID: UInt64;
    InitTick: UInt64;
    InitUnixSeconds: Int64;
    Generation: UInt32;
    FormatVersion: UInt16;
    ImageBase: UInt64;
    ImageSize: UInt64;
    ImageID: TCrashRawImageID;
    PayloadKind: TCrashRawPayloadKind;
    Primary: TCrashRawPrimarySnapshot;
    Concurrent: TCrashRawConcurrentSnapshot;
  end;

function CrashRawSupported: Boolean;

{ Calm-path lifecycle. AEnabled should be SaveToFile or UploadEnabled. }
function CrashRawPrepare(const AReportDir, AScanPrefix, AAppName,
  AAppVersion, ACompilationTime, AExeName: String;
  const AImageBase, AImageSize: UInt64;
  const AImageID: TCrashRawImageID;
  const AEnabled: Boolean): Boolean;
procedure CrashRawRotate(const ADeleteCurrentFiles: Boolean);
procedure CrashRawShutdown(const ADeleteCurrentFiles: Boolean);

{ Signal-path API. No allocation, strings, threadvar, locks or exceptions. }
procedure CrashRawBeginSlot(const ASlot: Integer);
procedure CrashRawCommitPrimary(const ASnapshot: TCrashRawPrimarySnapshot);
procedure CrashRawCommitConcurrent(
  const ASnapshot: TCrashRawConcurrentSnapshot);

{ Calm-path status/recovery helpers. }
function CrashRawGetCommittedKey(const ASlot: Integer;
  out AKey: String): Boolean;
function CrashRawCurrentSlotsPrepared: Boolean;
function CrashRawDescriptorsCloseOnExec: Boolean;
function CrashRawEnumerateFiles(const AReportDir,
  AScanPrefix: String): TArray<String>;
function CrashRawReadBlock(const AFilePath: String;
  out ARecord: TCrashRawRecord): Boolean;
function CrashRawInspectMarkers(const AFilePath: String;
  out AStage, ACommit: Byte): Boolean;
function CrashRawFileIsStale(const AFilePath: String): Boolean;
{ True when the OS still knows the process that preallocated a slot. Instances
  share one report directory, so this is what keeps a running sibling's files;
  unknown owner or no way to ask counts as alive. }
function CrashRawOwnerAlive(const AProcessID: UInt64): Boolean;
{ Never-entered slot of a process that is gone: nothing was captured there and
  nobody will. Collected on the next start instead of waiting out the stale
  window. The owner comes from the block header, or - for a slot preallocated
  and never written, which is all zeros on disk - from the capture key in the
  file name. Entered-but-torn blocks stay for the stale policy. }
function CrashRawFileIsAbandoned(const AFilePath: String): Boolean;
procedure CrashRawDeleteFile(const AFilePath: String);
procedure CrashRawDeleteUntouchedSibling(const ARaw: TCrashRawRecord);

function CrashRawPrimaryIP(const APrimary: TCrashRawPrimarySnapshot): UInt64;
function CrashRawPrimarySP(const APrimary: TCrashRawPrimarySnapshot): UInt64;
function CrashRawPrimaryFP(const APrimary: TCrashRawPrimarySnapshot): UInt64;
{ Translates an address captured in a V2 main image to the same offset in the
  current image. A stored binary image ID is the preferred build-identity gate;
  exact non-empty CompilationTime equality is the fallback on platforms without
  such an ID. A wrong symbol is worse than an unresolved one. }
function CrashRawTryRebaseAddress(const ARaw: TCrashRawRecord;
  const AAddress, ACurrentImageBase, ACurrentImageSize: UInt64;
  const ACurrentImageID: TCrashRawImageID;
  const ACurrentCompilationTime: String;
  out ARebasedAddress, AModuleOffset: UInt64): Boolean;

{$IFDEF AUTOTESTS}
type
  TCrashRawOwnerAliveProbe = reference to function(
    const AProcessID: UInt64): Boolean;

function CrashRawAutoTestWriteBlock(const AFilePath, ACaptureKey: String;
  const APayloadKind: TCrashRawPayloadKind;
  const ACommitted: Boolean): Boolean;
function CrashRawAutoTestWriteLegacyV1Block(const AFilePath,
  ACaptureKey: String; const APayloadKind: TCrashRawPayloadKind;
  const ACommitted: Boolean): Boolean;
{ Slot as CrashRawPrepare leaves it: valid header, zero stage/commit.
  AProcessID = 0 stamps the current process. }
function CrashRawAutoTestWritePristineBlock(const AFilePath,
  ACaptureKey: String; const APayloadKind: TCrashRawPayloadKind;
  const AProcessID: UInt64): Boolean;
{ Slot as CrashRawOpenPreallocated leaves it: block-sized and all zeros. }
function CrashRawAutoTestWriteZeroBlock(const AFilePath: String): Boolean;
procedure CrashRawAutoTestSetOwnerAliveProbe(
  const AProbe: TCrashRawOwnerAliveProbe);
{$ENDIF}

implementation

uses
  System.Classes,
  System.IOUtils,
  System.SyncObjs,
  System.DateUtils
  {$IF not Defined(MSWINDOWS)}
  , Posix.Fcntl,
  Posix.Signal,
  Posix.SysTypes,
  Posix.Unistd,
  Posix.Errno
  {$ENDIF};

const
  CRASH_RAW_MAGIC: array[0..7] of AnsiChar =
    ('C', 'R', 'S', 'H', 'R', 'A', 'W', '1');

{$IF not Defined(MSWINDOWS)}
const
  {$IF Defined(MACOS)}
  CRASH_RAW_O_CLOEXEC = $01000000;
  {$ELSE}
  CRASH_RAW_O_CLOEXEC = $00080000;
  {$ENDIF}
  CRASH_RAW_CREATE_MODE = $180; // 0600
  CRASH_RAW_MAX_IO_CALLS = 16;
  CRASH_RAW_MAX_FSYNC_CALLS = 4;
{$ENDIF}

var
  GRawFD: array[0..CRASH_RAW_SLOT_COUNT - 1] of Integer;
  GRawBlocks: array[0..CRASH_RAW_SLOT_COUNT - 1] of TCrashRawDiskBlockV2;
  GRawEntered: array[0..CRASH_RAW_SLOT_COUNT - 1] of Integer;
  GRawCommitted: array[0..CRASH_RAW_SLOT_COUNT - 1] of Integer;
  GRawPaths: array[0..CRASH_RAW_SLOT_COUNT - 1] of String;
  GRawKeys: array[0..CRASH_RAW_SLOT_COUNT - 1] of String;
  GRawReportDir: String;
  GRawScanPrefix: String;
  GRawAppName: String;
  GRawAppVersion: String;
  GRawCompilationTime: String;
  GRawExeName: String;
  GRawImageBase: UInt64;
  GRawImageSize: UInt64;
  GRawImageID: TCrashRawImageID;
  GRawEnabled: Boolean;
  GRawInitTick: UInt64;
  GRawInitUnixSeconds: Int64;
  GRawGeneration: UInt32;
  GRawStageByte: Byte = CRASH_RAW_STAGE_ENTERED;
  GRawCommitByte: Byte = CRASH_RAW_COMMIT;
  {$IFDEF AUTOTESTS}
  GRawOwnerAliveProbe: TCrashRawOwnerAliveProbe = nil;
  {$ENDIF}

function CrashRawSupported: Boolean;
begin
  {$IF (Defined(LINUX) and Defined(CPUX64)) or
       (Defined(ANDROID) and Defined(CPUARM64)) or
       (Defined(MACOS) and (Defined(CPUX64) or Defined(CPUARM64)))}
  Result := True;
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

function CrashRawPlatform: Byte;
begin
  {$IF Defined(LINUX)}
  Result := 1;
  {$ELSEIF Defined(ANDROID)}
  Result := 2;
  {$ELSEIF Defined(MACOS)}
  Result := 3;
  {$ELSE}
  Result := 0;
  {$ENDIF}
end;

function CrashRawArchitecture: Byte;
begin
  {$IF Defined(CPUX64)}
  Result := 1;
  {$ELSEIF Defined(CPUARM64)}
  Result := 2;
  {$ELSE}
  Result := 0;
  {$ENDIF}
end;

procedure CopyFixedUtf8(const AValue: String; ADest: Pointer;
  const ADestSize: Integer);
var
  Encoded: UTF8String;
  Count: Integer;
begin
  if (ADest = nil) or (ADestSize <= 0) then
    Exit;
  FillChar(ADest^, ADestSize, 0);
  Encoded := UTF8String(AValue);
  Count := Length(Encoded);
  if Count >= ADestSize then
    Count := ADestSize - 1;
  if Count > 0 then
    Move(PAnsiChar(Encoded)^, ADest^, Count);
end;

function FixedUtf8ToString(const AValue; const ASize: Integer): String;
var
  P: PAnsiChar;
  Count: Integer;
  Encoded: UTF8String;
begin
  P := @AValue;
  Count := 0;
  while (Count < ASize) and (P[Count] <> #0) do
    Inc(Count);
  SetString(Encoded, P, Count);
  Result := String(Encoded);
end;

function CrashRawBuildKey(const AGeneration: UInt32;
  const ASlot: Integer): String;
begin
  {$IF not Defined(MSWINDOWS)}
  Result := 'R2-' + IntToHex(UInt64(getpid), 8) + '-' +
    IntToHex(GRawInitTick, 16) + '-' + IntToHex(AGeneration, 8) + '-' +
    IntToStr(ASlot);
  {$ELSE}
  Result := '';
  {$ENDIF}
end;

procedure CrashRawFillTemplate(const ASlot: Integer;
  const AGeneration: UInt32; const AKey: String);
var
  PayloadKind, PayloadSize: Integer;
begin
  FillChar(GRawBlocks[ASlot], SizeOf(GRawBlocks[ASlot]), 0);
  Move(CRASH_RAW_MAGIC[0], GRawBlocks[ASlot].Header.Magic[0],
    SizeOf(CRASH_RAW_MAGIC));
  if ASlot = CRASH_RAW_SLOT_PRIMARY then
  begin
    PayloadKind := Ord(rpkPrimary);
    PayloadSize := SizeOf(TCrashRawPrimarySnapshot);
  end
  else
  begin
    PayloadKind := Ord(rpkConcurrent);
    PayloadSize := SizeOf(TCrashRawConcurrentSnapshot);
  end;
  GRawBlocks[ASlot].Header.Version := CRASH_RAW_VERSION;
  GRawBlocks[ASlot].Header.HeaderSize := SizeOf(TCrashRawHeaderV2);
  GRawBlocks[ASlot].Header.BlockSize := SizeOf(TCrashRawDiskBlockV2);
  GRawBlocks[ASlot].Header.PayloadSize := PayloadSize;
  GRawBlocks[ASlot].Header.PayloadKind := PayloadKind;
  GRawBlocks[ASlot].Header.SlotIndex := ASlot;
  GRawBlocks[ASlot].Header.Platform := CrashRawPlatform;
  GRawBlocks[ASlot].Header.Architecture := CrashRawArchitecture;
  {$IF not Defined(MSWINDOWS)}
  GRawBlocks[ASlot].Header.ProcessID := UInt64(getpid);
  {$ENDIF}
  GRawBlocks[ASlot].Header.InitTick := GRawInitTick;
  GRawBlocks[ASlot].Header.InitUnixSeconds := GRawInitUnixSeconds;
  GRawBlocks[ASlot].Header.Generation := AGeneration;
  CopyFixedUtf8(AKey, @GRawBlocks[ASlot].Header.CaptureKey[0],
    SizeOf(GRawBlocks[ASlot].Header.CaptureKey));
  CopyFixedUtf8(GRawAppName, @GRawBlocks[ASlot].Header.AppName[0],
    SizeOf(GRawBlocks[ASlot].Header.AppName));
  CopyFixedUtf8(GRawAppVersion, @GRawBlocks[ASlot].Header.AppVersion[0],
    SizeOf(GRawBlocks[ASlot].Header.AppVersion));
  CopyFixedUtf8(GRawCompilationTime,
    @GRawBlocks[ASlot].Header.CompilationTime[0],
    SizeOf(GRawBlocks[ASlot].Header.CompilationTime));
  CopyFixedUtf8(GRawExeName, @GRawBlocks[ASlot].Header.ExeName[0],
    SizeOf(GRawBlocks[ASlot].Header.ExeName));
  GRawBlocks[ASlot].Header.ImageBase := GRawImageBase;
  GRawBlocks[ASlot].Header.ImageSize := GRawImageSize;
  GRawBlocks[ASlot].Header.ImageID := GRawImageID;
end;

{$IF not Defined(MSWINDOWS)}
function CrashRawOpenPreallocated(const APath: String): Integer;
var
  Encoded: UTF8String;
  Attempt: Integer;
begin
  Encoded := UTF8String(APath);
  Attempt := 0;
  repeat
    Inc(Attempt);
    Result := __open(PAnsiChar(Encoded), O_WRONLY or O_CREAT or O_EXCL or
      CRASH_RAW_O_CLOEXEC, CRASH_RAW_CREATE_MODE);
  until (Result >= 0) or (errno <> EINTR) or (Attempt >= 4);
  if Result < 0 then
    Exit;
  Attempt := 0;
  repeat
    Inc(Attempt);
    if ftruncate(Result, SizeOf(TCrashRawDiskBlockV2)) = 0 then
      Exit;
  until (errno <> EINTR) or (Attempt >= 4);
  __close(Result);
  Result := -1;
  try
    TFile.Delete(APath);
  except
  end;
end;

function CrashRawWriteAll(const AFD: Integer; ABuffer: Pointer;
  const ACount: NativeUInt): Boolean;
var
  P: PByte;
  Remaining: NativeUInt;
  Written: IntPtr;
  Calls: Integer;
begin
  Result := False;
  if (AFD < 0) or (ABuffer = nil) then
    Exit;
  P := ABuffer;
  Remaining := ACount;
  Calls := 0;
  while (Remaining > 0) and (Calls < CRASH_RAW_MAX_IO_CALLS) do
  begin
    Inc(Calls);
    Written := __write(AFD, P, Remaining);
    if Written > 0 then
    begin
      Inc(P, NativeUInt(Written));
      Dec(Remaining, NativeUInt(Written));
    end
    else if not ((Written < 0) and (errno = EINTR)) then
      Exit;
  end;
  Result := Remaining = 0;
end;

function CrashRawFsync(const AFD: Integer): Boolean;
var
  RC, Calls: Integer;
begin
  Result := False;
  Calls := 0;
  repeat
    Inc(Calls);
    RC := fsync(AFD);
    if RC = 0 then
      Exit(True);
  until (errno <> EINTR) or (Calls >= CRASH_RAW_MAX_FSYNC_CALLS);
end;
{$ENDIF}

procedure CrashRawCloseCurrent;
var
  Slot: Integer;
  {$IF not Defined(MSWINDOWS)}
  FD: Integer;
  {$ENDIF}
begin
  for Slot := 0 to CRASH_RAW_SLOT_COUNT - 1 do
  begin
    {$IF not Defined(MSWINDOWS)}
    FD := TInterlocked.Exchange(GRawFD[Slot], -1);
    if FD >= 0 then
      __close(FD);
    {$ELSE}
    TInterlocked.Exchange(GRawFD[Slot], -1);
    {$ENDIF}
  end;
end;

procedure CrashRawDeleteCurrentFiles;
var
  Slot: Integer;
begin
  for Slot := 0 to CRASH_RAW_SLOT_COUNT - 1 do
  begin
    if GRawPaths[Slot] <> '' then
      CrashRawDeleteFile(GRawPaths[Slot]);
    GRawPaths[Slot] := '';
    GRawKeys[Slot] := '';
  end;
end;

procedure CrashRawForgetCurrentFiles;
var
  Slot: Integer;
begin
  for Slot := 0 to CRASH_RAW_SLOT_COUNT - 1 do
  begin
    GRawPaths[Slot] := '';
    GRawKeys[Slot] := '';
  end;
end;

function CrashRawPrepareCurrent: Boolean;
var
  Attempt, Slot: Integer;
  Generation: UInt32;
  Opened: Boolean;
begin
  Result := False;
  if (not GRawEnabled) or (not CrashRawSupported) then
    Exit;
  ForceDirectories(GRawReportDir);
  for Attempt := 1 to 16 do
  begin
    Inc(GRawGeneration);
    Generation := GRawGeneration;
    Opened := True;
    for Slot := 0 to CRASH_RAW_SLOT_COUNT - 1 do
    begin
      GRawKeys[Slot] := CrashRawBuildKey(Generation, Slot);
      GRawPaths[Slot] := IncludeTrailingPathDelimiter(GRawReportDir) +
        GRawScanPrefix + 'raw_' + GRawKeys[Slot] + '.crashraw';
      CrashRawFillTemplate(Slot, Generation, GRawKeys[Slot]);
      GRawEntered[Slot] := 0;
      GRawCommitted[Slot] := 0;
      {$IF not Defined(MSWINDOWS)}
      GRawFD[Slot] := CrashRawOpenPreallocated(GRawPaths[Slot]);
      {$ELSE}
      GRawFD[Slot] := -1;
      {$ENDIF}
      if GRawFD[Slot] < 0 then
      begin
        Opened := False;
        Break;
      end;
    end;
    if Opened then
      Exit(True);
    CrashRawCloseCurrent;
    CrashRawDeleteCurrentFiles;
  end;
end;

function CrashRawPrepare(const AReportDir, AScanPrefix, AAppName,
  AAppVersion, ACompilationTime, AExeName: String;
  const AImageBase, AImageSize: UInt64;
  const AImageID: TCrashRawImageID;
  const AEnabled: Boolean): Boolean;
begin
  CrashRawShutdown(True);
  GRawEnabled := AEnabled and CrashRawSupported;
  GRawReportDir := AReportDir;
  GRawScanPrefix := AScanPrefix;
  GRawAppName := AAppName;
  GRawAppVersion := AAppVersion;
  GRawCompilationTime := ACompilationTime;
  GRawExeName := AExeName;
  GRawImageBase := AImageBase;
  GRawImageSize := AImageSize;
  GRawImageID := AImageID;
  GRawInitTick := TThread.GetTickCount64;
  GRawInitUnixSeconds := DateTimeToUnix(Now, False);
  GRawGeneration := 0;
  Result := (not GRawEnabled) or CrashRawPrepareCurrent;
end;

procedure CrashRawRotate(const ADeleteCurrentFiles: Boolean);
begin
  CrashRawCloseCurrent;
  if ADeleteCurrentFiles then
    CrashRawDeleteCurrentFiles;
  if GRawEnabled then
    try
      CrashRawPrepareCurrent;
    except
      // Raw fallback is diagnostic; failure to rotate cannot break reporting.
    end;
end;

procedure CrashRawShutdown(const ADeleteCurrentFiles: Boolean);
begin
  CrashRawCloseCurrent;
  if ADeleteCurrentFiles then
    CrashRawDeleteCurrentFiles
  else
    CrashRawForgetCurrentFiles;
  GRawEnabled := False;
end;

procedure CrashRawBeginSlot(const ASlot: Integer);
begin
  {$IF not Defined(MSWINDOWS)}
  if (ASlot < 0) or (ASlot >= CRASH_RAW_SLOT_COUNT) or
     (GRawFD[ASlot] < 0) then
    Exit;
  if TInterlocked.CompareExchange(GRawEntered[ASlot], 1, 0) <> 0 then
    Exit;
  if not CrashRawWriteAll(GRawFD[ASlot], @GRawStageByte, 1) then
    TInterlocked.Exchange(GRawEntered[ASlot], -1);
  {$ENDIF}
end;

procedure CrashRawCommitSlot(const ASlot: Integer; APayload: Pointer;
  const APayloadSize: Integer);
begin
  {$IF not Defined(MSWINDOWS)}
  if (ASlot < 0) or (ASlot >= CRASH_RAW_SLOT_COUNT) or
     (GRawFD[ASlot] < 0) or (APayload = nil) or
     (APayloadSize <= 0) or (APayloadSize > CRASH_RAW_PAYLOAD_BYTES) then
    Exit;
  if TInterlocked.CompareExchange(GRawEntered[ASlot], 1, 1) <> 1 then
    Exit;
  Move(APayload^, GRawBlocks[ASlot].Payload[0], APayloadSize);
  if not CrashRawWriteAll(GRawFD[ASlot], @GRawBlocks[ASlot].Header,
       SizeOf(TCrashRawDiskBlockV2) - 2) then
    Exit;
  if not CrashRawFsync(GRawFD[ASlot]) then
    Exit;
  if not CrashRawWriteAll(GRawFD[ASlot], @GRawCommitByte, 1) then
    Exit;
  TInterlocked.Exchange(GRawCommitted[ASlot], 1);
  // Payload was durably flushed before the commit write. This final fsync makes
  // the commit durable too; if it fails, a later parser still accepts the file
  // only when the commit byte really survived.
  CrashRawFsync(GRawFD[ASlot]);
  {$ENDIF}
end;

procedure CrashRawCommitPrimary(const ASnapshot: TCrashRawPrimarySnapshot);
begin
  CrashRawCommitSlot(CRASH_RAW_SLOT_PRIMARY, @ASnapshot, SizeOf(ASnapshot));
end;

procedure CrashRawCommitConcurrent(
  const ASnapshot: TCrashRawConcurrentSnapshot);
begin
  CrashRawCommitSlot(CRASH_RAW_SLOT_CONCURRENT, @ASnapshot,
    SizeOf(ASnapshot));
end;

function CrashRawGetCommittedKey(const ASlot: Integer;
  out AKey: String): Boolean;
begin
  AKey := '';
  Result := (ASlot >= 0) and (ASlot < CRASH_RAW_SLOT_COUNT) and
    (TInterlocked.CompareExchange(GRawCommitted[ASlot], 1, 1) = 1);
  if Result then
    AKey := GRawKeys[ASlot];
end;

function CrashRawCurrentSlotsPrepared: Boolean;
begin
  if not CrashRawSupported then
    Exit(False);
  Result := (GRawFD[CRASH_RAW_SLOT_PRIMARY] >= 0) and
    (GRawFD[CRASH_RAW_SLOT_CONCURRENT] >= 0);
end;

function CrashRawDescriptorsCloseOnExec: Boolean;
{$IF not Defined(MSWINDOWS)}
var
  Slot, Flags: Integer;
{$ENDIF}
begin
  Result := True;
  {$IF not Defined(MSWINDOWS)}
  for Slot := 0 to CRASH_RAW_SLOT_COUNT - 1 do
  begin
    if GRawFD[Slot] < 0 then
      Continue;
    Flags := fcntl(GRawFD[Slot], F_GETFD);
    if (Flags < 0) or ((Flags and FD_CLOEXEC) = 0) then
      Exit(False);
  end;
  {$ENDIF}
end;

function CrashRawEnumerateFiles(const AReportDir,
  AScanPrefix: String): TArray<String>;
begin
  Result := nil;
  if AReportDir = '' then
    Exit;
  try
    Result := TDirectory.GetFiles(IncludeTrailingPathDelimiter(AReportDir),
      AScanPrefix + 'raw_*.crashraw');
  except
    Result := nil;
  end;
end;

function CrashRawInspectMarkers(const AFilePath: String;
  out AStage, ACommit: Byte): Boolean;
var
  Stream: TFileStream;
begin
  Result := False;
  AStage := 0;
  ACommit := 0;
  try
    Stream := TFileStream.Create(AFilePath, fmOpenRead or fmShareDenyNone);
    try
      if Stream.Size <> SizeOf(TCrashRawDiskBlockV2) then
        Exit;
      Stream.ReadBuffer(AStage, 1);
      Stream.Position := Stream.Size - 1;
      Stream.ReadBuffer(ACommit, 1);
      Result := True;
    finally
      Stream.Free;
    end;
  except
  end;
end;

function CrashRawReadBlock(const AFilePath: String;
  out ARecord: TCrashRawRecord): Boolean;
var
  Block: TCrashRawDiskBlockV2;
  Header: TCrashRawHeaderV1;
  Payload: PByte;
  PayloadCapacity: Integer;
  Stream: TFileStream;
  Key: String;
begin
  Result := False;
  ARecord := Default(TCrashRawRecord);
  FillChar(Block, SizeOf(Block), 0);
  try
    Stream := TFileStream.Create(AFilePath, fmOpenRead or fmShareDenyNone);
    try
      if Stream.Size <> SizeOf(Block) then
        Exit;
      Stream.ReadBuffer(Block, SizeOf(Block));
    finally
      Stream.Free;
    end;
  except
    Exit;
  end;
  { V1 and V2 have the same total size and the same common header prefix.
    Payload starts 32 bytes later in V2 because those bytes moved into the
    appended image-range and image-identity fields. }
  Move(Block.Header, Header, SizeOf(Header));
  if (Block.Stage <> CRASH_RAW_STAGE_ENTERED) or
     (Block.Commit <> CRASH_RAW_COMMIT) or
     (not CompareMem(@Header.Magic[0], @CRASH_RAW_MAGIC[0],
       SizeOf(CRASH_RAW_MAGIC))) or
     (Header.Platform <> CrashRawPlatform) or
     (Header.Architecture <> CrashRawArchitecture) or
     (Header.SlotIndex >= CRASH_RAW_SLOT_COUNT) or
     (Integer(Header.PayloadKind) < Ord(rpkPrimary)) or
     (Integer(Header.PayloadKind) > Ord(rpkConcurrent)) then
    Exit;
  case Header.Version of
    CRASH_RAW_VERSION_V1:
      begin
        if (Header.HeaderSize <> SizeOf(TCrashRawHeaderV1)) or
           (Header.BlockSize <> SizeOf(TCrashRawDiskBlockV1)) then
          Exit;
        Payload := PByte(@Block) + 1 + SizeOf(TCrashRawHeaderV1);
        PayloadCapacity := CRASH_RAW_V1_PAYLOAD_BYTES;
      end;
    CRASH_RAW_VERSION:
      begin
        if (Header.HeaderSize <> SizeOf(TCrashRawHeaderV2)) or
           (Header.BlockSize <> SizeOf(TCrashRawDiskBlockV2)) then
          Exit;
        Payload := @Block.Payload[0];
        PayloadCapacity := CRASH_RAW_PAYLOAD_BYTES;
      end;
  else
    Exit;
  end;
  if Header.PayloadSize > UInt32(PayloadCapacity) then
    Exit;
  Key := FixedUtf8ToString(Header.CaptureKey,
    SizeOf(Header.CaptureKey));
  if Key = '' then
    Exit;
  case TCrashRawPayloadKind(Header.PayloadKind) of
    rpkPrimary:
      begin
        if (Header.SlotIndex <> CRASH_RAW_SLOT_PRIMARY) or
           (Header.PayloadSize <> SizeOf(TCrashRawPrimarySnapshot)) then
          Exit;
        Move(Payload^, ARecord.Primary, SizeOf(ARecord.Primary));
        if (ARecord.Primary.Captured <> 1) or
           (ARecord.Primary.SignalNum <= 0) then
          Exit;
      end;
    rpkConcurrent:
      begin
        if (Header.SlotIndex <> CRASH_RAW_SLOT_CONCURRENT) or
           (Header.PayloadSize <> SizeOf(TCrashRawConcurrentSnapshot)) then
          Exit;
        Move(Payload^, ARecord.Concurrent, SizeOf(ARecord.Concurrent));
        if (ARecord.Concurrent.Captured <> 1) or
           (ARecord.Concurrent.SignalNum <= 0) then
          Exit;
      end;
  else
    Exit;
  end;
  ARecord.FilePath := AFilePath;
  ARecord.CaptureKey := Key;
  ARecord.AppName := FixedUtf8ToString(Header.AppName,
    SizeOf(Header.AppName));
  ARecord.AppVersion := FixedUtf8ToString(Header.AppVersion,
    SizeOf(Header.AppVersion));
  ARecord.CompilationTime := FixedUtf8ToString(
    Header.CompilationTime, SizeOf(Header.CompilationTime));
  ARecord.ExeName := FixedUtf8ToString(Header.ExeName,
    SizeOf(Header.ExeName));
  ARecord.ProcessID := Header.ProcessID;
  ARecord.InitTick := Header.InitTick;
  ARecord.InitUnixSeconds := Header.InitUnixSeconds;
  ARecord.Generation := Header.Generation;
  ARecord.FormatVersion := Header.Version;
  if Header.Version = CRASH_RAW_VERSION then
  begin
    ARecord.ImageBase := Block.Header.ImageBase;
    ARecord.ImageSize := Block.Header.ImageSize;
    ARecord.ImageID := Block.Header.ImageID;
  end;
  ARecord.PayloadKind := TCrashRawPayloadKind(Header.PayloadKind);
  Result := True;
end;

function CrashRawFileIsStale(const AFilePath: String): Boolean;
begin
  Result := False;
  try
    Result := TFile.GetLastWriteTime(AFilePath) <
      IncDay(Now, -CRASH_RAW_STALE_DAYS);
  except
  end;
end;

function CrashRawOwnerAlive(const AProcessID: UInt64): Boolean;
begin
  {$IFDEF AUTOTESTS}
  if Assigned(GRawOwnerAliveProbe) then
    Exit(GRawOwnerAliveProbe(AProcessID));
  {$ENDIF}
  Result := True;
  {$IF not Defined(MSWINDOWS)}
  // 0 would signal our own process group and a value past pid_t cannot be
  // asked about at all - both keep the file.
  if (AProcessID = 0) or (AProcessID > UInt64(High(Integer))) then
    Exit;
  if kill(pid_t(AProcessID), 0) = 0 then
    Exit;
  Result := errno <> ESRCH;
  {$ENDIF}
end;

function CrashRawFileCaptureKey(const AFilePath: String): String;
var
  Name: String;
  At: Integer;
begin
  // "<prefix>raw_<key>.crashraw"; the key itself carries no underscore.
  Name := ChangeFileExt(ExtractFileName(AFilePath), '');
  At := LastDelimiter('_', Name);
  if At <= 0 then
    Exit('');
  Result := Copy(Name, At + 1, MaxInt);
end;

function CrashRawKeyProcessID(const ACaptureKey: String): UInt64;
var
  Start, At: Integer;
begin
  Result := 0;
  if (Copy(ACaptureKey, 1, 3) <> 'R1-') and
     (Copy(ACaptureKey, 1, 3) <> 'R2-') then
    Exit;
  Start := 4;
  At := Start;
  while (At <= Length(ACaptureKey)) and (ACaptureKey[At] <> '-') do
    Inc(At);
  if At <= Start then
    Exit;
  Result := StrToUInt64Def('$' + Copy(ACaptureKey, Start, At - Start), 0);
end;

function CrashRawFileIsAbandoned(const AFilePath: String): Boolean;
var
  Block: TCrashRawDiskBlockV2;
  Header: TCrashRawHeaderV1;
  Stream: TFileStream;
  OwnerID: UInt64;
begin
  Result := False;
  FillChar(Block, SizeOf(Block), 0);
  try
    Stream := TFileStream.Create(AFilePath, fmOpenRead or fmShareDenyNone);
    try
      if Stream.Size <> SizeOf(Block) then
        Exit;
      Stream.ReadBuffer(Block, SizeOf(Block));
    finally
      Stream.Free;
    end;
  except
    Exit;
  end;
  Move(Block.Header, Header, SizeOf(Header));
  if (Block.Stage <> 0) or (Block.Commit <> 0) then
    Exit;
  if CompareMem(@Header.Magic[0], @CRASH_RAW_MAGIC[0],
       SizeOf(CRASH_RAW_MAGIC)) and
     ((Header.Version = CRASH_RAW_VERSION_V1) or
      (Header.Version = CRASH_RAW_VERSION)) then
    OwnerID := Header.ProcessID
  else
  begin
    // Preallocated and never written: ftruncate leaves the whole block zeroed,
    // so the owner is only in the capture key the file is named after.
    OwnerID := CrashRawKeyProcessID(CrashRawFileCaptureKey(AFilePath));
    if OwnerID = 0 then
      Exit;
  end;
  Result := not CrashRawOwnerAlive(OwnerID);
end;

procedure CrashRawDeleteFile(const AFilePath: String);
begin
  if AFilePath = '' then
    Exit;
  try
    if TFile.Exists(AFilePath) then
      TFile.Delete(AFilePath);
  except
  end;
end;

procedure CrashRawDeleteUntouchedSibling(const ARaw: TCrashRawRecord);
var
  BaseKey, SiblingKey, SiblingPath: String;
  DashAt: Integer;
  Stage, Commit: Byte;
begin
  DashAt := LastDelimiter('-', ARaw.CaptureKey);
  if (DashAt <= 0) or (ARaw.FilePath = '') then
    Exit;
  BaseKey := Copy(ARaw.CaptureKey, 1, DashAt);
  if ARaw.PayloadKind = rpkPrimary then
    SiblingKey := BaseKey + '1'
  else if ARaw.PayloadKind = rpkConcurrent then
    SiblingKey := BaseKey + '0'
  else
    Exit;
  SiblingPath := StringReplace(ARaw.FilePath, ARaw.CaptureKey, SiblingKey, []);
  if CrashRawInspectMarkers(SiblingPath, Stage, Commit) and
     (Stage = 0) and (Commit = 0) then
    CrashRawDeleteFile(SiblingPath);
end;

function CrashRawPrimaryIP(const APrimary: TCrashRawPrimarySnapshot): UInt64;
begin
  {$IF Defined(CPUX64)}
  Result := APrimary.Rip;
  {$ELSEIF Defined(CPUARM64)}
  Result := APrimary.Pc;
  {$ELSE}
  Result := 0;
  {$ENDIF}
end;

function CrashRawPrimarySP(const APrimary: TCrashRawPrimarySnapshot): UInt64;
begin
  {$IF Defined(CPUX64)}
  Result := APrimary.Rsp;
  {$ELSEIF Defined(CPUARM64)}
  Result := APrimary.Sp;
  {$ELSE}
  Result := 0;
  {$ENDIF}
end;

function CrashRawPrimaryFP(const APrimary: TCrashRawPrimarySnapshot): UInt64;
begin
  {$IF Defined(CPUX64)}
  Result := APrimary.Rbp;
  {$ELSEIF Defined(CPUARM64)}
  Result := APrimary.Fp;
  {$ELSE}
  Result := 0;
  {$ENDIF}
end;

function CrashRawImageIDPresent(const AImageID: TCrashRawImageID): Boolean;
var
  I: Integer;
begin
  for I := Low(AImageID) to High(AImageID) do
    if AImageID[I] <> 0 then
      Exit(True);
  Result := False;
end;

function CrashRawTryRebaseAddress(const ARaw: TCrashRawRecord;
  const AAddress, ACurrentImageBase, ACurrentImageSize: UInt64;
  const ACurrentImageID: TCrashRawImageID;
  const ACurrentCompilationTime: String;
  out ARebasedAddress, AModuleOffset: UInt64): Boolean;
begin
  Result := False;
  ARebasedAddress := 0;
  AModuleOffset := 0;
  if (ARaw.FormatVersion < CRASH_RAW_VERSION) or
     (ARaw.ImageBase = 0) or (ARaw.ImageSize = 0) or
     (ACurrentImageBase = 0) or (ACurrentImageSize = 0) or
     (AAddress < ARaw.ImageBase) then
    Exit;
  if CrashRawImageIDPresent(ARaw.ImageID) then
  begin
    if (not CrashRawImageIDPresent(ACurrentImageID)) or
       (not CompareMem(@ARaw.ImageID[0], @ACurrentImageID[0],
         SizeOf(ARaw.ImageID))) then
      Exit;
  end
  else if (ARaw.CompilationTime = '') or (ACurrentCompilationTime = '') or
          (ARaw.CompilationTime <> ACurrentCompilationTime) then
    Exit;
  AModuleOffset := AAddress - ARaw.ImageBase;
  if (AModuleOffset >= ARaw.ImageSize) or
     (AModuleOffset >= ACurrentImageSize) or
     (ACurrentImageBase > High(UInt64) - AModuleOffset) then
  begin
    AModuleOffset := 0;
    Exit;
  end;
  ARebasedAddress := ACurrentImageBase + AModuleOffset;
  Result := True;
end;

{$IFDEF AUTOTESTS}
function CrashRawAutoTestWriteBlock(const AFilePath, ACaptureKey: String;
  const APayloadKind: TCrashRawPayloadKind;
  const ACommitted: Boolean): Boolean;
var
  Block: TCrashRawDiskBlockV2;
  Primary: TCrashRawPrimarySnapshot;
  Concurrent: TCrashRawConcurrentSnapshot;
  Stream: TFileStream;
  I: Integer;
begin
  Result := False;
  FillChar(Block, SizeOf(Block), 0);
  Move(CRASH_RAW_MAGIC[0], Block.Header.Magic[0], SizeOf(CRASH_RAW_MAGIC));
  Block.Stage := CRASH_RAW_STAGE_ENTERED;
  Block.Header.Version := CRASH_RAW_VERSION;
  Block.Header.HeaderSize := SizeOf(TCrashRawHeaderV2);
  Block.Header.BlockSize := SizeOf(TCrashRawDiskBlockV2);
  Block.Header.PayloadKind := Ord(APayloadKind);
  Block.Header.Platform := CrashRawPlatform;
  Block.Header.Architecture := CrashRawArchitecture;
  Block.Header.ProcessID := 1234;
  Block.Header.InitTick := 5678;
  Block.Header.InitUnixSeconds := DateTimeToUnix(Now, False);
  Block.Header.Generation := 9;
  CopyFixedUtf8(ACaptureKey, @Block.Header.CaptureKey[0],
    SizeOf(Block.Header.CaptureKey));
  CopyFixedUtf8('RawFixture', @Block.Header.AppName[0],
    SizeOf(Block.Header.AppName));
  CopyFixedUtf8('1.2.3.4', @Block.Header.AppVersion[0],
    SizeOf(Block.Header.AppVersion));
  CopyFixedUtf8('fixture-build', @Block.Header.CompilationTime[0],
    SizeOf(Block.Header.CompilationTime));
  CopyFixedUtf8('fixture-exe', @Block.Header.ExeName[0],
    SizeOf(Block.Header.ExeName));
  Block.Header.ImageBase := $0000007100000000;
  Block.Header.ImageSize := $02000000;
  for I := Low(Block.Header.ImageID) to High(Block.Header.ImageID) do
    Block.Header.ImageID[I] := Byte(I + 1);
  if APayloadKind = rpkPrimary then
  begin
    Block.Header.SlotIndex := CRASH_RAW_SLOT_PRIMARY;
    Block.Header.PayloadSize := SizeOf(Primary);
    FillChar(Primary, SizeOf(Primary), 0);
    Primary.Claimed := 1;
    Primary.Captured := 1;
    Primary.InvocationCount := 1;
    Primary.SignalNum := 11;
    Primary.SignalCode := 1;
    Primary.FaultAddr := $DEADBEEF;
    Primary.ThreadID := 42;
    {$IF Defined(CPUX64)}
    Primary.Kind := Ord(skLinuxX64);
    Primary.Rip := $1122334455667788;
    Primary.Rsp := $8877665544332211;
    Primary.Rbp := $1234567890ABCDEF;
    {$ELSEIF Defined(CPUARM64)}
    Primary.Kind := Ord(skLinuxArm64);
    Primary.Pc := $1122334455667788;
    Primary.Sp := $8877665544332211;
    Primary.Fp := $1234567890ABCDEF;
    {$ENDIF}
    Move(Primary, Block.Payload[0], SizeOf(Primary));
  end
  else if APayloadKind = rpkConcurrent then
  begin
    Block.Header.SlotIndex := CRASH_RAW_SLOT_CONCURRENT;
    Block.Header.PayloadSize := SizeOf(Concurrent);
    FillChar(Concurrent, SizeOf(Concurrent), 0);
    Concurrent.Claimed := 1;
    Concurrent.Captured := 1;
    Concurrent.Epoch := 3;
    Concurrent.SignalNum := 7;
    Concurrent.SignalCode := 2;
    Concurrent.FaultAddr := $ABCD;
    Concurrent.IP := $1020304050607080;
    Concurrent.ThreadID := 84;
    Move(Concurrent, Block.Payload[0], SizeOf(Concurrent));
  end
  else
    Exit;
  if ACommitted then
    Block.Commit := CRASH_RAW_COMMIT;
  try
    Stream := TFileStream.Create(AFilePath, fmCreate or fmShareDenyNone);
    try
      Stream.WriteBuffer(Block, SizeOf(Block));
      Result := True;
    finally
      Stream.Free;
    end;
  except
  end;
end;

function CrashRawAutoTestWriteLegacyV1Block(const AFilePath,
  ACaptureKey: String; const APayloadKind: TCrashRawPayloadKind;
  const ACommitted: Boolean): Boolean;
var
  Current: TCrashRawDiskBlockV2;
  Legacy: TCrashRawDiskBlockV1;
  Stream: TFileStream;
begin
  Result := False;
  if not CrashRawAutoTestWriteBlock(AFilePath, ACaptureKey, APayloadKind,
       ACommitted) then
    Exit;
  FillChar(Current, SizeOf(Current), 0);
  FillChar(Legacy, SizeOf(Legacy), 0);
  try
    Stream := TFileStream.Create(AFilePath, fmOpenRead or fmShareDenyNone);
    try
      Stream.ReadBuffer(Current, SizeOf(Current));
    finally
      Stream.Free;
    end;
    Legacy.Stage := Current.Stage;
    Move(Current.Header, Legacy.Header, SizeOf(Legacy.Header));
    Legacy.Header.Version := CRASH_RAW_VERSION_V1;
    Legacy.Header.HeaderSize := SizeOf(TCrashRawHeaderV1);
    Legacy.Header.BlockSize := SizeOf(TCrashRawDiskBlockV1);
    Move(Current.Payload[0], Legacy.Payload[0], Current.Header.PayloadSize);
    Legacy.Commit := Current.Commit;
    Stream := TFileStream.Create(AFilePath, fmCreate or fmShareDenyNone);
    try
      Stream.WriteBuffer(Legacy, SizeOf(Legacy));
      Result := True;
    finally
      Stream.Free;
    end;
  except
    Result := False;
  end;
end;

function CrashRawAutoTestWritePristineBlock(const AFilePath,
  ACaptureKey: String; const APayloadKind: TCrashRawPayloadKind;
  const AProcessID: UInt64): Boolean;
var
  Block: TCrashRawDiskBlockV2;
  Stream: TFileStream;
begin
  Result := False;
  FillChar(Block, SizeOf(Block), 0);
  Move(CRASH_RAW_MAGIC[0], Block.Header.Magic[0], SizeOf(CRASH_RAW_MAGIC));
  Block.Header.Version := CRASH_RAW_VERSION;
  Block.Header.HeaderSize := SizeOf(TCrashRawHeaderV2);
  Block.Header.BlockSize := SizeOf(TCrashRawDiskBlockV2);
  Block.Header.PayloadKind := Ord(APayloadKind);
  Block.Header.Platform := CrashRawPlatform;
  Block.Header.Architecture := CrashRawArchitecture;
  if APayloadKind = rpkPrimary then
  begin
    Block.Header.SlotIndex := CRASH_RAW_SLOT_PRIMARY;
    Block.Header.PayloadSize := SizeOf(TCrashRawPrimarySnapshot);
  end
  else
  begin
    Block.Header.SlotIndex := CRASH_RAW_SLOT_CONCURRENT;
    Block.Header.PayloadSize := SizeOf(TCrashRawConcurrentSnapshot);
  end;
  Block.Header.ProcessID := AProcessID;
  {$IF not Defined(MSWINDOWS)}
  if Block.Header.ProcessID = 0 then
    Block.Header.ProcessID := UInt64(getpid);
  {$ENDIF}
  Block.Header.InitTick := 5678;
  Block.Header.InitUnixSeconds := DateTimeToUnix(Now, False);
  Block.Header.Generation := 9;
  CopyFixedUtf8(ACaptureKey, @Block.Header.CaptureKey[0],
    SizeOf(Block.Header.CaptureKey));
  CopyFixedUtf8('RawFixture', @Block.Header.AppName[0],
    SizeOf(Block.Header.AppName));
  Block.Header.ImageBase := $0000007100000000;
  Block.Header.ImageSize := $02000000;
  try
    Stream := TFileStream.Create(AFilePath, fmCreate or fmShareDenyNone);
    try
      Stream.WriteBuffer(Block, SizeOf(Block));
      Result := True;
    finally
      Stream.Free;
    end;
  except
  end;
end;

function CrashRawAutoTestWriteZeroBlock(const AFilePath: String): Boolean;
var
  Block: TCrashRawDiskBlockV2;
  Stream: TFileStream;
begin
  Result := False;
  FillChar(Block, SizeOf(Block), 0);
  try
    Stream := TFileStream.Create(AFilePath, fmCreate or fmShareDenyNone);
    try
      Stream.WriteBuffer(Block, SizeOf(Block));
      Result := True;
    finally
      Stream.Free;
    end;
  except
  end;
end;

procedure CrashRawAutoTestSetOwnerAliveProbe(
  const AProbe: TCrashRawOwnerAliveProbe);
begin
  GRawOwnerAliveProbe := AProbe;
end;
{$ENDIF}

initialization
  GRawFD[0] := -1;
  GRawFD[1] := -1;

finalization
  CrashRawShutdown(True);

end.
