#!/usr/bin/env python3
"""Write and check every literal `retention-days: N` from .github/artifact-retention.json.

GitHub Actions reads a step's retention-days from the workflow file and cannot read a repository
file, so the number has to stay in the YAML. What keeps it one fact is that the number is not
typed by hand: each literal names its class on the same line, and this script writes the class's
days from .github/artifact-retention.json.

    retention-days: 3  # retention-class: report

    python3 scripts/ci/artifact_retention.py          # check: exit 1 on a finding
    python3 scripts/ci/artifact_retention.py --fix    # write each value from its class; name a
                                                      # missing class from today's value
    python3 scripts/ci/artifact_retention.py --count  # literals, and how many name a class

A policy change is one number in the JSON plus `--fix` (cmux#43466 hand-edited 60 steps in 16
files). An expression (`${{ inputs.retention_days }}`, a fromJSON conditional) is not a literal; the
bounds in tests/test_ci_upload_artifact_retention.py cover those.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
POLICY = ".github/artifact-retention.json"
LITERAL = re.compile(r"(?P<key>\bretention-days:[ \t]*)(?P<days>\d+)\b")
MARKER = re.compile(r"#[^\n]*?\bretention-class:[ \t]*(?P<cls>[A-Za-z0-9_-]+)")


def load_classes(root: Path = ROOT) -> dict[str, int]:
    classes = json.loads((root / POLICY).read_text())["classes"]
    return {name: int(entry["days"]) for name, entry in classes.items()}


def workflow_files(root: Path = ROOT) -> list[Path]:
    files: list[Path] = []
    for pattern in ("*.yml", "*.yaml"):
        files += (root / ".github/workflows").glob(pattern)
    for pattern in ("action.yml", "action.yaml"):
        files += (root / ".github/actions").rglob(pattern)
    return sorted(files)


def literal_lines(path: Path):
    """(line number, line, literal match) for each non-comment line with a literal retention-days."""
    for number, line in enumerate(path.read_text().splitlines(keepends=True), 1):
        if line.lstrip().startswith("#"):
            continue
        match = LITERAL.search(line)
        # A literal inside a trailing comment ("... (retention-days: 2).") is prose, not a value.
        if match and "#" not in line[: match.start()]:
            yield number, line, match


def findings(root: Path = ROOT) -> list[str]:
    classes = load_classes(root)
    out: list[str] = []
    for path in workflow_files(root):
        rel = path.relative_to(root).as_posix()
        for number, line, match in literal_lines(path):
            days = int(match.group("days"))
            marker = MARKER.search(line, match.end())
            if not marker:
                out.append(f"{rel}:{number}: retention-days: {days} names no class; add "
                           f"`# retention-class: <{'|'.join(classes)}>` and run "
                           f"`python3 scripts/ci/artifact_retention.py --fix` ({POLICY} holds the days)")
                continue
            cls = marker.group("cls")
            if cls not in classes:
                out.append(f"{rel}:{number}: retention-class {cls!r} is not a class in {POLICY} "
                           f"({', '.join(classes)})")
            elif classes[cls] != days:
                out.append(f"{rel}:{number}: retention-days: {days} is hand-typed; class {cls} keeps "
                           f"{classes[cls]} days in {POLICY}; run "
                           f"`python3 scripts/ci/artifact_retention.py --fix`")
    return out


def fixed_line(line: str, match: re.Match, classes: dict[str, int], by_days: dict[int, str]) -> str:
    marker = MARKER.search(line, match.end())
    days = int(match.group("days"))
    if marker:
        cls = marker.group("cls")
        if cls not in classes:
            return line
    else:
        cls = by_days.get(days)
        if cls is None:
            return line
    line = line[: match.start("days")] + str(classes[cls]) + line[match.end("days"):]
    if marker:
        return line
    body = line.rstrip("\r\n")
    ending = line[len(body):]
    # Put the marker in the line's own comment if it has one, else start a comment.
    comment = body.find(" #", match.end())
    if comment >= 0:
        return body[: comment + 2] + f" retention-class: {cls};" + body[comment + 2:] + ending
    return body + f"  # retention-class: {cls}" + ending


def fix(root: Path = ROOT) -> int:
    classes = load_classes(root)
    by_days = {days: name for name, days in classes.items()}
    changed = 0
    for path in workflow_files(root):
        text = path.read_text()
        lines = text.splitlines(keepends=True)
        for number, line, match in list(literal_lines(path)):
            new = fixed_line(line, match, classes, by_days)
            if new != line:
                lines[number - 1] = new
                changed += 1
        new_text = "".join(lines)
        if new_text != text:
            path.write_text(new_text)
    return changed


def count(root: Path = ROOT) -> tuple[int, int]:
    total = named = 0
    for path in workflow_files(root):
        for _, line, match in literal_lines(path):
            total += 1
            named += bool(MARKER.search(line, match.end()))
    return total, named


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--fix", action="store_true", help="write each value from its class")
    parser.add_argument("--count", action="store_true", help="print literals and how many name a class")
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args(argv)
    if args.count:
        total, named = count(args.root)
        print(f"{total} literal retention-days lines, {named} name a class, {total - named} hand-typed")
        return 0
    if args.fix:
        print(f"artifact_retention: rewrote {fix(args.root)} lines")
    problems = findings(args.root)
    for problem in problems:
        print(problem, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
