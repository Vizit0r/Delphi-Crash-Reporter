unit GeneratorElf;
{ Linux/ELF variant of TLineNumberGenerator. Reads DWARF debug sections
  embedded in a Linux ELF64 binary (built with DCC_DebugInformation=2) and
  emits a .gol file in the same byte-format that Crash.LineNumbers
  consumes on macOS -- the runtime reader is platform-agnostic about the
  file payload itself, only the file ID and the VM-base lookup differ.

  Diff vs. Generator.pas (Mach-O):
  * Single input file (the ELF), not exe + .dSYM.
  * ID = first 16 bytes of .note.gnu.build-id (vs. LC_UUID).
  * DWARF sections come from .debug_* (vs. __DWARF segment __debug_*). }

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
  private
    procedure WriteLines(const AID: TGUID; var ALines: TArray<TLine>);
  {$ENDREGION 'Internal Declarations'}
  public
    constructor Create(const APath: String);
    procedure Run;
  end;

implementation

uses
  System.SysUtils,
  System.Generics.Collections,
  System.Generics.Defaults,
  Crash.LineNumbers,
  Elf,
  Dwarf;

{ TElfLineNumberGenerator }

constructor TElfLineNumberGenerator.Create(const APath: String);
begin
  inherited Create;
  FExePath := APath;
  FLineNumPath := APath + '.gol';
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
        DwarfSections.Str := Sec.Load;
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
      end;
    end;
    SetLength(Lines, LineCount);
  finally
    Dwarf.Free;
  end;

  WriteLines(ExeID, Lines);
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
