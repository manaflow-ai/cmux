#!/usr/bin/env python3
"""FOCUS-ROUTE ratchet (plans/cmux-next/focus-loss-AUDIT.md, "Focus route").

The person typed in cmux and lost the keys with no key or click (Lawrence 2026-11-15: "cmux window
stays in focus, but the text input area is out of focus"). Every move of the keyboard goes through
one route that names its caller and its reason and can refuse a move the person did not start:

  - Swift: `FocusRoute(origin, reason).moveKeyboard(in:to:)`, `.makeKey(_:front:)`,
    `.activateApp()` (Packages/macOS/CmuxNext/Sources/CmuxNextDesign/FocusRoute/FocusRoute.swift);
  - web: `focusRoute(element, origin, reason)` and `blurRoute(element, reason)`
    (webviews/src/ui/focusRoute.ts).

This guard fails on a new direct call in product code:

  - Swift under Packages/macOS/CmuxNext/Sources: `makeFirstResponder(`, `makeKey()`,
    `makeKeyAndOrderFront(`, `NSApp.activate(` / `NSApplication.shared.activate(`;
  - TypeScript under webviews/src: `.focus(` and `.blur(` calls, and an `autoFocus` JSX prop that is
    not `{false}`.

A call that must stay direct (an override's `super` call, the route itself, a page-DOM script in a
Swift string) says why in a `focus-route: <reason>` comment on its line or the line above.
Declarations (`func makeFirstResponder`, overrides), `super.` calls and comment lines do not count.
Tests, playgrounds, galleries and fixtures are out of scope.

Files from before the route are listed in scripts/cmux-next/focus-routes-baseline.tsv with their
count. A file with more direct calls than its row (or calls and no row) fails. A file with fewer
prints a note to lower its row (`--update-baseline` lowers rows, never raises one), so the count
only goes down as call sites move to the route.

It runs through prepush-gate.py. An error in the guard prints a warning and passes (fail open).

Usage: scripts/cmux-next/check-focus-routes.py [repo-root] [--list] [--update-baseline]
"""

from __future__ import annotations

import os
import re
import sys

BASELINE = "scripts/cmux-next/focus-routes-baseline.tsv"
SWIFT_ROOT = "Packages/macOS/CmuxNext/Sources"
WEB_ROOT = "webviews/src"
ROUTE_FILES = {
    "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/FocusRoute/FocusRoute.swift",
    "webviews/src/ui/focusRoute.ts",
}
SKIP_DIRS = {"node_modules", ".build", "Playground", "Playgrounds", "gallery", "fixtures", "__tests__", "test", "tests"}
SKIP_FILE = re.compile(r"(Playground|Gallery|Fixture)[\w+]*\.swift$|\.(gallery|fixture|test|spec)\.tsx?$|Plays?\.ts$")

SWIFT_CALL = re.compile(
    r"(?<![\w.])(?:[\w.?!()\]]+\.)?makeFirstResponder\s*\("
    r"|\.makeKey\s*\(\s*\)|(?<![\w.])makeKey\s*\(\s*\)"
    r"|\bmakeKeyAndOrderFront\s*\("
    r"|\bNSApp(?:lication\.shared)?\.activate\s*\("
)
SWIFT_SKIP = re.compile(r"\bfunc\s+(?:makeFirstResponder|makeKey)|\boverride\s+func\b|\bsuper\.|^\s*(//|/\*|\*)")
WEB_CALL = re.compile(r"\.(?:focus|blur)\s*\(|\bautoFocus\b(?!\s*=\s*\{\s*false\s*\})(?=\s*(?:=|\s|/?>))")
WEB_SKIP = re.compile(r"^\s*(//|/\*|\*)|\bautoFocus\s*[?:]|\binterface\b")
MARKER = re.compile(r"focus-route:\s*\S")
# Every pattern needs one of these words: a file without them is skipped unscanned.
TRIGGERS = ("FirstResponder", "makeKey", "activate", "focus", "Focus", "blur")
SWIFT_STRING = re.compile(r'"(?:[^"\\]|\\.)*"')
WEB_STRING = re.compile(r"`(?:[^`\\]|\\.)*`|'(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\"")


def direct_calls(rel: str, text: str) -> list[tuple[int, str]]:
    """Each line of REL with a direct focus call that carries no `focus-route:` reason."""
    swift = rel.endswith(".swift")
    call, skip, strings = (SWIFT_CALL, SWIFT_SKIP, SWIFT_STRING) if swift else (WEB_CALL, WEB_SKIP, WEB_STRING)
    lines = text.split("\n")
    out = []
    for index, line in enumerate(lines):
        code = strings.sub('""', line)
        if not call.search(code) or skip.search(line):
            continue
        if MARKER.search(line) or (index > 0 and MARKER.search(lines[index - 1])):
            continue
        out.append((index + 1, line.strip()))
    return out


