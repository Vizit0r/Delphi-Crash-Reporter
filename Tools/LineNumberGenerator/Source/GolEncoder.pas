unit GolEncoder;

{ Shared .gol state-machine encoder for the LNG (Mach-O) and LNG_ELF (ELF)
  generators - one implementation instead of two hand-synced copies. Pure and
  platform-free: line rows in, opcode program out; the callers own the .gol
  header and the file IO. The format itself is documented and consumed in
  Crash.LineNumbers.pas.

  Part of the Crash Reporter library - standalone, EurekaLog-compatible
  crash/exception reporting for Delphi cross-platform targets. }

interface

uses
  System.Classes;

type
  { One line-number row: the VM address of the first instruction generated for
    a source line. }
  TGolLine = record
    Address: UInt64;
    Line: Integer;
  end;

{ Sort ALines by address and append the .gol state-machine program to ABuffer.
  Returns the number of emitted entries (the header Count field). Duplicate
  addresses keep the smallest-line row (the sort breaks address ties by line,
  so the winner is deterministic and .gol builds are byte-reproducible);
  deltas always run against the last WRITTEN entry - the decoder's state
  machine never sees the skipped duplicates. Raises EInvalidOperation when
  ALines is nil or the sorted address span does not fit the 4 GB format
  limit. }
function GolEncodeLines(var ALines: TArray<TGolLine>;
  const ABuffer: TStream): Integer;

implementation

uses
  System.SysUtils,
  System.Generics.Collections,
  System.Generics.Defaults,
  Crash.LineNumbers;

procedure AppendByte(const AStream: TStream; const AValue: Byte);
begin
  AStream.WriteBuffer(AValue, 1);
end;

procedure AppendVarInt(const AStream: TStream; const AValue: UInt32);
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

function GolEncodeLines(var ALines: TArray<TGolLine>;
  const ABuffer: TStream): Integer;
var
  I, LineDelta: Integer;
  AddressDelta: Int64;
  PrevAddress: UInt64;
  PrevLine: Integer;
begin
  if (ALines = nil) then
    raise EInvalidOperation.Create('Line number information not available');

  TArray.Sort<TGolLine>(ALines, TComparer<TGolLine>.Construct(
    function(const ALeft, ARight: TGolLine): Integer
    begin
      // Branchy compare: a UInt64 subtraction narrowed to Integer flips sign
      // for far-apart addresses and breaks the sort order. Address ties break
      // by Line: TArray.Sort is unstable, and a deterministic duplicate winner
      // keeps .gol builds byte-reproducible.
      if ALeft.Address < ARight.Address then Result := -1
      else if ALeft.Address > ARight.Address then Result := 1
      else if ALeft.Line < ARight.Line then Result := -1
      else if ALeft.Line > ARight.Line then Result := 1
      else Result := 0;
    end));

  AddressDelta := Int64(ALines[Length(ALines) - 1].Address - ALines[0].Address);
  if (AddressDelta <= 0) or (AddressDelta > $FFFFFFFF) then
    raise EInvalidOperation.Create('Line number addresses exceed 4 GB range');

  { Create state machine program }
  Result := 0;
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
      // Skip duplicate-address rows (macOS dSYMs and ELF DWARF both ship them
      // for inlined / generic-instantiated code). The smallest-line row wins
      // (see the sort tie-break).
      Continue;
    end;
    PrevAddress := ALines[I].Address;
    PrevLine := ALines[I].Line;

    if (LineDelta >= 1) and (LineDelta <= 4) then
    begin
      if (AddressDelta <= 63) then
      begin
        { Most common case. Can be handled with single opcode without arguments }
        AppendByte(ABuffer, (LineDelta - 1) + ((AddressDelta - 1) * 4));
        Inc(Result);
        Continue;
      end
      else if (AddressDelta <= (63 * 2)) then
      begin
        { We can use a 2-byte value for this }
        AppendByte(ABuffer, OP_ADVANCE_ADDR);
        AppendByte(ABuffer, (LineDelta - 1) + ((AddressDelta - 63 - 1) * 4));
        Inc(Result);
        Continue;
      end;
    end;

    { We need more than 2 bytes (uncommon).
      When LineDelta <= 0, we *must* encode using an absolute line number.
      Otherwise, we use relative encoding. }
    if (LineDelta <= 0) then
    begin
      AppendByte(ABuffer, OP_ADVANCE_ABS);
      AppendVarInt(ABuffer, AddressDelta - 1);
      AppendVarInt(ABuffer, ALines[I].Line);
    end
    else
    begin
      AppendByte(ABuffer, OP_ADVANCE_REL);
      AppendVarInt(ABuffer, AddressDelta - 1);
      AppendVarInt(ABuffer, LineDelta - 1);
    end;
    Inc(Result);
  end;
end;

end.
