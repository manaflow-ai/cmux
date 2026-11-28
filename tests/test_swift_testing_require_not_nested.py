#!/usr/bin/env python3
"""Swift Testing's #require macro may not appear inside another #require.

The macro expands into code that itself calls `require`, so nesting one inside
another asks the compiler to expand a macro into its own expansion:

    macro expansion #require:4:35: error: recursive expansion of macro
      'require(_:_:sourceLocation:)'

Whether that is fatal depends on the toolchain. The Swift used by this
repository's main macOS lanes accepts it; the older Swift on the macos-14 and
macos-15-intel hosts in ci-macos-compat.yml does not, and rejected it on all
four runners of run 34656982146. Because that workflow is workflow_dispatch
only, the break sat in CMUXMobileCoreTests from at least 2026-09-01 without a
required check ever going red.

A lint is the right shape for this rather than a compiler: it is a syntactic
property, it costs nothing, and it runs on Linux on every pull request instead
of whenever somebody remembers to dispatch a compatibility matrix.

Hoisting the inner call into its own `let` is always available and never
changes behaviour -- `#require` returns the unwrapped value either way.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MACRO = "#require("


def tracked_swift_files() -> list[str]:
    return subprocess.run(
        ["git", "ls-files", "*.swift"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()


def argument_span(text: str, open_paren: int) -> str:
    """The text between #require's parentheses, matched by nesting depth."""
    depth = 0
    for index in range(open_paren, len(text)):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                return text[open_paren + 1 : index]
    return text[open_paren + 1 :]


def nested_requires(text: str) -> list[int]:
    lines: list[int] = []
    start = 0
    while (found := text.find(MACRO, start)) != -1:
        open_paren = found + len(MACRO) - 1
        if MACRO in argument_span(text, open_paren):
            lines.append(text.count("\n", 0, found) + 1)
        start = found + 1
    return lines


def main() -> int:
    offenders: list[str] = []
    for path in tracked_swift_files():
        try:
            text = (ROOT / path).read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        if MACRO not in text:
            continue
        offenders.extend(f"{path}:{line}" for line in nested_requires(text))

    if offenders:
        print("#require is nested inside another #require:", file=sys.stderr)
        for offender in offenders:
            print(f"  - {offender}", file=sys.stderr)
        print(
            "\nHoist the inner call into its own `let` before the outer "
            "#require. The macro returns the unwrapped value, so the types "
            "and the assertion are unchanged.",
            file=sys.stderr,
        )
        return 1

    print("no nested #require macros")
    return 0


if __name__ == "__main__":
    sys.exit(main())
