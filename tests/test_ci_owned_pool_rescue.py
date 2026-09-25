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
LIGHT = "glaeda-light-xcode-26.6"
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
        self.cancel_attempt = 0

    def run(self, run_id):
        self.calls.append("run")
        if self.cancelled_at is not None and self.cancel_attempt == self.attempt:
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
        return self.marker(name) if callable(self.marker) else self.marker

    def pull(self, number):
        self.calls.append("pull")
        return {"state": self.state, "head": {"sha": self.head}}

    def branch_head(self, branch):
        self.calls.append(f"branch:{branch}")
        return self.head

    def cancel(self, run_id):
        self.calls.append("cancel")
        self.cancelled_at, self.cancel_attempt = self.clock.seconds, self.attempt

    def force_cancel(self, run_id):
        self.calls.append("force-cancel")

    def rerun(self, run_id):
        self.calls.append("rerun")
        # cancelled_at stays for the assertions; the cancel was of the attempt before.
        self.attempt += 1
        self.rerun_at = self.clock.seconds

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
        # QUEUE_ROUNDS 0 keeps a CI run's budget the configured one; QueueBudget
        # covers the default, where the picker may queue on purpose.
        env = {"GITHUB_REPOSITORY": "manaflow-ai/cmux", "GITHUB_EVENT_PATH": str(path),
               "GITHUB_STEP_SUMMARY": str(summary), "POOL_OWNED": "1", "QUEUE_ROUNDS": "0",
               **(env_extra or {})}
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

    def test_a_dispatch_reads_the_named_run_and_watches_it(self):
        # A dispatch passes only the run id; the run object the
        # API returns carries what a workflow_run event did.
        clock = Clock()
        api = FakeAPI(clock, refusing_run(), marker=True)
        live_run = api.run
        api.run = lambda run_id: {**event()["workflow_run"], **live_run(run_id)}
        code, summary = run_main(api, clock, env_extra={"WATCH_RUN_ID": str(RUN_ID)},
                                 payload={"inputs": {"run_id": str(RUN_ID)}})
        self.assertEqual(code, 0)
        self.assertEqual(api.calls[0], "run")
        self.assertIn(f"watching run {RUN_ID} of pull request #42", summary)
        self.assertIn("rerun-failed", api.calls)

    def test_a_dispatch_naming_another_run_does_nothing(self):
        for why, run in {
                "a push run": event(event="push")["workflow_run"],
                "a fork head": event(head_repository={"full_name": "someone/cmux"})["workflow_run"],
                "a retry": event(run_attempt=2)["workflow_run"],
                "another workflow": event(path=".github/workflows/other.yml")["workflow_run"]}.items():
            clock = Clock()
            api = FakeAPI(clock, refusing_run(), marker=True)
            api.run = lambda run_id, run=run: (api.calls.append("run"), run)[1]
            code, summary = run_main(api, clock, env_extra={"WATCH_RUN_ID": str(RUN_ID)})
            self.assertEqual(code, 0, why)
            self.assertEqual(api.calls, ["run"], why)
            self.assertIn("not watched:", summary, why)

    def test_a_dispatch_with_a_bad_run_id_makes_no_request(self):
        clock = Clock()
        api = FakeAPI(clock, refusing_run(), marker=True)
        code, summary = run_main(api, clock, env_extra={"WATCH_RUN_ID": "1; rm"})
        self.assertEqual((code, api.calls), (0, []))
        self.assertIn("is not a number", summary)

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

    def test_a_late_refusal_is_rescued_and_attempt_2_inherits_the_watch(self):
        # A refusal found near the end of the watch is still rescued: the job
        # keeps time past the watch, under its own timeout, for the cancel to
        # settle and the re-run.
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
        self.assertIn("cancel", api.calls)
        self.assertIn("rerun-failed", api.calls)
        self.assertNotIn("too little of the job left", summary)
        self.assertLess(clock.seconds, rescue.WATCH_LIMIT_SECONDS + rescue.RESCUE_GRACE_SECONDS)
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


class Watching(unittest.TestCase):
    def test_ephemeral_run_stops_after_the_marker_check(self):
        clock = Clock()
        api = FakeAPI(clock, lambda s: [changes()(s), job("macos / macOS compile admission", labels=[BLACKSMITH])])
        code, summary = run_main(api, clock)
        self.assertEqual(code, 0)
        self.assertEqual(api.calls, ["jobs", f"artifact:macos-pool-persistent-{RUN_ID}-1-"])
        self.assertIn("the run is on an ephemeral pool", summary)

    def test_jobs_late_placement_moved_are_watched_and_rescued(self):
        # The picker put everything on Blacksmith (no marker), so ci.yml started the watch
        # for late placement, which moved a shard onto an owned root runner that another
        # run took first.
        def jobs(seconds):
            found = [changes()(seconds),
                     job("macos / macOS compile admission", status="completed", labels=[BLACKSMITH], created=5),
                     job("macos / swift-package-tests", status="in_progress", labels=[BLACKSMITH], created=5,
                         runner="bs-1")]
            if seconds >= 600:
                found.append(job(rescue.LATE_JOB, status="completed", created=590))
                found.append(job("macos / app-host unit tests (1/7)", labels=[MINI], created=600))
            return found
        clock = Clock()
        api = FakeAPI(clock, jobs, marker=lambda name: name.startswith("macos-pool-late-"))
        _, summary = run_main(api, clock, env_extra={"RESCUE_SECONDS": "30", "QUEUE_ROUNDS": "",
                                                     "LATE_PLACEMENT": "1"})
        self.assertIn(f"artifact:macos-pool-late-{RUN_ID}-1", api.calls)
        self.assertEqual(api.calls[-4:], ["cancel", "run", "pull", "rerun"])
        # The picker's marker is read once, not on every look while admission runs.
        self.assertEqual(api.calls.count(f"artifact:macos-pool-persistent-{RUN_ID}-1-"), 1)

    def test_late_placement_that_moved_nothing_ends_the_watch(self):
        def jobs(seconds):
            found = [changes()(seconds),
                     job("macos / macOS compile admission", status="completed", labels=[BLACKSMITH], created=5),
                     job("macos / swift-package-tests", status="in_progress", labels=[BLACKSMITH], created=5,
                         runner="bs-1")]
            if seconds >= 300:
                found.append(job(rescue.LATE_JOB, status="completed", created=290))
            return found
        clock = Clock()
        api = FakeAPI(clock, jobs, marker=False)
        _, summary = run_main(api, clock, env_extra={"LATE_PLACEMENT": "1"})
        self.assertIn("late placement moved no job", summary)
        self.assertNotIn("cancel", api.calls)
        # Admission's minutes pass at IDLE_POLL_SECONDS: looks at 45, 165, 285 and 405 s.
        self.assertLessEqual(api.calls.count("jobs"), 5)

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


