# Builds a ReFS volume holding known data, in an expandable VHDX, for qnxprobe's ReFS reader.
#
# Run in the Windows 11 VM from an administrator PowerShell (Windows PowerShell 5.1 is fine):
#   powershell -ExecutionPolicy Bypass -File "\\Mac\Home\Downloads\qnxprobe-fs-2026-10-15\wt\refs\tools\make_refs_fixtures.ps1"
#
# Windows 11 formats ReFS only as a Dev Drive, whose minimum size is 50 GB. The VHDX is
# expandable, so it takes only the space written. Results land in -OutDir (default: the
# fs-fixtures folder on the Mac share, in refs-rich\):
#   refs-rich.vhdx        the volume, detached
#   listing.tsv           every entry: path, kind, size, allocation, links, attributes, the
#                         four FILETIMEs (raw 100 ns counts), the 128-bit file id, link target
#   streams.tsv           every named stream: path, stream, length, sha256
#   sha256.txt            sha256 of every regular file's unnamed stream
#   deleted.txt           the paths that were created and then deleted
#   refs-rich-first-detach.vhdx  the same volume after the first detach, before it was
#                         attached again: shows whether that detach alone reached a checkpoint
#   extents.txt           fsutil's extents and layout for the large, fragmented and sparse files
#   make_refs_fixtures.log  the transcript, with fsutil fsinfo refsinfo
#
# The first fixture (make-refs.ps1) was detached seconds after its files were written, and its
# newest checkpoint predates them: the files are only in the metadata log, which Windows
# replays when it next mounts the volume. This script flushes, waits, detaches, attaches the
# volume again (a mount replays the log and checkpoints), waits again and detaches, so the
# files reach a checkpoint. The waits are generous on purpose; nothing documents the interval.
# On the run of 15 October 2026 the first detach, after a flush and a 120 s wait, had already
# reached a checkpoint holding every file (refs-rich-first-detach.vhdx reads the same).
#
# The script is ASCII only, so Windows PowerShell 5.1 reads it the same whatever its encoding
# guess. Non-ASCII names are built from code points.

param([string]$OutDir = '\\Mac\Home\Downloads\fs-fixtures-2026-10-15\refs-rich',
      [int]$ManyFiles = 2500,
      [int]$WaitSeconds = 120)

$ErrorActionPreference = 'Stop'
$work = 'C:\fsfix-rich'
$vhd = Join-Path $work 'refs-rich.vhdx'
New-Item -ItemType Directory -Force $OutDir | Out-Null
New-Item -ItemType Directory -Force $work | Out-Null
$log = Join-Path $OutDir 'make_refs_fixtures.log'
Start-Transcript -Path $log -Force | Out-Null

function Diskpart($name, $text) {
    $f = Join-Path $work $name
    $text | Set-Content -Path $f -Encoding ascii
    # diskpart.exe, not diskpart: PowerShell finds this function first and would call itself
    diskpart.exe /s $f
    if ($LASTEXITCODE -ne 0) { throw "diskpart $name failed ($LASTEXITCODE)" }
}
function Name([int[]]$cps) { ($cps | ForEach-Object { [char]::ConvertFromUtf32($_) }) -join '' }
function RandomBytes([int]$size, [int]$seed) { $r = New-Object System.Random($seed); $b = New-Object byte[] $size; $r.NextBytes($b); return ,$b }
function TextBytes([int]$size, [string]$tag) {
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    while ($sb.Length -lt $size) { [void]$sb.Append(('{0} line {1:D6}: known data written by Windows for qnxprobe.' -f $tag, $i)); [void]$sb.Append("`r`n"); $i++ }
    return ,([System.Text.Encoding]::ASCII.GetBytes($sb.ToString().Substring(0, $size)))
}
function FromFt([long]$v) { [DateTime]::FromFileTimeUtc($v) }

