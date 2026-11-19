unit GosymWriter;

{ Writes a .gosym side-file (address -> function name + source file, format
  documented and read in Crash.SymbolFile.pas) from the .symtab/.strtab of an
  unstripped ELF64 image. Used by LNG_ELF --gosym.

  Only LOCAL function symbols are taken: global ones are in .dynsym, which
  dladdr resolves at runtime without a side-file.

  Part of the Crash Reporter library - standalone, EurekaLog-compatible
  crash/exception reporting for Delphi cross-platform targets.

  Copyright (c) 2026 Vizit0r. BSD 2-Clause license (see LICENSE.txt). }

interface

uses
  System.SysUtils,
  System.Generics.Collections;

{ Writes APath. AFileByAddr maps a function start address to its source file
  name; addresses it lacks get no file. Returns the number of entries written.
  Raises EInvalidOperation when ASymtab is empty (the image is stripped). }
function GosymWriteFile(const APath: String; const ABuildID: TGUID;
  const ASymtab, AStrtab: TBytes;
  const AFileByAddr: TDictionary<UInt64, String>): Integer;

implementation

uses
  System.Classes,
  System.Generics.Defaults,
  Crash.SymbolFile;

type
  Elf64_Sym = packed record
    st_name: UInt32;
    st_info: Byte;
    st_other: Byte;
    st_shndx: UInt16;
    st_value: UInt64;
    st_size: UInt64;
  end;

  TGosymEntry = record
    Addr: UInt64;
    Size: UInt32;
    Name: RawByteString;
    FileName: RawByteString;
  end;

const
  STB_LOCAL = 0;
  STT_FUNC  = 2;
  SHN_UNDEF = 0;

function CStrAt(const ABytes: TBytes; const AOffset: UInt32): RawByteString;
var
  E: Integer;
begin
  Result := '';
  if AOffset >= UInt32(Length(ABytes)) then
    Exit;
  E := Integer(AOffset);
  while (E < Length(ABytes)) and (ABytes[E] <> 0) do
    Inc(E);
  SetLength(Result, E - Integer(AOffset));
  if E > Integer(AOffset) then
    Move(ABytes[AOffset], Result[1], E - Integer(AOffset));
end;

{ Deduplicated NUL-terminated string table; offset 0 is the empty string. }
type
  TStrTab = class
  private
    FStream: TMemoryStream;
    FOffsets: TDictionary<RawByteString, UInt32>;
  public
    constructor Create;
    destructor Destroy; override;
    function Add(const AValue: RawByteString): UInt32;
    function Bytes: TBytes;
  end;

constructor TStrTab.Create;
var
  Zero: Byte;
begin
  inherited;
  FStream := TMemoryStream.Create;
  FOffsets := TDictionary<RawByteString, UInt32>.Create;
  Zero := 0;
  FStream.WriteBuffer(Zero, 1);
  FOffsets.Add('', 0);
end;

destructor TStrTab.Destroy;
begin
  FOffsets.Free;
  FStream.Free;
  inherited;
end;

function TStrTab.Add(const AValue: RawByteString): UInt32;
var
  Zero: Byte;
begin
  if FOffsets.TryGetValue(AValue, Result) then
    Exit;
  Result := UInt32(FStream.Position);
  FStream.WriteBuffer(AValue[1], Length(AValue));
  Zero := 0;
  FStream.WriteBuffer(Zero, 1);
  FOffsets.Add(AValue, Result);
end;

function TStrTab.Bytes: TBytes;
begin
  SetLength(Result, FStream.Size);
  if FStream.Size > 0 then
    Move(FStream.Memory^, Result[0], FStream.Size);
end;

function GosymWriteFile(const APath: String; const ABuildID: TGUID;
  const ASymtab, AStrtab: TBytes;
  const AFileByAddr: TDictionary<UInt64, String>): Integer;
var
  Entries: TList<TGosymEntry>;
  Sym: Elf64_Sym;
  E: TGosymEntry;
  I, Count: Integer;
  Names, Files: TStrTab;
  NameOffs, FileOffs: TArray<UInt32>;
  NameBytes, FileBytes: TBytes;
  FileName: String;
  Output: TMemoryStream;
  Header: array [0..11] of UInt32;
  LastAddr: UInt64;
