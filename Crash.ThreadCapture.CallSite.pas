unit Crash.ThreadCapture.CallSite;

{ What the registered-thread sampler knows about code on the calm path:
  which addresses are executable, whether a stack value is a real return
  address (it follows a call), ARM64 pointer-auth stripping and when the ARM64
  link register still holds the caller.

  A TCrashCodeMap is an immutable snapshot (executable ranges, PAC mask and the
  .eh_frame_hdr module list). CrashCurrentCodeMap hands out a copy of a cached
  one, rebuilt at most once a second; a test builds its own over a synthetic
  code buffer. Never use any of this from a signal handler.

  Copyright (c) 2026 Vizit0r. BSD 2-Clause license (see LICENSE.txt). }

interface

uses
  Crash.Modules,
  Crash.Unwind.EhFrame;

type
  TCrashCodeMap = record
    Ranges: TCrashExecutableRanges;
    Modules: TCrashUnwindModules;
    // Low bits that can hold a user code address (all ones above the highest
    // executable mapping are cleared by NormalizeCodeAddress on ARM64).
    AddressMask: UIntPtr;
    class function Create(const ARanges: TCrashExecutableRanges;
      const AModules: TCrashUnwindModules): TCrashCodeMap; static;
    // One executable range [ALow, AHigh), no modules: for synthetic code.
    class function ForRange(const ALow, AHigh: UIntPtr): TCrashCodeMap; static;

    function FindRange(const AAddress: UIntPtr; const ASize: NativeUInt): Integer;
    // ARM64: strips a pointer-auth signature; identity elsewhere.
    function NormalizeCodeAddress(const AAddress: UIntPtr): UIntPtr;
    // AReturnAddress is executable and directly follows a call instruction.
    function CallSiteIsValid(const AReturnAddress: UIntPtr): Boolean;
    function FunctionStart(const AAddress: UIntPtr; out AStart: UIntPtr): Boolean;
    // ARM64: the frame LR contributes for a thread stopped at AIP, if any.
    function LinkFrame(const AIP, ALinkRegister: UIntPtr;
      out AAddress: UIntPtr): Boolean;
    // Diagnostics: 'ok' or why a return-address candidate is rejected.
    function CheckAddress(const AAddress: UIntPtr): String;
    // Diagnostics: how the LR decision is made at AIP.
    function DescribeLinkDecision(const AIP: UIntPtr): String;
  end;

function CrashCurrentCodeMap: TCrashCodeMap;
procedure CrashResetCodeMap;

// Pure instruction decoders.
function CrashX86FFCallEndsAt(const ABytes: Pointer;
  const ALength: Integer): Boolean;
function CrashARM64InstructionIsCall(const AInstruction: UInt32): Boolean;
function CrashARM64InstructionIsSvc(const AInstruction: UInt32): Boolean;
// STP/STR that spills x30 (LR).
function CrashARM64InstructionSavesLR(const AInstruction: UInt32): Boolean;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs;

const
  CODE_MAP_TTL_MS = 1000;
  LR_SCAN_MAX_WORDS = 4096;

type
  TCrashInstructionBytes = array [0..7] of Byte;
  PCrashInstructionBytes = ^TCrashInstructionBytes;

var
  GLock: TCriticalSection;
  GMap: TCrashCodeMap;
  GMapTick: UInt64 = 0;
  GMapValid: Boolean = False;

function CodeAddressMaskFor(const ARanges: TCrashExecutableRanges): UIntPtr;
var
  I: Integer;
  Highest: UIntPtr;
begin
  Highest := 0;
  for I := 0 to High(ARanges) do
    if ARanges[I].HighAddress > Highest then
      Highest := ARanges[I].HighAddress;
  if Highest <= 1 then
    Exit(High(UIntPtr));
  Result := 1;
  while (Result < Highest - 1) and (Result < High(UIntPtr) shr 1) do
    Result := (Result shl 1) or 1;
end;

function CrashX86FFCallEndsAt(const ABytes: Pointer;
  const ALength: Integer): Boolean;
var
  B: PCrashInstructionBytes;
  I, ModRM, ModBits, RMBits, SIB, DispBytes: Integer;
