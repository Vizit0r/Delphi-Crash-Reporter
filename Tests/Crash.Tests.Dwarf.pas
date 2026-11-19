unit Crash.Tests.Dwarf;

// ===========================================================================
//  Dwarf - parser coverage of the LNG / LNG_ELF DWARF reader (Dwarf.pas) on
//  hand-built debug sections, so every header layout and attribute form is
//  pinned without a real compiler output.
//
//    D1  DWARF 5 unit: v5 header order, strx1/strx2/strx resolved through a
//        NON-default DW_AT_str_offsets_base that follows the strx attributes,
//        addrx1 through DW_AT_addr_base, implicit_const, data16 skipped,
//        line v5 header (line_strp / string / udata / data16 entry formats,
//        0-based file table) and the statement program rows.
//    D2  DWARF 4 units: v2-4 header order, strp / string / data4 forms, two
//        units sharing one abbreviation table, line program v2 and v4.
//    D3  DWARF 5 non-compile units (DW_UT_type) are skipped.
//    D4  DW_FORM_strx without .debug_str_offsets raises EDwarfError.
//
//  Copyright (c) 2026 Vizit0r. BSD 2-Clause license (see LICENSE.txt).
// ===========================================================================

interface

{$IFDEF AUTOTESTS}

uses
  System.SysUtils,
  Crash.Tests.Registry;

type
  TDwarf_AllInOne = class
  public
    class function AutoTest(out OutLines: TArray<string>): Boolean; static;
  end;

{$ENDIF}

implementation

{$IFDEF AUTOTESTS}

uses
  System.Classes,
  System.Generics.Collections,
  Dwarf,
  Crash.Tests.Progress;

const
  TEST_NAME = 'Dwarf';

  // Literals pinned independently of Dwarf.pas.
  TAG_compile_unit  = $11;
  AT_name           = $03;
  AT_stmt_list      = $10;
  AT_low_pc         = $11;
  AT_language       = $13;
  AT_comp_dir       = $1b;
  AT_producer       = $25;
  AT_str_offs_base  = $72;
  AT_addr_base      = $73;
  AT_vendor         = $2001;
  FORM_data4        = $06;
  FORM_string       = $08;
  FORM_data1        = $0b;
  FORM_strp         = $0e;
  FORM_udata        = $0f;
  FORM_sec_offset   = $17;
  FORM_strx         = $1a;
  FORM_data16       = $1e;
  FORM_line_strp    = $1f;
  FORM_implicit     = $21;
  FORM_strx1        = $25;
  FORM_strx2        = $26;
  FORM_addrx1       = $29;
  UT_compile        = $01;
  UT_type           = $02;
  LNCT_path         = $1;
  LNCT_dir_index    = $2;
  LNCT_MD5          = $5;
  LNS_copy          = 1;
  LNS_advance_pc    = 2;
  LNS_advance_line  = 3;
  LNS_set_file      = 4;
  LNE_end_sequence  = 1;
  LNE_set_address   = 2;

  // Standard line program parameters used by every program below.
  LINE_BASE   = -5;
  LINE_RANGE  = 14;
  OPCODE_BASE = 13;

type
  { Little-endian byte builder for synthetic sections. }
  TSecBuilder = class
  private
    FData: TBytes;
    FLen: Integer;
    procedure Put(const AData; const ACount: Integer);
  public
    procedure U8(const AValue: Byte);
    procedure U16(const AValue: Word);
    procedure U32(const AValue: UInt32);
    procedure U64(const AValue: UInt64);
    procedure ULeb(AValue: UInt64);
    procedure SLeb(AValue: Int64);
    procedure Str(const AValue: AnsiString);
    procedure Fill(const AValue: Byte; const ACount: Integer);
    procedure Patch32(const APos: Integer; const AValue: UInt32);
    function Bytes: TBytes;
    property Pos: Integer read FLen;
  end;

procedure TSecBuilder.Put(const AData; const ACount: Integer);
begin
  if FLen + ACount > Length(FData) then
    SetLength(FData, (FLen + ACount) * 2 + 64);
  Move(AData, FData[FLen], ACount);
  Inc(FLen, ACount);
end;

procedure TSecBuilder.U8(const AValue: Byte);
begin
  Put(AValue, 1);
end;

procedure TSecBuilder.U16(const AValue: Word);
begin
  Put(AValue, 2);
end;

