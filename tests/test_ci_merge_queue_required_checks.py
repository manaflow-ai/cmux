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

import contextlib
import importlib.util
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

_SPEC = importlib.util.spec_from_file_location(
    "required_status_checks", ROOT / "scripts/ci/required_status_checks.py"
)
_required_status_checks = importlib.util.module_from_spec(_SPEC)
assert _SPEC.loader is not None
# Registered before execution: the module defines a dataclass, and dataclasses
# resolve field types through sys.modules[cls.__module__].
sys.modules["required_status_checks"] = _required_status_checks
_SPEC.loader.exec_module(_required_status_checks)

# The required status checks on main. Each must report for merge queue runs.
REQUIRED_NAMES = _required_status_checks.REQUIRED_CHECKS

# Checks that judge a pull request's author and head in workflows a pull request
# may not edit. BRIDGE reports them for a merge group without running anything, so it
# must stay exactly this document: any other job, step, trigger or permission
# would run with those names' authority. The no-op bridge has no token, checkout, or candidate code, so it runs
# on cmux-linux, the persistent pool, like every own-branch Linux job (only the fleet-wide CI_OVERFLOW_LINUX
# switch ahead of it): it needs no one-job VM, and on 2026-11-21 the gate JIT label queued its jobs for hours
# while that pool sat idle (tests/test_ci_required_gate_label.py POOL_JOBS).
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
                "runs-on": "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_OVERFLOW_LINUX || 'cmux-linux' }}",
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


def top_level_or_branches(expression: str) -> list[str]:
    """Split an Actions expression at its `||` operators outside parentheses and quotes."""
    branches, depth, quoted, start, index = [], 0, False, 0, 0
    while index < len(expression):
        char = expression[index]
        if char == "'":
            quoted = not quoted
        elif not quoted and char == "(":
            depth += 1
        elif not quoted and char == ")":
            depth -= 1
        elif not quoted and depth == 0 and expression.startswith("||", index):
            branches.append(expression[start:index])
            start = index + 2
            index += 1
        index += 1
    branches.append(expression[start:])
    return branches


def merge_group_name(name: str) -> str:
    """Return the name a job publishes on merge_group.

    A name expression whose every branch but the last is guarded by
    `github.event_name == 'pull_request_target' && ...` publishes its final
    `|| 'literal'` on merge_group (backend-migrations.yml's gate renames only
    ignored feat-cmux-next edits and labels). Anything else stays as written.
    """
    text = name.strip()
    if not (text.startswith("${{") and text.endswith("}}")):
        return name
    branches = [part.strip() for part in top_level_or_branches(text[3:-2])]
    *guarded, last = branches
    if not guarded or not (last.startswith("'") and last.endswith("'") and last.count("'") == 2):
        return name
    if not all(branch.startswith("github.event_name == 'pull_request_target' && ") for branch in guarded):
        return name
    return last[1:-1]


def negated_clauses(condition: str) -> list[str]:
    """Return the inner text of each balanced `!(...)` clause in an `if` expression."""
    found = []
    start = condition.find("!(")
    while start != -1:
        depth, index = 0, start + 1
        while index < len(condition):
            if condition[index] == "(":
                depth += 1
            elif condition[index] == ")":
                depth -= 1
                if depth == 0:
                    found.append(condition[start + 2:index].strip())
                    break
            index += 1
        start = condition.find("!(", start + 2)
    return found


def bare_condition(condition: str) -> str:
    text = condition.strip()
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2]
    return text.strip()


def excludes(condition: str, other: str) -> bool:
    """True when `condition` requires `!(X)` and `other` ends with `&& X`: never both run.

    backend-migrations.yml's gate and gate-no-change (#57278) split one required check this way, on
    the plan's answer; the job that skips publishes its unevaluated name expression, not the check.
    """
    other = bare_condition(other)
    return any(clause and other.endswith("&& " + clause) for clause in negated_clauses(bare_condition(condition)))


def merge_group_check_names() -> dict[str, list[str]]:
    """Collect check names that can be emitted for merge-group runs."""
    names: dict[str, list[str]] = {}
    # (workflow, check name) -> the `if` of each job already counted for it.
    seen: dict[tuple[str, str], list[str]] = {}
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
            name = merge_group_name(str(job.get("name", job_id)))
            if path.name == "web-complexity-trusted.yml" and job_id == "complexity":
                # The required workflow must publish its literal verdict on
                # every event, including metadata edits and merge groups.
                try:
                    validate_metadata_routing(document)
                except (AssertionError, KeyError, TypeError):
                    continue
                name = REQUIRED_CHECK
            if any(
                excludes(condition, prior) or excludes(prior, condition)
                for prior in seen.get((path.name, name), [])
            ):
                continue
            seen.setdefault((path.name, name), []).append(condition)
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


