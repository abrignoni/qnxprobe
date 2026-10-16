#!/usr/bin/env bash
# Build the RAID fixtures in tests/fixtures/raid: member images of Linux md arrays and of
# LVM RAID volumes, each array holding an ext4 filesystem made from a generated tree whose
# sha256 and listing are recorded, plus raid-fixtures.json, what mdadm, lvm2 and the kernel
# said about every array while it was assembled.
#
# Runs on Linux as root. It installs nothing. Needed first:
#   sudo apt install -y mdadm
# and lvm2, gdisk (sgdisk), e2fsprogs (mkfs.ext4, debugfs), util-linux (losetup, partx)
# and python3, which Ubuntu 26.04 has.
#
# Usage: sudo bash make_raid_fixtures.sh [output-folder]
#
# mdadm and lvm2 write every byte of RAID structure; the kernel's md and dm-raid
# personalities write every data and parity byte. The reader is checked against what
# they report, never against itself:
#   - sha256 of each file, from sha256sum over the source tree, independent of any reader
#   - sha256 and size of each assembled array or volume as the kernel presents it
#     (/dev/mdN, /dev/VG/LV), read while it is assembled: the reader's virtual image of
#     the array must hash the same
#   - the kernel's own parity check (sync_action check, then mismatch_cnt, and lvm2's
#     raid_mismatch_count) on every array that has redundancy and all members
#   - mdadm --examine and --detail (text and --export) and the md sysfs attributes
#     (level, layout, chunk size, member offsets and slots), and lvs/pvs as JSON
#
# Everything it touches is inside its own temporary folder (mktemp -d) and the loop
# devices, md arrays and volume groups it made; a trap stops and detaches them. The
# volume group commands use --devicesfile "" so the loop devices stay out of the
# system's LVM devices file. md devices are /dev/md/qp<N> and volume groups qpraid1/2.
# Every child process reads stdin from /dev/null, so nothing can stop for a prompt
# (mdadm --run answers its own questions).
#
# Each array gets members of a few MiB, written by losetup over files in the temporary
# folder. Members are whole disks unless the name says part (a GPT disk whose one
# partition, type fd00, holds the member). Arrays built:
#   md-r5ls-090    RAID5 left-symmetric, metadata 0.90, 4 members
#   md-r1-090      RAID1, metadata 0.90, 2 members
#   md-r1-10       RAID1, metadata 1.0, 2 members of different sizes (4 and 5 MiB)
#   md-r10n2-10    RAID10 near=2, metadata 1.0, 4 members
#   md-r0-11       RAID0, metadata 1.1, 3 members
#   md-r6ls-11     RAID6 left-symmetric, metadata 1.1, 5 members
#   md-linear      linear, metadata 1.2, 3 members of 3, 4 and 5 MiB
#   md-r0          RAID0, metadata 1.2, 3 members
#   md-r0-orig     RAID0 original layout over members of 3, 4 and 6 MiB (two zones)
#   md-r0-alt      RAID0 alternate layout over members of 3, 4 and 6 MiB (two zones)
#   md-r1          RAID1, metadata 1.2, 2 members
#   md-r10n2       RAID10 near=2 over 4, md-r10n2x3 over 3 members
#   md-r10f2       RAID10 far=2 over 4, md-r10f2x3 over 3 members
#   md-r10o2       RAID10 offset=2 over 4, md-r10o2x3 over 3 members
#   md-r10n3       RAID10 near=3 over 4 members
#   md-r4          RAID4, 3 members
#   md-r5-<lay>    RAID5, 4 members, each layout: la ra ls rs parity-first parity-last
#   md-r6-<lay>    RAID6, 5 members, every RAID6 layout mdadm names (14, see R6_LAYOUTS)
#   md-r5-part     RAID5 left-symmetric whose 3 members are partitions on GPT disks
#   md-r1-bitmap   RAID1 with an internal write-intent bitmap, 2 members
#   md-r5-ppl      RAID5 with the partial parity log consistency policy, 3 members
#   md-r5-journal  RAID5 with a write journal on a fourth device, 3 members + journal
# Degraded and stale (kept so a reader must reconstruct or must leave a member out):
#   md-r5-missing   RAID5 created with member 2 of 4 missing: its data was never written
#                   anywhere and is only in the parity
#   md-r6-missing1  RAID6 created with member 1 of 5 given as missing (on both runs so
#                   far, mdadm 4.5 and Linux 7.0 rebuilt the last device into slot 1, so
#                   slot 4 is the one missing; --detail in raid-fixtures.json says which)
#   md-r6-missing2  RAID6 created with members 1 and 3 of 5 missing
#   md-r5-failed    RAID5, 4 members, member 2 failed and removed after mkfs, then
#                   after-fail.bin written with debugfs; all 4 images kept, member 2 stale
#                   (lower event count, missing the new file's chunks)
#   md-r6-failed2   RAID6, 5 members, members 0 and 3 failed the same way; all kept
#   md-r1-stale     RAID1 with a bitmap, 3 members, member 1 failed after mkfs, then
#                   after-fail.bin written; all kept, member 1 stale
# Every md array is built best effort: one that the kernel or mdadm refuses is recorded as
# skipped in raid-fixtures.json with its build log, and the run names it at the end.
# These three are the ones most likely to be refused:
#   md-r5-reshape   RAID5 3 members grown to 4 and stopped with the reshape in progress
#   md-ddf          a DDF container of 3 members (64 MiB) holding a 4 MiB-per-member
#                   RAID5 volume
#   md-imsm         an Intel IMSM container of 2 members (64 MiB) holding a RAID1 volume
#                   (IMSM_NO_PLATFORM=1, there being no Intel RAID controller)
# LVM RAID (dm-raid), each volume best effort like the md arrays, 512 KiB extents, 32 KiB stripes, 256 KiB regions, 3 MiB volumes:
#   lvm-raid-single  one 128 MiB GPT disk with 5 partitions of 24 MiB, each a physical
#                    volume of qpraid1,
#                    volumes r4 (raid4), r5ls r5la r5rs r5ra (raid5_*, 2 data stripes),
#                    r5n (raid5_n), r6zr r6nr r6nc (raid6_*, 3 data stripes),
#                    r10 (raid10, 2 stripes, 2 copies)
#   lvm-raid-multi   5 whole 12 MiB disks, each a physical volume of qpraid2, volumes r5 (raid5,
#                    3 data stripes), r6 (raid6, 3 data stripes), r10 (raid10, 2 stripes,
#                    2 copies)
#
# Output (in the output folder, default tests/fixtures/raid beside this script's repo):
#   <array>-<n>.img.gz   member n, in the order the members were given to mdadm or lvm2
#   raid-fixtures.json   per array: level, metadata, layout, chunk, members (file, sha256,
#                        size, status kept/stale/omitted), device size and sha256, parity
#                        check result, mdadm/lvs output, sysfs attributes, notes
#   raid-trees.sha256    "sha256  <array>/<path>" for every file in every array's tree
#   raid-trees.list      "<array>/<path><TAB><size><TAB><f or d>" for every file and folder
set -euo pipefail
exec </dev/null
[ "$(id -u)" = 0 ] || { echo "run as root (sudo bash $0)"; exit 1; }
for t in mdadm lvcreate sgdisk mkfs.ext4 debugfs losetup partx python3 sha256sum gzip; do
    command -v "$t" >/dev/null || { echo "missing $t (sudo apt install -y mdadm gdisk e2fsprogs lvm2)"; exit 1; }