procedure TSecBuilder.U32(const AValue: UInt32);
begin
  Put(AValue, 4);
end;

procedure TSecBuilder.U64(const AValue: UInt64);
begin
  Put(AValue, 8);
end;

procedure TSecBuilder.ULeb(AValue: UInt64);
var
  B: Byte;
begin
  repeat
    B := AValue and $7F;
    AValue := AValue shr 7;
    if AValue <> 0 then
      B := B or $80;
    U8(B);
  until AValue = 0;
end;

procedure TSecBuilder.SLeb(AValue: Int64);
var
  B: Byte;
  More: Boolean;
begin
  repeat
    B := AValue and $7F;
    // Arithmetic shift right by 7
    if AValue < 0 then
      AValue := not Int64(UInt64(not AValue) shr 7)
    else
      AValue := AValue shr 7;
    More := not (((AValue = 0) and ((B and $40) = 0)) or
                 ((AValue = -1) and ((B and $40) <> 0)));
    if More then
      B := B or $80;
    U8(B);
  until not More;
end;

procedure TSecBuilder.Str(const AValue: AnsiString);
begin
  if AValue <> '' then
    Put(AValue[1], Length(AValue));
  U8(0);
end;

procedure TSecBuilder.Fill(const AValue: Byte; const ACount: Integer);
var
  I: Integer;
begin
  for I := 1 to ACount do
    U8(AValue);
end;

procedure TSecBuilder.Patch32(const APos: Integer; const AValue: UInt32);
begin
  Move(AValue, FData[APos], 4);
end;

function TSecBuilder.Bytes: TBytes;
begin
  Result := Copy(FData, 0, FLen);
end;

{ Section helpers }

procedure Abbr(const B: TSecBuilder; const AName, AForm: Integer);
begin
  B.ULeb(AName);
  B.ULeb(AForm);
end;

{ Opens a unit / line program: 4-byte length placeholder. Returns its
  position for CloseLength. }
function OpenLength(const B: TSecBuilder): Integer;
begin
  Result := B.Pos;
  B.U32(0);
end;

procedure CloseLength(const B: TSecBuilder; const ALenPos: Integer);
begin
  B.Patch32(ALenPos, B.Pos - ALenPos - 4);
end;

procedure StdOpcodeLengths(const B: TSecBuilder);
const
  LENGTHS: array [1..OPCODE_BASE - 1] of Byte = (0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1);
var
  I: Integer;
begin
  for I := Low(LENGTHS) to High(LENGTHS) do
    B.U8(LENGTHS[I]);
end;

procedure SetAddress(const B: TSecBuilder; const AAddr: UInt64);
begin
  B.U8(0);
  B.ULeb(9);
  B.U8(LNE_set_address);
  B.U64(AAddr);
end;

procedure EndSequence(const B: TSecBuilder);
begin
  B.U8(0);
  B.ULeb(1);
  B.U8(LNE_end_sequence);
end;

function SpecialOp(const AAddrAdv, ALineAdv: Integer): Byte;
begin
  Result := (ALineAdv - LINE_BASE) + (LINE_RANGE * AAddrAdv) + OPCODE_BASE;
end;

{ Checks }

function CheckStr(Progress: TCrashTestProgress; const ATag, AGot, AWant: string): Boolean;
begin
  Result := AGot = AWant;
  if not Result then
    Progress.InfoFmt('%s: "%s", want "%s"', [ATag, AGot, AWant]);
end;

function CheckInt(Progress: TCrashTestProgress; const ATag: string;
  const AGot, AWant: Int64): Boolean;
begin
  Result := AGot = AWant;
  if not Result then
    Progress.InfoFmt('%s: %d, want %d', [ATag, AGot, AWant]);
end;

function CheckLine(Progress: TCrashTestProgress; const ATag: string;
  const ALines: TList<TDwarfLine>; const AIndex: Integer; const AAddr: UInt64;
  const ALine, AFile: Integer; const AEnd: Boolean): Boolean;
var
  L: TDwarfLine;
