#requires -Version 5
<#
.SYNOPSIS
  Merge per-architecture `.gol` line-number files into one universal ('GOLF')
  container, for a macOS universal (x86_64 + arm64) binary.

.DESCRIPTION
  A macOS universal binary keeps a distinct LC_UUID per arch slice, and each
  slice has its own VM addresses -- so a single single-arch `.gol` can only map
  one slice. The crash reporter's reader (Crash.LineNumbers.pas) rejects a
  wrong-arch `.gol` outright (ExecutableIDMismatch -> no line numbers), it does
  not approximate across arches.

  This muxer takes two single-arch `.gol` blocks (produced by LNG on the per-arch
  thin builds) and bundles them into one container the reader resolves at runtime:
  it sniffs 'GOLF', walks the directory, and picks the slice whose embedded UUID
  == the running image's LC_UUID (which automatically selects the right
  architecture). The result is exact source lines on BOTH arches from a single
  file shipped next to (or inside) the universal binary.

  For a one-shot "two binaries -> universal .gol" run, use build-universal-gol.ps1
  in this directory, which runs LNG on each binary and then calls this muxer.

  On-disk layout (all integers little-endian; mirrors the packed records
  TLineNumberFatHeader / TLineNumberFatEntry in Crash.LineNumbers.pas):

    FatHeader (12 bytes)
      UInt32 Signature   'GOLF' = 0x464C4F47
      UInt32 Version     0x00010000
      UInt32 Count       number of slices (2 here)
    FatEntry x Count (36 bytes each)
      UInt32 CpuType     Mach-O CPU_TYPE_* (informational; match is by ID)
      Byte[16] ID        slice LC_UUID -- the runtime match key
      UInt64 Offset      file offset of the embedded 'GOLN' block
      UInt64 Size        size of that block (== block's own header Size field)
    <embedded 'GOLN' blocks, verbatim>

  Each input `.gol` is itself a 'GOLN' block; its embedded UUID is read straight
  from offset 16 of the block header, so no GUID parsing is needed -- the 16 raw
  bytes are copied through and compared byte-for-byte against the runtime UUID.

.PARAMETER Osx64Gol
  Path to the x86_64 (OSX64) single-arch `.gol`.

.PARAMETER OsxArmGol
  Path to the arm64 (OSXARM64) single-arch `.gol`.

.PARAMETER OutFile
  Path to write the universal container `.gol`.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File mux-gol-universal.ps1 `
    -Osx64Gol  out\x86_64\MyApp.gol `
    -OsxArmGol out\arm64\MyApp.gol  `
    -OutFile   out\MyApp.gol
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)] [string] $Osx64Gol,
  [Parameter(Mandatory=$true)] [string] $OsxArmGol,
  [Parameter(Mandatory=$true)] [string] $OutFile
)

$ErrorActionPreference = 'Stop'

# Must match Crash.LineNumbers.pas.
$SIG_BLOCK = [uint32]0x4E4C4F47   # 'GOLN' single-arch block
$SIG_FAT   = [uint32]0x464C4F47   # 'GOLF' universal container
$VER_FAT   = [uint32]0x00010000
$CPU_X8664 = [uint32]0x01000007   # Mach-O CPU_TYPE_X86_64
$CPU_ARM64 = [uint32]0x0100000C   # Mach-O CPU_TYPE_ARM64
$BLOCK_HEADER_SIZE = 44           # SizeOf(TLineNumberHeader): 4+4+4+4 + 16 (GUID) + 8 + 4

function Read-GolBlock([string]$path, [uint32]$cpuType) {
  if (-not (Test-Path -LiteralPath $path)) { throw "[mux-gol] input not found: $path" }
  $b = [IO.File]::ReadAllBytes($path)
  if ($b.Length -lt $BLOCK_HEADER_SIZE) { throw "[mux-gol] too small to be a .gol ($($b.Length) bytes): $path" }
  $sig = [BitConverter]::ToUInt32($b, 0)
  if ($sig -ne $SIG_BLOCK) { throw ("[mux-gol] bad signature 0x{0:X8} (expected 'GOLN'): {1}" -f $sig, $path) }
  $size = [BitConverter]::ToUInt32($b, 8)
  if ($size -ne $b.Length) { throw "[mux-gol] header Size ($size) != file length ($($b.Length)): $path" }
  $id = New-Object byte[] 16
  [Array]::Copy($b, 16, $id, 0, 16)        # embedded LC_UUID (TLineNumberHeader.ID @ offset 16)
  if (($id | Where-Object { $_ -ne 0 }).Count -eq 0) { throw "[mux-gol] empty (all-zero) UUID in: $path" }
  [pscustomobject]@{ Bytes=$b; Id=$id; CpuType=$cpuType; Path=$path }
}

$blocks = @(
  (Read-GolBlock $Osx64Gol  $CPU_X8664),
  (Read-GolBlock $OsxArmGol $CPU_ARM64)
)

# Reject a container where both slices share a UUID (would mean the same thin
# binary was passed twice -- the runtime match would be ambiguous/wrong).
if ([Linq.Enumerable]::SequenceEqual([byte[]]$blocks[0].Id, [byte[]]$blocks[1].Id)) {
  throw "[mux-gol] both inputs carry the same UUID -- did you pass the same arch twice?"
}

$headerSize = 12
$entrySize  = 36
$dirSize    = $headerSize + ($blocks.Count * $entrySize)

$ms = New-Object IO.MemoryStream
$bw = New-Object IO.BinaryWriter($ms)
try {
  # FatHeader
  $bw.Write([uint32]$SIG_FAT)
  $bw.Write([uint32]$VER_FAT)
  $bw.Write([uint32]$blocks.Count)

  # Directory entries. Blob offsets start right after the directory.
  $off = [uint64]$dirSize
  foreach ($blk in $blocks) {
    $bw.Write([uint32]$blk.CpuType)
    $bw.Write([byte[]]$blk.Id)              # 16 raw GUID bytes
    $bw.Write([uint64]$off)
    $bw.Write([uint64]$blk.Bytes.Length)
    $off += [uint64]$blk.Bytes.Length
  }

  # Embedded blocks, verbatim, in the same order as the directory.
  foreach ($blk in $blocks) { $bw.Write([byte[]]$blk.Bytes) }
  $bw.Flush()

  $outDir = Split-Path -Parent $OutFile
  if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Force $outDir | Out-Null
  }
  [IO.File]::WriteAllBytes($OutFile, $ms.ToArray())
}
finally {
  $bw.Dispose()
  $ms.Dispose()
}

$total = (Get-Item -LiteralPath $OutFile).Length
Write-Host ("[mux-gol] wrote {0} ({1:N0} bytes; {2} slices)" -f $OutFile, $total, $blocks.Count)
foreach ($blk in $blocks) {
  $uuid = ($blk.Id | ForEach-Object { $_.ToString('x2') }) -join ''
  Write-Host ("[mux-gol]   cpu=0x{0:X8} uuid={1} block={2:N0}B  <- {3}" -f $blk.CpuType, $uuid, $blk.Bytes.Length, $blk.Path)
}
exit 0
