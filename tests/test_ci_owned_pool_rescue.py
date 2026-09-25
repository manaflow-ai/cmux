#!/usr/bin/env python3
"""Tests for scripts/ci/owned_pool_rescue.py and ci-owned-pool-rescue.yml (no network)."""

from __future__ import annotations

import datetime as dt
import importlib.util
import io
import json
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


rescue = load("owned_pool_rescue", ROOT / "scripts/ci/owned_pool_rescue.py")

MINI = "glaeda-std-xcode-26.6"
BLACKSMITH = "blacksmith-6vcpu-macos-26"
START = dt.datetime(2026, 9, 24, 12, 0, tzinfo=dt.timezone.utc)
RUN_ID = 555
HEAD = "a" * 40


def stamp(seconds: float) -> str:
    return (START + dt.timedelta(seconds=seconds)).strftime("%Y-%m-%dT%H:%M:%SZ")


def job(name, *, status="queued", labels=(), created=0, runner=""):
    return {"name": name, "status": status, "labels": list(labels), "created_at": stamp(created),
            "runner_name": runner}


class Clock:
    def __init__(self):
        self.seconds = 0.0

    def now(self):
        return START + dt.timedelta(seconds=self.seconds)

    def sleep(self, seconds):
        self.seconds += seconds


class FakeAPI:
    """Jobs come from a function of elapsed seconds; every call is recorded."""

    def __init__(self, clock, jobs, *, marker=False, head=HEAD, state="open", settles_after=10,
                 attempt_after_cancel=1, finished=lambda seconds: False, rerun_jobs=None):
        self.clock, self.jobs_at, self.marker = clock, jobs, marker
        # Jobs of attempt 2 onwards, as a function of seconds since that attempt began.
        self.rerun_jobs = rerun_jobs or (lambda seconds: [job("macos / tests", status="completed",
                                                              labels=[BLACKSMITH])])
        self.attempt, self.rerun_at = 1, 0.0
        self.head, self.state = head, state
        self.settles_after, self.attempt_after_cancel = settles_after, attempt_after_cancel
        self.finished = finished
        self.calls: list[str] = []
        self.cancelled_at: float | None = None

    def run(self, run_id):
        self.calls.append("run")
        if self.cancelled_at is not None:
            done = self.clock.seconds - self.cancelled_at >= self.settles_after
            # attempt_after_cancel above 1: someone else re-ran it meanwhile.
            return {"status": "completed" if done else "in_progress",
                    "run_attempt": max(self.attempt, self.attempt_after_cancel) if done else self.attempt}
        if self.attempt > 1:
            jobs = self.rerun_jobs(self.clock.seconds - self.rerun_at)
            done = bool(jobs) and all(found.get("status") == "completed" for found in jobs)
            return {"status": "completed" if done else "in_progress", "run_attempt": self.attempt}
        return {"status": "completed" if self.finished(self.clock.seconds) else "in_progress", "run_attempt": 1}

    def jobs(self, run_id, attempt):
        self.calls.append("jobs" if attempt == 1 else f"jobs:{attempt}")
        if attempt > 1:
            return self.rerun_jobs(self.clock.seconds - self.rerun_at)
        return self.jobs_at(self.clock.seconds)

    def has_artifact(self, run_id, name):
        self.calls.append(f"artifact:{name}")
        return self.marker

    def pull(self, number):
        self.calls.append("pull")
        return {"state": self.state, "head": {"sha": self.head}}

    def cancel(self, run_id):
        self.calls.append("cancel")
        self.cancelled_at = self.clock.seconds

    def force_cancel(self, run_id):
        self.calls.append("force-cancel")

    def rerun(self, run_id):
        self.calls.append("rerun")

    def rerun_failed(self, run_id):
        self.calls.append("rerun-failed")
        self.attempt += 1
        self.cancelled_at, self.rerun_at = None, self.clock.seconds