begin
  Result := False;
  if (ABytes = nil) or (ALength < 2) or (ALength > 8) then
    Exit;
  B := PCrashInstructionBytes(ABytes);
  I := 0;
  if (B^[I] >= $40) and (B^[I] <= $4F) then
    Inc(I);
  if (I >= ALength) or (B^[I] <> $FF) then
    Exit;
  Inc(I);
  if I >= ALength then
    Exit;
  ModRM := B^[I];
  Inc(I);
  if ((ModRM shr 3) and 7) <> 2 then
    Exit;
  ModBits := ModRM shr 6;
  RMBits := ModRM and 7;
  DispBytes := 0;
  if ModBits <> 3 then
  begin
    if RMBits = 4 then
    begin
      if I >= ALength then
        Exit;
      SIB := B^[I];
      Inc(I);
      if (ModBits = 0) and ((SIB and 7) = 5) then
        DispBytes := 4;
    end
    else if (ModBits = 0) and (RMBits = 5) then
      DispBytes := 4;
    if ModBits = 1 then
      DispBytes := 1
    else if ModBits = 2 then
      DispBytes := 4;
  end;
  Inc(I, DispBytes);
  Result := I = ALength;
end;

function CrashARM64InstructionIsCall(const AInstruction: UInt32): Boolean;
const
  BL_MASK = $FC000000;
  BL_VALUE = $94000000;
  BLR_MASK = $FFFFFC1F;
  BLR_VALUE = $D63F0000;
begin
  Result := ((AInstruction and BL_MASK) = BL_VALUE) or
    ((AInstruction and BLR_MASK) = BLR_VALUE);
end;

function CrashARM64InstructionIsSvc(const AInstruction: UInt32): Boolean;
begin
  Result := (AInstruction and $FFE0001F) = $D4000001;
end;

function CrashARM64InstructionSavesLR(const AInstruction: UInt32): Boolean;
var
  Op: UInt32;
begin
  Op := AInstruction and $FFC00000;
  // STP Xt, Xt2: post-index, signed offset, pre-index
  if (Op = $A8800000) or (Op = $A9000000) or (Op = $A9800000) then
    Exit(((AInstruction and $1F) = 30) or
      (((AInstruction shr 10) and $1F) = 30));
  // STR Xt, [Xn, #uimm]
  if Op = $F9000000 then
    Exit((AInstruction and $1F) = 30);
  // STR Xt, [Xn, #simm]! / [Xn], #simm
  Op := AInstruction and $FFE00C00;
  Result := ((Op = $F8000C00) or (Op = $F8000400)) and
    ((AInstruction and $1F) = 30);
end;

{ TCrashCodeMap }

class function TCrashCodeMap.Create(const ARanges: TCrashExecutableRanges;
  const AModules: TCrashUnwindModules): TCrashCodeMap;
begin
  Result.Ranges := ARanges;
  Result.Modules := AModules;
  Result.AddressMask := CodeAddressMaskFor(ARanges);
end;

class function TCrashCodeMap.ForRange(const ALow,
  AHigh: UIntPtr): TCrashCodeMap;
var
  Ranges: TCrashExecutableRanges;
begin
  SetLength(Ranges, 1);
  Ranges[0].LowAddress := ALow;
  Ranges[0].HighAddress := AHigh;
  Result := TCrashCodeMap.Create(Ranges, nil);
end;

function TCrashCodeMap.FindRange(const AAddress: UIntPtr;
  const ASize: NativeUInt): Integer;
var
  I: Integer;
begin
  Result := -1;
  if ASize = 0 then
    Exit;
  for I := 0 to High(Ranges) do
    if (AAddress >= Ranges[I].LowAddress) and
       (AAddress < Ranges[I].HighAddress) and
       (ASize <= Ranges[I].HighAddress - AAddress) then
      Exit(I);
end;

// ARM64 pointer authentication signs the LR a function saves (bionic on newer
// Android, arm64e system code): the signature lives in the bits above the
// user VA. Stripping them is safe because every candidate is still checked
// against the executable ranges and for a preceding BL/BLR.
function TCrashCodeMap.NormalizeCodeAddress(const AAddress: UIntPtr): UIntPtr;
begin
  {$IF Defined(CPUARM64)}
  Result := AAddress and AddressMask;
  {$ELSE}
  Result := AAddress;
  {$ENDIF}
end;

function TCrashCodeMap.CallSiteIsValid(const AReturnAddress: UIntPtr): Boolean;
{$IF Defined(CPUX64)}
var
  Bytes: TCrashInstructionBytes;
  RangeIndex, Available, Offset, InstructionLength: Integer;
  ReadAddress, TargetAddress, DistanceFromRangeLow: UIntPtr;
  RelativeTarget: Int32;
