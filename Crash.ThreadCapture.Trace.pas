unit Crash.ThreadCapture.Trace;

{ Turns the raw payload the capture signal handler leaves in a slot into a
  call-stack trace: the exact IP, the ARM64 link-register caller when it is
  provably live, then saved return addresses from frame records and from a
  bounded raw stack scan below the first record (and above a broken chain),
  merged by stack position and validated against a TCrashCodeMap. Calm path
  only.

  Copyright (c) 2026 Vizit0r. BSD 2-Clause license (see LICENSE.txt). }

interface

uses
  Crash.ThreadCapture.CallSite;

const
  CRASH_THREAD_CAPTURE_MAX_FRAMES = 64;
  CRASH_THREAD_CAPTURE_RAW_WORDS = 128;

type
  TCrashThreadCaptureStopReason = (
    tcsrNone,
    tcsrEnd,
    tcsrBoundsNone,
    tcsrStackPointerOutside,
    tcsrFramePointerZero,
    tcsrFramePointerOutside,
    tcsrFramePointerMisaligned,
    tcsrFramePointerNonMonotonic,
    tcsrFrameInvalidCode,
    tcsrFrameLimit
  );

  // Where each address of a trace came from, parallel to Addresses.
  TCrashThreadFrameSource = (
    tfsInterrupted, // exact kernel IP
    tfsLink,        // ARM64 LR of a frameless leaf or syscall stub
    tfsFramePointer,
    tfsRaw
  );

  TCrashThreadRawTrace = record
    InterruptedIP: UIntPtr;
    Addresses: TArray<UIntPtr>;
    Sources: TArray<TCrashThreadFrameSource>;
    BoundsAvailable: Boolean;
    FPFrameCount: Integer;
    RawFrameCount: Integer;
    RawDroppedCount: Integer; // valid call sites inside the frame-record chain
    LinkFrameUsed: Boolean;
    StopReason: TCrashThreadCaptureStopReason;
  end;

  // Written by the signal handler: fixed-size, no managed fields.
  TCrashThreadCapturePayload = record
    InterruptedIP: UInt64;
    InterruptedSP: UIntPtr;
    InterruptedFP: UIntPtr;
    InterruptedLR: UIntPtr; // ARM64 only; 0 elsewhere
    Count: Integer;
    Addrs: array [0..CRASH_THREAD_CAPTURE_MAX_FRAMES - 1] of UIntPtr;
    AddrStackPos: array [0..CRASH_THREAD_CAPTURE_MAX_FRAMES - 1] of UIntPtr;
    RawBaseSP: UIntPtr;
    RawWordCount: Integer;
    RawWords: array [0..CRASH_THREAD_CAPTURE_RAW_WORDS - 1] of UIntPtr;
    StopReason: TCrashThreadCaptureStopReason;
  end;
  PCrashThreadCapturePayload = ^TCrashThreadCapturePayload;

  TCrashTraceCandidate = record
    StackPos: UIntPtr;
    Address: UIntPtr;
    IsRaw: Boolean;
  end;
  TCrashTraceCandidates = TArray<TCrashTraceCandidate>;

procedure CrashClearCapturePayload(var APayload: TCrashThreadCapturePayload);
procedure CrashBuildThreadTrace(const APayload: TCrashThreadCapturePayload;
  const ABoundsAvailable: Boolean; const AMap: TCrashCodeMap;
  out ATrace: TCrashThreadRawTrace);

// Merge building blocks: candidates stay sorted by stack position, a frame-
// record candidate replaces a raw one at the same position.
function CrashAddTraceCandidate(var ACandidates: TCrashTraceCandidates;
  const AStackPos, AAddress: UIntPtr; const AIsRaw: Boolean): Boolean;
procedure CrashCompactTraceCandidates(var ACandidates: TCrashTraceCandidates);

function CrashThreadCaptureStopReasonText(
  const AReason: TCrashThreadCaptureStopReason): String;
function CrashThreadCaptureFormatDiagnostics(const AThreadID: UInt64;
  const ATrace: TCrashThreadRawTrace): String;

implementation

uses
  System.SysUtils,
  System.Math;

procedure CrashClearCapturePayload(var APayload: TCrashThreadCapturePayload);
begin
  APayload.InterruptedIP := 0;
  APayload.InterruptedSP := 0;
  APayload.InterruptedFP := 0;
  APayload.InterruptedLR := 0;
  APayload.Count := 0;
  APayload.RawBaseSP := 0;
  APayload.RawWordCount := 0;
  APayload.StopReason := tcsrNone;
