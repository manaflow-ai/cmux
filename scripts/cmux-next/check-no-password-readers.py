#!/usr/bin/env python3
"""Exit 1 when any Mach-O file under the given paths still carries the browser
password readers that CMUX_NO_PASSWORD_IMPORT compiles out (cx-f58x notary test).

Markers are code-only: a reader type's name as a NUL-terminated string (its
Swift type descriptor) and the key4.db table name only the Firefox reader uses.
Source file names (ChromiumLoginDataReader.swift, kept in the objects of a
flagged build) are not markers.

Usage: check-no-password-readers.py PATH...   (a .app, a directory or files)
"""

from __future__ import annotations

import os
import re
import sys

TYPES = ("ChromiumLoginDataReader", "ChromiumPasswordCrypto", "FirefoxLoginReader",
         "FirefoxPasswordCrypto", "NSSDER")
MARKERS = [re.compile(rb"(?<![A-Za-z0-9_])" + name.encode() + rb"\x00") for name in TYPES]
MARKERS.append(re.compile(rb"nssPrivate"))
MACHO = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}


def files(paths: list[str]):
    for path in paths:
        if os.path.isfile(path):
            yield path
            continue
        for root, _, names in os.walk(path):
            for name in names:
                yield os.path.join(root, name)


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    hits: list[str] = []
    scanned = 0
    for path in files(sys.argv[1:]):
        if os.path.islink(path):
            continue
        try:
            with open(path, "rb") as handle:
                if handle.read(4) not in MACHO:
                    continue
                handle.seek(0)
                data = handle.read()
        except OSError:
            continue
        scanned += 1
        found = sorted({m.pattern.decode("latin-1") for m in MARKERS if m.search(data)})
        if found:
            hits.append(f"{path}: {', '.join(found)}")
    if scanned == 0:
        print("check-no-password-readers: no Mach-O file under the given paths", file=sys.stderr)
        return 2
    if hits:
        print("the password readers are still compiled in:", *hits, sep="\n  ", file=sys.stderr)
        return 1
    print(f"check-no-password-readers: none of {scanned} Mach-O files carries the password readers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