def event(**overrides):
    run = {"id": RUN_ID, "path": ".github/workflows/ci.yml", "event": "pull_request", "run_attempt": 1,
           "head_sha": HEAD, "head_repository": {"full_name": "manaflow-ai/cmux"},
           "pull_requests": [{"number": 42}]}
    run.update(overrides)
    return {"workflow_run": run}


def run_main(api, clock, *, env_extra=None, payload=None):
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp, "event.json")
        path.write_text(json.dumps(payload or event()))
        summary = Path(tmp, "summary")
        env = {"GITHUB_REPOSITORY": "manaflow-ai/cmux", "GITHUB_EVENT_PATH": str(path),
               "GITHUB_STEP_SUMMARY": str(summary), "POOL_OWNED": "1", **(env_extra or {})}
        with unittest.mock.patch("sys.stdout", io.StringIO()):
            code = rescue.main([], env, api=api, now=clock.now, sleep=clock.sleep)
        return code, summary.read_text() if summary.exists() else ""


def changes(done_at=30):
    return lambda seconds: job("changes", status="completed" if seconds >= done_at else "in_progress")


def persistent_run(*, compile_started_at=None, queued_at=40, done_at=None):
    def jobs(seconds):
        found = [changes()(seconds)]
        if seconds >= queued_at:
            started = compile_started_at is not None and seconds >= compile_started_at
            finished = done_at is not None and seconds >= done_at
            found.append(job("macos / macOS compile admission", labels=[MINI], created=queued_at,
                             status="completed" if finished else ("in_progress" if started else "queued"),
                             runner="mini-1" if started else ""))
        return found
    return jobs


def refused_job(name="macos / macOS compile admission", *, seconds=8, steps=None, labels=(MINI,)):
    found = job(name, status="completed", labels=labels, created=40, runner="mini-1")
    found.update(conclusion="failure", started_at=stamp(41), completed_at=stamp(41 + seconds),
                 steps=[{"name": "Set up job", "conclusion": "failure"}] if steps is None else steps)
    return found


def refusing_run(refused_at=60, **kwargs):
    def jobs(seconds):
        found = [changes()(seconds)]
        if seconds >= refused_at:
            found.append(refused_job(**kwargs))
        elif seconds >= 40:
            found.append(job("macos / macOS compile admission", labels=[MINI], created=40))
        return found
    return jobs