begin
  Result := False;
  if AIndex >= ALines.Count then
  begin
    Progress.InfoFmt('%s: row %d missing (%d rows)', [ATag, AIndex, ALines.Count]);
    Exit;
  end;
  L := ALines[AIndex];
  if (L.Address <> AAddr) or (L.Line <> ALine) or (L.FileIndex <> AFile) or
     ((TDwarfLineFlag.EndSequence in L.Flags) <> AEnd) then
  begin
    Progress.InfoFmt('%s: row %d is $%x:%d file %d end %s, want $%x:%d file %d end %s',
      [ATag, AIndex, L.Address, L.Line, L.FileIndex,
       BoolToStr(TDwarfLineFlag.EndSequence in L.Flags, True),
       AAddr, ALine, AFile, BoolToStr(AEnd, True)]);
    Exit;
  end;
  Result := True;
end;

{ D1 }

procedure BuildV5(out ASections: TDwarfSections; const AWithTypeUnit: Boolean);
var
  Abbrev, Info, Str, StrOffs, Addr, Line, LineStr: TSecBuilder;
  OffProducer, OffName, OffDir, OffSrc, LenPos, HdrLenPos: Integer;
begin
  Abbrev := TSecBuilder.Create;
  Info := TSecBuilder.Create;
  Str := TSecBuilder.Create;
  StrOffs := TSecBuilder.Create;
  Addr := TSecBuilder.Create;
  Line := TSecBuilder.Create;
  LineStr := TSecBuilder.Create;
  try
    { .debug_str }
    Str.Str('unused');
    OffProducer := Str.Pos;
    Str.Str('Delphi Test');
    OffName := Str.Pos;
    Str.Str('unit5.pas');
    OffDir := Str.Pos;
    Str.Str('/build');

    { .debug_str_offsets: a foreign 16-byte contribution first, so the
      default base (8) would hit its garbage entries. Ours starts at 24. }
    StrOffs.U32(12); StrOffs.U16(5); StrOffs.U16(0);
    StrOffs.U32($FFFFFFF0); StrOffs.U32($FFFFFFF0);
    StrOffs.U32(16); StrOffs.U16(5); StrOffs.U16(0);
    StrOffs.U32(OffProducer); // index 0
    StrOffs.U32(OffName);     // index 1
    StrOffs.U32(OffDir);      // index 2

    { .debug_addr: same idea, our base is 24 }
    Addr.U32(12); Addr.U16(5); Addr.U8(8); Addr.U8(0);
    Addr.U64($DEADBEEF);
    Addr.U32(20); Addr.U16(5); Addr.U8(8); Addr.U8(0);
    Addr.U64($401000); // index 0
    Addr.U64($402000); // index 1

    { .debug_line_str }
    LineStr.Str('xx');
    OffSrc := LineStr.Pos;
    LineStr.Str('/src');

    { .debug_abbrev: bases come AFTER the attributes that use them }
    Abbrev.ULeb(1);
    Abbrev.ULeb(TAG_compile_unit);
    Abbrev.U8(0); // no children
    Abbr(Abbrev, AT_producer, FORM_strx1);
    Abbr(Abbrev, AT_language, FORM_implicit);
    Abbrev.SLeb(9);
    Abbr(Abbrev, AT_name, FORM_strx2);
    Abbr(Abbrev, AT_comp_dir, FORM_strx);
    Abbr(Abbrev, AT_vendor, FORM_data16);
    Abbr(Abbrev, AT_low_pc, FORM_addrx1);
    Abbr(Abbrev, AT_stmt_list, FORM_sec_offset);
    Abbr(Abbrev, AT_str_offs_base, FORM_sec_offset);
    Abbr(Abbrev, AT_addr_base, FORM_sec_offset);
    Abbr(Abbrev, 0, 0);
    Abbrev.ULeb(0);

    { .debug_info }
    if AWithTypeUnit then
    begin
      // DW_UT_type header + junk DIE bytes that would not parse
      LenPos := OpenLength(Info);
      Info.U16(5); Info.U8(UT_type); Info.U8(8); Info.U32($7777);
      Info.U64($1122334455667788); Info.U32(0);
      Info.Fill($FF, 6);
      CloseLength(Info, LenPos);
    end;

    LenPos := OpenLength(Info);
    Info.U16(5);
    Info.U8(UT_compile);
    Info.U8(8);
    Info.U32(0); // abbrev offset
    Info.ULeb(1);
    Info.U8(0);             // producer: strx1 0
    { language: implicit_const, no bytes }
    Info.U16(1);            // name: strx2 1
    Info.ULeb(2);           // comp_dir: strx 2
    Info.Fill($AB, 16);     // vendor data16
    Info.U8(1);             // low_pc: addrx1 1
    Info.U32(0);            // stmt_list
    Info.U32(24);           // str_offsets_base
    Info.U32(24);           // addr_base
    CloseLength(Info, LenPos);

    { .debug_line v5 }
    LenPos := OpenLength(Line);
    Line.U16(5);
    Line.U8(8);  // address_size
    Line.U8(0);  // segment_selector_size
    HdrLenPos := Line.Pos;
    Line.U32(0); // header_length
    Line.U8(1);  // minimum_instruction_length
    Line.U8(1);  // maximum_operations_per_instruction
    Line.U8(1);  // default_is_stmt
    Line.U8(Byte(LINE_BASE));
    Line.U8(LINE_RANGE);
    Line.U8(OPCODE_BASE);
    StdOpcodeLengths(Line);
    Line.U8(1);  // directory_entry_format_count
    Abbr(Line, LNCT_path, FORM_line_strp);
    Line.ULeb(1);
    Line.U32(OffSrc);
    Line.U8(3);  // file_name_entry_format_count
    Abbr(Line, LNCT_path, FORM_string);
    Abbr(Line, LNCT_dir_index, FORM_udata);
    Abbr(Line, LNCT_MD5, FORM_data16);
    Line.ULeb(2);
    Line.Str('a.pas'); Line.ULeb(0); Line.Fill($11, 16);
    Line.Str('b.pas'); Line.ULeb(0); Line.Fill($22, 16);
    Line.Patch32(HdrLenPos, Line.Pos - HdrLenPos - 4);
    Line.U8(LNS_set_file); Line.ULeb(1);
    SetAddress(Line, $402000);
    Line.U8(LNS_advance_line); Line.SLeb(9);
    Line.U8(LNS_copy);
    Line.U8(SpecialOp(3, 1));
    Line.U8(LNS_advance_pc); Line.ULeb(4);
    EndSequence(Line);
    CloseLength(Line, LenPos);

    ASections.Abbrev := Abbrev.Bytes;
    ASections.Info := Info.Bytes;
    ASections.Line := Line.Bytes;
    ASections.Str := Str.Bytes;
    ASections.StrOffsets := StrOffs.Bytes;
    ASections.Addr := Addr.Bytes;
    ASections.LineStr := LineStr.Bytes;
  finally
    LineStr.Free;
    Line.Free;
    Addr.Free;
    StrOffs.Free;
    Str.Free;
    Info.Free;
    Abbrev.Free;
  end;
