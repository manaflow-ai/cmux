#!/usr/bin/env python3
"""Summarize Swift driver's opt-in incremental-compilation diagnostics."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess


ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
SWIFT_PATH_RE = re.compile(r"(?P<path>[A-Za-z0-9_./+@-]+\.swift)\b")
WHITESPACE_RE = re.compile(r"\s+")

CASCADE_MARKER = "because of dependencies discovered later"
SCHEDULED_MARKER = "Scheduling invalidated"
DISABLED_MARKER = "Incremental compilation has been disabled"
FAILED_DEPENDENCY_MARKER = "Failed to read some dependencies source; compiling everything"


def git_output(*args: str) -> str | None:
    try:
        return subprocess.check_output(
            ["git", *args],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (OSError, subprocess.SubprocessError):
        return None


def swift_file_from_line(line: str) -> str | None:
    matches = list(SWIFT_PATH_RE.finditer(line))
    if not matches:
        return None
    return matches[-1].group("path")


def normalize_line(line: str) -> str:
    return WHITESPACE_RE.sub(" ", ANSI_RE.sub("", line).strip())


def parse_log(path: Path) -> dict[str, object]:
    initial: set[str] = set()
    cascading: set[str] = set()
    scheduled_invalidated: set[str] = set()
    disabled_reasons: list[str] = []
    dependency_failures: list[str] = []
    evidence_lines = 0

    with path.open("r", encoding="utf-8", errors="replace") as stream:
        for raw in stream:
            line = normalize_line(raw)
            if not line:
                continue

            matched = False
            file = swift_file_from_line(line)

            if line.startswith("Queuing ") and "(initial)" in line and file:
                initial.add(file)
                matched = True

            if CASCADE_MARKER in line:
                if file:
                    cascading.add(file)
                matched = True

            if SCHEDULED_MARKER in line:
                if file:
                    scheduled_invalidated.add(file)
                matched = True

            if DISABLED_MARKER in line:
                if line not in disabled_reasons:
                    disabled_reasons.append(line)
                matched = True

            if FAILED_DEPENDENCY_MARKER in line:
                if line not in dependency_failures:
                    dependency_failures.append(line)
                matched = True

            if matched:
                evidence_lines += 1

    return {
        "schema_version": 1,
        "source": {
            "revision": os.environ.get("GITHUB_SHA") or git_output("rev-parse", "HEAD"),
            "tree": git_output("rev-parse", "HEAD^{tree}"),
        },
        "log": {
            "path": str(path),
            "bytes": path.stat().st_size,
        },
        "initial_files": sorted(initial),
        "dependency_cascade_files": sorted(cascading),
        "scheduled_invalidated_files": sorted(scheduled_invalidated),
        "incremental_disabled_reasons": disabled_reasons,
        "dependency_read_failures": dependency_failures,
        "counts": {
            "initial_files": len(initial),
            "dependency_cascade_files": len(cascading),
            "scheduled_invalidated_files": len(scheduled_invalidated),
            "incremental_disabled_reasons": len(disabled_reasons),
            "dependency_read_failures": len(dependency_failures),
            "diagnostic_evidence_lines": evidence_lines,
        },
    }


def print_summary(receipt: dict[str, object]) -> None:
    counts = dict(receipt["counts"])
    print("Swift incremental diagnostics")
    print(f"  initial files: {counts['initial_files']}")
    print(f"  dependency cascade files: {counts['dependency_cascade_files']}")
    print(f"  scheduled invalidated files: {counts['scheduled_invalidated_files']}")
    print(f"  incremental disabled reasons: {counts['incremental_disabled_reasons']}")
    print(f"  dependency read failures: {counts['dependency_read_failures']}")

    cascades = list(receipt["dependency_cascade_files"])
    if cascades:
        print("  cascade sample:")
        for file in cascades[:20]:
            print(f"    {file}")

    reasons = list(receipt["incremental_disabled_reasons"])
    if reasons:
        print("  disabled:")
        for reason in reasons:
            print(f"    {reason}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    receipt = parse_log(args.log)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(receipt, sort_keys=True, indent=2) + "\n",
        encoding="utf-8",
    )
    print_summary(receipt)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
