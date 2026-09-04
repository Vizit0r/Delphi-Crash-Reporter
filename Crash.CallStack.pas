unit Crash.CallStack;
{ Exception capture engine: installs the Delphi RTL exception hooks
  (ExceptProc / ExceptionAcquired / Exception.GetExceptionStackInfoProc) and,
  on an unhandled exception, builds a TCrashReport (message + fault location +
  call stack) and hands it to TCrashCapture.OnReport. The host wires
  Application.OnException := TCrashCapture.ExceptionHandler for main-thread
  GUI exceptions.

  Call stacks are produced on macOS (backtrace), Android (frame/unwind) and
  Linux (libgcc _Unwind_Backtrace); on Windows the unit is a no-op - the
  singleton is not created and no RTL hook is installed (EurekaLog territory).

  Part of the Crash Reporter library - standalone, EurekaLog-compatible
  crash/exception reporting for Delphi cross-platform targets.

  Derived from Grijjy JustAddCode / ErrorReporting:
    Copyright (c) 2017 Grijjy, Inc. BSD 2-Clause license (see LICENSE.txt).
  Modifications under the same BSD 2-Clause license. }

interface

uses
  {$IF (Defined(MACOS64) and not Defined(IOS)) or Defined(LINUX)}
  Crash.LineNumbers,
  System.Generics.Collections,
  {$ENDIF}
  System.SysUtils;

type
  { Signature of the TApplication.OnException event }
  TCrashExceptionEvent = procedure(Sender: TObject; E: Exception) of object;

type
  { A single entry in a stack trace }
  TCrashStackEntry = record
  public
    { The address of the code in the call stack. }
    CodeAddress: UIntPtr;

    { The address of the start of the routine in the call stack. The CodeAddress
      value always lies inside the routine that starts at RoutineAddress.
      This, the value "CodeAddress - RoutineAddress" is the offset into the
      routine in the call stack. }
    RoutineAddress: UIntPtr;

    { The (base) address of the module where CodeAddress is found. }
    ModuleAddress: UIntPtr;

    { The line number (of CodeAddress), or 0 if not available. }
    LineNumber: Integer;

    { Line number where the routine starts (of RoutineAddress), or 0 if not
      available. Lets the report formatter compute the in-routine relative
      line as (LineNumber - RoutineLineNumber + 1) for EL Viewer's Rel.Line
      column. Currently filled only on MACOS64 desktop where Grijjy has
      access to a .gol file -- on Linux/Win/Android stays 0. }
    RoutineLineNumber: Integer;

    { The name of the routine at CodeAddress, if available. }
    RoutineName: String;

    { The name of the module where CodeAddress is found. If CodeAddress is
      somewhere inside your (Delphi) code, then this will be the name of the
      executable module (or .so file on Android). }
    ModuleName: String;

    { Source file (e.g. "MyApp.Forms.Main.pas") from debug info, when the
      resolver knows it authoritatively. Lets the formatter take the unit from the
      file (correct casing) and split class/method unambiguously instead of guessing
      from the dotted name. Currently filled on Android (.gosym); '' elsewhere. }
    SourceFile: String;

    { True when RoutineName/RoutineAddress come from an authoritative source
      (Mach-O LC_SYMTAB cache, Android .gosym) rather than a dladdr
      nearest-export guess. Exempts the frame from the formatter's fake-name
      pass, so genuine recursion keeps its name. }
    NameTrusted: Boolean;
  public
    { Clears the entry (sets everything to 0) }
    procedure Clear;
  end;

type
  { A call stack (aka stack trace) is just an array of call stack entries. }
  TCrashStack = TArray<TCrashStackEntry>;

type
  { Which hook fired this report. Lets the adapter decide "process stays alive"
    vs "process will Halt right after we return". }
  TCrashSource = (
    csOnException,   // Application.OnException - FMX main thread caught it; process stays alive.
    csAcquired,      // ExceptionAcquired - secondary thread caught it; process stays alive.
    csFatalProc      // ExceptProc - truly unhandled; RTL will Halt(217) shortly.
  );

type
  TCrashThreadCaptureState = (
    ctcsCaptured,
    ctcsTimedOut,
    ctcsThreadGone,
    ctcsSignalUnavailable,
    ctcsBudgetExceeded,
    ctcsCaptureFailed
  );

  { One optional application-thread block appended to the EL call-stack table.
    Failure states are explicit and keep CallStack empty. }
  TCrashThreadStack = record
    ThreadID: UInt64;
    Name: String;
    GroupID: UInt64;
    State: TCrashThreadCaptureState;
    CallStack: TCrashStack;
    CaptureDiagnostics: String;
  end;

  { A captured exception report: message, fault location, full call stack, and
    which hook fired. A plain value type - no interface, no refcounting. }
  TCrashReport = record
    ExceptionMessage: String;
    ExceptionClassName: String;
    ExceptionLocation: TCrashStackEntry;
    CallStack: TCrashStack;
    PrimaryGroupID: UInt64;
    ExtendedThreads: TArray<TCrashThreadStack>;
    ExtendedThreadsOmitted: Integer;
    { Free-text bounded-capture diagnostics for the primary sampled thread
      (currently the watched thread in freeze reports). }
    PrimaryCaptureDiagnostics: String;
    Source: TCrashSource;
    { Freeze-watchdog report (Crash.Freeze): the stack is a SAMPLE of a running
      thread, not a raise point - BugID generation uses the freeze
      normalization (see CrashGenerateExceptionID). }
    IsFreeze: Boolean;
  end;

const
  { Sentinel ExceptionMessage set when the captured exception object is nil - a
    "phantom" report with no real exception behind it. Lets consumers recognise
    a content-less report (see GlobalHandleException). A non-nil but non-Exception
    object yields 'Unknown Error (<ClassName>)' instead, which is NOT this. }
  CrashMsgNilException = 'Unknown Error';