class QueueBudget(unittest.TestCase):
    """A CI run's owned job may wait up to the pool's expected wait (CI_PR_POOL_QUEUE_ROUNDS); the rescue waits it out."""

    def test_a_round_is_a_compile_admissions_length(self):
        self.assertEqual(rescue.queue_seconds(""), rescue.QUEUE_ROUND_SECONDS)
        self.assertEqual(rescue.queue_seconds(None), rescue.QUEUE_ROUND_SECONDS)
        self.assertEqual(rescue.queue_seconds("2"), 2 * rescue.QUEUE_ROUND_SECONDS)
        # 0 (the kill switch: owned only with machines free now) and invalid values add nothing.
        for value in ("0", "-1", "x"):
            self.assertEqual(rescue.queue_seconds(value), 0, value)

    def test_rounds_are_capped_so_the_rescue_can_still_fire(self):
        cap = rescue.MAX_QUEUE_ROUNDS
        self.assertEqual(cap, 3)
        self.assertEqual(rescue.queue_seconds("50"), cap * rescue.QUEUE_ROUND_SECONDS)
        self.assertEqual(pool_rounds("50"), cap)
        # The longest budget, with its first look and a poll, still ends inside the watch.
        longest = rescue.MAX_BUDGET_SECONDS + rescue.queue_seconds("50")
        self.assertEqual(longest, 3300)
        self.assertLess(longest + rescue.FIRST_LOOK_SECONDS + rescue.POLL_SECONDS, rescue.WATCH_LIMIT_SECONDS)
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True)
        _, summary = run_main(api, clock, env_extra={"RESCUE_SECONDS": "600", "QUEUE_ROUNDS": "50"})
        self.assertIn(f"for at least {longest}s", summary)
        self.assertEqual(api.calls[-4:], ["cancel", "run", "pull", "rerun"])

    def test_a_shard_queued_behind_a_later_run_is_not_rescued(self):
        # Run A took free minis; run B came later and took the idle ones A's
        # shards would have used (nothing is reserved). A's job waits 5 minutes
        # behind B's: well within the pool's expected wait, so A is left alone.
        # CI_OWNED_POOL_RESCUE_SECONDS is 30 on manaflow-ai/cmux (2026-09-25).
        clock = Clock()
        api = FakeAPI(clock, persistent_run(compile_started_at=40 + 300), marker=True)
        code, summary = run_main(api, clock, env_extra={"RESCUE_SECONDS": "30", "QUEUE_ROUNDS": ""})
        self.assertEqual(code, 0)
        self.assertIn(f"budget {30 + rescue.QUEUE_ROUND_SECONDS}s", summary)
        self.assertNotIn("cancel", api.calls)

    def test_a_ci_job_waiting_past_the_expected_wait_is_still_rescued(self):
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True)
        code, summary = run_main(api, clock, env_extra={"RESCUE_SECONDS": "30", "QUEUE_ROUNDS": ""})
        self.assertEqual(api.calls[-4:], ["cancel", "run", "pull", "rerun"])
        budget = 30 + rescue.QUEUE_ROUND_SECONDS
        self.assertIn(f"for at least {budget}s", summary)
        self.assertLess(api.cancelled_at, 40 + budget + rescue.POLL_SECONDS + 1)

    def test_a_late_shard_is_judged_before_the_watch_ends(self):
        # 600 s configured plus 3 rounds is 3300 s, but a shard queued 25
        # minutes in would outlast the 3600 s watch. Its budget is cut to end
        # END_MARGIN_SECONDS before the watch (counted from when the watch
        # first saw it queued), and it is rescued inside the watch.
        clock = Clock()
        api = FakeAPI(clock, persistent_run(queued_at=1500), marker=True)
        _, summary = run_main(api, clock, env_extra={"RESCUE_SECONDS": "600", "QUEUE_ROUNDS": "3"})
        self.assertEqual(api.calls[-4:], ["cancel", "run", "pull", "rerun"])
        self.assertLess(api.cancelled_at, rescue.WATCH_LIMIT_SECONDS)
        budget = int(summary.split("for at least ")[1].split("s")[0])
        self.assertLess(budget, rescue.WATCH_LIMIT_SECONDS - 1500 - rescue.END_MARGIN_SECONDS + 1)
        self.assertLess(budget, 3300)
        # An early job keeps its whole budget.
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True)
        _, summary = run_main(api, clock, env_extra={"RESCUE_SECONDS": "600", "QUEUE_ROUNDS": "3"})
        self.assertIn("for at least 3300s", summary)

    def test_a_job_budget_never_drops_below_the_configured_one(self):
        start = START
        deadline = start + dt.timedelta(seconds=rescue.WATCH_LIMIT_SECONDS)
        late = job("macos / app-host 1", labels=[MINI], created=3550)
        self.assertEqual(rescue.job_budget(late, 930, deadline=deadline, floor_seconds=30), 30)
        early = job("macos / app-host 1", labels=[MINI], created=100)
        self.assertEqual(rescue.job_budget(early, 930, deadline=deadline, floor_seconds=30), 930)
        self.assertEqual(rescue.job_budget(early, 930, deadline=None, floor_seconds=30), 930)

    def test_with_queueing_off_the_rescue_fires_at_30_seconds(self):
        # Rounds 0: the picker takes an owned pool only with machines free now.
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True)
        _, summary = run_main(api, clock, env_extra={"RESCUE_SECONDS": "30", "QUEUE_ROUNDS": "0"})
        self.assertIn("for at least 30s", summary)
        self.assertLess(api.cancelled_at, 40 + 30 + rescue.POLL_SECONDS + 1)

    def test_only_ci_runs_get_the_expected_wait(self):
        # E2E (and iOS, side-lane) runs have no queueing picker.
        clock = Clock()
        api = FakeAPI(clock, lambda s: [e2e_runner()(s)])
        _, summary = run_main(api, clock, payload=e2e_event(),
                              env_extra={"RESCUE_SECONDS": "30", "QUEUE_ROUNDS": ""})
        self.assertIn("(budget 30s)", summary)

    def test_the_workflow_passes_the_rounds_and_ci_uploads_no_queue_marker(self):
        doc = yaml.safe_load((ROOT / ".github/workflows/ci-owned-pool-rescue.yml").read_text())
        step = doc["jobs"]["rescue"]["steps"][-1]
        self.assertEqual(step["env"]["QUEUE_ROUNDS"], "${{ vars.CI_PR_POOL_QUEUE_ROUNDS }}")
        self.assertNotIn("macos-pool-queued", (ROOT / ".github/workflows/ci.yml").read_text())


