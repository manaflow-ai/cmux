#!/usr/bin/env python3
"""APP-ID-SPECIAL-CASES ratchet (docs/app-store-platonic-ideal.md 5, phase 0).

Zero first-party privilege: Home, the App Store, Cloud, CodeRouter and every
other built-in app use only the public app platform, so native code never
branches on an app id. Each place where Swift or Rust product code names a
first-party app id is debt: a third-party app could not get the same behavior.

This guard counts string literals of first-party app ids in product code:
  - the manifest form `"cmux/<name>"` and the namespace form `"cmux.<name>"`
    for every app in first-party-apps/ (the namespace form only as a whole
    literal, so op names such as "cmux.home.open" are not counted);
  - Swift under Packages/macOS/CmuxNext/Sources, Rust under cmux-tui/crates/*/src;
  - not tests, not first-party-apps/ itself, not comments.

Existing sites are listed in scripts/cmux-next/app-id-special-cases-baseline.tsv
with the number of literals per FILE. A file with more literals than its row,
or with literals and no row, fails: a special case moved out of one file cannot
come back in another. A file with fewer only prints a note to lower the row
(exit 0), because the pre-push gate judges the push against the installed copy
of this baseline.

It runs in the local pre-push gate (prepush-gate.py), which refuses a push
whose tree has a finding the base tree did not have. An error in the guard
itself prints a warning and passes (fail open). Tested by
scripts/cmux-next/tests/check-app-id-special-cases.test.sh.

Usage: scripts/cmux-next/check-app-id-special-cases.py [repo-root] [--list] [--write-baseline]
  --list            print every counted literal and exit 0.
  --write-baseline  rewrite the baseline from the tree (only to lower rows or
                    to seed it; a raise needs a reviewed reason in the commit).
"""

from __future__ import annotations

import os
import re
import sys

BASELINE = "scripts/cmux-next/app-id-special-cases-baseline.tsv"
SWIFT_ROOT = "Packages/macOS/CmuxNext/Sources"
RUST_ROOT = "cmux-tui/crates"
HEADER = "# path\tapp id literals\t(check-app-id-special-cases.py; the count only goes down)\n"


def first_party_names(root: str) -> list[str]:
    folder = os.path.join(root, "first-party-apps")
    try:
        entries = sorted(os.listdir(folder))
    except OSError:
        return []
    return [name for name in entries if os.path.isdir(os.path.join(folder, name)) and re.fullmatch(r"[a-z][a-z0-9-]*", name)]


def literal_pattern(names: list[str]) -> re.Pattern[str] | None:
    if not names:
        return None
    alternation = "|".join(re.escape(n) for n in sorted(names, key=len, reverse=True))
    underscored = "|".join(re.escape(n.replace("-", "_")) for n in sorted(names, key=len, reverse=True))
    return re.compile(rf'"(?:cmux/(?:{alternation})|cmux\.(?:{underscored}))"')


def strip_comment(line: str, rust_or_swift: bool = True) -> str:
    # A `//` outside a string ends the code on this line (good enough for a lint).
    out, in_string, i = [], False, 0
    while i < len(line):
        c = line[i]
        if c == "\\" and in_string:
            out.append(line[i:i + 2])
            i += 2
            continue
        if c == '"':
            in_string = not in_string
        if not in_string and line.startswith("//", i):
            break
        out.append(c)
        i += 1
    return "".join(out)


def is_test_path(path: str) -> bool:
    parts = path.split("/")
    name = parts[-1]
    return (
        "tests" in parts
        or "Tests" in parts
        or name.endswith("_tests.rs")
        or name.endswith("Tests.swift")
        or name == "tests.rs"
        or "/test_support" in path
    )


