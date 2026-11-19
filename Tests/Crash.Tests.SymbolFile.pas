unit Crash.Tests.SymbolFile;

// ===========================================================================
//  SymbolFile - the .gosym side-file: GosymWriter (LNG_ELF --gosym) writes it
//  from a synthetic .symtab, Crash.SymbolFile reads it back.
//
//    S1  Only LOCAL FUNC symbols are written, sorted, one per address (the
//        global function, the local object and the undefined symbol are not).
//    S2  Lookup: inside a sized function, past its end, a sizeless function
//        bounded by the next entry, below the first entry; source files.
//    S3  A side-file of another build-id is refused.
//    S4  Truncated / corrupt files are refused.
//    S5  Linux: CrashReadElfBuildID on the running executable gives a build-id
//        and a page-aligned link base that the main module address is above.
//
//  Copyright (c) 2026 Vizit0r. BSD 2-Clause license (see LICENSE.txt).
// ===========================================================================

interface

{$IFDEF AUTOTESTS}

uses
  System.SysUtils,
  Crash.Tests.Registry;

type
  TSymbolFile_AllInOne = class
  public
    class function AutoTest(out OutLines: TArray<string>): Boolean; static;
  end;

{$ENDIF}

implementation

{$IFDEF AUTOTESTS}

uses
  System.Classes,
  System.IOUtils,
  System.Generics.Collections,
  Crash.SymbolFile,
  GosymWriter,
  Crash.CallStack,
  Crash.Tests.Progress;

const
  TEST_NAME = 'SymbolFile';

  // Pinned independently of the writer/reader.
  STB_LOCAL_  = 0;
  STB_GLOBAL_ = 1;
  STT_OBJECT_ = 1;
  STT_FUNC_   = 2;

  BUILD_ID: TGUID = '{00112233-4455-6677-8899-AABBCCDDEEFF}';

type
  TSym = packed record
    st_name: UInt32;
    st_info: Byte;
    st_other: Byte;
    st_shndx: UInt16;
    st_value: UInt64;
    st_size: UInt64;
  end;

  TSymtabBuilder = class
  private
    FSyms: TList<TSym>;
    FStr: TMemoryStream;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Add(const AName: RawByteString; const ABind, AType: Byte;
      const AShndx: UInt16; const AValue, ASize: UInt64);
    function Symtab: TBytes;
    function Strtab: TBytes;
  end;

constructor TSymtabBuilder.Create;
var
  Zero: Byte;
  S: TSym;
begin
  inherited;
  FSyms := TList<TSym>.Create;
  FStr := TMemoryStream.Create;
  Zero := 0;
  FStr.WriteBuffer(Zero, 1);
  S := Default(TSym); // index 0: the null symbol
  FSyms.Add(S);
end;

destructor TSymtabBuilder.Destroy;
begin
  FStr.Free;
  FSyms.Free;
  inherited;
end;

procedure TSymtabBuilder.Add(const AName: RawByteString; const ABind, AType: Byte;
  const AShndx: UInt16; const AValue, ASize: UInt64);
var
  S: TSym;
  Zero: Byte;
begin
  S := Default(TSym);
  S.st_name := UInt32(FStr.Position);
  FStr.WriteBuffer(AName[1], Length(AName));
  Zero := 0;
  FStr.WriteBuffer(Zero, 1);
  S.st_info := (ABind shl 4) or AType;
  S.st_shndx := AShndx;
  S.st_value := AValue;
  S.st_size := ASize;
  FSyms.Add(S);
end;

function TSymtabBuilder.Symtab: TBytes;
var
  I: Integer;
  S: TSym;
begin
  SetLength(Result, FSyms.Count * SizeOf(TSym));
  for I := 0 to FSyms.Count - 1 do
  begin
    S := FSyms[I];
    Move(S, Result[I * SizeOf(TSym)], SizeOf(TSym));
  end;
end;

function TSymtabBuilder.Strtab: TBytes;
begin
  SetLength(Result, FStr.Size);
  Move(FStr.Memory^, Result[0], FStr.Size);
end;

function BuildIDBytes(const AID: TGUID): TCrashSymbolBuildID;
begin
  Move(AID, Result, SizeOf(Result));
end;

{ Writes a .gosym for the fixture symtab, returns its bytes. }
function WriteFixture(Progress: TCrashTestProgress; out ACount: Integer): TBytes;
var
  B: TSymtabBuilder;
  Files: TDictionary<UInt64, String>;
  Path: String;
