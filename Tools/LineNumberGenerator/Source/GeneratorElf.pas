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
  System.Classes;

type
  TElfLineNumberGenerator = class
  {$REGION 'Internal Declarations'}
  private type
    TLine = record
      Address: UInt64;
      Line: Integer;
    end;
  private
    FExePath: String;
    FLineNumPath: String;
  private
    procedure WriteLines(const AID: TGUID; const ALines: TArray<TLine>);
  private
    class procedure AppendByte(const AStream: TStream;
      const AValue: Byte); static;
    class procedure AppendVarInt(const AStream: TStream;
      const AValue: UInt32); inline; static;
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

class procedure TElfLineNumberGenerator.AppendByte(const AStream: TStream;
  const AValue: Byte);
begin
  AStream.WriteBuffer(AValue, 1);
end;

class procedure TElfLineNumberGenerator.AppendVarInt(const AStream: TStream;
  const AValue: UInt32);
var
  Value: UInt32;
  B: Byte;
begin
  Value := AValue;
  repeat
    B := Value and $7F;
    Value := Value shr 7;
    if (Value <> 0) then
      B := B or $80;
    AStream.WriteBuffer(B, 1);
  until (Value = 0);
end;

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
  PrevLine, LineCount, I: Integer;
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

  TArray.Sort<TLine>(Lines, TComparer<TLine>.Construct(
    function(const ALeft, ARight: TLine): Integer
    begin
      Result := ALeft.Address - ARight.Address;
    end));
  WriteLines(ExeID, Lines);
end;

procedure TElfLineNumberGenerator.WriteLines(const AID: TGUID;
  const ALines: TArray<TLine>);
{ Identical to Generator.WriteLines (macOS) - the .gol format is platform-
  independent. If the format changes, change it in both places at once. }
var
  Buffer: TMemoryStream;
  Header: TLineNumberHeader;
  Stream: TFileStream;
  I, LineDelta, Count: Integer;
  AddressDelta: Int64;
begin
  if (ALines = nil) then
    raise EInvalidOperation.Create('Line number information not available');

  AddressDelta := ALines[Length(ALines) - 1].Address - ALines[0].Address;
  if (AddressDelta <= 0) or (AddressDelta > $FFFFFFFF) then
    raise EInvalidOperation.Create('Line number addresses exceed 4 GB range');

  Buffer := TMemoryStream.Create;
  try
    Header.Signature := LINE_NUMBER_SIGNATURE;
    Header.Version := LINE_NUMBER_VERSION;
    Header.Size := 0;
    Header.Count := 0;
    Header.ID := AID;
    Header.StartVMAddress := ALines[0].Address;
    Header.StartLine := ALines[0].Line;
    Buffer.WriteBuffer(Header, SizeOf(Header));

    Count := 0;
    for I := 1 to Length(ALines) - 1 do
    begin
      AddressDelta := ALines[I].Address - ALines[I - 1].Address;
      if (AddressDelta < 0) then
        raise EInvalidOperation.Create('Invalid line number sequence (addresses should be incrementing)');

      LineDelta := ALines[I].Line - ALines[I - 1].Line;
      if (AddressDelta = 0) then
      begin
        // Skip duplicate-address line entries (silent Continue, see
        // Generator.pas for the macOS dSYM rationale -- ELF DWARF for
        // Delphi-generic'd routines ships them too).
        Continue;
      end
      else
      begin
        if (LineDelta >= 1) and (LineDelta <= 4) then
        begin
          if (AddressDelta <= 63) then
          begin
            AppendByte(Buffer, (LineDelta - 1) + ((AddressDelta - 1) * 4));
            Inc(Count);
            Continue;
          end
          else if (AddressDelta <= (63 * 2)) then
          begin
            AppendByte(Buffer, OP_ADVANCE_ADDR);
            AppendByte(Buffer, (LineDelta - 1) + ((AddressDelta - 63 - 1) * 4));
            Inc(Count);
            Continue;
          end;
        end;

        if (LineDelta <= 0) then
        begin
          AppendByte(Buffer, OP_ADVANCE_ABS);
          AppendVarInt(Buffer, AddressDelta - 1);
          AppendVarInt(Buffer, ALines[I].Line);
        end
        else
        begin
          AppendByte(Buffer, OP_ADVANCE_REL);
          AppendVarInt(Buffer, AddressDelta - 1);
          AppendVarInt(Buffer, LineDelta - 1);
        end;
        Inc(Count);
      end;
    end;

    Header.Count := Count;
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