def pool_rounds(value):
    return rescue.parse_queue_rounds(value)


class Rescuing(unittest.TestCase):
    def test_a_job_waiting_past_the_budget_reruns_the_run(self):
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True)
        code, summary = run_main(api, clock, env_extra={"OWNED_LIGHT_RETRY": "1"})
        self.assertEqual(code, 0)
        start = api.calls.index("cancel")
        self.assertEqual(api.calls[start:start + 4], ["cancel", "run", "pull", "rerun"])
        # The full re-run may take the light tier, so attempt 2 is watched too.
        self.assertIn("jobs:2", api.calls[start + 4:])
        self.assertIn(f"queued on {MINI} for at least 90s", summary)
        self.assertIn("attempt 2 takes an ephemeral pool", summary)
        # Rescued at the first look past 40 + 90 seconds.
        self.assertLess(api.cancelled_at, 40 + 90 + rescue.POLL_SECONDS + 1)

    def test_a_full_re_run_on_the_light_tier_is_watched_the_attempt_1_way(self):
        # The full re-run runs `changes` again. Its macOS jobs are created only
        # once the picker has chosen light, so the first look at attempt 2
        # sees `changes` alone; the watch must wait for the picker and read
        # attempt 2's own marker, then move a job stuck on light to Blacksmith.
        clock = Clock()
        light_run = persistent_run()

        def rerun_jobs(seconds):
            found = light_run(seconds)
            for queued in found[1:]:
                queued["labels"] = [LIGHT]
            return found

        api = FakeAPI(clock, persistent_run(), marker=lambda name: True, rerun_jobs=rerun_jobs)
        code, summary = run_main(api, clock, env_extra={"OWNED_LIGHT_RETRY": "1"})
        self.assertEqual(code, 0)
        self.assertEqual(api.calls.count("rerun"), 1)
        self.assertIn(f"artifact:{rescue.MARKER_PREFIX}-{RUN_ID}-2-", api.calls)
        self.assertEqual(api.calls[-1], "rerun-failed")
        self.assertIn(f"queued on {LIGHT}", summary)
        self.assertIn("attempt 3 takes retry_runner on Blacksmith", summary)
        # Attempt 2 without its own marker is on Blacksmith: the watch stops.
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=lambda name: name.endswith("-1-"), rerun_jobs=rerun_jobs)
        code, summary = run_main(api, clock, env_extra={"OWNED_LIGHT_RETRY": "1"})
        self.assertNotIn("rerun-failed", api.calls)
        self.assertIn("stopped watching attempt 2: the run is on an ephemeral pool", summary)

    def test_a_late_rescue_gives_the_followed_attempt_its_own_watch(self):
        # Attempt 1 queues at minute 40 and is rescued; attempt 2's light job
        # queues 25 minutes into the re-run, past attempt 1's 60-minute
        # deadline. The followed attempt must still be watched and moved.
        clock = Clock()
        late = persistent_run(queued_at=2400)

        def rerun_jobs(seconds):
            found = persistent_run(queued_at=1500)(seconds)
            for queued in found[1:]:
                queued["labels"] = [LIGHT]
            # A Linux job keeps the re-run going until its macOS jobs queue.
            return found + [job("linux-preflight", status="in_progress", labels=["blacksmith-4vcpu-ubuntu-2404"])]

        api = FakeAPI(clock, late, marker=lambda name: True, rerun_jobs=rerun_jobs)
        code, summary = run_main(api, clock, env_extra={"OWNED_LIGHT_RETRY": "1"})
        self.assertEqual(code, 0)
        self.assertGreater(clock.seconds, rescue.WATCH_LIMIT_SECONDS)
        self.assertEqual(api.calls[-1], "rerun-failed")
        self.assertIn(f"queued on {LIGHT}", summary)
        self.assertNotIn("watch limit reached", summary)

    def test_a_full_re_run_is_not_watched_with_the_light_retry_off(self):
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True)
        code, summary = run_main(api, clock)
        self.assertEqual(code, 0)
        self.assertEqual(api.calls[-1], "rerun")
        self.assertNotIn("jobs:2", api.calls)

    def test_the_light_retry_variable_reaches_the_rescue(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/ci-owned-pool-rescue.yml").read_text())
        steps = [step for job in workflow["jobs"].values() for step in job["steps"]
                 if "owned_pool_rescue.py" in str(step.get("run"))]
        self.assertEqual(steps[0]["env"]["OWNED_LIGHT_RETRY"], "${{ vars.CI_OWNED_LIGHT_RETRY }}")

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

    def test_a_slow_cancel_is_waited_out_and_re_run(self):
        # Run 36074561333: a Mac mid-compile took over 5 minutes to settle
        # after a force-cancel, and a 180 s wait left the run cancelled for good.
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True, settles_after=330)
        code, _ = run_main(api, clock)
        self.assertEqual(code, 0)
        self.assertGreaterEqual(api.calls.count("force-cancel"), 1)
        self.assertIn("rerun", api.calls)

    def test_no_cancel_starts_without_time_to_settle_and_re_run(self):
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True)
        target = rescue.Target(run_id=555, attempt=1, head_sha=HEAD, pr_number=7)
        deadline = clock.now() + rescue.dt.timedelta(
            seconds=rescue.CANCEL_WAIT_SECONDS + rescue.RERUN_MARGIN_SECONDS - 1)
        result = rescue.rescue(api, target, now=clock.now, sleep=clock.sleep, log=lambda _: None,
                               deadline=deadline)
        self.assertEqual(result, "not rescued: too little of the job left to cancel and re-run")
        self.assertNotIn("cancel", api.calls)

    def test_a_refused_force_cancel_keeps_waiting(self):
        # The run can settle between the read and the POST, and GitHub then
        # refuses the force-cancel; the next read sees it finished.
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True, settles_after=400)

        def refuse(run_id):
            api.calls.append("force-cancel")
            raise rescue.urllib.error.HTTPError("url", 409, "Conflict", {}, None)
        api.force_cancel = refuse
        code, _ = run_main(api, clock)
        self.assertEqual(code, 0)
        self.assertGreaterEqual(api.calls.count("force-cancel"), 2)
        self.assertIn("rerun", api.calls)

    def test_force_cancel_again_then_give_up_only_at_the_wait_limit(self):
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True, settles_after=10_000)
        code, summary = run_main(api, clock)
        self.assertEqual(code, 1)
        self.assertGreater(api.calls.count("force-cancel"), 1)
        self.assertGreaterEqual(clock.seconds - api.cancelled_at, rescue.CANCEL_WAIT_SECONDS)
        self.assertNotIn("rerun", api.calls)
        self.assertIn("did not finish", summary)


