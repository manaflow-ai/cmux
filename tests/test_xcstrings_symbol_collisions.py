#!/usr/bin/env python3
"""No two keys of one Xcode string catalog generate the same Swift symbol.

Xcode generates a symbol for each manual string by splitting the key on non-alphanumerics and joining
the parts in lowerCamelCase, so `action.new.browser.workspace` and `action.newBrowserWorkspace` are both
`actionNewBrowserWorkspace`. Two such keys fail the Release build ("This string key would generate the
same symbol as ..."): #37724 added the first beside the second and every NEXT nightly failed in
build-nightly-app (run 42444410163). Catalogs under webviews/ are read by the web build, not Xcode.
"""
from __future__ import annotations

import collections
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def symbol(key: str) -> str | None:
    parts = [p for p in re.split(r"[^A-Za-z0-9]+", key) if p]
    if not parts:
        return None
    return parts[0][:1].lower() + parts[0][1:] + "".join(p[:1].upper() + p[1:] for p in parts[1:])


def collisions(catalog: dict) -> list[list[str]]:
    by_symbol: dict[str, list[str]] = collections.defaultdict(list)
    for key in catalog.get("strings", {}):
        name = symbol(key)
        if name:
            by_symbol[name].append(key)
    return [sorted(keys) for keys in by_symbol.values() if len(keys) > 1]


def main() -> int:
    assert symbol("action.new.browser.workspace") == symbol("action.newBrowserWorkspace") == "actionNewBrowserWorkspace"
    assert collisions({"strings": {"a.b": {}, "aB": {}, "a.c": {}}}) == [["a.b", "aB"]]
    files = subprocess.run(["git", "ls-files", "*.xcstrings"], cwd=ROOT, capture_output=True, text=True,
                           check=True).stdout.split()
    failures = []
    for rel in files:
        if rel.startswith("webviews/"):
            continue
        for keys in collisions(json.loads((ROOT / rel).read_text())):
            failures.append(f"{rel}: {', '.join(keys)} generate the same symbol; rename one key")
    if failures:
        print("FAIL: string catalog keys collide\n  " + "\n  ".join(failures))
        return 1
    print(f"PASS: no symbol collisions in {len(files)} string catalogs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
