unit Elf;
{ Linux ELF64 container reader. Counterpart to MachO.pas — provides debug
  sections (.debug_info, .debug_line, .debug_abbrev, .debug_str) to Dwarf.pas
  and exposes the 20-byte GNU build-id (truncated to 16 bytes as TGUID) as the
  file's unique identifier.

  Only ELF64 little-endian is supported (covers Linux x86_64 and aarch64
  Delphi targets). 32-bit / big-endian / non-Linux ABIs are not implemented.

  References:
  * System V ABI ELF specification (gABI):
    http://www.sco.com/developers/gabi/latest/contents.html
  * GNU Build ID: https://fedoraproject.org/wiki/Releases/FeatureBuildId

  Implementation notes:
  * The Build ID is sha1 -> 20 bytes; TGUID is 16 bytes. We truncate to the
    first 16 bytes. Collision risk at 128-bit truncation is statistically
    negligible for our scale of binaries.
  * The first 16 bytes are NOT re-interpreted as a "GUID layout" (D1/D2/D3
    little-endian fields) -- they are stored byte-for-byte. The runtime
    reader (Crash.LineNumbers) must compare them the same way. }

interface

uses
  System.Classes,
  System.SysUtils,
  System.Generics.Collections;

type
  EElfError = class(Exception);

type
  { A named section in the ELF file, lazily loadable into a TBytes blob. }
  TElfSection = class
  {$REGION 'Internal Declarations'}
  private
    FStream: TStream;
    FName: String;
    FOffset: UInt64;
    FSize: UInt64;
  protected
    constructor Create(const AStream: TStream; const AName: String;
      const AOffset, ASize: UInt64);
  {$ENDREGION 'Internal Declarations'}
  public
    function Load: TBytes;
    property Name: String read FName;
    property Size: UInt64 read FSize;
  end;

type
  TElfFile = class
  {$REGION 'Internal Declarations'}
  private
    FStream: TStream;
    FOwnsStream: Boolean;
    FSections: TObjectList<TElfSection>;
    FID: TGUID;
    procedure ReadBuildId(const ASection: TElfSection);
  {$ENDREGION 'Internal Declarations'}
  public
    constructor Create;
    destructor Destroy; override;

    procedure Clear;
    procedure Load(const AFilename: String); overload;
    procedure Load(const AStream: TStream; const AOwnsStream: Boolean); overload;

    { First 16 bytes of the .note.gnu.build-id descriptor. }
    property ID: TGUID read FID;
    property Sections: TObjectList<TElfSection> read FSections;
  end;

implementation

const
  // Elf64_Ehdr.e_ident
  EI_MAG0      = $7F;
  EI_MAG1      = $45; // 'E'
  EI_MAG2      = $4C; // 'L'
  EI_MAG3      = $46; // 'F'
  EI_CLASS     = 4;
  EI_DATA      = 5;
  ELFCLASS64   = 2;
  ELFDATA2LSB  = 1;

  // section header types we care about
  SHT_NOTE = 7;

  // GNU note types
  NT_GNU_BUILD_ID = 3;

type
  Elf64_Ehdr = packed record
    e_ident: array[0..15] of Byte;
    e_type: UInt16;
    e_machine: UInt16;
    e_version: UInt32;
    e_entry: UInt64;
    e_phoff: UInt64;
    e_shoff: UInt64;
    e_flags: UInt32;
    e_ehsize: UInt16;
    e_phentsize: UInt16;
    e_phnum: UInt16;
    e_shentsize: UInt16;
    e_shnum: UInt16;
    e_shstrndx: UInt16;
  end;

  Elf64_Shdr = packed record
    sh_name: UInt32;       // offset into .shstrtab
    sh_type: UInt32;
    sh_flags: UInt64;
    sh_addr: UInt64;
    sh_offset: UInt64;
    sh_size: UInt64;
    sh_link: UInt32;
    sh_info: UInt32;
    sh_addralign: UInt64;
    sh_entsize: UInt64;
  end;

  Elf64_Nhdr = packed record
    n_namesz: UInt32;
    n_descsz: UInt32;
    n_type: UInt32;
  end;

{ TElfSection }

constructor TElfSection.Create(const AStream: TStream; const AName: String;
  const AOffset, ASize: UInt64);
begin
  inherited Create;
  FStream := AStream;
  FName := AName;
  FOffset := AOffset;
  FSize := ASize;
end;

function TElfSection.Load: TBytes;
begin
  if (FOffset = 0) or (FSize = 0) then
    Exit(nil);
  SetLength(Result, FSize);
  FStream.Position := FOffset;
  FStream.ReadBuffer(Result[0], FSize);
end;

{ TElfFile }

constructor TElfFile.Create;
begin
  inherited;
  FSections := TObjectList<TElfSection>.Create;
end;

destructor TElfFile.Destroy;
begin
  FSections.Free;
  if FOwnsStream then
    FStream.Free;
  inherited;
end;

procedure TElfFile.Clear;
begin
  if FOwnsStream then
    FStream.Free;
  FStream := nil;
  FOwnsStream := False;
  FSections.Clear;
  FID := TGUID.Empty;
end;

