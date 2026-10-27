unit Crash.Tests.GolCodec;

// ===========================================================================
//  GolCodec — pure round-trip coverage of the shared .gol state-machine
//  encoder (GolEncoder.pas, used by both the LNG and LNG_ELF generators).
//
//  The reference decoder below implements the format spec from
//  Crash.LineNumbers.pas (ops 0-251 fused advance, 252 = advance-addr,
//  253 = advance-rel, 254 = advance-abs, LEB128 varints) and is kept
//  deliberately independent of the production decoders, so an encoder
//  regression cannot hide behind a matching decoder change.
//
//    G1  Fused-opcode window (addr delta 1..63, line delta 1..4): exact bytes.
//    G2  Duplicate addresses with DIFFERENT lines: a skipped row must not
//        shift later lines (deltas run against the last WRITTEN row).
//    G3  REF_OP_ADVANCE_ADDR window (64..126) exact bytes; 127 falls to REL.
//    G4  Zero/negative line delta -> REF_OP_ADVANCE_ABS with the absolute line.
//    G5  Unsorted input is sorted by the encoder, including far-apart
//        addresses whose UInt64 delta breaks an Integer-narrowed comparator.
//    G6  LEB128 varint boundaries (1-byte vs 2-byte) exact bytes.
//    G7  Contract raises: nil input, single row (zero span), span > 4 GB.
//    G8  Reference-decoder self-check: truncated varint / op 255 rejected.
//    G9  Deterministic bulk round-trip (dup clusters, line jumps both ways).
//    G10 Production format constants match the literals pinned here.
//
//  Copyright (c) 2026 Vizit0r. BSD 2-Clause license (see LICENSE.txt).
// ===========================================================================

interface

{$IFDEF AUTOTESTS}

uses
  System.SysUtils,
  Crash.Tests.Registry;

type
  TGolCodec_AllInOne = class
  public
    class function AutoTest(out OutLines: TArray<string>): Boolean; static;
  end;

{$ENDIF}

implementation

{$IFDEF AUTOTESTS}

uses
  System.Classes,
  System.Generics.Collections,
  Crash.LineNumbers,
  GolEncoder,
  Crash.Tests.Progress;

const
  TEST_NAME = 'GolCodec';

  // Format literals pinned independently of production: if Crash.LineNumbers'
  // opcode constants ever drift, G10 goes red instead of every expectation
  // here silently drifting along with them.
  REF_OP_ADVANCE_ADDR = 252;
  REF_OP_ADVANCE_REL  = 253;
  REF_OP_ADVANCE_ABS  = 254;

function ML(const AAddr: UInt64; const ALine: Integer): TGolLine;
begin
  Result.Address := AAddr;
  Result.Line := ALine;
end;

function EncodeToBytes(var ALines: TArray<TGolLine>; out ACount: Integer): TBytes;
var
  MS: TMemoryStream;
begin
  MS := TMemoryStream.Create;
  try
    ACount := GolEncodeLines(ALines, MS);
    SetLength(Result, MS.Size);
    if MS.Size > 0 then
      Move(MS.Memory^, Result[0], MS.Size);
  finally
    MS.Free;
  end;
end;

function RefDecode(const AProg: TBytes; const AStartAddr: UInt64;
  const AStartLine: Integer; out ARows: TArray<TGolLine>): Boolean;
// Reference implementation of the .gol opcode program (format spec in
// Crash.LineNumbers.pas). Row 0 is the header anchor; every executed opcode
// appends exactly one row. False on any malformed input.
var
  L: TList<TGolLine>;
  Pos, Len: Integer;
  Addr: UInt64;
  Line: Integer;
  Op, Op2: Byte;
  A1, A2: UInt32;

  function ReadVarInt(out AValue: UInt32): Boolean;
  var
    Shift: Integer;
    B: Byte;
  begin
    Result := False;
    AValue := 0;
    Shift := 0;
    repeat
      if Pos >= Len then Exit; // truncated varint
      B := AProg[Pos];
      Inc(Pos);
      AValue := AValue or (UInt32(B and $7F) shl Shift);
      Inc(Shift, 7);
    until (B and $80) = 0;
    Result := True;
  end;

  procedure Emit;
  begin
    L.Add(ML(Addr, Line));
  end;

