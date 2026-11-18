unit Crash.Unwind.CompactUnwind;

{ Lookup through the Mach-O __unwind_info section (Apple compact unwind): the
  32-bit compact encoding of the code at an address and where its entry
  starts.

  The lookup itself only reads memory through CrashTryReadProcessMemory and
  bounds every offset by the section size, so it works on any target given a
  section image; enumerating the loaded images (dyld) is macOS only.

  Copyright (c) 2026 Vizit0r. BSD 2-Clause license (see LICENSE.txt). }

interface

type
  // One loaded Mach-O image: its executable __TEXT range and __unwind_info.
  TCrashCompactUnwindImage = record
    LowAddress: UIntPtr;  // inclusive
    HighAddress: UIntPtr; // exclusive
    ImageBase: UIntPtr;   // mach header; compact-unwind offsets are relative to it
    UnwindInfo: UIntPtr;
    UnwindInfoSize: UIntPtr;
  end;
  TCrashCompactUnwindImages = TArray<TCrashCompactUnwindImage>;

const
  // Mode bits of an ARM64 compact encoding.
  CRASH_UNWIND_ARM64_MODE_MASK      = $0F000000;
  CRASH_UNWIND_ARM64_MODE_FRAMELESS = $02000000;
  CRASH_UNWIND_ARM64_MODE_DWARF     = $03000000;
  CRASH_UNWIND_ARM64_MODE_FRAME     = $04000000;

// Calm path; macOS only (nil elsewhere).
function CrashEnumerateCompactUnwindImages: TCrashCompactUnwindImages;
{ Start and encoding of the compact-unwind entry holding AAddress. The linker
  merges neighbouring functions with the same encoding into one entry, so the
  start is a range start, not necessarily the function's own; the encoding is
  exact for every function of the range. False when no image covers it, the
  section is malformed, or the entry carries no unwind info. }
function CrashFindCompactFunctionStart(const AImages: TCrashCompactUnwindImages;
  const AAddress: UIntPtr; out AStart: UIntPtr; out AEncoding: UInt32): Boolean;

implementation

uses
  Crash.Modules
  {$IF Defined(MACOS)}
  , Posix.Base
  {$ENDIF};

const
  UNWIND_SECTION_VERSION = 1;
  UNWIND_SECOND_LEVEL_REGULAR = 2;
  UNWIND_SECOND_LEVEL_COMPRESSED = 3;

type
  TUnwindInfoHeader = packed record
    Version: UInt32;
    CommonEncodingsOffset: UInt32;
    CommonEncodingsCount: UInt32;
    PersonalityOffset: UInt32;
    PersonalityCount: UInt32;
    IndexOffset: UInt32;
    IndexCount: UInt32;
  end;

  TUnwindIndexEntry = packed record
    FunctionOffset: UInt32;
    SecondLevelOffset: UInt32;
    LsdaIndexOffset: UInt32;
  end;

  TUnwindPageHeader = packed record
    Kind: UInt32;
    EntryPageOffset: UInt16;
    EntryCount: UInt16;
    EncodingsPageOffset: UInt16; // compressed pages only
    EncodingsCount: UInt16;      // compressed pages only
  end;

  TUnwindRegularEntry = packed record
    FunctionOffset: UInt32;
    Encoding: UInt32;
  end;

// Reads ASize bytes at section offset AOffset, never outside the section.
function ReadAt(const AImage: TCrashCompactUnwindImage; const AOffset: UInt64;
  ABuffer: Pointer; const ASize: NativeUInt): Boolean;
begin
  Result := (AOffset <= AImage.UnwindInfoSize) and
    (UInt64(ASize) <= UInt64(AImage.UnwindInfoSize) - AOffset) and
    CrashTryReadProcessMemory(AImage.UnwindInfo + UIntPtr(AOffset), ABuffer,
      ASize);
end;

function FindInImage(const AImage: TCrashCompactUnwindImage;
  const ATarget: UInt32; out AStartOffset: UInt32;
  out AEncoding: UInt32): Boolean;
var
  Header: TUnwindInfoHeader;
  Entry, NextEntry: TUnwindIndexEntry;
  Page: TUnwindPageHeader;
  Regular: TUnwindRegularEntry;
  PageOffset: UInt64;
  Lo, Hi, Mid, Found: Int64;
  Packed32, EncodingIndex: UInt32;
