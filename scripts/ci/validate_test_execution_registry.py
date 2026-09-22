#!/usr/bin/env python3
"""Validate that every Python regression has a declared, live execution path."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

# Tests load this file through importlib, which does not add its directory
# to sys.path the way running it as a script does.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_execution_registry import load_registry  # noqa: E402


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "tests" / "test-execution.toml"
WORKFLOWS = ROOT / ".github" / "workflows"
CI_GUARDS = WORKFLOWS / "ci-guards.yml"
RUNNER_RE = re.compile(r"scripts/ci/run_python_test_lane\.py\s+--lane\s+([A-Za-z0-9_.-]+)")
TEST_PATH_RE = re.compile(r"^tests/test_[A-Za-z0-9_.-]+\.py$")
ALLOWED_FIELDS = {"path", "lane", "requirements", "reason"}
INVENTORY_LANES = {"legacy", "manual"}
SUPPORTED_REQUIREMENTS = {"cmux-cli", "fish"}


def runner_lanes_from_workflow_text(text: str) -> set[str]:
    lanes: set[str] = set()
    for line in text.splitlines():
        executable = line.split("#", 1)[0]
        lanes.update(RUNNER_RE.findall(executable))
    return lanes


def runner_lanes() -> set[str]:
    lanes: set[str] = set()
    for workflow in sorted(WORKFLOWS.glob("*.y*ml")):
        lanes.update(runner_lanes_from_workflow_text(workflow.read_text(encoding="utf-8")))
    return lanes


def newly_added_tests(base_sha: str) -> set[str]:
    output = subprocess.check_output(
        ["git", "diff", "--name-only", "--diff-filter=A", base_sha, "HEAD", "--", "tests"],
        cwd=ROOT,
        text=True,
    )
    return {line.strip() for line in output.splitlines() if TEST_PATH_RE.fullmatch(line.strip())}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-sha", default="")
    args = parser.parse_args(argv)

    errors: list[str] = []
    try:
        entries = load_registry(MANIFEST)
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1

    discovered = {
        path.relative_to(ROOT).as_posix()
        for path in (ROOT / "tests").glob("test_*.py")
        if path.is_file()
    }

    paths: list[str] = []
    by_path: dict[str, dict[str, object]] = {}
    for index, entry in enumerate(entries, start=1):
        unknown = sorted(set(entry) - ALLOWED_FIELDS)
        if unknown:
            errors.append(f"entry {index}: unknown fields: {', '.join(unknown)}")

        path = entry.get("path")
        lane = entry.get("lane")
        if not isinstance(path, str) or not TEST_PATH_RE.fullmatch(path):
            errors.append(f"entry {index}: invalid test path {path!r}")
            continue
        if not isinstance(lane, str) or not lane:
            errors.append(f"{path}: lane must be a non-empty string")
            continue

        requirements = entry.get("requirements", [])
        if not isinstance(requirements, list) or not all(isinstance(value, str) for value in requirements):
            errors.append(f"{path}: requirements must be a list of strings")
        else:
            unknown_requirements = sorted(set(requirements) - SUPPORTED_REQUIREMENTS)
            if unknown_requirements:
                errors.append(f"{path}: unsupported requirements: {', '.join(unknown_requirements)}")

        if lane == "manual" and not isinstance(entry.get("reason"), str):
            errors.append(f"{path}: manual tests require a reason")
        if lane != "manual" and "reason" in entry:
            errors.append(f"{path}: reason is only valid for manual tests")

        paths.append(path)
        by_path[path] = entry

    for path, count in Counter(paths).items():
        if count != 1:
            errors.append(f"{path}: registered more than once")

    for path in sorted(discovered - set(paths)):
        errors.append(f"{path}: test exists but has no execution registry entry")
    for path in sorted(set(paths) - discovered):
        errors.append(f"{path}: registry entry points to a missing test")

    live_runner_lanes = runner_lanes()
    guard_text = CI_GUARDS.read_text(encoding="utf-8")
    for path, entry in sorted(by_path.items()):
        lane = entry.get("lane")
        if lane in INVENTORY_LANES:
            continue
        if lane == "linux-guard":
            if path not in guard_text:
                errors.append(f"{path}: linux-guard lane is not referenced by ci-guards.yml")
        elif lane not in live_runner_lanes:
            errors.append(f"{path}: lane {lane!r} has no workflow invocation")

    if args.base_sha:
        try:
            added = newly_added_tests(args.base_sha)
        except subprocess.CalledProcessError as error:
            errors.append(f"could not compare new tests against {args.base_sha}: {error}")
        else:
            for path in sorted(added):
                entry = by_path.get(path)
                if entry and entry.get("lane") == "legacy":
                    errors.append(f"{path}: newly added tests may not enter the legacy migration lane")

    if errors:
        print("Python test execution registry validation failed:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1

    lane_counts = Counter(str(entry["lane"]) for entry in entries if "lane" in entry)
    summary = ", ".join(f"{lane}={count}" for lane, count in sorted(lane_counts.items()))
    print(f"Python test execution registry valid: {len(discovered)} tests ({summary})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