procedure TElfFile.ReadBuildId(const ASection: TElfSection);
// .note.gnu.build-id layout (one or more entries, in practice always one):
//   Elf64_Nhdr (namesz, descsz, type)
//   name[namesz] -- for GNU build-id this is the 4-byte ASCII "GNU" + NUL
//   padding to 4-byte boundary
//   desc[descsz] -- for NT_GNU_BUILD_ID this is 20 bytes of sha1
// We take the first 16 bytes of desc byte-for-byte as the TGUID.
var
  Data: TBytes;
  Nhdr: Elf64_Nhdr;
  NamePad, DescStart: Integer;
begin
  Data := ASection.Load;
  if Length(Data) < SizeOf(Nhdr) then
    raise EElfError.Create('.note.gnu.build-id section too small');

  Move(Data[0], Nhdr, SizeOf(Nhdr));
  if Nhdr.n_type <> NT_GNU_BUILD_ID then
    raise EElfError.CreateFmt(
      'Unexpected note type %d in .note.gnu.build-id (expected %d)',
      [Nhdr.n_type, NT_GNU_BUILD_ID]);

  // name padded up to 4-byte boundary
  NamePad := ((Nhdr.n_namesz + 3) div 4) * 4;
  DescStart := SizeOf(Nhdr) + NamePad;
  if (DescStart + Integer(Nhdr.n_descsz)) > Length(Data) then
    raise EElfError.Create('Build-id note truncated');

  if Nhdr.n_descsz < SizeOf(TGUID) then
    raise EElfError.CreateFmt(
      'Build-id too short: %d bytes (need at least %d)',
      [Nhdr.n_descsz, SizeOf(TGUID)]);

  Move(Data[DescStart], FID, SizeOf(TGUID));
end;

procedure TElfFile.Load(const AFilename: String);
begin
  Load(TFileStream.Create(AFilename, fmOpenRead or fmShareDenyWrite), True);
end;

procedure TElfFile.Load(const AStream: TStream; const AOwnsStream: Boolean);
var
  Ehdr: Elf64_Ehdr;
  Shdrs: array of Elf64_Shdr;
  StrtabBytes: TBytes;
  I: Integer;
  Name: String;
  NamePtr: PAnsiChar;
  BuildIdSection: TElfSection;
begin
  Assert(Assigned(AStream));
  Clear;
  FStream := AStream;
  FOwnsStream := AOwnsStream;

  AStream.Position := 0;
  AStream.ReadBuffer(Ehdr, SizeOf(Ehdr));
  if (Ehdr.e_ident[0] <> EI_MAG0) or (Ehdr.e_ident[1] <> EI_MAG1) or
     (Ehdr.e_ident[2] <> EI_MAG2) or (Ehdr.e_ident[3] <> EI_MAG3) then
    raise EElfError.Create('Not a valid ELF file (magic mismatch)');

  if Ehdr.e_ident[EI_CLASS] <> ELFCLASS64 then
    raise EElfError.Create('Only 64-bit ELF files are supported');
  if Ehdr.e_ident[EI_DATA] <> ELFDATA2LSB then
    raise EElfError.Create('Only little-endian ELF files are supported');

  if (Ehdr.e_shoff = 0) or (Ehdr.e_shnum = 0) then
    raise EElfError.Create('ELF has no section headers');
  if Ehdr.e_shentsize <> SizeOf(Elf64_Shdr) then
    raise EElfError.CreateFmt('Unexpected section header size %d (expected %d)',
      [Ehdr.e_shentsize, SizeOf(Elf64_Shdr)]);
  if Ehdr.e_shstrndx >= Ehdr.e_shnum then
    raise EElfError.Create('e_shstrndx out of range');

  // Read all section headers in one go.
  SetLength(Shdrs, Ehdr.e_shnum);
  AStream.Position := Ehdr.e_shoff;
  AStream.ReadBuffer(Shdrs[0], Int64(Ehdr.e_shnum) * SizeOf(Elf64_Shdr));

  // Read .shstrtab so we can resolve section names.
  with Shdrs[Ehdr.e_shstrndx] do
  begin
    SetLength(StrtabBytes, sh_size);
    if sh_size > 0 then
    begin
      AStream.Position := sh_offset;
      AStream.ReadBuffer(StrtabBytes[0], sh_size);
    end;
  end;

  // Build section list. Name = NUL-terminated string at sh_name offset in
  // .shstrtab.
  for I := 0 to Ehdr.e_shnum - 1 do
  begin
    if Shdrs[I].sh_name < UInt32(Length(StrtabBytes)) then
    begin
      NamePtr := @StrtabBytes[Shdrs[I].sh_name];
      Name := String(AnsiString(NamePtr));
    end
    else
      Name := '';
    FSections.Add(TElfSection.Create(AStream, Name,
      Shdrs[I].sh_offset, Shdrs[I].sh_size));
  end;

  // Find .note.gnu.build-id and extract the ID. Without it we cannot match
  // a .gol against a running binary, so this is mandatory.
  BuildIdSection := nil;
  for I := 0 to FSections.Count - 1 do
    if FSections[I].Name = '.note.gnu.build-id' then
    begin
      BuildIdSection := FSections[I];
      Break;
    end;

  if BuildIdSection = nil then
    raise EElfError.Create(
      'No .note.gnu.build-id section found. Link with --build-id (GNU ld' +
      ' default). Without it the .gol file has no way to match the binary.');

  ReadBuildId(BuildIdSection);
end;

end.
