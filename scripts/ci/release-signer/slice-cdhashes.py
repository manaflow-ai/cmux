#!/usr/bin/env python3
"""Print arch=CDHash for every slice of a bundle's main executable.

    slice-cdhashes.py <bundle>

The same lines as slice_cdhashes in scripts/ci/lib/notarization-ticket.sh,
which reads them with lipo and codesign -d; this reads the Mach-O code
signature directly, so it runs where those tools do not. A slice's CDHash is
the digest of its best CodeDirectory (SHA-256 over SHA-1), cut to 20 bytes.
"""

from __future__ import annotations

import hashlib
import pathlib
import plistlib
import struct
import sys

ARCHS = {(0x0100000C, 2): "arm64e", 0x0100000C: "arm64", 0x01000007: "x86_64"}
LC_CODE_SIGNATURE = 0x1D
HASHES = {1: hashlib.sha1, 2: hashlib.sha256}


def slices(data: bytes):
    magic = data[:4]
    if magic in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        wide = magic == b"\xca\xfe\xba\xbf"
        count = struct.unpack(">I", data[4:8])[0]
        size = 32 if wide else 20
        for i in range(count):
            entry = data[8 + i * size:8 + (i + 1) * size]
            cpu, sub = struct.unpack(">ii", entry[:8])
            offset, length = struct.unpack(">QQ" if wide else ">II", entry[8:24 if wide else 16])
            yield cpu & 0xFFFFFFFF, sub & 0xFF, data[offset:offset + length]
    elif magic == b"\xcf\xfa\xed\xfe":
        cpu, sub = struct.unpack("<II", data[4:12])
        yield cpu, sub & 0xFF, data
    else:
        sys.exit("error: not a 64-bit Mach-O file")


def cdhash(macho: bytes) -> str:
    ncmds = struct.unpack("<I", macho[16:20])[0]
    offset = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", macho[offset:offset + 8])
        if cmd == LC_CODE_SIGNATURE:
            dataoff, datasize = struct.unpack("<II", macho[offset + 8:offset + 16])
            blob = macho[dataoff:dataoff + datasize]
            break
        offset += size
    else:
        sys.exit("error: the slice has no code signature")
    if blob[:4] != b"\xfa\xde\x0c\xc0":
        sys.exit("error: the code signature is not an embedded signature")
    best = None
    for i in range(struct.unpack(">I", blob[8:12])[0]):
        slot, at = struct.unpack(">II", blob[12 + i * 8:20 + i * 8])
        if slot != 0 and not 0x1000 <= slot < 0x1005:
            continue
        magic, length = struct.unpack(">II", blob[at:at + 8])
        kind = blob[at + 37]
        if magic == 0xFADE0C02 and kind in HASHES and (best is None or kind > best[0]):
            best = (kind, blob[at:at + length])
    if best is None:
        sys.exit("error: the code signature has no CodeDirectory")
    return HASHES[best[0]](best[1]).hexdigest()[:40]


def main() -> None:
    bundle = pathlib.Path(sys.argv[1])
    with (bundle / "Contents/Info.plist").open("rb") as handle:
        name = plistlib.load(handle)["CFBundleExecutable"]
    if not name or pathlib.Path(name).name != name:
        sys.exit("error: invalid CFBundleExecutable")
    seen = {}
    for cpu, sub, macho in slices((bundle / "Contents/MacOS" / name).read_bytes()):
        arch = ARCHS.get((cpu, sub)) or ARCHS.get(cpu) or sys.exit(f"error: unknown CPU type {cpu:#x}")
        seen[arch] = cdhash(macho)
    for arch in sorted(seen):
        print(f"{arch}={seen[arch]}")


if __name__ == "__main__":
    main()
