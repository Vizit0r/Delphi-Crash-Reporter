unit Crash.ELFormat;

{ EurekaLog .el text-format writer.

  Part of the Crash Reporter library - standalone, EurekaLog-compatible
  crash/exception reporting for Delphi cross-platform targets.

  Produces a report in the EurekaLog text (.el) format so the stock EurekaLog
  Viewer can open it. The format follows EL's logic:
    - UTF-16LE + BOM + CRLF.
    - Sections: General (Application/Exception/User/Computer/OS/Steps), then
      Call Stack Information, then Modules / Registers (when present).
    - Call Stack column widths are computed dynamically (max over the data),
      as TEurekaStackFormatter.CalculateLengths does in EL.
    - Row format: `|col1|col2|...|col11|`, FmtCompleteStr = right-pad to maxWidth.
    - The 11 columns: Methods | Details | Stack | Address | Module | Offset
      | Source | Unit | Class | Procedure/Method | Line.

  Header hashes are placeholders (zeros); the Viewer usually doesn't validate them. }

interface

uses
  System.SysUtils,
  Crash.CallStack;

type
  TCrashELContext = record
    AppName: String;           // e.g. "MyApp"
    AppVersion: String;        // e.g. "1.2.3.4"
    AppParameters: String;     // ParamStr(1..N) joined
    StartTime: TDateTime;
    CompileTime: String;       // host-supplied literal, no reparsing
    ExceptionTime: TDateTime;
    CpuSnapshot: String;       // pre-formatted "Registers:" section body (regs + stack hex). '' = empty section.
    SignalInfoSection: String; // separate "Crash Signal Info:" section (outside the EL format), '' = omit.
    UserName: String;
    ComputerName: String;
    OSDescription: String;
    AppDpi: Integer;
    ThreadID: Cardinal;
    ThreadName: String;        // "MAIN" or the worker thread's name
    DisabledSections: TCrashReportSections; // sections to OMIT; default [] = full report
  end;

function CrashBuildELReportText(
  const AReport: TCrashReport;
  const ACtx: TCrashELContext): String;

function CrashDefaultELContext(const AStartTime: TDateTime = 0): TCrashELContext;

implementation

uses
  System.Classes,
  System.DateUtils,
  System.TimeSpan,
  System.Generics.Collections,
  {$IF not Defined(MSWINDOWS)}
  Posix.Unistd,
  Posix.SysUtsname,
  {$IFEND}
  System.IOUtils,
  Crash.Signals,       // CrashTakeAndFormatSnapshots
  Crash.Modules,       // CrashEnumerateModules + format
  Crash.MacOS.Symbols, // CrashLookupMacOSSymbol
  Crash.LineNumbers;   // TLineNumberStatus enum + accessor via TCrashCapture

const
  // EL constants (taken from EConsts.pas)
  ESectionFiller = '-';
  EHeaderSuffix = ':';
  CRLF = #13#10;

  // Column captions (EL mtCallStack_*). Fixed English values.
  CapMethods   = 'Methods';
  CapDetails   = 'Details';
  CapStack     = 'Stack';
  CapAddress   = 'Address';
  CapModule    = 'Module';
  CapOffset    = 'Offset';
  CapSource    = 'Source';
  CapUnit      = 'Unit';
  CapClass     = 'Class';
  CapProcedure = 'Procedure/Method';
  CapLine      = 'Line';

  PointerHexLen = SizeOf(Pointer) * 2; // 16 on x64, 8 on x86

function FmtCompleteStr(const S: String; const Len: Integer): String;
{ EL EInfoFormat.FmtCompleteStr: right-pad to Len. If S is longer than Len,
  leave it as is (as the original does). }
begin
  if Length(S) >= Len then
    Result := S
  else
    Result := S + StringOfChar(' ', Len - Length(S));
end;

function FormatELDate(const AWhen: TDateTime): String;
const
  DayShort: array[1..7] of String = ('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat');
  MonShort: array[1..12] of String = ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                                       'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec');
var
  Y, M, D, H, N, S, Ms: Word;
  Bias: TTimeSpan;
  BiasMin: Integer;
  BiasSign: Char;
begin
  if AWhen = 0 then Exit('');
  DecodeDate(AWhen, Y, M, D);
  DecodeTime(AWhen, H, N, S, Ms);
  Bias := TTimeZone.Local.GetUtcOffset(AWhen);
  BiasMin := Round(Bias.TotalMinutes);
  if BiasMin >= 0 then BiasSign := '+' else BiasSign := '-';
  BiasMin := Abs(BiasMin);
  Result := Format('%s, %d %s %d %.2d:%.2d:%.2d %s%.2d%.2d',
    [DayShort[DayOfWeek(AWhen)], D, MonShort[M], Y, H, N, S,
     BiasSign, BiasMin div 60, BiasMin mod 60]);