type
  { Optional report sections the host can omit via TCrashConfig.DisabledSections.
    When a section is disabled, its header AND body vanish from the .el entirely.
    Application, Exception and Call Stack are mandatory (always emitted) and are
    intentionally NOT listed here: Application/Exception carry the core "what
    crashed and where", and the EL Viewer needs the Call Stack table as the report's
    structural anchor (see ELogManager ParseBuffer / GetItem_Generals). }
  TCrashReportSection = (
    crsUser,              // section 3.x  User (name, email)
    crsComputer,          // section 5.x  Computer (name, display DPI)
    crsOperatingSystem,   // section 6.x  Operating System (type)
    crsStepsToReproduce,  // section 8.x  Steps to reproduce (text)
    crsModules,           // Modules Information table
    crsRegisters,         // Registers (present only after a hardware signal fault)
    crsSignalInfo         // Crash Signal Info (our custom trailing block)
  );
  TCrashReportSections = set of TCrashReportSection;

const
  { Every optional section. `DisabledSections := AllOptionalCrashReportSections`
    yields the most minimal report: the mandatory Application + Exception + Call
    Stack only. }
  AllOptionalCrashReportSections: TCrashReportSections =
    [crsUser, crsComputer, crsOperatingSystem, crsStepsToReproduce,
     crsModules, crsRegisters, crsSignalInfo];

type
  { Invoked by TCrashCapture when an unhandled exception is captured. Set it via
    TCrashCapture.OnReport. The report is built and handed over directly (no
    message broadcasting). May be called from any thread. }
  TCrashReportEvent = reference to procedure(const AReport: TCrashReport);