def product_files(root: str) -> list[str]:
    found = []
    for base, suffix in ((SWIFT_ROOT, ".swift"), (RUST_ROOT, ".rs")):
        top = os.path.join(root, base)
        for directory, dirs, files in os.walk(top):
            dirs[:] = [d for d in dirs if d not in ("target", "node_modules", ".build", "tests", "Tests")]
            rel_dir = os.path.relpath(directory, root)
            if base == RUST_ROOT and "/src" not in "/" + rel_dir + "/" and not rel_dir.endswith("/src"):
                # Rust product code lives under crates/<crate>/src.
                if "/src/" not in rel_dir + "/":
                    continue
            for name in files:
                if name.endswith(suffix):
                    path = os.path.join(rel_dir, name)
                    if not is_test_path(path):
                        found.append(path)
    return sorted(found)


def count(root: str) -> dict[str, list[tuple[int, str]]]:
    pattern = literal_pattern(first_party_names(root))
    if pattern is None:
        return {}
    hits: dict[str, list[tuple[int, str]]] = {}
    for path in product_files(root):
        try:
            with open(os.path.join(root, path), encoding="utf-8", errors="replace") as f:
                lines = f.readlines()
        except OSError:
            continue
        in_test_module = False
        for number, raw in enumerate(lines, 1):
            stripped = raw.strip()
            # Rust: an inline `#[cfg(test)] mod tests {` and everything after it is test code.
            if path.endswith(".rs") and stripped.startswith("#[cfg(test)]"):
                in_test_module = True
            if in_test_module:
                continue
            if stripped.startswith(("//", "///", "*", "/*")):
                continue
            for match in pattern.finditer(strip_comment(raw)):
                hits.setdefault(path, []).append((number, match.group(0)))
    return hits


def read_baseline(root: str) -> dict[str, int]:
    rows: dict[str, int] = {}
    try:
        with open(os.path.join(root, BASELINE), encoding="utf-8") as f:
            for line in f:
                if not line.strip() or line.startswith("#"):
                    continue
                path, number, *_ = line.rstrip("\n").split("\t")
                rows[path] = int(number)
    except FileNotFoundError:
        pass
    return rows


def main(argv: list[str]) -> int:
    args = [a for a in argv if not a.startswith("--")]
    root = os.path.abspath(args[0] if args else os.getcwd())
    hits = count(root)
    if "--list" in argv:
        for path, found in sorted(hits.items()):
            for number, literal in found:
                print(f"{path}:{number}: {literal}")
        print(f"check-app-id-special-cases: {sum(len(v) for v in hits.values())} literal(s) in {len(hits)} file(s)")
        return 0
    if "--write-baseline" in argv:
        with open(os.path.join(root, BASELINE), "w", encoding="utf-8") as f:
            f.write(HEADER)
            for path, found in sorted(hits.items()):
                f.write(f"{path}\t{len(found)}\n")
        print(f"check-app-id-special-cases: wrote {BASELINE} ({len(hits)} file(s))")
        return 0
    baseline = read_baseline(root)
    failed = False
    for path, found in sorted(hits.items()):
        allowed = baseline.get(path, 0)
        if len(found) > allowed:
            failed = True
            print(
                f"check-app-id-special-cases: {path} names first-party app ids {len(found)} time(s), baseline {allowed}. "
                "Native code must not branch on an app id (zero first-party privilege, docs/app-store-platonic-ideal.md 5): "
                "read the behavior from the manifest (presentation, implements) instead.",
                file=sys.stderr,
            )
            for number, literal in found:
                print(f"  {path}:{number}: {literal}", file=sys.stderr)
    for path, allowed in sorted(baseline.items()):
        now = len(hits.get(path, []))
        if now < allowed:
            print(f"check-app-id-special-cases: note: {path} has {now} (baseline {allowed}); lower its row with --write-baseline")
    if failed:
        return 1
    total = sum(len(v) for v in hits.values())
    print(f"check-app-id-special-cases: ok ({total} baselined literal(s) in {len(hits)} file(s))")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as error:  # fail open: a bug in the guard must not block every push
        print(f"check-app-id-special-cases: warning: the guard failed ({error}); passing", file=sys.stderr)
        sys.exit(0)