end;

function FormatUpTime(const ASeconds: Int64): String;
var
  Days, Hours, Mins, Secs: Int64;
  Parts: TStringList;
begin
  Parts := TStringList.Create;
  try
    Days := ASeconds div 86400;
    Hours := (ASeconds mod 86400) div 3600;
    Mins := (ASeconds mod 3600) div 60;
    Secs := ASeconds mod 60;
    if Days > 0 then Parts.Add(Format('%d day(s)', [Days]));
    if Hours > 0 then Parts.Add(Format('%d hour(s)', [Hours]));
    if Mins > 0 then Parts.Add(Format('%d minute(s)', [Mins]));
    Parts.Add(Format('%d second(s)', [Secs]));
    Result := String.Join(', ', Parts.ToStringArray);
  finally
    Parts.Free;
  end;
end;

procedure AppendEmptySection(const SB: TStringBuilder; const ATitle: String);
{ Exact match of EL TBaseLogBuilder.GetEmptySection:
    Value + ':' + LF + Dashes*(len(Value)+1) + LF + LF }
begin
  SB.Append(ATitle);
  SB.Append(EHeaderSuffix);
  SB.Append(CRLF);
  SB.Append(StringOfChar('-', Length(ATitle) + 1));
  SB.Append(CRLF);
  SB.Append(CRLF);
end;

procedure AppendSectionHeader(const SB: TStringBuilder; const ATitle: String);
begin
  SB.Append(ATitle);
  SB.Append(EHeaderSuffix);
  SB.Append(CRLF);
  SB.Append(StringOfChar('-', Length(ATitle) + 1));
  SB.Append(CRLF);
end;

procedure AppendField(const SB: TStringBuilder; const AKey, AValue: String;
  const AKeyPadLen: Integer);
var
  PaddedKey: String;
begin
  PaddedKey := FmtCompleteStr('  ' + AKey, AKeyPadLen);
  SB.Append(PaddedKey);
  SB.Append(': ');
  SB.Append(AValue);
  SB.Append(CRLF);
end;

function AddrHex(const A: UIntPtr): String;
begin
  Result := IntToHex(A, PointerHexLen);
end;

procedure SplitDottedName(const AFull: String; out AUnit, AClass, AProc: String);
{ "Foo.Bar.Baz.Qux" -> Unit="Foo.Bar", Class="Baz", Proc="Qux".
  With fewer than 2 dots the whole tail goes into Proc.
  Parameters (from the first '(' on) count as part of Proc and are NOT split on
  dots - otherwise demangled C++ names like "Foo.Bar.Baz(Quux.TFoo, ...)" would
  split on dots INSIDE the parameter types, and Class/Proc drift into neighbour
  columns. }
var
  Dots:       TArray<Integer>;
  I, LastDot, PrevDot: Integer;
  Sig, Params: String;
  ParenPos:   Integer;
begin
  AUnit := '';
  AClass := '';
  AProc := AFull;
  if AFull = '' then Exit;

  // Separate the signature (name up to '(') from the param list (with parens).
  // Dots are parsed only in the signature; params are appended to Proc as is.
  ParenPos := Pos('(', AFull);
  if ParenPos > 0 then
  begin
    Sig    := Copy(AFull, 1, ParenPos - 1);
    Params := Copy(AFull, ParenPos, MaxInt);
  end
  else
  begin
    Sig    := AFull;
    Params := '';
  end;

  SetLength(Dots, 0);
  for I := 1 to Length(Sig) do
    if Sig[I] = '.' then
    begin
      SetLength(Dots, Length(Dots) + 1);
      Dots[High(Dots)] := I;
    end;
  if Length(Dots) = 0 then
  begin
    AProc := Sig + Params;
    Exit;
  end;
  if Length(Dots) = 1 then
  begin
    AUnit := Copy(Sig, 1, Dots[0] - 1);
    AProc := Copy(Sig, Dots[0] + 1, MaxInt) + Params;
    Exit;
  end;
  LastDot := Dots[High(Dots)];
  PrevDot := Dots[High(Dots) - 1];
  AUnit  := Copy(Sig, 1, PrevDot - 1);
  AClass := Copy(Sig, PrevDot + 1, LastDot - PrevDot - 1);
  AProc  := Copy(Sig, LastDot + 1, MaxInt) + Params;
