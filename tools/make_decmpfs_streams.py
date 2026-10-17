#!/usr/bin/env python3
"""Write tests/fixtures/decmpfs-streams.json: LZVN and LZFSE streams made by
Apple's own encoder, with the SHA-256 of what each was made from, for
qnxprobe's self-test to decode on any platform.

Runs on macOS: the streams come from libcompression's
compression_encode_buffer (COMPRESSION_LZVN, COMPRESSION_LZFSE), and every
stream is decoded back with libcompression's compression_decode_buffer before
it is written, so each entry is Apple's encoder checked by Apple's decoder.
Neither is the reader the file is used to test.

One entry is not an encoder's output. Apple's encoder writes the v2 block
header (bvx2), whose frequency tables are packed; the reference decoder also
reads a v1 header (bvx1) with the tables written out in full
(lzfse/lzfse src/lzfse_internal.h lines 291 to 330), which no encoder here
writes. That entry is a bvx2 stream with its header rewritten as v1 by this
script, and it is recorded only if libcompression decodes it to the same
bytes.

    python3 tools/make_decmpfs_streams.py tests/fixtures/decmpfs-streams.json
"""
import base64
import ctypes
import hashlib
import json
import random
import struct
import sys

LZFSE, LZVN = 0x801, 0x900
lib = ctypes.CDLL("/usr/lib/libcompression.dylib")
for fn in (lib.compression_encode_buffer, lib.compression_decode_buffer):
    fn.restype = ctypes.c_size_t
    fn.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t,
                   ctypes.c_void_p, ctypes.c_int]


def encode(data, algorithm):
    buf = ctypes.create_string_buffer(2 * len(data) + 4096)
    n = lib.compression_encode_buffer(buf, len(buf), data, len(data), None, algorithm)
    if not n:
        raise SystemExit(f"libcompression would not encode {len(data)} bytes")
    return buf.raw[:n]


def decode(blob, algorithm, size):
    buf = ctypes.create_string_buffer(size + 1024)
    n = lib.compression_decode_buffer(buf, len(buf), blob, len(blob), None, algorithm)
    return buf.raw[:n]


def v2_to_v1(blob):
    """The stream with its first block's bvx2 header rewritten as bvx1. The
    packed fields are unpacked as lzfse_decode_base.c lines 72 to 104 read them
    and the frequencies decoded as lines 105 to 142 do, then written out in the
    v1 struct's order (lzfse_internal.h 291 to 330), padded to the 772 bytes
    sizeof() gives it."""
    assert blob[:4] == b"bvx2"
    raw, v0, v1, v2 = struct.unpack_from("<IQQQ", blob, 4)
    size = v2 & 0xFFFFFFFF
    nbits_t = (2, 3, 2, 5, 2, 3, 2, 8, 2, 3, 2, 5, 2, 3, 2, 14) * 2
    value_t = (0, 2, 1, 4, 0, 3, 1, -1, 0, 2, 1, 5, 0, 3, 1, -1,
               0, 2, 1, 6, 0, 3, 1, -1, 0, 2, 1, 7, 0, 3, 1, -1)
    freqs, accum, nbits, at = [], 0, 0, 32
    for _ in range(360):
        while at < size and nbits + 8 <= 32:
            accum |= blob[at] << nbits
            nbits, at = nbits + 8, at + 1
        low = accum & 31
        take = nbits_t[low]
        value = (8 + ((accum >> 4) & 0xF) if take == 8 else
                 24 + ((accum >> 4) & 0x3FF) if take == 14 else value_t[low])
        freqs.append(value)
        accum, nbits = accum >> take, nbits - take
    f = lambda v, o, n: (v >> o) & ((1 << n) - 1)
    n_lit, n_lit_pay, n_match = f(v0, 0, 20), f(v0, 20, 20), f(v0, 40, 20)
    lit_bits, lmd_bits = f(v0, 60, 3) - 7, f(v1, 60, 3) - 7
    n_lmd_pay = f(v1, 40, 20)
    head = struct.pack("<4sIIIIIIi4HiHHH", b"bvx1", raw, n_lit_pay + n_lmd_pay, n_lit, n_match,
                       n_lit_pay, n_lmd_pay, lit_bits, f(v1, 0, 10), f(v1, 10, 10),
                       f(v1, 20, 10), f(v1, 30, 10), lmd_bits, f(v2, 32, 10), f(v2, 42, 10),
                       f(v2, 52, 10))
    head += struct.pack("<360H", *freqs)
    head += bytes(772 - len(head))
    return head + blob[size:]


