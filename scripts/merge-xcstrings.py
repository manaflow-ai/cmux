#!/usr/bin/env python3
"""Git merge driver for Xcode string catalogs (.xcstrings).

A string catalog is one large JSON object keyed by string id. Two pull requests
that each add a new key collide positionally even though the keys are disjoint,
because the additions land in the same region of the file. On
Resources/Localizable.xcstrings (~6,700 entries, ~541k lines) that produced 42
conflict hunks in a single pull request, none of which were semantic.

This driver merges per key instead of per line. It is deliberately conservative:
when the same key is changed on both sides it exits non-zero and lets git write
normal conflict markers, so a real disagreement is never resolved silently.

Formatting is preserved because the catalog round-trips byte-identically through
`json.dumps(..., ensure_ascii=False, indent=2)` plus a trailing newline; the
driver asserts that on the inputs before writing.

Usage (git passes these): merge-xcstrings.py %O %A %B %P
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

SERIALIZED_SUFFIX = "\n"


def render(document: dict) -> str:
    return json.dumps(document, ensure_ascii=False, indent=2) + SERIALIZED_SUFFIX


def load(path: Path) -> tuple[dict, bool]:
    """Return the parsed catalog and whether it re-renders byte-identically."""
    text = path.read_text(encoding="utf-8")
    document = json.loads(text)
    return document, render(document) == text


def merge_mapping(base: dict, ours: dict, theirs: dict, label: str) -> tuple[dict, list[str]]:
    """Three-way merge one mapping. Returns (merged, conflicting keys)."""
    merged: dict = {}
    conflicts: list[str] = []
    # Preserve ours' order, then append keys only theirs introduced.
    for key in list(ours) + [k for k in theirs if k not in ours]:
        in_base, in_ours, in_theirs = key in base, key in ours, key in theirs
        ours_value = ours.get(key)
        theirs_value = theirs.get(key)
        base_value = base.get(key)
        ours_changed = ours_value != base_value if in_base else in_ours
        theirs_changed = theirs_value != base_value if in_base else in_theirs
        if not in_ours and not in_theirs:
            continue
        if ours_changed and theirs_changed:
            if ours_value == theirs_value:
                if in_ours:
                    merged[key] = ours_value
                continue
            conflicts.append(f"{label}.{key}")
            continue
        if ours_changed:
            if in_ours:
                merged[key] = ours_value
            continue
        if theirs_changed:
            if in_theirs:
                merged[key] = theirs_value
            continue
        merged[key] = ours_value
    return merged, conflicts


def merge_catalog(base: dict, ours: dict, theirs: dict) -> tuple[dict, list[str]]:
    strings, conflicts = merge_mapping(
        base.get("strings", {}), ours.get("strings", {}), theirs.get("strings", {}), "strings"
    )
    top_base = {k: v for k, v in base.items() if k != "strings"}
    top_ours = {k: v for k, v in ours.items() if k != "strings"}
    top_theirs = {k: v for k, v in theirs.items() if k != "strings"}
    merged, top_conflicts = merge_mapping(top_base, top_ours, top_theirs, "catalog")
    merged["strings"] = strings
    ordered = {k: merged[k] for k in ("sourceLanguage", "strings", "version") if k in merged}
    ordered.update({k: v for k, v in merged.items() if k not in ordered})
    return ordered, conflicts + top_conflicts


def main(argv: list[str]) -> int:
    if len(argv) < 4:
        print("usage: merge-xcstrings.py %O %A %B [%P]", file=sys.stderr)
        return 2
    base_path, ours_path, theirs_path = (Path(p) for p in argv[1:4])
    name = argv[4] if len(argv) > 4 else str(ours_path)
    try:
        base, base_exact = load(base_path)
        ours, ours_exact = load(ours_path)
        theirs, theirs_exact = load(theirs_path)
    except (OSError, ValueError) as error:
        print(f"merge-xcstrings: {name}: cannot parse ({error}); falling back", file=sys.stderr)
        return 1
    if not (base_exact and ours_exact and theirs_exact):
        print(
            f"merge-xcstrings: {name}: input is not canonically serialized; "
            "falling back to the default driver so formatting is not rewritten",
            file=sys.stderr,
        )
        return 1
    merged, conflicts = merge_catalog(base, ours, theirs)
    if conflicts:
        print(
            f"merge-xcstrings: {name}: {len(conflicts)} key(s) changed on both sides; "
            "leaving them to the default driver: " + ", ".join(conflicts[:5]),
            file=sys.stderr,
        )
        return 1
    ours_path.write_text(render(merged), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
