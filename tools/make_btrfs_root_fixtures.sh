#!/usr/bin/env bash
# Build the Btrfs fixtures that need a mounted filesystem, and so root:
#
#   tests/fixtures/btrfs-live.img.gz       a volume the Linux kernel wrote
#   tests/fixtures/btrfs-live.src.sha256   sha256sum over it while mounted
#   tests/fixtures/btrfs-live.src.json     lstat() of every entry while mounted
#   tests/fixtures/btrfs-live.deleted.sha256
#                                          sha256 of each 64 KiB block of the
#                                          files deleted before unmounting
#   tests/fixtures/btrfs-logtree.img.gz    the same kind of volume copied after
#                                          an fsync and before the transaction
#                                          committed, so its log tree is not empty
#   tests/fixtures/btrfs-logtree.json      what was fsync'd, and the generation
#
# Run as root on Linux with btrfs-progs and util-linux (written against
# btrfs-progs 6.17.1 and kernel 7.0):
#
#     sudo tools/make_btrfs_root_fixtures.sh [OUT_DIR]
#
# Then run "python3 qnxprobe.py --self-test": _btrfs_self_checks() picks these
# up when they are beside the others and skips them when they are not.
#
# What mkfs.btrfs --rootdir cannot write, and this does: holes (NO_HOLES, so a
# range no extent item covers), a preallocated extent partly written, a punched
# hole, a reflinked file partly overwritten (an extent read from an offset
# into a shared one), a compressed file partly overwritten (an offset into a
# compressed extent) for zlib, lzo and zstd, a file of many small extents, a
# rw and a read-only snapshot, a subvolume nested in a subvolume that is then
# snapshotted (the snapshot's link to it has no ROOT_REF, so the kernel shows
# an empty directory there), a default subvolume other than the top level,
# deleted files, and an extended attribute.
#
# The oracles are the mounted kernel's own answers, taken before unmounting:
# sha256sum and lstat() through the mount point.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "run as root (sudo), it mounts a loop device" >&2
    exit 1
fi
out=${1:-$(cd "$(dirname "$0")/.." && pwd)/tests/fixtures}
work=$(mktemp -d)
mnt=$work/mnt
mkdir -p "$mnt"
cleanup() {
    mountpoint -q "$mnt" && umount "$mnt" || true
    rm -rf "$work"
}
trap cleanup EXIT

lister() {   # lister <root>: the same lstat() listing make_btrfs_fixtures.sh writes
python3 - "$1" <<'PY'
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
                        dev=st.st_dev,
                        target=os.readlink(p) if kind == "symlink" else None))
json.dump(out, sys.stdout, indent=0, ensure_ascii=False)
PY
}

text() {     # text <bytes> <tag>: compressible text of that length
python3 -c 'import sys; n=int(sys.argv[1]); l=(sys.argv[2]+" btrfs live fixture line\n").encode(); sys.stdout.buffer.write((l*(n//len(l)+1))[:n])' "$1" "$2"
}
rand() {     # rand <bytes> <seed>
python3 -c 'import random,sys; r=random.Random(int(sys.argv[2])); sys.stdout.buffer.write(bytes(r.getrandbits(8) for _ in range(int(sys.argv[1]))))' "$1" "$2"
}

img=$work/live.img
truncate -s 200M "$img"
mkfs.btrfs -q -f -L qnxprobe-live "$img" </dev/null >/dev/null
mount -o loop "$img" "$mnt"
m=$mnt

btrfs -q subvolume create "$m/sub" </dev/null
mkdir -p "$m/data" "$m/sub/inner_dir"

# holes: data, a gap, data, then a hole to the end
python3 - "$m/data/sparse.bin" <<'PY'
import sys
with open(sys.argv[1], "wb") as f:
    f.write(b"A" * 8192)
    f.seek(3 << 20)
    f.write(b"B" * 5000)
    f.truncate(8 << 20)
PY
# preallocated, then 4 KiB written in its middle
fallocate -l 1M "$m/data/prealloc.bin"
text 4096 prealloc | dd of="$m/data/prealloc.bin" bs=4096 seek=100 conv=notrunc status=none
# a punched hole
rand 262144 1 > "$m/data/punched.bin"
fallocate -p -o 65536 -l 65536 "$m/data/punched.bin"
# a reflink, then part of the copy overwritten
rand 524288 2 > "$m/data/original.bin"
cp --reflink=always "$m/data/original.bin" "$m/data/clone.bin"
text 8192 clone | dd of="$m/data/clone.bin" bs=4096 seek=10 conv=notrunc status=none
# compressed files, each then overwritten in its middle
for c in zlib lzo zstd; do
    : > "$m/data/comp_$c.txt"
    btrfs property set "$m/data/comp_$c.txt" compression "$c" </dev/null
    text 400000 "$c" > "$m/data/comp_$c.txt"
    sync -f "$m/data/comp_$c.txt"
    rand 4096 3 | dd of="$m/data/comp_$c.txt" bs=4096 seek=30 conv=notrunc status=none