def e2e_event(**overrides):
    return event(**{"path": ".github/workflows/test-e2e.yml", "event": "workflow_dispatch",
                     "pull_requests": [], **overrides})


def e2e_runner(done_at=30):
    return lambda seconds: job("runner", status="completed" if seconds >= done_at else "in_progress")


class E2E(unittest.TestCase):
    def test_only_attempt_1_of_a_same_repository_dispatch(self):
        cases = {
            "not a dispatch": e2e_event(event="push"),
            "fork head": e2e_event(head_repository={"full_name": "someone/cmux"}),
            "attempt 2": e2e_event(run_attempt=2),
        }
        for why, payload in cases.items():
            self.assertIsInstance(rescue.target_from_event(payload, "manaflow-ai/cmux"), str, why)
        target = rescue.target_from_event(e2e_event(), "manaflow-ai/cmux")
        self.assertEqual((target.run_id, target.pr_number, target.e2e, target.picker_job),
                         (RUN_ID, 0, True, "runner"))
        self.assertEqual(target.watch_limit, rescue.E2E_WATCH_LIMIT_SECONDS)

    def test_ephemeral_e2e_run_stops_after_the_marker_check(self):
        clock = Clock()
        api = FakeAPI(clock, lambda s: [e2e_runner()(s)])
        code, summary = run_main(api, clock, payload=e2e_event())
        self.assertEqual(code, 0)
        self.assertEqual(api.calls, ["jobs", f"artifact:macos-pool-persistent-{RUN_ID}-1-"])
        self.assertIn("an E2E dispatch", summary)

    def test_a_stuck_e2e_job_reruns_only_what_failed_without_a_pull_request(self):
        def jobs(seconds):
            found = [e2e_runner()(seconds)]
            if seconds >= 40:
                found.append(job("build", labels=[MINI], created=40))
            return found
        clock = Clock()
        api = FakeAPI(clock, jobs, marker=True)
        code, summary = run_main(api, clock, payload=e2e_event())
        self.assertEqual(code, 0)
        self.assertNotIn("pull", api.calls)
        self.assertEqual(api.calls[-2:], ["rerun-failed", "jobs:2"])  # attempt 2 is on Blacksmith
        self.assertIn("cancel", api.calls)
        self.assertNotIn("rerun", api.calls)

    def test_a_refused_e2e_job_is_rerun(self):
        def jobs(seconds):
            found = [e2e_runner()(seconds)]
            if seconds >= 60:
                found.append(refused_job("build"))
            return found
        clock = Clock()
        api = FakeAPI(clock, jobs, marker=True, finished=lambda s: s >= 60)
        code, summary = run_main(api, clock, payload=e2e_event())
        self.assertEqual(code, 0)
        self.assertEqual(api.calls[-2:], ["rerun-failed", "jobs:2"])  # attempt 2 is on Blacksmith
        self.assertIn("refused", summary)


    def test_a_stuck_e2e_run_that_finished_otherwise_is_not_rerun(self):
        # A newer dispatch of the same group cancelled it; re-running it
        # would cancel that newer run in turn.
        def jobs(seconds):
            found = [e2e_runner()(seconds)]
            if seconds >= 40:
                found.append(job("build", labels=[MINI], created=40))
            return found
        clock = Clock()
        api = FakeAPI(clock, jobs, marker=True)
        target = rescue.target_from_event(e2e_event(), "manaflow-ai/cmux")
        api.finished = lambda seconds: True
        outcome = rescue.rescue(api, target, now=clock.now, sleep=clock.sleep, log=lambda text: None,
                                failed_only=True, refused=False)
        self.assertEqual(outcome, "not rescued: the run already finished")
        self.assertNotIn("rerun-failed", api.calls)


SIDE = "glaeda-side-std-xcode-26.6"


def side_event(**overrides):
    return event(**{"path": ".github/workflows/relay-tls.yml", **overrides})


def side_run(*, queued_at=0, started_at=None, gate_done_at=None):
    """relay-tls: an owned diagnostic job and a Blacksmith keychain job; optionally behind a Linux gate."""
    def jobs(seconds):
        found = []
        if gate_done_at is not None:
            found.append(job("changes", status="completed" if seconds >= gate_done_at else "in_progress"))
            if seconds < gate_done_at:
                return found
        started = started_at is not None and seconds >= started_at
        owned = job("diagnostic-presentation", labels=[SIDE], created=queued_at,
                    status="in_progress" if started else "queued", runner="mini-1-glaeda-2" if started else "")
        if started:
            owned["started_at"] = stamp(started_at)
        found += [owned, job("system-keychain", labels=[BLACKSMITH], status="in_progress", runner="bs")]
        return found
    return jobs


