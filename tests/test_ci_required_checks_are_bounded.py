#!/usr/bin/env python3
"""A required check must be bounded, and a superseded PR run must be cancelled.

Two properties, both of which CI is structurally unable to complain about
because neither one makes anything fail.

A job with no `timeout-minutes` inherits GitHub's six-hour default. Every job
in `ci.yml` declares one between 5 and 20 minutes except `ci-status`, which is
the required aggregate: the check every pull request in the repository is
blocked on. A hang there blocks the whole repository for six hours and reads
as "still running" the entire time.

A `pull_request` workflow with no concurrency group starts a fresh run per
push and lets the superseded ones finish. `ci.yml` and most of its neighbours
already cancel; five path-filtered workflows had no group at all.

Both rules stay derived rather than listed. The required contexts come from
the repository ruleset and are matched to jobs by name, and a context that
stops matching any job fails this test rather than quietly guarding nothing.
"""

from __future__ import annotations

import sys
from pathlib import Path

import yaml

from test_web_complexity_trusted_workflow import REQUIRED_CHECK, validate_metadata_routing


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
CI_WORKFLOW = WORKFLOWS / "ci.yml"

# `gh api repos/manaflow-ai/cmux/rules/branches/main`, the
# required_status_checks rule. Update alongside the ruleset.
REQUIRED_CONTEXTS = (
    "CLA Assistant",
    "CLA policy guard",
    "ci-status",
    "Web complexity",
    "web-validation",
)


def load(path: Path) -> dict:
    parsed = yaml.safe_load(path.read_text(encoding="utf-8"))
    return parsed if isinstance(parsed, dict) else {}


def triggers(workflow: dict) -> set[str]:
    # PyYAML resolves a bare `on:` key to the boolean True.
    on = workflow.get("on", workflow.get(True, {}))
    if isinstance(on, dict):
        return set(on)
    if isinstance(on, str):
        return {on}
    return set(on or ())



def reachable(roots: set[Path], workflows: dict[Path, dict]) -> set[Path]:
    """Required-check workflows plus the local reusable ones they call.

    ci.yml delegates whole areas through `uses: ./.github/workflows/...`.
    Those jobs run under ci.yml's run and gate ci-status exactly like its own
    jobs do, so a bound is worth just as much there. They are easy to miss
    because a reusable workflow has no runs of its own to look at.
    """
    seen: set[Path] = set()
    queue = list(roots)
    while queue:
        path = queue.pop()
        if path in seen or path not in workflows:
            continue
        seen.add(path)
        for job in (workflows[path].get("jobs") or {}).values():
            if not isinstance(job, dict):
                continue
            uses = job.get("uses", "")
            if isinstance(uses, str) and uses.startswith("./.github/workflows/"):
                queue.append(ROOT / uses.removeprefix("./"))
    return seen


def context_of(job_id: str, job: dict, path: Path, workflow: dict) -> str:
    name = job.get("name") or job_id
    if path.name == "web-complexity-trusted.yml" and job_id == "complexity" and "${{" in name:
        # Interpret only the validated routing contract. Unknown expressions
        # must remain unmatched instead of silently dropping timeout coverage.
        try:
            validate_metadata_routing(workflow)
        except (AssertionError, KeyError, TypeError):
            return name
        return REQUIRED_CHECK
    if path.name == "cla-policy-guard.yml" and job_id == "validate":
        from test_cla_guard_metadata_routing import (
            REQUIRED_CHECK as CLA_REQUIRED_CHECK,
            validate_metadata_routing as validate_cla_metadata_routing,
        )
        try:
            validate_cla_metadata_routing(workflow)
        except (AssertionError, KeyError, TypeError) as error:
            if "${{" in str(name) or "if" in job:
                raise ValueError("CLA metadata route violates its condition/name contract") from error
        else:
            return CLA_REQUIRED_CHECK
    return name


def check_macos_15_pull_request_lane() -> str | None:
    """Require every CI pull request run to execute the full unit target on macOS 15."""
    workflow = load(CI_WORKFLOW)
    jobs = workflow.get("jobs") or {}
    lane = jobs.get("macos-15-unit-tests")
    if not isinstance(lane, dict):
        return "ci.yml has no macos-15-unit-tests job"
    if lane.get("uses") != "./.github/workflows/test-macos-suite.yml":
        return "macos-15-unit-tests must call test-macos-suite.yml"
    if lane.get("if") is not None:
        return "macos-15-unit-tests must not be path-gated"
    if lane.get("with", {}).get("skip_unit_tests") is not False:
        return "macos-15-unit-tests must run unit tests"
    if lane.get("with", {}).get("skip_ui_tests") is not True:
        return "macos-15-unit-tests must skip UI tests"
    if lane.get("with", {}).get("runner") != (
        "${{ vars.MACOS_RUNNER_15 || 'blacksmith-6vcpu-macos-15' }}"
    ):
        return "macos-15-unit-tests must select the macOS 15 runner"
    if "macos-15-unit-tests" not in (jobs.get("ci-status", {}).get("needs") or []):
        return "ci-status must wait for macos-15-unit-tests"
    return None


def main() -> int:
    workflows = {p: load(p) for p in sorted(WORKFLOWS.glob("*.y*ml"))}
    failures: list[str] = []

    macos_15_failure = check_macos_15_pull_request_lane()
    if macos_15_failure:
        failures.append(macos_15_failure)

    # Which workflows own a required check, by what their jobs are called.
    owners: dict[str, set[Path]] = {}
    for path, workflow in workflows.items():
        for job_id, job in (workflow.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            try:
                context = context_of(job_id, job, path, workflow)
            except ValueError as error:
                failures.append(f"{path.name}:{job_id}: {error}")
                continue
            if context in REQUIRED_CONTEXTS:
                owners.setdefault(context, set()).add(path)

    unmatched = [c for c in REQUIRED_CONTEXTS if c not in owners]
    if unmatched:
        failures.append(
            "required contexts match no job; the ruleset and this list have "
            f"drifted apart: {', '.join(unmatched)}"
        )

    required_workflows = {path for paths in owners.values() for path in paths}
    for path in sorted(reachable(required_workflows, workflows)):
        for job_id, job in (workflows[path].get("jobs") or {}).items():
            if not isinstance(job, dict) or "uses" in job:
                continue
            if "timeout-minutes" not in job:
                failures.append(
                    f"{path.relative_to(ROOT)}:{job_id} has no "
                    "timeout-minutes, so it inherits GitHub's six-hour "
                    "default -- in a workflow that owns a required check"
                )

    for path, workflow in workflows.items():
        if "pull_request" not in triggers(workflow):
            continue
        # A group is the requirement; what it does with a superseded run is
        # the workflow's call. repair-nightly-appcast-content-types.yml sets
        # cancel-in-progress: false on purpose because it writes to R2, and
        # serializing is as good an answer as cancelling.
        if not workflow.get("concurrency"):
            failures.append(
                f"{path.relative_to(ROOT)} runs on pull_request with no "
                "concurrency group, so every push leaves the superseded run "
                "running"
            )

    if failures:
        print("unbounded CI:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1

    print(
        f"{len(REQUIRED_CONTEXTS)} required checks are bounded; "
        "every pull_request workflow has a concurrency group"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
