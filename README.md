# qnxprobe

Read QNX6, QNX4, ETFS, EFS, ext2/3/4, FAT32 and exFAT filesystems, and QNX IFS
boot images, out of raw disk images: identify each by its own on-disk structure
rather than trusting a partition type byte, list, and extract to a zip with a
provenance manifest. No mounting, no admin rights, standard library only.

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
records in each page's spare area; EFS is found by its `QSSL_F3S` boot record.
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

One file, Python 3 standard library only. Nothing to install, no admin rights, and
it never writes to the image. A second, optional file, `qnxprobe_gui.py`, puts a
window over it (see [The window](#the-window)); it is standard library too.

## Requirements

Python 3, and nothing else. No packages, no install step.

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
special entries; only regular files can be saved.

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
executables with PyInstaller, `qnxprobe` for the command line and `qnxprobe_gui`
for the window, on six targets: Windows x64 and arm64, macOS on Apple silicon and
Intel, and Linux x64 and arm64. Each build runs the self-test, the discovery check
and a window liveness check on its own runner before it is packaged with
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
label is only ever a suffix.

The zip also carries `volumes.json`: per volume, the LBA, byte offset, partition
size, filesystem type, the recorded volume id or UUID, and what was extracted,
including `short` (files whose blocks reach past the end of the image) and, on a
volume that does, `extends_past_image_by_bytes`.
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
```

`--list` walks qnx6 through the same block resolution the kernel uses in
`qnx6_block_map()`, including multi-level indirect trees and long filenames held out
of line in the Longfile tree, and walks ext through its extent trees. Both read-only.

The zip `--extract` produces is what a LEAPP tool ingests, so this replaces the mount
and the manual zip in one step. `--exclude` is repeatable.

## Options

| Option | What it does |
| --- | --- |
| `--list` | Walk each filesystem found and list its contents (qnx6, qnx4, ext2/3/4, FAT32, exFAT, ETFS, EFS and QNX IFS boot images) |
| `--depth N` | How deep to walk with `--list` (default 2) |
| `--list-max N` | Stop after this many entries per filesystem (default 400) |
| `--extract OUT.zip` | Copy the logical files out of every filesystem into a zip |
| `--only TEXT` | Restrict `--list` and `--extract` to partitions whose name or label contains TEXT |
| `--exclude TEXT` | Skip any path containing TEXT when extracting. Repeatable |
| `--triage` | Rank volumes by how much each has been written, and flag encrypted or bulk ones |
| `--scan-limit MiB` | How far to brute scan when no superblock sits at the offsets the kernel checks (default 256) |
| `--self-test` | Build throwaway positive and negative images, confirm the detector reports both ways, then delete them |
| `--version` | Print the version |

## The self-test, and why it is not decoration

Run it once before you trust a negative result on real evidence.

```
python3 qnxprobe.py --self-test
```

It builds throwaway images in a temp directory, some that must be detected and one
that must not, across qnx6 (both endians), FAT32, exFAT, ETFS, EFS and QNX IFS,
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

`--help` prints this same sourcing, so it travels with the tool.

## What it does not do

- **It does not join a split image.** FTK Imager and its peers write a raw image as
  numbered segments (`.001`, `.002`, ...) unless told otherwise, and the first segment
  alone carries the partition table and the boot volumes, so it identifies cleanly and
  its front volumes read correctly while the volume holding the user data ends past the
  cut, where every read answers empty. Measured on a Ford Sync G4 image cut at 1,500 MB:
  every boot partition extracted in full and the 28.8 GiB storage volume walked to 0
  files with nothing raised. Since 1.12 a run on such a file says
  `IMAGE IS SHORTER THAN ITS PARTITION TABLE`, names the partitions that reach past the
  end, marks each affected volume `INCOMPLETE` in the report and in `volumes.json`
  (`extends_past_image_by_bytes`), and stores a file whose blocks lie past the cut under
  a name ending `.SHORT-<here>-of-<size>-bytes`, counted as `short` rather than as
  extracted. Join the segments first (`cat`, `copy /b`, or the imaging tool's own export)
  and read the joined file.
- **Some IFS compression is recognised but not read.** UCL, zlib and uncompressed
  QNX IFS boot images are listed and extracted; `lzo`-compressed images and the Harman
  Becker HBCIFS container are recognised and reported but not decompressed, because no
  sample exists to validate a reader against. A big-endian IFS is declined the same way.
  In each case the header is still reported and the walk is declined out loud.
- **It does not decrypt.** A volume with encrypted filenames is flagged, not opened.
- **It does not write.** The image is opened read-only. The Linux qnx6 driver has no
  write path at all, so mounting a qnx6 volume on Linux cannot alter these timestamps
  either.
- **QNX4 is validated against a synthetic fixture, not yet against a real QNX4
  volume.** The round-trip oracle is the Linux kernel's own `fs/qnx4` driver, an
  independent implementation, but no confirmed real QNX4 volume exists in the
  test corpus; the one candidate partition (a Ford Sync G4 slot named
  `boot_fs`) turned out to carry a `RAW0` container, not QNX4.
- **ETFS and EFS are validated against qnxmount's synthetic test images, not yet
  against a real vehicle extraction.** No confirmed ETFS or EFS volume was available to
  test on. ETFS in particular keeps its transaction metadata in the NAND spare/out-of-band
  area, so an ETFS volume is only readable if the acquisition captured that spare area;
  an image that dropped it will not divide into pages and will be reported as not
  recognised rather than misread.

## License

MIT. See [LICENSE](LICENSE).
