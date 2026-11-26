#!/usr/bin/env python3
"""Every required check on main must also report for merge queue runs.

GitHub waits for each required check on the merge group commit. A check whose
workflow does not trigger on merge_group never reports there, and the queue
entry waits until it times out.

The list of required checks is not this file's to declare: it is a copy of a
repository ruleset, and it is owned by scripts/ci/required_status_checks.py,
which reconciles that copy against GitHub. This file reads the copy and the
workflows, so it can only see disagreements inside the tree.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

# Imported by name, never loaded by path: one module object per file (tests/test_script_module_loads.py).
if str(ROOT / "scripts/ci") not in sys.path:
    sys.path.insert(0, str(ROOT / "scripts/ci"))
import required_status_checks as _required_status_checks  # noqa: E402

# The required status checks on main. Each must report for merge queue runs.
REQUIRED_NAMES = _required_status_checks.REQUIRED_CHECKS

# Checks that judge a pull request's author and head in workflows a pull request
# may not edit. BRIDGE reports them for a merge group without running anything, so it
# must stay exactly this document: any other job, step, trigger or permission
# would run with those names' authority. The no-op bridge uses the standard
# Blacksmith expression because it has no token, checkout, or candidate code.
BRIDGE = WORKFLOWS / "merge-group-policy-checks.yml"
BRIDGED_CHECKS = {
    "cla-assistant": "CLA Assistant",
    "cla-policy-guard": "CLA policy guard",
}


def expected_bridge() -> dict:
    """Return the canonical required-check bridge fixture."""
    return {
        "name": "Merge-group policy checks",
        True: {"merge_group": None},
        "permissions": {},
        "jobs": {
            job_id: {
                "name": name,
                "runs-on": "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository && 'ubuntu-24.04' || 'cmux-linux' }}",
                "timeout-minutes": 5,
                "steps": [{"run": 'echo "Passed on every pull request in this merge group."'}],
            }
            for job_id, name in BRIDGED_CHECKS.items()
        },
    }


def triggers(document: dict) -> set[str]:
    """Return workflow event names from GitHub Actions YAML."""
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
    """Collect check names that can be emitted for merge-group runs."""
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
            name = str(job.get("name", job_id))
            if "${{" in name:
                # A name that differs only on a title or body edit (pattern pr-edit-fans-out-ci) is
                # its merge-group name with the event's own context. An unknown expression stays as
                # written, so it matches nothing.
                from test_ci_pr_runs_cancel_superseded import ExpressionError, pr_context, resolve

                context = pr_context(document, "pull_request", 101, 1)
                context["github"]["event_name"] = "merge_group"
                context["github"]["event"] = {"merge_group": {"head_sha": "a" * 40, "base_sha": "b" * 40}}
                try:
                    name = str(resolve(name, context))
                except (ExpressionError, KeyError, IndexError, TypeError, ValueError):
                    pass
            names.setdefault(name, []).append(path.name)
    return names


def main() -> int:
    """Validate required merge-queue check ownership and uniqueness."""
    if yaml.safe_load(BRIDGE.read_text(encoding="utf-8")) != expected_bridge():
        print(f"FAIL: {BRIDGE.name} must contain only the fixed no-op jobs for {', '.join(BRIDGED_CHECKS.values())}")
        return 1
    reported = merge_group_check_names()
    missing = [name for name in REQUIRED_NAMES if name not in reported]
    if missing:
        print(
            "FAIL: these required checks never report on merge_group, so a merge "
            f"queue entry would wait forever: {', '.join(missing)}"
        )
        return 1
    duplicated = {
        name: files for name, files in reported.items()
        if name in REQUIRED_NAMES and len(files) > 1
    }
    if duplicated:
        print(f"FAIL: more than one merge_group job reports the same required check: {duplicated}")
        return 1
    print("PASS: every required check reports on merge_group exactly once")
    return 0


if __name__ == "__main__":
    sys.exit(main())