class Refusal(unittest.TestCase):
    def test_what_counts_as_a_refusal(self):
        self.assertTrue(rescue.refused(refused_job()))
        self.assertTrue(rescue.refused(refused_job(steps=[])))
        self.assertTrue(rescue.refused(refused_job(steps=[{"name": "Set up job", "conclusion": "success"},
                                                          {"name": "Runner hook", "conclusion": "failure"}])))
        # glaeda's hook fails "Set up runner"; `always()` steps still run and succeed
        # (run 36070154108, job 107869588013 on 2026-09-24).
        self.assertTrue(rescue.refused(refused_job(steps=[
            {"name": "Set up job", "conclusion": "success"},
            {"name": "Set up runner", "conclusion": "failure"},
            {"name": "Checkout", "conclusion": "skipped"},
            {"name": "Record compiled-product reuse metrics", "conclusion": "success"},
            {"name": "Record compile admission metrics", "conclusion": "failure"},
            {"name": "Report evidence collection outcomes", "conclusion": "success"},
            {"name": "Complete runner", "conclusion": "success"},
            {"name": "Complete job", "conclusion": "success"}])))
        # A step of the workflow ran, the job ran too long, it is not on an owned pool, or it did not fail.
        self.assertFalse(rescue.refused(refused_job(steps=[{"name": "Set up job", "conclusion": "success"},
                                                           {"name": "Checkout", "conclusion": "success"},
                                                           {"name": "Build", "conclusion": "failure"}])))
        self.assertFalse(rescue.refused(refused_job(seconds=rescue.REFUSAL_SECONDS + 1)))
        self.assertFalse(rescue.refused(refused_job(labels=(BLACKSMITH,))))
        self.assertFalse(rescue.refused({**refused_job(), "conclusion": "cancelled"}))

    def test_a_refused_job_reruns_the_failed_jobs_after_cancelling(self):
        clock = Clock()
        api = FakeAPI(clock, refusing_run(), marker=True)
        code, summary = run_main(api, clock)
        self.assertEqual(code, 0)
        rerun = api.calls.index("rerun-failed")
        self.assertEqual(api.calls[rerun - 3:rerun + 1], ["cancel", "run", "pull", "rerun-failed"])
        # Then it follows attempt 2, which here took no owned job.
        self.assertEqual(api.calls[rerun + 1:], ["jobs:2"])
        self.assertIn("no job of this attempt asked for a persistent pool", summary)
        self.assertNotIn("rerun", api.calls)
        self.assertIn(f"refused by {MINI} at job start", summary)
        self.assertIn("attempt 2 takes the owned pool once more", summary)

    def test_a_finished_run_with_a_refusal_needs_no_cancel(self):
        clock = Clock()
        api = FakeAPI(clock, refusing_run(), marker=True, finished=lambda seconds: seconds >= 60)
        _, summary = run_main(api, clock)
        self.assertNotIn("cancel", api.calls)
        self.assertEqual(api.calls[-2:], ["rerun-failed", "jobs:2"])
        self.assertIn("re-ran the failed jobs", summary)

    def test_a_refused_retry_on_the_fleet_goes_to_blacksmith_next(self):
        # Attempt 2 takes the owned pool once more and is refused again: its
        # failed jobs are re-run, and attempt 3 is never watched or owned.
        clock = Clock()
        api = FakeAPI(clock, refusing_run(), marker=True, finished=lambda seconds: seconds >= 60,
                      rerun_jobs=lambda seconds: [refused_job()] if seconds >= 30 else
                      [job("macos / macOS compile admission", labels=[MINI], created=0)])
        _, summary = run_main(api, clock)
        self.assertEqual(api.calls.count("rerun-failed"), 2)
        self.assertNotIn("jobs:3", api.calls)
        self.assertIn("attempt 2 takes the owned pool once more", summary)
        self.assertIn("attempt 3 takes retry_runner on Blacksmith", summary)

    def test_a_retry_the_fleet_accepts_ends_the_watch(self):
        clock = Clock()
        running = job("macos / macOS compile admission", labels=[MINI], created=0, status="in_progress",
                      runner="mini-2")
        running["started_at"] = stamp(0)
        api = FakeAPI(clock, refusing_run(), marker=True, finished=lambda seconds: seconds >= 60,
                      rerun_jobs=lambda seconds: [running])
        _, summary = run_main(api, clock)
        self.assertEqual(api.calls.count("rerun-failed"), 1)
        # It stops once the job outlives the refusal window, not at the end of the run.
        self.assertIn("stopped watching attempt 2: the fleet accepted the retry", summary)
        self.assertLess(api.calls.count("jobs:2"), 20)

    def test_a_retry_stuck_on_a_busy_fleet_moves_to_blacksmith_keeping_what_passed(self):
        clock = Clock()
        api = FakeAPI(clock, refusing_run(), marker=True, finished=lambda seconds: seconds >= 60,
                      rerun_jobs=lambda seconds: [job("macos / macOS compile admission", labels=[MINI], created=0)])
        _, summary = run_main(api, clock)
        self.assertEqual(api.calls.count("rerun-failed"), 2)
        self.assertNotIn("rerun", api.calls)
        self.assertIn("queued on", summary)

    def test_an_attempt_2_with_no_owned_job_ends_the_watch_at_its_first_look(self):
        # Before routing sends retries to the fleet, attempt 2 runs on
        # Blacksmith; the watch must not poll it until it finishes.
        clock = Clock()
        still_running = [job("macos / tests", status="in_progress", labels=[BLACKSMITH], runner="bs-1")]
        api = FakeAPI(clock, refusing_run(), marker=True, finished=lambda seconds: seconds >= 60,
                      rerun_jobs=lambda seconds: still_running)
        _, summary = run_main(api, clock)
        self.assertEqual(api.calls.count("jobs:2"), 1)
        self.assertIn("no job of this attempt asked for a persistent pool", summary)

    def test_one_deadline_covers_both_attempts(self):
        # A refusal found near the end of the watch is left alone rather than
        # cancelled by a job that may be killed before it can re-run.
        late = rescue.WATCH_LIMIT_SECONDS - 150

        def jobs(seconds):
            found = [changes()(seconds)]
            if seconds >= late:
                # A later job of the run, refused at start near the deadline.
                found.append(refused_job("macos / cli-product-tests"))
            if seconds >= 40:
                found.append(job("macos / macOS compile admission", labels=[MINI], created=40,
                                 status="in_progress", runner="mini-1"))
            return found

        clock = Clock()
        api = FakeAPI(clock, jobs, marker=True)
        _, summary = run_main(api, clock)
        self.assertNotIn("cancel", api.calls)
        self.assertNotIn("rerun-failed", api.calls)
        self.assertIn("too little of the watch left", summary)
        # And attempt 2 inherits what is left, not a fresh hour.
        clock = Clock()
        waiting = [job("macos / macOS compile admission", labels=[MINI], created=0, status="in_progress",
                       runner="mini-1")]
        api = FakeAPI(clock, refusing_run(refused_at=600), marker=True, finished=lambda seconds: seconds >= 610,
                      rerun_jobs=lambda seconds: waiting)
        run_main(api, clock)
        self.assertLessEqual(clock.seconds, rescue.WATCH_LIMIT_SECONDS + rescue.IDLE_POLL_SECONDS + 60)

    def test_a_refusal_on_a_moved_head_is_left_alone(self):
        clock = Clock()
        api = FakeAPI(clock, refusing_run(), marker=True, head="b" * 40)
        _, summary = run_main(api, clock)
        self.assertNotIn("rerun-failed", api.calls)
        self.assertIn("not rescued", summary)


