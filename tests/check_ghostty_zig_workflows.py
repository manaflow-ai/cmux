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


def workflow_failures(workflow_dir: Path) -> list[str]:
    failures: list[str] = []
    paths = sorted((*workflow_dir.glob("*.yml"), *workflow_dir.glob("*.yaml")))
    for path in paths:
        lines = path.read_text().splitlines()
        current_job: str | None = None
        job_start = 0
        for index, line in enumerate(lines):
            match = JOB_HEADER.match(line)
            if match:
                current_job = match.group(1)
                job_start = index
                continue

            stripped = line.strip()
            if stripped.startswith("#") or stripped.startswith(("- \"scripts/", "- 'scripts/")):
                continue
            # A line that is nothing but a quoted script path (optionally with a
            # trailing comma) names the script without executing it, e.g. a JS
            # path array used for change detection inside a github-script step.
            if re.fullmatch(r"""(["'])scripts/[^"']+\1,?""", stripped):
                continue
            if not any(name in line for name in CONSUMER_NAMES):
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
