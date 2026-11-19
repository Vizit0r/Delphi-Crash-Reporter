unit Crash.SymbolFile;

{ Reader of the .gosym side-file: an offline address -> function-name map for a
  stripped ELF image.

  Part of the Crash Reporter library - standalone, EurekaLog-compatible
  crash/exception reporting for Delphi cross-platform targets.

  The .gosym is generated from the UNSTRIPPED image's .symtab (by LNG_ELF, or by
  Tools\gen-android-symfile.ps1) and keyed by the first 16 bytes of the ELF
  .note.gnu.build-id, so a side-file of another build is refused rather than
  producing wrong names. Platform-free: the callers find and read the file,
  translate runtime addresses to link-time ones, and demangle the names.

  Format v2 (little-endian):
    Header (48 bytes):
      UInt32 Signature  = 'GOSY' ($59534F47)
      UInt32 Version    = $00020000
      UInt32 Size       = total file size
      UInt32 Count      = number of symbol entries
      Byte[16] BuildId
      UInt32 StrTabOff  / UInt32 StrTabSize   (mangled-name string table)
      UInt32 FileTabOff / UInt32 FileTabSize  (source-file string table)
    Entries[Count] (sorted by Addr), 20 bytes each:
      UInt64 Addr | UInt32 Size | UInt32 NameOff | UInt32 FileOff
    StrTab  : NUL-terminated mangled names
    FileTab : NUL-terminated source file names (offset 0 = "" = unknown)

  Copyright (c) 2026 Vizit0r. BSD 2-Clause license (see LICENSE.txt). }

interface

uses
  System.SysUtils;

const
  CRASH_GOSYM_SIGNATURE   = $59534F47; // 'GOSY'
  CRASH_GOSYM_VERSION     = $00020000;
  CRASH_GOSYM_HEADER_SIZE = 48;
  CRASH_GOSYM_ENTRY_SIZE  = 20;

type
  TCrashSymbolBuildID = array[0..15] of Byte;

  { A loaded .gosym. Read-only after Load, so lookups need no lock. }
  TCrashSymbolFile = class
  private
    FData: TBytes;
    FCount: UInt32;
    FStrTabOff: UInt32;
    FStrTabSize: UInt32;
    FFileTabOff: UInt32;
    FFileTabSize: UInt32;
    function EntryAddr(const AIndex: UInt32): UInt64; inline;
    function BoundedCStr(const AOffset, ALimit: UInt64;
      out AStr: RawByteString): Boolean;
  public
    { Accepts AData when it is a structurally valid .gosym built for ABuildID.
      Otherwise nothing is loaded and the result is False. }
    function Load(const AData: TBytes; const ABuildID: TCrashSymbolBuildID): Boolean;
    function Active: Boolean;

    { Resolves a LINK-TIME address. AMangledName is the symbol as stored,
      AStart the link-time start of the function, ASourceFile its source file
      ('' when unknown). False when no entry covers AAddress. }
    function Lookup(const AAddress: UInt64; out AMangledName: RawByteString;
      out AStart: UInt64; out ASourceFile: String): Boolean;

    property Count: UInt32 read FCount;
  end;

{ Reads the first 16 bytes of the .note.gnu.build-id of the ELF64 file APath and
  its link base: the page-aligned virtual address of the lowest PT_LOAD segment
  (0 for a shared object, the image base for a non-PIE executable). A runtime
  address maps to a link-time one as Address - LoadBase + ALinkBase, where
  LoadBase is dladdr's dli_fbase. False when the file is not a readable ELF64
  with a build-id. }
function CrashReadElfBuildID(const APath: String; out AID: TCrashSymbolBuildID;
  out ALinkBase: UInt64): Boolean;

implementation

uses
  System.Classes;

type
  TElf64Ehdr = packed record
    e_ident: array[0..15] of Byte;
    e_type, e_machine: UInt16;
    e_version: UInt32;
    e_entry, e_phoff, e_shoff: UInt64;
    e_flags: UInt32;
    e_ehsize, e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx: UInt16;
  end;

  TElf64Phdr = packed record
    p_type, p_flags: UInt32;
    p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align: UInt64;
  end;

const
  PT_LOAD = 1;
  PT_NOTE = 4;
  NT_GNU_BUILD_ID = 3;

function Align4(const V: UInt32): UInt32; inline;
begin
  Result := (V + 3) and not UInt32(3);
end;

