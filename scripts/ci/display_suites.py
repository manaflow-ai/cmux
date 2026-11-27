#!/usr/bin/env python3
"""Derives the list of Swift test suites that need a display from the suites' own skip traits.

A suite needs a display when it, or any test in it, carries an `.enabled(...)` or `.disabled(...)` trait whose
condition reads `NSScreen` or whose comment names a display, a screen or a GUI host or session ("the drag tests need a display", "needs an awake
display and animations on, ...", "run on a GUI host", "no GUI login session"). Those traits are the only source of
truth. The list is derived wherever it is read, never committed: a committed copy went stale on every pull request
that added a display test (generated_files_guard.py refuses a new committed generated file, so the pull request
autofix could not write it) until the post-merge base autofix landed it. A reader that wants the list at another
commit runs this script from that commit's tree (`--root`).

Usage: display_suites.py [--root DIR]      print the suites the traits ask for (`PACKAGE TARGET.SUITE`, sorted)

`--fix` and `--check` are transitional no-ops that write, print and check nothing and exit 0. The pull request
autofix runs a trusted copy of base's scripts (`git archive "$BASE_SHA"`) against the pull request's tree, and base's
base-autofix.sh step 1e4 calls this script with `--fix` until this change is on base (run 43196743424 failed with
`unrecognized arguments: --fix`). Remove both, and tests/test_ci_display_suites.py's BASE_STEP_1E4, once no base the
autofix can archive has step 1e4.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

HEADER = ("# The suites that need a display (PACKAGE TARGET.SUITE), derived from their display skip traits by\n"
          "# scripts/ci/display_suites.py; never committed.\n")
# A skip comment that asks for a display: the words the suites' traits use.
DISPLAY = re.compile(r"\b(?:display|screen|GUI)\b", re.I)
# A trait condition that reads the screen needs one too, comment or not: `.enabled(if: NSScreen.main != nil)` gives
# no reason, so TitlebarDoubleClickTests was not listed and its `cmux-ci run --display` step went to a worker with
# no screen (P0 display run 20b78078, 2026-10-31).
SCREEN_CODE = re.compile(r"\bNSScreen\b")
TRAIT = re.compile(r"\.(?:enabled|disabled)\(")
# A type declaration; `class func` / `class var` (a class member) is no type.
DECL = re.compile(r"\b(?:struct|class|enum|actor|extension)\s+(?!(?:func|var|let|subscript|init)\b)([A-Za-z_][A-Za-z0-9_]*)")
SUITE_ATTRIBUTE = re.compile(r"@Suite\s*\(")


def lex(source: str) -> tuple[str, list[tuple[int, int, str]]]:
    """source with every comment and string literal blanked (same length, newlines kept), and the literals as
    (start, end, text). Knows // and nested /* */ comments, "...", multi-line \"\"\"...\"\"\" and #"..."# raw strings;
    an interpolation's code stays inside its literal, which is enough to find traits and braces."""
    out, literals, i, n = list(source), [], 0, len(source)

    def blank(a: int, b: int) -> None:
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        if source.startswith("//", i):
            j = source.find("\n", i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
        elif source.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if source.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif source.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            blank(i, j)
            i = j
        elif source[i] == '"' or (source[i] == "#" and re.match(r'#+"', source[i:])):
            hashes = len(source[i:]) - len(source[i:].lstrip("#"))
            start = i + hashes
            multi = source.startswith('"""', start)
            quote = '"""' if multi else '"'
            close = quote + "#" * hashes
            j = start + len(quote)
            while j < n:
                if source.startswith(close, j):
                    break
                if source[j] == "\\" and not hashes:
                    j += 2
                    continue
                if source[j] == "\n" and not multi:
                    break
                j += 1
            j = min(n, j + len(close))
            literals.append((i, j, source[start + len(quote):max(start + len(quote), j - len(close))]))
            blank(i, j)
            i = j
        else:
            i += 1
    return "".join(out), literals


def _close(code: str, at: int, open_ch: str = "(", close_ch: str = ")") -> int:
    """The index after the bracket that closes the one opened just before at (len(code) when unclosed)."""
    depth, j = 1, at
    while j < len(code) and depth:
        depth += {open_ch: 1, close_ch: -1}.get(code[j], 0)
        j += 1
    return j


def suites_in(source: str) -> set[str]:
    """The type names in one Swift file whose own trait, or a trait of a test inside them, asks for a display.
    A trait inside a `@Suite(...)` attribute belongs to the declaration after it; any other (a `@Test(...)`'s,
    however many lines it spans) to the innermost type whose body holds it."""
    code, literals = lex(source)
    bodies: list[tuple[int, int, str]] = []
    for decl in DECL.finditer(code):
        brace = code.find("{", decl.end())
        if brace >= 0:
            bodies.append((brace, _close(code, brace + 1, "{", "}"), decl.group(1)))
    suites = [(m.end(), _close(code, m.end())) for m in SUITE_ATTRIBUTE.finditer(code)]
    found: set[str] = set()
    for trait in TRAIT.finditer(code):
        end = _close(code, trait.end())
        if not (any(a >= trait.end() and b <= end and DISPLAY.search(text) for a, b, text in literals)
                or SCREEN_CODE.search(code, trait.end(), end)):
            continue
        attribute = next(((a, b) for a, b in suites if a <= trait.start() < b), None)
        if attribute:
            after = DECL.search(code, attribute[1])
            if after:
                found.add(after.group(1))
            continue
        around = [body for body in bodies if body[0] < trait.start() < body[1]]
        if around:
            found.add(max(around, key=lambda body: body[0])[2])
    return found


def display_suites(root: Path) -> list[str]:
    """`PACKAGE TARGET.SUITE` for every display suite under root/Packages/*/Tests/TARGET, sorted."""
    rows = set()
    for path in sorted((root / "Packages").glob("**/Tests/*/**/*.swift")):
        parts = path.relative_to(root).parts
        if ".build" in parts or any(part.startswith(".build") for part in parts):
            continue
        tests = parts.index("Tests")
        package, target = "/".join(parts[:tests]), parts[tests + 1]
        if not (root / package / "Package.swift").is_file():
            continue
        for suite in suites_in(path.read_text(encoding="utf-8", errors="replace")):
            rows.add(f"{package} {target}.{suite}")
    return sorted(rows)


def render(rows: list[str]) -> str:
    return HEADER + "".join(row + "\n" for row in rows)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    # Transitional: base's trusted base-autofix.sh step 1e4 still calls --fix (see the module docstring).
    parser.add_argument("--fix", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--check", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if args.fix or args.check:
        return 0
    sys.stdout.write(render(display_suites(args.root)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
