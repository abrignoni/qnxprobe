#!/usr/bin/env bash
# Build the XFS fixtures: tests/fixtures/xfs-*.img.gz and their xfs-*.known.json.gz.
#
# Runs on Linux as an ordinary user with xfsprogs 6.18 (mkfs.xfs, xfs_db) and
# python3, on a source filesystem with user extended attributes (ext4). No root
# and no mount: mkfs.xfs -p <dir> writes the whole tree into the
# image itself (xfsprogs mkfs/proto.c populate_from_dir), keeping the content,
# the holes of a sparse file (SEEK_DATA and SEEK_HOLE), hard links and the mtime
# of every entry. Every byte of XFS structure is written by xfsprogs.
#
# The known data is taken from the source tree, not from the image: path, type,
# permission bits, size, mtime in nanoseconds, symlink target, sha256 of every
# regular file and which names share an inode. xfs_db then reads each image
# (read only, -r) and records, for each test directory, its data fork format and
# the end of its block map, from which the directory format follows the way
# xfs_dir2_format() decides it (libxfs/xfs_dir2.c), the free extents and free
# list counts, and xfs_logprint the log's head, tail and state. xfs_repair -n
# checks each image before it is kept.
#
# Fixtures (tests/fixtures/NAME.img.gz):
# Each image comes with NAME.known.json.gz.
#
#   xfs-v5      300 MiB, mkfs.xfs defaults (v5: CRCs, ftype, bigtime, nrext64,
#               sparse inodes, finobt, rmapbt, reflink), 4 KiB blocks, 512-byte
#               inodes. The full tree, with times before 1970 and after 2038.
#   xfs-v4      64 MiB, -m crc=0 -n ftype=0 (v4, version 2 inodes, no file type
#               in directory entries), 1 KiB blocks, 16 KiB directory blocks,
#               256-byte inodes. The full tree without the after-2038 time,
#               which a v4 inode cannot hold.
#   xfs-v5-4kn  64 MiB, v5 with 4 KiB sectors (so the AG headers sit 4 KiB
#               apart), -m metadir=1,bigtime=0 -i size=1024,nrext64=0: the
#               metadata directory feature, classic timestamps and 32-bit extent
#               counters on a v5 volume. A small tree.
# The 64 MiB ones are below the 300 MiB mkfs.xfs now insists on, so they are
# made with --unsupported, which changes nothing on disk but the size.
#
# Usage: make_xfs_fixtures.sh [OUTDIR]   (default ~/fx/xfs/out)
set -euo pipefail
out=${1:-$HOME/fx/xfs/out}
work=${XFS_FIXTURE_WORK:-$HOME/fx/xfs/work}

