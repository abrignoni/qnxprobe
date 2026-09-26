#!/bin/bash
# Build the NTFS image qnxprobe's self-test reads alternate data streams from,
# and record what went into it.
#
# Runs on Linux with ntfs-3g, ntfsprogs and The Sleuth Kit. ntfs-3g mounts a
# plain image file through FUSE, so no loop device is needed. mkntfs writes the
# filesystem and ntfs-3g writes the content, so neither the image nor the
# expected answers come from the reader they are used to test.
#
# A second image rather than more files in ntfs-fixture.img: that one's record
# numbers, dates and free clusters are pinned by the self-test, and writing into
# it would move them and could reuse the clusters of the deleted files it keeps.
#
# Three statements of the same truth have to agree: what this script meant to
# write, what ntfs-3g reads back from the finished image, and what The Sleuth
# Kit's fls, istat and icat find in it. The run fails if they disagree. The
# fourth, what qnxprobe finds, is the self-test.
#
# Each stream is one shape a Windows volume holds:
#   downloads/*:Zone.Identifier   the Mark of the Web, resident, CRLF text
#   big.bin:payload               non-resident
#   journal.bin:$J                a hole at the front and records after it, in
#                                 hundreds of runs that overflow into a second
#                                 record: the shape of $Extend/$UsnJrnl:$J, beside
#                                 a $Max
#   hollow.bin:nothing-stored     sized and never written, so every cluster is
#                                 sparse: the shape of $BadClus:$Bad
#   holey.bin:holey               a hole in the middle, which is content
#   empty.txt:empty               a stream of no bytes
#   folder:dirstream              a stream on a directory
#   :rootstream                   a stream on the root directory
#   comp/packed.txt:packed        LZNT1 compressed
#   comp/packed.txt:late          LZNT1 compressed, after a hole at the front
#   linked_a.txt:tag              one file, two names, so the stream is listed twice
#   manystreams.txt:s1..s12       enough streams that some move to other records
#   notes.txt:ünïcödé             a stream name that needs UTF-16
#
# The manifest, tests/fixtures/ntfs-streams.sha256, names every $DATA stream fls
# reports that holds at least one stored cluster, as "path:stream", with the
# sha256 of its bytes from the first stored cluster on. That is the rule the
# reader follows: a hole at the front of a stream is not read, and a stream that
# is all hole is not listed. The skip is counted from istat's cluster list, where
# a sparse cluster prints as 0 (and from ntfsinfo's run list for $BadClus:$Bad,
# which istat prints no clusters for), and icat supplies the bytes.
#
#     bash tools/make_ntfs_streams_fixture.sh /tmp/ntfs-streams.img 8
set -euo pipefail

IMG=${1:-ntfs-streams.img}
MIB=${2:-8}
CLUSTER=4096
MNT=$(mktemp -d)
OUT=$(dirname "$IMG")