class Scope(unittest.TestCase):
    def test_owned_pools_off_makes_no_request(self):
        for value in ("", "0"):
            clock = Clock()
            api = FakeAPI(clock, persistent_run())
            code, summary = run_main(api, clock, env_extra={"POOL_OWNED": value})
            self.assertEqual((code, api.calls), (0, []), value)
            self.assertIn("owned pools are off", summary)

    def test_invalid_budget_watches_nothing(self):
        for value in ("abc", "10", "601"):
            clock = Clock()
            api = FakeAPI(clock, persistent_run())
            code, summary = run_main(api, clock, env_extra={"RESCUE_SECONDS": value})
            self.assertEqual((code, api.calls), (0, []), value)
            self.assertIn("must be 30 to 600", summary)

    def test_budget_defaults_to_90(self):
        self.assertEqual(rescue.budget(""), 90)
        self.assertEqual(rescue.budget(" 120 "), 120)

    def test_only_attempt_1_of_a_same_repository_ci_pull_request(self):
        cases = {
            "not .github/workflows/ci.yml": event(path=".github/workflows/other.yml"),
            "not a pull request": event(event="push"),
            "fork head": event(head_repository={"full_name": "someone/cmux"}),
            "attempt 2": event(run_attempt=2),
            "exactly one pull request": event(pull_requests=[]),
        }
        for why, payload in cases.items():
            target = rescue.target_from_event(payload, "manaflow-ai/cmux")
            self.assertIsInstance(target, str, why)
        target = rescue.target_from_event(event(), "manaflow-ai/cmux")
        self.assertEqual((target.run_id, target.pr_number, target.head_sha), (RUN_ID, 42, HEAD))

    def test_only_owned_pool_labels_count(self):
        self.assertEqual(rescue.job_pool(job("x", labels=["self-hosted", MINI])), MINI)
        for labels in ([BLACKSMITH], ["ubuntu-24.04"], ["glaeda-mini"]):
            self.assertIsNone(rescue.job_pool(job("x", labels=labels)), labels)