end;

function Step_D1_Dwarf5(Progress: TCrashTestProgress): Boolean;
var
  Sections: TDwarfSections;
  Info: TDwarfInfo;
  CU: TDwarfCompilationUnit;
begin
  Result := False;
  BuildV5(Sections, False);
  Info := TDwarfInfo.Create;
  try
    try
      Info.Load(Sections);
    except
      on E: Exception do
      begin
        Progress.InfoFmt('D1: %s: %s', [E.ClassName, E.Message]);
        Exit;
      end;
    end;
    if not CheckInt(Progress, 'D1 units', Info.CompilationUnits.Count, 1) then
      Exit;
    CU := Info.CompilationUnits[0];
    Result :=
      CheckInt(Progress, 'D1 version', CU.Version, 5) and
      CheckStr(Progress, 'D1 producer', CU.Producer, 'Delphi Test') and
      CheckStr(Progress, 'D1 name', CU.Name, 'unit5.pas') and
      CheckStr(Progress, 'D1 comp_dir', CU.Directory, '/build') and
      CheckInt(Progress, 'D1 language', CU.Language, 9) and
      CheckInt(Progress, 'D1 low_pc', CU.LowPC, $402000) and
      CheckInt(Progress, 'D1 dirs', CU.IncludeDirectories.Count, 1) and
      CheckStr(Progress, 'D1 dir[0]', CU.IncludeDirectories[0], '/src') and
      CheckInt(Progress, 'D1 files', CU.Files.Count, 2) and
      CheckStr(Progress, 'D1 file[0]', CU.Files[0].Name, 'a.pas') and
      CheckStr(Progress, 'D1 file[1]', CU.Files[1].Name, 'b.pas') and
      CheckInt(Progress, 'D1 rows', CU.Lines.Count, 3) and
      CheckLine(Progress, 'D1', CU.Lines, 0, $402000, 10, 1, False) and
      CheckLine(Progress, 'D1', CU.Lines, 1, $402003, 11, 1, False) and
      CheckLine(Progress, 'D1', CU.Lines, 2, $402007, 11, 1, True);
  finally
    Info.Free;
  end;