done
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here/../tests/fixtures/raid}
mkdir -p "$out"
out=$(cd "$out" && pwd)
work=$(mktemp -d /tmp/qp-raid.XXXXXX)
mkdir -p "$work/img" "$work/tree" "$work/meta"
L=(--devicesfile "")
# Every loop device and md device made here is listed in a file, not a variable, so the
# ones made inside a best-effort subshell (try, below) are cleaned up too.
: > "$work/loops.list"   # loop devices
: > "$work/mds.list"     # md devices, in the order made
VGS=()                   # volume groups
cleanup() {
    set +e
    for vg in "${VGS[@]}"; do vgchange "${L[@]}" -q -an "$vg" >/dev/null 2>&1; done
    if [ -f "$work/mds.list" ]; then
        tac "$work/mds.list" | while read -r m; do [ -e "$m" ] && mdadm --stop "$m" >/dev/null 2>&1; done
    fi
    if [ -f "$work/loops.list" ]; then
        # anything that udev assembled from our loops behind our back
        while read -r lp; do
            b=$(basename "$lp")
            for h in /sys/block/"$b"/holders/md* /sys/block/"$b"/"$b"p*/holders/md*; do
                [ -e "$h" ] && mdadm --stop "/dev/$(basename "$h")" >/dev/null 2>&1
            done
        done < "$work/loops.list"
        while read -r lp; do losetup -d "$lp" >/dev/null 2>&1; done < "$work/loops.list"
    fi
    rm -rf "$work"
}
trap cleanup EXIT

# newloop NAME SIZE_MIB [part]: a member image and its loop device; sets NEWDEV to the
# device that holds the member (the loop, or its first partition for part)
newloop() {
    local name=$1 size=$2 kind=${3:-whole} img="$work/img/$1.img" dev
    truncate -s "${size}M" "$img"
    if [ "$kind" = part ]; then
        sgdisk -o -n 1:2048:0 -t 1:fd00 -c 1:qp-member "$img" >/dev/null
        dev=$(losetup -fP --show "$img")
        echo "$dev" >> "$work/loops.list"
        for _ in $(seq 1 40); do [ -b "${dev}p1" ] && break; partx -u "$dev" 2>/dev/null || true; udevadm settle; sleep 0.25; done
        [ -b "${dev}p1" ] || { echo "partition of $dev did not appear" >&2; exit 1; }
        NEWDEV=${dev}p1
    else
        dev=$(losetup -f --show "$img")
        echo "$dev" >> "$work/loops.list"
        NEWDEV=$dev
    fi
}

