unit Crash.Restart;

{ Process restart for the freeze path: the notice file a restarting instance
  leaves for its next boot, the environment loop-guard mark, and the spawn of
  a replacement process.

  The POSIX spawn confirms through a CLOEXEC pipe that execv really started
  the replacement and marks every inherited descriptor close-on-exec in the
  child, so nothing of the frozen instance leaks into the new one.

  Copyright (c) 2026 Vizit0r. BSD 2-Clause license (see LICENSE.txt). }

interface

type
  { What a previous run left behind when RestartOnFreeze replaced a frozen
    instance. Read (and consumed) from the notice file at Init; the host
    surfaces it via TCrashReporter.TakeRestartNotice - a dialog, a journal
    line, a log entry. }
  TCrashRestartNotice = record
    Found: Boolean;         // False = the previous run did not freeze-restart
    RestartedAt: TDateTime; // when the frozen instance replaced itself
    FrozenForMS: Int64;     // no-heartbeat span of that freeze
    BugID: String;          // EL-style id of the freeze report
    ReportFile: String;     // .el left on disk ('' = uploaded-and-removed, or not saved)
    Uploaded: Boolean;      // True = the report reached the endpoint before the restart
  end;

{ Serialize / parse a freeze-restart notice file - the on-disk contract between
  the frozen instance and its next boot. Public so hosts and tests can inspect
  the file without an actual process restart. Read returns False when the file
  is missing or does not carry the notice signature; neither routine touches
  reporter state, and neither deletes the file. }
procedure CrashWriteRestartNoticeFile(const APath: String;
  const ANotice: TCrashRestartNotice);
function CrashReadRestartNoticeFile(const APath: String;
  out ANotice: TCrashRestartNotice): Boolean;

{ Freeze-restart loop-guard mark in the process ENVIRONMENT - the disk-free
  twin of the notice file. The guard must survive a report dir that cannot be
  written (read-only, full disk, missing), so it rides process inheritance:
  CreateProcess/execv hand the environment to the replacement unconditionally.
  Set returns True only when the mark is verifiably in place (the value is
  read back after the API call) - a False from BOTH channels means the
  restart loop guard cannot be armed at all, and the caller must not restart.
  Consume = read + remove, so later host-spawned children never inherit a
  stale mark. Exposed for tests. }
function CrashSetFreezeRestartEnvMark: Boolean;
function CrashConsumeFreezeRestartEnvMark: Boolean;

{ True where a process may replace itself (desktop targets; not the iOS /
  Android sandbox). }
function CrashRestartPlatformSupported: Boolean;

{ Spawn a copy of this process with the same command line, then quit.
  ASpawnAllowed=False quits without spawning. AHardExit=True quits via
  _exit/TerminateProcess, skipping unit finalization. Returns ONLY on spawn
  failure (False); on success the call never returns. }
function CrashRestartProcess(const AHardExit, ASpawnAllowed: Boolean): Boolean;

{$IF not Defined(MSWINDOWS)}
{ Spawn AExePath with AArgv (argv[0] included) detached, confirming through a
  CLOEXEC pipe that execv actually started it (a successful exec closes the
  write end - EOF; a failure writes a marker byte first, retried across
  EINTR). Fail-closed at every stage: no confirmation channel (pipe/fcntl
  failure, e.g. fd exhaustion) = no fork at all; a broken read on the channel
  = the child is killed and False (exec state unknown - the caller must keep
  living); an EOF whose child is already a zombie with one of our failure
  exit codes (126 sweep / 127 execv) = False, so a lost marker byte cannot
  masquerade as success. The child marks EVERY inherited fd >= 3
  close-on-exec between fork and execv (close_range, then a raw /proc/self/fd
  walk, then a bounded fcntl sweep - see the fallbacks below), so the
  replacement starts with only stdio - none of the frozen instance's sockets,
  locks or pipes leak into it; a sweep that cannot vouch for the whole table
  aborts the spawn (126) instead of exec'ing with an unknown fd set. False =
  nothing survives the call; the CALLER is alive either way, and a failed
  child is reaped. The building block of CrashRestartProcess, exposed so
  spawn-failure handling stays testable. }
