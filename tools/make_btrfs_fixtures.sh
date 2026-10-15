#!/usr/bin/env bash
# Build tests/fixtures/btrfs-*.img.gz and the lists the self-test checks them
# against.
#
# Runs on Linux with btrfs-progs installed (written against 6.17.1) and
# e2fsprogs. No root and no mount: mkfs.btrfs --rootdir fills each image from
# one source tree. The tree is packed once per compression mkfs.btrfs offers
# (none, zlib, zstd, lzo) and once more for each other checksum type (xxhash,
# sha256, blake2), so every decompressor and every checksum is exercised by the
# same files. Two more images: an ext4 volume converted by btrfs-convert, and
# the second device of a two-device RAID1 volume.
#
# Two oracles, both independent of the reader under test:
#
#   btrfs.src.sha256   sha256sum over the source tree, one line per regular
#                      file. mkfs.btrfs stores file bytes exactly, so the
#                      source is the truth for every image.
#
#   btrfs.src.json     every entry of the source tree from lstat(): path,
#                      type, mode (type and permission bits), size, mtime
#                      (seconds and nanoseconds), symlink target, and the inode
#                      number and link count, so hard links can be grouped.
#
# Before anything is written, every image is read back with
# "btrfs restore" (btrfs-progs' own offline reader, no mount) and its files
# hashed against the source list, and "btrfs check" must pass, so a fixture
# btrfs-progs itself cannot read never reaches the repository.
#
# The tree is chosen for its shapes: files small enough to be stored inline in
# the metadata, files of several 128 KiB extents (compressible text, and
# random bytes compression leaves alone), a file written with a 1 MiB gap, an
# empty file, an empty directory and a deep one, a directory of 400 entries
# (its items span several leaves, so the tree has interior nodes), a 255-byte
# name, names in several scripts, symlinks (relative, absolute, dangling,
# long), hard links in one directory and across directories, 150 hard links
# with long names to one file in one directory (more than one inode ref item
# holds, so the rest are stored as extended refs), a FIFO, an extended
# attribute, and a directory made a subvolume with --subvol.
#
# mkfs.btrfs --rootdir writes a gap in a source file as zeros, not as a hole
# (measured with 6.17.1), so holes come from the converted image here, and
# snapshots, deleted files, preallocated extents and a log tree from
# tools/make_btrfs_root_fixtures.sh, which needs root.
set -euo pipefail

out=${1:-$(cd "$(dirname "$0")/.." && pwd)/tests/fixtures}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
src=$work/src
mkdir -p "$src/dir/sub/deeper/deepest" "$src/empty_dir" "$src/many" "$src/links" "$src/subvol/inner"