end;

type
  TRenderedFrame = record
    Methods, Details, Stack, Address, Module, Offset,
    Source, AUnit, AClass, AProcedure, Line: String;
  end;

function RenderFrame(const AEntry: TCrashStackEntry; AIndex, ATotal: Integer): TRenderedFrame;
var
  UName, CName, PName, ModBase, MacName: String;
  MacAddr: UInt64;
begin
  // macOS-only: if the address is inside our exe, prefer the name from our
  // Mach-O LC_SYMTAB cache. dladdr on Mach-O returns garbage for all Pascal
  // frames (see Crash.MacOS.Symbols). On other platforms CrashLookupMacOSSymbol
  // is a no-op stub returning False, so we use the resolved RoutineName as usual.
  if CrashLookupMacOSSymbol(AEntry.CodeAddress, MacName, MacAddr) then
    SplitDottedName(MacName, UName, CName, PName)
  else
    SplitDottedName(AEntry.RoutineName, UName, CName, PName);

  ModBase := ExtractFileName(AEntry.ModuleName);
  // Methods - the EL field represents the tracer type (8 hex). We have a single
  // one, so we set markers: 7FFFFFFE for top, 7FFF7FFE for the bottom thread
  // frame, 00000060 otherwise. The EL parser tolerates these for display; they
  // are not critical for parsing.
  if AIndex = 0 then
    Result.Methods := '7FFFFFFE'
  else if AIndex = ATotal - 1 then
    Result.Methods := '7FFF7FFE'
  else
    Result.Methods := '00000060';
  Result.Details := '04';
  // The Stack address equals the code address (we have no separate RSP snapshot).
  Result.Stack := AddrHex(AEntry.CodeAddress);
  Result.Address := AddrHex(AEntry.CodeAddress);
  Result.Module := ModBase;
  if AEntry.ModuleAddress <> 0 then
    Result.Offset := AddrHex(AEntry.CodeAddress - AEntry.ModuleAddress)
  else
    Result.Offset := AddrHex(0);
  // Source filename - not available from the resolver; best effort is <unit>.pas.
  if UName <> '' then
    Result.Source := UName + '.pas'
  else
    Result.Source := '';
  Result.AUnit := UName;
  Result.AClass := CName;
  Result.AProcedure := PName;
  // The EL Viewer parses the Line cell as 'absolute[relative]' and splits it
  // into two visual columns: 'Line' (absolute line in the .pas) and 'Rel. Line'
  // (offset from the routine's first line).
  if AEntry.LineNumber > 0 then
  begin
    // happy path: the .gol gave a real line. If we also have the routine's start
    // line (also from .gol), compute the true relative line.
    if (AEntry.RoutineLineNumber > 0) and
       (AEntry.LineNumber >= AEntry.RoutineLineNumber) then
      Result.Line := Format('%d[%d]', [AEntry.LineNumber,
                                       AEntry.LineNumber - AEntry.RoutineLineNumber + 1])
    else
      // Absolute is known but the routine start wasn't found (RTL/FMX frame
      // without .gol coverage, or routine outside the loaded code segment) - use
      // 1 as a safe fallback (the EL Viewer expects a number in Rel.Line).
      Result.Line := Format('%d[1]', [AEntry.LineNumber]);
  end
  else if (AEntry.RoutineAddress > 0) and
          (AEntry.RoutineAddress <> AEntry.ModuleAddress) and
          (AEntry.CodeAddress >= AEntry.RoutineAddress) then
    // Linux/Windows/Android: absolute line is unavailable (no runtime DWARF
    // reader). Put the byte offset from the routine start into the Rel.Line slot -
    // the Viewer shows it in the column logically next to RoutineName rather than
    // the absolute column. Line is set to 0 (sentinel "absolute unknown"). Format
    // +$NN is hex; the EL Viewer tolerates a non-numeric Rel.Line (shows it as is).
    Result.Line := '0[+$' + IntToHex(Int64(AEntry.CodeAddress) - Int64(AEntry.RoutineAddress), 1) + ']'
  else
    Result.Line := '';
end;

function GenerateExceptionID(const AReport: TCrashReport): String;
var
  Loc: TCrashStackEntry;
  Hash: UInt32;
  Msg: String;
begin
  Loc := AReport.ExceptionLocation;
  Msg := AReport.ExceptionMessage;
  Hash := UInt32(Loc.CodeAddress xor (Loc.CodeAddress shr 32));
  if Msg <> '' then
    Hash := Hash xor (UInt32(Length(Msg)) * UInt32(2654435761));
  Result := IntToHex(Hash, 8);
