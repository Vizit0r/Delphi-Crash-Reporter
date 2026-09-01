# Post-package check: the .so inside the APK and the crash side-files packaged
# next to it must belong to the SAME link.
#
# Why this exists: the side-files (.gosym names, .gol lines) are keyed by the
# ELF sha1 build-id and the on-device resolver refuses a mismatch outright -
# silently, because wrong names are worse than none. So a broken pairing costs
# every crash report its symbols and nothing says a word at build time.
#
# Easy to break by accident: the side-files are generated from $(DCC_ExeOutput),
# but the packaged .so travels through the deploy chain, whose .deployproj rows
# address their sources relative to the PROJECT and ignore a redirected output
# root. Build with such a redirect and you get side-files from one tree against
# a .so from another; this has happened in practice.
#
# Usage: verify-android-crash-symbols.ps1 <path-to-apk>
# Exit 0 = consistent (or side-files absent by design), 1 = mismatch.

param([Parameter(Mandatory = $true)][string]$ApkPath)

$ErrorActionPreference = 'Stop'

function Get-ElfBuildId {
    param([byte[]]$Bytes)
    if ($Bytes.Length -lt 64) { return $null }
    if ($Bytes[0] -ne 0x7F -or $Bytes[1] -ne 0x45 -or $Bytes[2] -ne 0x4C -or $Bytes[3] -ne 0x46) { return $null }
    if ($Bytes[4] -ne 2) { return $null }   # ELFCLASS64 only
    $phoff = [BitConverter]::ToInt64($Bytes, 0x20)
    $phentsize = [BitConverter]::ToUInt16($Bytes, 0x36)
    $phnum = [BitConverter]::ToUInt16($Bytes, 0x38)
    for ($i = 0; $i -lt $phnum; $i++) {
        $o = $phoff + $i * $phentsize
        if ($o + 56 -gt $Bytes.Length) { break }
        if ([BitConverter]::ToUInt32($Bytes, $o) -ne 4) { continue }   # PT_NOTE
        $noteOff = [BitConverter]::ToInt64($Bytes, $o + 8)
        $noteSz = [BitConverter]::ToInt64($Bytes, $o + 32)
        if ($noteOff + $noteSz -gt $Bytes.Length) { continue }
        $p = $noteOff
        while ($p + 12 -le $noteOff + $noteSz) {
            $namesz = [BitConverter]::ToUInt32($Bytes, $p)
            $descsz = [BitConverter]::ToUInt32($Bytes, $p + 4)
            $ntype = [BitConverter]::ToUInt32($Bytes, $p + 8)
            $descPos = $p + 12 + (($namesz + 3) -band -bnot 3)
            if ($ntype -eq 3 -and $descsz -ge 16) {
                return (($Bytes[$descPos..($descPos + 15)] | ForEach-Object { $_.ToString('x2') }) -join '')
            }
            $p = $descPos + (($descsz + 3) -band -bnot 3)
        }
    }
    return $null
}

# Bounded read: the packaged .so is ~100 MB uncompressed and slurping it whole
# threw OutOfMemoryException when this ran under a loaded msbuild. Everything we
# need - ELF header, program headers, the PT_NOTE with the build-id, and the
# side-file header - lives in the first few KB, so read a prefix and stop.
function Read-EntryPrefix {
    param($Zip, [string]$Name, [int]$MaxBytes)
    $e = $Zip.GetEntry($Name)
    if (-not $e) { return $null }
    $s = $e.Open()
    try {
        $want = [Math]::Min([int64]$MaxBytes, $e.Length)
        $buf = New-Object byte[] $want
        $read = 0
        while ($read -lt $want) {
            $n = $s.Read($buf, $read, $want - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        if ($read -lt $want) { return $buf[0..($read - 1)] }
        return $buf
    } finally { $s.Dispose() }
}

if (-not (Test-Path -LiteralPath $ApkPath)) {
    Write-Host "[verify-crash-symbols] APK not found, nothing to check: $ApkPath"
    exit 0
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

# The packaging chain may still hold the freshly written APK when this runs, so
# give it a few tries before giving up. Never fail the build for "could not
# read it" - that would be a false alarm; only a proven mismatch is an error.
$zip = $null
for ($attempt = 1; $attempt -le 5; $attempt++) {
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ApkPath)
        break
    } catch {
        if ($attempt -eq 5) {
            Write-Host "[verify-crash-symbols] cannot read $ApkPath after $attempt tries: $($_.Exception.Message)"
            Write-Host '[verify-crash-symbols] check skipped - verify by hand if this build is going out'
            exit 0
        }
        Start-Sleep -Seconds 2
    }
}

try {
    # Drive from the side-files: the APK carries several .so (shard DLLs among
    # them) and only the ones we generated side-files for are ours to check.
    $sides = @($zip.Entries | Where-Object {
        $_.FullName -like 'assets/internal/*.gosym' -or $_.FullName -like 'assets/internal/*.gol'
    })
    if ($sides.Count -eq 0) {
        Write-Host '[verify-crash-symbols] no side-files packaged - skipped'
        exit 0
    }

    $bad = $false
    $seen = $false
    foreach ($side in $sides) {
        $sideName = [System.IO.Path]::GetFileName($side.FullName)
        $ext = [System.IO.Path]::GetExtension($sideName).TrimStart('.')
        $soName = [System.IO.Path]::GetFileNameWithoutExtension($sideName)  # libX.so.gosym -> libX.so
        $soPath = "lib/arm64-v8a/$soName"
        $soBytes = Read-EntryPrefix $zip $soPath 4194304   # 4 MB: header + phdrs + PT_NOTE
        if (-not $soBytes) {
            Write-Host "[verify-crash-symbols] $sideName packaged but $soPath is not in the APK"
            $bad = $true
            continue
        }
        $soId = Get-ElfBuildId -Bytes $soBytes
        if (-not $soId) {
            Write-Host "[verify-crash-symbols] $soName carries no build-id - link with --build-id=sha1; skipped"
            continue
        }
        $data = Read-EntryPrefix $zip $side.FullName 64    # build-id sits at 16..31
        $seen = $true
        # Both side-file formats keep the build-id at offset 16..31.
        if ($data.Length -lt 32) {
            Write-Host "[verify-crash-symbols] $soName.$ext is truncated"
            $bad = $true
            continue
        }
        $sideId = (($data[16..31] | ForEach-Object { $_.ToString('x2') }) -join '')
        if ($sideId -ne $soId) {
            Write-Host "[verify-crash-symbols] MISMATCH: $soName.$ext is for $sideId, packaged .so is $soId"
            $bad = $true
        } else {
            Write-Host "[verify-crash-symbols] ok: $soName.$ext matches $soId"
        }
    }

    if (-not $seen -and -not $bad) {
        Write-Host '[verify-crash-symbols] nothing checkable - skipped'
        exit 0
    }
    if ($bad) {
        Write-Host '[verify-crash-symbols] Crash reports from this APK would carry NO symbols.'
        Write-Host '[verify-crash-symbols] Usual cause: the .so was relinked after the side-files were generated.'
        exit 1
    }
    exit 0
} finally {
    $zip.Dispose()
}