def scan(root: str) -> dict[str, list[tuple[int, str]]]:
    hits: dict[str, list[tuple[int, str]]] = {}
    for top, suffixes in ((SWIFT_ROOT, (".swift",)), (WEB_ROOT, (".ts", ".tsx"))):
        base = os.path.join(root, top)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS and not d.lower().endswith("playground"))
            for name in sorted(filenames):
                if not name.endswith(suffixes) or name.endswith(".d.ts") or SKIP_FILE.search(name):
                    continue
                path = os.path.join(dirpath, name)
                rel = os.path.relpath(path, root).replace(os.sep, "/")
                if rel in ROUTE_FILES:
                    continue
                try:
                    with open(path, encoding="utf-8", errors="replace") as f:
                        text = f.read()
                except OSError:
                    continue
                if not any(word in text for word in TRIGGERS):
                    continue
                found = direct_calls(rel, text)
                if found:
                    hits[rel] = found
    return hits


def read_baseline(root: str) -> dict[str, int]:
    rows: dict[str, int] = {}
    path = os.path.join(root, BASELINE)
    if not os.path.exists(path):
        return rows
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2 or not parts[1].isdigit():
                print(f"check-focus-routes: bad baseline row: {line!r}", file=sys.stderr)
                sys.exit(2)
            rows[parts[0]] = int(parts[1])
    return rows


HEADER = (
    "# Direct keyboard focus calls per file from before the focus route (check-focus-routes.py).\n"
    "# Only lowered: move a call to FocusRoute (Swift) or focusRoute (web), then --update-baseline.\n"
)


def write_baseline(root: str, rows: dict[str, int]) -> None:
    with open(os.path.join(root, BASELINE), "w", encoding="utf-8") as f:
        f.write(HEADER)
        for rel in sorted(rows):
            if rows[rel] > 0:
                f.write(f"{rel}\t{rows[rel]}\n")


def main(argv: list[str]) -> int:
    args = [a for a in argv if not a.startswith("--")]
    root = os.path.abspath(args[0]) if args else os.getcwd()
    hits = scan(root)
    if "--list" in argv:
        for rel, found in sorted(hits.items()):
            for number, line in found:
                print(f"{rel}:{number}: {line}")
        return 0
    baseline = read_baseline(root)
    if "--update-baseline" in argv:
        fresh = not os.path.exists(os.path.join(root, BASELINE))
        rows = {rel: len(found) for rel, found in hits.items()} if fresh else {
            rel: min(allowed, len(hits.get(rel, []))) for rel, allowed in baseline.items()}
        write_baseline(root, rows)
        print(f"check-focus-routes: wrote {BASELINE} ({sum(rows.values())} line(s) in {len([r for r in rows.values() if r])} file(s))")
        return 0
    status = 0
    for rel, found in sorted(hits.items()):
        allowed = baseline.get(rel, 0)
        if len(found) > allowed:
            status = 1
            print(
                f"check-focus-routes: {rel} has {len(found)} direct focus call(s), baseline {allowed}. Move the keyboard "
                "through the focus route, which names the caller and the reason and refuses a move the person did not "
                "start: Swift `FocusRoute(.person or .system, \"why\").moveKeyboard(in:to:)` / `.makeKey(_:)` / "
                "`.activateApp()`, web `focusRoute(element, \"person\" or \"system\", \"why\")`. A call that must stay "
                "direct says why in a `focus-route: <reason>` comment.",
                file=sys.stderr,
            )
            for number, line in found:
                print(f"  {rel}:{number}: {line}", file=sys.stderr)
    for rel, allowed in sorted(baseline.items()):
        count = len(hits.get(rel, []))
        if count < allowed:
            print(f"check-focus-routes: {rel} now has {count} direct focus call(s), baseline {allowed}: "
                  f"lower its row ({sys.argv[0]} --update-baseline).", file=sys.stderr)
    if status == 0:
        print(f"check-focus-routes: ok ({sum(len(v) for v in hits.values())} baselined call(s) in {len(hits)} file(s))")
    return status


def guarded_main(argv: list[str]) -> int:
    """`main`, failing open on a bug in the guard (not on a finding)."""
    try:
        return main(argv)
    except SystemExit:
        raise
    except Exception as error:  # noqa: BLE001 - fail open on any guard bug
        print(f"check-focus-routes: WARNING: the guard failed ({type(error).__name__}: {error}); not applied.",
              file=sys.stderr)
        return 0


if __name__ == "__main__":
    sys.exit(guarded_main(sys.argv[1:]))