end;

function CrashBuildELReportText(
  const AReport: TCrashReport;
  const ACtx: TCrashELContext): String;
var
  SB: TStringBuilder;
  UpSecs: Int64;
  Loc: TCrashStackEntry;
  Stack: TCrashStack;
  Rendered: TArray<TRenderedFrame>;
  I: Integer;
  MaxMethods, MaxDetails, MaxStack, MaxAddress, MaxModule, MaxOffset: Integer;
  MaxSource, MaxUnit, MaxClass, MaxProc, MaxLine: Integer;
  TotalRowLen: Integer;
  ContentWidth: Integer;
  ThreadIDStr: String;

  procedure UpdateMax(var AMax: Integer; const S: String);
  begin
    if Length(S) > AMax then AMax := Length(S);
  end;

  function FormatRow(const F: TRenderedFrame): String;
  begin
    Result := Format('|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|',
      [FmtCompleteStr(F.Methods, MaxMethods),
       FmtCompleteStr(F.Details, MaxDetails),
       FmtCompleteStr(F.Stack, MaxStack),
       FmtCompleteStr(F.Address, MaxAddress),
       FmtCompleteStr(F.Module, MaxModule),
       FmtCompleteStr(F.Offset, MaxOffset),
       FmtCompleteStr(F.Source, MaxSource),
       FmtCompleteStr(F.AUnit, MaxUnit),
       FmtCompleteStr(F.AClass, MaxClass),
       FmtCompleteStr(F.AProcedure, MaxProc),
       FmtCompleteStr(F.Line, MaxLine)]);
  end;

  procedure AppendFullWidthLine(const ASB: TStringBuilder; const AContent: String);
  begin
    ASB.Append('|');
    ASB.Append(FmtCompleteStr(AContent, ContentWidth));
    ASB.Append('|');
    ASB.Append(CRLF);
  end;