end;

function CrashAddTraceCandidate(var ACandidates: TCrashTraceCandidates;
  const AStackPos, AAddress: UIntPtr; const AIsRaw: Boolean): Boolean;
var
  I, InsertAt: Integer;
begin
  Result := False;
  if (AStackPos = 0) or (AAddress = 0) then
    Exit;
  for I := 0 to High(ACandidates) do
    if ACandidates[I].StackPos = AStackPos then
    begin
      if ACandidates[I].IsRaw and (not AIsRaw) then
      begin
        ACandidates[I].Address := AAddress;
        ACandidates[I].IsRaw := False;
      end;
      Exit;
    end;
  InsertAt := Length(ACandidates);
  for I := 0 to High(ACandidates) do
    if AStackPos < ACandidates[I].StackPos then
    begin
      InsertAt := I;
      Break;
    end;
  SetLength(ACandidates, Length(ACandidates) + 1);
  for I := High(ACandidates) downto InsertAt + 1 do
    ACandidates[I] := ACandidates[I - 1];
  ACandidates[InsertAt].StackPos := AStackPos;
  ACandidates[InsertAt].Address := AAddress;
  ACandidates[InsertAt].IsRaw := AIsRaw;
  Result := True;
end;

procedure CrashCompactTraceCandidates(var ACandidates: TCrashTraceCandidates);
var
  I, OutIndex: Integer;
begin
  OutIndex := 0;
  for I := 0 to High(ACandidates) do
  begin
    // The same saved return address may be found by both sources at adjacent
    // stack positions. Preserve real recursion within one source, but remove
    // a cross-source duplicate after the position-based merge.
    if (OutIndex > 0) and
       (ACandidates[I].Address = ACandidates[OutIndex - 1].Address) and
       (ACandidates[I].IsRaw <> ACandidates[OutIndex - 1].IsRaw) then
      Continue;
    ACandidates[OutIndex] := ACandidates[I];
    Inc(OutIndex);
  end;
  SetLength(ACandidates, OutIndex);
end;

function CandidateAt(const ACandidates: TCrashTraceCandidates;
  const AStackPos: UIntPtr): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(ACandidates) do
    if ACandidates[I].StackPos = AStackPos then
      Exit(True);
  Result := False;
end;

procedure CrashBuildThreadTrace(const APayload: TCrashThreadCapturePayload;
  const ABoundsAvailable: Boolean; const AMap: TCrashCodeMap;
  out ATrace: TCrashThreadRawTrace);
var
  Candidates: TCrashTraceCandidates;
  I, N, OutIndex, LeadIndex: Integer;
  Address, StackPos, FirstFPPos, LastFPPos, LinkAddress: UIntPtr;
  HasLink, ChainComplete: Boolean;
