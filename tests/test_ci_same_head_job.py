#!/usr/bin/env python3
"""scripts/ci/same_head_job.py: a workflow's own job skips at a head where it already passed, and runs otherwise."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import same_head_job  # noqa: E402

SHA = "a" * 40
JOB = "cmux-next App Store shelf (every listing installs and shows something)"
WF = "cmux-next-guards.yml"


def event(labels=(), action="reopened", fork=False):
    repo = {"full_name": "manaflow-ai/cmux"}
    return {"action": action, "pull_request": {
        "head": {"sha": SHA, "repo": {"full_name": "someone/cmux"} if fork else repo},
        "base": {"ref": "feat-cmux-next", "repo": repo},
        "labels": [{"name": n} for n in labels]}}


def job(conclusion="success", seconds=600, name=JOB, status="completed"):
    return {"name": name, "status": status, "conclusion": conclusion,
            "started_at": "2026-11-28T00:00:00Z", "completed_at": f"2026-11-28T00:{seconds // 60:02d}:{seconds % 60:02d}Z"}


def run(i):
    return {"id": i, "path": f".github/workflows/{WF}@refs/pull/1/merge", "created_at": "2026-11-28T00:00:00Z"}


def decide(ev, jobs_by_run, runs=None, moved=False, switch="1", current="99"):
    runs = runs if runs is not None else [run(i) for i in jobs_by_run]
    return same_head_job.decide(ev, JOB, WF, current, "manaflow-ai/cmux", "tok", switch,
                                runs_reader=lambda *a: runs,
                                jobs_reader=lambda r, *a: jobs_by_run.get(r["id"]),
                                moved=lambda *a: moved)


class SameHeadJobTests(unittest.TestCase):
    def test_skips_after_a_long_green_at_this_head(self):
        self.assertTrue(decide(event(), {5: [job()]})[0])

    def test_runs_after_a_red(self):
        self.assertFalse(decide(event(), {5: [job("failure")]})[0])

    def test_short_green_defers_to_older_run(self):
        self.assertTrue(decide(event(), {6: [job(seconds=20)], 5: [job()]})[0])
        self.assertFalse(decide(event(), {6: [job(seconds=20)], 5: [job("cancelled")]})[0])
        self.assertFalse(decide(event(), {6: [job(seconds=20)]})[0])

    def test_newest_run_decides(self):
        self.assertFalse(decide(event(), {6: [job("failure")], 5: [job()]})[0])

    def test_workflow_moved_or_unread_runs(self):
        self.assertFalse(decide(event(), {5: [job()]}, moved=True)[0])
        self.assertFalse(decide(event(), {5: [job()]}, moved=None)[0])

    def test_opt_outs_and_forks_run(self):
        self.assertFalse(decide(event(labels=["full-ci"]), {5: [job()]})[0])
        self.assertFalse(decide(event(), {5: [job()]}, switch="0")[0])
        self.assertFalse(decide(event(fork=True), {5: [job()]})[0])

    def test_unread_runs_or_jobs_run(self):
        self.assertFalse(decide(event(), {}, runs=[])[0])
        self.assertFalse(same_head_job.decide(event(), JOB, WF, "99", "manaflow-ai/cmux", "tok",
                                              runs_reader=lambda *a: None, jobs_reader=lambda *a: None,
                                              moved=lambda *a: False)[0])
        self.assertFalse(decide(event(), {5: None})[0])

    def test_current_run_and_other_workflows_ignored(self):
        self.assertFalse(decide(event(), {99: [job()]})[0])
        other = [{"id": 5, "path": ".github/workflows/ci.yml@x", "created_at": "2026-11-28T00:00:00Z"}]
        self.assertFalse(decide(event(), {5: [job()]}, runs=other)[0])


if __name__ == "__main__":
    unittest.main()
