#!/usr/bin/env python3
"""ios-placeholder-bounds, the headless half: every placeholder in the iOS app has a bound.

Leo, 2026-11-24: "holy shit this is a huge problem in ios... wer need to chase all these
placeholders doen and prevent them". A placeholder is a view drawn in place of real content while
the content is on its way: a stand-in thumbnail, an empty bubble, a skeleton row, a spinner where
text goes, a "Connecting" chip, a greyed row. The rule (handbook: ios-placeholder-bounds) is
last-known state or nothing; a placeholder may show only for its first moments.

cmux-next-ios/design/placeholders.json holds:
  patterns     the constructs that draw a placeholder (regexes over Swift source lines);
  placeholders every placeholder the app draws: id, file, what it waits for, bound_ms, and the item
               that removes or keeps it;
  exempt       lines a pattern matches that are not a placeholder (a spinner on a button's own
               action, say), each with its reason;
  max_bound_ms the longest bound any placeholder may have.

It fails when:
  - a pattern matches a line under cmux-next-ios's app sources with no `.placeholderBound(` on that
    line or the next LOOKAHEAD lines, and the line is not exempt;
  - a `.placeholderBound("id", bound)` names an id the inventory does not list, or a bound that
    differs from the inventory's or is past max_bound_ms;
  - the inventory lists an id no source marks (it was removed: drop it from the inventory).

The simulator half (cmux-next-ios/UITests/PlaceholderBoundUITests.swift) drives Leo's flows and
fails on a placeholder still on screen after its bound.

Usage: ios_placeholder_bounds.py [--root DIR] [--json]
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

LOOKAHEAD = 12
SOURCE_DIRS = ("cmux-next-ios/App", "cmux-next-ios/CmuxMobileKit/Sources", "cmux-next-ios/NotificationContent")
INVENTORY = "cmux-next-ios/design/placeholders.json"
MARK = re.compile(r'\.placeholderBound\(\s*"([^"]+)"\s*,\s*\.(milliseconds|seconds)\((\d+(?:\.\d+)?)\)')


def bound_ms(unit: str, value: str) -> int:
    return int(float(value) * (1000 if unit == "seconds" else 1))


def sources(root: Path) -> list[Path]:
    out: list[Path] = []
    for rel in SOURCE_DIRS:
        base = root / rel
        if base.is_dir():
            out.extend(sorted(p for p in base.rglob("*.swift") if "/Tests/" not in p.as_posix()))
    return out


def check(root: Path) -> list[str]:
    inventory_path = root / INVENTORY
    if not inventory_path.is_file():
        return [f"{INVENTORY}: missing; every placeholder the app draws is listed there with its bound"]
    inventory = json.loads(inventory_path.read_text())
    patterns = [(p["name"], re.compile(p["regex"])) for p in inventory["patterns"]]
    listed = {p["id"]: p for p in inventory["placeholders"]}
    exempt = {(e["file"], e["text"].strip()) for e in inventory.get("exempt", [])}
    max_bound = int(inventory["max_bound_ms"])
    problems: list[str] = []
    marked: dict[str, str] = {}

    for entry in inventory["placeholders"]:
        if int(entry["bound_ms"]) > max_bound:
            problems.append(f"{INVENTORY}: {entry['id']} bound {entry['bound_ms']} ms is past max_bound_ms {max_bound}")

    for path in sources(root):
        rel = path.relative_to(root).as_posix()
        lines = path.read_text(errors="replace").splitlines()
        for index, line in enumerate(lines):
            for match in MARK.finditer(line):
                pid, ms = match.group(1), bound_ms(match.group(2), match.group(3))
                where = f"{rel}:{index + 1}"
                marked[pid] = where
                entry = listed.get(pid)
                if entry is None:
                    problems.append(f"{where}: placeholder {pid!r} is not in {INVENTORY}")
                elif int(entry["bound_ms"]) != ms:
                    problems.append(f"{where}: placeholder {pid!r} bound {ms} ms, inventory says {entry['bound_ms']} ms")
                if ms > max_bound:
                    problems.append(f"{where}: placeholder {pid!r} bound {ms} ms is past max_bound_ms {max_bound}")
            stripped = line.strip()
            if stripped.startswith("//") or stripped.startswith("///"):
                continue
            for name, regex in patterns:
                if not regex.search(line):
                    continue
                if (rel, stripped) in exempt:
                    continue
                window = "\n".join(lines[index : index + 1 + LOOKAHEAD])
                if ".placeholderBound(" in window:
                    continue
                problems.append(
                    f"{rel}:{index + 1}: {name} with no .placeholderBound within {LOOKAHEAD} lines: {stripped[:120]}"
                )

    for pid, entry in listed.items():
        if pid not in marked:
            problems.append(f"{INVENTORY}: {pid} ({entry['file']}) is marked nowhere in the sources; drop it if it was removed")
    return problems


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    problems = check(Path(args.root))
    if args.json:
        print(json.dumps({"problems": problems}, indent=2))
    else:
        for problem in problems:
            print(f"::error::ios-placeholder-bounds: {problem}")
        print(f"ios-placeholder-bounds: {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
