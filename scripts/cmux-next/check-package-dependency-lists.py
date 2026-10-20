#!/usr/bin/env python3
"""Keep Package.swift's hot dependency lists one entry per line and sorted.

Nearly every new CmuxNext module adds itself to the CmuxNextAppTests
dependencies. While that list was a few long lines that every pull request
appended to, two pull requests adding different modules always conflicted
(2026-10-20: #21480, #21487, #21284, #21568, #20945 and #21921 were each
CONFLICTING again within about twenty minutes of a clean rebase). GitHub runs
no merge drivers, so the fix is the layout: with one entry per line, sorted,
each with a trailing comma, two additions land on different lines and merge
cleanly unless they are neighbours in the sort order.

A list opts in with this marker on its opening line:

    dependencies: [  // sorted: scripts/cmux-next/check-package-dependency-lists.py

and the targets in REQUIRED must carry it. Inside a marked list every line is
one complete entry ending in a comma, or a `//` comment line, which belongs to
the entry below it and moves with it. Entries sort by their text: target names
("...") before products (.product(...)), each alphabetically.

Usage: scripts/cmux-next/check-package-dependency-lists.py [--fix] [PACKAGE_SWIFT]
  --fix  rewrite each marked list in canonical order (a merge resolution that
         kept both sides' lines in any order becomes canonical)
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MANIFEST = ROOT / "Packages/macOS/CmuxNext/Package.swift"
MARKER = "// sorted: scripts/cmux-next/check-package-dependency-lists.py"
REQUIRED = ("CmuxNextAppTests",)

OPEN = re.compile(r"^(\s*)dependencies: \[\s*" + re.escape(MARKER) + r"\s*$")
NAME = re.compile(r'^\s*name: "([^"]+)",\s*$')


class ListError(Exception):
    pass


def entries_of(lines: list[str], start: int) -> tuple[list[tuple[list[str], str]], int]:
    """Parse the marked list opening at `start`: ([(comments, entry)], closing line index)."""
    entries: list[tuple[list[str], str]] = []
    comments: list[str] = []
    i = start + 1
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if stripped in ("]", "],"):
            if comments:
                raise ListError(f"line {i + 1}: a comment ends the list instead of preceding an entry")
            return entries, i
        if not stripped:
            raise ListError(f"line {i + 1}: blank line inside a sorted list")
        if stripped.startswith("//"):
            comments.append(line)
        elif "//" in stripped:
            raise ListError(f"line {i + 1}: put the comment on its own line above the entry: {stripped}")
        elif not stripped.endswith(","):
            raise ListError(f"line {i + 1}: an entry must end in a comma: {stripped}")
        elif stripped.count("(") != stripped.count(")") or stripped.count('"') % 2:
            raise ListError(f"line {i + 1}: an entry must be complete on its own line: {stripped}")
        elif top_level_commas(stripped) != 1:
            raise ListError(f"line {i + 1}: one entry per line: {stripped}")
        else:
            entries.append((comments, line))
            comments = []
        i += 1
    raise ListError(f"line {start + 1}: the list never closes")


def top_level_commas(entry: str) -> int:
    """Commas outside string literals and parentheses: 1 for one entry with its trailing comma."""
    count = depth = 0
    quoted = False
    for char in entry:
        if char == '"':
            quoted = not quoted
        elif quoted:
            continue
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        elif char == "," and depth == 0:
            count += 1
    return count


def key(entry: str) -> str:
    return entry.strip()


def target_name(lines: list[str], start: int) -> str | None:
    for i in range(start - 1, max(start - 6, -1), -1):
        match = NAME.match(lines[i])
        if match:
            return match.group(1)
    return None


def check(text: str, fix: bool) -> tuple[list[str], str]:
    lines = text.split("\n")
    problems: list[str] = []
    marked: set[str] = set()
    out: list[str] = []
    i = 0
    while i < len(lines):
        out.append(lines[i])
        if not OPEN.match(lines[i]):
            i += 1
            continue
        name = target_name(lines, i) or f"line {i + 1}"
        marked.add(name)
        try:
            entries, close = entries_of(lines, i)
        except ListError as error:
            problems.append(f"{name}: {error}")
            i += 1
            continue
        seen: set[str] = set()
        for _, entry in entries:
            if key(entry) in seen:
                problems.append(f"{name}: duplicate entry {key(entry)}")
            seen.add(key(entry))
        indent = {len(entry) - len(entry.lstrip()) for _, entry in entries}
        if len(indent) > 1:
            problems.append(f"{name}: entries are not all indented alike")
        ordered = sorted(entries, key=lambda pair: key(pair[1]))
        if ordered != entries:
            problems.append(f"{name}: entries are not sorted (run with --fix)")
        for comments, entry in ordered if fix else entries:
            out.extend(comments)
            out.append(entry)
        out.append(lines[close])
        i = close + 1
    for name in REQUIRED:
        if name not in marked:
            problems.append(f"{name}: its dependencies list lacks the marker `{MARKER}`")
    return problems, "\n".join(out)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--fix", action="store_true")
    parser.add_argument("manifest", nargs="?", type=Path, default=DEFAULT_MANIFEST)
    args = parser.parse_args()
    text = args.manifest.read_text(encoding="utf-8")
    problems, fixed = check(text, args.fix)
    if args.fix:
        if fixed != text:
            args.manifest.write_text(fixed, encoding="utf-8")
            print(f"sorted the dependency lists in {args.manifest}")
        problems, _ = check(fixed, False)
    for problem in problems:
        print(f"{args.manifest}: {problem}", file=sys.stderr)
    if problems:
        print("One dependency per line, sorted, trailing comma; `--fix` sorts a list.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
