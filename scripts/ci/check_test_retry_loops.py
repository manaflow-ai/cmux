#!/usr/bin/env python3
"""Find a test command retried in a loop of its own, instead of through scripts/ci/cargo_test_retry.py.

    check_test_retry_loops.py [--root DIR]     # prints each finding as PATH[#job/step]: line; exits 1 on any

A retry loop is a counted loop (`for x in 1 2 3`, `for x in $(seq ...)`, `for ((...))`) or a `while`/`until` loop
whose body runs a test command (cargo test or nextest, swift test, xcodebuild test, bun test, vitest, pytest,
go test). Such a loop runs a deterministic assertion failure again, at full cost, and fails it again: the cmux_next_
daemon tests paid 133 to 146 s per red run that way (cmuxterm-hq#14034). Run the command through
cargo_test_retry.py, which runs it again only for a fetch fault. A loop over a list of packages or files is not a
retry and is not found.

It reads every `run:` of .github/workflows/*.yml and .github/actions/**/action.yml, and every scripts/**/*.sh and
.github/**/*.sh. Tests: tests/test_ci_cargo_test_retry.py.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
SHARED = "cargo_test_retry.py"

RETRY_VAR = r"\w*(?:attempt|try|tries|retr)\w*"
RETRY_HEADER = re.compile(
    r"^\s*(?:for\s+\w+\s+in\s+(?:\d+\s*)+(?:;|$)|for\s+\w+\s+in\s+(?:\$\(\s*seq\b|\{\d+\.\.)"
    rf"|for\s*\(\(\s*{RETRY_VAR}\b|while\s+(?:true|:)\s*(?:;|$)|while\b[^\n]*\b{RETRY_VAR}\b|until\b)")
# `# test-repeat: <why>` on the loop's line or the line above: a loop that runs the tests several times on
# purpose (a benchmark's runs) and stops at the first failure, which is not a retry.
REPEAT_ESCAPE = re.compile(r"#\s*test-repeat:\s*\S")
QUOTED = re.compile(r"'[^'\n]*'|\"(?:[^\"\\\n]|\\.)*\"")
LOOP_OPEN = re.compile(r"^\s*(?:for|while|until|select)\b")
LOOP_CLOSE = re.compile(r"(?:^|;|&&|\|\|)\s*done\b")
TEST_COMMAND = re.compile(
    r"(?<![\w./-])(?:cargo\s+(?:\+\S+\s+)?(?:test|nextest)\b|swift\s+test\b|xcodebuild\b[^\n]*\btest\b"
    r"|bun\s+(?:run\s+)?test\b|vitest\b|pytest\b|go\s+test\b)")


def code_lines(text: str) -> list[str]:
    """TEXT's lines, continuations joined, comments dropped (to a blank line, so indices stay meaningful)."""
    joined = re.sub(r"\\\n", " ", text)
    return ["" if line.lstrip().startswith("#") else line for line in joined.splitlines()]


def runs_a_test(line: str) -> bool:
    """LINE runs a test command (outside quotes: a message that names one runs nothing)."""
    return bool(TEST_COMMAND.search(QUOTED.sub("''", line)))


def retry_loops(text: str) -> list[str]:
    """The header line of each retry loop in shell TEXT whose body runs a test command not through the shared
    script."""
    raw = re.sub(r"\\\n", " ", text).splitlines()
    lines = code_lines(text)
    found = []
    for start, header in enumerate(lines):
        if not RETRY_HEADER.search(header):
            continue
        if any(REPEAT_ESCAPE.search(line) for line in raw[max(0, start - 1):start + 1]):
            continue
        depth = 0
        body = []
        for line in lines[start:]:
            if LOOP_OPEN.search(line):
                depth += 1
            if LOOP_CLOSE.search(line):
                depth -= 1
            body.append(line)
            if depth <= 0:
                break
        test_lines = [line for line in body if runs_a_test(line)]
        if test_lines and not any(SHARED in line for line in test_lines):
            found.append(header.strip())
    return found


def workflow_runs(path: Path) -> list[tuple[str, str]]:
    """(job/step name, run text) for every step of a workflow or composite action."""
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    steps = [(job, step) for job, body in (data.get("jobs") or {}).items() if isinstance(body, dict)
             for step in (body.get("steps") or []) if isinstance(step, dict)]
    runs = data.get("runs") if isinstance(data.get("runs"), dict) else {}
    steps += [("action", step) for step in (runs.get("steps") or []) if isinstance(step, dict)]
    return [(f"{job}/{step.get('name')}", step["run"]) for job, step in steps if isinstance(step.get("run"), str)]


def findings(root: Path) -> list[str]:
    listed = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "--", ".github", "scripts"],
                            capture_output=True, text=True, check=True).stdout.split("\0")
    out = []
    for relative in sorted(filter(None, listed)):
        path = root / relative
        if not path.is_file():
            continue
        if relative.startswith(".github/") and path.suffix in (".yml", ".yaml") and (
                relative.startswith(".github/workflows/") or path.name in ("action.yml", "action.yaml")):
            for where, run in workflow_runs(path):
                out += [f"{relative}#{where}: {loop}" for loop in retry_loops(run)]
        elif path.suffix == ".sh":
            out += [f"{relative}: {loop}" for loop in retry_loops(path.read_text(encoding="utf-8", errors="replace"))]
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args(argv)
    found = findings(args.root)
    for line in found:
        print(line)
    if found:
        print(f"{len(found)} test command(s) retried in a loop of their own: run each once through "
              f"scripts/ci/{SHARED}, which runs it again only for a fetch fault", file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
