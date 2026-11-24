#!/usr/bin/env bash
# Build tests/fixtures/ext4-inline.img.gz, ext4-metabg.img.gz and their .sha256 lists.
#
# Runs anywhere e2fsprogs is installed (Linux; no root, no mount: mke2fs -d writes the
# tree straight into the image). Each hash list comes from sha256sum over the source
# tree, independent of the image and of any reader of it.
#
# ext4-inline: inline_data, with files and folders held in the inode, one file past the
# 60 bytes of i_block so that its tail is in the system.data attribute.
# ext4-metabg: meta_bg with 64 block groups, more than one block of descriptors holds, so
# the later blocks of descriptors are not beside the first, and files in those later groups.
set -euo pipefail
out=${1:-$(cd "$(dirname "$0")/.." && pwd)/tests/fixtures}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/inline/a/b" "$work/meta/many"
python3 - "$work" <<'PY'
import os, sys
root = sys.argv[1]
def put(rel, data):
    with open(os.path.join(root, rel), "wb") as f:
        f.write(data)
put("inline/top.txt", b"top\n")
put("inline/over60.bin", bytes(range(100)))
put("inline/a/in_a.txt", b"inside a\n")
put("inline/a/b/in_b.txt", b"inside b\n")
for n in range(700):
    put(f"meta/many/f{n:04}.txt", b"file %d\n" % n)
PY
for t in inline meta; do
    (cd "$work/$t" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sed 's|  \./|  |') > "$work/$t.sha256"
done
mke2fs -q -t ext4 -b 1024 -I 256 -N 64 -O inline_data,^has_journal -L inlinefix \
    -d "$work/inline" "$work/ext4-inline.img" 1M
mke2fs -q -t ext4 -b 1024 -g 256 -N 1024 -O meta_bg,^resize_inode,^has_journal,^flex_bg -L metafix \
    -d "$work/meta" "$work/ext4-metabg.img" 16M
e2fsck -fn "$work/ext4-inline.img"
e2fsck -fn "$work/ext4-metabg.img"
cp "$work/inline.sha256" "$out/ext4-inline.sha256"
cp "$work/meta.sha256" "$out/ext4-metabg.sha256"
gzip -9 -n -c "$work/ext4-inline.img" > "$out/ext4-inline.img.gz"
gzip -9 -n -c "$work/ext4-metabg.img" > "$out/ext4-metabg.img.gz"
ls -la "$out"/ext4-inline.* "$out"/ext4-metabg.*
