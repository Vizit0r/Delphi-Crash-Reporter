unit Crash.Tests.HandledFault;

// ===========================================================================
//  CrashHandledFault -- a hardware fault whose exception the application
//  handles must not cost the process its fault capture.
//
//  The POSIX fault handler is one-shot: it records the snapshot, puts the RTL
//  handler back so the re-executed instruction becomes a Pascal exception,
//  and used to be re-armed only by a report. A handled AV (try/except, a
//  thread that swallows its exception) never reports, so the process ran
//  without capture for the rest of its life, and the handled fault's snapshot
//  and committed raw record stayed pending -- the next report or the next
//  startup presented them as a crash.
//
//    H0  handlers armed before the test
//    H1  a caught AV is captured by the Crash handler
//    H2  the handler is armed again once that exception is handled
//    H3  the handled fault leaves no pending snapshot and no committed raw
//    H4  a second caught AV is captured too (capture really survived)
//    H5  the same holds for an AV caught inside a worker thread
//    H6  an AV re-raised as a wrapper keeps its snapshot while the wrapper
//        is in flight (it may still reach a report)
//    H7  once the wrapper is handled, the snapshot is retired and capture armed
//
//  Registered only where Crash captures hardware faults. The faulting threads
//  register with Crash coverage: on macOS only that per-thread Mach observer
//  sees Delphi hardware faults (they never reach the POSIX handler there).
//
//  Copyright (c) 2026 Vizit0r. BSD 2-Clause license (see LICENSE.txt).
// ===========================================================================

interface

implementation

{$IFDEF AUTOTESTS}
{$IF (Defined(LINUX) and Defined(CPUX64)) or
     (Defined(MACOS) and not Defined(IOS) and
       (Defined(CPUX64) or Defined(CPUARM64))) or
     (Defined(ANDROID) and Defined(CPUARM64))}

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  Crash.Signals,
  Crash.RawFallback,
  Crash.Reporter,
  Crash.Tests.Progress,
  Crash.Tests.Registry;

const
  TEST_NAME = 'CrashHandledFault';

type
  TCrashHandledFault_AllInOne = class
  public
    class function AutoTest(out OutLines: TArray<string>): Boolean; static;
  end;

  TCaughtFault = record
    Caught: Boolean;
    CapturedDuring: Boolean;
    ArmedAfter: Boolean;
    PendingAfter: Boolean;
    RawCommittedAfter: Boolean;
  end;

  // Takes one AV inside its own try/except, like a host worker that keeps
  // running after a failed item.
  TCaughtFaultThread = class(TThread)
  private
    FResult: TCaughtFault;
  protected
    procedure Execute; override;
  public
    property FaultResult: TCaughtFault read FResult;
  end;

var
  // Globals so the compiler cannot fold the write or the call away.
  GNilTarget: PInteger = nil;
  GFrameCalls: Integer = 0;

procedure CountFrameCall;
begin
  Inc(GFrameCalls);
end;

procedure WriteThroughNil;
// The store sits in a routine that also makes a call, so it runs in its own
// frame. A frameless leaf routine made the AV uncatchable on Android ARM64
// (the process ended with runtime error 217), and a store inline in the
// try block was not caught there on Linux either.
begin
  CountFrameCall;
  GNilTarget^ := 1;
end;

function RawPrimaryCommitted: Boolean;
var
  Key: String;
begin
  Result := CrashRawGetCommittedKey(CRASH_RAW_SLOT_PRIMARY, Key);
end;

function TakeCaughtFault: TCaughtFault;
begin
  Result := Default(TCaughtFault);
  try
    WriteThroughNil;
  except
    on E: EAccessViolation do
    begin
      Result.Caught := True;
      Result.CapturedDuring := CrashHasSignalSnapshot;
    end;
  end;
  Result.ArmedAfter := CrashSignalHandlersArmed;
  Result.PendingAfter := CrashHasSignalSnapshot;
  Result.RawCommittedAfter := RawPrimaryCommitted;
end;

function CoverCurrentThread: Boolean;
// macOS delivers Delphi hardware faults through Mach, past the POSIX handler;
// only the per-thread Mach observer of a registered thread snapshots them.
// True = this call registered the thread and must unregister it.
begin
  Result := not TCrashReporter.GetStatus.CurrentThread.Registered;
  if Result then
    TCrashReporter.RegisterCurrentThread('CrashHandledFault');
end;

procedure TCaughtFaultThread.Execute;
begin
  TCrashReporter.RegisterCurrentThread('CrashHandledFault.Worker');
  try
    FResult := TakeCaughtFault;
  finally
    TCrashReporter.UnregisterCurrentThread;
  end;
end;

type
  EWrappedFault = class(Exception);