# newmd: the next md device name, /dev/md/qpN; short, because a 1.x superblock holds
# homehost:name in 32 bytes
newmd() { NEWMD=/dev/md/qp$(wc -l < "$work/mds.list" | tr -d ' '); }

# mktree NAME BYTES: the known tree for one array, sized to the array
mktree() {
    python3 - "$work/tree/$1" "$1" "$2" <<'PY'
import hashlib, os, sys
root, tag, cap = sys.argv[1], sys.argv[2], int(sys.argv[3])
os.makedirs(os.path.join(root, "docs", "deep"), exist_ok=True)
def blocks(n, t):
    # each 4 KiB block names itself, so a block read from the wrong place cannot
    # match; the rest repeats a digest of that name, so the images still compress
    out = bytearray()
    for i in range(n):
        head = f"{t} block {i:08d}\n".encode()
        fill = hashlib.sha256(f"{t}{i}".encode()).hexdigest().encode() * 64
        out += (head + fill)[:4096]
    return bytes(out)
with open(os.path.join(root, "hello.txt"), "w") as f:
    f.write(f"hello from the {tag} array\n")
with open(os.path.join(root, "docs", "notes.txt"), "w") as f:
    f.write(f"{tag}: a file in a folder\n")
with open(os.path.join(root, "docs", "deep", "small.bin"), "wb") as f:
    f.write(blocks(3, tag + "/small")[:10000])
# about 45% of the array, so the file crosses every member and many chunks
with open(os.path.join(root, "blocks.bin"), "wb") as f:
    f.write(blocks(max(16, cap * 45 // 100 // 4096), tag))
PY
}

# afterfile NAME: a file written after members failed, into the tree folder (for the
# listing) and so into the filesystem through debugfs; prints its path
afterfile() {
    python3 - "$work/tree/$1/after-fail.bin" "$1" <<'PY'
import hashlib, sys
out = bytearray()
for i in range(96):
    head = f"{sys.argv[2]} after-fail {i:08d}\n".encode()
    out += (head + hashlib.sha256(f"af{sys.argv[2]}{i}".encode()).hexdigest().encode() * 64)[:4096]
open(sys.argv[1], "wb").write(out)
PY
    echo "$work/tree/$1/after-fail.bin"
}

mdsys() { basename "$(readlink -f "$1")"; }

wait_idle() {
    local s=/sys/block/$1/md
    mdadm --wait "/dev/$1" >/dev/null 2>&1 || true
    [ -e "$s/sync_action" ] || return 0
    for _ in $(seq 1 1200); do [ "$(cat "$s/sync_action")" = idle ] && return 0; sleep 0.1; done
    echo "md $1 did not go idle" >&2; exit 1
}

# mkfs_on NAME DEVICE: ext4 from the array's tree
mkfs_on() {
    local cap
    cap=$(blockdev --getsize64 "$2")
    mktree "$1" "$cap"
    mkfs.ext4 -q -F -O ^has_journal -E nodiscard -L "${1:0:16}" -d "$work/tree/$1" "$2"
}

# record_md NAME DEV MEMBER...: what mdadm, the kernel and sha256sum say, while assembled.
# A member is "file:device:status" with status kept, stale or omitted.
record_md() {
    local name=$1 dev=$2 m=$work/meta/$1 md f d st
    shift 2
    mkdir -p "$m"
    md=$(mdsys "$dev")
    echo md > "$m/kind"
    mdadm --detail "$dev" > "$m/detail.txt" 2>&1 || true
    mdadm --detail --export "$dev" > "$m/detail.export" 2>&1 || true
    blockdev --getsize64 "$dev" > "$m/dev.size"
    # NOHASH=1 for an array whose bytes are moving (a reshape): a hash read then is not
    # known data for anything, so none is recorded
    [ "${NOHASH:-0}" = 1 ] || sha256sum < "$dev" | cut -d' ' -f1 > "$m/dev.sha256"
    {
        for a in level layout chunk_size raid_disks component_size metadata_version \
                 array_state consistency_policy degraded mismatch_cnt reshape_position \
                 reshape_direction bitmap/location bitmap/chunksize bitmap/metadata \
                 new_dev new_level new_layout new_chunk; do
            [ -r "/sys/block/$md/md/$a" ] && printf '%s=%s\n' "$a" "$(tr '\n' ' ' < "/sys/block/$md/md/$a" | sed 's/ *$//')"
        done
        for r in /sys/block/"$md"/md/dev-*; do
            [ -d "$r" ] || continue
            printf '%s=offset:%s slot:%s size:%s state:%s\n' "$(basename "$r")" \
                "$(cat "$r/offset" 2>/dev/null)" "$(cat "$r/slot" 2>/dev/null)" \
                "$(cat "$r/size" 2>/dev/null)" "$(cat "$r/state" 2>/dev/null | tr '\n' ' ')"
        done
    } > "$m/sysfs.txt"
    : > "$m/members.txt"
    for x in "$@"; do
        f=${x%%:*}; d=${x#*:}; st=${d#*:}; d=${d%%:*}
        printf '%s\t%s\t%s\n' "$f" "$d" "$st" >> "$m/members.txt"
        if [ -b "$d" ]; then
            mdadm --examine "$d" > "$m/examine-$f.txt" 2>&1 || true
            mdadm --examine --export "$d" > "$m/examine-$f.export" 2>&1 || true
        fi
    done
    [ -f "$m/notes.txt.tmp" ] && mv "$m/notes.txt.tmp" "$m/notes.txt" || true
}

# parity_check NAME DEV: the kernel's own check of the redundancy, on a full array
parity_check() {
    local md
    md=$(mdsys "$2")
    [ -w "/sys/block/$md/md/sync_action" ] || return 0
    echo check > "/sys/block/$md/md/sync_action"
    sleep 0.2
    wait_idle "$md"
    cat "/sys/block/$md/md/mismatch_cnt" > "$work/meta/$1/mismatch_cnt"
}

# examine_stopped NAME: mdadm --examine on each kept member image after the array stopped,
# which is what the image files hold
examine_stopped() {
    local m=$work/meta/$1 f
    while IFS=$'\t' read -r f _d st; do
        [ "$st" = omitted ] && continue
        mdadm --examine "$work/img/$f.img" > "$m/examine-stopped-$f.txt" 2>&1 || true
        mdadm --examine --export "$work/img/$f.img" > "$m/examine-stopped-$f.export" 2>&1 || true
    done < "$m/members.txt"
}

stop_md() {
    mdadm --stop "$1" >/dev/null
    udevadm settle
}

# mkmd NAME SIZES METADATA LEVEL [mdadm options...]
#   SIZES is a comma list of member sizes in MiB, "x" for a member given as missing,
#   and a trailing "p" on a size for a partitioned member
mkmd() {
    local name=$1 sizes=$2 meta=$3 level=$4 dev i=0 s devs=() mem=()
    shift 4
    newmd; dev=$NEWMD
    mkdir -p "$work/meta/$name"
    IFS=, read -r -a sz <<< "$sizes"
    for s in "${sz[@]}"; do
        if [ "$s" = x ]; then
            devs+=(missing); mem+=("$name-$i:missing:omitted")
        elif [ "${s%p}" != "$s" ]; then
            newloop "$name-$i" "${s%p}" part; devs+=("$NEWDEV"); mem+=("$name-$i:$NEWDEV:kept")
        else
            newloop "$name-$i" "$s"; devs+=("$NEWDEV"); mem+=("$name-$i:$NEWDEV:kept")
        fi
        i=$((i + 1))
    done
    echo "$dev" >> "$work/mds.list"
    mdadm --create "$dev" --run --quiet --homehost=qp --metadata="$meta" --level="$level" \
        --raid-devices="${#devs[@]}" "$@" "${devs[@]}"
    udevadm settle
    wait_idle "$(mdsys "$dev")"
    MEMBERS=("${mem[@]}")
    DEV=$dev
}

# finish_md NAME: record, stop, examine the stopped images
finish_md() {
    record_md "$1" "$DEV" "${MEMBERS[@]}"
    stop_md "$DEV"
    examine_stopped "$1"
}

# full NAME SIZES META LEVEL [opts]: build, fill, check the redundancy, record, stop
full() {
    local name=$1
    mkmd "$@"
    mkfs_on "$name" "$DEV"
    wait_idle "$(mdsys "$DEV")"
    record_md "$name" "$DEV" "${MEMBERS[@]}"
    parity_check "$name" "$DEV"
    stop_md "$DEV"
    examine_stopped "$name"
}

# degraded NAME SIZES META LEVEL [opts]: built with members given as missing
degraded() {
    local name=$1
    mkmd "$@"
    mkfs_on "$name" "$DEV"
    wait_idle "$(mdsys "$DEV")"
    finish_md "$name"
}

# failed NAME "IDX ..." SIZES META LEVEL [opts]: full array, filled and synced, then the
# listed members fail and are removed, then after-fail.bin is written; all images kept
failed() {
    local name=$1 idx=$2 k src stat detail
    shift 2
    mkmd "$name" "$@"
    mkfs_on "$name" "$DEV"
    wait_idle "$(mdsys "$DEV")"
    for k in $idx; do
        d=${MEMBERS[$k]#*:}; d=${d%%:*}
        mdadm "$DEV" --fail "$d" >/dev/null
        udevadm settle
        # md can still be letting go of the failed member; ask again for a while
        for _ in $(seq 1 50); do mdadm "$DEV" --remove "$d" >/dev/null 2>&1 && break; sleep 0.2; done
        detail=$(mdadm --detail "$DEV")
        case $detail in *"$d"*) echo "$d was not removed from $DEV" >&2; exit 1;; esac
        MEMBERS[$k]="$name-$k:$d:stale"
    done
    src=$(afterfile "$name")
    debugfs -w -R "write $src after-fail.bin" "$DEV" >/dev/null 2>&1
    stat=$(debugfs -R "stat after-fail.bin" "$DEV" 2>/dev/null)
    case $stat in *"Size: 393216"*) ;; *) echo "debugfs did not write after-fail.bin on $name" >&2; exit 1;; esac
    sync
    echo "members $idx failed and removed after mkfs; after-fail.bin written after that" \
        > "$work/meta/$name/notes.txt.tmp"
    finish_md "$name"
}

# try NAME COMMAND...: a best-effort build in a subshell; a failure is recorded, not fatal.
# The subshell is not run as a condition, because bash ignores set -e inside a command
# whose status is tested.
try() {
    local name=$1 before rc
    shift
    mkdir -p "$work/meta/$name"
    before=$(wc -l < "$work/mds.list")
    set +e
    ( set -e; "$@" ) > "$work/meta/$name/build.log" 2>&1
    rc=$?
    set -e
    if [ "$rc" != 0 ]; then
        echo skipped > "$work/meta/$name/skipped"
        echo "best-effort $name was not built (see raid-fixtures.json)" >&2
        # stop whatever of it is still assembled, newest first, and drop its images and tree
        tail -n +"$((before + 1))" "$work/mds.list" | tac | while read -r m; do
            [ -e "$m" ] && mdadm --stop "$m" >/dev/null 2>&1 || true
        done
        rm -f "$work/img/$name"-*.img
        rm -rf "$work/tree/$name"
    fi
}

# --- md arrays ---------------------------------------------------------------------
# Each array is built inside try, so one the kernel or mdadm refuses is recorded as
# skipped and the rest are still built; the run ends by naming every skipped one.
t() { try "$2" "$@"; }
t full md-r5ls-090  4,4,4,4  0.90 5 --chunk=32 --layout=left-symmetric --bitmap=none
t full md-r1-090    4,4      0.90 1 --bitmap=none
t full md-r1-10     4,5      1.0  1 --bitmap=none
t full md-r10n2-10  4,4,4,4  1.0  10 --chunk=32 --layout=n2 --bitmap=none
t full md-r0-11     4,4,4    1.1  0 --chunk=32
t full md-r6ls-11   4,4,4,4,4 1.1 6 --chunk=32 --layout=left-symmetric --bitmap=none
t full md-linear    3,4,5    1.2  linear
t full md-r0        4,4,4    1.2  0 --chunk=32
t full md-r0-orig   3,4,6    1.2  0 --chunk=32 --layout=original
t full md-r0-alt    3,4,6    1.2  0 --chunk=32 --layout=alternate
t full md-r1        4,4      1.2  1 --bitmap=none
t full md-r10n2     4,4,4,4  1.2  10 --chunk=32 --layout=n2 --bitmap=none
t full md-r10n2x3   4,4,4    1.2  10 --chunk=32 --layout=n2 --bitmap=none
t full md-r10f2     4,4,4,4  1.2  10 --chunk=32 --layout=f2 --bitmap=none
t full md-r10f2x3   4,4,4    1.2  10 --chunk=32 --layout=f2 --bitmap=none
t full md-r10o2     4,4,4,4  1.2  10 --chunk=32 --layout=o2 --bitmap=none
t full md-r10o2x3   4,4,4    1.2  10 --chunk=32 --layout=o2 --bitmap=none
t full md-r10n3     4,4,4,4  1.2  10 --chunk=32 --layout=n3 --bitmap=none
t full md-r4        4,4,4    1.2  4 --chunk=32 --bitmap=none
for lay in la ra ls rs parity-first parity-last; do
    t full "md-r5-$lay" 4,4,4,4 1.2 5 --chunk=32 --layout="$lay" --bitmap=none
done
R6_LAYOUTS="la ra ls rs parity-first parity-last ddf-zero-restart ddf-N-restart ddf-N-continue
            left-asymmetric-6 right-asymmetric-6 left-symmetric-6 right-symmetric-6 parity-first-6"
for lay in $R6_LAYOUTS; do
    t full "md-r6-$lay" 4,4,4,4,4 1.2 6 --chunk=32 --layout="$lay" --bitmap=none
done
t full md-r5-part   4p,4p,4p 1.2  5 --chunk=32 --bitmap=none
t full md-r1-bitmap 4,4      1.2  1 --bitmap=internal
t full md-r5-ppl    4,4,4    1.2  5 --chunk=32 --bitmap=none --consistency-policy=ppl
# The journal device is a fourth member in its own right, recorded with status journal.
journal_case() {
    newloop md-r5-journal-j 4
    local j=$NEWDEV m=$work/meta/md-r5-journal
    full md-r5-journal 4,4,4 1.2 5 --chunk=32 --bitmap=none --write-journal="$j"
    printf '%s\t%s\t%s\n' md-r5-journal-j "$j" journal >> "$m/members.txt"
    mdadm --examine "$work/img/md-r5-journal-j.img" > "$m/examine-stopped-md-r5-journal-j.txt" 2>&1 || true
    mdadm --examine --export "$work/img/md-r5-journal-j.img" > "$m/examine-stopped-md-r5-journal-j.export" 2>&1 || true
}
try md-r5-journal journal_case

t degraded md-r5-missing  4,4,x,4   1.2 5 --chunk=32 --bitmap=none
t degraded md-r6-missing1 4,x,4,4,4 1.2 6 --chunk=32 --bitmap=none
t degraded md-r6-missing2 4,x,4,x,4 1.2 6 --chunk=32 --bitmap=none
t failed md-r5-failed  "2"   4,4,4,4   1.2 5 --chunk=32 --bitmap=none
t failed md-r6-failed2 "0 3" 4,4,4,4,4 1.2 6 --chunk=32 --bitmap=none
t failed md-r1-stale   "1"   4,4,4     1.2 1 --bitmap=internal

# A reshape stopped half way: the grow is slowed to a crawl so it is still running when
# the array stops, and md keeps reshape_position in the superblock.
reshape() {
    mkmd md-r5-reshape 8,8,8 1.2 5 --chunk=32 --bitmap=none
    mkfs_on md-r5-reshape "$DEV"
    wait_idle "$(mdsys "$DEV")"
    local md
    md=$(mdsys "$DEV")
    echo 1 > "/sys/block/$md/md/sync_speed_min"
    echo 1 > "/sys/block/$md/md/sync_speed_max"
    newloop md-r5-reshape-3 8
    mdadm "$DEV" --add "$NEWDEV" >/dev/null
    MEMBERS+=("md-r5-reshape-3:$NEWDEV:kept")
    mdadm --grow "$DEV" --raid-devices=4 --backup-file="$work/reshape.backup"
    sleep 3
    grep -q reshape "/sys/block/$md/md/sync_action" || [ "$(cat "/sys/block/$md/md/reshape_position")" != none ] \
        || { echo "no reshape in progress"; exit 1; }
    echo "grown from 3 to 4 members and stopped during the reshape (the sysfs speed limit asked for 1 KiB/s; the reshape may run faster); the grow used a backup file that is not kept; no device hash, since the bytes were moving" \
        > "$work/meta/md-r5-reshape/notes.txt.tmp"
    NOHASH=1 finish_md md-r5-reshape
}
try md-r5-reshape reshape

# External metadata: a container, then a volume inside it (mdmon runs the volume).
external() {
    local name=$1 meta=$2 n=$3 vlevel=$4 i devs=() mem=() cdev vdev
    # DDF and IMSM keep their metadata in the last MiBs of each disk
    for ((i = 0; i < n; i++)); do
        newloop "$name-$i" 64; devs+=("$NEWDEV"); mem+=("$name-$i:$NEWDEV:kept")
    done
    newmd; cdev=$NEWMD; echo "$cdev" >> "$work/mds.list"
    mdadm --create "$cdev" --run --quiet --metadata="$meta" --raid-devices="$n" "${devs[@]}"
    newmd; vdev=$NEWMD; echo "$vdev" >> "$work/mds.list"
    mdadm --create "$vdev" --run --quiet --level="$vlevel" --raid-devices="$n" --size=4M "$cdev"
    udevadm settle
    wait_idle "$(mdsys "$vdev")"
    mkfs_on "$name" "$vdev"
    wait_idle "$(mdsys "$vdev")"
    MEMBERS=("${mem[@]}")
    record_md "$name" "$vdev" "${MEMBERS[@]}"
    mdadm --detail "$cdev" > "$work/meta/$name/container-detail.txt" 2>&1 || true
    mdadm --stop "$vdev" >/dev/null
    mdadm --stop "$cdev" >/dev/null
    udevadm settle
    examine_stopped "$name"
}
try md-ddf external md-ddf ddf 3 5
export IMSM_NO_PLATFORM=1
try md-imsm external md-imsm imsm 2 1
unset IMSM_NO_PLATFORM

# --- LVM RAID ------------------------------------------------------------------------
wait_lv() {
    for _ in $(seq 1 600); do
        [ "$(lvs "${L[@]}" --noheadings -o sync_percent "$1" | tr -d ' ')" = 100.00 ] && return 0
        sleep 0.2
    done
    echo "$1 did not sync" >&2; exit 1
}

# lvraid VG NAME TYPE ARGS...: a RAID volume, synced, filled, checked
lvraid() {
    local vg=$1 lv=$2 type=$3 name="$4" dev
    shift 4
    lvcreate "${L[@]}" -q -y -W n -Z n --type "$type" "$@" -I 32k -R 256k -n "$lv" "$vg"
    udevadm settle
    wait_lv "$vg/$lv"
    dev=/dev/$vg/$lv
    mkdir -p "$work/meta/$name"
    mkfs_on "$name" "$dev"
    lvchange "${L[@]}" -q --syncaction check "$vg/$lv"
    sleep 0.3
    wait_lv "$vg/$lv"
    for _ in $(seq 1 600); do
        [ "$(lvs "${L[@]}" --noheadings -o raid_sync_action "$vg/$lv" | tr -d ' ')" = idle ] && break
        sleep 0.2
    done
    lvs "${L[@]}" --noheadings -o raid_mismatch_count "$vg/$lv" | tr -d ' ' > "$work/meta/$name/mismatch_cnt"
    echo lvm > "$work/meta/$name/kind"
    echo "$vg/$lv" > "$work/meta/$name/lv"
    blockdev --getsize64 "$dev" > "$work/meta/$name/dev.size"
    sha256sum < "$dev" | cut -d' ' -f1 > "$work/meta/$name/dev.sha256"
}

# try_lv VG LV TYPE NAME ARGS...: lvraid as best effort, like try for md arrays
try_lv() { try "$4" lvraid "$@"; }

lvm_report() {
    local vg=$1 f=$2
    {
        echo '{"pvs":'
        pvs "${L[@]}" --reportformat json --units b -o pv_name,pv_uuid,pe_start,pv_size,vg_name -S "vg_name=$vg"
        echo ',"segments":'
        lvs "${L[@]}" --reportformat json --units b --segments -a \
            -o vg_name,lv_name,lv_uuid,lv_attr,lv_layout,seg_start_pe,seg_size_pe,segtype,stripes,stripe_size,data_stripes,data_copies,data_offset,reshape_len,region_size,seg_pe_ranges,devices,vg_extent_size,raid_mismatch_count,sync_percent "$vg"
        echo '}'
    } > "$f"
}

# One disk, five partitions, each a physical volume
single=$work/img/lvm-raid-single-0.img
truncate -s 128M "$single"
sgdisk -o -n 1:2048:+24M -t 1:8e00 -n 2:0:+24M -t 2:8e00 -n 3:0:+24M -t 3:8e00 \
       -n 4:0:+24M -t 4:8e00 -n 5:0:+24M -t 5:8e00 "$single" >/dev/null
sdisk=$(losetup -fP --show "$single")
echo "$sdisk" >> "$work/loops.list"
for _ in $(seq 1 40); do [ -b "${sdisk}p5" ] && break; partx -u "$sdisk" 2>/dev/null || true; udevadm settle; sleep 0.25; done
[ -b "${sdisk}p5" ] || { echo "partitions of $sdisk did not appear"; exit 1; }
pvcreate "${L[@]}" -q "${sdisk}p1" "${sdisk}p2" "${sdisk}p3" "${sdisk}p4" "${sdisk}p5"
vgcreate "${L[@]}" -q -s 512k qpraid1 "${sdisk}p1" "${sdisk}p2" "${sdisk}p3" "${sdisk}p4" "${sdisk}p5"
VGS+=(qpraid1)
try_lv qpraid1 r4   raid4    lvm-raid-single-r4   -i 2 -L 3M
try_lv qpraid1 r5ls raid5_ls lvm-raid-single-r5ls -i 2 -L 3M
try_lv qpraid1 r5la raid5_la lvm-raid-single-r5la -i 2 -L 3M
try_lv qpraid1 r5rs raid5_rs lvm-raid-single-r5rs -i 2 -L 3M
try_lv qpraid1 r5ra raid5_ra lvm-raid-single-r5ra -i 2 -L 3M
try_lv qpraid1 r5n  raid5_n  lvm-raid-single-r5n  -i 2 -L 3M
try_lv qpraid1 r6zr raid6_zr lvm-raid-single-r6zr -i 3 -L 3M
try_lv qpraid1 r6nr raid6_nr lvm-raid-single-r6nr -i 3 -L 3M
try_lv qpraid1 r6nc raid6_nc lvm-raid-single-r6nc -i 3 -L 3M
try_lv qpraid1 r10  raid10   lvm-raid-single-r10  -i 2 -m 1 -L 3M
lvm_report qpraid1 "$work/meta/lvm-raid-single.lvs.json"
sfdisk --json "$single" > "$work/meta/lvm-raid-single.parts.json"
vgchange "${L[@]}" -q -an qpraid1
udevadm settle

# Five whole disks, each a physical volume
mdisks=()
for i in 0 1 2 3 4; do
    f=$work/img/lvm-raid-multi-$i.img
    truncate -s 12M "$f"
    d=$(losetup -f --show "$f"); echo "$d" >> "$work/loops.list"; mdisks+=("$d")
done
pvcreate "${L[@]}" -q "${mdisks[@]}"
vgcreate "${L[@]}" -q -s 512k qpraid2 "${mdisks[@]}"
VGS+=(qpraid2)
try_lv qpraid2 r5  raid5  lvm-raid-multi-r5  -i 3 -L 3M
try_lv qpraid2 r6  raid6  lvm-raid-multi-r6  -i 3 -L 3M
try_lv qpraid2 r10 raid10 lvm-raid-multi-r10 -i 2 -m 1 -L 3M
lvm_report qpraid2 "$work/meta/lvm-raid-multi.lvs.json"
printf '%s\n' "${mdisks[@]}" > "$work/meta/lvm-raid-multi.loops"
vgchange "${L[@]}" -q -an qpraid2
udevadm settle

# --- nothing of ours may still be assembled ---------------------------------------
while read -r lp; do
    b=$(basename "$lp")
    for h in /sys/block/"$b"/holders/* /sys/block/"$b"/"$b"p*/holders/*; do
        [ -e "$h" ] && { echo "$(basename "$h") still holds $lp"; exit 1; }
    done
done < "$work/loops.list"

# --- known data and the manifest -----------------------------------------------------
(cd "$work/tree" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sed 's|  \./|  |') > "$out/raid-trees.sha256"
(cd "$work/tree" && find . -mindepth 2 \( -type f -o -type d \) -printf '%P\t%s\t%y\n' | sort) > "$out/raid-trees.list"
for f in "$work"/img/*.img; do sha256sum "$f"; done | sed "s|  $work/img/|  |" > "$work/meta/images.sha256"

python3 - "$work/meta" "$work/img" "$out/raid-fixtures.json" <<'PY'
import json, os, platform, subprocess, sys
meta, img, dest = sys.argv[1:]
def rd(p):
    try:
        with open(p, encoding="utf-8", errors="replace") as f:
            return f.read()
    except FileNotFoundError:
        return None
def kv(text):
    out = {}
    for line in (text or "").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out
hashes = {}
for line in rd(os.path.join(meta, "images.sha256")).splitlines():
    h, n = line.split("  ", 1)
    hashes[n[:-4]] = h
def ver(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, stdin=subprocess.DEVNULL).stdout.strip() \
            or subprocess.run(cmd, capture_output=True, text=True, stdin=subprocess.DEVNULL).stderr.strip()
    except OSError:
        return None
doc = {"host": {"kernel": platform.release(), "machine": platform.machine(),
                "byteorder": sys.byteorder,
                "mdadm": ver(["mdadm", "--version"]),
                "lvm": ver(["lvm", "version"]),
                "mke2fs": ver(["mke2fs", "-V"])},
       "arrays": {}, "lvm": {}}
for name in sorted(os.listdir(meta)):
    d = os.path.join(meta, name)
    if not os.path.isdir(d):
        continue
    a = {"kind": (rd(os.path.join(d, "kind")) or "").strip() or None}
    if os.path.exists(os.path.join(d, "skipped")):
        a["skipped"] = True
        a["build_log"] = rd(os.path.join(d, "build.log"))
        doc["arrays"][name] = a
        continue
    a["notes"] = (rd(os.path.join(d, "notes.txt")) or "").strip() or None
    a["device_size"] = int(rd(os.path.join(d, "dev.size")))
    h = rd(os.path.join(d, "dev.sha256"))
    a["device_sha256"] = h.strip() if h else None
    mm = rd(os.path.join(d, "mismatch_cnt"))
    a["parity_check_mismatch_cnt"] = int(mm) if mm and mm.strip().isdigit() else None
    if a["kind"] == "md":
        a["detail"] = rd(os.path.join(d, "detail.txt"))
        a["detail_export"] = kv(rd(os.path.join(d, "detail.export")))
        a["sysfs"] = kv(rd(os.path.join(d, "sysfs.txt")))
        a["container_detail"] = rd(os.path.join(d, "container-detail.txt"))
        a["members"] = []
        for line in rd(os.path.join(d, "members.txt")).splitlines():
            f, dev, st = line.split("\t")
            m = {"file": None if st == "omitted" else f + ".img.gz", "name": f,
                 "loop": dev, "status": st}
            if st != "omitted":
                m["sha256"] = hashes[f]
                m["size"] = os.path.getsize(os.path.join(img, f + ".img"))
                m["examine_assembled"] = rd(os.path.join(d, f"examine-{f}.txt"))
                m["examine_assembled_export"] = kv(rd(os.path.join(d, f"examine-{f}.export")))
                m["examine"] = rd(os.path.join(d, f"examine-stopped-{f}.txt"))
                m["examine_export"] = kv(rd(os.path.join(d, f"examine-stopped-{f}.export")))
            a["members"].append(m)
    else:
        a["lv"] = rd(os.path.join(d, "lv")).strip()
    doc["arrays"][name] = a
for group in ("lvm-raid-single", "lvm-raid-multi"):
    g = {"report": json.loads(rd(os.path.join(meta, group + ".lvs.json")))}
    p = rd(os.path.join(meta, group + ".parts.json"))
    if p:
        g["parts"] = json.loads(p)
    loops = rd(os.path.join(meta, group + ".loops"))
    g["images"] = [{"file": n + ".img.gz", "sha256": h,
                    "size": os.path.getsize(os.path.join(img, n + ".img"))}
                   for n, h in sorted(hashes.items()) if n.startswith(group + "-")]
    if loops:
        g["loops"] = loops.split()
    doc["lvm"][group] = g
with open(dest, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=1, sort_keys=True)
    f.write("\n")
PY

for f in "$work"/img/*.img; do
    gzip -9 -n -c "$f" > "$out/$(basename "$f").gz"
done
chmod a+r "$out"/*
[ -n "${SUDO_UID:-}" ] && chown -R "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$out"
grep -l '"skipped": true' "$out/raid-fixtures.json" >/dev/null && \
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("skipped:", [k for k,v in d["arrays"].items() if v.get("skipped")])' "$out/raid-fixtures.json"
echo "$(ls "$out"/*.img.gz | wc -l) member images, $(du -sh "$out" | cut -f1) in $out"