function CrashSpawnDetachedVerified(const AExePath: String;
  const AArgv: TArray<String>): Boolean;

{ Fallback levels of the child fd sweep, exposed for tests (safe to run in a
  live process: CLOEXEC only affects future execs). ViaProcFS walks the
  ACTUALLY open descriptors through /proc/self/fd with raw syscalls (no
  range bound); BySweep marks fd 3..AFdLimit-1 via fcntl. Both retry EINTR,
  ignore EBADF and return False when any live descriptor could not be
  marked. }
{$IF Defined(LINUX)}
function CrashMarkFDsCloseOnExecViaProcFS: Boolean;
{$ENDIF}
function CrashMarkFDsCloseOnExecBySweep(const AFdLimit: Integer): Boolean;
{$IF Defined(AUTOTESTS)}
{ Exact finite RLIMIT_NOFILE -> bounded-sweep limit. -1 means the limit cannot
  be represented safely, so an unbounded primitive must succeed or spawn must
  fail closed. Exposed only to regression tests. }
function CrashFdSweepLimitFromRLimit(const ARlimCur: UInt64): Integer;
{$ENDIF}
{$ENDIF}

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.DateUtils
  {$IF Defined(MSWINDOWS)}
  , Winapi.Windows
  {$ELSE}
  , Posix.Unistd, // fork(), execv(), pipe(), _exit()
  Posix.Stdlib,   // setenv/unsetenv
  Posix.SysTypes,
  Posix.Base,
  Posix.Fcntl,    // FD_CLOEXEC on the exec-confirmation pipe + the child fd sweep
  Posix.SysWait,  // waitpid() for the failed-exec child
  Posix.Signal,   // kill(SIGKILL) when the confirmation channel breaks
  Posix.Errno
  {$ENDIF};

const
  { First line of a freeze-restart notice file; the version tag lets a future
    format change fail closed (an unknown notice reads as not-found). }
  CRASH_RESTART_NOTICE_SIGNATURE = 'CrashRestartNotice v1';
  CRASH_FREEZE_RESTART_ENV = 'CRASH_FREEZE_RESTARTED';

procedure CrashWriteRestartNoticeFile(const APath: String;
  const ANotice: TCrashRestartNotice);
var
  Text: String;
const
  BoolChar: array [Boolean] of Char = ('0', '1');
begin
  // key=value lines; the timestamp is ISO 8601 so the parse never depends on
  // the locale of either run. UTF-8: ReportFile may carry non-ASCII paths.
  Text :=
    CRASH_RESTART_NOTICE_SIGNATURE + #13#10 +
    'restarted_at=' + DateToISO8601(ANotice.RestartedAt, False) + #13#10 +
    'frozen_ms=' + IntToStr(ANotice.FrozenForMS) + #13#10 +
    'bugid=' + ANotice.BugID + #13#10 +
    'report_file=' + ANotice.ReportFile + #13#10 +
    'uploaded=' + BoolChar[ANotice.Uploaded] + #13#10;
  ForceDirectories(ExtractFilePath(APath));
  TFile.WriteAllText(APath, Text, TEncoding.UTF8);
end;

function CrashReadRestartNoticeFile(const APath: String;
  out ANotice: TCrashRestartNotice): Boolean;
var
  Lines: TArray<String>;
  L, Key, Val: String;
  EqPos: Integer;
  DT: TDateTime;
  MS: Int64;
