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
    """The text between #require's parentheses, matched by nesting depth. A parenthesis inside a
    string literal ("f(x" as a search needle) is text, not nesting: it is skipped."""
    depth = 0
    quote = ""  # "" outside a string, '"' in a one-line literal, '"""' in a multi-line one
    index = open_paren
    while index < len(text):
        if quote:
            if text[index] == "\\":
                index += 2
                continue
            if text.startswith(quote, index):
                index += len(quote)
                quote = ""
                continue
            if quote == '"' and text[index] == "\n":
                quote = ""
        elif text[index] == "/" and text[index + 1 : index + 2] not in ("/", "*", " ") \
                and text[:index].rstrip()[-1:] in ("(", ",", ":", "="):
            # A one-line regex literal (/"id":"([^"]+)"/): its quotes and parentheses are pattern text.
            end = index + 1
            while end < len(text) and text[end] not in "/\n":
                end += 2 if text[end] == "\\" else 1
            if end < len(text) and text[end] == "/":
                index = end + 1
                continue
            index += 1
            continue
        elif text.startswith('"""', index):
            quote = '"""'
            index += 3
            continue
        elif text[index] == '"':
            quote = '"'
        elif text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                return text[open_paren + 1 : index]
        index += 1
    return text[open_paren + 1 :]


SELF_CHECKS = (
    # (Swift source, lines the lint must report)
    ('let a = try #require(f(try #require(g())))\n', [1]),
    ('let a = try #require(s.range(of: "f(x"))\nlet b = try #require(s.range(of: "y"))\n', []),
    ('let a = try #require(s.range(of: "q\\"("))\nlet b = try #require(t)\n', []),
    ('let a = try #require(parse("""\n  {"a": "(", "b": 1}\n  """))\nlet b = try #require(t)\n', []),
    ('let a = try #require(parse("""\n  x\n  """, try #require(y)))\n', [1]),
    ('let id = try #require(s.firstMatch(of: /"id":"([^"]+)"/)).1\nlet b = try #require(t)\n', []),
    ('let a = try #require(x / 2 > 1 ? f(try #require(y)) : 0)\n', [1]),
)


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
    for source, want in SELF_CHECKS:
        if nested_requires(source) != want:
            print(f"self-check failed: {source!r} reported {nested_requires(source)}, wanted {want}", file=sys.stderr)
            return 1
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
