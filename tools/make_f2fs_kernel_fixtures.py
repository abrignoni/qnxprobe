#!/usr/bin/env python3
"""Cut two F2FS images the Linux kernel wrote down to committed fixtures.

    make_f2fs_kernel_fixtures.py IMAGE_DIR tests/fixtures

IMAGE_DIR holds images written by Linux 7.0 with f2fs-tools 1.16.0, each with a manifest of
what the kernel read back (mtime, size, sha256, path):

- rf_unclean.img, rf.manifest: mkfs with extra_attr, inode_checksum, flexible_inline_xattr,
  inode_crtime and sb_checksum. Mounted with nodiscard, one file written and synced, then 20
  files each written and fsynced. The image was copied while still mounted, before another
  checkpoint, so those 20 files are only in the roll-forward log. The manifest was read
  from the mount.
- cp.img, cp.manifest: mkfs with extra_attr, inode_checksum, flexible_inline_xattr,
  inode_crtime and compression. Mounted with compress_algorithm=lz4,compress_extension=bin.
  The manifest was read after a read-only mount.

Two things are done to keep the fixtures small. Zero blocks at the end of an image are left
out, and the self-test puts them back. On the LZ4 image the data blocks of incompressible.bin
(1 MiB of random bytes) are zeroed and the file is left out of the list. compressible.bin
and mixed.bin, which hold compressed and plain clusters, are as the kernel wrote them.
"""
import gzip
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("qnxprobe_tool", os.path.join(HERE, "qnxprobe.py"))
Q = importlib.util.module_from_spec(SPEC)
sys.modules["qnxprobe_tool"] = Q
SPEC.loader.exec_module(Q)


def manifest(path):
    out = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            _when, _size, digest, name = line.rstrip("\n").split(None, 3)
            out[name[2:] if name.startswith("./") else name] = digest
    return out


def write(raw, known, stem, out_dir, comment):
    end = len(raw.rstrip(b"\0"))
    end = (end + 4095) // 4096 * 4096
    with open(os.path.join(out_dir, stem + ".img.gz"), "wb") as fh:
        fh.write(gzip.compress(bytes(raw[:end]), 9, mtime=0))
    with open(os.path.join(out_dir, stem + ".sha256"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(f"# {comment}\n")
        for name in sorted(known):
            fh.write(f"{known[name]}  {name}\n")


def main(src, out_dir):
    with open(os.path.join(src, "rf_unclean.img"), "rb") as fh:
        raw = bytearray(fh.read())
    write(raw, manifest(os.path.join(src, "rf.manifest")), "f2fs-rollforward", out_dir,
          "what Linux 7.0 read back; 20 of these files are only in the roll-forward log")

    with open(os.path.join(src, "cp.img"), "rb") as fh:
        raw = bytearray(fh.read())
        w = Q.F2fsWalker(fh, 0)
        nid = dict((p, n) for p, n, _s, _m in Q.collect(w, w.root))["incompressible.bin"]
        ino = w.inode(nid)
        for logical in range((ino["size"] + w.bs - 1) // w.bs):
            addr = w._block_of(ino, logical)                 # pylint: disable=protected-access
            if addr not in (Q.F2FS_NULL_ADDR, Q.F2FS_NEW_ADDR, Q.F2FS_COMPRESS_ADDR):
                raw[addr * w.bs:(addr + 1) * w.bs] = bytes(w.bs)
    known = manifest(os.path.join(src, "cp.manifest"))
    del known["incompressible.bin"]
    write(raw, known, "f2fs-lz4", out_dir,
          "what Linux 7.0 read back from an LZ4 volume; incompressible.bin was zeroed and is "
          "not listed")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
