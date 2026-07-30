#!/usr/bin/env python3
"""Require Ghostty submodule initialization before every Zig manifest consumer."""

from __future__ import annotations

import re
import sys
from pathlib import Path


CONSUMER_NAMES = (
    "scripts/install-zig-ci.sh",
    "scripts/build-ghostty-cli-helper.sh",
    "scripts/ghostty-zig-version.sh",
)
JOB_HEADER = re.compile(r"^  ([A-Za-z0-9_-]+):\s*$")
RUN_HEADER = re.compile(r"^(?P<indent>\s*)(?:-\s+)?run:\s*(?P<command>.*)$")
BLOCK_SCALAR = re.compile(r"^[>|][+-]?(?:\s+#.*)?$")


def consumer_run_lines(lines: list[str]) -> set[int]:
    consumers: set[int] = set()
    run_block_indent: int | None = None

    for index, line in enumerate(lines):
        stripped = line.strip()
        if run_block_indent is not None:
            line_indent = len(line) - len(line.lstrip())
            if stripped and line_indent <= run_block_indent:
                run_block_indent = None
            else:
                if not stripped.startswith("#") and any(
                    name in line for name in CONSUMER_NAMES
                ):
                    consumers.add(index)
                continue

        match = RUN_HEADER.match(line)
        if not match:
            continue

        command = match.group("command").strip()
        if BLOCK_SCALAR.fullmatch(command):
            run_block_indent = len(match.group("indent"))
        elif not command.startswith("#") and any(
            name in command for name in CONSUMER_NAMES
        ):
            consumers.add(index)

    return consumers


def workflow_failures(workflow_dir: Path) -> list[str]:
    failures: list[str] = []
    paths = sorted((*workflow_dir.glob("*.yml"), *workflow_dir.glob("*.yaml")))
    for path in paths:
        lines = path.read_text().splitlines()
        consumer_lines = consumer_run_lines(lines)
        current_job: str | None = None
        job_start = 0
        for index, line in enumerate(lines):
            match = JOB_HEADER.match(line)
            if match:
                current_job = match.group(1)
                job_start = index
                continue

            if index not in consumer_lines:
                continue
            if current_job is None:
                failures.append(f"{path.name}:{index + 1}: consumer is outside a job")
                continue

            preceding = "\n".join(lines[job_start:index])
            recursive_checkout = re.search(r"submodules:\s*recursive", preceding)
            explicit_init = re.search(
                r"git\s+submodule\s+update[^\n]*\bghostty\b",
                preceding,
            )
            if not recursive_checkout and not explicit_init:
                failures.append(
                    f"{path.name}:{index + 1}: {current_job} reads Ghostty before submodule init"
                )
    return failures


def main() -> int:
    workflow_dir = Path(sys.argv[1])
    failures = workflow_failures(workflow_dir)
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
