#!/usr/bin/env bash
# Build tests/fixtures/squashfs-deep.img.gz and squashfs-deep.src.sha256, the
# list the self-test checks it against.
#
# Runs on Linux with squashfs-tools installed (no root, no mount). The tree is
# one chain of folders 70 levels deep, L00/L01/.../L69, with one small file at
# each level, so a walk that stops at a fixed depth comes back short of the 70
# files. Its deepest path is 300 bytes, well inside what Linux takes.
#
# squashfs-deep.src.sha256 is sha256sum over the source tree, one line per
# file. Before anything is written the image is extracted with unsquashfs and
# hashed against that list, so a fixture squashfs-tools itself cannot read
# back never reaches the repository.
set -euo pipefail

out=${1:-$(cd "$(dirname "$0")/.." && pwd)/tests/fixtures}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
src=$work/src

python3 - "$src" <<'PY'
import os, sys
path = sys.argv[1]
for level in range(70):
    path = os.path.join(path, f"L{level:02d}")
    os.makedirs(path)
    with open(os.path.join(path, f"file_at_level_{level:02d}.txt"), "wb") as fh:
        fh.write(b"level %d\n" % level)
PY
find "$src" -exec touch -h -d '2023-11-14 22:13:20 UTC' {} +

( cd "$src" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sed 's|  \./|  |' ) \
    > "$work/squashfs-deep.src.sha256"

mksquashfs "$src" "$work/deep.img" -noappend -quiet -no-progress -all-root \
    -mkfs-time 1700000000 >/dev/null
unsquashfs -q -n -d "$work/x" "$work/deep.img" >/dev/null 2>&1 || true
( cd "$work/x" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sed 's|  \./|  |' ) \
    > "$work/deep.check"
if ! diff -q "$work/squashfs-deep.src.sha256" "$work/deep.check" >/dev/null; then
    echo "unsquashfs does not read the image back as the source tree" >&2
    diff "$work/squashfs-deep.src.sha256" "$work/deep.check" | head >&2
    exit 1
fi

gzip -9 -n -c "$work/deep.img" > "$out/squashfs-deep.img.gz"
cp "$work/squashfs-deep.src.sha256" "$out/squashfs-deep.src.sha256"
printf 'deep %8d bytes, %7d gzipped, %d files\n' "$(stat -c%s "$work/deep.img")" \
    "$(stat -c%s "$out/squashfs-deep.img.gz")" "$(wc -l < "$out/squashfs-deep.src.sha256")"
