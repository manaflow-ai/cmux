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


class Clock:
    """A monotonic clock that advances on every sleep and on every API call (request time counts)."""

    def __init__(self, per_call: float = 0.0):
        self.now, self.per_call = 1000.0, per_call

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds


class FakeGitHub:
    """Fixture API: run 7 settles after SETTLE_AFTER run reads; rerun POSTs can fail, or be accepted then fail."""

    def __init__(self, jobs: list[dict], settle_after: int = 1, rerun_errors: int = 0, accept_then_error: bool = False,
                 clock: Clock | None = None, runs: dict | None = None, sweeps: list | None = None,
                 artifacts: dict | None = None):
        self.calls: list[tuple[str, str]] = []
        self.job_list, self.settle_after, self.rerun_errors = jobs, settle_after, rerun_errors
        self.accept_then_error, self.clock = accept_then_error, clock
        self.attempt = 1
        self.runs_by_id = runs or {}
        self.sweeps, self.artifacts = sweeps or [], artifacts or {}
        self.timeouts: list[float] = []

    def jobs(self, run_id: int) -> list[dict]:
        self.calls.append(("GET", f"actions/runs/{run_id}/jobs"))
        return self.job_list

    def runs(self, status: str) -> list[dict]:
        return []

    def paged(self, path: str, key: str) -> list[dict]:
        self.calls.append(("GET", path))
        if key == "workflow_runs":
            return self.sweeps
        run_id = int(path.split("/")[2])
        return [{"name": name} for name in self.artifacts.get(run_id, [])]

    def call(self, method: str, path: str, timeout: float = 30):
        self.calls.append((method, path))
        self.timeouts.append(timeout)
        if self.clock:
            self.clock.now += self.clock.per_call
        run_id = int(path.split("/")[2])
        if path.endswith("rerun-failed-jobs"):
            if self.accept_then_error:
                self.accept_then_error = False
                self.attempt += 1
                raise spill.urllib.error.URLError("connection reset after the POST was accepted")
            if self.rerun_errors:
                self.rerun_errors -= 1
                raise spill.urllib.error.URLError("503")
            self.attempt += 1
            return None
        if method == "GET":
            if run_id in self.runs_by_id:
                return {"id": run_id, "run_attempt": self.attempt, **self.runs_by_id[run_id]}
            gets = sum(1 for m, p in self.calls if m == "GET" and p == f"actions/runs/{run_id}")
            settled = gets >= self.settle_after
            return {"status": "completed" if settled or self.attempt > 1 else "in_progress",
                    "run_attempt": self.attempt}
        return None


STUCK = [DONE, job("cmux_next_ daemon tests", minutes=37)]


class Spill(unittest.TestCase):
    def posts(self, github: FakeGitHub) -> list[str]:
        return [path for method, path in github.calls if method == "POST"]

    def spill(self, github: FakeGitHub, settle_seconds: float = 300, clock: Clock | None = None) -> str:
        clock = clock or github.clock or Clock()
        return spill.spill(github, run(id=7), NOW, sleep=clock.sleep, settle_seconds=settle_seconds, clock=clock)

    def test_cancel_then_rerun_failed_jobs(self) -> None:
        github = FakeGitHub(STUCK, settle_after=2)
        self.assertIn("attempt 2", self.spill(github))
        self.assertEqual(self.posts(github), ["actions/runs/7/cancel", "actions/runs/7/rerun-failed-jobs"])

    def test_a_job_that_started_since_the_first_read_keeps_the_run(self) -> None:
        started = [DONE, job("cmux_next_ daemon tests", status="in_progress"), job("x", minutes=37)]
        github = FakeGitHub(started)
        self.assertIn("not cancelled", self.spill(github))
        self.assertEqual(self.posts(github), [])

    def test_a_failed_rerun_is_retried(self) -> None:
        github = FakeGitHub(STUCK, rerun_errors=2)
        self.spill(github)
        self.assertEqual(self.posts(github).count("actions/runs/7/rerun-failed-jobs"), 3)

    def test_an_accepted_rerun_whose_answer_was_lost_is_not_sent_again(self) -> None:
        # GitHub took the POST (attempt 2 started) but the client saw an error: the next read sees attempt 2.
        github = FakeGitHub(STUCK, accept_then_error=True)
        self.assertIn("attempt 2", self.spill(github))
        self.assertEqual(self.posts(github).count("actions/runs/7/rerun-failed-jobs"), 1)

    def test_a_rerun_someone_else_started_is_not_sent_again(self) -> None:
        # cmux-tui-artifacts-retry.yml re-runs a cancelled feat-cmux-next run too; whoever is first wins.
        github = FakeGitHub(STUCK, settle_after=10**6)
        github.attempt = 2
        self.assertIn("attempt 2", self.spill(github))
        self.assertNotIn("actions/runs/7/rerun-failed-jobs", self.posts(github))

    def test_a_cancelled_run_never_rerun_fails_loudly(self) -> None:
        github = FakeGitHub(STUCK, settle_after=10**6)
        with self.assertRaisesRegex(spill.SpillFailed, "gh run rerun 7 --failed") as caught:
            self.spill(github, settle_seconds=30)
        self.assertEqual(caught.exception.run_id, 7)
        self.assertNotIn("actions/runs/7/rerun-failed-jobs", self.posts(github))

    def test_the_settle_deadline_counts_request_time(self) -> None:
        # Every request takes 20 s: counting only the sleeps would allow ~25 reads in 300 s; the deadline allows ~10.
        clock = Clock(per_call=20)
        github = FakeGitHub(STUCK, settle_after=10**6, clock=clock)
        start = clock.now
        with self.assertRaises(spill.SpillFailed):
            self.spill(github, settle_seconds=300, clock=clock)
        self.assertLessEqual(clock.now - start, 300 + 20 + 30)
        self.assertTrue(all(timeout <= 30 for timeout in github.timeouts))

    def test_each_request_is_limited_to_the_remaining_budget(self) -> None:
        clock = Clock(per_call=0)
        github = FakeGitHub(STUCK, settle_after=10**6, clock=clock)
        with self.assertRaises(spill.SpillFailed):
            self.spill(github, settle_seconds=25, clock=clock)
        self.assertTrue(any(timeout < 30 for timeout in github.timeouts))