class SideLanes(unittest.TestCase):
    def test_every_side_workflow_is_watched_like_a_pull_request(self):
        for path in sorted(rescue.SIDE_WORKFLOW_PATHS):
            target = rescue.target_from_event(side_event(path=path), "manaflow-ai/cmux")
            self.assertTrue(target.side, path)
            self.assertEqual((target.pr_number, target.watch_limit), (42, rescue.SIDE_WATCH_LIMIT_SECONDS))
        for why, payload in {"push": side_event(event="push"), "attempt 2": side_event(run_attempt=2),
                             "fork": side_event(head_repository={"full_name": "someone/cmux"}),
                             "not a side lane": side_event(path=".github/workflows/plain-paste-worker.yml")}.items():
            self.assertIsInstance(rescue.target_from_event(payload, "manaflow-ai/cmux"), str, why)

    def test_a_run_with_no_owned_job_stops_when_it_finishes(self):
        clock = Clock()
        api = FakeAPI(clock, lambda s: [job("system-keychain", labels=[BLACKSMITH], status="completed")])
        code, summary = run_main(api, clock, payload=side_event())
        self.assertEqual(code, 0)
        self.assertEqual(api.calls, ["jobs"])
        self.assertIn("no job of the run asked for a persistent pool", summary)
        self.assertNotIn("artifact", " ".join(api.calls))

    def test_the_watch_ends_once_the_fleet_accepts_the_side_job(self):
        clock = Clock()
        api = FakeAPI(clock, side_run(started_at=20))
        code, summary = run_main(api, clock, payload=side_event())
        self.assertEqual(code, 0)
        self.assertIn("the fleet accepted the side-lane jobs", summary)
        self.assertNotIn("cancel", api.calls)
        self.assertLess(clock.seconds, rescue.SIDE_WATCH_LIMIT_SECONDS)

    def test_a_gated_side_job_is_found_after_its_gate(self):
        clock = Clock()
        api = FakeAPI(clock, side_run(queued_at=90, started_at=100, gate_done_at=90))
        code, summary = run_main(api, clock, payload=side_event(path=".github/workflows/cloud-machine-tests.yml"))
        self.assertIn("a side-lane job asked for a persistent pool", summary)
        self.assertIn("the fleet accepted the side-lane jobs", summary)

    def test_a_stuck_side_job_moves_to_blacksmith_keeping_what_passed_and_is_not_followed(self):
        clock = Clock()
        api = FakeAPI(clock, side_run())
        code, summary = run_main(api, clock, payload=side_event())
        self.assertEqual(code, 0)
        self.assertIn("cancel", api.calls)
        self.assertEqual(api.calls[-1], "rerun-failed")  # attempt 2 takes Blacksmith; no watch of it
        self.assertNotIn("rerun", api.calls)
        self.assertIn("Blacksmith default", summary)

    def test_a_refused_side_job_is_rerun(self):
        def jobs(seconds):
            return [refused_job("diagnostic-presentation", labels=(SIDE,)) if seconds >= 60 else
                    job("diagnostic-presentation", labels=[SIDE], created=0)]
        clock = Clock()
        api = FakeAPI(clock, jobs, finished=lambda s: s >= 60)
        code, summary = run_main(api, clock, payload=side_event())
        self.assertEqual(api.calls[-1], "rerun-failed")
        self.assertIn("refused", summary)


IOS_SIM = "glaeda-ios-sim"


class IOSDispatch(unittest.TestCase):
    """test-ios.yml and ios-screenshots.yml dispatches are watched like an E2E run."""

    def test_ios_dispatches_are_targets(self):
        for path in (".github/workflows/test-ios.yml", ".github/workflows/ios-screenshots.yml"):
            target = rescue.target_from_event(e2e_event(path=path), "manaflow-ai/cmux")
            self.assertEqual((target.pr_number, target.e2e, target.picker_job, target.path),
                             (0, True, "runner", path))
            self.assertIsInstance(rescue.target_from_event(e2e_event(path=path, run_attempt=2),
                                                           "manaflow-ai/cmux"), str)
        # test-ios.yml pull request runs are watched too, against their pull request.
        target = rescue.target_from_event(event(path=".github/workflows/test-ios.yml"), "manaflow-ai/cmux")
        self.assertEqual((target.pr_number > 0, target.e2e, target.picker_job), (True, True, "runner"))
        self.assertIsInstance(rescue.target_from_event(
            event(path=".github/workflows/ios-screenshots.yml"), "manaflow-ai/cmux"), str)
        # Signing and streamed validation never take an owned Mac, so they are never watched.
        for path in (".github/workflows/ios-testflight.yml", ".github/workflows/ios-streamed-validate.yml"):
            self.assertIsInstance(rescue.target_from_event(e2e_event(path=path), "manaflow-ai/cmux"), str)

    def test_a_job_waiting_for_the_simulator_label_moves_to_blacksmith(self):
        # No idle mini carries glaeda-ios-sim yet: the job queues on the owned
        # labels and is re-run on retry_runs_on after the budget.
        def jobs(seconds):
            found = [e2e_runner()(seconds)]
            if seconds >= 40:
                found.append(job("ios-simulator-build", labels=[MINI, IOS_SIM], created=40))
            return found
        clock = Clock()
        api = FakeAPI(clock, jobs, marker=True)
        code, summary = run_main(api, clock, payload=e2e_event(path=".github/workflows/test-ios.yml"))
        self.assertEqual(code, 0)
        self.assertNotIn("pull", api.calls)
        self.assertEqual(api.calls[-2:], ["rerun-failed", "jobs:2"])
        self.assertIn("a dispatch of .github/workflows/test-ios.yml", summary)
        self.assertIn(f"queued on {MINI}", summary)

    def test_a_pull_request_run_waiting_for_the_simulator_label_moves_to_blacksmith(self):
        # The same wait on a pull request run: the head is checked before the re-run.
        def jobs(seconds):
            found = [e2e_runner()(seconds)]
            if seconds >= 40:
                found.append(job("ios-simulator-build", labels=[MINI, IOS_SIM], created=40))
            return found
        clock = Clock()
        api = FakeAPI(clock, jobs, marker=True)
        code, summary = run_main(api, clock, payload=event(path=".github/workflows/test-ios.yml"))
        self.assertEqual(code, 0)
        self.assertIn("pull", api.calls)
        self.assertEqual(api.calls[-2:], ["rerun-failed", "jobs:2"])
        self.assertIn("pull request #42's .github/workflows/test-ios.yml", summary)


def main_event(**overrides):
    return event(**{"event": "workflow_dispatch", "head_branch": "main", "pull_requests": [], **overrides})


