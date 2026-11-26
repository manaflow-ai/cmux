#!/usr/bin/env python3
"""Fail a pull request that adds a loading placeholder to the iPhone app.

Leo, 2026-11-24: "holy shit this is a huge problem in ios... wer need to chase all
these placeholders doen and prevent them". A screen the phone has already seen
should draw what it last had (cached rows, the last transcript, the last frame).
It should not show a spinner, a "Loading…" line, a redacted skeleton or a
shimmer while it waits for the Mac.

This check reads only the lines a change adds (git diff BASE...HEAD) in the
iPhone app's Swift (cmux-next-ios/ and Packages/iOS/). A placeholder that is
already on the base is not this change's to fix. The inventory of those lives in
cmux-next-ios/design/placeholder-inventory.md. An added line fails when it draws
one of these:

  spinner        ProgressView(...) or CmuxSpinner(...) (not ProgressView(value:), a bar)
  redacted       .redacted(reason: .placeholder)
  skeleton       a Skeleton view drawn (SkeletonList(...), RowSkeleton(...))
  loading-text   "Loading <thing>" / "Fetching|Syncing|Refreshing <thing>", or any
                 "Updating|Connecting|Waiting for …" ending in an ellipsis
                 ("Loading members", "Connecting…"; "Waiting for approval" passes)

A real wait with nothing cached to show (first sign-in, a send in flight, a
download the person started) may keep its indicator. To keep it, put
`placeholder-ok: <why nothing cached can stand in>` on the line or on one of the
two lines above it. The reason is required: a bare `placeholder-ok` still fails.

Usage: check-ios-loading-placeholders.py BASE_SHA [HEAD]   (exit 0 clean, 1 found, 2 usage)
       check-ios-loading-placeholders.py --scan PATH...    (report every hit, for the inventory)
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOTS = ("cmux-next-ios/", "Packages/iOS/")
SKIP_PARTS = ("/Tests/", "/UITests/", "Tests.swift", "/.build/", "Preview", "Gallery")

RULES: list[tuple[str, re.Pattern[str]]] = [
    # ProgressView(value:) is a determinate bar for a download the person started, not a wait.
    ("spinner", re.compile(r"\b(ProgressView\s*\((?!\s*value:)|CmuxSpinner\s*\()")),
    ("redacted", re.compile(r"\.redacted\s*\(\s*reason:\s*\.placeholder")),
    # A skeleton view being drawn (its construction), not the type's definition or a
    # shimmer over real text (an agent's "Working" label is live state, not a placeholder).
    ("skeleton", re.compile(r"(?<!func )(?<!init)\b[A-Za-z]*[Ss]keleton[A-Za-z]*\s*\((?!\s*\)\s*->)")),
    # Placeholder copy ends in an ellipsis; "Waiting for approval" is a real state.
    (
        "loading-text",
        re.compile(
            r'"((Loading|Fetching|Syncing|Refreshing) \w[^"]*'
            r'|(Loading|Updating|Connecting|Fetching|Syncing|Refreshing|Waiting for)\b[^"]*(…|\.\.\.))"'
        ),
    ),
]
OK_MARK = re.compile(r"placeholder-ok\s*:\s*\S")
COMMENT = re.compile(r"^\s*(//|///|\*|/\*)")


def in_scope(path: str) -> bool:
    return path.endswith(".swift") and path.startswith(ROOTS) and not any(p in path for p in SKIP_PARTS)


def hits(line: str) -> list[str]:
    if COMMENT.match(line):
        return []
    return [name for name, pat in RULES if pat.search(line)]


def allowed(lines: list[str], idx: int) -> bool:
    """idx is 0-based into the file's lines; checks it and the two lines above it."""
    return any(OK_MARK.search(lines[i]) for i in range(max(0, idx - 2), idx + 1))


def added_lines(base: str, head: str) -> dict[str, list[int]]:
    """path -> 1-based line numbers the change adds (in HEAD's copy)."""
    # CI checks out the PR's merge ref shallowly, where BASE...HEAD has no merge base:
    # there HEAD's parent is BASE, so the two-dot diff is the change itself.
    mb = subprocess.run(["git", "merge-base", base, head], capture_output=True, text=True)
    span = [f"{base}...{head}"] if mb.returncode == 0 else [base, head]
    out = subprocess.run(
        ["git", "diff", "--unified=0", "--no-color", "--diff-filter=AMR", *span, "--", *ROOTS],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    result: dict[str, list[int]] = {}
    path = None
    for raw in out.splitlines():
        if raw.startswith("+++ "):
            name = raw[4:]
            path = name[2:] if name.startswith("b/") else None
            continue
        m = re.match(r"^@@ -\S+ \+(\d+)(?:,(\d+))? @@", raw)
        if m and path and in_scope(path):
            start, count = int(m.group(1)), int(m.group(2) or "1")
            result.setdefault(path, []).extend(range(start, start + count))
    return result


def file_lines(head: str, path: str) -> list[str]:
    if head == "HEAD":
        try:
            return Path(path).read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            pass
    return subprocess.run(
        ["git", "show", f"{head}:{path}"], check=True, capture_output=True, text=True
    ).stdout.splitlines()


def findings_for(path: str, lines: list[str], only: list[int] | None) -> list[tuple[str, int, str, str]]:
    found = []
    numbers = only if only is not None else range(1, len(lines) + 1)
    for n in numbers:
        if n < 1 or n > len(lines):
            continue
        line = lines[n - 1]
        for rule in hits(line):
            if not allowed(lines, n - 1):
                found.append((path, n, rule, line.strip()[:110]))
    return found


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[1] == "--scan":
        found = []
        for root in argv[2:] or list(ROOTS):
            for p in sorted(Path(root).rglob("*.swift")):
                rel = p.as_posix()
                if in_scope(rel):
                    found += findings_for(rel, p.read_text(encoding="utf-8", errors="replace").splitlines(), None)
        for path, n, rule, text in found:
            print(f"{rule}\t{path}:{n}\t{text}")
        return 1 if found else 0
    if len(argv) not in (2, 3):
        print(__doc__, file=sys.stderr)
        return 2
    base, head = argv[1], argv[2] if len(argv) == 3 else "HEAD"
    found = []
    for path, numbers in sorted(added_lines(base, head).items()):
        found += findings_for(path, file_lines(head, path), numbers)
    for path, n, rule, text in found:
        print(f"::error file={path},line={n}::new loading placeholder ({rule}): {text}")
        print(f"NEW  {rule:<13} {path}:{n}  {text}")
    if found:
        print(
            f"\nFAIL: this change adds {len(found)} loading placeholder(s) to the iPhone app.\n"
            "Draw the cached or last-known content instead (see cmux-next-ios/design/placeholder-inventory.md).\n"
            "A real wait with nothing cached to show: add `placeholder-ok: <why>` on the line or the two above it."
        )
        return 1
    print("OK: no new loading placeholders in the iPhone app.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