type
  { Main class for reporting exceptions.
    See the documentation at the top of this unit for usage information. }
  TCrashCapture = class
  {$REGION 'Internal Declarations'}
  private class var
    FInstance: TCrashCapture;
    FOnReport: TCrashReportEvent;
    {$IF (Defined(MACOS64) and not Defined(IOS)) or Defined(LINUX)}
    FLineNumberInfo: TLineNumberInfo;
    { Per-module .gol readers for NON-main loaded modules (.so/.dylib), keyed by
      module base. Lazily populated; a nil value caches a "no .gol" miss. }
    FModuleReaders: TDictionary<UIntPtr, TLineNumberInfo>;
    class function GetLineNumber(const AAddress: UIntPtr): Integer; static;
    class function GetModuleLineNumber(const AAddress: UIntPtr): Integer; static;
  public class var
    class function GetLineNumberInfo: TLineNumberInfo; static;
  private class var
    {$ENDIF}
    class function GetExceptionHandler: TCrashExceptionEvent; static;
    class function GetMaxCallStackDepth: Integer; static;
    class procedure SetMaxCallStackDepth(const Value: Integer); static;
  private
    FMaxCallStackDepth: Integer;
    FModuleAddress: UIntPtr;
    FReportingException: Integer; // 0/1 via TInterlocked - single-flight gate across concurrently crashing threads
  private
    constructor InternalCreate(const ADummy: Integer = 0);
    procedure ReportException(const AExceptionObject: TObject;
      const AExceptionAddress: Pointer;
      const ASource: TCrashSource);
  private
    class function GetCallStack(const AStackInfo: Pointer): TCrashStack; static;
    class function GetCallStackEntry(var AEntry: TCrashStackEntry): Boolean; static;
  private
    { Global hooks }
    procedure GlobalHandleException(Sender: TObject; E: Exception);
    class procedure GlobalExceptionAcquiredHandler(Obj: {$IFDEF AUTOREFCOUNT}TObject{$ELSE}Pointer{$ENDIF}); static;
    class procedure GlobalExceptHandler(ExceptObject: TObject; ExceptAddr: Pointer); static;
    class function GlobalGetExceptionStackInfo(P: PExceptionRecord): Pointer; static;
    class procedure GlobalCleanUpStackInfo(Info: Pointer); static;
  {$ENDREGION 'Internal Declarations'}
  public
    { Don't call the constructor manually. This is a singleton. }
    constructor Create;

    { Set to Application.OnException handler event to this value to report
      unhandled exceptions in the main (UI) thread.
      For example:
        Application.OnException := TCrashCapture.ExceptionHandler; }
    class property ExceptionHandler: TCrashExceptionEvent read GetExceptionHandler;

    { Host (the reporter) sets this to receive captured reports directly. }
    class property OnReport: TCrashReportEvent read FOnReport write FOnReport;

    { Maximum depth of the call stack that is retrieved when an exception
      occurs. Defaults to 20.

      Every time an exception is raised, we retrieve a call stack. This adds a
      little overhead, but raising exceptions is already an "expensive"
      operation anyway.

      You can limit this overhead by decreasing the maximum number of entries
      in the call stack. You can also increase this number of you want a more
      detailed call stack.

      Set to 0 to disable call stacks altogether. }
    class property MaxCallStackDepth: Integer read GetMaxCallStackDepth write SetMaxCallStackDepth;

    { Support for the freeze detector (Crash.Freeze): the watchdog thread
      builds a report for ANOTHER (frozen) thread. }

    { Cross-thread report gate - the same single-flight flag the exception
      path uses (FReportingException). The freeze watchdog holds it while
      symbolizing/formatting so it never races a crashing thread's resolver
      state (module readers, line-number caches). While held, a concurrent
      exception loses its call stack (GetExceptionStackInfo bails out) - rare
      and acceptable; the crash itself is still reported. False when the
      singleton does not exist (Windows) or the gate is busy. }
    class function TryEnterReportGate: Boolean; static;
    class procedure LeaveReportGate; static;

    { Symbolize a raw address list into a TCrashStack (dladdr + demangle +
      line numbers) - the same pipeline the exception path applies to its
      backtrace. nil when call stacks are unsupported on this target. }
    class function SymbolizeAddressList(const AAddrs: array of UIntPtr): TCrashStack; static;

    { Base address of the module that carries the application code (dladdr on
      our own method at Init) - the identity of "our frame" for grouping.
      Matching by ADDRESS, not by executable name: on Android the app code
      lives in the app's .so and ParamStr(0) is empty, so a name probe cannot
      work there. 0 before Init / on unsupported targets. }
    class function MainModuleAddress: UIntPtr; static;
  end;

implementation

uses
  System.Classes,
  System.SyncObjs,
  {$IF Defined(MACOS) or Defined(ANDROID) or Defined(LINUX)}
  Posix.Dlfcn,
  Posix.Stdlib,
  {$ENDIF}
  {$IF Defined(LINUX)} // Posix.Base for libc/_PU constants
  Posix.Base,
  {$ENDIF}
  Crash.Demangle,
  Crash.Signals,
  Crash.MacOS.Symbols,   // LC_SYMTAB name adoption (no-op off macOS)
  Crash.Android.Symbols; // .gosym name resolution (no-op off Android)

{$RANGECHECKS OFF}

{ TCrashStackEntry }

procedure TCrashStackEntry.Clear;
begin
  CodeAddress := 0;
  RoutineAddress := 0;
  ModuleAddress := 0;
  LineNumber := 0;
  RoutineLineNumber := 0;
  RoutineName := '';
  ModuleName := '';
  SourceFile := '';
  NameTrusted := False;
end;

{ TCrashCapture }

constructor TCrashCapture.Create;
begin
  raise EInvalidOperation.Create('Invalid singleton constructor call');
end;

class function TCrashCapture.GetExceptionHandler: TCrashExceptionEvent;
begin
  { HandleException is usually called in response to the FMX
    Application.OnException event, which is called for exceptions that aren't
    handled in the main thread. This event is only fired for exceptions that
    occur in the main (UI) thread though. }
  if Assigned(FInstance) then
    Result := FInstance.GlobalHandleException
  else
    Result := nil;
end;

class function TCrashCapture.GetMaxCallStackDepth: Integer;
begin
  if Assigned(FInstance) then
    Result := FInstance.FMaxCallStackDepth
  else
    Result := 20;
end;

class function TCrashCapture.MainModuleAddress: UIntPtr;
begin
  if Assigned(FInstance) then
    Result := FInstance.FModuleAddress
  else
    Result := 0;
end;

class procedure TCrashCapture.GlobalCleanUpStackInfo(Info: Pointer);
begin
  { Free memory allocated by GlobalGetExceptionStackInfo }
  if (Info <> nil) then
    FreeMem(Info);
end;

class procedure TCrashCapture.GlobalExceptHandler(ExceptObject: TObject;
  ExceptAddr: Pointer);
begin
  if Assigned(FInstance) then
    FInstance.ReportException(ExceptObject, ExceptAddr, csFatalProc);
end;

class procedure TCrashCapture.GlobalExceptionAcquiredHandler(
  Obj: {$IFDEF AUTOREFCOUNT}TObject{$ELSE}Pointer{$ENDIF});
begin
  if Assigned(FInstance) then
    FInstance.ReportException(Obj, ExceptAddr, csAcquired);
end;

procedure TCrashCapture.GlobalHandleException(Sender: TObject; E: Exception);
begin
  ReportException(E, ExceptAddr, csOnException);
end;

{$IF Defined(MACOS) or Defined(ANDROID) or Defined(LINUX)}
procedure CrashModuleAnchor;
begin
end;
{$ENDIF}

constructor TCrashCapture.InternalCreate(const ADummy: Integer);
{$IF Defined(MACOS) or Defined(ANDROID) or Defined(LINUX)}
var
  Info: dl_info;
{$ENDIF}
begin
  inherited Create;
  FMaxCallStackDepth := 20;

  { Assign the global ExceptionAcquired procedure to our own implementation (it
    is nil by default). This procedure gets called for unhandled exceptions that
    happen in other threads than the main thread. }
  ExceptionAcquired := @GlobalExceptionAcquiredHandler;

  { The global ExceptProc method can be called for certain unhandled exception.
    By default, it calls the ExceptHandler procedure in the System.SysUtils
    unit, which shows the exception message and terminates the app.
    We set it to our own implementation. }
  ExceptProc := @GlobalExceptHandler;

  { We hook into the global static GetExceptionStackInfoProc and
    CleanUpStackInfoProc methods of the Exception class to provide a call stack
    for the exception. These methods are unassigned by default.
    The Exception.GetExceptionStackInfoProc method gets called soon after the
    exception is created, before the call stack is unwound. This is the only
    place where we can get the call stack at the point closest to the exception
    as possible. The Exception.CleanUpStackInfoProc just frees the memory
    allocated by GetExceptionStackInfoProc. }
  Exception.GetExceptionStackInfoProc := GlobalGetExceptionStackInfo;
  Exception.CleanUpStackInfoProc := GlobalCleanUpStackInfo;

  {$IF Defined(MACOS) or Defined(ANDROID) or Defined(LINUX)}
  { A Delphi class-method address is not a reliable native code address on all
    targets (Android may expose a JIT/thunk address). Anchor dladdr on a plain
    unit procedure that is unambiguously emitted in this module. }
  if (dladdr(UIntPtr(@CrashModuleAnchor), Info) <> 0) then
    FModuleAddress := UIntPtr(Info.dli_fbase);
  {$ENDIF}
end;

procedure TCrashCapture.ReportException(const AExceptionObject: TObject;
  const AExceptionAddress: Pointer;
  const ASource: TCrashSource);
var
  E: Exception;
  ExceptionMessage: String;
  ExcClassName: String;
  CallStack: TCrashStack;
  ExceptionLocation: TCrashStackEntry;
  Report: TCrashReport;
  I: Integer;
  FaultAddr: UIntPtr;
  CallerAddr: UIntPtr;
  InsertIdx: Integer;
  FaultEntry: TCrashStackEntry;
begin
  { Ignore exceptions that occur while we are already reporting another
    exception (cascading errors). Atomic: two threads crashing at once must not
    both proceed - the loser would race the shared resolver state
    (FModuleReaders) mid-report. The losing report is dropped. }
  if TInterlocked.CompareExchange(FReportingException, 1, 0) <> 0 then
    Exit;
  try
    CallStack := nil;
    if (AExceptionObject = nil) then
      ExceptionMessage := CrashMsgNilException
    else if (AExceptionObject is EAbort) then
      Exit //  do nothing
    else if (AExceptionObject is EControlC) then
      Exit // user-initiated Ctrl-C (SIGINT): terminate without a crash report
    else if (AExceptionObject is Exception) then
    begin
      E := Exception(AExceptionObject);
      ExceptionMessage := E.Message;
      if (E.StackInfo <> nil) then
      begin
        CallStack := GetCallStack(E.StackInfo);
        for I := 0 to Length(Callstack) - 1 do
        begin
          { If entry in call stack is for this module, then try to translate
            the routine name to Pascal. }
          if (CallStack[I].ModuleAddress = FModuleAddress) then
            CallStack[I].RoutineName := CppSymbolToPascal(CallStack[I].RoutineName);
        end;
      end;
    end
    else
      ExceptionMessage := 'Unknown Error (' + AExceptionObject.ClassName + ')';

    if AExceptionObject <> nil then
      ExcClassName := AExceptionObject.ClassName
    else
      ExcClassName := '';

    ExceptionLocation.Clear;
    ExceptionLocation.CodeAddress := UIntPtr(AExceptionAddress);
    GetCallStackEntry(ExceptionLocation);
    if (ExceptionLocation.ModuleAddress = FModuleAddress) then
      ExceptionLocation.RoutineName := CppSymbolToPascal(ExceptionLocation.RoutineName);

    { Re-insert the faulting frame for a hardware exception (SIGSEGV/SIGFPE/...).
      The POSIX signal model used by Crash.Signals returns from the handler and
      lets the RTL re-raise, which drops the FAULTING frame from the libc
      backtrace (the stack jumps straight to its caller). CrashPrimaryFaultAddr
      returns the fault RIP/PC only when the fault is a primary one in our exe
      range; we additionally require it to match this exception's address (guards
      against a stale snapshot riding a later soft `raise`) and to resolve to one
      of OUR source lines (LineNumber<>0 -> a unit with debug line info, i.e. our
      code, not a precompiled RTL/FMX unit or a system library). When all hold,
      prepend it as frame 0 so the crash line is visible in the call stack. A soft
      `raise` has no snapshot (its backtrace already includes the raise site), so
      nothing is inserted; a fault outside our code does not resolve to a line, so
      nothing is inserted either. }
    if CrashPrimaryFaultAddr(FaultAddr) and (FaultAddr = UIntPtr(AExceptionAddress)) then
    begin
      FaultEntry.Clear;
      FaultEntry.CodeAddress := FaultAddr;
      GetCallStackEntry(FaultEntry);
      if (FaultEntry.ModuleAddress = FModuleAddress) then
        FaultEntry.RoutineName := CppSymbolToPascal(FaultEntry.RoutineName);
      if (FaultEntry.LineNumber <> 0) then
      begin
        { Splice point: the faulting frame's caller. Its return address ([FP+8],
          from the snapshot) is still present in the libc backtrace -- only the
          faulting frame itself was dropped. Insert the faulting frame right
          before the caller so it lands in its TRUE position (between the RTL
          signal-conversion frames and the caller). Match within an 8-byte window
          because GetCallStack may bias the stored address (ARM64 subtracts 4).
          If the caller can't be located, fall back to the top (frame 0). }
        InsertIdx := 0;
        if CrashPrimaryFaultCallerAddr(CallerAddr) then
          for I := 0 to High(CallStack) do
            if (CallStack[I].CodeAddress <= CallerAddr) and
               (CallerAddr - CallStack[I].CodeAddress <= 8) then
            begin
              InsertIdx := I;
              Break;
            end;
        { Idempotency: skip if the faulting frame already occupies that slot. }
        if (InsertIdx >= Length(CallStack)) or
           (CallStack[InsertIdx].CodeAddress <> FaultEntry.CodeAddress) then
        begin
          SetLength(CallStack, Length(CallStack) + 1);
          for I := High(CallStack) downto InsertIdx + 1 do
            CallStack[I] := CallStack[I - 1];
          CallStack[InsertIdx] := FaultEntry;
        end;
      end;
    end;

    Report.ExceptionMessage := ExceptionMessage;
    Report.ExceptionClassName := ExcClassName;
    Report.ExceptionLocation := ExceptionLocation;
    Report.CallStack := CallStack;
    Report.Source := ASource;
    if Assigned(FOnReport) then
    try
      FOnReport(Report);
    except
      { Ignore any exceptions in the report handler. }
    end;
  finally
    TInterlocked.Exchange(FReportingException, 0);
  end;
