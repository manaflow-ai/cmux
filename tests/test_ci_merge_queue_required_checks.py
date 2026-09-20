#!/usr/bin/env python3
"""Every required check on main must also report for merge queue runs.

GitHub waits for each required check on the merge group commit. A check whose
workflow does not trigger on merge_group never reports there, and the queue
entry waits until it times out.
"""

from __future__ import annotations

import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
MERGE_GROUP_BRIDGE = WORKFLOWS / "merge-group-policy-checks.yml"

BRIDGE_RUNS = {
    "cla-assistant": (
        'set -euo pipefail\n'
        '[[ "$EVENT_NAME" == merge_group ]]\n'
        '[[ "$GROUP_SHA" =~ ^[0-9a-f]{40}$ ]]\n'
        'echo "CLA Assistant was satisfied on the pull-request heads; reporting the merge-group context."\n'
    ),
    "cla-policy-guard": (
        'set -euo pipefail\n'
        '[[ "$EVENT_NAME" == merge_group ]]\n'
        '[[ "$GROUP_SHA" =~ ^[0-9a-f]{40}$ ]]\n'
        'echo "CLA policy was evaluated on the pull-request heads; reporting the merge-group context."\n'
    ),
}

# The required status checks on main that report for merge queue runs.
REQUIRED_CHECKS = (
    "CLA Assistant",
    "CLA policy guard",
    "ci-status",
    "Web complexity",
    "web-validation",
)


def triggers(document: dict) -> set[str]:
    # PyYAML reads the bare key `on` as boolean True.
    on = document.get("on", document.get(True))
    if isinstance(on, str):
        return {on}
    if isinstance(on, list):
        return set(on)
    if isinstance(on, dict):
        return set(on)
    return set()


def merge_group_check_names() -> dict[str, list[str]]:
    names: dict[str, list[str]] = {}
    for path in sorted([*WORKFLOWS.glob("*.yml"), *WORKFLOWS.glob("*.yaml")]):
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
        if not isinstance(document, dict) or "merge_group" not in triggers(document):
            continue
        for job_id, job in (document.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            # A job that excludes merge_group in its `if` never reports there.
            condition = str(job.get("if", ""))
            if "merge_group" in condition and "!=" in condition:
                continue
            names.setdefault(str(job.get("name", job_id)), []).append(path.name)
    return names


def assert_merge_group_bridge() -> None:
    document = yaml.safe_load(MERGE_GROUP_BRIDGE.read_text(encoding="utf-8"))
    assert isinstance(document, dict)
    assert set(document) == {True, "name", "permissions", "jobs"}
    assert triggers(document) == {"merge_group"}
    assert document["permissions"] == {}

    jobs = document["jobs"]
    assert set(jobs) == set(BRIDGE_RUNS)
    expected_names = {
        "cla-assistant": "CLA Assistant",
        "cla-policy-guard": "CLA policy guard",
    }
    for job_id, expected_run in BRIDGE_RUNS.items():
        job = jobs[job_id]
        assert set(job) == {"name", "runs-on", "timeout-minutes", "steps"}
        assert job["name"] == expected_names[job_id]
        assert job["runs-on"] == "ubuntu-24.04"
        assert job["timeout-minutes"] == 5
        assert len(job["steps"]) == 1
        step = job["steps"][0]
        assert set(step) == {"name", "env", "run"}
        assert step["name"].startswith("Confirm ")
        assert set(step["env"]) == {"EVENT_NAME", "GROUP_SHA"}
        assert step["env"]["EVENT_NAME"] == "${{ github.event_name }}"
        assert step["env"]["GROUP_SHA"] == "${{ github.sha }}"
        assert step["run"] == expected_run


def main() -> int:
    assert_merge_group_bridge()
    reported = merge_group_check_names()
    missing = [name for name in REQUIRED_CHECKS if name not in reported]
    if missing:
        print(
            "FAIL: these required checks never report on merge_group, so a merge "
            f"queue entry would wait forever: {', '.join(missing)}"
        )
        return 1
    duplicated = {
        name: files for name, files in reported.items()
        if name in REQUIRED_CHECKS and len(files) > 1
    }
    if duplicated:
        print(f"FAIL: more than one merge_group job reports the same required check: {duplicated}")
        return 1
    print("PASS: every covered required check reports on merge_group exactly once")
    return 0


if __name__ == "__main__":
    sys.exit(main())