def blacksmith_admission(*, done_at):
    def at(seconds):
        found = job("macos / macOS compile admission", labels=[BLACKSMITH], created=40, runner="bs-1",
                    status="completed" if seconds >= done_at else "in_progress")
        found["conclusion"] = "success" if seconds >= done_at else None
        return found
    return at


class Watching(unittest.TestCase):
    def test_ephemeral_run_stops_once_admission_placed_nothing_owned(self):
        clock = Clock()

        def jobs(seconds):
            found = [changes()(seconds), blacksmith_admission(done_at=300)(seconds)]
            if seconds >= 300:
                found.append(job("macos / app-host unit tests (1/7)", labels=[BLACKSMITH], created=300))
            return found
        api = FakeAPI(clock, jobs)
        code, summary = run_main(api, clock)
        self.assertEqual(code, 0)
        # One marker check, slow looks while admission compiles, one look after it.
        self.assertEqual(sum(call.startswith("artifact:") for call in api.calls), 1)
        self.assertLessEqual(api.calls.count("jobs"), 6)
        self.assertIn("the run is on an ephemeral pool", summary)
        self.assertNotIn("cancel", api.calls)

    def test_a_run_without_a_macos_lane_stops_when_it_is_skipped(self):
        clock = Clock()
        api = FakeAPI(clock, lambda s: [changes()(s), {**job("macos", status="completed"), "conclusion": "skipped"},
                                        job("web / Web tests (1/4)", status="in_progress")])
        code, summary = run_main(api, clock)
        self.assertEqual(code, 0)
        self.assertEqual(api.calls.count("jobs"), 1)
        self.assertIn("the run has no macOS lane", summary)

    def test_waits_for_consumers_that_are_created_late(self):
        clock = Clock()

        def jobs(seconds):
            found = [changes()(seconds), blacksmith_admission(done_at=300)(seconds)]
            if seconds >= 350:
                found.append(job("macos / app-host unit tests (2/7)", labels=[MINI], created=350))
            return found
        api = FakeAPI(clock, jobs)
        run_main(api, clock)
        self.assertIn("rerun-failed", api.calls)
        self.assertNotIn("rerun", api.calls)

    def test_a_consumer_placed_on_a_busy_mini_after_a_blacksmith_admission_is_moved(self):
        clock = Clock()

        def jobs(seconds):
            found = [changes()(seconds), blacksmith_admission(done_at=300)(seconds)]
            if seconds >= 300:
                found.append(job("macos / app-host unit tests (3/7)", labels=[MINI], created=300))
            return found
        api = FakeAPI(clock, jobs)
        code, summary = run_main(api, clock)
        self.assertEqual(code, 0)
        # Cancelled, then only the failed and cancelled jobs re-run (the
        # watch then follows attempt 2).
        self.assertLess(api.calls.index("cancel"), api.calls.index("rerun-failed"))
        self.assertNotIn("rerun", api.calls)
        self.assertIn("consumers:", summary)
        self.assertIn("re-ran the failed jobs of run", summary)

    def test_a_stuck_consumer_keeps_an_owned_admissions_product(self):
        clock = Clock()

        def jobs(seconds):
            found = persistent_run(compile_started_at=45, done_at=200)(seconds)
            found[-1]["conclusion"] = "success" if seconds >= 200 else None
            if seconds >= 200:
                found.append(job("macos / cli-product-tests", labels=[MINI], created=200))
            return found
        api = FakeAPI(clock, jobs, marker=True)
        run_main(api, clock)
        # Cancelled, then only the failed and cancelled jobs re-run (the
        # watch then follows attempt 2).
        self.assertLess(api.calls.index("cancel"), api.calls.index("rerun-failed"))
        self.assertNotIn("rerun", api.calls)

    def test_waits_for_the_picker_before_looking_for_the_marker(self):
        clock = Clock()
        api = FakeAPI(clock, lambda s: [changes(done_at=100)(s)])
        run_main(api, clock)
        self.assertEqual(api.calls.count("jobs"), 4)  # 45, 65, 85, 105 seconds
        self.assertEqual(sum(call.startswith("artifact:") for call in api.calls), 1)

    def test_persistent_run_that_starts_in_time_is_left_alone(self):
        clock = Clock()
        api = FakeAPI(clock, persistent_run(compile_started_at=100, done_at=600), marker=True,
                      finished=lambda s: s >= 600)
        code, summary = run_main(api, clock)
        self.assertEqual(code, 0)
        self.assertNotIn("cancel", api.calls)
        self.assertNotIn("rerun", api.calls)
        self.assertIn("the run finished", summary)

    def test_polls_slowly_once_nothing_waits(self):
        clock = Clock()
        api = FakeAPI(clock, persistent_run(compile_started_at=50, done_at=20 * 60), marker=True,
                      finished=lambda s: s >= 20 * 60)
        run_main(api, clock)
        # 45 s first look, then one-minute looks until the run is done.
        self.assertLessEqual(api.calls.count("jobs"), 22)

    def test_watch_limit(self):
        clock = Clock()
        api = FakeAPI(clock, persistent_run(compile_started_at=50), marker=True)
        code, summary = run_main(api, clock)
        self.assertEqual(code, 0)
        self.assertIn("watch limit reached", summary)
        self.assertNotIn("cancel", api.calls)