begin
  ATrace := Default(TCrashThreadRawTrace);
  ATrace.InterruptedIP := UIntPtr(APayload.InterruptedIP);
  ATrace.BoundsAvailable := ABoundsAvailable;
  ATrace.StopReason := APayload.StopReason;
  Candidates := nil;

  FirstFPPos := 0;
  LastFPPos := 0;
  N := Min(APayload.Count, CRASH_THREAD_CAPTURE_MAX_FRAMES);
  for I := 0 to N - 1 do
  begin
    Address := AMap.NormalizeCodeAddress(APayload.Addrs[I]);
    StackPos := APayload.AddrStackPos[I];
    if not AMap.CallSiteIsValid(Address) then
    begin
      ATrace.StopReason := tcsrFrameInvalidCode;
      Break;
    end;
    if CrashAddTraceCandidate(Candidates, StackPos, Address, False) then
    begin
      if FirstFPPos = 0 then
        FirstFPPos := StackPos;
      LastFPPos := StackPos;
    end;
  end;

  // The chain owns the stack from its first record up: a raw word there is a
  // dead local, except above a chain that broke before its end.
  ChainComplete := ATrace.StopReason in [tcsrEnd, tcsrFrameLimit];
  N := Min(APayload.RawWordCount, CRASH_THREAD_CAPTURE_RAW_WORDS);
  for I := 0 to N - 1 do
  begin
    Address := AMap.NormalizeCodeAddress(APayload.RawWords[I]);
    if not AMap.CallSiteIsValid(Address) then
      Continue;
    StackPos := APayload.RawBaseSP + UIntPtr(I) * SizeOf(Pointer);
    if (FirstFPPos <> 0) and (StackPos >= FirstFPPos) and
       ((StackPos <= LastFPPos) or ChainComplete) then
    begin
      if not CandidateAt(Candidates, StackPos) then
        Inc(ATrace.RawDroppedCount);
      Continue;
    end;
    CrashAddTraceCandidate(Candidates, StackPos, Address, True);
  end;

  CrashCompactTraceCandidates(Candidates);
  HasLink := AMap.LinkFrame(UIntPtr(APayload.InterruptedIP),
    APayload.InterruptedLR, LinkAddress);
  SetLength(ATrace.Addresses, Length(Candidates) +
    Ord(ATrace.InterruptedIP <> 0) + Ord(HasLink));
  SetLength(ATrace.Sources, Length(ATrace.Addresses));
  OutIndex := 0;
  if ATrace.InterruptedIP <> 0 then
  begin
    ATrace.Addresses[0] := ATrace.InterruptedIP;
    ATrace.Sources[0] := tfsInterrupted;
    OutIndex := 1;
  end;
  if HasLink then
  begin
    ATrace.Addresses[OutIndex] := LinkAddress;
    ATrace.Sources[OutIndex] := tfsLink;
    Inc(OutIndex);
  end;
  LeadIndex := OutIndex;
  for I := 0 to High(Candidates) do
  begin
    // The exact kernel IP (and the LR frame) already lead the trace; drop the
    // first stack candidate when it repeats one of them.
    if (OutIndex = LeadIndex) and (LeadIndex > 0) and
       (Candidates[I].Address = ATrace.Addresses[LeadIndex - 1]) then
      Continue;
    ATrace.Addresses[OutIndex] := Candidates[I].Address;
    Inc(OutIndex);
    if Candidates[I].IsRaw then
    begin
      ATrace.Sources[OutIndex - 1] := tfsRaw;
      Inc(ATrace.RawFrameCount);
    end
    else
    begin
      ATrace.Sources[OutIndex - 1] := tfsFramePointer;
      Inc(ATrace.FPFrameCount);
    end;
  end;
  SetLength(ATrace.Addresses, OutIndex);
  SetLength(ATrace.Sources, OutIndex);
  ATrace.LinkFrameUsed := HasLink;
end;

function CrashThreadCaptureStopReasonText(
  const AReason: TCrashThreadCaptureStopReason): String;
begin
  case AReason of
    tcsrEnd: Result := 'end';
    tcsrBoundsNone: Result := 'bounds-none';
    tcsrStackPointerOutside: Result := 'sp-outside';
    tcsrFramePointerZero: Result := 'fp-zero';
    tcsrFramePointerOutside: Result := 'fp-outside';
    tcsrFramePointerMisaligned: Result := 'fp-misaligned';
    tcsrFramePointerNonMonotonic: Result := 'fp-nonmonotonic';
    tcsrFrameInvalidCode: Result := 'fp-invalid-code';
    tcsrFrameLimit: Result := 'frame-limit';
  else
    Result := 'none';
  end;
end;

function CrashThreadCaptureFormatDiagnostics(const AThreadID: UInt64;
  const ATrace: TCrashThreadRawTrace): String;
var
  BoundsText: String;
begin
  if (ATrace.StopReason = tcsrNone) and (not ATrace.BoundsAvailable) and
     (ATrace.FPFrameCount = 0) and (ATrace.RawFrameCount = 0) then
    Exit('');
  if ATrace.BoundsAvailable then
    BoundsText := 'ok'
  else
    BoundsText := 'none';
  Result := 'thread ' + UIntToStr(Cardinal(AThreadID)) +
    ': bounds=' + BoundsText +
    ' fp-frames=' + IntToStr(ATrace.FPFrameCount) +
    ' raw-frames=' + IntToStr(ATrace.RawFrameCount) +
    ' raw-dropped=' + IntToStr(ATrace.RawDroppedCount) +
    ' stop=' + CrashThreadCaptureStopReasonText(ATrace.StopReason);
  if ATrace.LinkFrameUsed then
    Result := Result + ' lr=used';
end;

end.
