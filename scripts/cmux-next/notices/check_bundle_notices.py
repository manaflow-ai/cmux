#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check that every Mach-O file in an app bundle has its license notices.

  check_bundle_notices.py <app> [--map bundle-map.json] [--notices FILE]

Each Mach-O file under <app>/Contents (symlinks are not followed) must match
an entry of the map, and every requirement of each matching entry must hold:
  first-party      Contents/Resources/LICENSE is a non-empty file
  section:<id>     Contents/Resources/THIRD_PARTY_LICENSES.md has the marker
                   `<!-- notices-section: <id> -->`
  file:<path>      <app>/<path> is a non-empty file
`resources` entries name non-Mach-O third-party data (a path relative to the
.app); when the bundle has that path, its notices must hold too.
Exit 1 lists every unmapped Mach-O and every missing notice. Python 3.11+
standard library only.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
from pathlib import Path
import re
import struct
import sys

HERE = Path(__file__).resolve().parent
THIN_MAGICS = {0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE}
FAT_MAGICS = {0xCAFEBABE, 0xCAFEBABF}
MARKER = re.compile(r"<!-- notices-section: ([A-Za-z0-9._-]+) -->")


def is_macho(path: Path) -> bool:
    with path.open("rb") as handle:
        head = handle.read(8)
    if len(head) < 8:
        return False
    magic, count = struct.unpack(">II", head)
    if magic in THIN_MAGICS:
        return True
    # A Java class file shares 0xCAFEBABE; its second word is a version >= 45.
    return magic in FAT_MAGICS and 0 < count < 45


def macho_files(app: Path) -> list[str]:
    found = []
    for path in sorted((app / "Contents").rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        if any(parent.is_symlink() for parent in path.relative_to(app).parents if parent != Path(".")):
            continue
        if is_macho(path):
            found.append(path.relative_to(app).as_posix())
    return found


def check(app: Path, bundle_map: dict, notices: Path | None = None) -> list[str]:
    notices = notices or app / "Contents/Resources/THIRD_PARTY_LICENSES.md"
    sections = set(MARKER.findall(notices.read_text(encoding="utf-8"))) if notices.is_file() else set()
    errors = []

    def requirement_holds(need: str, owner: str) -> bool:
        kind, _, value = need.partition(":")
        if kind == "first-party":
            return _non_empty(app / "Contents/Resources/LICENSE")
        if kind == "section":
            return value in sections
        if kind == "file":
            return _non_empty(app / value)
        raise SystemExit(f"check_bundle_notices: unknown requirement {need!r} in entry {owner!r}")

    # Third-party data that is not a Mach-O (themes and similar): when the
    # bundle has the path, its notices must be there too.
    for entry in bundle_map.get("resources", []):
        if (app / entry["path"]).exists():
            for need in entry["notices"]:
                if not requirement_holds(need, entry["path"]):
                    errors.append(f"{entry['path']}: missing notice {need}")
    for rel in macho_files(app):
        entries = [e for e in bundle_map["entries"] if fnmatch.fnmatchcase(rel, e["path"])]
        if not entries:
            errors.append(f"{rel}: Mach-O that no bundle-map entry covers")
            continue
        for entry in entries:
            for need in entry["notices"]:
                if not requirement_holds(need, entry["path"]):
                    errors.append(f"{rel}: missing notice {need}")
    return errors


def _non_empty(path: Path) -> bool:
    return path.is_file() and path.stat().st_size > 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("app", type=Path)
    parser.add_argument("--map", type=Path, default=HERE / "bundle-map.json")
    parser.add_argument("--notices", type=Path, help="check this THIRD_PARTY_LICENSES.md instead of the bundled one (a candidate before a build)")
    args = parser.parse_args(argv)
    errors = check(args.app, json.loads(args.map.read_text(encoding="utf-8")), args.notices)
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    if errors:
        print(f"check_bundle_notices: {len(errors)} problem(s) in {args.app}", file=sys.stderr)
        return 1
    print(f"check_bundle_notices: every Mach-O in {args.app} has its notices")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
