#!/usr/bin/env python3
"""A push to a pull request cancels its runs on older heads at once, and nothing else.

scripts/ci/cancel_superseded_pr_runs.py verdict() and .github/workflows/ci-pr-superseded-cancel.yml.
Run: python3 tests/test_cancel_superseded_pr_runs.py
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import cancel_superseded_pr_runs as c  # noqa: E402

REPO = "manaflow-ai/cmux"
BRANCH = "lane/x"
HEAD = "b" * 40
OLD = "a" * 40
WORKFLOW = ROOT / ".github/workflows/ci-pr-superseded-cancel.yml"


def run(**over):
    base = {"id": 1, "status": "in_progress", "head_sha": OLD, "run_attempt": 1, "event": "pull_request",
            "head_repository": {"full_name": REPO}, "head_branch": BRANCH,
            "path": ".github/workflows/pr-router.yml", "name": "pr router"}
    base.update(over)
    return base


def verdict(**over):
    return c.verdict(run(**over), REPO, BRANCH, HEAD, self_run_id=99)


class Verdict(unittest.TestCase):
    def test_running_and_queued_runs_on_an_older_head_are_cancelled(self):
        for status in c.ACTIVE:
            self.assertEqual(verdict(status=status), "cancel", status)
        for event in ("pull_request", "pull_request_target", "push", "workflow_run"):
            self.assertEqual(verdict(event=event), "cancel", event)

    def test_the_pushed_head_is_never_cancelled(self):
        self.assertEqual(verdict(head_sha=HEAD), "keep:head")
        self.assertEqual(verdict(head_sha=""), "keep:head")
        self.assertEqual(c.verdict(run(), REPO, BRANCH, ""), "keep:head")

    def test_what_is_kept(self):
        self.assertEqual(verdict(status="completed"), "keep:status-completed")
        self.assertEqual(verdict(run_attempt=2), "keep:attempt")
        self.assertEqual(verdict(event="workflow_dispatch"), "keep:event-workflow_dispatch")
        self.assertEqual(verdict(event="schedule"), "keep:event-schedule")
        self.assertEqual(verdict(head_repository={"full_name": "someone/cmux"}), "keep:fork")
        self.assertEqual(verdict(head_branch="lane/other"), "keep:branch")
        self.assertEqual(c.verdict(run(head_branch="main"), REPO, "main", HEAD), "keep:branch")
        self.assertEqual(verdict(id=99), "keep:self")
        self.assertEqual(verdict(path=c.SELF_PATH), "keep:workflow")
        for path in c.KEEP_PATHS:
            self.assertEqual(verdict(path=path), "keep:workflow", path)
        self.assertEqual(verdict(name="cmux nightly build", path=".github/workflows/x.yml"), "keep:protected-workflow")
        self.assertEqual(verdict(path=".github/workflows/backend-deploy.yml", name="b"), "keep:protected-workflow")

    def test_keep_paths_match_the_superseded_allowlist(self):
        sys.path.insert(0, str(ROOT / "tests"))
        import test_ci_pr_runs_cancel_superseded as allowed  # noqa: PLC0415
        # A workflow allowed to keep its superseded pull request runs keeps them here too.
        self.assertLessEqual(set(allowed.ALLOWED), {p.rsplit("/", 1)[1] for p in c.KEEP_PATHS})


class Workflow(unittest.TestCase):
    def test_runs_on_every_push_of_a_same_repo_pr_and_can_cancel(self):
        doc = yaml.load(WORKFLOW.read_text(), Loader=yaml.BaseLoader)
        self.assertEqual(doc["on"], {"pull_request": {"types": ["synchronize"]}})
        job = doc["jobs"]["cancel"]
        self.assertIn("github.event.pull_request.head.repo.full_name == github.repository", job["if"])
        self.assertIn("no-janitor", job["if"])
        self.assertEqual(job["permissions"], {"actions": "write", "contents": "read"})
        self.assertLessEqual(int(job["timeout-minutes"]), 5)
        step = job["steps"][-1]
        self.assertEqual(step["run"], "python3 scripts/ci/cancel_superseded_pr_runs.py")
        self.assertEqual(step["env"]["PR_HEAD_SHA"], "${{ github.event.pull_request.head.sha }}")
        sparse = job["steps"][0]["with"]["sparse-checkout"].split()
        for name in ("cancel_superseded_pr_runs.py", "shed_superseded_runs.py", "deadline_http.py"):
            self.assertIn(f"scripts/ci/{name}", sparse)


if __name__ == "__main__":
    unittest.main()