begin
  Result := False;
  RangeIndex := FindRange(AReturnAddress, 1);
  if RangeIndex < 0 then
    Exit;
  if AReturnAddress <= Ranges[RangeIndex].LowAddress then
    Exit;
  DistanceFromRangeLow := AReturnAddress - Ranges[RangeIndex].LowAddress;
  if DistanceFromRangeLow > SizeOf(Bytes) then
    Available := SizeOf(Bytes)
  else
    Available := Integer(DistanceFromRangeLow);
  if Available < 2 then
    Exit;
  ReadAddress := AReturnAddress - UIntPtr(Available);
  FillChar(Bytes, SizeOf(Bytes), 0);
  Offset := SizeOf(Bytes) - Available;
  if not CrashTryReadProcessMemory(ReadAddress, @Bytes[Offset], Available) then
    Exit;

  if (Available >= 5) and (Bytes[SizeOf(Bytes) - 5] = $E8) then
  begin
    Move(Bytes[SizeOf(Bytes) - 4], RelativeTarget, SizeOf(RelativeTarget));
    if RelativeTarget >= 0 then
    begin
      if UIntPtr(RelativeTarget) <= High(UIntPtr) - AReturnAddress then
      begin
        TargetAddress := AReturnAddress + UIntPtr(RelativeTarget);
        if FindRange(TargetAddress, 1) >= 0 then
          Exit(True);
      end;
    end;
    if RelativeTarget < 0 then
      if UIntPtr(-Int64(RelativeTarget)) <= AReturnAddress then
      begin
        TargetAddress := AReturnAddress - UIntPtr(-Int64(RelativeTarget));
        if FindRange(TargetAddress, 1) >= 0 then
          Exit(True);
      end;
  end;

  for InstructionLength := 2 to Available do
    if CrashX86FFCallEndsAt(@Bytes[SizeOf(Bytes) - InstructionLength],
         InstructionLength) then
      Exit(True);
end;
{$ELSEIF Defined(CPUARM64)}
var
  InstructionAddress: UIntPtr;
  Instruction: UInt32;
begin
  Result := False;
  if (AReturnAddress < SizeOf(Instruction)) or
     ((AReturnAddress and 3) <> 0) or
     (FindRange(AReturnAddress, 1) < 0) then
    Exit;
  InstructionAddress := AReturnAddress - SizeOf(Instruction);
  if FindRange(InstructionAddress, SizeOf(Instruction)) < 0 then
    Exit;
  Instruction := 0;
  if not CrashTryReadProcessMemory(InstructionAddress, @Instruction,
       SizeOf(Instruction)) then
    Exit;
  Result := CrashARM64InstructionIsCall(Instruction);
end;
{$ELSE}
begin
  Result := False;
end;
{$ENDIF}

function TCrashCodeMap.FunctionStart(const AAddress: UIntPtr;
  out AStart: UIntPtr): Boolean;
begin
  Result := CrashFindFunctionStart(Modules, AAddress, AStart);
end;

{$IF Defined(CPUARM64)}
function ReadCodeWord(const AMap: TCrashCodeMap; const AAddress: UIntPtr;
  out AWord: UInt32): Boolean;
begin
  AWord := 0;
  Result := ((AAddress and 3) = 0) and
    (AMap.FindRange(AAddress, SizeOf(AWord)) >= 0) and
    CrashTryReadProcessMemory(AAddress, @AWord, SizeOf(AWord));
end;

// A thread blocked in the kernel sits in a leaf syscall stub: the PC is on the
// SVC (restarted syscall) or right after it.
function InterruptedInSyscallStub(const AMap: TCrashCodeMap;
  const AIP: UIntPtr): Boolean;
var
  Word: UInt32;
begin
  Result := False;
  if AIP < SizeOf(Word) then
    Exit;
  if ReadCodeWord(AMap, AIP - SizeOf(Word), Word) and
     CrashARM64InstructionIsSvc(Word) then
    Exit(True);
  Result := ReadCodeWord(AMap, AIP, Word) and CrashARM64InstructionIsSvc(Word);
end;

// True when the function at AStart has not spilled x30 before AIP: LR then
// still holds its caller's return address (a frameless leaf, or a prologue).
function LinkRegisterLiveAt(const AMap: TCrashCodeMap; const AStart,
  AIP: UIntPtr; out AKnown: Boolean): Boolean;
var
  P: UIntPtr;
  Word: UInt32;
