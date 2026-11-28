#!/usr/bin/env python3
"""Refuses to publish a stable or RC release whose What's New is missing, empty or invalid.

    release_whats_new_gate.py [--version V] [--root DIR]

The stable What's New page (cmux.com/docs/changelog/<version>, rendered by
web/app/lib/changelog.ts from CHANGELOG.md) and the release's notes come from the
version's CHANGELOG.md section. This gate fails when that section:
  - is missing, appears twice, or has a heading the page cannot parse
    (`## [X.Y.Z] - YYYY-MM-DD`)
  - lists no user-facing item (thanks-only sections do not count), unless it says
    `_No user-facing changes._` on purpose
  - has a `###` category with no items, or placeholder text (TODO, TBD, FIXME,
    XXX, X.Y.Z, lorem ipsum)
When the checkout also has the structured What's New validator
(scripts/whats-new/validate.py), the gate runs it for the version too, with the
same arguments as the release skill's gate (--root whats-new --require-version),
so whats-new/<version>.json becomes required the moment the validator lands.

The version defaults to the tag (GITHUB_REF_NAME when it is a v* tag), then the
app's MARKETING_VERSION. An RC (X.Y.Z-rc.N) is checked against X.Y.Z, the notes
it ships; nightlies are skipped (their digest is generated).

CMUX_WHATS_NEW_GATE_MODE: enforce (default; tag pushes and the pre-tag guard)
fails on a problem; warn (a workflow_dispatch dry run, which publishes nothing
and often runs before the changelog is written) prints it and exits 0.
Exit 0 = may publish; 1 = refused, one line per problem.
"""
from __future__ import annotations

import argparse
import datetime
import os
import re
import subprocess
import sys
from pathlib import Path

VERSION = re.compile(r"^(\d+\.\d+\.\d+)(?:-(rc|nightly)\.\d+)?$")
RELEASE_HEADING = re.compile(r"^## \[(.+?)\] - (.+)$")
PLACEHOLDER = re.compile(r"\b(?:TODO|TBD|FIXME|XXX|X\.Y\.Z)\b|\b(?i:lorem ipsum)\b")


def marketing_version(root: Path) -> str | None:
    project = root / "cmux.xcodeproj" / "project.pbxproj"
    if not project.is_file():
        return None
    match = re.search(r"MARKETING_VERSION = ([^;]+);", project.read_text(encoding="utf-8"))
    return match.group(1).strip() if match else None


def resolve_version(explicit: str | None, root: Path) -> str | None:
    if explicit:
        return explicit
    ref = os.environ.get("GITHUB_REF_NAME", "")
    if os.environ.get("GITHUB_REF_TYPE", "tag") == "tag" and ref.startswith("v"):
        return ref
    return marketing_version(root)


def changelog_problems(markdown: str, version: str) -> list[str]:
    """Problems with the CHANGELOG.md section for one version, parsed the way the page parses it."""
    problems: list[str] = []
    lines = markdown.split("\n")
    starts = []
    for index, line in enumerate(lines):
        match = RELEASE_HEADING.match(line)
        if match and match.group(1) == version:
            starts.append((index, match.group(2).strip()))
        elif re.match(rf"^##\s+\[?v?{re.escape(version)}\]?(\s|$)", line):
            problems.append(f"CHANGELOG.md line {index + 1}: '{line}' is not the page's heading form "
                            f"'## [{version}] - YYYY-MM-DD'")
    if not starts:
        problems.append(f"CHANGELOG.md has no '## [{version}] - YYYY-MM-DD' section: the What's New "
                        "page for this release would be missing")
        return problems
    if len(starts) > 1:
        problems.append(f"CHANGELOG.md has {len(starts)} sections for {version}")
    start, date = starts[0]
    try:
        datetime.date.fromisoformat(date)
    except ValueError:
        problems.append(f"CHANGELOG.md line {start + 1}: date '{date}' is not YYYY-MM-DD")

    body: list[tuple[int, str]] = []
    for index in range(start + 1, len(lines)):
        if lines[index].startswith("## "):
            break
        body.append((index, lines[index]))

    heading, heading_line, heading_items = None, 0, 0
    user_items = 0
    # A release the changelog step confirmed has nothing user-facing says so explicitly (0.56.0).
    declared_none = any(re.fullmatch(r"[_*]*No user-facing changes\.?[_*]*", line.strip(), re.I)
                        for _, line in body)

    def close_heading() -> None:
        if heading is not None and heading_items == 0:
            problems.append(f"CHANGELOG.md line {heading_line + 1}: '### {heading}' has no items")

    for index, line in body:
        section = re.match(r"^### (.+)$", line)
        if section:
            close_heading()
            heading, heading_line, heading_items = section.group(1).strip(), index, 0
            continue
        item = re.match(r"^- (.+)$", line)
        if item:
            heading_items += 1
            if not (heading or "").lower().startswith("thanks"):
                user_items += 1
        if line.strip() and PLACEHOLDER.search(re.sub(r"`[^`]*`|\([^)]*\)", "", line)):
            problems.append(f"CHANGELOG.md line {index + 1}: placeholder text in '{line.strip()[:80]}'")
    close_heading()
    if user_items == 0 and not declared_none:
        problems.append(f"CHANGELOG.md section for {version} lists no user-facing change: the What's "
                        "New page would be empty")
    return problems


def structured_problems(root: Path, version: str) -> list[str]:
    validator = root / "scripts" / "whats-new" / "validate.py"
    if not validator.is_file():
        return []
    result = subprocess.run(
        [sys.executable, str(validator), "--root", str(root / "whats-new"), "--require-version", version],
        capture_output=True, text=True)
    if result.returncode == 0:
        return []
    detail = (result.stdout + result.stderr).strip().splitlines() or [f"exit {result.returncode}"]
    return [f"whats-new/{version}.json: {line}" for line in detail]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--version")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    mode = os.environ.get("CMUX_WHATS_NEW_GATE_MODE", "enforce")
    if mode not in ("enforce", "warn"):
        print(f"FAIL: CMUX_WHATS_NEW_GATE_MODE must be 'enforce' or 'warn' (got '{mode}')", file=sys.stderr)
        return 1

    raw = resolve_version(args.version, args.root)
    match = VERSION.match((raw or "").removeprefix("v"))
    if not match:
        problems = [f"cannot tell which version is being released (got '{raw}')"]
    elif match.group(2) == "nightly":
        print(f"whats-new gate: {raw} is a nightly; its digest is generated, nothing to check")
        return 0
    else:
        version = match.group(1)
        changelog = args.root / "CHANGELOG.md"
        if changelog.is_file():
            problems = changelog_problems(changelog.read_text(encoding="utf-8"), version)
        else:
            problems = ["CHANGELOG.md is missing"]
        problems += structured_problems(args.root, version)

    if not problems:
        print(f"whats-new gate: ok for {raw}")
        return 0
    label = "REFUSED" if mode == "enforce" else "WARNING (dry run, not enforced)"
    print(f"whats-new gate: {label} for {raw}:", file=sys.stderr)
    for problem in problems:
        print(f"  - {problem}", file=sys.stderr)
    if mode == "enforce":
        print("  Write the release's CHANGELOG.md section (the release skill's changelog step) and merge "
              "it before tagging.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
