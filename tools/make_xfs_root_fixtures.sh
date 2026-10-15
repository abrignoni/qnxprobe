#!/usr/bin/env bash
# Build the XFS fixtures that need a mounted filesystem, and so root:
# tests/fixtures/xfs-mounted.img.gz and xfs-dirty.img.gz, each with its
# NAME.known.json.gz.
#
# Run on Linux with xfsprogs 6.18 and the kernel's XFS driver:
#     sudo bash tools/make_xfs_root_fixtures.sh [OUTDIR]
# OUTDIR defaults to ./xfs-root-out. Copy what it writes into tests/fixtures;
# the self-test checks these two whenever they are there.
#
# xfs-mounted   300 MiB, mkfs.xfs defaults, written through the kernel:
#   frag/a.bin, frag/b.bin   grown by turns, one 4 KiB block at a time with an
#                            fsync after each and allocsize=4k, so each is
#                            many extents (657 on the committed image) under an
#                            extent B+tree root in the inode
#   unwritten.bin            1 MiB preallocated (fallocate), 64 KiB written in the
#                            middle: unwritten extents either side of a written one
#   reflink.bin              cp --reflink=always of frag/a.bin: shared extents
#   shrunk/                  2,000 entries made, 1,500 removed: a node directory
#                            after removals (on the committed image its data
#                            blocks stayed contiguous: no holes)
#   xattrs.bin               60 attributes: an attribute fork in blocks of its own
#   deleted/                 files written and removed, their blocks now free
#   scratch/                 empty, for the dirty fixture
# The listing and hashes are read back through the mounted filesystem after the
# tree is written and its times set, then the volume is unmounted cleanly.
#
# xfs-dirty     a copy of xfs-mounted, mounted again, files added under scratch/
#   and their data and the log forced to disk, then shut down (xfs_io shutdown -f)
#   and unmounted, which leaves the log dirty. Its known listing is xfs-mounted's
#   less scratch/, with extra entries allowed: whether the added files reached
#   their home locations before the shutdown is not controlled. xfs_logprint
#   records the dirty head and tail.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run this as root (sudo)"; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$PWD/xfs-root-out}
work=$(mktemp -d)
mnt=$work/mnt
mkdir -p "$mnt" "$out"
cleanup() { umount "$mnt" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT
# The helper sets work from XFS_FIXTURE_WORK when it is sourced: give it this run's own
# folder, so work keeps naming it (a lib/ subfolder here was never made).
export XFS_FIXTURE_WORK=$work
XFS_FIXTURE_LIB=1 . "$here/make_xfs_fixtures.sh" "$out"

img=$work/xfs-mounted.img
truncate -s 300M "$img"
mkfs.xfs -q -L xfs-mounted "$img" </dev/null
mount -o loop,noatime,allocsize=4k "$img" "$mnt"
python3 -I - "$mnt" <<'PY'
import os, subprocess, sys
root = sys.argv[1]
os.chdir(root)
T0 = 1710000000
n = 0
def stamp(p):
    global n
    n += 1
    os.utime(p, ns=((T0 + n * 4001) * 10**9 + n, (T0 + n * 4001) * 10**9 + n), follow_symlinks=False)

os.makedirs("frag")
fa = os.open("frag/a.bin", os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
fb = os.open("frag/b.bin", os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
for i in range(700):
    for fd, tag in ((fa, b"A"), (fb, b"B")):
        os.write(fd, (tag + f" block {i:06d}\n".encode()) * 256)
        os.fsync(fd)
os.close(fa)
os.close(fb)
subprocess.run(["xfs_io", "-f", "-c", "falloc 0 1m", "-c", "pwrite -S 0x5a 256k 64k", "-c", "fsync",
                "unwritten.bin"], check=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
subprocess.run(["cp", "--reflink=always", "frag/a.bin", "reflink.bin"], check=True,
               stdin=subprocess.DEVNULL)
os.makedirs("shrunk")
for k in range(2000):
    with open(f"shrunk/entry_with_a_fairly_long_name_{k:05d}", "wb") as fh:
        fh.write(f"{k}\n".encode())
for k in range(2000):
    if k % 4:
        os.unlink(f"shrunk/entry_with_a_fairly_long_name_{k:05d}")
with open("xattrs.bin", "wb") as fh:
    fh.write(b"a file with many attributes\n")
for k in range(60):
    os.setxattr("xattrs.bin", f"user.attr{k:03d}", bytes([k]) * 200)
os.makedirs("deleted")
for k in range(40):
    with open(f"deleted/gone{k:02d}.bin", "wb") as fh:
        fh.write(bytes([k]) * 20000)
os.sync()
for k in range(40):
    if k % 2:
        os.unlink(f"deleted/gone{k:02d}.bin")
os.makedirs("scratch")
for dirpath, dirnames, filenames in os.walk(".", topdown=False):
    for name in filenames + dirnames:
        stamp(os.path.join(dirpath, name))
stamp(".")
os.sync()
PY
XFS_DB_EXTRA=frag/a.bin,frag/b.bin,unwritten.bin,reflink.bin,shrunk,xattrs.bin known "$mnt" "$out/xfs-mounted.known.json"
umount "$mnt"
xfs_repair -n -f "$img" </dev/null >"$work/mounted.repair.txt" 2>&1 \
    || { echo "xfs_repair -n found problems"; cat "$work/mounted.repair.txt"; exit 1; }
XFS_DB_EXTRA=frag/a.bin,frag/b.bin,unwritten.bin,reflink.bin,shrunk,xattrs.bin \
    record_xfs_db "$img" "$out/xfs-mounted.known.json"
cp "$img" "$work/xfs-dirty.img"
gzip -9 -n -f "$out/xfs-mounted.known.json"
gzip -9 -n -c "$img" >"$out/xfs-mounted.img.gz"

dimg=$work/xfs-dirty.img
mount -o loop,noatime "$dimg" "$mnt"
for k in $(seq 1 20); do
    head -c 50000 /dev/urandom >"$mnt/scratch/added$k.bin"
done
xfs_io -c fsync "$mnt/scratch/added1.bin" </dev/null
xfs_io -x -c "shutdown -f" "$mnt" </dev/null
umount "$mnt"
python3 -I - "$out/xfs-mounted.known.json.gz" "$out/xfs-dirty.known.json" <<'PY'
import gzip, json, sys
doc = json.load(gzip.open(sys.argv[1], "rt"))
keep = [e for e in doc["entries"] if e["path"] != "scratch"]
json.dump({"entries": keep, "hard_links": doc["hard_links"], "allow_extra": True},
          open(sys.argv[2], "w"), indent=0, ensure_ascii=False)
PY
record_xfs_db "$dimg" "$out/xfs-dirty.known.json"
python3 -I - "$out/xfs-dirty.known.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc.pop("freesp", None)          # the free-space btrees on disk may predate the log
doc.pop("flcount", None)
assert doc["log"]["state"] == "DIRTY", doc["log"]
json.dump(doc, open(sys.argv[1], "w"), indent=0, ensure_ascii=False)
PY
gzip -9 -n -f "$out/xfs-dirty.known.json"
gzip -9 -n -c "$dimg" >"$out/xfs-dirty.img.gz"
[ -n "${SUDO_USER:-}" ] && chown -R "$SUDO_USER" "$out"
ls -l "$out"
