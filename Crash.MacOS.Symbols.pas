unit Crash.MacOS.Symbols;

{ macOS-only Pascal symbol resolution from Mach-O LC_SYMTAB.

  Part of the Crash Reporter library - standalone, EurekaLog-compatible
  crash/exception reporting for Delphi cross-platform targets.

  Problem: macOS `dladdr` only sees the narrow dynsym export list. Delphi
  doesn't promote Pascal procedures/methods to that list, so `dladdr`
  returns the nearest exported RTL symbol (usually `_SignalConverter`)
  for every Pascal frame - the call stack becomes useless.

  Solution: parse the running Mach-O image's LC_SYMTAB section, which DOES
  contain all Pascal symbols (as long as the binary isn't strip'ped). Build
  a sorted [Address -> Name] cache at startup, binary-search at lookup time.
  Names are Itanium-mangled (Delphi macOS uses C++ ABI), so demangle via
  `__cxa_demangle` + CppSymbolToPascal (Crash.Demangle).

  Bypasses dladdr completely - the symbol resolution is hooked at the
  Crash.ELFormat RenderFrame level for frames inside our own Mach-O image;
  foreign-module frames (AppKit/dyld/libsystem) keep their `dladdr` resolution
  because those modules DO export real names.

  Build requirements:
    - Linking -> Symbols: True (don't strip).
    - Debug info kind doesn't matter for THIS unit, only for line numbers
      (separate concern handled by Crash.LineNumbers + .gol). }

interface

{$IF Defined(MACOS) and not Defined(IOS)}

// Init at startup (idempotent). Heavy: walks the entire symtab and demangles
// every name. Few hundred ms on a normal exe. Call once from the reporter's Init.
procedure CrashInitMacOSSymbolCache;

// Returns True if AAddress falls inside our exe's text and a symbol was
// found at or before AAddress. ASymbolAddress is the symbol's start (for
// computing the in-function offset).
function CrashLookupMacOSSymbol(AAddress: UInt64;
  out ASymbolName: String; out ASymbolAddress: UInt64): Boolean;

// True if symbol cache loaded successfully.
function CrashMacOSSymbolCacheCount: Integer;

{$ELSE}

procedure CrashInitMacOSSymbolCache;
function CrashLookupMacOSSymbol(AAddress: UInt64;
  out ASymbolName: String; out ASymbolAddress: UInt64): Boolean;
function CrashMacOSSymbolCacheCount: Integer;

{$IFEND}

implementation

{$IF Defined(MACOS) and not Defined(IOS)}

uses
  System.SysUtils,
  System.Generics.Collections,
  System.Generics.Defaults,
  Posix.Stdlib,
  Crash.MacOS.Api,
  Crash.Demangle;

const
  libSystem = '/usr/lib/libSystem.dylib';
  libDyld   = '/usr/lib/system/libdyld.dylib';

function _dyld_get_image_header(image_index: UInt32): Pmach_header_64; cdecl;
  external libDyld name '_dyld_get_image_header';
function _dyld_get_image_vmaddr_slide(image_index: UInt32): NativeInt; cdecl;
  external libDyld name '_dyld_get_image_vmaddr_slide';

function __cxa_demangle(const mangled_name: MarshaledAString;
  output_buffer: MarshaledAString; length: NativeInt;
  out status: Integer): MarshaledAString; cdecl;
  external libSystem name '__cxa_demangle';

type
  TSymbolEntry = record
    Address: UInt64;
    Name:    String;
  end;

var
  GSymbols: TArray<TSymbolEntry>;
  GLoaded:  Boolean = False;
  GExeLoBound, GExeHiBound: UInt64;

function DemangleName(AMangled: MarshaledAString): String;
// __cxa_demangle returns a malloc'd buffer that we must Posix.Stdlib.free.
// Falls back to raw name if demangling fails. Then runs through
// CppSymbolToPascal to get Pascal-flavoured naming.
var
  Demangled: MarshaledAString;
  Status:    Integer;
begin
  Result := '';
  if AMangled = nil then Exit;
  Demangled := __cxa_demangle(AMangled, nil, 0, Status);
  if Demangled = nil then
    Result := String(AnsiString(AMangled))
  else
  try
    Result := String(AnsiString(Demangled));
  finally
    Posix.Stdlib.free(Demangled);
  end;
  Result := CppSymbolToPascal(Result);
end;

function SegnameEq(const ASegname: array of AnsiChar; const AWanted: AnsiString): Boolean;
// segname is fixed 16-byte field, NUL-padded. Compare up to the length of
// AWanted, demand exact match.
var
  I: Integer;
begin
  Result := False;
  if Length(AWanted) > Length(ASegname) then Exit;
  for I := 1 to Length(AWanted) do
    if ASegname[I - 1] <> AWanted[I] then Exit;
  // After AWanted must be NUL or end of field.
  if Length(AWanted) < Length(ASegname) then
    if ASegname[Length(AWanted)] <> #0 then Exit;
  Result := True;
end;

procedure CrashInitMacOSSymbolCache;
var
  Header:           Pmach_header_64;
  Slide:            NativeInt;
  LCmd:             Pload_command;
  Seg:              Psegment_command_64;
  Symtab:           Psymtab_command;
  Linkedit:         Psegment_command_64;
  TextSeg:          Psegment_command_64;
  P:                PByte;
  I, N:             Integer;
  SymtabPtr:        Pnlist_64;
  StrTabBase:       PAnsiChar;
  Sym:              Pnlist_64;
  LinkeditVMBase:   UInt64;
  Symbols:          TList<TSymbolEntry>;
  Entry:            TSymbolEntry;
  NameC:            MarshaledAString;
begin
  if GLoaded then Exit;
  GLoaded := True;
  GSymbols := nil;

  Header := _dyld_get_image_header(0);
  if Header = nil then Exit;
  Slide := _dyld_get_image_vmaddr_slide(0);

  // Walk load commands - find __LINKEDIT (for symtab/strtab address mapping),
  // LC_SYMTAB, and __TEXT (for bounds checking exe-internal addresses).
  Linkedit := nil;
  Symtab   := nil;
  TextSeg  := nil;
  P := PByte(Header) + SizeOf(mach_header_64);
  for I := 1 to Integer(Header.ncmds) do
  begin
    LCmd := Pload_command(P);
    case LCmd.cmd of
      LC_SEGMENT_64:
      begin
        Seg := Psegment_command_64(P);
        if SegnameEq(Seg.segname, '__LINKEDIT') then
          Linkedit := Seg
        else if SegnameEq(Seg.segname, '__TEXT') then
          TextSeg := Seg;
      end;
      LC_SYMTAB:
        Symtab := Psymtab_command(P);
    end;
    Inc(P, LCmd.cmdsize);
  end;

  if (Linkedit = nil) or (Symtab = nil) then Exit;

  // __TEXT bounds (for fast "is this address in our exe" check).
  if TextSeg <> nil then
  begin
    GExeLoBound := TextSeg.vmaddr + UInt64(Slide);
    GExeHiBound := GExeLoBound + TextSeg.vmsize;
  end;

  // symtab.symoff / .stroff are FILE offsets. In the running image,
  // __LINKEDIT is mmap'd; the file offset within __LINKEDIT translates
  // to (LINKEDIT.vmaddr + slide) + (file_offset - LINKEDIT.fileoff).
  LinkeditVMBase := Linkedit.vmaddr + UInt64(Slide);
  SymtabPtr := Pnlist_64(NativeUInt(LinkeditVMBase
                         + UInt64(Symtab.symoff) - Linkedit.fileoff));
  StrTabBase := PAnsiChar(NativeUInt(LinkeditVMBase
                         + UInt64(Symtab.stroff) - Linkedit.fileoff));

  Symbols := TList<TSymbolEntry>.Create;
  try
    Symbols.Capacity := Symtab.nsyms;
    Sym := SymtabPtr;
    for N := 0 to Symtab.nsyms - 1 do
    begin
      // Skip debug stabs entries.
      if (Sym.n_type and N_STAB) = 0 then
      begin
        // Only "defined in section" symbols have real addresses.
        if (Sym.n_type and N_TYPE) = N_SECT then
        begin
          // n_strx lives in the anonymous nested record n_un (see Crash.MacOS.Api).
          NameC := MarshaledAString(StrTabBase + Sym.n_un.n_strx);
          if (NameC <> nil) and (NameC^ <> #0) then
          begin
            Entry.Address := Sym.n_value + UInt64(Slide);
            // Mach-O convention: prepended underscore on every external
            // symbol - strip it before demangling.
            if NameC^ = '_' then Inc(NameC);
            Entry.Name := DemangleName(NameC);
            if Entry.Name <> '' then
              Symbols.Add(Entry);
          end;
        end;
      end;
      Inc(Sym);
    end;

    Symbols.Sort(TComparer<TSymbolEntry>.Construct(
      function(const L, R: TSymbolEntry): Integer
      begin
        if L.Address < R.Address then Result := -1
        else if L.Address > R.Address then Result := 1
        else Result := 0;
      end));

    GSymbols := Symbols.ToArray;
  finally
    Symbols.Free;
  end;
end;

function CrashMacOSSymbolCacheCount: Integer;
begin
  Result := Length(GSymbols);
end;

function CrashLookupMacOSSymbol(AAddress: UInt64;
  out ASymbolName: String; out ASymbolAddress: UInt64): Boolean;
var
  Lo, Hi, Mid: Integer;
begin
  Result := False;
  ASymbolName := '';
  ASymbolAddress := 0;
  if Length(GSymbols) = 0 then Exit;
  // Reject addresses outside our exe's __TEXT - those resolve via dladdr
  // (foreign modules: AppKit, dyld, libsystem - their dynsym is honest).
  if (GExeHiBound > 0) and
     ((AAddress < GExeLoBound) or (AAddress >= GExeHiBound)) then Exit;
  if AAddress < GSymbols[0].Address then Exit;

  // Binary search for largest entry with Address <= AAddress.
  Lo := 0;
  Hi := High(GSymbols);
  while Lo < Hi do
  begin
    Mid := (Lo + Hi + 1) div 2;
    if GSymbols[Mid].Address <= AAddress then
      Lo := Mid
    else
      Hi := Mid - 1;
  end;

  ASymbolName    := GSymbols[Lo].Name;
  ASymbolAddress := GSymbols[Lo].Address;
  Result := True;
end;

{$ELSE}  // not (MACOS and not IOS) - no-op stubs

procedure CrashInitMacOSSymbolCache; begin end;

function CrashLookupMacOSSymbol(AAddress: UInt64;
  out ASymbolName: String; out ASymbolAddress: UInt64): Boolean;
begin
  Result := False;
  ASymbolName := '';
  ASymbolAddress := 0;
end;

function CrashMacOSSymbolCacheCount: Integer;
begin
  Result := 0;
end;

{$IFEND}

end.
