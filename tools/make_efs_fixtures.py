#!/usr/bin/env python3
"""Write the QNX EFS (F3S) fixtures: one small NOR flash image per byte order.

    python3 tools/make_efs_fixtures.py [--oracle QNXMOUNT_CHECKOUT]

Nothing free writes EFS: QNX's mkefs ships with the QNX SDP, and the one open
reader, NetherlandsForensicInstitute/qnxmount, only reads. So this writes the
format itself, from the structures in fs/f3s_spec.h (RunZeJustin/qnx660 at
47c4158e3993d7536170b649e6c1e09552318fb4) as qnxmount/efs/parser.ksy lays them
out (commit 11c8a7f9ee9b945d584263743f6ea8524e8776d2). It shares no code with
qnxprobe.py, and what it records as expected (tests/fixtures/efs.known.json)
comes from what it was told to write, never from reading the image back.

--oracle reads the little-endian image with qnxmount, the reference reader,
and compares every live file it lists with what was written. It needs a
checkout of qnxmount at the commit above and the kaitaistruct package. qnxmount
reads little-endian only and lists live files only, so the big-endian image
and the deleted and superseded extents have no reference reading: the
big-endian image is the same model written in the other byte order, and the
deleted data is checked against what this writer put there.

What each image holds, behind 16 KiB that is not EFS and carries two decoy
signatures (one bare string, one with a boot record's first four bytes but no
unit in front of it):

  partition A   6 units of 4 KiB, one spare. Physical order is logical 2, 3,
                1, spare, 4, 5, so the boot record sits in physical unit 2 and
                the partition cannot be found from its first units alone.
  partition B   3 units of 4 KiB, boot record in its first unit, one file.
                24 KiB that is not EFS lies between the two.

Both partitions start on a 16 KiB boundary. qnxmount maps the image from the
partition's offset, and a mapping has to start on a page boundary, which is
16 KiB on Apple silicon.

Partition A's history, all of it still on the flash:

  log/current.log   its second extent was overwritten: the old extent stays
                    allocated with its supersede pointer set
  readme.txt        its directory entry was rewritten: the old entry is
                    deleted, with its supersede pointer set
  log/old.log       deleted, two extents; its directory entry is still reached
                    from log's chain through the entry that came before it
  gone.bin          deleted; its first extent was overwritten before that, and
                    nothing reaches its directory entry
  broken.dat        deleted; its first pointer names a logical unit that is
                    not there
  (no name)         two deleted extents chained by next, no directory entry

Header status words are the values seen on flash written by the QNX driver:
allocated 0x30, deleted 0x10, NO_SUPER and NO_NEXT cleared where a pointer is
set, BASIC and NO_SPLIT set, the bits above 0x7ff set. status[1] and status[2]
are written equal to status[0]; the format's use of them is not established
here, and qnxmount reads status[1] of header 1 only (a spare unit's reads
0xFFFFFFFF).
"""
import gzip
import hashlib
import json
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(os.path.dirname(HERE), "tests", "fixtures")

UNIT_POW2, ALIGN_POW2 = 12, 2
UNIT = 1 << UNIT_POW2
HEAD = 32
NO_NEXT, NO_SUPER, NO_SPLIT, LAST, BASIC = 0x02, 0x04, 0x08, 0x80, 0x400
ALLOC, DELETE = 0x30, 0x10
T_FILE, T_DIR, T_SYS = 0x300, 0x200, 0x100
S_IFDIR, S_IFREG, S_IFLNK = 0o040000, 0o100000, 0o120000
LEAD, GAP = 16384, 24576


def blob(label, n):
    """n bytes that depend only on label: synthetic, and never a run of 0xFF."""
    out, i = bytearray(), 0
    while len(out) < n:
        out += hashlib.sha256(f"qnxprobe efs fixture {label} {i}".encode()).digest()
        i += 1
    return bytes(out[:n]).replace(b"\xff", b"\xfe")


class Extent:
    def __init__(self, logi, index, typ, text, cond):
        self.ptr = (logi, index)
        self.typ, self.text, self.cond = typ, text, cond
        self.next = self.super = None
        self.toff = None


