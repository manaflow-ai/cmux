#!/usr/bin/env python3
"""
Deterministically sort the high-churn sections of cmux.xcodeproj/project.pbxproj.

What we sort:
  - Every entry inside PBXBuildFile and PBXFileReference (Xcode picks
    arbitrary order; entries are referenced by UUID so order is irrelevant
    to the build).
  - The files = ( ... ) arrays inside PBXSourcesBuildPhase,
    PBXResourcesBuildPhase, PBXFrameworksBuildPhase, and
    PBXCopyFilesBuildPhase (Xcode reorders these on UI touches; the
    compiler does not care about order).

What we leave alone:
  - PBXGroup children = ( ... ) arrays. Order controls the project
    navigator's visible order; sorting would reorder folders in the UI.
  - All UUIDs and all comment text. We only reorder lines, never
    rewrite identifiers.
  - The objectVersion field, build settings, and every other section.

Idempotent: running twice produces zero diff.
Designed for the OpenStep-pbxproj flavor that Xcode writes by default.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

DEFAULT_PATH = Path("cmux.xcodeproj/project.pbxproj")

ENTRY_COMMENT_RE = re.compile(r"/\*\s*(?P<label>.+?)\s*\*/")

# Sections we sort flat. Every entry is a single line of the form
#   <UUID> /* <label> */ = { ... };
FLAT_SECTIONS = (
    "PBXBuildFile",
    "PBXFileReference",
)

# Build phase sections whose `files = (...)` arrays we sort. Each line
# inside the array looks like
#   <UUID> /* <label> in <phase> */,
BUILD_PHASE_SECTIONS = (
    "PBXSourcesBuildPhase",
    "PBXResourcesBuildPhase",
    "PBXFrameworksBuildPhase",
    "PBXCopyFilesBuildPhase",
)


def entry_sort_key(line: str) -> tuple[str, str]:
    """Sort lines by their /* comment */ label, then UUID as tie-breaker.

    Falls back to the raw line when no comment is present so we never
    drop or scramble unexpected lines.
    """
    comment = ENTRY_COMMENT_RE.search(line)
    label = comment.group("label").lower() if comment else line.strip().lower()
    uuid = line.lstrip().split(" ", 1)[0]
    return (label, uuid)


def sort_flat_section(lines: list[str], section: str) -> list[str]:
    begin = f"/* Begin {section} section */"
    end = f"/* End {section} section */"
    try:
        start = next(i for i, l in enumerate(lines) if l.strip() == begin)
        stop = next(i for i, l in enumerate(lines) if l.strip() == end)
    except StopIteration:
        return lines

    body = lines[start + 1 : stop]
    # Separate content lines from blank lines; blanks are collapsed to a
    # trailing group so they don't interleave with the sorted entries.
    entries = [l for l in body if l.strip()]
    blanks = [l for l in body if not l.strip()]
    entries.sort(key=entry_sort_key)
    new_body = entries + blanks
    return lines[: start + 1] + new_body + lines[stop:]


def sort_build_phase_files(lines: list[str], section: str) -> list[str]:
    begin = f"/* Begin {section} section */"
    end = f"/* End {section} section */"
    try:
        start = next(i for i, l in enumerate(lines) if l.strip() == begin)
        stop = next(i for i, l in enumerate(lines) if l.strip() == end)
    except StopIteration:
        return lines

    out = lines[: start + 1]
    body = lines[start + 1 : stop]
    i = 0
    while i < len(body):
        line = body[i]
        out.append(line)
        if line.strip() == "files = (":
            j = i + 1
            inner = []
            while j < len(body) and body[j].strip() != ");":
                inner.append(body[j])
                j += 1
            inner.sort(key=entry_sort_key)
            out.extend(inner)
            i = j
            continue
        i += 1
    return out + lines[stop:]


def normalize(text: str) -> str:
    lines = text.splitlines(keepends=True)
    for section in FLAT_SECTIONS:
        lines = sort_flat_section(lines, section)
    for section in BUILD_PHASE_SECTIONS:
        lines = sort_build_phase_files(lines, section)
    return "".join(lines)


def main(argv: list[str]) -> int:
    check_only = "--check" in argv
    positional = [a for a in argv[1:] if not a.startswith("--")]
    path = Path(positional[0]) if positional else DEFAULT_PATH

    if not path.exists():
        print(f"error: not found: {path}", file=sys.stderr)
        return 2

    original = path.read_text()
    normalized = normalize(original)

    if check_only:
        if original != normalized:
            print(
                f"error: {path} is not normalized. Run scripts/normalize-pbxproj.py to fix.",
                file=sys.stderr,
            )
            return 1
        return 0

    if original != normalized:
        path.write_text(normalized)
        print(f"normalized: {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
