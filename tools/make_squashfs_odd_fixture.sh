#!/usr/bin/env bash
# Build tests/fixtures/squashfs-odd.img.gz and squashfs-odd.src.json, the list
# the self-test checks its names against.
#
# Runs on Linux with squashfs-tools installed (no root, no mount). A Linux file
# name is bytes, and SquashFS stores them as given, so the tree holds names
# that are not UTF-8 beside names that are: a Latin-1 byte, a lone
# continuation byte in the middle and at the start, bytes no UTF-8 sequence
# uses, the CESU-8 form of a surrogate, a folder with such a name, and a
# symlink whose target has one. The rest are names a zip member has to escape
# or keep as they are (a backslash, a colon, a star and a question mark, a
# tab, a trailing dot, a literal %E9).
#
# squashfs-odd.src.json is written from the source tree, before mksquashfs
# runs: each entry's path as hex of its stored bytes, its kind, and a file's
# sha256 or a symlink's target as hex. Before anything is written the image is
# extracted with unsquashfs and every file hashed against that list, so a
# fixture squashfs-tools itself cannot read back never reaches the repository.
set -euo pipefail

out=${1:-$(cd "$(dirname "$0")/.." && pwd)/tests/fixtures}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

python3 - "$work/src" "$work/squashfs-odd.src.json" <<'PY'
import hashlib, json, os, sys
root, listing = os.fsencode(sys.argv[1]), sys.argv[2]
names = [b"caf\xe9.txt", b"\x82leading.txt", b"a\x80b.txt", b"a\x81b.txt",
         "café_utf8.txt".encode(), "emoji_\U0001F600.txt".encode(),
         b"caf%E9.txt", b"back\\slash.txt", b"co:lon.txt", b"star*q?.txt",
         b"tab\there.txt", b"trailing.dot.", b"\xed\xa0\x80cesu_surrogate.txt",
         b"\xff\xfe\xfd.bin", b"plain.txt"]
os.makedirs(root)
for i, name in enumerate(names):
    with open(os.path.join(root, name), "wb") as fh:
        fh.write(b"odd name %d\n" % i)
sub = os.path.join(root, b"dir\xe9")
os.makedirs(sub)
for i in range(3):
    with open(os.path.join(sub, b"inner%d.txt" % i), "wb") as fh:
        fh.write(b"inside an undecodable folder %d\n" % i)
os.symlink(b"target\xe9", os.path.join(root, b"sym_bad_target"))
rows = []
for folder, dirs, files in os.walk(root):
    for name in sorted(dirs + files):
        full = os.path.join(folder, name)
        row = {"path_hex": os.path.relpath(full, root).hex()}
        if os.path.islink(full):
            row.update(kind="symlink", target_hex=os.readlink(full).hex())
        elif os.path.isdir(full):
            row.update(kind="dir")
        else:
            with open(full, "rb") as fh:
                row.update(kind="file", sha256=hashlib.sha256(fh.read()).hexdigest())
        rows.append(row)
        os.utime(full, (1700000000, 1700000000), follow_symlinks=False)
os.utime(root, (1700000000, 1700000000))
rows.sort(key=lambda r: bytes.fromhex(r["path_hex"]))
with open(listing, "w", encoding="ascii") as fh:
    json.dump(rows, fh, indent=1)
    fh.write("\n")
PY

mksquashfs "$work/src" "$work/odd.img" -noappend -quiet -no-progress -all-root \
    -mkfs-time 1700000000 >/dev/null
unsquashfs -q -n -d "$work/x" "$work/odd.img" >/dev/null 2>&1 || true
python3 - "$work/x" "$work/squashfs-odd.src.json" <<'PY'
import hashlib, json, os, sys
root = os.fsencode(sys.argv[1])
with open(sys.argv[2], encoding="ascii") as fh:
    rows = json.load(fh)
for row in rows:
    full = os.path.join(root, bytes.fromhex(row["path_hex"]))
    if row["kind"] == "file":
        with open(full, "rb") as fh:
            assert hashlib.sha256(fh.read()).hexdigest() == row["sha256"], row
    elif row["kind"] == "symlink":
        assert os.readlink(full).hex() == row["target_hex"], row
    else:
        assert os.path.isdir(full), row
found = sum(len(d) + len(f) for _p, d, f in os.walk(root))
assert found == len(rows), (found, len(rows))
print(f"unsquashfs reads back {len(rows)} entries as the source tree")
PY

gzip -9 -n -c "$work/odd.img" > "$out/squashfs-odd.img.gz"
cp "$work/squashfs-odd.src.json" "$out/squashfs-odd.src.json"
printf 'odd %8d bytes, %7d gzipped\n' "$(stat -c%s "$work/odd.img")" \
    "$(stat -c%s "$out/squashfs-odd.img.gz")"
