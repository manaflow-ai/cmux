#!/usr/bin/env python3
"""Print the SHA-256 of the disk image inside a DMG, apart from its signature and staple.

usage: dmg_image_digest.py DMG

A UDIF DMG is its data fork (the compressed image blocks), the XML property list
that maps them, and a 512-byte `koly` trailer. Signing a DMG and stapling its ticket
add a code signature after the property list and rewrite the trailer; they never change
the data fork or the block map, so the volume the DMG mounts (and every byte of the app
in it) is the same before and after. The digest covers the data fork, the resource fork
and the property list, each with its length, read where the trailer says they are.

nightly.yml's launch-smoke-nightly smokes the app in the unsigned DMG signer-dmg-image
built while signer-dmg signs, notarizes and staples that DMG; verify-final-dmg-nightly
reads this digest of the final DMG, and publish-nightly publishes the pool-signed build
only when the two are equal.
"""
from __future__ import annotations

import hashlib
import struct
import sys

TRAILER = 512


def image_digest(path: str) -> str:
    with open(path, "rb") as handle:
        handle.seek(0, 2)
        size = handle.tell()
        if size < TRAILER:
            raise ValueError(f"{path}: {size} bytes, too short for a DMG")
        handle.seek(size - TRAILER)
        koly = handle.read(TRAILER)
        if koly[:4] != b"koly":
            raise ValueError(f"{path}: no koly trailer")
        header_size = struct.unpack(">I", koly[8:12])[0]
        if header_size != TRAILER:
            raise ValueError(f"{path}: koly header size {header_size}")
        data_offset, data_length, rsrc_offset, rsrc_length = struct.unpack(">QQQQ", koly[24:56])
        xml_offset, xml_length = struct.unpack(">QQ", koly[216:232])
        digest = hashlib.sha256()
        for name, offset, length in (("data", data_offset, data_length), ("rsrc", rsrc_offset, rsrc_length),
                                     ("xml", xml_offset, xml_length)):
            if offset + length > size - TRAILER:
                raise ValueError(f"{path}: the {name} fork runs past the trailer")
            digest.update(struct.pack(">4sQ", name.encode(), length))
            handle.seek(offset)
            left = length
            while left:
                chunk = handle.read(min(left, 1 << 20))
                if not chunk:
                    raise ValueError(f"{path}: the {name} fork is truncated")
                digest.update(chunk)
                left -= len(chunk)
        if not data_length or not xml_length:
            raise ValueError(f"{path}: no data fork or no block map")
        return digest.hexdigest()


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__.splitlines()[2], file=sys.stderr)
        return 2
    try:
        print(image_digest(argv[1]))
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