end;

class procedure TCrashCapture.SetMaxCallStackDepth(const Value: Integer);
begin
  if Assigned(FInstance) then
    FInstance.FMaxCallStackDepth := Value;
end;

{$IF Defined(MACOS)}

(*****************************************************************************)
(*** iOS/macOS specific ******************************************************)
(*****************************************************************************)

const
  libSystem = '/usr/lib/libSystem.dylib';

function backtrace(buffer: PPointer; size: Integer): Integer;
  external libSystem name 'backtrace';

function cxa_demangle(const mangled_name: MarshaledAString;
  output_buffer: MarshaledAString; length: NativeInt;
  out status: Integer): MarshaledAString; cdecl;
  external libSystem name '__cxa_demangle';

type
  TCallStack = record
    { Number of entries in the call stack }
    Count: Integer;

    { The entries in the call stack }
    Stack: array [0..0] of UIntPtr;
  end;
  PCallStack = ^TCallStack;

class function TCrashCapture.GlobalGetExceptionStackInfo(
  P: PExceptionRecord): Pointer;
var
  CallStack: PCallStack;
begin
  { Don't call into FInstance here. That would only add another entry to the
    call stack. Instead, retrieve the entire call stack from within this method.
    Just return nil if we are already reporting an exception, or call stacks
    are disabled. }
  if (FInstance = nil) or (FInstance.FReportingException <> 0) or (FInstance.FMaxCallStackDepth <= 0) then
    Exit(nil);

  { Allocate a PCallStack record large enough to hold just MaxCallStackDepth
    entries }
  GetMem(CallStack, SizeOf(TCallStack) +
    (FInstance.FMaxCallStackDepth - 1) * SizeOf(UIntPtr));

  { Use backtrace API to retrieve call stack }
  CallStack.Count := backtrace(@CallStack.Stack, FInstance.FMaxCallStackDepth);
  Result := CallStack;
