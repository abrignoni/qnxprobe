#!/usr/bin/env bash
# Build tests/fixtures/ext4-times.img.gz, ext2-times128.img.gz and ext-times.json.
#
# Runs anywhere e2fsprogs is installed (no root, no mount). mke2fs -d writes the
# files, then debugfs -w sets each inode's time fields to chosen raw values, so
# every field differs and the cases the kernel decodes specially are present:
# nanoseconds, the epoch bits past 2038, a base with its top bit set before
# 1970, an i_extra_isize too short for i_crtime, one of 0, one the kernel
# rejects, an EXT4_EA_INODE_FL inode, and a volume of 128-byte inodes.
#
# The expected values in ext-times.json are not read by qnxprobe. debugfs stat
# reports each field's stored base and extra words and the inode's extra size;
# those are decoded here by the kernel's rule (fs/ext4/ext4.h at v7.3,
# c03c1a14507dfaf8b856c2608f9ac216021fc222: EXT4_FITS_IN_INODE,
# ext4_decode_extra_time, and __ext4_iget's i_extra_isize check). debugfs's own
# decoded date is not used, because e2fsprogs 1.47.4 reads the base unsigned
# (ext2fs_inode_xtime_get) where the kernel reads it signed; its text is kept
# beside each value so the two can be compared.
set -euo pipefail
out=${1:-$(cd "$(dirname "$0")/.." && pwd)/tests/fixtures}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export TZ=UTC
mkdir -p "$work/t4/d" "$work/t2"
for f in plain y2040 pre1970 nocrtime noextra badisize eainode; do
  printf '%s\n' "$f" > "$work/t4/$f.txt"
done
printf 'a\n' > "$work/t2/a.txt"
printf 'b\n' > "$work/t2/b.txt"
mke2fs -q -t ext4 -I 256 -L timesfix -d "$work/t4" "$work/ext4-times.img" 8M
mke2fs -q -t ext2 -I 128 -L timesfix -d "$work/t2" "$work/ext2-times128.img" 4M

# An extra word is (nanoseconds << 2) | epoch bits.
cat > "$work/set4" <<'EOF'
set_inode_field /plain.txt atime_lo 0x5f000001
set_inode_field /plain.txt atime_extra 0x1a7d6b1c
set_inode_field /plain.txt ctime_lo 0x5f000002
set_inode_field /plain.txt ctime_extra 0x34fad638
set_inode_field /plain.txt mtime_lo 0x5f000003
set_inode_field /plain.txt mtime_extra 0x4f784154
set_inode_field /plain.txt crtime_lo 0x5f000000
set_inode_field /plain.txt crtime_extra 0x69f5ac70
set_inode_field /y2040.txt mtime_lo 0x83000000
set_inode_field /y2040.txt mtime_extra 0x00000015
set_inode_field /y2040.txt atime_lo 0x10000000
set_inode_field /y2040.txt atime_extra 0x00000001
set_inode_field /y2040.txt ctime_lo 0x90000000
set_inode_field /y2040.txt ctime_extra 0x00000002
set_inode_field /y2040.txt crtime_lo 0x7fffffff
set_inode_field /y2040.txt crtime_extra 0x00000000
set_inode_field /pre1970.txt mtime_lo 0xf0000000
set_inode_field /pre1970.txt mtime_extra 0x00000000
set_inode_field /pre1970.txt atime_lo 0x80000000
set_inode_field /pre1970.txt atime_extra 0x00000000
set_inode_field /pre1970.txt ctime_lo 0x00000000
set_inode_field /pre1970.txt ctime_extra 0x00000000
set_inode_field /pre1970.txt crtime_lo 0xffffffff
set_inode_field /pre1970.txt crtime_extra 0x00000003
set_inode_field /nocrtime.txt atime_lo 0x60000001
set_inode_field /nocrtime.txt atime_extra 0x00000028
set_inode_field /nocrtime.txt ctime_lo 0x60000002
set_inode_field /nocrtime.txt ctime_extra 0x00000050
set_inode_field /nocrtime.txt mtime_lo 0x60000003
set_inode_field /nocrtime.txt mtime_extra 0x00000078
set_inode_field /nocrtime.txt crtime_lo 0x60000000
set_inode_field /nocrtime.txt crtime_extra 0x000000a0
set_inode_field /nocrtime.txt extra_isize 16
set_inode_field /noextra.txt atime_lo 0x61000001
set_inode_field /noextra.txt atime_extra 0x00000029
set_inode_field /noextra.txt ctime_lo 0x61000002
set_inode_field /noextra.txt mtime_lo 0x61000003
set_inode_field /noextra.txt mtime_extra 0x00000079
set_inode_field /noextra.txt crtime_lo 0x61000000
set_inode_field /noextra.txt extra_isize 0
set_inode_field /badisize.txt extra_isize 6
set_inode_field /eainode.txt crtime_lo 0x62000000
set_inode_field /eainode.txt crtime_extra 0x00000004
set_inode_field /eainode.txt flags 0x00280000
set_inode_field /d atime_lo 0x63000001
set_inode_field /d ctime_lo 0x63000002
set_inode_field /d mtime_lo 0x63000003
set_inode_field /d crtime_lo 0x63000000
EOF
cat > "$work/set2" <<'EOF'
set_inode_field /a.txt atime 0x64000001
set_inode_field /a.txt ctime 0x64000002
set_inode_field /a.txt mtime 0x64000003
EOF
debugfs -w -f "$work/set4" "$work/ext4-times.img" </dev/null >/dev/null 2>"$work/err4"
debugfs -w -f "$work/set2" "$work/ext2-times128.img" </dev/null >/dev/null 2>"$work/err2"
if grep -v '^debugfs [0-9]' "$work/err4" "$work/err2" | grep -q .; then
  cat "$work/err4" "$work/err2" >&2; exit 1