class MainDispatch(unittest.TestCase):
    """Main's full-suite dispatch of ci.yml is watched like a pull request run, against main's HEAD."""

    def test_only_attempt_1_of_a_same_repository_dispatch_on_main(self):
        cases = {
            "another branch": main_event(head_branch="topic"),
            "fork head": main_event(head_repository={"full_name": "someone/cmux"}),
            "attempt 2": main_event(run_attempt=2),
            "another workflow": main_event(path=".github/workflows/nightly.yml"),
        }
        for why, payload in cases.items():
            self.assertIsInstance(rescue.target_from_event(payload, "manaflow-ai/cmux"), str, why)
        target = rescue.target_from_event(main_event(), "manaflow-ai/cmux")
        self.assertEqual((target.run_id, target.pr_number, target.main, target.e2e, target.picker_job),
                         (RUN_ID, 0, True, False, "changes"))
        self.assertEqual(target.watch_limit, rescue.WATCH_LIMIT_SECONDS)

    def test_an_ephemeral_main_run_stops_after_the_marker_check(self):
        clock = Clock()
        api = FakeAPI(clock, lambda seconds: [changes()(seconds)])
        code, summary = run_main(api, clock, payload=main_event())
        self.assertEqual(code, 0)
        self.assertEqual(api.calls, ["jobs", f"artifact:macos-pool-persistent-{RUN_ID}-1-"])
        self.assertIn("main's full-suite dispatch", summary)

    def test_a_stuck_main_run_is_cancelled_and_rerun_on_blacksmith(self):
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True)
        code, summary = run_main(api, clock, payload=main_event())
        self.assertEqual(code, 0)
        self.assertNotIn("pull", api.calls)
        self.assertIn("branch:main", api.calls)
        self.assertEqual(api.calls[-1], "rerun")
        self.assertIn("cancel", api.calls)

    def test_a_stuck_main_run_is_cancelled_not_rerun_once_main_moves(self):
        # The stuck run holds main's concurrency group; cancelling it lets the
        # dispatcher start the new HEAD when it completes.
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True, head="b" * 40)
        _, summary = run_main(api, clock, payload=main_event())
        self.assertIn("cancel", api.calls)
        self.assertNotIn("rerun", api.calls)
        self.assertIn("main has moved on", summary)
        self.assertIn("not re-run", summary)
        # Main moving during the cancel: cancelled, and its completion dispatches the new HEAD.
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True)
        heads = iter([HEAD, "b" * 40])
        api.branch_head = lambda branch: next(heads)
        _, summary = run_main(api, clock, payload=main_event())
        self.assertIn("cancel", api.calls)
        self.assertNotIn("rerun", api.calls)
        self.assertIn("cancelled but not re-run", summary)

    def test_a_dispatch_naming_main_s_run_watches_it(self):
        # A dispatch may name main's run too; the run the API returns is
        # main's dispatch.
        clock = Clock()
        api = FakeAPI(clock, refusing_run(), marker=True)
        live_run = api.run
        api.run = lambda run_id: {**main_event()["workflow_run"], **live_run(run_id)}
        code, summary = run_main(api, clock, env_extra={"WATCH_RUN_ID": str(RUN_ID)},
                                 payload={"inputs": {"run_id": str(RUN_ID)}})
        self.assertEqual(code, 0)
        self.assertEqual(api.calls[0], "run")
        self.assertIn(f"watching run {RUN_ID} of main's full-suite dispatch", summary)
        self.assertIn("rerun-failed", api.calls)

    def test_a_main_run_gets_the_expected_owned_wait(self):
        # The picker places main like a pull request, queue rounds included.
        clock = Clock()
        api = FakeAPI(clock, persistent_run(compile_started_at=40 + 600), marker=True)
        code, summary = run_main(api, clock, payload=main_event(),
                                 env_extra={"RESCUE_SECONDS": "30", "QUEUE_ROUNDS": ""})
        self.assertEqual(code, 0)
        self.assertIn(f"budget {30 + rescue.QUEUE_ROUND_SECONDS}s", summary)
        self.assertNotIn("cancel", api.calls)

    def test_a_refused_main_job_reruns_the_failed_jobs(self):
        clock = Clock()
        api = FakeAPI(clock, refusing_run(), marker=True)
        code, summary = run_main(api, clock, payload=main_event())
        self.assertEqual(code, 0)
        self.assertIn("rerun-failed", api.calls)
        self.assertNotIn("pull", api.calls)
        self.assertIn("refused", summary)
        # Even once main moved: a fleet refusal must not leave main's run red.
        clock = Clock()
        api = FakeAPI(clock, refusing_run(), marker=True, head="b" * 40)
        code, summary = run_main(api, clock, payload=main_event())
        self.assertEqual(code, 0)
        self.assertIn("rerun-failed", api.calls)



class SweepAPI:
    """The sweeper's own reads: marker listings and the runs they name."""

    def __init__(self, runs, *, picker=(), late=(), created=0, attempt_jobs=None):
        self.runs = {run["id"]: run for run in runs}
        self.marked = {rescue.WATCH_MARKER: list(picker), rescue.LATE_WATCH_MARKER: list(late)}
        self.created, self.remaining, self.limit, self.reads = created, "900", "1000", []
        self.attempt_jobs = attempt_jobs or {}

    def jobs(self, run_id, attempt):
        return self.attempt_jobs.get(run_id, [])

    def marked_runs(self, name, count):
        return [(run_id, START + dt.timedelta(seconds=self.created)) for run_id in self.marked[name]][:count]

    def run(self, run_id):
        self.reads.append(run_id)
        return self.runs[run_id]


def listed(run_id, **overrides):
    run = dict(event(id=run_id)["workflow_run"])
    run.update(overrides)
    return run


