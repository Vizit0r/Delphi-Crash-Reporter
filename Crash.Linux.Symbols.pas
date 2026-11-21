unit Crash.Linux.Symbols;

{ Linux function-name resolution from a .gosym side-file.

  Part of the Crash Reporter library - standalone, EurekaLog-compatible
  crash/exception reporting for Delphi cross-platform targets.

  dladdr sees only .dynsym. Routines the compiler emits as LOCAL symbols (with
  Delphi 13.2: everything declared only in an implementation section) are not
  there, so dladdr returns no name for them, and a release build stripped of
  .symtab has no other source. LNG_ELF --gosym writes <exe>.gosym from the
  unstripped executable (its local function symbols plus their source files);
  this unit loads it at startup and resolves the frames dladdr left unnamed.
  The data is taken from the image's own .crash.gosym section when present
  (added after linking), else from the <exe>.gosym file next to it.

  Covers the module that contains this unit (the executable). The side-file is
  matched by the ELF build-id, so a stale one is refused, never misread.

  No-op on other targets (the unit still compiles everywhere).

  Copyright (c) 2026 Vizit0r. BSD 2-Clause license (see LICENSE.txt). }

interface

{ Load <module>.gosym for the module that holds this code. Call once at startup;
  idempotent. A missing or mismatched file just leaves the names unavailable. }
procedure CrashInitLinuxSymbols;

{ True once a matching .gosym is loaded. }
function CrashLinuxSymbolsActive: Boolean;

{ Resolve ACodeAddr (absolute runtime) within the module loaded at AModuleBase
  (dladdr dli_fbase). AName is the mangled symbol, ARoutineAddr the absolute
  start of the function, ASourceFile its source file ('' if unknown). False when
  symbols are unavailable, AModuleBase is another module, or no entry covers
  the address. }
function CrashLinuxLookupName(const ACodeAddr, AModuleBase: UIntPtr;
  out AMangledName: RawByteString; out ARoutineAddr: UIntPtr;
  out ASourceFile: String): Boolean;

implementation

{$IF Defined(LINUX)}

uses
  System.SysUtils,
  System.IOUtils,
  Posix.Dlfcn,
  Crash.SymbolFile;

var
  GLoaded: Boolean = False;
  GModuleBase: UIntPtr = 0;   // dli_fbase of the module the side-file describes
  GLinkBase: UInt64 = 0;      // its lowest PT_LOAD vaddr (non-PIE image base)
  GSymbols: TCrashSymbolFile = nil;

procedure CrashInitLinuxSymbols;
var
  Info: dl_info;
  ModulePath: String;
  ID: TCrashSymbolBuildID;
  LinkBase: UInt64;
  Data: TBytes;
  Symbols: TCrashSymbolFile;
begin
  if GLoaded then
    Exit;
  GLoaded := True; // attempt once regardless of outcome
  try
    if dladdr(UIntPtr(@CrashInitLinuxSymbols), Info) = 0 then
      Exit;
    ModulePath := String(Info.dli_fname);
    if (ModulePath = '') or (Info.dli_fbase = nil) then
      Exit;
    if not CrashReadElfBuildID(ModulePath, ID, LinkBase) then
      Exit;
    // Embedded in the image first, then the side-file next to it
    if not CrashReadElfSection(ModulePath, CRASH_ELF_GOSYM_SECTION, Data) then
    begin
      if not TFile.Exists(ModulePath + '.gosym') then
        Exit;
      Data := TFile.ReadAllBytes(ModulePath + '.gosym');
    end;
    Symbols := TCrashSymbolFile.Create;
    if Symbols.Load(Data, ID) then
    begin
      GModuleBase := UIntPtr(Info.dli_fbase);
      GLinkBase := LinkBase;
      GSymbols := Symbols;
    end
    else
      Symbols.Free;
  except
    // Names are a convenience: a failure here must not stop the reporter.
  end;
end;

function CrashLinuxSymbolsActive: Boolean;
begin
  Result := (GSymbols <> nil) and GSymbols.Active;
end;

function CrashLinuxLookupName(const ACodeAddr, AModuleBase: UIntPtr;
  out AMangledName: RawByteString; out ARoutineAddr: UIntPtr;
  out ASourceFile: String): Boolean;
var
  Start: UInt64;
begin
  Result := False;
  AMangledName := '';
  ARoutineAddr := 0;
  ASourceFile := '';
  if not CrashLinuxSymbolsActive then
    Exit;
  // Module-specific: never read a foreign module's offset as one of ours.
  if (AModuleBase <> GModuleBase) or (ACodeAddr < AModuleBase) then
    Exit;
  if not GSymbols.Lookup(UInt64(ACodeAddr) - UInt64(AModuleBase) + GLinkBase,
       AMangledName, Start, ASourceFile) then
    Exit;
  ARoutineAddr := UIntPtr(Start - GLinkBase + UInt64(AModuleBase));
  Result := True;
end;

{$ELSE}

procedure CrashInitLinuxSymbols;
begin
end;

function CrashLinuxSymbolsActive: Boolean;
begin
  Result := False;
end;

function CrashLinuxLookupName(const ACodeAddr, AModuleBase: UIntPtr;
  out AMangledName: RawByteString; out ARoutineAddr: UIntPtr;
  out ASourceFile: String): Boolean;
begin
  AMangledName := '';
  ARoutineAddr := 0;
  ASourceFile := '';
  Result := False;
end;

{$ENDIF}

{$IF Defined(LINUX)}
initialization

finalization
  FreeAndNil(GSymbols);
{$ENDIF}

end.