done
# many small extents: appends with a commit between
for i in $(seq 1 40); do
    text 4096 "frag$i" >> "$m/data/fragmented.txt"
    sync -f "$m/data/fragmented.txt"
done
# an extended attribute
echo "xattr carrier" > "$m/data/xattr.txt"
setfattr -n user.note -v "an extended attribute" "$m/data/xattr.txt"

# subvolumes and snapshots
text 20000 insub > "$m/sub/in_sub.txt"
echo "in a nested dir" > "$m/sub/inner_dir/f.txt"
btrfs -q subvolume create "$m/sub/nested" </dev/null
echo "inside the nested subvolume" > "$m/sub/nested/n.txt"
sync -f "$m/sub/in_sub.txt"
btrfs -q subvolume snapshot "$m/sub" "$m/snap_rw" </dev/null
btrfs -q subvolume snapshot -r "$m/sub" "$m/snap_ro" </dev/null
text 4096 changed | dd of="$m/sub/in_sub.txt" bs=4096 seek=1 conv=notrunc status=none
subid=$(btrfs subvolume show "$m/sub" </dev/null | awk '/Subvolume ID:/ {print $3}')
btrfs subvolume set-default "$subid" "$m" </dev/null

# deleted files: written, committed, removed, committed
mkdir -p "$m/gone"
rand 196608 4 > "$m/gone/deleted_random.bin"
text 131072 deleted > "$m/gone/deleted_text.txt"
sync -f "$m/gone/deleted_text.txt"
python3 - "$m/gone" > "$work/deleted.sha256" <<'PY'
import hashlib, os, sys
for name in sorted(os.listdir(sys.argv[1])):
    data = open(os.path.join(sys.argv[1], name), "rb").read()
    for i in range(0, len(data), 65536):
        print(f"{hashlib.sha256(data[i:i + 65536]).hexdigest()}  {name}@{i}")
PY
rm -rf "$m/gone"

# the oracles, through the mount point; times are whatever the kernel wrote
sync -f "$m"
( cd "$m" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sed 's|  \./|  |' ) \
    > "$work/live.src.sha256"
lister "$m" > "$work/live.src.json"
umount "$mnt"
btrfs check --readonly "$img" </dev/null >/dev/null
gzip -9 -n -c "$img" > "$out/btrfs-live.img.gz"
cp "$work/live.src.sha256" "$out/btrfs-live.src.sha256"
cp "$work/live.src.json" "$out/btrfs-live.src.json"
cp "$work/deleted.sha256" "$out/btrfs-live.deleted.sha256"

# A log tree: fsync a new file and copy the image before the transaction
# commits (commit=300 holds the commit back; nothing here syncs the volume).
img2=$work/logtree.img
truncate -s 160M "$img2"
mkfs.btrfs -q -f -L qnxprobe-logtree "$img2" </dev/null >/dev/null
mount -o loop,commit=300 "$img2" "$mnt"
text 10000 committed > "$mnt/committed.txt"
sync -f "$mnt"
gen=$(btrfs inspect-internal dump-super "$img2" </dev/null | awk '$1=="generation" {print $2}')
python3 - "$mnt/fsynced.txt" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT, 0o644)
os.write(fd, b"written and fsync'd after the last commit\n")
os.fsync(fd)
os.close(fd)
PY
cp --sparse=always "$img2" "$work/logtree-copy.img"
umount "$mnt"
log_root=$(btrfs inspect-internal dump-super "$work/logtree-copy.img" </dev/null | awk '$1=="log_root" {print $2}')
if [ "${log_root:-0}" = "0" ]; then
    echo "the copy has no log tree (log_root 0); the commit came first, run again" >&2
    exit 1
fi
gzip -9 -n -c "$work/logtree-copy.img" > "$out/btrfs-logtree.img.gz"
printf '{"generation": %s, "log_root": %s, "committed": ["committed.txt"], "fsynced": ["fsynced.txt"]}\n' \
    "$gen" "$log_root" > "$out/btrfs-logtree.json"

if [ -n "${SUDO_USER:-}" ]; then
    chown "$SUDO_USER" "$out"/btrfs-live.* "$out"/btrfs-logtree.*
fi
ls -l "$out"/btrfs-live.* "$out"/btrfs-logtree.*