begin
  SB := TStringBuilder.Create;
  try
    // ============== Header line ==============
    // EurekaLog <Ver> PID CID PasswordHash RID
    // The EL Viewer strictly checks the "EurekaLog" prefix - it must not change
    // (otherwise the Viewer won't show the Call Stack). Our version is 1.0
    // (reports from this crash reporter, not from real EurekaLog).
    // Hashes are placeholders (zeros).
    SB.Append('EurekaLog 1.0 ');
    SB.Append(StringOfChar('0', 32)); SB.Append(' ');
    SB.Append(StringOfChar('0', 32)); SB.Append(' ');
    SB.Append(StringOfChar('0', 40)); SB.Append(' ');
    SB.Append(StringOfChar('0', 32)); SB.Append(CRLF);
    SB.Append(CRLF);

    // ============== Application ============== (mandatory: always emitted)
    AppendSectionHeader(SB, 'Application');
    AppendField(SB, '1.1 Start Date',       FormatELDate(ACtx.StartTime), 22);
    AppendField(SB, '1.2 Name/Description', ACtx.AppName, 22);
    AppendField(SB, '1.3 Version Number',   ACtx.AppVersion, 22);
    AppendField(SB, '1.4 Parameters',       ACtx.AppParameters, 22);
    AppendField(SB, '1.5 Compilation Date', ACtx.CompileTime, 22);
    if ACtx.StartTime <> 0 then
    begin
      UpSecs := SecondsBetween(Now, ACtx.StartTime);
      AppendField(SB, '1.6 Up Time', FormatUpTime(UpSecs), 22);
    end;
    SB.Append(CRLF);

    // ============== Exception ============== (mandatory: always emitted)
    Loc := AReport.ExceptionLocation;
    AppendSectionHeader(SB, 'Exception');
    AppendField(SB, '2.1 Date',           FormatELDate(ACtx.ExceptionTime), 18);
    AppendField(SB, '2.2 Address',        AddrHex(Loc.CodeAddress), 18);
    AppendField(SB, '2.3 Module Name',    ACtx.AppName, 18);
    AppendField(SB, '2.4 Module Version', ACtx.AppVersion, 18);
    AppendField(SB, '2.5 Type',           'Exception', 18);
    AppendField(SB, '2.6 Message',        AReport.ExceptionMessage, 18);
    AppendField(SB, '2.7 ID',             GenerateExceptionID(AReport), 18);
    AppendField(SB, '2.8 Count',          '1', 18);
    AppendField(SB, '2.11 Sent',          '0', 18);
    SB.Append(CRLF);

    // ============== User ==============
    if not (crsUser in ACtx.DisabledSections) then
    begin
      AppendSectionHeader(SB, 'User');
      AppendField(SB, '3.2 Name',  ACtx.UserName, 10);
      AppendField(SB, '3.3 Email', '', 10);
      SB.Append(CRLF);
    end;

    // ============== Computer ==============
    if not (crsComputer in ACtx.DisabledSections) then
    begin
      AppendSectionHeader(SB, 'Computer');
      AppendField(SB, '5.1 Name',        ACtx.ComputerName, 18);
      AppendField(SB, '5.9 Display DPI', IntToStr(ACtx.AppDpi), 18);
      SB.Append(CRLF);
    end;

    // ============== Operating System ==============
    if not (crsOperatingSystem in ACtx.DisabledSections) then
    begin
      AppendSectionHeader(SB, 'Operating System');
      AppendField(SB, '6.1 Type', ACtx.OSDescription, 26);
      SB.Append(CRLF);
    end;

    // ============== Steps to reproduce ==============
    if not (crsStepsToReproduce in ACtx.DisabledSections) then
    begin
      AppendSectionHeader(SB, 'Steps to reproduce');
      AppendField(SB, '8.1 Text', '', 10);
      SB.Append(CRLF);
    end;

    // ============== Call Stack Information ==============
    // Mandatory section: always emitted, NOT gated by DisabledSections. The EL
    // Viewer treats the first "-<CRLF>|" table as the report's structural anchor
    // (ELogManager ParseBuffer / GetItem_Generals); without it the file fails the
    // load gate and the remaining tabs mis-parse.
    // Pre-render each frame to compute max widths over the real data.
    Stack := AReport.CallStack;
    SetLength(Rendered, Length(Stack));
    for I := 0 to High(Stack) do
      Rendered[I] := RenderFrame(Stack[I], I, Length(Stack));

    // ===== Anti-fake-symbol pass (macOS Mach-O dladdr clamping) =====
    // On macOS dladdr returns the nearest exported symbol even if it is far away
    // - Mach-O default exports are narrow (SignalConverter/_main/@DbgExcNotify/...).
    // The same routine name on N frames is a clear sign of clamping: those
    // "names" are lies. We clear Source/Unit/Class/Procedure for clamped frames
    // so they aren't mistaken for real ones. Module + Offset stay - they resolve
    // via `atos -o <exe> 0x<addr>` on a dev machine.
    //
    // Threshold: 3 on all platforms. It used to be 2 on macOS to guard against
    // dladdr clamping (when dladdr returned SignalConverter for every frame in
    // our exe). Now Crash.MacOS.Symbols gives honest names from LC_SYMTAB, so
    // duplicates are only legitimate (two consecutive Pascal RTL helper routines,
    // the same function in recursion). Threshold 3 keeps those.
    const FakeNameThreshold = 3;
    if Length(Rendered) >= FakeNameThreshold then
    begin
      var NameCounts := TDictionary<String, Integer>.Create;
      try
        var Cnt: Integer;
        for I := 0 to High(Rendered) do
          if Rendered[I].AProcedure <> '' then
          begin
            if NameCounts.TryGetValue(Rendered[I].AProcedure, Cnt) then
              NameCounts[Rendered[I].AProcedure] := Cnt + 1
            else
              NameCounts.Add(Rendered[I].AProcedure, 1);
          end;
        for I := 0 to High(Rendered) do
        begin
          if Rendered[I].AProcedure = '' then Continue;
          if NameCounts[Rendered[I].AProcedure] >= FakeNameThreshold then
          begin
            Rendered[I].Source     := '';
            Rendered[I].AUnit      := '';
            Rendered[I].AClass     := '';
            Rendered[I].AProcedure := '';
            // Line holds the routine-offset proxy "+$N" on Linux/Windows when
            // there is no real LineNumber. Without AProcedure that delta is
            // meaningless too - the base address is already wrong.
            Rendered[I].Line       := '';
          end;
        end;
      finally
        NameCounts.Free;
      end;
    end;

    // Init max widths from captions (like EL CalculateLengths).
    MaxMethods   := Length(CapMethods);
    if MaxMethods < 8 then MaxMethods := 8; // EL: (TracerMax div 8)*2, 8 in practice
    MaxDetails   := Length(CapDetails);
    if MaxDetails < 2 then MaxDetails := 2;
    MaxStack     := Length(CapStack);
    if MaxStack < PointerHexLen then MaxStack := PointerHexLen;
    MaxAddress   := Length(CapAddress);
    if MaxAddress < PointerHexLen then MaxAddress := PointerHexLen;
    MaxModule    := Length(CapModule);
    MaxOffset    := Length(CapOffset);
    if MaxOffset < PointerHexLen then MaxOffset := PointerHexLen;
    MaxSource    := Length(CapSource);
    MaxUnit      := Length(CapUnit);
    MaxClass     := Length(CapClass);
    MaxProc      := Length(CapProcedure);
    MaxLine      := Length(CapLine);

    // Grow by data.
    for I := 0 to High(Rendered) do
    begin
      UpdateMax(MaxMethods, Rendered[I].Methods);
      UpdateMax(MaxDetails, Rendered[I].Details);
      UpdateMax(MaxStack,   Rendered[I].Stack);
      UpdateMax(MaxAddress, Rendered[I].Address);
      UpdateMax(MaxModule,  Rendered[I].Module);
      UpdateMax(MaxOffset,  Rendered[I].Offset);
      UpdateMax(MaxSource,  Rendered[I].Source);
      UpdateMax(MaxUnit,    Rendered[I].AUnit);
      UpdateMax(MaxClass,   Rendered[I].AClass);
      UpdateMax(MaxProc,    Rendered[I].AProcedure);
      UpdateMax(MaxLine,    Rendered[I].Line);
    end;

    // Full row width = sum(widths) + 12 pipes (1 leading + 10 between + 1 trailing).
    TotalRowLen := MaxMethods + MaxDetails + MaxStack + MaxAddress + MaxModule +
                   MaxOffset + MaxSource + MaxUnit + MaxClass + MaxProc + MaxLine + 12;
    ContentWidth := TotalRowLen - 2; // for the `|<content>|` lines

    // Title + dashes (length = TotalRowLen).
    SB.Append('Call Stack Information'); SB.Append(EHeaderSuffix); SB.Append(CRLF);
    SB.Append(StringOfChar('-', TotalRowLen)); SB.Append(CRLF);

    // Header row (column captions).
    SB.Append('|');
    SB.Append(FmtCompleteStr(CapMethods,   MaxMethods)); SB.Append('|');
    SB.Append(FmtCompleteStr(CapDetails,   MaxDetails)); SB.Append('|');
    SB.Append(FmtCompleteStr(CapStack,     MaxStack));   SB.Append('|');
    SB.Append(FmtCompleteStr(CapAddress,   MaxAddress)); SB.Append('|');
    SB.Append(FmtCompleteStr(CapModule,    MaxModule));  SB.Append('|');
    SB.Append(FmtCompleteStr(CapOffset,    MaxOffset));  SB.Append('|');
    SB.Append(FmtCompleteStr(CapSource,    MaxSource));  SB.Append('|');
    SB.Append(FmtCompleteStr(CapUnit,      MaxUnit));    SB.Append('|');
    SB.Append(FmtCompleteStr(CapClass,     MaxClass));   SB.Append('|');
    SB.Append(FmtCompleteStr(CapProcedure, MaxProc));    SB.Append('|');
    SB.Append(FmtCompleteStr(CapLine,      MaxLine));    SB.Append('|');
    SB.Append(CRLF);
    SB.Append(StringOfChar('-', TotalRowLen)); SB.Append(CRLF);

    // Per-thread block. We have one thread - the one where the raise happened.
    ThreadIDStr := IntToStr(ACtx.ThreadID);
    AppendFullWidthLine(SB, '*Exception Thread: ID=' + ThreadIDStr + '; Parent=0; Priority=0');
    AppendFullWidthLine(SB, 'Class=; Name=' + ACtx.ThreadName);
    AppendFullWidthLine(SB, 'DeadLock=0; Wait Chain=');
    AppendFullWidthLine(SB, 'Comment=');
    // Internal thread separator: `|<dashes>|`
    SB.Append('|'); SB.Append(StringOfChar('-', ContentWidth)); SB.Append('|'); SB.Append(CRLF);
    // Data rows.
    for I := 0 to High(Rendered) do
    begin
      SB.Append(FormatRow(Rendered[I]));
      SB.Append(CRLF);
    end;
    // Thread-block closing separator (with pipes - inside the thread block).
    SB.Append('|'); SB.Append(StringOfChar('-', ContentWidth)); SB.Append('|'); SB.Append(CRLF);
    // Table-end separator: dashes WITHOUT pipes, length = TotalRowLen. The EL
    // Viewer looks for exactly this pattern to detect "Call Stack finished".
    // Without it the Viewer tries to parse the next section as a continuation of
    // the call-stack table and breaks.
    SB.Append(StringOfChar('-', TotalRowLen)); SB.Append(CRLF);
    SB.Append(CRLF);

    // ============== Modules + Registers ==============
    // The EL Viewer locates the CPU/Registers section POSITIONALLY: GetItem_CPU
    // (ELogManager.pas) counts 2 blank-line breaks after the Call Stack table.
    // EL's normal layout is CallStack -> Modules -> Registers, so the 2nd break
    // lands on Registers. If we emit Registers with NO Modules section between,
    // the 2nd break lands on our internal Registers/Stack-Dump blank instead, and
    // the Viewer's CPU tab shows empty (the registers are still in the .el text).
    // So: when Registers WILL be emitted but the real Modules table is absent
    // (crsModules disabled, or enumeration returned nothing), emit an EMPTY
    // "Modules Information:" header as the positional anchor. Verified against the
    // Viewer source: Generate_Modules treats an empty Modules section as an empty
    // tab (no '|' rows => no data), and Generate_CPU then finds the registers.
    var RegsPresent := (not (crsRegisters in ACtx.DisabledSections)) and
                       (ACtx.CpuSnapshot <> '');
    var ModulesText := '';
    if not (crsModules in ACtx.DisabledSections) then
      ModulesText := CrashFormatModulesTable(CrashEnumerateModules);
    if ModulesText <> '' then
    begin
      // Full "Modules Information:" header; the table brings its own dashes lines,
      // so we don't call AppendSectionHeader.
      SB.Append('Modules Information'); SB.Append(EHeaderSuffix); SB.Append(CRLF);
      SB.Append(ModulesText);
      SB.Append(CRLF);
    end
    else if RegsPresent then
      // Empty positional anchor so the Viewer can locate the Registers below.
      AppendEmptySection(SB, 'Modules Information');
    // Processes / Assembler are not emitted (we have no data to fill them).
    //
    // Registers - special section name (EStrConsts.pas rsELCPU_RegistersVal).
    // Empty (no signal fired) is not emitted.
    if RegsPresent then
    begin
      SB.Append(ACtx.CpuSnapshot);
      if not ACtx.CpuSnapshot.EndsWith(CRLF) then SB.Append(CRLF);
      SB.Append(CRLF);
    end;
    // ===== Crash Signal Info (our metadata, outside the EL standard) =====
    // Comes AFTER all EL-known sections so the Viewer doesn't try to parse it.
    // It's invisible in the Viewer UI (unknown to it), but reads fine in a
    // text view of the .el file.
    if (not (crsSignalInfo in ACtx.DisabledSections)) and (ACtx.SignalInfoSection <> '') then
    begin
      SB.Append(ACtx.SignalInfoSection);
      if not ACtx.SignalInfoSection.EndsWith(CRLF) then SB.Append(CRLF);
      SB.Append(CRLF);
    end;

    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function CrashDefaultELContext(const AStartTime: TDateTime): TCrashELContext;