begin
  Result := False;
  AStartOffset := 0;
  AEncoding := 0;
  if (not ReadAt(AImage, 0, @Header, SizeOf(Header))) or
     (Header.Version <> UNWIND_SECTION_VERSION) or (Header.IndexCount < 2) then
    Exit;

  // First level: the last real entry (the final one is a sentinel holding the
  // end of the text) whose function offset is <= ATarget.
  Lo := 0;
  Hi := Int64(Header.IndexCount) - 2;
  Found := -1;
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) div 2;
    if not ReadAt(AImage, UInt64(Header.IndexOffset) +
         UInt64(Mid) * SizeOf(Entry), @Entry, SizeOf(Entry)) then
      Exit;
    if Entry.FunctionOffset <= ATarget then
    begin
      Found := Mid;
      Lo := Mid + 1;
    end
    else
      Hi := Mid - 1;
  end;
  if Found < 0 then
    Exit;
  if (not ReadAt(AImage, UInt64(Header.IndexOffset) +
       UInt64(Found) * SizeOf(Entry), @Entry, SizeOf(Entry))) or
     (not ReadAt(AImage, UInt64(Header.IndexOffset) +
       UInt64(Found + 1) * SizeOf(Entry), @NextEntry, SizeOf(NextEntry))) then
    Exit;
  if (ATarget >= NextEntry.FunctionOffset) or (Entry.SecondLevelOffset = 0) then
    Exit;

  PageOffset := Entry.SecondLevelOffset;
  if not ReadAt(AImage, PageOffset, @Page, SizeOf(UInt32) + 2 * SizeOf(UInt16)) then
    Exit;
  if Page.EntryCount = 0 then
    Exit;

  if Page.Kind = UNWIND_SECOND_LEVEL_REGULAR then
  begin
    Lo := 0;
    Hi := Int64(Page.EntryCount) - 1;
    Found := -1;
    while Lo <= Hi do
    begin
      Mid := (Lo + Hi) div 2;
      if not ReadAt(AImage, PageOffset + Page.EntryPageOffset +
           UInt64(Mid) * SizeOf(Regular), @Regular, SizeOf(Regular)) then
        Exit;
      if Regular.FunctionOffset <= ATarget then
      begin
        Found := Mid;
        Lo := Mid + 1;
      end
      else
        Hi := Mid - 1;
    end;
    if (Found < 0) or
       (not ReadAt(AImage, PageOffset + Page.EntryPageOffset +
         UInt64(Found) * SizeOf(Regular), @Regular, SizeOf(Regular))) then
      Exit;
    AStartOffset := Regular.FunctionOffset;
    AEncoding := Regular.Encoding;
  end
  else if Page.Kind = UNWIND_SECOND_LEVEL_COMPRESSED then
  begin
    if not ReadAt(AImage, PageOffset, @Page, SizeOf(Page)) then
      Exit;
    // Compressed entries: low 24 bits = offset from the first-level function
    // offset, high 8 bits = encoding index (common array, then page-local).
    Lo := 0;
    Hi := Int64(Page.EntryCount) - 1;
    Found := -1;
    while Lo <= Hi do
    begin
      Mid := (Lo + Hi) div 2;
      if not ReadAt(AImage, PageOffset + Page.EntryPageOffset +
           UInt64(Mid) * SizeOf(UInt32), @Packed32, SizeOf(Packed32)) then
        Exit;
      if Entry.FunctionOffset + (Packed32 and $00FFFFFF) <= ATarget then
      begin
        Found := Mid;
        Lo := Mid + 1;
      end
      else
        Hi := Mid - 1;
    end;
    if (Found < 0) or
       (not ReadAt(AImage, PageOffset + Page.EntryPageOffset +
         UInt64(Found) * SizeOf(UInt32), @Packed32, SizeOf(Packed32))) then
      Exit;
    AStartOffset := Entry.FunctionOffset + (Packed32 and $00FFFFFF);
    EncodingIndex := Packed32 shr 24;
    if EncodingIndex < Header.CommonEncodingsCount then
    begin
      if not ReadAt(AImage, UInt64(Header.CommonEncodingsOffset) +
           UInt64(EncodingIndex) * SizeOf(UInt32), @AEncoding,
           SizeOf(AEncoding)) then
        Exit;
    end
    else
    begin
      Dec(EncodingIndex, Header.CommonEncodingsCount);
      if (EncodingIndex >= Page.EncodingsCount) or
         (not ReadAt(AImage, PageOffset + Page.EncodingsPageOffset +
           UInt64(EncodingIndex) * SizeOf(UInt32), @AEncoding,
           SizeOf(AEncoding))) then
        Exit;
    end;
  end
  else
    Exit;
  // Encoding 0 marks a range without unwind info (a gap between functions).
  Result := AEncoding <> 0;
end;

function CrashFindCompactFunctionStart(const AImages: TCrashCompactUnwindImages;
  const AAddress: UIntPtr; out AStart: UIntPtr; out AEncoding: UInt32): Boolean;
var
  I: Integer;
  Offset: UInt64;
  StartOffset: UInt32;
begin
  Result := False;
  AStart := 0;
  AEncoding := 0;
  for I := 0 to High(AImages) do
    if (AAddress >= AImages[I].LowAddress) and
       (AAddress < AImages[I].HighAddress) and
       (AAddress >= AImages[I].ImageBase) then
    begin
      Offset := UInt64(AAddress - AImages[I].ImageBase);
      if Offset > High(UInt32) then
        Exit;
      if not FindInImage(AImages[I], UInt32(Offset), StartOffset, AEncoding) then
        Exit;
      AStart := AImages[I].ImageBase + UIntPtr(StartOffset);
      Exit(True);
    end;
end;