class Sweeper(unittest.TestCase):
    def sweep(self, api, *, follow=None, ticks=3, light_retry=False):
        clock, watched = Clock(), []

        def fake_follow(client, target, **kwargs):
            watched.append((target.run_id, target.attempt, target.late) if not light_retry
                           else (target.run_id, target.attempt, target.full_rerun))
            return follow(kwargs["sleep"]) if follow else "stopped: the run finished"

        with unittest.mock.patch.object(rescue, "follow", fake_follow):
            outcomes = rescue.sweep(api, "manaflow-ai/cmux", seconds=90, queue_rounds="0", light_retry=light_retry,
                                    now=clock.now, log=lambda text: None, sweep_seconds=ticks * 60,
                                    tick_seconds=60, wait=clock.sleep)
        return sorted(watched), outcomes

    def test_watches_each_marked_run_once(self):
        runs = [listed(1),
                listed(2, path=".github/workflows/test-e2e.yml", event="workflow_dispatch", pull_requests=[]),
                listed(3, head_repository={"full_name": "someone/cmux"})]  # a fork never takes the fleet
        api = SweepAPI(runs, picker=[1, 2, 3])
        watched, outcomes = self.sweep(api)
        # Listed on every tick, read and watched once.
        self.assertEqual(watched, [(1, 1, False), (2, 1, False)])
        self.assertEqual(sorted(api.reads), [1, 2, 3])
        self.assertEqual(outcomes, {"stopped": 2})

    def test_late_placement_and_the_picker_marker(self):
        api = SweepAPI([listed(1), listed(2)], picker=[1], late=[1, 2])
        # A run the picker marked is watched the ordinary way even when late placement moved jobs too.
        self.assertEqual(self.sweep(api)[0], [(1, 1, False), (2, 1, True)])

    def test_resumes_the_attempt_a_rescue_re_ran(self):
        api = SweepAPI([listed(1, run_attempt=2), listed(2, run_attempt=3)], picker=[1, 2])
        # Attempt 3 and later always take Blacksmith: nothing to watch.
        self.assertEqual(self.sweep(api)[0], [(1, 2, False)])

    def test_a_finished_run_only_when_it_failed_since_the_last_sweeper(self):
        recent, old = stamp(-10 * 60), stamp(-rescue.SWEEP_FINISHED_SECONDS - 60)
        runs = [listed(1, status="completed", conclusion="success", updated_at=recent),
                listed(2, status="completed", conclusion="failure", updated_at=old),
                listed(3, status="completed", conclusion="failure", updated_at=recent),
                listed(4, status="in_progress")]
        # Only a recent failure can be a refusal nobody re-ran; a run in flight is watched as ever.
        self.assertEqual(self.sweep(SweepAPI(runs, picker=[1, 2, 3, 4]))[0], [(3, 1, False), (4, 1, False)])

    def test_a_resumed_full_re_run_waits_for_its_picker(self):
        full = [dict(job("changes", status="completed"), run_attempt=2)]
        failed_only = [dict(job("changes", status="completed"), run_attempt=1)]
        api = SweepAPI([listed(1, run_attempt=2), listed(2, run_attempt=2)], picker=[1, 2],
                       attempt_jobs={1: full, 2: failed_only})
        self.assertEqual(self.sweep(api, light_retry=True)[0], [(1, 2, True), (2, 2, False)])

    def test_leaves_runs_past_the_longest_watch(self):
        api = SweepAPI([listed(1)], picker=[1], created=-rescue.SWEEP_MAX_AGE_SECONDS - 60)
        self.assertEqual(self.sweep(api)[0], [])

    def test_a_handover_stops_watches(self):
        def forever(sleep):
            while True:
                sleep(0.01)
        watched, outcomes = self.sweep(SweepAPI([listed(1)], picker=[1]), follow=forever, ticks=1)
        self.assertEqual(watched, [(1, 1, False)])
        self.assertEqual(outcomes, {"handed over": 1})

    def test_one_runs_bug_ends_only_its_watch(self):
        def broken(sleep):
            raise KeyError("run")
        _, outcomes = self.sweep(SweepAPI([listed(1), listed(2)], picker=[1, 2]), follow=broken)
        self.assertEqual(outcomes, {"error": 2})

    def test_a_refusal_found_after_the_run_finished_is_re_run(self):
        # A run refused while no sweeper ran: the next one still finds its marker.
        clock = Clock()
        api = FakeAPI(clock, refusing_run(refused_at=0), marker=True, finished=lambda seconds: True)
        target = rescue.sweep_target(listed(RUN_ID), "manaflow-ai/cmux", late=False)
        outcome = rescue.follow(api, target, seconds=90, queue_rounds="0", light_retry=False,
                                now=clock.now, sleep=clock.sleep, log=lambda text: None)
        self.assertEqual(api.calls.count("rerun-failed"), 1)
        self.assertNotIn("cancel", api.calls)
        # Then it follows the re-run, which here took Blacksmith.
        self.assertEqual(outcome, "stopped watching attempt 2: no job of this attempt asked for a persistent pool")

    def test_main_sweeps_when_asked(self):
        clock = Clock()
        with unittest.mock.patch.object(rescue, "sweep", return_value={"done": 1, "stopped": 4}), \
                tempfile.TemporaryDirectory() as tmp, unittest.mock.patch("sys.stdout", io.StringIO()):
            summary = Path(tmp, "summary")
            env = {"GITHUB_REPOSITORY": "manaflow-ai/cmux", "GITHUB_STEP_SUMMARY": str(summary),
                   "POOL_OWNED": "1", "SWEEP": "1"}
            code = rescue.main([], env, api=SweepAPI([]), now=clock.now, sleep=clock.sleep)
            text = summary.read_text()
        self.assertEqual(code, 0)
        self.assertIn("swept: 1 done, 4 stopped", text)

