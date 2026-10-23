#!/usr/bin/env python3
"""NO-SWIFTUI: macOS code is AppKit (or a Chromium web view), never SwiftUI.

The user (2026-10-21, u9493): "Ideally we don't use SwiftUI anywhere." The
plan and the port order are in plans/cmux-next/no-swiftui-DESIGN.md.

Findings, in tracked Swift files under Packages/macOS:
  1. A file that imports SwiftUI (any form: `import SwiftUI`,
     `public import SwiftUI`, `@preconcurrency import SwiftUI`,
     `import struct SwiftUI.Color`) and is not in the allowlist.
  2. An allowlist entry for a file that no longer imports SwiftUI, or no
     longer exists: delete the line, so the list only shrinks.
  3. With --base REF: an allowlist entry that the allowlist at REF did not
     have. The allowlist only shrinks; a new screen is AppKit. A file moved
     since REF (a git rename of an entry REF allowed) keeps its entry under
     its new path.

The allowlist is scripts/cmux-next/no-swiftui-allowlist.txt, one
repo-relative path per line, sorted; `#` starts a comment.

Usage: check-no-swiftui.py [--base REF] [repo-root]
Exit 0 clean, 1 with findings (each names the file), 2 on a usage error.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys

SCOPE = "Packages/macOS"
ALLOWLIST = "scripts/cmux-next/no-swiftui-allowlist.txt"

IMPORT = re.compile(
    r"^[ \t]*(?:@[\w]+(?:\([^)]*\))?[ \t]+)*"
    r"(?:(?:public|package|internal|fileprivate|private)[ \t]+)?"
    r"import[ \t]+(?:(?:struct|class|enum|protocol|func|var|let|typealias)[ \t]+)?SwiftUI\b",
    re.MULTILINE,
)


def swift_files(root: pathlib.Path) -> list[str]:
    try:
        out = subprocess.run(["git", "-C", str(root), "ls-files", "--", f"{SCOPE}/*.swift"],
                             check=True, capture_output=True, text=True).stdout
        return [line for line in out.splitlines() if line]
    except (subprocess.CalledProcessError, FileNotFoundError):
        # Not a git checkout (the guard's self-test): every Swift file on disk.
        base = root / SCOPE
        if not base.is_dir():
            return []
        return sorted(str(p.relative_to(root)) for p in base.rglob("*.swift"))


def imports_swiftui(path: pathlib.Path) -> bool:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False
    # Ignore block and line comments that mention an import.
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    return IMPORT.search(text) is not None


def parse_allowlist(text: str) -> list[str]:
    entries = []
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            entries.append(line)
    return entries


def renamed_since(root: pathlib.Path, base: str) -> dict[str, str]:
    """New path -> old path for every file git sees as renamed from `base` to the work tree."""
    try:
        out = subprocess.run(["git", "-C", str(root), "diff", "--find-renames", "--name-status", base, "--", SCOPE],
                             check=True, capture_output=True, text=True).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return {}
    moves = {}
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) == 3 and parts[0].startswith("R"):
            moves[parts[2]] = parts[1]
    return moves


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", help="the commit the allowlist may only shrink from")
    parser.add_argument("root", nargs="?", default=".")
    args = parser.parse_args()
    root = pathlib.Path(args.root).resolve()

    allow_path = root / ALLOWLIST
    allowed = parse_allowlist(allow_path.read_text()) if allow_path.exists() else []
    allowed_set = set(allowed)
    findings: list[str] = []

    if allowed != sorted(allowed) or len(allowed) != len(allowed_set):
        findings.append(f"{ALLOWLIST}: keep it sorted with no duplicates")

    importing = {f for f in swift_files(root) if imports_swiftui(root / f)}
    for f in sorted(importing - allowed_set):
        findings.append(f"{f}: imports SwiftUI. macOS UI is AppKit (plans/cmux-next/no-swiftui-DESIGN.md); "
                        f"the allowlist only shrinks")
    for f in sorted(allowed_set - importing):
        findings.append(f"{ALLOWLIST}: {f} no longer imports SwiftUI (or is gone): delete its line")

    if args.base:
        try:
            old = subprocess.run(["git", "-C", str(root), "show", f"{args.base}:{ALLOWLIST}"],
                                 check=True, capture_output=True, text=True).stdout
            old_allowed = set(parse_allowlist(old))
            moves = renamed_since(root, args.base)
            for f in sorted(allowed_set - old_allowed):
                if moves.get(f) in old_allowed:
                    continue
                findings.append(f"{ALLOWLIST}: {f} is new since {args.base}; the allowlist only shrinks")
        except subprocess.CalledProcessError:
            print(f"note: no {ALLOWLIST} at {args.base}; growth check skipped", file=sys.stderr)

    for line in findings:
        print(f"NO-SWIFTUI: {line}", file=sys.stderr)
    if findings:
        print(f"NO-SWIFTUI: {len(findings)} finding(s); {len(importing)} file(s) still import SwiftUI",
              file=sys.stderr)
        return 1
    print(f"NO-SWIFTUI: ok, {len(importing)} allowlisted file(s) left")
    return 0


if __name__ == "__main__":
    sys.exit(main())
