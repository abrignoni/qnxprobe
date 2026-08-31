# qnxprobe

Read QNX6 and ext2/3/4 filesystems out of raw disk images: identify by superblock rather than trusting a partition type byte, list, and extract to a zip with a provenance manifest. No mounting, no admin rights, standard library only.

QNX is what a lot of vehicle infotainment runs on, and it is the reason this tool
exists and keeps its name. When a head unit image lands on your desk, the first
question is what filesystems are in it, and the usual tools do not answer it:
`blkid`, `file` and The Sleuth Kit have no QNX6 support, and the partition table
will happily call a qnx6 volume `0x83 Linux`. This reads the superblock and tells
you what is actually there, then lists and extracts what it found. It reads
ext2/3/4 the same way, so a mixed vehicle landscape (Ford runs QNX, BMW runs
Linux) is one tool rather than two.

One file, Python 3 standard library only. Nothing to install, no admin rights, and
it never writes to the image.

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
size, filesystem type, the recorded volume id or UUID, and what was extracted.
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
| `--list` | Walk each filesystem found and list its contents (qnx6 and ext2/3/4) |
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

It builds three throwaway images in a temp directory, two that must be detected and
one that must not, checks all three, and removes the directory.

The expected values in it are written as literal bytes rather than derived from the
constant they verify. That matters: an earlier version built its fixtures from
`QNX6_MAGIC`, and it passed with the magic deliberately corrupted to `0x68191123`,
which is a build that cannot identify a single real filesystem. A test whose fixture
moves with the bug is not a test.

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

QNX IFS boot images:

```
STARTUP_HDR_SIGNATURE  0x00ff7eeb   qnx sys/startup.h:88
STARTUP_HDR_VERSION             1   qnx sys/startup.h:89
struct startup_header               qnx sys/startup.h
```

Those field widths sum to 256 bytes, which each image's own `header_size` field
confirms. The `machine` field is an ELF machine type, reported through `EM_386` 3,
`EM_ARM` 40, `EM_X86_64` 62 and `EM_AARCH64` 183 from
`linux/include/uapi/linux/elf-em.h`.

`--help` prints this same sourcing, so it travels with the tool.

## What it does not do

- **IFS contents are not listed.** The IFS directory format is not sourced here, and
  on every image tested the filesystem is stored compressed, so listing it would mean
  guessing a layout. The header is reported and nothing is invented.
- **It does not decrypt.** A volume with encrypted filenames is flagged, not opened.
- **It does not write.** The image is opened read-only. The Linux qnx6 driver has no
  write path at all, so mounting a qnx6 volume on Linux cannot alter these timestamps
  either.
- **QNX4 is recognised only as an MBR partition type**, from util-linux's
  `pt-mbr-partnames.h`. There is no QNX4 filesystem parser here.

## License

MIT. See [LICENSE](LICENSE).
