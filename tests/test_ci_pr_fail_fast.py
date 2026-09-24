#!/usr/bin/env python3
"""Tests for the pull request CI fail-fast job (scripts/ci/pr_fail_fast.py).

ci-status accepts only `success` or `skipped` from every job it needs, so once
a required Linux job concludes `failure` the pull request is red on that head
whatever the macOS jobs find. macos-debounce declines admission for a failure
that lands before it admits; a failure after admission left the run's macOS
jobs holding the Mac pools until the queue janitor's next sweep plus its
10-minute grace window, and the janitor does not read Linux failures at all.

The `macos-fail-fast` job in ci.yml is started by the failure itself through
`needs:`, with no polling, and cancels its own run after one read that applies
the janitor's exemptions.
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts/ci"
WORKFLOWS = ROOT / ".github/workflows"
CI_WORKFLOW = WORKFLOWS / "ci.yml"
JOB = "macos-fail-fast"

sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("pr_fail_fast", SCRIPTS / "pr_fail_fast.py")
fail_fast = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules["pr_fail_fast"] = fail_fast
SPEC.loader.exec_module(fail_fast)

RUN_ID = 4242
ENV = {
    "CI_RUN_ID": str(RUN_ID),
    "CI_RUN_ATTEMPT": "1",
    "GITHUB_EVENT_NAME": "pull_request",
    "GITHUB_WORKFLOW": "CI",
    "CI_WORKFLOW_REF": "manaflow-ai/cmux/.github/workflows/ci.yml@refs/pull/7/merge",
    "PR_NUMBER": "7",
    "HEAD_REF": "feature",
    "HEAD_SHA": "aaa",
    "HEAD_OWNER": "manaflow-ai",
}


def make_run(**overrides):
    env = {**ENV, **{key: str(value) for key, value in overrides.items()}}
    return fail_fast.run_from_env(env)


def make_pr(*, number=7, state="OPEN", head="aaa", labels=(), files=("web/app/page.tsx",),
            files_truncated=False, owner="manaflow-ai"):
    return {
        "number": number, "state": state, "headRefOid": head,
        "headRepositoryOwner": {"login": owner},
        "files": None if files is None else {
            "pageInfo": {"hasNextPage": files_truncated},
            "nodes": [{"path": path} for path in files],
        },
        "labels": {"nodes": [{"name": name} for name in labels]},
        "timelineItems": {"nodes": []},
    }


def needs(**results):
    base = {name: {"result": "success", "outputs": {}} for name in fail_fast.FAST_LINUX_JOBS}
    base["changes"] = {"result": "success", "outputs": {"macos": "true"}}
    for name, result in results.items():
        base[name.replace("_", "-")] = {"result": result, "outputs": {}}
    return base


def ci_jobs() -> dict:
    return yaml.safe_load(CI_WORKFLOW.read_text(encoding="utf-8"))["jobs"]


def runs_on_macos(job: dict) -> bool:
    """Whether a ci.yml job, or any job of the workflow it calls, can take a Mac."""
    if "uses" in job:
        called = yaml.safe_load((ROOT / job["uses"]).read_text(encoding="utf-8"))
        return any(runs_on_macos(inner) for inner in (called.get("jobs") or {}).values())
    return "macos" in str(job.get("runs-on", "")).lower()


class FakeGitHub:
    def __init__(self, prs=None):
        self.prs = [make_pr()] if prs is None else prs
        self.cancelled: list[int] = []
        self.calls = 0

    def pull_requests(self, branches):
        self.calls += 1
        return {branch: self.prs for branch in branches}

    def cancel(self, run_id):
        self.calls += 1
        self.cancelled.append(run_id)

    def __getattr__(self, name):
        raise AssertionError(f"pr_fail_fast must not call GitHub.{name}")


class FailedJobTests(unittest.TestCase):
    def test_failed_fast_linux_jobs_are_reported(self):
        self.assertEqual(fail_fast.failed_linux_jobs(needs(guards="failure")), ["guards"])
        self.assertEqual(fail_fast.failed_linux_jobs(needs(web="failure", guards="failure")), ["guards", "web"])

    def test_only_failure_counts(self):
        for result in ("success", "skipped", "cancelled"):
            with self.subTest(result=result):
                self.assertEqual(fail_fast.failed_linux_jobs(needs(guards=result)), [])

    def test_jobs_outside_the_fast_linux_set_are_ignored(self):
        self.assertEqual(fail_fast.failed_linux_jobs(needs(changes="failure", macos="failure")), [])


class VerdictTests(unittest.TestCase):
    def verdict(self, *, run=None, failed=("guards",), pr="default"):
        return fail_fast.verdict(run or make_run(), list(failed), make_pr() if pr == "default" else pr)

    def test_decided_red_run_is_cancelled(self):
        action, reason = self.verdict()
        self.assertEqual(action, "cancel")
        self.assertIn("`guards`", reason)
        self.assertIn("PR #7", reason)

    def test_nothing_failed_is_kept(self):
        self.assertEqual(self.verdict(failed=())[0], "keep")

    def test_janitor_exemptions_keep_the_run(self):
        cases = {
            "re-run attempt": dict(run=make_run(CI_RUN_ATTEMPT=2)),
            "not the CI workflow": dict(run=make_run(
                CI_WORKFLOW_REF="manaflow-ai/cmux/.github/workflows/ci-macos.yml@refs/pull/7/merge")),
            "opt-out label": dict(pr=make_pr(labels=["no-janitor"])),
            "diff touches app-host tests": dict(pr=make_pr(files=("Sources/A.swift", "cmuxTests/ATests.swift"))),
            "diff touches shard workflow": dict(pr=make_pr(files=(".github/workflows/ci-macos.yml",))),
            "unreadable diff": dict(pr=make_pr(files_truncated=True)),
            "missing diff": dict(pr=make_pr(files=None)),
            "unresolved PR": dict(pr=None),
            "closed PR": dict(pr=make_pr(state="CLOSED")),
            "superseded head": dict(pr=make_pr(head="bbb")),
            "merge group": dict(run=make_run(GITHUB_EVENT_NAME="merge_group",
                                             HEAD_REF="gh-readonly-queue/main/pr-1-abc")),
            "push": dict(run=make_run(GITHUB_EVENT_NAME="push")),
        }
        for name, kwargs in cases.items():
            with self.subTest(name=name):
                action, reason = self.verdict(**kwargs)
                self.assertEqual(action, "keep", reason)
                self.assertTrue(reason)

    def test_run_is_rebuilt_from_the_event(self):
        run = make_run()
        self.assertEqual(run["id"], RUN_ID)
        self.assertEqual(run["path"], ".github/workflows/ci.yml")
        self.assertEqual(run["run_attempt"], 1)
        self.assertEqual(run["head_repository"]["owner"]["login"], "manaflow-ai")
        self.assertEqual(run["pull_requests"], [{"number": 7}])


class ApiBudgetTests(unittest.TestCase):
    """At most one read and one cancel per decided-red run, and no polling."""

    def decide(self, github, failed=("guards",), dry_run=False):
        return fail_fast.decide(github, make_run(), list(failed), dry_run=dry_run)

    def test_cancel_costs_one_read_and_one_cancel(self):
        github = FakeGitHub()
        outcome = self.decide(github)
        self.assertEqual(github.cancelled, [RUN_ID])
        self.assertEqual(github.calls, 2)
        self.assertTrue(outcome.startswith("cancelled"), outcome)

    def test_exempt_run_costs_one_read(self):
        github = FakeGitHub(prs=[make_pr(labels=["no-janitor"])])
        outcome = self.decide(github)
        self.assertEqual(github.cancelled, [])
        self.assertEqual(github.calls, 1)
        self.assertTrue(outcome.startswith("kept"), outcome)

    def test_dry_run_never_cancels(self):
        github = FakeGitHub()
        outcome = self.decide(github, dry_run=True)
        self.assertEqual(github.cancelled, [])
        self.assertEqual(github.calls, 1)
        self.assertTrue(outcome.startswith("would cancel"), outcome)

    def test_nothing_failed_costs_nothing(self):
        github = FakeGitHub()
        self.decide(github, failed=())
        self.assertEqual(github.calls, 0)

    def test_script_has_no_polling(self):
        source = (SCRIPTS / "pr_fail_fast.py").read_text(encoding="utf-8")
        self.assertNotIn("sleep", source)
        self.assertNotIn("while ", source)


class WorkflowShapeTests(unittest.TestCase):
    def setUp(self):
        self.jobs = ci_jobs()
        self.job = self.jobs[JOB]

    def test_started_by_needs_not_by_polling(self):
        self.assertEqual(self.job["needs"], ["changes", *fail_fast.FAST_LINUX_JOBS])
        condition = self.job["if"]
        self.assertTrue(condition.startswith("${{ !cancelled() && "), condition)
        for name in fail_fast.FAST_LINUX_JOBS:
            self.assertIn(f"needs.{name}.result == 'failure'", condition)
        self.assertIn("github.event_name == 'pull_request'", condition)
        self.assertIn("github.run_attempt == '1'", condition)
        # A fork's token cannot cancel; do not start a runner to find out.
        self.assertIn("github.event.pull_request.head.repo.full_name == github.repository", condition)
        # Nothing to reclaim when this run never routes macOS work.
        self.assertIn("needs.changes.outputs.macos != 'false'", condition)
        self.assertIn("needs.changes.outputs.swift_packages == 'true'", condition)
        for step in self.job["steps"]:
            text = str(step.get("run", ""))
            self.assertNotIn("sleep", text)
            self.assertNotIn("while", text)
        self.assertLessEqual(self.job["timeout-minutes"], 5)

    def test_waits_only_on_linux_jobs(self):
        # `needs:` waits for every listed job, so one Mac lane here would make
        # the cancel wait for the Mac time it is meant to save.
        for name in fail_fast.FAST_LINUX_JOBS:
            with self.subTest(job=name):
                self.assertFalse(runs_on_macos(self.jobs[name]))
                self.assertNotIn("macos", self.jobs[name].get("needs") or [])
        self.assertFalse(runs_on_macos(self.job))

    def test_every_required_linux_job_is_classified(self):
        # A new Linux job under ci-status either joins the fast set or is
        # excluded here with a reason in pr_fail_fast.py.
        required = set(self.jobs["ci-status"]["needs"])
        classified = set(fail_fast.FAST_LINUX_JOBS) | set(fail_fast.NOT_WATCHED)
        self.assertEqual(required - classified, set())
        self.assertEqual(set(fail_fast.FAST_LINUX_JOBS) - required, set())

    def test_least_privilege(self):
        self.assertEqual(self.job["permissions"], {"actions": "write", "contents": "read", "pull-requests": "read"})
        checkout = self.job["steps"][0]
        self.assertIs(checkout["with"]["persist-credentials"], False)
        self.assertEqual(checkout["with"]["sparse-checkout"].split(), ["scripts/ci"])
        # The only job in pull request CI that can write to Actions.
        writers = [name for name, job in self.jobs.items()
                   if (job.get("permissions") or {}).get("actions") == "write"]
        self.assertEqual(writers, [JOB])
        self.assertNotIn("actions: write", CI_WORKFLOW.read_text(encoding="utf-8").split("\njobs:\n", 1)[0])

    def test_cancels_only_its_own_run(self):
        step = self.job["steps"][-1]
        self.assertEqual(step["env"]["CI_RUN_ID"], "${{ github.run_id }}")
        self.assertEqual(step["env"]["CI_RUN_ATTEMPT"], "${{ github.run_attempt }}")
        self.assertEqual(step["run"].strip(), "python3 scripts/ci/pr_fail_fast.py")
        # The janitor's dry-run switch covers this job too.
        self.assertIn("vars.CI_JANITOR_DRY_RUN == 'true'", step["env"]["DRY_RUN"])

    def test_not_a_ci_status_input(self):
        # A failed cancel must not change the verdict ci-status reports.
        self.assertNotIn(JOB, self.jobs["ci-status"]["needs"])
        self.assertNotIn(JOB, self.jobs["tests"]["needs"])


if __name__ == "__main__":
    unittest.main()
