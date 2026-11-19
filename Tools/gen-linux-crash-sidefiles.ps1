#requires -Version 5
<#
.SYNOPSIS
  Generate the crash-symbolication side-files for a Linux64 ELF executable:
    <exe>.gol    (line numbers, from the DWARF)
    <exe>.gosym  (names of LOCAL functions + their source files, from .symtab)

.DESCRIPTION
  Post-build helper for Delphi Linux64 builds. Runs LNG_ELF --gosym on the
  UNSTRIPPED linker output, so run it before any strip step. dladdr resolves
  only .dynsym names at runtime; routines the compiler emits as local symbols
  are named from the .gosym by Crash.Linux.Symbols, line numbers come from the
  .gol via Crash.LineNumbers. Both files are matched to the executable by its
  ELF build-id and must ship next to it.

  Soft-fails (warn + exit 0) when the ELF has no DWARF, so builds without
  DCC_DebugInformation=2 still link; the crash report then has no line numbers
  and fewer names. Hard-fails on other LNG_ELF errors.

.PARAMETER ExePath
  The linked ELF executable (the MSBuild $(OUTPUTPATH)).
#>
param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$ExePath
)

$ErrorActionPreference = 'Stop'
$lngExe  = Join-Path $PSScriptRoot 'Bin\LNG_ELF.exe'
$lngProj = Join-Path $PSScriptRoot 'LineNumberGenerator\LNG_ELF.dproj'

# LNG_ELF is auto-built on first use. The .dproj defaults (Release/Win32,
# ExeOutput=..\Bin) are already correct, so a plain msbuild invocation is
# enough; msbuild comes from PATH (rsvars) or the .NET Framework dir.
function Resolve-MsBuild {
    $cmd = Get-Command msbuild.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($dir in @($env:FrameworkDir,
                       (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319'))) {
        if ($dir) {
            $p = Join-Path $dir 'MSBuild.exe'
            if (Test-Path $p) { return $p }
        }
    }
    return $null
}

if (-not (Test-Path $ExePath -PathType Leaf)) {
    Write-Error "[linux-sidefiles] Executable not found: $ExePath"
    exit 1
}

if (-not (Test-Path $lngExe)) {
    $msbuild = Resolve-MsBuild
    if ($msbuild) {
        Write-Host "[linux-sidefiles] LNG_ELF.exe not found, building $lngProj..."
        & $msbuild $lngProj /nologo /t:Build /v:minimal | Out-Null
    }
}
if (-not (Test-Path $lngExe)) {
    Write-Error "[linux-sidefiles] LNG_ELF.exe missing (build Tools\LineNumberGenerator\LNG_ELF.dproj)"
    exit 1
}

# Drop stale side-files: one left from another build would mismatch the build-id.
Remove-Item -Force -ErrorAction SilentlyContinue "$ExePath.gol", "$ExePath.gosym"

Write-Host "[linux-sidefiles] LNG_ELF.exe --gosym `"$ExePath`""
$lngOutput = & $lngExe --gosym $ExePath 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    if ($lngOutput -match 'ELF lacks DWARF debug sections') {
        Write-Warning "[linux-sidefiles] ELF has no DWARF (DCC_DebugInformation != 2) -- no side-files."
        exit 0
    }
    Write-Error "[linux-sidefiles] LNG_ELF failed (exit $LASTEXITCODE): $lngOutput"
    exit 1
}
Write-Host ("[linux-sidefiles] " + $lngOutput.Trim())
exit 0
