#!/usr/bin/env python3
"""Point a restored product's package-framework rpath at its own frameworks.

Debug builds link every Mach-O with an absolute rpath to the DerivedData they
were compiled in, <root>/derived-data-compile-admission/Build/Products/Debug/
PackageFrameworks, ahead of the bundle-relative ones. A consumer restores the
product into its own DerivedData, but on an owned Mac that producer path often
still exists: it is the canonical root's kept build, from another commit. dyld
then loads that commit's package frameworks first and aborts on a missing
symbol (the bundled CLI failing every CLI test with status 6 on main, 09-26).

This rewrites that rpath, in every Mach-O under the products directory, to the
products directory's own PackageFrameworks, then re-signs ad hoc what it
changed, innermost first so each bundle seals its already-signed nested code.
A product restored where it was compiled has nothing to rewrite.

usage: relocate_package_framework_rpaths.py <Build/Products/Debug>
"""

from __future__ import annotations

import os
import re
import struct
import subprocess
import sys
from pathlib import Path

PRODUCER_PACKAGE_FRAMEWORKS = re.compile(
    r"^(?:/private)?/tmp/cmux-ci(?:-[0-9]{1,2})?/derived-data-compile-admission/Build/Products/Debug/PackageFrameworks/?$"
)

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
LC_RPATH = 0x8000001C
# Directories that hold no code: skipping them keeps the walk to seconds.
SKIPPED_SUFFIXES = (".swiftmodule", ".dSYM", ".swiftdoc", ".swiftsourceinfo")


def _thin_rpaths(data: bytes, offset: int) -> list[str]:
    magic, = struct.unpack_from("<I", data, offset)
    if magic != MH_MAGIC_64:
        return []
    ncmds, _sizeofcmds = struct.unpack_from("<II", data, offset + 16)
    cursor = offset + 32
    rpaths: list[str] = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, cursor)
        if cmd == LC_RPATH:
            path_offset, = struct.unpack_from("<I", data, cursor + 8)
            raw = data[cursor + path_offset:cursor + cmdsize]
            rpaths.append(raw.split(b"\0", 1)[0].decode("utf-8", "replace"))
        cursor += cmdsize
    return rpaths


def rpaths(path: Path) -> list[str]:
    """LC_RPATH entries of a Mach-O (every slice of a fat one), else []."""
    try:
        with path.open("rb") as handle:
            head = handle.read(4096)
            if len(head) < 32:
                return []
            magic_le, = struct.unpack_from("<I", head, 0)
            magic_be, = struct.unpack_from(">I", head, 0)
            if magic_le == MH_MAGIC_64:
                sizeofcmds, = struct.unpack_from("<I", head, 20)
                handle.seek(0)
                return _thin_rpaths(handle.read(32 + sizeofcmds), 0)
            if magic_be in (FAT_MAGIC, FAT_MAGIC_64):
                found: list[str] = []
                nfat, = struct.unpack_from(">I", head, 4)
                wide = magic_be == FAT_MAGIC_64
                for index in range(nfat):
                    if wide:
                        _, _, slice_offset, _, _, _ = struct.unpack_from(">iiQQII", head, 8 + index * 32)
                    else:
                        _, _, slice_offset, _, _ = struct.unpack_from(">iiIII", head, 8 + index * 20)
                    handle.seek(slice_offset)
                    slice_head = handle.read(32)
                    if len(slice_head) < 32 or struct.unpack_from("<I", slice_head, 0)[0] != MH_MAGIC_64:
                        continue
                    sizeofcmds, = struct.unpack_from("<I", slice_head, 20)
                    handle.seek(slice_offset)
                    found += _thin_rpaths(handle.read(32 + sizeofcmds), 0)
                return found
    except (OSError, struct.error):
        return []
    return []


def stale_rpaths(entries: list[str], own: str) -> list[str]:
    """The producer package-framework rpaths that are not this product's own."""
    own = own.rstrip("/")
    return sorted({entry for entry in entries
                   if PRODUCER_PACKAGE_FRAMEWORKS.match(entry)
                   and os.path.realpath(entry.rstrip("/")) != os.path.realpath(own)})


def loadable(path: Path) -> bool:
    """False for a framework's dereferenced copies of its binary.

    Staging copies PackageFrameworks with `rsync -aL`, so X.framework/X and
    Versions/Current/X become plain files beside Versions/A/X. Install names
    always say Versions/A, so dyld never loads the copies, and codesign cannot
    seal them as a framework.
    """
    parts = path.parts
    for index in range(len(parts) - 1, -1, -1):
        if parts[index].endswith(".framework"):
            inner = parts[index + 1:]
            return len(inner) >= 3 and inner[0] == "Versions" and inner[1] != "Current"
    return True


def signing_target(path: Path) -> Path:
    """The code object codesign seals for a Mach-O: its bundle when it is one's main executable."""
    parts = path.parts
    if len(parts) >= 4 and parts[-3] == "Versions" and parts[-4] == path.name + ".framework":
        return path.parent
    if len(parts) >= 3 and parts[-2] == "MacOS" and parts[-3] == "Contents":
        bundle = path.parent.parent.parent
        info = path.parent.parent / "Info.plist"
        if info.is_file() and _bundle_executable(info) == path.name:
            return bundle
    return path


def _bundle_executable(info: Path) -> str | None:
    import plistlib
    try:
        with info.open("rb") as handle:
            return plistlib.load(handle).get("CFBundleExecutable")
    except Exception:
        return None


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 64
    products = Path(argv[1])
    own = str(products / "PackageFrameworks")
    rewritten: list[Path] = []
    for directory, subdirectories, files in os.walk(products):
        subdirectories[:] = [name for name in subdirectories if not name.endswith(SKIPPED_SUFFIXES)]
        for name in files:
            path = Path(directory) / name
            if path.is_symlink() or not path.is_file() or not loadable(path):
                continue
            stale = stale_rpaths(rpaths(path), own)
            if not stale:
                continue
            command = ["install_name_tool"]
            for entry in stale:
                command += ["-rpath", entry, own]
            subprocess.run(command + [str(path)], check=True, stderr=subprocess.DEVNULL)
            rewritten.append(path)
    if not rewritten:
        print("relocate-package-rpaths: nothing to rewrite")
        return 0
    targets = sorted({signing_target(path) for path in rewritten}, key=lambda target: (-len(target.parts), str(target)))
    for target in targets:
        subprocess.run(
            ["codesign", "--force", "--sign", "-", "--preserve-metadata=identifier,entitlements,flags,runtime",
             str(target)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )
    print(f"relocate-package-rpaths: pointed {len(rewritten)} Mach-O file(s) at {own}; re-signed {len(targets)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
