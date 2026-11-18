#!/usr/bin/env python3
"""LAUNCH-STAGES guard (docs/design/launch-shell-first.md, piece 5).

Nothing a person is not looking at runs before the frame they are looking at.
The launch stage plan lives in two places: the Rust crate owns the stage-0
allowlist (`STAGE_ZERO_ALLOWLIST` in cmux-tui/crates/cmux-launch-record) and
the app declares its launch work in `LaunchStageRegistry` (CmuxNextControl).
The Swift registry test only runs on a macOS runner and checks the registry
against its own copy of the allowlist, so a copy that drifts from Rust's, or a
new stage-0 task, would pass it. This guard reads both files as text on Linux
and fails when:
  - the Swift `stageZeroAllowlist` differs from the Rust `STAGE_ZERO_ALLOWLIST`;
  - a registry task is declared `.shell` but its name is not on the allowlist;
  - a registry task name is declared twice;
  - either file is missing or neither list can be read (the guard would
    otherwise pass on nothing).

Its rules are tested by scripts/cmux-next/tests/check-launch-stages.test.sh.
Usage: check-launch-stages.py [REPO_ROOT]
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

RUST = "cmux-tui/crates/cmux-launch-record/src/lib.rs"
SWIFT = "Packages/macOS/CmuxNext/Sources/CmuxNextControl/LaunchStageRegistry.swift"

RUST_LIST = re.compile(r"STAGE_ZERO_ALLOWLIST\s*:\s*&\[&str\]\s*=\s*&\[(.*?)\]", re.S)
SWIFT_LIST = re.compile(r"stageZeroAllowlist\s*:\s*Set<String>\s*=\s*\[(.*?)\]", re.S)
SWIFT_TASKS = re.compile(r"static\s+let\s+finishLaunching\s*:\s*\[LaunchTask\]\s*=\s*\[(.*?)\n\s*\]", re.S)
SWIFT_TASK = re.compile(r'\.init\(\s*"([^"]+)"\s*,\s*\.(\w+)\s*\)')
STRING = re.compile(r'"([^"]+)"')


def strip_line_comments(text: str) -> str:
    return re.sub(r"//[^\n]*", "", text)


def check(root: Path) -> list[str]:
    problems: list[str] = []
    try:
        rust = strip_line_comments((root / RUST).read_text())
        swift = strip_line_comments((root / SWIFT).read_text())
    except OSError as error:
        return [f"cannot read {error.filename}: {error.strerror}"]

    rust_match, swift_match, tasks_match = RUST_LIST.search(rust), SWIFT_LIST.search(swift), SWIFT_TASKS.search(swift)
    if not rust_match:
        problems.append(f"{RUST}: STAGE_ZERO_ALLOWLIST not found")
    if not swift_match:
        problems.append(f"{SWIFT}: stageZeroAllowlist not found")
    if not tasks_match:
        problems.append(f"{SWIFT}: finishLaunching task list not found")
    if problems:
        return problems

    rust_names = STRING.findall(rust_match.group(1))
    swift_names = STRING.findall(swift_match.group(1))
    if not rust_names:
        problems.append(f"{RUST}: STAGE_ZERO_ALLOWLIST is empty")
    if set(rust_names) != set(swift_names):
        only_rust = sorted(set(rust_names) - set(swift_names))
        only_swift = sorted(set(swift_names) - set(rust_names))
        problems.append(
            f"{SWIFT}: stageZeroAllowlist differs from Rust's STAGE_ZERO_ALLOWLIST"
            f" (only in Rust: {only_rust or 'none'}; only in Swift: {only_swift or 'none'})"
        )

    tasks = SWIFT_TASK.findall(tasks_match.group(1))
    if not tasks:
        problems.append(f"{SWIFT}: finishLaunching declares no tasks")
    seen: set[str] = set()
    for name, stage in tasks:
        if name in seen:
            problems.append(f"{SWIFT}: task {name!r} is declared twice")
        seen.add(name)
        if stage not in ("shell", "visible", "rest"):
            problems.append(f"{SWIFT}: task {name!r} has unknown stage .{stage}")
        elif stage == "shell" and name not in rust_names:
            problems.append(
                f"{SWIFT}: task {name!r} is stage 0 (.shell) but not on STAGE_ZERO_ALLOWLIST;"
                " defer it to .visible or .rest (docs/design/launch-shell-first.md)"
            )
    return problems


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[2]
    problems = check(root)
    for problem in problems:
        print(f"LAUNCH-STAGES: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