begin
  Result := False;
  AKnown := False;
  if (AIP < AStart) or ((AIP - AStart) div 4 > LR_SCAN_MAX_WORDS) then
    Exit;
  P := AStart;
  while P < AIP do
  begin
    if not ReadCodeWord(AMap, P, Word) then
      Exit;
    if CrashARM64InstructionSavesLR(Word) then
    begin
      AKnown := True;
      Exit(False);
    end;
    Inc(P, 4);
  end;
  AKnown := True;
  Result := True;
end;

// LR is the caller of the function at AIP while that function has not
// spilled it. Without an FDE only a syscall stub is trusted.
function LinkRegisterLive(const AMap: TCrashCodeMap; const AIP: UIntPtr): Boolean;
var
  Start: UIntPtr;
  Known: Boolean;
begin
  Result := False;
  Known := False;
  if AMap.FunctionStart(AIP, Start) then
    Result := LinkRegisterLiveAt(AMap, Start, AIP, Known);
  if not Known then
    Result := InterruptedInSyscallStub(AMap, AIP);
end;
{$ENDIF}

// ARM64 keeps the return address in LR until a function spills it, so the
// caller of a frameless leaf (syscall stubs, small Delphi leaves) is in no
// frame record. LR is used only where it is provably still live.
function TCrashCodeMap.LinkFrame(const AIP, ALinkRegister: UIntPtr;
  out AAddress: UIntPtr): Boolean;
begin
  AAddress := 0;
  Result := False;
  {$IF Defined(CPUARM64)}
  if (ALinkRegister = 0) or (AIP = 0) then
    Exit;
  if not LinkRegisterLive(Self, AIP) then
    Exit;
  AAddress := NormalizeCodeAddress(ALinkRegister);
  Result := (AAddress <> AIP) and CallSiteIsValid(AAddress);
  {$ENDIF}
end;

function TCrashCodeMap.CheckAddress(const AAddress: UIntPtr): String;
var
  Address: UIntPtr;
begin
  Address := NormalizeCodeAddress(AAddress);
  if FindRange(Address, 1) < 0 then
    Result := 'no-exec-range'
  else if not CallSiteIsValid(Address) then
    Result := 'not-after-call'
  else
    Result := 'ok';
  if Address <> AAddress then
    Result := Result + ' (pac-stripped)';
end;

function TCrashCodeMap.DescribeLinkDecision(const AIP: UIntPtr): String;
{$IF Defined(CPUARM64)}
var
  Start: UIntPtr;
  Known, Live: Boolean;
begin
  if FunctionStart(AIP, Start) then
  begin
    Live := LinkRegisterLiveAt(Self, Start, AIP, Known);
    Result := Format('fde-start=$%x+$%x lr-live=%s known=%s ',
      [UInt64(Start), UInt64(AIP - Start), BoolToStr(Live, True),
       BoolToStr(Known, True)]);
  end
  else
    Result := 'no-fde ';
  Result := Result + 'svc=' +
    BoolToStr(InterruptedInSyscallStub(Self, AIP), True);
end;
{$ELSE}
begin
  Result := 'no-lr-on-this-cpu';
end;
{$ENDIF}

function CrashCurrentCodeMap: TCrashCodeMap;
var
  NowTick: UInt64;
  Ranges: TCrashExecutableRanges;
  Modules: TCrashUnwindModules;
begin
  GLock.Enter;
  try
    NowTick := TThread.GetTickCount64;
    if (not GMapValid) or (NowTick - GMapTick >= CODE_MAP_TTL_MS) then
    begin
      Ranges := nil;
      Modules := nil;
      try
        Ranges := CrashEnumerateReadableExecutableRanges;
      except
        Ranges := nil;
      end;
      {$IF Defined(CPUARM64)}
      // Function bounds only feed the ARM64 LR decision.
      try
        Modules := CrashEnumerateUnwindModules;
      except
        Modules := nil;
      end;
      {$ENDIF}
      GMap := TCrashCodeMap.Create(Ranges, Modules);
      GMapTick := NowTick;
      GMapValid := Length(Ranges) > 0;
    end;
    Result := GMap;
  finally
    GLock.Leave;
  end;
end;

procedure CrashResetCodeMap;
begin
  GLock.Enter;
  try
    GMap := Default(TCrashCodeMap);
    GMapTick := 0;
    GMapValid := False;
  finally
    GLock.Leave;
  end;
end;

initialization
  GLock := TCriticalSection.Create;

finalization
  CrashResetCodeMap;
  GLock.Free;

end.