{$IF Defined(MACOS)}
const
  libdyld = '/usr/lib/system/libdyld.dylib';
  LC_SEGMENT_64 = $19;
  MH_MAGIC_64 = $FEEDFACF;

type
  TMachHeader64 = packed record
    Magic, CpuType, CpuSubtype, FileType, NCmds, SizeOfCmds, Flags,
      Reserved: UInt32;
  end;

  TLoadCommand = packed record
    Cmd, CmdSize: UInt32;
  end;

  TSegmentCommand64 = packed record
    Cmd, CmdSize: UInt32;
    SegName: array [0..15] of AnsiChar;
    VMAddr, VMSize, FileOff, FileSize: UInt64;
    MaxProt, InitProt, NSects, Flags: UInt32;
  end;

  TSection64 = packed record
    SectName: array [0..15] of AnsiChar;
    SegName: array [0..15] of AnsiChar;
    Addr, Size: UInt64;
    Offset, Align, RelOff, NReloc, Flags, Reserved1, Reserved2,
      Reserved3: UInt32;
  end;

function _dyld_image_count: UInt32; cdecl;
  external libdyld name '_dyld_image_count';
function _dyld_get_image_header(image_index: UInt32): Pointer; cdecl;
  external libdyld name '_dyld_get_image_header';
function _dyld_get_image_vmaddr_slide(image_index: UInt32): NativeInt; cdecl;
  external libdyld name '_dyld_get_image_vmaddr_slide';

function SameName(const AName: array of AnsiChar; const AExpected: AnsiString): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(AName) do
  begin
    if I >= Length(AExpected) then
      Exit(AName[I] = #0);
    if AName[I] <> AExpected[I + 1] then
      Exit(False);
  end;
  Result := Length(AExpected) = Length(AName);
end;

function CrashEnumerateCompactUnwindImages: TCrashCompactUnwindImages;
var
  Count, ImageIndex, CommandIndex, SectionIndex: UInt32;
  HeaderAddress, CommandAddress, SectionAddress: UIntPtr;
  Slide: NativeInt;
  Header: TMachHeader64;
  Command: TLoadCommand;
  Segment: TSegmentCommand64;
  Section: TSection64;
  Image: TCrashCompactUnwindImage;
  CommandsEnd: UIntPtr;
begin
  Result := nil;
  Count := _dyld_image_count;
  if Count = 0 then
    Exit;
  for ImageIndex := 0 to Count - 1 do
  begin
    HeaderAddress := UIntPtr(_dyld_get_image_header(ImageIndex));
    if (HeaderAddress = 0) or
       (not CrashTryReadProcessMemory(HeaderAddress, @Header, SizeOf(Header))) or
       (Header.Magic <> MH_MAGIC_64) or (Header.NCmds = 0) then
      Continue;
    Slide := _dyld_get_image_vmaddr_slide(ImageIndex);
    Image := Default(TCrashCompactUnwindImage);
    Image.ImageBase := HeaderAddress;
    CommandAddress := HeaderAddress + SizeOf(Header);
    CommandsEnd := CommandAddress + Header.SizeOfCmds;
    for CommandIndex := 1 to Header.NCmds do
    begin
      if (CommandAddress + SizeOf(Command) > CommandsEnd) or
         (not CrashTryReadProcessMemory(CommandAddress, @Command,
           SizeOf(Command))) or
         (Command.CmdSize < SizeOf(Command)) or
         (CommandAddress + Command.CmdSize > CommandsEnd) then
        Break;
      if (Command.Cmd = LC_SEGMENT_64) and
         (Command.CmdSize >= SizeOf(Segment)) and
         CrashTryReadProcessMemory(CommandAddress, @Segment, SizeOf(Segment)) and
         SameName(Segment.SegName, '__TEXT') then
      begin
        Image.LowAddress := UIntPtr(NativeInt(Segment.VMAddr) + Slide);
        Image.HighAddress := Image.LowAddress + UIntPtr(Segment.VMSize);
        SectionAddress := CommandAddress + SizeOf(Segment);
        if Segment.NSects > 0 then
          for SectionIndex := 1 to Segment.NSects do
          begin
            if (SectionAddress + SizeOf(Section) > CommandAddress + Command.CmdSize) or
               (not CrashTryReadProcessMemory(SectionAddress, @Section,
                 SizeOf(Section))) then
              Break;
            if SameName(Section.SectName, '__unwind_info') then
            begin
              Image.UnwindInfo := UIntPtr(NativeInt(Section.Addr) + Slide);
              Image.UnwindInfoSize := UIntPtr(Section.Size);
            end;
            Inc(SectionAddress, SizeOf(Section));
          end;
      end;
      Inc(CommandAddress, Command.CmdSize);
    end;
    if (Image.UnwindInfo <> 0) and (Image.UnwindInfoSize > 0) and
       (Image.HighAddress > Image.LowAddress) then
      Result := Result + [Image];
  end;
end;
{$ELSE}
function CrashEnumerateCompactUnwindImages: TCrashCompactUnwindImages;
begin
  Result := nil;
end;
{$ENDIF}

end.
