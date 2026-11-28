#!/usr/bin/env python3
"""Palette coverage gate: a pull request adds no CLI, menu-bar, right-click, keyboard-shortcut or Settings-page action without a palette entry.

scripts/cmux-next/palette-coverage.py lists what the command palette is missing (NOW's
code_shape.palette_coverage reads the same count; cmuxterm-hq goals/palette-coverage-gate-all-surfaces.md). Nothing
ran it on a pull request, so the count only moved after a merge: on 2026-11-28 it read 4 for hours because cmux#56767
removed `cmux coderouter` and #61161 its palette actions while plans/cmux-next/palette-coverage.json still mapped
the verbs.

This runs the merge's copy of the script, and when it reports a gap or a keep-list problem, the base's copy on the
base's own inputs (git objects only): it fails only on a gap or problem the base does not already have, so a red base
is a note, not this pull request's failure.

  palette_coverage_gate.py --base REV [--repo PATH]    exit 1 on a gap or problem the pull request adds
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT = "scripts/cmux-next/palette-coverage.py"
# The script and every file it reads (palette-coverage.py's KEEP, SURFACES, MENUS, CATALOG, SETTINGS, KEY_MAP).
INPUTS = (
    SCRIPT,
    "plans/cmux-next/palette-coverage.json",
    "plans/cmux-next/action-surfaces.json",
    "plans/cmux-next/action-catalog.json",
    "schemas/settings/settings-schema.json",
    "cmux-tui/crates/cmux-action-catalog/src/hand_built_menus.rs",
    "Packages/macOS/CmuxNext/Sources/CmuxNextPalette/PaletteKeyMap.swift",
)


def coverage(root: Path) -> dict | None:
    """The script's --json at ROOT, or None when it cannot run there (no script, unreadable output)."""
    script = root / SCRIPT
    if not script.is_file():
        return None
    out = subprocess.run([sys.executable, "-I", str(script), "--json"], cwd=root, capture_output=True, text=True)
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError:
        sys.stderr.write(out.stdout + out.stderr)
        return None


def base_coverage(repo: Path, base: str) -> dict | None:
    present = [p for p in INPUTS
               if subprocess.run(["git", "-C", str(repo), "cat-file", "-e", f"{base}:{p}"],
                                 capture_output=True).returncode == 0]
    if SCRIPT not in present:
        return None
    with tempfile.TemporaryDirectory(prefix="palette-coverage-base-") as tmp:
        archive = subprocess.run(["git", "-C", str(repo), "archive", "--format=tar", base, *present],
                                 check=True, capture_output=True).stdout
        subprocess.run(["tar", "-x", "-C", tmp], input=archive, check=True)
        return coverage(Path(tmp))


def keys(got: dict) -> tuple[set[str], set[str]]:
    gaps = {f"{e['surface']} {e['name']}" for e in got.get("entries", [])}
    return gaps, {str(p) for p in got.get("problems", [])}


def judge(head: dict, base: dict | None) -> tuple[list[str], list[str]]:
    """(added, already on base): the gaps and problems HEAD has, split by whether BASE has them too."""
    gaps, problems = keys(head)
    base_gaps, base_problems = keys(base) if base else (set(), set())
    lines = [(f"missing: {g}", g in base_gaps) for g in sorted(gaps)]
    lines += [(f"problem: {p}", p in base_problems) for p in sorted(problems)]
    return [l for l, old in lines if not old], [l for l, old in lines if old]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", required=True)
    ap.add_argument("--repo", default=".")
    args = ap.parse_args(argv)
    repo = Path(args.repo).resolve()
    head = coverage(repo)
    if head is None:
        print(f"palette coverage: {SCRIPT} did not run at the head")
        return 1
    if not head.get("missing") and not head.get("problems"):
        print(f"palette coverage: 0 missing, {head.get('kept', 0)} kept")
        return 0
    added, old = judge(head, base_coverage(repo, args.base))
    for line in old:
        print(f"note (base has it too): {line}")
    for line in added:
        print(f"::error::palette coverage: {line}")
    if added:
        print("Add a palette entry for the action, or a {verb, palette} / {verb, reason: \"keep: ...\"} row in "
              "plans/cmux-next/palette-coverage.json; a setting takes SettingDescriptor.hiddenFromPalette(\"why\") "
              "(python3 scripts/cmux-next/palette-coverage.py lists them).")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
