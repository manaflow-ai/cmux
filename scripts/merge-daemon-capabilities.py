#!/usr/bin/env python3
"""Git merge driver for plans/cmux-next/daemon-capabilities.json: a three-way set merge.

The file is the app's daemon capability lists (DaemonCapabilityExportTests
writes it from DaemonEndpoint.swift): one sorted array per list. Two branches
that each add a capability collide positionally under a line merge, and the
old `cmux-generated-v1` driver (`true`) kept the current branch's copy whole,
so a rebase silently dropped the other branch's new entries.

This merges each list as a set: a capability either side added is added, one
either side removed is removed, so a move from one list to another on one side
is kept. Scalars (the comment) take the side that changed them. The result is
written sorted, in the export's format, so it is byte-identical to a fresh
export of the merged Swift lists (check-daemon-capabilities-fresh.py checks it).

A conflict writes both whole files between ordinary markers and exits 1: a
side that does not parse as an object of string arrays, a scalar both sides
changed differently, or a capability that ends in two lists.

Usage (git): merge-daemon-capabilities.py %O %A %B %P; writes the result to %A.
"""
from __future__ import annotations

import json
import sys

MISSING = object()


def load(path: str):
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except FileNotFoundError:
        return {}, ""
    if not text.strip():
        return {}, text
    data = json.loads(text)
    if not isinstance(data, dict):
        raise ValueError("not a JSON object")
    for key, value in data.items():
        if isinstance(value, list) and not all(isinstance(item, str) for item in value):
            raise ValueError(f"{key}: not a list of strings")
    return data, text


def merge_set(base, ours, theirs) -> list[str]:
    base, ours, theirs = set(base or []), set(ours or []), set(theirs or [])
    return sorted((ours & theirs) | (ours - base) | (theirs - base))


def merge_scalar(base, ours, theirs):
    if ours == theirs or theirs == base:
        return ours, False
    if ours == base:
        return theirs, False
    return ours, True


def render(data: dict) -> str:
    """The export's format: JSONEncoder .prettyPrinted + .sortedKeys + .withoutEscapingSlashes."""
    lines = ["{"]
    keys = sorted(key for key in data if data[key] is not MISSING)
    for index, key in enumerate(keys):
        value = data[key]
        comma = "," if index < len(keys) - 1 else ""
        name = json.dumps(key, ensure_ascii=False)
        if isinstance(value, list):
            if value:
                items = ",\n".join("    " + json.dumps(item, ensure_ascii=False) for item in value)
                lines.append(f"  {name} : [\n{items}\n  ]{comma}")
            else:
                lines.append(f"  {name} : [\n\n  ]{comma}")
        else:
            lines.append(f"  {name} : {json.dumps(value, ensure_ascii=False)}{comma}")
    lines.append("}")
    return "\n".join(lines) + "\n"


def conflict(ours_path: str, ours_text: str, theirs_text: str, reason: str) -> int:
    with open(ours_path, "w", encoding="utf-8") as handle:
        handle.write("<<<<<<< ours\n" + ours_text + ("" if ours_text.endswith("\n") else "\n")
                     + "=======\n" + theirs_text + ("" if theirs_text.endswith("\n") else "\n")
                     + ">>>>>>> theirs\n")
    print(f"merge-daemon-capabilities: conflict: {reason}", file=sys.stderr)
    return 1


def main(argv: list[str]) -> int:
    if len(argv) < 4:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    base_path, ours_path, theirs_path = argv[1:4]
    try:
        base, _ = load(base_path)
        ours, ours_text = load(ours_path)
        theirs, theirs_text = load(theirs_path)
    except (ValueError, json.JSONDecodeError) as error:
        with open(ours_path, encoding="utf-8", errors="replace") as handle:
            ours_text = handle.read()
        with open(theirs_path, encoding="utf-8", errors="replace") as handle:
            theirs_text = handle.read()
        return conflict(ours_path, ours_text, theirs_text, f"a side does not parse ({error})")
    merged: dict = {}
    for key in sorted(set(base) | set(ours) | set(theirs)):
        b, o, t = base.get(key, MISSING), ours.get(key, MISSING), theirs.get(key, MISSING)
        lists = [v for v in (b, o, t) if v is not MISSING]
        if all(isinstance(v, list) for v in lists):
            if o is MISSING and t is MISSING:
                continue  # both sides deleted it
            if (o is MISSING and b is not MISSING) or (t is MISSING and b is not MISSING):
                # One side deleted the whole list: keep the deletion unless the other side changed it.
                kept = o if o is not MISSING else t
                if sorted(kept) == sorted(b):
                    continue
                return conflict(ours_path, ours_text, theirs_text, f"{key}: removed on one side, changed on the other")
            merged[key] = merge_set(None if b is MISSING else b, None if o is MISSING else o,
                                    None if t is MISSING else t)
            continue
        if any(isinstance(v, list) for v in lists):
            return conflict(ours_path, ours_text, theirs_text, f"{key}: a list on one side only")
        value, clash = merge_scalar(b, o, t)
        if clash:
            return conflict(ours_path, ours_text, theirs_text, f"{key}: both sides changed it")
        merged[key] = value
    seen: dict[str, str] = {}
    for key, value in merged.items():
        if not isinstance(value, list):
            continue
        for item in value:
            if item in seen:
                return conflict(ours_path, ours_text, theirs_text,
                                f"{item} is in both {seen[item]} and {key} after the merge")
            seen[item] = key
    with open(ours_path, "w", encoding="utf-8") as handle:
        handle.write(render(merged))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
