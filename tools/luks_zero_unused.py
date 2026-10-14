#!/usr/bin/env python3
"""Zero the keyslot space of a LUKS image that no active keyslot uses.

usage: luks_zero_unused.py IMAGE [IMAGE ...]

cryptsetup fills the whole keyslot area with random bytes when it formats a
LUKS device, and reads only the areas of the keyslots that are in use. Random
bytes do not compress, so a test image would carry about a megabyte of them for
nothing. This writes zeros over the rest, and nothing else: the headers, the
used keyslot areas and the data are untouched. tools/make_luks_fixtures.sh runs
it, then checks with cryptsetup that every passphrase still opens the image.

LUKS1 (cryptsetup docs/on-disk-format.pdf): a big-endian header whose eight
keyslots, from byte 208, are 48 bytes each: active (0x00AC71F3 when enabled),
iterations, a 32-byte salt, the key material's offset in sectors and its stripe
count; the material is key bytes times stripes long. The area runs from the end
of the header to the payload offset.

LUKS2 (docs/on-disk-format-luks2.pdf): the JSON in the first header names each
keyslot's area (offset and size in bytes) and the keyslots area's size; that
area starts after the two copies of the header, at twice the header size.
"""
import json
import struct
import sys

SECTOR = 512


def _zero(buf, start, end, keep):
    """Zero [start, end) of buf except the ranges in keep."""
    at = start
    for k_start, k_end in sorted(keep) + [(end, end)]:
        if k_start > at:
            buf[at:min(k_start, end)] = bytes(min(k_start, end) - at)
        at = max(at, k_end)


def zero_unused(buf):
    if buf[:6] != b"LUKS\xba\xbe":
        raise ValueError("not a LUKS header")
    version, = struct.unpack_from(">H", buf, 6)
    if version == 1:
        payload, key_bytes = struct.unpack_from(">II", buf, 104)
        keep = []
        for i in range(8):
            active, _it, = struct.unpack_from(">II", buf, 208 + 48 * i)
            off, stripes = struct.unpack_from(">II", buf, 208 + 48 * i + 40)
            if active == 0x00AC71F3:
                length = -(-key_bytes * stripes // SECTOR) * SECTOR
                keep.append((off * SECTOR, off * SECTOR + length))
        _zero(buf, 592, payload * SECTOR, keep)
        return
    if version == 2:
        hdr_size, = struct.unpack_from(">Q", buf, 8)
        meta = json.loads(bytes(buf[4096:hdr_size]).split(b"\0", 1)[0])
        start = 2 * hdr_size
        end = start + int(meta["config"]["keyslots_size"])
        keep = [(int(k["area"]["offset"]), int(k["area"]["offset"]) + int(k["area"]["size"]))
                for k in meta["keyslots"].values()]
        _zero(buf, start, end, keep)
        return
    raise ValueError(f"LUKS version {version}")


if __name__ == "__main__":
    for path in sys.argv[1:]:
        with open(path, "r+b") as f:
            data = bytearray(f.read())
            zero_unused(data)
            f.seek(0)
            f.write(data)
        print("zeroed unused keyslot space in", path)
