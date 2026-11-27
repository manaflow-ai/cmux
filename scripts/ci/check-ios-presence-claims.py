#!/usr/bin/env python3
"""Fail when iPhone app copy claims a Mac is asleep.

Usage: check-ios-presence-claims.py [ROOT ...]   (default: cmux-next-ios/ Packages/iOS/)

The phone can't know a Mac sleeps. The cmux service only knows that no Mac has cmux
connected, which also happens when cmux quit, is restarting or the Mac has no network.
Aziz, 2026-11-25: "it says mac is asleep incorrect" (cmux#57792). So phone copy says
"offline" instead. A hedged line ("The Mac may be asleep") is fine; so is another
subject ("display is asleep", Chief's "Computer is asleep", whose state is real).

The whole tree is scanned, not just added lines: the regression was a string that
was already there. A line that truly knows (a state the service reports) can carry
`presence-ok: <why>` on it or on one of the two lines above it.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOTS = ("cmux-next-ios/", "Packages/iOS/")
SKIP_PARTS = ("/Tests/", "/UITests/", "Tests.swift", "/.build/", "Mock", "Preview", "Gallery")

STRING = re.compile(r'"(?:[^"\\]|\\.)*"')
# "<Mac|Macs|\(name)> is/are asleep" (also 's / ’s). Other subjects pass.
CLAIM = re.compile(
    r"(?i)(?:\bmacs?|\\\([^()]*(?:\([^()]*\)[^()]*)*\))\s*(?:\b(?:is|are)\s+|['’]s\s+|['’]re\s+)asleep\b"
)
OK_MARK = re.compile(r"presence-ok\s*:\s*\S")
COMMENT = re.compile(r"^\s*(//|///|\*|/\*)")


def in_scope(path: str) -> bool:
    return path.endswith(".swift") and not any(p in path for p in SKIP_PARTS)


def findings_for(path: str, lines: list[str]) -> list[tuple[str, int, str]]:
    found = []
    for i, line in enumerate(lines):
        if COMMENT.match(line):
            continue
        if not any(CLAIM.search(s) for s in STRING.findall(line)):
            continue
        if any(OK_MARK.search(lines[j]) for j in range(max(0, i - 2), i + 1)):
            continue
        found.append((path, i + 1, line.strip()[:110]))
    return found


def scan(roots: list[str]) -> list[tuple[str, int, str]]:
    found = []
    for root in roots:
        for p in sorted(Path(root).rglob("*.swift")):
            rel = p.as_posix()
            if in_scope(rel):
                found += findings_for(rel, p.read_text(encoding="utf-8", errors="replace").splitlines())
    return found


def main(argv: list[str]) -> int:
    found = scan(argv[1:] or list(ROOTS))
    for path, n, text in found:
        print(f"::error file={path},line={n}::phone copy claims a Mac is asleep: {text}")
        print(f"ASLEEP  {path}:{n}  {text}")
    if found:
        print(
            f"\nFAIL: {len(found)} line(s) in the iPhone app say a Mac is asleep.\n"
            "The service only knows no Mac has cmux connected: say \"offline\" (cmux#57792).\n"
            "A state the service truly reports: add `presence-ok: <why>` on the line or the two above it."
        )
        return 1
    print("OK: no iPhone copy claims a Mac is asleep.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
