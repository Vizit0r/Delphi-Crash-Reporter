<#
.SYNOPSIS
  Generate a .gosym side-file (address -> function name + source file) from an
  UNSTRIPPED Android .so, for on-device crash-stack symbolication.

.DESCRIPTION
  On Android the deployed .so is stripped to .dynsym (a tiny export whitelist) and
  the linker's version script localizes all Pascal symbols, so dladdr resolves no
  names at runtime - app frames in the report carry just "<module> + <offset>".
  This mirrors the .gol model (line numbers): a compact side-file generated offline
  from the unstripped build, shipped with the app, read at runtime.

  Names come from the .symtab (mangled; demangled at runtime via __cxa_demangle).
  The source FILE per function comes from the DWARF line info (via llvm-symbolizer)
  - it gives the reporter the unit name with correct casing, so it can split
  class/method unambiguously (strip the unit prefix) the way EurekaLog does, instead
  of guessing from the dotted name. Functions without DWARF (~18%, RTL stubs) get no
  file and fall back to the heuristic split.

  Keyed by the ELF .note.gnu.build-id (first 16 bytes; link with --build-id=sha1).

  Format v2 (little-endian):
    Header (48 bytes):
      UInt32 Signature  = 'GOSY' (0x59534F47)
      UInt32 Version    = $00020000
      UInt32 Size       = total file size
      UInt32 Count      = number of symbol entries
      Byte[16] BuildId
      UInt32 StrTabOff  / UInt32 StrTabSize   (mangled-name string table)
      UInt32 FileTabOff / UInt32 FileTabSize  (source-file string table)
    Entries[Count] (sorted by Addr), 20 bytes each:
      UInt64 Addr | UInt32 Size | UInt32 NameOff | UInt32 FileOff
    StrTab  : NUL-terminated mangled names (deduplicated)
    FileTab : NUL-terminated source file names (deduplicated; offset 0 = "" = unknown)

.PARAMETER SoPath   Unstripped .so (the link output).
.PARAMETER OutPath  Output .gosym (default: "<SoPath>.gosym").
.PARAMETER Ndk      NDK llvm bin dir (auto-detected from RAD Studio if omitted).
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$SoPath,
  [string]$OutPath,
  [string]$Ndk
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $SoPath)) { throw "SoPath not found: $SoPath" }
if (-not $OutPath) { $OutPath = "$SoPath.gosym" }

function Find-NdkTool([string]$Hint, [string]$Tool) {
  if ($Hint -and (Test-Path (Join-Path $Hint $Tool))) { return (Join-Path $Hint $Tool) }
  $bases = @(
    "C:\Users\Public\Documents\Embarcadero\Studio\*\PlatformSDKs\android-sdk-windows\ndk\*\toolchains\llvm\prebuilt\windows-x86_64\bin",
    "$env:LOCALAPPDATA\Android\Sdk\ndk\*\toolchains\llvm\prebuilt\windows-x86_64\bin"
  )
  foreach ($b in $bases) {
    $hit = Resolve-Path -Path (Join-Path $b $Tool) -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($hit) { return $hit.Path }
  }
  $cmd = Get-Command $Tool -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  throw "$Tool not found (pass -Ndk <NDK llvm bin dir>)."
}
$nm      = Find-NdkTool $Ndk 'llvm-nm.exe'
$readelf = Find-NdkTool $Ndk 'llvm-readelf.exe'
$symbol  = Find-NdkTool $Ndk 'llvm-symbolizer.exe'

# --- build-id (first 16 bytes) ---
$buildIdHex = $null
foreach ($ln in (& $readelf -n $SoPath 2>$null)) {
  if ($ln -match 'Build ID:\s*([0-9a-fA-F]+)') { $buildIdHex = $matches[1]; break }
}
if (-not $buildIdHex) { throw "No .note.gnu.build-id in $SoPath. Link with --build-id=sha1." }
if ($buildIdHex.Length -lt 32) { throw "build-id too short ($($buildIdHex.Length/2) bytes); need >=16. Use --build-id=sha1." }
$buildId = New-Object byte[] 16
for ($i=0; $i -lt 16; $i++) { $buildId[$i] = [Convert]::ToByte($buildIdHex.Substring($i*2,2),16) }