function ExtractBuildIdFromNote(const ANote: TBytes;
  out AID: TCrashSymbolBuildID): Boolean;
var
  P, NameSz, DescSz, NType, DescPos: UInt32;
begin
  Result := False;
  P := 0;
  while (UInt64(P) + 12) <= UInt64(Length(ANote)) do
  begin
    NameSz := PUInt32(@ANote[P])^;
    DescSz := PUInt32(@ANote[P + 4])^;
    NType  := PUInt32(@ANote[P + 8])^;
    DescPos := P + 12 + Align4(NameSz);
    if (NType = NT_GNU_BUILD_ID) and (DescSz >= SizeOf(AID)) and
       ((UInt64(DescPos) + SizeOf(AID)) <= UInt64(Length(ANote))) then
    begin
      Move(ANote[DescPos], AID, SizeOf(AID));
      Exit(True);
    end;
    Inc(P, 12 + Align4(NameSz) + Align4(DescSz));
  end;
end;

function CrashReadElfBuildID(const APath: String; out AID: TCrashSymbolBuildID;
  out ALinkBase: UInt64): Boolean;
var
  Stream: TFileStream;
  Ehdr: TElf64Ehdr;
  Phdr: TElf64Phdr;
  I: Integer;
  Note: TBytes;
  HasLoad: Boolean;
begin
  Result := False;
  FillChar(AID, SizeOf(AID), 0);
  ALinkBase := 0;
  HasLoad := False;
  try
    Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
      if Stream.Read(Ehdr, SizeOf(Ehdr)) <> SizeOf(Ehdr) then Exit;
      if (Ehdr.e_ident[0] <> $7F) or (Ehdr.e_ident[1] <> Ord('E')) or
         (Ehdr.e_ident[2] <> Ord('L')) or (Ehdr.e_ident[3] <> Ord('F')) or
         (Ehdr.e_ident[4] <> 2) then // ELFCLASS64
        Exit;
      for I := 0 to Ehdr.e_phnum - 1 do
      begin
        Stream.Position := Int64(Ehdr.e_phoff) + Int64(I) * Ehdr.e_phentsize;
        if Stream.Read(Phdr, SizeOf(Phdr)) <> SizeOf(Phdr) then Break;
        if Phdr.p_type = PT_LOAD then
        begin
          if (not HasLoad) or (Phdr.p_vaddr < ALinkBase) then
            ALinkBase := Phdr.p_vaddr;
          HasLoad := True;
          Continue;
        end;
        if (Phdr.p_type <> PT_NOTE) or Result then Continue;
        if (Phdr.p_filesz = 0) or (Phdr.p_filesz > 1024 * 1024) then Continue;
        SetLength(Note, Phdr.p_filesz);
        Stream.Position := Int64(Phdr.p_offset);
        if Stream.Read(Note[0], Length(Note)) <> Length(Note) then Continue;
        Result := ExtractBuildIdFromNote(Note, AID);
      end;
    finally
      Stream.Free;
    end;
  except
    Result := False;
  end;
  ALinkBase := ALinkBase and not UInt64($FFF);
end;

{ TCrashSymbolFile }

function TCrashSymbolFile.Load(const AData: TBytes;
  const ABuildID: TCrashSymbolBuildID): Boolean;
var
  HdrSig, HdrVer, HdrSize, HdrCount: UInt32;
  HdrStrTabOff, HdrStrTabSize, HdrFileTabOff, HdrFileTabSize: UInt32;
  I: Integer;