class Partition:
    """A model of one partition: logical units, each a list of extents."""

    def __init__(self, e, physical):
        self.e = e
        self.physical = physical          # logical number per physical unit, None = spare
        self.total = len(physical)
        self.units = {logi: [] for logi in physical if logi is not None}
        self.boot_unit = physical.index(1)
        for phys, logi in enumerate(physical):
            if logi is None:
                continue
            self.add(logi, T_SYS, struct.pack(e + "HBBHHIHH", 0x10, ord("L" if e == "<" else "B"),
                                              0xFF, UNIT_POW2, 0xFFFF, 7 + phys, 1, 2))
            self.add(logi, T_SYS, struct.pack(e + "HHI", 0x18, logi, 100 + logi) + bytes(16))
        self.add(1, T_SYS, struct.pack(e + "HBB", 0x18, 3, 0) + b"QSSL_F3S"
                 + struct.pack(e + "HHHHHH", self.boot_unit, self.total, 1, ALIGN_POW2, 1, 3))

    def add(self, logi, typ, text=b"", cond=ALLOC):
        ext = Extent(logi, len(self.units[logi]), typ, text, cond)
        self.units[logi].append(ext)
        return ext

    def dirent(self, logi, name, mode, first, mtime, cond=ALLOC):
        raw = name.encode() + b"\x00"
        pad = (len(raw) + 3) & ~3
        text = (struct.pack(self.e + "HBBHH", 8, 0, len(raw), *first) + raw.ljust(pad, b"\x00")
                + struct.pack(self.e + "HHIIII", 0x14, mode, 0, 0, mtime, mtime))
        return self.add(logi, T_DIR, text, cond)

    def unit_bytes(self, logi, phys):
        e, unit = self.e, bytearray(b"\xff" * UNIT)
        if logi is None:                          # a spare: unit_info and nothing else
            unit[0:16] = struct.pack(e + "HBBHHIHH", 0x10, ord("L" if e == "<" else "B"), 0xFF,
                                     UNIT_POW2, 0xFFFF, 7 + phys, 1, 2)
            s0 = 0xFFFFF800 | BASIC | T_SYS | ALLOC | NO_SPLIT | NO_SUPER | NO_NEXT | LAST
            unit[UNIT - HEAD:UNIT] = self.head(s0, 0, 16, None, None, spare=True)
            return bytes(unit)
        cursor = 0
        for ext in self.units[logi]:
            ext.toff = cursor
            unit[cursor:cursor + len(ext.text)] = ext.text
            cursor = (cursor + len(ext.text) + (1 << ALIGN_POW2) - 1) & ~((1 << ALIGN_POW2) - 1)
        assert cursor <= UNIT - HEAD * (len(self.units[logi]) + 1), "unit overflows"
        for ext in self.units[logi]:
            s0 = 0xFFFFF800 | BASIC | ext.typ | ext.cond | NO_SPLIT
            if ext.next is None:
                s0 |= NO_NEXT
            if ext.super is None:
                s0 |= NO_SUPER
            off = UNIT - HEAD * (ext.ptr[1] + 1)
            unit[off:off + HEAD] = self.head(s0, ext.toff, len(ext.text), ext.next, ext.super)
        return bytes(unit)                          # the header after the last stays erased

    def head(self, s0, toff, tsize, nxt, sup, spare=False):
        e = self.e
        toff >>= ALIGN_POW2
        s1 = 0xFFFFFFFF if spare else s0
        return (struct.pack(e + "III", s0, s1, s1) + b"\xff" * 6 + b"\xff"
                + bytes([toff >> 16]) + struct.pack(e + "HH", toff & 0xFFFF, tsize)
                + struct.pack(e + "HH", *(nxt or (0xFFFF, 0xFFFF)))
                + struct.pack(e + "HH", *(sup or (0xFFFF, 0xFFFF))))

    def image(self):
        return b"".join(self.unit_bytes(logi, phys) for phys, logi in enumerate(self.physical))

    def where(self, base, ext):
        """Offset in the image of an extent's text."""
        return base + self.physical.index(ext.ptr[0]) * UNIT + ext.toff


