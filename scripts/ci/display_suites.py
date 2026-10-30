#!/usr/bin/env python3
"""Checks the declared list of Swift test suites that need a display against the suites' own skip traits.

A suite needs a display when it, or any test in it, carries an `.enabled(...)` or `.disabled(...)` trait whose
comment names a display, a screen or a GUI host or session ("the drag tests need a display", "needs an awake
display and animations on, ...", "run on a GUI host", "no GUI login session"). Those traits are the source of
truth; `scripts/ci/display-suites.txt` declares the same suites so cmux-ci can read them at a step's ref and send
a `package-test-lane.sh suite` step that names one to a display worker (the `gui-session-v1` label) without the
lane asking. `--check` (cmux-next checks, tests/test_ci_display_suites.py) fails when the two differ.

Usage: display_suites.py [--root DIR]      print the suites the traits ask for (`PACKAGE TARGET.SUITE`, sorted)
       display_suites.py --check           exit 1 when scripts/ci/display-suites.txt declares other suites
       display_suites.py --fix             rewrite scripts/ci/display-suites.txt to the traits' suites
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

LIST = Path("scripts/ci/display-suites.txt")
HEADER = ("# The suites that need a display (PACKAGE TARGET.SUITE): cmux-ci sends a package-test-lane suite step\n"
          "# naming one to a display worker. Each has a display skip trait; scripts/ci/display_suites.py --check\n"
          "# keeps this list equal to those traits, and --fix rewrites it.\n")
# A skip comment that asks for a display: the words the suites' traits use.
DISPLAY = re.compile(r"\b(?:display|screen|GUI)\b", re.I)
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
        if not any(a >= trait.end() and b <= end and DISPLAY.search(text) for a, b, text in literals):
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
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--fix", action="store_true")
    mode.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    text = render(display_suites(args.root))
    target = args.root / LIST
    if args.fix:
        target.write_text(text, encoding="utf-8")
        return 0
    if args.check:
        current = target.read_text(encoding="utf-8") if target.is_file() else ""
        if current != text:
            have = {l for l in current.splitlines() if l and not l.startswith("#")}
            want = {l for l in text.splitlines() if l and not l.startswith("#")}
            for row in sorted(want - have):
                print(f"display-suites.txt: missing {row} (it has a display skip trait)", file=sys.stderr)
            for row in sorted(have - want):
                print(f"display-suites.txt: lists {row}, which has no display skip trait", file=sys.stderr)
            print("run: python3 scripts/ci/display_suites.py --fix", file=sys.stderr)
            return 1
        return 0
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