fi

python3 - "$work" "$out/ext-times.json" <<'PY'
import json, os, re, subprocess, sys
work, dest = sys.argv[1:]
cases = {"ext4-times": ["/plain.txt", "/y2040.txt", "/pre1970.txt", "/nocrtime.txt",
                        "/noextra.txt", "/badisize.txt", "/eainode.txt", "/d"],
         "ext2-times128": ["/a.txt", "/b.txt"]}
FIELDS = {"atime": ("accessed", 0x08, 0x8C), "ctime": ("changed", 0x0C, 0x84),
          "mtime": ("modified", 0x10, 0x88), "crtime": ("created", 0x90, 0x94)}

def stat(img, path):
    r = subprocess.run(["debugfs", "-R", f"stat {path}", img], capture_output=True,
                       text=True, stdin=subprocess.DEVNULL, check=True)
    return r.stdout

def inode_size(img):
    r = subprocess.run(["dumpe2fs", "-h", img], capture_output=True, text=True,
                       stdin=subprocess.DEVNULL, check=True)
    return int(re.search(r"^Inode size:\s+(\d+)", r.stdout, re.M).group(1))

def signed32(v):
    return v - (1 << 32) if v & 0x80000000 else v

out = {"comment": [
    "Known data for qnxprobe's ExtWalker.times(), written by tools/make_ext_times_fixture.sh.",
    "raw is what debugfs stat reports for each field (base, extra or null) and the inode's",
    "extra size; debugfs is its own date text. expected is raw decoded by the kernel's rule",
    "(fs/ext4/ext4.h at v7.3, c03c1a14507dfaf8b856c2608f9ac216021fc222), as [seconds,",
    "nanoseconds] since 1970-01-01 UTC, null where the kernel reads no value, or null for",
    "the whole inode where __ext4_iget rejects its i_extra_isize."]}
for stem, paths in cases.items():
    img = os.path.join(work, stem + ".img")
    isz = inode_size(img)
    got = {}
    for path in paths:
        text = stat(img, path)
        m = re.search(r"Size of extra inode fields: (\d+)", text)
        extra = int(m.group(1)) if m and isz > 128 else 0
        flags = int(re.search(r"Flags: (0x[0-9a-f]+)", text).group(1), 16)
        raw = {"inode_size": isz, "extra_isize": extra, "flags": flags}
        shown = {}
        for name in FIELDS:
            m = re.search(rf"^\s*{name}: (0x[0-9a-f]+)(?::(0x[0-9a-f]+|[0-9a-f]+))? -- (.*)$",
                          text, re.M)
            if m:
                raw[name] = [int(m.group(1), 16), int(m.group(2), 16) if m.group(2) else None]
                shown[name] = m.group(3)
        bad = isz > 128 and (128 + extra > isz or extra & 3)
        if bad:
            expected = None
        else:
            room = 128 + extra
            expected = {}
            for name, (key, base_at, extra_at) in FIELDS.items():
                ea = flags & 0x200000 and name != "crtime"
                if ea or base_at + 4 > room or name not in raw:
                    expected[key] = None
                    continue
                base, word = raw[name]
                sec = signed32(base)
                if extra_at + 4 <= room:
                    sec += (word & 3) << 32
                    expected[key] = [sec, word >> 2]
                else:
                    expected[key] = [sec, 0]
        got[path] = {"raw": raw, "debugfs": shown, "expected": expected}
    out[stem] = got
with open(dest, "w") as f:
    json.dump(out, f, indent=1, sort_keys=True)
    f.write("\n")
PY
gzip -9 -n -c "$work/ext4-times.img" > "$out/ext4-times.img.gz"
gzip -9 -n -c "$work/ext2-times128.img" > "$out/ext2-times128.img.gz"
ls -la "$out"/ext4-times.img.gz "$out"/ext2-times128.img.gz "$out/ext-times.json"