begin
  ANotice := Default(TCrashRestartNotice);
  Result := False;
  if (APath = '') or (not TFile.Exists(APath)) then
    Exit;
  try
    Lines := TFile.ReadAllLines(APath, TEncoding.UTF8);
  except
    Exit; // unreadable = no notice
  end;
  if (Length(Lines) = 0) or (Lines[0].Trim <> CRASH_RESTART_NOTICE_SIGNATURE) then
    Exit;
  // Fields are best-effort: a missing/garbled value keeps its default, the
  // notice itself (signature matched) still counts.
  for L in Lines do
  begin
    EqPos := Pos('=', L);
    if EqPos <= 1 then
      Continue;
    Key := Copy(L, 1, EqPos - 1);
    Val := Copy(L, EqPos + 1, MaxInt);
    if Key = 'restarted_at' then
    begin
      if TryISO8601ToDate(Val, DT, False) then
        ANotice.RestartedAt := DT;
    end
    else if Key = 'frozen_ms' then
    begin
      if TryStrToInt64(Val, MS) then
        ANotice.FrozenForMS := MS;
    end
    else if Key = 'bugid' then
      ANotice.BugID := Val
    else if Key = 'report_file' then
      ANotice.ReportFile := Val
    else if Key = 'uploaded' then
      ANotice.Uploaded := Val = '1';
  end;
  ANotice.Found := True;
  Result := True;
end;

function CrashSetFreezeRestartEnvMark: Boolean;
begin
  {$IF Defined(MSWINDOWS)}
  SetEnvironmentVariable(CRASH_FREEZE_RESTART_ENV, '1');
  {$ELSE}
  setenv(CRASH_FREEZE_RESTART_ENV, '1', 1); // can fail (ENOMEM)
  {$ENDIF}
  // Read-back instead of trusting the API result: True = the mark is
  // verifiably in place for inheritance.
  Result := GetEnvironmentVariable(CRASH_FREEZE_RESTART_ENV) = '1';
end;

function CrashConsumeFreezeRestartEnvMark: Boolean;
begin
  Result := GetEnvironmentVariable(CRASH_FREEZE_RESTART_ENV) = '1';
  if not Result then
    Exit;
  {$IF Defined(MSWINDOWS)}
  SetEnvironmentVariable(CRASH_FREEZE_RESTART_ENV, nil);
  {$ELSE}
  unsetenv(CRASH_FREEZE_RESTART_ENV);
  {$ENDIF}
end;

function CrashRestartPlatformSupported: Boolean;
begin
  {$IF Defined(MSWINDOWS) or Defined(LINUX) or (Defined(MACOS) and not Defined(IOS))}
  Result := True;
  {$ELSE}
  Result := False; // iOS/Android sandbox - not allowed
  {$ENDIF}
end;

{$IF not Defined(MSWINDOWS)}
// POSIX fork/execv
function fork: pid_t; cdecl; external libc name _PU + 'fork';
function execv(path: MarshaledAString; argv: PMarshaledAString): Integer; cdecl;
  external libc name _PU + 'execv';

{$IF Defined(LINUX)}
// close_range(2) via the raw syscall: the libc wrapper only exists in
// glibc 2.34+, and an unresolved import would stop the binary from LOADING on
// older distros - syscall() resolves everywhere, an old kernel just returns
// ENOSYS and the caller falls back to the fcntl loop.
function syscall(ANumber: IntPtr): IntPtr; cdecl; varargs;
  external libc name _PU + 'syscall';

const
  SYS_close_range      = 436; // x86-64
  CLOSE_RANGE_CLOEXEC  = 4;   // mark instead of close
{$ENDIF}

type
  // struct rlimit; rlim_t is 64-bit on every target built here. The RTL has
  // no Posix.SysResource unit, hence the local declaration.
  TCrashRLimit = record
    rlim_cur: UInt64;
    rlim_max: UInt64;
  end;

const
  CRASH_RLIMIT_NOFILE = {$IF Defined(MACOS)} 8 {$ELSE} 7 {$ENDIF};

function getrlimit(resource: Integer; var rlp: TCrashRLimit): Integer; cdecl;
  external libc name _PU + 'getrlimit';

