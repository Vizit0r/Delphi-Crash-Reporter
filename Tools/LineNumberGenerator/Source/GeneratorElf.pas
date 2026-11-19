unit GeneratorElf;
{ Linux/ELF variant of TLineNumberGenerator. Reads DWARF debug sections
  embedded in a Linux ELF64 binary (built with DCC_DebugInformation=2) and
  emits a .gol file in the same byte-format that Crash.LineNumbers
  consumes on macOS -- the runtime reader is platform-agnostic about the
  file payload itself, only the file ID and the VM-base lookup differ.

  Diff vs. Generator.pas (Mach-O):
  * Single input file (the ELF), not exe + .dSYM.
  * ID = first 16 bytes of .note.gnu.build-id (vs. LC_UUID).
  * DWARF sections come from .debug_* (vs. __DWARF segment __debug_*).

  Copyright (c) 2026 Vizit0r. BSD 2-Clause license (see LICENSE.txt). }

interface

uses
  System.Classes,
  GolEncoder;

type
  TElfLineNumberGenerator = class
  {$REGION 'Internal Declarations'}
  private type
    TLine = TGolLine;
  private
    FExePath: String;
    FLineNumPath: String;
    FWriteSymbols: Boolean;
  private
    procedure WriteLines(const AID: TGUID; var ALines: TArray<TLine>);
  {$ENDREGION 'Internal Declarations'}
  public
    { AWriteSymbols: also write <path>.gosym (local function names, see
      GosymWriter) from the image's .symtab. }
    constructor Create(const APath: String; const AWriteSymbols: Boolean = False);
    procedure Run;
  end;

implementation

uses
  System.SysUtils,
  System.Generics.Collections,
  System.Generics.Defaults,
  Crash.LineNumbers,
  Elf,
  Dwarf,
  GosymWriter;

{ TElfLineNumberGenerator }

constructor TElfLineNumberGenerator.Create(const APath: String;
  const AWriteSymbols: Boolean);
begin
  inherited Create;
  FExePath := APath;
  FLineNumPath := APath + '.gol';
  FWriteSymbols := AWriteSymbols;
end;

procedure TElfLineNumberGenerator.Run;
var
  ElfFile: TElfFile;
  Dwarf: TDwarfInfo;
  ExeID: TGUID;
  DwarfSections: TDwarfSections;
  Sec: TElfSection;
  CU: TDwarfCompilationUnit;
  Lines: TArray<TLine>;
  Line: TDwarfLine;
  PrevLine, LineCount: Integer;
  Symtab, Strtab: TBytes;
  FileByAddr: TDictionary<UInt64, String>;
  FileIndex: Integer;
begin
  if not FileExists(FExePath) then
    raise EFileNotFoundException.CreateFmt('Executable file "%s" not found', [FExePath]);

  ElfFile := TElfFile.Create;
  try
    ElfFile.Load(FExePath);
    ExeID := ElfFile.ID;

    for Sec in ElfFile.Sections do
    begin
      if Sec.Name = '.debug_abbrev' then
        DwarfSections.Abbrev := Sec.Load
      else if Sec.Name = '.debug_info' then
        DwarfSections.Info := Sec.Load
      else if Sec.Name = '.debug_line' then
        DwarfSections.Line := Sec.Load
      else if Sec.Name = '.debug_str' then
        DwarfSections.Str := Sec.Load
      else if Sec.Name = '.debug_str_offsets' then
        DwarfSections.StrOffsets := Sec.Load
      else if Sec.Name = '.debug_addr' then
        DwarfSections.Addr := Sec.Load
      else if Sec.Name = '.debug_line_str' then
        DwarfSections.LineStr := Sec.Load
      else if FWriteSymbols and (Sec.Name = '.symtab') then
        Symtab := Sec.Load
      else if FWriteSymbols and (Sec.Name = '.strtab') then
        Strtab := Sec.Load;
    end;
  finally
    ElfFile.Free;
  end;

  if (DwarfSections.Info = nil) or (DwarfSections.Line = nil) or
     (DwarfSections.Abbrev = nil) then
    raise EInvalidOperation.Create(
      'ELF lacks DWARF debug sections (.debug_info/.debug_line/.debug_abbrev).' +
      ' Ensure DCC_DebugInformation=2 for the Linux64 Release config and that' +
      ' the linker does not strip them.');

  FileByAddr := TDictionary<UInt64, String>.Create;
  Dwarf := TDwarfInfo.Create;
  try
    Dwarf.Load(DwarfSections);
    LineCount := 0;
    for CU in Dwarf.CompilationUnits do
    begin
      PrevLine := -1;
      SetLength(Lines, LineCount + CU.Lines.Count);
      for Line in CU.Lines do
      begin
        // Source file of the first row at an address (a function start, for
        // the .gosym)
        if FWriteSymbols and (not (TDwarfLineFlag.EndSequence in Line.Flags)) then
        begin
          FileIndex := Line.FileIndex;
          if (FileIndex >= 0) and (FileIndex < CU.Files.Count) and
             (CU.Files[FileIndex].Name <> '') then
            FileByAddr.TryAdd(Line.Address, CU.Files[FileIndex].Name);
        end;
        if (Line.Line <> PrevLine) then
        begin
          PrevLine := Line.Line;
          if (Line.Address > 0) then
          begin
            Lines[LineCount].Address := Line.Address;
            Lines[LineCount].Line := Line.Line;
            Inc(LineCount);
          end;
        end;
        // The next sequence starts at an unrelated address: keep its first row
        if (TDwarfLineFlag.EndSequence in Line.Flags) then
          PrevLine := -1;
      end;
    end;
    SetLength(Lines, LineCount);
  finally
    Dwarf.Free;
  end;

  try
    WriteLines(ExeID, Lines);
    if FWriteSymbols then
      Writeln(Format('%s: %d local function symbols',
        [ExtractFileName(FExePath) + '.gosym',
         GosymWriteFile(FExePath + '.gosym', ExeID, Symtab, Strtab, FileByAddr)]));
  finally
    FileByAddr.Free;
  end;
end;

procedure TElfLineNumberGenerator.WriteLines(const AID: TGUID;
  var ALines: TArray<TLine>);
{ Header + file IO around the shared GolEncoder program (one encoder for both
  the Mach-O and the ELF generator; GolEncodeLines sorts ALines itself). }
var
  Buffer: TMemoryStream;
  Header: TLineNumberHeader;
  Stream: TFileStream;
begin
  Buffer := TMemoryStream.Create;
  try
    { Reserve the header slot; every field is written after the encode, when
      the sorted ALines[0] anchor and the entry count are known. }
    Header := Default(TLineNumberHeader);
    Buffer.WriteBuffer(Header, SizeOf(Header));

    Header.Count := GolEncodeLines(ALines, Buffer);
    Header.Signature := LINE_NUMBER_SIGNATURE;
    Header.Version := LINE_NUMBER_VERSION;
    Header.ID := AID;
    Header.StartVMAddress := ALines[0].Address;
    Header.StartLine := ALines[0].Line;
    Header.Size := Buffer.Size;
    Move(Header, Buffer.Memory^, SizeOf(Header));

    Stream := TFileStream.Create(FLineNumPath, fmCreate);
    try
      Buffer.Position := 0;
      Stream.CopyFrom(Buffer);
    finally
      Stream.Free;
    end;
  finally
    Buffer.Free;
  end;
end;

end.
