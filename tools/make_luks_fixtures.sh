#!/usr/bin/env bash
# Build tests/fixtures/luks-*.img.gz, luks-fixtures.json and luks-fixture.sha256.
#
# Runs on Linux as root with cryptsetup and e2fsprogs. cryptsetup writes every
# byte of LUKS structure; its own luksDump of each image is saved in
# luks-fixtures.json as the known layout, beside the passphrases (test values,
# made up here), and the file hashes come from sha256sum over the source tree.
#   luks2-argon2id.img  LUKS2, aes-xts-plain64, 512-bit key, argon2id (small memory so a
#                       test can derive it), and a second keyslot with another passphrase
#   luks2-pbkdf2.img    LUKS2, aes-xts-plain64, 256-bit key, pbkdf2-sha256
#   luks1-xts.img       LUKS1, aes-xts-plain64, 512-bit key, sha256
#   luks1-cbc.img       LUKS1, aes-cbc-essiv:sha256, 256-bit key, sha1
# Each holds ext4 with the same tree.
set -euo pipefail
out=${1:-$(cd "$(dirname "$0")/.." && pwd)/tests/fixtures}
work=$(mktemp -d)
open_maps=()
cleanup() {
    for m in "${open_maps[@]:-}"; do [ -n "$m" ] && cryptsetup close "$m" 2>/dev/null || true; done
    rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$work/tree/docs"
python3 - "$work/tree" <<'PY'
import hashlib, os, sys
os.chdir(sys.argv[1])
def blocks(n, tag):
    out = bytearray()
    for i in range(n):
        head = f"{tag} block {i:08d}\n".encode()
        fill = hashlib.sha256(f"{tag}{i}".encode()).hexdigest().encode() * 64
        out += (head + fill)[:4096]
    return bytes(out)
open('docs/sectors.bin', 'wb').write(blocks(96, 'luks'))        # 384 KiB, across many sectors
open('readme.txt', 'w').write('this filesystem is inside a LUKS container\n')
PY
(cd "$work/tree" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sed 's|  \./|  |') > "$out/luks-fixture.sha256"
P1='correct horse battery staple'
P2='second keyslot passphrase'
make() {   # name, size MiB, then cryptsetup luksFormat options
    local name=$1 mib=$2; shift 2
    truncate -s "${mib}M" "$work/$name.img"
    printf '%s' "$P1" | cryptsetup luksFormat -q --key-file - "$@" "$work/$name.img"
    printf '%s' "$P1" | cryptsetup open --key-file - "$work/$name.img" "qp_$name"
    open_maps+=("qp_$name")
    # no journal and lazily initialised inode tables: what mkfs writes through the
    # cipher is ciphertext, which does not compress, so it writes as little as it can
    mkfs.ext4 -q -L "$name" -O ^has_journal -E lazy_itable_init=1,nodiscard \
        -d "$work/tree" "/dev/mapper/qp_$name"
    cryptsetup close "qp_$name"
    # LUKS2 metadata is JSON already; a LUKS1 header is dumped as text. Each goes to
    # its file only when the dump worked, so a failed dump leaves no empty file.
    if cryptsetup luksDump --dump-json-metadata "$work/$name.img" > "$work/$name.tmp" 2>/dev/null; then
        mv "$work/$name.tmp" "$work/$name.json"
    else
        rm -f "$work/$name.tmp"
        cryptsetup luksDump "$work/$name.img" > "$work/$name.txt"
    fi
}
make luks2-argon2id 5 --type luks2 --luks2-metadata-size 16k --luks2-keyslots-size 1m \
     --cipher aes-xts-plain64 --key-size 512 \
     --pbkdf argon2id --pbkdf-memory 8192 --pbkdf-parallel 1 --pbkdf-force-iterations 4
printf '%s\n%s' "$P1" "$P2" > "$work/keys"
printf '%s' "$P2" > "$work/newkey"
printf '%s' "$P1" | cryptsetup luksAddKey -q --key-file - --pbkdf argon2id --pbkdf-memory 8192 \
     --pbkdf-parallel 1 --pbkdf-force-iterations 4 "$work/luks2-argon2id.img" "$work/newkey"
cryptsetup luksDump --dump-json-metadata "$work/luks2-argon2id.img" > "$work/luks2-argon2id.json"
make luks2-pbkdf2 5 --type luks2 --luks2-metadata-size 16k --luks2-keyslots-size 1m \
     --cipher aes-xts-plain64 --key-size 256 \
     --pbkdf pbkdf2 --hash sha256 --pbkdf-force-iterations 1000
make luks1-xts 6 --type luks1 --cipher aes-xts-plain64 --key-size 512 --hash sha256 \
     --pbkdf-force-iterations 1000
make luks1-cbc 5 --type luks1 --cipher aes-cbc-essiv:sha256 --key-size 256 --hash sha1 \
     --pbkdf-force-iterations 1000
python3 - "$work" "$out" "$P1" "$P2" "$(cryptsetup --version)" <<'PY'
import json, os, sys
work, out, p1, p2, version = sys.argv[1:6]
d = {"written_by": version, "passphrases": [p1, p2], "images": {}}
for name in ("luks2-argon2id", "luks2-pbkdf2", "luks1-xts", "luks1-cbc"):
    meta = {}
    if os.path.exists(f"{work}/{name}.json"):
        meta["luks2_metadata"] = json.load(open(f"{work}/{name}.json"))
    if os.path.exists(f"{work}/{name}.txt"):
        meta["luksDump"] = open(f"{work}/{name}.txt").read()
    d["images"][name] = meta
json.dump(d, open(f"{out}/luks-fixtures.json", "w"), indent=1)
PY
# cryptsetup fills the whole keyslot area with random bytes; zero what no active
# keyslot uses (luks_zero_unused.py), so the images compress, then check that every
# passphrase still opens each one and that a wrong one does not.
python3 "$(dirname "$0")/luks_zero_unused.py" "$work"/luks*.img
for n in luks2-argon2id luks2-pbkdf2 luks1-xts luks1-cbc; do
    printf '%s' "$P1" | cryptsetup open --test-passphrase --key-file - "$work/$n.img"
    if printf '%s' 'not the passphrase' | cryptsetup open --test-passphrase --key-file - "$work/$n.img" 2>/dev/null; then
        echo "$n opened with a wrong passphrase"; exit 1
    fi
done
printf '%s' "$P2" | cryptsetup open --test-passphrase --key-file - "$work/luks2-argon2id.img"
for n in luks2-argon2id luks2-pbkdf2 luks1-xts luks1-cbc; do gzip -9 -c "$work/$n.img" > "$out/$n.img.gz"; done
ls -la "$out"/luks-*