begin
  Result := False;
  FData := nil;
  FCount := 0;
  if Length(AData) < CRASH_GOSYM_HEADER_SIZE then
    Exit;

  HdrSig         := PUInt32(@AData[0])^;
  HdrVer         := PUInt32(@AData[4])^;
  HdrSize        := PUInt32(@AData[8])^;
  HdrCount       := PUInt32(@AData[12])^;
  HdrStrTabOff   := PUInt32(@AData[32])^;
  HdrStrTabSize  := PUInt32(@AData[36])^;
  HdrFileTabOff  := PUInt32(@AData[40])^;
  HdrFileTabSize := PUInt32(@AData[44])^;

  // [header][entries][string table][file table], each region inside the file
  // and none overlapping the next: a corrupt offset can then never read a
  // "name" out of a neighbouring region.
  if (HdrSig <> CRASH_GOSYM_SIGNATURE) or
     ((HdrVer shr 16) <> (CRASH_GOSYM_VERSION shr 16)) or
     (HdrSize <> UInt32(Length(AData))) or
     (CRASH_GOSYM_HEADER_SIZE + UInt64(HdrCount) * CRASH_GOSYM_ENTRY_SIZE > UInt64(HdrStrTabOff)) or
     (UInt64(HdrStrTabOff) + HdrStrTabSize > UInt64(HdrFileTabOff)) or
     (UInt64(HdrFileTabOff) + HdrFileTabSize > UInt64(Length(AData))) then
    Exit;

  // Built for THIS binary? Wrong names are worse than no names.
  for I := 0 to 15 do
    if AData[16 + I] <> ABuildID[I] then
      Exit;

  FData := AData;
  FCount := HdrCount;
  FStrTabOff := HdrStrTabOff;
  FStrTabSize := HdrStrTabSize;
  FFileTabOff := HdrFileTabOff;
  FFileTabSize := HdrFileTabSize;
  Result := True;
end;

function TCrashSymbolFile.Active: Boolean;
begin
  Result := (FData <> nil) and (FCount > 0);
end;

function TCrashSymbolFile.EntryAddr(const AIndex: UInt32): UInt64;
begin
  // Move, not PUInt64^: with a 20-byte entry every odd entry is only 4-byte
  // aligned, and this code also compiles for 32-bit ARM.
  Move(FData[CRASH_GOSYM_HEADER_SIZE + AIndex * CRASH_GOSYM_ENTRY_SIZE], Result,
    SizeOf(Result));
end;

function TCrashSymbolFile.BoundedCStr(const AOffset, ALimit: UInt64;
  out AStr: RawByteString): Boolean;
// True when FData holds a NUL-terminated string starting at AOffset and fully
// inside [AOffset, ALimit) - ALimit is the owning table's end.
var
  S, E, Lim: Integer;
begin
  Result := False;
  AStr := '';
  if (AOffset >= ALimit) or (ALimit > UInt64(Length(FData))) then
    Exit;
  Lim := Integer(ALimit);
  S := Integer(AOffset);
  E := S;
  while (E < Lim) and (FData[E] <> 0) do
    Inc(E);
  if E >= Lim then
    Exit; // no NUL inside the table - corrupt
  SetLength(AStr, E - S);
  if E > S then
    Move(FData[S], AStr[1], E - S);
  Result := True;
end;

function TCrashSymbolFile.Lookup(const AAddress: UInt64;
  out AMangledName: RawByteString; out AStart: UInt64;
  out ASourceFile: String): Boolean;
var
  Lo, Hi, Mid, Found: Integer;
  EntBase: UInt32;
  Size, NameOff, FileOff: UInt32;
  FileStr: RawByteString;
begin
  Result := False;
  AMangledName := '';
  AStart := 0;
  ASourceFile := '';
  if not Active then
    Exit;

  // largest entry with Addr <= AAddress
  Lo := 0;
  Hi := Integer(FCount) - 1;
  Found := -1;
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) div 2;
    if EntryAddr(UInt32(Mid)) <= AAddress then
    begin
      Found := Mid;
      Lo := Mid + 1;
    end
    else
      Hi := Mid - 1;
  end;
  if Found < 0 then
    Exit;

  EntBase := CRASH_GOSYM_HEADER_SIZE + UInt32(Found) * CRASH_GOSYM_ENTRY_SIZE;
  Move(FData[EntBase], AStart, SizeOf(AStart));
  Size    := PUInt32(@FData[EntBase + 8])^;
  NameOff := PUInt32(@FData[EntBase + 12])^;
  FileOff := PUInt32(@FData[EntBase + 16])^;

  // Within [AStart, AStart+Size) when the size is known, else up to the next
  // entry.
  if Size > 0 then
  begin
    if AAddress >= AStart + Size then
      Exit;
  end
  else if (UInt32(Found) + 1 < FCount) and
          (AAddress >= EntryAddr(UInt32(Found) + 1)) then
    Exit;

  if (FileOff > 0) and BoundedCStr(UInt64(FFileTabOff) + FileOff,
       UInt64(FFileTabOff) + FFileTabSize, FileStr) then
    ASourceFile := String(FileStr);

  if not BoundedCStr(UInt64(FStrTabOff) + NameOff,
       UInt64(FStrTabOff) + FStrTabSize, AMangledName) then
    Exit;
  Result := AMangledName <> '';
end;

end.