def chain(*exts):
    for a, b in zip(exts, exts[1:]):
        a.next = b.ptr
    return exts[0]


def build_a(e):
    """Partition A and what it holds: (partition, live, deleted)."""
    p = Partition(e, [2, 3, 1, None, 4, 5])
    live, t = {}, 1_700_000_000
    root = p.dirent(1, "", S_IFDIR | 0o755, (1, 4), t)               # header 3, F3S_ROOT_INDEX
    assert root.ptr == (1, 3)

    # the root's children, chained: etc, log, readme.txt (rewritten), link
    etc = p.dirent(1, "etc", S_IFDIR | 0o755, (2, 2), t + 1)          # header 4, F3S_FIRST_INDEX
    assert etc.ptr == (1, 4)
    log = p.dirent(1, "log", S_IFDIR | 0o755, (3, 2), t + 2)
    readme_data = p.add(4, T_FILE, blob("readme", 300))
    readme_old = p.dirent(1, "readme.txt", S_IFREG | 0o644, readme_data.ptr, t + 3, DELETE)
    readme_new = p.dirent(5, "readme.txt", S_IFREG | 0o644, readme_data.ptr, t + 30)
    readme_old.super = readme_new.ptr
    link_data = p.add(4, T_FILE, b"etc/config.txt")
    link = p.dirent(5, "link", S_IFLNK | 0o777, link_data.ptr, t + 4)
    chain(etc, log, readme_old)
    chain(readme_new, link)
    live["readme.txt"] = (S_IFREG | 0o644, t + 30, readme_data.text)

    # etc: config.txt in two extents across two units, and an empty file
    cfg1 = p.add(2, T_FILE, blob("config 1", 900))                    # logical 2 header 2
    cfg2 = p.add(4, T_FILE, blob("config 2", 517))
    chain(cfg1, cfg2)
    config = p.dirent(2, "config.txt", S_IFREG | 0o600, cfg1.ptr, t + 5)
    assert config.ptr[1] == 3
    # etc.first has to name config's directory entry, written after its data
    etc.text = etc.text[:4] + struct.pack(e + "HH", *config.ptr) + etc.text[8:]
    empty_data = p.add(2, T_FILE, b"")
    empty = p.dirent(2, "empty", S_IFREG | 0o644, empty_data.ptr, t + 6)
    chain(config, empty)
    live["etc/config.txt"] = (S_IFREG | 0o600, t + 5, cfg1.text + cfg2.text)
    live["etc/empty"] = (S_IFREG | 0o644, t + 6, b"")

    # log: current.log (second extent overwritten), then the deleted old.log
    cur1 = p.add(3, T_FILE, blob("current 1", 700))                   # logical 3 header 2
    cur2_old = p.add(3, T_FILE, blob("current 2 old", 400))
    cur2_new = p.add(5, T_FILE, blob("current 2 new", 450))
    chain(cur1, cur2_old)
    cur2_old.super = cur2_new.ptr
    old1 = p.add(4, T_FILE, blob("old 1", 1000), DELETE)
    old2 = p.add(5, T_FILE, blob("old 2", 333), DELETE)
    chain(old1, old2)
    # current.log's entry was rewritten when old.log was unlinked from the chain
    cur_v0 = p.dirent(3, "current.log", S_IFREG | 0o644, cur1.ptr, t + 7, DELETE)
    cur_v1 = p.dirent(3, "current.log", S_IFREG | 0o644, cur1.ptr, t + 40)
    old_log = p.dirent(3, "old.log", S_IFREG | 0o640, old1.ptr, t + 8, DELETE)
    cur_v0.next, cur_v0.super = old_log.ptr, cur_v1.ptr
    log.text = log.text[:4] + struct.pack(e + "HH", *cur_v0.ptr) + log.text[8:]
    live["log/current.log"] = (S_IFREG | 0o644, t + 40, cur1.text + cur2_new.text)

    # gone.bin: its first extent overwritten, then the file deleted; no entry leads to it
    gone_old = p.add(4, T_FILE, blob("gone old", 256), DELETE)
    gone_new = p.add(5, T_FILE, blob("gone new", 280), DELETE)
    gone_tail = p.add(5, T_FILE, blob("gone tail", 120), DELETE)
    gone_old.super = gone_new.ptr
    chain(gone_new, gone_tail)
    gone_old.next = gone_tail.ptr
    p.dirent(4, "gone.bin", S_IFREG | 0o600, gone_old.ptr, t + 9, DELETE)

    # broken.dat: its first pointer names logical unit 9
    p.dirent(4, "broken.dat", S_IFREG | 0o644, (9, 3), t + 10, DELETE)

    # two deleted extents with no directory entry
    orphan1 = p.add(2, T_FILE, blob("orphan 1", 200), DELETE)
    orphan2 = p.add(3, T_FILE, blob("orphan 2", 96), DELETE)
    chain(orphan1, orphan2)

    deleted = [
        dict(kind="deleted file", name="old.log", parent_path="log", recoverable=True,
             mode=S_IFREG | 0o640, mtime=t + 8, extents=[old1, old2]),
        dict(kind="deleted file", name="gone.bin", parent_path=None, recoverable=True,
             mode=S_IFREG | 0o600, mtime=t + 9, extents=[gone_new, gone_tail]),
        dict(kind="deleted file", name="broken.dat", parent_path=None, recoverable=False,
             mode=S_IFREG | 0o644, mtime=t + 10, extents=[]),
        dict(kind="extents of a deleted file", name="gone.bin", parent_path=None,
             recoverable=True, mode=S_IFREG | 0o600, mtime=t + 9, extents=[gone_old]),
        dict(kind="extents of a live file", name="current.log", parent_path="log",
             recoverable=True, mode=S_IFREG | 0o644, mtime=t + 40, extents=[cur2_old]),
        dict(kind="extents with no name", name="", parent_path=None, recoverable=True,
             mode=None, mtime=None, extents=[orphan1, orphan2]),
    ]
    dirs = {"etc": (S_IFDIR | 0o755, t + 1), "log": (S_IFDIR | 0o755, t + 2)}
    links = {"link": (S_IFLNK | 0o777, t + 4, "etc/config.txt")}
    return p, live, dirs, links, deleted