end;

{ D2 }

procedure BuildV4(out ASections: TDwarfSections);
const
  VERSIONS: array [0..1] of Integer = (2, 4);
var
  Abbrev, Info, Str, Line: TSecBuilder;
  OffProducer, ProgB, LenPos, HdrLenPos, Version, I: Integer;
begin
  Abbrev := TSecBuilder.Create;
  Info := TSecBuilder.Create;
  Str := TSecBuilder.Create;
  Line := TSecBuilder.Create;
  try
    Str.Str('x');
    OffProducer := Str.Pos;
    Str.Str('Delphi 4');

    Abbrev.ULeb(1);
    Abbrev.ULeb(TAG_compile_unit);
    Abbrev.U8(0);
    Abbr(Abbrev, AT_producer, FORM_strp);
    Abbr(Abbrev, AT_name, FORM_string);
    Abbr(Abbrev, AT_language, FORM_data1);
    Abbr(Abbrev, AT_stmt_list, FORM_data4);
    Abbr(Abbrev, 0, 0);
    Abbrev.ULeb(0);

    { Line programs: v2 at offset 0, v4 after it }
    ProgB := 0;
    for Version in VERSIONS do
    begin
      if Version = 4 then
        ProgB := Line.Pos;
      LenPos := OpenLength(Line);
      Line.U16(Version);
      HdrLenPos := Line.Pos;
      Line.U32(0);
      Line.U8(1); // minimum_instruction_length
      if Version >= 4 then
        Line.U8(1); // maximum_operations_per_instruction
      Line.U8(1);
      Line.U8(Byte(LINE_BASE));
      Line.U8(LINE_RANGE);
      Line.U8(OPCODE_BASE);
      StdOpcodeLengths(Line);
      Line.Str('inc');
      Line.U8(0);
      Line.Str('a.pas'); Line.ULeb(1); Line.ULeb(0); Line.ULeb(0);
      Line.U8(0);
      Line.Patch32(HdrLenPos, Line.Pos - HdrLenPos - 4);
      if Version = 2 then
      begin
        SetAddress(Line, $1000);
        Line.U8(LNS_advance_line); Line.SLeb(4);
        Line.U8(LNS_copy);
        Line.U8(SpecialOp(2, 2));
        Line.U8(LNS_advance_pc); Line.ULeb(1);
      end
      else
      begin
        SetAddress(Line, $2000);
        Line.U8(LNS_advance_line); Line.SLeb(19);
        Line.U8(LNS_copy);
        Line.U8(LNS_advance_pc); Line.ULeb(5);
      end;
      EndSequence(Line);
      CloseLength(Line, LenPos);
    end;

    { Two v4 units sharing abbreviation table 0 }
    for I := 0 to 1 do
    begin
      LenPos := OpenLength(Info);
      Info.U16(4);
      Info.U32(0); // abbrev offset
      Info.U8(8);  // address_size
      Info.ULeb(1);
      Info.U32(OffProducer);
      if I = 0 then Info.Str('two.pas') else Info.Str('four.pas');
      Info.U8(9);
      if I = 0 then Info.U32(0) else Info.U32(ProgB);
      CloseLength(Info, LenPos);
    end;

    ASections := Default(TDwarfSections);
    ASections.Abbrev := Abbrev.Bytes;
    ASections.Info := Info.Bytes;
    ASections.Line := Line.Bytes;
    ASections.Str := Str.Bytes;
  finally
    Line.Free;
    Str.Free;
    Info.Free;
    Abbrev.Free;
  end;
end;

function Step_D2_Dwarf4(Progress: TCrashTestProgress): Boolean;
var
  Sections: TDwarfSections;
  Info: TDwarfInfo;
  A, B: TDwarfCompilationUnit;