$info = @"
using System; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public static class RefsFix {
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sec, uint disposition, uint flags, IntPtr template);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool GetFileInformationByHandleEx(SafeFileHandle h, int cls, byte[] buf, uint size);
  // FILE_READ_ATTRIBUTES only, with FILE_FLAG_BACKUP_SEMANTICS (directories) and
  // FILE_FLAG_OPEN_REPARSE_POINT (the link itself, not its target). Opening for attributes
  // does not read the file, so it does not move its last access time.
  public static string Info(string path) {
    using (var h = CreateFileW(@"\\?\" + path, 0x80, 7, IntPtr.Zero, 3, 0x02000000 | 0x00200000, IntPtr.Zero)) {
      if (h.IsInvalid) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), path);
      var b = new byte[40]; var s = new byte[24]; var id = new byte[24];
      if (!GetFileInformationByHandleEx(h, 0, b, 40)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "FileBasicInfo " + path);
      if (!GetFileInformationByHandleEx(h, 1, s, 24)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "FileStandardInfo " + path);
      string fid = "";
      if (GetFileInformationByHandleEx(h, 0x12, id, 24)) { fid = BitConverter.ToString(id, 8, 16).Replace("-", "").ToLower(); }
      return String.Join("\t", new string[] {
        BitConverter.ToInt64(s, 8).ToString(), BitConverter.ToInt64(s, 0).ToString(),
        BitConverter.ToUInt32(s, 16).ToString(), "0x" + BitConverter.ToUInt32(b, 32).ToString("x"),
        BitConverter.ToInt64(b, 0).ToString(), BitConverter.ToInt64(b, 16).ToString(),
        BitConverter.ToInt64(b, 24).ToString(), BitConverter.ToInt64(b, 8).ToString(), fid });
    }
  }
}
"@
Add-Type -TypeDefinition $info

