#!/usr/bin/env python3
"""Prints, NUL-separated, every Mach-O file under DIR that has LC_ATOM_INFO.

    scripts/find-atom-info-macho.py DIR

LC_ATOM_INFO is the link data of a mergeable library (ld -make_mergeable): a
static link into another image reads it, dyld never does. Prebuilt
frameworks such as Sentry.framework ship it. strip-release-bundle.sh removes
it with `strip -no_atom_info`. Thin and fat images are read; symlinks are
skipped, so a framework's top-level link is reported once, by its target.
"""

from __future__ import annotations

import os
import struct
import sys

LC_ATOM_INFO = 0x36
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC, FAT_MAGIC_64 = 0xCAFEBABE, 0xCAFEBABF


def slice_offsets(f) -> list[int]:
    """File offsets of the 64-bit Mach-O images in f."""
    head = f.read(8)
    if len(head) < 8:
        return []
    if struct.unpack("<I", head[:4])[0] == MH_MAGIC_64:
        return [0]
    magic, count = struct.unpack(">II", head)
    if magic not in (FAT_MAGIC, FAT_MAGIC_64) or count > 32:
        return []
    size = 20 if magic == FAT_MAGIC else 32
    table = f.read(size * count)
    offsets = []
    for i in range(count):
        entry = table[i * size:(i + 1) * size]
        if magic == FAT_MAGIC:
            offsets.append(struct.unpack(">I", entry[8:12])[0])
        else:
            offsets.append(struct.unpack(">Q", entry[8:16])[0])
    return offsets


def has_atom_info(path: str) -> bool:
    with open(path, "rb") as f:
        for off in slice_offsets(f):
            f.seek(off)
            header = f.read(32)
            if len(header) < 32 or struct.unpack("<I", header[:4])[0] != MH_MAGIC_64:
                continue
            ncmds, sizeofcmds = struct.unpack("<II", header[16:24])
            cmds = f.read(sizeofcmds)
            p = 0
            for _ in range(ncmds):
                if p + 8 > len(cmds):
                    break
                cmd, cmdsize = struct.unpack("<II", cmds[p:p + 8])
                if cmd == LC_ATOM_INFO:
                    return True
                if cmdsize < 8:
                    break
                p += cmdsize
    return False


def main(root: str) -> int:
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            try:
                if has_atom_info(path):
                    sys.stdout.write(path + "\0")
            except (OSError, struct.error):
                continue
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