begin
  Result := False;
  BuildV4(Sections);
  Info := TDwarfInfo.Create;
  try
    try
      Info.Load(Sections);
    except
      on E: Exception do
      begin
        Progress.InfoFmt('D2: %s: %s', [E.ClassName, E.Message]);
        Exit;
      end;
    end;
    if not CheckInt(Progress, 'D2 units', Info.CompilationUnits.Count, 2) then
      Exit;
    A := Info.CompilationUnits[0];
    B := Info.CompilationUnits[1];
    Result :=
      CheckInt(Progress, 'D2 version', A.Version, 4) and
      CheckStr(Progress, 'D2 producer', A.Producer, 'Delphi 4') and
      CheckStr(Progress, 'D2 name A', A.Name, 'two.pas') and
      CheckStr(Progress, 'D2 name B', B.Name, 'four.pas') and
      CheckInt(Progress, 'D2 language', A.Language, 9) and
      // v2-4: implicit entry 0 = current directory / no file
      CheckInt(Progress, 'D2 dirs', A.IncludeDirectories.Count, 2) and
      CheckStr(Progress, 'D2 dir[1]', A.IncludeDirectories[1], 'inc') and
      CheckInt(Progress, 'D2 files', A.Files.Count, 2) and
      CheckStr(Progress, 'D2 file[1]', A.Files[1].Name, 'a.pas') and
      CheckInt(Progress, 'D2 file[1].dir', A.Files[1].DirectoryIndex, 1) and
      CheckInt(Progress, 'D2 rows A', A.Lines.Count, 3) and
      CheckLine(Progress, 'D2 A', A.Lines, 0, $1000, 5, 1, False) and
      CheckLine(Progress, 'D2 A', A.Lines, 1, $1002, 7, 1, False) and
      CheckLine(Progress, 'D2 A', A.Lines, 2, $1003, 7, 1, True) and
      CheckInt(Progress, 'D2 rows B', B.Lines.Count, 2) and
      CheckLine(Progress, 'D2 B', B.Lines, 0, $2000, 20, 1, False) and
      CheckLine(Progress, 'D2 B', B.Lines, 1, $2005, 20, 1, True);
  finally
    Info.Free;
  end;
end;

{ D3 }

function Step_D3_SkipsTypeUnit(Progress: TCrashTestProgress): Boolean;
var
  Sections: TDwarfSections;
  Info: TDwarfInfo;
begin
  Result := False;
  BuildV5(Sections, True);
  Info := TDwarfInfo.Create;
  try
    try
      Info.Load(Sections);
    except
      on E: Exception do
      begin
        Progress.InfoFmt('D3: %s: %s', [E.ClassName, E.Message]);
        Exit;
      end;
    end;
    Result :=
      CheckInt(Progress, 'D3 units', Info.CompilationUnits.Count, 1) and
      CheckStr(Progress, 'D3 name', Info.CompilationUnits[0].Name, 'unit5.pas');
  finally
    Info.Free;
  end;
end;

{ D4 }

function Step_D4_StrxWithoutOffsetsRaises(Progress: TCrashTestProgress): Boolean;
var
  Sections: TDwarfSections;
  Info: TDwarfInfo;
begin
  Result := False;
  BuildV5(Sections, False);
  Sections.StrOffsets := nil;
  Info := TDwarfInfo.Create;
  try
    try
      Info.Load(Sections);
      Progress.Info('D4: no exception raised');
    except
      on EDwarfError do
        Result := True;
      on E: Exception do
        Progress.InfoFmt('D4: %s instead of EDwarfError', [E.ClassName]);
    end;
  finally
    Info.Free;
  end;
end;

class function TDwarf_AllInOne.AutoTest(out OutLines: TArray<string>): Boolean;
var
  L: TList<string>;
  Progress: TCrashTestProgress;
begin
  L := TList<string>.Create;
  try
    Progress := TCrashTestProgress.Create(L);
    try
      Progress.Account(Step_D1_Dwarf5(Progress), 'D1: DWARF 5 unit, indexed forms and line v5 header');
      Progress.Account(Step_D2_Dwarf4(Progress), 'D2: DWARF 4 units, line programs v2 and v4');
      Progress.Account(Step_D3_SkipsTypeUnit(Progress), 'D3: DWARF 5 type unit skipped');
      Progress.Account(Step_D4_StrxWithoutOffsetsRaises(Progress), 'D4: strx without debug_str_offsets raises');
      Progress.WriteSummary(TEST_NAME);
      Result := Progress.AllPassed;
    finally
      Progress.Free;
    end;
    OutLines := L.ToArray;
  finally
    L.Free;
  end;
end;

initialization
  CrashRegisterTest(
    'Dwarf',
    'DWARF reader of the .gol generators',
    ['crash', 'gol', 'dwarf', 'linenumbers'],
    TDwarf_AllInOne.AutoTest
  );

{$ENDIF}

end.