gen_tree() {   # gen_tree DIR FLAVOUR   FLAVOUR is v5, v4 or small
python3 -I - "$1" "$2" <<'PY'
import hashlib, os, sys
root, flavour = sys.argv[1], sys.argv[2]
os.makedirs(root)
os.chdir(root)
T0 = 1700000000                      # 2023-11-14, a fixed base for every mtime
times = {}                           # path -> mtime in ns, applied at the end

def stamp(path, i):
    times[path] = (T0 + i * 3607) * 10**9 + (i * 7919 % 10**9)

def write(path, data, i):
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(data)
    stamp(path, i)

def blocks(n, tag, bs=4096):
    """n blocks that each name their own number, so a block read from the
    wrong place cannot match, and that still compress."""
    out = bytearray()
    for i in range(n):
        head = f"{tag} block {i:08d}\n".encode()
        fill = hashlib.sha256(f"{tag}{i}".encode()).hexdigest().encode() * (bs // 64 + 1)
        out += (head + fill)[:bs]
    return bytes(out)

def sparse(path, pieces, size, i):
    """A file with data only at the given (offset, bytes) pieces, holes between."""
    with open(path, "wb") as fh:
        for off, data in pieces:
            fh.seek(off)
            fh.write(data)
        fh.truncate(size)
    stamp(path, i)

n = 0
def nxt():
    global n
    n += 1
    return n

write("hello.txt", b"hello from an XFS fixture\n", nxt())
write("empty.txt", b"", nxt())
write("café résumé.txt", "accented name\n".encode(), nxt())
write("日本語のファイル.txt", "non-Latin name\n".encode(), nxt())
write("L" * 251 + ".txt", b"a name of 255 bytes\n", nxt())
write("é" * 125 + ".txt", b"a name of 254 bytes in two-byte characters\n", nxt())

# The four directory formats, plus one big enough for a B+tree block map. The
# counts are set so the formats come out as named on each flavour's geometry;
# xfs_db records what each really is, and the self-check reports it.
small = flavour == "small"
write("dirs/sf/a.txt", b"shortform a\n", nxt())
write("dirs/sf/b.txt", b"shortform b\n", nxt())
os.makedirs("dirs/sf/sub", exist_ok=True)
stamp("dirs/sf/sub", nxt())
for k in range(100):
    write(f"dirs/block/file{k:03d}.txt", f"block {k}\n".encode(), nxt())
if not small:
    for k in range(700 if flavour == "v4" else 300):    # v4 has 16 KiB directory blocks
        write(f"dirs/leaf/entry_{k:04d}_name.txt", b"", nxt())
    for k in range(3000):
        write(f"dirs/node/a_somewhat_longer_entry_name_{k:05d}.dat", b"", nxt())
    # Each file holds one block of data, written as its entry is added, so the
    # directory's own blocks land between the files' and its block map
    # fragments into more extents than the inode can hold.
    long = "x" * 180
    for k in range(1500):
        write(f"dirs/btree/{long}_{k:05d}", f"btree member {k}\n".encode(), nxt())

if not small:
    write("data/large.bin", blocks(1536, "large") + b"tail of 123 bytes".ljust(123, b"!"), nxt())
    # holes before, between and after the data
    sparse("data/sparse.bin", [(65536, blocks(1, "s1")), (1 << 20, blocks(2, "s2"))],
           3 * (1 << 20), nxt())
    # sixty separate data blocks with a hole after each: more extents than an
    # inode holds, so its block map is a B+tree
    sparse("data/manyext.bin", [(k * 8192, blocks(1, f"m{k}")) for k in range(60)],
           60 * 8192 - 4096 + 100, nxt())
    write("data/one_block.bin", blocks(1, "one"), nxt())
    sparse("data/all_hole.bin", [], 1 << 20, nxt())
else:
    write("data/large.bin", blocks(64, "small"), nxt())
    sparse("data/sparse.bin", [(32768, blocks(1, "s1")), (65536, blocks(2, "s2"))], 1 << 17, nxt())

# Symlinks: a short target lives in the inode, a long one in a block of its own.
for name, target in (("links/short", "../hello.txt"),
                     ("links/dangling", "does/not/exist"),
                     ("links/to_dir", "../dirs/sf"),
                     ("links/long", "/" + "/".join(f"segment{k:03d}" for k in range(90)))):
    os.makedirs("links", exist_ok=True)
    os.symlink(target, name)
    stamp(name, nxt())

# Hard links: three names for one inode, in two directories.
os.makedirs("hard/inner", exist_ok=True)
write("hard/original.txt", b"one inode, three names\n", nxt())
os.link("hard/original.txt", "hard/second.txt")
os.link("hard/original.txt", "hard/inner/third.txt")
os.mkfifo("pipe")
stamp("pipe", nxt())
os.makedirs("empty_dir")
stamp("empty_dir", nxt())

deep = "deep/" + "/".join(f"d{k:02d}" for k in range(1, 15))
write(deep + "/bottom.txt", b"fourteen levels down\n", nxt())

# Times: nanoseconds, before 1970, and (bigtime only) after 2038.
write("times/ns.txt", b"ns\n", nxt())
times["times/ns.txt"] = 1234567890 * 10**9 + 123456789
write("times/before_1970.txt", b"1960\n", nxt())
times["times/before_1970.txt"] = -315619200 * 10**9 + 5          # 1960-01-01
if flavour == "v5":
    write("times/after_2038.txt", b"2100\n", nxt())
    times["times/after_2038.txt"] = 4102444800 * 10**9 + 7        # 2100-01-01

# Extended attributes give an inode an attribute fork, which shrinks its data
# fork: a short one stays in the inode, a long one goes to blocks of its own.
os.setxattr("hello.txt", "user.note", b"an attribute in the inode")
os.setxattr("dirs/sf", "user.note", b"a shortform directory with an attribute fork")
os.setxattr("data/large.bin", "user.big", bytes(range(256)) * 12)
os.setxattr("dirs/block", "user.big", b"b" * 3000)

# Every directory gets a time too. Children first, so a parent's own time is
# set after its entries are made and nothing moves it again.
for dirpath, dirnames, _files in os.walk(".", topdown=False):
    p = os.path.relpath(dirpath)
    if p != "." and p not in times:
        stamp(p, nxt())
for p in sorted(times, key=lambda q: -q.count("/")):
    os.utime(p, ns=(times[p], times[p]), follow_symlinks=False)
PY
}

known() {      # known TREE OUT.json  the listing and hashes, read from the source tree
python3 -I - "$1" "$2" <<'PY'
import hashlib, json, os, stat, sys
root, dest = sys.argv[1], sys.argv[2]
entries, inodes = [], {}
for dirpath, dirnames, filenames in os.walk(root):
    dirnames.sort()
    for name in sorted(dirnames + filenames):
        full = os.path.join(dirpath, name)
        rel = os.path.relpath(full, root)
        st = os.lstat(full)
        e = {"path": rel, "mode": st.st_mode, "size": st.st_size, "mtime_ns": st.st_mtime_ns}
        if stat.S_ISREG(st.st_mode):
            e["type"] = "file"
            e["sha256"] = hashlib.sha256(open(full, "rb").read()).hexdigest()
            inodes.setdefault(st.st_ino, []).append(rel)
        elif stat.S_ISDIR(st.st_mode):
            e["type"] = "dir"
        elif stat.S_ISLNK(st.st_mode):
            e["type"] = "symlink"
            e["target"] = os.readlink(full)
        elif stat.S_ISFIFO(st.st_mode):
            e["type"] = "fifo"
        entries.append(e)
links = sorted(sorted(v) for v in inodes.values() if len(v) > 1)
json.dump({"entries": entries, "hard_links": links}, open(dest, "w"), indent=0, ensure_ascii=False)
print(f"{len(entries)} entries, {sum(1 for e in entries if e['type'] == 'file')} files")
PY
}

record_xfs_db() {   # record_xfs_db IMAGE KNOWN.json   add xfs_db's view of the test directories
python3 -I - "$1" "$2" <<'PY'
import json, os, re, subprocess, sys
img, dest = sys.argv[1], sys.argv[2]
doc = json.load(open(dest))
def db(*cmds):
    args = ["xfs_db", "-r"]
    for c in cmds:
        args += ["-c", c]
    return subprocess.run(args + [img], stdin=subprocess.DEVNULL, capture_output=True,
                          text=True, check=True).stdout
sb = db("sb 0", "p blocklog dirblklog")
blocklog = int(re.search(r"blocklog = (\d+)", sb).group(1))
dirblklog = int(re.search(r"dirblklog = (\d+)", sb).group(1))
fsbcount = 1 << dirblklog
leafblk = (1 << 35) >> blocklog          # XFS_DIR2_LEAF_OFFSET in filesystem blocks
seen = {}
want = ["", "dirs/sf", "dirs/block", "dirs/leaf", "dirs/node", "dirs/btree", "hard", "links",
        "data", "data/manyext.bin", "data/sparse.bin", "data/large.bin", "links/long", "links/short",
        "hello.txt"] + [p for p in os.environ.get("XFS_DB_EXTRA", "").split(",") if p]
for path in want:
    if path and not any(e["path"] == path for e in doc["entries"]):
        continue
    out = db(f"path /{path}", "p core.format core.nextents core.size core.forkoff", "bmap")
    fmt = re.search(r"core\.format = \d+ \((\w+)\)", out).group(1)
    ends = [int(o) + int(c) for o, c in re.findall(r"data offset (\d+) startblock \d+ \(\d+/\d+\) count (\d+)", out)]
    eof = max(ends) if ends else 0
    rec = {"fork": fmt, "extents": len(ends), "eof": eof,
           "forkoff": int(re.search(r"core\.forkoff = (\d+)", out).group(1))}
    is_dir = path == "" or any(e["path"] == path and e["type"] == "dir" for e in doc["entries"])
    if is_dir:
        # xfs_dir2_format(), libxfs/xfs_dir2.c
        rec["dir_format"] = ("shortform" if fmt == "local" else "block" if eof == fsbcount
                             else "leaf" if eof == leafblk + fsbcount else "node")
    seen[path or "/"] = rec
doc["xfs_db"] = seen
# Free space as xfs_db counts it: every free extent in the by-block btrees and,
# listed one block at a time, the blocks on each group's free list (db/freesp.c).
fs = db("freesp -d")
doc["freesp"] = [[int(a), int(b), int(c)] for a, b, c in re.findall(r"^\s+(\d+)\s+(\d+)\s+(\d+)\s*$", fs, re.M)]
agcount = int(re.search(r"agcount = (\d+)", db("sb 0", "p agcount")).group(1))
doc["flcount"] = [int(re.search(r"flcount = (\d+)", db(f"agf {a}", "p flcount")).group(1))
                  for a in range(agcount)]
lp = subprocess.run(["xfs_logprint", "-t", img], stdin=subprocess.DEVNULL, capture_output=True, text=True).stdout
m = re.search(r"log tail: (\d+) head: (\d+) state: <(\w+)>", lp)
doc["log"] = {"tail": int(m.group(1)), "head": int(m.group(2)), "state": m.group(3)}
print(f"  freesp {len(doc['freesp'])} rows, flcount {doc['flcount']}, log {doc['log']}")
doc["xfs_db_version"] = subprocess.run(["xfs_db", "-V"], stdin=subprocess.DEVNULL,
                                       capture_output=True, text=True).stdout.strip()
json.dump(doc, open(dest, "w"), indent=0, ensure_ascii=False)
for k, v in seen.items():
    print(f"  {k:<22} {v}")
PY
}

build() {      # build NAME FLAVOUR SIZE MKFS-OPTIONS...
    local name=$1 flavour=$2 size=$3
    shift 3
    gen_tree "$work/$name.tree" "$flavour"
    known "$work/$name.tree" "$out/$name.known.json"
    rm -f "$work/$name.img"
    truncate -s "$size" "$work/$name.img"
    mkfs.xfs -q "$@" -L "${name:0:12}" -p "$work/$name.tree" "$work/$name.img" </dev/null
    xfs_repair -n -f "$work/$name.img" </dev/null >"$work/$name.repair.txt" 2>&1 \
        || { echo "xfs_repair -n found problems in $name"; cat "$work/$name.repair.txt"; exit 1; }
    record_xfs_db "$work/$name.img" "$out/$name.known.json"
    gzip -9 -n -f "$out/$name.known.json"
    gzip -9 -n -c "$work/$name.img" >"$out/$name.img.gz"
    echo "$name: $(stat -c %s "$out/$name.img.gz") bytes compressed"
}

# make_xfs_root_fixtures.sh sources this file for the functions above.
[ -n "${XFS_FIXTURE_LIB:-}" ] && return 0

rm -rf "$work"
mkdir -p "$work" "$out"

build xfs-v5 v5 300M
build xfs-v4 v4 64M --unsupported -m crc=0 -n ftype=0,size=16384 -b size=1024 -i size=256
build xfs-v5-4kn small 64M --unsupported -s size=4096 -m metadir=1,bigtime=0 -i size=1024,nrext64=0
ls -l "$out"