begin
  Result := False;
  ARows := nil;
  L := TList<TGolLine>.Create;
  try
    Pos := 0;
    Len := Length(AProg);
    Addr := AStartAddr;
    Line := AStartLine;
    Emit; // header anchor row
    while Pos < Len do
    begin
      Op := AProg[Pos];
      Inc(Pos);
      if Op < REF_OP_ADVANCE_ADDR then
      begin
        Inc(Addr, (Op shr 2) + 1);
        Inc(Line, (Op and 3) + 1);
        Emit;
      end
      else case Op of
        REF_OP_ADVANCE_ADDR:
          begin
            if Pos >= Len then Exit;
            Op2 := AProg[Pos];
            Inc(Pos);
            if Op2 >= REF_OP_ADVANCE_ADDR then Exit; // must be a fused opcode
            Inc(Addr, 63 + (Op2 shr 2) + 1);
            Inc(Line, (Op2 and 3) + 1);
            Emit;
          end;
        REF_OP_ADVANCE_REL:
          begin
            if not ReadVarInt(A1) then Exit;
            if not ReadVarInt(A2) then Exit;
            Inc(Addr, A1 + 1);
            Inc(Line, Integer(A2) + 1);
            Emit;
          end;
        REF_OP_ADVANCE_ABS:
          begin
            if not ReadVarInt(A1) then Exit;
            if not ReadVarInt(A2) then Exit;
            Inc(Addr, A1 + 1);
            Line := Integer(A2);
            Emit;
          end;
      else
        Exit; // op 255 is unused by the format
      end;
    end;
    ARows := L.ToArray;
    Result := True;
  finally
    L.Free;
  end;
end;

