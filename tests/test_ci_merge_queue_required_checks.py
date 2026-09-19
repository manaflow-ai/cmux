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

# The required status checks on main that a pull request can make report for
# the merge queue. Three more are required and are left to maintainers:
# "CLA Assistant" and "CLA policy guard" judge a pull request's authors and
# policy edits from the base branch, and "Web complexity" lives in a workflow
# that its own check forbids a pull request from editing.
REQUIRED_CHECKS = (
    "ci-status",
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
    for path in sorted(WORKFLOWS.glob("*.yml")):
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


def main() -> int:
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
    print("PASS: every required check reports on merge_group exactly once")
    return 0


if __name__ == "__main__":
    sys.exit(main())
