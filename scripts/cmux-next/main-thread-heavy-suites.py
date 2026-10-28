#!/usr/bin/env python3
"""Print a swift-testing filter regex naming the suites that drive the main thread for long stretches.

A suite is main-thread heavy when its file commits Core Animation frames itself (`CATransaction.flush()`,
`displayIfNeeded()`, a bench's `drawFrame(`) or builds a helper type whose own file does (SidebarScrollBench,
SidebarLagBench, ...), or makes real WebKit downloads (`RemoteVideoPageTests`). In the shared swift test
process each such commit lays out every window the process holds, so one of them held the main thread for
5 to 11+ minutes and every main-actor test beside it stalled until the stuck watchdog killed the run
(#26809). The swift-test job skips these in its broad pass and runs them in a process of their own.

Derived from the test sources on every run, so a new frame-driving suite is covered without a list to edit.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

FRAME_DRIVERS = re.compile(r"CATransaction\.flush\(\)|\.displayIfNeeded\(\)|\bdrawFrame\(")
# Suites the frame scan cannot see: real WebKit downloads block the main thread in a kernel call.
ALWAYS = {("CmuxNextBrowserTests", "RemoteVideoPageTests")}
# A top-level declaration only: its attributes may sit on lines of their own, but each such line starts at
# column 0, so a nested (indented) type is never read as a top-level one.
TYPE_DECL = re.compile(r"^(?:@\w+(?:\([^\n]*?\))?(?:[ \t]+|\n))*(?:(?:public|package|internal|private|fileprivate|final|open|nonisolated)[ \t]+)*"
                       r"(?:struct|class|enum|actor)[ \t]+([A-Z][A-Za-z0-9_]*)", re.M)
EXTENSION = re.compile(r"^extension\s+([A-Z][A-Za-z0-9_]*)", re.M)


def top_level_blocks(text: str) -> list[tuple[str, str]]:
    """(type name, body) for each top-level type or extension declaration, in order."""
    starts = sorted([(m.start(), m.group(1)) for m in TYPE_DECL.finditer(text)]
                    + [(m.start(), m.group(1)) for m in EXTENSION.finditer(text)])
    return [(name, text[at:starts[i + 1][0] if i + 1 < len(starts) else len(text)])
            for i, (at, name) in enumerate(starts)]


def heavy_suites(tests_root: Path, targets: str = "all") -> list[tuple[str, str]]:
    """Every main-thread-heavy suite of the selected test targets ('all', or target names space-separated)."""
    found = _heavy_suites(tests_root)
    if targets.strip() == "all":
        return found
    wanted = set(targets.split())
    return [(t, n) for t, n in found if t in wanted]


def _heavy_suites(tests_root: Path) -> list[tuple[str, str]]:
    files = {p: p.read_text(encoding="utf-8", errors="replace") for p in sorted(tests_root.rglob("*.swift"))}
    driving = {p for p, text in files.items() if FRAME_DRIVERS.search(text)}
    # Helper types a driving file declares with no tests of its own (a bench class): their users drive frames too.
    helpers = {name for p in driving for name, body in top_level_blocks(files[p]) if "@Test" not in body}
    if helpers:
        uses = re.compile(r"\b(?:" + "|".join(sorted(map(re.escape, helpers))) + r")\s*[(.]")
        driving |= {p for p, text in files.items() if uses.search(text)}
    found = set(ALWAYS)
    for p in driving:
        target = p.relative_to(tests_root).parts[0]
        for name, body in top_level_blocks(files[p]):
            if "@Test" in body:
                found.add((target, name))
    return sorted(found)


def pattern(suites: list[tuple[str, str]]) -> str:
    by_target: dict[str, list[str]] = {}
    for target, name in suites:
        by_target.setdefault(target, []).append(name)
    parts = [f"{re.escape(t)}\\.({'|'.join(sorted(set(n)))})" for t, n in sorted(by_target.items())]
    return "(" + "|".join(parts) + ")\\b"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("tests_root", type=Path, help="Packages/macOS/CmuxNext/Tests")
    parser.add_argument("--list", action="store_true", help="one Target.Suite per line instead of the regex")
    parser.add_argument("--targets", default="all", help="'all' or the selected test targets, space-separated")
    args = parser.parse_args(argv)
    suites = heavy_suites(args.tests_root, args.targets)
    if not suites:
        return 0  # nothing heavy selected: no output, never a pattern that would match every test
    if args.list:
        print("\n".join(f"{t}.{n}" for t, n in suites))
    else:
        print(pattern(suites))
    return 0


if __name__ == "__main__":
    sys.exit(main())
