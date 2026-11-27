#!/usr/bin/env python3
"""Keep only the files that can be Mach-O, from a NUL-separated path list.

Reads NUL-separated paths on stdin and writes, NUL-separated, the paths whose
first four bytes are a Mach-O or fat (universal) magic number. `file` only
calls a file Mach-O when it starts with one of these magics, so a caller that
runs `file` on each listed path sees every Mach-O it saw before, with one
process per Mach-O instead of one per file in the bundle (a cmux NEXT app has
thousands of files; the per-file `file` loops took 34 s and 90 s on a hosted
runner). Unreadable paths are dropped, as `file` failing on them was.
"""

import sys

MAGICS = {
    bytes.fromhex(magic)
    for magic in (
        "feedface", "cefaedfe",  # 32-bit Mach-O, both byte orders
        "feedfacf", "cffaedfe",  # 64-bit Mach-O
        "cafebabe", "bebafeca",  # fat
        "cafebabf", "bfbafeca",  # fat with 64-bit offsets
    )
}


def main() -> int:
    out = sys.stdout.buffer
    for path in sys.stdin.buffer.read().split(b"\0"):
        if not path:
            continue
        try:
            with open(path, "rb") as handle:
                head = handle.read(4)
        except OSError:
            continue
        if head in MAGICS:
            out.write(path + b"\0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