begin
  B := TSymtabBuilder.Create;
  Files := TDictionary<UInt64, String>.Create;
  try
    // deliberately unsorted
    B.Add('_ZN4Unit6SecondEv', STB_LOCAL_, STT_FUNC_, 1, $2000, $40);
    B.Add('_ZN4Unit5FirstEv', STB_LOCAL_, STT_FUNC_, 1, $1000, $100);
    B.Add('_ZN4Unit5AliasEv', STB_LOCAL_, STT_FUNC_, 1, $1000, $100); // same address
    B.Add('_ZN4Unit8SizelessEv', STB_LOCAL_, STT_FUNC_, 1, $3000, 0);
    B.Add('_ZN4Unit4LastEv', STB_LOCAL_, STT_FUNC_, 1, $3100, $10);
    B.Add('_ZN4Unit6GlobalEv', STB_GLOBAL_, STT_FUNC_, 1, $1800, $20);
    B.Add('_ZN4Unit4DataE', STB_LOCAL_, STT_OBJECT_, 2, $5000, 8);
    B.Add('undefined_import', STB_LOCAL_, STT_FUNC_, 0, $6000, 0);
    Files.Add($1000, '/build/src/Unit.First.pas');
    Files.Add($3000, 'Unit.Sizeless.pas');
    Path := TPath.Combine(TPath.GetTempPath,
      Format('crash_symbolfile_%d.gosym', [TThread.CurrentThread.ThreadID]));
    try
      ACount := GosymWriteFile(Path, BUILD_ID, B.Symtab, B.Strtab, Files);
      Result := TFile.ReadAllBytes(Path);
    finally
      TFile.Delete(Path);
    end;
  finally
    Files.Free;
    B.Free;
  end;
end;

function Expect(Progress: TCrashTestProgress; const AFile: TCrashSymbolFile;
  const ATag: string; const AAddr: UInt64; const AWantName: RawByteString;
  const AWantStart: UInt64; const AWantFile: string): Boolean;
var
  Name: RawByteString;
  Start: UInt64;
  SrcFile: string;
  Found: Boolean;
begin
  Found := AFile.Lookup(AAddr, Name, Start, SrcFile);
  if AWantName = '' then
    Result := not Found
  else
    Result := Found and (Name = AWantName) and (Start = AWantStart) and
      (SrcFile = AWantFile);
  if not Result then
    Progress.InfoFmt('%s: $%x -> found=%s name=%s start=$%x file=%s',
      [ATag, AAddr, BoolToStr(Found, True), String(Name), Start, SrcFile]);
end;

function Step_S1_WritesLocalFunctions(Progress: TCrashTestProgress): Boolean;
var
  Data: TBytes;
  Count: Integer;
  F: TCrashSymbolFile;
begin
  Data := WriteFixture(Progress, Count);
  // First/Alias share $1000 -> one entry; Second, Sizeless, Last
  Result := Count = 4;
  if not Result then
    Progress.InfoFmt('S1: %d entries written, want 4', [Count]);
  F := TCrashSymbolFile.Create;
  try
    Result := Result and F.Load(Data, BuildIDBytes(BUILD_ID)) and (F.Count = 4);
    // the global function is not in the side-file
    Result := Result and Expect(Progress, F, 'S1 global', $1810, '', 0, '');
  finally
    F.Free;
  end;
end;

function Step_S2_Lookup(Progress: TCrashTestProgress): Boolean;
var
  Data: TBytes;
  Count: Integer;
  F: TCrashSymbolFile;
begin
  Data := WriteFixture(Progress, Count);
  F := TCrashSymbolFile.Create;
  try
    Result := F.Load(Data, BuildIDBytes(BUILD_ID)) and
      // same-address tie: the name that sorts first
      Expect(Progress, F, 'S2 start', $1000, '_ZN4Unit5AliasEv', $1000, 'Unit.First.pas') and
      Expect(Progress, F, 'S2 inside', $10FF, '_ZN4Unit5AliasEv', $1000, 'Unit.First.pas') and
      Expect(Progress, F, 'S2 past end', $1100, '', 0, '') and
      Expect(Progress, F, 'S2 no file', $2010, '_ZN4Unit6SecondEv', $2000, '') and
      Expect(Progress, F, 'S2 sizeless', $30FF, '_ZN4Unit8SizelessEv', $3000, 'Unit.Sizeless.pas') and
      Expect(Progress, F, 'S2 next entry', $3105, '_ZN4Unit4LastEv', $3100, '') and
      Expect(Progress, F, 'S2 after last', $3110, '', 0, '') and
      Expect(Progress, F, 'S2 below first', $0FFF, '', 0, '');
  finally
    F.Free;
  end;