class MergeGroupCheckNamesTests(unittest.TestCase):
    def setUp(self) -> None:
        """Load the trusted complexity workflow fixture for each test."""
        self.workflow = yaml.safe_load(
            (WORKFLOWS / "web-complexity-trusted.yml").read_text(encoding="utf-8")
        )

    def validate(self, workflow: dict, *, duplicate: bool = False) -> int:
        """Run the required-check validator against an isolated workflow set."""
        with tempfile.TemporaryDirectory() as temporary:
            workflows = Path(temporary)
            bridge = workflows / BRIDGE.name
            bridge.write_text(yaml.safe_dump(expected_bridge()), encoding="utf-8")
            (workflows / "web-complexity-trusted.yml").write_text(
                yaml.safe_dump(workflow), encoding="utf-8"
            )
            # "Web complexity" is no longer required on main, but its dynamic
            # name is still the hardest routing case, so these fixtures keep
            # requiring it.
            required = (*REQUIRED_NAMES, REQUIRED_CHECK)
            jobs = {
                name: {} for name in required
                if name not in {*BRIDGED_CHECKS.values(), REQUIRED_CHECK}
            }
            if duplicate:
                jobs["duplicate"] = {"name": "Web complexity"}
            (workflows / "other.yml").write_text(
                yaml.safe_dump({"on": "merge_group", "jobs": jobs}), encoding="utf-8"
            )
            with patch.dict(main.__globals__, WORKFLOWS=workflows, BRIDGE=bridge, REQUIRED_NAMES=required):
                with contextlib.redirect_stdout(io.StringIO()):
                    return main()

    def test_stable_name_reports_required_check_for_merge_group(self) -> None:
        """The real verdict must retain the required merge-group name."""
        self.assertEqual(self.validate(self.workflow), 0)

    def test_wrong_merge_group_name_is_rejected(self) -> None:
        """A changed required check name must fail validation."""
        self.workflow["jobs"]["complexity"]["name"] = "Wrong required name"
        self.assertEqual(self.validate(self.workflow), 1)

    def test_missing_merge_group_trigger_is_rejected(self) -> None:
        """Removing the merge-group trigger must fail validation."""
        events = self.workflow.get("on", self.workflow.get(True))
        events.pop("merge_group")
        self.assertEqual(self.validate(self.workflow), 1)

    def test_metadata_cannot_skip_required_verdict(self) -> None:
        """Metadata edits must execute the check, not publish skipped success."""
        self.workflow["jobs"]["complexity"]["if"] = "github.event.action != 'edited'"
        self.assertEqual(self.validate(self.workflow), 1)

    def test_duplicate_required_name_is_rejected(self) -> None:
        """Duplicate required check ownership must fail validation."""
        self.assertEqual(self.validate(self.workflow, duplicate=True), 1)

    def test_merge_group_name_resolves_pull_request_target_only_renames(self) -> None:
        """A name renamed only for pull_request_target events reports its fallback on merge_group."""
        renamed = (
            "${{ github.event_name == 'pull_request_target' && github.event.action == 'edited' && 'x (ignored)'"
            " || github.event_name == 'pull_request_target' && (github.event.action == 'labeled'"
            " || github.event.action == 'unlabeled') && 'y (ignored)' || 'backend migrations applied' }}"
        )
        self.assertEqual(merge_group_name(renamed), "backend migrations applied")
        other = "${{ github.event.action == 'edited' && 'x' || 'backend migrations applied' }}"
        self.assertEqual(merge_group_name(other), other)

    def test_merge_group_excluded_job_is_rejected(self) -> None:
        """The required job must remain eligible on merge-group events."""
        self.workflow["jobs"]["complexity"]["if"] = "github.event_name != 'merge_group'"
        self.assertEqual(self.validate(self.workflow), 1)

    def test_only_complementary_jobs_share_a_required_name(self) -> None:
        """Jobs split on `!(X)` / `&& X` never both run; any other pair is still a duplicate."""
        split = "needs.plan.result == 'success' && needs.plan.outputs.migrations == 'false'"
        self.assertTrue(excludes(f"always() && !({split})", f"${{{{ !cancelled() && {split} }}}}"))
        self.assertFalse(excludes("always()", f"${{{{ !cancelled() && {split} }}}}"))
        self.assertFalse(excludes(f"always() && !({split})", "${{ !cancelled() }}"))


if __name__ == "__main__":
    tests = unittest.defaultTestLoader.loadTestsFromTestCase(MergeGroupCheckNamesTests)
    if not unittest.TextTestRunner().run(tests).wasSuccessful():
        sys.exit(1)
    sys.exit(main())
