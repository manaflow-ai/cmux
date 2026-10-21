#!/usr/bin/env python3
"""Perf source guard (invariant I5): no CATransaction.flush
and no window capture in Packages/macOS/CmuxNext/Sources outside the capture helpers, the
screenshot actions and the debug tools. A theme change captures no window and forces no commit.

A reviewed exception carries `// perf-gate-ok: <reason>` on the line or the line above it.

This is the perf gate's source guard (scripts/cmux-next/perf-gate.py), here on its own so it runs
without an app: in the `cmux-next checks` job (on pushes and pull requests) and in the pre-push gate
(scripts/cmux-next/prepush-gate.py). The perf gate itself runs only where the scheme compiles, which
a direct push to feat-cmux-next skips; two hits landed that way (36c5b4217488, 715f623c97e1).

Usage: scripts/cmux-next/check-perf-source-guard.py [repo-root]
Prints `path:line: rule: source` for each hit and exits 1 when there is one.
"""

from __future__ import annotations

import os
import re
import sys

SOURCES = "Packages/macOS/CmuxNext/Sources"
ALLOW = re.compile(r"//\s*perf-gate-ok:\s*\S")
# Window capture APIs and the files that may use them.
CAPTURE = re.compile(r"CGWindowListCreateImage|CGDisplayCreateImage|SCScreenshotManager|\.renderSnapshot\(\)"
                     r"|\.compositedSnapshot\(|\.childWindowsSnapshot\(|\.floatingWindowsSnapshot\(\)|\.writeSnapshot\(to"
                     # The screenshot helpers' own entry points (NSWindow+Screenshot.swift).
                     r"|\.screenshotImage\(|\.screenCaptureKitSnapshot\(")
CAPTURE_FILES = re.compile(
    # The capture helpers.
    r"/CmuxNextDesign/Windows/(NSWindow\+Snapshot|NSWindow\+Screenshot|WindowFrame)\.swift$"
    # The window, pane and tab screenshot actions' image: a capture is what the person asked for.
    r"|/CmuxNextApp/Screenshots/AppWindowImage\.swift$"
    # The debug tools.
    r"|/CmuxNextApp/Control/Debug[^/]*\.swift$|/CmuxNextApp/Focus/DebugPaletteCapture\.swift$"
    r"|/CmuxNextApp/Popups/DebugPopups\.swift$")
FLUSH = re.compile(r"\bCATransaction\.flush\(")


def scan_file(rel: str, text: str) -> list[str]:
    """The hits in one file; `rel` is its path from the repository root."""
    hits = []
    lines = text.splitlines()
    for i, line in enumerate(lines):
        code = line.split("//", 1)[0]
        rule = None
        if FLUSH.search(code):
            rule = "CATransaction.flush forces a commit"
        elif CAPTURE.search(code) and not CAPTURE_FILES.search("/" + rel):
            rule = "window capture outside the capture helpers, screenshot actions and debug tools"
        if rule and not (ALLOW.search(line) or (i and ALLOW.search(lines[i - 1]))):
            hits.append(f"{rel}:{i + 1}: {rule}: {line.strip()[:120]}")
    return hits


def swift_files(root: str) -> list[str]:
    """Every Swift file under SOURCES, as paths from `root`, sorted."""
    found = []
    for directory, _, names in os.walk(os.path.join(root, SOURCES)):
        found += [os.path.relpath(os.path.join(directory, name), root).replace(os.sep, "/")
                  for name in names if name.endswith(".swift")]
    return sorted(found)


def scan(root: str) -> tuple[list[str], int]:
    """(hits, files scanned) for the tree at `root`."""
    files = swift_files(root)
    hits = []
    for rel in files:
        try:
            with open(os.path.join(root, rel), encoding="utf-8") as stream:
                hits += scan_file(rel, stream.read())
        except (OSError, UnicodeDecodeError):
            continue
    return hits, len(files)


def main(argv: list[str]) -> int:
    root = os.path.abspath(argv[1] if len(argv) > 1 else os.path.join(os.path.dirname(__file__), "../.."))
    hits, count = scan(root)
    for hit in hits:
        print(hit)
    if hits:
        print(f"perf source guard: {len(hits)} hits in {count} files; a reviewed exception carries "
              "`// perf-gate-ok: <reason>` on the line or the line above it", file=sys.stderr)
        return 1
    print(f"perf source guard: {count} files, no hits")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