class Rescuing(unittest.TestCase):
    def test_a_job_waiting_past_the_budget_reruns_the_run(self):
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True)
        code, summary = run_main(api, clock)
        self.assertEqual(code, 0)
        self.assertEqual(api.calls[-4:], ["cancel", "run", "pull", "rerun"])
        self.assertIn(f"queued on {MINI} for at least 90s", summary)
        self.assertIn("attempt 2 takes an ephemeral pool", summary)
        # Rescued at the first look past 40 + 90 seconds.
        self.assertLess(api.cancelled_at, 40 + 90 + rescue.POLL_SECONDS + 1)

    def test_budget_variable_moves_the_deadline(self):
        clock = Clock()
        api = FakeAPI(clock, persistent_run(compile_started_at=200), marker=True, finished=lambda s: s >= 400)
        run_main(api, clock, env_extra={"RESCUE_SECONDS": "300"})
        self.assertNotIn("cancel", api.calls)

    def test_newer_head_or_closed_pr_is_not_rerun(self):
        for kwargs, why in (({"head": "b" * 40}, "newer head"), ({"state": "closed"}, "closed")):
            clock = Clock()
            api = FakeAPI(clock, persistent_run(), marker=True, **kwargs)
            code, summary = run_main(api, clock)
            self.assertEqual(code, 0)
            self.assertNotIn("cancel", api.calls, why)
            self.assertIn("not rescued", summary)

    def test_someone_else_reran_first(self):
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True, attempt_after_cancel=2)
        _, summary = run_main(api, clock)
        self.assertNotIn("rerun", api.calls)
        self.assertIn("someone else already re-ran", summary)

    def test_a_push_during_the_cancel_is_not_overwritten(self):
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True)
        heads = iter([HEAD, "b" * 40])
        original = api.pull
        api.pull = lambda number: {**original(number), "head": {"sha": next(heads)}}
        _, summary = run_main(api, clock)
        self.assertIn("cancel", api.calls)
        self.assertNotIn("rerun", api.calls)
        self.assertIn("cancelled but not re-run", summary)

    def test_a_rerun_by_someone_else_during_the_cancel_is_left_alone(self):
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True, settles_after=10_000)
        original = api.run
        api.run = lambda run_id: ({"status": "queued", "run_attempt": 2} if api.cancelled_at is not None
                                  else original(run_id))
        code, summary = run_main(api, clock)
        self.assertEqual(code, 0)
        self.assertNotIn("force-cancel", api.calls)
        self.assertNotIn("rerun", api.calls)
        self.assertIn("someone else already re-ran", summary)

    def test_a_transient_read_error_does_not_end_the_watch(self):
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True)
        original, failures = api.jobs, iter([True, False])

        def flaky(run_id, attempt):
            if clock.seconds > 60 and next(failures, False):
                raise rescue.urllib.error.URLError("502")
            return original(run_id, attempt)
        api.jobs = flaky
        code, summary = run_main(api, clock)
        self.assertEqual(code, 0)
        self.assertIn("rerun", api.calls)
        self.assertIn("retrying", summary)

    def test_wait_counts_from_first_sight_when_created_at_is_early(self):
        clock = Clock()
        # The record claims it queued at 0 s, but the job first appears at 300 s.
        jobs = lambda s: [changes()(s)] + ([job("late consumer", labels=[MINI], created=0)] if s >= 300 else [])
        api = FakeAPI(clock, jobs, marker=True)
        run_main(api, clock)
        self.assertGreaterEqual(api.cancelled_at, 300 + 90)

    def test_force_cancel_then_give_up_without_rerun(self):
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True, settles_after=10_000)
        code, summary = run_main(api, clock)
        self.assertEqual(code, 1)
        self.assertEqual(api.calls.count("force-cancel"), 1)
        self.assertNotIn("rerun", api.calls)
        self.assertIn("did not finish", summary)


