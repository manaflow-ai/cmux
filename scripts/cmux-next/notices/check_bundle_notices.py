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
  ghostty-license-tree:<path>
                   <app>/<path> is a Ghostty dependency license tree that
                   verify-ghostty-license-bundle.py accepts, for the Ghostty
                   revision --ghostty-revision names (or, without it, the
                   revision in the tree's own SOURCE-MANIFEST.json)
`resources` entries name non-Mach-O third-party data (a path relative to the
.app); when the bundle has that path, its notices must hold too. A bundle that
has a path in REQUIRED_RESOURCES needs a `resources` entry for it.
Exit 1 lists every unmapped Mach-O and every missing notice. Python 3.11+
standard library only.
"""

from __future__ import annotations

import argparse
import fnmatch
import importlib.util
import json
from pathlib import Path
import re
import struct
import sys

HERE = Path(__file__).resolve().parent
THIN_MAGICS = {0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE}
FAT_MAGICS = {0xCAFEBABE, 0xCAFEBABF}
MARKER = re.compile(r"<!-- notices-section: ([A-Za-z0-9._-]+) -->")
GHOSTTY_VERIFIER = HERE.parents[2] / "cmux-tui/build-support/notices/ghostty/verify-ghostty-license-bundle.py"
# Third-party data that a bundle may carry only with a bundle-map `resources`
# entry: the nightly-next Ghostty dependency license tree (nightly.yml,
# "Inject the Ghostty dependency licenses").
REQUIRED_RESOURCES = ("Contents/Resources/ghostty-licenses",)


def _ghostty_verifier():
    spec = importlib.util.spec_from_file_location("verify_ghostty_license_bundle", GHOSTTY_VERIFIER)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def ghostty_license_tree_problem(root: Path, revision: str | None) -> str | None:
    """None when the tree verifies, else the verifier's reason."""
    verifier = _ghostty_verifier()
    if revision is None:
        try:
            revision = json.loads((root / "SOURCE-MANIFEST.json").read_text(encoding="utf-8")).get("ghostty_revision")
        except (OSError, ValueError, AttributeError) as error:
            return f"unreadable SOURCE-MANIFEST.json: {error}"
        if not isinstance(revision, str):
            return "SOURCE-MANIFEST.json names no ghostty_revision"
    try:
        verifier.verify(root, revision)
    except (OSError, verifier.VerificationError) as error:
        return str(error)
    return None


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


def check(
    app: Path, bundle_map: dict, notices: Path | None = None, ghostty_revision: str | None = None,
) -> list[str]:
    notices = notices or app / "Contents/Resources/THIRD_PARTY_LICENSES.md"
    sections = set(MARKER.findall(notices.read_text(encoding="utf-8"))) if notices.is_file() else set()
    errors = []
    reasons: dict[str, str] = {}

    def requirement_holds(need: str, owner: str) -> bool:
        kind, _, value = need.partition(":")
        if kind == "first-party":
            return _non_empty(app / "Contents/Resources/LICENSE")
        if kind == "section":
            return value in sections
        if kind == "file":
            return _non_empty(app / value)
        if kind == "ghostty-license-tree":
            problem = ghostty_license_tree_problem(app / value, ghostty_revision)
            if problem is not None:
                reasons[need] = problem
            return problem is None
        raise SystemExit(f"check_bundle_notices: unknown requirement {need!r} in entry {owner!r}")

    def missing(owner: str, need: str) -> str:
        reason = reasons.get(need)
        return f"{owner}: missing notice {need}" + (f" ({reason})" if reason else "")

    mapped = {entry["path"] for entry in bundle_map.get("resources", [])}
    for path in REQUIRED_RESOURCES:
        if (app / path).exists() and path not in mapped:
            errors.append(f"{path}: bundled, but no bundle-map.json resources entry covers it")
    # Third-party data that is not a Mach-O (themes and similar): when the
    # bundle has the path, its notices must be there too.
    for entry in bundle_map.get("resources", []):
        if (app / entry["path"]).exists():
            for need in entry["notices"]:
                if not requirement_holds(need, entry["path"]):
                    errors.append(missing(entry["path"], need))
    for rel in macho_files(app):
        entries = [e for e in bundle_map["entries"] if fnmatch.fnmatchcase(rel, e["path"])]
        if not entries:
            errors.append(f"{rel}: Mach-O that no bundle-map entry covers")
            continue
        for entry in entries:
            for need in entry["notices"]:
                if not requirement_holds(need, entry["path"]):
                    errors.append(missing(rel, need))
    return errors


def _non_empty(path: Path) -> bool:
    return path.is_file() and path.stat().st_size > 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("app", type=Path)
    parser.add_argument("--map", type=Path, default=HERE / "bundle-map.json")
    parser.add_argument("--notices", type=Path, help="check this THIRD_PARTY_LICENSES.md instead of the bundled one (a candidate before a build)")
    parser.add_argument("--ghostty-revision", help="the Ghostty commit the app was built from; a bundled Ghostty license tree must name it")
    args = parser.parse_args(argv)
    errors = check(args.app, json.loads(args.map.read_text(encoding="utf-8")), args.notices, args.ghostty_revision)
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    if errors:
        print(f"check_bundle_notices: {len(errors)} problem(s) in {args.app}", file=sys.stderr)
        return 1
    print(f"check_bundle_notices: every Mach-O in {args.app} has its notices")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
