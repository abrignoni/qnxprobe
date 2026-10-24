#!/usr/bin/env bash
# Build tests/fixtures/apfs-times.img.gz, hfsplus-times.img.gz and mac-times.json.
#
# Runs on macOS, as an ordinary user: hdiutil creates and mounts a plain image
# with no partition map, setattrlist(2) gives each file chosen creation,
# modification, access and backup times (the change time cannot be set; the
# kernel writes it), and after the image is detached and attached again read
# only, getattrlist(2) reads all five back through macOS's own APFS and HFS+
# drivers. That reading is the known data; qnxprobe plays no part in it.
#
# Two kinds of value are recorded as written rather than as macOS reads them
# back, both on HFS+ only, and the "why" field says which (Apple's hfs-715.120.4,
# 124b970fd5390f1c2cd6f985478616a04f6eeb1f, core/MacOSStubs.c):
# - a time set to 0, which to_hfs_time stores as 0, "uninitialized", and which
#   to_bsd_time reads back as 0, and a backup time never set, which
#   core/hfs_catalog.c stores as 0 when it creates the record: expected null;
# - a time before 1970, which TN1150 counts from 1904 and so can hold, but
#   which to_bsd_time reads back as 0 ("don't let date go negative"): expected
#   the time written.
set -euo pipefail
OUT=${1:-$(cd "$(dirname "$0")/.." && pwd)/tests/fixtures}
WORK=$(mktemp -d)
MNT="$WORK/mnt"
mkdir -p "$MNT"
cleanup() { hdiutil detach "$MNT" -quiet 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

cat > "$WORK/attrs.py" <<'PY'
"""setattrlist/getattrlist for the five common times (sys/attr.h)."""
import ctypes, json, os, struct, sys
libc = ctypes.CDLL(None, use_errno=True)
CRTIME, MODTIME, CHGTIME, ACCTIME, BKUPTIME = 0x200, 0x400, 0x800, 0x1000, 0x2000
NAMES = ((CRTIME, "created"), (MODTIME, "modified"), (CHGTIME, "changed"),
         (ACCTIME, "accessed"), (BKUPTIME, "backup"))
FSOPT_NOFOLLOW = 1

def attrlist(mask):
    return struct.pack("<HHIIIII", 5, 0, mask, 0, 0, 0, 0)

def set_times(path, when):
    mask, buf = 0, b""
    for bit, name in NAMES:
        if name in when:
            mask |= bit
            buf += struct.pack("<qq", *when[name])
    al = ctypes.create_string_buffer(attrlist(mask))
    data = ctypes.create_string_buffer(buf)
    if libc.setattrlist(path.encode(), al, data, len(buf), FSOPT_NOFOLLOW):
        raise OSError(ctypes.get_errno(), path)

def get_times(path):
    mask = CRTIME | MODTIME | CHGTIME | ACCTIME | BKUPTIME
    al = ctypes.create_string_buffer(attrlist(mask))
    data = ctypes.create_string_buffer(4 + 16 * 5)
    if libc.getattrlist(path.encode(), al, data, len(data), FSOPT_NOFOLLOW):
        raise OSError(ctypes.get_errno(), path)
    out, at = {}, 4
    for _bit, name in NAMES:
        out[name] = list(struct.unpack_from("<qq", data.raw, at))
        at += 16
    return out

if __name__ == "__main__":
    cmd, root, plan = sys.argv[1], sys.argv[2], sys.argv[3]
    plan = json.load(open(plan))
    if cmd == "set":
        for rel, when in plan.items():
            set_times(os.path.join(root, rel), when)
    else:
        print(json.dumps({rel: get_times(os.path.join(root, rel)) for rel in plan}))
PY

# What each file is given, as [seconds, nanoseconds] since 1970. Creation is
# set below modification because setattrlist(2) moves it down to a modification
# time set before it.
cat > "$WORK/plan.json" <<'JSON'
{
 "plain.txt":   {"created": [1593835520, 444444444], "modified": [1593835523, 333333333],
                 "accessed": [1593835521, 111111111], "backup": [1593835524, 555555555]},
 "d":           {"created": [1660944384, 0], "modified": [1660944387, 0],
                 "accessed": [1660944385, 0], "backup": [1660944388, 0]},
 "hard_a.txt":  {"created": [1610612736, 0], "modified": [1610612739, 0],
                 "accessed": [1610612737, 0], "backup": [1610612740, 0]},
 "zero.txt":    {"created": [1627389952, 0], "modified": [1627389955, 0],
                 "accessed": [0, 0], "backup": [0, 0]}
}
JSON
# Before 1970: HFS+ only, since the APFS reference describes its times as
# unsigned and gives no reading of a negative one.
cat > "$WORK/plan-hfs.json" <<'JSON'
{"pre1970.txt": {"created": [-172800, 0], "modified": [-86400, 0]}}
JSON

build() {   # build <stem> <fs> <plan files...>
  local stem=$1 fs=$2; shift 2
  hdiutil create -size 8m -fs "$fs" -volname QNXTIMES -type UDIF -layout NONE -quiet "$WORK/$stem.dmg"
  hdiutil attach "$WORK/$stem.dmg" -nobrowse -readwrite -mountpoint "$MNT" -quiet
  mkdir "$MNT/d"
  for f in plain zero pre1970; do printf '%s\n' "$f" > "$MNT/$f.txt"; done
  [ "$stem" = hfsplus-times ] || rm "$MNT/pre1970.txt"
  printf 'one record, two names\n' > "$MNT/hard_a.txt"
  ln "$MNT/hard_a.txt" "$MNT/hard_b.txt"
  for p in "$@"; do python3 "$WORK/attrs.py" set "$MNT" "$p"; done
  sync
  hdiutil detach "$MNT" -quiet
  hdiutil convert "$WORK/$stem.dmg" -format UDTO -quiet -o "$WORK/$stem"
  mv "$WORK/$stem.cdr" "$WORK/$stem.img"
  local before after
  before=$(shasum -a 256 "$WORK/$stem.img" | cut -d' ' -f1)
  hdiutil attach "$WORK/$stem.img" -readonly -nobrowse -mountpoint "$MNT" -quiet \
    -imagekey diskimage-class=CRawDiskImage
  python3 - "$WORK/attrs.py" "$MNT" "$WORK/$stem.read.json" "$@" <<'READ'
import json, runpy, sys
attrs = runpy.run_path(sys.argv[1])
root, dest, plans = sys.argv[2], sys.argv[3], sys.argv[4:]
rels = {}
for p in plans:
    rels.update(json.load(open(p)))
rels["hard_b.txt"] = rels["hard_a.txt"]
got = {rel: attrs["get_times"](root + "/" + rel) for rel in sorted(rels)}
json.dump({"set": rels, "read": got}, open(dest, "w"))
READ
  hdiutil detach "$MNT" -quiet
  after=$(shasum -a 256 "$WORK/$stem.img" | cut -d' ' -f1)
  [ "$before" = "$after" ] || { echo "the read-only attach changed $stem.img" >&2; exit 1; }
  gzip -9 -n -c "$WORK/$stem.img" > "$OUT/$stem.img.gz"
}
build apfs-times APFS "$WORK/plan.json"
build hfsplus-times "HFS+" "$WORK/plan.json" "$WORK/plan-hfs.json"

python3 - "$WORK" "$OUT/mac-times.json" <<'PY'
import json, os, sys
work, dest = sys.argv[1:]
out = {"comment": [
    "Known data for qnxprobe's ApfsWalker.times() and HfsPlusWalker.times(), written by",
    "tools/make_times_fixtures.sh. set is what setattrlist(2) was given; macos is what",
    "getattrlist(2) read back from the image attached read only; expected is the macos",
    "reading as [seconds, nanoseconds] since 1970-01-01 UTC, except where why says it",
    "is the value written (see the script). The change time is the kernel's own."]}
for stem in ("apfs-times", "hfsplus-times"):
    d = json.load(open(os.path.join(work, stem + ".read.json")))
    rows = {}
    for rel, read in d["read"].items():
        given = d["set"][rel]
        expected, why = {}, {}
        for name, value in read.items():
            if stem == "apfs-times" and name == "backup":
                continue                    # APFS keeps no backup time in j_inode_val_t
            want = given.get(name)
            if stem == "hfsplus-times" and want == [0, 0]:
                expected[name], why[name] = None, "stored as 0, uninitialized"
            elif stem == "hfsplus-times" and want is None and value == [0, 0]:
                # never set: hfs_catalog.c writes backupDate 0 when it creates a record
                expected[name], why[name] = None, "never set, stored as 0"
            elif stem == "hfsplus-times" and want is not None and want[0] < 0:
                expected[name], why[name] = want, "before 1970; macOS reads it back as 0"
            else:
                expected[name] = value
        rows[rel] = {"set": given, "macos": read, "expected": expected, "why": why}
    out[stem] = rows
with open(dest, "w") as f:
    json.dump(out, f, indent=1, sort_keys=True)
    f.write("\n")
PY
ls -la "$OUT"/apfs-times.img.gz "$OUT"/hfsplus-times.img.gz "$OUT/mac-times.json"
