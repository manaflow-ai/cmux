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


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"

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


def context_of(job_id: str, job: dict) -> str:
    return job.get("name") or job_id


def main() -> int:
    workflows = {p: load(p) for p in sorted(WORKFLOWS.glob("*.y*ml"))}
    failures: list[str] = []

    # Which workflows own a required check, by what their jobs are called.
    owners: dict[str, Path] = {}
    for path, workflow in workflows.items():
        for job_id, job in (workflow.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            context = context_of(job_id, job)
            if context in REQUIRED_CONTEXTS:
                owners[context] = path

    unmatched = [c for c in REQUIRED_CONTEXTS if c not in owners]
    if unmatched:
        failures.append(
            "required contexts match no job; the ruleset and this list have "
            f"drifted apart: {', '.join(unmatched)}"
        )

    for path in sorted(set(owners.values())):
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
        "pull_request workflows cancel superseded runs"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
