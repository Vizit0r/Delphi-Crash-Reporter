unit Crash.Modules;

{ Enumerates loaded modules (shared libs + main exe) for the .el "Modules"
  section, byte-perfect with EurekaLog TEurekaModulesFormatter layout
  (see EModules.pas/CalculateLengths/FormatLine/GetStrings):

    7 columns, pipe-separated: Handle | Name | Description | Version | Size |
    Last Modified | Path. Caption header line ("Modules:") - sole responsibility
    of the caller (this unit returns only the table). All cells right-padded
    to max width per column. Dashes-line above/between header and below.

  Part of the Crash Reporter library - standalone, EurekaLog-compatible
  crash/exception reporting for Delphi cross-platform targets.

  Sources:
    - Linux/Android: read /proc/self/maps via POSIX read() into a fixed buffer,
        parse in-place. Multiple segments per file are merged: base=min(start),
        size=max(end)-min(start). We avoid TStringList.LoadFromFile because
        /proc files don't report a size and that path has hung inside crash
        propagation under WSL.
    - macOS:         dyld public API. Size summed from LC_SEGMENT_64.vmsize.
    - Windows:       not implemented (intentionally skipped). }

interface

type
  TModuleInfo = record
    Name:        String;   // basename
    Path:        String;   // full path
    Description: String;   // empty on POSIX (no cheap source)
    BaseAddr:    UInt64;   // load base in process VAS
    Size:        UInt64;   // bytes (0 if unknown)
    Version:     String;   // empty if unknown
    LastModified:String;   // empty if unknown
  end;
  TModuleInfoArray = array of TModuleInfo;

  { A currently readable executable mapping. Kept separate from TModuleInfo:
    module rows deliberately merge mappings for EL display, while instruction
    validation must preserve the kernel's per-segment access rights. }
  TCrashExecutableRange = record
    LowAddress: UIntPtr;   // inclusive
    HighAddress: UIntPtr;  // exclusive
  end;
  TCrashExecutableRanges = TArray<TCrashExecutableRange>;

function CrashEnumerateModules: TModuleInfoArray;
function CrashEnumerateReadableExecutableRanges: TCrashExecutableRanges;
function CrashTryReadProcessMemory(const AAddress: UIntPtr; ABuffer: Pointer;
  const ASize: NativeUInt): Boolean;

// EL-compatible Modules table body (without the "Modules:" caption header line -
// caller adds that). Returns '' when AModules is empty.
function CrashFormatModulesTable(const AModules: TModuleInfoArray): String;

implementation

uses
  System.SysUtils
  {$IF Defined(LINUX) or Defined(ANDROID)}
  , Posix.Base, Posix.Fcntl, Posix.Unistd, Posix.Errno, Posix.SysTypes,
    Posix.SysUio
  {$ENDIF}
  ;

const
  CRLF = #13#10;

// ---------- EL-style formatting helpers ----------

function FmtPad(const S: String; W: Integer): String; inline;
begin
  if Length(S) >= W then Result := S
  else                   Result := S + StringOfChar(' ', W - Length(S));
end;

function FmtHex16(V: UInt64): String; inline;
begin
  Result := Format('%.16x', [V]);
end;

function CrashFormatModulesTable(const AModules: TModuleInfoArray): String;
const
  CapHandle  = 'Handle';
  CapName    = 'Name';
  CapDescr   = 'Description';
  CapVersion = 'Version';
  CapSize    = 'Size';
  CapModif   = 'Last Modified';
  CapPath    = 'Path';
var
  SB:                                                       TStringBuilder;
  MaxH, MaxN, MaxD, MaxV, MaxS, MaxM, MaxP, FLineLen:       Integer;
  M:                                                        TModuleInfo;
  SizeS:                                                    String;
  LineStr:                                                  String;

  function Row(const H, N, D, V, S, Mf, P: String): String;
  begin
    Result := '|' + FmtPad(H, MaxH) + '|' + FmtPad(N, MaxN) +
              '|' + FmtPad(D, MaxD) + '|' + FmtPad(V, MaxV) +
              '|' + FmtPad(S, MaxS) + '|' + FmtPad(Mf, MaxM) +
              '|' + FmtPad(P, MaxP) + '|';
  end;

begin
  if Length(AModules) = 0 then Exit('');

  // Init max widths from captions.
  MaxH := Length(CapHandle);   if MaxH < SizeOf(Pointer) * 2 then MaxH := SizeOf(Pointer) * 2;
  MaxN := Length(CapName);
  MaxD := Length(CapDescr);
  MaxV := Length(CapVersion);
  MaxS := Length(CapSize);
  MaxM := Length(CapModif);
  MaxP := Length(CapPath);

  // Grow by data.
  for M in AModules do
  begin
    if Length(M.Name)         > MaxN then MaxN := Length(M.Name);
    if Length(M.Description)  > MaxD then MaxD := Length(M.Description);
    if Length(M.Version)      > MaxV then MaxV := Length(M.Version);
    SizeS := IntToStr(M.Size);
    if Length(SizeS)          > MaxS then MaxS := Length(SizeS);
    if Length(M.LastModified) > MaxM then MaxM := Length(M.LastModified);
    if Length(M.Path)         > MaxP then MaxP := Length(M.Path);
  end;

  // FLineLen = sum + 8 pipes (see EModules.pas:1116-1117).
  FLineLen := MaxH + MaxN + MaxD + MaxV + MaxS + MaxM + MaxP + 8;
  LineStr  := StringOfChar('-', FLineLen);

  SB := TStringBuilder.Create;
  try
    SB.Append(LineStr); SB.Append(CRLF);
    SB.Append(Row(CapHandle, CapName, CapDescr, CapVersion, CapSize, CapModif, CapPath));
    SB.Append(CRLF);
    SB.Append(LineStr); SB.Append(CRLF);
    for M in AModules do
    begin
      SB.Append(Row(FmtHex16(M.BaseAddr), M.Name, M.Description, M.Version,
                    IntToStr(M.Size), M.LastModified, M.Path));
      SB.Append(CRLF);
    end;
    SB.Append(LineStr); SB.Append(CRLF);
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

// =========================================================================
//                            LINUX / ANDROID
// =========================================================================
{$IF Defined(LINUX) or Defined(ANDROID)}

function ReadMapsFile(out Buffer: TBytes): Boolean;
// POSIX read of /proc/self/maps into a byte buffer. The file is a pseudo-file
// with no known size - read in chunks. Avoid TStringList.LoadFromFile: it does
// size detection (Stream.Size) which returns 0 for /proc and truncates the read.
const
  ChunkSize = 16 * 1024;
var
  Fd, N, Total: Integer;
begin
  Result := False;
  Buffer := nil;
  Total := 0;
  Fd := __open('/proc/self/maps', O_RDONLY);
  if Fd < 0 then Exit;
  try
    SetLength(Buffer, ChunkSize);
    // Loop until EOF (N=0) or error (N<0). Do NOT stop on a partial read
    // (N < ChunkSize): /proc files routinely return part of the data while more
    // is available - there is no stat size, the kernel returns whatever is
    // convenient.
    repeat
      if Length(Buffer) - Total < ChunkSize then
        SetLength(Buffer, Length(Buffer) + ChunkSize);
      repeat
        N := __read(Fd, @Buffer[Total], ChunkSize);
      until (N >= 0) or (errno <> EINTR); // a signal mid-read must not truncate the module list
      if N <= 0 then Break;
      Inc(Total, N);
    until False;
    SetLength(Buffer, Total);
    Result := Total > 0;
  finally
    __close(Fd);
  end;
end;

function ParseHex64(const S: String): UInt64;
var
  I:   Integer;
  Ch:  Char;
begin
  Result := 0;
  for I := 1 to Length(S) do
  begin
    Ch := S[I];
    case Ch of
      '0'..'9': Result := (Result shl 4) or UInt64(Ord(Ch) - Ord('0'));
      'a'..'f': Result := (Result shl 4) or UInt64(Ord(Ch) - Ord('a') + 10);
      'A'..'F': Result := (Result shl 4) or UInt64(Ord(Ch) - Ord('A') + 10);
    else
      Exit;
    end;
  end;
end;

function ParseMapsLine(const Line: String;
  out StartA, EndA: UInt64; out Perms, Path: String): Boolean;
// "<hex_start>-<hex_end> <perms> <hex_offset> <dev> <inode> <pathname>"
// Pathname is optional (anonymous mmap) and may contain spaces. Callers decide
// whether pseudo-paths such as [stack]/[vdso] are useful for their purpose.
var
  P, LineLen, Field, FieldStart: Integer;
  Dash:                          Integer;
begin
  Result := False;
  StartA := 0; EndA := 0; Perms := ''; Path := '';
  LineLen := Length(Line);
  if LineLen < 16 then Exit;

  Dash := Pos('-', Line);
  if Dash <= 1 then Exit;
  StartA := ParseHex64(Copy(Line, 1, Dash - 1));

  P := Dash + 1;
  while (P <= LineLen) and (Line[P] <> ' ') do Inc(P);
  EndA := ParseHex64(Copy(Line, Dash + 1, P - Dash - 1));

  // Capture perms, then skip offset, dev and inode.
  while (P <= LineLen) and (Line[P] = ' ') do Inc(P);
  FieldStart := P;
  while (P <= LineLen) and (Line[P] <> ' ') do Inc(P);
  Perms := Copy(Line, FieldStart, P - FieldStart);
  for Field := 1 to 3 do
  begin
    while (P <= LineLen) and (Line[P] = ' ') do Inc(P);
    while (P <= LineLen) and (Line[P] <> ' ') do Inc(P);
  end;
  while (P <= LineLen) and (Line[P] = ' ') do Inc(P);
  if P <= LineLen then
    Path := Copy(Line, P, LineLen - P + 1);

  Result := (StartA < EndA) and (Perms <> '');
end;

function FindOrAdd(var Arr: TModuleInfoArray; const Path: String): Integer;
var
  I: Integer;
begin
  for I := 0 to High(Arr) do
    if Arr[I].Path = Path then Exit(I);
  Result := Length(Arr);
  SetLength(Arr, Result + 1);
  Arr[Result] := Default(TModuleInfo);
  Arr[Result].Path := Path;
  Arr[Result].Name := ExtractFileName(Path);
end;

function CrashEnumerateModules: TModuleInfoArray;
var
  Buf:                    TBytes;
  Text, Line:             String;
  Cursor, NextLF, Stop:   Integer;
  StartA, EndA:           UInt64;
  Perms, Path:            String;
  Idx:                    Integer;
begin
  Result := nil;
  if not ReadMapsFile(Buf) then Exit;
  Text := TEncoding.UTF8.GetString(Buf);
  Cursor := 1;
  Stop := Length(Text);
  while Cursor <= Stop do
  begin
    NextLF := Cursor;
    while (NextLF <= Stop) and (Text[NextLF] <> #10) do Inc(NextLF);
    Line := Copy(Text, Cursor, NextLF - Cursor);
    if ParseMapsLine(Line, StartA, EndA, Perms, Path) and
       (Path <> '') and (Path[1] <> '[') then
    begin
      Idx := FindOrAdd(Result, Path);
      if (Result[Idx].BaseAddr = 0) or (StartA < Result[Idx].BaseAddr) then
        Result[Idx].BaseAddr := StartA;
      if EndA > Result[Idx].BaseAddr + Result[Idx].Size then
        Result[Idx].Size := EndA - Result[Idx].BaseAddr;
    end;
    Cursor := NextLF + 1;
  end;
end;

function CrashEnumerateReadableExecutableRanges: TCrashExecutableRanges;
var
  Buf:                    TBytes;
  Text, Line:             String;
  Cursor, NextLF, Stop:   Integer;
  StartA, EndA:           UInt64;
  Perms, Path:            String;
  Idx:                    Integer;
begin
  Result := nil;
  if not ReadMapsFile(Buf) then
    Exit;
  Text := TEncoding.UTF8.GetString(Buf);
  Cursor := 1;
  Stop := Length(Text);
  while Cursor <= Stop do
  begin
    NextLF := Cursor;
    while (NextLF <= Stop) and (Text[NextLF] <> #10) do
      Inc(NextLF);
    Line := Copy(Text, Cursor, NextLF - Cursor);
    if ParseMapsLine(Line, StartA, EndA, Perms, Path) and
       (Length(Perms) >= 3) and (Perms[1] = 'r') and
       (Perms[3] = 'x') then
    begin
      Idx := Length(Result);
      SetLength(Result, Idx + 1);
      Result[Idx].LowAddress := UIntPtr(StartA);
      Result[Idx].HighAddress := UIntPtr(EndA);
    end;
    Cursor := NextLF + 1;
  end;
end;

function crash_process_vm_readv(APid: pid_t; ALocalIOV: Piovec;
  ALocalCount: NativeUInt; ARemoteIOV: Piovec; ARemoteCount: NativeUInt;
  AFlags: NativeUInt): NativeInt; cdecl;
  external libc name _PU + 'process_vm_readv';

function CrashTryReadProcessMemory(const AAddress: UIntPtr; ABuffer: Pointer;
  const ASize: NativeUInt): Boolean;
var
  LocalIOV, RemoteIOV: iovec;
  ReadCount: NativeInt;
  Attempt: Integer;
begin
  Result := ASize = 0;
  if Result then
    Exit;
  if (AAddress = 0) or (ABuffer = nil) then
    Exit(False);
  LocalIOV.iov_base := ABuffer;
  LocalIOV.iov_len := ASize;
  RemoteIOV.iov_base := Pointer(AAddress);
  RemoteIOV.iov_len := ASize;
  for Attempt := 0 to 2 do
  begin
    ReadCount := crash_process_vm_readv(getpid, @LocalIOV, 1,
      @RemoteIOV, 1, 0);
    if ReadCount = NativeInt(ASize) then
      Exit(True);
    if (ReadCount >= 0) or (errno <> EINTR) then
      Exit(False);
  end;
end;

// =========================================================================
//                                  macOS
// =========================================================================
{$ELSEIF Defined(MACOS)}

const
  libdyld = '/usr/lib/system/libdyld.dylib';

function _dyld_image_count: UInt32; cdecl;
  external libdyld name '_dyld_image_count';
function _dyld_get_image_name(image_index: UInt32): MarshaledAString; cdecl;
  external libdyld name '_dyld_get_image_name';
function _dyld_get_image_header(image_index: UInt32): Pointer; cdecl;
  external libdyld name '_dyld_get_image_header';

type
  Pmach_header_64 = ^Tmach_header_64;
  Tmach_header_64 = packed record
    magic, cputype, cpusubtype, filetype,
    ncmds, sizeofcmds, flags, reserved: UInt32;
  end;

  Pload_command = ^Tload_command;
  Tload_command = packed record
    cmd, cmdsize: UInt32;
  end;

  Psegment_command_64 = ^Tsegment_command_64;
  Tsegment_command_64 = packed record
    cmd, cmdsize: UInt32;
    segname:      array[0..15] of AnsiChar;
    vmaddr, vmsize, fileoff, filesize: UInt64;
    maxprot, initprot, nsects, flags:  UInt32;
  end;

const
  LC_SEGMENT_64 = $19;

function SumSegmentSizes(Header: Pmach_header_64): UInt64;
var
  P:   PByte;
  LC:  Pload_command;
  Seg: Psegment_command_64;
  I:   UInt32;
begin
  Result := 0;
  if Header = nil then Exit;
  P := PByte(Header) + SizeOf(Tmach_header_64);
  for I := 1 to Header.ncmds do
  begin
    LC := Pload_command(P);
    if LC.cmdsize = 0 then Break; // malformed image - avoid an infinite walk
    if LC.cmd = LC_SEGMENT_64 then
    begin
      Seg := Psegment_command_64(P);
      Inc(Result, Seg.vmsize);
    end;
    Inc(P, LC.cmdsize);
  end;
end;

function CrashEnumerateModules: TModuleInfoArray;
var
  Count, I:   UInt32;
  NameC:      MarshaledAString;
  Header:     Pmach_header_64;
  M:          TModuleInfo;
begin
  Result := nil;
  Count := _dyld_image_count;
  SetLength(Result, Count);
  for I := 0 to Count - 1 do
  begin
    M := Default(TModuleInfo);
    NameC  := _dyld_get_image_name(I);
    Header := _dyld_get_image_header(I);
    if NameC <> nil then
    begin
      M.Path := String(AnsiString(NameC));
      M.Name := ExtractFileName(M.Path);
    end;
    M.BaseAddr := UInt64(NativeUInt(Header));
    M.Size     := SumSegmentSizes(Header);
    Result[I]  := M;
  end;
end;

function CrashEnumerateReadableExecutableRanges: TCrashExecutableRanges;
begin
  Result := nil;
end;

function CrashTryReadProcessMemory(const AAddress: UIntPtr; ABuffer: Pointer;
  const ASize: NativeUInt): Boolean;
begin
  Result := False;
end;

// =========================================================================
//                              ELSE (Win, etc.)
// =========================================================================
{$ELSE}

function CrashEnumerateModules: TModuleInfoArray;
begin
  Result := nil;
end;

function CrashEnumerateReadableExecutableRanges: TCrashExecutableRanges;
begin
  Result := nil;
end;

function CrashTryReadProcessMemory(const AAddress: UIntPtr; ABuffer: Pointer;
  const ASize: NativeUInt): Boolean;
begin
  Result := False;
end;

{$ENDIF}

end.
