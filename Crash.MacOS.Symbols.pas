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

{$ENDIF}

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

function _dyld_image_count: UInt32; cdecl;
  external libDyld name '_dyld_image_count';
function _dyld_get_image_header(image_index: UInt32): Pmach_header_64; cdecl;
  external libDyld name '_dyld_get_image_header';
function _dyld_get_image_name(image_index: UInt32): MarshaledAString; cdecl;
  external libDyld name '_dyld_get_image_name';
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
  { Per-image symbol cache: the image's runtime __TEXT range (for "is this
    address in this image?") plus its symbols, address-sorted with the image's
    slide already applied. One of these per cached (= our own) Mach-O image. }
  TImageSymbols = record
    LoBound, HiBound: UInt64;
    Symbols:          TArray<TSymbolEntry>;
  end;

var
  GImages: TArray<TImageSymbols>;
  GLoaded: Boolean = False;

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

function IsSystemImagePath(const APath: String): Boolean;
// System dylibs (AppKit/libsystem/...) live under /usr/ or /System/. We skip
// them: their names resolve fine via dladdr (honest exports), and -- critically
// -- they live in the dyld shared cache, whose __LINKEDIT is a single combined
// region NOT laid out at each image's own (symoff - fileoff), so the per-image
// pointer math below would read garbage for them. Our own modules (main exe +
// bundled .dylib plugins) are regular on-disk Mach-Os mapped normally.
begin
  Result := (APath = '') or
            APath.StartsWith('/usr/') or
            APath.StartsWith('/System/');
end;

function TryBuildImage(AIndex: UInt32; out AImg: TImageSymbols): Boolean;
// Parse one dyld image's LC_SYMTAB into an address-sorted symbol cache, with the
// image's own slide applied. Returns False (and AImg empty) if the image has no
// usable symtab/text. Same pointer math as before, now per-image.
var
  Header:         Pmach_header_64;
  Slide:          NativeInt;
  LCmd:           Pload_command;
  Seg:            Psegment_command_64;
  Symtab:         Psymtab_command;
  Linkedit:       Psegment_command_64;
  TextSeg:        Psegment_command_64;
  P:              PByte;
  I, N:           Integer;
  SymtabPtr:      Pnlist_64;
  StrTabBase:     PAnsiChar;
  Sym:            Pnlist_64;
  LinkeditVMBase: UInt64;
  Symbols:        TList<TSymbolEntry>;
  Entry:          TSymbolEntry;
  NameC:          MarshaledAString;
begin
  Result := False;
  AImg := Default(TImageSymbols);

  Header := _dyld_get_image_header(AIndex);
  if Header = nil then Exit;
  Slide := _dyld_get_image_vmaddr_slide(AIndex);

  Linkedit := nil;
  Symtab   := nil;
  TextSeg  := nil;
  P := PByte(Header) + SizeOf(mach_header_64);
  for I := 1 to Integer(Header.ncmds) do
  begin
    LCmd := Pload_command(P);
    if LCmd.cmdsize = 0 then Break; // malformed image - avoid an infinite walk
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

  if (Linkedit = nil) or (Symtab = nil) or (TextSeg = nil) then Exit;

  AImg.LoBound := TextSeg.vmaddr + UInt64(Slide);
  AImg.HiBound := AImg.LoBound + TextSeg.vmsize;

  // symtab.symoff / .stroff are FILE offsets. In the running image, __LINKEDIT
  // is mmap'd; the file offset within __LINKEDIT translates to
  // (LINKEDIT.vmaddr + slide) + (file_offset - LINKEDIT.fileoff).
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
      // Skip debug stabs; only "defined in section" symbols have real addresses.
      if ((Sym.n_type and N_STAB) = 0) and ((Sym.n_type and N_TYPE) = N_SECT) and
         (UInt32(Sym.n_un.n_strx) < UInt32(Symtab.strsize)) then // a wild n_strx must not walk past __LINKEDIT
      begin
        // n_strx lives in the anonymous nested record n_un (see Crash.MacOS.Api).
        NameC := MarshaledAString(StrTabBase + Sym.n_un.n_strx);
        if (NameC <> nil) and (NameC^ <> #0) then
        begin
          Entry.Address := Sym.n_value + UInt64(Slide);
          // Mach-O convention: prepended underscore on every external symbol.
          if NameC^ = '_' then Inc(NameC);
          Entry.Name := DemangleName(NameC);
          if Entry.Name <> '' then
            Symbols.Add(Entry);
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

    AImg.Symbols := Symbols.ToArray;
  finally
    Symbols.Free;
  end;

  Result := Length(AImg.Symbols) > 0;
end;

procedure CrashInitMacOSSymbolCache;
// Cache LC_SYMTAB of the main exe (image 0) AND every non-system loaded image
// (our bundled .dylib plugins), so Pascal frame names resolve in plugin code too
// -- macOS dladdr can't see Pascal symbols. Snapshot at Init time; images loaded
// later are not covered. Per-image failures are isolated (a malformed image just
// gets skipped, never aborts startup).
var
  Count, I: UInt32;
  NameC:    MarshaledAString;
  Path:     String;
  Img:      TImageSymbols;
  List:     TList<TImageSymbols>;
begin
  if GLoaded then Exit;
  GLoaded := True;
  GImages := nil;

  Count := _dyld_image_count;
  List := TList<TImageSymbols>.Create;
  try
    for I := 0 to Count - 1 do
    begin
      NameC := _dyld_get_image_name(I);
      Path  := '';
      if NameC <> nil then
        Path := String(AnsiString(NameC));
      // Always include the main image (0); skip system images otherwise.
      if (I <> 0) and IsSystemImagePath(Path) then Continue;
      try
        if TryBuildImage(I, Img) then
          List.Add(Img);
      except
        // A malformed image must never break startup -- just skip it.
      end;
    end;
    GImages := List.ToArray;
  finally
    List.Free;
  end;
end;

function CrashMacOSSymbolCacheCount: Integer;
var
  Img: TImageSymbols;
begin
  Result := 0;
  for Img in GImages do
    Inc(Result, Length(Img.Symbols));
end;

function CrashLookupMacOSSymbol(AAddress: UInt64;
  out ASymbolName: String; out ASymbolAddress: UInt64): Boolean;
var
  I, Lo, Hi, Mid: Integer;
begin
  Result := False;
  ASymbolName := '';
  ASymbolAddress := 0;

  // Find the cached image whose __TEXT contains AAddress. Addresses outside every
  // cached (= our own) image resolve via dladdr (foreign/system modules export
  // honest names).
  for I := 0 to High(GImages) do
  begin
    if (AAddress < GImages[I].LoBound) or (AAddress >= GImages[I].HiBound) then
      Continue;
    if (Length(GImages[I].Symbols) = 0) or
       (AAddress < GImages[I].Symbols[0].Address) then
      Exit;  // inside this image's text but before its first symbol -> no match

    // Binary search for the largest entry with Address <= AAddress.
    Lo := 0;
    Hi := High(GImages[I].Symbols);
    while Lo < Hi do
    begin
      Mid := (Lo + Hi + 1) div 2;
      if GImages[I].Symbols[Mid].Address <= AAddress then
        Lo := Mid
      else
        Hi := Mid - 1;
    end;

    ASymbolName    := GImages[I].Symbols[Lo].Name;
    ASymbolAddress := GImages[I].Symbols[Lo].Address;
    Result := True;
    Exit;
  end;
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

{$ENDIF}

end.
