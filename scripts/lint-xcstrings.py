#!/usr/bin/env python3
"""Validate tracked Xcode string catalogs: their top-level schema, and that no text a person
reads names one of cmux's internal parts (acpmux, optchat). Keys and translator comments may."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


ALLOWED_TOP_LEVEL_KEYS = frozenset(("sourceLanguage", "strings", "version"))

# Internal component names a person never reads in the app (user, 2026-11-09: "generally in gui we
# should not mention stuff like acpmux"). The CLI, docs and logs may still name them.
INTERNAL_NAMES = re.compile(r"acpmux|optchat", re.IGNORECASE)


def _string_values(node: object) -> list[str]:
    """Every stringUnit value under a localization, its plural and device variations included."""
    if isinstance(node, dict):
        values = []
        unit = node.get("stringUnit")
        if isinstance(unit, dict) and isinstance(unit.get("value"), str):
            values.append(unit["value"])
        for key, child in node.items():
            if key != "stringUnit":
                values.extend(_string_values(child))
        return values
    if isinstance(node, list):
        return [value for child in node for value in _string_values(child)]
    return []


def internal_name_errors(path: Path, strings: dict[str, object]) -> list[str]:
    """Name each localization whose text shows an internal component name."""
    errors: list[str] = []
    for key, entry in strings.items():
        localizations = entry.get("localizations") if isinstance(entry, dict) else None
        if not isinstance(localizations, dict):
            continue
        for locale, localization in localizations.items():
            for value in _string_values(localization):
                found = INTERNAL_NAMES.search(value)
                if found:
                    errors.append(
                        f"{path}: {key} [{locale}] shows the internal name '{found.group(0).lower()}' "
                        "to the user; say cmux, or say what it does"
                    )
    return errors


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
    else:
        errors.extend(internal_name_errors(path, data["strings"]))
    if data.get("version") != "1.0":
        errors.append(f"{path}: missing top-level 'version' key with value '1.0'")
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