class Paging(unittest.TestCase):
    def test_every_page_is_read_before_filtering(self) -> None:
        pages = {1: [{"id": n, "run_attempt": 2} for n in range(spill.PER_PAGE)], 2: [{"id": 999, "run_attempt": 1}]}

        class Paged(spill.GitHub):
            def call(self, method, path, timeout=30):
                page = int(path.rsplit("page=", 1)[1])
                return {"total_count": spill.PER_PAGE + 1, "workflow_runs": pages.get(page, [])}

        runs = Paged("t", "o/r").runs("queued")
        self.assertIn(999, [r["id"] for r in runs])
        self.assertEqual(len(runs), spill.PER_PAGE + 1)

    def test_paging_stops_at_a_short_page(self) -> None:
        seen = []

        class Short(spill.GitHub):
            def call(self, method, path, timeout=30):
                seen.append(path)
                return {"total_count": 10**6, "jobs": [{"id": 1}]}

        Short("t", "o/r").jobs(7)
        self.assertEqual(len(seen), 1)


class Recover(unittest.TestCase):
    def test_artifact_names_carry_the_pending_ids(self) -> None:
        self.assertEqual(spill.pending_from("owned-first-spill-pending-7-44464326281"), [7, 44464326281])
        self.assertEqual(spill.pending_from("something-else-7"), [])

    def test_a_run_an_earlier_sweep_could_not_rerun_is_rerun(self) -> None:
        github = FakeGitHub([], runs={7: {"status": "completed", "created_at": at(40)}},
                            sweeps=[{"id": 500, "created_at": at(10)}],
                            artifacts={500: ["owned-first-spill-pending-7"]})
        lines, still = spill.recover(github, spill.pending_runs(github, NOW), NOW, dry_run=False)
        self.assertEqual(still, [])
        self.assertIn("actions/runs/7/rerun-failed-jobs", [p for m, p in github.calls if m == "POST"])
        self.assertIn("recovered", lines[0])

    def test_a_run_already_rerun_is_left_alone(self) -> None:
        github = FakeGitHub([], runs={7: {"status": "in_progress", "created_at": at(40)}})
        github.attempt = 2
        lines, still = spill.recover(github, [7], NOW, dry_run=False)
        self.assertEqual((still, [m for m, _ in github.calls if m == "POST"]), ([], []))
        self.assertIn("already re-run", lines[0])

    def test_an_unsettled_or_refused_rerun_stays_pending(self) -> None:
        unsettled = FakeGitHub([], runs={7: {"status": "in_progress", "created_at": at(40)}})
        self.assertEqual(spill.recover(unsettled, [7], NOW, dry_run=False)[1], [7])
        refused = FakeGitHub([], runs={7: {"status": "completed", "created_at": at(40)}}, rerun_errors=1)
        self.assertEqual(spill.recover(refused, [7], NOW, dry_run=False)[1], [7])

    def test_a_dry_run_recovers_nothing(self) -> None:
        github = FakeGitHub([], runs={7: {"status": "completed", "created_at": at(40)}})
        spill.recover(github, [7], NOW, dry_run=True)
        self.assertEqual([m for m, _ in github.calls if m == "POST"], [])

    def test_a_run_too_old_is_given_up_with_the_manual_command(self) -> None:
        github = FakeGitHub([], runs={7: {"status": "completed", "created_at": at(60 * 30)}})
        lines, still = spill.recover(github, [7], NOW, dry_run=False)
        self.assertEqual(still, [])
        self.assertIn("gh run rerun 7 --failed", lines[0])


class Main(unittest.TestCase):
    def test_a_pending_rerun_fails_the_sweep_and_is_handed_on(self) -> None:
        import tempfile

        github = FakeGitHub([], runs={7: {"status": "in_progress", "created_at": at(40)}},
                            sweeps=[{"id": 500, "created_at": at(10)}],
                            artifacts={500: ["owned-first-spill-pending-7"]})
        with tempfile.TemporaryDirectory() as tmp:
            output, pending = Path(tmp, "out"), Path(tmp, "pending.json")
            env = {"GITHUB_OUTPUT": str(output), "PENDING_FILE": str(pending)}
            self.assertEqual(spill.main(env, NOW, github), 1)
            self.assertIn("pending=7", output.read_text())
            self.assertIn("7", pending.read_text())

    def test_a_quiet_sweep_succeeds_with_nothing_pending(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp, "out")
            self.assertEqual(spill.main({"GITHUB_OUTPUT": str(output)}, NOW, FakeGitHub([])), 0)
            self.assertEqual(output.read_text(), "pending=\n")


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
        upload = steps["Hand pending re-runs to the next sweep"]
        self.assertEqual(upload["with"]["name"], spill.PENDING_ARTIFACT + "${{ steps.spill.outputs.pending }}")
        self.assertEqual(upload["with"]["path"], run_step["env"]["PENDING_FILE"])
        self.assertIn("always()", upload["if"])


if __name__ == "__main__":
    unittest.main()