class Workflow(unittest.TestCase):
    def setUp(self):
        self.text = (ROOT / ".github/workflows/ci-owned-pool-rescue.yml").read_text(encoding="utf-8")
        self.doc = yaml.safe_load(self.text)

    def test_default_branch_code_with_actions_write_only_in_the_job(self):
        self.assertEqual(self.doc["permissions"], {})
        job = self.doc["jobs"]["rescue"]
        self.assertEqual(job["permissions"], {"actions": "write", "contents": "read", "pull-requests": "read"})
        checkout = job["steps"][0]
        self.assertEqual(checkout["with"], {"ref": "main", "persist-credentials": False})

    def test_runs_whenever_owned_pools_are_on(self):
        self.assertEqual(self.doc[True]["workflow_run"], {"workflows": ["CI"], "types": ["requested"]})
        condition = self.doc["jobs"]["rescue"]["if"]
        for part in ("vars.CI_PR_POOL_OWNED == '1'", "(vars.CI_OWNED_POOL_RESCUE || '1') != '0'",
                     "github.event.workflow_run.event == 'pull_request'",
                     "github.event.workflow_run.head_repository.full_name == github.repository",
                     "github.event.workflow_run.run_attempt == 1"):
            self.assertIn(part, condition)

    def test_runs_the_rescue_script(self):
        step = self.doc["jobs"]["rescue"]["steps"][-1]
        self.assertEqual(step["run"], "python3 scripts/ci/owned_pool_rescue.py")
        self.assertEqual(step["env"]["RESCUE_SECONDS"], "${{ vars.CI_OWNED_POOL_RESCUE_SECONDS }}")
        self.assertEqual(step["env"]["POOL_OWNED"], "${{ vars.CI_PR_POOL_OWNED }}")

    def test_polls_from_a_github_hosted_runner(self):
        self.assertEqual(self.doc["jobs"]["rescue"]["runs-on"], "ubuntu-24.04")

    def test_marker_steps_never_fail_the_changes_job(self):
        steps = yaml.safe_load((ROOT / ".github/workflows/ci.yml").read_text())["jobs"]["changes"]["steps"]
        for name in ("Mark a run on a persistent macOS pool", "Upload the persistent pool marker"):
            step = next(step for step in steps if step.get("name") == name)
            self.assertIs(step.get("continue-on-error"), True, name)

    def test_job_timeout_covers_the_watch_and_the_cancel_wait(self):
        limit = (rescue.WATCH_LIMIT_SECONDS + rescue.CANCEL_WAIT_SECONDS + rescue.FIRST_LOOK_SECONDS) / 60
        self.assertGreater(self.doc["jobs"]["rescue"]["timeout-minutes"], limit)


if __name__ == "__main__":
    unittest.main(verbosity=2)
