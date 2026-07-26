unit Generator;

interface

uses
  System.Classes,
  GolEncoder;

type
  TLineNumberGenerator = class
  {$REGION 'Internal Declarations'}
  private type
    TLine = TGolLine;
  private
    FExePath: String;
    FSymPath: String;
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
  MachO,
  Dwarf;

{ TLineNumberGenerator }

constructor TLineNumberGenerator.Create(const APath: String);
begin
  inherited Create;
  FExePath := APath;
  FSymPath := APath + '.dSYM';
  FLineNumPath := APath + '.gol';
end;

procedure TLineNumberGenerator.Run;
var
  MachO: TMachOFile;
  Dwarf: TDwarfInfo;
  ExeID, SymID: TGUID;
  DwarfSections: TDwarfSections;
  MachOSection: TSection;
  CU: TDwarfCompilationUnit;
  Name: String;
  Lines: TArray<TLine>;
  Line: TDwarfLine;
  PrevLine, LineCount: Integer;
begin
  if (not FileExists(FExePath)) then
    raise EFileNotFoundException.CreateFmt('Executable file "%s" not found', [FExePath]);

  if (not FileExists(FSymPath)) then
    raise EFileNotFoundException.CreateFmt('Symbol file "%s" not found', [FSymPath]);

  MachO := TMachOFile.Create;
  try
    MachO.Load(FExePath);
    ExeID := MachO.ID;

    MachO.Load(FSymPath);
    SymID := MachO.ID;

    if (ExeID <> SymID) then
      raise EStreamError.Create('ID of executable does not match ID of dSYM symbol file');

    for MachOSection in MachO.Sections do
    begin
      if (MachOSection.SegmentName = '__DWARF') then
      begin
        Name := MachOSection.SectionName;
        if (Name = '__debug_abbrev') then
          DwarfSections.Abbrev := MachOSection.Load
        else if (Name = '__debug_info') then
          DwarfSections.Info := MachOSection.Load
        else if (Name = '__debug_line') then
          DwarfSections.Line := MachOSection.Load
        else if (Name = '__debug_str') then
          DwarfSections.Str := MachOSection.Load;
      end;
    end;
  finally
    MachO.Free;
  end;

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

procedure TLineNumberGenerator.WriteLines(const AID: TGUID;
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
