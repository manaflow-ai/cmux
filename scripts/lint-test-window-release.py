#!/usr/bin/env python3
"""Fail if a test creates an NSWindow that frees itself on close.

An NSWindow built in code is `isReleasedWhenClosed = true` by default. A test that
builds one and closes it therefore drops a reference ARC still owns, and the freed
window is over-released the next time the autorelease pool drains — SIGSEGV in
`objc_release`, inside the test host. When the host dies mid-run xcodebuild relaunches
it and prints a summary covering only the last launch, so every verdict still pending
in the dead host is lost and the run can read as a pass.

Five separate pull requests have now fixed this one file at a time, each finding it
again in a suite nobody had run headless. The bug is not hard to fix and not hard to
understand; the problem is that nothing fails when a new window goes in without the
flag, so the next suite to grow one starts the cycle over. This is that check.

Setting the flag is safe everywhere in a test: the local strong reference is what keeps
the window alive, and it dies at end of scope. There is no case where a test wants the
window to free itself on close, so the rule has no documented-exception list.

The baseline file records how many unflagged windows each file still has, so the check
can land before the debt is paid. A count may shrink but never grow, and a file that is
not listed may not have any at all.

Usage:
  scripts/lint-test-window-release.py            # check; exit 1 on a violation
  scripts/lint-test-window-release.py --write    # rewrite the baseline from the tree
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BASELINE = REPO / "scripts" / "lint-test-window-release-baseline.tsv"
TEST_DIRS = ("cmuxTests", "cmuxUITests")

# `let window = NSWindow(`, `window = NSPanel(`, `let w: NSWindow = NSWindow(`
ASSIGNED = re.compile(
    r"(?:\b(?:let|var)\s+)?(\w+)\s*(?::\s*NS(?:Window|Panel)[?!]?\s*)?=\s*NS(?:Window|Panel)\("
)
# A construction that is not bound to a name: `return NSWindow(`, `foo(NSWindow(`
BARE = re.compile(r"NS(?:Window|Panel)\(")
FLAG = "isReleasedWhenClosed = false"
LOOKAHEAD = 14


def violations_in(path: Path) -> list[tuple[int, str]]:
    """Return (line number, window name) for each window that never clears the flag."""
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    found: list[tuple[int, str]] = []
    for i, line in enumerate(lines):
        if "NSWindow(" not in line and "NSPanel(" not in line:
            continue
        # A type reference or a signature is not a construction.
        stripped = line.strip()
        if stripped.startswith("//") or stripped.startswith("*"):
            continue
        window = None
        match = ASSIGNED.search(line)
        if match:
            window = match.group(1)
        elif BARE.search(line):
            window = None  # constructed inline; any nearby flag counts
        else:
            continue
        window_flag = f"{window}.{FLAG}" if window else FLAG
        window = window or "<inline>"
        # The flag may be set on the next line or after the multi-line initializer.
        if any(
            window_flag in lines[j] or (window == "<inline>" and FLAG in lines[j])
            for j in range(i, min(i + LOOKAHEAD, len(lines)))
        ):
            continue
        found.append((i + 1, window))
    return found


def scan() -> dict[str, list[tuple[int, str]]]:
    out: dict[str, list[tuple[int, str]]] = {}
    for directory in TEST_DIRS:
        root = REPO / directory
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*.swift")):
            found = violations_in(path)
            if found:
                out[str(path.relative_to(REPO))] = found
    return out


def read_baseline() -> dict[str, int]:
    if not BASELINE.exists():
        return {}
    allowed: dict[str, int] = {}
    for line in BASELINE.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        path, _, count = line.partition("\t")
        allowed[path.strip()] = int(count.strip())
    return allowed


def write_baseline(found: dict[str, list[tuple[int, str]]]) -> None:
    body = [
        "# Windows in the test targets that still free themselves on close.",
        "# scripts/lint-test-window-release.py fails if a count grows or a new file appears.",
        "# Lower a count by setting `isReleasedWhenClosed = false` on the window; never raise one.",
    ]
    body += [f"{path}\t{len(v)}" for path, v in sorted(found.items())]
    BASELINE.write_text("\n".join(body) + "\n", encoding="utf-8")


def main() -> int:
    found = scan()
    if "--write" in sys.argv:
        write_baseline(found)
        total = sum(len(v) for v in found.values())
        print(f"wrote {BASELINE.relative_to(REPO)}: {len(found)} files, {total} windows")
        return 0

    allowed = read_baseline()
    grew: list[str] = []
    for path, sites in sorted(found.items()):
        budget = allowed.get(path, 0)
        if len(sites) > budget:
            for line, window in sites[budget:]:
                grew.append(f"{path}:{line}: {window} is released when closed")
    shrank = [
        f"{path}\t{len(found.get(path, []))}"
        for path, budget in sorted(allowed.items())
        if len(found.get(path, [])) < budget
    ]

    if grew:
        print("An NSWindow in a test closes itself and takes the test host with it.\n")
        for line in grew:
            print(f"  {line}")
        print(
            "\nSet the flag before the window is closed:\n"
            "\n    window.isReleasedWhenClosed = false\n"
            "\nThe local reference keeps it alive for the rest of the test, and closing it\n"
            "no longer double-releases. See scripts/lint-test-window-release.py for why."
        )
        return 1

    if shrank:
        print("Windows were fixed but the baseline still lists them. Lower these counts:\n")
        for line in shrank:
            print(f"  {line}")
        print("\n  scripts/lint-test-window-release.py --write")
        return 1

    total = sum(len(v) for v in found.values())
    print(f"OK: no new self-releasing windows ({total} known, all within baseline)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
