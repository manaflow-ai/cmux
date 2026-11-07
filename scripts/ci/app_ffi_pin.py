#!/usr/bin/env python3
"""The app FFI pin of Packages/macOS/CmuxNext/Package.swift, read by one fail-closed canonical match.

    python3 scripts/ci/app_ffi_pin.py read [Package.swift]               # prints "SOURCE_SHA CHECKSUM"
    python3 scripts/ci/app_ffi_pin.py rewrite SHA CHECKSUM [Package.swift]

No Swift is parsed (2026-11-07: five lexer holes in a row, so the reader stopped lexing). The whole file is read as raw
text, and nothing in it is skipped, comments and strings included:

- none of the constructs that can hide a line from the compiler or carry one over several lines appears anywhere: a
  block comment (`/*`, `*/`), a multiline string (three quotes), a raw string or extended regex (`#"`, `#/`), or a
  conditional compilation block (`#if`). With none of them, every line is code or a whole-line `//` comment, and a
  string or a bare regex ends on its own line;
- `binaryTarget`, `releases/download/`, `xcframework.zip` and `checksum:` each occur exactly once, all of them in the
  CANONICAL block below, which must match line for line (anchored, its text and indentation fixed). Only the release
  sha of its url (this repository's own cmux-app-ffi-<sha> release download) and its 64-hex checksum vary;
- every other line that names CCmuxAppFFI or appFFI has one fixed, anchored shape (OTHER_LINES): a whole-line `//`
  comment, a target list element, or a dependencies list of plain names and products. None of those can declare a
  target, so the canonical block is the only CCmuxAppFFI declaration in the file.

Anything else refuses, naming the first line that does not match. base_red_excuse.py's published-base-pin rule, the
repin picker (scripts/cmux-next/newest_app_ffi_release.py) and the repin script (scripts/cmux-next/repin-app-ffi.sh)
all read and rewrite the pin through this file alone.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = "manaflow-ai/cmux"
MANIFEST = Path(__file__).resolve().parents[2] / "Packages/macOS/CmuxNext/Package.swift"
TARGET = "CCmuxAppFFI"
FORBIDDEN = ("/*", "*/", '"""', '#"', "#/", "#if")
ONCE = ("binaryTarget", "releases/download/", "xcframework.zip", "checksum:")
NAME = r"[A-Za-z0-9_]+"
ELEMENT = rf'(?:"{NAME}"|\.product\(name: "{NAME}", package: "{NAME}"\))'
OTHER_LINES = (
    re.compile(r"^\s*//[^\n]*$"),  # a whole-line comment
    re.compile(rf'^\s+"{TARGET}",?$'),  # an element of a multi-line dependencies list
    re.compile(r"^\s+appFFI,?$"),  # the target in the package's target list
    re.compile(r"^\s+\] \+ \[appFFI\],?$"),  # the target list's end, the target appended
    re.compile(rf"^\s+dependencies: \[{ELEMENT}(?:, {ELEMENT})*\],?$"),  # a one-line dependencies list
)


def canonical(repo: str = REPO) -> tuple[re.Pattern[str], ...]:
    """The canonical block's lines, anchored: the url's release sha and the checksum are its only groups."""
    return (
        re.compile(r"^let appFFI: Target = \.binaryTarget\($"),
        re.compile(rf'^    name: "{TARGET}",$'),
        re.compile(r'^    url: "https://github\.com/' + re.escape(repo)
                   + rf'/releases/download/cmux-app-ffi-([0-9a-f]{{40}})/{TARGET}\.xcframework\.zip",$'),
        re.compile(r'^    checksum: "([0-9a-f]{64})"$'),
        re.compile(r"^\)$"),
    )


class NotCanonical(ValueError):
    """Package.swift's app FFI pin is not the canonical block: the reason names the first line that fails."""


def read(text: str, repo: str = REPO) -> tuple[str, str, int]:
    """(source sha, checksum, the canonical block's first line index) of TEXT, Package.swift's whole text."""
    for token in FORBIDDEN:
        if token in text:
            line = text[:text.index(token)].count("\n") + 1
            raise NotCanonical(f"Package.swift line {line} has {token!r}, which no canonical pin file has")
    for token in ONCE:
        if text.count(token) != 1:
            raise NotCanonical(f"Package.swift has {text.count(token)} {token!r}, not one")
    lines = text.split("\n")
    start = next(i for i, line in enumerate(lines) if "binaryTarget" in line)
    block, found = canonical(repo), []
    for offset, pattern in enumerate(block):
        line = lines[start + offset] if start + offset < len(lines) else ""
        match = pattern.fullmatch(line)
        if not match:
            raise NotCanonical(f"Package.swift line {start + offset + 1} is not the canonical {TARGET} pin line "
                               f"{pattern.pattern!r}: {line[:160]!r}")
        found.extend(match.groups())
    for index, line in enumerate(lines):
        if start <= index < start + len(block) or (TARGET not in line and "appFFI" not in line):
            continue
        if not any(pattern.fullmatch(line) for pattern in OTHER_LINES):
            raise NotCanonical(f"Package.swift line {index + 1} names {TARGET} or appFFI outside the canonical pin and its "
                               f"fixed reference shapes: {line[:160]!r}")
    return found[0], found[1], start


def rewrite(text: str, sha: str, checksum: str, repo: str = REPO) -> str:
    """TEXT with only the canonical block's release sha and checksum replaced; NotCanonical before or after."""
    if not re.fullmatch(r"[0-9a-f]{40}", sha) or not re.fullmatch(r"[0-9a-f]{64}", checksum):
        raise NotCanonical(f"bad pin {sha!r} {checksum!r}")
    old_sha, old_checksum, start = read(text, repo)
    lines = text.split("\n")
    lines[start + 2] = lines[start + 2].replace(f"cmux-app-ffi-{old_sha}/", f"cmux-app-ffi-{sha}/")
    lines[start + 3] = lines[start + 3].replace(f'"{old_checksum}"', f'"{checksum}"')
    out = "\n".join(lines)
    if read(out, repo)[:2] != (sha, checksum):
        raise NotCanonical("the rewritten pin does not read back")
    return out


def main(argv: list[str]) -> int:
    try:
        if argv[:1] == ["read"] and len(argv) <= 2:
            path = Path(argv[1]) if len(argv) == 2 else MANIFEST
            sha, checksum, _ = read(path.read_text(encoding="utf-8"))
            print(sha, checksum)
            return 0
        if argv[:1] == ["rewrite"] and len(argv) in (3, 4):
            path = Path(argv[3]) if len(argv) == 4 else MANIFEST
            path.write_text(rewrite(path.read_text(encoding="utf-8"), argv[1], argv[2]), encoding="utf-8")
            return 0
    except NotCanonical as why:
        print(f"error: {why}", file=sys.stderr)
        return 1
    print(__doc__.split("\n\n")[0], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
