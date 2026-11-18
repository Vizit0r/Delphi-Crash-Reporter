unit Crash.Unwind.EhFrame;

{ Function lookup through the .eh_frame_hdr search table of the loaded ELF
  modules: which function (FDE) holds a code address and where it starts.

  Calm path only: enumeration takes the loader lock (dl_iterate_phdr), and
  every read of module memory goes through CrashTryReadProcessMemory, so an
  unmapped or corrupt table fails the lookup instead of faulting.

  Supported: 64-bit ELF targets (Linux, Android). Elsewhere the module list is
  empty and every lookup fails.

  Copyright (c) 2026 Vizit0r. BSD 2-Clause license (see LICENSE.txt). }

interface

type
  // Executable PT_LOAD of a loaded ELF and its .eh_frame_hdr.
  TCrashUnwindModule = record
    LowAddress: UIntPtr;  // inclusive
    HighAddress: UIntPtr; // exclusive
    EhFrameHdr: UIntPtr;
  end;
  TCrashUnwindModules = TArray<TCrashUnwindModule>;

function CrashEnumerateUnwindModules: TCrashUnwindModules;
// Start of the function holding AAddress, from the FDE that covers it.
function CrashFindFunctionStart(const AModules: TCrashUnwindModules;
  const AAddress: UIntPtr; out AStart: UIntPtr): Boolean;

implementation

{$IF (Defined(LINUX) or Defined(ANDROID)) and Defined(CPU64BITS)}
  {$DEFINE CRASH_EH_FRAME}
{$ENDIF}

{$IF Defined(CRASH_EH_FRAME)}

uses
  Crash.Modules,
  Posix.Base;

const
  CRASH_PT_LOAD = 1;
  CRASH_PT_GNU_EH_FRAME = $6474E550;
  CRASH_PF_X = 1;

  DW_EH_PE_absptr  = $00;
  DW_EH_PE_udata2  = $02;
  DW_EH_PE_udata4  = $03;
  DW_EH_PE_udata8  = $04;
  DW_EH_PE_sdata2  = $0A;
  DW_EH_PE_sdata4  = $0B;
  DW_EH_PE_sdata8  = $0C;
  DW_EH_PE_pcrel   = $10;
  DW_EH_PE_datarel = $30;
  DW_EH_PE_omit    = $FF;

type
  TCrashElf64Phdr = record
    p_type: UInt32;
    p_flags: UInt32;
    p_offset: UInt64;
    p_vaddr: UInt64;
    p_paddr: UInt64;
    p_filesz: UInt64;
    p_memsz: UInt64;
    p_align: UInt64;
  end;
  PCrashElf64Phdr = ^TCrashElf64Phdr;

  TCrashDlPhdrInfo = record
    dlpi_addr: UIntPtr;
    dlpi_name: MarshaledAString;
    dlpi_phdr: PCrashElf64Phdr;
    dlpi_phnum: UInt16;
  end;
  PCrashDlPhdrInfo = ^TCrashDlPhdrInfo;

  TCrashDlIterateCallback = function(AInfo: PCrashDlPhdrInfo; ASize: NativeUInt;
    AData: Pointer): Integer; cdecl;

function crash_dl_iterate_phdr(ACallback: TCrashDlIterateCallback;
  AData: Pointer): Integer; cdecl; external libc name _PU + 'dl_iterate_phdr';

// No exception may leave this cdecl callback.
function CollectUnwindModule(AInfo: PCrashDlPhdrInfo; ASize: NativeUInt;
  AData: Pointer): Integer; cdecl;
var
  Modules: ^TCrashUnwindModules;
  Phdr: PCrashElf64Phdr;
  I, N: Integer;
  Hdr: UIntPtr;
begin
  Result := 0;
  try
    if (AInfo = nil) or (AInfo.dlpi_phdr = nil) then
      Exit;
    Modules := AData;
    Hdr := 0;
    for I := 0 to Integer(AInfo.dlpi_phnum) - 1 do
    begin
      Phdr := PCrashElf64Phdr(PByte(AInfo.dlpi_phdr) +
        I * SizeOf(TCrashElf64Phdr));
      if Phdr.p_type = CRASH_PT_GNU_EH_FRAME then
        Hdr := AInfo.dlpi_addr + UIntPtr(Phdr.p_vaddr);
    end;
    if Hdr = 0 then
      Exit;
    for I := 0 to Integer(AInfo.dlpi_phnum) - 1 do
    begin
      Phdr := PCrashElf64Phdr(PByte(AInfo.dlpi_phdr) +
        I * SizeOf(TCrashElf64Phdr));
      if (Phdr.p_type <> CRASH_PT_LOAD) or
         ((Phdr.p_flags and CRASH_PF_X) = 0) or (Phdr.p_memsz = 0) then
        Continue;
      N := Length(Modules^);
      SetLength(Modules^, N + 1);
      Modules^[N].LowAddress := AInfo.dlpi_addr + UIntPtr(Phdr.p_vaddr);
      Modules^[N].HighAddress := Modules^[N].LowAddress + UIntPtr(Phdr.p_memsz);
      Modules^[N].EhFrameHdr := Hdr;
    end;
  except
    Result := 0;
  end;
