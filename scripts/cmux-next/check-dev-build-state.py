#!/usr/bin/env python3
"""Dev build state paths ratchet (AGENTS.md "Dev builds are separate"; Swift `BuildStatePaths`).

The user, 2026-11-16: "for dev builds we must make sure that all such values and configurations have a dev build
isolation that prevents each dev build from deriving state from each other even from prod."

A path every build resolves the same way (`~/.config/cmux/...`, a fixed folder in Application Support or Caches, a
fixed UserDefaults suite or Keychain service, `~/.cmux/...`) is shared by NIGHTLY, stable and every dev build. Ask
`BuildStatePaths` (or the build's bundle id, `BuildIdentity`) for the path instead, and pass a Rust child its file
through `BuildStatePaths.environment`.

Usage: check-dev-build-state.py ROOT [--list] [--baseline FILE] [--update-baseline]

Reads Swift under Packages/macOS/CmuxNext/Sources and Rust under cmux-tui/crates (no test folders, no *Tests.swift
or *tests.rs; lines that start with a comment do not count) in the tree at ROOT. Each file's matching lines are
counted against its row in ROOT's scripts/cmux-next/dev-build-state-baseline.tsv (else the one beside this script):
`path<TAB>count<TAB>reason`, the reviewed sites (per bundle id, a resolver, an input of this Mac, a remote
machine's path). A file with more matches than its row prints one `<path>:<line>: <finding>` per match and the
check exits 1. Only rises are judged: the pre-push gate's trees hold the changed files only, so a missing file
says nothing. `--list` prints every match; `--update-baseline` rewrites the counts, keeping the reasons.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BASELINE = HERE / "dev-build-state-baseline.tsv"
SCOPES = (("Packages/macOS/CmuxNext/Sources", ".swift"), ("cmux-tui/crates", ".rs"))
PRUNE = {"target", ".build", "tests", "Tests", "node_modules", "fixtures", "benches"}
COMMENT = re.compile(r"^\s*(//|/\*|\*(\s|$)|#)")

RULES: tuple[tuple[str, str, re.Pattern[str]], ...] = (
    ("both", "a ~/.config/cmux path every build shares: ask BuildStatePaths", re.compile(r"\.config/cmux\b")),
    ("swift", "an Application Support or Caches folder outside the build's bundle id: ask BuildStatePaths or name the bundle id",
     re.compile(r"urls\(for:\s*\.(applicationSupportDirectory|cachesDirectory)\b")),
    ("swift", "a fixed UserDefaults suite: another build's preferences", re.compile(r"UserDefaults\(suiteName:\s*\"")),
    ("swift", "a fixed Keychain service: name it after the bundle id",
     re.compile(r"kSecAttrService as String:\s*\"|static let service\s*=\s*\"")),
    ("swift", "a ~/.cmux path every build shares: ask BuildIdentity or BuildStatePaths",
     re.compile(r"homeDirectoryForCurrentUser\s*\.\s*appending(PathComponent)?\(\s*(path:\s*)?\"\.cmux")),
)


def files(root: Path) -> list[str]:
    out: list[str] = []
    for scope, ext in SCOPES:
        base = root / scope
        if not base.is_dir():
            continue
        for path in base.rglob(f"*{ext}"):
            rel = path.relative_to(root)
            if any(part in PRUNE for part in rel.parts[:-1]):
                continue
            if path.name.endswith("Tests.swift") or path.name.endswith("tests.rs"):
                continue
            out.append(rel.as_posix())
    return sorted(out)


def matches(root: Path, rel: str) -> list[tuple[int, str, str]]:
    lang = "swift" if rel.endswith(".swift") else "rust"
    found: list[tuple[int, str, str]] = []
    try:
        text = (root / rel).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return found
    for number, line in enumerate(text.splitlines(), 1):
        if COMMENT.match(line):
            continue
        for scope, finding, pattern in RULES:
            if scope in ("both", lang) and pattern.search(line):
                found.append((number, finding, line.strip()))
                break
    return found


def read_baseline(path: Path) -> dict[str, tuple[int, str]]:
    rows: dict[str, tuple[int, str]] = {}
    if not path.is_file():
        return rows
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw.strip() or raw.startswith("#"):
            continue
        parts = raw.split("\t")
        if len(parts) != 3 or not parts[1].isdigit() or not parts[2].strip():
            raise SystemExit(f"check-dev-build-state: bad baseline row: {raw}")
        if parts[0] in rows:
            raise SystemExit(f"check-dev-build-state: duplicate baseline row: {parts[0]}")
        rows[parts[0]] = (int(parts[1]), parts[2])
    return rows


def main(argv: list[str]) -> int:
    args = [a for a in argv if not a.startswith("--")]
    flags = {a for a in argv if a.startswith("--")}
    baseline = BASELINE
    if "--baseline" in argv:
        baseline = Path(argv[argv.index("--baseline") + 1])
        args = [a for a in args if a != str(baseline)]
    root = Path(args[0]) if args else Path.cwd()
    if "--baseline" not in argv and (root / "scripts/cmux-next" / BASELINE.name).is_file():
        baseline = root / "scripts/cmux-next" / BASELINE.name  # the tree's own (each side of the gate)
    rows = read_baseline(baseline)
    found = {rel: hits for rel in files(root) if (hits := matches(root, rel))}
    if "--list" in flags:
        for rel, hits in found.items():
            for number, finding, line in hits:
                print(f"{rel}:{number}: {line}")
        return 0
    if "--update-baseline" in flags:
        lines = ["# path\tcount\treason (check-dev-build-state.py: reviewed sites; a rise fails the pre-push gate)"]
        for rel, hits in found.items():
            reason = rows.get(rel, (0, "TODO: review"))[1]
            lines.append(f"{rel}\t{len(hits)}\t{reason}")
        baseline.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return 0
    status = 0
    for rel, hits in found.items():
        limit = rows.get(rel, (0, ""))[0]
        if len(hits) > limit:
            status = 1
            for number, finding, line in hits:
                print(f"{rel}:{number}: {finding} ({len(hits)} in the file, {limit} reviewed in "
                      f"scripts/cmux-next/dev-build-state-baseline.tsv): {line[:160]}")
    if status:
        print("check-dev-build-state: a dev build must not share this path with NIGHTLY, stable or another tag "
              "(AGENTS.md \"Dev builds are separate\"); if it is safe (per bundle id, an input of this Mac, a remote "
              "machine's file), raise the file's row with the reason.")
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
