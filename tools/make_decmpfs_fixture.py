#!/usr/bin/env python3
"""Build the small APFS and HFS+ images of compressed files that qnxprobe's
self-test reads, and record what each file holds.

Runs on macOS, as an ordinary user. hdiutil makes and mounts a plain image, and
the operating system's own drivers write it. Each file is compressed one of two
ways:

  * by ditto --hfsCompression, which is Apple's own compressor choosing its own
    method, so those files are the shape macOS writes;
  * by hand, for every decmpfs method this script knows: the content is
    compressed with zlib or with Apple's libcompression (LZVN, LZFSE,
    LZBITMAP), laid out in the com.apple.decmpfs attribute or the resource
    fork, and the file then flagged compressed (chflags UF_COMPRESSED), the
    way tools/make_apfs_fixture.sh writes its one zlib file.

Every file is then read back through the mounted volume, so macOS's own
decompressor decodes it, and the script fails unless that matches what was
written. That read is what confirms each layout: a hand-built file macOS
cannot read is a layout this script got wrong, and it is never recorded.

The listing records, per file, the method the image holds (read back with
XATTR_SHOWCOMPRESSION) and the SHA-256 of what macOS read.

    python3 tools/make_decmpfs_fixture.py tests/fixtures
"""
import ctypes
import gzip
import hashlib
import os
import random
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import zlib

XATTR_SHOWCOMPRESSION = 0x0020
COMPRESSION_LZFSE, COMPRESSION_LZVN, COMPRESSION_LZBITMAP = 0x801, 0x900, 0x702
BLOCK = 0x10000

libc = ctypes.CDLL(None, use_errno=True)
libc.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p,
                          ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
libc.getxattr.restype = ctypes.c_ssize_t
libc.setxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p,
                          ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
libc.setxattr.restype = ctypes.c_int
lzc = ctypes.CDLL("/usr/lib/libcompression.dylib")
lzc.compression_encode_buffer.restype = ctypes.c_size_t
lzc.compression_encode_buffer.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p,
                                          ctypes.c_size_t, ctypes.c_void_p, ctypes.c_int]


def apple_encode(data, algorithm):
    cap = 2 * len(data) + 4096
    buf = ctypes.create_string_buffer(cap)
    n = lzc.compression_encode_buffer(buf, cap, data, len(data), None, algorithm)
    if not n:
        raise RuntimeError(f"libcompression would not encode {len(data)} bytes")
    return buf.raw[:n]


def decmpfs_attr(path):
    buf = ctypes.create_string_buffer(65536)
    n = libc.getxattr(path.encode(), b"com.apple.decmpfs", buf, len(buf), 0,
                      XATTR_SHOWCOMPRESSION)
    return buf.raw[:n] if n > 0 else None


def set_attr(path, name, value):
    if libc.setxattr(path.encode(), name.encode(), value, len(value), 0, 0) != 0:
        raise OSError(ctypes.get_errno(), f"setxattr {name} on {path}")


def header(method, size):
    return b"fpmc" + struct.pack("<IQ", method, size)


def blocks(data):
    return [data[i:i + BLOCK] for i in range(0, len(data), BLOCK)] or []


def block_lzvn(piece):
    enc = apple_encode(piece, COMPRESSION_LZVN)
    return enc if len(enc) < len(piece) else b"\x06" + piece


def block_lzfse(piece):
    enc = apple_encode(piece, COMPRESSION_LZFSE)
    return enc if len(enc) < len(piece) else b"\xff" + piece


def block_zlib(piece):
    enc = zlib.compress(piece, 9)
    return enc if len(enc) < len(piece) else b"\xff" + piece


def block_lzbitmap(piece):
    return apple_encode(piece, COMPRESSION_LZBITMAP)


def offset_fork(pieces):
    """Methods 8, 10, 12, 14: a table of n + 1 little-endian offsets, then the
    blocks, each offset counted from the start of the fork."""
    at = 4 * (len(pieces) + 1)
    offs = []
    for p in pieces:
        offs.append(at)
        at += len(p)
    offs.append(at)
    return struct.pack(f"<{len(offs)}I", *offs) + b"".join(pieces)