class Tokens(unittest.TestCase):
    """Reads may use the App's token; writes always use GITHUB_TOKEN."""

    def open_with(self, fail_first_read=False, code=401):
        seen = []

        class Response(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        def urlopen(request, timeout):
            seen.append((request.get_method(), request.headers["Authorization"]))
            if fail_first_read and len(seen) == 1:
                raise rescue.urllib.error.HTTPError(request.full_url, code, "refused", {}, None)
            return Response(b"{}")
        return seen, unittest.mock.patch.object(rescue.urllib.request, "urlopen", urlopen)

    def test_reads_use_the_app_token_and_writes_keep_github_token(self):
        seen, patch = self.open_with()
        with patch:
            api = rescue.GitHub("repo-token", "o/r", read_token="app-token")
            api.run(1)
            api.rerun_failed(1)
            api.cancel(1)
        # A re-run started by the App would not be github-actions[bot], which
        # ci-macos.yml's attempt-2 routing requires.
        self.assertEqual(seen, [("GET", "Bearer app-token"), ("POST", "Bearer repo-token"),
                                ("POST", "Bearer repo-token")])

    def test_an_expired_app_token_falls_back_for_the_rest_of_the_watch(self):
        seen, patch = self.open_with(fail_first_read=True)
        with patch:
            api = rescue.GitHub("repo-token", "o/r", read_token="app-token")
            api.run(1)
            api.run(1)
        self.assertEqual(seen, [("GET", "Bearer app-token"), ("GET", "Bearer repo-token"),
                                ("GET", "Bearer repo-token")])

    def test_a_read_the_app_may_not_make_uses_github_token_once(self):
        seen, patch = self.open_with(fail_first_read=True, code=403)
        with patch:
            api = rescue.GitHub("repo-token", "o/r", read_token="app-token")
            api.pull(1)
            api.run(1)
        # 403: this read lacks a permission; the next read still tries the App.
        self.assertEqual(seen, [("GET", "Bearer app-token"), ("GET", "Bearer repo-token"),
                                ("GET", "Bearer app-token")])

    def test_without_an_app_token_everything_uses_github_token(self):
        seen, patch = self.open_with()
        with patch:
            rescue.GitHub("repo-token", "o/r").run(1)
        self.assertEqual(seen, [("GET", "Bearer repo-token")])

    def test_the_workflow_mints_a_read_only_token_and_passes_it(self):
        steps = yaml.safe_load((ROOT / ".github/workflows/ci-owned-pool-rescue.yml").read_text(
            encoding="utf-8"))["jobs"]["rescue"]["steps"]
        mint = next(step for step in steps if step.get("id") == "read-token")
        self.assertTrue(mint["continue-on-error"])
        self.assertEqual({key: value for key, value in mint["with"].items() if key.startswith("permission-")},
                         # Only what owned_pool_rescue.py reads (actions and pulls endpoints). The
                         # installation has no contents grant, and asking for one fails the mint (422).
                         {"permission-actions": "read", "permission-pull-requests": "read"})
        watch = next(step for step in steps if step.get("name") == "Watch runs on persistent pools")
        self.assertEqual(watch["env"]["READ_TOKEN"], "${{ steps.read-token.outputs.token }}")
        self.assertEqual(watch["env"]["GH_TOKEN"], "${{ github.token }}")


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

    def test_runs_when_dispatched_or_for_a_screenshots_or_side_lane_run(self):
        triggers = self.doc[True]
        self.assertEqual(sorted(triggers), ["schedule", "workflow_dispatch", "workflow_run"])
        self.assertIs(triggers["workflow_dispatch"]["inputs"]["run_id"]["required"], False)
        # release.yml calls ios-screenshots.yml with contents: read only, so
        # it cannot upload through a job asking for more; the side lanes have
        # no picker and are all on the fleet. Both keep the event trigger.
        self.assertEqual(triggers["workflow_run"]["types"], ["requested"])
        self.assertEqual(triggers["workflow_run"]["workflows"][0], "iOS App Store screenshots")
        self.assertNotIn("CI", triggers["workflow_run"]["workflows"])
        paths = self.doc["env"]["SOURCE_WORKFLOW_PATHS"].split()
        self.assertEqual(set(paths), {rescue.IOS_SCREENSHOTS_WORKFLOW_PATH, *rescue.SIDE_WORKFLOW_PATHS})
        condition = self.doc["jobs"]["rescue"]["if"]
        for part in ("vars.CI_PR_POOL_OWNED == '1'", "(vars.CI_OWNED_POOL_RESCUE || '1') != '0'",
                     "(github.event_name == 'schedule' || github.event_name == 'workflow_dispatch' || "
                     "(github.event.workflow_run.event == 'pull_request' && "
                     "startsWith(vars.CI_SIDE_LANE_RUNNER, 'glaeda-side-') || "
                     "github.event.workflow_run.path == '.github/workflows/ios-screenshots.yml' && "
                     "github.event.workflow_run.event == 'workflow_dispatch') && "
                     "github.event.workflow_run.head_repository.full_name == github.repository && "
                     "github.event.workflow_run.run_attempt == 1)"):
            self.assertIn(part, condition)
        step = self.doc["jobs"]["rescue"]["steps"][-1]
        self.assertEqual(step["env"]["WATCH_RUN_ID"], "${{ inputs.run_id }}")
        self.assertIn("inputs.run_id || github.event.workflow_run.id", self.doc["concurrency"]["group"])

    def test_one_sweeper_at_a_time_from_the_cron(self):
        self.assertEqual(self.doc[True]["schedule"], [{"cron": "17 */2 * * *"}])
        sweeper = "(github.event_name == 'schedule' || github.event_name == 'workflow_dispatch' && !inputs.run_id)"
        self.assertIn(sweeper + " && 'owned-pool-sweeper'", self.doc["concurrency"]["group"])
        # A queued sweeper waits for the running one, so a rescue it started is never killed;
        # a single run's watch still cancels its predecessor.
        self.assertEqual(self.doc["concurrency"]["cancel-in-progress"], "${{ !" + sweeper + " }}")
        env = self.doc["jobs"]["rescue"]["steps"][-1]["env"]
        self.assertEqual(env["SWEEP"], "${{ " + sweeper + " && '1' || '' }}")

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

    def test_pickers_mark_the_runs_the_sweeper_watches(self):
        # No source workflow dispatches a watch or holds actions: write for it.
        for path in (".github/workflows/ci.yml", ".github/workflows/test-e2e.yml",
                     ".github/workflows/test-ios.yml"):
            text = (ROOT / path).read_text(encoding="utf-8")
            self.assertNotIn("owned-pool-watch", yaml.safe_load(text)["jobs"], path)
            self.assertNotIn("gh workflow run ci-owned-pool-rescue.yml", text, path)
        for path, job, marker, name in (
                (".github/workflows/ci.yml", "changes", "steps.macos-pool-marker.outputs.path", rescue.WATCH_MARKER),
                (".github/workflows/test-e2e.yml", "runner", "steps.marker.outputs.path", rescue.WATCH_MARKER),
                (".github/workflows/test-ios.yml", "runner", "steps.marker.outputs.path", rescue.WATCH_MARKER),
                (".github/workflows/ci-macos.yml", "late-placement", "steps.place.outputs.runners",
                 rescue.LATE_WATCH_MARKER)):
            steps = yaml.safe_load((ROOT / path).read_text(encoding="utf-8"))["jobs"][job]["steps"]
            upload = next(step for step in steps if (step.get("with") or {}).get("name") == name)
            self.assertIn(marker, upload["if"], path)
            # Fail-safe: a missing marker only means the run is not watched.
            self.assertIs(upload.get("continue-on-error"), True, path)
            self.assertIn("actions/upload-artifact@", upload["uses"], path)
            if path in (".github/workflows/ci.yml", ".github/workflows/ci-macos.yml"):
                # The others' marker step already runs on attempt 1 only.
                self.assertIn("github.run_attempt == 1", upload["if"], path)

    def test_job_timeout_covers_the_watch_and_the_cancel_wait(self):
        timeout = self.doc["jobs"]["rescue"]["timeout-minutes"] * 60
        self.assertGreaterEqual(timeout, rescue.JOB_TIMEOUT_SECONDS)
        # A sweeper adopts runs, then gives a rescue under way its grace, within a hosted job's 6 hours.
        self.assertLessEqual(rescue.SWEEP_SECONDS + rescue.RESCUE_GRACE_SECONDS,
                             timeout - rescue.JOB_TIMEOUT_MARGIN_SECONDS)
        self.assertLessEqual(timeout, 6 * 60 * 60)
        watch = max(rescue.WATCH_LIMIT_SECONDS, rescue.E2E_WATCH_LIMIT_SECONDS)
        # A cancel starts only with CANCEL_WAIT + RERUN_MARGIN left of the grace.
        self.assertGreater(rescue.RESCUE_GRACE_SECONDS, rescue.CANCEL_WAIT_SECONDS + rescue.RERUN_MARGIN_SECONDS)
        self.assertLessEqual(watch + rescue.RESCUE_GRACE_SECONDS,
                             rescue.JOB_TIMEOUT_SECONDS - rescue.JOB_TIMEOUT_MARGIN_SECONDS)


if __name__ == "__main__":
    unittest.main(verbosity=2)
