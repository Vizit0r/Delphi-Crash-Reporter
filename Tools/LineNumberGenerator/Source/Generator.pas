unit Generator;

interface

uses
  System.Classes;

type
  TLineNumberGenerator = class
  {$REGION 'Internal Declarations'}
  private type
    TLine = record
      Address: UInt64;
      Line: Integer;
    end;
  private
    FExePath: String;
    FSymPath: String;
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
  MachO,
  Dwarf;

{ TLineNumberGenerator }

class procedure TLineNumberGenerator.AppendByte(const AStream: TStream;
  const AValue: Byte);
begin
  AStream.WriteBuffer(AValue, 1);
end;

class procedure TLineNumberGenerator.AppendVarInt(const AStream: TStream;
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

  TArray.Sort<TLine>(Lines, TComparer<TLine>.Construct(
    function(const ALeft, ARight: TLine): Integer
    begin
      // Branchy compare: a UInt64 subtraction narrowed to Integer flips sign
      // for far-apart addresses and breaks the sort order.
      if ALeft.Address < ARight.Address then Result := -1
      else if ALeft.Address > ARight.Address then Result := 1
      else Result := 0;
    end));
  WriteLines(ExeID, Lines);
end;

procedure TLineNumberGenerator.WriteLines(const AID: TGUID;
  const ALines: TArray<TLine>);
var
  Buffer: TMemoryStream;
  Header: TLineNumberHeader;
  Stream: TFileStream;
  I, LineDelta, Count, PrevLine: Integer;
  AddressDelta: Int64;
  PrevAddress: UInt64;
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
    Header.Size := 0; // Filled in at the end
    Header.Count := 0; // Filled in at the end
    Header.ID := AID;
    Header.StartVMAddress := ALines[0].Address;
    Header.StartLine := ALines[0].Line;
    Buffer.WriteBuffer(Header, SizeOf(Header));

    { Create state machine program }
    Count := 0;
    PrevAddress := ALines[0].Address;
    PrevLine := ALines[0].Line;
    for I := 1 to Length(ALines) - 1 do
    begin
      { Deltas are relative to the last WRITTEN entry: the decoder never sees
        the skipped duplicates below, its state advances only on written
        records. }
      AddressDelta := ALines[I].Address - PrevAddress;
      if (AddressDelta < 0) then
        raise EInvalidOperation.Create('Invalid line number sequence (addresses should be incrementing)');

      LineDelta := ALines[I].Line - PrevLine;
      if (AddressDelta = 0) then
      begin
        // Skip duplicate-address line entries (silent Continue instead of
        // raising). OSXARM64 dSYMs contain multiple line numbers per address
        // — a typical artifact of inlining and Pascal-generic template
        // instantiation in Mach-O. Skipping the duplicates yields slightly
        // less coverage but a valid .gol.
        Continue;
      end
      else
      begin
        PrevAddress := ALines[I].Address;
        PrevLine := ALines[I].Line;
        if (LineDelta >= 1) and (LineDelta <= 4) then
        begin
          if (AddressDelta <= 63) then
          begin
            { Most common case. Can be handled with single opcode without arguments }
            AppendByte(Buffer, (LineDelta - 1) + ((AddressDelta - 1) * 4));
            Inc(Count);
            Continue;
          end
          else if (AddressDelta <= (63 * 2)) then
          begin
            { We can use a 2-byte value for this }
            AppendByte(Buffer, OP_ADVANCE_ADDR);
            AppendByte(Buffer, (LineDelta - 1) + ((AddressDelta - 63 - 1) * 4));
            Inc(Count);
            Continue;
          end;
        end;

        { We need more than 2 bytes (uncommon).
          When LineDelta <= 0, we *must* encode using an absolute line number.
          Otherwise, we use relative encoding. }
        if (LineDelta <= 0) then
        begin
          { We need to encode an absolute line number }
          AppendByte(Buffer, OP_ADVANCE_ABS);
          AppendVarInt(Buffer, AddressDelta - 1);
          AppendVarInt(Buffer, ALines[I].Line);
        end
        else
        begin
          { We can encode a relative line number (which is usually more efficient) }
          AppendByte(Buffer, OP_ADVANCE_REL);
          AppendVarInt(Buffer, AddressDelta - 1);
          AppendVarInt(Buffer, LineDelta - 1);
        end;
        Inc(Count);
      end;
    end;

    { Update Count and Size field }
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
