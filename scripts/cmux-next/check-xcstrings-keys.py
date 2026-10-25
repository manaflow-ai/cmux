#!/usr/bin/env python3
"""No string catalog names a key twice.

JSON lets an object repeat a key and every parser keeps the last one, so two branches that each add
a `message.delivered` with their own text merge cleanly in git and one text silently replaces the
other (#22773). This parses every tracked `.xcstrings` file and refuses a repeated key in any
object, at any depth: a string key, a language under `localizations`, a plural category.

Exits 1 with one line per repeated key (with the lines it appears on), or per catalog that is not
valid JSON; 0 when clean.

  python3 scripts/cmux-next/check-xcstrings-keys.py [--root DIR]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))


def catalogs(root: str) -> list[str]:
    out = subprocess.run(["git", "-C", root, "ls-files", "-z", "--", "*.xcstrings"],
                         check=True, capture_output=True).stdout
    return sorted(p for p in out.decode().split("\0") if p)


def repeated_keys(text: str) -> list[str]:
    repeated: list[str] = []

    def pairs(items: list[tuple[str, object]]) -> dict[str, object]:
        seen: set[str] = set()
        for key, _ in items:
            if key in seen:
                repeated.append(key)
            seen.add(key)
        return dict(items)

    json.loads(text, object_pairs_hook=pairs)
    return repeated


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=REPO)
    root = parser.parse_args().root
    findings = []
    paths = catalogs(root)
    for rel in paths:
        with open(os.path.join(root, rel), encoding="utf-8") as f:
            text = f.read()
        try:
            keys = repeated_keys(text)
        except json.JSONDecodeError as error:
            findings.append(f"{rel}:{error.lineno}: not valid JSON: {error.msg}")
            continue
        for key in dict.fromkeys(keys):
            pattern = re.compile(r'^\s*' + re.escape(json.dumps(key)) + r'\s*:')
            lines = [str(n) for n, line in enumerate(text.splitlines(), 1) if pattern.match(line)]
            findings.append(f"{rel}:{lines[0] if lines else 1}: key {json.dumps(key)} appears "
                            f"more than once in one object (lines {', '.join(lines) or '?'}); "
                            "give each text its own key")
    for finding in findings:
        print(finding)
    if findings:
        print(f"{len(findings)} problem(s) in {len(paths)} string catalogs", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