# --- function symbols from .symtab (addr, size, mangled name) ---
Write-Host "Reading .symtab via llvm-nm ..."
$entries = New-Object System.Collections.Generic.List[object]
$re = [regex]'^([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+([tTwW])\s+(\S.*)$'
foreach ($ln in (& $nm --defined-only --print-size --numeric-sort $SoPath 2>$null)) {
  $m = $re.Match($ln)
  if (-not $m.Success) { continue }
  $name = $m.Groups[4].Value
  if ($name[0] -eq '.' -or $name[0] -eq '$') { continue }
  $entries.Add([pscustomobject]@{
    Addr = [Convert]::ToUInt64($m.Groups[1].Value,16)
    Size = [Convert]::ToUInt32($m.Groups[2].Value,16)
    Name = $name
    File = ''
  })
}
# numeric-sort already orders by addr; drop duplicate addresses (keep first)
$dedup = New-Object System.Collections.Generic.List[object]
$lastAddr = [UInt64]::MaxValue
foreach ($e in $entries) { if ($e.Addr -ne $lastAddr) { $dedup.Add($e); $lastAddr = $e.Addr } }
$entries = $dedup
if ($entries.Count -eq 0) { throw "No function symbols found." }
Write-Host ("Function symbols: {0}" -f $entries.Count)

# --- source file per function (DWARF line info via llvm-symbolizer, same order) ---
Write-Host "Resolving source files via llvm-symbolizer ..."
$addrInputs = $entries | ForEach-Object { '0x' + $_.Addr.ToString('x') }
$fileLines = $addrInputs | & $symbol --obj=$SoPath --output-style=GNU --functions=none 2>$null
$withFile = 0
for ($i = 0; $i -lt $entries.Count -and $i -lt $fileLines.Count; $i++) {
  $f = ($fileLines[$i] -split ':')[0] -replace '^\./',''
  if ($f -and $f -ne '??') { $entries[$i].File = [System.IO.Path]::GetFileName($f); $withFile++ }
}
Write-Host ("With source file: {0} ({1:P0})" -f $withFile, ($withFile / $entries.Count))

# --- string tables (dedup names + files) ---
function Build-StrTab([System.Collections.Generic.List[object]]$items, [string]$prop) {
  $buf = New-Object System.IO.MemoryStream
  $off = @{ '' = 0 }
  $buf.WriteByte(0)  # offset 0 = empty string (used for "no file")
  foreach ($e in $items) {
    $v = $e.$prop
    if (-not $off.ContainsKey($v)) {
      $off[$v] = [int]$buf.Position
      $bytes = [System.Text.Encoding]::ASCII.GetBytes($v)
      $buf.Write($bytes, 0, $bytes.Length); $buf.WriteByte(0)
    }
  }
  return @{ Bytes = $buf.ToArray(); Off = $off }
}
$str  = Build-StrTab $entries 'Name'
$file = Build-StrTab $entries 'File'

# --- assemble file (v2) ---
$count       = $entries.Count
$headerSize  = 48
$entriesSize = $count * 20
$strTabOff   = $headerSize + $entriesSize
$fileTabOff  = $strTabOff + $str.Bytes.Length
$totalSize   = $fileTabOff + $file.Bytes.Length

$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)
$bw.Write([UInt32]0x59534F47)     # 'GOSY'
$bw.Write([UInt32]0x00020000)     # version 2
$bw.Write([UInt32]$totalSize)
$bw.Write([UInt32]$count)
$bw.Write($buildId, 0, 16)
$bw.Write([UInt32]$strTabOff)
$bw.Write([UInt32]$str.Bytes.Length)
$bw.Write([UInt32]$fileTabOff)
$bw.Write([UInt32]$file.Bytes.Length)
foreach ($e in $entries) {
  $bw.Write([UInt64]$e.Addr)
  $bw.Write([UInt32]$e.Size)
  $bw.Write([UInt32]$str.Off[$e.Name])
  $bw.Write([UInt32]$file.Off[$e.File])
}
$bw.Write($str.Bytes, 0, $str.Bytes.Length)
$bw.Write($file.Bytes, 0, $file.Bytes.Length)
$bw.Flush()
[System.IO.File]::WriteAllBytes($OutPath, $ms.ToArray())
$bw.Dispose(); $ms.Dispose()

Write-Host ("Wrote {0}  ({1:N1} MB, {2} symbols, {3} files, build-id {4})" -f `
  $OutPath, ((Get-Item $OutPath).Length/1MB), $count, ($file.Off.Count - 1), ($buildIdHex.Substring(0,16)))
