#!/usr/bin/env bash
# Build tests/fixtures/lvm-fixture.img.gz, lvm-wholedisk.img.gz, lvm-fixture.lvs.json and
# lvm-fixture.sha256.
#
# Runs on Linux as root with lvm2, gdisk and e2fsprogs (loop devices and device-mapper).
# lvm2's own tools write every byte of LVM structure, and lvm2's own report (lvs, pvs)
# is saved beside the images as the known layout the reader is checked against. The
# file hashes come from sha256sum over the source trees, independent of any reader.
# --devicesfile "" keeps the loop devices out of the system's LVM devices file.
#
# lvm-fixture.img, 64 MiB, GPT with two LVM partitions, volume group fixvg, 1 MiB extents:
#   root     6 MiB, linear, one run on partition 1, ext4 holding tree/root
#   data     3 MiB then +3 MiB after gap was made, so two runs with gap between them
#   gap      2 MiB, linear, between data's two runs
#   onb      4 MiB, linear, on partition 2, ext4 holding tree/onb
#   striped  4 MiB, striped across both partitions
#   grow     2 MiB then +2 MiB straight after it, on partition 1
#   mirror   2 MiB, raid1 across both partitions, whose image and metadata legs are
#            hidden internal volumes
# lvm-wholedisk.img, 16 MiB, no partition table, the whole disk one PV whose extents start
# 3 MiB in (--dataalignment 3m, so pe_start differs from the 1 MiB extent size), volume
# group wholevg with one linear volume, root, ext4 holding tree/root.
set -euo pipefail
out=${1:-$(cd "$(dirname "$0")/.." && pwd)/tests/fixtures}
work=$(mktemp -d)
L=(--devicesfile "")
cleanup() {
    vgchange "${L[@]}" -an fixvg >/dev/null 2>&1 || true
    vgchange "${L[@]}" -an wholevg >/dev/null 2>&1 || true
    [ -n "${disk:-}" ] && losetup -d "$disk" 2>/dev/null || true
    [ -n "${whole:-}" ] && losetup -d "$whole" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$work/tree/root/etc" "$work/tree/root/var/log" "$work/tree/onb/docs"
python3 - "$work/tree" <<'PY'
import os, random, sys
os.chdir(sys.argv[1])
rnd = random.Random(64)
def blob(n): return bytes(rnd.getrandbits(8) for _ in range(n))
open('root/etc/os-release', 'w').write('NAME="Fixture Linux"\nVERSION_ID="1"\n')
open('root/etc/hostname', 'w').write('lvm-fixture\n')
open('root/var/log/syslog', 'wb').write(blob(200 * 1024 + 7))
open('root/hello.txt', 'w').write('hello from a logical volume\n')
open('onb/docs/notes.txt', 'w').write('this volume lives on the second physical volume\n')
open('onb/docs/data.bin', 'wb').write(blob(700 * 1024 + 3))
PY
(cd "$work/tree" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sed 's|  \./|  |') > "$out/lvm-fixture.sha256"

truncate -s 64M "$work/lvm-fixture.img"
sgdisk -o -n 1:2048:+24M -t 1:8e00 -c 1:lvm-a -n 2:0:+20M -t 2:8e00 -c 2:lvm-b "$work/lvm-fixture.img" >/dev/null
sgdisk -p "$work/lvm-fixture.img" | grep -q lvm-b || { echo "sgdisk wrote no partitions"; exit 1; }
disk=$(losetup -fP --show "$work/lvm-fixture.img")
a=${disk}p1; b=${disk}p2
for _ in $(seq 1 40); do [ -b "$a" ] && [ -b "$b" ] && break; partx -u "$disk" 2>/dev/null || true; udevadm settle; sleep 0.25; done
[ -b "$a" ] && [ -b "$b" ] || { echo "partition devices for $disk did not appear"; exit 1; }
pvcreate "${L[@]}" -q "$a" "$b"
vgcreate "${L[@]}" -q -s 1M fixvg "$a" "$b"
lvcreate "${L[@]}" -q -y -W n -Z n -L 6M -n root fixvg "$a"
lvcreate "${L[@]}" -q -y -W n -Z n -L 3M -n data fixvg "$a"
lvcreate "${L[@]}" -q -y -W n -Z n -L 2M -n gap fixvg "$a"
lvextend "${L[@]}" -q -L +3M fixvg/data "$a"
lvcreate "${L[@]}" -q -y -W n -Z n -L 4M -n onb fixvg "$b"
lvcreate "${L[@]}" -q -y -W n -Z n -i 2 -I 64k -L 4M -n striped fixvg "$a" "$b"
lvcreate "${L[@]}" -q -y -W n -Z n -L 2M -n grow fixvg "$a"
lvextend "${L[@]}" -q -L +2M fixvg/grow "$a"
lvcreate "${L[@]}" -q -y -W n -Z n --type raid1 -m 1 -L 2M -n mirror fixvg "$a" "$b"
udevadm settle
mkfs.ext4 -q -L rootfix -d "$work/tree/root" /dev/fixvg/root
mkfs.ext4 -q -L onbfix -d "$work/tree/onb" /dev/fixvg/onb
mkfs.ext4 -q -L datafix /dev/fixvg/data
{
  echo '{"pvs":'
  pvs "${L[@]}" --reportformat json --units b -o pv_name,pv_uuid,pe_start,vg_name
  echo ',"segments":'
  lvs "${L[@]}" --reportformat json --units b --segments \
      -a -o vg_name,lv_name,lv_attr,seg_start_pe,seg_size_pe,segtype,stripes,seg_pe_ranges,vg_extent_size fixvg
  echo ',"parts":'
  sfdisk --json "$work/lvm-fixture.img"
  echo '}'
} | python3 -c 'import json,sys; d=json.load(sys.stdin); d["loop"]=sys.argv[1]; print(json.dumps(d, indent=1))' "$disk" \
  > "$out/lvm-fixture.lvs.json"
vgchange "${L[@]}" -q -an fixvg
losetup -d "$disk"; disk=

truncate -s 16M "$work/lvm-wholedisk.img"
whole=$(losetup -f --show "$work/lvm-wholedisk.img")
pvcreate "${L[@]}" -q --dataalignment 3m "$whole"
vgcreate "${L[@]}" -q -s 1M wholevg "$whole"
lvcreate "${L[@]}" -q -y -W n -Z n -L 8M -n root wholevg
udevadm settle
mkfs.ext4 -q -L wholefix -d "$work/tree/root" /dev/wholevg/root
pvs "${L[@]}" --reportformat json --units b -o pv_name,pe_start,vg_name "$whole" > "$work/whole.pvs.json"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps({"pvs": d}, indent=1))' "$work/whole.pvs.json" > "$out/lvm-wholedisk.pvs.json"
vgchange "${L[@]}" -q -an wholevg
losetup -d "$whole"; whole=

gzip -9 -c "$work/lvm-fixture.img" > "$out/lvm-fixture.img.gz"
gzip -9 -c "$work/lvm-wholedisk.img" > "$out/lvm-wholedisk.img.gz"
ls -la "$out"/lvm-*