def zlib_fork(pieces):
    """Method 4: a resource file with one 'cmpf' resource. Header (data offset,
    map offset, data length, map length, big endian), the data area at 0x100
    holding the resource's big-endian length then its bytes (a block count and
    (offset, length) pairs, little endian, offsets from the resource's first
    byte), then a resource map naming the one resource. The layout is the one
    all 937 method 4 files found on the Mac this was built on have. A map whose
    first 16 bytes repeated the header, as Inside Macintosh allows, was refused
    by macOS (EINVAL) when this was written, so they are left zero, as they are
    in every file measured."""
    table_len = 4 + 8 * len(pieces)
    at, pairs = table_len, []
    for p in pieces:
        pairs.append(struct.pack("<II", at, len(p)))
        at += len(p)
    res = struct.pack("<I", len(pieces)) + b"".join(pairs) + b"".join(pieces)
    data = struct.pack(">I", len(res)) + res
    data_off, map_off = 0x100, 0x100 + len(data)
    rmap = bytearray(50)
    struct.pack_into(">HH", rmap, 24, 28, 50)              # type list, name list
    struct.pack_into(">H4sHH", rmap, 28, 0, b"cmpf", 0, 10)  # one type, one resource
    struct.pack_into(">hHI", rmap, 38, 1, 0xFFFF, 0)       # id 1, no name, data at 0
    head = struct.pack(">IIII", data_off, map_off, len(data), len(rmap))
    return head + bytes(0x100 - 16) + data + bytes(rmap)


def hand_built(path, method, data):
    """Write ``data`` as a decmpfs file of ``method`` at ``path``."""
    open(path, "wb").close()
    size = len(data)
    fork = None
    if method == 1:
        attr = header(1, size) + data
    elif method == 3:
        attr = header(3, size) + block_zlib(data)
    elif method == 7:
        attr = header(7, size) + block_lzvn(data)
    elif method == 9:
        attr = header(9, size) + b"\xcc" + data
    elif method == 11:
        attr = header(11, size) + block_lzfse(data)
    elif method == 13:
        attr = header(13, size) + block_lzbitmap(data)
    else:
        attr = header(method, size)
        encode = {4: block_zlib, 8: block_lzvn, 10: lambda p: b"\xcc" + p,
                  12: block_lzfse, 14: block_lzbitmap}[method]
        pieces = [encode(p) for p in blocks(data)]
        fork = zlib_fork(pieces) if method == 4 else offset_fork(pieces)
    if fork is not None:
        with open(path + "/..namedfork/rsrc", "wb") as fh:
            fh.write(fork)
    set_attr(path, "com.apple.decmpfs", attr)
    os.chflags(path, stat.UF_COMPRESSED)


def contents():
    """Deterministic sample contents: text, a binary-like run, incompressible
    bytes, and mixes of them that span several 64 KiB blocks."""
    rng = random.Random(20261017)
    words = [bytes(rng.choice(b"etaoinshrdlucmfwyp") for _ in range(rng.randint(2, 9)))
             for _ in range(60)]

    def text(n):
        out = bytearray()
        while len(out) < n:
            out += rng.choice(words) + (b"\n" if rng.random() < 0.08 else b" ")
        return bytes(out[:n])

    def binary(n):
        out = bytearray()
        while len(out) < n:
            out += struct.pack("<IIHH", rng.randrange(64), len(out), rng.randrange(8), 0x4141)
        return bytes(out[:n])

    return {
        "tiny.txt": text(40),
        "small.txt": text(3000),
        "block.txt": text(BLOCK),
        "blocks.txt": text(2 * BLOCK + 1234),
        "binary.bin": binary(BLOCK + 77),
        # the last block will not compress, so it is stored behind its marker
        "mixed.bin": text(BLOCK) + bytes(BLOCK) + rng.randbytes(3000),
        "zeros.bin": bytes(3 * BLOCK),
    }


# Which sample each hand-built method is given. The attribute methods hold a
# whole file in an attribute of at most 3,802 bytes (xnu decmpfs.h line 71),
# so they get the samples that fit once compressed.
HAND = {
    1: ["tiny.txt"],
    3: ["tiny.txt", "small.txt"],
    7: ["tiny.txt", "small.txt"],
    9: ["tiny.txt"],
    11: ["tiny.txt", "small.txt"],
    13: ["small.txt"],
    4: ["mixed.bin"],
    8: ["mixed.bin"],                 # ditto/ holds the method 8 files macOS wrote itself
    10: ["blocks.txt"],
    12: ["block.txt", "blocks.txt", "mixed.bin"],
    14: ["blocks.txt"],
}


# The HFS+ image takes one file per method: it is there for the HFS+ walker's
# own path to the attribute and the resource fork, which the APFS image does
# not exercise.
HAND_HFS = {1: ["tiny.txt"], 3: ["small.txt"], 7: ["small.txt"], 9: ["tiny.txt"],
            11: ["small.txt"], 13: ["small.txt"], 4: ["mixed.bin"], 8: ["mixed.bin"],
            10: ["blocks.txt"], 12: ["mixed.bin"], 14: ["blocks.txt"]}