end;

class function TCrashCapture.GetCallStack(
  const AStackInfo: Pointer): TCrashStack;
var
  CallStack: PCallStack;
  I: Integer;
begin
  { Convert TCallStack to TCrashStack }
  CallStack := AStackInfo;
  SetLength(Result, CallStack.Count);
  for I := 0 to CallStack.Count - 1 do
  begin
    Result[I].CodeAddress := CallStack.Stack[I];
    GetCallStackEntry(Result[I]);
  end;
end;

{$ELSEIF Defined(ANDROID64)}

(*****************************************************************************)
(*** Android64 specific ******************************************************)
(*****************************************************************************)

function cxa_demangle(const mangled_name: MarshaledAString;
  output_buffer: MarshaledAString; length: NativeInt;
  out status: Integer): MarshaledAString; cdecl;
  external 'libc++abi.a' name '__cxa_demangle';

type
  _PUnwind_Context = Pointer;
  _Unwind_Ptr = UIntPtr;

type
  _Unwind_Reason_code = Integer;

const
  _URC_NO_REASON = 0;
  _URC_FOREIGN_EXCEPTION_CAUGHT = 1;
  _URC_FATAL_PHASE2_ERROR = 2;
  _URC_FATAL_PHASE1_ERROR = 3;
  _URC_NORMAL_STOP = 4;
  _URC_END_OF_STACK = 5;
  _URC_HANDLER_FOUND = 6;
  _URC_INSTALL_CONTEXT = 7;
  _URC_CONTINUE_UNWIND = 8;
type
  _Unwind_Trace_Fn = function(context: _PUnwind_Context; userdata: Pointer): _Unwind_Reason_code; cdecl;

const
  LIB_UNWIND = 'libunwind.a';

procedure _Unwind_Backtrace(fn: _Unwind_Trace_Fn; userdata: Pointer); cdecl; external LIB_UNWIND;
function _Unwind_GetIP(context: _PUnwind_Context): _Unwind_Ptr; cdecl; external LIB_UNWIND;

type
  TCallStack = record
    { Number of entries in the call stack }
    Count: Integer;

    { The entries in the call stack }
    Stack: array [0..0] of UIntPtr;
  end;
  PCallStack = ^TCallStack;

function UnwindCallback(AContext: _PUnwind_Context; AUserData: Pointer): _Unwind_Reason_code; cdecl;
var
  Callstack: PCallstack;
begin
  Callstack := AUserData;
  if (TCrashCapture.FInstance = nil) or (Callstack.Count >= TCrashCapture.FInstance.FMaxCallStackDepth) then
    Exit(_URC_END_OF_STACK);

  Callstack.Stack[Callstack.Count] := _Unwind_GetIP(AContext);
  Inc(Callstack.Count);
  Result := _URC_NO_REASON;
end;

class function TCrashCapture.GlobalGetExceptionStackInfo(
  P: PExceptionRecord): Pointer;
var
  CallStack: PCallStack;
begin
  { Don't call into FInstance here. That would only add another entry to the
    call stack. Instead, retrieve the entire call stack from within this method.
    Just return nil if we are already reporting an exception, or call stacks
    are disabled. }
  if (FInstance = nil) or (FInstance.FReportingException <> 0) or (FInstance.FMaxCallStackDepth <= 0) then
    Exit(nil);

  { Allocate a PCallStack record large enough to hold just MaxCallStackDepth
    entries }
  GetMem(CallStack, SizeOf(TCallStack) +
    (FInstance.FMaxCallStackDepth - 1) * SizeOf(UIntPtr));

  { Use _Unwind_Backtrace API to retrieve call stack }
  CallStack.Count := 0;
  _Unwind_Backtrace(UnwindCallback, Callstack);
  Result := CallStack;
end;

class function TCrashCapture.GetCallStack(
  const AStackInfo: Pointer): TCrashStack;
var
  CallStack: PCallStack;
  I: Integer;
begin
  { Convert TCallStack to TCrashStack }
  CallStack := AStackInfo;
  SetLength(Result, CallStack.Count);
  for I := 0 to CallStack.Count - 1 do
  begin
    Result[I].CodeAddress := CallStack.Stack[I];
    GetCallStackEntry(Result[I]);
  end;
end;

{$ELSEIF Defined(ANDROID)}

(*****************************************************************************)
(*** Android32 specific ******************************************************)
(*****************************************************************************)

type
  TGetFramePointer = function: NativeUInt; cdecl;

const
  { We need a function to get the frame pointer. The address of this frame
    pointer is stored in register R7.
    In assembly code, the function would look like this:
      ldr R0, [R7]       // Retrieve frame pointer
      bx  LR             // Return to caller
    The R0 register is used to store the function result.
    The "bx LR" line means "return to the address stored in the LR register".
    The LR (Link Return) register is set by the calling routine to the address
    to return to.

    We could create a text file with this code, assemble it to a static library,
    and link that library into this unit. However, since the routine is so
    small, it assembles to just 8 bytes, which we store in an array here. }
  GET_FRAME_POINTER_CODE: array [0..7] of Byte = (
    $00, $00, $97, $E5,  // ldr R0, [R7]
    $1E, $FF, $2F, $E1); // bx  LR

var
  { Now define a variable of a procedural type, that is assigned to the
    assembled code above }
  GetFramePointer: TGetFramePointer = @GET_FRAME_POINTER_CODE;

function cxa_demangle(const mangled_name: MarshaledAString;
  output_buffer: MarshaledAString; length: NativeInt;
  out status: Integer): MarshaledAString; cdecl;
  external {$IF (RTLVersion < 34)}'libgnustl_static.a'{$ELSE}'libc++abi.a'{$ENDIF} name '__cxa_demangle';

type
  { For each entry in the call stack, we save 7 values for inspection later.
    See GlobalGetExceptionStackInfo for explaination. }
  TStackValues = array [0..6] of UIntPtr;

