#!/usr/bin/env python3
"""Read the EFS image QNX itself wrote and hold the reading against its record.

    python3 tools/check_efs_reference_image.py [DIRECTORY]

NetherlandsForensicInstitute/qnxmount (Apache-2.0) commits a 2 MiB EFS image
made on QNX: mkefs formatted it, the devf-ram flash driver mounted it, and
tests/qnx_efs/test_data/make_test_fs.sh wrote files to it, overwrote part of
one, copied one and removed the original, then archived the mounted tree with
tar. The image is not kept in this repository. This fetches it and the tar
from the commit below into DIRECTORY (a temporary one when none is given),
checks both against the SHA-256 recorded here, and compares:

  * every live entry: kind, permission bits, mtime, and file content or link
    target, against the tar QNX made from the same mounted filesystem;
  * the removed file: the script wrote 16 random bytes to this_file_is_removed,
    copied it to this_file_is_a_copy and removed it, so recover_deleted() has
    to return a deleted file of that name whose bytes are the copy's;
  * the overwrite: the script rewrote 10 blocks of 1 KiB at block 5 of
    this_file_is_large, so the superseded extents of that file have to hold
    10,240 bytes that are not what the file holds there now;
  * unaccounted(): no programmed byte outside the extent table.

Exits 1 when any of them fails. Needs the network once.
"""
import hashlib
import os
import sys
import tarfile
import tempfile
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import qnxprobe  # noqa: E402  pylint: disable=wrong-import-position

COMMIT = "11c8a7f9ee9b945d584263743f6ea8524e8776d2"
URL = ("https://raw.githubusercontent.com/NetherlandsForensicInstitute/qnxmount/"
       f"{COMMIT}/tests/qnx_efs/test_data/")
FILES = {"test_image.bin": "0b0dc3a5b95320f20721093fadf3a08f52f80227e1ec60db5e1fbaf2877f92b3",
         "test_image.tar.gz": "dd60372bad552278770de8c8ea0716ec6dfb5031d09e90cd2e5f5d20b8e5a1ac"}
S_IFMT, S_IFDIR, S_IFREG, S_IFLNK, S_IFIFO = 0o170000, 0o040000, 0o100000, 0o120000, 0o010000


def fetch(directory):
    for name, want in FILES.items():
        path = os.path.join(directory, name)
        if not os.path.isfile(path):
            with urllib.request.urlopen(URL + name) as resp, open(path, "wb") as out:
                out.write(resp.read())
        with open(path, "rb") as fh:
            got = hashlib.sha256(fh.read()).hexdigest()
        if got != want:
            raise SystemExit(f"{name}: sha256 {got}, expected {want}")


def tar_tree(path):
    out = {}
    with tarfile.open(path) as tf:
        for m in tf.getmembers():
            kind = (S_IFDIR if m.isdir() else S_IFLNK if m.issym() else S_IFIFO if m.isfifo()
                    else S_IFREG)
            body = (tf.extractfile(m).read() if m.isfile()
                    else m.linkname.encode() if m.issym() else None)
            out[m.name.strip("/")] = (kind, m.mode & 0o7777, m.mtime, body)
    return out


def walker_tree(w):
    out, stack = {}, [(w.root, "")]
    while stack:
        node, path = stack.pop()
        for name, child in w.listdir(node):
            mode, size, mtime = w.entry(child)
            cpath = f"{path}/{name}" if path else name
            body = (b"".join(w.read_file(child, size))
                    if mode & S_IFMT in (S_IFREG, S_IFLNK) else None)
            out[cpath] = (mode & S_IFMT, mode & 0o7777, mtime, body)
            if mode & S_IFMT == S_IFDIR:
                stack.append((child, cpath))
    return out


def check(directory):
    fetch(directory)
    image = os.path.join(directory, "test_image.bin")
    size = os.path.getsize(image)
    problems = []
    with open(image, "rb") as fh:
        vols = qnxprobe.volumes(fh, size)
        if [v["kind"] for v in vols] != ["efs"] or "walker" not in vols[0]:
            return [f"volumes() gave {[(v['kind'], v.get('note')) for v in vols]}"]
        w = vols[0]["walker"]
        got, want = walker_tree(w), tar_tree(os.path.join(directory, "test_image.tar.gz"))
        same = sum(1 for k in got if got[k] == want.get(k))
        print(f"live entries: {same} of {len(got)} as the tar has them, "
              f"{len(want)} in the tar")
        if got != want:
            problems.append("the live tree is not the tar's: "
                            f"{sorted(k for k in set(got) | set(want) if got.get(k) != want.get(k))}")
        entries = list(w.recover_deleted())
        removed = [e for e in entries if e.name == "this_file_is_removed"
                   and e.note.startswith("a deleted file")]
        copy = got.get("this_file_is_a_copy", (0, 0, 0, None))[3]
        if (len(removed) != 1 or not removed[0].recoverable or copy is None
                or b"".join(w.read_deleted(removed[0])) != copy):
            problems.append("this_file_is_removed did not come back with its copy's bytes")
        else:
            print(f"removed file: recovered by name, its {removed[0].size} bytes are the "
                  "copy's, folder " + repr(removed[0].parent_path))
        large = got.get("this_file_is_large", (0, 0, 0, b""))[3]
        old = [e for e in entries if e.name == "this_file_is_large"]
        old_bytes = b"".join(b"".join(w.read_deleted(e)) for e in old)
        states = {state for e in old for _off, _n, state in w.deleted_extents(e)}
        if (len(old_bytes) != 10 * 1024 or states != {"allocated, superseded"}
                or old_bytes == large[5 * 1024:15 * 1024]):
            problems.append(f"this_file_is_large: {len(old_bytes)} superseded bytes in "
                            f"{len(old)} entries, states {sorted(states)}")
        else:
            print(f"overwrite: {len(old_bytes):,} superseded bytes of this_file_is_large, "
                  "all allocated with a supersede pointer, and not what the file holds "
                  "there now")
        other = [e for e in entries if e not in removed and e not in old]
        if other:
            problems.append(f"{len(other)} entries the script's history does not account for")
        total, stray = w.unaccounted()
        print(f"unaccounted: {total:,} bytes no extent covers, {stray} of them not 0xFF")
        if stray:
            problems.append(f"{stray} programmed bytes outside the extent table")
    return problems


def main():
    if len(sys.argv) > 1:
        os.makedirs(sys.argv[1], exist_ok=True)
        problems = check(sys.argv[1])
    else:
        with tempfile.TemporaryDirectory() as d:
            problems = check(d)
    for line in problems:
        print("PROBLEM", line)
    print("FAILED" if problems else "all checks hold")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