cleanup() { mountpoint -q "$MNT" && fusermount3 -u "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT

rm -f "$IMG"
dd if=/dev/zero of="$IMG" bs=1M count="$MIB" status=none
mkntfs -F -f -Q -L STREAMS -s 512 -c "$CLUSTER" "$IMG" >/dev/null 2>&1
ntfs-3g -o streams_interface=windows "$IMG" "$MNT"

# The writer. Each stream's intended content is recorded as it is written, as
# "<sha256 of every byte>\t<bytes of hole at the front>\t<path:stream>", so the
# expected answer comes from what was meant rather than from any reader.
python3 - "$MNT" "$OUT/streams.intended" <<'PY'
import hashlib, os, struct, sys
mnt, intended = sys.argv[1], sys.argv[2]
rows = []

def lines(text, size):
    return ((text + "\n") * (size // (len(text) + 1) + 1))[:size].encode()

def put(path, stream, data=b"", hole=0, truncate=None, tail=None):
    """Write one stream: hole bytes of nothing, then data, then optionally
    another hole and tail. truncate sizes a stream without writing it."""
    target = os.path.join(mnt, path) + ":" + stream
    with open(target, "wb") as fh:
        if truncate is not None:
            fh.truncate(truncate)
            full = b"\0" * truncate
        else:
            fh.seek(hole)
            fh.write(data)
            full = b"\0" * hole + data
            if tail is not None:
                gap, more = tail
                fh.seek(len(full) + gap)
                fh.write(more)
                full += b"\0" * gap + more
    shown = ":" + stream if path in (".", "") else f"{path}:{stream}"
    rows.append(f"{hashlib.sha256(full).hexdigest()}\t{hole}\t{shown}")

def plain(path, data):
    with open(os.path.join(mnt, path), "wb") as fh:
        fh.write(data)

os.makedirs(os.path.join(mnt, "downloads"))
plain("downloads/setup.exe", b"MZ" + lines("not a real installer", 3000))
put("downloads/setup.exe", "Zone.Identifier",
    b"[ZoneTransfer]\r\nZoneId=3\r\nReferrerUrl=https://example.com/downloads\r\n"
    b"HostUrl=https://example.com/files/setup.exe\r\n")
plain("downloads/report.pdf", b"%PDF-1.4\n" + lines("not a real pdf", 1500))
put("downloads/report.pdf", "Zone.Identifier",
    b"[ZoneTransfer]\r\nZoneId=3\r\nHostUrl=https://example.org/report.pdf\r\n")

plain("big.bin", b"the file itself is small\n")
put("big.bin", "payload", lines("non-resident named stream payload line", 300000))

# journal.bin:$J is written last, below. Its $Max goes in now.
plain("journal.bin", b"")
put("journal.bin", "$Max", struct.pack("<QQQQ", 32 << 20, 1 << 20, 0x01DD41A5_2EB4E800, 0))

plain("hollow.bin", b"a file whose stream was sized and never written\n")
put("hollow.bin", "nothing-stored", truncate=4 << 20)

plain("holey.bin", b"")
put("holey.bin", "holey", lines("before the hole", 65536),
    tail=(1 << 20, lines("after the hole", 65536)))

plain("empty.txt", b"a file with an empty stream\n")
put("empty.txt", "empty", b"")

os.makedirs(os.path.join(mnt, "folder"))
plain("folder/inside.txt", b"a file inside a directory that has a stream\n")
put("folder", "dirstream", b"a stream on a directory\n")
put(".", "rootstream", b"a stream on the root directory\n")

# The directory carries FILE_ATTRIBUTE_COMPRESSED, and ntfs-3g compresses what is
# written into it, named streams included.
os.makedirs(os.path.join(mnt, "comp"))
os.setxattr(os.path.join(mnt, "comp"), "system.ntfs_attrib", struct.pack("<I", 0x810))
plain("comp/packed.txt", b"x\n")
put("comp/packed.txt", "packed", lines("a line that repeats and so compresses well", 860000))
put("comp/packed.txt", "late", lines("compressed, after a hole at the front", 200000),
    hole=1 << 20)

plain("linked_a.txt", b"one record, two names, one stream\n")
put("linked_a.txt", "tag", b"the stream both names share\n")
os.link(os.path.join(mnt, "linked_a.txt"), os.path.join(mnt, "linked_b.txt"))
rows.append(rows[-1].replace("\tlinked_a.txt:tag", "\tlinked_b.txt:tag"))

plain("manystreams.txt", b"many streams\n")
for i in range(1, 13):
    put("manystreams.txt", f"s{i}", (f"stream {i} " * 40).encode())

plain("notes.txt", b"a stream whose name is not ASCII\n")
put("notes.txt", "ünïcödé", "ünïcödé stream\n".encode())

plain("plain.txt", b"a file with no stream at all\n")

# $UsnJrnl:$J keeps its records at the end of a stream whose front Windows has
# freed, and on a volume of any age those records are scattered: its run list
# outgrows its record and continues in another, named by an $ATTRIBUTE_LIST.
# The volume is filled with one-cluster files and every other one removed, so
# the stream written next can only go into one-cluster holes, and the fillers
# are then removed too. 1 MiB is a multiple of the 64 KiB compression unit
# ntfs-3g allocates sparse streams in, so the front stays a hole rather than
# becoming written zeros.
os.makedirs(os.path.join(mnt, "holes"))
count = 0
while True:
    try:
        plain(f"holes/h{count}.bin", b"h" * 4096)
    except OSError:
        try:
            os.remove(os.path.join(mnt, f"holes/h{count}.bin"))
        except OSError:
            pass
        break
    count += 1
for i in range(0, count, 2):
    os.remove(os.path.join(mnt, f"holes/h{i}.bin"))
size = (count // 2 - 40) * 4096
records = b"".join(b"usn record %07d, after the freed front of the journal\n" % i
                   for i in range(size // 54 + 1))[:size]
put("journal.bin", "$J", records, hole=1 << 20)
for i in range(1, count, 2):
    os.remove(os.path.join(mnt, f"holes/h{i}.bin"))
os.rmdir(os.path.join(mnt, "holes"))
print(f"  filled the volume with {count} files and emptied it, to scatter "
      f"{size} bytes of journal", file=sys.stderr)

with open(intended, "w", encoding="utf-8") as fh:
    fh.write("\n".join(sorted(rows, key=lambda r: r.split("\t")[2])) + "\n")
PY
sync
fusermount3 -u "$MNT"
echo "  wrote $(wc -l < "$OUT/streams.intended") streams" >&2

# First reader: ntfs-3g, mounted read-only, reads back every stream in full.
ntfs-3g -o ro,streams_interface=windows "$IMG" "$MNT"
python3 - "$MNT" "$OUT/streams.intended" <<'PY'
import hashlib, os, sys
mnt, intended = sys.argv[1], sys.argv[2]
bad = 0
for row in open(intended, encoding="utf-8").read().splitlines():
    digest, _hole, shown = row.split("\t")
    path = "." + shown if shown.startswith(":") else shown
    got = hashlib.sha256(open(os.path.join(mnt, path), "rb").read()).hexdigest()
    if got != digest:
        bad += 1
        print(f"NTFS-3G READS BACK SOMETHING ELSE for {shown}", file=sys.stderr)
sys.exit(1 if bad else 0)
PY
fusermount3 -u "$MNT"
echo "  ntfs-3g reads back every stream as written" >&2

# Second reader: The Sleuth Kit. fls names every $DATA stream (type 128) and
# the index attributes too, which are left out: they are not streams of bytes.
# At the root fls names a stream ".:name", and under a directory it names the
# directory's own stream a second time as "dir/.:name", which is the same
# attribute reached through the directory's "." entry and is dropped here.
python3 - "$IMG" "$CLUSTER" "$OUT/streams.intended" "$OUT/ntfs-streams.sha256" <<'PY'
import hashlib, re, subprocess, sys
img, cluster, intended, manifest = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]

def run(*args):
    return subprocess.run(args, check=True, capture_output=True).stdout

listed = {}
for line in run("fls", "-r", "-p", "-u", img).decode("utf-8").splitlines():
    m = re.match(r"^\S+ (\d+)-128-(\d+):\t(.*)$", line)
    if not m:
        continue
    inode, ident, path = m.group(1), m.group(2), m.group(3)
    parent, _slash, leaf = path.rpartition("/")
    if ":" not in leaf:
        continue
    name, _colon, stream = leaf.partition(":")
    if name == ".":
        if parent:
            continue                        # dir/.:x is dir:x again
        shown = ":" + stream
    else:
        shown = path
    listed[shown] = (inode, ident, stream)

stat_cache = {}
def front_hole(inode, ident, stream):
    """(clusters of hole at the front, clusters in all) for one attribute, or
    None when it is resident.

    istat lists a non-resident attribute's clusters with a sparse one as 0.
    It lists none at all for $BadClus:$Bad, whose only run is a hole the size
    of the volume, so for an attribute istat lists nothing for, the run list
    ntfsinfo prints is read instead, where a hole is <HOLE>."""
    text = stat_cache.get(inode)
    if text is None:
        text = stat_cache[inode] = run("istat", img, inode).decode("utf-8", "replace")
    block = re.search(r"^Type: \$DATA \(128-%s\).*?$(.*?)(?=^Type: |\Z)" % ident,
                      text, re.S | re.M)
    if block is None or "Non-Resident" not in block.group(0).splitlines()[0]:
        return None
    lcns = [int(v) for v in block.group(1).split()]
    if lcns:
        lead = 0
        while lead < len(lcns) and lcns[lead] == 0:
            lead += 1
        return lead, len(lcns)
    info = run("ntfsinfo", "-i", inode, "-v", img).decode("utf-8", "replace")
    runs = []
    for part in info.split("Dumping attribute ")[1:]:
        named = re.search(r"Attribute name:\s+'(.*)'", part)
        if not part.startswith("$DATA") or not named or named.group(1) != stream:
            continue
        runs += [(int(v, 16), l, int(n, 16)) for v, l, n in re.findall(
            r"^\t\t\t(0x[0-9a-f]+)\t\t(<HOLE>|0x[0-9a-f]+)\t\t(0x[0-9a-f]+)$", part, re.M)]
    runs.sort()
    lead = 0
    for _vcn, lcn, count in runs:
        if lcn != "<HOLE>":
            break
        lead += count
    return lead, sum(count for _v, _l, count in runs)

rows, skipped, found = [], [], {}
for shown, (inode, ident, stream) in sorted(listed.items()):
    data = run("icat", img, f"{inode}-128-{ident}")
    hole = front_hole(inode, ident, stream)
    lead = 0
    if hole is not None and hole[1]:
        lead, total = hole
        if lead == total:
            skipped.append(shown)           # nothing stored: not listed
            found[shown] = (hashlib.sha256(data).hexdigest(), total * cluster)
            continue
    rows.append(f"{hashlib.sha256(data[lead * cluster:]).hexdigest()}  {shown}")
    found[shown] = (hashlib.sha256(data).hexdigest(), lead * cluster)

# Intent and The Sleuth Kit have to agree on every stream this script wrote:
# on its bytes, and on how much of its front is hole.
bad = 0
for row in open(intended, encoding="utf-8").read().splitlines():
    digest, hole, shown = row.split("\t")
    got = found.get(shown)
    if got is None:
        print(f"FLS DOES NOT LIST {shown}", file=sys.stderr); bad += 1
        continue
    if got[0] != digest:
        print(f"ICAT READS SOMETHING ELSE for {shown}", file=sys.stderr); bad += 1
    if int(hole) and got[1] != int(hole) and shown not in skipped:
        print(f"ISTAT PUTS THE FIRST STORED CLUSTER OF {shown} AT {got[1]}, "
              f"NOT AFTER THE {hole}-BYTE HOLE", file=sys.stderr); bad += 1
extents = sum(1 for part in run("ntfsinfo", "-i", listed["journal.bin:$J"][0], "-v", img)
              .decode("utf-8", "replace").split("Dumping attribute ")[1:]
              if part.startswith("$DATA") and "Attribute name:\t\t '$J'" in part)
if extents < 2:
    print(f"JOURNAL.BIN:$J IS IN {extents} RECORD(S), NOT SPREAD OVER SEVERAL", file=sys.stderr)
    bad += 1
if "hollow.bin:nothing-stored" not in skipped or "$BadClus:$Bad" not in skipped:
    print(f"THE ALL-HOLE STREAMS ARE NOT ALL HOLE: {skipped}", file=sys.stderr); bad += 1
if bad:
    sys.exit(1)

with open(manifest, "w", encoding="utf-8") as fh:
    fh.write("# Every $DATA stream The Sleuth Kit's fls lists on ntfs-streams.img that holds\n"
             "# a stored cluster: the sha256 icat reads from its first stored cluster on,\n"
             "# counted from istat (ntfsinfo where istat lists no clusters). Written by\n"
             "# tools/make_ntfs_streams_fixture.sh.\n"
             "# Not listed, because every cluster is sparse: " + ", ".join(skipped) + "\n")
    fh.write("\n".join(rows) + "\n")
print(f"  The Sleuth Kit agrees with what was written; {len(rows)} streams in the "
      f"manifest, {len(skipped)} left out as all hole", file=sys.stderr)
PY
rm -f "$OUT/streams.intended"
ls -l "$IMG"