try {
    "Windows build: $([Environment]::OSVersion.Version)"
    if (Test-Path $vhd) { Remove-Item $vhd -Force }
    Diskpart 'dp-create.txt' @"
create vdisk file="$vhd" maximum=51200 type=expandable
select vdisk file="$vhd"
attach vdisk
convert gpt
create partition primary
assign letter=R
"@
    Format-Volume -DriveLetter R -DevDrive -NewFileSystemLabel 'REFSRICH' -Confirm:$false -Force
    (Get-Volume -DriveLetter R) | Format-List DriveLetter, FileSystem, FileSystemLabel, Size
    fsutil fsinfo refsinfo R:
    fsutil behavior query disablelastaccess

    # ---- small files of chosen sizes: inline (resident) storage versus clusters ----
    try {
        New-Item -ItemType Directory -Force 'R:\sizes' | Out-Null
        foreach ($n in 0, 1, 100, 1000, 3000, 4095, 4096, 4097, 10000, 65537) {
            [IO.File]::WriteAllBytes("R:\sizes\size_$n.bin", (TextBytes $n "size $n"))
        }
    } catch { "STEP FAILED (small files of chosen sizes): $_" }

    # ---- one directory with many entries, to split its B+ tree over several pages ----
    try {
        New-Item -ItemType Directory -Force 'R:\many' | Out-Null
        for ($i = 0; $i -lt $ManyFiles; $i++) {
            [IO.File]::WriteAllBytes(('R:\many\entry_{0:D5}.txt' -f $i), [System.Text.Encoding]::ASCII.GetBytes("entry $i of the many directory`r`n"))
        }
        for ($i = 0; $i -lt 40; $i++) { New-Item -ItemType Directory -Force ('R:\many\sub_{0:D3}' -f $i) | Out-Null }
    } catch { "STEP FAILED (one directory with many entries): $_" }

    # ---- names: long, non-ASCII, a surrogate pair, mixed case ----
    try {
        New-Item -ItemType Directory -Force 'R:\names' | Out-Null
        $long = ('L' * 180) + ('_long_name_' * 4) + 'end.txt'           # 231 characters
        [IO.File]::WriteAllBytes("R:\names\$long", (TextBytes 77 'long'))
        $jp = (Name @(0x65E5, 0x672C, 0x8A9E)) + '.txt'                    # Japanese
        [IO.File]::WriteAllBytes("R:\names\$jp", (TextBytes 33 'jp'))
        $gr = 'greek_' + (Name @(0x03B1, 0x03B2, 0x03B3, 0x0394)) + '.txt'
        [IO.File]::WriteAllBytes("R:\names\$gr", (TextBytes 44 'greek'))
        $emo = 'smile_' + (Name @(0x1F600)) + '.txt'                         # outside the BMP
        [IO.File]::WriteAllBytes("R:\names\$emo", (TextBytes 55 'emoji'))
        $acc = 'caf' + (Name @(0xE9)) + ' r' + (Name @(0xE9)) + 'sum' + (Name @(0xE9)) + '.txt'
        [IO.File]::WriteAllBytes("R:\names\$acc", (TextBytes 66 'accent'))
        [IO.File]::WriteAllBytes('R:\names\MiXeD CaSe With Spaces.TXT', (TextBytes 88 'case'))
        New-Item -ItemType Directory -Force ('R:\names\dir_' + (Name @(0x00FC, 0x00DF))) | Out-Null
        [IO.File]::WriteAllBytes(('R:\names\dir_' + (Name @(0x00FC, 0x00DF)) + '\inner.txt'), (TextBytes 99 'inner'))
    } catch { "STEP FAILED (names): $_" }

    # ---- nested depth ----
    try {
        $p = 'R:\deep'
        for ($d = 1; $d -le 12; $d++) { $p = Join-Path $p ('level{0:D2}' -f $d) }
        New-Item -ItemType Directory -Force $p | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $p 'bottom.txt'), (TextBytes 123 'bottom'))
    } catch { "STEP FAILED (nested depth): $_" }

    # ---- a large file over many clusters, and two files grown in alternation ----
    try {
        New-Item -ItemType Directory -Force 'R:\big' | Out-Null
        $fs = [IO.File]::Open('R:\big\large_48MiB.bin', 'CreateNew', 'Write')
        $chunk = RandomBytes 1048576 2026
        for ($i = 0; $i -lt 48; $i++) { [BitConverter]::GetBytes([long]$i).CopyTo($chunk, 0); $fs.Write($chunk, 0, $chunk.Length) }
        $fs.Close()
        $fa = [IO.File]::Open('R:\big\frag_a.bin', 'CreateNew', 'Write')
        $fb = [IO.File]::Open('R:\big\frag_b.bin', 'CreateNew', 'Write')
        for ($i = 0; $i -lt 24; $i++) {
            $ca = RandomBytes 262144 (1000 + $i); $cb = RandomBytes 262144 (2000 + $i)
            $fa.Write($ca, 0, $ca.Length); $fa.Flush($true)
            $fb.Write($cb, 0, $cb.Length); $fb.Flush($true)
        }
        $fa.Close(); $fb.Close()
        $z = New-Object byte[] 300000
        [IO.File]::WriteAllBytes('R:\big\zeros_300000.bin', $z)
    } catch { "STEP FAILED (a large file over many clusters): $_" }

    # ---- sparse files (fsutil sparse) ----
    try {
        New-Item -ItemType Directory -Force 'R:\sparse' | Out-Null
        [IO.File]::WriteAllBytes('R:\sparse\punched.bin', (RandomBytes 4194304 77))
        fsutil sparse setflag R:\sparse\punched.bin
        fsutil sparse setrange R:\sparse\punched.bin 1048576 2097152
        [IO.File]::WriteAllBytes('R:\sparse\grown.bin', (New-Object byte[] 0))
        fsutil sparse setflag R:\sparse\grown.bin
        $fs = [IO.File]::Open('R:\sparse\grown.bin', 'Open', 'ReadWrite')
        $blk = RandomBytes 65536 5
        $fs.Position = 0; $fs.Write($blk, 0, $blk.Length)
        $fs.Position = 6291456; $fs.Write($blk, 0, $blk.Length)
        $fs.SetLength(8388608); $fs.Close()
        [IO.File]::WriteAllBytes('R:\sparse\all_hole.bin', (New-Object byte[] 0))
        fsutil sparse setflag R:\sparse\all_hole.bin
        $fs = [IO.File]::Open('R:\sparse\all_hole.bin', 'Open', 'ReadWrite'); $fs.SetLength(3145728); $fs.Close()
    } catch { "STEP FAILED (sparse files (fsutil sparse)): $_" }

    # ---- alternate data streams ----
    try {
        New-Item -ItemType Directory -Force 'R:\ads' | Out-Null
        [IO.File]::WriteAllBytes('R:\ads\host.txt', (TextBytes 500 'host'))
        Set-Content -Path 'R:\ads\host.txt' -Stream 'small' -Value 'a small alternate stream' -Encoding ascii
        $big = TextBytes 150000 'big stream'
        Set-Content -Path 'R:\ads\host.txt' -Stream 'big' -Value $big -Encoding Byte
        Set-Content -Path 'R:\ads\host.txt' -Stream 'Zone.Identifier' -Value "[ZoneTransfer]`r`nZoneId=3" -Encoding ascii
        New-Item -ItemType Directory -Force 'R:\ads\dir_with_stream' | Out-Null
        try { Set-Content -Path 'R:\ads\dir_with_stream' -Stream 'onadir' -Value 'a stream on a directory' -Encoding ascii }
        catch { "stream on a directory not written: $_" }
    } catch { "STEP FAILED (alternate data streams): $_" }

    # ---- hard links, symbolic links, a junction ----
    try {
        New-Item -ItemType Directory -Force 'R:\links' | Out-Null
        New-Item -ItemType Directory -Force 'R:\links\other' | Out-Null
        [IO.File]::WriteAllBytes('R:\links\target.txt', (TextBytes 4321 'link target'))
        cmd /c mklink /h R:\links\hard_same_dir.txt R:\links\target.txt
        cmd /c mklink /h R:\links\other\hard_other_dir.txt R:\links\target.txt
        cmd /c mklink R:\links\sym_relative.txt target.txt
        cmd /c mklink R:\links\sym_absolute.txt R:\links\target.txt
        cmd /c mklink /d R:\links\sym_dir other
        cmd /c mklink /j R:\links\junction_dir R:\links\other
        cmd /c mklink R:\links\sym_dangling.txt does_not_exist.txt
    } catch { "STEP FAILED (hard links): $_" }

    # ---- moved and renamed ----
    try {
        New-Item -ItemType Directory -Force 'R:\moves\from' | Out-Null
        New-Item -ItemType Directory -Force 'R:\moves\to' | Out-Null
        [IO.File]::WriteAllBytes('R:\moves\from\moved.txt', (TextBytes 222 'moved'))
        [IO.File]::WriteAllBytes('R:\moves\from\renamed_before.txt', (TextBytes 333 'renamed'))
        [IO.File]::WriteAllBytes('R:\moves\from\big_moved.bin', (RandomBytes 200000 9))
        Move-Item 'R:\moves\from\moved.txt' 'R:\moves\to\moved.txt'
        Move-Item 'R:\moves\from\big_moved.bin' 'R:\moves\to\big_moved.bin'
        Rename-Item 'R:\moves\from\renamed_before.txt' 'renamed_after.txt'
        New-Item -ItemType Directory -Force 'R:\moves\from\moved_dir' | Out-Null
        [IO.File]::WriteAllBytes('R:\moves\from\moved_dir\in_moved_dir.txt', (TextBytes 111 'in moved dir'))
        Move-Item 'R:\moves\from\moved_dir' 'R:\moves\to\moved_dir'
    } catch { "STEP FAILED (moved and renamed): $_" }

    # ---- attributes ----
    try {
        New-Item -ItemType Directory -Force 'R:\attrs' | Out-Null
        foreach ($a in 'ReadOnly', 'Hidden', 'System', 'Archive') {
            [IO.File]::WriteAllBytes("R:\attrs\$a.txt", (TextBytes 50 $a))
            Set-ItemProperty "R:\attrs\$a.txt" -Name Attributes -Value $a
        }
    } catch { "STEP FAILED (attributes): $_" }

    # ---- created, then deleted: these must not be listed as live files ----
    try {
        New-Item -ItemType Directory -Force 'R:\deleted\gone_dir' | Out-Null
        $deleted = @()
        for ($i = 0; $i -lt 20; $i++) {
            $f = ('R:\deleted\file_{0:D2}.txt' -f $i)
            if ($i % 2) { [IO.File]::WriteAllBytes($f, (TextBytes (100 * $i) "deleted $i")) } else { [IO.File]::WriteAllBytes($f, (RandomBytes (20000 + $i) $i)) }
        }
        [IO.File]::WriteAllBytes('R:\deleted\gone_dir\inside.txt', (TextBytes 600 'gone'))
        for ($i = 0; $i -lt 20; $i += 2) { $f = ('R:\deleted\file_{0:D2}.txt' -f $i); Remove-Item $f -Force; $deleted += $f }
        for ($i = 1; $i -lt 20; $i += 4) { $f = ('R:\deleted\file_{0:D2}.txt' -f $i); Remove-Item $f -Force; $deleted += $f }
        Remove-Item 'R:\deleted\gone_dir' -Recurse -Force; $deleted += 'R:\deleted\gone_dir\inside.txt'; $deleted += 'R:\deleted\gone_dir'
        $deleted | ForEach-Object { $_.Substring(3).Replace('\', '/') } | Set-Content -Path (Join-Path $OutDir 'deleted.txt') -Encoding utf8
    } catch { "STEP FAILED (created): $_" }

    # ---- fixed times, set last so later writes in the same folders cannot move them ----
    try {
        New-Item -ItemType Directory -Force 'R:\times' | Out-Null
        [IO.File]::WriteAllBytes('R:\times\fixed.txt', (TextBytes 1234 'fixed times'))
        [IO.File]::WriteAllBytes('R:\times\old.bin', (RandomBytes 50000 11))
        New-Item -ItemType Directory -Force 'R:\times\fixed_dir' | Out-Null
        $c = FromFt 126257463067891234   # 2001-02-03 04:05:06.7891234 UTC
        $m = FromFt 130000000001234567
        $a = FromFt 133000000009876543
        foreach ($t in 'R:\times\fixed.txt', 'R:\times\fixed_dir') {
            $it = Get-Item -Force $t
            $it.CreationTimeUtc = $c; $it.LastWriteTimeUtc = $m; $it.LastAccessTimeUtc = $a
        }
        $it = Get-Item -Force 'R:\times\old.bin'
        $it.CreationTimeUtc = FromFt 116444736000000000; $it.LastWriteTimeUtc = FromFt 116444736010000000; $it.LastAccessTimeUtc = FromFt 159000000000000000
    } catch { "STEP FAILED (fixed times): $_" }

    # ---- hashes, then the listing (a read can move an access time, so the listing comes last) ----
    $sha = New-Object System.Collections.Generic.List[string]
    $streams = New-Object System.Collections.Generic.List[string]
    $rows = New-Object System.Collections.Generic.List[string]
    $rows.Add("path`tkind`tsize`tallocated`tlinks`tattributes`tcreated`tmodified`tchanged`taccessed`tfile_id`ttarget")
    $streams.Add("path`tstream`tlength`tsha256")
    function Walk($dir) {
        foreach ($it in (Get-ChildItem -LiteralPath $dir -Force | Sort-Object Name)) {
            $rel = $it.FullName.Substring(3).Replace('\', '/')
            if ($rel -eq 'System Volume Information') { continue }
            $isLink = [bool]($it.Attributes -band [IO.FileAttributes]::ReparsePoint)
            $isDir = $it.PSIsContainer
            $kind = if ($isLink) { if ($isDir) { 'dirlink' } else { 'filelink' } } elseif ($isDir) { 'dir' } else { 'file' }
            $target = if ($isLink) { (@($it.Target) -join '|') } else { '' }
            if ($kind -eq 'file') {
                $sha.Add(('{0}  {1}' -f (Get-FileHash -LiteralPath $it.FullName -Algorithm SHA256).Hash.ToLower(), $rel))
            }
            if (-not $isLink) {
                foreach ($st in (Get-Item -LiteralPath $it.FullName -Stream * -Force -ErrorAction SilentlyContinue)) {
                    if ($st.Stream -eq ':$DATA') { continue }
                    $bytes = Get-Content -LiteralPath $it.FullName -Stream $st.Stream -Encoding Byte -Raw
                    if ($null -eq $bytes) { $bytes = New-Object byte[] 0 }
                    $h = (([Security.Cryptography.SHA256]::Create().ComputeHash([byte[]]$bytes)) | ForEach-Object { $_.ToString('x2') }) -join ''
                    $streams.Add(("{0}`t{1}`t{2}`t{3}" -f $rel, $st.Stream, $st.Length, $h))
                }
            }
            $script:pending += , @($rel, $kind, $it.FullName, $target)
            if ($isDir -and -not $isLink) { Walk $it.FullName }
        }
    }
    $script:pending = @()
    Walk 'R:\'
    foreach ($p in $script:pending) {
        $rows.Add(("{0}`t{1}`t{2}`t{3}" -f $p[0], $p[1], [RefsFix]::Info($p[2]), $p[3]))
    }
    $rows | Set-Content -Path (Join-Path $OutDir 'listing.tsv') -Encoding utf8
    ($sha | Sort-Object { $_.Substring(66) }) | Set-Content -Path (Join-Path $OutDir 'sha256.txt') -Encoding utf8
    $streams | Set-Content -Path (Join-Path $OutDir 'streams.tsv') -Encoding utf8

    $ext = New-Object System.Collections.Generic.List[string]
    foreach ($f in 'R:\big\large_48MiB.bin', 'R:\big\frag_a.bin', 'R:\big\frag_b.bin', 'R:\sparse\punched.bin', 'R:\sparse\grown.bin', 'R:\sparse\all_hole.bin', 'R:\ads\host.txt', 'R:\links\target.txt', 'R:\moves\to\big_moved.bin', 'R:\sizes\size_4097.bin', 'R:\sizes\size_100.bin') {
        $ext.Add("==== $f"); $ext.Add(((fsutil file queryextents $f) -join "`r`n")); $ext.Add(((fsutil file layout $f) -join "`r`n"))
    }
    $ext | Set-Content -Path (Join-Path $OutDir 'extents.txt') -Encoding utf8
    fsutil fsinfo refsinfo R:

    # ---- get the files into a checkpoint ----
    Write-VolumeCache -DriveLetter R
    "waiting $WaitSeconds s before the first detach"
    Start-Sleep -Seconds $WaitSeconds
    Write-VolumeCache -DriveLetter R
    Diskpart 'dp-detach1.txt' @"
select vdisk file="$vhd"
detach vdisk
"@
    Copy-Item $vhd (Join-Path $OutDir 'refs-rich-first-detach.vhdx') -Force
    Diskpart 'dp-attach.txt' @"
select vdisk file="$vhd"
attach vdisk
"@
    "attached again; waiting $WaitSeconds s"
    Start-Sleep -Seconds $WaitSeconds
    Get-Volume | Where-Object { $_.FileSystemLabel -eq 'REFSRICH' } | Format-List DriveLetter, FileSystem, FileSystemLabel, HealthStatus
    $v = Get-Volume | Where-Object { $_.FileSystemLabel -eq 'REFSRICH' -and $_.DriveLetter }
    if ($v) { Write-VolumeCache -DriveLetter $v.DriveLetter; Start-Sleep -Seconds 10 }
    Diskpart 'dp-detach2.txt' @"
select vdisk file="$vhd"
detach vdisk
"@
    Copy-Item $vhd (Join-Path $OutDir 'refs-rich.vhdx') -Force
    "vhdx sha256 " + (Get-FileHash -Algorithm SHA256 $vhd).Hash.ToLower()
    "DONE: refs-rich.vhdx and its listing are in $OutDir"
}
catch {
    "FAILED: $_"
    $_.ScriptStackTrace
}
finally {
    Stop-Transcript | Out-Null
}