def build_b(e):
    p = Partition(e, [1, 2, None])
    t = 1_700_100_000
    p.dirent(1, "", S_IFDIR | 0o755, (1, 4), t)
    data = p.add(2, T_FILE, blob("b only", 640))
    only = p.dirent(1, "only.bin", S_IFREG | 0o444, data.ptr, t + 1)
    assert only.ptr == (1, 4)
    return p, {"only.bin": (S_IFREG | 0o444, t + 1, data.text)}


def build(e):
    lead = bytearray(blob("lead", LEAD))
    lead[0x400:0x408] = b"QSSL_F3S"                                   # a bare string
    lead[0x1000:0x1004] = struct.pack(e + "HBB", 0x18, 3, 0)          # a boot record's head,
    lead[0x1004:0x100C] = b"QSSL_F3S"                                 # with no unit around it
    a, live_a, dirs_a, links_a, deleted = build_a(e)
    b, live_b = build_b(e)
    img_a, img_b = a.image(), b.image()
    base_a, base_b = LEAD, LEAD + len(img_a) + GAP
    image = bytes(lead) + img_a + blob("gap", GAP) + img_b + b"\xff" * UNIT

    def files(live):
        return {path: dict(mode=mode, mtime=mtime, size=len(data),
                           sha256=hashlib.sha256(data).hexdigest())
                for path, (mode, mtime, data) in live.items()}
    known = dict(
        partitions=[
            dict(base=base_a, size=len(img_a), unit_size=UNIT, unit_total=a.total,
                 unit_index=a.boot_unit, files=files(live_a),
                 dirs={k: dict(mode=m, mtime=mt) for k, (m, mt) in dirs_a.items()},
                 symlinks={k: dict(mode=m, mtime=mt, target=tg)
                           for k, (m, mt, tg) in links_a.items()},
                 deleted=[dict(kind=d["kind"], name=d["name"], parent_path=d["parent_path"],
                               recoverable=d["recoverable"], mode=d["mode"], mtime=d["mtime"],
                               size=sum(len(x.text) for x in d["extents"]),
                               sha256=hashlib.sha256(b"".join(x.text for x in d["extents"]))
                               .hexdigest(),
                               extents=[[a.where(base_a, x), len(x.text),
                                         ("deleted" if x.cond == DELETE else "allocated")
                                         + (", superseded" if x.super else "")]
                                        for x in d["extents"]])
                          for d in deleted]),
            dict(base=base_b, size=len(img_b), unit_size=UNIT, unit_total=b.total,
                 unit_index=b.boot_unit, files=files(live_b), dirs={}, symlinks={}, deleted=[]),
        ])
    return image, known


