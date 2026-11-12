#!/usr/bin/env python3
"""Validate the top-level schema used by tracked Xcode string catalogs."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


ALLOWED_TOP_LEVEL_KEYS = frozenset(("sourceLanguage", "strings", "version"))


def _tracked_catalogs() -> list[Path]:
    """List tracked catalogs relative to the current repository directory."""
    result = subprocess.run(
        ["git", "ls-files", "-z", "*.xcstrings"],
        check=True,
        capture_output=True,
    )
    return [Path(item) for item in result.stdout.decode().split("\0") if item]


def check_catalog(path: Path) -> list[str]:
    """Return diagnostics for an unreadable or structurally invalid catalog."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        return [f"{path}: invalid JSON: {exc}"]

    if not isinstance(data, dict):
        return [f"{path}: catalog root must be a JSON object"]

    errors: list[str] = []
    unexpected = sorted(set(data) - ALLOWED_TOP_LEVEL_KEYS)
    if unexpected:
        errors.append(
            f"{path}: unexpected top-level key(s): {', '.join(unexpected)}; "
            "localized entries must be inside 'strings'"
        )
    if not isinstance(data.get("strings"), dict):
        errors.append(f"{path}: missing top-level 'strings' object")
    return errors


def main() -> int:
    """Validate selected or tracked catalogs and report all catalog errors."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", action="append", type=Path)
    args = parser.parse_args()

    try:
        paths = args.catalog or _tracked_catalogs()
    except (OSError, subprocess.CalledProcessError) as exc:
        print(f"unable to enumerate tracked catalogs: {exc}", file=sys.stderr)
        return 2

    errors = [error for path in paths for error in check_catalog(path)]
    if errors:
        print("\n".join(errors), file=sys.stderr)
        print(f"XCStrings lint failed: {len(errors)} error(s)", file=sys.stderr)
        return 1

    print(f"XCStrings lint passed: {len(paths)} catalog(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
