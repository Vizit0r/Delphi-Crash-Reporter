# Crash Reporter

A standalone, **EurekaLog-compatible** crash/exception reporter for Delphi
cross-platform targets (Linux, macOS, Android, iOS) built on FMX/RTL. No
EurekaLog license required — it produces `.el` text reports that the EurekaLog
Viewer opens natively, with call stacks, CPU registers, modules and source line
numbers.

On **Windows** it is a no-op by design (use EurekaLog there); the units still
compile so the same code base builds on every platform.

Derived from [grijjy/JustAddCode](https://github.com/grijjy/JustAddCode)
(ErrorReporting), BSD 2-Clause — see `LICENSE.txt`.

## What you get

| Capability | Linux | macOS | Android | iOS | Windows |
|---|---|---|---|---|---|
| Unhandled-exception trapping | ✅ | ✅ | ✅ | ✅ | ❌ (EurekaLog) |
| Call stack (Pascal names) | ✅ | ✅ (LC_SYMTAB) | ✅ | ✅ | ❌ |
| Source line numbers (`.gol`) | ✅ | ✅ | — | — | — |
| CPU registers on hardware faults | ✅ | — (Mach ports) | — | — | — |
| Modules section | ✅ | ✅ | ✅ | — | — |
| EL-compatible `.el` output | ✅ | ✅ | ✅ | ✅ | — |
| Save / upload / dialog / restart | ✅ | ✅ | ✅ (no restart) | ✅ (no restart) | — |

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
| `DisabledSections` | `[]` (full report) | Report sections to omit entirely (header + body); Application, Exception and Call Stack are mandatory and not omittable |
| `ReportDir` | `''` (platform default) | Directory for `.el` files (write + boot-recovery scan). Empty → next to the `.app` on macOS (not inside the bundle), the exe's own dir on Linux/Windows |

Set the env var `CRASH_NO_UPLOAD=1` to skip uploads and keep the file on disk
(useful for local testing).

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
- `Crash.ELFormat` — EurekaLog `.el` text writer.
- `Crash.MacOS.Api` / `Crash.MacOS.Symbols` — Mach-O structs + LC_SYMTAB symbolication.
- `Crash.Demangle` — C++ (Itanium) → Pascal symbol translation.

Optional UI:

- `Crash.Dialog.FMX` — modal FMX report dialog. `ShowCrashDialog` wires into
  `TCrashConfig.OnShowDialog`; set `CrashDialogTitle` to change the caption.

## Source line numbers (`.gol`)

Line numbers come from a `.gol` file generated at build time from the binary's
debug info and deployed next to the executable.

- **Linux**: `Tools/LineNumberGenerator/LNG_ELF` reads DWARF from the ELF.
- **macOS**: `Tools/LineNumberGenerator/LNG` reads DWARF from the `.dSYM`.

Both emit the same `.gol` byte format that `Crash.LineNumbers` reads at runtime.

### Build requirements

- **Linux64**: `DCC_DebugInformation=2` (keep DWARF for the generator) and the
  linker option `--export-dynamic` (so `dladdr` sees Pascal symbols). Without
  the latter the call stack falls back to module-offset proxies.
- **macOS** (Release): Local symbols = True and Output debug information = True,
  otherwise the linker strips the symbol table and names resolve poorly.
- After changing `DCC_DebugInformation`, do one full rebuild (incremental Make
  reuses `.dcu` cache and the `.gol` ends up near-empty).

## License

BSD 2-Clause. Portions © 2017 Grijjy, Inc.; modifications under the same terms.
See `LICENSE.txt`.
