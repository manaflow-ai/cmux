#!/usr/bin/env python3
"""Every string key a settings schema source names is in the CmuxNextSettings string catalog.

SettingsSchemaExportTests checks the same thing, but it is a Mac test, and pull requests into feat-cmux-next
defer their Mac jobs: three rows (experiments.forum, experiments.terminalAgentMark,
sessions.keepAwakeWhenLocked) merged without their catalog keys, and the settings exports stopped
regenerating for every row after them. This reads JSON only, so it runs in the fast gates on every PR.

With --base-rev, the same keys are read at BASE from git objects, and the gate fails only for a key missing at
ROOT that BASE does not already miss: a key BASE already misses is printed as a base note and does not fail.
Without it, every PR that touched settings failed while feat-cmux-next itself missed keys (#56824 added two
that main lacked), and lanes base-merged to get past a red that was not theirs. A key the PR's own change drops
or newly names still fails: the compare is by key, so a base red never excuses a different key. A base that
cannot be read excuses nothing.

    python3 scripts/ci/settings_catalog_keys.py [--root REPO] [--base-rev BASE [--repo GITDIR]]
"""
from __future__ import annotations

import argparse
import json
import subprocess
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


def missing_in(catalog: set[str], sources: list[tuple[str, str]]) -> list[tuple[str, str]]:
    """(key, "source: where: key") for every text key in SOURCES ((relative path, JSON text), sorted) not in CATALOG."""
    found = []
    for name, text in sources:
        for key, where in text_keys(json.loads(text)):
            if key not in catalog:
                found.append((key, f"{name}: {where}: {key}"))
    return found


def missing_rows(root: Path) -> list[tuple[str, str]]:
    catalog = {p.name[: -len(".xcstrings")] for p in (root / CATALOG).glob("*.xcstrings")}
    sources = [(str(s.relative_to(root)), s.read_text()) for s in sorted((root / SOURCES).glob("*.json"))]
    return missing_in(catalog, sources)


def missing(root: Path) -> list[str]:
    return [line for _, line in missing_rows(root)]


def git(repo: Path, *args: str, stdin: bytes | None = None) -> bytes:
    return subprocess.run(["git", "-C", str(repo), *args], input=stdin, capture_output=True, check=True).stdout


def missing_keys_at(repo: Path, rev: str) -> set[str]:
    """The text keys REV's tree misses, from git objects only (no checkout of REV). Raises when REV cannot be read."""
    names = git(repo, "ls-tree", "-z", "--name-only", rev, "--", f"{CATALOG}/", f"{SOURCES}/").decode().split("\0")
    catalog = {Path(n).name[: -len(".xcstrings")] for n in names
               if n.startswith(f"{CATALOG}/") and n.endswith(".xcstrings")}
    paths = sorted(n for n in names if n.startswith(f"{SOURCES}/") and n.endswith(".json"))
    sources = []
    if paths:
        out = git(repo, "cat-file", "--batch", stdin="".join(f"{rev}:{p}\n" for p in paths).encode())
        at = 0
        for path in paths:
            header_end = out.index(b"\n", at)
            size = int(out[at:header_end].split()[2])
            sources.append((path, out[header_end + 1:header_end + 1 + size].decode()))
            at = header_end + 1 + size + 1
    keys = set()
    for path, text in sources:
        try:
            keys |= {key for key, _ in missing_in(catalog, [(path, text)])}
        except json.JSONDecodeError:
            continue  # a base source that does not parse excuses none of its keys
    return keys


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--base-rev", help="the base the PR merges into: keys it already misses are notes, not failures")
    parser.add_argument("--repo", type=Path, help="the git repository holding --base-rev (default: --root)")
    args = parser.parse_args(argv)
    rows = missing_rows(args.root)
    at_base: set[str] = set()
    if args.base_rev and rows:
        try:
            at_base = missing_keys_at(args.repo or args.root, args.base_rev)
        except (subprocess.CalledProcessError, ValueError, IndexError) as error:
            print(f"::warning::settings catalog keys: base {args.base_rev} could not be read ({error}); "
                  "every missing key counts as this change's")
    found = [line for key, line in rows if key not in at_base]
    for key, line in rows:
        if key in at_base:
            print(f"::notice::settings text key not in {CATALOG}, already missing on base {args.base_rev} "
                  f"(base, not this change): {line}")
    for line in found:
        print(f"::error::settings text key not in {CATALOG}: {line}")
    if found:
        print(f"{len(found)} settings text key(s) missing from the catalog: add each with all its languages, "
              "as the other settings strings there have.", file=sys.stderr)
        return 1
    if rows:
        print(f"settings catalog keys: {len(rows)} key(s) missing, all already missing on base {args.base_rev}: "
              "the base's to fix, not this change's")
        return 0
    print("settings catalog keys: every schema text key is in the catalog")
    return 0


if __name__ == "__main__":
    sys.exit(main())