function CrashSetCloseOnExec(const AFd: Integer): Boolean;
// One sweep step. EINTR = retry; EBADF = a hole in the table, fine; any
// other error on a live descriptor means the sweep cannot vouch for it.
var
  RC: Integer;
begin
  repeat
    RC := fcntl(AFd, F_SETFD, FD_CLOEXEC);
  until (RC = 0) or (errno <> EINTR);
  Result := (RC = 0) or (errno = EBADF);
end;

function CrashMarkFDsCloseOnExecBySweep(const AFdLimit: Integer): Boolean;
var
  Fd: Integer;
begin
  Result := True;
  for Fd := 3 to AFdLimit - 1 do
    if not CrashSetCloseOnExec(Fd) then
      Result := False; // keep sweeping - mark as much as possible - but report
end;

function CrashFdSweepLimitFromRLimit(const ARlimCur: UInt64): Integer;
begin
  if ARlimCur <= UInt64(High(Integer)) then
    Result := Integer(ARlimCur)
  else
    Result := -1;
end;

{$IF Defined(LINUX)}
const
  SYS_getdents64     = 217;    // x86-64
  CRASH_O_DIRECTORY  = $10000; // Linux x86-64 O_DIRECTORY
  CRASH_O_CLOEXEC    = $80000; // Linux O_CLOEXEC

function CrashMarkFDsCloseOnExecViaProcFS: Boolean;
// Walk the ACTUALLY open descriptors via /proc/self/fd - raw syscalls only
// (open/getdents64/close; libc readdir allocates and is not
// async-signal-safe). No range bound: any fd number is reached.
var
  DirFd: Integer;
  Buf: array [0..1023] of Byte;
  NRead, Off: IntPtr;
  Name: PAnsiChar;
  Fd: Integer;
  Ok: Boolean;

  function ParseFdName(P: PAnsiChar; out AFd: Integer): Boolean;
  var
    V: Integer;
  begin
    Result := False;
    if P^ = #0 then
      Exit;
    V := 0;
    while P^ <> #0 do
    begin
      if (P^ < '0') or (P^ > '9') then
        Exit; // '.', '..'
      V := V * 10 + (Ord(P^) - Ord('0'));
      Inc(P);
    end;
    AFd := V;
    Result := True;
  end;

begin
  Result := False;
  repeat
    DirFd := Posix.Fcntl.open('/proc/self/fd',
      O_RDONLY or CRASH_O_DIRECTORY or CRASH_O_CLOEXEC);
  until (DirFd >= 0) or (errno <> EINTR);
  if DirFd < 0 then
    Exit;
  Ok := True;
  repeat
    NRead := syscall(SYS_getdents64, IntPtr(DirFd), IntPtr(@Buf[0]),
      IntPtr(SizeOf(Buf)));
    if NRead < 0 then
    begin
      if errno = EINTR then
        Continue;
      Ok := False;
      Break;
    end;
    Off := 0;
    while Off < NRead do
    begin
      // struct linux_dirent64: u64 d_ino; s64 d_off; u16 d_reclen;
      // u8 d_type; char d_name[]
      Name := PAnsiChar(@Buf[Off + 19]);
      if ParseFdName(Name, Fd) and (Fd >= 3) and (Fd <> DirFd) then
        if not CrashSetCloseOnExec(Fd) then
          Ok := False;
      Inc(Off, PWord(@Buf[Off + 16])^);
    end;
  until NRead = 0;
  __close(DirFd);
  Result := Ok;
end;
{$ENDIF}

