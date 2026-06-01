#requires -Version 5
<#
.SYNOPSIS
  Build one universal ('GOLF') `.gol` line-number container from a macOS universal
  binary's two per-arch thin builds (arm64 + x86_64).

.DESCRIPTION
  A macOS universal binary keeps a distinct LC_UUID + address space per arch
  slice, so one single-arch `.gol` can only map one slice (the crash reporter
  rejects a wrong-arch `.gol` outright -- no line numbers for the other arch).
  This script produces a container that covers BOTH arches; at runtime the reader
  (Crash.LineNumbers) picks the slice whose UUID matches the running image.

  It is a thin orchestrator over the two tools in this directory:
    1. LNG.exe          -- reads each thin binary's sibling `.dSYM` (DWARF) and
                           writes a single-arch `<binary>.gol` next to it.
    2. mux-gol-universal.ps1 -- merges the two single-arch `.gol`s into one
                           universal container.

  Self-contained: it calls LNG.exe directly and does NOT depend on any host
  build system. LNG.exe must already exist (default: Bin\LNG.exe beside this
  script); build it from Tools\LineNumberGenerator\LNG.dproj (a Win32 console
  utility that runs on the build host) or pass -LngExe.

  Each thin binary must have its sibling `.dSYM` bundle (build the macOS targets
  with debug information enabled, e.g. DCC_DebugInformation=2).

.PARAMETER Arm64Bin
  Path to the thin arm64 (OSXARM64) Mach-O binary. Its `<bin>.dSYM` must sit
  alongside it.

.PARAMETER X64Bin
  Path to the thin x86_64 (OSX64) Mach-O binary. Its `<bin>.dSYM` must sit
  alongside it.

.PARAMETER OutFile
  Path to write the universal `.gol`. Default: "<X64Bin>.universal.gol".

.PARAMETER LngExe
  Path to the macOS `.gol` generator. Default: "Bin\LNG.exe" beside this script.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File build-universal-gol.ps1 `
    -Arm64Bin out\arm64\MyApp `
    -X64Bin   out\x86_64\MyApp `
    -OutFile  out\MyApp.gol

.NOTES
  Deploy the result as <app>.app/Contents/Resources/<exe>.gol -- the reader's
  macOS fallback looks for it there, and codesign rejects non-Mach-O files in
  Contents/MacOS/.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)] [string] $Arm64Bin,
  [Parameter(Mandatory=$true)] [string] $X64Bin,
  [string] $OutFile = '',
  [string] $LngExe  = ''
)

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
if (-not $LngExe)  { $LngExe  = Join-Path $here 'Bin\LNG.exe' }
$Mux = Join-Path $here 'mux-gol-universal.ps1'
if (-not $OutFile) { $OutFile = "$X64Bin.universal.gol" }

if (-not (Test-Path -LiteralPath $LngExe)) {
  throw "[build-gol] LNG.exe not found: $LngExe`n  Build it from Tools\LineNumberGenerator\LNG.dproj (Win32 console host utility), or pass -LngExe."
}
if (-not (Test-Path -LiteralPath $Mux)) {
  throw "[build-gol] muxer not found: $Mux"
}

function New-SingleArchGol([string]$bin) {
  if (-not (Test-Path -LiteralPath $bin)) { throw "[build-gol] binary not found: $bin" }
  if (-not (Test-Path -LiteralPath "$bin.dSYM")) {
    throw "[build-gol] dSYM not found: $bin.dSYM  (build with debug info, e.g. DCC_DebugInformation=2)"
  }
  Write-Host "[build-gol] LNG.exe `"$bin`""
  & $LngExe $bin | Out-Host            # keep LNG output off the function's return pipeline
  if ($LASTEXITCODE -ne 0) { throw "[build-gol] LNG.exe failed on $bin (exit $LASTEXITCODE)" }
  if (-not (Test-Path -LiteralPath "$bin.gol")) { throw "[build-gol] LNG produced no .gol for $bin" }
}

New-SingleArchGol $Arm64Bin
New-SingleArchGol $X64Bin

Write-Host "[build-gol] muxing universal .gol -> $OutFile"
& powershell -NoProfile -ExecutionPolicy Bypass -File $Mux `
    -Osx64Gol "$X64Bin.gol" -OsxArmGol "$Arm64Bin.gol" -OutFile $OutFile
if ($LASTEXITCODE -ne 0) { throw "[build-gol] mux-gol-universal.ps1 failed (exit $LASTEXITCODE)" }

Write-Host "[build-gol] OK: $OutFile"
exit 0