begin
  if Length(ASymtab) = 0 then
    raise EInvalidOperation.Create(
      'ELF has no .symtab (already stripped); cannot write a .gosym');

  Entries := TList<TGosymEntry>.Create;
  Names := TStrTab.Create;
  Files := TStrTab.Create;
  Output := TMemoryStream.Create;
  try
    for I := 0 to (Length(ASymtab) div SizeOf(Elf64_Sym)) - 1 do
    begin
      Move(ASymtab[I * SizeOf(Elf64_Sym)], Sym, SizeOf(Sym));
      if ((Sym.st_info and $F) <> STT_FUNC) or ((Sym.st_info shr 4) <> STB_LOCAL) or
         (Sym.st_shndx = SHN_UNDEF) or (Sym.st_value = 0) then
        Continue;
      E.Addr := Sym.st_value;
      if Sym.st_size > High(UInt32) then
        E.Size := 0
      else
        E.Size := UInt32(Sym.st_size);
      E.Name := CStrAt(AStrtab, Sym.st_name);
      if (E.Name = '') or (E.Name[1] = '.') or (E.Name[1] = '$') then
        Continue;
      if AFileByAddr.TryGetValue(E.Addr, FileName) then
        // base name; DWARF paths may use either separator whatever the host
        E.FileName := RawByteString(UTF8Encode(
          Copy(FileName, LastDelimiter('/\', FileName) + 1, MaxInt)))
      else
        E.FileName := '';
      Entries.Add(E);
    end;

    Entries.Sort(TComparer<TGosymEntry>.Construct(
      function(const ALeft, ARight: TGosymEntry): Integer
      begin
        if ALeft.Addr < ARight.Addr then Result := -1
        else if ALeft.Addr > ARight.Addr then Result := 1
        else Result := CompareStr(String(ALeft.Name), String(ARight.Name));
      end));

    // one entry per address (the first after the deterministic sort)
    Count := 0;
    LastAddr := 0;
    for I := 0 to Entries.Count - 1 do
      if (Count = 0) or (Entries[I].Addr <> LastAddr) then
      begin
        LastAddr := Entries[I].Addr;
        Entries[Count] := Entries[I];
        Inc(Count);
      end;
    Entries.Count := Count;

    SetLength(NameOffs, Count);
    SetLength(FileOffs, Count);
    for I := 0 to Count - 1 do
    begin
      NameOffs[I] := Names.Add(Entries[I].Name);
      FileOffs[I] := Files.Add(Entries[I].FileName);
    end;
    NameBytes := Names.Bytes;
    FileBytes := Files.Bytes;

    Header[0] := CRASH_GOSYM_SIGNATURE;
    Header[1] := CRASH_GOSYM_VERSION;
    Header[2] := CRASH_GOSYM_HEADER_SIZE + UInt32(Count) * CRASH_GOSYM_ENTRY_SIZE +
      UInt32(Length(NameBytes)) + UInt32(Length(FileBytes));
    Header[3] := UInt32(Count);
    Move(ABuildID, Header[4], SizeOf(TGUID)); // Header[4..7]
    Header[8] := CRASH_GOSYM_HEADER_SIZE + UInt32(Count) * CRASH_GOSYM_ENTRY_SIZE;
    Header[9] := UInt32(Length(NameBytes));
    Header[10] := Header[8] + Header[9];
    Header[11] := UInt32(Length(FileBytes));
    Output.WriteBuffer(Header, SizeOf(Header));
    for I := 0 to Count - 1 do
    begin
      E := Entries[I];
      Output.WriteBuffer(E.Addr, SizeOf(UInt64));
      Output.WriteBuffer(E.Size, SizeOf(UInt32));
      Output.WriteBuffer(NameOffs[I], SizeOf(UInt32));
      Output.WriteBuffer(FileOffs[I], SizeOf(UInt32));
    end;
    if Length(NameBytes) > 0 then
      Output.WriteBuffer(NameBytes[0], Length(NameBytes));
    if Length(FileBytes) > 0 then
      Output.WriteBuffer(FileBytes[0], Length(FileBytes));
    Output.SaveToFile(APath);
    Result := Count;
  finally
    Output.Free;
    Files.Free;
    Names.Free;
    Entries.Free;
  end;
end;

end.
