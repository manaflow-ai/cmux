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
DECL = re.compile(r"\b(?:struct|class|enum|actor|extension)\s+([A-Za-z_][A-Za-z0-9_]*)")
STRING = re.compile(r'"(?:[^"\\]|\\.)*"')


def _strip_comment(line: str) -> str:
    """The line without a trailing // comment (outside a string literal)."""
    out, quoted, i = [], False, 0
    while i < len(line):
        ch = line[i]
        if ch == "\\" and quoted:
            out.append(line[i:i + 2])
            i += 2
            continue
        if ch == '"':
            quoted = not quoted
        elif not quoted and line.startswith("//", i):
            break
        out.append(ch)
        i += 1
    return "".join(out)


def _trait_texts(text: str) -> list[str]:
    """The string literals inside each `.enabled(` / `.disabled(` call of one line."""
    texts = []
    for match in TRAIT.finditer(text):
        depth, end = 1, match.end()
        while end < len(text) and depth:
            depth += {"(": 1, ")": -1}.get(text[end], 0)
            end += 1
        texts.extend(STRING.findall(text[match.end():end]))
    return texts


def suites_in(source: str) -> set[str]:
    """The type names in one Swift file whose own trait, or a trait of a test inside them, asks for a display.
    A trait on a `@Suite` line belongs to the declaration that follows; any other (a `@Test` line's) to the
    innermost type around it."""
    found: set[str] = set()
    stack: list[tuple[str, int]] = []
    depth, pending, suite_trait = 0, None, False
    for raw in source.splitlines():
        line = _strip_comment(raw)
        bare = STRING.sub('""', line)
        needs = any(DISPLAY.search(text) for text in _trait_texts(line))
        if needs and bare.lstrip().startswith("@") and "@Suite" in bare:
            suite_trait = True
        elif needs and stack:
            found.add(stack[-1][0])
        if decl := DECL.search(bare):
            pending = decl.group(1)
            if suite_trait:
                found.add(pending)
                suite_trait = False
        for ch in bare:
            if ch == "{":
                depth += 1
                if pending:
                    stack.append((pending, depth))
                    pending = None
            elif ch == "}":
                if stack and stack[-1][1] == depth:
                    stack.pop()
                depth -= 1
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