python3 - "$src" <<'PY'
import os, random, sys
root = sys.argv[1]
rnd = random.Random(20261015)
def blob(n): return bytes(rnd.getrandbits(8) for _ in range(n))
def text(n, tag):
    line = (tag + " btrfs fixture line, compressible on purpose\n").encode()
    return (line * (n // len(line) + 1))[:n]
def put(rel, data):
    with open(os.path.join(root, rel), "wb") as f:
        f.write(data)
put("tiny.txt", b"inline\n")
put("empty.bin", b"")
put("small_2000.txt", text(2000, "two thousand"))
put("small_3000.txt", text(3000, "three thousand"))
put("exact_4096.bin", blob(4096))
put("text_700k.txt", text(700 * 1024 + 123, "seven hundred"))
put("random_100k.bin", blob(100 * 1024 + 7))
# Mixed: compressible and random runs alternate inside one file.
put("dir/mixed.bin", b"".join(text(50000, "m%d" % i) + blob(3000) for i in range(6)))
put("dir/sub/deeper/deepest/deep.txt", b"deep file\n")
# Shapes an LZ compressor encodes with its rarer instructions.
a = blob(2000)
shapes = bytearray(a + text(18000, "filler") + a)
for i in range(12000):
    shapes.append(shapes[-2500] if i % 40 < 3 and i >= 2500 else rnd.getrandbits(8))
put("dir/lz_shapes.bin", bytes(shapes))
# Holes: data, a 1 MiB gap, data, then a hole to the end.
with open(os.path.join(root, "dir/holes.bin"), "wb") as f:
    f.write(text(8192, "head"))
    f.seek(1 << 20, 1)
    f.write(text(5000, "middle"))
    f.truncate(3 << 20)
for i in range(400):
    put(f"many/entry_{i:04d}_with_a_longer_name.txt", b"m%04d\n" % i)
put("L" * 251 + ".txt", b"a name 255 bytes long\n")
for name in ("café résumé.txt", "Ελληνικά.txt", "日本語のファイル.txt", "emoji_\U0001F600.txt"):
    put(name, ("named " + name + "\n").encode("utf-8"))
os.symlink("dir/mixed.bin", os.path.join(root, "link_rel"))
os.symlink("/etc/hostname", os.path.join(root, "link_abs"))
os.symlink("does/not/exist", os.path.join(root, "link_dangling"))
os.symlink("t" * 300 + "/target", os.path.join(root, "link_long"))
put("links/original.txt", b"one inode, many names\n")
os.link(os.path.join(root, "links/original.txt"), os.path.join(root, "links/second_name.txt"))
os.link(os.path.join(root, "links/original.txt"), os.path.join(root, "dir/third_name.txt"))
put("links/many_target.txt", b"a file with 150 names\n")
for i in range(150):
    os.link(os.path.join(root, "links/many_target.txt"),
            os.path.join(root, "links", f"hard_{i:03d}_" + "h" * 180))
os.mkfifo(os.path.join(root, "a_fifo"))
put("subvol/in_subvol.txt", b"inside a subvolume\n")
put("subvol/inner/nested.txt", text(9000, "nested"))
os.setxattr(os.path.join(root, "tiny.txt"), "user.note", b"an extended attribute")
PY

# Fixed times, so the listing oracle is reproducible: one for everything, one
# with nanoseconds for a single file. mkfs.btrfs --rootdir keeps the seconds
# and writes 0 nanoseconds (mkfs/rootdir.c:288-295), which the self-test checks.
find "$src" -exec touch -h -d '2024-05-06 07:08:09 UTC' {} +
touch -d '2023-01-02 03:04:05.123456789 UTC' "$src/text_700k.txt"

( cd "$src" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sed 's|  \./|  |' ) \
    > "$work/btrfs.src.sha256"
python3 - "$src" > "$work/btrfs.src.json" <<'PY'
import json, os, stat, sys
root = sys.argv[1]
out = []
for d, dirs, files in os.walk(root):
    dirs.sort()
    for name in sorted(dirs + files):
        p = os.path.join(d, name)
        st = os.lstat(p)
        kind = ("dir" if stat.S_ISDIR(st.st_mode) else "file" if stat.S_ISREG(st.st_mode)
                else "symlink" if stat.S_ISLNK(st.st_mode) else "fifo" if stat.S_ISFIFO(st.st_mode)
                else "other")
        out.append(dict(path=os.path.relpath(p, root), type=kind, mode=st.st_mode,
                        size=st.st_size, mtime=st.st_mtime_ns // 10**9,
                        mtime_ns=st.st_mtime_ns % 10**9, ino=st.st_ino, nlink=st.st_nlink,
                        target=os.readlink(p) if kind == "symlink" else None))
json.dump(out, sys.stdout, indent=0, ensure_ascii=False)
PY

build() {   # build <name> <mkfs.btrfs options...>
    local name=$1; shift
    local img=$work/$name.img
    rm -f "$img"
    truncate -s 160M "$img"
    mkfs.btrfs -q -f -K -L "qnxprobe-$name" --rootdir "$src" --shrink "$@" "$img" \
        </dev/null >/dev/null
    btrfs check --readonly "$img" </dev/null >/dev/null 2>&1 || {
        echo "btrfs check does not pass $name" >&2; exit 1; }
    rm -rf "$work/x"; mkdir "$work/x"
    btrfs restore -S -x "$img" "$work/x" </dev/null >/dev/null 2>&1 || true
    ( cd "$work/x" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sed 's|  \./|  |' ) \
        > "$work/$name.check"
    if ! diff -q "$work/btrfs.src.sha256" "$work/$name.check" >/dev/null; then
        echo "btrfs restore does not read $name back as the source tree" >&2
        diff "$work/btrfs.src.sha256" "$work/$name.check" | head >&2
        exit 1
    fi
    gzip -9 -n -c "$img" > "$out/btrfs-$name.img.gz"
    printf '%-12s %10d bytes, %8d gzipped\n' "$name" "$(stat -c%s "$img")" \
        "$(stat -c%s "$out/btrfs-$name.img.gz")"
}

# Metadata is DUP (two copies on the one device, mkfs.btrfs's default) in every
# image but xxhash, which is SINGLE throughout and has 4 KiB nodes, so its
# trees are deeper. sha256 makes the subvolume the default one; blake2 makes it
# read-only.
build none   --subvol rw:subvol
build zlib   --subvol rw:subvol --compress zlib
build zstd   --subvol rw:subvol --compress zstd
build lzo    --subvol rw:subvol --compress lzo
build xxhash --subvol rw:subvol --csum xxhash -m single -n 4096
build sha256 --subvol default:subvol --csum sha256
build blake2 --subvol ro:subvol --csum blake2

cp "$work/btrfs.src.sha256" "$work/btrfs.src.json" "$out/"

# An ext4 volume converted in place by btrfs-convert. The original ext4 image
# is kept as the file ext2_saved/image in a subvolume of the new volume, so its
# sha256, taken before conversion, is known data for that file, which is
# mostly holes and extents that point at the old ext4 blocks.
conv=$work/conv
mkdir -p "$conv/src"
printf 'converted from ext4\n' > "$conv/src/a.txt"
python3 -c 'import random,sys; r=random.Random(7); sys.stdout.buffer.write(bytes(r.getrandbits(8) for _ in range(20000)))' \
    > "$conv/src/r.bin"
find "$conv/src" -exec touch -h -d '2024-05-06 07:08:09 UTC' {} +
truncate -s 160M "$conv/e.img"
mkfs.ext4 -q -F -E root_owner=0:0 -d "$conv/src" "$conv/e.img" </dev/null
( cd "$conv/src" && sha256sum a.txt r.bin ) > "$out/btrfs-convert.sha256"
printf '%s  ext2_saved/image\n' "$(sha256sum < "$conv/e.img" | cut -d' ' -f1)" \
    >> "$out/btrfs-convert.sha256"
btrfs-convert "$conv/e.img" </dev/null >/dev/null
btrfs check --readonly "$conv/e.img" </dev/null >/dev/null 2>&1 || {
    echo "btrfs check does not pass the converted image" >&2; exit 1; }
gzip -9 -n -c "$conv/e.img" > "$out/btrfs-convert.img.gz"
printf '%-12s %10d bytes, %8d gzipped\n' convert "$(stat -c%s "$conv/e.img")" \
    "$(stat -c%s "$out/btrfs-convert.img.gz")"

# The second device of a two-device RAID1 volume (data and metadata). mkfs.btrfs
# --rootdir takes one device only, so this volume holds no files: what it
# exercises is reading every tree from the copy on devid 2.
truncate -s 160M "$work/r1.img" "$work/r2.img"
mkfs.btrfs -q -f -K -L qnxprobe-raid1 -d raid1 -m raid1 "$work/r1.img" "$work/r2.img" \
    </dev/null >/dev/null
gzip -9 -n -c "$work/r2.img" > "$out/btrfs-raid1-dev2.img.gz"
printf '%-12s %10d bytes, %8d gzipped\n' raid1-dev2 "$(stat -c%s "$work/r2.img")" \
    "$(stat -c%s "$out/btrfs-raid1-dev2.img.gz")"
