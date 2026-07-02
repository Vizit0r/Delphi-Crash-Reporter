# Crash Reporter

A standalone crash/exception reporter for Delphi cross-platform targets (Linux,
macOS, Android, iOS), built on the Delphi RTL. It writes reports in EurekaLog's
**`.el` file format** — no EurekaLog license required — so they open natively in
the EurekaLog Viewer, with call stacks, CPU registers, modules and source line
numbers. The compatibility is with the report *format* and Viewer; the library
does not use EurekaLog itself.

On **Windows** it is a no-op by design (use EurekaLog there); the units still
compile so the same code base builds on every platform.

**Not tied to FMX (or any UI framework).** The core is framework-agnostic: it
depends only on the Delphi RTL (`System.*`, `Posix.*`), so it links into FMX
apps, VCL apps and headless console/daemon targets alike. The *only* unit that
references FMX is the optional `Crash.Dialog.FMX` (the GUI report dialog) — leave
it out and non-fatal exceptions fall back to a stderr message. `Demo/CrashDemo`
is precisely this case: a pure console program that links the entire reporter
with zero FMX units.

Derived from [grijjy/JustAddCode](https://github.com/grijjy/JustAddCode)
(ErrorReporting), BSD 2-Clause — see `LICENSE.txt`.

## What you get

| Capability | Linux | macOS | Android | iOS | Windows |
|---|---|---|---|---|---|
| Unhandled-exception trapping | ✅ | ✅ | ✅ | ✅ | ❌ (EurekaLog) |
| Call stack (Pascal names) | ✅ | ✅ (LC_SYMTAB) | ✅ (`.gosym`) | ❓ untested | — |
| Source line numbers (`.gol`) | ✅ | ✅ | ✅ | — | — |
| CPU registers on hardware faults | ✅ | ✅ (signal ucontext / Mach) | ✅ (ARM64) | — | — |
| Modules section | ✅ | ✅ | ✅ | — | — |
| EL-compatible `.el` output | ✅ | ✅ | ✅ | ✅ | — |
| Save / upload / dialog / restart | ✅ | ✅ | ✅ (no restart) | ✅ (no restart) | — |

**iOS is not runtime-tested.** The units compile for iOS and its paths mirror the macOS
Mach-O ones (so the call stack *should* resolve via `LC_SYMTAB`), but nothing in the iOS
column has been verified on device — treat those marks as *expected, not confirmed*. The
Pascal-name call stack is the least certain: iOS strips/signs binaries differently, which
can leave `LC_SYMTAB` without the local symbols the resolver needs.

On **Android** the deployed `.so` is stripped and the linker localizes Pascal symbols,
so names + lines come from two side-files shipped with the app — `.gosym` (names) and
`.gol` (lines); see their sections below. There is also no usable modal report dialog on
mobile (FMX `ShowModal` is async-only), so wire `OnShowDialog := nil`: non-fatal
exceptions are saved + uploaded headlessly, and an unhandled main-thread Pascal exception
is caught by FMX's `HandleException` (the app survives), not the `ExceptProc` fatal path.

## Quick start

```pascal
uses
  Crash.Reporter,
  Crash.CallStack,   // TCrashCapture.ExceptionHandler
  Crash.Dialog.FMX;  // optional, FMX GUI only

var
  Cfg: TCrashConfig;
begin
  Cfg := DefaultCrashConfig;
  Cfg.AppName         := 'MyApp';
  Cfg.AppVersion      := '1.2.3.4';        // host-supplied
  Cfg.CompilationTime := '28.05.2026 14:00:00';
  Cfg.UploadEnabled   := True;
  Cfg.UploadUrl       := 'https://example.com/upload.php';
  Cfg.OnShowDialog    := ShowCrashDialog;  // GUI; omit for headless
  TCrashReporter.Init(Cfg);

  // FMX GUI: also catch main-thread exceptions before the RTL does.
  Application.OnException := TCrashCapture.ExceptionHandler;

  // Boot recovery: surface reports left by previous runs.
  for var R in TCrashReporter.TakePending do
    Writeln(ErrOutput, R);
end;
```

`Init` is idempotent and should run once at startup, before forms are created.

## Configuration (`TCrashConfig`)

Start from `DefaultCrashConfig` and override what you need. Everything that can
vary is a field — there are no compile-time constants baked into the library.

| Field | Default | Meaning |
|---|---|---|
| `AppName` | exe name | Shown in the report header |
| `AppVersion` | `''` | Host-supplied version string |
| `CompilationTime` | `''` | "1.5 Compilation Date" field |
| `SaveToFile` | `True` | Persist the `.el` next to the exe |
| `FileNamePrefix` | `<exe>_<PLATFORM>_` | `<prefix><timestamp>.el`; also the boot-scan pattern |
| `UploadEnabled` | `False` | Upload reports to `UploadUrl` |
| `UploadUrl` | `''` | Full multipart-POST endpoint (host builds it) |
| `UploadFieldName` | `el_upload_file_0` | Multipart file field name |
| `UploadPendingOnStartup` | `False` | Re-upload leftover reports on `Init` |
| `AllowRestart` | `True` | Allow the Restart action (platform-gated) |
| `OnShowDialog` | `nil` | GUI dialog provider; `nil` → brief stderr |
| `OnCollectContext` | `nil` | Optional extra text appended to the report |
| `OnFilterReport` | `nil` | Last-step veto: `function(const AReport): Boolean`; return `False` to drop the report |
| `DisabledSections` | `[]` (full report) | Report sections to omit entirely (header + body); Application, Exception and Call Stack are mandatory and not omittable |
| `ReportDir` | `''` (platform default) | Directory for `.el` files (write + boot-recovery scan). Empty → next to the `.app` on macOS (not inside the bundle), the exe's own dir on Linux/Windows |

Set the env var `CRASH_NO_UPLOAD=1` to skip uploads and keep the file on disk
(useful for local testing).

### Vetoing a report (`OnFilterReport`)

`OnFilterReport` is the last-step gate: it receives the fully-built `TCrashReport`
(message, exception class name, call stack, source) just before the report is
persisted or surfaced, and returning `False` drops it. Use it for host-specific
policy — suppressing a known-benign exception, dropping reports during a planned
shutdown, rate-limiting, and so on.

```pascal
Cfg.OnFilterReport :=
  function(const AReport: TCrashReport): Boolean
  begin
    // keep everything except one known-benign app exception
    Result := AReport.ExceptionClassName <> 'EMyExpectedAbort';
  end;
```

It runs in the crash path, so keep it cheap and robust. An exception raised by the
filter is swallowed and the report is **kept** — a faulty filter must never silence
a real crash. `EAbort` and a clean Ctrl-C (`EControlC`) are dropped by the library
itself, before the filter is consulted, so you don't need to handle those.

### Trimming report sections

`DisabledSections` omits whole sections from the `.el` — both the section header
and its body disappear. Default `[]` emits the full report. The optional sections
are `crsUser`, `crsComputer`, `crsOperatingSystem`, `crsStepsToReproduce`,
`crsModules`, `crsRegisters`, `crsSignalInfo`. **Application, Exception and Call
Stack are always emitted** — Application/Exception carry the core crash info, and
the EurekaLog Viewer needs the Call Stack table as the report's structural anchor;
they are deliberately not part of `TCrashReportSection`.

```pascal
Cfg.DisabledSections := [crsModules, crsRegisters];     // drop just these two
Cfg.DisabledSections := AllOptionalCrashReportSections; // mandatory three only
```

`TCrashReportSection`, `TCrashReportSections` and `AllOptionalCrashReportSections`
are declared in `Crash.CallStack` (which the quick-start already uses).

## Units

Core (framework-agnostic):

- `Crash.Reporter` — public façade: `TCrashConfig`, `DefaultCrashConfig`, `TCrashReporter`.
- `Crash.CallStack` — RTL exception hooks + stack capture; `TCrashCapture`, `TCrashReport`, `TCrashReportSection`.
- `Crash.Signals` — POSIX `sigaction` CPU-register snapshot for hardware faults.
- `Crash.Modules` — loaded-module enumeration.
- `Crash.LineNumbers` — `.gol` line-number reader.
- `Crash.Android.Symbols` — `.gosym` reader: address → Pascal name + source file on Android.
- `Crash.ELFormat` — EurekaLog `.el` text writer.
- `Crash.MacOS.Api` / `Crash.MacOS.Symbols` — Mach-O structs + LC_SYMTAB symbolication.
- `Crash.Demangle` — C++ (Itanium) → Pascal symbol translation.

Optional UI:

- `Crash.Dialog.FMX` — modal FMX report dialog. `ShowCrashDialog` wires into
  `TCrashConfig.OnShowDialog`; set `CrashDialogTitle` to change the caption.

## Source line numbers (`.gol`)

Line numbers come from a `.gol` file generated at build time from the binary's
debug info and deployed alongside the app (next to the executable on Linux/macOS; as an
APK asset on Android — the mobile deploy is shared with `.gosym`, see *Function names*).

- **Linux**: `Tools/LineNumberGenerator/LNG_ELF` reads DWARF from the ELF.
- **macOS**: `Tools/LineNumberGenerator/LNG` reads DWARF from the `.dSYM`.
- **Android**: the same `LNG_ELF` reads DWARF from the **unstripped** `.so`. Link with
  `--build-id=sha1` so the reader can match the `.gol` to the stripped, on-device `.so`
  (which keeps the build-id note but drops DWARF). Lines resolve identically to Linux;
  what differs is only where the file is found at runtime (the app documents dir, not
  next to the binary).

All emit the same `.gol` byte format that `Crash.LineNumbers` reads at runtime.

### Build requirements

- **Linux64**: `DCC_DebugInformation=2` (keep DWARF for the generator) and the
  linker option `--export-dynamic` (so `dladdr` sees Pascal symbols). Without
  the latter the call stack falls back to module-offset proxies.
- **macOS** (Release): Local symbols = True and Output debug information = True,
  otherwise the linker strips the symbol table and names resolve poorly.
- **Android**: `DCC_DebugInformation=2` here too, so `LNG_ELF` can read the DWARF, plus
  `--build-id=sha1` so the reader can match the `.gol` to the stripped on-device `.so`.
  (Unlike Linux, `--export-dynamic` is pointless on Android — the version script localizes
  the symbols anyway; on-device *names* come from the `.gosym`, which has its own
  build requirements.)
- After changing `DCC_DebugInformation`, do one full rebuild (incremental Make
  reuses `.dcu` cache and the `.gol` ends up near-empty).

### Building the generators

`LNG` (macOS) and `LNG_ELF` (Linux) are **Win32 console utilities that run on the
build host**, not on the target. Build them from
`Tools/LineNumberGenerator/LNG.dproj` and `LNG_ELF.dproj` (MSBuild / `dcc32`); the
prebuilt binaries live in `Tools/Bin/`.

### Universal (fat) `.gol` for macOS

A macOS *universal* binary keeps a distinct `LC_UUID` and address space per arch
slice (x86_64, arm64). The runtime reader matches a `.gol` to the running image by
UUID, so a single single-arch `.gol` only ever covers one slice — on the other
arch it is rejected outright (`ExecutableIDMismatch`) and you get **no** line
numbers, not approximate ones.

The fix is a **universal container** (`'GOLF'` signature) that bundles one per-arch
`.gol` and lets the reader pick the slice whose embedded UUID matches the running
image — automatically selecting the right architecture. One file, exact lines on
both arches. The container format is documented at the top of
`Crash.LineNumbers.pas`; the reader detects it by sniffing the first 4 bytes, so a
legacy single-arch `.gol` keeps working unchanged (and an old reader rejects a
container cleanly instead of misreading it).

Two host tools in `Tools/` produce it:

| Tool | Input | Output |
|---|---|---|
| `build-universal-gol.ps1` | the two thin per-arch **binaries** | runs `LNG` on each, then muxes → one universal `.gol` |
| `mux-gol-universal.ps1` | two existing single-arch **`.gol`s** | one universal `.gol` (the merge step alone) |

```powershell
# from the two thin per-arch builds (each with its sibling .dSYM alongside):
powershell -NoProfile -ExecutionPolicy Bypass -File Tools\build-universal-gol.ps1 `
    -Arm64Bin out\arm64\MyApp -X64Bin out\x86_64\MyApp -OutFile out\MyApp.gol
```

Each slice's `LC_UUID` survives `lipo` and ad-hoc `codesign` unchanged, so a
container built from the thin `.gol`s matches the assembled universal binary.

**Deploy:** place the `.gol` at `<app>.app/Contents/Resources/<exe>.gol` — the
reader's macOS fallback looks for it there, and `codesign` rejects non-Mach-O
files in `Contents/MacOS/`.

## Function names (`.gosym`) — Android

On Linux/macOS the call-stack *names* come from the binary's own symbol table at runtime
(`dladdr` over `--export-dynamic` on Linux; `LC_SYMTAB` on macOS). On Android neither is
available: the Delphi linker localizes every Pascal symbol with a version script, and the
deployed `.so` is stripped to a tiny `.dynsym` export whitelist, so `dladdr` resolves only
the few entry points. The `.gosym` side-file restores names on-device, the same way the
`.gol` restores lines — and it is deployed and matched (by build-id) identically.

A `.gosym` is an address-sorted table of `(VM address, size, mangled name, source file)`,
generated offline from the **unstripped** `.so`:

- **Names** come from the `.so`'s `.symtab` (`llvm-nm`) — stored mangled, demangled at
  runtime via `__cxa_demangle`, exactly as `dladdr` names are on the other POSIX targets.
- **The source file** per function comes from the DWARF line info (`llvm-symbolizer`).
  Knowing the unit (from the file — with correct casing) lets the reporter split
  Unit/Class/Procedure **the way EurekaLog does** (`TEurekaBaseStackList.ParseClassName`):
  strip the unit prefix, then take the last dot outside any brackets — no guessing from
  the flat dotted name. It also fills the `Source` column with the real `.pas`. Functions
  with no DWARF (~18%, RTL stubs) carry no file and fall back to `module + offset`.

The byte format is documented at the top of `Crash.Android.Symbols`, which reads the file
once at startup, verifies its build-id against the running `.so`, and serves lookups from
an in-memory binary search (cheap on the crash path).

### Build requirements

The same two link settings as the `.gol` (both come from one `.so`): `DCC_DebugInformation=2`
and `--build-id=sha1`. The build-id matches the file to the stripped on-device `.so`. DWARF
is what yields the **source file** per function — hence the correct unit, the EurekaLog-style
class/method split and the `Source` column; the *names* come from the `.symtab` and survive
even without DWARF, but then the split falls back to the dotted-name heuristic and there is
no source file. `--export-dynamic` does nothing here (the version script localizes the
symbols regardless).

### Building the generator

`Tools/gen-android-symfile.ps1` is a host PowerShell script (it shells out to the NDK
`llvm-nm`, `llvm-readelf` and `llvm-symbolizer`). It is the `.gosym` counterpart of
`LNG_ELF` for the `.gol`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File Tools\gen-android-symfile.ps1 `
    -SoPath out\Android64\libMyApp.so          # -> libMyApp.so.gosym
```

### Mobile deploy (`.gosym` + `.gol`)

Both files are produced together and shipped together:

1. Link the `.so` with `--build-id=sha1` and keep DWARF (`DCC_DebugInformation=2`).
2. From the just-linked **unstripped** `.so`, run `LNG_ELF` → `<so>.gol` and
   `gen-android-symfile.ps1` → `<so>.gosym`. Regenerate every build (a fresh link gives a
   new build-id; a stale side-file is rejected, not mis-read).
3. Ship both inside the APK as assets with RemoteDir `assets\internal\`, which lands them
   in the app's documents dir — where `Crash.Android.Symbols` / `Crash.LineNumbers` look
   for `<so-name>.gosym` / `<so-name>.gol`.
4. **Archive the unstripped `.so` per release** so any leftover `module + offset` report
   (a no-DWARF frame, or an old report whose side-files were lost) can still be symbolized
   offline against it.

## Wiring into your build

Two stages, mirroring how the reader finds the `.gol` at runtime (`<exe>.gol` next
to the binary; macOS also falls back to `Contents/Resources/<exe>.gol`):

- **Per build (per arch)** — a natural PostBuild step. After linking each target,
  run the matching generator on the binary so a single-arch `.gol` lands beside it:
  - Linux: `LNG_ELF <elf>` → `<elf>.gol` (ship it next to the ELF).
  - macOS (single-arch): `LNG <binary>` → `<binary>.gol`.
- **At packaging (macOS universal only)** — once both thin arches exist, build the
  container and place it in the bundle **before** `codesign` (so the resource is
  sealed; never put a `.gol` in `Contents/MacOS/`):

  ```
  Tools\build-universal-gol.ps1 -Arm64Bin <arm64> -X64Bin <x86_64> -OutFile MyApp.gol
  cp MyApp.gol  MyApp.app/Contents/Resources/MyApp.gol
  ```

The generators need debug info on the target (DWARF / `.dSYM`) — see *Build
requirements* above.

**Optional — strip the binary.** Both platforms link a binary that still carries
the build-time debug info, and the reporter never reads it at runtime — it
resolves names from the regular/dynamic symbol table and lines from the `.gol`.
Stripping that debug info shrinks the shipped binary substantially. On **both**
platforms the strip must run **after** the generator (the `.gol` is built from the
very debug info you are about to drop); on macOS it must *also* run **before**
`codesign` (strip invalidates the signature). The right tool and how aggressive
you can be differ per platform, because each resolves Pascal names from a
different table:

- **macOS** — `strip -S <binary>`. Drops only the DWARF debug map (STAB symbols)
  that `dsymutil` needed at build time — ~27% smaller on a typical FMX build —
  while leaving `LC_UUID`, the code addresses and the name table (`LC_SYMTAB`)
  untouched, so the `.gol` and the crash-stack names stay valid. Use **`-S`
  only**: a plain `strip` / `-x` removes local symbols and loses the Pascal names
  that macOS symbolication reads straight from `LC_SYMTAB`. Run it *before*
  `codesign`.
- **Linux** — `objcopy --strip-all <elf>` (or the gentler `objcopy --strip-debug`
  if you want to keep the static symbol table too). Removes `.debug_*` plus the
  static `.symtab` / `.strtab`, while keeping `.dynsym` and `.note.gnu.build-id`.
  This can be **more** aggressive than macOS's `-S`: Linux symbolication reads
  names from `.dynsym` (exposed by the `--export-dynamic` link option), not
  `.symtab`, and the reader matches the `.gol` to the image by the build-id — both
  survive `--strip-all`. There is no signature on Linux, so the only ordering
  constraint is to strip *after* `LNG_ELF`. (On a typical FMX build this takes the
  linked ELF from ~150 MB down to the ~60–70 MB actually shipped.)

## Hardware faults (POSIX signals)

A Pascal `raise` carries its own call stack, but a hardware fault
(SIGSEGV/SIGFPE/SIGILL/SIGBUS) arrives through the kernel. `Crash.Signals` installs
a `sigaction` handler that snapshots the CPU registers and a slice of the stack,
then returns and lets the Delphi RTL re-raise the fault as a catchable Pascal
exception, which the reporter turns into the `.el`.

That "return + re-raise" path has one quirk: the libc backtrace taken at report
time **drops the faulting frame** — the stack jumps straight from the RTL signal
converter to the faulting function's *caller*. The reporter repairs this: from the
snapshot it recovers the fault address (`RIP`/`PC`) and the caller's return address
(`[FP+8]`), locates the caller in the backtrace, and splices the faulting frame
back into its **true position** (right before the caller). The exception address
(report field `2.2`) is additionally symbolicated to `Unit | Class | Procedure |
Line`.

The repair is conservative — it only fires for a primary fault **in your own code**
(one that resolves to a source line). A soft `raise` has no snapshot (its backtrace
is already complete → nothing is added); a fault inside a system library is treated
as secondary and left alone (its nearest in-app frame is already shown).

**Snapshot↔exception correlation.** The handler is one-shot: after the first
catch it restores the previous (RTL) disposition and is re-armed only after a
report is written. A fault whose exception the app swallows therefore leaves a
pending snapshot behind, and the *next* reported exception — possibly on
another thread — would otherwise inherit it. Seen live (report `CDFC1215`):
the report header carried the main thread's `CheckSynchronize` AV while
Registers/Stack dump held a worker thread's `RemoveQueuedEvents` #GP context. The snapshot is now stamped with the
faulting thread's pthread identity, and at report time it is correlated with
the exception being reported (thread identity + fault RIP vs the exception
address — the same predicate the call-stack splice uses). A foreign-thread or
stale snapshot is *demoted*: the EL `Registers:` section is suppressed (the
Viewer must not present a foreign CPU context as this exception's) and the
registers/stack move into `Crash Signal Info:` as an explicitly-labeled dump
with **lowercase** register names — lowercase so the Viewer's literal
`EAX`/`RAX` content check never claims the block as the CPU tab. A second
fault that enters the handler while a snapshot is pending is recorded
location-only (signal, code, ip, thread) and printed as a `Concurrent :` line.
`Invocations` counts entries into *this* handler only; faults converted by the
RTL while the handler was uninstalled are invisible to it (the report wording
says so).

Scope: Linux x86-64, macOS x86-64 + ARM64, and Android ARM64 (aarch64). Other
targets compile to no-ops.

On **Android** register capture is on by default, like the other POSIX targets. The
handler reads the bionic aarch64 `ucontext` (`X0..X30`, `SP`, `PC`, `PSTATE`) and emits
a `Registers:` + `Stack:` / `Memory Dump` block just like the x86/x64 path. One
Android-specific wrinkle: the
EurekaLog Viewer keeps a CPU section only if it contains the literal `EAX` or `RAX`
(an x86/x64 register-name check in `TLogFile.GetItem_CPU`), so the ARM64 block carries
a single `EAX/RAX: n/a on ARM64 - …compatibility` note line to satisfy that gate; the
Viewer then shows the real ARM registers as text.

## EurekaLog `.el` compatibility

The writer (`Crash.ELFormat`) targets the EurekaLog Viewer's parser, which is
strict in a few non-obvious ways:

- **Header prefix.** The file must begin with the literal `EurekaLog ` — rename it
  and the Viewer silently drops the Call Stack tab. The version after it is free
  (we emit `1.0`).
- **Call Stack is the anchor.** The Call Stack table must always be present, so
  Application / Exception / Call Stack are not omittable via `DisabledSections`.
- **No blank trailing sections.** A section emitted with an empty `Title:----`
  body makes the Viewer choke, so unused tail sections are omitted entirely rather
  than left blank.
- **Registers section.** Its header is `Registers:` (not `CPU:`, which is only the
  dialog tab caption), with no stray text between the `EXP/STK` line and the
  `Stack:` / `Memory Dump:` header.
- **Encoding.** UTF-16LE + BOM, matching a Windows EurekaLog build.

## Demo / smoke test

`Demo/CrashDemo.dpr` (+ `CrashDemo.dproj`) is a tiny console program that uses
**only** `Crash.*` units — no host framework, no FMX. It is the library's
self-containment check: if it links on a bare console target and produces a
valid `.el`, nothing in the library secretly depends on a host application.

```
# build (Linux64) — open Demo/CrashDemo.dproj in the IDE, or from a RAD Studio
# command prompt (rsvars.bat applied to the environment):
msbuild Demo/CrashDemo.dproj /t:Build /p:Config=Release /p:Platform=Linux64
# -> Demo/Linux64/Release/CrashDemo

# run (CRASH_NO_UPLOAD=1 keeps the .el on disk and skips any network)
CRASH_NO_UPLOAD=1 ./CrashDemo --crash=segv     # hardware fault -> .el with Registers
CRASH_NO_UPLOAD=1 ./CrashDemo --crash=raise    # software raise -> .el without Registers
# also: --crash=fpe (div-by-zero), --crash=callbad (call into unmapped memory)
# snapshot<->exception correlation tests (the CDFC1215 mixed-report scenario):
CRASH_NO_UPLOAD=1 ./CrashDemo --crash=stale    # swallowed fault, then soft raise on the SAME
                                               # thread -> no Registers, "STALE snapshot" note
CRASH_NO_UPLOAD=1 ./CrashDemo --crash=foreign  # worker's fault swallowed, main thread raises ->
                                               # no Registers, "captured on ANOTHER thread" note
```

With no `--crash` argument it just prints `Reporter Active = True`. The reporter
consumes the library purely via the unit search path (a single `..` entry — the
directory holding the `Crash.*` units), exactly as an external consumer would.

## License

BSD 2-Clause. Portions © 2017 Grijjy, Inc.; modifications under the same terms.
See `LICENSE.txt`.