function TakeWrappedFault(out ASnapshotInWrapper: Boolean): TCaughtFault;
// The AV object is freed while its wrapper unwinds; the wrapper still carries
// the fault and must keep its snapshot until it is handled itself.
begin
  Result := Default(TCaughtFault);
  ASnapshotInWrapper := False;
  try
    try
      WriteThroughNil;
    except
      on E: EAccessViolation do
      begin
        Result.CapturedDuring := CrashHasSignalSnapshot;
        raise EWrappedFault.Create('wrapped: ' + E.Message);
      end;
    end;
  except
    on E: EWrappedFault do
    begin
      Result.Caught := True;
      ASnapshotInWrapper := CrashHasSignalSnapshot;
    end;
  end;
  Result.ArmedAfter := CrashSignalHandlersArmed;
  Result.PendingAfter := CrashHasSignalSnapshot;
  Result.RawCommittedAfter := RawPrimaryCommitted;
end;

procedure InfoFault(const AProgress: TCrashTestProgress; const ATag: String;
  const AFault: TCaughtFault);
begin
  AProgress.InfoFmt('%s: caught=%s captured=%s armed-after=%s pending-after=%s raw-after=%s',
    [ATag, BoolToStr(AFault.Caught, True), BoolToStr(AFault.CapturedDuring, True),
     BoolToStr(AFault.ArmedAfter, True), BoolToStr(AFault.PendingAfter, True),
     BoolToStr(AFault.RawCommittedAfter, True)]);
end;

class function TCrashHandledFault_AllInOne.AutoTest(
  out OutLines: TArray<string>): Boolean;
var
  Lines: TList<string>;
  P: TCrashTestProgress;
  First, Second, InThread, Wrapped: TCaughtFault;
  SnapshotInWrapper, Covered: Boolean;
  Worker: TCaughtFaultThread;
begin
  Lines := TList<string>.Create;
  P := TCrashTestProgress.Create(Lines);
  try
    if not CrashSignalHandlersInstalled then
    begin
      P.Skip('Crash fault handlers are not installed in this process');
      P.WriteSummary(TEST_NAME);
      Result := P.AllPassed;
      OutLines := Lines.ToArray;
      Exit;
    end;

    // A snapshot left by an earlier fault would hide what this test observes.
    if CrashHasSignalSnapshot then
    begin
      P.Info('H0: discarding a crash snapshot left by an earlier fault');
      CrashDiscardPendingSnapshot;
    end;
    P.Account(CrashSignalHandlersArmed, 'H0: fault handlers are armed');
    if not CrashSignalHandlersArmed then
      CrashInstallSignalHandlers;

    Covered := CoverCurrentThread;
    try
      First := TakeCaughtFault;
      Second := TakeCaughtFault;
      Wrapped := TakeWrappedFault(SnapshotInWrapper);
    finally
      if Covered then
        TCrashReporter.UnregisterCurrentThread;
    end;

    InfoFault(P, 'first', First);
    P.Account(First.Caught and First.CapturedDuring,
      'H1: a caught AV is captured by the Crash handler');
    P.Account(First.ArmedAfter,
      'H2: the handler is armed again once the AV is handled');
    P.Account((not First.PendingAfter) and (not First.RawCommittedAfter),
      'H3: the handled AV leaves no pending snapshot and no committed raw');

    InfoFault(P, 'second', Second);
    P.Account(Second.Caught and Second.CapturedDuring and Second.ArmedAfter and
      (not Second.PendingAfter),
      'H4: a second caught AV is captured and handled the same way');

    Worker := TCaughtFaultThread.Create(True);
    try
      Worker.FreeOnTerminate := False;
      Worker.Start;
      Worker.WaitFor;
      InThread := Worker.FaultResult;
    finally
      Worker.Free;
    end;
    InfoFault(P, 'thread', InThread);
    P.Account(InThread.Caught and InThread.CapturedDuring and
      InThread.ArmedAfter and (not InThread.PendingAfter) and
      (not InThread.RawCommittedAfter),
      'H5: an AV caught inside a worker thread is captured and retired');

    InfoFault(P, 'wrapped', Wrapped);
    P.Account(Wrapped.Caught and Wrapped.CapturedDuring and SnapshotInWrapper,
      'H6: an AV re-raised as a wrapper keeps its snapshot while the wrapper is in flight');
    P.Account(Wrapped.ArmedAfter and (not Wrapped.PendingAfter) and
      (not Wrapped.RawCommittedAfter),
      'H7: the handled wrapper retires the snapshot and leaves capture armed');

    // Leave the process armed and clean whatever the verdict.
    if CrashHasSignalSnapshot then
      CrashDiscardPendingSnapshot;
    if not CrashSignalHandlersArmed then
      CrashInstallSignalHandlers;

    P.WriteSummary(TEST_NAME);
    Result := P.AllPassed;
    OutLines := Lines.ToArray;
  finally
    P.Free;
    Lines.Free;
  end;
end;

initialization
  CrashRegisterTest(
    'CrashHandledFault',
    'Handled hardware fault keeps Crash capture armed and leaves no stale snapshot',
    ['crash', 'signal', 'handled', 'raw'],
    TCrashHandledFault_AllInOne.AutoTest
  );

{$ENDIF}
{$ENDIF}

end.
