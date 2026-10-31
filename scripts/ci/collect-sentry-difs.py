#!/usr/bin/env python3
"""Gather what `sentry-cli debug-files upload --include-sources PRODUCTS` reads, for a job that has the token.

    collect-sentry-difs.py PRODUCTS OUT [--sentry-cli PATH]

nightly.yml's build-nightly-app runs on a reused trusted mini and holds no Sentry token. It runs
this after the unsigned app is uploaded (where the upload used to run), packs OUT, and
upload-nightly-dsyms uploads it from Linux with scripts/upload-sentry-dsyms.sh.

OUT/products keeps PRODUCTS' layout, with hard links where it can (copies otherwise), and holds:
- every file inside a `.dSYM` bundle: the DWARF and the plists sentry-cli reads next to it;
- every other Mach-O file with an LC_UUID in at least one slice. sentry-cli skips an object with
  no debug id (every `.o`), so those stay behind.
Symlinks are neither followed nor kept: the file a link names is collected under its own path.

--include-sources reads each source file from the path the compiler recorded, which exists only
on the build machine. So, with --sentry-cli, each collected Mach-O file gets
`sentry-cli debug-files bundle-sources` here (the same writer and filter the upload uses), into
OUT/sources/<its path>/; a file whose line tables name no readable source gives no bundle. The
upload then sends OUT/products and OUT/sources. A bundle that fails is logged, and a ::warning
only when no file was bundled; never an error: symbolication is never worth a nightly
(scripts/upload-sentry-dsyms.sh).
"""

from __future__ import annotations

import argparse
import os
import shutil
import struct
import subprocess
import sys
from pathlib import Path

LC_UUID = 0x1B
# First four bytes -> (struct byte order, 64-bit header).
THIN = {
    b"\xce\xfa\xed\xfe": ("<", False),
    b"\xcf\xfa\xed\xfe": ("<", True),
    b"\xfe\xed\xfa\xce": (">", False),
    b"\xfe\xed\xfa\xcf": (">", True),
}
FAT = {b"\xca\xfe\xba\xbe": False, b"\xca\xfe\xba\xbf": True}  # value: 64-bit fat_arch entries
MAX_SLICES = 64  # a Java class file shares 0xcafebabe; its "count" is a class version, far above this


def _slice_has_uuid(handle, offset: int, size: int) -> bool:
    handle.seek(offset)
    magic = handle.read(4)
    if magic not in THIN:
        return False
    order, wide = THIN[magic]
    # mach_header(_64) after its magic: cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags[, reserved].
    header = handle.read(28 if wide else 24)
    if len(header) < (28 if wide else 24):
        return False
    _cputype, _subtype, _filetype, ncmds, sizeofcmds = struct.unpack(order + "iiIII", header[:20])
    if sizeofcmds > size:
        return False
    commands = handle.read(sizeofcmds)
    position = 0
    for _ in range(ncmds):
        if position + 8 > len(commands):
            return False
        command, length = struct.unpack_from(order + "II", commands, position)
        if command == LC_UUID:
            return True
        if length < 8:
            return False
        position += length
    return False


def has_debug_id(path: Path) -> bool:
    """True when the file is a Mach-O (thin or fat) with an LC_UUID in some slice."""
    try:
        size = path.stat().st_size
        with path.open("rb") as handle:
            magic = handle.read(4)
            if magic in THIN:
                return _slice_has_uuid(handle, 0, size)
            if magic not in FAT:
                return False
            wide = FAT[magic]
            (count,) = struct.unpack(">I", handle.read(4))
            if count == 0 or count > MAX_SLICES:
                return False
            entry = 32 if wide else 20
            table = handle.read(count * entry)
            if len(table) < count * entry:
                return False
            for index in range(count):
                if wide:
                    _cpu, _sub, offset, length, _align, _reserved = struct.unpack_from(">iiQQII", table, index * entry)
                else:
                    _cpu, _sub, offset, length, _align = struct.unpack_from(">iiIII", table, index * entry)
                if offset + length <= size and _slice_has_uuid(handle, offset, length):
                    return True
    except (OSError, struct.error):
        return False
    return False


def in_dsym(relative: Path) -> bool:
    return any(part.endswith(".dSYM") for part in relative.parts[:-1])


def place(source: Path, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.link(source, target)
    except OSError:
        shutil.copy2(source, target)


def collect(products: Path, out: Path, sentry_cli: str | None) -> int:
    if not products.is_dir():
        print(f"collect-sentry-difs: {products} is not a directory", file=sys.stderr)
        return 1
    shutil.rmtree(out, ignore_errors=True)
    (out / "products").mkdir(parents=True)
    (out / "sources").mkdir(parents=True)
    machos: list[Path] = []
    kept = 0
    for directory, folders, files in os.walk(products):
        folders.sort()
        for name in sorted(files):
            path = Path(directory) / name
            if path.is_symlink() or not path.is_file():
                continue
            relative = path.relative_to(products)
            macho = has_debug_id(path)
            if not (macho or in_dsym(relative)):
                continue
            place(path, out / "products" / relative)
            kept += 1
            if macho:
                machos.append(relative)
    print(f"collect-sentry-difs: {kept} files, {len(machos)} with a debug id, from {products}")
    if not sentry_cli:
        return 0
    bundled = failed = 0
    for relative in machos:
        target = out / "sources" / relative
        result = subprocess.run(
            [sentry_cli, "debug-files", "bundle-sources", "-o", str(target), str(products / relative)],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False,
        )
        if result.returncode != 0:
            # The upload skips an object it cannot parse ("Skipping invalid object") without a warning.
            failed += 1
            print(f"collect-sentry-difs: no source bundle for {relative}: {result.stdout.strip()[-500:]}")
        if target.is_dir() and any(target.iterdir()):
            bundled += 1
        elif target.is_dir():
            target.rmdir()
    # Drop the folders the empty targets left behind.
    for directory, _folders, _files in sorted(os.walk(out / "sources"), key=lambda item: -len(item[0])):
        if Path(directory) != out / "sources" and not any(Path(directory).iterdir()):
            Path(directory).rmdir()
    print(f"collect-sentry-difs: source bundles for {bundled} files, {failed} failed")
    if failed and not bundled:
        print("::warning title=Sentry source bundles failed::sentry-cli bundled no sources; "
              "this nightly's dSYMs go to Sentry without source context.")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("products", type=Path)
    parser.add_argument("out", type=Path)
    parser.add_argument("--sentry-cli", default=None)
    args = parser.parse_args(argv)
    return collect(args.products, args.out, args.sentry_cli)


if __name__ == "__main__":
    sys.exit(main())