end;

function Step_S3_RefusesOtherBuild(Progress: TCrashTestProgress): Boolean;
var
  Data: TBytes;
  Count: Integer;
  F: TCrashSymbolFile;
  Other: TCrashSymbolBuildID;
begin
  Data := WriteFixture(Progress, Count);
  Other := BuildIDBytes(BUILD_ID);
  Other[15] := Other[15] xor 1;
  F := TCrashSymbolFile.Create;
  try
    Result := (not F.Load(Data, Other)) and (not F.Active) and
      Expect(Progress, F, 'S3', $1000, '', 0, '');
  finally
    F.Free;
  end;
end;

function Step_S4_RefusesCorrupt(Progress: TCrashTestProgress): Boolean;
var
  Data, Bad: TBytes;
  Count: Integer;
  F: TCrashSymbolFile;
  ID: TCrashSymbolBuildID;
begin
  Data := WriteFixture(Progress, Count);
  ID := BuildIDBytes(BUILD_ID);
  F := TCrashSymbolFile.Create;
  try
    Result := True;
    Bad := Copy(Data, 0, Length(Data) - 1);
    if F.Load(Bad, ID) then
    begin
      Progress.Info('S4a: truncated file accepted');
      Result := False;
    end;
    Bad := Copy(Data);
    PUInt32(@Bad[12])^ := $10000; // entry count beyond the string table
    if F.Load(Bad, ID) then
    begin
      Progress.Info('S4b: oversized entry count accepted');
      Result := False;
    end;
    Bad := Copy(Data);
    Bad[0] := Bad[0] xor $FF;
    if F.Load(Bad, ID) then
    begin
      Progress.Info('S4c: bad signature accepted');
      Result := False;
    end;
    if F.Load(nil, ID) then
    begin
      Progress.Info('S4d: empty data accepted');
      Result := False;
    end;
  finally
    F.Free;
  end;
end;

{$IF Defined(LINUX)}
function Step_S5_RunningElf(Progress: TCrashTestProgress): Boolean;
var
  ID: TCrashSymbolBuildID;
  LinkBase: UInt64;
  I: Integer;
  NonZero: Boolean;
begin
  Result := CrashReadElfBuildID(ParamStr(0), ID, LinkBase);
  if not Result then
  begin
    Progress.Info('S5: no build-id read from the running executable');
    Exit;
  end;
  NonZero := False;
  for I := 0 to High(ID) do
    NonZero := NonZero or (ID[I] <> 0);
  Result := NonZero and ((LinkBase and $FFF) = 0) and
    (UInt64(TCrashCapture.MainModuleAddress) >= LinkBase);
  if not Result then
    Progress.InfoFmt('S5: id nonzero=%s link base=$%x main module=$%x',
      [BoolToStr(NonZero, True), LinkBase, UInt64(TCrashCapture.MainModuleAddress)]);
end;
{$ENDIF}

class function TSymbolFile_AllInOne.AutoTest(out OutLines: TArray<string>): Boolean;
var
  L: TList<string>;
  Progress: TCrashTestProgress;
begin
  L := TList<string>.Create;
  try
    Progress := TCrashTestProgress.Create(L);
    try
      Progress.Account(Step_S1_WritesLocalFunctions(Progress), 'S1: only local functions, one per address');
      Progress.Account(Step_S2_Lookup(Progress), 'S2: lookup bounds and source files');
      Progress.Account(Step_S3_RefusesOtherBuild(Progress), 'S3: a side-file of another build is refused');
      Progress.Account(Step_S4_RefusesCorrupt(Progress), 'S4: truncated or corrupt side-files are refused');
      {$IF Defined(LINUX)}
      Progress.Account(Step_S5_RunningElf(Progress), 'S5: build-id and link base of the running executable');
      {$ENDIF}
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
    'SymbolFile',
    'The .gosym side-file writer and reader',
    ['crash', 'gosym', 'symbols'],
    TSymbolFile_AllInOne.AutoTest
  );

{$ENDIF}

end.