type
  TCallStack = record
    { Number of entries in the call stack }
    Count: Integer;

    { The entries in the call stack }
    Stack: array [0..0] of TStackValues;
  end;
  PCallStack = ^TCallStack;

class function TCrashCapture.GlobalGetExceptionStackInfo(
  P: PExceptionRecord): Pointer;
const
  { On most Android systems, each thread has a stack of 1MB }
  MAX_STACK_SIZE = 1024 * 1024;
var
  MaxCallStackDepth, Count: Integer;
  FramePointer, MinStack, MaxStack: UIntPtr;
  Address: Pointer;
  CallStack: PCallStack;
begin
  { Don't call into FInstance here. That would only add another entry to the
    call stack. Instead, retrieve the entire call stack from within this method.
    Just return nil if we are already reporting an exception, or call stacks
    are disabled. }
  if (FInstance = nil) or (FInstance.FReportingException <> 0) or (FInstance.FMaxCallStackDepth <= 0) then
    Exit(nil);

  MaxCallStackDepth := FInstance.FMaxCallStackDepth;

  { Allocate a PCallStack record large enough to hold just MaxCallStackDepth
    entries }
  GetMem(CallStack, SizeOf(TCallStack) +
    (MaxCallStackDepth - 1) * SizeOf(TStackValues));

  (*We manually walk the stack to create a stack trace. This is possible since
    Delphi creates a stack frame for each routine, by starting each routine with
    a prolog. This prolog is similar to the one used by the iOS ABI (Application
    Binary Interface, see
    https://developer.apple.com/library/content/documentation/Xcode/Conceptual/iPhoneOSABIReference/Articles/ARMv7FunctionCallingConventions.html

    The prolog looks like this:
    * Push all registers that need saving. Always push the R7 and LR registers.
    * Set R7 (frame pointer) to the location in the stack where the previous
      value of R7 was just pushed.

    A minimal prolog (used in many small functions) looks like this:

      push {R7, LR}
      mov  R7, SP

    We are interested in the value of the LR (Link Return) register. This
    register contains the address to return to after the routine finishes. We
    can use this address to look up the symbol (routine name). Using the
    example prolog above, we can get to the LR value and walk the stack like
    this:
    1. Set FramePointer to the value of the R7 register.
    2. At this location in the stack, you will find the previous value of the
       R7 register. Lets call this PreviousFramePointer.
    3. At the next location in the stack, we will find the LR register. Add its
       value to our stack trace so we can use it later to look up the routine
       name at this address.
    4. Set FramePointer to PreviousFramePointer and go back to step 2, until
       FramePointer is 0 or falls outside of the stack.

    Unfortunately, Delphi doesn't follow the iOS ABI exactly, and it may push
    other registers between R7 and LR. For example:

      push {R4, R5, R6, R7, R8, R9, LR}
      add  R7, SP, #12

    Here, it pushed 3 registers (R4-R6) before R7, so in the second line it sets
    R7 to point 12 bytes into the stack (so it still points to the previous R7,
    as required). However, it also pushed registers R8 and R9, before it pushes
    the LR register. This means we cannot assume that the LR register will be
    directly located after the R7 register in the stack. There may be (up to 6)
    registers in between. We don't know which one represents LR, so we just
    store all 7 values after R7, and later try to figure out which one
    represents LR (in the GetCallStack method). *)
  FramePointer := GetFramePointer;

  { The stack grows downwards, so all entries in the call stack leading to this
    call have addresses greater than FramePointer. We don't know what the start
    and end address of the stack is for this thread, but we do know that the
    stack is at most 1MB in size, so we only investigate entries from
    FramePointer to FramePointer + 1MB. }
  MinStack := FramePointer;
  MaxStack := MinStack + MAX_STACK_SIZE;

  { Now we can walk the stack using the algorithm described above. }
  Count := 0;
  while (Count < MaxCallStackDepth) and (FramePointer <> 0)
    and (FramePointer >= MinStack) and (FramePointer < MaxStack) do
  begin
    { The first value at FramePointer contains the previous value of R7.
      Store the 7 values after that. }
    Address := Pointer(FramePointer + SizeOf(UIntPtr));
    Move(Address^, CallStack.Stack[Count], SizeOf(TStackValues));
    Inc(Count);

    { The FramePointer points to the previous value of R7, which contains the
      previous FramePointer. }
    FramePointer := PNativeUInt(FramePointer)^;
  end;

  CallStack.Count := Count;
  Result := CallStack;
end;

class function TCrashCapture.GetCallStack(
  const AStackInfo: Pointer): TCrashStack;
var
  CallStack: PCallStack;
  I, J: Integer;
  FoundLR: Boolean;
begin
  { Convert TCallStack to TCrashStack }
  CallStack := AStackInfo;
  SetLength(Result, CallStack.Count);
  for I := 0 to CallStack.Count - 1 do
  begin
    { For each entry in the call stack, we have up to 7 values now that may
      represent the LR register. Most of the time, it will be the first value.
      We try to find the correct LR value by passing up to all 7 addresses to
      the dladdr API (by calling GetCallStackEntry). If the API call succeeds,
      we assume we found the value of LR. However, this is not fool proof
      because an address value we pass to dladdr may be a valid code address,
      but not the LR value we are looking for.

      Also, the LR value contains the address of the next instruction after the
      call instruction. Delphi usually uses the BL or BLX instruction to call
      another routine. These instructions takes 4 bytes, so LR will be set to 4
      bytes after the BL(X) instruction (the return address). However, we want
      to know at what address the call was made, so we need to subtract 4
      bytes.

      There is one final complication here: the lowest bit of the LR register
      indicates the mode the CPU operates in (ARM or Thumb). We need to clear
      this bit to get to the actual address, by AND'ing it with "not 1". }
    FoundLR := False;
    for J := 0 to Length(CallStack.Stack[I]) - 1 do
    begin
      Result[I].CodeAddress := (CallStack.Stack[I, J] and not 1) - 4;
      if GetCallStackEntry(Result[I]) then
      begin
        { Assume we found LR }
        FoundLR := True;
        Break;
      end;
    end;

    if (not FoundLR) then
      { None of the 7 values were valid.
        Set CodeAddress to 0 to signal we couldn't find LR. }
      Result[I].CodeAddress := 0;
  end;
end;

{$ELSEIF Defined(LINUX)}

(*****************************************************************************)
(*** Linux specific                                                         **)
(*****************************************************************************)

{ __cxa_demangle from libstdc++ (Itanium C++ ABI). Delphi Linux64 RTL emits
  Itanium-mangled symbols compatible with this demangler. If libstdc++.so.6
  is missing on the target, the unit will fail to load -- in practice it is
  present on every Ubuntu/Debian dev/server install. }
const
  libstdcpp = 'libstdc++.so.6';
  libgccs   = 'libgcc_s.so.1';

function cxa_demangle(const mangled_name: MarshaledAString;
  output_buffer: MarshaledAString; length: NativeInt;
  out status: Integer): MarshaledAString; cdecl;
  external libstdcpp name '__cxa_demangle';

{ Use libgcc_s _Unwind_Backtrace (same API as Android64). glibc's backtrace()
  in our experiments emits garbage IPs for deep FMX/RTL stacks (addresses
  land in .dynstr / .hash instead of .text). libgcc walks .eh_frame directly
  and is steadier on Delphi-generated code. }
type
  _PUnwind_Context = Pointer;
  _Unwind_Ptr = UIntPtr;
  _Unwind_Reason_code = Integer;

const
  _URC_NO_REASON      = 0;
  _URC_END_OF_STACK   = 5;

type
  _Unwind_Trace_Fn = function(context: _PUnwind_Context; userdata: Pointer): _Unwind_Reason_code; cdecl;

procedure _Unwind_Backtrace(fn: _Unwind_Trace_Fn; userdata: Pointer); cdecl;
  external libgccs name '_Unwind_Backtrace';
function _Unwind_GetIP(context: _PUnwind_Context): _Unwind_Ptr; cdecl;
  external libgccs name '_Unwind_GetIP';

type
  TCallStack = record
    Count: Integer;
    Stack: array [0..0] of UIntPtr;
  end;
  PCallStack = ^TCallStack;

function CrashLinuxUnwindCallback(AContext: _PUnwind_Context; AUserData: Pointer): _Unwind_Reason_code; cdecl;
var
  CS: PCallStack;
begin
  CS := AUserData;
  if (TCrashCapture.FInstance = nil) or
     (CS.Count >= TCrashCapture.FInstance.FMaxCallStackDepth) then
    Exit(_URC_END_OF_STACK);
  CS.Stack[CS.Count] := UIntPtr(_Unwind_GetIP(AContext));
  Inc(CS.Count);
  Result := _URC_NO_REASON;
end;

class function TCrashCapture.GlobalGetExceptionStackInfo(
  P: PExceptionRecord): Pointer;
var
  CallStack: PCallStack;
begin
  if (FInstance = nil) or (FInstance.FReportingException <> 0) or (FInstance.FMaxCallStackDepth <= 0) then
    Exit(nil);

  GetMem(CallStack, SizeOf(TCallStack) +
    (FInstance.FMaxCallStackDepth - 1) * SizeOf(UIntPtr));
  CallStack.Count := 0;
  _Unwind_Backtrace(CrashLinuxUnwindCallback, CallStack);
  Result := CallStack;
end;

class function TCrashCapture.GetCallStack(
  const AStackInfo: Pointer): TCrashStack;
var
  CallStack: PCallStack;
  I: Integer;
begin
  CallStack := AStackInfo;
  SetLength(Result, CallStack.Count);
  for I := 0 to CallStack.Count - 1 do
  begin
    Result[I].CodeAddress := CallStack.Stack[I];
    GetCallStackEntry(Result[I]);
  end;
end;

{$ELSE}

(*****************************************************************************)
(*** Non iOS/Android/Linux                                                  **)
(*****************************************************************************)

class function TCrashCapture.GlobalGetExceptionStackInfo(
  P: PExceptionRecord): Pointer;
begin
  { Call stacks are only supported on iOS, Android and macOS }
  Result := nil;
end;

class function TCrashCapture.GetCallStack(
  const AStackInfo: Pointer): TCrashStack;
begin
  { Call stacks are only supported on iOS, Android and macOS }
  Result := nil;
end;

class function TCrashCapture.GetCallStackEntry(
  var AEntry: TCrashStackEntry): Boolean;
begin
  { Call stacks are only supported on iOS, Android and macOS }
  Result := False;
end;

{$ENDIF}

{$IF Defined(MACOS) or Defined(ANDROID) or Defined(LINUX)}
class function TCrashCapture.GetCallStackEntry(
  var AEntry: TCrashStackEntry): Boolean;
var
  Info: dl_info;
  Status: Integer;
  Demangled: MarshaledAString;
  {$IF Defined(MACOS64) and not Defined(IOS)}
  MacSymName: String;
  MacSymAddr: UInt64;
  {$ENDIF}
begin
  // dladdr success is enough: even without a nearest exported symbol (typical
  // for internal RTL frames before the first Pascal export) Module/Offset are
  // filled from dli_fname/dli_fbase. An extra dli_saddr<>nil check would lose
  // those fields in such cases.
  Result := dladdr(AEntry.CodeAddress, Info) <> 0;
  if (Result) then
  begin
    AEntry.ModuleAddress := UIntPtr(Info.dli_fbase);
    AEntry.ModuleName := String(Info.dli_fname);

    if Info.dli_saddr <> nil then
    begin
      AEntry.RoutineAddress := UIntPtr(Info.dli_saddr);
      if Info.dli_sname <> nil then
      begin
        Demangled := cxa_demangle(Info.dli_sname, nil, 0, Status);
        if (Demangled = nil) then
          AEntry.RoutineName := String(Info.dli_sname)
        else
        begin
          AEntry.RoutineName := String(Demangled);
          Posix.Stdlib.free(Demangled);
        end;
      end;
    end
    else
    begin
      // No nearest exported symbol - leave routine empty, but Module and
      // Offset (via CodeAddress-ModuleAddress) are already filled.
      AEntry.RoutineAddress := AEntry.ModuleAddress; // offset = code - module
    end;

    {$IF Defined(MACOS64) and not Defined(IOS)}
    // Adopt the Mach-O LC_SYMTAB name + start address over the dladdr guess
    // (see Crash.MacOS.Symbols), so BugID/offsets/RoutineLineNumber all match
    // the shown name.
    if CrashLookupMacOSSymbol(AEntry.CodeAddress, MacSymName, MacSymAddr) then
    begin
      AEntry.RoutineName := MacSymName;
      AEntry.RoutineAddress := UIntPtr(MacSymAddr);
      AEntry.NameTrusted := True;
    end;
    {$ENDIF}

    {$IF Defined(ANDROID)}
    // dladdr sees only the .dynsym export whitelist on Android (the linker
    // localizes Pascal symbols), so RoutineName is empty above. Fill the name +
    // function start from the .gosym side-file (an offline address->name map
    // generated from the unstripped .so's symtab; see Crash.Android.Symbols).
    if (AEntry.RoutineName = '') and (AEntry.ModuleAddress <> 0) then
      AEntry.NameTrusted := CrashAndroidLookupName(AEntry.CodeAddress,
        AEntry.ModuleAddress, AEntry.RoutineName, AEntry.RoutineAddress,
        AEntry.SourceFile);
    {$ENDIF}

    {$IF (Defined(MACOS64) and not Defined(IOS)) or Defined(LINUX)}
    AEntry.LineNumber := GetLineNumber(AEntry.CodeAddress);
    AEntry.RoutineLineNumber := GetLineNumber(AEntry.RoutineAddress);
    {$ELSEIF Defined(ANDROID)}
    // Lines from the .gol side-file (LNG_ELF-generated; see Crash.Android.Symbols).
    AEntry.LineNumber := CrashAndroidLookupLine(AEntry.CodeAddress, AEntry.ModuleAddress);
    AEntry.RoutineLineNumber := CrashAndroidLookupLine(AEntry.RoutineAddress, AEntry.ModuleAddress);
    {$ELSE}
    AEntry.LineNumber := 0;
    AEntry.RoutineLineNumber := 0;
    {$ENDIF}
  end;
end;
{$ENDIF}

{$IF (Defined(MACOS64) and not Defined(IOS)) or Defined(LINUX)}
// Moved here from inside the {$IF Defined(MACOS)} branch above so that it is
// visible to the LINUX branch too -- the class declaration is now active for
// both, and the implementation must live in a block both code paths reach.
class function TCrashCapture.GetLineNumber(const AAddress: UIntPtr): Integer;
begin
  if (FLineNumberInfo = nil) then
    FLineNumberInfo := TLineNumberInfo.Create;
  Result := FLineNumberInfo.Lookup(AAddress);
  // Main-exe reader had no line -> the address may be in a loaded module (.so/
  // .dylib) that ships its own .gol. This only fires for non-main addresses, so
  // the verified main path is untouched.
  if (Result = 0) then
    Result := GetModuleLineNumber(AAddress);
end;

class function TCrashCapture.GetModuleLineNumber(const AAddress: UIntPtr): Integer;
// Per-module fallback. Fully guarded -- this runs while building a crash report,
// so a fault here must never double-fault the process.
var
  Info: dl_info;
  Base: UIntPtr;
  Reader: TLineNumberInfo;
begin
  Result := 0;
  try
    if (dladdr(AAddress, Info) = 0) or (Info.dli_fbase = nil) then Exit;
    Base := UIntPtr(Info.dli_fbase);
    // Skip the main image -- handled by FLineNumberInfo (which already returned 0).
    if (FInstance <> nil) and (Base = FInstance.FModuleAddress) then Exit;

    if (FModuleReaders = nil) then
      FModuleReaders := TDictionary<UIntPtr, TLineNumberInfo>.Create;

    if not FModuleReaders.TryGetValue(Base, Reader) then
    begin
      // First sighting of this module: build its reader (nil = no/mismatched .gol).
      Reader := CreateModuleLineNumberInfo(Info.dli_fbase, String(Info.dli_fname));
      FModuleReaders.Add(Base, Reader);   // cache the miss (nil) too
    end;

    if (Reader <> nil) then
      Result := Reader.Lookup(AAddress);
  except
    Result := 0;
  end;
end;

// Expose the singleton for diagnostic surfacing.
class function TCrashCapture.GetLineNumberInfo: TLineNumberInfo;
begin
  if (FLineNumberInfo = nil) then
    FLineNumberInfo := TLineNumberInfo.Create;
  Result := FLineNumberInfo;
end;
{$ENDIF}

class function TCrashCapture.TryEnterReportGate: Boolean;
begin
  Result := (FInstance <> nil) and
    (TInterlocked.CompareExchange(FInstance.FReportingException, 1, 0) = 0);
end;

class procedure TCrashCapture.LeaveReportGate;
begin
  if FInstance <> nil then
    TInterlocked.Exchange(FInstance.FReportingException, 0);
end;

class function TCrashCapture.SymbolizeAddressList(
  const AAddrs: array of UIntPtr): TCrashStack;
{$IF Defined(MACOS) or Defined(ANDROID) or Defined(LINUX)}
var
  I: Integer;
begin
  Result := nil;
  if (FInstance = nil) or (Length(AAddrs) = 0) then
    Exit;
  SetLength(Result, Length(AAddrs));
  for I := 0 to High(AAddrs) do
  begin
    Result[I].Clear;
    Result[I].CodeAddress := AAddrs[I];
    GetCallStackEntry(Result[I]);
    if Result[I].ModuleAddress = FInstance.FModuleAddress then
      Result[I].RoutineName := CppSymbolToPascal(Result[I].RoutineName);
  end;
end;
{$ELSE}
begin
  Result := nil;
end;
{$ENDIF}

initialization
  // Windows = no-op by design: no singleton -> no RTL hooks (EurekaLog territory).
  {$IF not Defined(MSWINDOWS)}
  TCrashCapture.FInstance := TCrashCapture.InternalCreate;
  {$ENDIF}

finalization
  FreeAndNil(TCrashCapture.FInstance);

end.
