#requires -Version 5
<#
.SYNOPSIS
  Generate BOTH crash-symbolication side-files for an Android .so:
    <so>.gosym  (function names + source files, via gen-android-symfile.ps1)
    <so>.gol    (line numbers, via LNG_ELF on the DWARF)

.DESCRIPTION
  Deploy-time helper for Delphi FMX Android builds. Runs on the UNSTRIPPED
  linker output (the ExeOutput .so, which RAD never strips -- it strips only the
  staged copy that goes into the APK), so .symtab + DWARF are present. The two
  side-files are written next to the .so under the exact names the runtime
  readers expect (Crash.Android.Symbols / Crash.LineNumbers look for
  "<so-basename>.gosym" / ".gol" in the app documents dir). They ride into the
  APK as assets\internal\ and System.StartUpCopy extracts them on first run.

  Both files are build-id-matched to the .so (the Android64 config must link
  with --build-id=sha1). RAD's NDK strip preserves .note.gnu.build-id, so the
  shipped (stripped) .so keeps matching these side-files.

  Soft-fails (warn + exit 0) when the .so lacks .symtab/DWARF -- e.g. a build
  without DCC_DebugInformation=2 -- so dev/iteration builds still package; the
  crash report just falls back to <module>+<offset>. Hard-fails only on real
  tooling errors (missing .so, generator crash).

.PARAMETER SoPath
  The linked .so. Accepts the MSBuild $(OUTPUTPATH); if that is not the .so
  itself, the lib<SanitizedProjectName>.so sibling is derived.
#>
param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$SoPath
)

$ErrorActionPreference = 'Stop'
$genGosym = Join-Path $PSScriptRoot 'gen-android-symfile.ps1'
$lngExe   = Join-Path $PSScriptRoot 'Bin\LNG_ELF.exe'
$lngProj  = Join-Path $PSScriptRoot 'LineNumberGenerator\LNG_ELF.dproj'

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

# --- resolve the .so (OUTPUTPATH may be a dir or a non-.so output name) ---
if (Test-Path $SoPath -PathType Container) {
    $hit = Get-ChildItem -Path $SoPath -Filter '*.so' -File -ErrorAction SilentlyContinue |
           Sort-Object Length -Descending | Select-Object -First 1
    if ($hit) { $SoPath = $hit.FullName }
} elseif ($SoPath -notmatch '\.so$') {
    $dir  = Split-Path -Parent $SoPath
    $base = [System.IO.Path]::GetFileNameWithoutExtension($SoPath)
    foreach ($cand in @("lib$base.so", "$base.so")) {
        $p = Join-Path $dir $cand
        if (Test-Path $p) { $SoPath = $p; break }
    }
}
if (-not (Test-Path $SoPath)) {
    Write-Warning "[android-sidefiles] .so not found ($SoPath) -- skipping (no symbolication side-files)."
    exit 0
}
Write-Host "[android-sidefiles] target .so: $SoPath"

$gosym = "$SoPath.gosym"
$gol   = "$SoPath.gol"

# Drop stale side-files first, so the post-run Test-Path reflects THIS run only
# (a leftover .gosym from a prior, differently-built .so would mismatch build-id).
Remove-Item -Force -ErrorAction SilentlyContinue $gosym, $gol

# Child scripts run in THIS PowerShell process (& on the .ps1, not a nested
# powershell.exe) -- avoids -File/-arg quirks and inherits the ExecutionPolicy.
# Each is wrapped: a build without DWARF/symtab (e.g. DCC_DebugInformation!=2)
# makes a generator throw, which must NOT break the APK build -- the crash report
# just degrades to <module>+<offset>. So this hook always exits 0 and only warns.

# --- .gol (line numbers) -- LNG_ELF reads the DWARF from the .so directly. ---
try {
    if (-not (Test-Path $lngExe)) {
        $msbuild = Resolve-MsBuild
        if ($msbuild) {
            Write-Host "[android-sidefiles] LNG_ELF.exe not found, building $lngProj..."
            & $msbuild $lngProj /nologo /t:Build /v:minimal | Out-Null
        }
    }
    if (-not (Test-Path $lngExe)) {
        Write-Warning "[android-sidefiles] LNG_ELF.exe missing (build Tools\LineNumberGenerator\LNG_ELF.dproj) -- skipping .gol."
    } else {
        $lngOutput = & $lngExe $SoPath 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            if ($lngOutput -match 'ELF lacks DWARF debug sections') {
                Write-Warning "[android-sidefiles] .so has no DWARF (DCC_DebugInformation != 2) -- skipping .gol."
            } else {
                Write-Warning "[android-sidefiles] LNG_ELF failed (exit $LASTEXITCODE): $lngOutput"
            }
        }
    }
}
catch { Write-Warning "[android-sidefiles] .gol generation errored: $($_.Exception.Message)" }

# --- .gosym (names + source files) ---
try { & $genGosym -SoPath $SoPath }
catch { Write-Warning "[android-sidefiles] .gosym generation errored: $($_.Exception.Message)" }

$haveGosym = Test-Path $gosym
$haveGol   = Test-Path $gol
Write-Host ("[android-sidefiles] result: .gosym={0} .gol={1}" -f `
    $(if($haveGosym){'{0:N1} MB' -f ((Get-Item $gosym).Length/1MB)}else{'MISSING'}), `
    $(if($haveGol){'{0:N0} B' -f (Get-Item $gol).Length}else{'MISSING'}))
if (-not ($haveGosym -and $haveGol)) {
    Write-Warning "[android-sidefiles] one or both side-files missing -- crash reports degrade to module+offset for this build."
}
exit 0