var
  I: Integer;
  Params: TStringList;
  {$IF not Defined(MSWINDOWS)}
  UTS: utsname;
  {$IFEND}
begin
  Result := Default(TCrashELContext);
  Result.AppName := ExtractFileName(ParamStr(0));
  // AppName/AppVersion/CompileTime are host-supplied: the reporter overlays
  // them from TCrashConfig after this call. Left empty here by design.
  Params := TStringList.Create;
  try
    for I := 1 to ParamCount do
      Params.Add(ParamStr(I));
    Result.AppParameters := String.Join(' ', Params.ToStringArray);
  finally
    Params.Free;
  end;
  if AStartTime <> 0 then
    Result.StartTime := AStartTime
  else
    Result.StartTime := Now;
  Result.ExceptionTime := Now;
  // Take both sections in one call (the snapshot is reset, a second call can't
  // give the same data). If the handler didn't fire - both empty.
  CrashTakeAndFormatSnapshots(Result.CpuSnapshot, Result.SignalInfoSection);
  // macOS-only note: on macOS the Pascal RTL catches signals via Mach exception
  // ports (task_set_exception_ports), bypassing the POSIX sigaction layer - our
  // handler is NOT called, so Registers is always absent. We explain this in the
  // .el so the reader doesn't look for a bug that isn't there.
  {$IF Defined(MACOS)}
  if Result.SignalInfoSection = '' then
    Result.SignalInfoSection :=
      'Crash Signal Info:' + #13#10 +
      '--------------------' + #13#10 +
      Format('  MachO symtab cache: %d entries', [CrashMacOSSymbolCacheCount]) + #13#10 +
      '  Note       : macOS uses Mach exception ports for signal delivery,' + #13#10 +
      '               not POSIX sigaction - our CPU snapshot handler does' + #13#10 +
      '               not fire on this platform. Primary fault details are' + #13#10 +
      '               in section 2 (Exception).' + #13#10 +
      '               To resolve Pascal addresses on dev machine:' + #13#10 +
      '                 atos -o <exe>.app/Contents/MacOS/<exe> 0x<address>' + #13#10;
  {$IFEND}

  // Linux diagnostics: why is Line=0 on all frames? Fold the .gol loader's
  // status into Signal Info so the reader sees the real state.
  {$IF Defined(LINUX)}
  begin
    var Lni := Crash.CallStack.TCrashCapture.GetLineNumberInfo;
    var StatusStr: String;
    case Lni.Status of
      TLineNumberStatus.Available:            StatusStr := 'Available';
      TLineNumberStatus.FileNotFound:         StatusStr := 'FileNotFound';
      TLineNumberStatus.InvalidSize:          StatusStr := 'InvalidSize';
      TLineNumberStatus.InvalidSignature:     StatusStr := 'InvalidSignature';
      TLineNumberStatus.UnsupportedVersion:   StatusStr := 'UnsupportedVersion';
      TLineNumberStatus.ExecutableIDMismatch: StatusStr := 'ExecutableIDMismatch';
      TLineNumberStatus.FileCorrupt:          StatusStr := 'FileCorrupt';
      TLineNumberStatus.Exception:            StatusStr := 'Exception during load';
    else
      StatusStr := 'Unknown';
    end;
    var Diag := 'Crash LineNumberInfo (diag):' + #13#10 +
                '------------------------------' + #13#10 +
                '  .gol expected at: ' + Lni.DiagFilename + #13#10 +
                '  .gol exists?    : ' + BoolToStr(Lni.DiagFileExists, True) + #13#10 +
                '  Status          : ' + StatusStr + #13#10 +
                Format('  BaseAddress     : 0x%.16x', [Lni.BaseAddress]) + #13#10 +
                Format('  Line entries    : %d', [Lni.LineCount]) + #13#10 +
                '  ELF BuildID(16) : ' + Lni.DiagImageBuildIdHex + #13#10 +
                '  .gol Header.ID  : ' + Lni.DiagHeaderIdHex + #13#10;
    if (Lni.Status <> TLineNumberStatus.Available) and Lni.DiagHasDwarf then
      Diag := Diag +
        '  Note            : ELF carries embedded DWARF (.debug_line) but no' + #13#10 +
        '                    usable .gol, so source line numbers are not' + #13#10 +
        '                    available (the Line column falls back to +$offset' + #13#10 +
        '                    proxies). This is typically an IDE-built Linux' + #13#10 +
        '                    binary: the IDE drives dcclinux64 directly and' + #13#10 +
        '                    skips the MSBuild post-build that generates the' + #13#10 +
        '                    .gol. Rebuild via "build.cmd fmx_linux" to emit a' + #13#10 +
        '                    matching .gol next to the executable.' + #13#10;
    if Result.SignalInfoSection = '' then
      Result.SignalInfoSection := Diag
    else
      Result.SignalInfoSection := Result.SignalInfoSection + #13#10 + Diag;
  end;
  {$IFEND}

  {$IF Defined(MSWINDOWS)}
  Result.UserName := GetEnvironmentVariable('USERNAME');
  Result.ComputerName := GetEnvironmentVariable('COMPUTERNAME');
  Result.OSDescription := 'Microsoft Windows';
  {$ELSE}
  Result.UserName := String(GetEnvironmentVariable('USER'));
  FillChar(UTS, SizeOf(UTS), 0);
  if Posix.SysUtsname.uname(UTS) = 0 then
  begin
    Result.ComputerName := String(MarshaledAString(@UTS.nodename));
    Result.OSDescription :=
      String(MarshaledAString(@UTS.sysname)) + ' ' +
      String(MarshaledAString(@UTS.release)) + ' ' +
      String(MarshaledAString(@UTS.machine));
  end
  else
  begin
    Result.ComputerName := '';
    Result.OSDescription := 'POSIX';
  end;
  {$IFEND}
  Result.AppDpi := 96;
  Result.ThreadID := 0;        // overridden by the reporter with the real crashing TID
  Result.ThreadName := 'MAIN'; // overridden by the reporter for worker threads
end;

end.