end;

function CrashEnumerateUnwindModules: TCrashUnwindModules;
begin
  Result := nil;
  crash_dl_iterate_phdr(CollectUnwindModule, @Result);
end;

function ReadMem(const AAddress: UIntPtr; ABuffer: Pointer;
  const ASize: NativeUInt): Boolean; inline;
begin
  Result := (AAddress <> 0) and
    CrashTryReadProcessMemory(AAddress, ABuffer, ASize);
end;

function ReadULEB(var AAddress: UIntPtr; out AValue: UInt64): Boolean;
var
  B: Byte;
  Shift: Integer;
begin
  AValue := 0;
  Shift := 0;
  repeat
    if (Shift > 63) or (not ReadMem(AAddress, @B, 1)) then
      Exit(False);
    Inc(AAddress);
    AValue := AValue or (UInt64(B and $7F) shl Shift);
    Inc(Shift, 7);
  until (B and $80) = 0;
  Result := True;
end;

function EncodedSize(const AEncoding: Byte): Integer;
begin
  case AEncoding and $0F of
    DW_EH_PE_absptr, DW_EH_PE_udata8, DW_EH_PE_sdata8: Result := 8;
    DW_EH_PE_udata4, DW_EH_PE_sdata4: Result := 4;
    DW_EH_PE_udata2, DW_EH_PE_sdata2: Result := 2;
  else
    Result := 0;
  end;
end;

// Decodes an absolute/pc-relative pointer; ABase is the datarel base.
function ReadEncoded(var AAddress: UIntPtr; const AEncoding: Byte;
  const ABase: UIntPtr; out AValue: UIntPtr): Boolean;
var
  Start: UIntPtr;
  U16: UInt16;
  U32: UInt32;
  U64: UInt64;
  V: Int64;
begin
  Result := False;
  Start := AAddress;
  case AEncoding and $0F of
    DW_EH_PE_absptr, DW_EH_PE_udata8, DW_EH_PE_sdata8:
      begin
        if not ReadMem(AAddress, @U64, 8) then
          Exit;
        V := Int64(U64);
      end;
    DW_EH_PE_udata4:
      begin
        if not ReadMem(AAddress, @U32, 4) then
          Exit;
        V := Int64(U32);
      end;
    DW_EH_PE_sdata4:
      begin
        if not ReadMem(AAddress, @U32, 4) then
          Exit;
        V := Int64(Int32(U32));
      end;
    DW_EH_PE_udata2:
      begin
        if not ReadMem(AAddress, @U16, 2) then
          Exit;
        V := Int64(U16);
      end;
    DW_EH_PE_sdata2:
      begin
        if not ReadMem(AAddress, @U16, 2) then
          Exit;
        V := Int64(Int16(U16));
      end;
  else
    Exit;
  end;
  Inc(AAddress, EncodedSize(AEncoding));
  case AEncoding and $70 of
    0: ;
    DW_EH_PE_pcrel: V := V + Int64(Start);
    DW_EH_PE_datarel: V := V + Int64(ABase);
  else
    Exit;
  end;
  AValue := UIntPtr(V);
  Result := True;
end;

// Pointer encoding ('R') of the FDEs that use this CIE.
function ReadCieFdeEncoding(const ACie: UIntPtr; out AEncoding: Byte): Boolean;
var
  P: UIntPtr;
  Len, CieID: UInt32;
  Version, C, Skip: Byte;
  Aug: array [0..15] of Byte;
  AugLen, I: Integer;
  Ignored: UInt64;
  Dummy: UIntPtr;
