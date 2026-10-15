#!/usr/bin/env python3
"""Turn what tools/make_refs_fixtures.ps1 wrote into the committed ReFS fixtures.

    python3 tools/make_refs_fixture.py <refs-rich folder> <refs-test.vhdx>

Windows 11 formats ReFS only as a Dev Drive of at least 50 GB, so the volumes
Windows wrote are 50 GB VHDX files (541 MB and 420 MB on disk). The fixtures
committed here keep only the bytes of the ReFS partition that qnxprobe's reader
reads, each at its own offset, in a small container:

    gzip( b"QNXPROBE-SPARSE 1\\n"
          + one line of JSON: {"size": partition bytes, "runs": [[offset, length], ...], ...}
          + the bytes of each run, in order )

Every other byte of the partition reads as zero (_RefsSparseImage in qnxprobe.py
reads it). Nothing is rewritten: a shipped byte is the byte Windows wrote.

Which bytes: every read the reader makes, rounded out to whole clusters, while it
opens the volume, walks it, reads each entry's dates, ids, links and streams, and
reads the content of every file Windows listed, except the files whose stored
content is over 256 KiB and does not compress to half its size (random bytes). Those files are
named in the JSON ("not_shipped"): their records are shipped and checked, their
content reads as zeros and is not checked against its hash. Nothing under
"System Volume Information" is read for content, since Windows put it there and
the listing does not cover it.

refs-fixture.known.tsv.gz is what Windows said about the volume while it was
mounted (listing.tsv, sha256.txt, streams.tsv, deleted.txt), in one table. None
of its values comes from qnxprobe.

refs-dirty.bin.gz is the first fixture (make-refs.ps1), whose newest checkpoint
predates its files: what the reader reads to open it and walk it, including the
log records that follow the checkpoint.

Before writing, the shipped bytes are searched for a Windows security identifier
of a machine (S-1-5-21-...) and for the VM's computer and user names; the tool
stops if it finds one.
"""
import gzip
import hashlib
import io
import json
import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import qnxprobe as q  # noqa: E402

FIXTURES = os.path.join(os.path.dirname(HERE), "tests", "fixtures")
PART_BASE = 32768 * 512            # the ReFS partition of both VHDX files (GPT entry 2)
NOT_SHIPPED_OVER = 256 * 1024
SID_HEAD = bytes.fromhex("010500000000000515000000")    # S-1-5-21, five sub-authorities
NAMES = ("ALEXISBRIGN", "alexisbrignoni")


class Recorder:
    """A file object that remembers which byte ranges were read, relative to
    the partition."""

    def __init__(self, fh):
        self.fh, self.pos, self.ranges = fh, 0, []

    def seek(self, off, whence=0):
        self.pos = self.fh.seek(off, whence)
        return self.pos

    def tell(self):
        return self.pos

    def read(self, n=-1):
        data = self.fh.read(n)
        if data:
            self.ranges.append((self.pos - PART_BASE, len(data)))
        self.pos += len(data)
        return data


def rows(folder, name):
    with open(os.path.join(folder, name), encoding="utf-8-sig") as fh:
        return [line.rstrip("\r\n") for line in fh if line.strip()]


def known_table(folder):
    listing = rows(folder, "listing.tsv")
    head = listing[0].split("\t")
    sha = dict(reversed(line.split("  ", 1)) for line in rows(folder, "sha256.txt"))
    out = ["\t".join(["kind", "path", "size", "allocated", "links", "attributes", "created",
                      "modified", "changed", "accessed", "file_id", "target", "sha256"])]
    entries = []
    for line in listing[1:]:
        f = dict(zip(head, line.split("\t")))
        entries.append(f)
        out.append("\t".join([f["kind"], f["path"], f["size"], f["allocated"], f["links"],
                              f["attributes"],
                              f["created"], f["modified"], f["changed"], f["accessed"],
                              f["file_id"], f["target"], sha.get(f["path"], "")]))
    for line in rows(folder, "streams.tsv")[1:]:
        path, stream, length, digest = line.split("\t")
        out.append("\t".join(["stream", f"{path}:{stream}", length] + [""] * 9 + [digest]))
    for path in rows(folder, "deleted.txt"):
        out.append("\t".join(["deleted", path] + [""] * 11))
    return "\n".join(out) + "\n", entries


