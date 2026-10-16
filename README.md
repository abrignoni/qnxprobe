# qnxprobe

Read QNX6, QNX4, ETFS, EFS, ext2/3/4, Btrfs, F2FS, FAT32, FAT16, FAT12, exFAT, NTFS, ReFS, HFS+, APFS and XFS filesystems,
the Linux flash filesystems SquashFS, JFFS2, UBI/UBIFS and YAFFS1/YAFFS2, and QNX IFS boot
images, out of raw disk images and flash dumps, including the logical volumes of an
LVM2 physical volume (linear, striped, RAID1 and RAID4/5/6/10) and Linux md RAID
arrays assembled from their member images (see "RAID" below): identify each by its own
on-disk structure rather than trusting a partition type byte, list, and extract to a
zip with a provenance manifest. No mounting, no admin rights, standard library only.

QNX is what a lot of vehicle infotainment runs on, and it is the reason this tool
exists and keeps its name. When a head unit image lands on your desk, the first
question is what filesystems are in it, and the usual tools do not answer it:
`blkid`, `file` and The Sleuth Kit have no QNX6 support, and the partition table
will happily call a qnx6 volume `0x83 Linux`. This reads the superblock and tells
you what is actually there, then lists and extracts what it found. It reads
ext2/3/4 the same way, so a mixed vehicle landscape (Ford runs QNX, BMW runs
Linux) is one tool rather than two.