function SameBytes(const A, B: TBytes; out AWhy: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if Length(A) <> Length(B) then
  begin
    AWhy := Format('program length %d, want %d', [Length(A), Length(B)]);
    Exit;
  end;
  for I := 0 to High(A) do
    if A[I] <> B[I] then
    begin
      AWhy := Format('byte %d is $%.2x, want $%.2x', [I, A[I], B[I]]);
      Exit;
    end;
  Result := True;
end;

function RowsEqual(const A, B: TArray<TGolLine>; out AWhy: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if Length(A) <> Length(B) then
  begin
    AWhy := Format('row count %d, want %d', [Length(A), Length(B)]);
    Exit;
  end;
  for I := 0 to High(A) do
    if (A[I].Address <> B[I].Address) or (A[I].Line <> B[I].Line) then
    begin
      AWhy := Format('row %d is %u:%d, want %u:%d',
        [I, A[I].Address, A[I].Line, B[I].Address, B[I].Line]);
      Exit;
    end;
  Result := True;
end;

function RoundTrip(Progress: TCrashTestProgress; const ATag: string;
  AInput: TArray<TGolLine>; const AExpectRows: TArray<TGolLine>;
  const AExpectBytes: TBytes): Boolean;
// Encode AInput, optionally byte-compare the program, then reference-decode
// and compare the full row table. AExpectBytes = nil skips the byte check.
var
  Prog: TBytes;
  Count: Integer;
  Rows: TArray<TGolLine>;
  Why: string;
begin
  Result := False;
  Prog := EncodeToBytes(AInput, Count);
  if (AExpectBytes <> nil) and (not SameBytes(Prog, AExpectBytes, Why)) then
  begin
    Progress.InfoFmt('%s: %s', [ATag, Why]);
    Exit;
  end;
  if Count <> Length(AExpectRows) - 1 then
  begin
    Progress.InfoFmt('%s: Count=%d, want %d', [ATag, Count, Length(AExpectRows) - 1]);
    Exit;
  end;
  // AInput is sorted in place by the encoder - row 0 is the header anchor.
  if not RefDecode(Prog, AInput[0].Address, AInput[0].Line, Rows) then
  begin
    Progress.InfoFmt('%s: reference decoder rejected the program', [ATag]);
    Exit;
  end;
  if not RowsEqual(Rows, AExpectRows, Why) then
  begin
    Progress.InfoFmt('%s: %s', [ATag, Why]);
    Exit;
  end;
  Result := True;
end;

function ExpectRaise(Progress: TCrashTestProgress; const ATag: string;
  AInput: TArray<TGolLine>): Boolean;
var
  MS: TMemoryStream;
begin
  Result := False;
  MS := TMemoryStream.Create;
  try
    try
      GolEncodeLines(AInput, MS);
      Progress.InfoFmt('%s: no exception raised', [ATag]);
    except
      on EInvalidOperation do
        Result := True;
      on E: Exception do
        Progress.InfoFmt('%s: %s instead of EInvalidOperation', [ATag, E.ClassName]);
    end;
  finally
    MS.Free;
  end;
end;

function Step_G1_FusedWindow(Progress: TCrashTestProgress): Boolean;
begin
  // (100,10)->(101,11): op 0; ->(163,12): delta 62, +1 line: op 61*4 = 244.
  Result := RoundTrip(Progress, 'G1',
    [ML(100, 10), ML(101, 11), ML(163, 12)],
    [ML(100, 10), ML(101, 11), ML(163, 12)],
    [0, 244]);
end;

function Step_G2_DupAddressNoShift(Progress: TCrashTestProgress): Boolean;
begin
  // The audited generator defect: the skipped duplicate (100,20) must not
  // feed the next delta. (100->101) runs from line 10: delta 11 -> REL(0,10);
  // then (102,22): fused op 0. A pre-fix encoder emitted line delta +1 here
  // and every later line came out 10 lower.
  Result := RoundTrip(Progress, 'G2',
    [ML(100, 10), ML(100, 20), ML(101, 21), ML(102, 22)],
    [ML(100, 10), ML(101, 21), ML(102, 22)],
    [REF_OP_ADVANCE_REL, 0, 10, 0]);
  // Same-line duplicates simply collapse.
  Result := Result and RoundTrip(Progress, 'G2b',
    [ML(100, 10), ML(100, 10), ML(101, 11)],
    [ML(100, 10), ML(101, 11)],
    [0]);
end;

function Step_G3_AdvanceAddrWindow(Progress: TCrashTestProgress): Boolean;
begin
  // delta 64 -> [252, 0]; delta 126 line +4 -> [252, 3+62*4=251];
  // delta 127 -> REL(126, 0).
  Result :=
    RoundTrip(Progress, 'G3a', [ML(1000, 5), ML(1064, 6)],
      [ML(1000, 5), ML(1064, 6)], [REF_OP_ADVANCE_ADDR, 0]) and
    RoundTrip(Progress, 'G3b', [ML(1000, 5), ML(1126, 9)],
      [ML(1000, 5), ML(1126, 9)], [REF_OP_ADVANCE_ADDR, 251]) and
    RoundTrip(Progress, 'G3c', [ML(1000, 5), ML(1127, 6)],
      [ML(1000, 5), ML(1127, 6)], [REF_OP_ADVANCE_REL, 126, 0]);
end;

function Step_G4_AbsoluteLine(Progress: TCrashTestProgress): Boolean;
begin
  // Line delta 0 and negative both must use REF_OP_ADVANCE_ABS with the absolute
  // line value (not +1-biased).
  Result :=
    RoundTrip(Progress, 'G4a', [ML(100, 50), ML(200, 50)],
      [ML(100, 50), ML(200, 50)], [REF_OP_ADVANCE_ABS, 99, 50]) and
    RoundTrip(Progress, 'G4b', [ML(100, 50), ML(150, 20)],
      [ML(100, 50), ML(150, 20)], [REF_OP_ADVANCE_ABS, 49, 20]);
end;

function Step_G5_SortsInput(Progress: TCrashTestProgress): Boolean;
begin
  // Shuffled input; the $F0000000-far row breaks an Integer-narrowed
  // comparator (its UInt64 delta has the sign bit set).
  Result :=
    RoundTrip(Progress, 'G5a', [ML(163, 12), ML(100, 10), ML(101, 11)],
      [ML(100, 10), ML(101, 11), ML(163, 12)], [0, 244]) and
    RoundTrip(Progress, 'G5b', [ML($F0000000, 7), ML(0, 1), ML(1, 2)],
      [ML(0, 1), ML(1, 2), ML($F0000000, 7)],
      [0, REF_OP_ADVANCE_REL, $FE, $FF, $FF, $FF, $0E, 4]);
end;

function Step_G6_VarIntBoundaries(Progress: TCrashTestProgress): Boolean;
begin
  // Address delta 128 -> varint(127) = one byte; delta 129 -> varint(128) =
  // two bytes ($80,$01).
  Result :=
    RoundTrip(Progress, 'G6a', [ML(0, 1), ML(128, 10)],
      [ML(0, 1), ML(128, 10)], [REF_OP_ADVANCE_REL, 127, 8]) and
    RoundTrip(Progress, 'G6b', [ML(0, 1), ML(129, 10)],
      [ML(0, 1), ML(129, 10)], [REF_OP_ADVANCE_REL, $80, $01, 8]);
end;

function Step_G7_ContractRaises(Progress: TCrashTestProgress): Boolean;
begin
  Result :=
    ExpectRaise(Progress, 'G7a nil', nil) and
    ExpectRaise(Progress, 'G7b single row', [ML(5, 1)]) and
    ExpectRaise(Progress, 'G7c 4GB span', [ML(0, 1), ML(UInt64($100000001), 2)]);
end;

function Step_G8_RefDecoderRejects(Progress: TCrashTestProgress): Boolean;
var
  Rows: TArray<TGolLine>;
begin
  Result := True;
  if RefDecode([REF_OP_ADVANCE_REL, $80], 0, 1, Rows) then
  begin
    Progress.Info('G8a: truncated varint was accepted');
    Result := False;
  end;
  if RefDecode([255], 0, 1, Rows) then
  begin
    Progress.Info('G8b: op 255 was accepted');
    Result := False;
  end;
  if RefDecode([REF_OP_ADVANCE_ADDR], 0, 1, Rows) then
  begin
    Progress.Info('G8c: dangling REF_OP_ADVANCE_ADDR was accepted');
    Result := False;
  end;
end;

function Step_G9_BulkRoundTrip(Progress: TCrashTestProgress): Boolean;
const
  N = 2000;
var
  Input: TArray<TGolLine>;
  Expected: TList<TGolLine>;
  Prog: TBytes;
  Rows: TArray<TGolLine>;
  Count, I, Line, StepA, StepL: Integer;
  Addr: UInt64;
  Seed: UInt32;
  Why: string;
begin
  Result := False;
  // Deterministic LCG stream: dup clusters (StepA=0), fused-window advances,
  // large gaps, and line jumps in both directions.
  Seed := 12345;
  Addr := 4096;
  Line := 100;
  SetLength(Input, N);
  Expected := TList<TGolLine>.Create;
  try
    for I := 0 to N - 1 do
    begin
      Input[I] := ML(Addr, Line);
      // The smallest line wins for a duplicated address (deterministic sort
      // tie-break in the encoder).
      if (Expected.Count = 0) or (Expected.Last.Address <> Addr) then
        Expected.Add(ML(Addr, Line))
      else if Line < Expected.Last.Line then
        Expected[Expected.Count - 1] := ML(Addr, Line);

      // Via UInt64: the AutoTests config builds with $Q+, a raw UInt32 multiply
      // would raise EIntOverflow.
      Seed := UInt32((UInt64(Seed) * 134775813 + 1) and $FFFFFFFF);
      StepA := (Seed shr 16) mod 200;        // 0..199, 0 = duplicate address
      StepL := Integer((Seed shr 8) mod 21) - 10; // -10..+10
      Inc(Addr, UInt32(StepA));
      Inc(Line, StepL);
      if Line < 1 then
        Line := 1;
    end;

    Prog := EncodeToBytes(Input, Count);
    if Count <> Expected.Count - 1 then
    begin
      Progress.InfoFmt('G9: Count=%d, want %d', [Count, Expected.Count - 1]);
      Exit;
    end;
    if not RefDecode(Prog, Input[0].Address, Input[0].Line, Rows) then
    begin
      Progress.Info('G9: reference decoder rejected the program');
      Exit;
    end;
    if not RowsEqual(Rows, Expected.ToArray, Why) then
    begin
      Progress.InfoFmt('G9: %s', [Why]);
      Exit;
    end;
    Result := True;
  finally
    Expected.Free;
  end;
end;

function Step_G10_FormatConstantsPinned(Progress: TCrashTestProgress): Boolean;
begin
  {$WARN COMPARISON_TRUE OFF}
  Result := (OP_ADVANCE_ADDR = REF_OP_ADVANCE_ADDR) and
            (OP_ADVANCE_REL = REF_OP_ADVANCE_REL) and
            (OP_ADVANCE_ABS = REF_OP_ADVANCE_ABS) and
            (LINE_NUMBER_SIGNATURE = UInt32($4E4C4F47)) and
            ((LINE_NUMBER_VERSION shr 16) = 1);
  {$WARN COMPARISON_TRUE DEFAULT}
  if not Result then
    Progress.Info('G10: Crash.LineNumbers format constants drifted from the pinned literals');
end;

class function TGolCodec_AllInOne.AutoTest(out OutLines: TArray<string>): Boolean;
var
  L: TList<string>;
  Progress: TCrashTestProgress;
begin
  L := TList<string>.Create;
  try
    Progress := TCrashTestProgress.Create(L);
    try
      Progress.Account(Step_G1_FusedWindow(Progress), 'G1: fused-opcode window, exact bytes');
      Progress.Account(Step_G2_DupAddressNoShift(Progress), 'G2: duplicate address does not shift later lines');
      Progress.Account(Step_G3_AdvanceAddrWindow(Progress), 'G3: advance-addr window 64..126, 127 -> REL');
      Progress.Account(Step_G4_AbsoluteLine(Progress), 'G4: zero/negative line delta -> advance-abs');
      Progress.Account(Step_G5_SortsInput(Progress), 'G5: encoder sorts, far-apart addresses keep order');
      Progress.Account(Step_G6_VarIntBoundaries(Progress), 'G6: LEB128 one/two-byte boundaries');
      Progress.Account(Step_G7_ContractRaises(Progress), 'G7: nil / single-row / 4GB-span raise');
      Progress.Account(Step_G8_RefDecoderRejects(Progress), 'G8: reference decoder rejects malformed programs');
      Progress.Account(Step_G9_BulkRoundTrip(Progress), 'G9: bulk deterministic round-trip');
      Progress.Account(Step_G10_FormatConstantsPinned(Progress), 'G10: production format constants match pinned literals');
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
    'GolCodec',
    'GolEncoder (.gol codec)',
    ['crash', 'gol', 'codec', 'linenumbers'],
    TGolCodec_AllInOne.AutoTest
  );

{$ENDIF}

end.