function CrashChildMarkFDsCloseOnExec(const AFdLimit: Integer): Boolean;
// Runs IN THE CHILD between fork and execv: mark every fd >= 3 close-on-exec
// so the exec'd replacement starts with only stdio (see the interface
// comment). Everything here is async-signal-safe; the sweep limit is read by
// the PARENT before fork and passed in. The confirmation pipe's write end is
// caught too - it is already CLOEXEC, and a failed execv can still write
// into it (CLOEXEC only acts on a successful exec). False = the fd table
// cannot be vouched for; the caller must NOT exec.
begin
  {$IF Defined(LINUX)}
  if syscall(SYS_close_range, IntPtr(3), IntPtr(High(Cardinal)),
       IntPtr(CLOSE_RANGE_CLOEXEC)) = 0 then
    Exit(True);
  if CrashMarkFDsCloseOnExecViaProcFS then
    Exit(True);
  {$ENDIF}
  if AFdLimit < 0 then
    Exit(False); // no exact bound: never run a knowingly incomplete sweep
  Result := CrashMarkFDsCloseOnExecBySweep(AFdLimit);
end;

function CrashSpawnDetachedVerified(const AExePath: String;
  const AArgv: TArray<String>): Boolean;
var
  ChildPid: pid_t;
  ArgBytes: array of TBytes;
  Argv: array of MarshaledAString;
  ExePath: TBytes;
  I, FdLimit, WStatus: Integer;
  RLim: TCrashRLimit;
  Fds: TPipeDescriptors;
  Confirm: Byte;
  N: ssize_t;
begin
  Result := False;
  // Marshal argv BEFORE fork: in the child of a multithreaded process only
  // async-signal-safe calls are allowed until execv - a heap allocation there
  // can deadlock on a lock another thread held at fork time.
  ExePath := TEncoding.UTF8.GetBytes(AExePath);
  SetLength(ExePath, Length(ExePath) + 1); // null-terminate
  SetLength(ArgBytes, Length(AArgv));
  SetLength(Argv, Length(AArgv) + 1); // +1 for the NULL terminator
  for I := 0 to High(AArgv) do
  begin
    ArgBytes[I] := TEncoding.UTF8.GetBytes(AArgv[I]);
    SetLength(ArgBytes[I], Length(ArgBytes[I]) + 1); // null-terminate
    Argv[I] := MarshaledAString(@ArgBytes[I][0]);
  end;
  Argv[Length(AArgv)] := nil;

  // Exact bound for the LAST-RESORT bounded sweep (Linux normally takes
  // close_range or the /proc walk - neither needs one; macOS has no unbounded
  // primitive). A finite representable rlim_cur is the honest limit: no fd at
  // or above it can exist. A failed getrlimit, RLIM_INFINITY or a value beyond
  // Integer cannot be swept completely by this loop, so keep the -1 sentinel:
  // Linux may still succeed through an unbounded level; otherwise the child
  // aborts before execv. Read in the parent because getrlimit is not on the
  // async-signal-safe list.
  FdLimit := -1;
  if getrlimit(CRASH_RLIMIT_NOFILE, RLim) = 0 then
    FdLimit := CrashFdSweepLimitFromRLimit(RLim.rlim_cur);

  // Exec-confirmation channel (see the interface comment). Fail-closed: a
  // spawn we cannot confirm is a spawn we do not attempt - the caller keeps
  // the process alive instead of exiting on a guess.
  if pipe(Fds) <> 0 then
    Exit;
  if fcntl(Fds.WriteDes, F_SETFD, FD_CLOEXEC) <> 0 then
  begin
    __close(Fds.ReadDes);
    __close(Fds.WriteDes);
    Exit;
  end;

  ChildPid := fork;
  if ChildPid = 0 then
  begin
    // Child: detach from the parent's fd table before exec - only stdio and
    // the (CLOEXEC) confirmation pipe may cross into the replacement. A table
    // the sweep cannot vouch for aborts the spawn: marker + _exit(126).
    if not CrashChildMarkFDsCloseOnExec(FdLimit) then
    begin
      Confirm := 2;
      repeat
        N := __write(Fds.WriteDes, @Confirm, 1);
      until (N = 1) or ((N < 0) and (errno <> EINTR));
      Posix.Unistd._exit(126);
    end;
    // If execv returns, it failed - report through the pipe (the write
    // retried across EINTR: a lost marker byte would read as success), then
    // _exit, not Halt: unit finalization is not fork-safe either. (write and
    // _exit are async-signal-safe.)
    execv(MarshaledAString(@ExePath[0]), @Argv[0]);
    Confirm := 1;
    repeat
      N := __write(Fds.WriteDes, @Confirm, 1);
    until (N = 1) or ((N < 0) and (errno <> EINTR));
    Posix.Unistd._exit(127);
  end;
  if ChildPid = -1 then
  begin
    // fork failed - nothing was spawned.
    __close(Fds.ReadDes);
    __close(Fds.WriteDes);
    Exit;
  end;
  __close(Fds.WriteDes);
  repeat
    N := __read(Fds.ReadDes, @Confirm, 1);
  until (N >= 0) or (errno <> EINTR);
  __close(Fds.ReadDes);
  if N < 0 then
  begin
    // The channel broke: exec state UNKNOWN. Fail-closed - this process must
    // keep living, so make the outcome deterministic by taking the child
    // down (it is either a not-yet-exec'd twin or a milliseconds-old
    // replacement that has not touched anything durable yet).
    kill(ChildPid, SIGKILL);
    waitpid(ChildPid, nil, 0);
    Exit;
  end;
  if N > 0 then
  begin
    // Failure marker delivered (sweep=2 / execv=1); reap the child.
    waitpid(ChildPid, nil, 0);
    Exit;
  end;
  // EOF: normally a successful exec closed the CLOEXEC write end. Guard the
  // lost-marker corner - a child that died without managing to deliver its
  // byte also produces an EOF, but by then it is a zombie carrying one of
  // OUR failure exit codes; a live (or differently-exited) child is a real
  // replacement.
  if (waitpid(ChildPid, @WStatus, WNOHANG) = ChildPid) and
     WIFEXITED(WStatus) and
     ((WEXITSTATUS(WStatus) = 126) or (WEXITSTATUS(WStatus) = 127)) then
    Exit;
  Result := True;
