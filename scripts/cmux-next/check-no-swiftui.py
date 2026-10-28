#!/usr/bin/env python3
"""NO-SWIFTUI: macOS code is AppKit (or a Chromium web view), never SwiftUI.

The user (2026-10-21, u9493): "Ideally we don't use SwiftUI anywhere." The
plan and the port order are in plans/cmux-next/no-swiftui-DESIGN.md.

Findings, in tracked Swift files under Packages/macOS:
  1. A file that imports SwiftUI (any form: `import SwiftUI`,
     `public import SwiftUI`, `@preconcurrency import SwiftUI`,
     `import struct SwiftUI.Color`) and is not in the allowlist.
  2. An allowlist entry for a file that no longer imports SwiftUI, or no
     longer exists: delete the line, so the list only shrinks. If the file
     is gone and one unlisted file with its name now imports SwiftUI, it
     moved: the finding names the new path, so the line is re-pointed, not
     deleted (deleting it left the moved file failing, 91d4ac2f).
  3. With --base REF: an allowlist entry that the allowlist at REF did not
     have. The allowlist only shrinks; a new screen is AppKit. A file moved
     since REF keeps its entry under its new path: a git rename of an entry
     REF allowed, or (a move that also rewrote the file, below git's rename
     similarity) an entry swapped one-for-one for the entry REF allowed with
     the same file name whose file is gone (the name unique among both the
     gone and the added entries). An entry for a file that already imported
     SwiftUI at REF adds no SwiftUI: it is printed as a note, not a finding
     (it acknowledges a base red; the review sees the list grow).

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


def imported_at(root: pathlib.Path, ref: str, path: str) -> bool:
    """Whether `path` existed at `ref` and imported SwiftUI there."""
    try:
        text = subprocess.run(["git", "-C", str(root), "show", f"{ref}:{path}"],
                              check=True, capture_output=True, text=True).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False
    return IMPORT.search(re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)) is not None


def by_name(paths) -> dict[str, list[str]]:
    """File name -> the paths with that name."""
    names: dict[str, list[str]] = {}
    for path in paths:
        names.setdefault(pathlib.PurePosixPath(path).name, []).append(path)
    return names


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
    unlisted = by_name(importing - allowed_set)
    for f in sorted(allowed_set - importing):
        moved = unlisted.get(pathlib.PurePosixPath(f).name, [])
        if len(moved) == 1 and not (root / f).exists():
            findings.append(f"{ALLOWLIST}: {f} is gone and {moved[0]} imports SwiftUI: if it moved there, "
                            f"change the line to the new path instead of deleting it")
        else:
            findings.append(f"{ALLOWLIST}: {f} no longer imports SwiftUI (or is gone): delete its line")

    if args.base:
        try:
            old = subprocess.run(["git", "-C", str(root), "show", f"{args.base}:{ALLOWLIST}"],
                                 check=True, capture_output=True, text=True).stdout
            old_allowed = set(parse_allowlist(old))
            moves = renamed_since(root, args.base)
            added = sorted(allowed_set - old_allowed)
            # A move that also rewrote the file: pair one gone entry with one added entry of the
            # same file name, only when the name is unique on both sides.
            dropped = by_name(f for f in old_allowed - allowed_set if not (root / f).exists())
            added_names = by_name(added)
            for f in added:
                name = pathlib.PurePosixPath(f).name
                if moves.get(f) in old_allowed or (len(dropped.get(name, [])) == 1 and len(added_names[name]) == 1):
                    continue
                if imported_at(root, args.base, f):
                    # Not new SwiftUI: the file already imported it at the base (a base red this
                    # entry acknowledges). Shown, so the review sees the list grow.
                    print(f"note: {f} is new in {ALLOWLIST} but already imported SwiftUI at {args.base}",
                          file=sys.stderr)
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