def build(out_dir, fs, mib):
    stem = {"APFS": "decmpfs-apfs", "HFS+": "decmpfs-hfsplus"}[fs]
    work = tempfile.mkdtemp(prefix="decmpfs-")
    mnt = os.path.join(work, "mnt")
    os.mkdir(mnt)
    dmg = os.path.join(work, "img.dmg")
    run = lambda *a: subprocess.run(a, check=True, stdin=subprocess.DEVNULL)
    run("hdiutil", "create", "-size", f"{mib}m", "-fs", fs, "-volname", "DECMPFS",
        "-type", "UDIF", "-layout", "NONE", "-quiet", dmg)
    run("hdiutil", "attach", dmg, "-nobrowse", "-readwrite", "-mountpoint", mnt, "-quiet")
    rows, bad = [], []
    try:
        samples = contents()
        src = os.path.join(work, "src")
        os.mkdir(src)
        for name, data in samples.items():
            with open(os.path.join(src, name), "wb") as fh:
                fh.write(data)
        # Apple's own compressor first, choosing its own method.
        if fs == "APFS":
            os.mkdir(os.path.join(mnt, "ditto"))
            run("ditto", "--hfsCompression", src, os.path.join(mnt, "ditto"))
        for method, names in (HAND if fs == "APFS" else HAND_HFS).items():
            folder = os.path.join(mnt, f"method{method:02d}")
            os.mkdir(folder)
            for name in names:
                hand_built(os.path.join(folder, name), method, samples[name])
        # A compression attribute on a file that is not flagged compressed: macOS
        # reads the data fork (xnu decmpfs.c 838 to 862), here empty for one file
        # and holding other bytes for the other, so a reader that decodes the
        # attribute gives the wrong content for both.
        folder = os.path.join(mnt, "unflagged")
        os.mkdir(folder)
        unflagged = {"empty.txt": b"", "small.txt": samples["small.txt"]}
        for name, fork in unflagged.items():
            path = os.path.join(folder, name)
            with open(path, "wb") as fh:
                fh.write(fork)
            set_attr(path, "com.apple.decmpfs",
                     header(9, len(samples["tiny.txt"])) + b"\xcc" + samples["tiny.txt"])
        subprocess.run(["sync"], check=True)
        for top in sorted(os.listdir(mnt)):
            folder = os.path.join(mnt, top)
            if not os.path.isdir(folder) or top.startswith("."):
                continue
            for name in sorted(os.listdir(folder)):
                path = os.path.join(folder, name)
                attr = decmpfs_attr(path)
                method = struct.unpack_from("<I", attr, 4)[0] if attr else 0
                try:
                    with open(path, "rb") as fh:
                        got = fh.read()
                except OSError as exc:
                    bad.append(f"macOS cannot read {top}/{name}: {exc}")
                    continue
                expect = unflagged[name] if top == "unflagged" else samples[name]
                if got != expect:
                    bad.append(f"macOS reads {top}/{name} as {len(got)} bytes that differ "
                               f"from the {len(expect)} written")
                    continue
                if top.startswith("method") and method != int(top[6:]):
                    bad.append(f"{top}/{name} holds method {method}")
                    continue
                rows.append((hashlib.sha256(got).hexdigest(), method, f"{top}/{name}"))
    finally:
        subprocess.run(["hdiutil", "detach", mnt, "-quiet"], check=False,
                       stdin=subprocess.DEVNULL)
    if bad:
        shutil.rmtree(work)
        raise SystemExit("\n".join(bad))
    img = os.path.join(out_dir, stem + ".img.gz")
    with open(dmg, "rb") as src_fh, gzip.GzipFile(img, "wb", mtime=0) as dst:
        shutil.copyfileobj(src_fh, dst)
    with open(os.path.join(out_dir, stem + ".sha256"), "w", encoding="utf-8") as fh:
        fh.write(f"# {fs} volume written by macOS; method is the decmpfs method the file\n"
                 f"# holds, and the hash is of what macOS itself read back through the\n"
                 f"# mounted volume. Built by tools/make_decmpfs_fixture.py\n")
        for digest, method, path in rows:
            fh.write(f"{digest}  {method:2d}  {path}\n")
    shutil.rmtree(work)
    return img, rows


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    for fs, mib in (("APFS", 8), ("HFS+", 8)):
        img, rows = build(out_dir, fs, mib)
        kinds = sorted({m for _d, m, _p in rows})
        print(f"{img}: {len(rows)} files, {os.path.getsize(img):,} bytes, methods {kinds}")


if __name__ == "__main__":
    main()
