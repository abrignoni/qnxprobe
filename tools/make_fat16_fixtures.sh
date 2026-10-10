#!/bin/bash
# Build the FAT16 and FAT12 images the self-test reads.
#
#   fat16-fixture   a FAT16 volume as macOS formats one: 512-byte sectors.
#   fat12-fixture   a FAT12 volume as macOS formats one.
#   tfat16-fixture  a FAT16 volume with 2,048-byte sectors and 8,192-byte
#                   clusters whose files all sit under a root folder named
#                   __TFAT_HIDDEN_ROOT_DIR__, with the type string "TFAT16  ".
#                   That is the layout measured on volumes Windows CE wrote as
#                   transaction-safe FAT. macOS wrote this one, and it stands in
#                   for the layout and the type string, not for Windows CE's
#                   driver. macOS will not mount a FAT volume whose sectors are
#                   larger than the device's, so it is formatted with 512-byte
#                   sectors and every sector count a multiple of four (4
#                   reserved, 24 per table, a 32-sector root, 16 per cluster),
#                   and once macOS has unmounted it this script rewrites the
#                   boot sector's counts in 2,048-byte units and its type
#                   string. No byte outside the boot sector changes, so the
#                   tables, directories and file data are as macOS wrote them.
#
# Each carries live files (a long name, a file of several clusters, an empty
# file, a file in a nested folder, a fragmented file) and files created and then
# deleted. Live content is hashed from the mounted volume into <stem>.sha256 and
# deleted content is hashed before deletion into <stem>.deleted.sha256, so the
# expected answers come from what was written.
#
# Runs on macOS (hdiutil, newfs_msdos through -fsargs).
#
#     bash tools/make_fat16_fixtures.sh /tmp/out
set -euo pipefail
OUT=${1:-.}

pattern() {  # pattern <bytes> <seed> <file>: repeatable bytes that are not all one value
  python3 -c 'import sys,hashlib
n,seed,path=int(sys.argv[1]),sys.argv[2].encode(),sys.argv[3]
out=bytearray(); i=0
while len(out)<n:
    out+=hashlib.sha256(seed+i.to_bytes(4,"little")).digest(); i+=1
open(path,"wb").write(bytes(out[:n]))' "$1" "$2" "$3"
}

build() {  # build <size> <fsargs> <label> <stem> <folder under the root, or "">
  local size="$1" fsargs="$2" label="$3" stem="$4" sub="$5"
  local img="$OUT/$stem.img"
  rm -f "$img.dmg"
  hdiutil create -size "$size" -fs "MS-DOS" -fsargs "$fsargs" -volname "$label" -layout NONE "$img.dmg" -quiet
  hdiutil attach "$img.dmg" -nobrowse -quiet; sleep 1
  local V="/Volumes/$label" R
  R="$V"
  if [ -n "$sub" ]; then mkdir "$V/$sub"; R="$V/$sub"; fi
  printf 'a FAT16 volume built for the qnxprobe self-test\n' > "$R/readme.txt"
  pattern 300 long "$R/a long file name with spaces.txt"
  : > "$R/empty.dat"
  mkdir -p "$R/logs/deep"
  pattern 70000 several "$R/logs/several-clusters.bin"
  pattern 5000 inner "$R/logs/deep/inner.bin"
  # three fillers, the middle one removed, then a file into the hole and beyond
  for n in a b c; do pattern 20000 "filler-$n" "$R/$n.bin"; done; sync
  rm -f "$R/b.bin"; sync
  pattern 90000 fragmented "$R/fragmented.bin"; sync
  # files that will be deleted, hashed first
  mkdir "$R/gone"
  pattern 9000 one "$R/gone/one.bin"
  pattern 30000 two "$R/gone/two.bin"
  pattern 12000 alone "$R/deleted-alone.bin"; sync
  : > "$OUT/$stem.deleted.sha256"
  for f in gone/one.bin gone/two.bin deleted-alone.bin; do
    printf '%s  %s\n' "$(shasum -a256 "$R/$f" | cut -d' ' -f1)" "$f" >> "$OUT/$stem.deleted.sha256"
  done
  rm -rf "$R/gone" "$R/deleted-alone.bin"; sync; sleep 1
  ( cd "$V" && find . -type f ! -path './.fseventsd/*' ! -name '._*' -print0 | sort -z \
      | xargs -0 shasum -a256 | sed 's|  \./|  |' ) > "$OUT/$stem.sha256"
  hdiutil detach "$V" -quiet
  if [ -n "$sub" ]; then
    python3 -c 'import struct,sys
p=sys.argv[1]; b=bytearray(open(p,"rb").read())
u16=lambda o: struct.unpack_from("<H",b,o)[0]
u32=lambda o: struct.unpack_from("<I",b,o)[0]
assert b[54:62]==b"FAT16   ", bytes(b[54:62])
bps,spc,res,spf,tot16,tot32,hid,spt=u16(11),b[13],u16(14),u16(22),u16(19),u32(32),u32(28),u16(24)
assert bps==512 and spc==16 and res%4==0 and spf%4==0 and (u16(17)*32)%2048==0, (bps,spc,res,spf,u16(17))
assert tot16%4==0 and tot32%4==0 and hid%4==0, (tot16,tot32,hid)
struct.pack_into("<H",b,11,2048); b[13]=spc//4
struct.pack_into("<H",b,14,res//4); struct.pack_into("<H",b,22,spf//4)
struct.pack_into("<H",b,19,tot16//4); struct.pack_into("<I",b,32,tot32//4)
struct.pack_into("<I",b,28,hid//4)
b[54:62]=b"TFAT16  "
open(p,"wb").write(bytes(b))' "$img.dmg"
  fi
  gzip -9 -n -c "$img.dmg" > "$OUT/$stem.img.gz"; rm -f "$img.dmg"
  echo "wrote $OUT/$stem.img.gz, $OUT/$stem.sha256 and $OUT/$stem.deleted.sha256"
}

build 16m "-F 16"            FAT16FIX  fat16-fixture  ""
build 4m  "-F 12"            FAT12FIX  fat12-fixture  ""
build 40m "-F 16 -c 16 -r 4 -e 512 -a 24" TFAT16FIX tfat16-fixture "__TFAT_HIDDEN_ROOT_DIR__"
