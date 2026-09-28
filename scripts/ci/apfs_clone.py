#!/usr/bin/env python3
"""Clone a directory tree with one clonefile(2) call.

`cp -cR` clones file by file through copyfile(3): about 12 s of kernel time
for 50,000 files on an M-series Mac, and a kept DerivedData or a checkout has
more. One clonefile(2) on the directory made the same tree in about 1 s.
File contents, file and symlink times, modes and extended attributes come
across as with `cp -c`; every directory gets the current time, as `cp -R`
gives it. Apple discourages directory clonefile for very large trees because
the call is atomic; these are the trees CI already cloned whole.

`clone_directory` returns False, leaving DESTINATION absent, on any failure
(another volume, no clone support, not macOS, no space), so callers fall back
to the copy they made before.

Usage: apfs_clone.py SOURCE DESTINATION (exit 1 when not cloned).
"""
from __future__ import annotations

import ctypes
import ctypes.util
import os
import sys
from pathlib import Path

CLONE_NOFOLLOW = 0x0001


def clone_directory(source: Path, destination: Path) -> bool:
    """Clone SOURCE's tree to DESTINATION, which must not exist yet."""
    if sys.platform != "darwin" or not source.is_dir() or source.is_symlink():
        return False
    try:
        libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
        clonefile = libc.clonefile
    except (OSError, AttributeError):
        return False
    clonefile.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32)
    clonefile.restype = ctypes.c_int
    return clonefile(os.fsencode(source), os.fsencode(destination), CLONE_NOFOLLOW) == 0


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    return 0 if clone_directory(Path(argv[1]), Path(argv[2])) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
