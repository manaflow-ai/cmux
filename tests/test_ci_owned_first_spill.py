#!/usr/bin/env python3
"""Policy tests for scripts/ci/owned_first_spill.py over fixture runs and jobs (no network)."""

from __future__ import annotations

import datetime as dt
import importlib.util
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/owned_first_spill.py"
WORKFLOW = ROOT / ".github/workflows/ci-owned-first-spill.yml"
SPEC = importlib.util.spec_from_file_location("owned_first_spill", SCRIPT)
spill = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules["owned_first_spill"] = spill
SPEC.loader.exec_module(spill)

NOW = dt.datetime(2026, 11, 19, 6, 0, tzinfo=dt.timezone.utc)


def at(minutes_ago: float) -> str:
    return (NOW - dt.timedelta(minutes=minutes_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")


def run(**overrides) -> dict:
    return {"id": 44464326281, "run_attempt": 1, "event": "push", "head_branch": "feat-cmux-next",
            "status": "in_progress", **overrides}


def job(name: str, status: str = "queued", labels=("cmux-gcp-lane-build-x64",), minutes: float = 30) -> dict:
    return {"name": name, "status": status, "labels": list(labels), "created_at": at(minutes)}


DONE = job("cmux-tui tree preflight", status="completed", minutes=60)


class Decide(unittest.TestCase):
    def test_a_job_queued_on_an_owned_label_past_the_bound_spills(self) -> None:
        verdict = spill.decide(run(), [DONE, job("cmux_next_ daemon tests", minutes=37)], NOW)
        self.assertEqual(verdict[0], "spill")
        self.assertIn("cmux_next_ daemon tests queued 37 min on cmux-gcp-lane-build-x64", verdict[1])

    def test_within_the_bound_it_waits_its_turn(self) -> None:
        self.assertIsNone(spill.decide(run(), [DONE, job("cmux_next_ daemon tests", minutes=5)], NOW))

    def test_a_running_job_is_never_cancelled(self) -> None:
        # A publish of immutable objects must never stop mid-upload: the run waits for the next sweep.
        publishing = job("publish tree-addressed cmux-tui", status="in_progress", labels=("blacksmith-4vcpu-ubuntu-2404",))
        verdict = spill.decide(run(), [DONE, publishing, job("cmux_next_ daemon tests", minutes=80)], NOW)
        self.assertEqual(verdict[0], "wait")
        self.assertIn("publish tree-addressed cmux-tui", verdict[1])

    def test_a_job_queued_on_blacksmith_is_not_this_sweeps(self) -> None:
        # Attempt 2+ is the spill route itself; it is never moved again.
        queued = job("cmux_next_ daemon tests", labels=("blacksmith-16vcpu-ubuntu-2404",), minutes=90)
        self.assertIsNone(spill.decide(run(), [DONE, queued], NOW))

    def test_only_attempt_one_of_the_nightly_path_moves(self) -> None:
        stuck = [DONE, job("cmux_next_ daemon tests", minutes=90)]
        self.assertIsNone(spill.decide(run(run_attempt=2), stuck, NOW))
        self.assertIsNone(spill.decide(run(head_branch="lane/x"), stuck, NOW))
        self.assertIsNone(spill.decide(run(status="completed"), stuck, NOW))
        for moved in (run(event="workflow_dispatch"), run(head_branch="nightly-next")):
            with self.subTest(run=moved):
                self.assertEqual(spill.decide(moved, stuck, NOW)[0], "spill")

    def test_every_owned_label_counts(self) -> None:
        for label in spill.OWNED_LABELS:
            with self.subTest(label=label):
                self.assertEqual(spill.decide(run(), [job("x", labels=(label,), minutes=25)], NOW)[0], "spill")


class FakeGitHub:
    def __init__(self, jobs: list[dict], settle_after: int = 1, rerun_errors: int = 0):
        self.calls: list[tuple[str, str]] = []
        self.job_list, self.settle_after, self.rerun_errors = jobs, settle_after, rerun_errors

    def jobs(self, run_id: int) -> list[dict]:
        self.calls.append(("GET", f"actions/runs/{run_id}/jobs"))
        return self.job_list

    def call(self, method: str, path: str):
        self.calls.append((method, path))
        if path.endswith("rerun-failed-jobs") and self.rerun_errors:
            self.rerun_errors -= 1
            raise spill.urllib.error.URLError("503")
        if method == "GET":
            gets = sum(1 for m, p in self.calls if m == "GET" and not p.endswith("/jobs"))
            return {"status": "completed" if gets >= self.settle_after else "in_progress"}
        return None


STUCK = [DONE, job("cmux_next_ daemon tests", minutes=37)]


class Spill(unittest.TestCase):
    def posts(self, github: FakeGitHub) -> list[str]:
        return [path for method, path in github.calls if method == "POST"]

    def test_cancel_then_rerun_failed_jobs(self) -> None:
        github = FakeGitHub(STUCK, settle_after=2)
        self.assertIn("attempt 2", spill.spill(github, run(id=7), NOW, sleep=lambda _: None))
        self.assertEqual(self.posts(github), ["actions/runs/7/cancel", "actions/runs/7/rerun-failed-jobs"])

    def test_a_job_that_started_since_the_first_read_keeps_the_run(self) -> None:
        started = [DONE, job("cmux_next_ daemon tests", status="in_progress"), job("x", minutes=37)]
        github = FakeGitHub(started)
        self.assertIn("not cancelled", spill.spill(github, run(id=7), NOW, sleep=lambda _: None))
        self.assertEqual(self.posts(github), [])

    def test_a_failed_rerun_is_retried(self) -> None:
        github = FakeGitHub(STUCK, rerun_errors=2)
        spill.spill(github, run(id=7), NOW, sleep=lambda _: None)
        self.assertEqual(self.posts(github).count("actions/runs/7/rerun-failed-jobs"), 3)

    def test_a_cancelled_run_never_rerun_fails_loudly(self) -> None:
        github = FakeGitHub(STUCK, settle_after=10**6)
        with self.assertRaisesRegex(spill.SpillFailed, "gh run rerun 7 --failed"):
            spill.spill(github, run(id=7), NOW, sleep=lambda _: None, settle_seconds=30)
        self.assertNotIn("actions/runs/7/rerun-failed-jobs", self.posts(github))


class Workflow(unittest.TestCase):
    def test_it_runs_the_script_keyless_from_main(self) -> None:
        document = yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
        job = document["jobs"]["spill"]
        self.assertEqual(job["permissions"], {"actions": "write", "contents": "read"})
        steps = {step.get("name"): step for step in job["steps"]}
        self.assertEqual(steps["Checkout trusted spill"]["with"]["ref"], "main")
        self.assertIn("create-github-app-token", steps["Mint the cmux-bot token"]["uses"])
        run_step = steps["Spill owned-first jobs queued past the bound"]
        self.assertEqual(run_step["run"], "python3 scripts/ci/owned_first_spill.py")
        self.assertIn("cmux-bot-token.outputs.token || github.token", run_step["env"]["GH_TOKEN"])
        self.assertEqual(document["concurrency"]["cancel-in-progress"], "false")


if __name__ == "__main__":
    unittest.main()