begin
  Result := False;
  AEncoding := DW_EH_PE_absptr;
  P := ACie;
  if (not ReadMem(P, @Len, 4)) or (Len = 0) or (Len = $FFFFFFFF) then
    Exit;
  if (not ReadMem(P + 4, @CieID, 4)) or (CieID <> 0) then
    Exit;
  if not ReadMem(P + 8, @Version, 1) then
    Exit;
  P := P + 9;
  AugLen := 0;
  repeat
    if (AugLen > High(Aug)) or (not ReadMem(P, @C, 1)) then
      Exit;
    Inc(P);
    Aug[AugLen] := C;
    Inc(AugLen);
  until C = 0;
  if not (ReadULEB(P, Ignored) and ReadULEB(P, Ignored)) then // align factors
    Exit;
  if Version = 1 then
    Inc(P)
  else if not ReadULEB(P, Ignored) then
    Exit;
  if (AugLen <= 1) or (Aug[0] <> Ord('z')) then
    Exit(True);
  if not ReadULEB(P, Ignored) then
    Exit;
  for I := 1 to AugLen - 2 do
    case Chr(Aug[I]) of
      'R':
        begin
          if not ReadMem(P, @AEncoding, 1) then
            Exit;
          Inc(P);
        end;
      'P':
        begin
          if not ReadMem(P, @Skip, 1) then
            Exit;
          Inc(P);
          if not ReadEncoded(P, Skip and $7F, 0, Dummy) then
            Exit;
        end;
      'L':
        Inc(P);
      'S', 'B', 'G':
        ;
    else
      Exit;
    end;
  Result := True;
end;

function CrashFindFunctionStart(const AModules: TCrashUnwindModules;
  const AAddress: UIntPtr; out AStart: UIntPtr): Boolean;
var
  I: Integer;
  Hdr, P, Table, Fde, Cie, PcBegin, PcRange: UIntPtr;
  Header: array [0..3] of Byte;
  Count: UInt32;
  Lo, Hi, Mid: Int64;
  Entry: array [0..1] of Int32;
  FdeLen, CieDelta: UInt32;
  Encoding: Byte;
begin
  Result := False;
  AStart := 0;
  Hdr := 0;
  for I := 0 to High(AModules) do
    if (AAddress >= AModules[I].LowAddress) and
       (AAddress < AModules[I].HighAddress) then
    begin
      Hdr := AModules[I].EhFrameHdr;
      Break;
    end;
  if (Hdr = 0) or (not ReadMem(Hdr, @Header, 4)) or (Header[0] <> 1) then
    Exit;
  if (Header[2] <> DW_EH_PE_udata4) or
     (Header[3] <> (DW_EH_PE_datarel or DW_EH_PE_sdata4)) or
     (Header[1] = DW_EH_PE_omit) or (EncodedSize(Header[1]) = 0) then
    Exit;
  P := Hdr + 4 + UIntPtr(EncodedSize(Header[1]));
  if (not ReadMem(P, @Count, 4)) or (Count = 0) then
    Exit;
  Table := P + 4;
  // Last entry whose initial location is <= AAddress.
  Lo := 0;
  Hi := Int64(Count) - 1;
  Fde := 0;
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) div 2;
    if not ReadMem(Table + UIntPtr(Mid) * 8, @Entry, 8) then
      Exit;
    if UIntPtr(Int64(Hdr) + Entry[0]) <= AAddress then
    begin
      Fde := UIntPtr(Int64(Hdr) + Entry[1]);
      Lo := Mid + 1;
    end
    else
      Hi := Mid - 1;
  end;
  if Fde = 0 then
    Exit;
  if (not ReadMem(Fde, @FdeLen, 4)) or (FdeLen = 0) or (FdeLen = $FFFFFFFF) or
     (not ReadMem(Fde + 4, @CieDelta, 4)) or (CieDelta = 0) then
    Exit;
  Cie := Fde + 4 - UIntPtr(CieDelta);
  if not ReadCieFdeEncoding(Cie, Encoding) then
    Exit;
  P := Fde + 8;
  if not ReadEncoded(P, Encoding, Hdr, PcBegin) then
    Exit;
  if not ReadEncoded(P, Encoding and $0F, 0, PcRange) then
    Exit;
  Result := (AAddress >= PcBegin) and (AAddress - PcBegin < PcRange);
  if Result then
    AStart := PcBegin;
end;

{$ELSE}

function CrashEnumerateUnwindModules: TCrashUnwindModules;
begin
  Result := nil;
end;

function CrashFindFunctionStart(const AModules: TCrashUnwindModules;
  const AAddress: UIntPtr; out AStart: UIntPtr): Boolean;
begin
  AStart := 0;
  Result := False;
end;

{$ENDIF}

end.
