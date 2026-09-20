#!/usr/bin/env python3
"""Every required check on main must also report for merge queue runs.

GitHub waits for each required check on the merge group commit. A check whose
workflow does not trigger on merge_group never reports there, and the queue
entry waits until it times out.
"""

from __future__ import annotations

import contextlib
import io
import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

import yaml

from test_web_complexity_trusted_workflow import REQUIRED_CHECK, validate_metadata_routing

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

# The required status checks on main. Each must report for merge queue runs.
REQUIRED_CHECKS = (
    "CLA Assistant",
    "CLA policy guard",
    "Web complexity",
    "ci-status",
    "web-validation",
)

# Checks that judge a pull request's author and head in workflows a pull request
# may not edit. BRIDGE reports them for a merge group without running anything, so it
# must stay exactly this document: any other job, step, trigger or permission
# would run with those names' authority.
BRIDGE = WORKFLOWS / "merge-group-policy-checks.yml"
BRIDGED_CHECKS = {
    "cla-assistant": "CLA Assistant",
    "cla-policy-guard": "CLA policy guard",
}


def expected_bridge() -> dict:
    return {
        "name": "Merge-group policy checks",
        True: {"merge_group": None},
        "permissions": {},
        "jobs": {
            job_id: {
                "name": name,
                "runs-on": "ubuntu-24.04",
                "timeout-minutes": 5,
                "steps": [{"run": 'echo "Passed on every pull request in this merge group."'}],
            }
            for job_id, name in BRIDGED_CHECKS.items()
        },
    }


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
            name = str(job.get("name", job_id))
            if path.name == "web-complexity-trusted.yml" and job_id == "complexity" and "${{" in name:
                # This routing contract requires the metadata predicate to start
                # with event_name == pull_request_target. On merge_group it is
                # false, so the job runs with the required name. Validate the
                # entire contract before interpreting this one dynamic name;
                # changed/unknown expressions must not satisfy the queue guard.
                try:
                    validate_metadata_routing(document)
                except (AssertionError, KeyError, TypeError):
                    continue
                name = REQUIRED_CHECK
            names.setdefault(name, []).append(path.name)
    return names


def main() -> int:
    if yaml.safe_load(BRIDGE.read_text(encoding="utf-8")) != expected_bridge():
        print(f"FAIL: {BRIDGE.name} must contain only the fixed no-op jobs for {', '.join(BRIDGED_CHECKS.values())}")
        return 1
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


class MergeGroupCheckNamesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.workflow = yaml.safe_load(
            (WORKFLOWS / "web-complexity-trusted.yml").read_text(encoding="utf-8")
        )

    def validate(self, workflow: dict, *, duplicate: bool = False) -> int:
        with tempfile.TemporaryDirectory() as temporary:
            workflows = Path(temporary)
            bridge = workflows / BRIDGE.name
            bridge.write_text(yaml.safe_dump(expected_bridge()), encoding="utf-8")
            (workflows / "web-complexity-trusted.yml").write_text(
                yaml.safe_dump(workflow), encoding="utf-8"
            )
            jobs = {
                name: {} for name in REQUIRED_CHECKS
                if name not in {*BRIDGED_CHECKS.values(), "Web complexity"}
            }
            if duplicate:
                jobs["duplicate"] = {"name": "Web complexity"}
            (workflows / "other.yml").write_text(
                yaml.safe_dump({"on": "merge_group", "jobs": jobs}), encoding="utf-8"
            )
            with patch.dict(main.__globals__, WORKFLOWS=workflows, BRIDGE=bridge):
                with contextlib.redirect_stdout(io.StringIO()):
                    return main()

    def test_dynamic_name_reports_required_check_for_merge_group(self) -> None:
        self.assertEqual(self.validate(self.workflow), 0)

    def test_wrong_merge_group_name_is_rejected(self) -> None:
        self.workflow["jobs"]["complexity"]["name"] = self.workflow["jobs"]["complexity"]["name"].replace(
            "'Web complexity'", "'Wrong required name'"
        )
        self.assertEqual(self.validate(self.workflow), 1)

    def test_missing_merge_group_trigger_is_rejected(self) -> None:
        events = self.workflow.get("on", self.workflow.get(True))
        events.pop("merge_group")
        self.assertEqual(self.validate(self.workflow), 1)

    def test_metadata_cannot_use_required_name(self) -> None:
        self.workflow["jobs"]["complexity"]["name"] = self.workflow["jobs"]["complexity"]["name"].replace(
            "'Web complexity metadata (ignored)'", "'Web complexity'"
        )
        self.assertEqual(self.validate(self.workflow), 1)

    def test_duplicate_required_name_is_rejected(self) -> None:
        self.assertEqual(self.validate(self.workflow, duplicate=True), 1)

    def test_merge_group_excluded_job_is_rejected(self) -> None:
        self.workflow["jobs"]["complexity"]["if"] = "github.event_name != 'merge_group'"
        self.assertEqual(self.validate(self.workflow), 1)


if __name__ == "__main__":
    tests = unittest.defaultTestLoader.loadTestsFromTestCase(MergeGroupCheckNamesTests)
    if not unittest.TextTestRunner().run(tests).wasSuccessful():
        sys.exit(1)
    sys.exit(main())