def block_list(blob):
    """The magic of each block in order, walked by each block's own sizes."""
    out, p = [], 0
    while p + 4 <= len(blob):
        magic = blob[p:p + 4]
        out.append(magic.decode())
        if magic == b"bvx$":
            break
        if magic == b"bvx-":
            p += 8 + struct.unpack_from("<I", blob, p + 4)[0]
        elif magic == b"bvxn":
            p += 12 + struct.unpack_from("<I", blob, p + 8)[0]
        elif magic == b"bvx2":
            _raw, v0, v1, v2 = struct.unpack_from("<IQQQ", blob, p + 4)
            p += (v2 & 0xFFFFFFFF) + ((v0 >> 20) & 0xFFFFF) + ((v1 >> 40) & 0xFFFFF)
        elif magic == b"bvx1":
            p += 772 + sum(struct.unpack_from("<II", blob, p + 20))
        else:
            raise SystemExit(f"unexpected block {magic!r}")
    return out


def main():
    out_path = sys.argv[1]
    rng = random.Random(1017)
    words = [bytes(rng.choice(b"abcdefgh") for _ in range(rng.randint(2, 6))) for _ in range(24)]

    def text(n):
        out = bytearray()
        while len(out) < n:
            out += rng.choice(words) + b" "
        return bytes(out[:n])

    samples = {
        "short text, one raw block": (LZFSE, text(60)),
        "text, one LZVN block": (LZFSE, text(3000)),
        "text, one LZFSE block": (LZFSE, text(20000)),
        # two bvx2 blocks: a block holds at most 10,000 matches
        # (lzfse_internal.h line 97), and this needs more
        "two LZFSE blocks": (LZFSE, bytes(rng.choice(b"ab") for _ in range(80000))),
        "incompressible, one raw block": (LZFSE, rng.randbytes(700)),
        "LZVN, text": (LZVN, text(20000)),
        "LZVN, bytes and runs": (LZVN, rng.randbytes(300) + bytes(5000) + b"ab" * 900),
    }
    entries = []
    for name, (alg, data) in samples.items():
        blob = encode(data, alg)
        if decode(blob, alg, len(data)) != data:
            raise SystemExit(f"libcompression does not decode its own {name}")
        magics = block_list(blob) if alg == LZFSE else []
        entries.append({"name": name, "codec": "LZFSE" if alg == LZFSE else "LZVN",
                        "size": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                        "blocks": magics, "stream": base64.b64encode(blob).decode()})
    data = text(20000)
    blob = v2_to_v1(encode(data, LZFSE))
    if decode(blob, LZFSE, len(data)) != data:
        raise SystemExit("libcompression does not decode the v1 rewrite")
    entries.append({"name": "one LZFSE block with a v1 header", "codec": "LZFSE",
                    "size": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                    "blocks": block_list(blob), "stream": base64.b64encode(blob).decode()})
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump({"about": "LZVN and LZFSE streams from Apple's libcompression, each decoded "
                            "back by libcompression; tools/make_decmpfs_streams.py",
                   "streams": entries}, fh, indent=1)
        fh.write("\n")
    for e in entries:
        print(f"{e['codec']:5} {e['size']:7,} -> {len(base64.b64decode(e['stream'])):6,}  "
              f"{' '.join(e['blocks'])}  {e['name']}")


if __name__ == "__main__":
    main()