It also reads QNX's two flash filesystems, ETFS and EFS, the kind a head unit
keeps its manufacturing and configuration data on. Both are typically imaged bare
with no partition table, so they arrive as the whole image and are read at LBA 0.
ETFS has no superblock at all, so it is rebuilt by replaying the transaction
records in each page's spare area; EFS is found by its `QSSL_F3S` boot record,
in either byte order, and since 1.60 wherever its partitions sit in a raw flash
image, with the deleted and superseded data they still hold (see "QNX EFS in a
raw flash image" below).
Their byte layouts are transcribed from the Kaitai specs in
[NetherlandsForensicInstitute/qnxmount](https://github.com/NetherlandsForensicInstitute/qnxmount)
(Apache-2.0), whose ETFS spec is itself sourced to QNX's `fs/etfs.h` and whose EFS
spec to `fs/f3s_spec.h`, and both readers are validated by round-trip against
qnxmount's own committed test images.

It also reads QNX4, the filesystem of QNX 4 systems, still met on older embedded
and industrial gear. The MBR type bytes `0x4d/0x4e/0x4f` announce a QNX4
partition but never prove one; this reads the actual structure, the `/` root
inode that doubles as the `0x002f` magic, and walks it the way the Linux
kernel's own read-only `fs/qnx4` driver does, inline 64-byte inode entries,
long names resolved through `.inodes` links, and multi-extent files through
their `IamXblk` chains. The reader is validated by round-trip against that
kernel driver on a populated fixture; see
[Where the constants come from](#where-the-constants-come-from).

It also reads QNX IFS boot images, the compressed boot filesystem behind a head
unit's `ifs_*` partitions, holding the kernel, the boot drivers and the startup
scripts. The image filesystem is UCL-compressed, which is not in the standard
library, so a small pure-Python UCL NRV2B decoder is carried in the file rather
than taken as a dependency: the tool still installs nothing. The format and the
decompression are sourced from QNX's own `dumpifs` and `sys/image.h`, and the
decoder is proven byte for byte against the three Ford Sync G4 IFS volumes (each
decompresses to exactly the size its header records and the image checksum
balances). See [What it does not do](#what-it-does-not-do) for the compression
methods it recognises but does not yet read.

It also opens BitLocker volumes with their password, recovery password or startup key
(`.BEK`) file, and reads the NTFS, FAT32 or exFAT inside them; without a key it names
the volume, its protectors and what would open it. See [BitLocker](#bitlocker).

It also opens an APFS volume macOS encrypted in software (an external drive, or a Mac
without a T2 chip or Apple silicon) with its password or personal recovery key; without
one it names the volume, says what would open it and gives the passphrase hint the volume
stores. See [Opening an encrypted APFS volume](#opening-an-encrypted-apfs-volume).

It also reads the filesystems embedded Linux keeps on flash: SquashFS, JFFS2, UBI and the
UBIFS inside it, and YAFFS1 and YAFFS2. They are what routers, cameras, drones and Linux
head units tend to carry, often as a chip dump with no partition table and sometimes with
the NAND spare bytes still between the pages. Each is found by its own headers inside such
a dump and read the way the Linux kernel (for YAFFS, Aleph One's own code) reads it. LZO
and LZ4, which the standard library lacks, are carried as small pure-Python decoders. See
[Linux flash filesystems](#linux-flash-filesystems). A U-Boot environment or a Belkin
libnvram store found on the chip is handed over as a one-file volume holding its bytes (see
[Raw flash dumps and NAND spare bytes](#raw-flash-dumps-and-nand-spare-bytes)).

It also reads XFS, the default filesystem of Red Hat Enterprise Linux and common on Linux
servers and storage appliances: version 4 and version 5 (with CRCs), every directory
format and both forms of extent map. See [XFS](#xfs).

One file, Python 3 standard library only. Nothing to install, no admin rights, and
it never writes to the image. A second, optional file, `qnxprobe_gui.py`, puts a
window over it (see [The window](#the-window)); it is standard library too.

## Requirements

Python 3, and nothing else. No packages, no install step.

Reading zstd-compressed SquashFS, UBIFS or Btrfs needs Python 3.14 or later, whose standard
library adds `compression.zstd`. On an older Python those files are named and reported as
not read (see [What it does not do](#what-it-does-not-do)). The
[executables](#executables) carry their own Python 3.14, so they read zstd wherever they
run; those published with v1.31 and v1.32 were built on 3.12 and do not.

Run and self-tested on 3.10, 3.12 and 3.14. It uses no syntax newer than 3.8 and
parses cleanly under 3.8 and 3.9, but it has not been run there.

## Quick start

```
python3 qnxprobe.py mmcblk0.img            # one image
python3 qnxprobe.py *.img *.bin            # several at once
python3 qnxprobe.py partition2.dd          # a partition already carved out
python3 qnxprobe.py --self-test            # prove it reports both ways
python3 qnxprobe.py --help                 # every option, with sourcing
```

## The window

`qnxprobe_gui.py` is a tkinter front end for people who would rather not use a
terminal. It needs the same Python and nothing else; tkinter ships with the
standard Python installers on macOS and Windows and with the `python3-tk` package
on most Linux distributions.

```
python3 qnxprobe_gui.py                 # open the window
python3 qnxprobe_gui.py mmcblk0.img     # open it with an image already added
```

Add one or more images, set the same options the command line takes, and press
**Run report** or **Extract to zip**. Both run `qnxprobe.py` as a subprocess and
stream its output into the Report pane as it is printed, so the report in the
window is byte for byte the report the command line prints. During an extraction
the progress bar is driven by the tool's own `--progress` stream, with exact file
and byte counts per volume. Cancel stops the subprocess; a zip left behind by a
cancelled run is not a complete extraction and the window says so.

The **Contents** pane browses an image without extracting it. It opens the image
read-only, finds each volume with the same partition-table and superblock code
the report uses, and walks it with the same reader classes the extractor uses.
Directories load when you expand them, and a selected file can be saved out on
its own. The Kind column tells regular files from directories, symlinks and
special entries; only regular files can be saved. Created and Accessed are filled
for NTFS and ReFS, which store all three times as instants; the other readers carry only
Modified, so those two columns stay blank for them. A FAT32 or exFAT file has no
instant at all: its (UTC) columns stay blank and its readings appear in **Recorded
(as stored)**.

The two halves are kept honest against each other by a check you can run on any
image, with no window:

```
python3 qnxprobe_gui.py --check-discovery mmcblk0.img
```

It runs the report, reads back which volumes it named and what it called each
one, and requires the Contents pane's own discovery to name exactly the same
set. It was run on the 12 synthetic self-test images, qnxmount's four reference
images, a Ford Sync G4 eMMC image (9 volumes) and a BMW MGU image (11 volumes)
before this was published, and all agreed. A qnx6 found only by the brute scan
is reported but has no partition to walk, so it appears in the report and not in
the Contents pane, in the window exactly as on the command line.

## Executables

For a machine with no Python, the repository's GitHub Actions workflow
(`.github/workflows/build-executables.yml`) builds both files into standalone
executables with PyInstaller on Python 3.14, `qnxprobe` for the command line and
`qnxprobe_gui` for the window, on six targets: Windows x64 and arm64, macOS on Apple
silicon and Intel, and Linux x64 and arm64. Each build runs the self-test, the discovery
check, a check that the command line executable extracts every file of the zstd SquashFS
fixture with the bytes it was built from, and a window liveness check on its own runner
before it is packaged with
`SHA256SUMS.txt` and a README. The executables are not code signed; the README
inside each archive says what Windows SmartScreen and macOS Gatekeeper will ask.
They are published on the release for a `v*` tag and are otherwise available as
workflow artifacts.

## What a run looks like

```
==============================================================================
synthetic.img
  7,340,032 bytes (7.0 MiB)
==============================================================================
  MBR      valid, 1 entries
    1  type 0xb1  LBA 2,048           4.0 MiB

  2 magic match(es): 2 CONFIRMED, 0 rejected as coincidence

  CONFIRMED qnx6 filesystem on MBR part 1  [little endian]
      2 superblock copies, 2 generations

      ACTIVE   serial 41   at 0x102000
        sb_ctime   2018-03-19 15:00:25 UTC
        sb_atime   2024-04-04 09:27:48 UTC
        version    4.3   blocksize 4,096   flags 0x00000000
        volume     4.0 MiB  (1,020 blocks, 966 free)   <- 99.6% of the 4.0 MiB partition
        inodes     20,000 total, 15,000 free, 5,000 used

      PREVIOUS serial 40   at 0x102e00   (still on disk)
        sb_ctime   2018-03-19 15:00:25 UTC
        sb_atime   2024-04-04 09:27:46 UTC

      WHAT CHANGED between the two generations
        serial       +1   (one commit)
        sb_atime     +2 s   (forward 2 seconds)
        free_blocks  -1  (1 block allocated)
        free_inodes  -1  (1 inode allocated)

  VERDICT: QNX6 filesystem present.
```

That output is from a synthetic image built by the self-test code, so nothing in it
came off a real device.

## Reading the timestamps

This is the part worth getting right, because it is easy to report the wrong thing.

- **`sb_ctime`** is written once, when the filesystem is created. It does not move.
- **`sb_atime`** moves when the filesystem is **committed**, not when a file is read.
  Do not read it as when the device was last used by a person.
- **`serial`** counts commits. It is the better measure of how much a volume has
  been written.

A qnx6 volume carries four superblock copies, and the tool groups them into
generations. The highest serial is the active one; the one below it is the previous
committed state, still on disk. The `WHAT CHANGED` block diffs the two, so you can
see what a single commit did.

## Deciding what to pull first

A head unit runs to tens of gigabytes and most of it is not evidence.

```
python3 qnxprobe.py --triage mmcblk0.img
```

## What an extraction is named, and how to check it

Every volume extracts under a directory named from the partition table, not from
the filesystem:

```
p2_lba65536                MBR primary 2
p6_lba13168672             second logical volume (logicals number from 5, as OSes do)
p3_lba16384_dps_mfg        GPT partition 3, carrying its name
lba0                       no partition table: a whole-disk filesystem or bare region
```

The LBA is the identity. It is a physical fact about the image that any partition
tool reproduces, and two volumes cannot share one, so names cannot collide. A
label is only ever a suffix. An LBA counts the disk's own logical sectors: 512
bytes on most disks, and 4096 on a disk whose GPT header sits at byte 4096, as on
4Kn drives and UFS LUN images, so `p1_lba300` on such a disk begins at byte
1,228,800.

The zip also carries `volumes.json`: per volume, the LBA and the sector size it
counts in (`sector_bytes`), byte offset, partition size, filesystem type, the recorded volume id or UUID, and what was extracted,
including `short` (files whose blocks reach past the end of the image), `failed`
(files that could not be read, which are not in the zip) and, on a
volume that does, `extends_past_image_by_bytes`. On a split image `image` names the
first segment and `image_segments` lists every segment joined, with its byte count;
on a virtual disk read over a parent, `image_parents` lists each parent's files, nearest
first, with theirs.
For a bare image with no vendor export alongside it, that file is the record
tying every extracted path back to a place on the disk, checkable against
`mmls` or `fdisk` without trusting the directory names.

`--triage` ranks the volumes by how much each has been written, using only what the
probe already read: the qnx6 superblock serial is a commit counter, and ext exposes
mount count and lifetime kilobytes written. It also samples filenames and says so
when they are encrypted, because a volume whose names are encrypted will not yield
to any parser without the keys.

Read the fill percentage alongside the ranking rather than sorting on size. Two
results from real vehicles, both counter-intuitive:

- On a 2024 BMW MGU the busiest volume on the disk was 36% encrypted filenames in a
  sample, so the ranking's top entry was the one least worth extracting.
- On a Ford Sync G4 the 4 MiB manufacturing volume ranked last with 16 commits, and
  it is the one holding the unit's Bluetooth and WiFi addresses, serials and TLS
  keys.

Activity finds the user data. It does not measure value per byte.

## Listing and extracting, without mounting

You do not need to mount anything. macOS ships 18 filesystems and qnx6 is not one of
them, the WSL2 kernel is built with `CONFIG_QNX6FS_FS` unset, and the free FUSE
options are Linux only. So the tool reads the filesystem directly instead.

```
python3 qnxprobe.py --list mmcblk0.img                      # walk and print the tree
python3 qnxprobe.py --list --depth 4 --list-max 3000 img    # deeper, higher cap
python3 qnxprobe.py --extract case.zip mmcblk0.img          # everything, into one zip
python3 qnxprobe.py --extract storage.zip --only storage img   # one volume by name
python3 qnxprobe.py --extract case.zip --exclude ECRYPTFS img  # leave out what will not parse
python3 qnxprobe.py --extract case.zip mmcblk0.img.001        # any segment of a split image; the set is joined
```

`--list` walks qnx6 through the same block resolution the kernel uses in
`qnx6_block_map()`, including multi-level indirect trees and long filenames held out
of line in the Longfile tree, and walks ext through its extent trees, or through the
classic block map of ext2 and ext3 (twelve direct pointers, then single, double and
triple indirect blocks). Both read-only.

A file is read by logical block, so a sparse file comes out at its declared size
with zeros where its holes are, and an extent the kernel wrote as uninitialized
reads as zeros too. That matters on an Android image: SQLite's `-shm` files and
MMKV stores are sparse, and a reader that concatenates the allocated blocks hands
back a shorter file with its pages in the wrong order. The two ext fixtures under
`tests/fixtures/` hold a hole first, a hole in the middle, a trailing hole past the
last block, a file that is nothing but hole and a 3 MiB file with data at both ends,
built with `mke2fs -d` from one tree (`tools/make_ext_fixtures.sh`); the self-test
requires every one to hash to what `sha256sum` recorded over that tree. A file whose
data is inline in its inode is read when it fits the inode's 60 bytes and refused,
by name, when the rest lives in an extended attribute this does not read.

The zip `--extract` produces is what a LEAPP tool ingests, so this replaces the mount
and the manual zip in one step. `--exclude` is repeatable.

Each file is read in full before anything of it is written to the zip, because a zip
member cannot be taken back once written. A file whose read raises partway (in the
self-test, a UBIFS data node that reads as erased flash) is left out of the zip
entirely: the report counts it as `FAILED` and prints
`could not extract <path>: <reason>` for the first five on each volume, and
`volumes.json` counts it under `failed`.
There is no member for it, under its own name or a marker. Before 1.53 such a file
could reach the zip holding only the bytes read before the error, under its real
name, where it looked like an ordinary, shorter file. A file whose blocks reach past
the end of the image is still stored, under a name ending
`.SHORT-<here>-of-<size>-bytes` (see "What it does not do"), and since 1.53 that name
is given on every volume, not only on one the partition table already shows is cut.
A file larger than 32 MiB is held in a temporary file while it is read, so extraction
needs that file's size free in the system's temporary folder.

Since 1.68 a member's name is made safe before it is written: a stored name of `.` or
`..`, an empty one (a `/` the filesystem kept inside a name, or a leading one), and any
backslash, colon or control character are written escaped as `%XX`, so no member can
land outside the folder it is extracted into, start at a root, or be cut short by a
NUL. Ordinary names are kept exactly as stored. Each renamed member is logged as
`RENAMED <volume>/<name as stored> stored as <member>`. Damage a reader recorded while
walking a volume (a structure that failed its check, a record it could not resolve) is
printed under `--list` as `DAMAGE`, counted on the extraction line as `DAMAGED`, with
the first five shown, and kept in `volumes.json` as `damage_recorded` and
`damage_first` (up to 50).

## Reading an image from Python

Everything the command line does is reachable by importing the file, and the
entry point is `volumes()`, the callable form of the discovery the report does
while it prints. The window's Contents pane and the LEAPP tools read images
through it, and `qnxprobe_gui.py --check-discovery IMAGE` proves that it names
the same volumes the report does, on any image you give it.

```python
import qnxprobe as q

segments = q.split_segments(path)          # the .001/.002 set beside a segment, or None
image = q.open_image(path, segments)       # a plain file, a joined set, or an acquisition
for vol in q.volumes(image):
    print(vol["name"], vol["kind"], vol["label"], vol["missing_past_end"])
    walker = vol.get("walker")            # None when the kind is not one this reads
    if walker is None:
        print("   ", vol["note"])
        continue
    for path, ino, size, mtime in q.collect(walker, walker.root):
        if size is None:                   # a symlink or special file
            continue
        for chunk in walker.read_file(ino, size):
            ...                            # the file's bytes, streamed
image.close()
```

Each dict names the region as the report does (`label`), gives its byte offset and
length (`base`, `size`) and its sector (`lba`, in the disk's logical sectors), the
directory an extraction uses
(`name`, see [What an extraction is named](#what-an-extraction-is-named-and-how-to-check-it)),
the filesystem (`kind`, or `not recognised`, or `extended container` for the MBR
entry that holds logical volumes) and, when the image holds only part of the
volume, `missing_past_end`, the bytes of it that lie past the end of the file. That
last field is how a lone first segment of a split image shows itself. FAT32 and
exFAT walkers hand back readings rather than instants for their times, as
described under [FAT32 and exFAT times](#fat32-and-exfat-times-are-readings-and-are-listed-as-such);
pass a dict as `times` to `collect()` to receive them.

`allocation(walker, ino)` (since 1.56) says what the volume stores for one file beside
the size it records, and whether it is a cloud placeholder with no content to read; see
[What a file stores](#what-a-file-stores-cloud-placeholders-and-overlay-compression).

`volumes()` reads only what identification needs. The walk and the reads happen
when you ask for them, so a consumer that wants a few files out of a 250 GiB disk
never touches the rest.

### Listing a whole volume

`collect()` returns the regular files in tree order, which is what an extraction
needs. Something that wants **everything**, directories included, should ask
`walk_all()` instead, because it takes a faster route where one exists.

```python
for path, node, mode, size, mtime, recorded in q.walk_all(walker):
    ...                                    # every file, directory, link and node
```

On NTFS it builds the listing from one sequential pass over `$MFT` rather than
from the directory indexes, and on APFS it reads the file-system tree's leaves
once rather than searching it per lookup. Measured on this Mac:

| | tree walk | `walk_all()` |
| --- | ---: | ---: |
| 7.4 GB Windows E01, 156,894 entries | 6.9 s | 2.0 s |
| 32 GB macOS E01, 625,543 entries | 147.0 s | 8.0 s |

The APFS route trades memory for it, roughly 900 MB on that 625,543-entry
volume, and a volume larger than `APFS_PRIME_MAX_RECORDS` is walked the
ordinary way instead of held.

Since 1.30. `walk_all()` **does not promise an order**, and on NTFS it answers a slightly
different question: it reads what each record says about itself rather than what
each directory says is in it. The two agree on every consistent volume measured
and differ on 4 entries of 313,652 on one acquisition where the volume's own
index and records disagree, and on 3 on another. `NtfsWalker.listing` says which
and what is known about why. `collect()` is unchanged.

## FAT32 and exFAT: a cluster chain shorter than the size

A FAT32 or exFAT directory entry records a file's size, and the allocation table records
which clusters hold it. Nothing makes the two agree, and a volume can hold a file whose
chain ends before its size is covered. `read_file()` then returns only what the chain
reaches, which is fewer bytes than the size.

Since 1.59 `chain_shortfall(walker, node)` answers
`(clusters in the chain, clusters the size needs)` for such a file and `None` otherwise. A
caller whose read came back short, with nothing lost past the end of the image, can use it
to tell a volume that contradicts itself from a reader that went wrong. `None` means the
chain covers the size, or the file is an exFAT single run (NoFatChain) with no chain to
follow, or the walker is not FAT32 or exFAT. It does not mean the file is whole. The
extraction log names this case instead of saying the rest of the file lies past the end
of the image.

Measured on one exFAT volume with two FATs: 6 of its 31 FAT-chained files had a chain
shorter than their size, in both FATs alike, and none of its 7,209 single-run files did.
Why that volume is in that state is not established. FAT32 is exercised by the self-test
only.

Also since 1.59, an empty exFAT file reads as no bytes. Until then `ExfatWalker.read_file()`
returned one cluster of the volume's own bytes for a file of size zero.

## FAT16, FAT12 and transaction-safe FAT (TFAT)

Since 1.62. A FAT16 volume is read through `Fat16Walker` and a FAT12 volume through
`Fat12Walker`, with the same listing, reading, `deleted_files()`, `free_extents()` and
`chain_shortfall()` calls as FAT32. Either is recognised by a `FAT16   ` or `FAT12   ` type
string at offset 54 of the boot sector, the `0x55AA` signature, and a BPB a cluster count
can be computed from. Which of the two it is comes from that count and not from the
string, because Microsoft's FAT specification types a volume by its count of clusters and
nothing else: fewer than 4,085 is FAT12, and 4,085 to 65,524 is FAT16. A volume whose
string and count disagree is read by its count, and the report says both.

Three things differ from FAT32, all from that specification: a table entry is 16 bits, or
12 bits packed two to every three bytes on FAT12; the root directory is a fixed run of
`BPB_RootEntCnt` entries ahead of cluster 2; and a directory entry has no high word for its
first cluster.

Windows CE's transaction-safe FAT writes `TFAT16  ` or `TFAT32  ` where FAT writes its type
string. Until 1.62 such a volume was reported as not recognised. It is now read as the
FAT16 or FAT32 it is, and the report gives the type string and says whether the volume's
two tables agree.

What Microsoft documents about it, and what the reader does with each point:

- [TFAT Overview](https://learn.microsoft.com/en-us/previous-versions/aa915463(v=msdn.10))
  has FAT1 as the table current operations are made in and FAT0 as the stable copy of the
  last known good table, with FAT1 copied to FAT0 once a transaction completes. The walker
  reads FAT0. So when the two differ, the listing is the last committed state, and the
  report counts the entries that differ.
- [TFAT Registry Settings](https://learn.microsoft.com/en-us/previous-versions/windows/embedded/aa516907(v=msdn.10))
  lists a flag, `FATFS_DISABLE_TFAT_REDIR`, that "disables the redirect of the root
  directory to another hidden directory for FAT12 or 16". Neither page names that
  directory. On the volumes measured it is `__TFAT_HIDDEN_ROOT_DIR__`, it is the only entry
  in the fixed root, and every file sits under it. It is listed as stored: not hidden, and
  not removed from the paths.

Measured on the partition images of eight Ford SYNC Gen1 head units (the acquisitions
registered as `xtrmp_item002`, `xtrmp_item003`, `xtrmp_item004`, `xtrmp_item008`,
`xtrmp_item010`, `xtrmp_item065` and `xtrmp_item066`, which are TFAT16, and
`xtrmp_item012`, which is TFAT32). All eight have 2,048-byte sectors and two identical
tables. Every file the acquisition tool had extracted was listed at the same path, under
the hidden directory where there is one, with the same content: 48, 71, 57, 65, 77, 69 and
71 files on the TFAT16 volumes and 5,044 on the TFAT32 one. One TFAT16 volume listed one
file the tool had not extracted, a file of zero length. No volume in that set has tables
that differ, so that case is exercised by the self-test only, on a fixture whose second
table was altered.

`tools/make_fat16_fixtures.sh` builds the three committed fixtures with macOS. Two are a
FAT16 and a FAT12 volume as macOS formats them. The third has 2,048-byte sectors, its
files under a `__TFAT_HIDDEN_ROOT_DIR__` folder, and the `TFAT16  ` type string: macOS
wrote its tables, directories and file data, and the script then rewrote the boot sector's
counts in 2,048-byte units and its type string, because macOS will not mount a FAT volume
with sectors larger than the device's. It stands in for the layout, not for Windows CE's
driver. The self-test reads every live file of all three against hashes taken from the
mounted volume and recovers the files deleted before unmounting against hashes taken
before deletion. Its controls: the FAT16 volume read as FAT32 lists none of its files, and
the FAT12 volume read with a 16-bit table returns 3 of its 8 files. At build time The
Sleuth Kit listed the same live and deleted files on all three, and `icat` returned the
same bytes for every live file and every recoverable deleted one.

FAT12 has been read on that one macOS-written fixture only. No FAT12 volume from a device
has been run through it.

## QNX6 free space

Since 1.58 `Qnx6Walker.free_extents()` reports the space a qnx6 volume says is free, as
`(byte offset into the image, length)` runs. It is the call the F2FS, FAT32, exFAT, NTFS,
HFS+ and APFS walkers already answer, so a carve can be scoped to free space on a qnx6
volume the same way.

```python
import qnxprobe as q

image = q.open_image(path)
for vol in q.volumes(image):
    if vol["kind"] != "qnx6" or vol.get("walker") is None:
        continue
    for offset, length in vol["walker"].free_extents(min_bytes=1 << 20):
        data = q.read_at(image, offset, min(length, 1 << 20))   # the run's first bytes
image.close()
```

The bitmap is a tree under the Bitmap root node of the superblock, the second root node
of `struct qnx6_super_block`
([qnx6_fs.h line 111](https://github.com/torvalds/linux/blob/d56b699d76d1b352f7a3d3a0a3e91c79b8612d94/include/linux/qnx6_fs.h#L111)). The kernel's description of
it ([qnx6.rst lines 156 to 165](https://github.com/torvalds/linux/blob/d56b699d76d1b352f7a3d3a0a3e91c79b8612d94/Documentation/filesystems/qnx6.rst#L156-L165))
gives one bit per block, block 0 where file blocks start, and the bits past the last
block set. It does not say which bit value means in use or which end of a byte is counted
first, and the Linux driver, which has no write path, never reads the bitmap. Both were
measured, on the four qnx6 volumes at hand: qnxmount's reference image and the three qnx6
partitions of a Ford Sync G4 image. Live blocks below are every block named by the
superblock's root nodes and by every inode whose status is directory or normal file.

| volume | blocks | block size | free runs | free blocks | `sb_free_blocks` | live blocks | live blocks inside a free run | the same, most significant bit first |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| qnxmount `test_image.bin` | 384 | 1,024 | 2 | 339 | 339 | 38 | 0 | 5 |
| Sync G4 `dps_mfg` | 1,020 | 4,096 | 2 | 965 | 965 | 50 | 0 | 4 |
| Sync G4 `dps_os` | 6,140 | 4,096 | 3 | 6,055 | 6,055 | 59 | 0 | 2 |
| Sync G4 `storage` | 7,541,755 | 4,096 | 5,422 | 3,716,776 | 3,716,776 | 3,822,697 | 0 | 10,445 |

A set bit is a block in use, and bit 0 is the least significant bit of byte 0. Read that
way the clear bits equal the superblock's own `sb_free_blocks` on all four volumes and no
live block is clear. The count cannot settle the bit order (on the reference image both
orders give 339); position does, and read from the top of each byte live blocks fall in
free space on every volume. A second qnx6 reader, written independently of this one,
names the same set of free blocks on the three volumes it opens, and its dump of them is
byte-identical by SHA-256 on the two small ones.

Live and free blocks do not add up to the volume. 7, 5, 26 and 2,282 blocks are marked in
use and named by no live inode or root node. qnx6.rst describes a preallocated system
area in the bitmap; whether that accounts for them was not established. They are not
reported as free.

The bitmap read is the one of the superblock the walker was opened on, the newest
generation. Blocks that only the previous generation's trees name can be clear in it (1,
1 and 7 blocks on the three volumes that hold two generations), so a reported run can
hold what the last commit replaced.

Nothing is reported unless the whole bitmap can be read and its clear bits equal
`sb_free_blocks`. A bitmap that is cut short by a partial image, shorter than the volume
needs, not mapped, or at odds with its superblock returns an empty list, which is "no
answer" and not "nothing free". The walker reads little-endian volumes; all four
measured are little endian.

## Writing free space to files

Since 1.58 `--unallocated DIR` copies out the free space of every volume whose filesystem
says what is free: qnx6, F2FS, FAT32, FAT16 and FAT12 (since 1.62), exFAT, NTFS, HFS+, APFS,
XFS and Btrfs.

```
python3 qnxprobe.py --unallocated free_space --only dps_mfg mmcblk0.img
```

For each such volume it writes `<image>.<volume>.unallocated.bin`, the free runs one after
another, and a `.tsv` beside it with one line per run: where the run starts in that file,
where it came from in the image, and its length. A carve hit at an offset in the `.bin`
maps back to the disk through that table. `unallocated.json` lists every volume looked at,
what was done with it, and the SHA-256 of each file written. Offsets are into the image
as qnxprobe reads it, so for an E01, an AFF, a disk image or a split set they are offsets
into the disk and not into the container file.

What it writes and what it leaves out:

- **A filesystem that does not report free space gets no file.** ext2/3/4, QNX4, ETFS,
  EFS, SquashFS, JFFS2, UBI/UBIFS, YAFFS and QNX IFS readers have no free-space call. The
  volume is listed as `not written: the ext4 reader does not report free space`.
- **An empty answer gets no file, and is not called "nothing free".** A reader returns
  the same empty list when it cannot read its allocation map and when the volume is full,
  so the status is `no free space reported (the allocation map could not be read, or
  nothing is free)`.
- **A run past the end of a partial image is cut there.** The FAT32 reader, on an image
  cut short, reports clusters past the end of the file as free. On the committed FAT32
  fixture cut to 3,000,000 bytes, 1.8 MiB was written and 61.1 MiB was counted as lying
  past the end and not written.
- **An APFS container's free space is the container's**, not one volume's, so it is one
  file per container. It is copied as stored: blocks an encrypted volume wrote there stay
  encrypted, with or without its password, and the output says when the container holds
  an encrypted volume.
- **A BitLocker volume that was opened is read through its decryption**, the same handle
  file reads use. No test image here pairs BitLocker with a filesystem that reports free
  space, so that path has not been run.
- **Space outside every recognised volume is not written.** Gaps between partitions,
  reserved partitions and an unpartitioned tail are no filesystem's free space.
- **Nothing is overwritten.** DIR must be new or empty, and a volume whose output would
  not fit in the room DIR has is listed and skipped.

`--only` applies, as it does to `--extract`. The output can be nearly as large as the
disk: the Ford Sync G4 `storage` volume has 3,716,776 free blocks, about 14.2 GiB.

On the two small qnx6 volumes measured above (qnxmount's reference image and Sync G4
`dps_mfg`) the `.bin` is byte-identical, by SHA-256, to the dump the second qnx6 reader
writes. One committed fixture per other filesystem was run through it: F2FS, FAT32, exFAT,
NTFS, HFS+ and APFS each wrote a file, and the ext4 and SquashFS ones were listed as not
reporting free space.

From Python the same writer is `write_unallocated(fh, size, volumes(fh, size), out_dir,
image_name)`.

## QNX EFS in a raw flash image: either byte order, and deleted data

Since 1.60.

**Finding the partitions.** A NOR dump from a telematics unit holds its EFS partitions one
after another behind the boot code, with no table. Each partition has one boot record
(`QSSL_F3S`), the text of header 2 of the unit that holds logical unit 1. Wear levelling
moves that unit, so the record is often not in the partition's first unit. Its
`unit_index` field is the physical index of the unit holding it, so the partition starts
`unit_index` units before that unit. `efs_partitions(fh, size)` returns every partition
placed that way, and the flash search described under "Raw flash dumps" now includes
them, so `volumes()` and the report list each one as its own volume.

A signature counts as a boot record only when the unit it sits in opens with a `unit_info`
of the same byte order and that unit's header 2 points at the record. The string also
occurs elsewhere on the flash images measured below, in 1 to 8 places per image, and
those are not taken.

Until 1.60 the record was looked for in a partition's first four units and read
little-endian only, and nothing searched a flash image for EFS. The images below came
back as not recognised.

**Byte order.** `f3s_unit_info_t` carries an endian byte, `L` or `B`, and the partition is
stored in that order throughout. Both are read. qnxmount reads little-endian only, so no
reference reader stands behind the big-endian reading. It is the same code with the other
byte order, checked on a fixture written in both orders and on the four big-endian images
below, where every extent table parsed and the accounting check held.

**Deleted and superseded data.** EFS marks an extent deleted in its header, and on every
image measured the text was still in place behind it. An extent that was overwritten has
its supersede pointer set to the extent that replaced it. A directory entry is an extent
too, so a deleted file's name, mode and times can stay on the flash the same way. `EfsWalker.recover_deleted()` lists what is left:

```python
for vol in qnxprobe.volumes(fh, size):
    if vol["kind"] != "efs" or "walker" not in vol:
        continue
    w = vol["walker"]
    for e in w.recover_deleted():
        print(e.parent_path, e.name, e.size, e.recoverable, e.reason, e.note)
        if e.recoverable:
            data = b"".join(w.read_deleted(e))
            where = w.deleted_extents(e)      # [(offset in the image, length, state)]
```

Three kinds of entry come back, and `note` says which:

- **A deleted file.** A directory entry no live directory reaches, naming a file whose
  extent chain still reads from its first pointer to its end. The content is the chain in
  its current version, read the way a live file is read.
- **A deleted file that does not read whole.** A pointer in its chain no longer resolves,
  or the chain runs into a free header, a live file's extents or another deleted file's.
  The name is reported, `recoverable` is False and `reason` says which.
- **A run of deleted or superseded extents** that no entry above took, chained by their
  next pointers. It carries the name of the file a directory entry still leads to it from,
  live or deleted, when exactly one does. Otherwise the name is empty. These are pieces:
  an earlier version of part of a file, or what is left of a file whose directory entry is
  gone.

Every deleted or superseded file extent that has text is in exactly one entry. The state in
`deleted_extents()` is the header's condition, `deleted` or `allocated`, followed by
`, superseded` when its supersede pointer is set.

What the entries do not say:

- **Size.** The directory records none. `size` is the bytes the entry's extents hold.
- **Ownership.** An extent pointer is a logical unit and a header index. Nothing in it says
  whether that unit was rewritten since the pointer was written, so a name is what the
  directory data leads to, not proof.
- **Folder, most of the time.** `parent_path` is given only when a live directory's own
  chain of entries still reaches the file's directory entry. Following a deleted entry's
  next pointer forward into a live directory was tried and dropped: with it, the folder
  differed from the one the acquisition's own extracted files sit in for 60 of 84 deleted
  files on one image.

**The accounting check.** `EfsWalker.unaccounted()` returns the bytes of the partition that
are neither an extent header nor the text of an extent whose header is not free, and how
many of those bytes are not 0xFF. Erased flash reads 0xFF, so the second number is 0 when
the extent table accounts for everything written.

**Measured on six flash images** from GM OnStar telematics units (LG, Gen9 and Gen10),
corpus keys `xtrmp_item020`, `027`, `030`, `031` (64 MiB, big-endian) and `xtrmp_item081`,
`115` (128 MiB, little-endian). All units are 128 KiB:

| | 020 | 027 | 030 | 031 | 081 | 115 |
|---|---|---|---|---|---|---|
| EFS partitions found and walked | 10 | 12 | 12 | 10 | 8 | 8 |
| of them, boot record not in the first unit | 2 | 3 | 2 | 2 | 4 | 4 |
| units | 445 | 467 | 460 | 445 | 968 | 968 |
| live files | 2,761 | 2,762 | 3,295 | 2,655 | 3,463 | 3,431 |
| deleted files recovered | 123 | 371 | 560 | 301 | 1,528 | 1,771 |
| deleted files named, not recoverable | 17 | 8 | 5 | 3 | 57 | 46 |
| extent runs with a name | 117 | 197 | 524 | 33 | 185 | 84 |
| extent runs with none | 219 | 325 | 1,431 | 173 | 1,270 | 1,319 |
| deleted or superseded file extents listed | 8,703 | 5,096 | 10,779 | 4,148 | 7,718 | 5,422 |
| the same, counted by a separate reader | 8,703 | 5,096 | 10,779 | 4,148 | 7,718 | 5,422 |
| unaccounted bytes that are not 0xFF | 0 | 0 | 0 | 0 | 0 | 0 |

The separate reader is a research script that parses the extent tables with no directory
walk. Its set of extents and the set `recover_deleted()` lists are identical on all six,
and no extent is listed twice. Of the runs with no name, 2, 37, 4, 0, 0 and 0 are ones
that more than one file's directory entries lead to.

Each acquisition also carries the files its own tool extracted, many of them marked as
deleted copies. Across the six there are 527 distinct file contents in those sets. 485 are
reproduced byte for byte: 108 by a live file, 390 by a deleted-file entry, 20 by an extent
run (some by more than one). 479 of the 485 come back under the name the tool gave them.
The other 42 are not reproduced. 17 of them have a size that is a multiple of 65,535
bytes, the most one extent holds. Why any of the 42 differ is not established. Where both give a
folder for a deleted file, they agree on 32 and differ on 6.

**On an image QNX wrote.** qnxmount's committed test image was made on QNX by `mkefs` and
the `devf-ram` driver, and its build script removes one file after copying it and
overwrites 10 blocks of 1 KiB inside another. That image and the tar QNX made of the
mounted tree are kept here as `tests/fixtures/efs-qnx.img.gz` and `efs-qnx.tar.gz`, from
qnxmount at commit `11c8a7f9ee9b945d584263743f6ea8524e8776d2` (Apache-2.0, see
[LICENSE-qnxmount](LICENSE-qnxmount)); the image is gzipped and otherwise unchanged. The
self-test checks all of it: the 31 live entries equal the tar, the removed file comes back
by name with the bytes of its copy, and the superseded extents of the overwritten file
hold 10,240 bytes that are not what the file holds there now. A control sets the removed
file's extent header to free, and the check has to fail.

**Fixtures.** No free tool writes EFS, so `tools/make_efs_fixtures.py` writes the two
fixtures, one per byte order, from one model and records what it wrote. Run with
`--oracle`, it has qnxmount read the little-endian one, and every live file comes back as
written. The big-endian fixture and the deleted data have no reference reading. The
self-test reads both fixtures and breaks three things to show the checks can fail.

**Not established, or not built.**

- What `status[1]` and `status[2]` of an extent header record. Only `status[0]` is read,
  and `status[1]` of header 1 to tell a spare unit, as qnxmount does.
- A partition whose first unit has no `unit_info` is found by `efs_partitions()` but not
  opened. None of the 60 partitions measured is like that.
- A partition that runs past the end of the image is not reported.
- Free space is not reported for EFS.

## APFS

Every Mac since 2017 is APFS, so `--list` and `--extract` read a container. It is
claimed by the `NXSB` magic in the first block's object header together with a block
size that is a power of two, and only reported once its newest checkpoint and object
map have been read far enough to name the volumes inside it.

A container holds several volumes, and on a Mac the user's data is not the first of
them, so the container is listed as a **directory whose children are its volumes**.
One walk reaches all of them and each file lands under its volume's name.

What it reads: the checkpoint with the highest transaction id whose Fletcher-64
checksum is right, the container and volume object maps, the file-system B-tree,
directory records, inodes and their extended fields, file extents including sparse
ones, symbolic links, and files compressed with the `decmpfs` attribute in its zlib
forms.

What it does not do: an encrypted volume whose blocks are ciphertext in the image, and
which no password given opens (see below), is named, marked `encrypted and locked, not
read`, and not walked, and a file compressed with LZVN or LZFSE is listed with its size
and refuses to be read. Nothing here reads a snapshot: what is walked is the volume as
the newest checkpoint leaves it.

An encrypted volume is one whose flags lack `APFS_FS_UNENCRYPTED` (Apple File System
Reference, 2020-06-22, `apfs_superblock_t` and "Volume Flags"). Whether its blocks are
ciphertext in a given image is a separate question, and the volume's own blocks answer
it: when the root node of its file-system tree passes its Fletcher-64 checksum, the
image holds the volume decrypted, and it is read and marked `encrypted, read in the
clear`; when it does not, the volume is locked. An acquisition made through the Mac's
own decryption stores a volume that way: on Digital Collector 3.7's AFF4 of an Apple
silicon MacBook Pro, whose log says it enabled "crypto I/O" for the encrypted Data
volume, that volume reads in the clear, and 198 of 200 property lists read from it
parse (one is LZVN-compressed, one holds a date Python cannot represent). Before 1.44
both kinds were walked as though they were plain: the one in the clear happened to
read, and a locked one was missing from listings with nothing saying why. A report
and `volumes()` now say which is which, in a `note` beside the volume list.

The self-test reads an image `tools/make_apfs_encrypted_fixture.sh` builds on any Mac:
a plain volume, and a volume `diskutil` encrypted with a test passphrase, which APFS
encrypts in software. The plain volume's files must match what macOS wrote and the
encrypted one must be named locked with its tree never parsed. The in-the-clear case is
built from the plain fixture by clearing the flag and sealing the superblock's
checksum again, and must read every entry; with the tree's root node replaced by noise,
the same volume must read as locked.

### Opening an encrypted APFS volume

Since 1.50 an encrypted APFS volume whose blocks are ciphertext in the image opens with
its password or its personal recovery key, given the way any password is
(`--password-file FILE` or `--password-env NAME`, repeatable, each tried against every
such volume), and is then listed and extracted like any other. The report marks it
`encrypted, opened with a password`, and the note says so. Without a key that opens it,
it stays `encrypted and locked, not read`, and the note says what would open it and gives
the passphrase hint the volume stores, as stored. The window asks for each locked
volume's password when it loads an image, showing the hint. A file listed while its
volume was open and asked for again once it is locked (a later session, without the key)
is refused with `ApfsUnreadable`, never read back as an empty file. From 1.44 to 1.49
such a volume was named locked and not walked.

This is the software encryption Apple File System Reference (2020-06-22) describes in
"Encryption" and "Accessing Encrypted Objects", which a Mac uses for external storage and
for internal storage without hardware encryption. The password, through PBKDF2 with the
salt and iteration count its unlock record carries, unwraps the key encryption key
(RFC 3394); that unwraps the volume key; and the volume key decrypts the volume's tree and
files as AES-XTS. Two details come from libfsapfs's format notes and code at commit
`f63c83b462275214fc5e4b0919540d892f50b467` rather than from Apple's reference: each keybag
is itself AES-XTS encrypted with its container's or volume's identifier as both keys (the
reference says RFC 3394 for that step; the keybags on both test volumes do not unwrap as
RFC 3394 and do read as AES-XTS), and a file's data is decrypted from its extent's
`crypto_id`, not from the block it sits in now (`libfsapfs_file_system_data_handle.c`,
lines 274 to 307). PBKDF2 is HMAC-SHA256, which is what unwraps the key on both test
volumes. It needs the optional
`pycryptodome` package, and says so without it.

Not read, and named in the note: a volume whose files use per-file keys (Apple's reference
ties those to hardware encryption), a volume that was being encrypted, decrypted or given
a new key when it was imaged (its blocks are then not all in one state), an unlock
record in the CoreStorage-compatible form (libfsapfs: flag 0x2, AES-128), and an
institutional recovery key. The internal storage of a Mac with a T2 chip or Apple silicon
does not open with a password from an image: Apple Platform Security's
[FileVault page](https://support.apple.com/guide/security/volume-encryption-with-filevault-sec4c6dc1b6e/web)
says its key encryption key "is protected by a combination of the user's password and
hardware UID". An acquisition made through such a Mac's own decryption holds the volume
in the clear, and is read as described above.

From Python, after `unlock_bitlocker()` if the image may hold BitLocker too:

```python
image = q.open_image(path)
image, found = q.unlock_apfs(image, passwords=[password])
for vol in q.volumes(image):
    print(vol["kind"], vol.get("note", ""))
```

`unlock_apfs()` returns the image carrying the keys it derived, so every `ApfsWalker`
made over it (and so `volumes()`, `walk_all()` and every extraction) reads those volumes
decrypted, and one `ApfsLock` per such volume, opened or not, with `name`, `hint`,
`unlocked_by` (`password` or `personal recovery key`), `why` (what stops it being opened
at all) and `locked_note()`.

Checked on two volumes macOS 26 encrypted, which ship gzipped under `tests/fixtures`:
one encrypted as it was made (`tools/make_apfs_encrypted_fixture.sh`) and one encrypted in
place after files were written, with a passphrase hint
(`tools/make_apfs_converted_fixture.sh`). The self-test requires every file on both to
match what macOS wrote, a wrong password to leave the volume locked with its tree never
parsed, and the hint to be reported as stored. On every extent record of both volumes
(5 and 6) `crypto_id` equals the extent's block, so the self-test also moves one extent of a copy to
another block, as a container shrink would, and requires it to read the same; a reader
that took the tweak from the block fails there. It refuses copies built with each of the
shapes named above as not read. A personal recovery key goes through the same steps as a
password in Apple's reference; no volume carrying one was available to test.

Decryption is the same pure-Python AES-XTS the BitLocker reader uses, about 95 MB/s on an
Apple M2 Max. Since 1.50 a file is also read in one pass over its extents: before, each
megabyte of a file read its whole data again, so the largest file of the APFS fixture
below, 12,288,000 bytes, took 148,840,448 bytes of reads and now takes 12,500,992.

### Checked against The Sleuth Kit

Validated against The Sleuth Kit's APFS support, an entirely separate implementation.
A 32 MiB container written by macOS itself and populated through its own driver ships
gzipped under `tests/fixtures`; the self-test walks it and requires all 411 files to
match hashes `fls` and `icat` recorded from the same image, and
`tools/make_apfs_fixture.sh` rebuilds it on any Mac as an ordinary user. It carries a
file in 2,046 extents, a sparse file whose hole is a real one, a compressed file, a
symbolic link, two names for one inode, a directory of 400 entries so the tree is
several levels deep, a UTF-16 name and an empty file.

Two defects the comparison found, both in the same place and neither visible by
reading: the object map's own tree points at blocks while the file-system tree points
at virtual ids, so reading the first through the second walks whatever happens to sit
at that offset; and a run of records can begin part way through the leaf before the
first one whose key matches, so starting at the matching leaf lost 13 of 400 children.

## Btrfs

`--list`, `--extract` and `--unallocated` read Btrfs directly, without mounting. A
volume is claimed only when three things hold: the `_BHRfS_M` magic is in the
superblock 64 KiB in, a superblock copy's checksum holds, and the chunk tree root block
that superblock names is a block of this filesystem (its checksum holds, and it records
its own address and the superblock's filesystem id). The magic alone is not enough, and
neither is a whole superblock copied where its filesystem is not: both fall through to
the identifiers after Btrfs. An image cut short before the chunk tree is still named
Btrfs, with the reason it cannot be walked. Btrfs is tested before ext, the more specific
test first, as everywhere else in the identifier; mkfs.btrfs 6.17.1 and mke2fs 1.47.2
each clear the other's signature when they format (measured), so the order decides
something only on an image written by older tools.

What it reads: the superblock, the chunk tree that maps logical addresses to the device,
the root tree, and every file tree reachable from the top-level subvolume (id 5). A
device without the magic at 64 KiB is not Btrfs, as btrfs-progs' own format notes say,
so its mirror copies are not looked at. A primary whose checksum holds is used, as a
normal mount uses it, even when a mirror records a later generation. When the primary
fails, the mirrors at 64 MiB and 256 GiB are tried the way `btrfs` does when told to
recover: the good copy with the highest generation is taken, every copy used must carry
the fsid of the first good one, and the note says a mirror was read. Directories are read
from their `DIR_INDEX` items, as the kernel's readdir reads them. Files are read from
their inline, regular and preallocated extents, with holes (both the hole items older
volumes write and the ranges a `NO_HOLES` volume leaves without an item) and
preallocated ranges read as zeros, and with zlib, LZO and zstd extents decompressed.
Hard links are one file under several names, and the names the inode records for itself
(`INODE_REF` and, for a file with many names in one directory, `INODE_EXTREF`) are read
by `links()`.

Subvolumes and snapshots are **directories**, where the top-level tree links them, the
way the kernel and `btrfs restore -s` present them. A link the root tree has no matching
`ROOT_REF` for (a snapshot's view of a subvolume nested in the subvolume it copied) is
an empty directory, as the kernel shows it; no disk records a time for that directory,
so it is listed with time 0. A subvolume's directory entry for itself is not followed.
When the default subvolume is not the top level, the note says which id it is: it is
still listed where the top level links it.

Every tree block is checked before it is used: its checksum, the address it records for
itself, its filesystem id, the structure the kernel's tree checker requires (keys in
order, items packed inside the block, a node's pointer count and pointers), and, on
every read whether the block was read before or not, the level, generation and first key
its parent records for it. Each tree's root block is held to the generation the
superblock or its `ROOT_ITEM` records. All four checksum types are read: crc32c and
xxhash64 are carried as pure Python, sha256 and blake2b come from `hashlib`. Metadata is
kept twice on a single device by default (DUP), so a block whose first copy fails is
read from the second, and the walker's `damage` list records the repair. A block whose
every copy fails is recorded there too, and the walk goes on without it. Items are held
to the sizes and rules the kernel's tree checker sets for them: an inode item is 160
bytes and its size no larger than the largest file Btrfs allows; an inline extent is at
file offset 0 and, uncompressed, holds exactly the bytes it records; a regular extent's
sizes and offsets fall on sector boundaries; a compressed extent holds 1 byte to 128 KiB
stored and decompressed, which also bounds what a damaged stream can make it
decompress. An item that breaks one of these makes its file unreadable, by name, and is
recorded. A directory entry whose inode is missing or unreadable is still listed, as
readdir lists it, with the file type its entry records, no permission bits, size 0 and
time 0, and recorded; reading it then fails, by name.

On one device of a multi-device volume, everything with a copy on that device is read
(SINGLE chunks placed there, DUP, and RAID1, RAID1C3 and RAID1C4 through the device's
own copy). RAID0, RAID10, RAID5 and RAID6 chunks are refused by name: their data is
striped across devices, so one image does not hold it. The note says how many devices
the volume has and which one this is. One member of a two-device RAID1 volume is in the
fixtures, but it holds only metadata, because `mkfs.btrfs --rootdir` fills only a single
device; reading data through a RAID1 chunk is checked with chunks set by hand, and
RAID1C3 and RAID1C4 are not in the fixtures.

Free space (`free_extents()`, so `--unallocated`) is two things: the device's space no
chunk is allocated on, from 1 MiB (below which btrfs allocates nothing) to its end, and,
inside each block group, the ranges no `EXTENT_ITEM` or `METADATA_ITEM` of the extent
tree covers, at every copy on the device. The superblock copies are left out. On each
of the seven `mkfs.btrfs` fixtures below, the free space found from the extent tree is
exactly what the volume's own free space tree records. On one of them, no free run
overlaps a file's data, and the unallocated total is what the superblock's device item
leaves. On the kernel-written fixture, every 64 KiB block of the two files deleted
before it was unmounted is inside the free space reported.

A log tree (changes `fsync`'d after the last commit, which the kernel replays at the
next mount) is not replayed. The volume reads as of its last commit, and the note says a
log tree is present.

Validated against images `mkfs.btrfs --rootdir` (btrfs-progs 6.17.1) wrote from one
source tree, once per compression (none, zlib, zstd, LZO) and once per other checksum
(xxhash64, sha256, blake2b), each read back first by btrfs-progs' own `btrfs restore`
and passed by `btrfs check` (`tools/make_btrfs_fixtures.sh`). On each, all 572 files
match the sha256 recorded over the source, and all 586 entries match the source's own
`lstat()` for type, permission bits, size, modification time and symlink target. The
tree holds inline files, files of many extents, compressible and random data, 400 files
in one directory, a 255-byte name, names in Greek, Japanese and emoji, four kinds of
symlink, hard links (one file has 151 names, so its extended refs are read), a FIFO and
a subvolume. `mkfs.btrfs --rootdir` writes 0 nanoseconds and no creation time, and the
self-test checks that they read so.

Four more images. An ext4 volume converted by `btrfs-convert`, whose saved
`ext2_saved/image` (mostly holes) reads back with the sha256 the ext4 image had before
conversion. The second device of a two-device RAID1 volume, read through its own
copies. Two that the Linux kernel wrote on a mounted volume
(`tools/make_btrfs_root_fixtures.sh`, which needs root): `btrfs-live` holds a sparse
file, a preallocated file written in its middle, a punched hole, a reflinked copy partly
overwritten, a file of 40 small extents, zlib, LZO and zstd files each overwritten in
their middle (so read from an offset into a compressed extent), a subvolume with a
nested one, a read-write and a read-only snapshot of it (whose views of the nested
subvolume are the empty directories the kernel shows), a default subvolume other than
the top level, and two deleted files. All 17 of its files match the sha256 taken through
the mount, and all 27 entries match `lstat()` through the mount to the nanosecond.
`btrfs-logtree` was copied after an `fsync` and before the next commit: the note says its
log tree is present, the file committed before it is listed, and the file only the log
holds is not.

The self-test also breaks one rule at a time in copies of these images, each in memory
with its checksum rewritten so the break reaches the check under test: a node that
points at itself, a generation, a first key and a filesystem id that do not match, a
leaf that claims more items than fit, a directory entry whose inode is missing, a
changed `DIR_ITEM` name, a subvolume entry for itself, a `ROOT_REF` too short for its
name, an inline extent with the wrong size, an inode size past the largest file, broken
superblocks, LZO segments with sector padding, zlib streams with a wrong adler32 and
compressed extents past 128 KiB. Each is recorded or refused as described above.

## HFS+

A Mac before APFS is an HFS+ volume, and so is an older iOS device, so `--list` and
`--extract` read one. The volume is claimed by the `H+` or `HX` signature 1024 bytes
into the volume together with a geometry that has to make sense.

What it reads: the catalog B-tree in both its index and leaf forms, forks whose
fragments outgrew the eight extent descriptors a catalog record holds and continue in
the extents overflow tree, symbolic links, hard links through the private directory
the volume keeps their indirect nodes in, and files compressed with the `decmpfs`
attribute in its zlib forms, whether the compressed data sits in the attribute or in
the resource fork behind a block table. A `--list` names a resource fork that carries
anything, because that is content the file's own size does not account for. HFSX, the
case-sensitive variant, is read the same way and reported as itself.

What it does not do: a file compressed with LZVN or LZFSE is listed with its recorded
size and refuses to be read, since neither is in the standard library.

Validated against The Sleuth Kit, which reads HFS+ through an entirely separate
implementation. A 24 MiB volume written by macOS itself and populated through its own
driver carries a fragmented file whose extents spilled into the overflow tree, a
compressed file, a symbolic link, two names for one file, a file with a resource fork,
a directory of 400 entries so the catalog is three levels deep, a name that needs
UTF-16 and an empty file. All 412 of its files come back byte for byte against hashes
`fls` and `icat` recorded from the same image, and the fixture ships with the tool so
the self-test compares against it. `tools/make_hfsplus_fixture.sh` rebuilds it on any
Mac, as an ordinary user, and refuses to finish if the image it wrote does not read
back as what it meant to write.

Six deliberate breaks each turn a different case red. The one that mattered was the
B-tree descent: every entry of a directory shares a parent id, so several index entries
carry that id with different names, and taking the last one that is not greater lands
on the last leaf of the run. A 400-entry directory came back with 10 children until the
comparison was strict.

## NTFS

An acquisition of a Windows computer is an NTFS volume, so `--list` and `--extract`
read one directly. The volume is claimed by the `NTFS` name in its boot sector plus a
geometry that has to make sense, and an NTFS boot sector is declined as a partition
table for the same reason a FAT one is: it ends in `0x55AA` and its boot code sits
where partition entries would be.

What it reads: resident and non-resident data, sparse runs, LZNT1 compressed data,
files the Windows Overlay Filter compressed with XPRESS (since 1.56),
attributes that overflowed into other MFT records through `$ATTRIBUTE_LIST`, and
directory indexes in both the resident `$INDEX_ROOT` and the allocated
`$INDEX_ALLOCATION` form, with the sector fixups put back. Bytes past a file's
initialized size read as zero, which is what the format says and what a database that
preallocates its file depends on. An LZNT1 compression unit that stops before it is full
reads as zeros from there (since 1.57, see
[NTFS compression units that stop early](#ntfs-compression-units-that-stop-early)). A
`--list` also names any alternate data stream it finds, because a stream is content the
file's own size does not account for.

What `--list` does not do: it lists what the directory indexes hold, so an 8.3 name
indexed beside a long one is skipped rather than listed twice, and an encrypted file is
listed with its recorded size and refuses to be read, since the volume holds no key.
Since 1.56 a cloud provider's online-only placeholder and a file overlay-compressed with
LZX are refused the same way, for the reasons under
[What a file stores](#what-a-file-stores-cloud-placeholders-and-overlay-compression).
Only the unnamed stream is the file's content; the named ones are read separately, as
[Alternate data streams](#alternate-data-streams) describes. `NtfsWalker.stamps(record)` returns
the created, modified and accessed instants a file's `$STANDARD_INFORMATION` holds;
`entry()` carries only the modified one, which is what a listing needs.

Deleted files are recovered separately, from the MFT rather than the directory index.
`NtfsWalker.deleted_files()` yields every record that is marked free but still names a
file: its name, size, dates, and whether the content can still be read. A file whose
data was **resident**, small enough to sit inside the MFT record, is always recoverable
this way, and it is the only route to one, because it never occupied a cluster a carver
could find. A non-resident file is recoverable only while every cluster it used is still
free; once a later file has taken one, `read_deleted()` refuses it rather than hand back
bytes that now belong to something else, so overwritten data is never presented as the
file. `$ATTRIBUTE_LIST` is not followed for a deleted record, because it points at other
records that may since have been reused, so a file whose attributes overflowed its record
is reported as having existed rather than reconstructed from whatever now lives there.

Validated two ways. A 16 MiB volume written by `mkntfs` and populated through `ntfs-3g`
carries a resident file, an empty one, a sparse one, a compressed one, one fragmented
across 333 runs whose attributes had to move into other records, a file grown past what
was written into it, one record with 61 names, a directory of 400 entries so the index
outgrows its record, a name that needs UTF-16, an alternate data stream, and a resident
and a non-resident file that were created and then deleted; every one of its 475 live
files comes back byte for byte against hashes an independent reader recorded from the
same image, the two deleted files are recovered from the MFT and match the bytes written
before they were deleted (which The Sleuth Kit's `icat` confirms from the same records),
and that fixture ships with the tool so the self-test compares against it. On real evidence, a 231.9 GiB Windows volume inside a 232.9 GiB FTK Imager
acquisition: 221,851 live regular files in 9 seconds, the same set The Sleuth Kit's
`fls` reports, each resolving to the same MFT record, and 1,339 of 1,341 sampled files
byte-identical to `icat`. The two that differ are metadata files whose content lives
only in named streams, where the two tools pick different streams.

On a second real image, a small NTFS volume with a screen recording deleted from it,
`deleted_files()` finds the one deleted record `fls -d` reports and recovers its 5.8 MB
byte-identical to `icat`.

`tools/make_ntfs_fixture.sh` rebuilds the fixture on any Linux box with
`ntfsprogs` and `ntfs-3g`, as an ordinary user, and refuses to finish if the image it
wrote does not read back as what it meant to write. It creates the two deleted files
last, so nothing reuses their records or clusters, and records their hashes before
removing them.

That comparison earned its cost twice: it found this reader returning stale bytes past
a file's initialized size, and a second pass found the run list of a heavily fragmented
file counted twice because its own record is named in its attribute list.

### Alternate data streams

Since 1.37. A file on NTFS can carry named streams beside its content, and some of what an
examiner wants most lives in one: `Zone.Identifier`, the Mark of the Web, says where a
download came from; `$Extend/$UsnJrnl:$J` is the change journal, a record of files created,
renamed and deleted; `$Secure:$SDS` holds the volume's security descriptors. The metadata
files whose content is in their unnamed stream (`$MFT`, `$LogFile`, `$Boot` and the rest)
were always listed and read like any file. `$UsnJrnl` and `$Secure`, whose content is only
in named streams, were listed as empty files, and nothing read a stream.

Each stream has a node of its own, an `NtfsStreamRef` of the record and the stream's name,
and `read_file()`, `entry()` and `stamps()` take it. So a caller that lists entries and
hands each node back to read it, as the LEAPP tools' raw image reader does, reads a stream
with no new call:

```python
for path, node, mode, size, mtime, recorded in walker.listing(streams=True):
    if isinstance(node, q.NtfsStreamRef):          # "Downloads/setup.exe:Zone.Identifier"
        data = b"".join(walker.read_file(node, size))
```

Streams are listed only when asked for. `listing()`, `walk_all()`, `collect()`, `--extract`
and the window's Contents pane are as they were, because a caller that asked for a folder's
files and was handed `report.lnk:Zone.Identifier` among them would pass it to a parser
expecting a shortcut. `listing(streams=True)` names each stream `path:stream`, as Windows
does, straight after its file, with the file's modified time (NTFS keeps no dates per
stream); a stream on the root directory is `:stream`. A caller walking the tree instead asks
`streams(record)` for each entry. `--list` names every stream beside its file at its
recorded size, as it did, and now once each: before 1.37 a stream whose run list had
outgrown its record, which `$J` on a volume of any age has, was printed once per record,
all but the first at 0 B.

Two rules about holes decide what a stream is read as, and both come from metadata files
whose recorded size is not what they hold:

- **A hole at the front of a stream is not read.** Windows frees the front of `$J` as the
  journal grows and leaves a hole there, so its recorded size runs to gigabytes and all but
  its last few megabytes read as zeros. A stream is read from its first stored cluster
  instead, and its listed size is what that read returns. A USN journal parser loses
  nothing, because every record carries its own offset in the stream as its USN, and
  `front_hole(node)` gives the bytes skipped for anything else that needs the offset.
- **A stream that is all hole is not listed.** `$BadClus:$Bad` is recorded as the size of
  the whole volume and a healthy disk stores none of it. A stream of no bytes is listed,
  since it was created empty and its being there can be the evidence.

A hole after the first stored cluster is content and reads as zeros, as in a file.

Validated against a second NTFS fixture, `tests/fixtures/ntfs-streams.img.gz`, written by
`mkntfs` and `ntfs-3g` with a stream of every shape above: two `Zone.Identifier` streams, a
`$J` with a 1 MiB hole at its front and 1.8 MB of records scattered over 365 runs whose
run list overflows into a second MFT record, a `$Max` beside it, a stream sized and never written,
one with a hole in the middle, an empty one, one on a directory and one on the root, two
compressed ones (one after a hole), one on a file with two names, twelve on one file so
that five move to other records, and one whose name needs UTF-16. The self-test lists all
28 that store anything, and each matches the bytes The Sleuth Kit's `icat` reads from the
same stream, from the first stored cluster that `istat` names. `$BadClus:$Bad` and the
stream sized and never written are the two left out. The same check turns red when the
front hole is read, when a stream that stores nothing is listed, and under each of nine
further changes that break a rule here, one at a time.

`tools/make_ntfs_streams_fixture.sh` rebuilds that fixture on Linux, and refuses to finish
unless what it wrote, what `ntfs-3g` reads back, and what `fls`, `istat` and `icat` find all
agree. No Windows-written change journal is in it, because `ntfs-3g` does not keep one.

On a 1,006 MiB volume Windows wrote, `ntfs-cloud.bin.gz` in the dissect.ntfs test data (at
fox-it/dissect.ntfs `7f021dd1182eb6f9b6a2dbd19cf2e29143ea654d`, not committed here), all
seven streams that store anything are listed, `$Extend/$UsnJrnl:$J` (21,376 bytes),
`$UsnJrnl:$Max`, `$Secure:$SDS`, `$UpCase:$Info`, `$RmMetadata/$Repair:$Config`,
`$TxfLog/$Tops:$T` and a stream the OneDrive client left on its folder, and each is
byte-identical to `icat`'s reading; `$BadClus:$Bad` is left out. That journal is young
enough to have no hole at its front, so the front-hole rule is still checked against the
fixture's shape only.


### Directory indexes

Since 1.63. `NtfsWalker.directory_index(record)` gives `[("$I30", node, size)]` for a
directory whose file name index has grown into an `$INDEX_ALLOCATION` attribute, and `[]`
for any other record. The node is an `NtfsStreamRef`, so `read_file()`, `entry()` and
`stamps()` take it as they take a stream's.

What is read is the attribute as the volume stores it: one index block after another,
each `idx_size` bytes and starting `INDX`, with the update sequence array of each block
not applied. The space past a block's last entry can still hold entries NTFS has since
removed, and that is what this is for. `listdir()` is what lists a directory.

The index is not an alternate data stream. `streams()`, `listing(streams=True)` and
`--list` do not show it, and nothing that already reads a volume changes: a caller has
to ask for it.

The self-test reads the index allocation of the five directories of
`tests/fixtures/ntfs-fixture.img.gz` that have one, and checks that the blocks, fixed up,
hold with each directory's index root exactly the entries `listdir()` gives. It has not
been compared with another tool's reading of the same blocks.

### What a file stores, cloud placeholders and overlay compression

Since 1.56. The size a file records and the bytes a volume holds for it are different
numbers for a sparse file, a compressed file and a cloud provider's placeholder, and
`read_file()` hands back the recorded size in every case it reads, holes as zeros. A tool
that copies files out of an image therefore writes more than the image holds, and until
1.56 it also wrote two kinds of file that were not there at all:

- **A cloud placeholder.** OneDrive with Files On-Demand, and any other sync engine built
  on the Windows Cloud Files API, leaves a file kept online-only as a record with its full
  size, a cloud reparse tag, and an unnamed stream in which every cluster is a hole. Read
  as a file, it is its size in zeros. Windows itself will not read one with no provider
  running ("The cloud file provider is not running"), and since 1.56 neither does this:
  `read_file()` raises `NtfsUnreadable` naming the tag, the recorded size and what is
  stored, so an extraction lists the file as not read instead of writing zeros under its
  name. A cloud file that is all there (a hydrated placeholder) keeps its tag and reads
  normally.
- **An overlay-compressed file.** `compact /exe` compresses a file through the Windows
  Overlay Filter, and Store app packages, .NET native images and Defender's platform
  files were found compressed that way on the images below. The filter keeps the
  same all-hole unnamed stream and puts the real content, compressed, in a stream named
  `WofCompressedData`. Until 1.56 such a file read as zeros of the right length. It is now
  decoded: XPRESS in 4K, 8K and 16K chunks. LZX (`compact /exe:lzx`) is not decoded and
  is refused by name, as is a file of 4 GiB or more and one backed by WIMBoot, whose
  content is in a WIM file elsewhere.

`allocation(walker, node)` says what a volume stores for one file: `size` (what
`read_file()` returns), `stored` (the bytes held for the content, in whole clusters, or the
length of a resident one), `sparse`, `compression` (`lznt1`, `wof-xpress8k` and so on, or
`decmpfs` on APFS) and `placeholder`. On NTFS it adds `reparse_tag` and `attributes`, on
APFS `bsd_flags`. A walker that cannot say answers `None`. Total `stored` over the files
you are about to copy to know what they occupy; total `size` to know what you will write.

On APFS the stored figure is the data stream's `alloced_size` less the inode's
sparse-bytes field. `alloced_size` alone is the logical size for a sparse file, holes
included. Measured on a volume macOS 27 wrote: the difference equals the blocks `stat`
reports on five of five sparse files (a 100 MB file storing 32 KB among them), and the
figure equals `stat` on the three ordinary files beside them. `placeholder` on APFS is the
`SF_DATALESS` flag (iCloud Drive with optimised storage sets it). That is taken from
`sys/stat.h` and is not exercised: no image holding a dataless file has been read.

Validated against a volume Windows 11 (build 26200) wrote,
`tests/fixtures/ntfs-windows.img.gz`, built by `tools/make_ntfs_windows_fixture.cmd`:
five files compressed with each of `compact /exe:xpress4k`, `xpress8k`, `xpress16k` and
`lzx` (text, text of exactly 32,768 bytes, a 5,000 byte file, text around 20,000 random
bytes, and zeros around text; 7 of the 161 XPRESS chunks are stored plain), two NTFS
compressed files, five sparse files, a plain file, a resident file, a file with two names, three
online-only placeholders the Cloud Files filter wrote through `CfCreatePlaceholders`, and
one cloud file converted in place and left whole. The manifest beside it holds what
Windows said about each: its length, its size on disk, its SHA-256, and whether Windows
could read it. The self-test requires all 27 files Windows hashed to read to the same
hash, the three Windows refused to be refused and to be the only placeholders, the five
LZX files to be refused by name, and `stored` to equal Windows's size on disk on all 25
sparse and compressed files whose content lies in clusters. Then it switches each rule
off in turn and requires the comparison to fail: reading the unnamed stream of an
overlay-compressed file, reading a placeholder's hole, and taking every XPRESS file to be
in 4 KiB chunks. The algorithm numbers in the reparse point (0 XPRESS4K, 1 LZX,
2 XPRESS8K, 3 XPRESS16K) are what that volume holds for each.

On real evidence: two public Windows 10 acquisitions hold 1,873 overlay-compressed files
between them, all XPRESS8K, and all decode to their recorded length. 843 of them are
executables carrying an Authenticode signature, and the digest computed from the decoded
bytes is in the signature on every one. 43 more match the checksum in their PE header.
27 differ from that checksum and carry nothing else to check them against; 34 of the 843
differ from it the same way and are proven by their signatures, so a stale header
checksum is something those files have. A public Windows 11 acquisition holds four LZX
files, which are refused, and one OneDrive file kept online-only: 1,151,898 bytes
recorded, none stored, reparse tag `0x9000401A`, the attributes `SPARSE_FILE`,
`REPARSE_POINT`, `OFFLINE` and `RECALL_ON_DATA_ACCESS`, the tag and the four attributes
the fixture's placeholders carry. It read as 1,151,898 zero bytes before 1.56 and is
refused now.

Not exercised: a cloud file held in part, some ranges present and some with the
provider. It is refused on its `RECALL_ON_DATA_ACCESS` attribute, because its holes are
missing data and not zeros, and no image holding one was found; Windows would not make
one without a provider running (`CfDehydratePlaceholder` answered `0x8007016A`).

### NTFS compression units that stop early

Since 1.57. An NTFS-compressed file is stored in units of 16 clusters, and a compressed
unit is a series of LZNT1 chunks of up to 4,096 bytes of output each. A unit does not
have to be full. A chunk header of zero ends it, and the rest of the unit is zeros.
Until 1.57 `read_file()` returned only what had been decoded up to that point, so the
file came back shorter than its recorded size with nothing said, and any unit after the
short one was returned at the wrong offset.

This is how ntfs-3g reads one: a zero header ends the unit
([compress.c lines 506 to 507](https://github.com/tuxera/ntfs-3g/blob/7f0f841fc52cf719106c5c93bafe465004e36816/libntfs-3g/compress.c#L506-L507))
and what is left of it is filled with zeros
([lines 683 to 685](https://github.com/tuxera/ntfs-3g/blob/7f0f841fc52cf719106c5c93bafe465004e36816/libntfs-3g/compress.c#L683-L685)), as is a
compressed chunk that inflates to fewer than 4,096 bytes
([lines 668 to 676](https://github.com/tuxera/ntfs-3g/blob/7f0f841fc52cf719106c5c93bafe465004e36816/libntfs-3g/compress.c#L668-L676)). A chunk
that runs past the unit's stored bytes, a stored chunk that is not 4,096 bytes long and
a back reference to before its own chunk are refused there
([lines 522 to 523](https://github.com/tuxera/ntfs-3g/blob/7f0f841fc52cf719106c5c93bafe465004e36816/libntfs-3g/compress.c#L522-L523),
[531 to 533](https://github.com/tuxera/ntfs-3g/blob/7f0f841fc52cf719106c5c93bafe465004e36816/libntfs-3g/compress.c#L531-L533),
[626 to 627](https://github.com/tuxera/ntfs-3g/blob/7f0f841fc52cf719106c5c93bafe465004e36816/libntfs-3g/compress.c#L626-L627)), and here
`read_file()` raises `NtfsUnreadable` for them. Until 1.57 those three also ended the
unit quietly.

Measured on four public Windows acquisitions (three of Windows 10, one of Windows 11):
846 NTFS-compressed files, 17,442 compressed units. 17,440 decode to a full unit and
are byte for byte what 1.56 returned. Two stop at a zero header, one on each of two
images, both in a OneDrive sync engine log (`SyncEngine-*.aodl`):

| recorded size | stored | 1.56 returned | 1.57 returns |
| ---: | ---: | ---: | ---: |
| 129,947 | 73,728 | 65,536 | 129,947, the second unit as zeros |
| 61,521 | 20,480 | 0 | 61,521, all zeros |

The Sleuth Kit 4.15.0 (`icat`) returns the same bytes as 1.57 for both, by SHA-256. In
the second file the unit's five stored clusters are not empty: the first two are zeros
and the other three hold 11,223 non-zero bytes. By the rule above those bytes are not the
file's content, and neither reader returns them. They are on the volume, in the clusters
`allocation()` counts as `stored`. None of the 17,442 units met any of the three
refusals.

The self-test changes one unit of the Windows-written fixture's `lznt1/text_100000.txt`
in three copies of the volume: the second unit's first header set to zero, the first
unit's first header set to zero, and a second unit that opens with a back reference. The
first two have to read to the SHA-256 `icat` gave for the same changed volumes, which is
also what the file's own bytes give with that unit replaced by zeros. The third has to
be refused, and `icat` stops with an error at that unit. Then it runs the first two with
a decoder that ends the unit at the zero header and requires both to fail.

Not changed: the initialized size of a compressed stream is not applied, as it is for a
stream that is not compressed. One of the 846 files has one below its size (8,192 of
8,448 bytes), and the bytes past it decode to zeros anyway.

### FAT32 and exFAT times are readings, and are listed as such

A FAT32 or exFAT file's times are a wall clock the volume stored with no zone
(exFAT stores a UTC offset beside each one, which is shown and not applied), so a
walker for either gives `entry()` an mtime of 0 and hands the readings out through
`listdir_records()` instead. `--list` prints them that way, `modified 2023-06-01
12:00:00 (as stored, no zone)`, never as an instant and never as `1970-01-01`,
and the window's Contents pane puts them in a **Recorded (as stored)** column with
the three (UTC) columns left blank.

### Deleted files on FAT32 and exFAT

FAT32 and exFAT recover deleted files too, through `Fat32Walker.deleted_files()` and
`ExfatWalker.deleted_files()` with the same `read_deleted()` reader. A FAT32 delete
writes `0xE5` over the first byte of the directory entry and frees its clusters in the
FAT; an exFAT delete clears the in-use bit of the entry's type byte and the file's bits
in the Allocation Bitmap. Either way the name, first cluster, size and recorded dates
survive, so a deleted file comes back with all of them.

What neither keeps is where a fragmented file's later clusters lay: FAT32 zeroes the
chain on delete, and exFAT keeps a chain only for a file it wrote fragmented in the
first place. So a file that occupied one run is recovered exactly, and one whose size
would need clusters that a later file has since taken is reported as having existed
rather than read, because reading it would splice in bytes that now belong to something
else. A recovered file says in `assumed_contiguous` whether its layout was taken on the
one-run assumption or from a chain the volume still held. A deleted directory whose
first cluster is still free and still parses as a directory is walked into, so a folder
of photographs deleted whole comes back file by file.

Validated the same way as NTFS. `tools/make_fat_deleted_fixtures.sh` builds a FAT32 and
an exFAT image, each with a folder of two photographs and one fragmented photograph,
created and then deleted; the self-test recovers them from the directory entries and
matches the hashes taken before deletion, and The Sleuth Kit's `icat` recovers the same
bytes from the same entries. The fragmented file that lands across reused space is
refused by this reader and is the one case `icat` will read on the contiguous
assumption; refusing it is the deliberate choice not to present bytes the entry cannot
vouch for.

### exFAT: orphan directory entries

Since 1.61. An exFAT volume can hold directory clusters that the Allocation Bitmap marks
in use and that the directory tree no longer reaches. The file entry sets in such a
cluster are still marked in use and still carry a valid checksum, and the files they name
can still be allocated too. A listing does not show them, because it follows the tree, and
`deleted_files()` does not either, because it reads the entries marked deleted in live
directories.

`ExfatWalker.recover_deleted()` lists them and `read_deleted()` reads one:

```python
w = qnxprobe.ExfatWalker(fh, base)
for e in w.recover_deleted():                 # FlashDeletedFile, kind "exfat"
    print(e.parent_path, e.name, e.size, e.times["modified"], e.recoverable, e.reason)
    if e.recoverable:
        data = b"".join(w.read_deleted(e))
```

The method keeps the name the flash readers use so a caller handles one interface. The
name is not a finding: nothing in an orphan entry says its file was deleted. Each record
says what it is in `note`, and none of them is ever added to the live listing.

- **What counts as reached.** The root directory's chain, every directory's clusters,
  every file's clusters (the run its size needs when NoFatChain is set, else its whole
  chain in the first FAT), both allocation bitmaps and the up-case table. The tree is
  walked once per walker, the first time `recover_deleted()` is called.
- **What is searched.** Every allocated cluster outside that set, for a `0x85` File entry
  followed by its `0xC0` stream extension and `0xC1` name entries, with the checksum the
  File entry records. A set that runs off the end of its cluster is completed from the
  cluster the first FAT links next, or the one after it, and the checksum decides.
- **Directories are walked down.** The clusters an orphan directory entry names are read
  as its directory when they are allocated and unreached, so a file under it has
  `parent_path` set to the directory names that lead to it. A file whose entry sits in a
  cluster no orphan directory entry names has a `parent_path` of `None`: nothing on the
  volume says what that directory was called. `parent` is the cluster the entry set is in
  and `ident` the file's first cluster.
- **When a file is recoverable.** Its size is not zero and every cluster it names is
  allocated and unreached: the run when NoFatChain is set, else a chain in the first FAT
  that runs to an end-of-chain mark and covers the size. Otherwise `reason` says what
  failed, and `read_deleted()` refuses it. A cluster a live file holds is never read as
  the orphan's.
- **Times are readings.** `mtime` and `mode` are `None`. `times` holds the stored readings
  and UTC offset fields as `listdir_records()` gives them, for the reason under
  [FAT32 and exFAT times](#fat32-and-exfat-times-are-readings-and-are-listed-as-such).
- **Copies are one record.** Entry sets that are byte for byte the same in several
  clusters come back once, and `note` gives the count. When two different entries name
  the same cluster both stay recoverable and `note` says the bytes may be another file's,
  because the volume does not say which wrote last.

It does not search free clusters, does not follow the second FAT, does not list entries
marked deleted, and does not list the orphan directories themselves. Why a volume holds
such clusters is not established here.

Measured on four exFAT partition images, corpus keys `xtrmp_item014` and `xtrmp_item016`,
all with 4,096-byte clusters and two FATs:

| | item016 p2 | item016 p3 | item014 p2 | item014 p3 |
|---|---:|---:|---:|---:|
| allocated clusters | 174,593 | 8,368 | 164,081 | 7,584 |
| allocated and not reached | 60,345 | 6,507 | 1,139 | 0 |
| of those, clusters holding entry sets | 349 | 2 | 18 | 0 |
| orphan file entries | 2,858 | 14 | 198 | 0 |
| recoverable | 2,455 | 2 | 97 | 0 |
| recoverable bytes | 125,969,784 | 13,328 | 285,706 | 0 |
| recoverable with a `parent_path` | 1,481 | 0 | 0 | 0 |
| not recoverable: same first cluster and size as a live file | 345 | 2 | 93 | 0 |
| not recoverable: names a live file's or directory's clusters | 5 | 3 | 4 | 0 |
| not recoverable: names free clusters | 42 | 2 | 2 | 0 |
| not recoverable: fewer clusters than the size needs | 4 | 4 | 0 | 0 |
| not recoverable: empty | 7 | 1 | 2 | 0 |

Every recoverable file read back at its recorded size. On item016 p2, 608 entries were in
more than one cluster, 3 recoverable ones carry the shared-cluster note, and the 2,455
recoverable files hold 1,947 distinct contents. One of them is 17,408 bytes with a
`.sqlite` name; it opens as SQLite and `PRAGMA integrity_check` answers `ok`. Listing took
under half a second per image on the machine that measured it. The images had been read
before, so that is not the time of a cold read.

A second count, written without this reader's search code, agrees on the allocated and
unreached clusters of all four images and finds every entry set that lies inside one
cluster: 2,833, 14, 197 and 0. The reader lists all of those and 25, 0, 1 and 0 more. Those
are taken to be the sets it completes across a cluster boundary, which was not checked set
by set.

No reference reading exists for these volumes, so beyond that one SQLite file it is not
established that the bytes returned are each file's content. The known data is the
self-test's: it builds a volume with a live tree and unlinked directory clusters, writes
each set's checksum from the specification's formula and not with the reader's function,
and requires the names, directory paths and bytes back. It also requires a refusal for a
file that names a live file's cluster, a free cluster or a short chain, and nothing for a
deleted entry, a bad checksum, or a valid entry set placed in the up-case table, in a live
file's content or in a free cluster. The reader's checksum is held against a driver's on
the committed exFAT fixture, which macOS wrote: all 4 of its in-use file entries match.

## ReFS

ReFS is Microsoft's Resilient File System. Windows 11 formats it as a Dev Drive, and Windows
Server uses it for data volumes. `--list` and `--extract` read ReFS 3.x directly. A volume is
claimed by `ReFS` at byte 3 of its boot sector together with `FSRS` at byte 0x10, and the
report gives the version the boot sector records, the label, and the checkpoint it read:

```
    GPT part 2 Basic data partition   50.0 GiB   ->  refs
        version      ReFS 3.14 (boot sector)
        bytes/sector 512   sectors/cluster 8   cluster 4,096 bytes
        volume       49.9 GiB (104,726,528 sectors)
        serial       b0d61ca3d61c6c3a
        label        REFSRICH
        checkpoint   clock 37 at cluster 1,570,928, written as ReFS 3.14
        log          no record follows the checkpoint
```

Microsoft publishes no specification of ReFS, so the reader follows two public
descriptions, and every field it uses was checked against volumes Windows wrote:

- xbqt/forefst, commit `d4d5fd28942eb14ebe11d90f4eb9342f5e3d7b92`, the pages under
  `docs/structures/` and `docs/concepts/` (GPL-3.0; read, no code taken)
- libyal/libfsrefs, commit `77e1b7ba68cf225ec888a61e9784fb9a93a0156f`,
  `documentation/Resilient File System (ReFS).asciidoc` by Joachim Metz (GFDL 1.3)
- Microsoft's [MS-FSCC] 2.1.2.4 and 2.1.2.5 for the symbolic link and mount point data

The comment above `RefsWalker` in `qnxprobe.py` names the page each structure comes from.

What it reads: of the three superblock copies, the one with the highest clock whose own
checksum holds; the newer of the two checkpoints (a tie is reported); the container table
that turns the virtual cluster numbers everything else uses into real ones; the object
table; and each directory's B+ tree. The superblock and checkpoint carry their own
checksums. Every B+ tree page is checked against the checksum its parent's reference
records for it, and that checksum has to be of the kind the volume uses: the one the boot
sector's selector (0x2A) names, CRC-64/NVME or SHA-256, or for a volume whose selector is 0
the one its checkpoint's reference size implies. A reference carrying no checksum or
another kind is refused. A page that does not match is named in `RefsWalker.damage` and
its rows are left out, rather than read from bytes that are not what was written; the rest
of the volume is still listed. A walk reads each page at most once, so references that
point back up a tree cannot make it loop. `damage` keeps the first 1,000 problems and
`damage_count` counts all of them.

What it treats as damage rather than reads past, each because none of the six volumes
measured shows it: a container whose first cluster is not a multiple of its size, that
reaches past the volume or overlaps another; a run crossing the end of its container; two
extents over one cluster of a file; extents reaching past the stream's allocation; a file
not marked sparse with clusters no extent covers (they read as zeros, and are reported); a
directory named in two places or naming the root; and a stream larger than the 35 PB
Microsoft gives as ReFS's largest file. A file whose record does not check out is still
listed, with the size and time its name row holds, and reading it fails with the reason.

A file's content is read from its record when ReFS keeps it inline (small files) and from
its extents otherwise, including an extent map that has grown into child pages. Holes in a
sparse file, and runs ReFS reserved or allocated but had not written, read as zeros, as
forefst describes. On forefst's sample volumes 32 such runs sit over clusters that are not
zero; among what is there are copies of the generating script's file header in the middle
of a file and, in one case, a B+ tree page, neither of which belongs in the file. A file with stream
snapshots (`refsutil streamsnapshot`) keeps in its live stream only what changed since its
last snapshot; the rest is read from the most recent snapshot that holds it, as the driver
does. A file that was moved or
given a second name keeps its record in the folder it was created in, and the reader
follows it there. Each name of a hard-linked file lists the one record, and
`RefsWalker.link_count(node)` gives the number of names. Symbolic links and junctions are
listed as links with `readlink()` giving their target, and are not followed. Alternate data
streams are listed by `named_streams(node)` and read through `stream_ref(node, name)`,
including a stream on a directory.

ReFS keeps four times per file, as NTFS does. `stamps(node)` gives created, modified and
accessed in Unix seconds, like `NtfsWalker.stamps`; `filetimes(node)` gives all four
FILETIMEs as stored, with the change time, to the 100 ns. A file's times come from its own
record. The name row of a moved or linked file keeps a copy that ReFS refreshes only when
that name is opened, so it can be older, and two names of one file can disagree; the record
is the one ReFS updates at once (forefst `concepts/hard_links.md`). A directory's times
come from its own record except the change time, which is taken from its name row in its
parent: forefst measured that copy, not the record's, against what PowerShell reports
(`attributes/STANDARD_INFORMATION.md`). On the Windows fixture here the two copies never
differ, so that rule rests on forefst's measurement. `file_id(node)` gives the two halves of
the 128-bit file id Windows reports. `allocation(node)` answers with the same keys as on
NTFS; for a file held in extents `stored` is the stream's own allocation (which counts
reserved runs) plus any clusters a snapshotted file reads from its snapshots, and it equals
the allocation Windows reported for every such file on the fixture and forefst's for every
one on its four sample volumes.

### The log is not replayed

ReFS writes each change to its metadata log first and folds it into a checkpoint later.
Windows replays the log when it mounts the volume. This reader does not: it shows the volume
as of its newest checkpoint, and says how many log records follow that checkpoint. On a
volume Windows detached cleanly the count is zero. The first test volume was detached
seconds after its files were written, and its checkpoint predates every one of them:

```
        checkpoint   clock 20 at cluster 1,570,928, written as ReFS 3.14
        log          16 metadata log records follow the newest checkpoint. Windows applies
                     them when it mounts the volume; this reader does not, so it shows the
                     volume as of that checkpoint, and what changed after it is missing or
                     older here
```

Its root lists empty here, which is what its checkpoint holds; the six files Windows hashed
on that volume while it was mounted are in the log only. If you see this line, image the volume as it is and do not mount it first:
a mount replays the log and writes a new checkpoint, and the log records are evidence of their
own. The reader counts them and decodes none of them.

### What it refuses, and what no fixture exercises

Refused, with the reason in the error or the report:

- ReFS 1.x and 2.x, which keep their metadata in another layout, and any version past
  3.14, which no source describes. The volume is identified and its version reported;
  nothing is listed.
- An encrypted file's content (the EFS attribute is set: what is on disk is ciphertext).
- Data in a container marked compressed. forefst (`concepts/compression.md`) says ReFS
  compresses by container, marked by bit 0x800 of a flags word loaded from the container
  table row; that it is the row's flags field (+0x14) is inferred, and no sample with
  compressed data was to hand, so such data is refused rather than returned compressed.
  The report names the volume's compression policy when it is set.
- A stream record laid out other than as ReFS 3.14 writes it. forefst gives the record written
  by ReFS 3.4 to 3.10 another summary size, and on 3.4 its size fields four bytes later; no
  such volume was to hand.
- A large alternate data stream when more than one extent record matches it. ReFS keeps such
  a stream's extents in a separate record that does not name the stream; forefst ties the two
  by size, and the reader also requires the allocation to agree and refuses a tie.

Handled from the descriptions but not exercised by any real volume: the backup superblocks
and the second copies of the container and object tables (read only when the first fails
its checksum), volumes upgraded from an older ReFS, and the direct form of the checkpoint's
root list. Per-cluster data checksums, which a volume with integrity streams keeps, are not
verified while reading; the self-test checks what is read against them (below).

Not done: deleted files are not recovered, free space is not reported (so `--unallocated`
skips ReFS), and the change journal is not read.

### Checked against what Windows wrote, and against forefst

`tools/make_refs_fixtures.ps1` builds a ReFS 3.14 Dev Drive in a VHDX on Windows 11 build
26200 and records, from the mounted volume, every entry's type, size, allocation, link
count, attributes, four FILETIMEs, file id and link target, the SHA-256 of every file and
stream, and the paths it created and then deleted. On that volume the reader walks all
2,620 entries Windows listed, each with its type, size, four FILETIMEs, file id and link
target as Windows reported them, and for each file its link count, attributes and, for a
file held in extents, its allocation. It reads all 2,544 files
and the 3 streams back to Windows's hashes, lists none of the 17 deleted paths, and
`--extract` writes 2,547 files (the 2,544 plus 3 Windows keeps under `System Volume
Information`) whose hashes match, with the 5 links skipped.

A 50 GB volume cannot be committed, so `tools/make_refs_fixture.py` keeps only the bytes
the reader reads, each at its own offset: `tests/fixtures/refs-fixture.bin.gz` (516,202
bytes) and `tests/fixtures/refs-dirty.bin.gz` (14,918 bytes), with what Windows reported in
`tests/fixtures/refs-fixture.known.tsv.gz` (126,522 bytes). The content of the 4 files holding
more than 256 KiB of random bytes is left out by name, and their records kept. Every entry, time, id,
link, stream and every shipped file's content reads the same from these as from the VHDX
files. The first test volume's log held the machine security identifier of the Windows
computer that wrote it in 2 records; its three machine numbers are replaced with 1-2-3 and
those records' check values recomputed, which the tool prints.

The self-test runs nineteen ReFS checks on these. Ten use the volumes as Windows wrote them,
or broken on purpose: the listing and every field above, the hashes, the streams, the
deleted paths, the 16 log records, one letter of one name changed in a directory page
(reported, that page's rows left out), a boot sector saying 2.x (refused), and a byte
changed in a log record (the count stops before it). Nine check one rule each on the
fixture or on records the self-test builds: `stamps()` in Unix seconds; an unwritten run
and bytes past the valid length reading as zeros; container arithmetic, a run crossing a
container, a compressed container and containers that cannot be where the table says; a
directory's change time from its name row; a snapshot not listed as a stream, and snapshots
read newest first; short snapshot rows, overlapping extents, a 2^60-byte stream, an
encrypted file, a gap in a file not marked sparse and extents past the allocation; a page
named twice in one table, a cached page asked for under another digest or checksum kind, and
the damage cap; directory rows naming the root or a directory named elsewhere; and versions
3.15 and 9.99, the superblock clock and a checkpoint tie. Each of 26 deliberate changes to
the reader, one per rule, fails at least one of these with forefst's volumes absent.

forefst publishes four sample volumes with its own output for each (GPL-3.0; nothing from
them is in this repository). Where they are mounted, at `/Volumes/Corpus/Data for
DLEAPP/Public_Test_Images/forefst-ReFS` or the folder `QNXPROBE_REFS_SAMPLES` names, the
self-test runs ten more checks on them, comparing each with forefst's inventory entry by
entry, and skips them otherwise:

| Corpus key | Volume | What it adds |
|---|---|---|
| `forefst_refs314_64k_sha256` | `wininsiderrefs8gtest2` | 64 KiB clusters, SHA-256 metadata checksums (Insider build 29574) |
| `forefst_refs314_specials` | `win11refs2tspecials` | hard links, symbolic links, streams, file tables grown into child pages |
| `forefst_refs314_snapshots` | `win11refs2tsnapshots` | stream snapshots, a stream held in extents |
| `forefst_refs314_usn` | `win11refstestmftecmd` | integrity streams, an extent map in child pages (a 226 MB file) |

On all four, every entry forefst lists is walked and nothing else (894, 1,550, 304 and
1,744), with forefst's type, size, file id, home directory, link count, allocation, link target
and stream names for each, no page failing its checksum and no log record after the
checkpoint. The times agree on every directory and on every file except moved or linked
files whose name row differs from their record: forefst prints the name row's copy, which
holds exactly forefst's values on every one (44, 58, 1 and 174 names, files and symbolic
links, which are 37, 30, 1 and 98 distinct files by file id), and the
reader prints the record's. forefst lists the two names of one such file with different
times, which one record cannot hold. On the integrity volume, what the reader returns for
3,000 clusters of files with integrity streams matches the CRC32-C ReFS stored for each
cluster, the 226 MB file among them (all 111,338 such clusters on that volume matched when
checked in full, outside the self-test). On the snapshot volume `test.txt` reads `abc\r\n`,
the live version forefst's `snapshots_versioning.md` gives for it. Its live stream holds no
cluster of its own, so read without its snapshots it would have been five zeros.

## BitLocker

Since 1.43 a BitLocker volume is recognised by its own header and, given a key, read
decrypted in place, so the filesystem inside it (NTFS, FAT32 or exFAT) is listed and
extracted like any other. Before 1.43 its header, which is a FAT32 boot sector in all but
BitLocker's own signature and identifier, was taken for an empty FAT32 volume.

Without a key the volume is listed as `bitlocker` and not walked. The report gives what
the volume records about itself: the encryption method, its description (the computer
name, drive label and date Windows wrote when it was encrypted, as stored), when it was
created, its volume id, and each key protector with its id. The note says what would
open it, naming the recovery password's protector id, which is the id to quote when
asking for the recovery key from wherever it was escrowed.

A key is one of:

- its password or recovery password, with `--password-file FILE` or `--password-env NAME`,
  the options an encrypted image takes (each one given is tried as both);
- its startup key, a `.BEK` file, with `--bitlocker-key FILE`;
- nothing, when protection is suspended: the volume then keeps its key in the clear, and
  the report says `suspended`.

A volume whose only protector is its TPM cannot be read from an image, because the TPM's
key never leaves the device; a recovery password set on the same volume still opens it.
The window asks for a password or recovery password for each locked volume when it
loads an image, and takes a `.BEK` file when the answer is left empty.

From Python:

```python
image = q.open_image(path)
image, found = q.unlock_bitlocker(image, passwords=[recovery_password], key_files=["key.BEK"])
for vol in q.volumes(image):
    print(vol["kind"], vol.get("encryption", ""), vol.get("note", ""))
```

`unlock_bitlocker()` returns the image with every volume it opened decrypted in place,
so `read_at()` at that volume's own offsets returns plaintext and every walker, free
space report and extraction sees the decrypted volume; it also returns one `BitLocker`
per volume found, opened or not, whose `lines()` is what the report prints. A volume it
opened carries `encryption` in `volumes()` (`BitLocker AES-128-XTS, unlocked with its
recovery password`), and a locked one carries `BitLocker, locked` and the note.

**What is read**: AES-128 and AES-256 in CBC and XTS modes, the layout Windows 7 and later
write, and a volume whose conversion was paused while encrypting or decrypting. Such a
volume carries an Encrypt-on-Write map saying which ranges are not yet encrypted, and
those are read as stored. **What is not**: the Elephant diffuser (Windows Vista and 7), the
Windows Vista layout, and a TPM; each is named in the note. The BitLocker To Go layout
for FAT volumes (Windows 7's discovery volume on removable drives) is read the same way,
but no sample of it exists here, so it is tested only on constructed volumes.

A volume encrypted with "used space only" encrypted only the space holding data at the
time, and its free space is not wiped
([Microsoft, BitLocker configuration](https://learn.microsoft.com/en-us/windows/security/operating-system-security/data-protection/bitlocker/configure)).
Space that was free then and not written since can still hold earlier data in the clear,
and reading it through the key turns that into noise. If deleted files from before
encryption matter, carve the partition as stored as well as decrypted.

Decryption is pure Python over the `pycryptodome` package the release executables carry:
on an Apple M2 Max, about 80 MB/s for XTS and 120 MB/s for CBC.

Checked against 13 volumes Windows 11 Pro (build 26200) wrote: NTFS with each of the four
methods, FAT32 and exFAT, a suspended volume, two fully encrypted ones, and four whose
conversion was paused (encrypting used space only at 93.8%, and three paused early:
encrypting at 45.6%, encrypting used space only at 58.6%, decrypting with 63.8% still
encrypted). On every one, every file written before encryption hashed as Windows
recorded, each opened with each of its keys given alone (the suspended one with the
clear key, which is tried first), and the protector ids equal those Windows reports
(less the clear key of the suspended volume, which Windows does not list as a
protector). With the Encrypt-on-Write map ignored, the three early ones lost 8 and 9 of
their 25 files, and the one being decrypted was not recognised as NTFS at all. Those
volumes are kept outside this repository; `tools/make_bitlocker_fixtures.py` builds the
small ones the self-test reads.

## LUKS

Since 1.67. A LUKS1 or LUKS2 container is reported as `luks`, with its version, cipher,
key size, where its data starts and its keyslots. Given a passphrase (`--password-file`,
`--password-env`, or `unlock_luks()` from Python, which tries each one on each keyslot),
its data is read decrypted in place, as a region of its own labelled
`LUKS <where the container is>` and named `luks_lba<first sector of the data>`, so the
filesystem or LVM2 physical volume inside is identified, listed, walked and extracted
like any other, also when the container is inside a logical volume that is one run of
extents. Without a passphrase that opens it, the container is listed as locked and says
so; a header that does not read, or that names a cipher, a feature or a cost this does
not take, is listed as not read and says why, before any passphrase is asked for, and
costs the image nothing else. Apply `unlock_luks()` before `lvm_image()`, so a physical
volume inside a container is seen, and after `unlock_bitlocker()` and `unlock_apfs()`; a
BitLocker or APFS volume inside a LUKS container is therefore not opened. A passphrase
is text: key files and binary key material are not taken, and `--password-file` takes
its first line.

The layouts are cryptsetup's (docs/on-disk-format.pdf for LUKS1, on-disk-format-luks2.pdf
for LUKS2). A passphrase opens a keyslot through its key derivation (PBKDF2 with the
hashes hashlib has; Argon2i and Argon2id with the argon2-cffi package, which is needed
only for those), the key decrypts the keyslot's material, the material is merged from its
anti-forensic stripes into the master key, and the master key counts as right only when
its PBKDF2 digest matches the one a digest stores for that keyslot. A keyslot's key is
derived at the length its area names (luks2_keyslot_luks2.c), which need not be the
volume key's. A LUKS2 header is stored twice; each copy's checksum and the place it
records for itself are checked, the second copy is looked for at cryptsetup's fixed
offsets too when the first does not give its size, and of the copies that pass, the one
with the higher sequence id is read. Costs past cryptsetup's own limits (Argon2 memory
over 4 GiB, and iteration and stripe counts no benchmark gives) are refused, not run. The data is decrypted sector by sector with AES in XTS (plain64, plain) or CBC
(essiv, plain64, plain), each sector's IV its number from the start of the data in
512-byte units, also when a LUKS2 segment's sectors are 4096 bytes, plus the segment's
`iv_tweak`. XTS-plain64 and CBC-ESSIV are exercised by the fixtures; XTS-plain,
CBC-plain64 and CBC-plain, and a non-zero `iv_tweak`, are checked only on constructed
input (the 32-bit wrap of plain, and the tweak's shift). AES needs the pycryptodome
package, as BitLocker does.

The fixtures were written by cryptsetup 2.8.4 (`tools/make_luks_fixtures.sh`): LUKS2 with
Argon2id and two keyslots, LUKS2 with PBKDF2-SHA256, both AES-XTS with 4096-byte sectors,
and LUKS1 with AES-XTS and with AES-CBC-ESSIV:SHA256, each holding ext4 with a file
whose every 4 KiB block names its own number. The keyslot space no slot uses, which
cryptsetup fills with random bytes, is zeroed so the images compress
(`tools/luks_zero_unused.py`), and cryptsetup then opens each with its passphrases and
refuses a wrong one. `--self-test` checks each header against cryptsetup's own
`luksDump`, every file against sha256sum over the source tree, the second keyslot's
passphrase, a wrong passphrase, a LUKS2 header copy that fails its checksum and one with a
higher sequence id, a copy that records another place, both copies damaged, an unknown
version, crafted metadata (a missing field, keyslots that are not an object, a size that
is not a number, dm-integrity, a serpent cipher, an Argon2 memory cost of 4 TiB), a
digest limited to one keyslot, a keyslot key shorter than the volume key, a container
written inside a logical volume, and, as a control, that counting a 4096-byte sector's
IV in 4096-byte units would have decrypted every sector after the first wrongly. Not
exercised: a LUKS container on a real disk image.

## F2FS

F2FS is the filesystem Android uses for `/data` on most phones, so an Android
image or a bare `userdata` partition can carry one where an older device would have
ext4. `--list` and `--extract` read it directly. The volume is claimed by its 4-byte
magic 1024 bytes in, together with the reserved inode numbers the format fixes (node 1,
meta 2, root 3) and a block size and segment size it allows, rather than by the magic
alone.

What it reads: files stored inline in the inode, files addressed by the inode's own
pointer list, and larger files reached through direct, single- and double-indirect node
blocks; directories in both the inline and the multi-block form; and symbolic links.
Timestamps are real UTC instants, so a `--list` shows Modified and, in the window,
Created and Accessed. To find a file the reader resolves each node id through the Node
Address Table, choosing the current copy of each NAT block from the active checkpoint's
bitmap and applying any override in the checkpoint's NAT journal, exactly as the kernel
does.

What it does not do: a file with per-file encryption (the norm on a real Android
`/data`) is listed and its content refused, since the volume holds no key, and its name
is shown as stored; a compressed file (LZ4/LZO/zstd clusters) is listed with its
recorded size and not decompressed. See [What it does not do](#what-it-does-not-do).

Validated against two independent readers. On a fixture `mkfs.f2fs` and `sload.f2fs` wrote
(`tools/make_f2fs_fixture.sh`), every file inside the inode matches what `sha256sum`
recorded over the source tree, and the one file large enough to reach direct and
single-indirect node blocks matches what f2fs-tools' own `dump.f2fs` extracts. On a second
fixture the Linux kernel driver itself wrote by mounting a volume and writing sparse files
(`tools/make_f2fs_hole_fixture.sh`), files full of holes read back the same bytes the
kernel read, holes as zeros. That kernel-written image also carries seven NAT-journal
entries in the compact summary form, every one of them overriding an on-disk NAT entry
that reads unallocated, so the journal path is not just exercised but load-bearing there:
without it no file on that volume resolves. The journal in the normal (non-compact)
summary form is read by the same rules and is not exercised by either fixture. No real
F2FS volume is in the test corpus yet, and the double-indirect path (reached only past
about 8 GiB in one file) is not exercised at all.

A defect in 1.28 is worth knowing about: the bitmap that says which copy of each NAT
block is current was read with bit 0 as the least significant bit of a byte, but F2FS's
own `f2fs_test_bit` puts bit 0 at the most significant end. Every fixture then had that
bitmap all zero, so the two orders agreed and nothing showed it. A third fixture
(`tools/make_f2fs_free_fixture.sh`, root required) has the kernel write the volume in two
mount sessions, which rewrites NAT block 0 and sets the bitmap's first bit. Measured on
it: 1.28 finds no files at all, and the kernel reads 44; 1.29 reads the same 44 byte for
byte. So the failure of the old order is an empty walk that looks like an empty volume.
Fixed in 1.29, where the SIT version bitmap is read the same way, and that fixture's
self-test leg refuses to pass unless the bitmap really does carry a set bit.

The same fixture deletes a 1 MiB file, each of whose 256 blocks names its own index,
before the second checkpoint, on a `nodiscard` mount so the loop device does not zero
what it frees. All 256 blocks are still in the image and all 256 lie inside the runs
`free_extents()` reports, which is the property a carve scoped to free space depends on.
Both kernel-written fixtures also carry six SIT-journal entries that differ from the
on-disk table, so that override is load-bearing for the free-space answer too.

Since 1.29 `F2fsWalker.free_extents()` reports the space the volume says is free, from the
segment information table: one validity bit per block of the main area, 512 per segment,
set by the filesystem's own `f2fs_set_bit` (bit 0 at the top of the byte, the same trap as
above), the current copy of each SIT block chosen by the checkpoint's SIT version bitmap
and any entry in the cold-data summary journal overriding the table. Only the main area is
reported; the superblock, checkpoint, SIT, NAT and SSA areas are the filesystem's own. The
self-test holds it against the checkpoint's own `valid_block_count` and against position:
on both committed images the blocks live files and their nodes occupy equal that count
exactly, none of them lies in a reported run, and the runs plus those blocks tile the main
area. Read least-significant-first, the same map put 14 live blocks of one image inside
"free" runs while the total still matched, which is why the check is positional.

## Linux flash filesystems

Since 1.31. Embedded Linux keeps its filesystems on flash, and four formats cover most
of what turns up: SquashFS for a read-only system image, JFFS2 on NOR flash, UBI with UBIFS on NAND,
and YAFFS on older NAND. `--list` and `--extract` read all four, on their own or inside a
raw flash dump (see [Raw flash dumps and NAND spare bytes](#raw-flash-dumps-and-nand-spare-bytes)).
Each reader follows the kernel code (for YAFFS, Aleph One's own code) that reads the
format, cited line by line in the source and under
[Where the constants come from](#where-the-constants-come-from).

The fixtures come in two kinds. Most were written by the format's own tools
(squashfs-tools 4.7.5, mtd-utils 2.3.0, and Aleph One's yaffs2 built from source) from a
source tree chosen for its shapes, and each reader is held against oracles it never
touches: `sha256sum` over the source tree for the content of every file, and the tree's
own `stat` listing (for SquashFS, `unsquashfs -lln`) for the type, permissions, size and
modification time of every entry. Those tools write an image in one pass, so they leave no
history. The others carry history: the Linux kernel's own JFFS2, UBI and UBIFS drivers
(kernel 7.0.0), and YAFFS's own code, wrote them through a series of overwrites, deletions
and renames, and read them back, and that reading is the oracle. The scripts that build
them all are in `tools/`. Two of the readers have since been run against flash from a real
device as well: YAFFS2 against an Android phone and UBIFS against a camera, both below.
SquashFS and JFFS2 have not; see [What it does not do](#what-it-does-not-do).

### SquashFS

A read-only, compressed filesystem, and the usual root filesystem of a router or a camera.
Version 4.0 is read. The 1.x to 3.x layouts, and their big-endian `sqsh` form, are
recognised and reported but not walked. A volume is claimed only when its superblock
passes the checks the kernel makes before it mounts one (a block size that agrees with its
own log, a compression id the format defines) and its root inode reads back as a
directory.

Every compressor mksquashfs offers is read: gzip, xz (including a BCJ filter), the legacy
lzma format, LZO, LZ4 and, on Python 3.14 or later, zstd. Files split into blocks, files
that end in a shared fragment, and holes are read; symlinks, hard links, device nodes and
FIFOs are listed. Extended attributes are not reported.

Validated on eight images, one per compressor plus an uncompressed one and one with 4 KiB
blocks: 612 of 612 files match `sha256sum` over the source tree, and 621 of 621 entries
agree with `unsquashfs -lln` on every image. The tree includes random bytes that the
4 KiB-block image stores uncompressed because they did not shrink, a file shaped to reach
an LZ decoder's rarer instructions, a directory of 600 entries (more than one directory
header and metadata block) and a 255-byte name.

### JFFS2

A log-structured filesystem with no superblock: the filesystem is whatever nodes the
region holds. It is claimed when the region's first bytes that are not erased flash
(0xFF) open a node whose header CRC holds, and a scan of the region finds inode or
directory nodes. Both byte orders are read.

Every node is scanned and its header CRC checked. A node the filesystem has marked
obsolete is ignored, and so is one whose data fails its own CRC, as the kernel's
`check_node_data` does, so an older copy of that data shows through where one exists; the
report counts the nodes dropped, and a name whose inode is left with no readable node is
not listed, and counted too. For
each name the newest version wins and a newer entry with inode 0 unlinks it; each file
takes its mode, owner and times from its newest inode node and is cut to that node's size.
The none, zero, rtime, zlib and LZO compressors are read, and so is LZMA (compression
8), which mainline Linux does not have and OpenWrt adds: a raw LZMA stream with its
properties fixed in the code rather than stored (lc 0, lp 0, pb 0, an 8 KiB dictionary),
decoded to exactly the size the node records. Rubin, dynrubin and copy are reported and
not read. Erase block summary nodes are stepped over.

Validated on seven images from `mkfs.jffs2` (both byte orders, zlib, LZO, rtime, none, one
run through `sumtool`, and one written by OpenWrt's LZMA-patched `mkfs.jffs2`, which
`tools/make_jffs2_lzma_fixture.sh` builds from pinned sources): 310 of 310 files and 317
of 317 entries match, and the two
device nodes carry the type and permissions the device table gave them. (`mkfs.jffs2`
stamps device nodes, and so `/dev`, with the time it ran, so their times are not compared.)

`mkfs.jffs2` writes each node once, so those images carry no history. Two more do, written
by the Linux kernel's JFFS2 driver through the history described under
[Kernel-written history](#kernel-written-history) below: one on NOR flash, where the kernel
marks each node it supersedes obsolete (154 on the committed image), and one on NAND
taken with `nanddump --oob`, where it cannot, so older nodes stay valid and only their
version numbers say which is current (24 directory entry nodes for 13 linked names, none
marked). The self-test prints these counts and fails if the history is gone.
Both match what the kernel reads back from them, 10 of 10 files and 13 of 13 entries.

### UBI and UBIFS

UBI is the volume layer raw NAND runs under: each eraseblock carries an erase counter
header, and a mapped one a second header naming the volume and logical block it holds.
The reader finds the eraseblock size from the distance between those headers, rebuilds
each volume from its blocks (of two copies of one block the higher sequence number wins,
unless it is a copy whose data CRC fails; a block with one copy is used as it is, as the
kernel attaches it), and reads the volume table. A volume holding
UBIFS or SquashFS is listed as a folder named after the volume; any other volume, a kernel
image for example, as a single file holding its bytes. UBI records no time for a volume,
so none is shown for such a file.

UBIFS is read from its committed index, found through the master node, and then the
journal written since the last commit is replayed over it the way the kernel's
`replay.c` does: newer inode and data nodes in sequence order, an inode whose link count
reaches zero removed, a directory entry with inode 0 removing its name, and a truncation
dropping the blocks past the new size. LZO, zlib (raw deflate, as the kernel writes it),
uncompressed data and, on Python 3.14 or later, zstd are read, and a block the index does
not hold is a hole. A bare UBIFS image, as `mkfs.ubifs` writes it before `ubinize` wraps
it, is read too.

A raw NAND dump holds the bits as the cells gave them, before the controller's error
correction fixed them, so a node the device read cleanly can fail its CRC in the dump by
one flipped bit. When one bit accounts for the difference, qnxprobe restores it and reads
the node, as the controller would have, and the report counts every node read that way:

```
        bit errors   4 node(s) failed their CRC by one flipped bit and were read with that bit restored, as the NAND controller's ECC would have done
```

CRC-32 gives every single bit of a message this size a different CRC change, so at most
one bit fits, and its shortest weight-3 codeword is 91,640 bits, so on a node of up to
11,450 bytes two flipped bits are never taken for one (the self-test finds that codeword).
A node off by more than one bit is not read, and the file says why: its CRC fails by more
than one bit, or its place reads as erased flash, so no copy of it is in the image.

Validated on a bare `mkfs.ubifs` image and on five `ubinize` images (NAND with LZO, zlib,
zstd and no compression, and NOR), each with three volumes: the UBIFS volume matches 410 of
410 files and 416 of 416 entries, a static volume holding SquashFS matches 6 of 6 files,
and a static raw volume spanning two eraseblocks matches its hash. `mkfs.ubifs` commits
everything to the index and `ubinize` writes each block once, so in those images the
journal is empty and no block has a second copy.

A third image carries both. The Linux kernel's UBI and UBIFS drivers wrote it on simulated
NAND through the history described below, and it was taken with `nanddump --oob` while
UBIFS was still mounted, so the journal nodes written since the last commit (269 on the
committed image) have to be replayed over the index. Among them are a truncation, deletions, renames and a file created
with no name (`O_TMPFILE`), written, given an extended attribute and then linked in, which
leaves an inode record with no links after the file's data. Its static volume was written
twice, and the first version's two eraseblocks were put back into free eraseblocks from a
dump taken between the writes, the state a power cut during the rewrite leaves, so each of
its blocks has an older copy on the flash. The UBIFS volume matches what the kernel reads
back, 11 of 11 files and 14 of 14 entries, and the static volume the kernel's choice of its
second version. The report names the older copies:

```
        note         2 eraseblock(s): an older copy of a block, not the one read
```

### YAFFS1 and YAFFS2

NAND filesystems with no superblock: every page carries its tags in its spare bytes, and
the filesystem is rebuilt from the tags. The page size, spare size and where in the spare
the tags sit are recorded nowhere, and differ with the NAND controller, so they are found
by trying eleven common page and spare sizes (512+16 to 16384+1280) and, for YAFFS2,
every tag offset in the spare and both byte orders. A layout is accepted only when at least 90% of the used
spares hold plausible tags and at least 90% of the pages those tags call object headers
parse as object headers. The first 256 pages are tried first. YAFFS writes wherever
garbage collection freed a block, so a partition can open on blocks holding only data
pages or only erased ones; when the first pages hold tags that fit but no object header,
or almost nothing but erased pages, the same test runs again over sixteen stretches spread
across the whole region, each the same number of bytes for every page size tried.

YAFFS2 is read the way its own scan reads it: blocks newest first, the newest object
header and the newest copy of each data page winning, data past a shrink or past the
newest header's size ignored, and a file's size taken from its newest header or from data
written after it, whichever is further. YAFFS1 orders two copies of a page by their 2-bit
serial number and takes a file's size from where its furthest live page ends. `lost+found`
is always listed, as YAFFS lists it; when the flash holds no header for it or for the root,
no time is shown for them, since YAFFS makes them at mount time.

Validated two ways. Aleph One's own image makers wrote four images (YAFFS2 little endian,
YAFFS2 with big-endian headers, YAFFS2 with its tags two bytes into the spare, and YAFFS1):
158 of 158 files and 164 of 164 entries match on each. And YAFFS's own code, run in user
space over a file standing in for NAND (`tools/yaffs_history.c`), wrote three images with
history: overwrites, a shrink and a regrow, holes, deletion, a rename, a hard link whose
first name was removed, enough churn for garbage collection to run, and a file flushed and
never closed, with no unmount at the end. The YAFFS1 images end in power cuts, one of them
leaving two live copies of a page with different bytes that only their serial numbers
order. The oracle for those is YAFFS's own code mounting a copy read-only and reading every
file back: 48 of 48, 49 of 49 and 2 of 2 files match, and every entry agrees.

A real device dump confirms it: Case 2 of the DFRWS 2011 Forensics Challenge, the flash of
an Android phone taken with `nanddump`, spare bytes included (2048-byte pages, 64-byte
spare, tags two bytes in). Its /system, /data and /cache partitions were read by qnxprobe
and by YAFFS's own code (the same core, pinned at the same commit, reading the dump
read-only with its tags two bytes into the spare). Both list the same 661, 2,422 and 22
entries, and all 565, 1,876 and 20 files have the same bytes. Modes and times agree on
every entry but three: the time of `lost+found` on /system, which the flash does not hold,
and a socket and a FIFO on /data, whose stored modes carry their type, which qnxprobe
reports and YAFFS's direct interface drops. Directory sizes were not compared (YAFFS
reports 2048, qnxprobe 0). The /cache partition's first object header is at page 3,968,
which is what the wider search above is for; before 1.35 it was not recognised.

### Deleted files on YAFFS2, JFFS2 and UBIFS

None of these filesystems rewrites anything in place. A change goes to a new page or node,
and the old one stays on the flash until garbage collection erases its block, so a deleted
file's last name, size and content often outlive the deletion. `recover_deleted()` on a
YAFFS2, JFFS2, UBIFS or UBI walker yields a `FlashDeletedFile` for each one, and
`read_deleted()` reads it:

```python
kind = qnxprobe.identify_fs(fh, 0, size)[0]           # "yaffs2", "jffs2", "ubi", ...
w = qnxprobe.walker_for(kind, fh, 0, size)
for e in w.recover_deleted():
    print(e.parent_path, e.name, e.size, e.recoverable, e.reason, e.note)
    if e.recoverable:
        data = b"".join(w.read_deleted(e))
```

The method has its own name rather than `deleted_files()`, because a caller that handles
`deleted_files()` for NTFS, FAT32 and exFAT reads fields (`record`, `first_cluster`) these
records do not have. Since 1.61 `ExfatWalker` has a `recover_deleted()` too, for
[orphan directory entries](#exfat-orphan-directory-entries).

- **YAFFS2** deletes a file by writing a header that files it under its unlinked or
  deleted directory. Each object's headers are cut at every such header, so when YAFFS
  reuses an object id for a later file, the earlier file still comes back. The file is
  rebuilt from the chunks written before its deletion, through the same rules as the live
  scan. When YAFFS deletes a file still in its folder, it first resizes it to 0, writing a
  header there with size 0 (`yaffs_del_file`); that header is taken as the deletion's, and
  the file is rebuilt as the header before it describes it. A file truncated to 0 just
  before it was deleted leaves the same header, and the flash cannot tell the two apart, so
  a file with content recovered that way says so in `note`. YAFFS1 is not recovered: its pages are ordered only by a 2-bit serial number,
  which cannot say which copy a deleted file last held.
- **JFFS2** deletes a name with a directory entry pointing at inode 0 and frees the
  inode's nodes without erasing them. On NOR it clears one bit in each node header (the
  node's own CRCs were computed with that bit set, so it is set again before they are
  checked); on NAND it cannot, and the nodes stay valid. A deleted file is rebuilt from all
  of its nodes, oldest version first, and named from the newest entry that pointed at it.
  JFFS2 writes holes as nodes too, so a range no node covers is missing, not a hole.
- **UBIFS** deletes a file with an inode node of link count 0 and an entry pointing at
  inode 0. Every node carries a sequence number that orders all writes on the volume, so a
  deleted inode's data and truncation nodes are replayed in that order up to its deletion,
  as the journal is. Only the LEBs the volume maps now are read, not an older copy of a LEB
  UBI still holds.

A file is `recoverable` only when every page, byte or block its size needs is still on the
flash. Otherwise `missing` counts the gap and `read_deleted()` refuses it: an erased block
and a hole that was never written look the same, and reading the file would put zeros
where its content was. A file whose name was erased comes back with an empty `name`.

Validated three ways. On the history fixtures above, the files the writers deleted come back
with the bytes the writers gave them: `deleted.txt` and the last churn file on YAFFS2,
`gone.txt` and the replaced `target.txt` on JFFS2 NOR, JFFS2 NAND and UBIFS. Files garbage
collection partly erased are refused (11 on YAFFS2, 3 on NOR, 24 on UBIFS). Seven changes
that each break one rule all turn the self-test red.

On a real dump, the /data partition of DFRWS 2011 Case 2 (an Android phone, nanddump with
spare): 1,945 deleted files, 1,924 of them complete, 1,001 of those SQLite `-journal`
files. YAFFS reuses object ids: id 2539 alone held 114 of those deleted files. As a
second reader, YAFFS's own core read copies of the dump with everything written from a
file's deletion onward erased, so that the file was live again. On 150 files sampled at
random from those with content, 149 match byte for byte: 24 at their path and 125 under
`lost+found`, where YAFFS files an object whose folder's newer header the rollback erased.
The one that differs, a 3-byte property file, had its replacement renamed onto its name two
writes before it was deleted, so the rolled-back path already held the replacement.

On the Foscam R2 camera dump used in the UBIFT case study (DFRWS EU 2024), the root
volume gives 26 deleted files and the configuration volume 10, all complete, every block
decompressing to the size its node records. No second reader was run on those.

### Raw flash dumps and NAND spare bytes

A dump read off a flash chip has no partition table (the kernel learns the flash layout
from the device tree or its command line, which the dump does not carry), and usually a
bootloader at offset 0. So when an image has no partition table and nothing is recognised
at its start, qnxprobe looks for SquashFS, UBI and JFFS2 at every 4 KiB boundary of an
image up to 8 GiB, checks each candidate the way identification does, and reports each one
it finds as its own volume, under `FLASH` in the report. Since 1.60 it also finds QNX EFS
partitions there, by their boot records at any offset. Since 1.51 the same pass also looks
for ext2, ext3 and ext4, because an eMMC image from an embedded device can hold its
partitions with no table the image carries (the kernel can take the layout from its
command line instead, `blkdevparts=` in
[block/partitions/cmdline.c](https://github.com/torvalds/linux/blob/72d3fcf802c45d00b300f25b848a93c3a2bd7c7e/block/partitions/cmdline.c#L287)),
and its writable data can sit in ext4 there:

```
  FLASH    no partition table and nothing recognised at offset 0; 2 flash filesystem(s) found by their own headers
    @0x140000 squashfs       36.0 KiB  at byte 1,310,720
    @0x150000 jffs2           2.7 MiB  at byte 1,376,256
```

An ext filesystem is taken only from a primary superblock (block group 0; a backup copy
names its own group) whose root directory reads, and it ends at the block count it
records. A superblock inside a filesystem already found, such as an ext image kept as a
file, is not reported as another volume. A SquashFS volume ends where its superblock says;
UBI runs over the following eraseblocks that carry the same image sequence number, or are
erased; JFFS2 records no size, so it runs to the next volume found or the end of the
image. YAFFS has no header to search for, so it is read only when it fills the image or a
partition.

Since 1.54 the same pass also finds two configuration stores a flash chip keeps beside its
filesystems: the U-Boot environment, and the libnvram store Belkin WeMo devices keep, which
opens with `NVRM`. Neither is a filesystem, so each is reported as a volume holding one
file, `uboot-env.bin` or `nvram.bin`: the store's bytes as held on flash, for a consumer to
parse. The report gives a store's layout and how many name=value strings it holds, never
their values. A store is named by its layout, and the layout does not say which program wrote
it. A store is taken only when its CRC-32 holds over it, at a size tried in 4 KiB
steps up to 256 KiB, and a U-Boot environment only when its first string opens with a name
and `=` and its strings end inside it. A store sits in its own MTD partition, so a JFFS2 in
front of one ends where it begins. A partition or a file is taken for a store when the store
fills it or only erased flash follows, so a dump that merely begins with an environment is
still searched for the rest.

The U-Boot layout is `env_t` in
[include/env_internal.h](https://github.com/u-boot/u-boot/blob/866ca972d6c3cabeaf6dbac431e8e08bb30b3c8e/include/env_internal.h#L80-L86)
(v2024.01): a little-endian CRC-32, a flags byte only on a board that keeps a redundant copy,
then NUL-separated strings ending in an empty one, the CRC covering the rest of the
environment as
[`env_import`](https://github.com/u-boot/u-boot/blob/866ca972d6c3cabeaf6dbac431e8e08bb30b3c8e/env/common.c#L310)
checks it. The libnvram layout is `env_image_gemtek` in Belkin's own libnvram source (its
header carries Belkin's copyright), as found in a public copy of the WeMo firmware tree,
[libnvram.c](https://github.com/svenschwermer/wemo/blob/46d0ccd248806e8e07210f9b34166b127e9d3d52/package/belkin_nvram_bd/src/libnvram.c#L97-L108):
`NVRM`, a CRC-32 over the partition less the 16-byte header, an entry count and the offset
of the end of the data, then the strings. The count and end of data are reported as stored
and not checked, because the CRC does not cover them and libnvram rebuilds both from the
strings. Both layouts are round-trip tested on stores the self-test builds, one U-Boot
environment of each layout and an NVRM store after the JFFS2 fixture, with three controls
that must not be claimed: one flipped data byte, strings that never end, and a CRC over a
shorter length.

Two JFFS2 partitions can sit side by side with nothing between them, an OpenWrt overlay
followed by a vendor's settings partition for example. Each numbers its inodes and versions
from 1, so read as one filesystem a name from one partition would show the other's file of
the same number. Within one filesystem an inode number and version name one node (garbage
collection copies a node unchanged, and the one rewrite that keeps a version, a partly
overwritten hole, keeps its range), and a directory's version names one entry. So when a
JFFS2 region holds two nodes with the same inode number and version but a different file
type, range or data, or two entries with the same directory and version but a different
name or target, obsolete nodes included, qnxprobe cuts the region along erase blocks
(found from the spacing of the clean markers, else 4 KiB) into contiguous pieces with no
such conflict inside any of them. Where more than one cut would do, it takes the one that
separates the fewest names from their own inodes and directories, counting a name only
where its recorded time matches a time on that inode or directory: the kernel gives a new
file's name the new inode's time, a new symlink's, directory's or device's name a time read
a moment after its inode's, and the directory the name's time. Each piece is then listed and read as its own filesystem. A
region with no conflict is read whole, as before. Where a cut falls inside the erased
blocks between two partitions cannot be known from the nodes, so the boundary is placed at
the second partition's first block that holds one.

A NAND dump taken with its spare bytes (for example by `nanddump --oob`) holds each page's
data followed by its spare. YAFFS needs those bytes. For UBI and JFFS2 they are noise that
does not look like noise: the spare holds error-correction bytes and, on NAND, JFFS2's own
clean markers, and a UBI header in a 512-byte subpage sits inside the first page where the
spare cannot disturb it. So qnxprobe tries the common page and spare sizes, reading the
region with the spare stripped, when a UBI volume table does not read or no JFFS2 node
opens the region, and says so in the report:

```
        NAND         a raw dump: 2048-byte pages each followed by 64 spare bytes, read with the spare stripped
```

Validated two ways. On dumps built from the fixtures: a 4 MiB NOR layout with 1.25 MiB of
bytes no filesystem claims, then the SquashFS and JFFS2 images at 64 KiB boundaries, where
both are found at their offsets and every entry is read, and the UBI and JFFS2 images with
64 spare bytes after every 2 KiB page, where the geometry is found and every file matches.
And on the two kernel-written NAND images, each a `nanddump --oob` of one partition of the
kernel's simulated NAND chip (`nandsim`), where the geometry is found and every file
matches the kernel's reading. The first run on those two images read the files of neither: the UBI
dump mapped through its subpage headers and the JFFS2 dump opened with spare bytes, the
two cases the paragraph above now handles, and neither had shown on the dumps built from
fixtures. An image recognised at offset 0 is never searched further.

### Kernel-written history

`tools/make_kernel_flash_fixtures.sh` (Linux, root) builds the three kernel-written images.
It first writes and deletes more data than the volume holds, so garbage collection runs
and UBIFS commits, then makes the history: data overwritten in the middle and appended, a
shrink followed by data written past the old end, a truncate that grows, a file written
only far from its start, one file rewritten forty times, a deleted file and directory, a
rename across directories, a rename over an existing name, a hard link whose first name is
removed, a symlink, a permission change, and on UBIFS the unnamed file above. Every step
is fsynced, and nothing after the first phase calls `sync()`, which on UBIFS runs a commit.
The kernel then reads each image back: the NOR image through a copy mounted read-only, the
NAND ones after being written back to an erased partition or mounted read-only again, and
a second dump shows the kernel read the bytes that are committed (for UBI, only the two
stale eraseblocks changed, erased by the kernel as older copies).

These images are what make the history rules testable: a deliberate change to any of them
(newest version or name first, journal replay, truncation, name deletion, keeping a
relinked inode, the newest copy of a UBI block) turns the self-test red.

## LVM2

Since 1.64. An LVM2 physical volume, a partition or a whole disk that carries lvm2's
label, is reported as `lvm2 pv`, and each of its logical volumes that is linear and lies
in one run of extents on one physical volume in the image is listed as a volume of its
own, labelled `LVM <volume group>/<logical volume>` and named
`lvm_lba<first sector>_<group>_<volume>`, the sector counted in the disk's sector size as
the partition names are (checked with a 4096-byte sector size given; no 4Kn image with
LVM was run). Such a volume is a byte range of the image like a partition, so
it is identified, listed, walked and extracted at its true offset, and its free space is
written out where that filesystem's reader reports free space (the ext reader does not).

Since 1.66, a logical volume whose extents are split into separate runs (extended into a
gap, or across physical volumes) or striped, its every run on a physical volume in the
image, is read too, through a map of where each of its bytes lies, as lvm2's linear and
striped segment types lay them out (`lvm_image()`, `LvmMap`). The volume is placed past
everything the image can describe, its end and the end of every region its tables name,
and never below 2^60 bytes, so every reader works on it unchanged while a read of the disk,
even of a partition a partial image's table names past the file, never lands there;
`image_size()` stays the image's own. A placed base is valid only through the handle
`lvm_image()` returns. Its place is not reported as an offset: in `volumes()` its `lba`
is `None` and `lvm_map` gives each run,
the report prints its first four runs, its record in
`volumes.json` has `offset_bytes` and `lba` null and an `lvm_map` list with each
segment's offset in the volume, length, the image offset of each run and the stripe
size, `unallocated.json` carries the same map, and free space found in it is written at
the image offsets it lies at. `volumes()` and `main()` apply `lvm_image()` themselves; a
caller that builds its own volume list from the identifiers applies it to its image
first, after `unlock_bitlocker()` and `unlock_apfs()`, whose wrappers read only up to
the image's own size. A BitLocker or APFS volume inside a mapped logical volume is not
opened.

Free space, since 1.66: an LVM2 physical volume's extents that no logical volume holds,
hidden ones included and both sides of a move in progress (lvm2 keeps a pvmove's
extents under a mirror segment), are its free space for `--unallocated` and
`write_unallocated()`, each run at its own offset; the label and metadata before the
first extent, and any space past the last, are not included. On the Ubuntu image below
that is one run of about 898 GiB: its one logical volume holds 100 GiB of a 998 GiB
volume group.

The layout follows lvm2's own code (lvmteam/lvm2 at tag v2_03_43). A label is taken as
lvm2 takes it: `LABELONE` in one of the first four sectors, naming that sector and
passing its checksum, of type `LVM2 001`; one that fails is passed over and the next
sector tried. Then the pv_header, each metadata area's header (its checksum checked),
and the committed metadata text (its checksum checked), which wraps past the end of its
area back to just after the header. A copy lvm2 marks ignored is not used. When the
volume group spans several physical volumes, the copy with the highest `seqno` decides,
and a copy whose checksum fails is named in the report and the others are used. A
label with no good metadata area behind it counts only when a volume group read from
another physical volume names it, so a stray label does not hide the filesystem in a
region. Metadata text that does not parse, or that parses with a value of the wrong
kind where lvm2 writes a number, a section, a string or a list, is reported and that copy
is not used; the other volumes of the image are unaffected. lvm2's configuration syntax is
read as lvm2 writes it; single-quoted strings, floating-point, hexadecimal and octal
(leading-zero) numbers, which lvm2 accepts but does not write, are refused.

Since 1.67, a RAID1 volume, and an old-style mirror, is read from the first of its copies
whose extents are all in the image: lvm2 lists a raid1 segment's copies under `raids`
(raid.c) and a mirror's under `mirrors` (mirrored.c), each a hidden logical volume
holding the volume's data from its start. Since this release a raid1 copy lvm2 marks
REBUILD, one on a physical volume marked MISSING, and one the dm-raid superblock lists as
failed, still recovering or behind is passed over for the next (see "RAID" below); a
mirror's copies, and a raid1 copy out of sync in some other way, are read as they are; a
segment with a `data_offset`, which lvm2 writes while a reshape moves the data, is not
read. On the fixture the two copies hold the same bytes, the files read from the first
match their source, and with the first copy's physical volume missing the second is read.
The old-style mirror is read by the same code but no fixture holds one.

A RAID4, RAID5, RAID6 or RAID10 volume is read too, from its image volumes in the image,
with one missing read from the other copy or rebuilt from parity (see "RAID" below); a volume group whose physical volumes are spread over
several images is read when all of them are given on the command line.

Not read, and named in the physical volume's report with the reason (since 1.65 also in its
`note` in `volumes()`, which a LEAPP run log prints): a RAID0 volume, one
with a run on a physical volume that is not in the image, and one on extents of something
that is not a physical volume of the group (a move in progress). Thin, cache, VDO and
snapshot volumes are refused by
their segment type too, but no fixture holds one, so that path is unexercised; a
snapshot is to be named by the volume lvm2 lists for it (`cow_store`), which is checked
on a constructed segment, not on a real snapshot. lvm2's hidden internal volumes
(a RAID volume's image and metadata legs, a pool's data) are not listed.

The fixtures were written by lvm2 itself (`tools/make_lvm_fixtures.sh`, lvm2 2.03.31 on
Linux): a GPT disk with two physical volumes holding a contiguous volume, a volume split
by another and holding a file that crosses both of its runs, one on the second physical
volume, a striped volume holding a file that crosses its 64 KiB stripes many times, a
RAID1 volume, and a disk
that is one whole physical volume whose extents start 3 MiB in while they are 1 MiB
long. `--self-test` checks the volumes read against lvm2's own report (`lvs`, `pvs`)
saved beside them, the runs each map covers against the extents that report gives,
every file against sha256sum over the source trees (each 4 KiB block of the files that
cross runs and stripes names its own number), the unallocated extents written against
the ones the report leaves free, and the inputs
lvm2 would refuse or that were damaged or crafted after it wrote them: a moved label, a
failed checksum on a label, a metadata header and the text, an older copy on either
physical volume, an ignored copy, wrapped text, unterminated and deeply nested text,
values of the wrong kind, a second partition carrying the same physical volume id, a
partial image whose table names a partition past the file, an image cut short, and a
constructed pvmove in progress. On
the public image of The Open University's "Defaced web server (Ubuntu 22.04)"
simulation (https://doi.org/10.21954/ou.rd.26038669.v1), whose root filesystem is in a
logical volume, 1.63 reported that partition only as not recognised; 1.64 reads the
logical volume as ext4 and walks its 93,747 entries.

## RAID

A RAID set arrives as several images, one per disk. Give them all on the command line
and qnxprobe reads each image as before, then assembles the arrays their members belong
to and reads each array as an image of its own:

```
qnxprobe.py --extract out.zip disk0.img disk1.img disk2.img disk3.img
```

Each member image is opened as qnxprobe opens any image, so it can be raw, split, E01,
VHDX or any other format it reads (the fixtures are raw), and a member can be the whole
disk or a partition. An image that holds no member
of anything is read exactly as before. Hardware RAID imaged as one logical disk needs
none of this: it is already one image.

What is read:

- **Linux md (mdadm) arrays**, metadata 0.90, 1.0, 1.1 and 1.2: linear, RAID0 (with the
  original and the alternate layout over members of different sizes), RAID1, RAID4,
  RAID5 in its six layouts, RAID6 in its fourteen, and RAID10 near, far and offset.
- **LVM RAID4, RAID5, RAID6 and RAID10 volumes** (dm-raid), inside one image or across
  several. An image volume lvm2 marks REBUILD, one on a physical volume lvm2 marks MISSING
  or that is not among the images given, and one the dm-raid superblock in its metadata
  volume lists as failed, is treated as missing: a RAID10 volume is read from the other
  copy, and a RAID4/5/6 volume rebuilt from parity when the dm-raid superblock says the
  array is in sync and lvm2 does not mark the volume NOTSYNCED; otherwise it is refused.
- **A RAID4 or RAID5 array missing one member, and a RAID6 array missing one or two**:
  the missing member's chunks are rebuilt from parity (XOR, and for RAID6 the Q
  syndrome), but only when the array was stopped clean. A RAID1 or RAID10 array missing
  members is read from the copies that are there.

The report gets a RAID section after the images: each member found, then each array with
its level, layout, chunk, metadata version, uuid and event count, which image holds each
role, which roles are missing, which members were left out and why, and what was refused.
Each array that is read then gets a report of its own, named `md_<name>_<first eight hex
digits of its uuid>` (or `lvm_<group>_<volume>` for a volume group spread over images),
and its volumes are extracted under that name followed by the volume's own
(`md_qp_qp46_5e57911c_lba0_...`). In `volumes.json` such a volume's `image` is that name,
and a `raid` record gives the array's members, roles, missing roles and notes.

The exit status is 1 only when an array has every member it needs among the images given
and is still not read. One rule serves md arrays and LVM volumes: what was given decides
it, not why it was refused. A member or leg given but unusable (stale, faulty, cut short,
marked REBUILD, a failed device) counts as given, and the members or legs not given at
all must be no more than the level can lose (RAID4/5 one, RAID6 two, RAID10 its copies
less one, RAID1 all but one, linear and RAID0 none). So four RAID5 members of which two
are stale exit 1, and so does an LVM raid5 volume with one leg's image not given and
another leg marked REBUILD. Part of an array
(one member given alone, or beside images that belong to nothing, or LVM images holding
too few of a volume's legs) is reported as members, with a line naming the roles
or physical volumes not given, and leaves the exit status as v1.68 had it. When the members are partitions of
the one image given, that line instead says how many of them can be used, and the members
left out above say why the others cannot. Members of metadata this only names (DDF
and the others below) do not change the exit status. A RAID1 array whose data starts at
the first byte of the member it is read from (metadata 0.90 or 1.0) is not read a second
time: that member's own listing above shows the same bytes, and the RAID section says so.

A member is assembled the way the kernel assembles it (drivers/md/md.c): its superblock
must pass its checksum at the place its metadata version puts it, and members are grouped
by array uuid. A member more than one event behind the freshest superblock is left out as
stale (its disk failed or was removed, and writes after that never reached it); one event
behind takes its role from the freshest superblock, for metadata 1.x from its role table
(md.c 2111-2133) and for 0.90 from the freshest `disks[]` entry of its device number, and
is left out when that entry no longer has it in sync. The same holds for a write journal
device, and a journal device whose own superblock has no journal feature is left out
(md.c 2146-2150). A spare, a member marked faulty, one still being rebuilt, one whose superblock
gives the array a different level or layout, one whose image is shorter than the array
needs, a 1.1 or 1.2 superblock whose data offset falls inside the superblock (md.c
1877-1882), a member one event behind whose device number is past the freshest role table
(md.c 2125-2130), and a second copy of a member already used are all left out and named. When a 0.90 or 1.0
superblock is found both from the whole disk and from a partition that ends where the disk
does, the member is the partition. A physical volume given twice (the same image, or two
copies of one disk) is read once and the second named. Since 1.71 a volume group spread over several images is
matched by its id, never by its name: two groups that share a name (a default such as
`vg0`) are each read through their own physical volumes only, and their volumes are
labelled with the start of each group's id (`LVM qpraid2@uxxMPS/r5`), with a member line
naming the shared name. Up to 1.70 they were matched by name: on the self-test's ten
images below, 1.70 lists the six volumes under three labels, each twice. The
self-test gives the five LVM RAID images with a copy of them rewritten to another group
id and other physical volume ids (checksums made good): all six volumes read to the
kernel's bytes under six labels, and with the second group given only in part, none of
its volumes is read through the first group's disks. A RAID1 member whose superblock is at its end
(metadata 0.90 or 1.0) starts with the filesystem itself, so read alone it is listed as
that filesystem, as before; every other member read alone is listed as `linux md member`
and not walked. That includes the first member of a linear array: md lays a linear array
out as its members one after another (linear_conf), so a filesystem made on the array
continues on the next member (the fixture's 9 MiB ext4 starts on a first member holding
2 MiB of it), and walking that member alone would read a filesystem cut short.

A DDF or Intel IMSM (RST) member is different, because its array is never assembled here.
Since 1.71 the level its own metadata records decides whether the member is walked on its
own, the same rule as for md: only a mirror holds the whole of its data on one disk.

- The level is read as mdadm-4.5 reads it, checksums included. For DDF (`ddf_levels()`,
  super-ddf.c): the anchor in the last sector; the primary or the secondary header, chosen
  as mdadm chooses (the secondary when the primary does not load, or when its seq is newer
  and it is not open); and each virtual disk configuration record, with their CRCs. A
  record of RAID1 with more than one secondary element is not a mirror: mdadm writes its
  RAID10 that way (RAID1 over two-disk sets, spanned), and it reads here as `RAID10`. For
  IMSM (`imsm_levels()`, super-intel.c): the metadata ending two sectors from the end of
  the disk, with its checksum, and each volume's map, level 1 with two members being RAID1
  and with more RAID10.
- A mirror is walked only in its normal state. For DDF, the virtual disk's record must say
  optimal (no degraded, morphing or inconsistent state), and this disk's own physical
  disk record (found by the guid in its disk data) must say online and not failed,
  rebuilding, in transition or missing. For IMSM, the volume's map must be in its normal
  state and not migrating; a degraded map is not walked, because which member it lost is a
  disk number this one disk cannot be matched to without the drive's serial number.
- When every array the metadata records is such a mirror, the member's filesystem or
  partitions are walked as any other, and a line under each (and the volume's `note`)
  says it is a mirror member whose array is not assembled.
- For any other level (RAID0, RAID5, RAID10, concatenation and the rest), for a mirror
  not in its normal state, and when the metadata cannot be read or its checksum does not
  match, the region is a `raid member` and is not walked. Its note names the level and
  state (or why it was not read), says its array is not assembled, and names what it
  starts with (`it starts with ext4`). On the DDF fixture, a RAID5, two members start with
  an ext4 superblock. qnxprobe 1.67, which walked them, lists one with
  `spec hello.txt 3,096.3 PiB 2017-04-03` (measured on md-ddf-2): that is what this rule
  keeps out.
- The rule covers everything found on such a disk, not only its partitions: a logical
  volume of an LVM2 physical volume on it, what an opened LUKS or BitLocker volume on it
  holds, and a qnx6 volume. The disk's metadata is read from the image's own bytes, never
  through an opened volume's decrypted view of them.
- A partitioned disk whose own end carries the metadata (the IMSM case, where the
  partition table of a RAID0 or RAID5 volume sits on its first member) gets a `RAID` line
  in the report.
- A region in which nothing is recognised is a `raid member`, unless its metadata records
  a mirror in its normal state, when it is read as any region is.

Not read, each named with why:

- a reshape in progress (part of the array is in the old layout and part in the new);
- more members missing than the level can lose, or every copy of some RAID10 chunks;
- a degraded RAID4, RAID5 or RAID6 array not stopped clean, whose parity may not match
  its data;
- a RAID5 or RAID6 array with a write journal whose device is not given, or whose journal
  holds data for a stripe with no parity after it (a write held only in the journal). The
  journal is walked as the kernel replays it at start (raid5-cache.c). A stripe whose data
  and parity are both logged is one the kernel rewrites from the log; on an array stopped
  clean the array is read from its members as they are (the fixture's journal holds one
  such stripe, and its array reads to the bytes the kernel presented), and on one not
  stopped clean it is refused;
- a RAID0 array of members of different sizes that records no layout (made before Linux
  5.4), a RAID10 layout with far sets, a clustered array, and a 0.90 superblock written
  by a big-endian host;
- what the kernel itself would not run: a RAID4/5/6 chunk that is not a power of two of
  at least 4 KiB (raid5.c 7492-7497), a RAID10 layout of fewer than two copies (raid10.c
  3848), and a superblock recording more members than its role table holds (more than 27
  for 0.90), which is refused before anything is sized by it;
- a member's bad block log on a linear or RAID0 array, which keeps no other copy, or on a
  RAID4/5/6 array not stopped clean, and a bad block range nothing can supply (above);
- an LVM raid segment whose image volumes nest more than four deep or name the volume
  itself (the group's other volumes are still read);
- arrays of metadata this does not assemble: DDF and Intel IMSM (RST) members by their
  anchors at the end of the disk (a mirror member is still read on its own, above), and GPT
  partitions of Windows LDM, Windows Storage Spaces and Apple RAID by their type.

A write-intent bitmap and a partial parity log (PPL) are noted and not used: the bitmap
marks regions to resync when a stale member is added back, and no stale member is read; a
PPL is for an array stopped unclean, and a degraded one of those is refused above. The
fixtures with each, stopped clean, read to the bytes the kernel presented.

A 1.x member's bad block log is read as the kernel reads it (md.c 1890-1920): the ranges
it lists on that member are never read from it, but from the other copy (RAID1, RAID10)
or rebuilt from parity (RAID4/5/6, on an array stopped clean), and the report names the
member and the ranges. Before the array is read, every array chunk such a range touches
is read once: if neither another copy nor parity can supply one (both RAID1 or RAID10
copies listed bad, two RAID5 members bad at the same place, a bad range on a degraded
array), the array is refused, naming each member and range. A member whose bad block log
runs past the end of its image is left out, as md would not load it. A member whose read
fails (a damaged chunk of its container, for one) is tried once more, then read around as
md reads around a failed read: from the other copy (RAID1, RAID10), or rebuilt from parity
(RAID4/5/6) on an array stopped clean. On a RAID4/5/6 array not stopped clean its parity
may be out of step, so such a read is not rebuilt: it ends short there. On a mirror not
stopped clean md reads the first readable copy and moves to the next when that read fails
(raid1-10.c 278-289, raid1.c 589-612), and so does this, so the bytes may be the other
copy's version of a region being resynced; the array's notes say it was not stopped clean.
And
should a RAID read fail all the same, with nothing to read around it, it ends short, so the file it belongs to is extracted as
`.SHORT-<got>-of-<size>-bytes` and counted short in `volumes.json`, never filled with
zeros. An LVM RAID volume's metadata volumes are read for the dm-raid superblock
(dm-raid.c 1954-1975): its in-sync offset, its failed-device list, each device's own
recovery offset (a device still being recovered, dm-raid.c 2499-2508, is treated as
missing), whether it holds a dm-raid superblock at all (one without, when another image
volume's superblock exists, is a device dm-raid would take as new and rebuild, super_load
2207-2222, and is treated as missing) and its event count (a device whose superblock is more than one event behind the
freshest is treated as missing too; dm-raid takes the array's state from the freshest
superblock alone, and leaving out one that fell behind is md's own rule, md.c 2087,
applied here as the stricter reading). An LVM raid1 volume uses the same tests to pass
over a copy for the next good one, and is refused when no copy is good; NOTSYNCED does
not stop a raid1 volume, which needs no parity. An old-style mirror's copies are read as
they are. `--unallocated` on an LVM RAID volume with an image volume missing says how
many bytes of its free space lie in chunks rebuilt from parity, which are on no disk, and
leaves them out (`rebuilt_bytes_not_written` in `unallocated.json`).

A 1.1 or 1.2 superblock's role table is rounded up to the device's logical block size
before its data offset is checked against it (md.c 1872-1882). An image says its logical
block size only through a GPT header found at 4096 bytes; for any other image 512 bytes
is assumed.

From Python, `raid_open(paths)` opens the images and assembles them, and
`raid_assemble([(label, image), ...])` does the same for images already open; each of
the result's `arrays` has `lines()`, `describe()`, `refused` (None, or why it was not read)
and `image`, which `volumes()`, `main()` and the walkers read like any image:

```python
import qnxprobe as q

with q.raid_open(["disk0.img", "disk1.img", "disk2.img"]) as rs:
    for arr in rs.arrays:
        print("\n".join(arr.lines()))
        if arr.image is not None:
            for vol in q.volumes(arr.image):
                print(vol["kind"], vol["label"])
```

### Finding the other members from one of them

Since 1.70, `--find-members` takes one member image and finds the others beside it:

```
qnxprobe.py --find-members --extract out.zip disk0.img
```

For each image given that holds a Linux md member or an LVM2 physical volume, qnxprobe
looks in that image's folder for the other members. It goes by what each file records
about itself, never by its name:

- an md member is added when its superblock passes its checksum at a place the kernel
  looks for it, read with the same code the assembly uses, and carries an array uuid
  that the image given holds;
- an LVM2 physical volume is added when its label is one lvm2 accepts, its own id is
  listed under `physical_volumes` in the newest copy (highest seqno) of the metadata of
  a volume group the image given holds, and its own metadata, when it has any, names
  that group's id.

Before anything is read, the report names the folder, the arrays and volume groups looked
for, any `WARNING` (below), every other entry of the folder with what became of it and
why, and the md roles or physical volumes that no file holds. A file added that also
holds a member of some other array or volume group (on another partition, say) is read
with it all the same, and the report names that identity as not one of the image given's,
so not searched for. Each file added is then read exactly as if it had been typed on the
command line, so the RAID section and the exit status are what they would be for the full
list. Without `--find-members` nothing changes: `--list` prints the same bytes and exits
with the same status as 1.69 on each of the 83 other fixture images and the 203 RAID
member images given alone (the one-image LVM RAID fixture among them), and on each of the
51 md fixture sets (the DDF set and the set stopped during a reshape among them) and the
five-image LVM RAID set given in full.

What the search looks at:

- **The image's own folder only.** A subfolder is named and skipped, as are symbolic
  links and anything that is not a regular file (a device, a pipe, a socket). One exception:
  a differencing VHD in the folder makes the vendored reader open its parent disk where the
  VHD's parent locator points, which can be an absolute path outside the folder (the reader
  opens only a regular file there). Each file
  that is opened is opened without blocking and without following a link (on systems that have
  those open flags; Windows has neither), and checked through
  the open descriptor to be the regular file it was when listed, before a byte is read,
  so a file swapped for a pipe in between is refused rather than waited on. A raw file
  and the segments of a split raw set are read only through descriptors checked that
  way. An acquisition container (E01, VHD and the rest) is read by the vendored reader,
  which opens its files by name: just before that, the file is checked again and every
  entry of the folder whose name starts with its stem must be a regular file or a
  folder; the moment between that check and the reader's own open is not closed.
- **One file per member.** A member is named by its md array uuid and device uuid (0.90
  records no device uuid, so its device number is used), or by its physical volume id.
  A file with the same device and inode as one given is not opened; one with the same
  device and inode as a file already looked at (a hard link) has only its first and last
  512 bytes read, to tell what kind of file it is, and is then named as the same file. A
  member the image given holds is always read from the
  image given, never from another file. When another file holds a newer copy of it (md
  events, lvm2 metadata seqno), or one as new with different bytes, the report gives a
  `WARNING`, ahead of the list of files, naming that file and saying the copy given is stale or differs. Of
  other files holding one member, the newest is used, as mdadm keeps the newer of two
  members claiming one role (`Assemble.c` 841-843, mdadm-4.5). When the newest copies
  are as new as each other, they are compared byte for byte over the whole partition or
  image the member is on. If they are the same, the first looked at is used and the others
  are named as its copies. If not, none is used: each is rejected as `ambiguous-member`,
  and the member is reported missing, so the array is rebuilt without it where its level
  allows and refused where it does not. mdadm itself refuses to assemble two 0.90
  members with one role and the same event count (`Assemble.c` 820-838); this applies
  that to 1.x members and to physical volumes as well. How lvm2 itself chooses between
  duplicate physical volumes was not checked.
- **Every place a member can begin.** Each file is opened as qnxprobe opens any image
  (raw, a split raw set, E01 and the other containers the vendored ewfprobe reads), and
  the whole image and each partition its MBR, EBR chain or GPT gives are read at the
  places the assembly reads, so a member can be a partition. Acquisition containers are
  opened first, then the first segment of each split raw set, then the rest, each in name
  order; a file that one of them is read from (`disk1.E02`, `disk2.002`) is named as part
  of it. An image given as its second segment is read as its whole set.
- **Bounded reads.** At most 256 files are opened per search (`max_candidates`), the
  first 256 by name; the rest are named as not opened. At most 64 MiB is read from any
  one of them through qnxprobe's own reads (`read_budget`), besides the first and last
  512 bytes of each file read to tell what kind of file it is, and a file that asks for
  more, as a metadata area claiming to be larger would, is named as over the limit. A
  file smaller than 2,048 bytes, the four sectors an LVM2 label can sit in, is named and
  not opened. The reads an acquisition reader makes to open its container (an EWF set's
  section tables, for one) are its own and not counted. The image given is read as it
  needs, and so are two copies of one member compared byte for byte: the comparison stops
  at the first difference, so copies that are the same are read in full.
- **Files that do not open** (a split set with a hole, a damaged container, an encrypted
  one without its password) are named with why and never stop the search. An encrypted
  container is tried with the passwords and keys given with `--password-file`,
  `--password-env` and `--private-key`.

Not supported: folders read as images (an AFD folder, a sparse bundle) are skipped as
folders; the search does not follow identities it finds in the files it adds (it looks
for what the image given holds, one step); a volume group whose physical volumes are md
arrays is found only through those arrays' members; DDF and Intel IMSM members are named,
not searched for; and the window (`qnxprobe_gui.py`) does not offer the search yet. A
0.90 member is told from another by its device number, and mdadm can give a disk added
to an array a number a removed disk had (`Manage.c` 959-971, mdadm-4.5), so two different
disks of one 0.90 array, the removed one and its replacement, can count as one member
here: the one given is used if either is, otherwise the newer, or neither when they are
as new as each other and differ.

E01 is not among the committed fixtures, so the self-test covers containers with a fixed
VHD and a split raw set. A manual test on 2026-10-16, not repeated by the self-test: a
five-segment E01 of an md RAID5 member, written by `ewfacquire` 20140816 and read through
the vendored ewfprobe 0.12.0, was found as a member (its other four segments named as
part of it) and searched from as the image given, and the array read with it hashed to
the bytes the kernel presented.

From Python, `raid_siblings(path)` returns what the search found, and its `paths()` are
what `raid_open()` takes:

```python
import qnxprobe as q

found = q.raid_siblings("disk0.img")
print("\n".join(found.lines()))
for rec in found.added:
    print(rec["path"], rec["files"], rec["identities"])
for rec in found.rejected:
    print(rec["path"], rec["code"], rec["why"])
with q.raid_open(found.paths()) as rs:
    for arr in rs.arrays:
        print("\n".join(arr.lines()))
```

`raid_siblings(path, passwords=(), private_keys=(), also_given=(), max_candidates=256,
min_bytes=2048, read_budget=64 MiB)` never raises for a file it cannot read; when the
image given itself does not open, `error` says why. The result has `start`, `folder`,
`given` (the files the image given is read from), `identities` (each md array and volume
group looked for), `checked` (one record per other entry of the folder, in the order looked
at, each with `path`, `status`, `code` and `why`), `added`, `rejected` (rejected and
skipped), `missing` (md roles, or physical volumes by name and id, that no file given or
found holds; a member whose copies were ambiguous is among them, and says so), `warnings`,
`ambiguous` (each member whose newest copies differ: `files`, `identity`), `notes`,
`lines()` and `describe()` (all of it as a dict for JSON). An added record also has
`files`, every file its image is read from, `not_searched` when it also holds members of
other arrays or volume groups, and `identities`, each member it holds that matched: for md the array uuid, name, metadata version, role, events and
device uuid (0.90: device number); for LVM the physical volume's name and id, and the
volume group's name, id and seqno. `also_given` takes images the caller already has: they
are never added, and their members count as present.

The statuses and codes: `added` (`md-array-uuid`, `lvm-vg-pv`); `part-of` (`segment`);
`rejected`, opened and not used (`different-array`, `different-vg`, `pv-not-listed`,
`duplicate-member`, `ambiguous-member`, `bad-metadata` for an md superblock magic or an
LVM2 label that does not check out, `foreign-metadata` for DDF or IMSM metadata,
`no-raid-metadata`, `unreadable`, `not-regular` or `changed` for a file that was not, when
opened, the regular file it was when listed, `over-budget`); and `skipped`, not opened
(`symlink`, `directory`, `not-regular`, `changed`, `same-file`, `too-small`, `over-limit`,
and `unreadable` for an entry that could not even be looked at or opened).

`--self-test` puts the member images of each of the 50 md sets that are not DDF in a
folder of their own, with decoys beside them: a member of another array (of the same level
for 48 of the 50 sets; the linear and RAID4 sets have no other set of their level), a copy
of a member with one superblock byte changed so its checksum fails, a FAT12 image, a small
text file, a symbolic link to a member, a subfolder holding a copy of a member, a hard link
to a member, a byte copy of a member, and a split set with a hole. From each of the 194
members it checks that exactly the other members are added and each decoy gets the status
and code it is there for, that every member added carries the array uuid `mdadm --examine`
gives the start, and that the roles reported missing are those no member file holds by
`mdadm --examine`. Each of the 49 md arrays that are read is read from the members found to
the sha256 and size of the device the kernel presented. The same is done for the five LVM
RAID images with a physical volume of another volume group, a label whose checksum fails
and a physical volume id the group does not list as decoys, and each of the three volumes
read from the images found hashes to the kernel's bytes from each of the five starts.
Members in a fixed VHD and in a split raw set are found and read to the kernel's bytes.
Each rule is shown to matter by turning it off and seeing the comparison fail: the array
uuid, the volume group id, the physical volume listing, symbolic links, subfolders, the
same file, a second copy of a member, the size floor, and the superblock and label
checksums (given its checksum again, the changed copy is no longer rejected for it). A linear or
RAID0 member given alone does not read as its array. A search limited to two files names
the rest as not opened and reports the members among them as missing, and with a 4,096-byte
read limit every file that opens is rejected as over the limit and none is added.

It also checks the cases an independent review raised, each shown to fail with its fix
taken out: two files swapped for pipes just after they are listed are refused and the
search returns (it runs in a thread with a 60-second limit; skipped where there are no
pipes); two copies of a 0.90 RAID5 member as new as each other with 4 KiB different are
both rejected as ambiguous, the role is reported missing and the array is rebuilt without
it to the kernel's bytes; given one of those copies, it is used and the other raised as a
warning; for metadata 1.2, three such copies with one different are all ambiguous, while
two byte-for-byte copies give one member and the array reads to the kernel's bytes; two
copies of an LVM2 physical volume with the same seqno and different bytes are ambiguous
and the physical volume is reported missing; given an older copy of a member while the
newer one is beside it, the copy given is used and the newer one named in a warning; an
added physical volume that also holds an md superblock of another array names that array
as not searched for; and the sibling checks and the free-space check leave no temporary
folder behind.

The layouts follow the kernel's own code (Linux v7.0) and mdadm's (4.5), each structure
and rule cited where it is used in `qnxprobe.py` and listed under "Where the constants
come from" below. The fixtures were written by `tools/make_raid_fixtures.sh`, and
`raid-fixtures.json` records the machine it ran on: Linux 7.0.0-38-generic on aarch64
(little-endian), mdadm 4.5 (package 4.5-5ubuntu1.1), lvm2 2.03.31 and mke2fs 1.47.2. Every
lvm2 key and flag this relies on was checked in lvm2 2.03.31 (commit
`3a6e221c569eb253fa38a772b15e53b5de65b5d1`) as well as in the pinned 2.03.43. They are small
member images of 49 md arrays that are read (linear 1, RAID0 4, RAID1 5, RAID4 1, RAID5
12, RAID6 18, RAID10 8, across all four metadata versions), among them RAID5 on GPT
partitions, RAID1 with members of different sizes, RAID0 over members of three sizes in
both layouts, a bitmap, PPL and a write journal, three built degraded (a RAID5 and two
RAID6 created with members missing) and three whose members failed and were removed before
more was written (a RAID5 with one stale member, a RAID6 with two, a RAID1 with one); one
more stopped during a reshape, and a DDF set; and LVM RAID volumes, ten inside one image
(raid4, raid5 in its five layouts, raid6 in three, and raid10) and three across five
images (raid5, raid6, raid10). While each array ran, the script recorded the sha256 and size of
the device the kernel presented, the kernel's own parity check, `mdadm --examine` and
`--detail`, and `lvs`; the files came from a generated tree whose sha256 and listing it
recorded.

`--self-test` checks that every one of those 49 md arrays and 13 LVM volumes reads back to
the sha256 and size of the device the kernel presented, every file (199 in the md
arrays) to its source's sha256 and every listing to its source's; that each member holds
the role `mdadm --examine` gives it; that with each member of every full RAID1, RAID4,
RAID5 and RAID10 array left out in turn, and each one or two of every RAID6 array, the
array still reads to the kernel's bytes (299 member sets); that the same comparison
fails when one RAID5 layout is read as another (the control); that the md signature is
where each metadata version puts it on every md member image (194), as `mdadm --examine`
places it (the positive control for a search of other images); and that the reshape and the DDF
set are refused by name. It also checks inputs changed after mdadm wrote them: a failed
checksum, a member one and two events behind, a member image cut short, the same member
given twice, a member of another level, an array not stopped clean with and without a
member missing, too many members missing, a missing journal device, a journal holding
data with no parity, a big-endian 0.90 superblock, a RAID10 layout with far sets, a RAID0
with no layout recorded, a clustered array, and (constructed, no fixture holds them) an
IMSM anchor and GPT partitions of Windows LDM, Storage Spaces and Apple RAID. It writes no
disk image to disk.

It also checks the cases an independent review raised, each built from a fixture and each
shown to fail without its fix: a bad block log over spoiled bytes on a RAID1 and a RAID5
member (read to the kernel's bytes) and on a linear array (refused); a 0.90 member one
event behind that the freshest superblocks mark faulty, with a chunk written after it
failed (left out, the chunk read as written); 0.90 RAID1 and RAID5 members on MBR
partitions that end where their disks end (read from the partitions to the kernel's
bytes); 4,000,000,000 members recorded (refused at once); a 1,900-member RAID10 near=2
with every other member given (read, its copies checked by looking at each chunk pattern
once, counted rather than timed); a journal meta block whose payloads run past it, given
beside an unrelated array (that array refused by name, the other read); a stale journal
device and a journal device for an array with no journal; a RAID5 chunk that is not a
power of two, a one-copy RAID10, a data offset inside the superblock and a device number
past the freshest role table; the device uuid against `mdadm --examine`; a degraded RAID1
not stopped clean; one member given alone, and a lone RAID1 member; IMSM and DDF anchors on
a 4096-byte-sector disk; an LVM image volume marked REBUILD, one dm-raid lists as failed,
and a physical volume marked MISSING, each with its bytes spoiled (read to the kernel's
bytes from parity or the other copy); a volume marked NOTSYNCED with an image volume to
rebuild (refused); a raid segment naming its own volume (refused, the others read); each
of the five images of the volume group across images left out in turn (all 15 volume
reads to the kernel's bytes); and one of those images given twice (read once).

And the cases a second review raised, each also shown to fail without its fix: bad block
ranges on eight arrangements another copy or parity can supply (read to the kernel's
bytes) and five nothing can (RAID5 two overlapping, RAID5 with a member missing, RAID6
two with a member missing, RAID10 and RAID1 both copies: refused, naming member and
range); a RAID1 read whose copies are both bad, built past that refusal (extracted as
`.SHORT` and counted short) and an LVM RAID read with two image volumes gone (short); an
LVM image volume whose dm-raid superblock says it is still recovering, and one two events
behind (rebuilt from parity to the kernel's bytes, their bytes spoiled); an LVM raid1 copy
marked REBUILD (the other read) and both copies marked (refused); one member beside an
unrelated image and a lone member whose superblock is refused (exit status untouched),
and a complete set refused (counted); members on one image's partitions (no request for
other images); a 1.2 data offset one sector past the superblock (accepted with 512-byte
logical blocks, refused with 4096); a bad block log cut off by the end of the image
(member left out); and free space in rebuilt chunks (said and left out). That free-space
check writes one file, in a folder of its own inside the self-test's temporary folder.

And a third review's: the command line's RAID step, report included (`raid_run`, the code
`qnxprobe.py` runs after the images), over every non-empty subset of the member images of
a RAID1, RAID5, RAID6, RAID10 and 0.90 RAID5 set and of the five images of the volume group
across images (110 subsets): nothing escapes, exactly the arrays and volumes the subset
can hold (worked out from the level and from where `lvs` put each image volume, not from
the reader) are read, each to the kernel's bytes, and none counts against the exit status;
four RAID5 members two of them stale, and an LVM volume refused for its own REBUILD marks
with every image given (both count), against the same volume with images missing (does
not); a metadata volume with no dm-raid superblock (rebuilt from parity); and members
whose reads fail over a range (read around from the other copy or parity; with both RAID1
copies failing, the read ends short and gives no digest). A fault in one array's report or
read is said and never stops the others being reported or read.

And a fourth review's: a RAID5 not stopped clean whose data member fails to read where its
parity is out of step (the read ends short, it is not rebuilt), with an unclean RAID1 copy
failing (read from the next copy, as md does); the LVM exit rule by legs (one leg's image
not given and another marked REBUILD: counts); the layout control now requires a full read
before comparing digests; and a member read that fails once and serves when tried again
(read in full, in one read, on RAID0).

What no fixture exercises as mdadm or lvm2 wrote it (the cases above are changed copies of
fixtures): a big-endian 0.90 array (refused), a bad block log written by the kernel, a
dm-raid superblock listing a failed device, LVM's raid6 layouts with a
dedicated Q (raid6_ls_6 and the rest; md's own versions of those layouts are in the
fixtures and read through the same code), an array
whose members are partitions of one image, an LVM volume group on an md array, and free
space read from an array (the fixtures hold ext4, whose free space is not reported). IMSM
and DDF arrays are not assembled; only a mirror's members are read, one by one, each
saying so. No fixture holds IMSM metadata: the self-test builds it.

## XFS

XFS is the default filesystem of Red Hat Enterprise Linux and its rebuilds, and common on
Linux servers, NAS units and storage appliances. `--list`, `--extract` and
`--unallocated` read it directly, no mounting. A volume is claimed only once its
superblock is verified: the `XFSB` magic, a geometry that holds as the kernel requires it,
and on v5 a superblock CRC that holds. A v4 superblock has no CRC, so its root inode must
also read as a directory. A superblock that fails any of these is not claimed, and the
other filesystems get their turn at the region.

What it reads:

- version 5 volumes (metadata CRCs) and version 4 volumes (no CRCs), which `mkfs.xfs`
  6.18 still makes with `-m crc=0` while warning that v4 is deprecated;
- version 2 and version 3 inodes (version 1 too, by the source; no v1 inode was made to
  test), found from the inode number alone: allocation group, block, slot;
- timestamps as UTC instants to the nanosecond, both the classic signed 32-bit seconds
  (so dates before 1970 read right) and the `bigtime` 64-bit nanosecond counter that runs
  to 2486; the creation time of a v5 inode is kept too (`XfsWalker.inode_info`);
- data forks held inline, as a list of extents, or as a B+tree of extents, with the
  32-bit or the `nrext64` 64-bit extent counters; holes read as zeros and so does an
  extent allocated but never written (`unwritten`);
- directories in all five forms: shortform (in the inode), block, leaf, node, and node or
  leaf with a B+tree extent map, with and without the file type byte (`ftype`), and
  directory blocks larger than the filesystem block;
- symbolic links held inline and in blocks of their own; hard links, which list as one
  inode under each name; FIFOs, listed and not extracted (device nodes the same way, by
  the source: making one needs root, and none was made);
- free space, from each allocation group's free-space B+tree by block number.

The extended attributes themselves are not read. A file that has them is read correctly:
the attribute fork's size is taken off the data fork's, as the format requires.

### What is checked, and what happens when a check fails

What the kernel checks before it uses a structure is checked here:

- the superblock: its geometry, and on v5 its CRC;
- each inode, in the kernel's order (`xfs_dinode_verify`): the magic, then on v5 the CRC,
  its own inode number and the volume's uuid, then a size within the format's largest, a
  mode that is a file type, the fork offset, and an extent count its fork can hold;
- every block number an extent or a B+tree pointer names: inside an allocation group,
  before that group's end (the last group ends where the volume does), clear of the
  group's own headers, and an extent not crossing into the next group;
- each extent B+tree block: magic, level, record count, a height no greater than the
  volume allows, and on v5 its CRC, its own disk address, its owner and the uuid;
- each directory data block, and each leaf and node block when the index is read: on
  v5 the CRC, its own disk address, its owner and the uuid; each entry's tag; a shortform
  directory's count of 8-byte inode numbers;
- each remote symlink block on v5: the CRC, the offset, length, owner, uuid and disk
  address its header records; only the blocks the target needs are read;
- each AGF and free-space B+tree block, for free space.

The log's records are not checked against their CRCs: only the head, the tail and the
unmount flag are read (see below).

What fails is not used, and is counted:

- an inode that fails reads as absent and the rest of the volume still lists;
- a directory block that fails is skipped and the rest of the directory still lists;
- a file whose extent map or symlink block fails is not handed back at all, so it is
  counted as failed in an extraction, never written cut short;
- a volume larger than the region it sits in says its end is missing; a structure past
  the end is counted as damage, and file data past it reads short, so an extraction
  names the file `.SHORT` rather than passing it as whole. In a region shorter than the
  image (a partition followed by another), nothing past the region is read as the
  volume's.

The count and the first damaged structure appear in the volume's note.

**The log is not replayed.** Whether it is clean is decided the way `xfs_db` and
`xfs_logprint` decide it (libxlog `xlog_is_dirty`): find the log's head by the cycle
numbers stamped in it, and its tail from the last record before the head. A dirty log is
reported in the volume's lines and its note, and the volume is read as it is stored: what
was still only in the log is not there. The head is found by the kernel's first pass only;
its later passes step back over a write torn at the moment of a crash, which this does
not, so on such a log the head named here can be later than the kernel's. An external log
is reported as such, its state not known.

### What is refused, and why

- **Incompatible features outside the ones it reads** are refused by name, or by bit when
  the bit has no name. Read: `ftype`, sparse inode chunks, meta uuid, `bigtime`,
  needsrepair (read, and reported), `nrext64`, exchange range, parent pointers and the
  metadata directory. Refused: the zoned realtime allocator and its zone gaps, and any
  unknown bit, which the kernel refuses too. Unknown read-only-compatible bits are named
  and the volume is still read, as the kernel will still mount it read only.
- **Realtime files.** A file whose blocks are on the realtime device is listed, and its
  read is refused with the reason: that device is a separate one this does not read.
- **Superblock versions 1 to 3**, which no current kernel mounts, and a v4 volume without
  version 2 directories or unwritten extents, which the kernel will not mount either.
- **A metadata B+tree data fork** (`meta_btree`, used by realtime metadata inodes) is
  not read; no such inode is reachable from the root of the tree.

A file whose recorded size is within the format's largest but far past the data it maps
is read as the sparse file it says it is: the bytes past its last extent read as zeros,
however many. A forged size of 2^56 bytes on one 26-byte file was tested; it is not
counted as damage, and extracting it would try to write it whole.

### Free space

`free_extents()` reports each allocation group's free extents from its free-space B+tree
by block number. The few blocks on each group's free list (AGFL), held back for the
B+trees' own growth, are not in that tree and are not reported. Nothing is reported for a
volume unless every group's AGF and every tree block pass their checks and the free
blocks each tree records add up to its AGF's own count, the comparison `xfs_repair`
makes.

### Checked against

`mkfs.xfs` 6.18 wrote three fixtures from a source tree on Ubuntu 26.04
(`tools/make_xfs_fixtures.sh`, no root needed: `mkfs.xfs -p` copies a directory into the
image, keeping holes, hard links and every mtime). Two more were written through the
kernel on a mounted volume by `tools/make_xfs_root_fixtures.sh`, run as root. The listing
and the sha256 of every file were taken from the source tree (for the two mounted ones,
read back through the mounted filesystem), and `xfs_db`, `xfs_logprint` and
`xfs_repair -n` read each image independently.

| Fixture | Made with | Size (gzip) | What it carries |
| --- | --- | --- | --- |
| `xfs-v5` | defaults, 300 MiB | 682 KiB | v5 with bigtime and nrext64, 4,953 entries; block, leaf and node directories and a node directory with a B+tree extent map; a file with a 60-extent B+tree map; holes; times before 1970 and after 2038 |
| `xfs-v4` | `-m crc=0 -n ftype=0,size=16384 -b size=1024`, 64 MiB | 332 KiB | v4, no ftype, 1 KiB blocks and 16 KiB directory blocks, 5,352 entries; a leaf directory, and a leaf and a node directory each with a B+tree extent map |
| `xfs-v5-4kn` | `-s size=4096 -m metadir=1,bigtime=0 -i size=1024,nrext64=0`, 64 MiB | 83 KiB | 4 KiB sectors, the metadata directory, classic times and 32-bit extent counts on v5, 146 entries |
| `xfs-mounted` | defaults, 300 MiB, written by the kernel | 1,214 KiB | 529 entries; two files grown a block at a time to 657 extents each, so a B+tree root in the inode over three leaf blocks; a 657-extent reflinked copy sharing those extents; unwritten extents from `fallocate` either side of a written one; a node directory with a B+tree extent map after 1,500 of its 2,000 entries were removed; a file whose 60 attributes are in blocks of their own |
| `xfs-dirty` | `xfs-mounted`, mounted again, files added, then shut down | 1,281 KiB | a dirty log (head 31,936, tail 31,919 by `xfs_logprint`); the files added did not reach the tree on disk |

On all five the self-test finds every entry by path with its type and permission bits,
size, mtime to the nanosecond and symlink target, every regular file with its sha256,
hard links as one inode, each test directory in the format `xfs_db` gives it (and its
entry count equal to its own hash index's, less `.` and `..`), every recorded file's and
directory's extent map with the number of extents `xfs_db` maps, the free extents equal
to `xfs_db`'s less the free-list blocks it also lists (not on `xfs-dirty`, whose free-space
trees on disk may predate its log), and the log state, head and tail `xfs_logprint`
reports. On the v5 fixtures it also finds every inode's creation time at or before its
change time. On `xfs-v5`, `--extract` wrote 4,920 files whose sha256 all match the source
tree.

Other paths are proved on a fixture patched in memory by the self-test, each with any
other check that would see the change made to hold (a CRC rewritten, say), so that only
the check under test can catch it: an extent flagged unwritten; an inode without its
magic, one that fails its CRC, and one counting more extents than its fork holds; a
realtime file; a dirty log (the unmount record's flag cleared); refused feature bits; a
superblock whose CRC fails; a shortform directory with 8-byte inode numbers, and one whose
header miscounts them; a directory block that fails its CRC, one that names another
owner, another volume or another disk address, and an entry whose tag is wrong; an
extent B+tree block that fails its CRC, and a root taller than the volume allows; an
extent crossing its group's end, one on a group's headers, and a last group shortened by
the superblock; remote symlink headers naming another offset, length, owner or block, and
one mapped to 2,000 blocks; a volume cut to half its size, and one in a region shorter
than the image; and a v4 superblock pasted onto a region with no XFS root inode behind it.
Each of these checks was shown to fail when the line of the reader it guards was changed.

The layout is sourced from xfsprogs v6.18.0 (commit
8b892adad226bb9fef4009c4cba4dbc25b70b011); no xfsprogs code was copied, as xfsprogs is
GPL:

```
superblock, struct xfs_dsb                   libxfs/xfs_format.h:193
feature bits                                 libxfs/xfs_format.h:35-87, 373-416
AGF, at sector 1 of each group               libxfs/xfs_format.h:517, 610
inode core, struct xfs_dinode                libxfs/xfs_format.h:901
data fork size and place                     libxfs/xfs_format.h:1093-1121
classic and bigtime timestamps               libxfs/xfs_format.h:780-857
inode number to AG, block, slot              libxfs/xfs_format.h:1270-1289
filesystem block number to AG and block      libxfs/xfs_format.h:702-707
bmap record, root and block layout           libxfs/xfs_format.h:1843-1910, 1928-1982
                                             libxfs/xfs_bmap_btree.c:77, 747, 782
remote symlink header and read               libxfs/xfs_format.h:1502
                                             libxfs/xfs_symlink_remote.c:86, 236
free-space record and block                  libxfs/xfs_format.h:1543
                                             libxfs/xfs_alloc_btree.c:563
directory blocks, entries, leaves, tail      libxfs/xfs_da_format.h:214-540
the data, leaf and free spaces, 32 GiB each  libxfs/xfs_da_format.h:292-294, 418, 483
directory entry walk and sizes               libxfs/xfs_dir2_data.c:96, 1231
                                             libxfs/xfs_dir2_priv.h:200
                                             libxfs/xfs_dir2_sf.c:41-140
directory format and geometry                libxfs/xfs_dir2.c:132-162, 264
inode checks                                 libxfs/xfs_inode_buf.c:175, 586
superblock checks                            libxfs/xfs_sb.c:82, 192, 475, 1072
CRC32C rule                                  libxfs/xfs_cksum.h
log head, tail and clean state               libxfs/xfs_log_format.h:26-128
                                             libxlog/xfs_log_recover.c:178, 400, 671
                                             libxlog/util.c:46
```

## Split images

FTK Imager and its peers write a raw image as numbered segments (`.001`, `.002`, ...)
unless told to write one file, and the first segment alone is a trap: it carries the
partition table and the boot volumes, so it identifies cleanly and its front volumes
read correctly, while the volume holding the user data ends past the cut, where every
read answers empty. Measured on a Ford Sync G4 image cut at 1,500 MB: every boot
partition extracted in full and the 28.8 GiB storage volume walked to 0 files with
nothing raised.

Since 1.13 the tool joins the set itself. Name any one segment and every segment
beside it (same folder, same stem, same number of digits) is read as one image, in
order, with nothing copied or concatenated on disk:

```
python3 qnxprobe.py --extract case.zip mmcblk0.img.001    # .001 through the last segment beside it
```

The report says what was joined (`20 segments joined, mmcblk0.img.001 ..
mmcblk0.img.020`, with the segment sizes), and in `volumes.json` every volume's
`image` names the first segment while `image_segments` lists each one with its byte
count, so the extraction can be checked back against the set.

A set is joined only when it is whole from its first segment. A hole in the numbering
(`.001` and `.003` with no `.002`), a set whose lowest segment is not `.000` or `.001`,
and segments numbered at two different widths are each refused by name, with exit
status 1, because a set joined around a hole reads every volume past it at the wrong
offset and answers wrong rather than empty. A set that simply ends early cannot be
told from a small disk by its numbering; that case is caught the other way, by the
partition table reaching past the joined size, which draws the
`IMAGE IS SHORTER THAN ITS PARTITION TABLE` warning described under "What it does not
do".

## EnCase/EWF and AFF acquisitions

An acquisition is read directly, so a run on one works exactly like a run on a raw
image:

    python3 qnxprobe.py evidence.E01

Since 1.38 that covers every disk image the vendored reader reads, each recognised
by its own first bytes rather than its name:

| Container | Point it at |
| --- | --- |
| EnCase/EWF (E01) | the `.E01` |
| SMART (EWF-S01) | the `.s01` |
| EWF2 (Ex01) | the `.Ex01` |
| AFF | the `.aff` |
| AFD, the folder of AFF files AFFLIB writes when an image is split | the `.afd` folder, or any `.aff` in it |
| AFM, AFF metadata beside the disk as raw files, since 1.47 | the `.afm`, with its `.000`, `.001`, ... beside it |
| an AFF, AFD or AFM AFFLIB encrypted, since 1.47 | the same, with its passphrase, or with `--private-key` when it is sealed to a certificate |
| Apple disk image (UDIF), since 1.39 | the `.dmg` |
| Apple disk image split by `hdiutil segment`, since 1.40 | the `.dmg`, with its `.dmgpart` files beside it |
| Apple sparse image, since 1.39 | the `.sparseimage` |
| Apple sparse bundle, since 1.40 | the `.sparsebundle` folder |
| any of the Apple images above encrypted with a password, since 1.41 | the same, with its password |
| any of the Apple images above sealed to a certificate, since 1.48 | the same, with `--private-key` (the certificate's RSA private key), or its password when it also has one |
| an E01, SMART or raw (dd) set FTK Imager encrypted with AD encryption, since 1.42 | the first file (`.E01`, `.s01`), or any `.001`, `.002`, ... of a raw set, with its password |
| such a set sealed to a certificate instead of a password, since 1.49 | the same, with `--private-key` (the certificate's RSA private key) |
| AFF4 (standard v1.0 or Evimetry's pre-standard layout), since 1.44 | the `.aff4`, or any file of one striped across several, with the others beside it |
| VHD, fixed, dynamic or differencing, since 1.46 | the `.vhd`; a differencing one with its parent beside it or where it names |
| VHDX, fixed, dynamic or differencing, since 1.46 | the `.vhdx`, likewise |
| VMDK, since 1.46 | the descriptor `.vmdk`, or any of its sparse extents, with its other files beside it |
| QCOW, versions 1, 2 and 3, since 1.46 | the `.qcow` or `.qcow2`; an overlay with its backing file beside it |

A `.dmg` is recognised by the trailer at its end. An uncompressed read-write `.dmg`
has no trailer: it is the disk's bytes as they are, and has always been read as a raw
image. An AFF4 is a ZIP, and is told from any other ZIP by the volume URI the AFF4
Standard has its writer put in the ZIP comment or in a first member named
`container.description`; ewfprobe reads its map, image streams (stored, Snappy, LZ4
or deflate) and symbolic streams, and reports an AFF4 whose streams it cannot find
beside it as incomplete. A `.dmg` compressed with LZFSE needs the optional `pyliblzfse` package beside
ewfprobe, and is refused, naming it, without. Since 1.41 an Apple disk image encrypted
with a password (`hdiutil -encryption`, AES-128 or AES-256; a `.dmg`, a split one, a
`.sparseimage` or a `.sparsebundle`) is read with that password, which needs the
optional `pycryptodome` package and is refused, naming it, without. Give the password
with `--password-file FILE` (its first line) or `--password-env NAME` (an environment
variable), both repeatable, and each image opens with the first that opens it; without
either, qnxprobe asks at a terminal. The window asks for it once per image and keeps it
in memory for the session, and hands it to the report it runs through an environment
variable, never on a command line. From Python, `open_image(path, password=...)`
raises `ImagePasswordError`, whose `wrong` says whether a password was given, when the
image does not open. Before 1.41 an encrypted image was refused. Since 1.42 an E01,
SMART or raw (dd) set FTK Imager encrypted with AD encryption opens the same way, with
the same password options; `needs_password(path)` answers for both kinds, and
`PASSWORD_FORMATS` names them as `acquisition_format` does (`DMG_ENCRYPTED`,
`AD_ENCRYPTED`). Only the first file of such a set carries the encryption header, so
a later numbered file of a raw set is recognised by its first. Before 1.42 an
AD-encrypted set was read as raw bytes and nothing in it was recognised. A `.dmgpart` on
its own is refused by the reader, which names the `.dmg` to open instead, and a split
`.dmg` with a segment missing is refused rather than read short. A sparse bundle is
recognised by its `Info.plist`, whatever the folder is called. Before 1.40 a sparse
bundle stopped the run with a Python error (`IsADirectoryError`), and a split `.dmg`
was refused. Before 1.39 a `.dmg` or `.sparseimage` was read as raw
bytes; made from one test volume in every format `hdiutil` writes, the compressed ones
(UDZO, UDBZ, ULMO, ULFO, UDCO), UDRO, the sparse image and an encrypted image all came
back `not recognised`, and only the three that hold the disk's bytes in order (UDRW,
`.cdr` and UFBI) were read.

Before 1.38 only the E01 signature was recognised. An Ex01, AFF, AFD or L01 was
read as raw bytes, and on every test acquisition of each that found no filesystem
at all: the report said `whole image ... not recognised`.

Since 1.47 an AFF AFFLIB encrypted opens with its passphrase, given the way any
password is, or, when it is sealed to a certificate, with that certificate's RSA
private key (`--private-key FILE`, repeatable; the window asks for the key file).
`needs_password` and `needs_private_key` say which one an image needs, and
`ImagePasswordError.needs` names it when neither was given. An AFF whose header was
overwritten by a segment, as AFFLIB 3.7.22's `affcrypto -e` leaves a file it
encrypts in place (AFFLIB cannot open it afterwards), is recognised by that segment
and read from its segments. An `.afm` is read from the raw files beside it; before
1.47 it was read as an AFF with every page missing, so the whole disk came back as the
bad-sector marker and nothing on it was found.

Since 1.48 an Apple disk image sealed to a certificate (`hdiutil create -certificate`)
opens the same way, with that certificate's RSA private key; one that also has a
password opens with either. Before 1.48 an image sealed only to a certificate was
refused whatever was given. An image whose key is kept in a keybag is still refused,
naming it.

Since 1.49 an E01, SMART, raw or AD1 set FTK Imager sealed to a certificate with AD
encryption opens the same way, with that certificate's RSA private key; before 1.49 it
was refused as needing a password it could not use. An AD1 inside is still refused as
logical evidence. `needs_password` and `needs_private_key` now ask the reader for an
AD-encrypted set too, so one whose header is damaged is refused on opening rather than
asking for a password first.

Since 1.46 the disks virtual machines keep are read the same way: Microsoft's VHD and
VHDX, VMware's VMDK and QEMU's QCOW, each recognised by its own bytes (a VHD by the footer at its end
or the copy of it at its start). A differencing VHD or VHDX, a VMDK delta and a QCOW
overlay are read through the disks under them, which the reader checks against the id
the child records where the format keeps one; the report names each parent, and
`volumes.json` lists every parent file with its byte count as `image_parents`, nearest
first. A VMDK flat extent holds the disk's bytes as they are and is still read as raw.
An encrypted QCOW is refused by the reader. Before 1.46 a fixed VHD was read as a raw
image with its 512-byte footer at the end (on the one qemu-img 10.2.1 wrote, that still
found its volume), and the dynamic VHD, VHDX, VMDK and QCOW2 disks qemu-img 10.2.1
wrote, and a dynamic VHD Windows 11 wrote, each came back `whole image ... not
recognised`. Extracting through a differencing VHD Windows 11 wrote now gives the same
22 files, byte for byte, as extracting from the disk Windows presented, read through
`\\.\PhysicalDriveN`.

The segments of a multi-segment acquisition, and the files of an AFD, are joined by
the reader from the format's own records, not from the file names, and a set
missing a segment or a file is refused rather than read short.

Logical evidence, EnCase's (`.L01`, `.Lx01`) and FTK Imager's (`.ad1`, `.ad2`, ...),
holds copies of files, not a disk, so it has no partition table or filesystem for this
tool to read. It is refused with a message saying so, and never read as raw bytes,
including an AD-encrypted set that turns out, once opened with its password, to hold an
L01 or an AD1. `ewfprobe.py` lists and exports the files of an L01 or an AD1
(`python3 ewfprobe.py files evidence.ad1`).

This is `ewfprobe.py`, vendored from
[abrignoni/ewfprobe](https://github.com/abrignoni/ewfprobe) and recorded in
`vendored.json`. It is MIT, pure Python and standard library only, so it adds
nothing to build and nothing to install; only an LZFSE `.dmg` and an encrypted image
(an Apple disk image or an AD-encrypted acquisition) need an optional package, and the
release executables carry the one for encrypted images. `tools/check_vendored.py` confirms the
copy still matches what was vendored, and reports a copy it could not check
separately from one that has drifted, because those are different results.

The reader is optional. Without `ewfprobe.py` beside this script everything else
works as before, and an acquisition is refused with a message saying what is
missing.
It is never read as raw bytes: a container read that way holds no filesystem the
walkers can see, so the run would report an empty image instead of saying it
could not read the container.

Measured with 1.27 on a 15-segment FTK Imager acquisition of a 232.9 GiB Windows
disk: the segments join, the GPT and its four partitions are read, the EFI system
partition is identified as FAT32 and the basic data and recovery partitions as
NTFS, all in about a second. Only the 16 MiB Microsoft reserved partition is
reported as not recognised, with its first bytes shown.

## Options

| Option | What it does |
| --- | --- |
| `--list` | Walk each filesystem found and list its contents (qnx6, qnx4, ext2/3/4, Btrfs, F2FS, FAT32, exFAT, NTFS, ReFS, HFS+, APFS, XFS, ETFS, EFS and QNX IFS boot images) |
| `--depth N` | How deep to walk with `--list` (default 2) |
| `--list-max N` | Stop after this many entries per filesystem (default 400) |
| `--extract OUT.zip` | Copy the logical files out of every filesystem into a zip |
| `--unallocated DIR` | Write the free space of every volume whose filesystem reports it into DIR, with a map back to the image. See [Writing free space to files](#writing-free-space-to-files) |
| `--only TEXT` | Restrict `--list`, `--extract` and `--unallocated` to partitions whose name or label contains TEXT |
| `--exclude TEXT` | Skip any path containing TEXT when extracting. Repeatable |
| `--triage` | Rank volumes by how much each has been written, and flag encrypted or bulk ones |
| `--progress` | While extracting, emit one JSON progress object per line on stderr, for a caller driving this as a subprocess. The report on stdout is unchanged |
| `--password-file FILE` | For an encrypted image (an Apple disk image, an AD-encrypted FTK Imager acquisition or an encrypted AFF), a BitLocker volume or an encrypted APFS volume: a password or recovery password (for APFS, the personal recovery key), the first line of FILE. Repeatable |
| `--password-env NAME` | For an encrypted image, a BitLocker volume or an encrypted APFS volume: a password, from the environment variable NAME. Repeatable. Without either, qnxprobe asks at a terminal for an encrypted image's password |
| `--bitlocker-key FILE` | A BitLocker startup key (a `.BEK` file), tried against every BitLocker volume. Repeatable |
| `--private-key FILE` | For an AFF, an Apple disk image or an AD-encrypted set sealed to a certificate, the certificate's RSA private key, unencrypted, as PEM or DER. Repeatable |
| `--scan-limit MiB` | How far to brute scan when no superblock sits at the offsets the kernel checks (default 256) |
| `--self-test` | Build throwaway positive and negative images, confirm the detector reports both ways, then delete them |
| several images | Each image is read, then each Linux md array and each LVM volume group spread over several of them is assembled from its members and read as an image of its own (see [RAID](#raid)) |
| `--version` | Print the version |

## The self-test, and why it is not decoration

Run it once before you trust a negative result on real evidence.

```
python3 qnxprobe.py --self-test
```

It builds throwaway images in a temp directory, some that must be detected and one
that must not, across qnx6 (both endians), QNX4, ext4, ext2, F2FS, FAT32, exFAT, NTFS, HFS+, APFS, ETFS, EFS and QNX IFS,
checks them, and removes the directory. For ETFS it also round-trips one file out of
a synthetic image, so a broken structure offset, not just a broken constant, turns
the leg red. For IFS the UCL decoder is run against a fixed synthetic block whose
expected output is written out by hand, and a flipped byte in a synthetic imagefs
must break the image checksum, so a regression in the decompressor or the walk
turns a leg red rather than passing against itself.

The expected values in it are written as literal bytes rather than derived from the
constant they verify. That matters: an earlier version built its fixtures from
`QNX6_MAGIC`, and it passed with the magic deliberately corrupted to `0x68191123`,
which is a build that cannot identify a single real filesystem. A test whose fixture
moves with the bug is not a test. The same discipline covers the ETFS reserved names
and the EFS `QSSL_F3S` signature: break one of those literals and the self-test
exits 1.

## A magic match is not a finding

Across a 256 MiB scan you expect roughly one 4-byte magic hit by chance. Every
candidate is therefore parsed as a superblock and its fields checked for internal
consistency before it is reported CONFIRMED. The run tells you how many matches were
rejected as coincidence.

## Where the constants come from

Nothing here is assumed. Every constant and field offset is read out of the
producer's own source.

QNX6, from the Linux kernel's qnx6 driver:

```
QNX6_SUPER_MAGIC     0x68191122   include/uapi/linux/magic.h:55
QNX6_BOOTBLOCK_SIZE      0x2000   include/linux/qnx6_fs.h:23
QNX6_SUPERBLOCK_SIZE      0x200   include/linux/qnx6_fs.h:21
struct qnx6_super_block               include/linux/qnx6_fs.h:94
```

`fs/qnx6/inode.c` reads the first superblock at `QNX6_BOOTBLOCK_SIZE` and, if the
magic is wrong there, retries at offset 0. It tries little endian first, then big
endian, so both are live in the wild and both are checked.

ext2/3/4:

```
EXT2_SUPER_MAGIC     0xEF53   linux/include/uapi/linux/magic.h:24
EXT4_EXT_MAGIC       0xf30a   linux/fs/ext4/ext4_extents.h
struct ext4_super_block, ext4_group_desc, ext4_inode, ext4_dir_entry_2
                              linux/fs/ext4/ext4.h
```

The ext field offsets were derived from that header and cross-checked against its own
`/*NN*/` offset markers, all fifteen of which agreed, with the struct totalling the
expected 1024 bytes.

F2FS, from the Linux kernel at v7.0 (commit
`028ef9c96e96197026887c0f092424679298aae8`):

```
F2FS_SUPER_MAGIC     0xF2F52010   include/linux/f2fs_fs.h
struct f2fs_super_block, f2fs_checkpoint, f2fs_inode, node_footer,
  f2fs_dir_entry, f2fs_dentry_block, f2fs_nat_entry
                                  include/linux/f2fs_fs.h
current_nat_addr, get_node_path   fs/f2fs/node.{h,c}
validate_checkpoint               fs/f2fs/checkpoint.c
sanity_check_raw_super            fs/f2fs/super.c
read_normal_summaries             fs/f2fs/segment.c   (the NAT journal)
do_read_inode                     fs/f2fs/inode.c
f2fs_fill_dentries                fs/f2fs/dir.c
```

The inode's address count, the direct/indirect node layout and the NAT block
addressing are all parameterised by the superblock's block size, so a 4K-block
and a 16K-block volume are read the same way.

QNX IFS boot images, from QNX's own `dumpifs` and `sys/image.h`:

```
STARTUP_HDR_SIGNATURE  0x00ff7eeb   qnx sys/startup.h:88
STARTUP_HDR_VERSION             1   qnx sys/startup.h:89
struct startup_header               qnx sys/startup.h
flags1 compression, block framing   qnx dumpifs.c  (none/zlib/lzo/ucl)
struct image_header, image_dirent   qnx sys/image.h
UCL NRV2B (_8) decompressor          Oberhumer UCL src/n2b_d.c, src/getbit.h
```

The startup header's field widths sum to 256 bytes, which each image's own
`header_size` field confirms, and the `machine` field is an ELF machine type
(`EM_386` 3, `EM_ARM` 40, `EM_X86_64` 62, `EM_AARCH64` 183 from
`linux/include/uapi/linux/elf-em.h`). `flags1` gives the compression method; a
compressed imagefs is a run of blocks, each a two-byte big-endian length then
that many bytes decompressing to at most 64 KiB, ending at a zero length. Each
UCL block is NRV2B, ported from Oberhumer's UCL into a small pure-Python decoder
so the tool still installs nothing, and `zlib` images are read through the
standard library. The decompressed image is walked from its `image_header` and a
flat table of `image_dirent` records.

This is proven byte for byte against the Ford Sync G4 `ifs_a`, `ifs_b` and
`ifs_recovery` volumes: each decompressed to exactly the `imagefs_size` its own
header records, the 32-bit words from the header through the `image_trailer`
summed to zero against the trailer's checksum, and the extracted files were
valid, including the AArch64 ELF kernel `procnto-smp-instr` whose machine matched
the startup header. That checksum is reported on every run as a decode self-check.

QNX4, from the Linux kernel's read-only qnx4 driver, the same sourcing as qnx6:

```
QNX4_SUPER_MAGIC       0x002f   linux/include/uapi/linux/magic.h:54
struct qnx4_inode_entry         linux/include/uapi/linux/qnx4_fs.h:44
struct qnx4_link_info           linux/include/uapi/linux/qnx4_fs.h:63
struct qnx4_xblk ("IamXblk")    linux/include/uapi/linux/qnx4_fs.h:71
field widths                    linux/include/uapi/linux/qnxtypes.h
directory entry union           linux/fs/qnx4/qnx4.h:75
```

The `0x002f` magic is simply the `/` name of the root directory inode at the
start of the superblock, 512 bytes into the volume. Blocks are 512 bytes and
1-based on disk. A directory's data is a run of 64-byte entries: a name up to
16 bytes is a full inode entry stored inline, a longer name (up to 48) is a
link entry resolving to the real inode by block and index, conventionally
inside the `.inodes` file. A file's extents 2..n live in a chain of `IamXblk`
blocks, followed exactly as `fs/qnx4/inode.c qnx4_block_map()` follows them.
Detection requires what the kernel itself requires to mount: the `/` root
inode with a directory mode and a `.bitmap` entry in the root directory
(`qnx4_checkroot`). A QNX4 boot block can end in `0x55AA`, so the MBR parser
declines a sector whose following sector is a QNX4 root superblock, the same
shared-magic rule as FAT above.

A qnx6 boot block can end in `0x55AA` as well: on qnxmount's qnx6 reference image
sector 0 is x86 boot code, and its bytes at 446 parse as two partitions starting
1.5 and 1.8 TB into a 400 KB file. Taking that table at face value hid the
filesystem entirely, since the qnx6 at offset 0 then had no partition to be listed
or extracted from and its end-of-volume superblock, the active generation, was never
probed. So the MBR parser first checks for a consistent qnx6 superblock at `0x2000`,
the offset the Linux driver reads (`fs/qnx6/inode.c`, `qnx6_fill_super`), and
declines the sector if one is there. As a last resort it also declines any table none
of whose partitions begins inside the image. The boot indicator byte is not used as a
test, because neither util-linux's libfdisk nor The Sleuth Kit rejects a table on it.
The self-test builds an image of this shape and requires both superblock copies to be
found and the volume to be listed.

Since 1.31 the GPT is read as UEFI 2.10 section 5.3 lays it out. The primary header is at LBA 1,
so its byte offset is the logical sector size: 512 on most disks, 4096 on 4Kn drives
and UFS LUN images, and both are tried. A header is used only when it passes the four
checks the spec lists in section 5.3.2: the `EFI PART` signature, HeaderCRC32 over
HeaderSize bytes with that field set to zero, MyLBA naming the block it was read from,
and the CRC32 of the partition entry array, with the offsets from Table 5.5 and the
entry fields from Table 5.6. When the primary fails, the backup header in the last
logical block is read, as that section says to, but only when sector 0 holds a
protective `0xEE` record, because the same section warns that a disk reformatted to a
legacy MBR can keep a stale GPT there. The report names every header it did not use
and why, and says when the backup was the one read. On a 4096-byte disk the MBR's LBAs
are counted in 4096-byte sectors too: Table 5.4 starts the protective record at LBA 1,
"the LBA of the GPT Partition Header". The self-test builds a GPT at each size around
the ext4 fixture and requires the volume at the byte its entry names. Those images read
the same in The Sleuth Kit's `mmls -b 4096` and in util-linux `sfdisk --sector-size
4096`, and a GPT that `sfdisk` wrote with 4096-byte sectors is read as `sfdisk` wrote it.

The QNX4 reader was validated by round-trip against the Linux kernel driver
itself: a fixture populated with nested directories, a multi-extent file, a
long name, a symlink, an empty file and distinct modes, owners and mtimes was
mounted read-only with `fs/qnx4` on kernel 7.0.0, and every path, type,
permission, owner, size, mtime, symlink target and byte of content the kernel
reported matched what this walker reads, 15 of 15 entries. The fixture was
written by a separate generator program (its skeleton follows Peter
Waechtler's Linux-side QNX4 `dinit`, a second independent statement of the
layout), not by this parser, so the two sides are independent.

QNX ETFS and EFS, from [NetherlandsForensicInstitute/qnxmount](https://github.com/NetherlandsForensicInstitute/qnxmount)
(Apache-2.0):

```
etfs_trans, fid scheme, ftable + dir entry   qnxmount/etfs/parser.ksy -> fs/etfs.h
F3S extent, unit, boot, dir entry            qnxmount/efs/parser.ksy  -> fs/f3s_spec.h
```

qnxmount is a peer institute's vehicle-forensics reader. Its ETFS spec cross-references
QNX's own `fs/etfs.h` and its EFS spec `fs/f3s_spec.h`; only the field layouts are
transcribed here, into the same hand-written struct style, so the Kaitai runtime is not
a dependency and the tool stays standard library only. Both readers were validated by
extracting qnxmount's own committed test images and comparing every name, mode, owner,
timestamp, symlink target and byte of content against the tar archive built from the
same live filesystem, which qnxmount produced on QNX independently of this code: ETFS
matched 32 of 32 entries, EFS 31 of 31. ETFS has no magic, so it is claimed only when
the page geometry divides evenly and the `.filetable` carries its fixed reserved names
at their fixed ids; EFS is claimed by its `QSSL_F3S` boot record. Neither fired on the
u-boot, boot_fs or ext partitions of the two vehicle images tested.

The EFS layouts are read from qnxmount at commit
`11c8a7f9ee9b945d584263743f6ea8524e8776d2`. The extent status bits (condition mask 0x70
with free 0x70, allocated 0x30, deleted 0x10 and bad 0x00; NO_NEXT 0x02, NO_SUPER 0x04,
LAST 0x80; type mask 0x300 with file 0x300, directory 0x200, system 0x100), the header
index of the boot record (2) and the endian byte of `f3s_unit_info_t` are from the header
that spec pins,
[fs/f3s_spec.h](https://github.com/RunZeJustin/qnx660/blob/47c4158e3993d7536170b649e6c1e09552318fb4/target/qnx6/usr/include/fs/f3s_spec.h#L114-L129)
(lines 114 to 129, line 94 for the boot index, 189 for the endian byte and 214 for
`unit_index`). The header's one-line comments are
all it says about what a deleted or superseded extent means. What such an extent still
holds was measured, as "QNX EFS in a raw flash image" above describes.

Btrfs, from btrfs-progs at v6.17.1 (commit `06981428c08f78f019a2f4956407fd84b495e21e`),
and the kernel's `fs/btrfs` at v7.0 (commit `028ef9c96e96197026887c0f092424679298aae8`)
where only the kernel settles a rule. The full list, with lines, is in the comment above
`BtrfsWalker`; the main ones:

```
struct btrfs_super_block, BTRFS_MAGIC   kernel-shared/uapi/btrfs_tree.h:668-726, 14
superblock at 64 KiB, mirrors           kernel-shared/ctree.h:72-73, disk-io.h:148-156
checksum types and sizes                btrfs_tree.h:381-384, kernel-shared/ctree.c:49-55
how each checksum is computed           crypto/hash.c:32-81, kernel-shared/disk-io.c:165-216
header, item, key pointer               btrfs_tree.h:482-497, 549-580
chunk item, stripe, profile bits        btrfs_tree.h:629-663, 1154-1185
logical to physical                     kernel-shared/volumes.c:2093-2313, 2577-2666
root, inode, dir and ref items          btrfs_tree.h:853-982
file extent item, compression types     btrfs_tree.h:1063-1119, kernel-shared/compression.h:108-111
reading a file's extents                cmds/restore.c:292-471, 617-760
LZO framing in an extent                linux fs/btrfs/lzo.c:24-59, 429-546
zlib with or without its header         linux fs/btrfs/zlib.c:351-384
subvolume link needs a ROOT_REF         linux fs/btrfs/inode.c:5811-5875, 6008-6040, 6096-6102
superblock copy chosen                  kernel-shared/disk-io.c:1933-2017
tree block and item checks              linux fs/btrfs/tree-checker.c:207-341, 1126-1215,
                                          2018-2234, 2302-2355
compressed extent bounds, 128 KiB       linux fs/btrfs/compression.h:34-40
largest file                            linux fs/btrfs/super.c:963 (MAX_LFS_FILESIZE)
```

SquashFS, JFFS2, UBI and UBIFS, from the Linux kernel at v7.0 (commit
`028ef9c96e96197026887c0f092424679298aae8`):

```
SQUASHFS_MAGIC  0x73717368 ("hsqs")     include/uapi/linux/magic.h:20
struct squashfs_super_block             fs/squashfs/squashfs_fs.h:241
inode, directory, fragment layouts      fs/squashfs/squashfs_fs.h:270-424
metadata block 8 KiB, bit 15 stored     fs/squashfs/squashfs_fs.h:19,106
data block, bit 24 stored               fs/squashfs/squashfs_fs.h:113
JFFS2_MAGIC_BITMASK 0x1985, old 0x1984  include/uapi/linux/jffs2.h:24-25
JFFS2 compressor ids                    include/uapi/linux/jffs2.h:41-48
struct jffs2_unknown_node, raw_dirent,  include/uapi/linux/jffs2.h:102,111,135
  raw_inode
UBI_EC_HDR_MAGIC "UBI#", VID "UBI!"     drivers/mtd/ubi/ubi-media.h:29,31
struct ubi_ec_hdr, ubi_vid_hdr          drivers/mtd/ubi/ubi-media.h:147,268
UBI_CRC32_INIT 0xFFFFFFFF               drivers/mtd/ubi/ubi-media.h:26
layout volume 0x7FFFEFFF                drivers/mtd/ubi/ubi-media.h:294,298
struct ubi_vtbl_record (172 bytes)      drivers/mtd/ubi/ubi-media.h:355
UBIFS_NODE_MAGIC 0x06101831             fs/ubifs/ubifs-media.h:25
superblock, master and log LEBs         fs/ubifs/ubifs-media.h:227-231
key: block or hash bits 29              fs/ubifs/ubifs-media.h:199
```

How each reader chooses among versions and copies is taken from the code that makes the
choice, and cited beside the Python that follows it: `fs/jffs2/readinode.c`
(`check_node_data`, `read_direntry`, `jffs2_do_read_inode_internal`) for JFFS2,
`drivers/mtd/ubi/attach.c` (`ubi_compare_lebs`) for UBI, and `fs/ubifs/replay.c`
(`apply_replay_entry`, `inode_still_linked`, `trun_remove_range`) for the UBIFS journal.

LZO and LZ4 are not in the standard library, so both are carried as pure-Python decoders.
LZO1X is written from the kernel's `Documentation/staging/lzo.rst` and
`lib/lzo/lzo1x_decompress_safe.c` at the same commit, and LZ4 from
`doc/lz4_Block_format.md` in lz4 at v1.10.0 (commit
`ebb370ca83af193212df4dcbadcc5d87bc0de2f0`). Every fixture compressed with them reads back
byte for byte, and each source tree carries a file shaped to reach the decoders' rarer
instructions. LZO-RLE, the second LZO bitstream, which zram writes and none of these
filesystems does, is refused rather than decoded. The kernel does not read SquashFS's
legacy lzma format, so that one follows squashfs-tools' own `lzma_xz_wrapper.c` at commit
`708c59ae80853b0845017c33b42e56061cc546cd`. Mainline Linux has no JFFS2 LZMA either, so
compression 8 follows the OpenWrt patch that adds it,
`target/linux/generic/pending-6.12/530-jffs2_make_lzma_available.patch` at OpenWrt commit
`d9f8ecc394dd30537d7136963fa4f6891b59c1ee` (the id at line 1094, the decoder at lines 200
to 214, the properties at 229 to 237 and 342 to 348), and its fixture is written by the
matching `tools/mtd-utils/patches/130-lzma_jffs2.patch` on mtd-utils 2.3.1.

YAFFS1 and YAFFS2, from Aleph One's
[yaffs2](https://github.com/Aleph-One-Ltd/yaffs2) at commit
`474b3acb927d27b2305618aaf24456b9d33fe91b`. The object header's field offsets were printed
with `offsetof()` from that tree's own headers rather than counted by hand:

```
object ids: root 1 .. summary 0x10      core/yaffs_guts.h:94-100
sequence numbers 0x1000..0xefffff00     core/yaffs_guts.h:123-124
struct yaffs_spare (YAFFS1 tags)        core/yaffs_guts.h:225
struct yaffs_obj_hdr (512 bytes)        core/yaffs_guts.h:330
YAFFS2 packed tags and their ECC        core/yaffs_packedtags2.c
YAFFS2 scan                             core/yaffs_yaffs2.c yaffs2_scan_chunk
YAFFS1 tags and deletion                core/yaffs_tagscompat.c, core/yaffs_yaffs1.c
root and lost+found modes 0755, 0700    direct/ydirectenv.h:99-100
```

BitLocker, from Joachim Metz's
[BitLocker Drive Encryption (BDE) format specification](https://github.com/libyal/libbde/blob/96e3c5dce6143c2702c90f3903018fb8c12a8956/documentation/BitLocker%20Drive%20Encryption%20(BDE)%20format.asciidoc)
in libyal/libbde at commit `96e3c5dce6143c2702c90f3903018fb8c12a8956`, and for how a
sector is read back, libbde's own code at the same commit:

```
volume header, FVE metadata blocks and entries   the format document
recovery password and user key stretching        sections "Recovery key", "User key"
AES-CBC IV, AES-XTS tweak                        sections "AES-CBC", "AES-XTS"
moved first sectors, zeroed metadata, the
encrypted size, unencrypted ranges               libbde/libbde_sector_data.c:274-420
Encrypt-on-Write map                             libbde/libbde_volume.c:1668
bytes per sector from the moved header           libbde/libbde_volume.c:1497-1506
```

NTFS reparse points, cloud placeholders and overlay compression, from Microsoft:

```
reparse tags (IO_REPARSE_TAG_WOF, _CLOUD to _CLOUD_F)   [MS-FSCC] 2.1.2.1
file attributes (SPARSE_FILE, OFFLINE,
RECALL_ON_DATA_ACCESS)                                  [MS-FSCC] 2.6
overlay reparse data: version, provider, then the
file provider's version and algorithm                   WOF_EXTERNAL_INFO,
                                                        FILE_PROVIDER_EXTERNAL_INFO_V1
XPRESS chunk sizes, LZX's 32 KB                         WOF_FILE_COMPRESSION_INFO_V1
LZ77+Huffman block: 256 bytes of code lengths for
512 symbols, then the symbols                           [MS-XCA] 2.1
```

The algorithm numbers, the chunk table of the `WofCompressedData` stream and the order
of the decoder's reads are checked against files Windows wrote and Windows's own hashes
of them (the self-test), and `SF_DATALESS` is from macOS's `sys/stat.h`.

ReFS, from xbqt/forefst at `d4d5fd28942eb14ebe11d90f4eb9342f5e3d7b92` (`docs/`), libyal/libfsrefs
at `77e1b7ba68cf225ec888a61e9784fb9a93a0156f` (`documentation/`) and Microsoft:

```
boot sector: "ReFS" at 3, "FSRS" at 0x10, sectors 0x18,
bytes/sector 0x20, sectors/cluster 0x24, version 0x28/0x29   libfsrefs "The volume header",
                                                             forefst structures/vbr.md
superblock at cluster 30, checkpoint list at 0x70,
self checksum over one cluster, descriptor zeroed            forefst structures/supb.md
checkpoint clock 0x60, log position 0x70, flags 0x78,
roots at 0x94 or through it when flag 0x200 is set           forefst structures/chkp.md
page reference: four cluster slots, checksum kind 0x22,
digest offset 0x23, length 0x24                              libfsrefs "Metadata block reference",
                                                             forefst structures/page_references.md
node header (level 0x0C, key index 0x10 to 0x20, count 0x14)
and row (size, key, flags, value)                            libfsrefs "Node header", "Node record",
                                                             forefst structures/btree_node.md
container table: clusters per container 0x18, first
cluster 16 bytes before the value's end                      forefst structures/container_table.md
virtual cluster: container is the number shifted by the
bit length of the clusters per container                     forefst concepts/virtual_addressing.md
object table key, page reference at value 0x20               forefst structures/object_table.md
name rows (0x30, key flag 1 or 2), split records (0x40),
record times 0x28 to 0x40, attributes 0x48, size 0x58        forefst structures/directory_entries.md
$DATA sizes 0x30 to 0x48, 24-byte extent records, maps in
child pages, unwritten and hole runs read as zeros           forefst structures/extent_descriptors.md
live stream read through its snapshots, newest first         forefst concepts/snapshots_versioning.md
a file's times from its record, not a name row               forefst concepts/hard_links.md
a directory's change time from its name row                  forefst attributes/STANDARD_INFORMATION.md
named streams (0xB0), inline content, extents tied by size   forefst attributes/NAMED_DATA.md
CRC-64/NVME, CRC32-C, the CRC64 sentinel                     forefst concepts/checksum_architecture.md
log control page, record position and check value           forefst structures/mlog.md
volume label, object 0x500 row 0x510                         forefst structures/volume_info.md
symbolic link and mount point data                           [MS-FSCC] 2.1.2.4, 2.1.2.5
```

Measured on the volumes and not taken from either description: the log's control pages as
the fourth and fifth u64 of row 1 of the logfile information table (object 0x9; they are
where forefst's own report finds them, and 0x30 and 0x31 on four of the six volumes), a
record's id within its directory at 0x80 (it equals the low half of the file id Windows
reports, for every file), a directory's other three times in its own record, and the link
count as the number of names a record lists.

Linux md RAID and LVM RAID, from the Linux kernel at v7.0 (commit
`028ef9c96e96197026887c0f092424679298aae8`), mdadm at mdadm-4.5 (commit
`8f0c7692d48414ff7b3fe927ce75799c65ef24b1`) and lvm2 at v2_03_43 (commit
`7b0bce6909611966bdc1e17c2408e1ec3b0f8c17`):

```
MD_SB_MAGIC 0xa92b4efc, roles, feature bits     include/uapi/linux/raid/md_p.h 95-109, 306-343
0.90 superblock, host byte order, last 64 KiB   md_p.h 44-47, 131-209; md.c 1054-1058
0.90 checksum, folded                           md.c 1249-1281
1.x superblock, little-endian                   md_p.h 225-304
1.0 at the end, 1.1 at 0, 1.2 at 4 KiB          md.c 1814-1826 (super_1_load)
1.x checksum                                    md.c 1774-1794
events: one behind is used, more is refused     md.c 1550-1554, 2087, 2111-2133
RAID0 without the layout bit has no layout      md.c 1519-1520, 2060-2061
linear                                          md-linear.c 113-150
RAID0 zones, original and alternate layouts     raid0.c 65-298, 304-352, 560-590
RAID10 near/far/offset                          raid10.c 581-642, 3712-3815
RAID4/5/6 parity and data placement             raid5.c 2946-3149
RAID6 Q slot order                              raid5.c 124-161, 1603-1640
array sizes                                     raid5.c 7309-7321, raid10.c 3712-3730,
                                                md-linear.c, raid0.c 357-370
write journal walk and checksum                 raid5-cache.c 1722-1752, 1800-1846,
                                                2061-2246, 2941-3000, 3079
GF(2^8) over 0x11d, exp/inv/exi tables          lib/raid6/mktables.c 21-34, 108-171
two data, or data and P, from P and Q           lib/raid6/recov.c 19-89
several superblocks: the newest ctime           mdadm util.c 1259-1300
DDF anchor 0xDE11DE11 in the last sector        mdadm super-ddf.c 145, 977-1000
DDF header, vd_config prl, RAID level codes      mdadm super-ddf.c 107-118, 160-221, 334-372,
                                                815-880, 1058-1080, 1240-1290, 1484-1496
DDF secondary level, RAID10 as RAID1 spanned    mdadm super-ddf.c 138-142, 665-678
DDF header choice (primary or secondary)        mdadm super-ddf.c 1079-1091
DDF disk and virtual disk states                mdadm super-ddf.c 232-316, 404-413, 1100-1123,
                                                1235-1239, 2620
DDF CRC: crc field as 0xffffffff, CRC-32 table  mdadm super-ddf.c 571-585, crc32.c
step from 0, no inversion
IMSM metadata, checksum, volume level, map      mdadm super-intel.c 38, 146-307, 441-445,
state                                           888-905, 941-952, 1354-1363, 4577-4685
IMSM "Intel Raid ISM Cfg Sig. " 2 sectors back  mdadm super-intel.c 38, 4594 (512 and
                                                4096-byte sectors)
lvm2 RAID segment keys, raids list              lvm2 lib/raid/raid.c 45-190, 202-224
                                                (2.03.31: 45-185, 197-229)
"raid5" is raid5_ls, "raid6" is raid6_zr        lvm2 libdm/libdm-deptree.c 92-109
                                                (2.03.31: 86-103)
MISSING, NOTSYNCED, REBUILD                     lvm2 lib/format_text/flags.c 50-51, 65-66
                                                (the same lines in 2.03.31)
dm-raid superblock: failed devices, in sync     dm-raid.c 1953-1975
bad block log                                   md.c 1890-1920, 1180-1181; md.h 300-312
dm-raid types to md level and layout            dm-raid.c 294-313
LDM, Storage Spaces, Apple RAID GPT types       util-linux v2.41.6 (commit
                                                02822c9374fc72d38baf8a1f859eb0813970bf3f)
                                                include/pt-gpt-partnames.h 37-41, 193-194;
                                                Microsoft PARTITION_INFORMATION_GPT
```

`--help` prints this same sourcing, so it travels with the tool. (The ReFS and RAID lines
above are in this README only for now.)

## What it does not do

- **It reads raw images and the acquisitions `ewfprobe.py` reads only.** A raw image
  is one file or the numbered segments of one, and an E01, s01, Ex01, AFF, AFD, AFF4,
  `.dmg` (split into `.dmgpart` files or not), `.sparseimage` or `.sparsebundle`,
  (since 1.46) a VHD, VHDX, VMDK or QCOW virtual disk, and (since 1.47) an AFM or an
  encrypted AFF, is read
  through `ewfprobe.py` (see "EnCase/EWF and AFF acquisitions" above). L01, Lx01 and
  (since 1.45) AD1 logical evidence is refused, since it holds no disk. Other evidence containers
  are not decoded; such a file is read as plain raw bytes, so export the raw image
  from the imaging tool first. A segment set is joined only when it is whole from its first
  segment (see "Split images" above). A lone first segment is read as the file it is,
  and since 1.12 a run on it says `IMAGE IS SHORTER THAN ITS PARTITION TABLE`, names
  the partitions that reach past the end, marks each affected volume `INCOMPLETE` in
  the report and in `volumes.json` (`extends_past_image_by_bytes`), and stores a file
  whose blocks lie past the cut under a name ending `.SHORT-<here>-of-<size>-bytes`,
  counted as `short` rather than as extracted.
- **A 4096-byte-sector disk is recognised by its GPT.** A 4Kn disk that carries only
  a legacy MBR states its sector size nowhere, so its LBAs are read as 512-byte
  sectors. Sector sizes other than 512 and 4096 are not probed. A GPT header that fails
  a check is reported and not used, and nothing is ever written back to restore one.
- **Some IFS compression is recognised but not read.** UCL, zlib and uncompressed
  QNX IFS boot images are listed and extracted; `lzo`-compressed images and the Harman
  Becker HBCIFS container are recognised and reported but not decompressed, because no
  sample exists to validate a reader against. A big-endian IFS is declined the same way.
  In each case the header is still reported and the walk is declined out loud.
- **It decrypts BitLocker and APFS volume encryption, not per-file encryption.** An
  encrypted Apple disk image or an AD-encrypted acquisition opens with its password, a
  BitLocker volume with its key, and an APFS volume macOS encrypted in software with its
  password or personal recovery key (above). An APFS volume with per-file keys, one that
  was mid-way through being encrypted, an NTFS file encrypted on its own, and a volume
  with encrypted filenames are flagged, not opened; an APFS volume the image holds
  decrypted is read (see APFS above). A BitLocker volume with the Elephant diffuser, in the Windows Vista layout, or
  protected only by a TPM is named and not read.
  On F2FS, a real Android `/data` uses per-file encryption: such a file is listed and
  its content refused rather than guessed at.
- **LVM2: linear, striped, RAID1, mirror and RAID4/5/6/10 logical volumes are read.** A
  RAID0 volume, a thin, cache, VDO or snapshot volume, or one with a run on a physical
  volume missing from the images given, is named in the report with why and not read (see
  "LVM2" above).
- **RAID: Linux md and LVM RAID only.** Arrays are assembled from the member images given
  together; a degraded parity array is rebuilt only when it was stopped clean, and an
  array mid-reshape is refused. DDF and Intel IMSM (RST) arrays are not assembled: a
  member is walked on its own only when its metadata, read and checked, records RAID1, and
  otherwise is named with the level and not walked. Windows LDM and Storage Spaces, and
  Apple RAID members are named and not read (see "RAID" above).
- **LUKS: AES only, and only what a passphrase opens.** A LUKS container with another
  cipher, with dm-integrity, with a keyslot that is not of the luks2 type, or being
  re-encrypted is named and not read (see "LUKS" above). A detached LUKS2 header is not
  read: the data it describes carries no header to find. A LUKS container inside a
  logical volume read through a map is not opened, and its note says so.
- **Overlay compression with LZX is recognised but not read.** A file compressed with
  `compact /exe:lzx` is listed with its recorded size and refused by name; the three
  XPRESS forms are decoded. A cloud provider's online-only placeholder holds no content
  on the volume and is refused too, rather than written out as zeros.
- **ReFS: the newest checkpoint, without the log.** Changes still only in the metadata
  log are counted and reported, not applied; deleted files and free space are not read; ReFS
  1.x and 2.x are identified and refused. See [ReFS](#refs).
- **F2FS compression is recognised but not read.** A file compressed with F2FS's LZ4,
  LZO or zstd clusters is listed with its recorded size and not decompressed.
- **F2FS is validated against synthetic fixtures, not yet against a real F2FS volume.**
  Two independent readers are the oracles: f2fs-tools' `dump.f2fs` for inline data,
  directories, the inode's own pointers and direct and single-indirect node blocks, and
  the Linux kernel driver itself for files full of holes. No real F2FS volume is in the
  test corpus, so the NAT-journal override is implemented and sourced but not exercised (a
  cleanly unmounted image has an empty journal), and the double-indirect path (past about
  8 GiB in one file) is not exercised at all.
- **It does not write.** The image is opened read-only. The Linux qnx6 driver has no
  write path at all, so mounting a qnx6 volume on Linux cannot alter these timestamps
  either.
- **QNX4 is validated against a synthetic fixture, not yet against a real QNX4
  volume.** The round-trip oracle is the Linux kernel's own `fs/qnx4` driver, an
  independent implementation, but no confirmed real QNX4 volume exists in the
  test corpus; the one candidate partition (a Ford Sync G4 slot named
  `boot_fs`) turned out to carry a `RAW0` container, not QNX4.
- **ETFS is validated against qnxmount's synthetic test images, not yet against a real
  vehicle extraction.** No confirmed ETFS volume was available to test on. EFS has been
  measured on six vehicle flash images since 1.60 (see "QNX EFS in a raw flash image").
  ETFS keeps its transaction metadata in the NAND spare/out-of-band
  area, so an ETFS volume is only readable if the acquisition captured that spare area;
  an image that dropped it will not divide into pages and will be reported as not
  recognised rather than misread.
- **SquashFS and JFFS2 have not been run against flash from a real device.** Their images
  were written by the formats' own tools and, for JFFS2's history, by the Linux kernel's
  driver on the kernel's simulated NAND chip (`nandsim`) rather than on hardware. YAFFS2
  and UBIFS have been: an Android phone under
  [YAFFS1 and YAFFS2](#yaffs1-and-yaffs2), and that phone and a Foscam R2 camera under
  [Deleted files on YAFFS2, JFFS2 and UBIFS](#deleted-files-on-yaffs2-jffs2-and-ubifs).
  The older copies in the UBI fixture were put there from an earlier dump rather than left
  by a real power cut, and UBI's fallback to an older copy when a moved block's data CRC
  fails is implemented and sourced but not exercised. YAFFS2's skipping of block summary
  chunks is exercised (the YAFFS2 history image holds 24) but decides nothing there: those
  chunks reach no listing either way.
- **Btrfs: one device, committed state, metadata checksums.** Striped chunks (RAID0,
  RAID10, RAID5, RAID6) are refused by name, and on one device of several only what has a
  copy there is read. A log tree is not replayed. Encrypted or otherwise encoded extents
  (the format says a reader that does not understand them must treat them as incompatible)
  and extent tree v2 are refused.
  Tree blocks are checked against their checksums; file data is not checked against the
  checksum tree, so a changed data block reads back changed. Deleted files are not listed
  (the space they held is reported free), extended attributes are not reported, and zstd
  needs Python 3.14. An inode size is refused only past the largest file Btrfs allows
  (2^63 - 1 bytes); a size below that and far past the data is read as the hole it is.
  This reader has been run only on the fixtures named under Btrfs above, none of them
  from a real device.
- **Some flash compression is recognised but not read.** zstd needs Python 3.14 or later
  (`compression.zstd`). On an older Python a zstd SquashFS is identified but cannot be
  listed, since its directory tables are compressed too; since 1.34 `volumes()` carries
  the reason as the volume's note, so the report, the window and a LEAPP run log say why
  it lists nothing. In UBIFS each file whose data
  is zstd-compressed is named and refused. The executables published with v1.31 and v1.32
  were built on Python 3.12 and so do not read zstd; later ones are built on 3.14 and do.
  JFFS2's rubin, dynrubin and copy compressors are reported and not read, and LZO-RLE is
  refused.
- **Older and unusual flash layouts are not walked.** SquashFS 1.x to 3.x (and its
  big-endian `sqsh` form) and JFFS2's original 0x1984 layout are recognised and reported.
  YAFFS2 with inband tags (kept inside the page, on NAND with no usable spare) is not
  recognised at all.
- **Older versions of live files on flash are not listed.** Each flash reader returns the
  filesystem's current state, the way the filesystem itself reads it, and deleted files
  come from `recover_deleted()` (above). The earlier contents of a file that still exists
  (JFFS2's superseded nodes, YAFFS's superseded pages, UBIFS's older data nodes, UBI's old
  copies of a block) are not returned, and neither is deleted YAFFS1 data. EFS is the
  exception: its `recover_deleted()` lists superseded extents too.
- **Encrypted and authenticated UBIFS.** Encryption is not undone: a file fscrypt marks as
  encrypted has its content refused rather than returned, and encrypted names are not
  decrypted. The hashes of an authenticated volume are not checked. Neither case is in the
  fixtures. Extended attributes are not reported on any of the flash filesystems.
- **A raw flash dump is searched only for SquashFS, UBI and JFFS2**, only when it has no
  partition table and nothing is recognised at offset 0, and only up to 8 GiB. Its spare
  bytes are stripped only for UBI and JFFS2, and only for the common page and spare sizes.
  NAND dumps with spare bytes were tested as dumps of one partition each; a filesystem
  that starts further into such a dump has not been tested.

## License

MIT. See [LICENSE](LICENSE).

Two test fixtures, `tests/fixtures/efs-qnx.img.gz` and `tests/fixtures/efs-qnx.tar.gz`, are
from [NetherlandsForensicInstitute/qnxmount](https://github.com/NetherlandsForensicInstitute/qnxmount)
and stay under its Apache-2.0 licence. See [LICENSE-qnxmount](LICENSE-qnxmount).