end;
{$ENDIF}

function CrashRestartProcess(const AHardExit, ASpawnAllowed: Boolean): Boolean;
{$IF Defined(MSWINDOWS)}
var
  SI: TStartupInfo;
  PI: TProcessInformation;
  CmdLine: String;
{$ELSEIF Defined(LINUX) or Defined(MACOS)}
var
  Args: TArray<String>;
  I: Integer;
{$ENDIF}

  procedure QuitSelf;
  // AHardExit skips unit finalization (see the declaration comment); the
  // fallthrough Halt only ever runs in the soft mode.
  begin
    if AHardExit then
    {$IF Defined(MSWINDOWS)}
      TerminateProcess(GetCurrentProcess, 0);
    {$ELSE}
      Posix.Unistd._exit(0);
    {$ENDIF}
    Halt(0);
  end;

begin
  Result := False;
  if not ASpawnAllowed then
  begin
    // Restart is disallowed here (not a spawn failure): quit as requested.
    QuitSelf;
    Exit;
  end;

  {$IF Defined(MSWINDOWS)}
  // GetCommandLine, not a ParamStr rebuild: the original quoting survives.
  CmdLine := GetCommandLine;
  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  if not CreateProcess(nil, PChar(CmdLine), nil, nil, False, 0, nil, nil, SI, PI) then
    Exit; // spawn failed - the caller keeps this process alive
  CloseHandle(PI.hProcess);
  CloseHandle(PI.hThread);
  QuitSelf;
  {$ELSEIF Defined(LINUX) or Defined(MACOS)}
  SetLength(Args, ParamCount + 1);
  for I := 0 to ParamCount do
    Args[I] := ParamStr(I);
  if not CrashSpawnDetachedVerified(ParamStr(0), Args) then
    Exit; // spawn failed - the caller keeps this process alive
  QuitSelf;
  {$ELSE}
  QuitSelf;
  {$ENDIF}
end;

end.
