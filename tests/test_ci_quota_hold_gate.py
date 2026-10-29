#!/usr/bin/env python3
"""The CI_QUOTA_HOLD repository variable pauses API-heavy optional workflows.

Every workflow run spends the same installation GITHUB_TOKEN budget (5000
calls an hour). On 2026-10-26 pull request traffic emptied it within about 30
minutes of each reset, and the nightly's attest step then failed with "API
rate limit exceeded for installation". Setting the repository variable
CI_QUOTA_HOLD to 1 for the first hour after a reset pauses the optional,
API-heavy workflows listed here, so the nightly gets the budget first.

The gate is a job condition, `vars.CI_QUOTA_HOLD != '1'`, so an unset or any
other value runs everything as before. This test keeps it in place:

  - every workflow in HOLD_GATED gates each job that does not wait on another
    job of the same workflow (a job that `needs` a gated job is skipped with it),
    or, where HOLD_GATED names its jobs, each of those jobs;
  - no workflow that produces a required check reads the variable, so the hold
    can never make a pull request unmergeable or let one merge unchecked;
  - no nightly, dev or promote delivery workflow reads it.

A workflow that reads CI_QUOTA_HOLD must be listed in HOLD_GATED, so a partial
gate (one job held, its siblings still spending) cannot slip in unnoticed.

pull_request and pull_request_target runs into feat-cmux-next read this
branch's workflow files; workflow_run runs read main's, so main carries its own
copy of this test with its own list.

DRAFT_SKIPPED workflows also skip draft pull requests: a draft cannot merge, so
its checks run once, when it is marked ready (the `ready_for_review` trigger).

Each list maps a workflow to the jobs it covers; an empty tuple means every job
that does not wait on another. pr-checks.yml folds several pull request checks
into one run, so only some of its jobs are held or skip drafts.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))

from test_ci_required_checks_are_bounded import context_of, load  # noqa: E402
from test_ci_required_checks_have_no_path_filters import REQUIRED_CHECKS  # noqa: E402

WORKFLOWS = ROOT / ".github/workflows"
VARIABLE = "CI_QUOTA_HOLD"
GATE = "vars.CI_QUOTA_HOLD != '1'"

# Optional workflows that spend GITHUB_TOKEN calls on every pull request
# completion and that the nightly must not compete with during the hold.
HOLD_GATED: dict[str, tuple[str, ...]] = {
    "gallery-advisory.yml": (),
    "pr-checks.yml": ("link", "size"),
}

# Optional pull request workflows that skip drafts and run on ready_for_review.
# Only workflows whose skipped run no merger reads as a pass: next-autoland
# treats a skipped check as passing and ignores a pending one, so a check that
# can block a merge (the capture check, the defaults guard) keeps running on
# drafts. The fast gates are safe: mergers read their commit status, and one
# missing on the head dispatches the gates rather than passing.
DRAFT_SKIPPED: dict[str, tuple[str, ...]] = {
    "cmux-next-fast-gates.yml": (),
    "gallery-advisory.yml": (),
    "pr-checks.yml": ("link", "size"),
}
# Checks a merger reads as a pass when skipped; they must never skip drafts.
NEVER_DRAFT_SKIPPED = (
    "cmux-next-defaults-guard.yml",
    "pr-capture-check.yml",
)
DRAFT = "!github.event.pull_request.draft"
PR_EVENTS = ("pull_request", "pull_request_target")

DELIVERY = re.compile(r"^(nightly.*|cmux-next-dev-daily.*|.*promote.*|release)\.ya?ml$")


def workflow_files() -> list[Path]:
    return sorted(WORKFLOWS.glob("*.y*ml"))


def required_owners(workflows: dict[Path, dict]) -> set[Path]:
    owners: set[Path] = set()
    for path, workflow in workflows.items():
        for job_id, job in (workflow.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            try:
                context = context_of(job_id, job, path, workflow)
            except ValueError:
                # A malformed CLA route is the timeout guard's to report; a
                # job here that cannot be matched still owns nothing.
                owners.add(path)
                continue
            if context in REQUIRED_CHECKS:
                owners.add(path)
    return owners


def covered_jobs(workflow: dict, listed: tuple[str, ...] = ()) -> dict[str, dict]:
    """The listed jobs, or, for an empty tuple, every job that waits on no other."""
    jobs = {job_id: job for job_id, job in (workflow.get("jobs") or {}).items() if isinstance(job, dict)}
    if listed:
        return {job_id: jobs.get(job_id, {}) for job_id in listed}
    return {job_id: job for job_id, job in jobs.items() if not job.get("needs")}


def ungated_jobs(workflow: dict, listed: tuple[str, ...] = ()) -> list[str]:
    return [job_id for job_id, job in covered_jobs(workflow, listed).items() if GATE not in str(job.get("if", ""))]


def events(workflow: dict) -> dict:
    # PyYAML resolves a bare `on:` key to the boolean True.
    on = workflow.get("on", workflow.get(True))
    if isinstance(on, dict):
        return on
    if isinstance(on, str):
        return {on: None}
    if isinstance(on, list):
        return dict.fromkeys(on)
    return {}


def draft_violations(paths: list[Path] | None = None, listed: dict[str, tuple[str, ...]] = DRAFT_SKIPPED) -> list[str]:
    paths = workflow_files() if paths is None else paths
    by_name = {path.name: path for path in paths}
    workflows = {path: load(path) for path in paths}
    owners = {path.name for path in required_owners(workflows)}
    failures: list[str] = []
    for name in listed:
        path = by_name.get(name)
        if path is None:
            failures.append(f"{name} is listed in DRAFT_SKIPPED but does not exist")
            continue
        if name in owners and not listed[name]:
            failures.append(f"{name} produces a required check and must not skip drafts")
        if listed[name] and required_owners({path: {**workflows[path], "jobs": covered_jobs(workflows[path], listed[name])}}):
            failures.append(f"{name} skips drafts in a job that produces a required check")
        workflow = workflows[path]
        triggers = events(workflow)
        pr_events = [event for event in PR_EVENTS if event in triggers]
        if not pr_events:
            failures.append(f"{name} has no pull request trigger to skip drafts on")
        for event in pr_events:
            types = (triggers[event] or {}).get("types") if isinstance(triggers[event], dict) else None
            if not types or "ready_for_review" not in types:
                failures.append(f"{name} skips drafts but `{event}` does not list ready_for_review")
        for job_id, job in covered_jobs(workflow, listed[name]).items():
            if DRAFT not in str(job.get("if", "")):
                failures.append(f"{name} job {job_id!r} does not skip drafts (`{DRAFT}`)")
    return failures


def violations(paths: list[Path] | None = None, gated: dict[str, tuple[str, ...]] = HOLD_GATED) -> list[str]:
    paths = workflow_files() if paths is None else paths
    texts = {path: path.read_text(encoding="utf-8") for path in paths}
    workflows = {path: load(path) for path in paths}
    by_name = {path.name: path for path in paths}
    failures: list[str] = []

    for name in gated:
        path = by_name.get(name)
        if path is None:
            failures.append(f"{name} is listed in HOLD_GATED but does not exist")
            continue
        for job_id in ungated_jobs(workflows[path], gated[name]):
            failures.append(f"{name} job {job_id!r} does not gate on `{GATE}`")

    owners = required_owners(workflows)
    for path, text in texts.items():
        if VARIABLE not in text:
            continue
        held = gated.get(path.name)
        if held:
            # A folded workflow: only the named jobs may read it, and none of them owns a required check.
            jobs = workflows[path].get("jobs") or {}
            failures.extend(f"{path.name} job {job_id!r} reads {VARIABLE} but is not listed in HOLD_GATED"
                            for job_id, job in jobs.items() if VARIABLE in str(job) and job_id not in held)
            if required_owners({path: {**workflows[path], "jobs": covered_jobs(workflows[path], held)}}):
                failures.append(f"{path.name} holds a job that produces a required check on {VARIABLE}")
        elif path in owners:
            failures.append(f"{path.name} produces a required check and must not read {VARIABLE}")
        if DELIVERY.match(path.name):
            failures.append(f"{path.name} is a delivery workflow and must not read {VARIABLE}")
        if path.name not in gated:
            failures.append(f"{path.name} reads {VARIABLE} but is not listed in HOLD_GATED")
    return failures


class QuotaHoldGateTests(unittest.TestCase):
    def test_current_tree_passes(self) -> None:
        self.assertEqual(violations(), [])

    def test_the_gated_workflows_produce_no_required_check(self) -> None:
        owners = {path.name for path in required_owners({p: load(p) for p in workflow_files()})}
        self.assertTrue(owners, "no workflow owns a required check; the mirror is unreadable")
        self.assertFalse(owners & {name for name, jobs in HOLD_GATED.items() if not jobs})

    def test_draft_skipping_workflows_run_when_marked_ready(self) -> None:
        self.assertEqual(draft_violations(), [])

    def test_a_dropped_ready_for_review_trigger_is_reported(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            original = (WORKFLOWS / "pr-checks.yml").read_text(encoding="utf-8")
            dropped = self.write(directory, "pr-checks.yml", original.replace(", ready_for_review]", "]"))
            others = [p for p in workflow_files() if p.name != dropped.name]
            failures = draft_violations(others + [dropped])
        self.assertTrue(any("does not list ready_for_review" in f for f in failures), failures)

    def test_merge_blocking_checks_still_run_on_drafts(self) -> None:
        for name in NEVER_DRAFT_SKIPPED:
            with self.subTest(workflow=name):
                self.assertNotIn("pull_request.draft", (WORKFLOWS / name).read_text(encoding="utf-8"))
                self.assertNotIn(name, DRAFT_SKIPPED)

    def write(self, directory: Path, name: str, text: str) -> Path:
        path = directory / name
        path.write_text(text, encoding="utf-8")
        return path

    def test_a_dropped_gate_is_reported(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            original = (WORKFLOWS / "pr-checks.yml").read_text(encoding="utf-8")
            dropped = self.write(directory, "pr-checks.yml", original.replace(f"{GATE} && ", "", 1))
            others = [p for p in workflow_files() if p.name != dropped.name]
            failures = violations(others + [dropped])
        self.assertTrue(any("'link' does not gate" in f for f in failures), failures)

    def test_a_required_workflow_reading_the_variable_is_reported(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            original = (WORKFLOWS / "backend-migrations.yml").read_text(encoding="utf-8")
            held = self.write(directory, "backend-migrations.yml", original + f"\n# {VARIABLE}\n")
            others = [p for p in workflow_files() if p.name != held.name]
            failures = violations(others + [held])
        self.assertTrue(any("produces a required check" in f for f in failures), failures)

    def test_an_unlisted_reader_is_reported(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            stray = self.write(directory, "stray.yml", "on: push\njobs:\n  a:\n"
                               f"    if: {GATE}\n    runs-on: ubuntu-24.04\n    steps: [{{run: x}}]\n")
            failures = violations(workflow_files() + [stray])
        self.assertTrue(any("stray.yml reads" in f for f in failures), failures)

    def test_delivery_names_are_recognised(self) -> None:
        for name in ("nightly.yml", "nightly-next-tick.yml", "cmux-next-dev-daily.yml", "release.yml"):
            self.assertTrue(DELIVERY.match(name), name)
        self.assertFalse(DELIVERY.match("pr-checks.yml"))


if __name__ == "__main__":
    unittest.main()
