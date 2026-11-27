#!/usr/bin/env python3
"""Every string key a settings schema source names is in the CmuxNextSettings string catalog.

SettingsSchemaExportTests checks the same thing, but it is a Mac test, and pull requests into feat-cmux-next
defer their Mac jobs: three rows (experiments.forum, experiments.terminalAgentMark,
sessions.keepAwakeWhenLocked) merged without their catalog keys, and the settings exports stopped
regenerating for every row after them. This reads JSON only, so it runs in the fast gates on every PR.

    python3 scripts/ci/settings_catalog_keys.py [--root REPO]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

SOURCES = "schemas/settings/source"
# One file per key (scripts/cmux-next/string_catalogs.py): `<key>.xcstrings`, its `check` holding each name to its key.
CATALOG = "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Localizable.xcstrings.d"


def text_keys(node, path: str = ""):
    """(key, where) for every {"key": ..., "text": ...} object: a localized text, not a row's setting key."""
    if isinstance(node, dict):
        if isinstance(node.get("key"), str) and "text" in node:
            yield node["key"], path
        for name, value in node.items():
            yield from text_keys(value, f"{path}.{name}" if path else name)
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from text_keys(value, f"{path}[{index}]")


def missing(root: Path) -> list[str]:
    catalog = {p.name[: -len(".xcstrings")] for p in (root / CATALOG).glob("*.xcstrings")}
    found = []
    for source in sorted((root / SOURCES).glob("*.json")):
        for key, where in text_keys(json.loads(source.read_text())):
            if key not in catalog:
                found.append(f"{source.relative_to(root)}: {where}: {key}")
    return found


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args(argv)
    found = missing(args.root)
    for line in found:
        print(f"::error::settings text key not in {CATALOG}: {line}")
    if found:
        print(f"{len(found)} settings text key(s) missing from the catalog: add each with all its languages, "
              "as the other settings strings there have.", file=sys.stderr)
        return 1
    print("settings catalog keys: every schema text key is in the catalog")
    return 0


if __name__ == "__main__":
    sys.exit(main())
