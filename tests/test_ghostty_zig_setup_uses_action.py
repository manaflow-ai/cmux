#!/usr/bin/env python3
"""The Ghostty Zig is resolved and installed only by .github/actions/setup-ghostty-zig.

Workflows that build cmux-tui or acpmux in tree need the Zig that
ghostty-next's build.zig.zon names. That used to be two inline steps (run
scripts/ghostty-zig-version.sh, then mlugg/setup-zig with its output) copied
into about fifteen jobs, and the copies drifted: some failed on an empty
version and some handed it on to setup-zig, some set GHOSTTY_ZIG_SOURCE and
some leaned on the job's env. Setup order around these steps is what stopped
cloud-chat-proof run 42730570609.

This guard fails when a workflow inlines the pair again:
- a mlugg/setup-zig step whose version is an expression (a resolved Ghostty
  version) instead of a literal pin, or
- a step that writes scripts/ghostty-zig-version.sh's answer to GITHUB_OUTPUT.

A literal pin (cmux-tui-sdks.yml's SDK Zig, 0.15.2) is a different Zig and
stays inline. Reading the version for a comparison (cmux-next-skew-matrix.yml)
writes no step output and is not an install.

Run: python3 tests/test_ghostty_zig_setup_uses_action.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_DIR = ROOT / ".github" / "workflows"
ACTION = ROOT / ".github" / "actions" / "setup-ghostty-zig" / "action.yml"
ACTION_USE = "uses: ./.github/actions/setup-ghostty-zig"

SETUP_ZIG = re.compile(r"^\s*(?:-\s+)?uses:\s*mlugg/setup-zig@")
STEP_START = re.compile(r"^(\s*)-\s")
VERSION_LINE = re.compile(r"^\s*version:\s*(.+?)\s*$")


def step_bounds(lines: list[str], index: int) -> tuple[int, int]:
    """Return [start, end) of the YAML list item (workflow step) holding line `index`."""
    start = index
    while start >= 0 and not STEP_START.match(lines[start]):
        start -= 1
    if start < 0:
        return index, index + 1
    indent = len(STEP_START.match(lines[start]).group(1))
    end = start + 1
    while end < len(lines):
        line = lines[end]
        if line.strip() and not line.lstrip().startswith("#"):
            if len(line) - len(line.lstrip()) <= indent:
                break
        end += 1
    return start, end


def inline_setups(label: str, text: str) -> list[str]:
    lines = text.splitlines()
    problems: set[str] = set()
    for index, line in enumerate(lines):
        if SETUP_ZIG.match(line):
            start, end = step_bounds(lines, index)
            for step_line in lines[start:end]:
                match = VERSION_LINE.match(step_line)
                if match and "${{" in match.group(1):
                    problems.add(
                        f"{label}:{index + 1}: mlugg/setup-zig takes version {match.group(1)}; "
                        f"use {ACTION_USE}"
                    )
        if "ghostty-zig-version.sh" in line and not line.lstrip().startswith("#"):
            start, end = step_bounds(lines, index)
            if any("GITHUB_OUTPUT" in step_line for step_line in lines[start:end]):
                problems.add(
                    f"{label}:{index + 1}: writes the Ghostty Zig version to a step output; "
                    f"use {ACTION_USE}"
                )
    return sorted(problems)


INLINE_SAMPLE = """\
jobs:
  build:
    steps:
      - name: Resolve Ghostty Zig version
        id: ghostty-zig-version
        run: |
          version="$(bash ./scripts/ghostty-zig-version.sh)"
          echo "version=$version" >> "$GITHUB_OUTPUT"
      - name: Install zig
        uses: mlugg/setup-zig@8d6198c65fb0feaa111df26e6b467fea8345e46f # v2.0.5
        with:
          version: ${{ steps.ghostty-zig-version.outputs.version }}
"""

ALLOWED_SAMPLE = """\
jobs:
  build:
    steps:
      - name: Set up Zig for Ghostty
        id: ghostty-zig-version
        uses: ./.github/actions/setup-ghostty-zig
      - name: Set up Zig for SDK conformance
        uses: mlugg/setup-zig@8d6198c65fb0feaa111df26e6b467fea8345e46f # v2.0.5
        with:
          version: 0.15.2
      - name: Compare versions
        run: |
          new="$(bash scripts/ghostty-zig-version.sh "$GITHUB_WORKSPACE")"
          echo "$new"
"""


def self_test() -> list[str]:
    failures = []
    if len(inline_setups("inline-sample", INLINE_SAMPLE)) != 2:
        failures.append("self-test: the inline resolve + setup-zig sample was not caught twice")
    if inline_setups("allowed-sample", ALLOWED_SAMPLE):
        failures.append("self-test: the shared action, a literal pin or a comparison was flagged")
    return failures


def main() -> int:
    failures = self_test()
    if not ACTION.is_file():
        failures.append(f"missing {ACTION.relative_to(ROOT)}")
    users = 0
    for path in sorted(WORKFLOW_DIR.glob("*.y*ml")):
        text = path.read_text(encoding="utf-8")
        failures.extend(inline_setups(str(path.relative_to(ROOT)), text))
        users += text.count(ACTION_USE)
    if users == 0:
        failures.append(f"no workflow uses {ACTION_USE}; the guard checks nothing")
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1
    print(f"ghostty-zig setup: ok ({users} workflow steps use the shared action, no inline copies)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