def oracle(checkout, image_path, known):
    """Read the little-endian image with qnxmount and compare its live files
    with what was written. Returns the number of problems."""
    sys.path.insert(0, checkout)
    import re
    from qnxmount.efs.interface import EFS, KaitaiIO
    from qnxmount.efs.parser import Parser
    io = KaitaiIO(image_path)
    opened, problems = {}, []
    for hit in re.finditer(b"QSSL_F3S", io.mm):                       # qnxmount's scan_partitions,
        try:                                                           # one hit at a time
            io.stream.seek(hit.start() - 4)
            boot = Parser.BootInfo(io.stream)
            if not boot.is_valid:
                continue
            start = hit.start() & 0xfffff000
            io.stream.seek(start)
            info = Parser.UnitInfo(io.stream)
            base = start - boot.unit_index * info.unit_size
            opened[base] = EFS(image_path, boot, offset=base)
        except Exception as exc:                                       # pylint: disable=broad-except
            print(f"  qnxmount did not open the hit at {hit.start():#x}: {type(exc).__name__}")
    for part in known["partitions"]:
        efs = opened.get(part["base"])
        if efs is None:
            problems.append(f"qnxmount opened no partition at {part['base']:#x}")
            continue
        got, stack = {}, [("", efs.root)]
        while stack:
            path, entry = stack.pop()
            for child in efs.read_dir(entry):
                cpath = f"{path}/{child.name}" if path else child.name
                kind = child.stat.mode & 0o170000
                if kind == S_IFDIR:
                    stack.append((cpath, child))
                elif kind == S_IFREG:
                    data = efs.read_file(child)
                    got[cpath] = dict(mode=child.stat.mode, mtime=child.stat.mtime, size=len(data),
                                      sha256=hashlib.sha256(data).hexdigest())
        if got != part["files"]:
            problems.append(f"partition at {part['base']:#x}: qnxmount read "
                            f"{sorted(got)} and the files written were {sorted(part['files'])}, "
                            "or a mode, time or hash differs")
        else:
            print(f"  qnxmount reads the partition at {part['base']:#x}: "
                  f"{len(got)} files, every mode, mtime and SHA-256 as written")
    extra = set(opened) - {p["base"] for p in known["partitions"]}
    if extra:
        problems.append(f"qnxmount opened partitions that were not written: {sorted(extra)}")
    for line in problems:
        print("  PROBLEM", line)
    return len(problems)


def main():
    os.makedirs(FIXTURES, exist_ok=True)
    knowns = {}
    for name, e in (("efs-le", "<"), ("efs-be", ">")):
        image, known = build(e)
        knowns[name] = known
        with open(os.path.join(FIXTURES, name + ".img.gz"), "wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as gz:
                gz.write(image)
        print(f"{name}.img.gz  {len(image):,} bytes, sha256 {hashlib.sha256(image).hexdigest()}")
    # the two byte orders hold the same files at the same offsets
    assert knowns["efs-le"] == knowns["efs-be"]
    with open(os.path.join(FIXTURES, "efs.known.json"), "w", encoding="utf-8") as out:
        json.dump(knowns["efs-le"], out, indent=1, sort_keys=True)
        out.write("\n")
    print("efs.known.json")
    if "--oracle" in sys.argv:
        checkout = sys.argv[sys.argv.index("--oracle") + 1]
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "efs-le.img")
            with open(path, "wb") as out:
                out.write(build("<")[0])
            return 1 if oracle(checkout, path, knowns["efs-le"]) else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