def cluster_runs(ranges, cluster, size):
    spans = sorted((off // cluster * cluster,
                    min(size, -(-(off + n) // cluster) * cluster)) for off, n in ranges
                   if 0 <= off < size)
    runs = []
    for a, b in spans:
        if runs and a <= runs[-1][1]:
            runs[-1][1] = max(runs[-1][1], b)
        else:
            runs.append([a, b])
    return [[a, b - a] for a, b in runs]


def log_fold(page):
    """The check value of one 4 KiB log block, as qnxprobe's _refs_log_check
    computes it [forefst mlog.md]."""
    eh = struct.unpack_from("<I", page, 0x54)[0]
    body = bytearray(page)
    body[eh + 8:eh + 16] = bytes(8)
    lanes = [0, 0, 0, 0]
    for i, word in enumerate(struct.unpack(f"<{len(body) // 8}Q", body)):
        lanes[i & 3] ^= word
    v = lanes[0] ^ lanes[1] ^ lanes[2] ^ lanes[3]
    return eh, (v >> 32) ^ (v & 0xFFFFFFFF)


def scrub_sids(blob):
    """Replace the three machine numbers of every S-1-5-21 identifier with 1-2-3,
    and recompute the check value of each log block that changes, so it still
    reads as the record Windows wrote apart from those numbers. Returns how many
    identifiers and log blocks were changed."""
    changed, blocks = 0, set()
    at = blob.find(SID_HEAD)
    while at >= 0:
        blob[at + len(SID_HEAD):at + len(SID_HEAD) + 12] = struct.pack("<III", 1, 2, 3)
        changed += 1
        blocks.add(at // 4096 * 4096)
        at = blob.find(SID_HEAD, at + 1)
    fixed = 0
    for b in sorted(blocks):
        page = blob[b:b + 4096]
        if page[:4] != b"MLog":
            raise SystemExit(f"a security identifier outside a log block, at {b:#x} of the "
                             "shipped bytes; not writing")
        eh, value = log_fold(page)
        struct.pack_into("<Q", blob, b + eh + 8, value)
        fixed += 1
    return changed, fixed


def pack(fh, runs, size, extra, scrub=False):
    head = dict(size=size, runs=runs, **extra)
    out = io.BytesIO()
    out.write(b"QNXPROBE-SPARSE 1\n")
    out.write(json.dumps(head, sort_keys=True).encode() + b"\n")
    blob = bytearray()
    for off, n in runs:
        fh.seek(PART_BASE + off)
        data = fh.read(n)
        if len(data) != n:
            raise SystemExit(f"short read at {off:#x}")
        blob += data
    if scrub:
        changed, fixed = scrub_sids(blob)
        head["scrubbed"] = (f"{changed} machine security identifiers in {fixed} log blocks: "
                            "their three machine numbers replaced with 1-2-3 and each "
                            "block's check value recomputed")
        print("  " + head["scrubbed"])
        out = io.BytesIO()
        out.write(b"QNXPROBE-SPARSE 1\n")
        out.write(json.dumps(head, sort_keys=True).encode() + b"\n")
    for needle in [x.encode() for x in NAMES] + [x.encode("utf-16-le") for x in NAMES]:
        if needle in blob:
            raise SystemExit(f"the shipped bytes hold {needle!r}; not writing")
    at = blob.find(SID_HEAD)
    while at >= 0:
        if blob[at + len(SID_HEAD):at + len(SID_HEAD) + 12] != struct.pack("<III", 1, 2, 3):
            raise SystemExit("the shipped bytes hold a machine security identifier; not writing")
        at = blob.find(SID_HEAD, at + 1)
    out.write(blob)
    return out.getvalue(), len(blob)


def record_rich(path, entries):
    fh = q.open_image_trying(path)
    rec = Recorder(fh)
    w = q.RefsWalker(rec, PART_BASE)
    q.identify_refs(rec, PART_BASE)
    nodes = {}
    for item in q.walk_all(w):
        nodes[item[0]] = item[1]
    not_shipped = []
    for f in entries:
        node = nodes[f["path"]]
        for ask in (w.filetimes, w.file_id, w.attributes, w.named_streams):
            ask(node)
        if f["kind"] in ("filelink", "dirlink"):
            w.readlink(node)
        if f["kind"] != "file":
            for name, size in w.named_streams(node):
                for _ in w.read_file(w.stream_ref(node, name), size):
                    pass
            continue
        w.link_count(node)
        got = w.allocation(node)
        size = w.entry(node)[1]
        if got["stored"] > NOT_SHIPPED_OVER:
            # read through the walker without recording, to see whether it compresses
            probe = q.RefsWalker(fh, PART_BASE)
            data = b"".join(probe.read_file(node, size))
            if len(zlib.compress(data, 1)) > len(data) // 2:
                not_shipped.append(f["path"])
                continue
        for _ in w.read_file(node, size):
            pass
        for name, ssize in w.named_streams(node):
            for _ in w.read_file(w.stream_ref(node, name), ssize):
                pass
    size = w.total_sectors * w.bps
    return fh, cluster_runs(rec.ranges, w.cluster, size), size, not_shipped


def record_dirty(path):
    fh = q.open_image_trying(path)
    rec = Recorder(fh)
    w = q.RefsWalker(rec, PART_BASE)
    q.identify_refs(rec, PART_BASE)
    list(q.walk_all(w))
    size = w.total_sectors * w.bps
    return fh, cluster_runs(rec.ranges, w.cluster, size), size


def write_gz(name, data):
    with open(os.path.join(FIXTURES, name), "wb") as raw:
        with gzip.GzipFile(filename="", fileobj=raw, mode="wb", compresslevel=9, mtime=0) as gz:
            gz.write(data)


def main(folder, dirty_vhdx):
    known, entries = known_table(folder)
    vhdx = os.path.join(folder, "refs-rich.vhdx")
    with open(vhdx, "rb") as fh:
        print("refs-rich.vhdx sha256", hashlib.sha256(fh.read()).hexdigest())
    fh, runs, size, not_shipped = record_rich(vhdx, entries)
    blob, n = pack(fh, runs, size, {"source": "refs-rich.vhdx, GPT entry 2 (LBA 32768), "
                                    "written by Windows 11 build 26200 (tools/make_refs_fixtures.ps1)",
                                    "not_shipped": not_shipped})
    write_gz("refs-fixture.bin.gz", blob)
    print(f"refs-fixture.bin.gz: {len(runs)} runs, {n:,} bytes of {size:,}; not shipped: {not_shipped}")
    write_gz("refs-fixture.known.tsv.gz", known.encode("utf-8"))
    fh, runs, size = record_dirty(dirty_vhdx)
    blob, n = pack(fh, runs, size, {"source": "refs-test.vhdx, GPT entry 2 (LBA 32768), "
                                    "written by Windows 11 build 26200 (make-refs.ps1)",
                                    "not_shipped": []}, scrub=True)
    write_gz("refs-dirty.bin.gz", blob)
    print(f"refs-dirty.bin.gz: {len(runs)} runs, {n:,} bytes of {size:,}")
    for name in ("refs-fixture.bin.gz", "refs-fixture.known.tsv.gz", "refs-dirty.bin.gz"):
        print(f"  {name}: {os.path.getsize(os.path.join(FIXTURES, name)):,} bytes")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    main(sys.argv[1], sys.argv[2])
