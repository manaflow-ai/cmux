#!/usr/bin/env python3
"""Tests for scripts/ci/owned_pool_rescue.py and ci-owned-pool-rescue.yml (no network)."""

from __future__ import annotations

import contextlib
import dataclasses
import datetime as dt
import importlib.util
import io
import json
import re
import sys
import tempfile
import types
import unittest
import unittest.mock
import urllib.error
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
# The bot's two re-run actors (rescue.RESCUE_ACTORS): the workflow token's and the cmux-bot App's.
ACTIONS_BOT, CMUX_BOT = "github-actions[bot]", "cmux-bot[bot]"


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

    def advance(self, seconds):
        """The test moves its virtual clock on (not a wait: nothing real passes)."""
        self.seconds += seconds


class FakeAPI:
    """Jobs come from a function of elapsed seconds; every call is recorded."""

    def __init__(self, clock, jobs, *, marker=False, head=HEAD, state="open", settles_after=10,
                 attempt_after_cancel=1, finished=lambda seconds: False, rerun_jobs=None, conclusion=None,
                 workflow=None, snapshot=None):
        self.clock, self.jobs_at, self.marker = clock, jobs, marker
        rescue.SETTLED_HERE.clear()  # each fake API stands for a fresh rescue process
        # The janitor's pool snapshot (pool_snapshot()), as a function of elapsed seconds; by default every
        # Blacksmith label is free, so a queue rescue moves at its configured budget.
        self.snapshot = snapshot or (lambda seconds: {"generated_at": stamp(seconds), "pools": {}})
        self.snapshot_reads = 0
        # The workflow file at the run's head (workflow_file()); None reads as missing.
        self.workflow = workflow
        # Jobs of attempt 2 onwards, as a function of seconds since that attempt began.
        self.rerun_jobs = rerun_jobs or (lambda seconds: [job("macos / tests", status="completed",
                                                              labels=[BLACKSMITH])])
        self.attempt, self.rerun_at = 1, 0.0
        self.head, self.state = head, state
        self.settles_after, self.attempt_after_cancel = settles_after, attempt_after_cancel
        self.finished = finished
        # The finished attempt-1 run's conclusion; None leaves it out, as the older fakes did.
        self.conclusion = conclusion
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
        if self.finished(self.clock.seconds):
            return {"status": "completed", "run_attempt": 1, "conclusion": self.conclusion}
        return {"status": "in_progress", "run_attempt": 1}

    def jobs(self, run_id, attempt):
        self.calls.append("jobs" if attempt == 1 else f"jobs:{attempt}")
        if attempt > 1:
            return self.rerun_jobs(self.clock.seconds - self.rerun_at)
        return self.jobs_at(self.clock.seconds)

    def workflow_file(self, path, ref):
        self.calls.append(f"workflow:{path}@{ref}")
        return self.workflow

    def pool_snapshot(self, now):
        self.snapshot_reads += 1
        return self.snapshot(self.clock.seconds)

    def has_artifact(self, run_id, name):
        self.calls.append(f"artifact:{name}")
        return self.marker(name) if callable(self.marker) else self.marker

    def pull(self, number):
        self.calls.append("pull")
        return {"state": self.state, "head": {"sha": self.head}}

    def branch_head(self, branch):
        self.calls.append(f"branch:{branch}")
        return self.head

    def cancel(self, run_id, before_send=None):
        if before_send is not None:
            before_send()  # as GitHub.request() does, right before the request goes out
        self.calls.append("cancel")
        self.cancelled_at, self.cancel_attempt = self.clock.seconds, self.attempt
        self.first_cancel = getattr(self, "first_cancel", None) or self.clock.seconds

    def force_cancel(self, run_id):
        self.calls.append("force-cancel")

    def annotations(self, job_id, *, final=False):
        self.calls.append(f"annotations:{job_id}")
        return []

    def rerun(self, run_id, next_attempt):
        self.calls.append("rerun")
        # The attempt the re-run starts, which ci-ui-tests.yml is dispatched for.
        assert next_attempt == self.attempt + 1, (next_attempt, self.attempt)
        # cancelled_at stays for the assertions; the cancel was of the attempt before.
        self.attempt += 1
        self.rerun_at = self.clock.seconds

    def rerun_failed(self, run_id, next_attempt):
        self.calls.append("rerun-failed")
        assert next_attempt == self.attempt + 1, (next_attempt, self.attempt)
        self.attempt += 1
        self.cancelled_at, self.rerun_at = None, self.clock.seconds

    def rerun_job(self, run_id, job_id, next_attempt):
        self.calls.append(f"rerun-job:{job_id}")
        assert next_attempt == self.attempt + 1, (next_attempt, self.attempt)
        self.attempt += 1
        self.cancelled_at, self.rerun_at = None, self.clock.seconds


def assert_left_at_open_head(case, api, text, number=42):
    """The rescue found the stuck job but cancelled nothing: the pull request is open at the run's head."""
    case.assertNotIn("cancel", api.calls)
    case.assertNotIn("force-cancel", api.calls)
    case.assertNotIn("rerun", api.calls)
    case.assertNotIn("rerun-failed", api.calls)
    case.assertIn(f"not rescued: PR #{number} is open at the run's head; {rescue.OPEN_HEAD_RULE}", text)


def with_ids(jobs_at, first=900000):
    """`jobs_at` with an id on every job that has none, as GitHub gives each job one."""
    def jobs(seconds):
        return [found if found.get("id") is not None else {**found, "id": first + index}
                for index, found in enumerate(jobs_at(seconds))]
    return jobs


def assert_settled_failover(case, api):
    """The settled-sibling failover: a cancel, then a re-run of only what waited (one job, or the failed and cancelled
    jobs), never a full re-run or a placement re-run that would repeat a finished job."""
    case.assertIn("cancel", api.calls)
    case.assertNotIn("rerun", api.calls)
    case.assertNotIn("rerun-failed", api.calls)
    case.assertTrue(any(call.startswith("rerun-job:") for call in api.calls), api.calls)


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


def unacquired_job(name="ios-simulator-build", *, labels=(MINI, "glaeda-ios-sim")):
    """A job GitHub cancelled after no runner of its pool acquired it: no runner, no step."""
    found = job(name, status="completed", labels=labels, created=40)
    found.update(conclusion="cancelled", started_at=stamp(40), completed_at=stamp(270), steps=[])
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


def setup_job(*, started=41, past_setup=False):
    """An owned job its runner took, still in glaeda's hook ("Set up runner") unless past_setup."""
    found = job("macos / macOS compile admission", status="in_progress", labels=[MINI], created=40, runner="mini-1")
    found.update(started_at=stamp(started), steps=[
        {"name": "Set up job", "status": "completed", "conclusion": "success"},
        {"name": "Set up runner", "status": "completed" if past_setup else "in_progress", "conclusion": None,
         "started_at": stamp(started + 3)},
        {"name": "Checkout", "status": "in_progress" if past_setup else "queued", "conclusion": None}])
    return found


class SetupWait(unittest.TestCase):
    def test_a_job_waiting_in_setup_is_watched_then_rescued(self):
        waiting = setup_job()
        self.assertTrue(rescue.in_setup(waiting))
        self.assertFalse(rescue.in_setup(setup_job(past_setup=True)))
        early = START + dt.timedelta(seconds=41 + rescue.REFUSAL_SECONDS + 60)
        self.assertFalse(rescue.accepted(waiting, early), "a job in setup has not been accepted yet")
        self.assertTrue(rescue.accepted(setup_job(past_setup=True), early))
        look = rescue.assess([changes()(60), waiting], now=early, budget_seconds=90)
        self.assertEqual((look.action, look.waiting), ("watch", True))
        # measured from the setup step the hook waits in, not from the job's start
        self.assertEqual(rescue.assess([changes()(60), waiting], budget_seconds=90,
                                       now=START + dt.timedelta(seconds=41 + rescue.SETUP_WAIT_SECONDS)).action,
                         "watch")
        late = START + dt.timedelta(seconds=44 + rescue.SETUP_WAIT_SECONDS)
        look = rescue.assess([changes()(60), waiting], now=late, budget_seconds=90)
        self.assertEqual(look.action, "rescue")
        self.assertIn("runner setup", look.reason)
        self.assertEqual(rescue.assess([changes()(60), setup_job(past_setup=True)], now=late,
                                       budget_seconds=90).action, "watch")
        # a job that entered setup late is judged before the watch ends, but not before the queued budget
        soon = START + dt.timedelta(seconds=44 + 300)
        self.assertEqual(rescue.assess([changes()(60), waiting], now=soon, budget_seconds=90,
                                       deadline=soon + dt.timedelta(seconds=rescue.END_MARGIN_SECONDS)).action,
                         "rescue")
        early_close = START + dt.timedelta(seconds=44 + 30)
        self.assertEqual(rescue.assess([changes()(60), waiting], now=early_close, budget_seconds=90,
                                       deadline=early_close).action, "watch")
        # a sibling still running is not cancelled for it, until the watch is about to end
        shard = job("macos / shard", status="in_progress", labels=[MINI], runner="mini-2")
        look = rescue.assess([changes()(60), waiting, shard], now=late, budget_seconds=90)
        self.assertEqual((look.action, look.waiting), ("watch", True))
        look = rescue.assess([changes()(60), waiting, shard], now=late, budget_seconds=90,
                             deadline=late + dt.timedelta(seconds=rescue.END_MARGIN_SECONDS - 1))
        self.assertEqual(look.action, "rescue")


class Refusal(unittest.TestCase):
    def test_refusals_only_queue_alarm_keeps_watching_until_dev_refusal(self):
        clock = Clock()

        def jobs(seconds):
            found = [changes()(seconds)]
            if seconds >= 300:
                found.append(refused_job("cmux NEXT DEV Release compile"))
            elif seconds >= 40:
                found.append(job("cmux NEXT DEV Release compile", labels=[MINI], created=40))
            return found

        api = FakeAPI(clock, jobs, marker=True, settles_after=10)
        target = rescue.Target(RUN_ID, 1, HEAD, 0, path=rescue.CMUX_NEXT_WORKFLOW_PATH,
                               side=True, refusals_only=True)
        outcome = rescue.follow(api, target, seconds=90, queue_rounds="0",
                                now=clock.now, sleep=clock.sleep, log=lambda text: None)
        self.assertEqual(outcome, "done")
        self.assertIn("rerun", api.calls)
        self.assertNotIn("rerun-failed", api.calls)

    def test_dev_refusal_reruns_every_job_after_a_completed_run(self):
        clock = Clock()
        api = FakeAPI(clock, lambda seconds: [refused_job("cmux NEXT DEV Release compile")],
                      marker=True, finished=lambda seconds: True, conclusion="failure")
        target = rescue.Target(RUN_ID, 1, HEAD, 0, path=rescue.CMUX_NEXT_WORKFLOW_PATH,
                               side=True)
        outcome = rescue.follow(api, target, seconds=90, queue_rounds="0",
                                now=clock.now, sleep=clock.sleep, log=lambda text: None)
        self.assertEqual(outcome, "done")
        self.assertIn("rerun", api.calls)
        self.assertNotIn("rerun-failed", api.calls)

    def test_missing_pinned_xcode_on_owned_runner_is_refused_even_after_helper_build(self):
        steps = [
            {"name": "Set up job", "conclusion": "success"},
            {"name": "Checkout", "conclusion": "success"},
            {"name": "Build helper", "conclusion": "success"},
            {"name": "Select helper Xcode", "conclusion": "failure"},
        ]
        failed = refused_job(seconds=rescue.REFUSAL_SECONDS + 500, steps=steps)
        self.assertTrue(rescue.refused(failed))
        self.assertEqual(rescue.assess([failed], now=START, budget_seconds=90).action, "refused")
        steps[-1]["name"] = "Select Xcode"
        self.assertTrue(rescue.refused(failed))
        self.assertFalse(rescue.refused({**failed, "labels": [BLACKSMITH]}))
        steps[-1]["name"] = "Build"
        self.assertFalse(rescue.refused(failed))

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

    def test_a_hook_refusal_after_a_long_capacity_wait_is_a_refusal(self):
        # Job 122357989139 (run 40551896747, PR 26269): glaeda's hook waited 766 s in
        # "Set up runner" for capacity, then refused because a fleet build had started
        # waiting for the host. Past REFUSAL_SECONDS, it must still be re-run, not left red.
        steps = [
            {"name": "Set up job", "conclusion": "success"},
            {"name": "Set up runner", "conclusion": "failure"},
            {"name": "Compile-check the app at the pull request's head on the build fleet",
             "conclusion": "skipped"},
            {"name": "Complete runner", "conclusion": "success"},
            {"name": "Complete job", "conclusion": "success"},
        ]
        late = refused_job("cmux-next app compile (build fleet)", seconds=770, steps=steps)
        self.assertTrue(rescue.refused(late))
        self.assertEqual(rescue.assess([late], now=START + dt.timedelta(seconds=900),
                                       budget_seconds=90).action, "refused")
        self.assertFalse(rescue.accepted(late, START + dt.timedelta(hours=1)))
        # An `always()` step that fails after the refusal changes nothing.
        steps.insert(3, {"name": "Record compile admission metrics", "conclusion": "failure"})
        self.assertTrue(rescue.refused(late))
        # Only the hook's own step: a late "Set up job" failure, a passed hook, or a job off the
        # owned pools is not a refusal.
        self.assertFalse(rescue.refused(refused_job(seconds=rescue.REFUSAL_SECONDS + 1)))
        steps[1] = {"name": "Set up runner", "conclusion": "success"}
        steps[2] = {"name": steps[2]["name"], "conclusion": "failure"}
        self.assertFalse(rescue.refused(late))
        steps[1] = {"name": "Set up runner", "conclusion": "failure"}
        self.assertFalse(rescue.refused({**late, "labels": [BLACKSMITH]}))

    def test_a_late_hook_refusal_is_rerun_once_the_run_finishes(self):
        steps = [{"name": "Set up job", "conclusion": "success"},
                 {"name": "Set up runner", "conclusion": "failure"},
                 {"name": "Build", "conclusion": "skipped"}]
        clock = Clock()
        api = FakeAPI(clock, refusing_run(refused_at=0, seconds=770, steps=steps), marker=True,
                      finished=lambda seconds: True)
        target = rescue.sweep_target(listed(RUN_ID), "manaflow-ai/cmux", late=False)
        rescue.follow(api, target, seconds=90, queue_rounds="0",
                      now=clock.now, sleep=clock.sleep, log=lambda text: None)
        self.assertEqual(api.calls.count("rerun-failed"), 1)
        # Before hook_refused() the same 770 s job was left red.
        with unittest.mock.patch.object(rescue, "hook_refused", return_value=False):
            clock = Clock()
            api = FakeAPI(clock, refusing_run(refused_at=0, seconds=770, steps=steps), marker=True,
                          finished=lambda seconds: True)
            rescue.follow(api, rescue.sweep_target(listed(RUN_ID), "manaflow-ai/cmux", late=False),
                          seconds=90, queue_rounds="0", now=clock.now, sleep=clock.sleep, log=lambda text: None)
            self.assertNotIn("rerun-failed", api.calls)

    def test_a_job_whose_runner_was_lost_counts_as_a_refusal_whatever_its_length(self):
        # PR 15160's run 36420353579: cmux14-glaeda took compile admission at 12:20:18
        # with its listener stopped; GitHub failed it at 12:30:18 ("The self-hosted
        # runner lost communication with the server") and it listed no step at all.
        lost = refused_job(seconds=600, steps=[])
        self.assertTrue(rescue.refused(lost))
        self.assertFalse(rescue.accepted(lost, START + dt.timedelta(hours=1)))
        # A job that ran its own steps and then failed is still the code's.
        self.assertFalse(rescue.refused(refused_job(seconds=600, steps=[
            {"name": "Set up job", "conclusion": "success"},
            {"name": "Checkout", "conclusion": "success"},
            {"name": "Build", "conclusion": "failure"}])))
        self.assertFalse(rescue.refused(refused_job(seconds=600, steps=[], labels=(BLACKSMITH,))))

    def test_a_lost_runner_is_rerun_once_the_run_finishes(self):
        clock = Clock()
        api = FakeAPI(clock, refusing_run(refused_at=0, seconds=600, steps=[]), marker=True,
                      finished=lambda seconds: True)
        target = rescue.sweep_target(listed(RUN_ID), "manaflow-ai/cmux", late=False)
        rescue.follow(api, target, seconds=90, queue_rounds="0",
                      now=clock.now, sleep=clock.sleep, log=lambda text: None)
        self.assertEqual(api.calls.count("rerun-failed"), 1)

    def test_a_job_whose_runner_was_stopped_mid_job_counts_as_a_refusal_whatever_its_length(self):
        # Job 121926149188 (run 40424205219, PR #25241, 2026-10-27): "Set up runner" (glaeda's hook) was
        # cancelled when the runner got a shutdown signal; the job failed and its `always()` steps passed.
        in_hook = refused_job(name="cmux-next Release compile (Xcode 26)", seconds=585, labels=(SIDE,), steps=[
            {"name": "Set up job", "conclusion": "success"},
            {"name": "Set up runner", "conclusion": "cancelled"},
            {"name": "Checkout", "conclusion": "skipped"},
            {"name": "Complete job", "conclusion": "success"}])
        self.assertTrue(rescue.refused(in_hook))
        # Job 121931705481 (run 40425653402, PR #25768): stopped twelve minutes in, inside "Run the fast tier".
        in_step = refused_job(name="cmux-next fast tier", seconds=760, labels=(SIDE,), steps=[
            {"name": "Set up job", "conclusion": "success"},
            {"name": "Set up runner", "conclusion": "success"},
            {"name": "Checkout", "conclusion": "success"},
            {"name": "Select Xcode", "conclusion": "success"},
            {"name": "Run the fast tier", "conclusion": "cancelled"},
            {"name": "Complete job", "conclusion": "success"}])
        self.assertTrue(rescue.refused(in_step))
        self.assertEqual(rescue.decided_failures([in_hook, in_step]), [])
        # A step that failed (a step timeout too) is the code's; a cancelled job or a Blacksmith job is not ours.
        failed_step = [dict(step, conclusion="failure") if step["conclusion"] == "cancelled" else step
                       for step in in_step["steps"]]
        self.assertFalse(rescue.refused({**in_step, "steps": failed_step}))
        # Tests failed, then the runner was stopped in an `always()` upload: still the code's failure.
        failed_then_stopped = in_step["steps"][:-2] + [{"name": "Run the fast tier", "conclusion": "failure"},
                                                      {"name": "Upload logs", "conclusion": "cancelled"},
                                                      {"name": "Complete job", "conclusion": "success"}]
        failed_then_stopped = {**in_step, "steps": failed_then_stopped}
        self.assertFalse(rescue.refused(failed_then_stopped))
        self.assertEqual(rescue.decided_failures([failed_then_stopped]), ["cmux-next fast tier"])
        self.assertFalse(rescue.refused({**in_step, "conclusion": "cancelled"}))
        self.assertFalse(rescue.refused({**in_step, "labels": [BLACKSMITH]}))

    def test_an_open_heads_stopped_runner_is_rerun_once_its_run_finishes_without_a_cancel(self):
        clock = Clock()
        api = FakeAPI(clock, refusing_run(refused_at=0, seconds=760, labels=(SIDE,), steps=[
            {"name": "Set up job", "conclusion": "success"},
            {"name": "Run the fast tier", "conclusion": "cancelled"},
            {"name": "Complete job", "conclusion": "success"}]), marker=True, finished=lambda seconds: True)
        target = rescue.sweep_target(listed(RUN_ID, path=rescue.CMUX_NEXT_WORKFLOW_PATH,
                                            pull_requests=[{"number": 25768}]), "manaflow-ai/cmux", late=False)
        rescue.follow(api, target, seconds=90, queue_rounds="0",
                      now=clock.now, sleep=clock.sleep, log=lambda text: None)
        self.assertEqual(api.calls.count("rerun-failed"), 1)
        self.assertNotIn("cancel", api.calls)
        self.assertNotIn("force-cancel", api.calls)

    def test_a_job_no_runner_acquired_is_rerun_once_the_run_finishes_red(self):
        # Run 39607661629 (2026-10-21): GitHub cancelled ios-simulator-build after 4 minutes on
        # glaeda-ios-sim ("not acquired by Runner of type self-hosted"), and the run ended in failure.
        lost = unacquired_job()
        self.assertTrue(rescue.unacquired(lost))
        self.assertFalse(rescue.refused(lost))
        self.assertFalse(rescue.unacquired(unacquired_job(labels=(BLACKSMITH,))))
        self.assertFalse(rescue.unacquired({**lost, "runner_name": "mini-1"}))
        self.assertFalse(rescue.unacquired({**lost, "steps": [{"name": "Set up job", "conclusion": "success"}]}))
        clock = Clock()
        api = FakeAPI(clock, lambda seconds: [changes()(seconds), unacquired_job()], marker=True,
                      finished=lambda seconds: True, conclusion="failure")
        _, summary = run_main(api, clock)
        self.assertNotIn("cancel", api.calls)
        self.assertEqual(api.calls.count("rerun-failed"), 1)
        self.assertIn(f"cancelled by GitHub: no {MINI} runner acquired it", summary)

    def test_a_rerun_no_runner_acquires_either_is_not_rerun_without_end(self):
        # A cmux-next lane's test-ios re-run asks for the same owned label (test-ios.yml's NEXT_LANE
        # retry_runs_on), so it can go unacquired again. This watch re-runs once and ends.
        clock = Clock()
        api = FakeAPI(clock, lambda seconds: [changes()(seconds), unacquired_job()], marker=True,
                      finished=lambda seconds: True, conclusion="failure",
                      rerun_jobs=lambda seconds: [unacquired_job()])
        run_main(api, clock)
        self.assertEqual(api.calls.count("rerun-failed"), 1)
        self.assertEqual(api.calls[-1], "rerun-failed")
        # A later sweeper resumes test-ios through attempt 2 at most (no owned_rerun() past it), and
        # cmux-next's bot re-runs through attempt 3, whose re-run takes Blacksmith: two re-runs at most.
        stranded = {"status": "completed", "conclusion": "failure", "triggering_actor": {"login": ACTIONS_BOT}}
        for path, last in ((".github/workflows/test-ios.yml", rescue.LAST_OWNED_ATTEMPT),
                           (rescue.CMUX_NEXT_WORKFLOW_PATH, rescue.REFUSAL_RESCUE_ATTEMPT)):
            self.assertEqual(rescue.sweep_target(listed(RUN_ID, path=path, run_attempt=last + 1, **stranded),
                                                 "manaflow-ai/cmux", late=False), f"attempt {last + 1}")

    def test_a_run_cancelled_as_a_whole_is_not_rerun(self):
        # A newer push or a person cancelled it: its queued jobs look unacquired, and stay cancelled.
        clock = Clock()
        api = FakeAPI(clock, lambda seconds: [changes()(seconds), unacquired_job()], marker=True,
                      finished=lambda seconds: True, conclusion="cancelled")
        run_main(api, clock)
        self.assertNotIn("rerun-failed", api.calls)
        self.assertNotIn("rerun", api.calls)

    def test_a_refused_job_of_a_running_run_is_cancelled_only_without_an_open_head(self):
        clock = Clock()
        api = FakeAPI(clock, refusing_run(), marker=True)
        code, summary = run_main(api, clock)
        self.assertEqual(code, 0)
        # Still running at the watch's end, at the open pull request's head: nothing is cancelled.
        self.assertIn(f"refused by {MINI} at job start", summary)
        assert_left_at_open_head(self, api, summary)
        # Main's dispatch (no pull request) is still cancelled and its failed jobs re-run (a refusal re-runs
        # main's run whether or not main moved, so no head is read).
        clock = Clock()
        api = FakeAPI(clock, refusing_run(), marker=True)
        code, summary = run_main(api, clock, payload=main_event())
        self.assertEqual(code, 0)
        rerun = api.calls.index("rerun-failed")
        self.assertEqual(api.calls[rerun - 2:rerun + 1], ["cancel", "run", "rerun-failed"])
        # Attempt 2 goes back to the owned labels, where the sweeper watches
        # it (owned_reruns()), so this watch ends with the re-run.
        self.assertEqual(api.calls[rerun + 1:], [])
        self.assertIn("attempt 2 goes back to the owned labels, where the sweeper watches it", summary)

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
        assert_left_at_open_head(self, api, summary)

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

    def test_a_refused_shard_waits_for_its_running_siblings_instead_of_cancelling_them(self):
        # Run 36198335113: shards 2/7 and 6/7 were refused while the other
        # shards and the CLI product tests ran fine. Cancelling to re-run the
        # refused ones killed the healthy jobs, and attempt 3 put all of them on
        # Blacksmith. GitHub refuses any re-run while the run is going, so wait.
        def jobs(seconds):
            sibling = job("macos / app-host unit tests (1/7)", labels=[MINI], created=40, runner="mini-2",
                          status="completed" if seconds >= 900 else "in_progress")
            sibling["started_at"] = stamp(41)
            if seconds >= 900:
                sibling.update(conclusion="success", completed_at=stamp(900))
            return [changes()(seconds), refused_job("macos / app-host unit tests (2/7)"), sibling]

        clock = Clock()
        api = FakeAPI(clock, jobs, marker=True, finished=lambda seconds: seconds >= 900)
        _, summary = run_main(api, clock)
        self.assertNotIn("cancel", api.calls)
        self.assertNotIn("force-cancel", api.calls)
        self.assertEqual(api.calls.count("rerun-failed"), 1)
        self.assertGreaterEqual(api.rerun_at, 900)
        self.assertIn("waiting for the rest of the run to finish", summary)
        self.assertIn("re-ran the failed jobs", summary)

    def test_a_finished_run_with_a_refusal_needs_no_cancel(self):
        clock = Clock()
        api = FakeAPI(clock, refusing_run(), marker=True, finished=lambda seconds: seconds >= 60)
        _, summary = run_main(api, clock)
        self.assertNotIn("cancel", api.calls)
        self.assertEqual(api.calls[-1], "rerun-failed")
        self.assertIn("re-ran the failed jobs", summary)

    def test_a_refusal_is_retried_once_and_this_watch_leaves_attempt_2_to_the_sweeper(self):
        # A retry never loops: attempt 2 takes the owned label (not the refusing
        # runner's pin), the sweeper watches it, and its own rescue is attempt
        # 3, which every runs-on sends to retry_runner. This watch re-runs once.
        clock = Clock()
        api = FakeAPI(clock, refusing_run(), marker=True, finished=lambda seconds: seconds >= 60,
                      rerun_jobs=lambda seconds: [refused_job()])
        result, summary = run_main(api, clock)
        self.assertEqual(api.calls.count("rerun-failed"), 1)
        self.assertNotIn("jobs:2", api.calls)
        self.assertIn("attempt 2 goes back to the owned labels", summary)
        # Attempt 2's own rescue goes to Blacksmith.
        target = rescue.target_from_event(event(), "manaflow-ai/cmux")
        self.assertIn("attempt 3 takes retry_runner on Blacksmith",
                      rescue.next_attempt(dataclasses.replace(target, attempt=2)))

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
        _, summary = run_main(api, clock, payload=main_event())
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
        self.assertIn(f"queued on {MINI}", summary)
        assert_left_at_open_head(self, api, summary)
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
        _, summary = run_main(api, clock, payload=main_event(), env_extra={"RESCUE_SECONDS": "600", "QUEUE_ROUNDS": "50"})
        self.assertIn(f"for at least {longest}s", summary)
        self.assertEqual(api.calls[-4:], ["cancel", "run", "branch:main", "rerun"])

    def test_a_shard_queued_behind_a_later_run_is_not_rescued(self):
        # Run A took free minis; run B came later and took the idle ones A's
        # shards would have used (nothing is reserved). A's job waits 5 minutes
        # behind B's: well within the pool's expected wait, so A is left alone.
        # CI_OWNED_POOL_RESCUE_SECONDS is 30 on manaflow-ai/cmux (2026-09-25).
        clock = Clock()
        api = FakeAPI(clock, persistent_run(compile_started_at=40 + 300), marker=True)
        # Main's dispatch, which the rescue still cancels: so "no cancel" is the budget's doing.
        code, summary = run_main(api, clock, payload=main_event(), env_extra={"RESCUE_SECONDS": "30", "QUEUE_ROUNDS": ""})
        self.assertEqual(code, 0)
        self.assertIn(f"budget {30 + rescue.QUEUE_ROUND_SECONDS}s", summary)
        self.assertNotIn("cancel", api.calls)
        self.assertNotIn("rescue:", summary)

    def test_a_ci_job_waiting_past_the_expected_wait_is_still_rescued(self):
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True)
        code, summary = run_main(api, clock, payload=main_event(), env_extra={"RESCUE_SECONDS": "30", "QUEUE_ROUNDS": ""})
        self.assertEqual(api.calls[-4:], ["cancel", "run", "branch:main", "rerun"])
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
        _, summary = run_main(api, clock, payload=main_event(), env_extra={"RESCUE_SECONDS": "600", "QUEUE_ROUNDS": "3"})
        self.assertEqual(api.calls[-4:], ["cancel", "run", "branch:main", "rerun"])
        self.assertLess(api.cancelled_at, rescue.WATCH_LIMIT_SECONDS)
        budget = int(summary.split("for at least ")[1].split("s")[0])
        self.assertLess(budget, rescue.WATCH_LIMIT_SECONDS - 1500 - rescue.END_MARGIN_SECONDS + 1)
        self.assertLess(budget, 3300)
        # An early job keeps its whole budget.
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True)
        _, summary = run_main(api, clock, payload=main_event(), env_extra={"RESCUE_SECONDS": "600", "QUEUE_ROUNDS": "3"})
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
        _, summary = run_main(api, clock, payload=main_event(), env_extra={"RESCUE_SECONDS": "30", "QUEUE_ROUNDS": "0"})
        self.assertIn("for at least 30s", summary)
        self.assertLess(api.cancelled_at, 40 + 30 + rescue.POLL_SECONDS + 1)

    def test_only_ci_test_ios_and_e2e_runs_get_the_expected_wait(self):
        # iOS screenshots and side-lane runs have no queueing picker.
        for payload in (e2e_event(path=".github/workflows/ios-screenshots.yml"),):
            clock = Clock()
            api = FakeAPI(clock, lambda s: [e2e_runner()(s)])
            _, summary = run_main(api, clock, payload=payload,
                                  env_extra={"RESCUE_SECONDS": "30", "QUEUE_ROUNDS": ""})
            self.assertIn("(budget 30s)", summary, payload["workflow_run"]["path"])
        # ios_runner_pool.py and e2e_runner_pool.py queue within CI_PR_POOL_QUEUE_ROUNDS.
        for payload in (e2e_event(path=".github/workflows/test-ios.yml"), event(path=".github/workflows/test-ios.yml"),
                        e2e_event()):
            clock = Clock()
            api = FakeAPI(clock, lambda s: [e2e_runner()(s)])
            _, summary = run_main(api, clock, payload=payload,
                                  env_extra={"RESCUE_SECONDS": "30", "QUEUE_ROUNDS": "2"})
            self.assertIn(f"(budget {30 + 2 * rescue.QUEUE_ROUND_SECONDS}s", summary)

    def test_the_workflow_passes_the_rounds_and_ci_uploads_no_queue_marker(self):
        doc = yaml.safe_load((ROOT / ".github/workflows/ci-owned-pool-rescue.yml").read_text())
        step = doc["jobs"]["rescue"]["steps"][-1]
        self.assertEqual(step["env"]["QUEUE_ROUNDS"], "${{ vars.CI_PR_POOL_QUEUE_ROUNDS }}")
        self.assertEqual(step["env"]["SIDE_RESCUE_SECONDS"], "${{ vars.CI_OWNED_POOL_RESCUE_SECONDS }}")
        self.assertNotIn("macos-pool-queued", (ROOT / ".github/workflows/ci.yml").read_text())


def pool_rounds(value):
    return rescue.parse_queue_rounds(value)


class Rescuing(unittest.TestCase):
    def test_a_job_waiting_past_the_budget_reruns_the_run(self):
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True)
        code, summary = run_main(api, clock, payload=main_event())
        self.assertEqual(code, 0)
        start = api.calls.index("cancel")
        self.assertEqual(api.calls[start:start + 4], ["cancel", "run", "branch:main", "rerun"])
        # The full re-run picks again; the sweeper watches attempt 2 (owned_reruns()), not this watch.
        self.assertEqual(api.calls[start + 4:], [])
        self.assertIn(f"queued on {MINI} for at least 90s", summary)
        self.assertIn("attempt 2 picks again, the owned machines free now first", summary)
        # Rescued at the first look past 40 + 90 seconds.
        self.assertLess(api.cancelled_at, 40 + 90 + rescue.POLL_SECONDS + 1)

    def follow_attempt_2(self, api, clock, *, full_rerun=True, queue_rounds="0"):
        """The sweeper's watch of attempt 2 (sweep_target() on a listed re-run)."""
        api.attempt = 2
        target = rescue.sweep_target(dict(event()["workflow_run"], run_attempt=2), "manaflow-ai/cmux",
                                     late=False, full_rerun=full_rerun)
        with unittest.mock.patch("sys.stdout", io.StringIO()):
            lines = []
            outcome = rescue.follow(api, target, seconds=90, queue_rounds=queue_rounds, now=clock.now,
                                    sleep=clock.sleep, log=lines.append)
        return outcome, "\n".join(lines)

    def test_a_full_re_run_is_watched_the_attempt_1_way(self):
        # The full re-run runs `changes` again. Its macOS jobs are created only
        # once the picker has chosen, so the first look at attempt 2 sees
        # `changes` alone; the watch must wait for the picker and read
        # attempt 2's own marker, then move a job stuck on the fleet to Blacksmith.
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=lambda name: True, rerun_jobs=persistent_run())
        outcome, log = self.follow_attempt_2(api, clock)
        self.assertEqual(outcome, "done")
        self.assertIn(f"artifact:{rescue.MARKER_PREFIX}-{RUN_ID}-2-", api.calls)
        assert_left_at_open_head(self, api, log)
        self.assertIn(f"queued on {MINI}", log)
        # Attempt 2 without its own marker waits for late-placement's, then stops.
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=lambda name: name.endswith("-1-"),
                      rerun_jobs=lambda seconds: [changes()(seconds),
                                                  job(rescue.LATE_JOB, status="completed", created=40)])
        outcome, _ = self.follow_attempt_2(api, clock)
        self.assertNotIn("rerun-failed", api.calls)
        self.assertIn(f"artifact:{rescue.LATE_MARKER_PREFIX}-{RUN_ID}-2", api.calls)
        self.assertEqual(outcome, "stopped: late placement moved no job onto a persistent pool")

    def test_a_full_re_run_is_watched_past_its_accepted_admission(self):
        # Attempt 2's first looks see only admission, running on the fleet; its
        # shard is created once admission finishes, and is stuck there.
        clock = Clock()

        def rerun_jobs(seconds):
            found = [changes()(seconds)]
            if seconds >= 40:
                admission = job("macos / macOS compile admission", labels=[LIGHT], created=40,
                                status="in_progress" if seconds < 300 else "completed", runner="mini-1")
                admission.update(started_at=stamp(40), conclusion=None if seconds < 300 else "success")
                found.append(admission)
            if seconds >= 300:
                found.append(job("macos / app-host shard 1", labels=[LIGHT], created=300))
            return found

        api = FakeAPI(clock, persistent_run(), marker=lambda name: True, rerun_jobs=rerun_jobs)
        outcome, log = self.follow_attempt_2(api, clock)
        self.assertEqual(outcome, "done")
        self.assertNotIn("the fleet accepted the retry", log)
        assert_left_at_open_head(self, api, log)
        self.assertIn(f"queued on {LIGHT}", log)

    def test_a_re_run_of_failed_jobs_waits_for_a_late_placement_that_re_ran(self):
        # Attempt 1's admission failed on Blacksmith; attempt 2 re-runs it
        # there, and late-placement after it may move the shards onto the fleet.
        clock = Clock()

        def rerun_jobs(seconds):
            done = seconds >= 300
            found = [job(rescue.ADMISSION_JOB, labels=[BLACKSMITH], created=0, runner="bs-1",
                         status="completed" if done else "in_progress")]
            if seconds >= 300:
                # Created as admission finishes.
                late = job(rescue.LATE_JOB, created=300, status="completed" if seconds >= 320 else "queued")
                late.update(started_at=stamp(301), conclusion="success" if seconds >= 320 else None)
                found.append(late)
            if seconds >= 330:
                found.append(job("macos / app-host shard 1", labels=[MINI], created=330))
            # A Linux job keeps the re-run going until its shard queues.
            return found + [job("linux-preflight", status="in_progress", labels=["blacksmith-4vcpu-ubuntu-2404"])]

        api = FakeAPI(clock, persistent_run(), marker=lambda name: True, rerun_jobs=rerun_jobs)
        outcome, log = self.follow_attempt_2(api, clock, full_rerun=False)
        self.assertEqual(outcome, "done")
        self.assertIn(f"artifact:{rescue.LATE_MARKER_PREFIX}-{RUN_ID}-2", api.calls)
        assert_left_at_open_head(self, api, log)
        self.assertIn(f"queued on {MINI}", log)
        # Nothing re-ran late-placement and nothing asked for the fleet: the first look decides.
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), rerun_jobs=lambda seconds: [
            job("macos / tests", status="in_progress", labels=[BLACKSMITH], created=0, runner="bs-1")])
        outcome, _ = self.follow_attempt_2(api, clock, full_rerun=False)
        self.assertEqual(outcome, "stopped: no job of this attempt asked for a persistent pool")

    def test_a_re_run_of_a_failed_owned_admission_waits_for_its_shards(self):
        # The bot's attempt 2 re-runs a failed admission on the root label. Past the refusal window every owned
        # job counts as accepted, but this attempt's shards exist only after its admission: the watch goes on
        # and rescues a shard stuck on the owned label.
        clock = Clock()
        root = "glaeda-root-std-xcode-26.6"

        def rerun_jobs(seconds):
            admission = job(rescue.ADMISSION_JOB, labels=[root], created=0, runner="mini-1",
                            status="completed" if seconds >= 900 else "in_progress")
            admission.update(started_at=stamp(5))
            found = [admission]
            if seconds >= 900:
                late = job(rescue.LATE_JOB, created=900, status="completed" if seconds >= 920 else "queued")
                late.update(started_at=stamp(901), conclusion="success" if seconds >= 920 else None)
                found.append(late)
            if seconds >= 930:
                found.append(job("macos / app-host shard 1", labels=[MINI], created=930))
            return found + [job("linux-preflight", status="in_progress", labels=["blacksmith-4vcpu-ubuntu-2404"])]

        api = FakeAPI(clock, persistent_run(), marker=lambda name: True, rerun_jobs=rerun_jobs)
        outcome, log = self.follow_attempt_2(api, clock, full_rerun=False)
        self.assertEqual(outcome, "done")
        self.assertNotIn("the fleet accepted the retry", log)
        assert_left_at_open_head(self, api, log)
        self.assertIn(f"queued on {MINI}", log)
        # A failed-only re-run whose admission passed in attempt 1 still stops once the fleet accepted it.
        clock = Clock()
        shard = job("macos / app-host shard 1", labels=[MINI], created=0, runner="mini-1", status="in_progress")
        shard.update(started_at=stamp(5))
        api = FakeAPI(clock, persistent_run(), rerun_jobs=lambda seconds: [shard])
        outcome, _ = self.follow_attempt_2(api, clock, full_rerun=False)
        self.assertEqual(outcome, "stopped: the fleet accepted the retry")

    def test_a_re_run_gets_the_queue_allowance_of_attempt_1(self):
        # A re-run of failed jobs queues on the owned labels like attempt 1's jobs, so a job waiting within the
        # rounds is left where it is.
        clock = Clock()
        rerun = lambda seconds: [job("macos / app-host shard 1", labels=[MINI], created=0,
                                     status="queued" if seconds < 600 else "in_progress",
                                     runner="" if seconds < 600 else "mini-1"),
                                 job("macos / macOS status", created=0, status="queued" if seconds < 900 else "completed",
                                     labels=[BLACKSMITH])]
        api = FakeAPI(clock, persistent_run(), rerun_jobs=rerun)
        outcome, log = self.follow_attempt_2(api, clock, full_rerun=False, queue_rounds="1")
        self.assertIn(f"budget {90 + rescue.QUEUE_ROUND_SECONDS}s", log)
        self.assertNotIn("rerun-failed", api.calls)
        self.assertTrue(outcome.startswith("stopped"), outcome)

    def test_budget_variable_moves_the_deadline(self):
        clock = Clock()
        api = FakeAPI(clock, persistent_run(compile_started_at=200), marker=True, finished=lambda s: s >= 400)
        _, summary = run_main(api, clock, payload=main_event(), env_extra={"RESCUE_SECONDS": "300"})
        self.assertNotIn("cancel", api.calls)
        self.assertNotIn("rescue:", summary)

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
        _, summary = run_main(api, clock, payload=main_event())
        self.assertNotIn("rerun", api.calls)
        self.assertIn("someone else already re-ran", summary)

    def test_a_push_during_the_cancel_is_not_overwritten(self):
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True)
        heads = iter([HEAD, "b" * 40])
        # Main's dispatch: a pull request's run at its open head is never cancelled (OPEN_HEAD_RULE).
        api.branch_head = lambda branch: next(heads)
        _, summary = run_main(api, clock, payload=main_event())
        self.assertIn("cancel", api.calls)
        self.assertNotIn("rerun", api.calls)
        self.assertIn("cancelled but not re-run", summary)

    def test_a_rerun_by_someone_else_during_the_cancel_is_left_alone(self):
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True, settles_after=10_000)
        original = api.run
        api.run = lambda run_id: ({"status": "queued", "run_attempt": 2} if api.cancelled_at is not None
                                  else original(run_id))
        code, summary = run_main(api, clock, payload=main_event())
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
        code, summary = run_main(api, clock, payload=main_event())
        self.assertEqual(code, 0)
        self.assertIn("rerun", api.calls)
        self.assertIn("retrying", summary)

    def test_wait_counts_from_first_sight_when_created_at_is_early(self):
        clock = Clock()
        # The record claims it queued at 0 s, but the job first appears at 300 s.
        jobs = lambda s: [changes()(s)] + ([job("late consumer", labels=[MINI], created=0)] if s >= 300 else [])
        api = FakeAPI(clock, jobs, marker=True)
        run_main(api, clock, payload=main_event())
        self.assertGreaterEqual(api.cancelled_at, 300 + 90)

    def test_a_slow_cancel_is_waited_out_and_re_run(self):
        # Run 36074561333: a Mac mid-compile took over 5 minutes to settle
        # after a force-cancel, and a 180 s wait left the run cancelled for good.
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True, settles_after=330)
        code, _ = run_main(api, clock, payload=main_event())
        self.assertEqual(code, 0)
        self.assertGreaterEqual(api.calls.count("force-cancel"), 1)
        self.assertIn("rerun", api.calls)

    def test_no_cancel_starts_without_time_to_settle_and_re_run(self):
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True)
        target = rescue.Target(run_id=555, attempt=1, head_sha=HEAD, pr_number=0, main=True)
        deadline = clock.now() + rescue.dt.timedelta(
            seconds=rescue.CANCEL_WAIT_SECONDS + rescue.RERUN_MARGIN_SECONDS - 1)
        result = rescue.rescue(api, target, now=clock.now, sleep=clock.sleep, log=lambda _: None,
                               deadline=deadline)
        self.assertEqual(result, "not rescued: too little of the job left to cancel and re-run")
        self.assertNotIn("cancel", api.calls)

    def test_no_cancel_starts_without_time_for_the_rate_limit_waits_too(self):
        # A watch that may still wait out rate limits needs that time on top of the settle.
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True)
        api.rate_limit_waited = 0.0
        target = rescue.Target(run_id=555, attempt=1, head_sha=HEAD, pr_number=0, main=True)
        deadline = clock.now() + rescue.dt.timedelta(
            seconds=rescue.CANCEL_WAIT_SECONDS + rescue.RERUN_MARGIN_SECONDS + rescue.RATE_LIMIT_WAIT_SECONDS - 1)
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
        code, _ = run_main(api, clock, payload=main_event())
        self.assertEqual(code, 0)
        self.assertGreaterEqual(api.calls.count("force-cancel"), 2)
        self.assertIn("rerun", api.calls)

    def test_force_cancel_again_then_give_up_only_at_the_wait_limit(self):
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True, settles_after=10_000)
        code, summary = run_main(api, clock, payload=main_event())
        self.assertEqual(code, 1)
        self.assertGreater(api.calls.count("force-cancel"), 1)
        self.assertGreaterEqual(clock.seconds - api.cancelled_at, rescue.CANCEL_WAIT_SECONDS)
        self.assertNotIn("rerun", api.calls)
        self.assertIn("did not finish", summary)

    def test_rate_limit_waits_do_not_end_the_settle_window(self):
        # A force-cancel that waited 15 minutes through a rate limit must not cost the re-run:
        # only the run's own settling counts toward CANCEL_WAIT_SECONDS.
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True, settles_after=rescue.CANCEL_WAIT_SECONDS + 600)
        api.rate_limit_waited = 0.0

        def limited_force_cancel(run_id):
            api.calls.append("force-cancel")
            if api.rate_limit_waited == 0.0:
                clock.sleep(rescue.RATE_LIMIT_WAIT_SECONDS)
                api.rate_limit_waited = float(rescue.RATE_LIMIT_WAIT_SECONDS)
        api.force_cancel = limited_force_cancel
        code, summary = run_main(api, clock, payload=main_event())
        self.assertEqual(code, 0, summary)
        self.assertIn("rerun", api.calls)


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
        # The build never finished, so every job re-runs and the sibling wait looks again.
        self.assertEqual(api.calls[-2:], ["rerun", "jobs:2"])  # attempt 2 is checked and ends on Blacksmith
        self.assertIn("cancel", api.calls)
        self.assertNotIn("rerun-failed", api.calls)

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
        self.assertEqual(api.calls[-2:], ["rerun", "jobs:2"])  # attempt 2 is checked and ends on Blacksmith
        self.assertIn("refused", summary)
        self.assertIn("so its sibling wait runs again", summary)

    def test_a_full_e2e_rerun_on_the_fleet_is_followed_by_its_marker(self):
        # Attempt 2 of a full re-run takes the runner job's new pick, which may
        # be an owned Mac. The watch follows it by attempt 2's own marker, and a
        # second refusal moves the run on to attempt 3 (always Blacksmith).
        def jobs(seconds):
            found = [e2e_runner()(seconds)]
            if seconds >= 60:
                found.append(refused_job("build"))
            return found

        def rerun_jobs(seconds):
            found = [e2e_runner()(seconds)]
            if seconds >= 60:
                found.append(refused_job("build"))
            elif seconds >= 30:
                found.append(job("build", labels=[MINI], created=30))
            return found
        clock = Clock()
        markers = []
        api = FakeAPI(clock, jobs, marker=lambda name: markers.append(name) or True,
                      finished=lambda s: s >= 60, rerun_jobs=rerun_jobs)
        code, summary = run_main(api, clock, payload=e2e_event())
        self.assertEqual(code, 0)
        self.assertEqual(api.calls.count("rerun"), 2, summary)
        self.assertEqual(api.attempt, 3)
        self.assertIn(f"{rescue.MARKER_PREFIX}-{RUN_ID}-2-", markers)
        self.assertIn("attempt 3 takes retry_runner on Blacksmith", summary)

    def test_a_full_e2e_rerun_on_blacksmith_ends_the_watch(self):
        def jobs(seconds):
            found = [e2e_runner()(seconds)]
            if seconds >= 60:
                found.append(refused_job("build"))
            return found
        clock = Clock()
        api = FakeAPI(clock, jobs, marker=lambda name: name.endswith("-1-"),
                      finished=lambda s: s >= 60,
                      rerun_jobs=lambda s: [e2e_runner()(s), job("build", labels=[BLACKSMITH])])
        code, summary = run_main(api, clock, payload=e2e_event())
        self.assertEqual(code, 0)
        self.assertEqual(api.calls.count("rerun"), 1)
        self.assertIn("ephemeral pool", summary)

    def test_an_e2e_run_whose_build_passed_keeps_it(self):
        # Only the test job failed: re-running every job would compile again.
        def jobs(seconds):
            passed = dict(job("build", labels=[MINI], created=10, status="completed"), conclusion="success")
            found = [e2e_runner()(seconds), passed]
            if seconds >= 60:
                found.append(refused_job("test"))
            return found
        clock = Clock()
        api = FakeAPI(clock, jobs, marker=True, finished=lambda s: s >= 60)
        code, summary = run_main(api, clock, payload=e2e_event())
        self.assertEqual(code, 0)
        self.assertIn("rerun-failed", api.calls)
        self.assertNotIn("rerun", api.calls)

    def test_only_e2e_runs_rerun_every_job_for_an_unfinished_build(self):
        clock = Clock()
        api = FakeAPI(clock, lambda s: [refused_job("build")])
        target = rescue.Target(run_id=RUN_ID, attempt=1, head_sha="a" * 40, pr_number=7)
        self.assertFalse(rescue.e2e_build_unfinished(api, target, clock.sleep, lambda text: None))
        self.assertEqual(api.calls, [], "a ci.yml run is not read here")


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


DEV_DAILY = ".github/workflows/cmux-next-dev-daily.yml"
DEV_WORKFLOW = (ROOT / DEV_DAILY).read_text()


def dev_event(**overrides):
    return e2e_event(**{"path": DEV_DAILY, **overrides})


def blacksmith_snapshot(*, queued=0, running=0, oldest=0, label=BLACKSMITH):
    """A janitor snapshot with one Blacksmith label's load (simple_pool_picker reads the same fields)."""
    return lambda seconds: {"generated_at": stamp(seconds), "pools": {
        label: {"queued": queued, "running": running, "oldest_queued_minutes": oldest}}}


def dev_jobs(seconds):
    """Run 40466780519: verify and tip-dmg-build queued on the light owned pool, never taken."""
    found = [e2e_runner()(seconds)]
    if seconds >= 40:
        found += [job("Verify signed cmux NEXT DEV", labels=[LIGHT], created=40),
                  job("Build the unsigned cmux NEXT DEV tip DMG", labels=[LIGHT], created=40)]
    return found


class Killed(BaseException):
    """The sweeper's job stopped (cancelled, killed, out of time) in the middle of a rescue: GitHub's SIGINT raises
    KeyboardInterrupt, a BaseException no `except Exception` catches."""


class CancelledAPI(FakeAPI):
    """A DEV run whose cancel leaves its queued owned jobs as GitHub does (cancelled, no runner, no step) and the run
    concluded `cancelled`, with `note` as the jobs' "canceled by" annotation (an exception: unreadable), and
    `rescue_log` as the log of the rescue jobs that ran meanwhile."""

    def __init__(self, clock, *, note=f"The run was canceled by @{CMUX_BOT}.", cancelled=False, rescue_log=(),
                 extra=(), **kwargs):
        super().__init__(clock, lambda seconds: dev_jobs(seconds) + list(extra), marker=True, workflow=DEV_WORKFLOW,
                         **kwargs)
        self.note, self.rescue_log = note, rescue_log
        if cancelled:
            self.cancelled_at, self.cancel_attempt = 0.0, 1

    def settled(self):
        return self.attempt == 1 and self.cancelled_at is not None and \
            self.clock.seconds - self.cancelled_at >= self.settles_after

    def run(self, run_id):
        found = super().run(run_id)
        return {**found, "conclusion": "cancelled", "id": run_id, "updated_at": stamp(self.clock.seconds)} \
            if self.settled() else found

    def jobs(self, run_id, attempt):
        found = super().jobs(run_id, attempt)
        if attempt != 1 or not self.settled():
            return found
        return [{**found_job, "id": index, "status": "completed", "conclusion": "cancelled", "steps": []}
                if found_job.get("status") == "queued" else {**found_job, "id": index}
                for index, found_job in enumerate(found, 1)]

    def annotations(self, job_id, *, final=False):
        self.calls.append(f"annotations:{job_id}")
        if isinstance(self.note, Exception):
            raise self.note
        return [{"annotation_level": "failure", "message": self.note}] if self.note else []

    def rescue_jobs(self, earliest_end, run_id=0):
        self.calls.append("rescue-jobs")
        return [7001]

    def job_marks(self, job_id):
        self.calls.append(f"log:{job_id}")
        return rescue.cancel_marks(self.rescue_log)


def log_response(body, *, length="auto", cut=None, chunked=False, repeat=1):
    """A job log's HTTP response: `body` (`repeat` times), its Content-Length (`length`, "auto" the true one), cut
    off after `cut` bytes as a dropped connection does, recording each readline() limit."""
    class Response(io.BytesIO):
        def __init__(self):
            super().__init__(body[:cut] if cut is not None else body * (1 if repeat > 10 else repeat))
            self.reads, self.left = [], repeat
            self.headers = {}
            if length is not None:
                self.headers["Content-Length"] = str(len(body) * repeat if length == "auto" else length)
            if chunked:
                self.headers["Transfer-Encoding"] = "chunked"

        def readline(self, limit=-1):
            self.reads.append(limit)
            line = super().readline(limit)
            if not line and repeat > 10 and self.left > 1:
                self.left -= 1
                self.seek(0)
                line = super().readline(limit)
            return line

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False
    return Response()


class StrandedCancel(unittest.TestCase):
    """A rescue that stopped between its cancel and its re-run leaves the run to the next watch, which re-runs it;
    every other cancel is final."""

    def follow(self, api, clock, log=lambda _: None):
        target = rescue.Target(RUN_ID, 1, HEAD, 0, e2e=True, path=DEV_DAILY)
        return rescue.follow(api, target, seconds=30, queue_rounds="0", now=clock.now, sleep=clock.sleep, log=log)

    def test_a_sweeper_killed_between_the_cancel_and_the_re_run_strands_nothing(self):
        clock = Clock()
        killed_log = []
        api = CancelledAPI(clock, rescue_log=killed_log)
        target = rescue.Target(RUN_ID, 1, HEAD, 0, e2e=True, path=DEV_DAILY)

        def killed(seconds):
            raise Killed()
        with self.assertRaises(Killed):
            rescue.follow(api, target, seconds=30, queue_rounds="0", now=clock.now, sleep=clock.sleep,
                          log=killed_log.append, rescue_sleep=killed)
        self.assertEqual(mutations(api), ["cancel"])
        self.assertIn(f"{rescue.CANCEL_SENT} run {RUN_ID} attempt 1", killed_log)
        self.assertNotIn(f"{rescue.CANCEL_SETTLED} run {RUN_ID} attempt 1", killed_log)
        clock.advance(api.settles_after)
        # The next sweeper adopts the run again (by its marker): cancelled by the bot, and the killed rescue's own
        # log says it meant to re-run it.
        lines = []
        self.assertEqual(self.follow(api, clock, lines.append), "done")
        self.assertEqual(mutations(api), ["cancel", "rerun-failed"])
        self.assertTrue(any("stopped before the re-run" in line for line in lines), lines)

    def test_a_rescue_killed_after_cancelling_a_job_held_in_setup_is_resumed(self):
        # The cancelled job had a runner and its setup step (glaeda's hook held it): not unacquired, still the
        # rescue's own cancel, so its re-run follows.
        held = {**job("Verify signed cmux NEXT DEV", labels=[LIGHT], runner="mini-1"), "id": 1, "status": "completed",
                "conclusion": "cancelled", "steps": [{"name": "Set up runner", "conclusion": "cancelled"}]}
        clock = Clock()
        api = CancelledAPI(clock, cancelled=True, rescue_log=[f"{rescue.CANCEL_SENT} run {RUN_ID} attempt 1"])
        api.jobs_at = lambda seconds: [e2e_runner()(seconds)]
        jobs = api.jobs

        def with_held(run_id, attempt):
            return jobs(run_id, attempt) + ([held] if attempt == 1 else [])
        api.jobs = with_held
        clock.advance(60)
        self.assertEqual(self.follow(api, clock), "done")
        self.assertEqual(mutations(api), ["rerun-failed"])

    def test_a_resumed_rescue_re_runs_what_the_stopped_one_meant(self):
        for tail, want in (("", ["rerun-failed"]), (rescue.EVERY_JOB, ["rerun"]),
                           (rescue.ONE_JOB.format(3), ["rerun-job:3"])):
            clock = Clock()
            api = CancelledAPI(clock, cancelled=True,
                               rescue_log=[f"{rescue.CANCEL_SENT} run {RUN_ID} attempt 1{tail}"])
            clock.sleep(60)
            lines = []
            self.assertEqual(self.follow(api, clock, lines.append), "done", tail)
            self.assertEqual(mutations(api), want, tail)
            self.assertIn(f"{rescue.CANCEL_SETTLED} run {RUN_ID} attempt 1", lines)
        self.assertEqual(rescue.cancel_marks([f"{rescue.CANCEL_SENT} run 5 attempt 1{rescue.EVERY_JOB}",
                                              f"{rescue.CANCEL_SENT} run 6 attempt 10",
                                              f"{rescue.CANCEL_SENT} run 7 attempt 2 of job 123874955999"]),
                         {(5, 1): "sent all", (6, 10): "sent", (7, 2): "sent job 123874955999"})

    def test_a_rewatch_that_finds_a_stopped_rescue_resumes_its_re_run(self):
        # The refusals-only rewatch after a queue alarm, and the E2E watch of the next attempt, can also find a run a
        # rescue cancelled and stopped before re-running: both finish that re-run, as the first watch does.
        for case in ("refusals only", "next attempt"):
            clock = Clock()
            api = CancelledAPI(clock)
            looks = iter([("rescue", "queue alarm"), ("resume", "all")])
            resumed = []

            def resume_rerun(api, target, *, now, sleep, log, every_job, only_job=None):
                resumed.append((target.attempt, every_job))
                return "re-ran it"
            target = rescue.Target(RUN_ID, 1, HEAD, 0, e2e=True, path=DEV_DAILY, refusals_only=case == "refusals only")
            with unittest.mock.patch.object(rescue, "watch", lambda *args, **kwargs: next(looks)), \
                    unittest.mock.patch.object(rescue, "resume_rerun", resume_rerun), \
                    unittest.mock.patch.object(rescue, "hold_for_destination",
                                               lambda client, target, outcome, reason, **_: (outcome, reason, "")), \
                    unittest.mock.patch.object(rescue, "rescue",
                                               lambda *args, **kwargs: f"re-ran every job of run {RUN_ID}"):
                result = rescue.follow(api, target, seconds=30, queue_rounds="0", now=clock.now, sleep=clock.sleep,
                                       log=lambda _: None)
            self.assertEqual(result, "done", case)
            self.assertEqual(resumed, [(1 if case == "refusals only" else 2, True)], case)
        # A mark logged with Windows line endings still counts.
        self.assertEqual(rescue.cancel_marks([f"{rescue.CANCEL_SETTLED} run 5 attempt 1\r\n",
                                              f"{rescue.CANCEL_SENT} run 6 attempt 2{rescue.EVERY_JOB}\r\n"]),
                         {(5, 1): "settled", (6, 2): "sent all"})

    def test_the_next_attempt_s_destination_hold_resumes_a_stopped_rescue(self):
        # The hold (the real one) watches on while the re-run's label is stalled, and finds attempt 2 cancelled by a
        # rescue that stopped before re-running it: that re-run is finished, never left cancelled.
        clock = Clock()
        api = CancelledAPI(clock)
        looks = iter([("rescue", "queue alarm"), ("rescue", "queue alarm"), ("resume", "failed")])
        verdicts = iter([("free", BLACKSMITH), ("stalled", BLACKSMITH)])
        resumed, logged = [], []

        def resume_rerun(api, target, *, now, sleep, log, every_job, only_job=None):
            resumed.append((target.attempt, every_job))
            return "re-ran it"
        target = rescue.Target(RUN_ID, 1, HEAD, 0, e2e=True, path=DEV_DAILY)
        with unittest.mock.patch.object(rescue, "watch", lambda *args, **kwargs: next(looks)), \
                unittest.mock.patch.object(rescue, "resume_rerun", resume_rerun), \
                unittest.mock.patch.object(rescue, "repicks", lambda target: False), \
                unittest.mock.patch.object(rescue, "pull_moved", lambda *args: False), \
                unittest.mock.patch.object(rescue, "move_verdict", lambda *args, **kwargs: next(verdicts)), \
                unittest.mock.patch.object(rescue, "rescue",
                                           lambda *args, **kwargs: f"re-ran every job of run {RUN_ID}"):
            result = rescue.follow(api, target, seconds=30, queue_rounds="0", now=clock.now, sleep=clock.sleep,
                                   log=logged.append)
        self.assertEqual(result, "done", logged)
        self.assertEqual(resumed, [(2, False)], logged)
        self.assertTrue(any("is stalled" in line for line in logged), logged)

    def test_a_rescue_history_past_the_page_cap_leaves_the_run_cancelled(self):
        api = rescue.GitHub("t", "manaflow-ai/cmux")
        pages = []

        def request(method, path, **_):
            if path.startswith("/actions/workflows/"):
                pages.append(path)
                return {"workflow_runs": [{"id": len(pages), "conclusion": "skipped"}]}
            return {"jobs": []}
        api.request = request
        with self.assertRaises(rescue.RescueHistoryCapped):
            api.rescue_jobs(START)
        self.assertEqual(len(pages), rescue.RESCUE_RUN_PAGES)
        clock = Clock()
        cancelled = CancelledAPI(clock, cancelled=True, rescue_log=[f"{rescue.CANCEL_SENT} run {RUN_ID} attempt 1"])
        cancelled.rescue_jobs = lambda earliest_end, run_id=0: (_ for _ in ()).throw(rescue.RescueHistoryCapped("capped"))
        clock.advance(60)
        lines = []
        self.assertEqual(rescue.rerun_intended(cancelled, cancelled.run(RUN_ID), 1, clock.sleep, lines.append), "")
        self.assertTrue(any("left cancelled" in line for line in lines), lines)

    def test_a_re_run_rescue_workflow_keeps_its_earlier_attempts_marks(self):
        # The sweeper run was re-run: attempt 1 (SENT, then stopped) is finished, attempt 2 runs. Both are read.
        api = rescue.GitHub("t", "manaflow-ai/cmux")
        asked = []
        runs = {"workflow_runs": [{"id": 3, "status": "in_progress", "conclusion": None, "run_attempt": 2,
                                   "run_started_at": stamp(-60), "updated_at": stamp(0)}]}

        def request(method, path, **_):
            asked.append(path)
            if path.startswith("/actions/workflows/"):
                return runs if "&page=1&" in path else {}
            attempt = int(path.split("/attempts/")[1].split("/")[0])
            return {"jobs": [{"id": 30 + attempt, "status": "in_progress" if attempt == 2 else "completed",
                              "conclusion": None if attempt == 2 else "cancelled"}]}
        api.request = request
        self.assertEqual(api.rescue_jobs(START - dt.timedelta(seconds=600)), [31])
        self.assertNotIn("status=completed", asked[0])
        self.assertEqual([path for path in asked if "/attempts/" in path],
                         ["/actions/runs/3/attempts/2/jobs?per_page=20", "/actions/runs/3/attempts/1/jobs?per_page=20"])

    def test_a_cancel_after_the_watch_looked_is_never_re_run(self):
        # The watch found a refusal; before rescue() read the run, someone cancelled it. No cancel was this rescue's.
        clock = Clock()
        api = CancelledAPI(clock, cancelled=True, note="The run was canceled by @leo.")
        clock.sleep(60)
        target = rescue.Target(RUN_ID, 1, HEAD, 0, e2e=True, path=DEV_DAILY)
        for refused in (True, None):
            result = rescue.rescue(api, target, now=clock.now, sleep=clock.sleep, log=lambda _: None,
                                   failed_only=True, refused=refused, refusal=True)
            self.assertEqual(result, "not rescued: the run was cancelled by @leo meanwhile; left cancelled", refused)
        self.assertEqual(mutations(api), [])

    def test_a_re_run_of_the_rescue_workflow_acts_on_nothing(self):
        # Its marks could fall outside rescue_jobs()' creation window (the run keeps attempt 1's created_at).
        clock = Clock()
        api = CancelledAPI(clock, rescue_log=[f"{rescue.CANCEL_SENT} run {RUN_ID} attempt 1"])
        for extra in ({"GITHUB_RUN_ATTEMPT": "2"}, {"GITHUB_RUN_ATTEMPT": "3", "SWEEP": "1"}):
            code, summary = run_main(api, clock, env_extra=extra)
            self.assertEqual(code, 0)
            self.assertIn("a re-run of the rescue workflow acts on nothing", summary)
        self.assertEqual(api.calls, [])

    def test_a_live_sweeper_s_unread_settlement_leaves_the_run_cancelled(self):
        # R1 stopped after its cancel (SENT); R2, a sweeper still running, resumed it, hit an error and logged SETTLED.
        # R2's log cannot be read until it ends, so another watch must not read R1's intent alone.
        def listing(live):
            return {"workflow_runs": [
                {"id": 1, "status": "completed", "conclusion": "cancelled", "run_attempt": 1,
                 "display_title": "owned-pool-sweeper", "run_started_at": stamp(-3600), "updated_at": stamp(-100)},
                {"id": 2, "run_attempt": 1, "run_started_at": stamp(-60), "updated_at": stamp(0), **live}]}
        for live, raises in (({"status": "in_progress", "display_title": "owned-pool-sweeper"}, True),
                             ({"status": "in_progress", "display_title": f"owned-pool-rescue-{RUN_ID}-1"}, True),
                             ({"status": "in_progress", "display_title": "owned-pool-rescue-99-1"}, False),
                             ({"status": "queued", "display_title": "owned-pool-sweeper"}, False)):
            api = rescue.GitHub("t", "manaflow-ai/cmux")
            api.request = lambda method, path, **_: (listing(live) if "&page=1&" in path else {}) \
                if path.startswith("/actions/workflows/") else {"jobs": [{"id": 11, "status": "completed"}]}
            if raises:
                with self.assertRaises(rescue.RescueHistoryLive, msg=live):
                    api.rescue_jobs(START - dt.timedelta(seconds=600), RUN_ID)
            else:
                self.assertTrue(api.rescue_jobs(START - dt.timedelta(seconds=600), RUN_ID), live)
            # The reader's own run never counts.
            api.own_run = 2
            self.assertTrue(api.rescue_jobs(START - dt.timedelta(seconds=600), RUN_ID), live)
        clock = Clock()
        api = CancelledAPI(clock, cancelled=True, rescue_log=[f"{rescue.CANCEL_SENT} run {RUN_ID} attempt 1"])
        api.rescue_jobs = lambda earliest_end, run_id=0: (_ for _ in ()).throw(rescue.RescueHistoryLive("live"))
        clock.advance(60)
        self.assertEqual(self.follow(api, clock), f"stopped: the run was cancelled by @{CMUX_BOT}; left cancelled")
        self.assertEqual(mutations(api), [])

    def test_a_sweeper_never_resumes_an_attempt_it_settled_itself(self):
        # The sweeper resumed R1's stopped re-run, the re-run POST failed (503) and it logged SETTLED: its own log is
        # not read while it runs, so a later watch in it of the same attempt must not read R1's SENT alone.
        clock = Clock()
        api = CancelledAPI(clock, cancelled=True, rescue_log=[f"{rescue.CANCEL_SENT} run {RUN_ID} attempt 1"])
        clock.advance(60)

        def refused(run_id, attempt):
            raise urllib.error.HTTPError("u", 503, "unavailable", None, io.BytesIO(b""))
        api.rerun_failed = refused
        with unittest.mock.patch.object(rescue, "SETTLED_HERE", set()):
            with self.assertRaises(Exception):
                self.follow(api, clock)
            self.assertIn((RUN_ID, 1), rescue.SETTLED_HERE)
            api.calls.clear()
            self.assertEqual(self.follow(api, clock), f"stopped: the run was cancelled by @{CMUX_BOT}; left cancelled")
            self.assertEqual(mutations(api), [])

    def test_a_janitor_cancel_by_the_same_bot_stays_cancelled(self):
        # The queue janitor cancels as cmux-bot too (a superseded DEV run that never started, an orphan): no rescue
        # sent a cancel of this run's attempt, or it settled that cancel (re-ran it, or left it for a moved head).
        sent, settled = f"{rescue.CANCEL_SENT} run {RUN_ID} attempt 1", f"{rescue.CANCEL_SETTLED} run {RUN_ID} attempt 1"
        for rescue_log in ((), (f"{rescue.CANCEL_SENT} run {RUN_ID + 1} attempt 1",),
                           (f"{rescue.CANCEL_SENT} run {RUN_ID} attempt 2",), (sent, settled)):
            clock = Clock()
            api = CancelledAPI(clock, cancelled=True, rescue_log=rescue_log)
            clock.sleep(60)
            self.assertEqual(self.follow(api, clock), f"stopped: the run was cancelled by @{CMUX_BOT}; left cancelled")
            self.assertEqual(mutations(api), [], rescue_log)

    def test_someone_elses_cancel_is_final_even_beside_a_refusal(self):
        refused = {**refused_job("Verify signed cmux NEXT DEV (shard 2)", labels=(LIGHT,)), "id": 99}
        for note, said in (("The run was canceled by @leo.", "stopped: the run was cancelled by @leo; left cancelled"),
                           (urllib.error.HTTPError("u", 403, "no checks: read", None, io.BytesIO(b"")),
                            "stopped: the run was cancelled, and who cancelled it could not be read; left cancelled")):
            clock = Clock()
            api = CancelledAPI(clock, note=note, cancelled=True, extra=[refused],
                               rescue_log=[f"{rescue.CANCEL_SENT} run {RUN_ID} attempt 1"])
            clock.sleep(60)
            self.assertEqual(self.follow(api, clock), said)
            self.assertEqual(mutations(api), [], note)

    def test_real_http_responses_cut_short_are_not_judged(self):
        # http.client's own framing: a chunked body cut after the SENT chunk, and a sized one cut short.
        import http.client
        sent, settled = f"{rescue.CANCEL_SENT} run 5 attempt 1\n".encode(), f"{rescue.CANCEL_SETTLED} run 5 attempt 1\n".encode()

        class Sock:
            def __init__(self, data):
                self.data = data

            def makefile(self, mode, *args, **kwargs):
                return io.BytesIO(self.data)

        def response(head, body):
            found = http.client.HTTPResponse(Sock(b"HTTP/1.1 200 OK\r\n" + head + b"\r\n" + body))
            found.begin()
            return found
        api = rescue.GitHub("t", "manaflow-ai/cmux")
        chunked = response(b"Transfer-Encoding: chunked\r\n", b"%x\r\n" % len(sent) + sent + b"\r\n")
        cut = response(b"Content-Length: %d\r\n" % len(sent + settled), sent)
        whole = response(b"Content-Length: %d\r\n" % len(sent + settled), sent + settled)
        for name, body, want in (("chunked", chunked, None), ("cut", cut, None), ("whole", whole, {(5, 1): "settled"})):
            with unittest.mock.patch.object(rescue.urllib.request, "build_opener",
                                            lambda *handlers, body=body: types.SimpleNamespace(
                                                open=lambda request, timeout: contextlib.nullcontext(body))):
                api._logs.clear()
                self.assertEqual(api.job_marks(13), want, name)

    def test_a_canceller_named_past_the_read_cap_is_unknown_not_none(self):
        refused = {**refused_job("Verify signed cmux NEXT DEV (shard 2)", labels=(LIGHT,)), "id": 99}
        many = [{**job(f"leg {index}", labels=[LIGHT]), "status": "completed", "conclusion": "cancelled", "steps": []}
                for index in range(rescue.CANCELLED_BY_READS + 1)]
        clock = Clock()
        api = CancelledAPI(clock, note="", cancelled=True, extra=[refused, *many])
        clock.advance(60)
        self.assertEqual(self.follow(api, clock),
                         "stopped: the run was cancelled, and who cancelled it could not be read; left cancelled")
        self.assertEqual(mutations(api), [])

    def test_annotations_are_paged_and_a_full_last_page_is_unknown(self):
        api = rescue.GitHub("t", "manaflow-ai/cmux")
        pages = []

        def request(method, path, **_):
            page = int(path.split("&page=")[1])
            pages.append(page)
            full = [{"message": "lint"}] * 100
            if path_pages[0] == "short" and page == 2:
                return [{"message": "The run was canceled by @leo."}]
            return full
        api.request = request
        path_pages = ["short"]
        self.assertEqual(rescue.canceller(api, [{"id": 7, "conclusion": "cancelled"}], lambda _: None, lambda _: None),
                         "leo")
        self.assertEqual(pages, [1, 2])
        path_pages[0] = "endless"
        pages.clear()
        self.assertIsNone(rescue.canceller(api, [{"id": 7, "conclusion": "cancelled"}], lambda _: None, lambda _: None))
        self.assertEqual(pages, list(range(1, rescue.ANNOTATION_PAGES + 1)))

    def test_a_cancel_no_annotation_explains_keeps_the_old_rules(self):
        # GitHub's own cancels (a job timeout) write no "canceled by" line: the refusal and timeout rules decide.
        clock = Clock()
        api = CancelledAPI(clock, note="", cancelled=True)
        clock.advance(60)
        self.assertEqual(self.follow(api, clock), "stopped: the run finished")
        self.assertNotIn("rescue-jobs", api.calls)

    def test_a_successor_sweeper_adopts_a_recently_cancelled_marked_run(self):
        cancelled = listed(1, path=DEV_DAILY, event="workflow_dispatch", pull_requests=[], status="completed",
                           conclusion="cancelled", updated_at=stamp(0))
        old = dict(cancelled, id=2, updated_at=stamp(-3 * 3600))
        success = dict(cancelled, id=3, conclusion="success")
        api = SweepAPI([cancelled, old, success], picker=[1, 2, 3])
        self.assertEqual(Sweeper.sweep(Sweeper(), api)[0], [(1, 1, False)])
        self.assertIsInstance(rescue.sweep_target(cancelled, "manaflow-ai/cmux", late=False), rescue.Target)

    def test_a_re_run_attempt_is_not_read_or_touched(self):
        for actor in (ACTIONS_BOT, CMUX_BOT, "leo"):
            api = CancelledAPI(Clock(), note=f"The run was canceled by @{actor}.")
            jobs = [{**job("Verify signed cmux NEXT DEV", labels=[LIGHT]), "id": 9, "status": "completed",
                     "conclusion": "cancelled", "steps": []}]
            self.assertEqual(rescue.canceller(api, jobs, lambda _: None, lambda _: None), actor)
        # Someone re-ran it meanwhile: the watch of attempt 1 reads no annotation and re-runs nothing.
        clock = Clock()
        api = CancelledAPI(clock, cancelled=True, attempt_after_cancel=2)
        clock.advance(60)
        api.run = lambda run_id: {"status": "completed", "conclusion": "cancelled", "run_attempt": 2}
        self.follow(api, clock)
        self.assertEqual(mutations(api), [])
        self.assertFalse(any(call.startswith("annotations:") for call in api.calls))

    def test_the_rescue_jobs_read_are_those_alive_at_the_cancel(self):
        api = rescue.GitHub("t", "manaflow-ai/cmux")
        asked = []
        runs = {"workflow_runs": [
            {"id": 1, "conclusion": "cancelled", "run_started_at": stamp(-3600), "updated_at": stamp(-100)},
            {"id": 2, "conclusion": "success", "run_started_at": stamp(-7200), "updated_at": stamp(-5000)},
            {"id": 3, "conclusion": "skipped", "run_started_at": stamp(-50), "updated_at": stamp(-40)},
            {"id": 4, "conclusion": "success", "run_started_at": stamp(60), "updated_at": stamp(90)}]}

        def request(method, path, **_):
            asked.append(path)
            if path.startswith("/actions/workflows/"):
                return runs if "&page=1&" in path else {}
            return {"jobs": [{"id": int(path.split("/")[3]) * 10 + 1, "status": "completed", "conclusion": "cancelled"}]}
        api.request = request
        # Run 1 was alive at the cancel; run 4 started later (a successor that may have settled it); run 2 ended
        # before the cancel and run 3 was skipped.
        self.assertEqual(api.rescue_jobs(START - dt.timedelta(seconds=1200)), [11, 41])
        self.assertEqual([path for path in asked if not path.startswith("/actions/workflows/")],
                         ["/actions/runs/1/attempts/1/jobs?per_page=20", "/actions/runs/4/attempts/1/jobs?per_page=20"])
        # A five-hour sweeper that rescued near its end is in the window, even one that first waited behind another.
        since = (START - dt.timedelta(seconds=1200 + 2 * rescue.RESCUE_JOB_LIFETIME_SECONDS)).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.assertIn(f"created=%3E%3D{since}", asked[0])
        self.assertGreaterEqual(rescue.RESCUE_JOB_LIFETIME_SECONDS, rescue.SWEEP_SECONDS + rescue.RESCUE_GRACE_SECONDS)

    def test_a_sweeper_that_queued_behind_another_is_in_the_window(self):
        # Created 05:30, waited in the sweeper group until 07:00, stopped 11:59:30; the cancelled run ended 12:00.
        api = rescue.GitHub("t", "manaflow-ai/cmux")
        asked = []
        end = START
        created = end - dt.timedelta(hours=6, minutes=30)
        runs = {"workflow_runs": [{"id": 1, "conclusion": "cancelled", "created_at": stamp(-6.5 * 3600),
                                   "run_started_at": stamp(-5 * 3600), "updated_at": stamp(-30)}]}

        def request(method, path, **_):
            asked.append(path)
            if path.startswith("/actions/workflows/"):
                since = rescue.urllib.parse.unquote(path.split("created=")[1])[2:]
                return runs if "&page=1&" in path and \
                    created >= dt.datetime.fromisoformat(since.replace("Z", "+00:00")) else {}
            return {"jobs": [{"id": 11, "status": "completed", "conclusion": "cancelled"}]}
        api.request = request
        self.assertEqual(api.rescue_jobs(end - dt.timedelta(seconds=rescue.CANCEL_WAIT_SECONDS)), [11])

    def test_the_rescue_run_listing_reads_past_a_short_page(self):
        api = rescue.GitHub("t", "manaflow-ai/cmux")
        pages = []

        def request(method, path, **_):
            if path.startswith("/actions/workflows/"):
                page = int(path.split("&page=")[1].split("&")[0])
                pages.append(page)
                found = {1: [{"id": index, "conclusion": "skipped"} for index in range(99)],
                         2: [{"id": 500, "conclusion": "cancelled", "run_started_at": stamp(-60),
                              "updated_at": stamp(0)}]}
                return {"workflow_runs": found.get(page, [])}
            return {"jobs": [{"id": 77, "status": "completed", "conclusion": "cancelled"}]}
        api.request = request
        self.assertEqual(api.rescue_jobs(START), [77])
        self.assertEqual(pages, [1, 2, 3])

    def test_a_rescue_that_stops_between_its_cancel_and_settling_is_the_only_mark_left(self):
        for stop, settled in (("moved", True), ("someone else re-ran", True), ("error", True), ("killed", False)):
            clock = Clock()
            lines = []
            api = CancelledAPI(clock)
            target = rescue.Target(RUN_ID, 1, HEAD, 0, e2e=True, path=DEV_DAILY)
            if stop == "moved":
                api.state = "closed"
                target = dataclasses.replace(target, pr_number=42)
            if stop == "someone else re-ran":
                api.attempt_after_cancel = 2
            if stop == "error":
                api.rerun_failed = lambda run_id, attempt: (_ for _ in ()).throw(rescue.Aborted("refused"))

            def killed(seconds):
                if stop == "killed":
                    raise Killed()
                clock.sleep(seconds)
            try:
                rescue.rescue(api, target, now=clock.now, sleep=killed, log=lines.append, failed_only=True)
            except (Killed, rescue.Aborted):
                pass
            marks = rescue.cancel_marks(lines)
            if stop == "moved":
                self.assertEqual(marks, {}, stop)  # never cancelled: the PR was closed before
                continue
            self.assertEqual(marks, {(RUN_ID, 1): "settled" if settled else "sent"}, stop)

    def test_a_guard_that_drops_the_cancel_leaves_no_mark(self):
        clock = Clock()
        lines = []
        api = CancelledAPI(clock)
        target = rescue.Target(RUN_ID, 1, HEAD, 0, e2e=True, path=DEV_DAILY)

        def guard():
            raise rescue.Aborted("the run changed")
        with self.assertRaises(rescue.Aborted):
            rescue.rescue(api, target, now=clock.now, sleep=clock.sleep, log=lines.append, failed_only=True,
                          before_cancel=guard)
        self.assertEqual(rescue.cancel_marks(lines), {})
        self.assertNotIn("cancel", api.calls)

    def test_a_job_log_follows_its_redirect_without_the_token(self):
        import email.message
        sent = []

        class Response(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        class Opener:
            def open(self, request, timeout=None):
                sent.append((request.full_url, request.headers.get("Authorization")))
                headers = email.message.Message()
                headers["Location"] = "https://logs.example/job-11"
                raise urllib.error.HTTPError(request.full_url, 302, "Found", headers, io.BytesIO(b""))

        def urlopen(url, timeout=None):
            sent.append((url, None))
            return log_response(f"x {rescue.CANCEL_SENT} run 5 attempt 1\nother\n".encode() * 3)
        api = rescue.GitHub("t", "manaflow-ai/cmux")
        with unittest.mock.patch.object(rescue.urllib.request, "build_opener", lambda *handlers: Opener()), \
                unittest.mock.patch.object(rescue.urllib.request, "urlopen", urlopen):
            self.assertEqual(api.job_marks(11), {(5, 1): "sent"})
            api.job_marks(11)  # read once
        self.assertEqual(sent, [(f"{rescue.API}/repos/manaflow-ai/cmux/actions/jobs/11/logs", "Bearer t"),
                                ("https://logs.example/job-11", None)])

    def test_a_log_past_the_cap_or_cut_short_is_not_judged(self):
        def marks(response, **patches):
            api = rescue.GitHub("t", "manaflow-ai/cmux")
            with unittest.mock.patch.multiple(rescue, **(patches or {"JOB_LOG_LINE_BYTES": rescue.JOB_LOG_LINE_BYTES})), \
                    unittest.mock.patch.object(rescue.urllib.request, "build_opener",
                                               lambda *handlers: types.SimpleNamespace(open=lambda request, timeout: response)):
                return api.job_marks(12), api
        sent, settled = f"{rescue.CANCEL_SENT} run 5 attempt 1\n".encode(), f"{rescue.CANCEL_SETTLED} run 5 attempt 1\n".encode()
        # Past the cap.
        self.assertIsNone(marks(log_response(b"x" * 1023 + b"\n", repeat=10 ** 6), JOB_LOG_MAX_BYTES=64 * 1024)[0])
        # Cut short: the SETTLED mark was in the bytes that never came. Not judged, and not cached.
        found, api = marks(log_response(sent + settled, length=len(sent + settled), cut=len(sent)))
        self.assertIsNone(found)
        self.assertNotIn(12, api._logs)
        # No length, or chunked: whether it all came cannot be told.
        self.assertIsNone(marks(log_response(sent, length=None))[0])
        self.assertIsNone(marks(log_response(sent, length=None, chunked=True))[0])
        # A line longer than JOB_LOG_LINE_BYTES is read in bounded pieces and skipped; the marks around it count.
        long_line = b"y" * (3 * 1024 * 1024) + b"\n"
        response = log_response(sent + long_line + settled)
        self.assertEqual(marks(response, JOB_LOG_LINE_BYTES=4096)[0], {(5, 1): "settled"})
        self.assertLessEqual(max(response.reads), 4096)
        # And a successor reading such a log leaves the run cancelled.
        clock = Clock()
        cancelled = CancelledAPI(clock, cancelled=True)
        cancelled.job_marks = lambda job_id: None
        clock.advance(60)
        self.assertFalse(rescue.rerun_intended(cancelled, cancelled.run(RUN_ID), 1, clock.sleep, lambda _: None))

    def test_a_successor_that_resumed_the_re_run_stops_the_next_one(self):
        # The stopped sweeper logged SENT; the next (started after the run finished) resumed it and logged SETTLED.
        clock = Clock()
        api = CancelledAPI(clock, cancelled=True)
        clock.sleep(60)
        logs = {8002: f"{rescue.CANCEL_SETTLED} run {RUN_ID} attempt 1",
                7001: f"{rescue.CANCEL_SENT} run {RUN_ID} attempt 1"}
        api.rescue_jobs = lambda earliest_end, run_id=0: [8002, 7001]  # newest first
        api.job_marks = lambda job_id: rescue.cancel_marks([logs[job_id]])
        self.assertEqual(rescue.rerun_intended(api, api.run(RUN_ID), 1, clock.sleep, lambda _: None), "")
        api.rescue_jobs = lambda earliest_end, run_id=0: [7001]
        self.assertEqual(rescue.rerun_intended(api, api.run(RUN_ID), 1, clock.sleep, lambda _: None), "failed")


class BlacksmithStall(unittest.TestCase):
    """A queue rescue never moves a job onto a Blacksmith label the pickers call stalled (run 40466780519)."""

    def test_the_dev_daily_retry_label_comes_from_its_workflow(self):
        self.assertEqual(rescue.retry_labels(DEV_WORKFLOW), {BLACKSMITH})
        every = set(rescue.simple_pool_picker.BLACKSMITH)
        # A workflow that names no picker label, calls a reusable workflow or cannot be read may go anywhere.
        self.assertEqual(rescue.retry_labels("jobs:\n  a:\n    runs-on: ${{ needs.x.outputs.retry }}\n"), every)
        self.assertEqual(rescue.retry_labels(None), every)
        # A reusable workflow's input names the label; a call that names none may go anywhere.
        self.assertEqual(rescue.retry_labels(
            "jobs:\n  a:\n    uses: ./.github/workflows/x.yml\n    with:\n      r: blacksmith-6vcpu-macos-15\n"),
            {"blacksmith-6vcpu-macos-15"})
        self.assertEqual(rescue.retry_labels("jobs:\n  a:\n    uses: ./.github/workflows/resolve-dispatch-ref.yml\n"),
                         every)
        # A matrix entry or a reusable workflow's input counts, not only runs-on lines.
        self.assertIn("blacksmith-6vcpu-macos-15", rescue.retry_labels(
            "jobs:\n  a:\n    strategy:\n      matrix:\n        pool: [blacksmith-6vcpu-macos-15]\n"
            "    runs-on: ${{ matrix.pool }}\n"))
        self.assertEqual(rescue.retry_labels((ROOT / ".github/workflows/cmux-tui.yml").read_text()),
                         {"blacksmith-6vcpu-macos-15"})
        # A retry route a picker job computes may be any picker label, whatever else the file names.
        for name in ("ci.yml", "test-e2e.yml", "test-ios.yml", "ios-screenshots.yml"):
            self.assertEqual(rescue.retry_labels((ROOT / ".github/workflows" / name).read_text()), every, name)

    def test_only_the_labels_a_workflow_names_decide(self):
        target = rescue.Target(RUN_ID, 1, HEAD, 0, e2e=True, path=DEV_DAILY)
        stalled_12 = blacksmith_snapshot(queued=40, oldest=300, label="blacksmith-12vcpu-macos-26")
        api = FakeAPI(Clock(), dev_jobs, workflow="runs-on: blacksmith-6vcpu-macos-15\n", snapshot=stalled_12)
        self.assertEqual(rescue.move_verdict(api, target, now=START, sleep=lambda _: None, log=lambda _: None),
                         ("free", ""))
        # With two named, the worse decides.
        api = FakeAPI(Clock(), dev_jobs, workflow="a: blacksmith-6vcpu-macos-15\nb: blacksmith-12vcpu-macos-26\n",
                      snapshot=stalled_12)
        self.assertEqual(rescue.move_verdict(api, target, now=START, sleep=lambda _: None, log=lambda _: None),
                         ("stalled", "blacksmith-12vcpu-macos-26"))

    def test_states_use_the_pickers_stall_rule(self):
        now = START
        snapshot = {"generated_at": stamp(0), "pools": {
            BLACKSMITH: {"queued": 3, "running": 10, "oldest_queued_minutes": 10},
            "blacksmith-12vcpu-macos-26": {"queued": 1, "running": 5, "oldest_queued_minutes": 2},
        }}
        self.assertEqual(rescue.blacksmith_states(snapshot, now), {
            BLACKSMITH: "stalled", "blacksmith-12vcpu-macos-26": "busy", "blacksmith-6vcpu-macos-15": "free"})
        # The snapshot's age counts toward the wait, as in the pickers.
        later = START + dt.timedelta(minutes=8)
        snapshot["pools"]["blacksmith-12vcpu-macos-26"]["oldest_queued_minutes"] = 3
        self.assertEqual(rescue.blacksmith_states(snapshot, later)["blacksmith-12vcpu-macos-26"], "stalled")

    def test_a_dev_daily_run_stays_on_the_owned_pool_while_its_retry_label_is_stalled(self):
        clock = Clock()
        api = FakeAPI(clock, dev_jobs, marker=True, workflow=DEV_WORKFLOW,
                      snapshot=blacksmith_snapshot(queued=40, running=0, oldest=30))
        code, summary = run_main(api, clock, payload=dev_event())
        self.assertEqual(code, 0)
        self.assertNotIn("cancel", api.calls)
        self.assertNotIn("rerun", api.calls)
        self.assertNotIn("rerun-failed", api.calls)
        self.assertIn(f"kept on the owned pool: {BLACKSMITH} is stalled", summary)
        self.assertIn("watch limit reached", summary)
        # One look at the snapshot every STALL_RECHECK_SECONDS or so, not every poll.
        self.assertLessEqual(api.snapshot_reads,
                             rescue.E2E_WATCH_LIMIT_SECONDS // rescue.STALL_RECHECK_SECONDS + 1)

    def test_a_held_run_moves_once_its_retry_label_has_room(self):
        clock = Clock()
        moving = 30 * 60
        stalled = blacksmith_snapshot(queued=40, running=0, oldest=30)
        free = blacksmith_snapshot()
        api = FakeAPI(clock, dev_jobs, marker=True, workflow=DEV_WORKFLOW,
                      snapshot=lambda seconds: (stalled if seconds < moving else free)(seconds))
        code, summary = run_main(api, clock, payload=dev_event())
        self.assertEqual(code, 0)
        self.assertIn("cancel", api.calls)
        self.assertGreaterEqual(api.first_cancel, moving)
        self.assertIn("held on the owned pool", summary)

    def test_a_busy_retry_label_takes_the_job_only_after_the_owned_floor(self):
        clock = Clock()
        api = FakeAPI(clock, dev_jobs, marker=True, workflow=DEV_WORKFLOW,
                      snapshot=blacksmith_snapshot(queued=2, running=10, oldest=1))
        code, summary = run_main(api, clock, payload=dev_event())
        self.assertEqual(code, 0)
        self.assertIn("cancel", api.calls)
        # The jobs were first seen queued at the first look (45 s).
        self.assertGreaterEqual(api.first_cancel, rescue.FIRST_LOOK_SECONDS + rescue.OWNED_WAIT_FLOOR_SECONDS)
        self.assertIn("which has no free slot", summary)

    def test_a_free_retry_label_takes_the_job_at_the_configured_budget(self):
        clock = Clock()
        api = FakeAPI(clock, dev_jobs, marker=True, workflow=DEV_WORKFLOW)
        code, summary = run_main(api, clock, payload=dev_event())
        self.assertEqual(code, 0)
        self.assertIn("cancel", api.calls)
        self.assertLess(api.first_cancel, rescue.OWNED_WAIT_FLOOR_SECONDS)
        self.assertNotIn("held on the owned pool", summary)

    def test_an_unreadable_snapshot_waits_the_owned_floor(self):
        clock = Clock()
        api = FakeAPI(clock, dev_jobs, marker=True, workflow=DEV_WORKFLOW, snapshot=lambda seconds: None)
        run_main(api, clock, payload=dev_event())
        self.assertIn("cancel", api.calls)
        self.assertGreaterEqual(api.first_cancel, rescue.OWNED_WAIT_FLOOR_SECONDS)

    def test_a_stall_on_another_label_does_not_hold_the_run(self):
        clock = Clock()
        api = FakeAPI(clock, dev_jobs, marker=True, workflow=DEV_WORKFLOW,
                      snapshot=blacksmith_snapshot(queued=40, oldest=300, label="blacksmith-12vcpu-macos-26"))
        code, summary = run_main(api, clock, payload=dev_event())
        self.assertIn("cancel", api.calls)
        self.assertLess(api.first_cancel, rescue.OWNED_WAIT_FLOOR_SECONDS)
        self.assertIn(f"workflow:{DEV_DAILY}@{HEAD}", api.calls)

    def test_a_ci_attempt_1_picks_again_so_it_reads_no_snapshot(self):
        target = rescue.Target(RUN_ID, 1, HEAD, 0, main=True)
        self.assertTrue(rescue.repicks(target))
        self.assertFalse(rescue.repicks(dataclasses.replace(target, attempt=2)))
        self.assertFalse(rescue.repicks(rescue.Target(RUN_ID, 1, HEAD, 0, e2e=True, path=DEV_DAILY)))

    def test_a_late_job_moves_onto_a_busy_label_only_after_the_full_floor(self):
        # job_budget() cuts a budget near the deadline; the floor keeps the 10 minutes.
        late = rescue.E2E_WATCH_LIMIT_SECONDS - 200

        def jobs(seconds):
            found = [e2e_runner()(seconds)]
            if seconds >= late:
                found.append(job("Verify signed cmux NEXT DEV", labels=[LIGHT], created=late))
            return found
        clock = Clock()
        api = FakeAPI(clock, jobs, marker=True, workflow=DEV_WORKFLOW,
                      snapshot=blacksmith_snapshot(queued=2, running=10, oldest=1))
        run_main(api, clock, payload=dev_event())
        first = getattr(api, "first_cancel", None)
        self.assertTrue(first is None or first - late >= rescue.OWNED_WAIT_FLOOR_SECONDS, first)

    def test_a_refusal_beside_a_queued_sibling_is_not_held(self):
        def jobs(seconds):
            found = dev_jobs(seconds)[:2]  # runner, and verify queued on the owned pool
            if seconds >= 40:
                found.append({**job("Build the unsigned cmux NEXT DEV tip DMG", labels=[LIGHT], created=40),
                              "status": "completed", "conclusion": "failure", "runner_name": "mini",
                              "started_at": stamp(41), "completed_at": stamp(45),
                              "steps": [{"name": "Set up job", "conclusion": "failure"}]})
            return found
        clock = Clock()
        api = FakeAPI(clock, jobs, marker=True, workflow=DEV_WORKFLOW,
                      snapshot=blacksmith_snapshot(queued=40, running=0, oldest=30))
        _, summary = run_main(api, clock, payload=dev_event())
        self.assertNotIn("cancel", api.calls)
        self.assertIn("started delivery work", summary)

    def test_a_refusal_found_after_the_run_finished_during_a_hold_is_rerun(self):
        # verify and tip-dmg-build stay queued while Blacksmith stalls; then verify runs and passes and
        # tip-dmg-build is refused, and the run finishes, all between two looks of the hold.
        ran_at = 10 * 60

        def jobs(seconds):
            found = [e2e_runner()(seconds)]
            if seconds < 40:
                return found
            verify = job("Verify signed cmux NEXT DEV", labels=[LIGHT], created=40)
            dmg = job("Build the unsigned cmux NEXT DEV tip DMG", labels=[LIGHT], created=40)
            if seconds >= ran_at:
                verify = {**verify, "status": "completed", "conclusion": "success", "runner_name": "mini",
                          "started_at": stamp(ran_at - 400), "completed_at": stamp(ran_at),
                          "steps": [{"name": "Set up job", "conclusion": "success"},
                                    {"name": "Verify", "conclusion": "success"}]}
                dmg = {**dmg, "status": "completed", "conclusion": "failure", "runner_name": "mini",
                       "started_at": stamp(ran_at - 5), "completed_at": stamp(ran_at),
                       "steps": [{"name": "Set up job", "conclusion": "failure"}]}
            return found + [verify, dmg]
        clock = Clock()
        api = FakeAPI(clock, jobs, marker=True, workflow=DEV_WORKFLOW, conclusion="failure",
                      finished=lambda seconds: seconds >= ran_at,
                      snapshot=blacksmith_snapshot(queued=40, running=0, oldest=30))
        _, summary = run_main(api, clock, payload=dev_event())
        self.assertIn("held on the owned pool", summary)
        self.assertIn("rerun-failed", api.calls)

    def test_the_hold_hands_a_finished_refused_run_to_the_refusal_path(self):
        clock = Clock()
        refused_job = {**job("Build the unsigned cmux NEXT DEV tip DMG", labels=[LIGHT]), "status": "completed",
                       "conclusion": "failure", "runner_name": "mini", "started_at": stamp(1),
                       "completed_at": stamp(5), "steps": [{"name": "Set up job", "conclusion": "failure"}]}
        # Still in progress at the hold's look (a sibling runs on); it may finish before rescue() reads it.
        api = FakeAPI(clock, lambda seconds: [refused_job], finished=lambda seconds: False,
                      snapshot=blacksmith_snapshot(queued=40, running=0, oldest=30), workflow=DEV_WORKFLOW)
        target = rescue.Target(RUN_ID, 1, HEAD, 0, e2e=True, path=DEV_DAILY)
        outcome, _, _ = rescue.hold_for_destination(
            api, target, "rescue", "stuck", budget_seconds=90, floor_seconds=90,
            deadline=START + dt.timedelta(hours=1), now=clock.now, sleep=clock.sleep, log=lambda _: None, seen={})
        self.assertEqual(outcome, "refused")

    def test_a_refusal_on_the_last_look_of_a_hold_is_rerun(self):
        clock = Clock()
        refused_job = {**job("Build the unsigned cmux NEXT DEV tip DMG", labels=[LIGHT]), "status": "completed",
                       "conclusion": "failure", "runner_name": "mini", "started_at": stamp(1),
                       "completed_at": stamp(5), "steps": [{"name": "Set up job", "conclusion": "failure"}]}
        api = FakeAPI(clock, lambda seconds: [refused_job],
                      snapshot=blacksmith_snapshot(queued=40, running=0, oldest=30), workflow=DEV_WORKFLOW)
        target = rescue.Target(RUN_ID, 1, HEAD, 0, e2e=True, path=DEV_DAILY)
        outcome, _, _ = rescue.hold_for_destination(
            api, target, "rescue", "stuck", budget_seconds=90, floor_seconds=90,
            deadline=START, now=clock.now, sleep=clock.sleep, log=lambda _: None, seen={})
        self.assertEqual(outcome, "refused")

    def test_a_superseded_main_attempt_is_still_cancelled_while_blacksmith_stalls(self):
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True, head="b" * 40,
                      rerun_jobs=lambda seconds: [job("macos / tests", labels=[LIGHT])],
                      snapshot=blacksmith_snapshot(queued=40, running=0, oldest=30))
        api.attempt = 2
        target = rescue.Target(run_id=RUN_ID, attempt=2, head_sha=HEAD, pr_number=0, main=True)
        result = rescue.follow(api, target, seconds=90, queue_rounds="0", now=clock.now, sleep=clock.sleep,
                               log=lambda _: None)
        self.assertEqual(result, "done")
        self.assertIn("cancel", api.calls)
        self.assertNotIn("rerun-failed", api.calls)
        self.assertLess(api.first_cancel, rescue.OWNED_WAIT_FLOOR_SECONDS)

    def test_a_refusal_is_still_rerun_while_the_retry_label_is_stalled(self):
        # A refused job has already failed: holding it moves nothing, and its re-run is the only way it runs.
        def jobs(seconds):
            found = [e2e_runner()(seconds)]
            if seconds >= 40:
                found.append({**job("Verify signed cmux NEXT DEV", labels=[LIGHT], created=40),
                              "status": "completed", "conclusion": "failure", "runner_name": "mini",
                              "started_at": stamp(41), "completed_at": stamp(45),
                              "steps": [{"name": "Set up job", "conclusion": "failure"}]})
            return found
        clock = Clock()
        api = FakeAPI(clock, jobs, marker=True, workflow=DEV_WORKFLOW, finished=lambda seconds: seconds >= 45,
                      conclusion="failure", snapshot=blacksmith_snapshot(queued=40, running=0, oldest=30))
        run_main(api, clock, payload=dev_event())
        self.assertTrue({"rerun", "rerun-failed"} & set(api.calls))


class SideLanes(unittest.TestCase):
    def test_every_side_workflow_is_watched_like_a_pull_request(self):
        for path in sorted(rescue.SIDE_WORKFLOW_PATHS):
            target = rescue.target_from_event(side_event(path=path), "manaflow-ai/cmux")
            self.assertTrue(target.side, path)
            self.assertEqual((target.pr_number, target.watch_limit), (42, rescue.SIDE_WATCH_LIMIT_SECONDS))
        for why, payload in {"merge group": side_event(event="merge_group"),
                             "workflow_run": side_event(event="workflow_run"),
                             "pull_request_target": side_event(event="pull_request_target"),
                             "attempt 2": side_event(run_attempt=2),
                             "fork": side_event(head_repository={"full_name": "someone/cmux"}),
                             "fork push": side_event(event="push", head_repository={"full_name": "someone/cmux"}),
                             "not a side lane": side_event(path=".github/workflows/plain-paste-worker.yml")}.items():
            self.assertIsInstance(rescue.target_from_event(payload, "manaflow-ai/cmux"), str, why)

    def test_a_marked_cmux_next_run_is_adopted_as_a_side_lane(self):
        # cmux-next.yml lives on feat-cmux-next only and uploads the watch marker itself.
        run = dict(side_event(path=".github/workflows/cmux-next.yml", head_branch="feat-cmux-next-x",
                              status="queued")["workflow_run"])
        target = rescue.sweep_target(run, "manaflow-ai/cmux", late=False)
        self.assertTrue(target.side)
        self.assertEqual((target.pr_number, target.watch_limit), (42, rescue.SIDE_WATCH_LIMIT_SECONDS))
        fork = dict(run, head_repository={"full_name": "someone/cmux"})
        self.assertIsInstance(rescue.sweep_target(fork, "manaflow-ai/cmux", late=False), str)

    def test_trusted_non_pull_request_side_runs_are_watched_without_a_head(self):
        # A push, schedule or dispatch runs this repository's own branch: owned-eligible, and no
        # pull request head can move under it.
        for kind in ("push", "schedule", "workflow_dispatch"):
            for path in sorted(rescue.SIDE_WORKFLOW_PATHS):
                target = rescue.target_from_event(side_event(path=path, event=kind, pull_requests=[]),
                                                  "manaflow-ai/cmux")
                self.assertTrue(target.side, (kind, path))
                self.assertEqual((target.pr_number, target.e2e, target.main), (0, False, False))
        target = rescue.target_from_event(side_event(event="workflow_dispatch", pull_requests=[]), "manaflow-ai/cmux")
        clock = Clock()
        self.assertEqual(rescue.pull_moved(FakeAPI(clock, lambda s: []), target, clock.sleep, lambda text: None), "")

    def test_shared_cmux_next_dev_title_is_protected_delivery_work(self):
        run = side_event(path=rescue.CMUX_NEXT_WORKFLOW_PATH, event="push", pull_requests=[],
                         name="cmux NEXT DEV daily · " + HEAD,
                         display_title="cmux NEXT DEV daily · " + HEAD)
        target = rescue.target_from_event(run, "manaflow-ai/cmux")
        self.assertIsInstance(target, rescue.Target)
        self.assertTrue(rescue.is_delivery_target(target))
        self.assertTrue(rescue.never_fails_over(target.path, target.event, target.name, target.display_title))

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

    def test_a_stuck_side_job_moves_to_blacksmith_keeping_what_passed(self):
        clock = Clock()
        api = FakeAPI(clock, side_run())
        code, summary = run_main(api, clock, payload=side_event())
        self.assertEqual(code, 0)
        assert_left_at_open_head(self, api, summary)
        clock = Clock()
        api = FakeAPI(clock, side_run())
        code, summary = run_main(api, clock, payload=side_event(event="workflow_dispatch", pull_requests=[]))
        self.assertEqual(code, 0)
        self.assertIn("cancel", api.calls)
        self.assertIn("rerun-failed", api.calls)
        self.assertNotIn("rerun", api.calls)
        # Other side lanes retain their existing Blacksmith fallback.
        self.assertIn("attempt 2 takes the side lane's Blacksmith default", summary)
        self.assertNotIn("jobs:2", api.calls)

    def test_a_stuck_push_run_superseded_by_a_newer_push_is_not_cancelled(self):
        # 2026-10-07 00:20Z to 01:05Z: with a push about once a minute, this rescue
        # cancelled every cmux-next push run on feat-cmux-next while a newer push run
        # existed (run 37552678540: "cancelled but not re-run: a newer push run ...
        # covers the branch instead"), running jobs included, so no tip swift test
        # completed. cmux-next.yml queues each push Mac job in a group per branch
        # (one runs, one waits), so a newer push never makes this one cancel it.
        payload = side_event(path=".github/workflows/cmux-next.yml", event="push", pull_requests=[],
                             head_branch="feat-cmux-next")
        target = rescue.target_from_event(payload, "manaflow-ai/cmux")
        self.assertEqual(target.push_branch, "feat-cmux-next")
        clock = Clock()
        api = SupersedingAPI(clock, side_run(), newer=[RUN_ID + 7])
        code, summary = run_main(api, clock, payload=payload)
        self.assertEqual(code, 0)
        self.assertIn("newer:feat-cmux-next", api.calls)
        self.assertNotIn("cancel", api.calls)
        self.assertNotIn("force-cancel", api.calls)
        self.assertNotIn("rerun-failed", api.calls)
        self.assertNotIn("rerun", api.calls)
        self.assertIn(f"a newer push run on feat-cmux-next ({RUN_ID + 7})", summary)
        self.assertIn("never cancelled", summary)

    def test_a_refused_cmux_next_push_job_in_a_superseded_run_is_not_cancelled(self):
        # A mini refused a job, the run still goes at the watch's end, and a newer push
        # run exists: the running jobs finish, and the newer run covers the branch.
        payload = side_event(path=".github/workflows/cmux-next.yml", event="push", pull_requests=[],
                             head_branch="feat-cmux-next")
        clock = Clock()
        running = job("cmux-next Release compile (Xcode 26)", status="in_progress", labels=[SIDE],
                      runner="mini-2-glaeda-2")
        api = SupersedingAPI(clock, lambda seconds: [refused_job("cmux-next swift test", labels=(SIDE,)), running],
                             newer=[RUN_ID + 3])
        code, summary = run_main(api, clock, payload=payload)
        self.assertEqual(code, 0)
        self.assertNotIn("cancel", api.calls)
        self.assertNotIn("force-cancel", api.calls)
        self.assertNotIn("rerun", api.calls)

    def test_a_refused_cmux_next_push_job_is_still_rerun(self):
        # The refusal re-run stays: with no newer push run, the finished run's
        # failed jobs are re-run, and nothing is cancelled.
        payload = side_event(path=".github/workflows/cmux-next.yml", event="push", pull_requests=[],
                             head_branch="feat-cmux-next")
        clock = Clock()
        api = SupersedingAPI(clock, lambda seconds: [refused_job("cmux-next swift test", labels=(SIDE,))],
                             finished=lambda seconds: True)
        code, summary = run_main(api, clock, payload=payload)
        self.assertEqual(code, 0)
        self.assertNotIn("cancel", api.calls)
        self.assertEqual(api.calls.count("rerun-failed"), 1)
        self.assertIn("re-ran the failed jobs", summary)

    def test_a_stuck_push_run_with_no_newer_push_is_rescued(self):
        # The branch head is no test: a head commit outside the workflow's paths has
        # no run, and the newest covering push run must still finish.
        payload = side_event(path=".github/workflows/cmux-next.yml", event="push", pull_requests=[],
                             head_branch="feat-cmux-next")
        clock = Clock()
        api = SupersedingAPI(clock, side_run(), head="0" * 40)
        code, summary = run_main(api, clock, payload=payload)
        self.assertEqual(code, 0)
        self.assertIn("newer:feat-cmux-next", api.calls)
        self.assertIn("rerun-failed", api.calls)
        self.assertNotIn("branch:feat-cmux-next", api.calls)

    def test_schedule_and_dispatch_side_runs_are_never_superseded(self):
        for kind in ("schedule", "workflow_dispatch"):
            target = rescue.target_from_event(side_event(event=kind, pull_requests=[], head_branch="main"),
                                              "manaflow-ai/cmux")
            self.assertEqual(target.push_branch, "", kind)
            clock = Clock()
            api = SupersedingAPI(clock, lambda s: [], newer=[RUN_ID + 1])
            self.assertEqual(rescue.pull_moved(api, target, clock.sleep, lambda text: None), "", kind)
            self.assertNotIn("newer:main", api.calls, kind)

    def test_newer_push_runs_skips_cancelled_and_older_runs(self):
        api = rescue.GitHub("token", "manaflow-ai/cmux")
        seen = []
        runs = [{"id": RUN_ID + 3, "status": "queued", "event": "push"},
                {"id": RUN_ID + 2, "status": "completed", "conclusion": "success", "event": "push"},
                {"id": RUN_ID + 1, "status": "completed", "conclusion": "cancelled", "event": "push"},
                {"id": RUN_ID + 4, "status": "queued", "event": "workflow_dispatch"},
                {"id": RUN_ID, "status": "in_progress", "event": "push"},
                {"id": RUN_ID - 1, "status": "queued", "event": "push"}]
        api.request = lambda method, path, **_: seen.append((method, path)) or {"workflow_runs": runs}
        self.assertEqual(api.newer_push_runs(".github/workflows/cmux-next.yml", RUN_ID, "feat-cmux-next"),
                         [RUN_ID + 2, RUN_ID + 3])
        self.assertEqual(seen, [("GET", "/actions/workflows/cmux-next.yml/runs"
                                        "?branch=feat-cmux-next&event=push&per_page=20")])

    def test_cmux_next_overflows_a_queued_side_job_with_a_running_sibling(self):
        # cmux-next's explicit rescue window is the overflow boundary. A queued
        # side job moves with the bot rerun even when another side job is still
        # running; attempt 2 remains minis-first and attempt 3 is Blacksmith.
        def cmux_next(done_at):
            def jobs(seconds):
                test = job("cmux-next swift test", labels=[SIDE], status="in_progress", runner="mini-5-glaeda-3")
                test["started_at"] = stamp(5)
                if done_at is not None and seconds >= done_at:
                    test.update(status="completed", conclusion="success")
                return [test, job("cmux-next Release compile (Xcode 26)", labels=[SIDE], created=0)]
            return jobs

        payload = side_event(path=".github/workflows/cmux-next.yml", event="workflow_dispatch", pull_requests=[])
        clock = Clock()
        api = FakeAPI(clock, cmux_next(done_at=None))
        code, summary = run_main(api, clock, payload=payload,
                                 env_extra={"SIDE_RESCUE_SECONDS": "30"})
        self.assertEqual(code, 0)
        self.assertIn("cancel", api.calls)
        self.assertIn("rerun-failed", api.calls)
        self.assertIn("overflowing the queued side jobs", summary)
        self.assertIn("attempt 2 stays on the side lane's owned label", summary)
        # The same pull request run at its open head is found but never cancelled.
        clock = Clock()
        api = FakeAPI(clock, cmux_next(done_at=None))
        _, summary = run_main(api, clock, payload=side_event(path=".github/workflows/cmux-next.yml"),
                              env_extra={"SIDE_RESCUE_SECONDS": "30"})
        self.assertIn("overflowing the queued side jobs", summary)
        assert_left_at_open_head(self, api, summary)

        # A non-cmux-next side lane keeps the historical sibling protection.
        clock = Clock()
        api = FakeAPI(clock, cmux_next(done_at=None))
        code, summary = run_main(api, clock, payload=side_event())
        self.assertEqual(code, 0)
        self.assertNotIn("cancel", api.calls)
        self.assertIn("watch limit reached", summary)

    def test_a_run_a_code_failure_already_decided_is_not_re_run(self):
        # feat-cmux-next, 2026-10-20: the Linux `checks` job failed on the base's own red checks,
        # the Release compile waited on the side minis, and the rescue cancelled and re-ran the
        # run twice; each attempt failed `checks` the same way (run 39382369248, attempts 1 to 3).
        def checks_failed():
            failed = job("cmux-next checks (god files, concurrency, string tables)", status="completed",
                         labels=["blacksmith-16vcpu-ubuntu-2404"], runner="blacksmith-1")
            failed.update(conclusion="failure", started_at=stamp(1), completed_at=stamp(120), steps=[
                {"name": "Set up job", "conclusion": "success"},
                {"name": "God files and types (Swift)", "conclusion": "success"},
                {"name": "Fail on any red check", "conclusion": "failure"}])
            return failed

        def cmux_next(seconds):
            return [checks_failed(), job("cmux-next Release compile (Xcode 26)", labels=[SIDE], created=0)]

        clock = Clock()
        api = FakeAPI(clock, cmux_next)
        code, summary = run_main(api, clock, payload=side_event(path=".github/workflows/cmux-next.yml"),
                                 env_extra={"SIDE_RESCUE_SECONDS": "30"})
        self.assertEqual(code, 0)
        self.assertNotIn("cancel", api.calls)
        self.assertNotIn("rerun-failed", api.calls)
        self.assertNotIn("rerun", api.calls)
        self.assertIn("already failed", summary)

        # The same holds for a CI pull request run on the minis: a stuck shard is left queued when a guard
        # already failed.
        stuck = job("macos / shard 2", labels=[MINI], created=0)
        late = START + dt.timedelta(seconds=600)
        look = rescue.assess([checks_failed(), stuck], now=late, budget_seconds=90, leave_decided=True)
        self.assertEqual((look.action, look.waiting), ("watch", True))
        self.assertIn("already failed", look.reason)
        # Runs that are not pull requests (main, nightly, push) keep the rescue.
        self.assertEqual(rescue.assess([checks_failed(), stuck], now=late, budget_seconds=90).action, "rescue")
        # A refusal is still re-run: it is the fleet's failure, not the change's.
        look = rescue.assess([checks_failed(), stuck, refused_job("macos / shard 3")], now=late, budget_seconds=90,
                             leave_decided=True)
        self.assertEqual(look.action, "refused")
        # Neither a refusal nor a lost runner (no step ran) nor a job carried from an earlier attempt
        # decides the run: the stuck job is still moved.
        lost = {**checks_failed(), "steps": []}
        carried = {**checks_failed(), "created_at": stamp(200), "started_at": stamp(100)}
        for sibling in (refused_job("macos / shard 3"), lost, carried):
            look = rescue.assess([sibling, stuck], now=late, budget_seconds=90, leave_decided=True)
            self.assertEqual(look.action, "rescue", sibling)

    def test_a_main_run_a_guard_failed_is_still_cancelled_once_main_moves(self):
        # Main's stuck run holds its concurrency group, so a red one is still cancelled.
        failed = job("guards / workflow-guard-tests", status="completed", labels=["blacksmith-4vcpu-ubuntu-2404"],
                     runner="blacksmith-2")
        failed.update(conclusion="failure", started_at=stamp(1), completed_at=stamp(20),
                      steps=[{"name": "Run the guard tests", "conclusion": "failure"}])
        clock = Clock()
        api = FakeAPI(clock, lambda seconds: persistent_run()(seconds) + [failed], marker=True, head="b" * 40)
        _, summary = run_main(api, clock, payload=main_event())
        self.assertIn("cancel", api.calls)
        self.assertNotIn("rerun", api.calls)
        self.assertIn("not re-run", summary)

    def test_a_sibling_on_a_mini_does_not_hide_a_refusal_or_a_held_job(self):
        running = job("macos / shard 1", status="in_progress", labels=[MINI], runner="mini-2")
        running["started_at"] = stamp(5)
        stuck = job("macos / shard 2", labels=[MINI], created=0)
        late = START + dt.timedelta(seconds=44 + rescue.SETUP_WAIT_SECONDS)
        look = rescue.assess([running, stuck], now=late, budget_seconds=90)
        self.assertEqual((look.action, look.waiting), ("watch", True))
        self.assertIn("running on a persistent runner", look.reason)
        look = rescue.assess([running, stuck, refused_job("macos / shard 3")], now=late, budget_seconds=90)
        self.assertEqual(look.action, "refused")
        closing = late + dt.timedelta(seconds=rescue.END_MARGIN_SECONDS - 1)
        look = rescue.assess([running, stuck, setup_job()], now=late, budget_seconds=90, deadline=closing)
        self.assertEqual(look.action, "rescue")
        self.assertIn("runner setup", look.reason)

    def test_a_side_lane_retry_takes_blacksmith(self):
        target = rescue.target_from_event(side_event(), "manaflow-ai/cmux")
        self.assertIn("Blacksmith default", rescue.next_attempt(target))
        target = rescue.target_from_event(side_event(path=rescue.CMUX_NEXT_WORKFLOW_PATH), "manaflow-ai/cmux")
        self.assertIn("stays on the side lane's owned label", rescue.next_attempt(target))
        self.assertIn("Blacksmith overflow", rescue.next_attempt(dataclasses.replace(target, attempt=2)))

    def test_a_cmux_next_job_queued_past_the_ci_budget_is_not_cancelled(self):
        # 2026-10-06: main judged cmux-next on the 30 s CI budget and cancelled
        # 13 of 20 PR runs whose Mac jobs were queued minutes on the minis.
        clock = Clock()
        api = FakeAPI(clock, side_run(started_at=180))
        code, summary = run_main(api, clock, env_extra={"RESCUE_SECONDS": "30"},
                                 payload=side_event(path=".github/workflows/cmux-next.yml"))
        self.assertEqual(code, 0)
        self.assertNotIn("cancel", api.calls)
        self.assertIn("the fleet accepted the side-lane jobs", summary)

    def test_side_lane_budget_is_ten_minutes_not_the_ninety_second_default(self):
        self.assertEqual(rescue.SIDE_DEFAULT_BUDGET_SECONDS, 600)

    def test_side_lane_bot_attempts_two_and_three_are_watched_but_four_is_not(self):
        # Bot attempt 3 still runs on the minis (it keeps macos-placement's
        # label), so it is watched for refusals; attempt 4 is on Blacksmith.
        path = ".github/workflows/cmux-next.yml"
        for attempt, watched in ((2, True), (3, True), (4, False)):
            self.assertEqual(rescue.owned_rerun({"path": path, "run_attempt": attempt,
                                                 "triggering_actor": {"login": ACTIONS_BOT}}), watched, attempt)
        self.assertTrue(rescue.owned_rerun({"path": path, "run_attempt": 4,
                                           "triggering_actor": {"login": "teamleaderleo"}}))

    def test_cmux_bot_reruns_count_as_the_bots(self):
        # The rescue re-runs with the cmux-bot App's token. Run 40444295785 (a DEV daily) went through 10
        # cmux-bot attempts on the minis while only github-actions[bot] counted as the bot here.
        self.assertEqual(rescue.RESCUE_ACTORS, {ACTIONS_BOT, CMUX_BOT})
        path = rescue.CMUX_NEXT_WORKFLOW_PATH
        for attempt, watched in ((2, True), (3, True), (4, False)):
            self.assertEqual(rescue.owned_rerun({"path": path, "run_attempt": attempt,
                                                 "triggering_actor": {"login": CMUX_BOT}}), watched, attempt)
        run = dict(side_event(path=path, event="workflow_dispatch", run_attempt=3, status="completed",
                              conclusion="failure", triggering_actor={"login": CMUX_BOT})["workflow_run"])
        target = rescue.sweep_target(run, "manaflow-ai/cmux", late=False)
        self.assertNotIsInstance(target, str)
        self.assertIs(target.refusals_only, True)
        self.assertEqual(rescue.next_attempt(target), "attempt 4 takes Blacksmith: a mini refused attempt 3")
        self.assertEqual(rescue.sweep_target({**run, "run_attempt": 4}, "manaflow-ai/cmux", late=False),
                         "attempt 4")
        # ci.yml's placement moves only github-actions[bot]'s attempt 3 to Blacksmith (pr_runner_pool), so a
        # cmux-bot re-run of a pull request's CI still goes back to the minis and is still watched.
        for actor, watched in ((CMUX_BOT, True), (ACTIONS_BOT, False)):
            self.assertEqual(rescue.owned_rerun({"path": rescue.CI_WORKFLOW_PATH, "event": "pull_request",
                                                 "run_attempt": 3, "triggering_actor": {"login": actor}}),
                             watched, actor)
        # A person's attempt 3 stays minis-first and is not refusals only.
        person = rescue.sweep_target({**run, "triggering_actor": {"login": "teamleaderleo"}},
                                     "manaflow-ai/cmux", late=False)
        self.assertIs(person.refusals_only, False)

    def follow_cmux_next_attempt_three(self, jobs):
        run = dict(side_event(path=".github/workflows/cmux-next.yml", run_attempt=3, status="in_progress",
                              triggering_actor={"login": ACTIONS_BOT})["workflow_run"])
        target = rescue.sweep_target(run, "manaflow-ai/cmux", late=False)
        self.assertNotIsInstance(target, str)
        clock = Clock()
        api = FakeAPI(clock, lambda seconds: [], rerun_jobs=jobs)
        api.attempt = 3
        lines: list[str] = []
        outcome = rescue.follow(api, target, seconds=90, queue_rounds="0", now=clock.now, sleep=clock.sleep,
                                log=lines.append)
        return api, outcome, "\n".join(lines)

    def test_a_refusal_on_cmux_next_attempt_three_reruns_on_blacksmith(self):
        # #18147, 2026-10-07 02:23Z: a lend drain refused the scheme compile on
        # bot attempt 3, the last re-run, and nothing re-ran it.
        passed = job("cmux-next swift test", status="completed", labels=[SIDE], runner="mini-1-glaeda-1")
        passed.update(conclusion="success", steps=[{"name": "Set up runner", "conclusion": "success"},
                                                   {"name": "Run package tests", "conclusion": "success"}])
        api, outcome, log = self.follow_cmux_next_attempt_three(
            lambda seconds: [passed, refused_job("cmux app scheme compile (Debug)", labels=(SIDE,))])
        self.assertEqual(api.calls.count("rerun-failed"), 1, log)
        self.assertNotIn("cancel", api.calls)
        self.assertIn("attempt 4 takes Blacksmith", log)

    def dev_daily_completed(self, **overrides):
        run = {"path": rescue.CMUX_NEXT_WORKFLOW_PATH, "event": "workflow_dispatch", "run_attempt": 2,
               "status": "completed", "conclusion": "failure", "pull_requests": [],
               "display_title": f"cmux NEXT DEV daily · {HEAD}", "triggering_actor": {"login": CMUX_BOT},
               **overrides}
        return {"action": "completed", "workflow_run": dict(side_event(**run)["workflow_run"])}

    def test_a_failed_dev_daily_wakes_its_own_rescue_at_attempt_two(self):
        # The sweeper's listings ran out of the hour's API budget, so a refused DEV compile on a re-run
        # had no rescue owner; the `completed` event watches that attempt itself.
        refused = refused_job("cmux NEXT DEV Release compile", seconds=68, labels=(SIDE,), steps=[
            {"name": "Set up job", "conclusion": "success"}, {"name": "Set up runner", "conclusion": "failure"}])
        clock = Clock()
        api = FakeAPI(clock, lambda seconds: [], rerun_jobs=lambda seconds: [refused])
        api.attempt = 2
        code, summary = run_main(api, clock, payload=self.dev_daily_completed())
        self.assertEqual(code, 0, summary)
        # A refused DEV compile re-runs every job (FakeAPI.rerun checks it starts attempt 3).
        self.assertEqual(api.calls.count("rerun"), 1, summary)
        self.assertEqual(api.attempt, 3)
        self.assertNotIn("rerun-failed", api.calls)
        self.assertNotIn("cancel", api.calls)
        self.assertIn("attempt 3 takes the side lane's Blacksmith overflow", summary)

    def test_a_failed_cmux_next_pull_request_or_tip_suite_run_is_watched_when_it_completes(self):
        # A pull request's swift test the runner hook refused (run 40671913126) and the tip Swift suite's
        # dispatch had no `completed` wake: they stayed red until the two-hourly sweeper reached them.
        pull = self.dev_daily_completed(event="pull_request", run_attempt=1, display_title="cmux-next · " + HEAD,
                                        pull_requests=[{"number": 26809}])
        target = rescue.completed_target(pull, "manaflow-ai/cmux")
        self.assertIsInstance(target, rescue.Target, target)
        self.assertEqual(target.pr_number, 26809)
        tip = self.dev_daily_completed(run_attempt=1, display_title=f"cmux-next tip Swift suite · {HEAD}")
        self.assertIsInstance(rescue.completed_target(tip, "manaflow-ai/cmux"), rescue.Target)
        # The tip daemon suite (cmux-next-tip-swift-suite-dispatch.yml's daemon leg) too: a refused daemon
        # test must not wait for the sweeper, or the base has no daemon-test verdict for hours.
        daemon = self.dev_daily_completed(run_attempt=1, display_title=f"cmux-next tip daemon suite · {HEAD}")
        self.assertIsInstance(rescue.completed_target(daemon, "manaflow-ai/cmux"), rescue.Target)
        fork = self.dev_daily_completed(event="pull_request", run_attempt=1, pull_requests=[{"number": 1}],
                                        head_repository={"full_name": "someone/cmux"})
        self.assertIsInstance(rescue.completed_target(fork, "manaflow-ai/cmux"), str)

    def test_a_completed_event_watches_only_cmux_next_and_never_past_the_bots_attempt_three(self):
        clock = Clock()
        api = FakeAPI(clock, lambda seconds: [])
        _, summary = run_main(api, clock, payload=self.dev_daily_completed(path=".github/workflows/nightly.yml"))
        self.assertIn("not watched: a finished run of .github/workflows/nightly.yml", summary)
        _, summary = run_main(api, clock, payload=self.dev_daily_completed(run_attempt=4))
        self.assertIn("not watched: attempt 4", summary)
        _, summary = run_main(api, clock, payload=self.dev_daily_completed(conclusion="success"))
        self.assertIn("not watched: finished (success)", summary)
        self.assertEqual(api.calls, [])

    def test_a_real_failure_on_cmux_next_attempt_three_is_not_rerun(self):
        # Only refusals go to attempt 4: a re-run of failed jobs would also re-run the red test.
        red = job("cmux-next swift test", status="completed", labels=[SIDE], runner="mini-1-glaeda-1")
        red.update(conclusion="failure", started_at=stamp(0), completed_at=stamp(900),
                   steps=[{"name": "Set up runner", "conclusion": "success"},
                          {"name": "Run package tests", "conclusion": "failure"}])
        api, outcome, log = self.follow_cmux_next_attempt_three(
            lambda seconds: [red, refused_job("cmux app scheme compile (Debug)", labels=(SIDE,))])
        self.assertNotIn("rerun-failed", api.calls)
        self.assertNotIn("rerun", api.calls)
        self.assertIn("also failed for a reason that is not a refusal", outcome)

    def test_a_queued_cmux_next_attempt_three_is_never_cancelled(self):
        # Minis-first holds through attempt 3: a long queue there is not moved.
        api, outcome, log = self.follow_cmux_next_attempt_three(
            lambda seconds: [job("cmux app scheme compile (Debug)", labels=[SIDE])])
        self.assertNotIn("cancel", api.calls)
        self.assertNotIn("rerun", api.calls)
        self.assertNotIn("rerun-failed", api.calls)

    def follow_refusals_only(self, jobs, **api_kwargs):
        run = dict(side_event(path=".github/workflows/cmux-next.yml", status="in_progress")["workflow_run"])
        target = dataclasses.replace(rescue.sweep_target(run, "manaflow-ai/cmux", late=False), refusals_only=True)
        clock = Clock()
        api = FakeAPI(clock, jobs, rerun_jobs=lambda seconds: [], **api_kwargs)
        lines: list[str] = []
        outcome = rescue.follow(api, target, seconds=90, queue_rounds="0", now=clock.now, sleep=clock.sleep,
                                log=lines.append)
        return api, outcome, "\n".join(lines)

    def test_a_refusals_only_run_reruns_a_job_no_runner_acquired(self):
        # #23528 with this: GitHub cancelled the queued scheme compile (no runner acquired it) and the
        # run failed. That counts as a refusal, so the failed jobs are re-run once, as for any refusal;
        # owned_rerun() still ends the bot's re-runs on the minis at attempt 3.
        run = dict(side_event(path=".github/workflows/cmux-next.yml", status="in_progress")["workflow_run"])
        target = dataclasses.replace(rescue.sweep_target(run, "manaflow-ai/cmux", late=False), refusals_only=True)
        clock = Clock()
        api = FakeAPI(clock, lambda seconds: [unacquired_job("cmux app scheme compile (Debug)", labels=(SIDE,))],
                      finished=lambda seconds: True, conclusion="failure", rerun_jobs=lambda seconds: [])
        lines: list[str] = []
        rescue.follow(api, target, seconds=90, queue_rounds="0", now=clock.now, sleep=clock.sleep,
                      log=lines.append)
        self.assertEqual(api.calls.count("rerun-failed"), 1, "\n".join(lines))
        self.assertNotIn("cancel", api.calls)

    def test_a_refusals_only_attempt_one_waits_out_its_queue(self):
        # Run 39615562861: the scheme compile queued on the side label with no free overflow.
        api, outcome, log = self.follow_refusals_only(
            lambda seconds: [job("cmux app scheme compile (Debug)", labels=[SIDE])])
        self.assertNotIn("cancel", api.calls, log)
        self.assertNotIn("rerun", api.calls)
        self.assertNotIn("rerun-failed", api.calls)
        self.assertIn("refusals only", outcome)

    def test_a_refusals_only_attempt_one_still_reruns_a_refusal(self):
        api, outcome, log = self.follow_refusals_only(
            lambda seconds: [refused_job("cmux app scheme compile (Debug)", labels=(SIDE,))],
            finished=lambda seconds: seconds >= 60, conclusion="failure")
        # Once the run has finished, its failed jobs are re-run with no cancel, open head or not.
        self.assertEqual(api.calls.count("rerun-failed"), 1, log)
        self.assertNotIn("cancel", api.calls)

    def test_a_side_lane_refusal_beside_a_real_failure_is_not_rerun(self):
        # A failed side-lane run found by the sweeper's failed-run listing: re-running its failed jobs would
        # re-run the red one on the minis too, so the run is left red.
        red = job("system-keychain", status="completed", labels=[BLACKSMITH], runner="bs")
        red.update(conclusion="failure", started_at=stamp(0), completed_at=stamp(900),
                   steps=[{"name": "Set up job", "conclusion": "success"},
                          {"name": "Run tests", "conclusion": "failure"}])
        clock = Clock()
        api = FakeAPI(clock, lambda seconds: [refused_job("diagnostic-presentation", labels=(SIDE,)), red],
                      finished=lambda seconds: True, conclusion="failure")
        target = rescue.target_from_event(side_event(), "manaflow-ai/cmux")
        lines: list[str] = []
        outcome = rescue.follow(api, target, seconds=90, queue_rounds="0", now=clock.now, sleep=clock.sleep,
                                log=lines.append)
        self.assertNotIn("rerun-failed", api.calls, "\n".join(lines))
        self.assertNotIn("rerun", api.calls)
        self.assertIn("also failed for a reason that is not a refusal (system-keychain)", outcome)
        # The refused job alone is still re-run.
        clock = Clock()
        api = FakeAPI(clock, lambda seconds: [refused_job("diagnostic-presentation", labels=(SIDE,))],
                      finished=lambda seconds: True, conclusion="failure", rerun_jobs=lambda seconds: [])
        rescue.follow(api, target, seconds=90, queue_rounds="0", now=clock.now, sleep=clock.sleep,
                      log=lines.append)
        self.assertEqual(api.calls.count("rerun-failed"), 1, "\n".join(lines))

    def test_a_refused_side_job_is_rerun(self):
        def jobs(seconds):
            return [refused_job("diagnostic-presentation", labels=(SIDE,)) if seconds >= 60 else
                    job("diagnostic-presentation", labels=[SIDE], created=0)]
        clock = Clock()
        api = FakeAPI(clock, jobs, finished=lambda s: s >= 60)
        code, summary = run_main(api, clock, payload=side_event())
        self.assertIn("rerun-failed", api.calls)
        self.assertIn("refused", summary)
        # Other side lanes still overflow on attempt 2.
        self.assertNotIn("attempt 2 stays on the side lane's owned label", summary)

    def cmux_tui_run(self, *, refused_test=True, red_lint=False):
        """Run 39605033138's shape (cmux-tui.yml, focused mode, 2026-10-21): every job of the run, with
        the macOS `test` leg refused by the side label (here) or passed, the `if: always()` aggregator
        `hosted-verification` failed on `require_success "Rust tests"`, and lint (linux) optionally red."""
        def done(name, conclusion="success", labels=("blacksmith-4vcpu-ubuntu-2404",), steps=None):
            found = job(name, status="completed", labels=labels, runner="bs" if conclusion != "skipped" else "")
            found.update(conclusion=conclusion, started_at=stamp(0), completed_at=stamp(300),
                         steps=[] if conclusion == "skipped" else steps or [
                             {"name": "Set up job", "conclusion": "success"},
                             {"name": "Run tests", "conclusion": conclusion}])
            return found
        jobs = [done("validate exact commit request"), done("Rust MSRV (1.91)"),
                done("lint (linux)", "failure" if red_lint else "success"), done("lint (macos)", labels=(SIDE,)),
                done("test (linux)"),
                refused_job("test (macos)", labels=(SIDE,)) if refused_test else done("test (macos)", labels=(SIDE,)),
                done("release-path dogfood artifacts / select binary targets"),
                done("release-path dogfood artifacts / build aarch64-apple-darwin"),
                done("release-path dogfood artifacts / package distributions", "skipped"),
                done("test (windows)", "skipped"), done("web-frontend", "skipped"),
                done("valgrind-leak-check", "skipped"), done("valgrind-leak-check (startup)", "skipped"),
                done("CDP browser smoke (${{ matrix.os }})", "skipped"), done("bindings-e2e", "skipped"),
                done("focused hosted verification", "failure", steps=[
                    {"name": "Set up job", "conclusion": "success"},
                    {"name": "Require selected verification jobs", "conclusion": "failure"},
                    {"name": "Complete job", "conclusion": "success"}])]
        return jobs

    def follow_cmux_tui(self, jobs, *, workflow=None):
        path = ".github/workflows/cmux-tui.yml"
        text = (ROOT / path).read_text(encoding="utf-8") if workflow is None else workflow
        target = rescue.target_from_event(side_event(path=path, event="workflow_dispatch", pull_requests=[]),
                                          "manaflow-ai/cmux")
        clock = Clock()
        api = FakeAPI(clock, lambda seconds: jobs, finished=lambda seconds: True, conclusion="failure",
                      rerun_jobs=lambda seconds: [], workflow=text or None)
        lines: list[str] = []
        outcome = rescue.follow(api, target, seconds=90, queue_rounds="0", now=clock.now, sleep=clock.sleep,
                                log=lines.append)
        return api, outcome, "\n".join(lines)

    def test_an_always_aggregator_failed_only_by_a_refused_leg_does_not_block_its_rerun(self):
        # cmux-tui.yml's hosted-verification (`if: always()`, needs every leg) fails when the macOS test
        # leg is refused, which made the refusal look like a real failure and left the run red. It needs
        # the refused job and no other job of the run failed, so the failed jobs are re-run; GitHub's
        # rerun-failed-jobs re-runs the aggregator with them (it failed, and it depends on the leg).
        api, outcome, log = self.follow_cmux_tui(self.cmux_tui_run())
        self.assertEqual(api.calls.count("rerun-failed"), 1, f"{outcome}\n{log}")
        self.assertIn(f"workflow:.github/workflows/cmux-tui.yml@{HEAD}", api.calls)
        self.assertNotIn("cancel", api.calls)
        self.assertIn("focused hosted verification", log)

    def test_a_failure_not_downstream_of_the_refused_leg_still_blocks_the_rerun(self):
        # lint (linux) does not need test (macos): its failure is its own, so nothing is re-run, and the
        # aggregator, which needs lint too, is not excused either.
        api, outcome, log = self.follow_cmux_tui(self.cmux_tui_run(red_lint=True))
        self.assertNotIn("rerun-failed", api.calls, log)
        self.assertNotIn("rerun", api.calls)
        self.assertIn("also failed for a reason that is not a refusal", outcome)
        self.assertIn("lint (linux)", outcome)
        self.assertIn("focused hosted verification", outcome)

    def test_an_aggregator_failure_with_no_refused_leg_is_its_own(self):
        # Same graph, but the leg it needs passed: nothing is refused, so the watch never re-runs it.
        api, outcome, log = self.follow_cmux_tui(self.cmux_tui_run(refused_test=False))
        self.assertNotIn("rerun-failed", api.calls, log)

    def test_an_unreadable_workflow_leaves_the_aggregator_failure_blocking(self):
        # Without the needs graph (file missing at the head, or the read failed) nothing is excused.
        api, outcome, log = self.follow_cmux_tui(self.cmux_tui_run(), workflow="")
        self.assertNotIn("rerun-failed", api.calls, log)
        self.assertIn("focused hosted verification", outcome)

    def test_downstream_needs_follow_names_matrices_and_reusable_calls(self):
        text = (ROOT / ".github/workflows/cmux-tui.yml").read_text(encoding="utf-8")
        jobs = self.cmux_tui_run()
        excused = rescue.downstream_of_refusals(text, jobs)
        self.assertEqual(excused, {"focused hosted verification"})
        # A refused macOS build inside the reusable package call excuses the aggregator the same way.
        build = "release-path dogfood artifacts / build aarch64-apple-darwin"
        jobs = [refused_job(build, labels=(SIDE,)) if found["name"] == build else found
                for found in self.cmux_tui_run(refused_test=False)]
        self.assertEqual(rescue.downstream_of_refusals(text, jobs), {"focused hosted verification"})
        # A failed job upstream of the aggregator but not downstream of the refusal is never excused.
        jobs = self.cmux_tui_run(red_lint=True)
        self.assertEqual(rescue.downstream_of_refusals(text, jobs), set())


TRUSTED = "glaeda-trusted-std-xcode-26.6"


def nightly_event(**overrides):
    return event(**{"path": ".github/workflows/nightly.yml", "event": "push", "head_branch": "main",
                    "pull_requests": [], **overrides})


def nightly_run(*, queued_at=15, started_at=None, refused_at=None, runner_label=None, setup_until=None,
                helper_done_at=None):
    """nightly.yml: decide, then the app build on the trusted pool beside a Blacksmith helper build.

    `runner_label` adds the reserved runner's own label, as nightly.yml's runs-on does; `setup_until`
    keeps a started build in its runner's setup until then (glaeda's hook waiting for capacity). The
    helper build runs until `helper_done_at` (never finishing by default)."""
    labels = [TRUSTED, *([runner_label] if runner_label else [])]

    def jobs(seconds):
        found = [job("decide", status="completed", labels=[BLACKSMITH])]
        if seconds < queued_at:
            return found
        if refused_at is not None and seconds >= refused_at:
            app = refused_job("build-nightly-app", labels=tuple(labels))
        else:
            started = started_at is not None and seconds >= started_at
            app = job("build-nightly-app", labels=labels, created=queued_at,
                      status="in_progress" if started else "queued", runner="cmux15-glaeda" if started else "")
            if started:
                app["started_at"] = stamp(started_at)
                if setup_until is not None:
                    app["steps"] = [{"name": "Set up runner", "started_at": stamp(started_at),
                                     "status": "in_progress" if seconds < setup_until else "completed",
                                     "conclusion": None if seconds < setup_until else "success"}]
        helper_done = helper_done_at is not None and seconds >= helper_done_at
        helper = job("build-nightly-ghostty-cli-helper", labels=["blacksmith-6vcpu-macos-15"],
                     status="completed" if helper_done else "in_progress", runner="bs")
        if helper_done:
            helper["conclusion"] = "success"
        return found + [app, helper]
    return jobs


# nightly.yml's shape around its build picker (feat-cmux-next): the helper's uploads as `overwrite` says.
def picker_workflow(overwrite="true"):
    upload = {"uses": "actions/upload-artifact@v7", "with": {"name": "cmux-next-source-archive"}}
    if overwrite is not None:
        upload["with"]["overwrite"] = overwrite
    return json.dumps({"jobs": {  # JSON is YAML
        "decide": {"runs-on": "ubuntu-latest", "steps": [{"run": "true"}]},
        "pick-nightly-build-runner": {"needs": "decide", "runs-on": "ubuntu-latest", "steps": [{"run": "true"}]},
        "build-nightly-app": {"needs": ["decide", "pick-nightly-build-runner"], "runs-on": "x", "steps": [{"run": "true"}]},
        "build-nightly-ghostty-cli-helper": {"needs": ["pick-nightly-build-runner"], "runs-on": "x", "steps": [upload]},
        "publish": {"needs": ["build-nightly-app", "build-nightly-ghostty-cli-helper"], "runs-on": "x",
                    "steps": [{"uses": "actions/upload-artifact@v7", "with": {"name": "appcast"}}]},
        "lint": {"runs-on": "ubuntu-latest", "steps": [{"run": "true"}]},
    }})


def with_picker(jobs_at, picker_id=901):
    """Adds attempt 1's finished pick-nightly-build-runner job (with an id) to a jobs function."""
    def jobs(seconds):
        picker = job("pick-nightly-build-runner", status="completed", labels=[BLACKSMITH], runner="gh")
        picker.update(id=picker_id, conclusion="success")
        return [picker, *jobs_at(seconds)]
    return jobs


def done(name, conclusion, **extra):
    found = job(name, status="completed", labels=[BLACKSMITH], runner="bs")
    found.update(conclusion=conclusion, **extra)
    return found


class NightlyRepick(unittest.TestCase):
    """A rescued nightly-next attempt 1 re-runs its build picker, so attempt 2 picks its runner fresh.

    Runs 40549487427, 40550551073 and 40550711613 (2026-10-27): attempt 1's build-nightly-app was refused at
    "Set up runner" on the dedicated builder; the rescue re-ran the failed jobs, which kept the picker's outputs,
    and attempt 2 queued on blacksmith-6vcpu-macos-26, a label the picker had reported as stalled."""

    def picker_jobs(self, *rest):
        picker = done("pick-nightly-build-runner", "success", id=901)
        return [picker, *rest]

    def test_a_failed_build_that_needs_the_picker_re_runs_the_picker(self):
        jobs = self.picker_jobs(done("decide", "success"), done("build-nightly-app", "failure"),
                                done("build-nightly-ghostty-cli-helper", "success"), done("lint", "success"))
        self.assertEqual(rescue.repick_job(picker_workflow(), jobs)[0], 901)

    def test_a_succeeded_helper_that_uploads_without_overwrite_keeps_the_failed_jobs_re_run(self):
        jobs = self.picker_jobs(done("build-nightly-app", "failure"), done("build-nightly-ghostty-cli-helper", "success"))
        for overwrite in (None, "false"):
            with self.subTest(overwrite=overwrite):
                picker, why = rescue.repick_job(picker_workflow(overwrite), jobs)
                self.assertIsNone(picker)
                self.assertIn("cmux-next-source-archive again without overwrite", why)

    def test_a_skipped_helper_uploaded_nothing(self):
        jobs = self.picker_jobs(done("build-nightly-app", "failure"), done("build-nightly-ghostty-cli-helper", "skipped"))
        self.assertEqual(rescue.repick_job(picker_workflow(None), jobs)[0], 901)

    def test_a_picker_kept_from_an_earlier_attempt_is_re_run(self):
        # After a re-run of failed jobs, attempt 2's list keeps attempt 1's picker (started before attempt 2).
        picker = done("pick-nightly-build-runner", "success", id=901, started_at=stamp(-3600))
        jobs = [picker, done("build-nightly-app", "cancelled", started_at=stamp(10))]
        self.assertEqual(rescue.repick_job(picker_workflow(), jobs)[0], 901)
        # A failure kept from earlier would still be retried by a re-run of failed jobs: it must need the picker.
        kept = done("lint", "failure", started_at=stamp(-3500))
        self.assertIsNone(rescue.repick_job(picker_workflow(), [*jobs, kept])[0])

    def test_a_helper_that_failed_too_re_runs_either_way(self):
        # Both builds re-run under a re-run of failed jobs as well: no extra upload.
        jobs = self.picker_jobs(done("build-nightly-app", "failure"), done("build-nightly-ghostty-cli-helper", "cancelled"))
        self.assertEqual(rescue.repick_job(picker_workflow(None), jobs)[0], 901)

    def test_a_failed_job_outside_the_picker_keeps_the_failed_jobs_re_run(self):
        jobs = self.picker_jobs(done("build-nightly-app", "failure"), done("lint", "failure"))
        picker, why = rescue.repick_job(picker_workflow(), jobs)
        self.assertIsNone(picker)
        self.assertIn("lint does not need pick-nightly-build-runner", why)

    def test_no_picker_job_or_no_id_or_no_failure_keeps_the_failed_jobs_re_run(self):
        app = done("build-nightly-app", "failure")
        cases = {
            "no picker job": [app],
            "no id": [done("pick-nightly-build-runner", "success"), app],
            "two pickers": [*self.picker_jobs(app), done("pick-nightly-build-runner", "success", id=902)],
            "nothing failed": self.picker_jobs(done("build-nightly-app", "success")),
            "picker failed only": [done("pick-nightly-build-runner", "failure", id=901)],
        }
        for case, jobs in cases.items():
            with self.subTest(case):
                self.assertIsNone(rescue.repick_job(picker_workflow(), jobs)[0])
        self.assertIsNone(rescue.repick_job("jobs: [", self.picker_jobs(app))[0])
        self.assertIsNone(rescue.repick_job('{"jobs": {"build-nightly-app": {}}}', self.picker_jobs(app))[0])

    def run_refused(self, workflow, payload=None):
        clock = Clock()
        api = NightlyAPI(clock, with_picker(nightly_run(refused_at=60, runner_label="glaeda-runner-cmux22-nightly-next",
                                                        helper_done_at=200)),
                         finished=lambda s: s >= 200, workflow=workflow)
        _, summary = run_main(api, clock, payload=payload or nightly_event(head_branch="nightly-next"))
        return api, summary

    def test_a_refused_next_build_re_runs_the_picker_and_what_needs_it(self):
        for event_name in ("push", "workflow_dispatch"):
            with self.subTest(event_name):
                api, summary = self.run_refused(picker_workflow(),
                                                nightly_event(event=event_name, head_branch="nightly-next"))
                self.assertEqual(api.calls[-1], "rerun-job:901")
                self.assertNotIn("rerun-failed", api.calls)
                self.assertNotIn("cancel", api.calls)
                self.assertIn(f"workflow:{rescue.NIGHTLY_WORKFLOW_PATH}@{HEAD}", api.calls)
                self.assertIn("so attempt 2 picks its runner fresh", summary)

    def test_a_refused_next_build_whose_workflow_cannot_be_used_re_runs_its_failed_jobs(self):
        for workflow in (None, picker_workflow(None)):
            with self.subTest(missing=workflow is None):
                api, summary = self.run_refused(workflow)
                self.assertEqual(api.calls[-1], "rerun-failed")
                self.assertNotIn("rerun-job:901", api.calls)

    def test_main_s_nightly_keeps_the_failed_jobs_re_run(self):
        # Only nightly-next's builds read the picker; main's nightly has none to re-run.
        api, _ = self.run_refused(picker_workflow(), nightly_event())
        self.assertEqual(api.calls[-1], "rerun-failed")
        self.assertFalse(any(call.startswith("workflow:") for call in api.calls), api.calls)

    def test_a_later_attempt_keeps_the_failed_jobs_re_run(self):
        # Attempt 2 already picked fresh: a refusal there re-runs failed jobs onto attempt 2's Blacksmith pick.
        clock = Clock()
        api = NightlyAPI(clock, lambda s: [], workflow=picker_workflow())
        target = rescue.Target(RUN_ID, 2, HEAD, 0, path=rescue.NIGHTLY_WORKFLOW_PATH, side=True, nightly=True,
                               push_branch="nightly-next")
        api.attempt = 2
        text = rescue.rerun_failed_or_repick(api, target, clock.sleep, lambda line: None, refusal=True)
        self.assertEqual(api.calls, ["rerun-failed"])
        self.assertIn("re-ran the failed jobs", text)

    def later_attempt(self, jobs, workflow=None):
        clock = Clock()
        api = NightlyAPI(clock, lambda s: [], workflow=picker_workflow() if workflow is None else workflow)
        api.attempt, api.rerun_jobs = 2, lambda s: jobs
        target = rescue.Target(RUN_ID, 2, HEAD, 0, path=rescue.NIGHTLY_WORKFLOW_PATH, side=True, nightly=True,
                               push_branch="nightly-next")
        lines = []
        return api, rescue.rerun_failed_or_repick(api, target, clock.sleep, lines.append), lines

    def test_a_later_attempt_s_build_moved_off_a_queue_re_runs_the_picker(self):
        # #26614 queues the build on a busy owned label when every Blacksmith label is stalled. A re-run of
        # failed jobs from attempt 2 would take attempt 2's `blacksmith` output, that stalled label, where no
        # owned watch follows it: the picker runs again instead, so attempt 3 picks fresh.
        api, text, _ = self.later_attempt(self.picker_jobs(done("decide", "success"),
                                                           done("build-nightly-app", "cancelled")))
        self.assertEqual(api.calls[-1], "rerun-job:901")
        self.assertNotIn("rerun-failed", api.calls)
        self.assertIn("so attempt 3 picks its runner fresh", text)

    def test_a_later_attempt_s_moved_build_re_runs_every_job_when_the_picker_cannot_be_re_run(self):
        # A failed job outside the picker's tree: re-running the picker alone would leave it, so the whole run
        # goes again (the pickers choose afresh), never a re-run of failed jobs onto the stalled label.
        for name, jobs, workflow in (
                ("unrelated failure", self.picker_jobs(done("build-nightly-app", "cancelled"), done("lint", "failure")),
                 None),
                ("no picker in the file", self.picker_jobs(done("build-nightly-app", "cancelled")),
                 '{"jobs": {"build-nightly-app": {}}}')):
            with self.subTest(name):
                api, text, lines = self.later_attempt(jobs, workflow)
                self.assertEqual(api.calls[-1], "rerun")
                self.assertNotIn("rerun-failed", api.calls)
                self.assertIn("attempt 3's pickers choose again", text)
                self.assertTrue(any(line.startswith("no fresh runner pick:") for line in lines), lines)

    def test_a_later_attempt_whose_app_was_built_keeps_the_failed_jobs_re_run(self):
        # Only the verify jobs wait: they take their sign picker's alternate, and the built app is kept.
        api, text, lines = self.later_attempt(self.picker_jobs(done("build-nightly-app", "success"),
                                                               done("publish", "cancelled")))
        self.assertEqual(api.calls[-1], "rerun-failed")
        self.assertNotIn("rerun-job:901", api.calls)
        self.assertNotIn("rerun", api.calls)
        self.assertTrue(any("was not moved off a queue" in line for line in lines), lines)

    def test_a_refused_job_re_run_re_runs_the_failed_jobs(self):
        clock = Clock()

        class Refusing(NightlyAPI):
            def rerun_job(self, run_id, job_id, next_attempt):
                self.calls.append(f"rerun-job:{job_id}")
                raise urllib.error.HTTPError("u", 422, "cannot", {}, None)

        jobs = [done("pick-nightly-build-runner", "success", id=901), done("build-nightly-app", "failure")]
        api = Refusing(clock, lambda s: jobs, workflow=picker_workflow())
        target = rescue.Target(RUN_ID, 1, HEAD, 0, path=rescue.NIGHTLY_WORKFLOW_PATH, side=True, nightly=True,
                               push_branch="nightly-next")
        lines = []
        text = rescue.rerun_failed_or_repick(api, target, clock.sleep, lines.append)
        self.assertEqual(api.calls[-2:], ["rerun-job:901", "rerun-failed"])
        self.assertIn("re-ran the failed jobs", text)
        self.assertTrue(any("was refused (422)" in line for line in lines), lines)

    def test_an_unreadable_run_re_runs_its_failed_jobs(self):
        clock = Clock()

        class Unreadable(NightlyAPI):
            def workflow_file(self, path, ref):
                raise OSError("down")

        api = Unreadable(clock, lambda s: [], workflow=picker_workflow())
        target = rescue.Target(RUN_ID, 1, HEAD, 0, path=rescue.NIGHTLY_WORKFLOW_PATH, side=True, nightly=True,
                               push_branch="nightly-next")
        lines = []
        text = rescue.rerun_failed_or_repick(api, target, clock.sleep, lines.append)
        self.assertEqual(api.calls[-1], "rerun-failed")
        self.assertIn("re-ran the failed jobs", text)
        self.assertTrue(any("could not read the run for a fresh runner pick" in line for line in lines), lines)


class SupersedingAPI(FakeAPI):
    def __init__(self, *args, newer=(), **kwargs):
        super().__init__(*args, **kwargs)
        self.newer = list(newer)

    def newer_push_runs(self, path, run_id, branch):
        self.calls.append(f"newer:{branch}")
        return self.newer


class NightlyAPI(FakeAPI):
    def __init__(self, *args, newer=(), pushes=(), **kwargs):
        super().__init__(*args, **kwargs)
        self.newer, self.pushes = list(newer), list(pushes)

    def newer_unfinished_runs(self, path, run_id, branch):
        self.calls.append(f"newer:{branch}")
        return self.newer

    def newer_push_runs(self, path, run_id, branch):
        self.calls.append(f"pushes:{branch}")
        return self.pushes


class NightlyRetryDestination(unittest.TestCase):
    """A held nightly-next owned job is judged by the label its re-run takes, read from its picker's log, and its
    hold on a stalled label is timed (NIGHTLY_HOLD_SECONDS). Run 40515681971 (2026-10-27) queued 5 h of 6 h on
    Blacksmith; a busy owned Mac could only take its jobs once the rescue had a timed Blacksmith fallback."""

    SMALL, LARGE = "blacksmith-6vcpu-macos-26", "blacksmith-12vcpu-macos-26"
    SIDE = "glaeda-side-std-xcode-26.6"
    TARGET = rescue.Target(RUN_ID, 1, HEAD, 0, side=True, nightly=True, path=rescue.NIGHTLY_WORKFLOW_PATH,
                           push_branch="nightly-next")
    BUILD_LOG = ["2026-10-27T13:51:45Z nightly build runner: owned: none (no idle runner)\n",
                 "2026-10-27T13:51:45Z nightly build runner: blacksmith: blacksmith-12vcpu-macos-26 (moving)\n"]
    SIGN_LOG = ["2026-10-27T16:01:40Z nightly sign runner: `blacksmith-6vcpu-macos-26`; a re-run takes "
                "`blacksmith-12vcpu-macos-26`\n"]

    def jobs(self, name="build-nightly-app", picker="pick-nightly-build-runner"):
        return [{**job(picker, status="completed", runner="linux"), "id": 7},
                {**job(name, labels=[self.SIDE]), "id": 8}]

    def api(self, jobs, logs, snapshot):
        api = NightlyAPI(Clock(), lambda seconds: jobs, workflow=f"a: {self.SMALL}\nb: {self.LARGE}\n",
                         snapshot=snapshot)
        api.job_log_lines = lambda job_id: logs.get(job_id)
        return api

    def verdict(self, api, target=None):
        return rescue.move_verdict(api, target or self.TARGET, now=START, sleep=lambda _: None, log=lambda _: None)

    def test_the_picker_s_label_decides_not_every_label_the_file_names(self):
        stalled_small = blacksmith_snapshot(queued=40, oldest=300, label=self.SMALL)
        for name, picker, log in (("build-nightly-app", "pick-nightly-build-runner", self.BUILD_LOG),
                                  ("Verify signed nightly app (arm64)", "pick-nightly-sign-runner", self.SIGN_LOG)):
            with self.subTest(job=name):
                api = self.api(self.jobs(name, picker), {7: log}, stalled_small)
                self.assertEqual(rescue.nightly_retry_destinations(api, self.TARGET, lambda _: None, lambda _: None),
                                 {self.LARGE})
                # The re-run takes the 12 vCPU label, which has room: the stalled 6 vCPU one never holds it.
                self.assertEqual(self.verdict(api), ("free", ""))
        stalled_large = blacksmith_snapshot(queued=40, oldest=300, label=self.LARGE)
        api = self.api(self.jobs(), {7: self.BUILD_LOG}, stalled_large)
        self.assertEqual(self.verdict(api), ("stalled", self.LARGE))

    def test_an_unknown_destination_falls_back_to_the_workflow_s_labels(self):
        stalled_small = blacksmith_snapshot(queued=40, oldest=300, label=self.SMALL)
        cases = {
            "unread log": ({}, self.jobs()),
            "no label in the log": ({7: ["nightly build runner: owned: none\n"]}, self.jobs()),
            "a job with no known picker": ({7: self.BUILD_LOG}, self.jobs("prepare-nightly-variant")),
        }
        for why, (logs, jobs) in cases.items():
            with self.subTest(why=why):
                api = self.api(jobs, logs, stalled_small)
                self.assertIsNone(rescue.nightly_retry_destinations(api, self.TARGET, lambda _: None, lambda _: None))
                self.assertEqual(self.verdict(api), ("stalled", self.SMALL))
        # Only nightly-next: main's nightly and every other workflow keep the workflow's labels.
        api = self.api(self.jobs(), {7: self.BUILD_LOG}, stalled_small)
        main = dataclasses.replace(self.TARGET, push_branch="main")
        self.assertIsNone(rescue.nightly_retry_destinations(api, main, lambda _: None, lambda _: None))
        self.assertEqual(self.verdict(api, main), ("stalled", self.SMALL))

    def test_the_legacy_identity_jobs_read_legacy_identity_target_s_label(self):
        stalled_small = blacksmith_snapshot(queued=40, oldest=300, label=self.SMALL)
        for name in ("sign-nightly-identity-legacy", "verify-nightly-identity-legacy"):
            with self.subTest(job=name):
                api = self.api(self.jobs(name, "legacy-identity-target"), {7: self.SIGN_LOG}, stalled_small)
                self.assertEqual(rescue.nightly_retry_destinations(api, self.TARGET, lambda _: None, lambda _: None),
                                 {self.LARGE})
                self.assertEqual(self.verdict(api), ("free", ""))

    def test_a_label_the_snapshot_does_not_judge_falls_back_to_the_workflow_s_labels(self):
        # The picker may print a size the janitor's pools do not list: it has no state, so it never reads "free".
        stalled_small = blacksmith_snapshot(queued=40, oldest=300, label=self.SMALL)
        log = ["nightly build runner: blacksmith: blacksmith-24vcpu-macos-26 (moving)\n"]
        api = self.api(self.jobs(), {7: log}, stalled_small)
        self.assertEqual(rescue.nightly_retry_destinations(api, self.TARGET, lambda _: None, lambda _: None),
                         {"blacksmith-24vcpu-macos-26"})
        self.assertEqual(self.verdict(api), ("stalled", self.SMALL))

    def test_only_picker_lines_are_cached_and_job_marks_caches_no_log(self):
        client = rescue.GitHub.__new__(rescue.GitHub)
        client._logs, client._log_lines = {}, {}
        body = ["x" * 1000 + "\n"] * 50 + self.BUILD_LOG
        reads = []
        client._read_log_lines = lambda job_id: reads.append(job_id) or list(body)
        self.assertEqual(client.job_log_lines(7), self.BUILD_LOG)
        self.assertEqual(client.job_log_lines(7), self.BUILD_LOG)
        self.assertEqual(reads, [7])
        client.job_marks(9)
        self.assertNotIn(9, client._log_lines)

    def test_a_held_nightly_job_moves_after_the_hold_and_others_stay_held(self):
        stalled = blacksmith_snapshot(queued=40, running=0, oldest=30)
        for nightly in (True, False):
            with self.subTest(nightly=nightly):
                clock = Clock()
                api = self.api(self.jobs(), {}, stalled)
                target = dataclasses.replace(self.TARGET, nightly=nightly)
                lines = []
                deadline = START + dt.timedelta(hours=10)
                with unittest.mock.patch.object(rescue, "watch", return_value=("rescue", "build-nightly-app queued")):
                    outcome, _, why = rescue.hold_for_destination(
                        api, target, "rescue", "build-nightly-app queued", budget_seconds=30, floor_seconds=30,
                        deadline=deadline if nightly else START + dt.timedelta(hours=2), now=clock.now,
                        sleep=clock.sleep, log=lines.append, seen={})
                self.assertIn("is stalled", why)
                if nightly:
                    self.assertEqual(outcome, "rescue")
                    self.assertGreaterEqual(clock.seconds, rescue.NIGHTLY_HOLD_SECONDS)
                    self.assertLess(clock.seconds, rescue.NIGHTLY_HOLD_SECONDS + 2 * rescue.STALL_RECHECK_SECONDS)
                else:
                    self.assertEqual((outcome, clock.now() >= START + dt.timedelta(hours=2)), ("stop", True))

    def test_a_held_nightly_job_moves_at_the_watch_limit(self):
        clock = Clock()
        api = self.api(self.jobs(), {}, blacksmith_snapshot(queued=40, running=0, oldest=30))
        lines = []
        with unittest.mock.patch.object(rescue, "watch", return_value=("rescue", "build-nightly-app queued")), \
                unittest.mock.patch.object(rescue, "NIGHTLY_HOLD_SECONDS", 10 ** 6):
            outcome, _, _ = rescue.hold_for_destination(
                api, self.TARGET, "rescue", "build-nightly-app queued", budget_seconds=30, floor_seconds=30,
                deadline=START + dt.timedelta(seconds=900), now=clock.now, sleep=clock.sleep, log=lines.append,
                seen={})
        self.assertEqual(outcome, "rescue")
        self.assertTrue(any(line.startswith("moving the held nightly job at the watch limit") for line in lines), lines)


    def test_from_the_last_move_attempt_a_held_nightly_waits_on_its_owned_pool(self):
        # Each move re-runs the picker, which queues on the owned pool again while Blacksmith stays stalled: from
        # NIGHTLY_LAST_MOVE_ATTEMPT on the job is held untimed and left queued there at the watch limit.
        for attempt, moves in ((rescue.NIGHTLY_LAST_MOVE_ATTEMPT - 1, True), (rescue.NIGHTLY_LAST_MOVE_ATTEMPT, False)):
            with self.subTest(attempt=attempt):
                clock = Clock()
                api = self.api(self.jobs(), {}, blacksmith_snapshot(queued=40, running=0, oldest=30))
                target = dataclasses.replace(self.TARGET, attempt=attempt)
                lines = []
                with unittest.mock.patch.object(rescue, "watch", return_value=("rescue", "build-nightly-app queued")):
                    outcome, reason, _ = rescue.hold_for_destination(
                        api, target, "rescue", "build-nightly-app queued", budget_seconds=30, floor_seconds=30,
                        deadline=START + dt.timedelta(hours=2), now=clock.now, sleep=clock.sleep,
                        log=lines.append, seen={})
                self.assertEqual(rescue.nightly_moves(target), moves)
                if moves:
                    self.assertEqual(outcome, "rescue")
                    self.assertLess(clock.seconds, rescue.NIGHTLY_HOLD_SECONDS + 2 * rescue.STALL_RECHECK_SECONDS)
                else:
                    self.assertEqual((outcome, reason), ("stop", "watch limit reached"))

    def test_a_late_attempt_whose_build_is_off_the_owned_pools_is_not_watched_on(self):
        started = START + dt.timedelta(minutes=10)
        before, after = (START + dt.timedelta(minutes=1)).isoformat(), (START + dt.timedelta(minutes=12)).isoformat()

        def picker(name, at):
            return {**job(name, status="completed", runner="linux"), "started_at": at}
        build_kept, sign_kept = picker("pick-nightly-build-runner", before), picker("pick-nightly-sign-runner", before)
        build_bs = {**job("build-nightly-app", labels=[self.LARGE]), "started_at": None}
        picker_kept = build_kept
        # Both pickers kept from an earlier attempt: every owned runs-on falls through to Blacksmith.
        self.assertTrue(rescue.nightly_build_off_owned([build_kept, sign_kept, build_bs], started))
        # A picker that ran on this attempt, or one not listed yet, may still place a later job on an owned pool
        # (review on #28019: a queued Blacksmith build ended the watch before its owned verify jobs appeared).
        self.assertFalse(rescue.nightly_build_off_owned([picker("pick-nightly-build-runner", after), sign_kept,
                                                         build_bs], started))
        self.assertFalse(rescue.nightly_build_off_owned([build_kept, picker("pick-nightly-sign-runner", after),
                                                         build_bs], started))
        self.assertFalse(rescue.nightly_build_off_owned([build_kept, build_bs], started))
        self.assertFalse(rescue.nightly_build_off_owned([], started))
        # watch() ends such an attempt at once past SIGN_RESCUE_LAST_ATTEMPT; up to it, its signing stalls keep it.
        clock = Clock()
        api = self.api([], {}, None)
        api.attempt, api.rerun_jobs = rescue.SIGN_RESCUE_LAST_ATTEMPT + 1, lambda s: [picker_kept, sign_kept, build_bs]
        target = dataclasses.replace(self.TARGET, attempt=rescue.SIGN_RESCUE_LAST_ATTEMPT + 1,
                                     attempt_started_at=started)
        outcome, reason = rescue.watch(api, target, budget_seconds=600, deadline=START + dt.timedelta(hours=2),
                                       now=clock.now, sleep=clock.sleep, log=lambda _: None)[:2]
        self.assertEqual((outcome, reason), ("stop", f"no job of attempt {target.attempt} can take a persistent pool"))
        self.assertEqual(clock.seconds, rescue.FIRST_LOOK_SECONDS)  # its first look

class Nightly(unittest.TestCase):
    def test_started_dev_delivery_protects_a_later_queued_job(self):
        clock = Clock()

        def jobs(_seconds):
            return [job("runner", status="completed", runner="linux"),
                    {**job("tip-dmg-build", status="completed", runner="mini"), "conclusion": "success"},
                    job("verify", status="queued", labels=["glaeda-side-std-xcode-26.6"])]

        api = NightlyAPI(clock, jobs)
        target = rescue.Target(RUN_ID, 1, HEAD, 0, e2e=True, path=DEV_DAILY, event="workflow_dispatch")
        result = rescue.rescue(api, target, now=clock.now, sleep=clock.sleep, log=lambda _: None)
        self.assertIn("started delivery work", result)
        self.assertNotIn("cancel", api.calls)

    """nightly.yml's app build takes the trusted owned pool on attempt 1 of main's push and schedule runs."""

    def test_only_attempt_1_of_main_s_own_push_or_schedule_run(self):
        for kind in ("push", "schedule"):
            target = rescue.target_from_event(nightly_event(event=kind), "manaflow-ai/cmux")
            self.assertEqual((target.nightly, target.side, target.main, target.e2e, target.pr_number),
                             (True, True, False, False, 0), kind)
        cases = {
            "dispatch": nightly_event(event="workflow_dispatch"),
            "release candidate branch": nightly_event(head_branch="rc/1.2"),
            "fork head": nightly_event(head_repository={"full_name": "someone/cmux"}),
            "attempt 2": nightly_event(run_attempt=2),
            "nightly-next schedule": nightly_event(event="schedule", head_branch="nightly-next"),
            "nightly-next pull request": nightly_event(event="pull_request", head_branch="nightly-next"),
            "nightly-next fork dispatch": nightly_event(event="workflow_dispatch", head_branch="nightly-next",
                                                        head_repository={"full_name": "someone/cmux"}),
        }
        for why, payload in cases.items():
            self.assertIsInstance(rescue.target_from_event(payload, "manaflow-ai/cmux"), str, why)

    def test_nightly_decide_fleet_control_label_is_a_rescuable_pool(self):
        control = {"name": "decide", "labels": ["gcp-linux-control"], "status": "queued"}
        self.assertEqual(rescue.job_pool(control), "gcp-linux-control")
        self.assertIsNone(rescue.job_pool({**control, "labels": ["ubuntu-24.04"]}))

    def test_a_started_next_decide_protects_later_queued_delivery_work(self):
        decide = {**job("decide", status="completed", runner="mini"),
                  "conclusion": "success", "started_at": stamp(10), "completed_at": stamp(20)}
        queued = job("build-nightly-app", labels=[TRUSTED], created=30)
        clock = Clock()
        api = NightlyAPI(clock, lambda _seconds: [decide, queued])
        target = rescue.Target(RUN_ID, 1, HEAD, 0, path=rescue.NIGHTLY_WORKFLOW_PATH,
                               side=True, nightly=True, push_branch="nightly-next", event="push")
        result = rescue.rescue(api, target, now=clock.now, sleep=clock.sleep, log=lambda _: None)
        self.assertIn("started delivery work", result)
        self.assertIn("decide", result)
        self.assertNotIn("cancel", api.calls)

    def test_a_never_started_next_decide_does_not_block_no_start_rescue(self):
        queued = lambda _seconds: [
            job("decide", labels=["glaeda-nightly-std-xcode-26.6"]),
            job("build-nightly-app", labels=[TRUSTED], created=30),
        ]
        clock = Clock()
        api = NightlyAPI(clock, queued)
        target = rescue.Target(RUN_ID, 1, HEAD, 0, path=rescue.NIGHTLY_WORKFLOW_PATH,
                               side=True, nightly=True, push_branch="nightly-next", event="push")
        result = rescue.rescue(api, target, now=clock.now, sleep=clock.sleep, log=lambda _: None)
        self.assertIn("cancel", api.calls)
        self.assertNotIn("decide", result)

    def test_a_completed_decide_without_a_start_record_does_not_block_next_rescue(self):
        decide = job("decide", status="completed") | {"conclusion": "success"}
        queued = job("build-nightly-app", labels=[TRUSTED], created=30)
        clock = Clock()
        api = NightlyAPI(clock, lambda _seconds: [decide, queued])
        target = rescue.Target(RUN_ID, 1, HEAD, 0, path=rescue.NIGHTLY_WORKFLOW_PATH,
                               side=True, nightly=True, push_branch="nightly-next", event="push")
        result = rescue.rescue(api, target, now=clock.now, sleep=clock.sleep, log=lambda _: None)
        self.assertIn("cancel", api.calls)
        self.assertNotIn("started delivery work", result)

    def test_a_queued_next_decide_with_a_runner_assignment_is_still_not_started(self):
        decide = job("decide", runner="mini-1")
        self.assertFalse(rescue._started_delivery_job(decide))

    def test_a_completed_main_decide_does_not_block_rescue(self):
        decide = {**job("decide", status="completed", runner="mini"),
                  "conclusion": "success", "started_at": stamp(10), "completed_at": stamp(20)}
        queued = job("build-nightly-app", labels=[TRUSTED], created=30)
        clock = Clock()
        api = NightlyAPI(clock, lambda _seconds: [decide, queued])
        target = rescue.Target(RUN_ID, 1, HEAD, 0, path=rescue.NIGHTLY_WORKFLOW_PATH,
                               side=True, nightly=True, push_branch="main", event="push")
        result = rescue.rescue(api, target, now=clock.now, sleep=clock.sleep, log=lambda _: None)
        self.assertIn("cancel", api.calls)
        self.assertNotIn("started delivery work", result)

    def test_next_push_bootstrap_uses_the_explicit_180_second_window(self):
        clock = Clock()
        api = NightlyAPI(clock, nightly_run(started_at=30))
        _, summary = run_main(api, clock, payload=nightly_event(head_branch="nightly-next"))
        self.assertIn("budget 180s", summary)

    def test_a_next_dispatch_and_a_next_rerun_are_watched_through_the_picker_s_marker(self):
        # nightly-next's pick-nightly-build-runner gives a dispatch, and a re-run that picks again, an idle
        # owned Mac and uploads the owned-pool-watch marker; the sweeper adopts the run at its attempt.
        dispatch = nightly_event(event="workflow_dispatch", head_branch="nightly-next")["workflow_run"]
        target = rescue.target_from_event({"workflow_run": dispatch}, "manaflow-ai/cmux")
        self.assertEqual((target.nightly, target.side, target.push_branch, target.attempt),
                         (True, True, "nightly-next", 1))
        for event_name, attempt in (("workflow_dispatch", 1), ("workflow_dispatch", 2), ("push", 2), ("push", 3)):
            with self.subTest(event=event_name, attempt=attempt):
                run = {**dispatch, "event": event_name, "run_attempt": attempt, "status": "in_progress"}
                target = rescue.sweep_target(run, "manaflow-ai/cmux", late=False)
                self.assertIsInstance(target, rescue.Target)
                self.assertEqual((target.nightly, target.attempt, target.push_branch),
                                 (True, attempt, "nightly-next"))
        # Main's nightly keeps its scope: attempt 1 of a push or schedule only.
        for run in ({**dispatch, "head_branch": "main", "run_attempt": 3, "status": "in_progress"},
                    {**dispatch, "head_branch": "main", "status": "in_progress"}):
            self.assertIsInstance(rescue.sweep_target(run, "manaflow-ai/cmux", late=False), str)
        self.assertFalse(rescue.owned_rerun({**dispatch, "head_branch": "main", "run_attempt": 3}))

    def test_a_refused_next_dispatch_moves_its_failed_jobs_to_blacksmith(self):
        clock = Clock()
        api = NightlyAPI(clock, nightly_run(refused_at=60, helper_done_at=200), finished=lambda s: s >= 200)
        code, summary = run_main(api, clock, payload=nightly_event(event="workflow_dispatch", head_branch="nightly-next"))
        self.assertEqual(code, 0)
        self.assertNotIn("cancel", api.calls)
        self.assertIn("rerun-failed", api.calls)
        self.assertIn("Blacksmith", summary)

    def next_helper_run(self, *, app_running_until, refused_at=None):
        """A nightly-next dispatch or re-pick: the Ghostty helper on the picker's owned side label, the app
        build on Blacksmith."""
        side = "glaeda-side-std-xcode-26.6"

        def jobs(seconds):
            app = job("build-nightly-app", labels=[BLACKSMITH], runner="bs",
                      status="in_progress" if seconds < app_running_until else "completed")
            if seconds >= app_running_until:
                app["conclusion"] = "success"
            found = [job("decide", status="completed", labels=[BLACKSMITH]), app]
            if seconds < 15:
                return found
            if refused_at is not None and seconds >= refused_at:
                return found + [refused_job("build-nightly-ghostty-cli-helper", labels=(side,))]
            return found + [job("build-nightly-ghostty-cli-helper", labels=[side], created=15)]
        return jobs

    def test_a_stuck_next_helper_never_cancels_a_running_app_build(self):
        # pick-nightly-build-runner gives a dispatch, and a re-run that picks again, an owned side Mac for the
        # Ghostty helper (cmux#26253, cmux#26237). A helper stuck there never cancels the run while the app
        # build still runs on Blacksmith (cmux#26192); it moves once nothing else runs.
        for event_name, attempt in (("workflow_dispatch", 1), ("workflow_dispatch", 2), ("push", 2)):
            with self.subTest(event=event_name, attempt=attempt):
                clock = Clock()
                api = NightlyAPI(clock, self.next_helper_run(app_running_until=10 ** 6),
                                 finished=lambda s: False)
                target = rescue.sweep_target({**nightly_event(event=event_name, head_branch="nightly-next",
                                                              run_attempt=attempt)["workflow_run"],
                                              "status": "in_progress"}, "manaflow-ai/cmux", late=False)
                self.assertIsInstance(target, rescue.Target)
                with unittest.mock.patch("sys.stdout", io.StringIO()):
                    rescue.follow(api, target, seconds=30, queue_rounds="0", now=clock.now, sleep=clock.sleep,
                                  log=lambda text: None)
                self.assertNotIn("cancel", api.calls)
                self.assertNotIn("force-cancel", api.calls)
        clock = Clock()
        api = NightlyAPI(clock, self.next_helper_run(app_running_until=400), finished=lambda s: False)
        _, summary = run_main(api, clock, payload=nightly_event(event="workflow_dispatch", head_branch="nightly-next"),
                              env_extra={"RESCUE_SECONDS": "30"})
        self.assertIn("build-nightly-ghostty-cli-helper", summary)
        if "cancel" in api.calls:
            self.assertGreaterEqual(clock.seconds, 400)

    def test_a_refused_next_helper_reruns_its_failed_jobs_without_a_cancel(self):
        clock = Clock()
        api = NightlyAPI(clock, self.next_helper_run(app_running_until=100, refused_at=60), finished=lambda s: s >= 200)
        code, _ = run_main(api, clock, payload=nightly_event(event="workflow_dispatch", head_branch="nightly-next"))
        self.assertEqual(code, 0)
        self.assertNotIn("cancel", api.calls)
        self.assertEqual(api.calls[-1], "rerun-failed")

    def test_a_newer_next_push_never_cancels_this_one(self):
        # Each nightly-next run builds in its own groups, so a newer tip builds alongside this one.
        payload = nightly_event(head_branch="nightly-next")
        target = rescue.target_from_event(payload, "manaflow-ai/cmux")
        self.assertIsInstance(target, rescue.Target)
        self.assertEqual(target.push_branch, "nightly-next")
        clock = Clock()
        api = NightlyAPI(clock, nightly_run(refused_at=60, helper_done_at=200), finished=lambda s: s >= 200,
                         newer=[RUN_ID + 7], head="b" * 40, pushes=[RUN_ID + 7])
        run_main(api, clock, payload=payload, env_extra={"RESCUE_SECONDS": "30"})
        self.assertNotIn("cancel", api.calls)
        self.assertNotIn("newer:nightly-next", api.calls)
        self.assertEqual(api.calls[-1], "rerun-failed")

    # nightly-next's build-nightly-app as an owned-only job (as sign-nightly-identity-legacy is there).
    OWNED_ONLY = ("jobs:\n  build-nightly-app:\n    runs-on: ${{ needs.pick.outputs.attempt == github.run_attempt && "
                  "needs.pick.outputs.owned || vars.CI_NIGHTLY_NEXT_BUILD_RUNNER || 'glaeda-std-xcode-26.6' }}\n"
                  "    steps: []\n")

    @staticmethod
    def with_ids(jobs):
        """nightly_run()'s jobs with ids, so their annotations can be read."""
        return lambda seconds: [dict(found, id=900 + index) for index, found in enumerate(jobs(seconds))]

    def test_a_next_run_older_than_the_feeds_newest_build_is_not_re_run(self):
        # 2026-10-31: cmux-bot kept re-running old nightly-next runs while the feed already had a newer run's
        # build; publish-nightly refuses an older build, so such a re-run only holds a slot.
        clock = Clock()
        api = NightlyAPI(clock, nightly_run(refused_at=60, helper_done_at=200), finished=lambda s: s >= 200)
        api.next_feed_newest_build = lambda: (RUN_ID + 3) * 100 + 2
        code, summary = run_main(api, clock, payload=nightly_event(head_branch="nightly-next"))
        self.assertEqual(code, 0)
        self.assertNotIn("rerun-failed", api.calls)
        self.assertNotIn("rerun", api.calls)
        self.assertNotIn("cancel", api.calls)
        self.assertIn("publish-nightly refuses an older build", summary)

    def test_the_run_the_feeds_newest_build_came_from_is_still_re_run(self):
        # Its legacy jobs may still have the old feed to publish.
        clock = Clock()
        api = NightlyAPI(clock, nightly_run(refused_at=60, helper_done_at=200), finished=lambda s: s >= 200)
        api.next_feed_newest_build = lambda: RUN_ID * 100 + 1
        run_main(api, clock, payload=nightly_event(head_branch="nightly-next"))
        self.assertEqual(api.calls[-1], "rerun-failed")

    def test_a_refusal_for_a_hook_the_commit_never_lists_is_not_re_run(self):
        # glaeda's hook reads scripts/ci/glaeda-signing-hooks.txt at the run's own commit, so a re-run of that
        # commit is refused the same way (sign-nightly-identity-legacy reached attempt 15 on 2026-10-31).
        clock = Clock()
        api = NightlyAPI(clock, self.with_ids(nightly_run(refused_at=60, helper_done_at=200)),
                         finished=lambda s: s >= 200, workflow=self.OWNED_ONLY)
        refused_ids = set()

        def annotations(job_id, *, final=False):
            api.calls.append(f"annotations:{job_id}")
            if job_id in refused_ids:
                return [{"message": "glaeda-cmux-runner-hook: refused: scripts/ci/glaeda-signing-hooks.txt at this "
                                    "run's commit does not list this hook (df0e90b42c73), so the job's claim gate "
                                    "would refuse the whole mini"}]
            return []
        jobs_at = api.jobs_at
        refused_ids.update(found["id"] for found in jobs_at(300) if found["name"] == "build-nightly-app")
        api.annotations = annotations
        code, summary = run_main(api, clock, payload=nightly_event(head_branch="nightly-next"))
        self.assertEqual(code, 0)
        self.assertNotIn("rerun-failed", api.calls)
        self.assertNotIn("cancel", api.calls)
        self.assertIn("does not list the minis' runner hook", summary)

    def test_an_unlisted_hook_refusal_whose_re_run_can_leave_the_minis_is_still_re_run(self):
        # A runs-on with an attempt-2 alternate (or a Blacksmith pick) sends the re-run past the hook.
        for workflow in (self.OWNED_ONLY.replace("vars.CI_NIGHTLY_NEXT_BUILD_RUNNER",
                                                 "github.run_attempt > 1 && needs.pick.outputs.sign_alternate"),
                         self.OWNED_ONLY.replace("vars.CI_NIGHTLY_NEXT_BUILD_RUNNER",
                                                 "needs.pick.outputs.blacksmith"),
                         None):
            with self.subTest(workflow=workflow):
                clock = Clock()
                api = NightlyAPI(clock, self.with_ids(nightly_run(refused_at=60, helper_done_at=200)),
                                 finished=lambda s: s >= 200, workflow=workflow)
                api.annotations = lambda job_id, *, final=False: [{"message": rescue.HOOK_UNLISTED}]
                run_main(api, clock, payload=nightly_event(head_branch="nightly-next"))
                self.assertEqual(api.calls[-1], "rerun-failed")

    def test_an_unlisted_hook_refusal_during_a_feed_outage_is_still_re_run(self):
        # #29448: a feed that cannot be read keeps the run wanted; the refusal is not judged moot meanwhile.
        clock = Clock()
        api = NightlyAPI(clock, self.with_ids(nightly_run(refused_at=60, helper_done_at=200)),
                         finished=lambda s: s >= 200, workflow=self.OWNED_ONLY)
        api.annotations = lambda job_id, *, final=False: [{"message": rescue.HOOK_UNLISTED}]

        def outage():
            raise urllib.error.URLError("files-next.cmux.com unreachable")
        api.next_feed_newest_build = outage
        run_main(api, clock, payload=nightly_event(head_branch="nightly-next"))
        self.assertEqual(api.calls[-1], "rerun-failed")

    def test_the_feed_read_raises_on_an_outage_instead_of_reading_as_no_build(self):
        api = rescue.GitHub("t", "manaflow-ai/cmux")
        with unittest.mock.patch.object(rescue.urllib.request, "urlopen",
                                        side_effect=urllib.error.URLError("unreachable")):
            with self.assertRaises(rescue.READ_ERRORS):
                api.next_feed_newest_build()

        class Response(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False
        with unittest.mock.patch.object(rescue.urllib.request, "urlopen", return_value=Response(b"<rss></rss>")):
            self.assertIsNone(api.next_feed_newest_build())

    # nightly.yml's sign-nightly-identity-legacy: its picker's output, else a Blacksmith literal.
    LEGACY = ("jobs:\n  sign-nightly-identity-legacy:\n    runs-on: ${{ needs.legacy-identity-target.outputs.sign_runner"
              " || 'blacksmith-6vcpu-macos-26' }}\n    steps: []\n")

    def test_a_failed_jobs_re_run_keeps_a_picked_owned_label_whatever_its_fallback_literal(self):
        # #29447: a re-run of failed jobs keeps the picker's output, so the Blacksmith literal is never reached for a
        # job the minis' hook refused; only a runs-on that reads the attempt can move.
        name = "sign-nightly-identity-legacy"
        self.assertTrue(rescue.rerun_stays_owned(self.LEGACY, name, failed_only=True))
        # Attempt 1 of nightly-next may re-run pickers: the fallback literal still counts as a way off the minis.
        self.assertFalse(rescue.rerun_stays_owned(self.LEGACY, name))
        attempt_alt = self.LEGACY.replace("needs.legacy-identity-target.outputs.sign_runner ||",
                                          "github.run_attempt > 1 && needs.legacy-identity-target.outputs.alt ||"
                                          " needs.legacy-identity-target.outputs.sign_runner ||")
        self.assertFalse(rescue.rerun_stays_owned(attempt_alt, name, failed_only=True))
        pinned = self.OWNED_ONLY.replace("vars.CI_NIGHTLY_NEXT_BUILD_RUNNER", "needs.pick.outputs.blacksmith")
        self.assertFalse(rescue.rerun_stays_owned(pinned, "build-nightly-app", failed_only=True))
        self.assertTrue(rescue.rerun_stays_owned(self.OWNED_ONLY, "build-nightly-app", failed_only=True))
        for text in (None, "", "jobs: [", self.LEGACY.replace("runs-on", "runs_on")):
            self.assertFalse(rescue.rerun_stays_owned(text, name, failed_only=True), text)

    def test_jobs_all_done_in_a_run_still_going_is_not_moot(self):
        # The jobs list can be all done while the run is still in progress (its later jobs not created yet).
        clock = Clock()
        api = NightlyAPI(clock, nightly_run(refused_at=60, helper_done_at=200), finished=lambda s: False)
        api.next_feed_newest_build = lambda: (RUN_ID + 3) * 100 + 2
        target = rescue.target_from_event(nightly_event(head_branch="nightly-next"), "manaflow-ai/cmux")
        clock.seconds = 300
        self.assertEqual(rescue.pull_moved(api, target, clock.sleep, lambda text: None), "")
        api.finished = lambda s: True
        self.assertIn("publish-nightly refuses", rescue.pull_moved(api, target, clock.sleep, lambda text: None))

    def test_an_other_refusal_is_still_re_run(self):
        clock = Clock()
        api = NightlyAPI(clock, self.with_ids(nightly_run(refused_at=60, helper_done_at=200)),
                         finished=lambda s: s >= 200)
        api.next_feed_newest_build = lambda: None  # the feed has no Nightly build
        run_main(api, clock, payload=nightly_event(head_branch="nightly-next"))
        self.assertEqual(api.calls[-1], "rerun-failed")

    def test_an_unfinished_next_run_is_never_moot(self):
        # A newer build in the feed never cancels a started nightly (Nightly freshness).
        clock = Clock()
        api = NightlyAPI(clock, nightly_run(refused_at=60), finished=lambda s: False)
        api.next_feed_newest_build = lambda: (RUN_ID + 3) * 100 + 2
        target = rescue.target_from_event(nightly_event(head_branch="nightly-next"), "manaflow-ai/cmux")
        clock.seconds = 100
        self.assertEqual(rescue.pull_moved(api, target, clock.sleep, lambda text: None), "")

    def test_the_feeds_newest_build_is_its_highest_version(self):
        xml = ("<item><sparkle:channel>cmux-next</sparkle:channel><sparkle:version>4119158082902</sparkle:version></item>"
               "<item><sparkle:channel>cmux-next</sparkle:channel><sparkle:version> 4118935876003 </sparkle:version></item>"
               "<item><sparkle:channel>cmux-next-dev</sparkle:channel><sparkle:version>9919158082902</sparkle:version></item>"
               "<item><sparkle:version>9999999999999</sparkle:version></item>")
        # A Dev item, or one with no channel, is no nightly run's build.
        self.assertEqual(rescue.newest_feed_build(xml), 4119158082902)
        self.assertIsNone(rescue.newest_feed_build("<rss></rss>"))

    def test_next_refusal_moves_failed_jobs_to_blacksmith(self):
        clock = Clock()
        api = NightlyAPI(clock, nightly_run(refused_at=60, helper_done_at=200), finished=lambda s: s >= 200)
        code, summary = run_main(api, clock, payload=nightly_event(head_branch="nightly-next"))
        self.assertEqual(code, 0)
        self.assertIn("rerun-failed", api.calls)
        self.assertIn("Blacksmith", summary)

    def test_the_trusted_pool_is_an_owned_label_only_here(self):
        self.assertEqual(rescue.job_pool({"labels": [TRUSTED]}), TRUSTED)
        # nightly.yml asks for the pool and one runner's own label together.
        self.assertEqual(rescue.job_pool({"labels": [TRUSTED, "glaeda-runner-cmux15-glaeda"]}), TRUSTED)
        self.assertEqual(rescue.job_pool({"labels": ["glaeda-root-trusted-std-xcode-26.6"]}),
                         "glaeda-root-trusted-std-xcode-26.6")
        self.assertIsNone(rescue.job_pool({"labels": ["glaeda-trusted"]}))
        # The pickers never hand it out: it is not a pull request pool.
        self.assertFalse(rescue.persistent(TRUSTED))

    def test_the_dedicated_nightly_builder_is_watched_but_never_a_pull_request_pool(self):
        # nightly_build_runner.py offers it first on nightly-next; a build queued on it while another
        # run holds it is moved after the budget, so no build waits on that one mini.
        self.assertEqual(rescue.job_pool({"labels": ["glaeda-trusted-next-nightly"]}), "glaeda-trusted-next-nightly")
        self.assertIsNone(rescue.job_pool({"labels": ["glaeda-trusted-next-nightly-x"]}))
        self.assertFalse(rescue.persistent("glaeda-trusted-next-nightly"))

    def test_the_marker_listing_pages_past_the_window_by_the_id_order_skew(self):
        api = rescue.GitHub("token", "manaflow-ai/cmux")
        start = dt.datetime(2026, 9, 27, 12, 0, tzinfo=dt.timezone.utc)
        oldest = start - dt.timedelta(minutes=150)

        def marker(run_id, minutes_ago):
            return {"workflow_run": {"id": run_id},
                    "created_at": (start - dt.timedelta(minutes=minutes_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")}

        # Ordered by id, not upload time: page two ends past the window but
        # under the skew, and page three still holds a marker inside it (run
        # 7, like run 36322763980 listed behind markers 78 minutes older).
        pages = {1: [marker(1, 0), marker(2, 60)], 2: [marker(3, 120), marker(4, 170)],
                 3: [marker(5, 200), marker(7, 140)], 4: [marker(8, 260), marker(9, 300)],
                 5: [marker(10, 330)]}
        paths, logs = [], []

        def request(method, path, **_):
            paths.append(path)
            page = int(path.rsplit("page=", 1)[1])
            if page in failing:
                raise urllib.error.URLError("down")
            return {"artifacts": pages[page]}

        failing = set()
        api.request = request
        found = [run_id for run_id, _ in api.marked_runs("owned-pool-watch", 2, oldest, 5, log=logs.append)]
        # Page four ends 90 minutes past the window, so the listing stops there.
        self.assertIn(7, found)
        self.assertEqual(found, [1, 2, 3, 4, 5, 7, 8, 9])
        self.assertEqual(len(paths), 4)
        # No window reads one page, as before.
        paths.clear()
        self.assertEqual(len(api.marked_runs("owned-pool-watch", 2)), 2)
        self.assertEqual(len(paths), 1)
        # A later page that cannot be read keeps the pages before it, and says so.
        failing = {3}
        self.assertEqual([r for r, _ in api.marked_runs("owned-pool-watch", 2, oldest, 5, log=logs.append)],
                         [1, 2, 3, 4])
        self.assertIn("could not read page 3", logs[-1])
        failing = {1}
        with self.assertRaises(urllib.error.URLError):
            api.marked_runs("owned-pool-watch", 2, oldest, 5)
        # Reaching the page cap short of the window is logged.
        failing = set()
        api.marked_runs("owned-pool-watch", 2, oldest, 2, log=logs.append)
        self.assertIn("without reaching", logs[-1])

    def test_owned_reruns_lists_cmux_next_attempt_two(self):
        """A sweep that adopted cmux-next attempt 1 by its marker returns after starting the re-run, and the run
        is already in `seen`, so attempt 2 is found only through this listing."""
        api = rescue.GitHub("token", "manaflow-ai/cmux")
        workflows = {"ci.yml": [], "cmux-next.yml": [
            {"id": RUN_ID, "path": ".github/workflows/cmux-next.yml", "event": "pull_request", "run_attempt": 2,
             "triggering_actor": {"login": ACTIONS_BOT}}]}

        def request(method, path, **_):
            name = path.split("/actions/workflows/")[1].split("/")[0]
            return {"workflow_runs": workflows[name] if "status=queued" in path else []}

        api.request = request
        self.assertEqual(api.owned_reruns(20), [(RUN_ID, 2)])

    def test_newer_unfinished_runs_reads_one_page_of_main_s_nightly_runs(self):
        api = rescue.GitHub("token", "manaflow-ai/cmux")
        seen = []
        runs = [{"id": RUN_ID + 2, "status": "pending", "event": "push"},
                {"id": RUN_ID + 1, "status": "completed", "event": "push"},
                {"id": RUN_ID, "status": "in_progress", "event": "push"},
                {"id": RUN_ID - 1, "status": "pending", "event": "push"},
                # The daily build and a full dispatch wait in the same `full` group.
                {"id": RUN_ID + 3, "status": "pending", "event": "schedule"},
                {"id": RUN_ID + 6, "status": "pending", "event": "workflow_dispatch"},
                # The six-hourly cache seed runs in its own group, never pending behind this run.
                {"id": RUN_ID + 4, "status": "in_progress", "event": "schedule"},
                {"id": RUN_ID + 5, "status": "queued", "event": "workflow_dispatch"}]
        api.request = lambda method, path, **_: seen.append((method, path)) or {"workflow_runs": runs}
        self.assertEqual(api.newer_unfinished_runs(rescue.NIGHTLY_WORKFLOW_PATH, RUN_ID, "main"),
                         [RUN_ID + 2, RUN_ID + 3, RUN_ID + 6])
        self.assertEqual(seen, [("GET", "/actions/workflows/nightly.yml/runs?branch=main&per_page=20")])

    def test_a_run_with_no_trusted_job_stops_when_it_finishes(self):
        # Its jobs listed so far finishing is not enough: its sign and verify jobs appear later (signs_late).
        clock = Clock()
        api = NightlyAPI(clock, lambda s: [job("decide", status="completed", labels=[BLACKSMITH])],
                         finished=lambda s: s >= 300)
        code, summary = run_main(api, clock, payload=nightly_event())
        self.assertEqual(code, 0)
        self.assertIn("no job of the run asked for a persistent pool", summary)

    def test_a_build_a_trusted_mini_takes_is_watched_until_the_run_finishes(self):
        # An accepted app build can still time out (FeedTimeouts), so main's watch lasts like nightly-next's.
        clock = Clock()
        api = NightlyAPI(clock, nightly_run(started_at=30))
        code, summary = run_main(api, clock, payload=nightly_event())
        self.assertEqual(code, 0)
        self.assertIn("main's nightly build", summary)
        self.assertNotIn("the fleet accepted", summary)
        self.assertIn("stopped: watch limit reached", summary)
        self.assertNotIn("cancel", api.calls)

    def test_a_next_build_a_mini_takes_is_watched_until_the_run_finishes(self):
        # nightly-next's prepare-nightly-variant takes the side label later and can still be refused.
        clock = Clock()
        api = NightlyAPI(clock, nightly_run(started_at=30))
        code, summary = run_main(api, clock, payload=nightly_event(head_branch="nightly-next"))
        self.assertEqual(code, 0)
        self.assertNotIn("the fleet accepted", summary)
        self.assertIn("stopped: watch limit reached", summary)
        self.assertGreaterEqual(clock.seconds, rescue.NIGHTLY_WATCH_LIMIT_SECONDS)
        self.assertNotIn("cancel", api.calls)
        self.assertNotIn("rerun-failed", api.calls)

    def test_the_budget_is_the_configured_one_with_no_copied_allowance(self):
        # CI_OWNED_POOL_RESCUE_SECONDS alone: no nightly-only round on top (it was 930 s at 30).
        for seconds in ("30", "120"):
            clock = Clock()
            api = NightlyAPI(clock, nightly_run(started_at=30))
            _, summary = run_main(api, clock, payload=nightly_event(), env_extra={"RESCUE_SECONDS": seconds})
            self.assertIn(f"budget {seconds}s)", summary)

    def test_a_build_waiting_for_its_reserved_runner_is_never_cancelled(self):
        # Runs 39318999424, 39320477722, 39329116254, 39350597131: a wait past 930 s
        # behind a seed or an earlier build was cancelled and moved to Blacksmith.
        for branch, label in (("main", "glaeda-runner-cmux15-glaeda"),
                              ("nightly-next", "glaeda-runner-cmux22-nightly-next")):
            clock = Clock()
            api = NightlyAPI(clock, nightly_run(runner_label=label), newer=[RUN_ID + 7], pushes=[RUN_ID + 8])
            code, summary = run_main(api, clock, payload=nightly_event(head_branch=branch),
                                     env_extra={"RESCUE_SECONDS": "30"})
            self.assertEqual(code, 0)
            self.assertNotIn("cancel", api.calls, branch)
            self.assertNotIn("rerun-failed", api.calls, branch)
            self.assertIn(f"waiting for the runner reserved for it", summary)
            self.assertIn("watch limit reached", summary)
            self.assertIn(f"::warning::build-nightly-app was still waiting for its reserved runner {label}", summary)

    def test_a_build_held_in_its_reserved_runner_s_setup_is_never_cancelled(self):
        clock = Clock()
        api = NightlyAPI(clock, nightly_run(runner_label="glaeda-runner-cmux15-glaeda", started_at=20,
                                            setup_until=90 * 60))
        _, summary = run_main(api, clock, payload=nightly_event(), env_extra={"RESCUE_SECONDS": "30"})
        # Past SETUP_WAIT_SECONDS and into the watch's closing margin, where an unreserved job is moved.
        self.assertNotIn("cancel", api.calls)
        self.assertIn("watch limit reached", summary)

    def test_a_refused_reserved_build_is_still_moved(self):
        clock = Clock()
        api = NightlyAPI(clock, nightly_run(refused_at=60, runner_label="glaeda-runner-cmux22-nightly-next",
                                                  helper_done_at=200), finished=lambda s: s >= 200)
        _, summary = run_main(api, clock, payload=nightly_event(head_branch="nightly-next"))
        self.assertEqual(api.calls[-1], "rerun-failed")

    def test_a_later_job_refused_after_the_build_was_accepted_is_still_moved(self):
        # Run 40144317744: build-nightly-app ran on cmux14-glaeda-3, and the
        # prepare-nightly-variant job behind it, created 20 minutes later on the
        # same side label, was refused for disk. The watch had already stopped.
        built_at, refused_at = 20 * 60, 21 * 60

        def jobs(seconds):
            found = [job("decide", status="completed", labels=[BLACKSMITH])]
            app = job("build-nightly-app", labels=[SIDE], created=15, runner="cmux14-glaeda-3",
                      status="completed" if seconds >= built_at else "in_progress")
            app.update(started_at=stamp(20), steps=[{"name": "Set up runner", "conclusion": "success"}])
            if seconds >= built_at:
                app.update(conclusion="success", completed_at=stamp(built_at))
            found.append(app)
            if seconds >= refused_at:
                prepare = refused_job("prepare-nightly-variant (arm64)", seconds=60, labels=(SIDE,),
                                      steps=[{"name": "Set up runner", "conclusion": "failure"}])
                found.append(prepare)
            elif seconds >= built_at:
                found.append(job("prepare-nightly-variant (arm64)", labels=[SIDE], created=built_at))
            return found

        clock = Clock()
        api = NightlyAPI(clock, jobs, finished=lambda s: s >= refused_at + 120)
        _, summary = run_main(api, clock, payload=nightly_event(head_branch="nightly-next"))
        self.assertNotIn("the fleet accepted", summary)
        # The refusal waits for the run to finish: nothing healthy is cancelled.
        self.assertNotIn("cancel", api.calls)
        self.assertEqual(api.calls[-1], "rerun-failed")

    def test_a_run_cancelled_before_any_job_stops_when_it_finishes(self):
        clock = Clock()
        api = NightlyAPI(clock, lambda s: [], finished=lambda s: s >= 100)
        _, summary = run_main(api, clock, payload=nightly_event(head_branch="nightly-next"))
        self.assertIn("stopped: the run finished with no job", summary)
        self.assertLess(clock.seconds, 300)

    def test_a_job_pinned_after_the_build_moves_after_a_short_wait(self):
        # #26494: main's prepare-nightly-variant legs take the trusted mini right after the build, and a newer
        # push's build can take it first. The build's own wait stays untimed; the legs move after
        # RESERVED_FOLLOWER_SECONDS, unless another job of the run is running.
        pinned = [TRUSTED, "glaeda-runner-cmux15-glaeda"]
        legs = [dict(job(f"prepare-nightly-variant ({variant})", labels=pinned, created=0), id=index)
                for index, variant in enumerate(("primary", "fallback", "legacy"), start=10)]
        built = dict(job("build-nightly-app", status="completed", labels=pinned), id=1, conclusion="success")
        early = START + dt.timedelta(seconds=rescue.RESERVED_FOLLOWER_SECONDS - 1)
        late = START + dt.timedelta(seconds=rescue.RESERVED_FOLLOWER_SECONDS)
        self.assertEqual(rescue.assess([built, *legs], now=early, budget_seconds=30, reserved=True).action, "watch")
        look = rescue.assess([built, *legs], now=late, budget_seconds=30, reserved=True)
        self.assertEqual(look.action, "rescue", look.reason)
        self.assertIn("prepare-nightly-variant (primary)", look.reason)
        # One leg running on the mini: the others wait for it (a started nightly is never cancelled).
        running = dict(legs[0], status="in_progress", runner_name="cmux15")
        self.assertEqual(rescue.assess([built, running, *legs[1:]], now=late, budget_seconds=30,
                                       reserved=True).action, "watch")
        # The build's wait is never timed, however long.
        build = dict(job("build-nightly-app", labels=pinned, created=0), id=1)
        self.assertEqual(rescue.assess([build], now=late + dt.timedelta(hours=2), budget_seconds=30,
                                       reserved=True).action, "watch")

    def test_main_s_pinned_legs_are_re_run_when_main_moved_on(self):
        # The app is built, so a newer main push does not make the run moot: its failed jobs are re-run.
        pinned = [TRUSTED, "glaeda-runner-cmux15-glaeda"]

        def jobs(seconds):
            return [dict(job("decide", status="completed", labels=[BLACKSMITH]), id=1, conclusion="success"),
                    dict(job("build-nightly-app", status="completed", labels=pinned), id=2, conclusion="success"),
                    dict(job("prepare-nightly-variant (primary)", labels=pinned, created=60), id=3)]
        clock = Clock()
        api = NightlyAPI(clock, jobs, pushes=[RUN_ID + 1])
        api.branch_head = lambda branch: "b" * 40
        _, summary = run_main(api, clock, payload=nightly_event())
        self.assertEqual(mutations(api), [], summary)
        # Before the build has succeeded, main moving on still cancels without a re-run, as before.
        self.assertEqual(rescue.app_built([jobs(0)[0], dict(jobs(0)[1], conclusion="failure")]), False)

    def test_only_a_nightly_honours_a_runner_label(self):
        # A pull request's compile admission names a warm runner as a preference: still rescued.
        stuck = job("macos / macOS compile admission", labels=[MINI, "glaeda-runner-cmux1-glaeda"], created=0)
        now = START + dt.timedelta(seconds=600)
        self.assertEqual(rescue.assess([stuck], now=now, budget_seconds=90).action, "rescue")
        build = dict(stuck, name="build-nightly-app")
        self.assertEqual(rescue.assess([build], now=now, budget_seconds=90, reserved=True).action, "watch")
        # With no runner label the nightly's job is judged on the configured budget.
        plain = job("build-nightly-app", labels=[TRUSTED], created=0)
        self.assertEqual(rescue.assess([plain], now=now, budget_seconds=90, reserved=True).action, "rescue")
        self.assertEqual(rescue.reserved_runner({"labels": [TRUSTED, "glaeda-runner-x"]}), "glaeda-runner-x")
        self.assertIsNone(rescue.reserved_runner({"labels": [TRUSTED]}))

    def test_a_superseded_main_commit_is_never_rerun(self):
        # On main: a newer push run that is already running or done, not pending.
        clock = Clock()
        api = NightlyAPI(clock, nightly_run(refused_at=60, helper_done_at=200), finished=lambda s: s >= 200,
                         head="c" * 40, pushes=[RUN_ID + 4])
        _, summary = run_main(api, clock, payload=nightly_event())
        self.assertNotIn("rerun-failed", api.calls)
        self.assertIn("main has moved on to cccccccccccc", summary)
        # A newer push run on the same head (a re-push) does not supersede it.
        clock = Clock()
        api = NightlyAPI(clock, nightly_run(refused_at=60, helper_done_at=200), finished=lambda s: s >= 200, pushes=[RUN_ID + 3])
        run_main(api, clock, payload=nightly_event(head_branch="nightly-next"))
        self.assertEqual(api.calls[-1], "rerun-failed")
        # A moved head with no newer push run (outside the workflow's paths) does not either.
        clock = Clock()
        api = NightlyAPI(clock, nightly_run(refused_at=60, helper_done_at=200), finished=lambda s: s >= 200, head="b" * 40)
        run_main(api, clock, payload=nightly_event())
        self.assertEqual(api.calls[-1], "rerun-failed")

    def test_a_stuck_build_never_cancels_a_started_sibling(self):
        # The Blacksmith helper build is mid-job: a started nightly is never cancelled for a slow runner,
        # not even at the watch's end.
        clock = Clock()
        api = NightlyAPI(clock, nightly_run())
        code, summary = run_main(api, clock, payload=nightly_event(), env_extra={"RESCUE_SECONDS": "30"})
        self.assertEqual(code, 0)
        self.assertNotIn("cancel", api.calls)
        self.assertNotIn("rerun-failed", api.calls)
        self.assertIn("a started nightly is never cancelled", summary)
        self.assertIn("watch limit reached", summary)

    def test_a_stuck_build_moves_to_blacksmith_keeping_what_passed_once_nothing_else_runs(self):
        clock = Clock()
        api = NightlyAPI(clock, nightly_run(helper_done_at=300))
        code, summary = run_main(api, clock, payload=nightly_event(), env_extra={"RESCUE_SECONDS": "30"})
        self.assertEqual(code, 0)
        self.assertNotIn("cancel", api.calls)
        self.assertIn("started delivery work", summary)
        self.assertNotIn("rerun", api.calls)
        self.assertNotIn("pull", api.calls)
        self.assertIn(f"queued on {TRUSTED}", summary)

    def test_a_held_build_never_cancels_a_started_sibling_at_the_watch_end(self):
        looks = []
        jobs = nightly_run(started_at=20, setup_until=10 ** 9)(30 * 60)
        for closing in (False, True):
            deadline = START + dt.timedelta(seconds=30 * 60 + (30 if closing else 3600))
            looks.append(rescue.assess(jobs, now=START + dt.timedelta(seconds=30 * 60), budget_seconds=30,
                                       deadline=deadline, reserved=True).action)
        self.assertEqual(looks, ["watch", "watch"])

    def test_a_refusal_at_the_watch_end_never_cancels_a_started_nightly(self):
        clock = Clock()
        api = NightlyAPI(clock, nightly_run(refused_at=60))
        _, summary = run_main(api, clock, payload=nightly_event())
        self.assertNotIn("cancel", api.calls)
        self.assertNotIn("rerun-failed", api.calls)
        self.assertIn("watch limit reached with a started nightly still running", summary)

    def test_a_sibling_that_starts_after_the_look_is_never_cancelled(self):
        # assess() saw nothing else running; by the cancel a Linux job (no owned or Blacksmith label) runs.
        for newer, moved in (((), False), ([RUN_ID + 7], True)):
            clock = Clock()
            linux = job("publish-nightly", labels=["blacksmith-2vcpu-ubuntu-2404"], status="in_progress",
                        runner="linux")
            api = NightlyAPI(clock, lambda seconds: nightly_run(helper_done_at=0)(seconds) + [linux],
                             newer=newer)
            target = rescue.Target(RUN_ID, 1, HEAD, 0, side=True, nightly=True, path=rescue.NIGHTLY_WORKFLOW_PATH)
            result = rescue.rescue(api, target, now=clock.now, sleep=clock.sleep, log=lambda _: None,
                                   failed_only=True)
            self.assertNotIn("cancel", api.calls, moved)
            self.assertTrue(result.startswith(rescue.NIGHTLY_BUSY), result)
            self.assertIn("publish-nightly", result)

    def late_sibling_api(self, *, stalled_from_sibling=False, retry=False):
        """Nightly: the build stuck on the trusted pool, nothing else running at the look; a Linux sibling starts
        right after it (at the first superseded check, which every rescue makes) and runs 540 s."""
        clock = Clock()
        state = {"start": None}
        lasts = 540

        def sibling_running():
            return state["start"] is not None and clock.seconds < state["start"] + lasts

        def jobs(seconds):
            found = nightly_run(helper_done_at=0)(seconds)
            if sibling_running():
                found.append(job("publish-nightly", labels=["blacksmith-2vcpu-ubuntu-2404"], status="in_progress",
                                 runner="linux"))
            return found
        stalled = blacksmith_snapshot(queued=40, running=0, oldest=30)
        free = blacksmith_snapshot()

        class API(NightlyAPI):
            def newer_unfinished_runs(self, path, run_id, branch):
                if state["start"] is None and not retry:
                    state["start"] = clock.seconds
                return super().newer_unfinished_runs(path, run_id, branch)

            def cancel(self, run_id, before_send=None):
                if retry and state["start"] is None:
                    # The first send is refused for a rate limit; the sibling starts during the wait.
                    before_send()
                    state["start"] = clock.seconds
                super().cancel(run_id, before_send)
        api = API(clock, jobs, workflow="runs-on: blacksmith-6vcpu-macos-26\n",
                  snapshot=lambda seconds: (stalled if stalled_from_sibling and state["start"] is not None
                                            else free)(seconds))
        target = rescue.Target(RUN_ID, 1, HEAD, 0, side=True, nightly=True, path=rescue.NIGHTLY_WORKFLOW_PATH)
        return clock, api, target, state, lasts

    def test_the_watch_resumes_and_moves_the_build_once_the_late_sibling_ends(self):
        for retry in (False, True):
            clock, api, target, state, lasts = self.late_sibling_api(retry=retry)
            lines = []
            result = rescue.follow(api, target, seconds=30, queue_rounds="0", now=clock.now, sleep=clock.sleep,
                                   log=lines.append)
            self.assertTrue(any(line.startswith(rescue.NIGHTLY_BUSY) for line in lines), (retry, lines))
            self.assertIn("watch limit reached", result, retry)
            self.assertNotIn("cancel", api.calls)

    def test_a_resumed_watch_still_holds_off_a_stalled_label_for_the_nightly_hold(self):
        # The hold on a stalled label is timed for a nightly (NIGHTLY_HOLD_SECONDS): it then moves, never left queued.
        clock, api, target, state, lasts = self.late_sibling_api(stalled_from_sibling=True)
        lines = []
        rescue.follow(api, target, seconds=30, queue_rounds="0", now=clock.now, sleep=clock.sleep, log=lines.append)
        held = [index for index, line in enumerate(lines) if line.startswith("held on the owned pool")]
        self.assertTrue(held, lines)
        self.assertTrue(any(line.startswith("moving the held nightly job") for line in lines), lines)
        self.assertNotIn("cancel", api.calls)

    def test_a_sibling_in_its_runner_setup_is_started_work(self):
        setup = {**job("publish-nightly", status="in_progress", runner="linux"),
                 "steps": [{"name": "Set up job", "status": "in_progress"}]}
        jobs = nightly_run(helper_done_at=0)(30 * 60) + [setup]
        look = rescue.assess(jobs, now=START + dt.timedelta(seconds=30 * 60), budget_seconds=30, reserved=True)
        self.assertEqual(look.action, "watch")
        api = NightlyAPI(Clock(), lambda seconds: jobs)
        target = rescue.Target(RUN_ID, 1, HEAD, 0, side=True, nightly=True, path=rescue.NIGHTLY_WORKFLOW_PATH)
        self.assertEqual(rescue.started_nightly_work(api, target, lambda _: None, lambda _: None),
                         "build-nightly-ghostty-cli-helper, publish-nightly")
        # A nightly build held in its own runner's setup is started too: never cancelled, even at the end.
        held = nightly_run(started_at=20, setup_until=10 ** 9, helper_done_at=0)(30 * 60)
        for closing in (False, True):
            deadline = START + dt.timedelta(seconds=30 * 60 + (30 if closing else 3600))
            self.assertEqual(rescue.assess(held, now=START + dt.timedelta(seconds=30 * 60), budget_seconds=30,
                                           deadline=deadline, reserved=True).action, "watch")

    def test_a_retried_cancel_of_a_nightly_reads_its_jobs_again(self):
        class Limited(rescue.GitHub):
            def __init__(self):
                super().__init__("t", "manaflow-ai/cmux")
                self.sent = []

            def request(self, method, path, *, own_token=False, body=None, before_retry=None, before_send=None):
                self.sent.append(path)
                if before_send is not None:
                    before_send()  # as GitHub.request does before each send
                return {}

            def jobs(self, run_id, attempt):
                return [job("publish-nightly", status="in_progress", runner="linux")]
        api = Limited()
        target = rescue.Target(RUN_ID, 1, HEAD, 0, side=True, nightly=True, path=rescue.NIGHTLY_WORKFLOW_PATH)
        api.run = lambda run_id: {"run_attempt": 1, "status": "in_progress"}
        with self.assertRaises(rescue.NightlyBusy):
            rescue.nightly_cancel(api, target, lambda _: None, lambda _: None)

    def test_a_retried_cancel_is_dropped_once_someone_re_ran_the_nightly(self):
        # Through GitHub.request's own rate-limit retry: the first cancel gets 429; during the wait another
        # watch starts attempt 2, whose jobs run. No second cancel may go out.
        import email.message
        sent = []
        attempt = {"now": 1}

        class Http(rescue.GitHub):
            def __init__(self):
                super().__init__("t", "manaflow-ai/cmux")
                self.sleep = lambda seconds: attempt.update(now=2)

            def run(self, run_id):
                return {"run_attempt": attempt["now"], "status": "in_progress"}

            def jobs(self, run_id, attempt_number):
                return [job("decide", status="completed")]  # attempt 1's jobs: nothing running there

        def urlopen(request, timeout=None):
            sent.append(request.get_method() + " " + request.full_url)
            headers = email.message.Message()
            headers["Retry-After"] = "1"
            raise urllib.error.HTTPError(request.full_url, 429, "rate limited", headers, io.BytesIO(b"{}"))
        api = Http()
        target = rescue.Target(RUN_ID, 1, HEAD, 0, side=True, nightly=True, path=rescue.NIGHTLY_WORKFLOW_PATH)
        with unittest.mock.patch("urllib.request.urlopen", urlopen):
            with self.assertRaises(rescue.Aborted) as raised:
                rescue.nightly_cancel(api, target, lambda _: None, lambda _: None)
        self.assertNotIsInstance(raised.exception, rescue.NightlyBusy)
        self.assertIn("attempt 2", str(raised.exception))
        self.assertEqual([line for line in sent if line.endswith("/cancel")], [sent[0]])

    def guard_http(self, limited):
        """A real GitHub over a fake urlopen: `limited` is the request path part ("/jobs" or "/runs/<id>") whose first
        send gets a 429; during its wait the nightly moves on as `state` says."""
        import email.message
        sent, state = [], {"attempt": 1, "running": False, "limited": False}

        class Response(io.BytesIO):
            headers = {}

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        def urlopen(request, timeout=None):
            method, url = request.get_method(), request.full_url
            sent.append(f"{method} {url}")
            if not state["limited"] and url.split("?")[0].endswith(limited):
                state["limited"] = True
                headers = email.message.Message()
                headers["Retry-After"] = "1"
                raise urllib.error.HTTPError(url, 429, "rate limited", headers, io.BytesIO(b"{}"))
            if url.endswith("/cancel"):
                return Response(b"{}")
            if "/jobs" in url:
                status = "in_progress" if state["running"] else "completed"
                return Response(json.dumps({"jobs": [job("publish-nightly", status=status)]}).encode())
            return Response(json.dumps({"run_attempt": state["attempt"], "status": "in_progress"}).encode())

        api = rescue.GitHub("t", "manaflow-ai/cmux")
        api.read_headers = api.headers  # every read on the token that waits through a rate limit
        return api, sent, state, unittest.mock.patch("urllib.request.urlopen", urlopen)

    def test_a_rate_limited_jobs_read_never_lets_the_cancel_hit_a_newer_attempt(self):
        # The jobs GET waits through a 429; meanwhile attempt 1 ends and attempt 2 starts. The retried read still
        # returns attempt 1's finished jobs, so only the run read after it can tell: no cancel goes out.
        api, sent, state, patch = self.guard_http("/attempts/1/jobs")
        api.sleep = lambda seconds: state.update(attempt=2)
        target = rescue.Target(RUN_ID, 1, HEAD, 0, side=True, nightly=True, path=rescue.NIGHTLY_WORKFLOW_PATH)
        with patch, self.assertRaises(rescue.Aborted) as raised:
            rescue.nightly_cancel(api, target, lambda _: None, lambda _: None)
        self.assertNotIsInstance(raised.exception, rescue.NightlyBusy)
        self.assertIn("attempt 2", str(raised.exception))
        self.assertFalse([line for line in sent if line.endswith("/cancel")], sent)

    def test_a_rate_limited_run_read_looks_at_the_jobs_again(self):
        # The run GET waits through a 429; meanwhile a job of the nightly starts. The guard reads the jobs again.
        api, sent, state, patch = self.guard_http(f"/runs/{RUN_ID}")
        api.sleep = lambda seconds: state.update(running=True)
        target = rescue.Target(RUN_ID, 1, HEAD, 0, side=True, nightly=True, path=rescue.NIGHTLY_WORKFLOW_PATH)
        with patch, self.assertRaises(rescue.NightlyBusy) as raised:
            rescue.nightly_cancel(api, target, lambda _: None, lambda _: None)
        self.assertIn("publish-nightly", str(raised.exception))
        self.assertFalse([line for line in sent if line.endswith("/cancel")], sent)

    def test_a_linux_sibling_blocks_the_look_too(self):
        jobs = nightly_run(helper_done_at=0)(30 * 60) + [
            job("publish-nightly", labels=["blacksmith-2vcpu-ubuntu-2404"], status="in_progress", runner="linux")]
        look = rescue.assess(jobs, now=START + dt.timedelta(seconds=30 * 60), budget_seconds=30, reserved=True)
        self.assertEqual(look.action, "watch")
        self.assertIn("a started nightly is never cancelled", look.reason)

    def test_a_stuck_build_behind_which_a_newer_nightly_waits_is_cancelled_not_rerun(self):
        # nightly.yml never cancels in progress: the newer run is pending behind
        # this one, and a re-run would join the group and cancel it.
        clock = Clock()
        api = NightlyAPI(clock, nightly_run(helper_done_at=300), newer=[RUN_ID + 7])
        _, summary = run_main(api, clock, payload=nightly_event(), env_extra={"RESCUE_SECONDS": "30"})
        self.assertNotIn("cancel", api.calls)
        self.assertNotIn("rerun-failed", api.calls)
        self.assertIn("a newer nightly run on main", summary)

    def test_a_refused_build_is_rerun_once_the_run_finishes(self):
        clock = Clock()
        api = NightlyAPI(clock, nightly_run(refused_at=60, helper_done_at=200), finished=lambda s: s >= 200)
        code, summary = run_main(api, clock, payload=nightly_event())
        self.assertEqual(code, 0)
        self.assertIn("waiting for the rest of the run to finish", summary)
        self.assertNotIn("cancel", api.calls)
        self.assertEqual(api.calls[-1], "rerun-failed")
        self.assertGreaterEqual(clock.seconds, 200)
        # A newer nightly run builds main's newer HEAD instead: left as it is.
        clock = Clock()
        api = NightlyAPI(clock, nightly_run(refused_at=60, helper_done_at=200), finished=lambda s: s >= 200, newer=[RUN_ID + 1])
        _, summary = run_main(api, clock, payload=nightly_event())
        self.assertNotIn("rerun-failed", api.calls)
        self.assertIn("not rescued", summary)


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
        # The Iroh release gate's runner job places its Tailscale job the same way.
        path = ".github/workflows/iroh-release-gate.yml"
        target = rescue.target_from_event(e2e_event(path=path), "manaflow-ai/cmux")
        self.assertEqual((target.pr_number, target.e2e, target.picker_job, target.path), (0, True, "runner", path))
        # Signing and streamed validation never take an owned Mac, so they are never watched.
        for path in (".github/workflows/ios-testflight.yml", ".github/workflows/ios-streamed-validate.yml"):
            self.assertIsInstance(rescue.target_from_event(e2e_event(path=path), "manaflow-ai/cmux"), str)

    def test_kit_pr_rescues_only_the_unstarted_test_after_three_minutes(self):
        def jobs(seconds):
            return [e2e_runner()(seconds),
                    {**job("cmux-next-ios kit tests", labels=[MINI, IOS_SIM]), "id": 123}]
        clock = Clock()
        api = FakeAPI(clock, jobs, marker=True, snapshot=lambda seconds: {
            "generated_at": stamp(seconds), "pools": {MINI: {"running": 0}}})
        code, summary = run_main(api, clock, payload=event(path=rescue.IOS_KIT_WORKFLOW_PATH),
                                 env_extra={"RESCUE_SECONDS": "600", "QUEUE_ROUNDS": "8"})
        self.assertEqual(code, 0, summary)
        self.assertIn("budget 180s", summary)
        self.assertIn("cancel", api.calls)
        self.assertIn("rerun-job:123", api.calls)
        self.assertNotIn("rerun", api.calls)
        self.assertNotIn("rerun-failed", api.calls)
        self.assertEqual(api.first_cancel, rescue.FIRST_LOOK_SECONDS + 180)

    def test_other_ios_prs_keep_the_existing_e2e_exclusion_on_an_idle_pool(self):
        clock = Clock()
        api = FakeAPI(clock, lambda seconds: [e2e_runner()(seconds), {
            **job("ios-simulator-build", labels=[MINI, IOS_SIM]), "id": 123}], marker=True,
            snapshot=lambda seconds: {"generated_at": stamp(seconds), "pools": {MINI: {"running": 0}}})
        _, summary = run_main(api, clock, payload=event(path=rescue.IOS_TEST_WORKFLOW_PATH))
        assert_left_at_open_head(self, api, summary)
        self.assertNotIn("rerun-job:123", api.calls)

    def test_kit_pr_never_cancels_a_running_or_assigned_test(self):
        for status, runner in (("in_progress", "mini"), ("queued", "mini")):
            with self.subTest(status=status):
                clock = Clock()
                api = FakeAPI(clock, lambda seconds: [e2e_runner()(seconds), {
                    **job("cmux-next-ios kit tests", labels=[MINI, IOS_SIM],
                          status=status, runner=runner), "id": 123}], marker=True,
                    finished=lambda seconds: seconds >= 240,
                    snapshot=lambda seconds: {"generated_at": stamp(seconds),
                                              "pools": {MINI: {"running": 0}}})
                code, summary = run_main(api, clock, payload=event(path=rescue.IOS_KIT_WORKFLOW_PATH))
                self.assertEqual(code, 0, summary)
                self.assertNotIn("cancel", api.calls)
                self.assertNotIn("rerun-job:123", api.calls)

    def test_kit_targets_accept_same_repo_pr_push_and_dispatch_only(self):
        for kind in ("pull_request", "push", "workflow_dispatch"):
            with self.subTest(event=kind):
                payload = event(path=rescue.IOS_KIT_WORKFLOW_PATH, event=kind)
                target = rescue.target_from_event(payload, "manaflow-ai/cmux")
                self.assertIsInstance(target, rescue.Target)
                self.assertTrue(target.e2e)
                self.assertEqual(target.picker_job, "runner")
                fork = event(path=rescue.IOS_KIT_WORKFLOW_PATH, event=kind,
                             head_repository={"full_name": "someone/cmux"})
                self.assertIsInstance(rescue.target_from_event(fork, "manaflow-ai/cmux"), str)

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
        self.assertEqual(api.calls[-1], "rerun-failed")  # attempt 2 is on Blacksmith: not watched
        self.assertIn("a dispatch of .github/workflows/test-ios.yml", summary)
        self.assertIn(f"queued on {MINI}", summary)

    def test_a_pull_request_run_waiting_for_the_simulator_label_is_left_at_its_open_head(self):
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
        assert_left_at_open_head(self, api, summary)
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
        # Cancelled at once, not held: a failed main run opens the red-CI issue.
        self.assertIn("cancel", api.calls)
        self.assertNotIn("waiting for the rest of the run", summary)
        self.assertLess(clock.seconds, 600)
        # Even once main moved: a fleet refusal must not leave main's run red.
        clock = Clock()
        api = FakeAPI(clock, refusing_run(), marker=True, head="b" * 40)
        code, summary = run_main(api, clock, payload=main_event())
        self.assertEqual(code, 0)
        self.assertIn("rerun-failed", api.calls)

    def test_a_stuck_later_main_attempt_is_cancelled_not_rerun_once_main_moves(self):
        # Attempt 2 re-runs its failed jobs when stuck, but a stuck job is no
        # refusal: main having moved, the run is only cancelled.
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True, head="b" * 40,
                      rerun_jobs=lambda seconds: [job("macos / tests", labels=[LIGHT])])
        api.attempt = 2
        target = rescue.Target(run_id=RUN_ID, attempt=2, head_sha=HEAD, pr_number=0, main=True)
        result = rescue.rescue(api, target, now=clock.now, sleep=clock.sleep, log=lambda _: None,
                               failed_only=True)
        self.assertEqual(result, f"cancelled run {RUN_ID}, not re-run: main has moved on, and "
                                 "ci-main-full-suite.yml dispatches its new HEAD once this run completes")
        self.assertNotIn("rerun-failed", api.calls)

    def test_a_moved_main_run_someone_re_ran_is_not_cancelled(self):
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True, head="b" * 40,
                      rerun_jobs=lambda seconds: [job("macos / tests", labels=[BLACKSMITH])])
        api.attempt = 2
        target = rescue.Target(run_id=RUN_ID, attempt=1, head_sha=HEAD, pr_number=0, main=True)
        result = rescue.rescue(api, target, now=clock.now, sleep=clock.sleep, log=lambda _: None)
        self.assertEqual(result, "not rescued: someone else already re-ran the run")
        self.assertNotIn("cancel", api.calls)

    def test_an_unreadable_moved_main_run_is_neither_cancelled_nor_blamed_on_a_re_run(self):
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True, head="b" * 40,
                      rerun_jobs=lambda seconds: [job("macos / tests", labels=[BLACKSMITH])])
        api.run = lambda run_id: {}
        target = rescue.Target(run_id=RUN_ID, attempt=1, head_sha=HEAD, pr_number=0, main=True)
        result = rescue.rescue(api, target, now=clock.now, sleep=clock.sleep, log=lambda _: None)
        self.assertTrue(result.startswith("not rescued: the run could not be read"), result)
        self.assertNotIn("cancel", api.calls)



class SweepAPI:
    """The sweeper's own reads: marker listings and the runs they name."""

    def __init__(self, runs, *, picker=(), late=(), refusals=(), created=0, attempt_jobs=None, failed=(), queued=()):
        self.failed = list(failed)  # failed side-lane run ids (failed_runs())
        self.failed_listings = 0
        self.queued = list(queued)  # queued side-lane run ids (queued_side_runs())
        self.queued_listings = 0
        self.runs = {run["id"]: run for run in runs}
        self.marked = {rescue.WATCH_MARKER: list(picker), rescue.LATE_WATCH_MARKER: list(late),
                       rescue.REFUSALS_WATCH_MARKER: list(refusals)}
        self.created, self.remaining, self.limit, self.reads = created, "900", "1000", []
        self.attempt_jobs = attempt_jobs or {}

    def jobs(self, run_id, attempt):
        return self.attempt_jobs.get(run_id, [])

    def marked_runs(self, name, count, oldest=None, pages=1, log=None):
        return [(run_id, START + dt.timedelta(seconds=self.created)) for run_id in self.marked[name]][:count * pages]

    def owned_reruns(self, count):
        return [(run["id"], int(run["run_attempt"])) for run in self.runs.values()
                if run.get("status") != "completed" and rescue.owned_rerun(run)][:count]

    def failed_runs(self, count, oldest, since=None, pages=1):
        self.failed_listings += 1
        return [(run_id, int(self.runs[run_id]["run_attempt"])) for run_id in self.failed][:count * pages]

    def queued_side_runs(self, count, oldest, pages=1):
        self.queued_listings += 1
        return [(run_id, int(self.runs[run_id]["run_attempt"])) for run_id in self.queued][:count * pages]

    def run(self, run_id):
        self.reads.append(run_id)
        return self.runs[run_id]


class CodeSweepAPI(SweepAPI):
    """A SweepAPI whose main changes the rescue script after `changes_after` code checks."""

    def __init__(self, *args, changes_after=None, fails=False, **kwargs):
        super().__init__(*args, **kwargs)
        self.checks, self.changes_after, self.fails, self.dispatched = 0, changes_after, fails, 0

    def code_shas(self, names):
        self.checks += 1
        if self.fails:
            raise urllib.error.URLError("down")
        changed = self.changes_after is not None and self.checks > self.changes_after
        return {name: ("new" if changed and name == "owned_pool_rescue.py" else "old") for name in names}

    def dispatch_sweeper(self):
        self.dispatched += 1


def listed(run_id, **overrides):
    run = dict(event(id=run_id)["workflow_run"])
    run.update(overrides)
    return run


class Sweeper(unittest.TestCase):
    def sweep(self, api, *, follow=None, ticks=3, light_retry=False):
        clock, watched = Clock(), []

        def fake_follow(client, target, **kwargs):
            watched.append((target.run_id, target.attempt, target.full_rerun) if light_retry
                           else (target.run_id, target.attempt, target.late))
            return follow(kwargs["sleep"]) if follow else "stopped: the run finished"

        with unittest.mock.patch.object(rescue, "follow", fake_follow):
            outcomes = rescue.sweep(api, "manaflow-ai/cmux", seconds=90, queue_rounds="0", light_retry=light_retry,
                                    now=clock.now, log=lambda text: None, sweep_seconds=ticks * 60,
                                    tick_seconds=60, wait=clock.sleep)
        return sorted(watched), outcomes

    def code_sweep(self, api, *, ticks=30, follow=None):
        clock, watched = Clock(), []

        def fake_follow(client, target, **kwargs):
            watched.append(target.run_id)
            return follow(kwargs) if follow else "stopped: the run finished"
        running = {name: "old" for name in rescue.CODE_FILES}
        with unittest.mock.patch.object(rescue, "follow", fake_follow):
            outcomes = rescue.sweep(api, "manaflow-ai/cmux", seconds=90, queue_rounds="0", now=clock.now,
                                    log=lambda text: None, sweep_seconds=ticks * 60, tick_seconds=60,
                                    wait=clock.sleep, running_code=running)
        return clock, watched, outcomes

    def test_a_re_run_whose_jobs_read_failed_is_adopted_on_a_later_tick(self):
        run = dict(nightly_event(head_branch="nightly-next")["workflow_run"], id=7, run_attempt=4,
                   status="in_progress")

        class API(SweepAPI):
            fails = rescue.READ_ATTEMPTS  # every retry of the first adoption's read

            def jobs(self, run_id, attempt):
                if API.fails:
                    API.fails -= 1
                    raise urllib.error.URLError("down")
                return []

            def nightly_reruns(self, count):
                return [(7, 4)]
        with unittest.mock.patch.object(rescue, "SIDE_FAILURE_TICKS", 1):
            watched, _ = self.sweep(API([run]), ticks=3)
        self.assertEqual(watched, [(7, 4, False)])

    def test_hands_over_once_main_s_code_changes(self):
        api = CodeSweepAPI([listed(1)], picker=[1], changes_after=1)
        clock, watched, outcomes = self.code_sweep(api)
        # Checked at the first tick and every CODE_CHECK_TICKS after; the second check sees the change.
        self.assertEqual(api.checks, 2)
        self.assertLess(clock.seconds, (rescue.CODE_CHECK_TICKS + 1) * 60)
        self.assertEqual(outcomes.get("code changed"), 1)
        self.assertEqual(api.dispatched, 1)
        self.assertEqual(watched, [1])

    def test_a_handover_dispatches_no_sweeper_when_one_already_waits(self):
        # 2026-10-30: the handover's dispatch cancelled the cron's pending sweeper (run 41071107039) in the
        # concurrency group before it ran. The waiting one checks out main, so it already runs the new code.
        class Waiting(CodeSweepAPI):
            def waiting_sweeper(self):
                return 41071107039
        api = Waiting([listed(1)], picker=[1], changes_after=1)
        _, _, outcomes = self.code_sweep(api)
        self.assertEqual(outcomes.get("code changed"), 1)
        self.assertEqual(api.dispatched, 0)

        class NoneWaiting(CodeSweepAPI):
            def waiting_sweeper(self):
                return None

        class Unreadable(CodeSweepAPI):
            def waiting_sweeper(self):
                raise urllib.error.URLError("down")
        for cls in (NoneWaiting, Unreadable):  # unknown dispatches as before, so a sweeper surely follows
            with self.subTest(api=cls.__name__):
                api = cls([listed(1)], picker=[1], changes_after=1)
                self.code_sweep(api)
                self.assertEqual(api.dispatched, 1)

    def test_waiting_sweeper_finds_a_queued_or_pending_sweeper_but_not_itself_or_a_rescue(self):
        client = rescue.GitHub("token", "manaflow-ai/cmux")
        client.own_run = 5
        listings = {"pending": [{"id": 5, "display_title": "owned-pool-sweeper"},
                                {"id": 6, "display_title": "owned-pool-rescue-77-1"}],
                    "queued": [{"id": 8, "display_title": "owned-pool-sweeper"}]}
        asked = []

        def request(method, path, **kwargs):
            asked.append(path)
            status = path.split("status=", 1)[1].split("&", 1)[0]
            return {"workflow_runs": listings.get(status, [])}
        client.request = request
        self.assertEqual(client.waiting_sweeper(), 8)
        self.assertEqual([path.split("?")[1].split("&")[0] for path in asked], ["status=pending", "status=queued"])
        listings["queued"] = []
        self.assertIsNone(client.waiting_sweeper())

    def test_unchanged_or_unreadable_code_keeps_sweeping(self):
        for api in (CodeSweepAPI([], changes_after=None), CodeSweepAPI([], fails=True)):
            clock, _, outcomes = self.code_sweep(api, ticks=12)
            self.assertNotIn("code changed", outcomes)
            self.assertEqual(api.dispatched, 0)
            self.assertGreaterEqual(clock.seconds, 12 * 60)
            self.assertEqual(api.checks, 3)  # ticks 0, 5 and 10

    def test_a_rescue_under_way_finishes_through_a_code_handover(self):
        # The watch sleeps through `sleep` (raises Stopping at handover); a rescue paces itself with
        # `rescue_sleep`, which never raises, so a cancel it started is followed by its re-run.
        finished = []

        def follow(kwargs):
            for _ in range(3):
                kwargs["rescue_sleep"](60)  # rescue under way: not interrupted by the handover
            finished.append(True)
            return "done"
        # A change seen at the very first check adopts nothing.
        api = CodeSweepAPI([listed(1)], picker=[1], changes_after=0)
        _, watched, _ = self.code_sweep(api, follow=follow)
        self.assertEqual((watched, api.dispatched), ([], 1))
        api = CodeSweepAPI([listed(1)], picker=[1], changes_after=1)
        _, watched, outcomes = self.code_sweep(api, follow=follow)
        self.assertEqual(watched, [1])
        self.assertEqual(finished, [True])
        self.assertEqual(outcomes.get("done"), 1)

    def test_running_code_shas_match_git(self):
        import subprocess
        shas = rescue.running_code_shas()
        for name in rescue.CODE_FILES:
            expected = subprocess.run(["git", "hash-object", str(ROOT / "scripts/ci" / name)], capture_output=True,
                                      text=True, check=True).stdout.strip()
            self.assertEqual(shas[name], expected, name)

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

    def test_watches_attempt_2_and_a_persons_re_run_on_any_attempt(self):
        # A re-run of failed jobs goes back to the minis with no marker of its own: attempt 2 whoever
        # started it (the failure attribution's, say), and a person's on any attempt.
        person, bot = {"login": "teamleaderleo"}, {"login": ACTIONS_BOT}
        api = SweepAPI([listed(1, run_attempt=3, triggering_actor=person),
                        listed(2, run_attempt=3, triggering_actor=bot),
                        listed(3, run_attempt=2, triggering_actor=person, status="completed", conclusion="success"),
                        listed(4, run_attempt=2, triggering_actor=bot),
                        listed(5, run_attempt=2, path=".github/workflows/test-e2e.yml", triggering_actor=bot)])
        self.assertEqual(self.sweep(api, ticks=1)[0], [(1, 3, False), (4, 2, False)])

    def test_resumes_the_attempt_a_rescue_re_ran(self):
        api = SweepAPI([listed(1, run_attempt=2), listed(2, run_attempt=3, triggering_actor={"login": ACTIONS_BOT})],
                       picker=[1, 2])
        # The bot's attempt 3 and later take Blacksmith: nothing to watch.
        self.assertEqual(self.sweep(api)[0], [(1, 2, False)])

    def test_an_e2e_full_rerun_is_resumed_as_one_without_light_retry(self):
        # The picker ran again on attempt 2, so its marker, not its jobs, decides.
        e2e = dict(path=".github/workflows/test-e2e.yml", event="workflow_dispatch", pull_requests=[],
                   run_attempt=2)
        picker = {"name": "runner", "run_attempt": 2}
        api = SweepAPI([listed(1, **e2e), listed(2, **e2e)], picker=[1, 2],
                       attempt_jobs={1: [picker], 2: [{"name": "runner", "run_attempt": 1}]})
        self.assertEqual(self.sweep(api, light_retry=True)[0], [(1, 2, True), (2, 2, False)])
        clock, targets = Clock(), []

        def fake_follow(client, target, **kwargs):
            targets.append(target.full_rerun)
            return "stopped: the run finished"
        with unittest.mock.patch.object(rescue, "follow", fake_follow):
            rescue.sweep(api, "manaflow-ai/cmux", seconds=90, queue_rounds="0", light_retry=False,
                         now=clock.now, log=lambda text: None, sweep_seconds=120, tick_seconds=60,
                         wait=clock.sleep)
        self.assertEqual(sorted(targets), [False, True])

    def test_a_run_with_no_free_overflow_is_watched_for_refusals_only(self):
        # Run 39615562861, 2026-10-21: placement found no free Blacksmith slot, so the scheme compile
        # stayed on the side label and a re-run could only rejoin that queue. The sweeper cancelled
        # and re-ran it twice while it waited. Its marker says so; the bot's re-runs inherit it.
        path = ".github/workflows/cmux-next.yml"
        bot = {"login": ACTIONS_BOT}
        api = SweepAPI([listed(1, path=path), listed(2, path=path),
                        listed(3, path=path, run_attempt=2, triggering_actor=bot)],
                       picker=[2], refusals=[1, 3])
        clock, targets = Clock(), []

        def fake_follow(client, target, **kwargs):
            targets.append((target.run_id, target.attempt, target.refusals_only))
            if target.run_id == 1 and target.attempt == 1:
                # The rescue re-ran a refused job: attempt 2 is found among the re-runs next tick.
                api.runs[1].update(run_attempt=2, triggering_actor=bot)
            return "stopped: the run finished"
        with unittest.mock.patch.object(rescue, "follow", fake_follow):
            rescue.sweep(api, "manaflow-ai/cmux", seconds=90, queue_rounds="0", now=clock.now,
                         log=lambda text: None, sweep_seconds=180, tick_seconds=60, wait=clock.sleep)
        self.assertEqual(sorted(targets), [(1, 1, True), (1, 2, True), (2, 1, False), (3, 2, True)])

    def test_a_marker_older_than_the_watch_still_marks_a_re_run(self):
        # A new sweeper finds attempt 2 of a run whose attempt-1 marker is past SWEEP_MAX_AGE_SECONDS.
        bot = {"login": ACTIONS_BOT}
        api = SweepAPI([listed(1, path=".github/workflows/cmux-next.yml", run_attempt=2, triggering_actor=bot)],
                       refusals=[1], created=-rescue.SWEEP_MAX_AGE_SECONDS - 60)
        clock, targets = Clock(), []

        def fake_follow(client, target, **kwargs):
            targets.append((target.run_id, target.attempt, target.refusals_only))
            return "stopped: the run finished"
        with unittest.mock.patch.object(rescue, "follow", fake_follow):
            rescue.sweep(api, "manaflow-ai/cmux", seconds=90, queue_rounds="0", now=clock.now,
                         log=lambda text: None, sweep_seconds=60, tick_seconds=60, wait=clock.sleep)
        self.assertEqual(targets, [(1, 2, True)])

    def test_a_cmux_next_re_run_waits_for_the_refusals_listing(self):
        # The refusals listing failed: a cmux-next re-run is adopted on a later tick, with its mark;
        # a ci.yml re-run, which has none, is adopted at once.
        bot = {"login": ACTIONS_BOT}
        api = SweepAPI([listed(1, path=".github/workflows/cmux-next.yml", run_attempt=2, triggering_actor=bot),
                        listed(2, run_attempt=2, triggering_actor=bot)], refusals=[1])
        listings = {"failed": False}
        real = api.marked_runs

        def flaky(name, count, oldest=None, pages=1, log=None):
            if name == rescue.REFUSALS_WATCH_MARKER and not listings["failed"]:
                listings["failed"] = True
                raise OSError("timed out")
            return real(name, count, oldest, pages, log)
        api.marked_runs = flaky
        clock, targets = Clock(), []

        def fake_follow(client, target, **kwargs):
            targets.append((target.run_id, target.attempt, target.refusals_only, int(clock.seconds)))
            return "stopped: the run finished"
        with unittest.mock.patch.object(rescue, "follow", fake_follow):
            rescue.sweep(api, "manaflow-ai/cmux", seconds=90, queue_rounds="0", now=clock.now,
                         log=lambda text: None, sweep_seconds=120, tick_seconds=60, wait=clock.sleep)
        self.assertEqual(sorted(targets), [(1, 2, True, 60), (2, 2, False, 0)])

    def test_a_failed_side_lane_run_is_adopted_without_a_marker(self):
        # Run 39638669325, 2026-10-21: cmux-next-base-autofix.yml's push run on feat-cmux-next. A mini refused
        # its Mac exports job at job start and the run failed; the workflow uploads no marker, so before this
        # listing no sweeper looked at it.
        autofix = dict(path=".github/workflows/cmux-next-base-autofix.yml", event="push", pull_requests=[],
                       head_branch="feat-cmux-next", status="completed", conclusion="failure",
                       updated_at=stamp(-60))
        api = SweepAPI([listed(1, **autofix), listed(2, **dict(autofix, run_attempt=2)),
                        listed(3, **dict(autofix, run_attempt=3)), listed(4, path=".github/workflows/cmux-next.yml",
                                                                          status="completed", conclusion="failure",
                                                                          updated_at=stamp(-60))],
                       picker=[4], failed=[1, 2, 3, 4])
        # Attempts 1 and 2 are watched once each; attempt 3 has had its owned retries. The marked run 4 is
        # watched through its marker and, once that watch has ended, taken up once more by the listing (a
        # side lane's watch stops when the fleet accepted its jobs; a runner stopped later fails the run).
        self.assertEqual(self.sweep(api, ticks=rescue.SIDE_FAILURE_TICKS + 1)[0],
                         [(1, 1, False), (2, 2, False), (4, 1, False), (4, 1, False)])
        # One listing per SIDE_FAILURE_TICKS ticks.
        self.assertEqual(api.failed_listings, 2)

    def test_a_queued_side_lane_run_is_adopted_without_a_marker_or_a_failure(self):
        # Run 41055587932, 2026-10-30: nightly-next-launch-smoke.yml's pull request run put its smoke on
        # glaeda-side-std-xcode-26.6 at 12:28Z, a label with no runner online, and it sat queued for over five
        # hours. The workflow uploads no marker and main's rescue has no workflow_run wakeup for it, and a run
        # that only waits never fails, so no sweeper ever watched it and the open-head failover never saw it.
        smoke = dict(path=".github/workflows/nightly-next-launch-smoke.yml", status="queued", conclusion=None)
        api = SweepAPI([listed(1, **smoke)], queued=[1])
        # Listed every SIDE_FAILURE_TICKS ticks, adopted once per attempt.
        self.assertEqual(self.sweep(api, ticks=rescue.SIDE_FAILURE_TICKS + 1)[0], [(1, 1, False)])
        self.assertEqual(api.queued_listings, 2)

    def test_a_queued_side_lane_run_already_watched_through_its_marker_is_not_adopted_again(self):
        next_run = dict(path=".github/workflows/cmux-next.yml", status="queued", conclusion=None)
        api = SweepAPI([listed(4, **next_run)], picker=[4], queued=[4])
        self.assertEqual(self.sweep(api, ticks=rescue.SIDE_FAILURE_TICKS + 1)[0], [(4, 1, False)])

    def test_queued_side_runs_lists_queued_side_lane_runs_only(self):
        api = rescue.GitHub("token", "manaflow-ai/cmux")
        seen = []
        smoke = ".github/workflows/nightly-next-launch-smoke.yml"
        pages = {1: [{"id": 9, "path": smoke, "run_attempt": 1, "event": "pull_request"},
                     {"id": 8, "path": ".github/workflows/ci.yml", "run_attempt": 1, "event": "pull_request"},
                     # A marker adopts cmux-next.yml's runs (sweep()).
                     {"id": 6, "path": rescue.CMUX_NEXT_WORKFLOW_PATH, "run_attempt": 1, "event": "pull_request"},
                     # A scheduled smoke is a delivery run (never_fails_over()): not listed.
                     {"id": 5, "path": smoke, "run_attempt": 1, "event": "schedule"}],
                 2: [{"id": 9, "path": smoke, "run_attempt": 1, "event": "pull_request"},
                     {"id": 7, "path": ".github/workflows/cmux-tui.yml", "run_attempt": 2, "event": "push"}]}

        def request(method, path, **_):
            seen.append(path)
            page = int(path.split("&page=")[1].split("&")[0])
            return {"workflow_runs": pages.get(page, [])}
        api.request = request
        self.assertEqual(api.queued_side_runs(3, START, pages=5), [(9, 1), (7, 2)])
        # Only an empty page ends the listing before `pages` (a status-filtered page can come back short).
        self.assertEqual(len(seen), 3)
        self.assertTrue(all("status=queued" in path for path in seen), seen)
        self.assertIn("created=%3E%3D2026-09-24T12:00:00Z", seen[0])

    def test_a_failed_marked_run_is_not_taken_up_while_its_watch_goes_on(self):
        next_run = dict(path=".github/workflows/cmux-next.yml", status="completed", conclusion="failure",
                        updated_at=stamp(-60))
        api = SweepAPI([listed(4, **next_run)], picker=[4], failed=[4])

        def forever(sleep):
            while True:
                sleep(0.01)
        watched, outcomes = self.sweep(api, follow=forever, ticks=rescue.SIDE_FAILURE_TICKS + 1)
        self.assertEqual(watched, [(4, 1, False)])
        self.assertEqual(outcomes, {"handed over": 1})

    def test_a_failed_side_lane_run_whose_read_failed_is_tried_again(self):
        # adopt() could not read the run: the next listing adopts it, rather than the run being marked seen.
        autofix = dict(path=".github/workflows/cmux-next-base-autofix.yml", event="push", pull_requests=[],
                       head_branch="feat-cmux-next", status="completed", conclusion="failure",
                       updated_at=stamp(-60))
        api = SweepAPI([listed(1, **autofix)], failed=[1])
        real, failures = api.run, {"left": rescue.READ_ATTEMPTS}

        def flaky(run_id):
            if failures["left"]:
                failures["left"] -= 1
                raise OSError("timed out")
            return real(run_id)
        api.run = flaky
        self.assertEqual(self.sweep(api, ticks=rescue.SIDE_FAILURE_TICKS + 1)[0], [(1, 1, False)])
        self.assertEqual(api.failed_listings, 2)

    def test_failed_runs_lists_side_lanes_since_the_window_and_the_last_sweeper(self):
        api = rescue.GitHub("token", "manaflow-ai/cmux")
        seen = []
        side = ".github/workflows/cmux-next-base-autofix.yml"
        pages = {1: [{"id": 9, "path": side, "run_attempt": 1, "updated_at": stamp(0)},
                     {"id": 8, "path": ".github/workflows/ci.yml", "run_attempt": 1, "updated_at": stamp(0)}],
                 2: [{"id": 7, "path": side, "run_attempt": 2, "updated_at": stamp(-3600)}]}

        def request(method, path, **_):
            seen.append(path)
            page = int(path.split("&page=")[1].split("&")[0])
            return {"workflow_runs": pages.get(page, [])}
        api.request = request
        self.assertEqual(api.failed_runs(2, START, since=START - dt.timedelta(minutes=30), pages=5), [(9, 1)])
        # Page 2 is short, which no longer ends the listing (failed_runs()): the empty page 3 does. Then one
        # page of cancelled runs (a rescue's cancel whose re-run never came).
        self.assertEqual(len(seen), 4)
        self.assertIn("status=failure", seen[0])
        self.assertIn("status=cancelled", seen[3])
        self.assertIn("created=%3E%3D2026-09-24T12:00:00Z", seen[0])

    def test_failed_runs_reads_past_a_short_page_while_the_total_says_more(self):
        api = rescue.GitHub("token", "manaflow-ai/cmux")
        side = ".github/workflows/cmux-next-base-autofix.yml"
        pages = {1: [{"id": 9, "path": side, "run_attempt": 1, "updated_at": stamp(0)}],
                 # A shifted listing repeats a row; it is listed once.
                 2: [{"id": 9, "path": side, "run_attempt": 1, "updated_at": stamp(0)},
                     {"id": 7, "path": side, "run_attempt": 2, "updated_at": stamp(0)}]}
        seen = []

        def request(method, path, **_):
            page = int(path.split("&page=")[1].split("&")[0])
            seen.append(page)
            return {"workflow_runs": pages.get(page, []), "total_count": 2}
        api.request = request
        self.assertEqual(api.failed_runs(2, START, pages=5), [(9, 1), (7, 2)])
        self.assertEqual(seen, [1, 2, 3, 1])

    def test_the_session_label_is_an_owned_pool(self):
        # feat-cmux-next's session role (glaeda#1530): run 39638669325's Mac job asked for it.
        label = "glaeda-session-std-xcode-26.6"
        self.assertEqual(rescue.job_pool({"labels": [label]}), label)
        self.assertEqual(rescue.job_pool({"labels": ["glaeda-fast-std-xcode-26.6"]}), "glaeda-fast-std-xcode-26.6")
        self.assertIsNone(rescue.job_pool({"labels": ["glaeda-session"]}))
        target = rescue.target_from_event(event(path=".github/workflows/cmux-next-base-autofix.yml", event="push",
                                                pull_requests=[], head_branch="feat-cmux-next"),
                                          "manaflow-ai/cmux")
        self.assertTrue(target.side)
        self.assertEqual(target.push_branch, "feat-cmux-next")

    def test_the_dev_freshness_slot_label_is_an_owned_pool(self):
        # cmux-next.yml's freshness slot (vars.CI_DEV_COMPILE_RUNNER): a feed compile queued there gets the
        # rescue's refusal and queue handling like a side or session job.
        label = "glaeda-dev-std-xcode-26.6"
        self.assertEqual(rescue.job_pool({"labels": [label]}), label)
        self.assertEqual(rescue.job_pool({"labels": ["glaeda-aws-dev-light-xcode-26"]}), "glaeda-aws-dev-light-xcode-26")
        for labels in (["glaeda-dev"], ["glaeda-dev-std"], ["glaeda-devx-std-xcode-26.6"]):
            self.assertIsNone(rescue.job_pool({"labels": labels}), labels)
        lost = unacquired_job(labels=(label,))
        self.assertTrue(rescue.unacquired(lost))
        # GitHub reports the runner of a job it cancelled unacquired as "" as well as null (run 40453240553).
        self.assertTrue(rescue.unacquired({**lost, "runner_name": ""}))

    def test_the_nightly_slot_label_is_an_owned_pool(self):
        # glaeda's nightly slot (one runner per mini that takes only nightly jobs): a nightly-next app build
        # queued there that no runner acquires is re-run like one on the side label.
        label = "glaeda-nightly-std-xcode-26.6"
        self.assertEqual(rescue.job_pool({"labels": [label]}), label)
        for labels in (["glaeda-nightly"], ["glaeda-nightly-std"], ["glaeda-nightlyx-std-xcode-26.6"]):
            self.assertIsNone(rescue.job_pool({"labels": labels}), labels)
        self.assertTrue(rescue.unacquired(unacquired_job(labels=(label,))))
        self.assertIsNone(rescue.started_dev_compile([job("build-nightly-app", status="in_progress", labels=[label])]),
                          "a nightly slot is not the freshness slot")

    def test_a_dev_compile_that_started_after_the_watch_read_is_never_cancelled(self):
        # The watch saw the compile queued on the freshness slot; it started before rescue() cancelled.
        label = "glaeda-dev-std-xcode-26.6"
        clock = Clock()
        started = job("cmux NEXT DEV Release compile", status="in_progress", labels=[label])
        started["runner_name"] = "mini-1-glaeda"
        api = FakeAPI(clock, lambda seconds: [started], marker=True)
        target = rescue.Target(RUN_ID, 1, HEAD, 0, side=True, path=rescue.CMUX_NEXT_WORKFLOW_PATH)
        result = rescue.rescue(api, target, now=clock.now, sleep=clock.sleep, log=lambda _: None)
        self.assertEqual(result, f"not rescued: a DEV feed compile started on {label}; "
                                 "a started dev build is never cancelled")
        self.assertNotIn("cancel", api.calls)
        self.assertNotIn("rerun", api.calls)
        # Still queued with no runner: the rescue goes ahead as before.
        clock = Clock()
        queued = job("cmux NEXT DEV Release compile", labels=[label])
        api = FakeAPI(clock, lambda seconds: [queued], marker=True)
        rescue.rescue(api, target, now=clock.now, sleep=clock.sleep, log=lambda _: None)
        self.assertIn("cancel", api.calls)
        self.assertIsNone(rescue.started_dev_compile([dict(started, labels=["glaeda-side-std-xcode-26.6"])]))
        self.assertIsNone(rescue.started_dev_compile([dict(started, status="completed")]))

    def test_a_finished_run_only_when_it_failed_since_the_last_sweeper(self):
        recent, old = stamp(-10 * 60), stamp(-rescue.SWEEP_FINISHED_SECONDS - 60)
        runs = [listed(1, status="completed", conclusion="success", updated_at=recent),
                listed(2, status="completed", conclusion="failure", updated_at=old),
                listed(3, status="completed", conclusion="failure", updated_at=recent),
                listed(4, status="in_progress")]
        # Only a recent failure can be a refusal nobody re-ran; a run in flight is watched as ever.
        self.assertEqual(self.sweep(SweepAPI(runs, picker=[1, 2, 3, 4]))[0], [(3, 1, False), (4, 1, False)])

    def test_a_resumed_full_re_run_waits_for_its_picker_and_late_placement(self):
        # An attempt's listing names every job with its run_attempt; one a re-run of failed jobs kept started
        # before the listing created it (rescue.carried()).
        full = [dict(job("changes", status="completed", created=100), run_attempt=2, started_at=stamp(101))]
        failed_only = [{"name": "changes", "status": "completed", "labels": [], "run_attempt": 2,
                        "started_at": stamp(5), "runner_name": ""}]
        api = SweepAPI([listed(1, run_attempt=2, run_started_at=stamp(50)),
                        listed(2, run_attempt=2, run_started_at=stamp(50))], picker=[1, 2],
                       attempt_jobs={1: full, 2: failed_only})
        self.assertEqual(self.sweep(api)[0], [(1, 2, True), (2, 2, False)])

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
        outcome = rescue.follow(api, target, seconds=90, queue_rounds="0",
                                now=clock.now, sleep=clock.sleep, log=lambda text: None)
        self.assertEqual(api.calls.count("rerun-failed"), 1)
        self.assertNotIn("cancel", api.calls)
        # The sweeper's listing, not this watch, follows the re-run.
        self.assertEqual(outcome, "done")

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
            return Response(b'{"run_attempt": 1, "status": "completed"}' if request.get_method() == "GET" else b"{}")
        return seen, unittest.mock.patch.object(rescue.urllib.request, "urlopen", urlopen)

    def test_reads_use_the_app_token_and_writes_keep_github_token(self):
        seen, patch = self.open_with()
        with patch:
            api = rescue.GitHub("repo-token", "o/r", read_token="app-token")
            api.run(1)
            api.rerun_failed(1, 2)
            api.cancel(1)
        # A re-run started by the App would not be github-actions[bot], which
        # ci-macos.yml's attempt-2 routing requires. It reads the run's attempt right before it is sent, and
        # after it the run, to see whether a UI test dispatch must follow (not for this one).
        self.assertEqual(seen, [("GET", "Bearer app-token"), ("GET", "Bearer app-token"), ("POST", "Bearer repo-token"),
                                ("GET", "Bearer app-token"), ("POST", "Bearer repo-token")])

    def test_a_re_run_of_pull_request_ci_starts_its_ui_test_dispatch(self):
        sent = []

        class Response(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        def urlopen(request, timeout):
            sent.append((request.get_method(), request.full_url, request.data))
            if request.get_method() == "GET":
                # A read right after the re-run may still report the old attempt.
                return Response(json.dumps({"path": ".github/workflows/ci.yml", "event": "pull_request",
                                            "run_attempt": 1, "status": "completed"}).encode())
            return Response(b"")
        with unittest.mock.patch.object(rescue.urllib.request, "urlopen", urlopen):
            rescue.GitHub("repo-token", "o/r").rerun(7, 2)
        # A GITHUB_TOKEN re-run may emit no workflow_run event for ci-ui-tests.yml.
        self.assertEqual(sent[-1][:2], ("POST", f"{rescue.API}/repos/o/r/actions/workflows/ci-ui-tests.yml/dispatches"))
        self.assertEqual(json.loads(sent[-1][2]), {"ref": "main", "inputs": {"run_id": "7", "run_attempt": "2"}})

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

    def refusing(self, refusals):
        """urlopen that refuses the first requests with `refusals` (code, headers, body), then answers {}."""
        seen = []

        class Response(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        def urlopen(request, timeout):
            seen.append((request.get_method(), request.full_url, request.headers["Authorization"]))
            if refusals:
                code, headers, body = refusals.pop(0)
                raise rescue.urllib.error.HTTPError(request.full_url, code, "refused", headers, io.BytesIO(body))
            return Response(b"{}")
        return seen, unittest.mock.patch.object(rescue.urllib.request, "urlopen", urlopen)

    def test_a_re_run_refused_for_the_rate_limit_waits_and_is_sent_again(self):
        # Run 40340830337: cancelled, then its re-run refused and never sent.
        limited = b'{"message": "API rate limit exceeded for installation."}'
        seen, patch = self.refusing([(403, {}, limited), (403, {}, limited), (429, {"Retry-After": "7"}, b"")])
        waits = []
        with patch:
            api = rescue.GitHub("repo-token", "o/r", read_token="app-token")
            api.sleep = waits.append
            api.request("POST", "/actions/runs/7/rerun-failed-jobs")
        self.assertEqual(waits, [60, 120, 7])
        self.assertEqual([entry[:2] for entry in seen], [("POST", f"{rescue.API}/repos/o/r/actions/runs/7/rerun-failed-jobs")] * 4)
        self.assertTrue(all(entry[2] == "Bearer repo-token" for entry in seen))

    def test_a_re_run_waiting_out_a_rate_limit_is_not_sent_once_someone_else_re_ran_the_run(self):
        # A cmux-next `completed` watch and the sweeper can own one failed attempt; the other's re-run
        # may start during this one's wait.
        limited = b'{"message": "API rate limit exceeded for installation."}'
        for moved, sent in (({"run_attempt": 3, "status": "queued"}, 1), ({"run_attempt": 2, "status": "completed"}, 2)):
            with self.subTest(moved=moved):
                seen, patch = self.refusing([(403, {}, limited)])
                reads = []

                def run(api, run_id):
                    reads.append(run_id)
                    return {"run_attempt": 2, "status": "completed"} if len(reads) == 1 else moved
                with patch, unittest.mock.patch.object(rescue.GitHub, "run", run):
                    api = rescue.GitHub("repo-token", "o/r")
                    api.sleep = lambda seconds: None
                    api.request_ui_tests = lambda run_id, attempt: None
                    if sent == 1:
                        with self.assertRaisesRegex(rescue.Aborted, "someone else already re-ran it"):
                            api.rerun_failed(7, 3)
                    else:
                        api.rerun_failed(7, 3)
                posts = [entry for entry in seen if entry[0] == "POST"]
                self.assertEqual(len(posts), sent)

    def test_a_re_run_is_not_sent_once_someone_else_re_ran_the_run_since_the_rescue_read_it(self):
        # A token mint (or a slow read) lets another watch re-run the run before this one's first send.
        seen, patch = self.refusing([])
        with patch, unittest.mock.patch.object(rescue.GitHub, "run",
                                               lambda api, run_id: {"run_attempt": 3, "status": "in_progress"}):
            api = rescue.GitHub("repo-token", "o/r")
            api.request_ui_tests = lambda run_id, attempt: None
            for rerun in (api.rerun_failed, api.rerun):
                with self.assertRaisesRegex(rescue.Aborted, "someone else already re-ran it"):
                    rerun(7, 2)
        self.assertEqual([entry for entry in seen if entry[0] == "POST"], [])

    def test_an_app_read_refused_with_429_goes_on_github_token(self):
        seen, patch = self.refusing([(429, {}, b"")])
        with patch:
            api = rescue.GitHub("repo-token", "o/r", read_token="app-token")
            api.sleep = lambda seconds: None
            api.run(1)
            api.run(1)
        self.assertEqual([entry[2] for entry in seen],
                         ["Bearer app-token", "Bearer repo-token", "Bearer app-token"])

    def test_the_sweeper_thread_never_waits(self):
        limited = b'{"message": "secondary rate limit"}'
        seen, patch = self.refusing([(403, {}, limited)])
        waits = []
        with patch:
            api = rescue.GitHub("repo-token", "o/r")
            api.sleep = waits.append
            api.no_rate_limit_waits()
            with self.assertRaises(rescue.urllib.error.HTTPError):
                api.cancel(7)
            other = []
            worker = rescue.threading.Thread(target=lambda: other.append(api.rate_limit_waited))
            worker.start()
            worker.join()
        self.assertEqual((len(seen), waits, other), (1, [], [0.0]))

    def test_every_limiter_message_counts(self):
        for said in ("You have exceeded a secondary rate limit", "You have triggered an abuse detection mechanism",
                     "Too many requests"):
            self.assertEqual(rescue.rate_limit_wait(403, {}, said, 0.0, 0), 60.0, said)
        self.assertIsNone(rescue.rate_limit_wait(403, {}, "Resource not accessible by integration", 0.0, 0))

    def test_a_spent_budget_waits_for_its_reset(self):
        reset = str(int(rescue.time.time()) + 100)
        seen, patch = self.refusing([(403, {"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": reset}, b"{}")])
        waits = []
        with patch:
            api = rescue.GitHub("repo-token", "o/r")
            api.sleep = waits.append
            api.cancel(7)
        self.assertEqual(len(seen), 2)
        self.assertTrue(100 <= waits[0] <= 106, waits)

    def test_a_permission_403_is_not_waited_for(self):
        seen, patch = self.refusing([(403, {}, b'{"message": "Resource not accessible by integration"}')])
        waits = []
        with patch:
            api = rescue.GitHub("repo-token", "o/r")
            api.sleep = waits.append
            with self.assertRaises(rescue.urllib.error.HTTPError):
                api.cancel(7)
        self.assertEqual((len(seen), waits), (1, []))

    def test_rate_limit_waits_are_bounded(self):
        limited = b'{"message": "secondary rate limit"}'
        seen, patch = self.refusing([(403, {}, limited)] * 50)
        waits = []
        with patch:
            api = rescue.GitHub("repo-token", "o/r")
            api.sleep = waits.append
            with self.assertRaises(rescue.urllib.error.HTTPError):
                api.cancel(7)
        self.assertEqual(sum(waits), rescue.RATE_LIMIT_WAIT_SECONDS)
        self.assertTrue(all(wait <= rescue.RATE_LIMIT_MAX_WAIT_SECONDS for wait in waits))

    def test_an_app_read_refused_for_the_rate_limit_falls_back_then_waits(self):
        limited = b'{"message": "API rate limit exceeded for installation."}'
        seen, patch = self.refusing([(403, {}, limited), (403, {}, limited)])
        waits = []
        with patch:
            api = rescue.GitHub("repo-token", "o/r", read_token="app-token")
            api.sleep = waits.append
            api.run(1)
        self.assertEqual([entry[2] for entry in seen], ["Bearer app-token", "Bearer repo-token", "Bearer repo-token"])
        self.assertEqual(waits, [60])

    def test_each_watch_thread_has_its_own_rate_limit_budget(self):
        limited = b'{"message": "secondary rate limit"}'
        seen, patch = self.refusing([(403, {}, limited)] * 50)
        with patch:
            api = rescue.GitHub("repo-token", "o/r")
            api.sleep = lambda seconds: None
            with self.assertRaises(rescue.urllib.error.HTTPError):
                api.cancel(7)
            self.assertEqual(api.rate_limit_waited, rescue.RATE_LIMIT_WAIT_SECONDS)
            other = []
            worker = rescue.threading.Thread(target=lambda: other.append(api.rate_limit_waited))
            worker.start()
            worker.join()
        self.assertEqual(other, [0.0])

    def test_a_nightly_give_up_is_an_error_annotation(self):
        nightly = rescue.Target(run_id=40340830337, attempt=1, head_sha=HEAD, pr_number=None, nightly=True)
        self.assertTrue(rescue.gave_up(nightly, RuntimeError("HTTP Error 403")).startswith(
            "::error title=nightly rescue::run 40340830337 gave up: HTTP Error 403"))
        other = rescue.Target(run_id=1, attempt=1, head_sha=HEAD, pr_number=7)
        self.assertEqual(rescue.gave_up(other, RuntimeError("x")), "gave up: x")

    def test_the_workflow_mints_a_read_only_token_and_passes_it(self):
        steps = yaml.safe_load((ROOT / ".github/workflows/ci-owned-pool-rescue.yml").read_text(
            encoding="utf-8"))["jobs"]["rescue"]["steps"]
        mint = next(step for step in steps if step.get("id") == "read-token")
        self.assertTrue(mint["continue-on-error"])
        self.assertEqual({key: value for key, value in mint["with"].items() if key.startswith("permission-")},
                         # The installation has no contents grant, and asking for one fails the mint
                         # (422). The one contents read (branch_head, /branches) gets a 403 and retries
                         # on GITHUB_TOKEN (Tokens.test_a_read_the_app_may_not_make...).
                         {"permission-actions": "read", "permission-pull-requests": "read"})
        watch = next(step for step in steps if step.get("name") == "Watch runs on persistent pools")
        self.assertEqual(
            watch["env"]["READ_TOKEN"],
            "${{ steps.cmux-bot-token.outputs.token || steps.read-token.outputs.token }}",
        )
        self.assertEqual(watch["env"]["GH_TOKEN"], "${{ steps.cmux-bot-token.outputs.token || github.token }}")


DEV_DAILY_TEXT = """
jobs:
  runner:
    runs-on: blacksmith-4vcpu-ubuntu-2404
    timeout-minutes: 5
  verify:
    name: Verify signed cmux NEXT DEV
    needs: runner
    runs-on: ${{ needs.runner.outputs.label }}
    timeout-minutes: 15
  tip-dmg-build:
    name: Build the unsigned cmux NEXT DEV tip DMG
    needs: runner
    runs-on: ${{ needs.runner.outputs.dmg_label }}
    timeout-minutes: 20
  dynamic:
    name: Dynamic limit
    runs-on: ${{ needs.runner.outputs.label }}
    timeout-minutes: ${{ fromJSON(vars.LIMIT) }}
"""


def cancelled_owned_job(name, *, lasted, labels=(LIGHT,), runner="cmux-mini-1-glaeda"):
    """An owned job concluded cancelled after `lasted` seconds on a runner (GitHub's timeout records this)."""
    found = job(name, status="completed", labels=labels, created=40, runner=runner)
    found.update(conclusion="cancelled", started_at=stamp(41), completed_at=stamp(41 + lasted), steps=[
        {"name": "Set up job", "status": "completed", "conclusion": "success"},
        {"name": "Set up runner", "status": "completed", "conclusion": "success"},
        {"name": "Checkout trusted verification scripts", "status": "completed", "conclusion": "cancelled"}])
    return found


SIGN_WORKFLOW = """
jobs:
  build-sign-notarize-nightly:
    runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || github.run_attempt > 1 && needs.pick-nightly-sign-runner.outputs.alternate || needs.pick-nightly-sign-runner.outputs.runner || 'blacksmith-6vcpu-macos-26' }}
  sign-nightly-identity-legacy:
    runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || github.run_attempt > 1 && needs.legacy-identity-target.outputs.sign_alternate || needs.legacy-identity-target.outputs.sign_runner || 'blacksmith-6vcpu-macos-26' }}
"""
# nightly-next's verify jobs (feat-cmux-next's nightly.yml): an owned Mac on attempt 1, the alternate after.
SIGN_VERIFY_WORKFLOW = """  verify-signed-nightly:
    runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || github.run_attempt == 1 && needs.pick-nightly-sign-runner.outputs.owned || github.run_attempt > 1 && needs.pick-nightly-sign-runner.outputs.alternate || needs.pick-nightly-sign-runner.outputs.runner || 'blacksmith-6vcpu-macos-26' }}
  verify-final-dmg-nightly:
    runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || github.run_attempt == 1 && needs.pick-nightly-sign-runner.outputs.owned || github.run_attempt > 1 && needs.pick-nightly-sign-runner.outputs.alternate || needs.pick-nightly-sign-runner.outputs.runner || 'blacksmith-6vcpu-macos-26' }}
"""
# main's nightly.yml (classic): the alternate is taken only by an attempt after the one that picked it.
CLASSIC_SIGN_WORKFLOW = """
jobs:
  build-sign-notarize-nightly:
    runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || github.run_attempt > 1 && needs.pick-classic-sign-runner.outputs.attempt != github.run_attempt && needs.pick-classic-sign-runner.outputs.alternate || needs.pick-classic-sign-runner.outputs.runner || 'blacksmith-6vcpu-macos-26' }}
  sign-nightly-identity-legacy:
    runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || github.run_attempt > 1 && needs.legacy-identity-target.outputs.sign_alternate || needs.legacy-identity-target.outputs.sign_runner || 'blacksmith-6vcpu-macos-26' }}
"""
# nightly-next's Linux signer path (#26171's successors): its Mac jobs image, verify and check the final DMG.
SIGNER_WORKFLOW = "jobs:\n" + "".join(
    f"  {name}:\n    runs-on: ${{{{ github.run_attempt == 1 && needs.pick-nightly-sign-runner.outputs.owned || "
    "github.run_attempt > 1 && needs.pick-nightly-sign-runner.outputs.alternate || "
    "needs.pick-nightly-sign-runner.outputs.runner || 'blacksmith-6vcpu-macos-26' }}\n"
    for name in ("signer-dmg-image", "signer-verify", "verify-final-dmg-nightly"))
# The same jobs before the alternate label (nightly.yml before #26171): a re-run takes the stalled label again.
SIGN_WORKFLOW_BEFORE = """
jobs:
  build-sign-notarize-nightly:
    runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || needs.pick-nightly-sign-runner.outputs.runner || 'blacksmith-6vcpu-macos-26' }}
  sign-nightly-identity-legacy:
    runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || needs.legacy-identity-target.outputs.sign_runner || 'blacksmith-6vcpu-macos-26' }}
"""


def signing_run(*, queued_at=60, sibling_done_at=0, started_at=None):
    """Run 40489472569's shape: everything before signing finished, then both signing jobs queued on Blacksmith.

    `sibling_done_at` keeps one other job running until then; `started_at` gives the arm64 signing job a runner."""
    def jobs(seconds):
        found = [dict(job("decide", status="completed", labels=["blacksmith-4vcpu-ubuntu-2404"]), id=1),
                 dict(job("build-nightly-app", status="completed", labels=[BLACKSMITH], runner="bs-1"), id=2,
                      conclusion="success"),
                 dict(job("build-nightly-ghostty-cli-helper", labels=["blacksmith-4vcpu-ubuntu-2404"], runner="bs-2",
                          status="completed" if seconds >= sibling_done_at else "in_progress"), id=3)]
        if seconds >= queued_at:
            started = started_at is not None and seconds >= started_at
            found.append(dict(job("build-sign-notarize-nightly (arm64)", labels=[BLACKSMITH], created=queued_at,
                                  status="in_progress" if started else "queued", runner="bs-3" if started else ""),
                              id=4))
            found.append(dict(job("sign-nightly-identity-legacy", labels=[BLACKSMITH], created=queued_at + 10),
                              id=5))
        return found
    return jobs


def mutations(api):
    return [call for call in api.calls
            if call in ("cancel", "force-cancel", "rerun", "rerun-failed") or call.startswith("rerun-job:")]


def cancel_times(api):
    """When each cancel was sent (FakeAPI forgets cancelled_at once the re-run starts)."""
    times, cancel = [], api.cancel

    def recorded(run_id, before_send=None):
        times.append(api.clock.seconds)
        cancel(run_id, before_send)
    api.cancel = recorded
    return times


class NightlySigningStall(unittest.TestCase):
    """A started delivery run stays intact while a signing job waits for capacity."""

    def test_stalled_signing_jobs_with_nothing_else_running_stay_for_capacity(self):
        clock = Clock()
        api = NightlyAPI(clock, signing_run(), workflow=SIGN_WORKFLOW)
        cancel_times(api)
        code, summary = run_main(api, clock, payload=nightly_event(head_branch="nightly-next"))
        self.assertEqual(code, 0)
        self.assertEqual(mutations(api), [])
        self.assertIn("past the 600s Blacksmith stall time, and every other job of the run has finished", summary)
        self.assertIn("started delivery work", summary)

    def test_another_job_in_progress_holds_the_rescue_until_it_finishes(self):
        clock = Clock()
        done_at = 60 + rescue.SIGN_STALL_SECONDS + 900
        api = NightlyAPI(clock, signing_run(sibling_done_at=done_at), workflow=SIGN_WORKFLOW)
        cancelled = cancel_times(api)
        _, summary = run_main(api, clock, payload=nightly_event(head_branch="nightly-next"))
        self.assertIn("but build-nightly-ghostty-cli-helper not finished; cancelling the run would lose that work",
                      summary)
        # The whole run is already started, so it remains intact even after
        # the other sibling finishes.
        self.assertEqual(mutations(api), [])

    def test_a_job_still_running_at_the_watch_limit_is_never_cancelled(self):
        clock = Clock()
        api = NightlyAPI(clock, signing_run(sibling_done_at=10 ** 9), workflow=SIGN_WORKFLOW)
        _, summary = run_main(api, clock, payload=nightly_event(head_branch="nightly-next"))
        self.assertIn("stopped: watch limit reached", summary)
        self.assertEqual(mutations(api), [])

    def test_a_signing_job_that_started_holds_the_other(self):
        # The arm64 job got a runner: it is running, so the legacy job's stall waits for it.
        clock = Clock()
        api = NightlyAPI(clock, signing_run(started_at=300), workflow=SIGN_WORKFLOW)
        _, summary = run_main(api, clock, payload=nightly_event(head_branch="nightly-next"))
        self.assertIn("but build-sign-notarize-nightly (arm64) not finished", summary)
        self.assertEqual(mutations(api), [])

    def test_no_rescue_without_the_alternate_label_on_a_re_run(self):
        for workflow in (SIGN_WORKFLOW_BEFORE, None):
            clock = Clock()
            api = NightlyAPI(clock, signing_run(), workflow=workflow)
            _, summary = run_main(api, clock, payload=nightly_event(head_branch="nightly-next"))
            self.assertIn("takes no alternate label on a re-run", summary)
            self.assertEqual(mutations(api), [])
            # The file is read once per watch, not every look.
            self.assertEqual(sum(call.startswith("workflow:") for call in api.calls), 1)

    def test_main_s_first_attempt_with_the_classic_alternate_is_rescued(self):
        # Main's nightly (classic) takes pick-classic-sign-runner's alternate on a re-run: its stall is moved too.
        clock = Clock()
        api = NightlyAPI(clock, signing_run(), workflow=CLASSIC_SIGN_WORKFLOW)
        _, summary = run_main(api, clock, payload=nightly_event())
        self.assertEqual(mutations(api), [], summary)
        # main having moved on does not make a run whose app is built moot; a newer run pending behind it does.
        clock = Clock()
        api = NightlyAPI(clock, signing_run(), workflow=CLASSIC_SIGN_WORKFLOW, pushes=[RUN_ID + 1])
        api.branch_head = lambda branch: "b" * 40
        run_main(api, clock, payload=nightly_event())
        self.assertEqual(mutations(api), [])
        clock = Clock()
        api = NightlyAPI(clock, signing_run(), workflow=CLASSIC_SIGN_WORKFLOW, newer=[RUN_ID + 1])
        run_main(api, clock, payload=nightly_event())
        self.assertNotIn("rerun-failed", mutations(api))
        # Without the alternate in its runs-on a re-run would queue on the same label: left alone.
        clock = Clock()
        api = NightlyAPI(clock, signing_run(), workflow=SIGN_WORKFLOW_BEFORE)
        _, summary = run_main(api, clock, payload=nightly_event())
        self.assertEqual(mutations(api), [])
        self.assertIn("takes no alternate label on a re-run", summary)

    def test_signer_verify_and_dmg_image_are_left_for_capacity(self):
        # A queued signer may appear only after the app build has completed.
        # The run is already started, so queue rescue must leave it alone.
        def jobs(seconds):
            found = [dict(job("decide", status="completed", labels=["blacksmith-4vcpu-ubuntu-2404"]), id=1),
                     dict(job("signer-dmg-image", status="completed", labels=[BLACKSMITH]), id=2,
                          conclusion="success")]
            if seconds >= 60:
                found += [dict(job("signer-verify", labels=[BLACKSMITH], created=60), id=3),
                          dict(job("Verify final nightly DMG (arm64)", labels=[BLACKSMITH], created=70), id=4)]
            return found
        clock = Clock()
        api = NightlyAPI(clock, jobs, workflow=SIGNER_WORKFLOW)
        _, summary = run_main(api, clock, payload=nightly_event(head_branch="nightly-next"))
        self.assertEqual(mutations(api), [], summary)
        self.assertIn("started delivery work", summary)
        self.assertEqual(rescue.sign_job_key({"name": "signer-dmg-image"}), "signer-dmg-image")
        # Attempt 2 is already on the alternate label: it is never cancelled again for a stall.
        target = rescue.target_from_event(nightly_event(head_branch="nightly-next"), "manaflow-ai/cmux")
        target = dataclasses.replace(target, attempt=2)
        clock = Clock()
        api = NightlyAPI(clock, signing_run(), workflow=SIGN_WORKFLOW, rerun_jobs=signing_run())
        api.attempt = 2
        outcome, _ = rescue.watch(api, target, budget_seconds=600, now=clock.now, sleep=clock.sleep,
                                  log=lambda text: None, deadline=clock.now() + dt.timedelta(hours=1))
        self.assertNotEqual(outcome, "stalled")
        self.assertEqual(mutations(api), [])

    def test_legacy_blacksmith_fallback_is_left_for_capacity(self):
        # The app build has already run; a stalled legacy signer is still part
        # of this started delivery run and is left for capacity.
        fallback = "sign-nightly-identity-legacy-blacksmith"
        fallback_workflow = f"""  {fallback}:
    runs-on: ${{{{ github.run_attempt > 1 && needs.legacy-identity-target.outputs.sign_alternate || 'blacksmith-6vcpu-macos-26' }}}}
"""

        def jobs(seconds):
            return [dict(job("sign-nightly-identity-legacy", status="completed", labels=[LIGHT], runner="mini"),
                         id=1, conclusion="failure"),
                    dict(job(fallback, labels=[BLACKSMITH], created=0), id=2)]

        for has_alternate in (True, False):
            with self.subTest(has_alternate=has_alternate):
                current = SIGN_WORKFLOW + (fallback_workflow if has_alternate else fallback_workflow.replace(
                    "github.run_attempt > 1 && needs.legacy-identity-target.outputs.sign_alternate || ", "")
                )
                clock = Clock()
                clock.seconds = rescue.SIGN_STALL_SECONDS + 30
                api = NightlyAPI(clock, jobs, workflow=current)
                target = rescue.target_from_event(nightly_event(head_branch="nightly-next"), "manaflow-ai/cmux")
                summary = rescue.rescue_stalled_signing(
                    api, target, now=clock.now, sleep=clock.sleep, log=lambda text: None,
                    deadline=clock.now() + dt.timedelta(hours=1), sign_seen={2: START}, workflow_text=current)
                self.assertEqual(mutations(api), [], summary)
                self.assertIn("started delivery work", summary)

    def test_the_look_before_the_cancel_sees_a_job_that_started(self):
        clock = Clock()
        api = NightlyAPI(clock, signing_run(started_at=0), workflow=SIGN_WORKFLOW)
        target = rescue.target_from_event(nightly_event(head_branch="nightly-next"), "manaflow-ai/cmux")
        clock.seconds = 60 + rescue.SIGN_STALL_SECONDS + 30
        result = rescue.rescue_stalled_signing(api, target, now=clock.now, sleep=clock.sleep, log=lambda text: None,
                                               deadline=clock.now() + dt.timedelta(hours=1))
        self.assertTrue(result.startswith(rescue.SIGN_NOT_YET), result)
        self.assertEqual(mutations(api), [])
        # Nor does a job whose runs-on has no alternate, though the watch's look had passed the gate.
        api = NightlyAPI(clock, signing_run(), workflow=SIGN_WORKFLOW)
        result = rescue.rescue_stalled_signing(api, target, now=clock.now, sleep=clock.sleep, log=lambda text: None,
                                               deadline=clock.now() + dt.timedelta(hours=1),
                                               sign_seen={4: START, 5: START}, workflow_text=SIGN_WORKFLOW_BEFORE)
        self.assertIn("started delivery work", result)
        self.assertEqual(mutations(api), [])
        # A job first seen queued late counts from then, not from its created_at.
        result = rescue.rescue_stalled_signing(api, target, now=clock.now, sleep=clock.sleep, log=lambda text: None,
                                               deadline=clock.now() + dt.timedelta(hours=1),
                                               sign_seen={4: clock.now(), 5: clock.now()}, workflow_text=SIGN_WORKFLOW)
        self.assertTrue(result.startswith(rescue.SIGN_NOT_YET), result)
        self.assertEqual(mutations(api), [])

    def test_a_job_that_starts_after_the_last_look_is_seen_before_the_cancel(self):
        # rescue() reads the run (which can wait out a rate limit) between the last look and the cancel: the
        # arm64 signing job gets a runner then, so the look right before the cancel leaves the run alone.
        clock = Clock()
        state = {"started": False}
        stalled, started = signing_run(), signing_run(started_at=0)
        api = NightlyAPI(clock, lambda seconds: started(seconds) if state["started"] else stalled(seconds),
                         workflow=SIGN_WORKFLOW)
        read_run = api.run

        def run(run_id):
            if "jobs" in api.calls and any("workflow:" in call for call in api.calls):
                state["started"] = True
            return read_run(run_id)
        api.run = run
        _, summary = run_main(api, clock, payload=nightly_event(head_branch="nightly-next"))
        self.assertIn("not rescued yet: ", summary)
        self.assertIn("build-sign-notarize-nightly (arm64) not finished", summary)
        self.assertEqual(mutations(api), [])

    def test_the_guard_runs_after_a_token_mint_and_before_every_send_of_the_cancel(self):
        api = rescue.GitHub("token", "manaflow-ai/cmux")
        order: list[str] = []
        api._fresh_token = lambda stale=None: order.append("mint")
        lock = api._lock

        class Recorded:
            # The shared lock another thread may hold through a slow mint: the guard runs after it is released.
            def __enter__(self):
                order.append("lock")
                return lock.__enter__()

            def __exit__(self, *exc):
                order.append("unlock")
                return lock.__exit__(*exc)
        api._lock = Recorded()

        def opened(request, timeout):
            order.append(f"send:{request.get_method()}")
            raise urllib.error.HTTPError(request.full_url, 403, "rate limited", {}, None)
        waits = iter([True, False])
        api._wait_for_rate_limit = lambda method, path, error: next(waits)
        with unittest.mock.patch("urllib.request.urlopen", opened):
            with self.assertRaises(urllib.error.HTTPError):
                api.cancel(RUN_ID, before_send=lambda: order.append("guard"))
        # Mint, lock, guard, send; after the rate-limit wait the same again.
        attempt = ["mint", "lock", "unlock", "guard", "send:POST"]
        self.assertEqual([step for step in order if step in attempt][:5], attempt)
        self.assertEqual(order.count("guard"), 2)
        for at, step in enumerate(order):
            if step == "send:POST":
                self.assertEqual(order[at - 1], "guard")
        # A guard that raises drops the request before it is sent.
        order.clear()

        def stop():
            raise rescue.SignStallChanged("a signing job started")
        with unittest.mock.patch("urllib.request.urlopen", opened):
            with self.assertRaises(rescue.SignStallChanged):
                api.cancel(RUN_ID, before_send=stop)
        self.assertNotIn("send:POST", order)

    def test_a_finished_signing_job_the_re_run_repeats_is_gated_too(self):
        # The legacy signer already failed: the re-run of failed jobs repeats it, so its runs-on must have the
        # alternate as well, or nothing is rescued.
        now = START + dt.timedelta(seconds=60 + rescue.SIGN_STALL_SECONDS)
        stalled = dict(job("build-sign-notarize-nightly (arm64)", labels=[BLACKSMITH], created=60), id=4)
        failed = dict(job("sign-nightly-identity-legacy", status="completed", labels=[BLACKSMITH], runner="bs"),
                      id=5, conclusion="failure")
        only_arm64 = SIGN_WORKFLOW.split("  sign-nightly-identity-legacy:")[0]
        self.assertEqual(rescue.gated_signing_stall([stalled, failed], now, {}, SIGN_WORKFLOW).action, "stalled")
        look = rescue.gated_signing_stall([stalled, failed], now, {}, only_arm64)
        self.assertEqual(look.action, "watch")
        self.assertIn("sign-nightly-identity-legacy", look.reason)

    def test_the_guard_never_cancels_an_attempt_someone_else_started(self):
        clock = Clock()
        clock.seconds = 60 + rescue.SIGN_STALL_SECONDS + 30
        api = NightlyAPI(clock, signing_run(), workflow=SIGN_WORKFLOW)
        target = rescue.target_from_event(nightly_event(head_branch="nightly-next"), "manaflow-ai/cmux")
        reads = {"count": 0}
        read_run = api.run

        def run(run_id):
            # The first look's and rescue()'s own reads see attempt 1; by the read right before the cancel,
            # another watcher has started attempt 2.
            reads["count"] += 1
            found = dict(read_run(run_id))
            if reads["count"] > 2:
                found.update(run_attempt=2, status="in_progress")
            return found
        api.run = run
        result = rescue.rescue_stalled_signing(api, target, now=clock.now, sleep=clock.sleep, log=lambda text: None,
                                               deadline=clock.now() + dt.timedelta(hours=1),
                                               sign_seen={4: START, 5: START}, workflow_text=SIGN_WORKFLOW)
        self.assertTrue(result.startswith(rescue.SIGN_NOT_YET), result)
        self.assertIn("started delivery work", result)
        self.assertEqual(reads["count"], 1)
        self.assertEqual(mutations(api), [])

    def test_a_stall_found_while_held_keeps_its_first_seen_times(self):
        # follow() hands its signing state to hold_for_destination(), whose watch() can be the one that finds
        # the stall; the guard then judges with the same times, so the stall is rescued, not restarted.
        clock = Clock()
        api = NightlyAPI(clock, signing_run(), workflow=SIGN_WORKFLOW)
        calls = []

        def hold(client, target, outcome, reason, **kwargs):
            calls.append(kwargs)
            outcome, reason = rescue.watch(client, target, budget_seconds=kwargs["budget_seconds"],
                                           now=kwargs["now"], sleep=kwargs["sleep"], log=kwargs["log"],
                                           deadline=kwargs["deadline"], seen=kwargs["seen"],
                                           sign_seen=kwargs["sign_seen"], sign_text=kwargs["sign_text"])
            return outcome, reason, ""
        real_watch = rescue.watch
        first = {"done": False}

        def watch(*args, **kwargs):
            if not first["done"]:
                first["done"] = True
                return "rescue", "an owned job is stuck"
            return real_watch(*args, **kwargs)
        with unittest.mock.patch.object(rescue, "watch", watch), \
                unittest.mock.patch.object(rescue, "hold_for_destination", hold):
            _, summary = run_main(api, clock, payload=nightly_event(head_branch="nightly-next"))
        self.assertTrue(calls[0]["sign_seen"])
        self.assertTrue(calls[0]["sign_text"])
        self.assertEqual(mutations(api), [])

    def test_every_retry_inside_request_keeps_the_guard(self):
        import inspect
        import re as re_module
        source = inspect.getsource(rescue.GitHub.request)
        retries = re_module.findall(r"return self\.request\(method, path,.*?refreshed=[^,)]+[^\n]*", source, re_module.S)
        self.assertGreaterEqual(len(retries), 4)
        for call in retries:
            self.assertIn("before_send=before_send", call)

    def test_a_signing_job_first_seen_at_the_last_look_is_not_stalled_yet(self):
        clock = Clock()
        clock.seconds = 60 + rescue.SIGN_STALL_SECONDS + 30
        api = NightlyAPI(clock, signing_run(), workflow=SIGN_WORKFLOW)
        target = rescue.target_from_event(nightly_event(head_branch="nightly-next"), "manaflow-ai/cmux")
        seen = {4: START}  # the watch saw the arm64 job, never the legacy one
        result = rescue.rescue_stalled_signing(api, target, now=clock.now, sleep=clock.sleep, log=lambda text: None,
                                               deadline=clock.now() + dt.timedelta(hours=1), sign_seen=seen,
                                               workflow_text=SIGN_WORKFLOW)
        self.assertTrue(result.startswith(rescue.SIGN_NOT_YET), result)
        self.assertIn("started delivery work", result)
        self.assertNotIn(5, seen)
        self.assertEqual(mutations(api), [])

    def test_a_change_at_the_last_look_resumes_the_watch(self):
        # The final look finds a sibling running again; the watch goes on and rescues once it finishes.
        clock = Clock()
        api = NightlyAPI(clock, signing_run(), workflow=SIGN_WORKFLOW)
        real = rescue.rescue_stalled_signing
        answers = []

        def once(*args, **kwargs):
            if not answers:
                answers.append(rescue.SIGN_NOT_YET + "a sibling came back")
                return answers[0]
            return real(*args, **kwargs)
        with unittest.mock.patch.object(rescue, "rescue_stalled_signing", once):
            _, summary = run_main(api, clock, payload=nightly_event(head_branch="nightly-next"))
        self.assertIn("not rescued yet: a sibling came back", summary)
        self.assertEqual(mutations(api), [])

    def test_a_started_nightly_at_the_signing_cancel_resumes_the_watch(self):
        # The cancel guard found a nightly job running (NightlyBusy): the watch goes on and rescues later.
        clock = Clock()
        api = NightlyAPI(clock, signing_run(), workflow=SIGN_WORKFLOW)
        real = rescue.rescue_stalled_signing
        answers = []

        def once(*args, **kwargs):
            if not answers:
                answers.append(rescue.NIGHTLY_BUSY + " (publish-nightly)")
                return answers[0]
            return real(*args, **kwargs)
        with unittest.mock.patch.object(rescue, "rescue_stalled_signing", once):
            _, summary = run_main(api, clock, payload=nightly_event(head_branch="nightly-next"))
        self.assertIn(rescue.NIGHTLY_BUSY, summary)
        self.assertEqual(mutations(api), [])
        self.assertIn("started delivery work", summary)

    def test_a_busy_rescue_resumes_into_the_signing_stall_rescue(self):
        # An ordinary rescue found a started nightly at its cancel; the resumed watch then finds the signing jobs
        # stalled, with the same first-seen times, and the signing rescue moves them.
        clock = Clock()
        api = NightlyAPI(clock, signing_run(), workflow=SIGN_WORKFLOW)
        real_watch, real_rescue = rescue.watch, rescue.rescue
        state = {"watched": False, "busy": False}

        def watch(*args, **kwargs):
            if not state["watched"]:
                state["watched"] = True
                return "refused", "a job was refused"
            return real_watch(*args, **kwargs)

        def rescue_once(*args, **kwargs):
            if not state["busy"]:
                state["busy"] = True
                return rescue.NIGHTLY_BUSY + " (publish-nightly)"
            return real_rescue(*args, **kwargs)
        with unittest.mock.patch.object(rescue, "watch", watch), \
                unittest.mock.patch.object(rescue, "rescue", rescue_once):
            _, summary = run_main(api, clock, payload=nightly_event(head_branch="nightly-next"))
        self.assertEqual(mutations(api), [])
        self.assertIn("started delivery work", summary)

    def later_attempt(self, attempt, jobs, *, after=None):
        """Attempt `attempt` of a nightly-next push run (a re-run the sweeper adopted), its jobs `jobs`; after a
        re-run, attempt + 1's jobs are `after`."""
        clock = Clock()
        api = NightlyAPI(clock, lambda seconds: [], workflow=SIGN_WORKFLOW + SIGN_VERIFY_WORKFLOW,
                         rerun_jobs=lambda seconds: jobs(seconds) if api.attempt == attempt else (after or jobs)(seconds))
        api.attempt = attempt
        target = rescue.sweep_target(dict(nightly_event(head_branch="nightly-next")["workflow_run"],
                                          run_attempt=attempt, status="in_progress"), "manaflow-ai/cmux", late=False)
        self.assertIsInstance(target, rescue.Target)
        return clock, api, target

    def test_a_later_attempt_s_stalled_sign_and_verify_jobs_get_a_full_re_run(self):
        # Run 40500413442: attempt 2's legacy sign queued on blacksmith-12vcpu-macos-26 from 13:01Z and its two verify
        # jobs from 15:15Z, everything else finished. A re-run of failed jobs would read attempt 2's own pick again.
        stalled = "blacksmith-12vcpu-macos-26"

        def attempt_2(seconds):
            done = [dict(job("decide", status="completed", labels=["blacksmith-4vcpu-ubuntu-2404"]), id=1,
                         conclusion="success"),
                    dict(job("build-nightly-app", status="completed", labels=[BLACKSMITH], runner="bs-1"), id=2,
                         conclusion="success"),
                    dict(job("build-sign-notarize-nightly (arm64)", status="completed", labels=[stalled], runner="bs-2"),
                         id=3, conclusion="success")]
            return done + [dict(job("sign-nightly-identity-legacy", labels=[stalled], created=60), id=4),
                           dict(job("Verify signed nightly app (arm64)", labels=[stalled], created=90), id=5),
                           dict(job("Verify final nightly DMG (arm64)", labels=[stalled], created=90), id=6)]

        def attempt_3(seconds):
            # The pickers ran again: the signing and verify jobs take a label that is running (or an owned Mac).
            return [dict(job("pick-nightly-sign-runner", status="completed", labels=["ubuntu-24.04"]), id=11,
                         conclusion="success"),
                    dict(job("sign-nightly-identity-legacy", status="in_progress", labels=[BLACKSMITH], runner="bs-9"),
                         id=12),
                    dict(job("Verify signed nightly app (arm64)", status="in_progress", labels=[LIGHT],
                             runner="mini-1"), id=13)]
        for attempt in (2, 3):
            clock, api, target = self.later_attempt(attempt, attempt_2, after=attempt_3)
            lines = []
            result = rescue.follow(api, target, seconds=30, queue_rounds="0", now=clock.now, sleep=clock.sleep,
                                   log=lines.append)
            self.assertEqual(result, "done", lines)
            # A full re-run (the pickers choose again), never a re-run of failed jobs onto the stalled label.
            self.assertEqual(mutations(api), [], attempt)
            self.assertEqual(api.attempt, attempt)
            self.assertIn("started delivery work", "\n".join(lines))
            # The next attempt's sign and verify jobs run where the pickers put them: nothing more to rescue there.
            next_target = dataclasses.replace(target, attempt=attempt + 1)
            api.calls.clear()
            api.finished = lambda seconds: False
            rescue.follow(api, next_target, seconds=30, queue_rounds="0", now=clock.now,
                          sleep=clock.sleep, log=lines.append)
            self.assertEqual(mutations(api), [], attempt)

    def test_a_later_attempt_with_an_accepted_owned_job_still_watches_its_signing(self):
        # A re-run the sweeper adopted (no marker, so not a full re-run) whose app build an owned Mac took: the watch
        # must not stop at "the fleet accepted the retry" before its sign and verify jobs have stalled long enough.
        stalled = "blacksmith-12vcpu-macos-26"

        def attempt_n(seconds):
            done = [dict(job("decide", status="completed", labels=["blacksmith-4vcpu-ubuntu-2404"]), id=1,
                         conclusion="success"),
                    dict(job("build-nightly-app", status="completed", labels=[LIGHT], runner="mini-2"), id=2,
                         conclusion="success")]
            return done + [dict(job("sign-nightly-identity-legacy", labels=[stalled], created=60), id=4),
                           dict(job("Verify signed nightly app (arm64)", labels=[stalled], created=90), id=5)]

        def after(seconds):
            return [dict(job("sign-nightly-identity-legacy", status="in_progress", labels=[LIGHT], runner="mini-1"),
                         id=12)]
        for attempt in (2, 3):
            clock, api, target = self.later_attempt(attempt, attempt_n, after=after)
            self.assertFalse(target.full_rerun)
            lines = []
            result = rescue.follow(api, target, seconds=30, queue_rounds="0", now=clock.now, sleep=clock.sleep,
                                   log=lines.append)
            self.assertEqual(result, "done", lines)
            self.assertFalse(any("the fleet accepted the retry" in line for line in lines), lines)
            self.assertEqual(mutations(api), [], (attempt, lines))
            self.assertEqual(api.attempt, attempt)
            self.assertIn("started delivery work", "\n".join(lines))

    def test_the_sweeper_adopts_a_nightly_next_re_run_on_blacksmith(self):
        # Run 40500413442's attempt 2 left no marker (its build picker chose Blacksmith): the sweeper lists it.
        run = dict(nightly_event(head_branch="nightly-next")["workflow_run"], id=7, run_attempt=2,
                   status="in_progress")

        class API(SweepAPI):
            listed = 0

            def nightly_reruns(self, count):
                API.listed += 1
                return [(7, 2)]
        api = API([run])
        watched, _ = Sweeper.sweep(Sweeper(), api, ticks=rescue.SIDE_FAILURE_TICKS + 1)
        self.assertEqual(watched, [(7, 2, False)])
        self.assertEqual(API.listed, 2)  # every SIDE_FAILURE_TICKS ticks
        # The listing reads nightly-next's unfinished runs and keeps every attempt from 2 on: attempt 4 and
        # later are the picker's repeated owned picks while Blacksmith stalls (review P1 on #26614), and only
        # watch() stops the signing-stall rescue at SIGN_RESCUE_LAST_ATTEMPT.
        github = rescue.GitHub("t", "manaflow-ai/cmux")
        asked = []

        def request(method, path, **_):
            asked.append(path)
            return {"workflow_runs": [dict(run, run_attempt=attempt, id=attempt) for attempt in (1, 2, 3, 4, 7)]
                    + [dict(run, id=9, head_branch="main")]}
        github.request = request
        self.assertEqual(github.nightly_reruns(5), [(2, 2), (3, 3), (4, 4), (7, 7)] * 2)
        # And the sweeper watches such a later attempt (owned_rerun(): any nightly-next attempt).
        later = rescue.sweep_target(dict(run, run_attempt=5), "manaflow-ai/cmux", late=False)
        self.assertIsInstance(later, rescue.Target)
        self.assertEqual(later.attempt, 5)
        self.assertTrue(all("branch=nightly-next" in path and "nightly.yml" in path for path in asked))

    def test_a_later_attempt_never_cancels_started_work_and_stops_at_the_last_attempt(self):
        # The arm64 sign/notarize job still runs on attempt 2: the stalled legacy sign waits for it.
        clock, api, target = self.later_attempt(2, signing_run(started_at=300))
        rescue.follow(api, target, seconds=30, queue_rounds="0", now=clock.now, sleep=clock.sleep,
                      log=lambda _: None)
        self.assertEqual(mutations(api), [])
        # Past SIGN_RESCUE_LAST_ATTEMPT a full re-run would build the app once more: left to the nightly helper.
        last = rescue.SIGN_RESCUE_LAST_ATTEMPT + 1
        clock, api, target = self.later_attempt(last, signing_run())
        rescue.follow(api, target, seconds=30, queue_rounds="0", now=clock.now, sleep=clock.sleep,
                      log=lambda _: None)
        self.assertEqual(mutations(api), [])
        self.assertTrue(rescue.signing_rerun_full(2))
        self.assertFalse(rescue.signing_rerun_full(1))

    def test_signing_stall_rules(self):
        now = START + dt.timedelta(seconds=60 + rescue.SIGN_STALL_SECONDS)
        queued = dict(job("sign-nightly-identity-legacy", labels=[BLACKSMITH], created=60), id=9)
        self.assertEqual(rescue.signing_stall([queued], now).action, "stalled")
        self.assertIsNone(rescue.signing_stall([queued], now - dt.timedelta(seconds=1)))
        # An owned label is the owned-pool rescue's, and a job that is not a signing job is not this rule's.
        self.assertIsNone(rescue.signing_stall([dict(queued, labels=[MINI])], now))
        self.assertIsNone(rescue.signing_stall([dict(queued, name="build-nightly-app")], now))
        self.assertIsNone(rescue.signing_stall([dict(queued, runner_name="bs-1")], now))
        # Any Blacksmith macOS size and image suffix (the module has a narrower BLACKSMITH_MACOS_LABEL too).
        for label in ("blacksmith-12vcpu-macos-26", "blacksmith-6vcpu-macos-26-arm64"):
            self.assertEqual(rescue.signing_stall([dict(queued, labels=[label])], now).action, "stalled", label)
        # A verify leg's rendered matrix name maps to its job.
        self.assertEqual(rescue.sign_job_key({"name": "Verify signed nightly app (arm64)"}), "verify-signed-nightly")
        self.assertEqual(rescue.sign_stall_gate(SIGN_WORKFLOW, ["build-sign-notarize-nightly"]), [])
        self.assertEqual(rescue.sign_stall_gate(SIGN_WORKFLOW, ["verify-signed-nightly"]), ["verify-signed-nightly"])
        self.assertEqual(rescue.sign_stall_gate("jobs: [", ["build-sign-notarize-nightly"]),
                         ["build-sign-notarize-nightly"])


# Run 40989498281 (00c873b5, 2026-10-30): build-nightly-app's Release compile failed on #27223's swiftc error.
COMPILE_STEPS = [{"name": "Set up job", "conclusion": "success"}, {"name": "Select Xcode", "conclusion": "success"},
                 {"name": "Build nightly app (Release)", "conclusion": "failure"},
                 {"name": "Upload unsigned nightly app", "conclusion": "skipped"}]
COMPILE_ANNOTATIONS = [
    {"path": ".github", "start_line": 39700, "annotation_level": "failure",
     "message": "Process completed with exit code 65."},
    {"path": "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Remote/JoinConsent+App.swift", "start_line": 222,
     "annotation_level": "failure", "message": "'async' call in a function that does not support concurrency"},
    {"path": ".github", "start_line": 39502, "annotation_level": "failure",
     "message": "xcodebuild failed with status=65; build errors and resource diagnostics follow"},
]


def failed_build(steps=COMPILE_STEPS, conclusion="failure", job_id=2):
    return dict(job("build-nightly-app", status="completed", labels=[MINI], runner="cmux13s-mac-mini-glaeda-2"),
                id=job_id, conclusion=conclusion, steps=[dict(step) for step in steps])


def broken_signing_run(build):
    """signing_run()'s stalled legacy signer, behind an app build that failed (attempt 1 of run 40989498281)."""
    stalled = signing_run()

    def jobs(seconds):
        return [build if found.get("name") == "build-nightly-app" else found for found in stalled(seconds)
                if found.get("name") != "build-sign-notarize-nightly (arm64)"]
    return jobs


class CompileRedAPI(NightlyAPI):
    """NightlyAPI whose jobs carry annotations (job id -> list), and whose earlier attempts can be listed."""

    def __init__(self, *args, notes=None, attempts=None, **kwargs):
        super().__init__(*args, **kwargs)
        self.notes, self.attempts = notes or {}, attempts or {}

    def jobs(self, run_id, attempt):
        if attempt in self.attempts:
            self.calls.append(f"jobs:{attempt}")
            return self.attempts[attempt]
        return super().jobs(run_id, attempt)

    def annotations(self, job_id):
        self.calls.append(f"annotations:{job_id}")
        return self.notes.get(job_id, [])


class NightlyCompileRed(unittest.TestCase):
    """A nightly whose build failed on a swiftc error is never cancelled or re-run: the same commit fails the same
    way. On 2026-10-30 the signing-stall rescue re-ran run 40989498281 (00c873b5) to attempt 4, rebuilding the
    commit #27223 broke each time, while the feed fell 85 minutes behind."""

    def test_the_incident_s_build_is_a_compile_error(self):
        why = rescue.compile_error(failed_build(), COMPILE_ANNOTATIONS)
        self.assertIn("build-nightly-app failed to compile: Packages/macOS/CmuxNext/Sources/CmuxNextApp/Remote/"
                      "JoinConsent+App.swift:222: 'async' call in a function that does not support concurrency", why)

    def test_only_a_swiftc_error_with_exit_65_counts(self):
        signal = [dict(COMPILE_ANNOTATIONS[0], message="Process completed with exit code 137."), COMPILE_ANNOTATIONS[1]]
        warning = [COMPILE_ANNOTATIONS[0], dict(COMPILE_ANNOTATIONS[1], annotation_level="warning")]
        no_line = [COMPILE_ANNOTATIONS[0], dict(COMPILE_ANNOTATIONS[1], start_line=0)]
        not_swift = [COMPILE_ANNOTATIONS[0], dict(COMPILE_ANNOTATIONS[1], path="scripts/ci/build.sh")]
        setup = [{"name": "Set up runner", "conclusion": "failure"}, *COMPILE_STEPS[2:]]
        cases = {
            "a signal (exit 137)": (failed_build(), signal),
            "no swiftc diagnostic": (failed_build(), [COMPILE_ANNOTATIONS[0], COMPILE_ANNOTATIONS[2]]),
            "a Swift warning only": (failed_build(), warning),
            "no source line": (failed_build(), no_line),
            "not a Swift source": (failed_build(), not_swift),
            "no annotations read": (failed_build(), []),
            "a refusal at setup": (failed_build(steps=setup), COMPILE_ANNOTATIONS),
            "a later step failed first": (failed_build(steps=[{"name": "Fetch the Chromium engine",
                                                               "conclusion": "failure"}, *COMPILE_STEPS[2:]]),
                                          COMPILE_ANNOTATIONS),
            "a lost runner (no steps)": (failed_build(steps=[]), COMPILE_ANNOTATIONS),
            "a timeout": (failed_build(conclusion="timed_out"), COMPILE_ANNOTATIONS),
            "cancelled": (failed_build(conclusion="cancelled"), COMPILE_ANNOTATIONS),
            "still running": (dict(failed_build(), status="in_progress", conclusion=None), COMPILE_ANNOTATIONS),
        }
        for case, (build, notes) in cases.items():
            with self.subTest(case):
                self.assertEqual(rescue.compile_error(build, notes), "")

    def test_the_signing_stall_behind_a_compile_error_is_left_alone(self):
        clock = Clock()
        api = CompileRedAPI(clock, broken_signing_run(failed_build()), workflow=SIGN_WORKFLOW,
                            notes={2: COMPILE_ANNOTATIONS})
        code, summary = run_main(api, clock, payload=nightly_event(head_branch="nightly-next"))
        self.assertEqual(code, 0)
        self.assertEqual(mutations(api), [], summary)
        self.assertFalse(any(call.startswith("rerun-job") for call in api.calls), api.calls)
        self.assertIn(rescue.COMPILE_RED, summary)
        self.assertIn("JoinConsent+App.swift:222", summary)

    def test_the_same_stall_behind_a_build_that_failed_otherwise_is_left_for_capacity(self):
        # A non-timeout build failure is not a queue-rescue exception.  The
        # started delivery run remains intact for a human or its normal
        # failure handling, whatever signing fallback exists.
        for notes in ([dict(COMPILE_ANNOTATIONS[0], message="Process completed with exit code 137.")],
                      [COMPILE_ANNOTATIONS[0], COMPILE_ANNOTATIONS[2]]):
            with self.subTest(notes=notes):
                clock = Clock()
                api = CompileRedAPI(clock, broken_signing_run(failed_build()), workflow=SIGN_WORKFLOW,
                                    notes={2: notes})
                _, summary = run_main(api, clock, payload=nightly_event(head_branch="nightly-next"))
                self.assertEqual(mutations(api), [], summary)
                self.assertIn("started delivery work", summary)

    def test_a_compile_red_nightly_whose_head_moved_is_not_cancelled_either(self):
        # rescue() cancels an unfinished nightly whose branch moved on (or that a newer run replaces); a compile-red
        # one is left alone before that branch.
        for overrides in ({"head": "b" * 40}, {"newer": [RUN_ID + 1]}):
            with self.subTest(overrides=list(overrides)):
                clock = Clock()
                api = CompileRedAPI(clock, broken_signing_run(failed_build()), notes={2: COMPILE_ANNOTATIONS},
                                    **overrides)
                result = rescue.rescue(api, self.target(), now=clock.now, sleep=clock.sleep, log=lambda text: None,
                                       failed_only=True)
                self.assertTrue(result.startswith(rescue.COMPILE_RED), result)
                self.assertEqual(mutations(api), [])
                self.assertFalse(any(call.startswith(("newer:", "branch:")) for call in api.calls), api.calls)

    def target(self, attempt=1, **overrides):
        return rescue.Target(RUN_ID, attempt, HEAD, 0, side=True, path=rescue.NIGHTLY_WORKFLOW_PATH, nightly=True,
                             push_branch="nightly-next", **overrides)

    def test_an_attempt_that_never_ran_the_build_reads_the_one_before(self):
        # Attempts 3 and 4 of run 40989498281 skipped build-nightly-app; attempt 2's had failed to compile.
        skipped = dict(job("build-nightly-app", status="completed"), id=9, conclusion="skipped")
        clock = Clock()
        api = CompileRedAPI(clock, lambda seconds: [], attempts={4: [skipped], 3: [], 2: [failed_build(job_id=7)]},
                            notes={7: COMPILE_ANNOTATIONS})
        why = rescue.nightly_compile_red(api, self.target(4), clock.sleep, lambda text: None)
        self.assertTrue(why.startswith("attempt 2's build-nightly-app failed to compile"), why)
        self.assertEqual([call for call in api.calls if call.startswith("jobs")], ["jobs:4", "jobs:3", "jobs:2"])

    def test_a_newer_build_that_compiled_decides(self):
        passed = dict(job("build-nightly-app", status="completed"), id=8, conclusion="success")
        clock = Clock()
        api = CompileRedAPI(clock, lambda seconds: [], attempts={2: [passed], 1: [failed_build()]},
                            notes={2: COMPILE_ANNOTATIONS})
        self.assertEqual(rescue.nightly_compile_red(api, self.target(2), clock.sleep, lambda text: None), "")
        self.assertNotIn("jobs:1", api.calls)

    def test_a_newer_build_that_timed_out_or_was_cancelled_running_decides(self):
        # Retryable outcomes on the newest attempt are never hidden by an older attempt's compile error.
        timed_out = dict(failed_build(job_id=8), conclusion="timed_out")
        cancelled_running = dict(failed_build(job_id=8), conclusion="cancelled")
        for newest in (timed_out, cancelled_running):
            with self.subTest(conclusion=newest["conclusion"]):
                clock = Clock()
                api = CompileRedAPI(clock, lambda seconds: [], attempts={2: [newest], 1: [failed_build()]},
                                    notes={2: COMPILE_ANNOTATIONS, 8: COMPILE_ANNOTATIONS})
                self.assertEqual(rescue.nightly_compile_red(api, self.target(2), clock.sleep, lambda text: None), "")
                self.assertNotIn("jobs:1", api.calls)
        # Cancelled before any runner took it: says nothing, so attempt 1 decides.
        unstarted = dict(failed_build(job_id=8), conclusion="cancelled", runner_name="")
        clock = Clock()
        api = CompileRedAPI(clock, lambda seconds: [], attempts={2: [unstarted], 1: [failed_build()]},
                            notes={2: COMPILE_ANNOTATIONS})
        self.assertIn("failed to compile", rescue.nightly_compile_red(api, self.target(2), clock.sleep,
                                                                       lambda text: None))

    def test_a_read_error_is_retryable(self):
        clock = Clock()
        lines = []

        class Unreadable(CompileRedAPI):
            def annotations(self, job_id):
                raise urllib.error.URLError("boom")
        api = Unreadable(clock, lambda seconds: [failed_build()])
        self.assertEqual(rescue.nightly_compile_red(api, self.target(), clock.sleep, lines.append), "")
        self.assertTrue(any("treated as retryable" in line for line in lines), lines)

    def test_only_a_nightly_is_read(self):
        clock = Clock()
        api = CompileRedAPI(clock, lambda seconds: [failed_build()], notes={2: COMPILE_ANNOTATIONS})
        target = rescue.Target(RUN_ID, 1, HEAD, 42)
        self.assertEqual(rescue.nightly_compile_red(api, target, clock.sleep, lambda text: None), "")
        self.assertEqual(api.calls, [])

    def test_a_resumed_re_run_of_a_compile_red_nightly_settles_without_re_running(self):
        clock = Clock()
        api = CompileRedAPI(clock, lambda seconds: [failed_build()], notes={2: COMPILE_ANNOTATIONS})
        result = rescue.resume_rerun(api, self.target(), now=clock.now, sleep=clock.sleep, log=lambda text: None,
                                     every_job=True)
        self.assertTrue(result.startswith(rescue.COMPILE_RED), result)
        self.assertEqual(mutations(api), [])
        self.assertIn((RUN_ID, 1), rescue.SETTLED_HERE)


class FeedTimeouts(unittest.TestCase):
    """A DEV daily or nightly owned job GitHub timed out is re-run, never left cancelled (DEV run 40466210697)."""

    def dev_event(self):
        return e2e_event(path=rescue.CMUX_NEXT_DEV_DAILY_WORKFLOW_PATH)

    def dev_run(self, *, lasted, done_at=None):
        done_at = done_at if done_at is not None else 41 + lasted

        def jobs(seconds):
            found = [e2e_runner()(seconds)]
            if seconds >= done_at:
                found.append(cancelled_owned_job("Verify signed cmux NEXT DEV", lasted=lasted))
            elif seconds >= 40:
                # Past its setup, in a slow checkout (verify's took 12 minutes on the mini).
                found.append(setup_job(past_setup=True))
            return found
        return jobs, (lambda seconds: seconds >= done_at)

    def test_timed_out_names_only_jobs_that_lasted_their_limit(self):
        jobs = [
            cancelled_owned_job("Verify signed cmux NEXT DEV", lasted=15 * 60 + 2),
            cancelled_owned_job("Build the unsigned cmux NEXT DEV tip DMG", lasted=20 * 60 - 10),
            # Cancelled by someone well short of its limit.
            cancelled_owned_job("Build the unsigned cmux NEXT DEV tip DMG", lasted=8 * 60),
            # Its limit is an expression: unknown, so never counted.
            cancelled_owned_job("Dynamic limit", lasted=999 * 60),
            # Not an owned job, and a job with no runner: neither is this rescue's.
            cancelled_owned_job("Verify signed cmux NEXT DEV", lasted=30 * 60, labels=(BLACKSMITH,)),
            cancelled_owned_job("Verify signed cmux NEXT DEV", lasted=30 * 60, runner=""),
            # A name the workflow does not have.
            cancelled_owned_job("Something else", lasted=30 * 60),
        ]
        self.assertEqual(rescue.timed_out(DEV_DAILY_TEXT, jobs),
                         ["Build the unsigned cmux NEXT DEV tip DMG", "Verify signed cmux NEXT DEV"])
        failed = cancelled_owned_job("Verify signed cmux NEXT DEV", lasted=16 * 60)
        failed["conclusion"] = "failure"
        self.assertEqual(rescue.timed_out(DEV_DAILY_TEXT, [failed]), [])

    def test_a_timed_out_dev_daily_job_reruns_its_failed_jobs(self):
        jobs, finished = self.dev_run(lasted=15 * 60 + 5)
        clock = Clock()
        api = FakeAPI(clock, jobs, marker=True, finished=finished, conclusion="cancelled", workflow=DEV_DAILY_TEXT)
        code, summary = run_main(api, clock, payload=self.dev_event())
        self.assertEqual(code, 0)
        self.assertNotIn("cancel", api.calls)
        self.assertEqual(api.calls[-1], "rerun-failed", summary)
        self.assertIn("timed out", summary)
        self.assertIn(f"workflow:{rescue.CMUX_NEXT_DEV_DAILY_WORKFLOW_PATH}@{HEAD}", api.calls)

    def test_a_dev_daily_run_someone_cancelled_is_left_alone(self):
        jobs, finished = self.dev_run(lasted=4 * 60)
        clock = Clock()
        api = FakeAPI(clock, jobs, marker=True, finished=finished, conclusion="cancelled", workflow=DEV_DAILY_TEXT)
        code, summary = run_main(api, clock, payload=self.dev_event())
        self.assertEqual(code, 0)
        self.assertNotIn("rerun-failed", api.calls)
        self.assertNotIn("rerun", api.calls)
        self.assertIn("stopped: the run finished", summary)

    def test_an_e2e_timeout_is_not_a_feed_timeout(self):
        jobs, finished = self.dev_run(lasted=15 * 60 + 5)
        clock = Clock()
        api = FakeAPI(clock, jobs, marker=True, finished=finished, conclusion="cancelled", workflow=DEV_DAILY_TEXT)
        code, summary = run_main(api, clock, payload=e2e_event())
        self.assertEqual(code, 0)
        self.assertNotIn("rerun-failed", api.calls)
        self.assertFalse(any(call.startswith("workflow:") for call in api.calls))
        self.assertIn("stopped: the run finished", summary)

    def test_no_yaml_parser_counts_no_timeout(self):
        jobs, finished = self.dev_run(lasted=15 * 60 + 5)
        clock = Clock()
        api = FakeAPI(clock, jobs, marker=True, finished=finished, conclusion="cancelled", workflow=DEV_DAILY_TEXT)
        with unittest.mock.patch.object(rescue.owned_pool_sources, "_load", side_effect=ModuleNotFoundError("yaml")):
            code, summary = run_main(api, clock, payload=self.dev_event())
        self.assertEqual(code, 0)
        self.assertNotIn("rerun-failed", api.calls)
        self.assertIn("no cancelled job is put down to a timeout", summary)
        self.assertIn("stopped: the run finished", summary)

    def test_main_nightly_is_watched_past_an_accepted_build_until_it_times_out(self):
        text = "jobs:\n  build-nightly-app:\n    runs-on: x\n    timeout-minutes: 90\n"
        timeout_at = 41 + 90 * 60

        def jobs(seconds):
            found = [job("decide", status="completed", labels=[BLACKSMITH])]
            if seconds >= timeout_at:
                found.append(cancelled_owned_job("build-nightly-app", lasted=90 * 60, labels=(TRUSTED,)))
            else:
                app = job("build-nightly-app", labels=[TRUSTED], created=15, status="in_progress",
                          runner="cmux15-glaeda")
                app["started_at"] = stamp(41)
                found.append(app)
            return found
        clock = Clock()
        api = NightlyAPI(clock, jobs, finished=lambda s: s >= timeout_at, conclusion="cancelled", workflow=text)
        code, summary = run_main(api, clock, payload=nightly_event())
        self.assertEqual(code, 0)
        self.assertNotIn("cancel", api.calls)
        self.assertEqual(api.calls[-1], "rerun-failed", summary)
        self.assertIn("timed out", summary)

    def test_a_superseded_timed_out_nightly_is_not_rerun(self):
        text = "jobs:\n  build-nightly-app:\n    runs-on: x\n    timeout-minutes: 90\n"
        done = 41 + 90 * 60

        def jobs(seconds):
            found = [job("decide", status="completed", labels=[BLACKSMITH])]
            found.append(cancelled_owned_job("build-nightly-app", lasted=90 * 60, labels=(TRUSTED,))
                         if seconds >= done else job("build-nightly-app", labels=[TRUSTED], created=15,
                                                     status="in_progress", runner="cmux15-glaeda"))
            return found
        clock = Clock()
        api = NightlyAPI(clock, jobs, finished=lambda s: s >= done, conclusion="cancelled", workflow=text,
                         newer=[RUN_ID + 3], head="b" * 40, pushes=[RUN_ID + 3])
        code, summary = run_main(api, clock, payload=nightly_event())
        self.assertEqual(code, 0)
        self.assertNotIn("rerun-failed", api.calls)
        self.assertNotIn("rerun", api.calls)

    def test_a_timed_out_nightly_app_build_reruns_its_failed_jobs(self):
        text = "jobs:\n  build-nightly-app:\n    runs-on: x\n    timeout-minutes: 90\n"

        def jobs(seconds):
            found = [job("decide", status="completed", labels=[BLACKSMITH])]
            if seconds >= 41 + 90 * 60:
                found.append(cancelled_owned_job("build-nightly-app", lasted=90 * 60, labels=(TRUSTED,)))
            else:
                found.append(job("build-nightly-app", labels=[TRUSTED], created=15, status="in_progress",
                                 runner="cmux15-glaeda"))
            return found
        clock = Clock()
        api = NightlyAPI(clock, jobs, finished=lambda s: s >= 41 + 90 * 60, conclusion="cancelled", workflow=text)
        code, summary = run_main(api, clock, payload=nightly_event(head_branch="nightly-next"))
        self.assertEqual(code, 0)
        self.assertNotIn("cancel", api.calls)
        self.assertEqual(api.calls[-1], "rerun-failed", summary)


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

    def test_runs_when_dispatched_or_for_a_screenshots_or_nightly_run(self):
        triggers = self.doc[True]
        self.assertEqual(sorted(triggers), ["schedule", "workflow_dispatch", "workflow_run"])
        self.assertIs(triggers["workflow_dispatch"]["inputs"]["run_id"]["required"], False)
        # release.yml calls ios-screenshots.yml with contents: read only, so
        # it cannot upload through a job asking for more. Side lanes are swept
        # periodically and must not create one rescue run per workflow_run.
        # cmux-next is the one `completed` source; the `if` keeps the others on `requested`.
        self.assertEqual(triggers["workflow_run"]["types"], ["requested", "completed"])
        self.assertEqual(
            triggers["workflow_run"]["workflows"],
            ["iOS App Store screenshots", "Nightly macOS build", "cmux NEXT DEV daily", "cmux-next"],
        )
        self.assertNotIn("CI", triggers["workflow_run"]["workflows"])
        paths = self.doc["env"]["SOURCE_WORKFLOW_PATHS"].split()
        self.assertEqual(
            set(paths),
            {rescue.IOS_SCREENSHOTS_WORKFLOW_PATH, rescue.NIGHTLY_WORKFLOW_PATH,
             rescue.CMUX_NEXT_DEV_DAILY_WORKFLOW_PATH, rescue.CMUX_NEXT_WORKFLOW_PATH},
        )
        self.assertEqual(set(paths) & rescue.SIDE_WORKFLOW_PATHS, {rescue.CMUX_NEXT_WORKFLOW_PATH})
        # workflow_run matches by display name: each source's `name:` is listed, and nothing else.
        names = {yaml.safe_load((ROOT / path).read_text(encoding="utf-8"))["name"] for path in paths}
        self.assertEqual(set(triggers["workflow_run"]["workflows"]), names)
        condition = self.doc["jobs"]["rescue"]["if"]
        for part in ("vars.CI_PR_POOL_OWNED == '1'", "(vars.CI_OWNED_POOL_RESCUE || '1') != '0'",
                     "(github.event_name == 'schedule' || github.event_name == 'workflow_dispatch' || "
                     "github.event.action == 'requested' && "
                     "github.event.workflow_run.path != '.github/workflows/cmux-next.yml' && "
                     "(github.event.workflow_run.path != '.github/workflows/nightly.yml' && "
                     "github.event.workflow_run.path != '.github/workflows/ios-screenshots.yml' && "
                     "contains(fromJSON('[\"pull_request\",\"push\",\"schedule\",\"workflow_dispatch\"]'), "
                     "github.event.workflow_run.event) && "
                     "(startsWith(vars.CI_SIDE_LANE_RUNNER, 'glaeda-side-') || "
                     "startsWith(vars.CI_LIGHT_LANE_RUNNER, 'glaeda-side-')) || "
                     "github.event.workflow_run.path == '.github/workflows/ios-screenshots.yml' && "
                     "github.event.workflow_run.event == 'workflow_dispatch' || "
                     "github.event.workflow_run.path == '.github/workflows/cmux-next-dev-daily.yml' && "
                     "github.event.workflow_run.event == 'workflow_dispatch' || "
                     "github.event.workflow_run.path == '.github/workflows/nightly.yml' && "
                     "(github.event.workflow_run.event == 'push' || github.event.workflow_run.event == 'schedule') && "
                     "(github.event.workflow_run.head_branch == 'main' && "
                     "startsWith(vars.CI_SEED_TRUSTED_POOL, 'glaeda-trusted-') && "
                     "startsWith(vars.CI_NIGHTLY_TRUSTED_RUNNER, 'glaeda-runner-') || "
                     "github.event.workflow_run.head_branch == 'nightly-next' && "
                     "github.event.workflow_run.event == 'push' && "
                     "(startsWith(vars.CI_SIDE_LANE_RUNNER, 'glaeda-side-') || "
                     "startsWith(vars.CI_NIGHTLY_NEXT_BUILD_RUNNER, 'glaeda-nightly-') || "
                     "!startsWith(vars.CI_NIGHTLY_NEXT_BUILD_RUNNER, 'glaeda-nightly-') || "
                     "startsWith(vars.CI_NIGHTLY_NEXT_TRUSTED_POOL, 'glaeda-trusted-') && "
                     "startsWith(vars.CI_NIGHTLY_NEXT_TRUSTED_RUNNER, 'glaeda-runner-')))) && "
                     "github.event.workflow_run.head_repository.full_name == github.repository && "
                     "github.event.workflow_run.run_attempt == 1 || "
                     + self.COMPLETED_DEV_RUN + ")"):
            self.assertIn(part, condition)
        step = self.doc["jobs"]["rescue"]["steps"][-1]
        self.assertEqual(step["env"]["WATCH_RUN_ID"], "${{ inputs.run_id }}")
        self.assertIn("inputs.run_id || github.event.workflow_run.id", self.doc["concurrency"]["group"])

    # A failed cmux-next DEV daily, tip Swift suite or tip daemon suite dispatch, base-branch push or
    # same-repository pull
    # request run, at any attempt (completed_target()).
    COMPLETED_DEV_RUN = (
        "github.event.action == 'completed' && "
        "github.event.workflow_run.path == '.github/workflows/cmux-next.yml' && "
        "github.event.workflow_run.conclusion == 'failure' && "
        "github.event.workflow_run.head_repository.full_name == github.repository && "
        "(github.event.workflow_run.event == 'workflow_dispatch' && "
        "(startsWith(github.event.workflow_run.display_title, 'cmux NEXT DEV daily') || "
        "startsWith(github.event.workflow_run.display_title, 'cmux-next tip Swift suite') || "
        "startsWith(github.event.workflow_run.display_title, 'cmux-next tip daemon suite')) || "
        "github.event.workflow_run.event == 'push' && github.event.workflow_run.head_branch == 'feat-cmux-next' || "
        "github.event.workflow_run.event == 'pull_request')")

    def test_a_failed_cmux_next_dev_run_wakes_a_rescue_when_it_completes(self):
        condition = self.doc["jobs"]["rescue"]["if"]
        self.assertIn(" || " + self.COMPLETED_DEV_RUN + ") }}", condition)
        # The run-name the completed branch matches: cmux-next.yml's DEV daily dispatch title.
        next_doc = yaml.safe_load((ROOT / rescue.CMUX_NEXT_WORKFLOW_PATH).read_text(encoding="utf-8"))
        self.assertEqual(next_doc["name"], "cmux-next")
        # A cmux-next `requested` event never matches the requested branch, which admits any side lane.
        self.assertIn("github.event.action == 'requested' && "
                      "github.event.workflow_run.path != '.github/workflows/cmux-next.yml' && ", condition)
        # Each failed attempt gets its own concurrency group, so attempt 3's rescue never cancels attempt 2's,
        # and a `completed` event never joins (and cancels) the `requested` watch of the same attempt.
        suffixed = ("format('owned-pool-rescue-{0}-{1}{2}', inputs.run_id || github.event.workflow_run.id, "
                    "inputs.run_attempt || github.event.workflow_run.run_attempt, "
                    "github.event.action == 'completed' && '-completed' || '')")
        self.assertIn(suffixed, self.doc["concurrency"]["group"])
        self.assertIn(suffixed, self.doc["run-name"])

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

    def test_the_needs_check_gets_pyyaml_without_ever_failing_the_job(self):
        # downstream_of_refusals() parses the run's workflow file; a failed install only excuses nothing.
        steps = self.doc["jobs"]["rescue"]["steps"]
        prepare = next(step for step in steps if step.get("name") == "Prepare rescue Python")
        self.assertLess(steps.index(prepare), len(steps) - 1)
        self.assertIs(prepare.get("continue-on-error"), True)
        self.assertIn("PyYAML==6.0.3", prepare["run"])
        self.assertIn('>> "$GITHUB_PATH"', prepare["run"])

    def test_polls_from_an_ephemeral_runner(self):
        # Never from an owned pool it may rescue, and never only from
        # GitHub-hosted: a GitHub billing block must not stop the rescue.
        self.assertEqual(
            self.doc["jobs"]["rescue"]["runs-on"],
            '${{ github.repository_owner != \'manaflow-ai\' && \'ubuntu-24.04\' || contains(fromJSON(\'["ubuntu-24.04","blacksmith-2vcpu-ubuntu-2404","blacksmith-4vcpu-ubuntu-2404","blacksmith-8vcpu-ubuntu-2404"]\'), vars.CI_TRUSTED_RUNNER) && vars.CI_TRUSTED_RUNNER || \'blacksmith-4vcpu-ubuntu-2404\' }}',
        )

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
        # A handover joins its rescues for the grace: it holds a whole cancel, its re-run and the
        # watch's rate-limit waits, so the process never exits with a run cancelled and not re-run.
        self.assertGreaterEqual(rescue.RESCUE_GRACE_SECONDS, rescue.CANCEL_WAIT_SECONDS + rescue.RERUN_MARGIN_SECONDS
                                + rescue.RATE_LIMIT_WAIT_SECONDS)
        self.assertLessEqual(watch + rescue.RESCUE_GRACE_SECONDS,
                             rescue.JOB_TIMEOUT_SECONDS - rescue.JOB_TIMEOUT_MARGIN_SECONDS)



class BotRerunRouteTests(unittest.TestCase):
    """Where the bot's re-run of failed jobs sends a leg still queued on an owned label.

    queue_janitor.py's unclaimed-leg rule (run 39652497071's cmux-tui macOS leg, queued 18:25Z to 00:37Z on
    glaeda-side-std-xcode-26.6) re-runs a run only when that re-run leaves the owned pool.
    """

    def test_a_side_lane_attempt_1_goes_to_its_blacksmith_default(self):
        for path in (".github/workflows/cmux-tui.yml", ".github/workflows/remote-daemon.yml"):
            with self.subTest(path=path):
                self.assertTrue(rescue.bot_rerun_leaves_owned(path, 1))
                self.assertTrue(rescue.bot_rerun_leaves_owned(path, 2))

    def test_cmux_next_stays_on_the_minis_until_its_refusal_attempt(self):
        path = rescue.CMUX_NEXT_WORKFLOW_PATH
        self.assertFalse(rescue.bot_rerun_leaves_owned(path, 1))
        self.assertFalse(rescue.bot_rerun_leaves_owned(path, rescue.REFUSAL_RESCUE_ATTEMPT - 1))
        self.assertTrue(rescue.bot_rerun_leaves_owned(path, rescue.REFUSAL_RESCUE_ATTEMPT))

    def test_ci_reuses_attempt_1s_owned_labels_on_attempt_2(self):
        self.assertFalse(rescue.bot_rerun_leaves_owned(rescue.CI_WORKFLOW_PATH, 1))
        self.assertTrue(rescue.bot_rerun_leaves_owned(rescue.CI_WORKFLOW_PATH, rescue.LAST_OWNED_ATTEMPT))

    def test_dispatches_take_their_retry_label_except_an_e2e_ui_run(self):
        self.assertTrue(rescue.bot_rerun_leaves_owned(rescue.IOS_TEST_WORKFLOW_PATH, 1))
        # A UI run's retry_label stays on its owned pool, and the path cannot tell a UI run apart.
        self.assertFalse(rescue.bot_rerun_leaves_owned(rescue.E2E_WORKFLOW_PATH, 1))

    def test_an_unwatched_or_release_workflow_is_never_moved(self):
        self.assertFalse(rescue.bot_rerun_leaves_owned(".github/workflows/unknown.yml", 1))
        for path in rescue.UNRESCUED_WORKFLOW_PATHS:
            with self.subTest(path=path):
                self.assertFalse(rescue.bot_rerun_leaves_owned(path, 1))
        self.assertFalse(rescue.bot_rerun_leaves_owned(rescue.NIGHTLY_WORKFLOW_PATH, 1))
        # The autofix Mac exports keep their session or gui label on every attempt.
        for path in rescue.OWNED_EVERY_ATTEMPT_PATHS:
            with self.subTest(path=path):
                self.assertIn(path, rescue.SIDE_WORKFLOW_PATHS)
                self.assertFalse(rescue.bot_rerun_leaves_owned(path, 5))

    def test_cmux_tui_macos_legs_take_blacksmith_on_any_later_attempt(self):
        # The route bot_rerun_leaves_owned() relies on: every macOS runner expression in cmux-tui.yml takes
        # CI_SIDE_LANE_RUNNER only on attempt 1 and falls back to a Blacksmith macOS label otherwise.
        text = (ROOT / ".github/workflows/cmux-tui.yml").read_text(encoding="utf-8")
        legs = [line for line in text.splitlines() if "vars.CI_SIDE_LANE_RUNNER" in line]
        self.assertTrue(legs)
        for line in legs:
            with self.subTest(line=line.strip()[:60]):
                self.assertIn("github.run_attempt == 1 && vars.CI_SIDE_LANE_RUNNER || 'blacksmith-", line)
                self.assertIn("macos", line.rsplit("||", 1)[1])


class OpenHeadNeverCancelled(unittest.TestCase):
    """rescue() never cancels a run whose pull request is open at the run's head (OPEN_HEAD_RULE)."""

    def test_pr_25446_cmux_next_run_at_its_open_head_is_never_cancelled(self):
        # Run 40398277457 (cmux-next, PR #25446 at 8be738c84d8): attempt 1 was cancelled and re-run here at
        # 21:23Z, and the janitor then cancelled attempt 2. A stuck side job of that run now waits.
        clock = Clock()
        stuck = lambda seconds: [job("cmux-next fast tier", labels=[SIDE], created=0),
                                 job("cmux-next Release compile (Xcode 26)", labels=[SIDE], status="in_progress",
                                     created=0, runner="mini-5-glaeda-3")]
        api = FakeAPI(clock, stuck)
        payload = side_event(path=".github/workflows/cmux-next.yml", pull_requests=[{"number": 25446}])
        code, summary = run_main(api, clock, payload=payload, env_extra={"SIDE_RESCUE_SECONDS": "30"})
        self.assertEqual(code, 0)
        assert_left_at_open_head(self, api, summary, number=25446)

    def test_every_kind_of_pull_request_target_is_left_alone_while_its_run_goes_on(self):
        kinds = {"ci": {}, "side": {"side": True, "path": ".github/workflows/relay-tls.yml"},
                 "cmux-next": {"side": True, "path": rescue.CMUX_NEXT_WORKFLOW_PATH},
                 "ios": {"e2e": True, "path": ".github/workflows/test-ios.yml"},
                 "attempt 2": {"attempt": 2, "full_rerun": True}}
        for kind, extra in kinds.items():
            for failed_only in (False, True):
                with self.subTest(kind=kind, failed_only=failed_only):
                    clock = Clock()
                    api = FakeAPI(clock, persistent_run(), marker=True, rerun_jobs=persistent_run())
                    api.attempt = extra.get("attempt", 1)
                    target = rescue.Target(**{"run_id": RUN_ID, "attempt": 1, "head_sha": HEAD, "pr_number": 42,
                                              **extra})
                    result = rescue.rescue(api, target, now=clock.now, sleep=clock.sleep, log=lambda _: None,
                                           failed_only=failed_only)
                    self.assertEqual(api.calls, ["pull", "run"])
                    self.assertIn(rescue.OPEN_HEAD_RULE, result)

    def test_a_finished_run_at_its_open_head_still_gets_its_failed_jobs_re_run(self):
        clock = Clock()
        api = FakeAPI(clock, persistent_run(), marker=True, finished=lambda seconds: True)
        target = rescue.Target(run_id=RUN_ID, attempt=1, head_sha=HEAD, pr_number=42)
        result = rescue.rescue(api, target, now=clock.now, sleep=clock.sleep, log=lambda _: None, failed_only=True)
        self.assertEqual(api.calls, ["pull", "run", "rerun-failed"])
        self.assertIn("re-ran the failed jobs", result)

    def test_superseded_or_closed_runs_are_unchanged(self):
        for kwargs in ({"head": "b" * 40}, {"state": "closed"}):
            with self.subTest(**kwargs):
                clock = Clock()
                api = FakeAPI(clock, persistent_run(), marker=True, **kwargs)
                target = rescue.Target(run_id=RUN_ID, attempt=1, head_sha=HEAD, pr_number=42)
                result = rescue.rescue(api, target, now=clock.now, sleep=clock.sleep, log=lambda _: None)
                self.assertNotIn("cancel", api.calls)
                self.assertTrue(result.startswith("not rescued:"), result)
                self.assertNotIn(rescue.OPEN_HEAD_RULE, result)



SESSION = "glaeda-session-std-xcode-26.6"


class OpenHeadUnstartedFailover(unittest.TestCase):
    """The stall-aware failover at an open head (unstarted_failover()): cancel and re-run every job only while no
    job was taken by a runner and one waited past UNSTARTED_STALL_SECONDS on a label that runs nothing."""

    def world(self, jobs, *, running=0, listed=True, path=rescue.CMUX_NEXT_WORKFLOW_PATH, extra=None):
        clock = Clock()
        pools = {SESSION: {"queued": 1, "running": running, "oldest_queued_minutes": 4}} if listed else \
            {MINI: {"queued": 0, "running": 3}}
        api = FakeAPI(clock, jobs, snapshot=lambda seconds: {"generated_at": stamp(seconds), "pools": pools},
                      rerun_jobs=lambda seconds: [job("cmux-next daemon tests", labels=[BLACKSMITH], status="queued")])
        target = rescue.Target(**{"run_id": RUN_ID, "attempt": 1, "head_sha": HEAD, "pr_number": 26999,
                                  "side": True, "path": path, **(extra or {})})
        return clock, api, target

    def gates(self, seconds):
        """Run 40887257098's shape: Linux gates done, the daemon test queued on the session label."""
        done = job("cmux-next macOS placement", status="completed", labels=["blacksmith-4vcpu-ubuntu-2404"],
                   runner="bs-linux")
        done["conclusion"] = "success"
        skipped = job("cmux-next Swift canary", status="completed", labels=[SESSION])
        skipped["conclusion"] = "skipped"
        return [done, skipped, job("cmux-next daemon tests", labels=[SESSION], created=-240)]

    def run_rescue(self, api, clock, target, failed_only=True):
        lines = []
        result = rescue.rescue(api, target, now=clock.now, sleep=clock.sleep, log=lines.append,
                               failed_only=failed_only)
        return result, lines

    def test_run_40887257098_is_moved_while_nothing_has_started(self):
        clock, api, target = self.world(self.gates)
        result, lines = self.run_rescue(api, clock, target)
        self.assertIn("cancel", api.calls)
        self.assertIn("rerun", api.calls)  # every job again, so the placement checks the routes afresh
        self.assertNotIn("rerun-failed", api.calls)
        self.assertNotIn(rescue.OPEN_HEAD_RULE, result)
        self.assertTrue(any(line.startswith(rescue.OPEN_HEAD_FAILOVER) and SESSION in line for line in lines), lines)

    def test_a_label_that_runs_a_job_keeps_the_open_head_rule(self):
        clock, api, target = self.world(self.gates, running=1)
        result, _ = self.run_rescue(api, clock, target)
        assert_left_at_open_head(self, api, result, number=26999)

    def test_a_label_the_snapshot_does_not_list_proves_nothing(self):
        clock, api, target = self.world(self.gates, listed=False)
        result, _ = self.run_rescue(api, clock, target)
        assert_left_at_open_head(self, api, result, number=26999)

    def test_a_started_or_taken_mac_job_keeps_the_open_head_rule(self):
        def running(seconds):
            return [*self.gates(seconds), job("cmux-next swift test", labels=["glaeda-gui-std-xcode-26.6"],
                                              status="in_progress", runner="mini-11")]

        def carried(seconds):
            # A re-run of failed jobs carries attempt 1's finished Mac job: a full re-run would lose it.
            return [*self.gates(seconds), job("cmux-next swift test", labels=["glaeda-gui-std-xcode-26.6"],
                                              status="completed", runner="mini-11")]

        def linux_running(seconds):
            return [*self.gates(seconds), job("cmux-next checks", labels=["blacksmith-16vcpu-ubuntu-2404"],
                                              status="in_progress", runner="bs")]

        def linux_finished(seconds):
            # A finished Linux job that is no placement (a check, a build) is a result a full re-run would discard.
            done = job("cmux-next fast tier (cargo)", labels=["blacksmith-32vcpu-ubuntu-2404"], status="completed",
                       runner="bs")
            done["conclusion"] = "success"
            return [*self.gates(seconds), done]
        for jobs in (running, linux_running):
            with self.subTest(jobs=jobs.__name__):
                clock, api, target = self.world(jobs)
                result, _ = self.run_rescue(api, clock, target)
                assert_left_at_open_head(self, api, result, number=26999)
        # A finished job is no started work a cancel kills: the settled-sibling failover re-runs only what waited,
        # so the full re-run never discards it.
        for jobs in (carried, linux_finished):
            with self.subTest(jobs=jobs.__name__):
                clock, api, target = self.world(with_ids(jobs))
                self.run_rescue(api, clock, target)
                assert_settled_failover(self, api)

    def test_a_short_wait_is_looked_at_again_once_it_reaches_the_floor(self):
        def fresh(seconds):
            return [job("cmux-next daemon tests", labels=[SESSION], created=0)]
        clock, api, target = self.world(fresh)
        result, _ = self.run_rescue(api, clock, target)
        self.assertGreaterEqual(clock.seconds, rescue.UNSTARTED_STALL_SECONDS)
        self.assertIn("cancel", api.calls)
        self.assertIn("rerun", api.calls)

    def test_a_job_that_starts_before_the_cancel_drops_it(self):
        state = {"looks": 0}

        def starts(seconds):
            state["looks"] += 1
            queued = job("cmux-next daemon tests", labels=[SESSION], created=-240)
            if state["looks"] > 1:  # the guard's read right before the cancel
                queued.update(status="in_progress", runner="mini-10")
            return [queued]
        clock, api, target = self.world(starts)
        result, _ = self.run_rescue(api, clock, target)
        assert_left_at_open_head(self, api, result, number=26999)
        self.assertIn("started before the cancel", result)

    def test_a_cancel_never_hits_a_newer_attempt(self):
        # Review of #27521: another watch re-ran the run between the look and the cancel; the cancel would hit
        # the newer attempt's jobs.
        clock, api, target = self.world(self.gates)
        reads = {"n": 0}
        real_run = api.run

        def run(run_id):
            reads["n"] += 1
            found = real_run(run_id)
            if reads["n"] >= 2:  # rescue()'s own read first, then the guard's
                found = {**found, "run_attempt": 2}
            return found
        api.run = run
        result, _ = self.run_rescue(api, clock, target)
        self.assertNotIn("cancel", api.calls)
        self.assertIn("attempt 2, not 1", result)

    def test_a_job_without_created_at_is_dated_by_when_a_watch_saw_it(self):
        def undated(seconds):
            queued = job("cmux-next daemon tests", labels=[SESSION])
            queued.pop("created_at")
            queued["id"] = 77
            return [queued]
        clock, api, target = self.world(undated)
        result = rescue.unstarted_failover(api, target, now=clock.now, sleep=clock.sleep, log=lambda _: None,
                                           first_seen={77: START - dt.timedelta(minutes=5)})
        self.assertIn("has waited 5 min", result)
        self.assertEqual(clock.seconds, 0, "no sleep: the watcher saw it queued 5 minutes ago")
        clock, api, target = self.world(undated)
        result = rescue.unstarted_failover(api, target, now=clock.now, sleep=clock.sleep, log=lambda _: None)
        self.assertTrue(result, "unseen before: this look dates it, and the second look finds it past the floor")
        self.assertEqual(clock.seconds, rescue.UNSTARTED_STALL_SECONDS)

    def test_a_listing_that_may_be_cut_short_proves_nothing(self):
        def many(seconds):
            return [job(f"shard {index}", labels=[SESSION], created=-240)
                    for index in range(rescue.MAX_JOB_PAGES * 100)]
        clock, api, target = self.world(many)
        self.assertEqual(rescue.unstarted_failover(api, target, now=clock.now, sleep=clock.sleep,
                                                   log=lambda _: None), "")

    def test_a_failed_rerun_leaves_the_cancel_for_a_successor(self):
        clock, api, target = self.world(self.gates)

        def broken(run_id, next_attempt):
            raise rescue.urllib.error.URLError("rerun refused")
        api.rerun = broken
        lines = []
        with self.assertRaises(Exception):
            rescue.rescue(api, target, now=clock.now, sleep=clock.sleep, log=lines.append, failed_only=True)
        self.assertIn("cancel", api.calls)
        self.assertTrue(any(line.startswith(rescue.CANCEL_SENT) for line in lines), lines)
        self.assertFalse(any(line.startswith(rescue.CANCEL_SETTLED) for line in lines), lines)
        self.assertNotIn((RUN_ID, 1), rescue.SETTLED_HERE)

    def test_the_guard_refuses_a_listing_that_grew_past_its_pages(self):
        state = {"looks": 0}

        def grows(seconds):
            state["looks"] += 1
            if state["looks"] == 1:
                return self.gates(seconds)
            return [job(f"shard {index}", labels=[SESSION], created=-240) for index in range(rescue.MAX_JOB_PAGES * 100)]
        clock, api, target = self.world(grows)
        result, _ = self.run_rescue(api, clock, target)
        self.assertNotIn("cancel", api.calls)
        self.assertIn("maybe more", result)

    def test_a_resumed_rerun_that_fails_leaves_a_pull_requests_cancel_unsettled(self):
        clock, api, target = self.world(self.gates)
        api.cancel(RUN_ID)

        def broken(run_id, next_attempt):
            raise rescue.urllib.error.URLError("rerun refused")
        api.rerun = broken
        lines = []
        with self.assertRaises(Exception):
            rescue.resume_rerun(api, target, now=clock.now, sleep=clock.sleep, log=lines.append, every_job=True)
        self.assertFalse(any(line.startswith(rescue.CANCEL_SETTLED) for line in lines), lines)

    def test_the_placement_list_holds_only_placement_jobs(self):
        # dep-fleet's ruling: the exempt jobs only place or preflight; one that builds, tests or signs never joins.
        forbidden = re.compile(r"build|compile|test|sign|notar|publish|archive|bundle|package|export|smoke|canary",
                               re.IGNORECASE)
        self.assertTrue(rescue.PLACEMENT_JOBS)
        for name in rescue.PLACEMENT_JOBS:
            self.assertIsNone(forbidden.search(name), name)

    def test_a_placement_job_counts_only_when_it_succeeded(self):
        for conclusion in ("failure", "cancelled", "timed_out"):
            placement = job("cmux-next macOS placement", status="completed", labels=["blacksmith-4vcpu-ubuntu-2404"],
                            runner="bs")
            placement["conclusion"] = conclusion
            self.assertTrue(rescue.job_started(placement), conclusion)
        assigned = job("cmux-next daemon tests", labels=[SESSION])
        assigned["runner_id"] = 7
        self.assertTrue(rescue.job_started(assigned), "a runner assigned is started")

    def test_every_nightly_dev_and_promote_delivery_run_is_excluded(self):
        # dep-fleet's ruling: a delivery run (any event but a pull request's) of a nightly, DEV, promote, release,
        # sign or rollback workflow never fails over; an unread event keeps the exclusion.
        for path in rescue.NEVER_FAILOVER_PATHS | {".github/workflows/nightly-next-future.yml"}:
            for event in ("schedule", "workflow_dispatch", "push", "workflow_run", "", None):
                self.assertTrue(rescue.never_fails_over(path, event), (path, event))
        self.assertFalse(rescue.never_fails_over(rescue.CMUX_NEXT_WORKFLOW_PATH, "schedule"))

    def test_a_pull_request_run_of_the_canary_or_launch_smoke_is_not_excluded(self):
        # The ruling never meant a pull request's test run of a post-publish check: it publishes, signs, rolls back
        # and files nothing (8 such jobs held glaeda-side-std-xcode-26.6 as reserved on 2026-10-30 14:16Z).
        for path in (".github/workflows/nightly-next-canary.yml", ".github/workflows/nightly-next-launch-smoke.yml"):
            self.assertFalse(rescue.never_fails_over(path, "pull_request"), path)

    def test_a_pull_request_run_of_the_canary_or_launch_smoke_fails_over_a_dead_label(self):
        for path in (".github/workflows/nightly-next-canary.yml", ".github/workflows/nightly-next-launch-smoke.yml"):
            with self.subTest(path=path):
                target = rescue.target_from_event(event(path=path, pull_requests=[{"number": 26999}]),
                                                  "manaflow-ai/cmux")
                self.assertIsInstance(target, rescue.Target)
                clock, api, _ = self.world(self.gates, path=path)
                result, lines = self.run_rescue(api, clock, target)
                self.assertIn("cancel", api.calls)
                self.assertIn("rerun", api.calls)
                self.assertNotIn(rescue.OPEN_HEAD_RULE, result)
                self.assertTrue(any(line.startswith(rescue.OPEN_HEAD_FAILOVER) for line in lines), lines)

    def test_the_failover_leaves_a_receipt(self):
        clock, api, target = self.world(self.gates)
        with unittest.mock.patch("sys.stdout", io.StringIO()) as out:
            result, lines = self.run_rescue(api, clock, target)
        receipt = [line for line in lines if "receipt" in line]
        self.assertTrue(receipt, lines)
        self.assertIn("cmux-next daemon tests on " + SESSION, receipt[0])
        self.assertIn("cmux-next macOS placement", receipt[0])
        self.assertIn("::notice title=Open-head failover::", out.getvalue())

    def test_nightly_dev_and_dispatch_targets_never_fail_over(self):
        for extra in ({"path": DEV_DAILY}, {"path": rescue.NIGHTLY_WORKFLOW_PATH, "nightly": True},
                      {"e2e": True, "path": ".github/workflows/test-ios.yml"}):
            with self.subTest(**extra):
                clock, api, target = self.world(self.gates, extra=extra)
                self.assertEqual(rescue.unstarted_failover(api, target, now=clock.now, sleep=clock.sleep,
                                                           log=lambda _: None), "")
                self.assertNotIn("cancel", api.calls)

    def test_a_refusals_only_watch_fails_over_a_dead_label(self):
        # Run 40887257098's placement found no free Blacksmith slot, so its watch was refusals-only: a queue alarm
        # never moved it. A label that runs nothing is no queue to wait in.
        for running, moved in ((0, True), (1, False)):
            with self.subTest(running=running):
                clock, api, target = self.world(self.gates, running=running,
                                                extra={"refusals_only": True, "attempt_started_at": START})
                result = rescue.follow(api, target, seconds=30, queue_rounds="0", now=clock.now, sleep=clock.sleep,
                                       log=lambda _: None, side_seconds=30)
                self.assertEqual("rerun" in api.calls, moved, (result, api.calls))
                self.assertEqual("cancel" in api.calls, moved, (result, api.calls))

    def test_the_janitor_snapshot_counts_lane_labels(self):
        janitor = load("queue_janitor", ROOT / "scripts/ci/queue_janitor.py")
        now = START + dt.timedelta(minutes=10)
        run = {"id": 9, "status": "queued", "path": rescue.CMUX_NEXT_WORKFLOW_PATH}
        queued = job("cmux-next daemon tests", labels=[SESSION], created=0)
        snapshot = janitor.pool_load_snapshot([run], {9: [queued]}, now=now)
        self.assertEqual(snapshot["pools"][SESSION]["queued"], 1)
        self.assertEqual(snapshot["pools"][SESSION]["running"], 0)
        self.assertEqual(snapshot["pools"][SESSION]["oldest_queued_minutes"], 10)
        self.assertEqual(snapshot["running"], {}, "lane jobs add no owned runner to the warm map")
        # Review of #27521: a running lane job that also asked for `macOS` still counts on its lane.
        busy = job("cmux-next daemon tests", labels=["self-hosted", "macOS", SESSION], status="in_progress",
                   created=0, runner="mini-10")
        snapshot = janitor.pool_load_snapshot([run], {9: [queued, busy]}, now=now)
        self.assertEqual(snapshot["pools"][SESSION]["running"], 1)
        self.assertEqual(snapshot["pools"][SESSION]["queued"], 1)


# A trimmed cmux-next.yml (feat-cmux-next) with the `needs` graph of the jobs a pull request run lists: the Linux
# checks and builds need path routing only; the Mac tiers need the macOS placement.
CMUX_NEXT_FIXTURE = """
on: pull_request
jobs:
  path_route:
    name: cmux-next path routing
    runs-on: ubuntu-latest
    steps: [{run: "true"}]
  push-head-preflight:
    name: cmux-next push head preflight
    needs: path_route
    runs-on: ubuntu-latest
    steps: [{run: "true"}]
  macos-placement:
    name: cmux-next macOS placement
    needs: [path_route, push-head-preflight]
    runs-on: ubuntu-latest
    steps: [{run: "true"}]
  checks:
    name: cmux-next checks (god files, concurrency, crash safety, l10n)
    needs: path_route
    runs-on: ubuntu-latest
    steps: [{run: "true"}]
  pr-red-checks:
    needs: [checks]
    uses: ./.github/workflows/pr-red-checks.yml
  fast-tier-cargo:
    name: cmux-next fast tier (cargo)
    needs: path_route
    runs-on: ubuntu-latest
    steps: [{run: "true"}]
  compile-status:
    name: cmux-next fleet Release compile
    needs: [path_route]
    runs-on: ubuntu-latest
    steps: [{run: "true"}]
  fast-tier:
    name: cmux-next fast tier
    needs: [macos-placement, path_route, push-head-preflight]
    runs-on: macos-26
    steps: [{run: "true"}]
  swift-test:
    name: cmux-next swift test
    needs: [path_route, macos-placement]
    runs-on: macos-26
    steps: [{run: "true"}]
  release-compile:
    name: cmux-next Release compile (Xcode 26)
    needs: [macos-placement]
    runs-on: macos-26
    steps: [{run: "true"}]
"""
SIDE_STD = "glaeda-side-std-xcode-26.6"


def finished(name, conclusion, *, labels=("blacksmith-4vcpu-ubuntu-2404",), runner="bs-linux", job_id=None):
    found = job(name, status="completed", labels=list(labels), runner=runner if conclusion != "skipped" else "")
    found["conclusion"] = conclusion
    found["steps"] = [{"name": "Set up job", "conclusion": "success"}] if conclusion != "skipped" else []
    if job_id is not None:
        found["id"] = job_id
    return found


class OpenHeadSettledFailover(unittest.TestCase):
    """The settled-sibling failover (open_head_failover()'s `settled`): no job of the run runs or is held by a runner,
    one waited past UNSTARTED_STALL_SECONDS on a label that runs nothing, and a placement or full re-run would repeat
    a finished job. The cancel stops only what waits, and only that runs again; run 40997814347's shape."""

    COMPILE = "cmux-next Release compile (Xcode 26)"
    COMPILE_ID = 123874955999

    def world(self, jobs, *, pools=None, extra=None):
        clock = Clock()
        pools = pools if pools is not None else {MINI: {"queued": 40, "running": 0, "oldest_queued_minutes": 110}}
        api = FakeAPI(clock, jobs, workflow=CMUX_NEXT_FIXTURE,
                      snapshot=lambda seconds: {"generated_at": stamp(seconds), "pools": pools},
                      rerun_jobs=lambda seconds: [job(self.COMPILE, labels=[SIDE], status="queued")])
        target = rescue.Target(**{"run_id": RUN_ID, "attempt": 1, "head_sha": HEAD, "pr_number": 27853,
                                  "side": True, "path": rescue.CMUX_NEXT_WORKFLOW_PATH, **(extra or {})})
        return clock, api, target

    def shape_27853(self, seconds):
        """Run 40997814347 (PR #27853, 2026-10-30): 28 jobs finished, its swift test and daemon tests red below the
        placement, the Release compile queued on glaeda-std-xcode-26.6 since 03:35Z."""
        jobs = [finished("cmux-next path routing", "success"), finished("cmux-next push head preflight", "success"),
                finished(rescue.CMUX_NEXT_PLACEMENT_JOB, "success", job_id=1),
                finished("cmux-next swift test", "failure", labels=("glaeda-gui-std-xcode-26.6",), runner="mini-11"),
                finished("cmux-next fast tier", "failure", labels=(SIDE,), runner="mini-5")]
        jobs += [finished(f"linux check {index}", "success", labels=("blacksmith-4vcpu-ubuntu-2404",))
                 for index in range(23)]
        compile_job = job(self.COMPILE, labels=[MINI], created=-16000)
        compile_job["id"] = self.COMPILE_ID
        return [*jobs, compile_job]

    def run_rescue(self, api, clock, target):
        lines = []
        with unittest.mock.patch("sys.stdout", io.StringIO()) as out:
            result = rescue.rescue(api, target, now=clock.now, sleep=clock.sleep, log=lines.append, failed_only=False)
        return result, lines, out.getvalue()

    def test_run_40997814347_re_runs_only_its_stranded_compile(self):
        clock, api, target = self.world(self.shape_27853)
        result, lines, out = self.run_rescue(api, clock, target)
        self.assertIn("cancel", api.calls)
        self.assertIn(f"rerun-job:{self.COMPILE_ID}", api.calls)
        self.assertNotIn("rerun-job:1", api.calls, "the placement re-run would repeat the red swift test")
        self.assertNotIn("rerun", api.calls)
        self.assertNotIn("rerun-failed", api.calls, "the finished jobs, red ones too, keep their results")
        self.assertIn("keeping every finished job", result)
        # A rescue stopped after its cancel leaves the job it meant, so a successor re-runs that job, not the failed.
        self.assertIn(f"{rescue.CANCEL_SENT} run {RUN_ID} attempt 1 of job {self.COMPILE_ID}", lines)
        receipt = [line for line in lines if "receipt" in line]
        self.assertTrue(receipt and "finished jobs kept: 28" in receipt[0], receipt)
        self.assertIn(f"{self.COMPILE} on {MINI}", receipt[0])
        self.assertIn("::notice title=Open-head failover::", out)

    def test_a_cancel_never_leaves_a_queued_job_behind(self):
        # Every job the cancel would stop must come back in the re-run. With a second job queued (another Mac job,
        # a Linux job on a live label), no single re-run does: a job re-run brings back one job and its dependents,
        # and a re-run of the failed jobs is not shown to bring back a cancelled queued one. The open head keeps the
        # run, and a later look moves it once only the stalled job is left.
        def mac(seconds):
            other = job("cmux-next app scheme compile", labels=[MINI], created=-600)
            other["id"] = 99
            return [*self.shape_27853(seconds), other]

        def linux(seconds):
            other = job("cmux-next fleet Release compile", labels=["blacksmith-2vcpu-ubuntu-2404"], created=-60)
            other["id"] = 98
            return [*self.shape_27853(seconds), other]
        for jobs in (mac, linux):
            with self.subTest(jobs=jobs.__name__):
                clock, api, target = self.world(jobs)
                result, lines, out = self.run_rescue(api, clock, target)
                assert_left_at_open_head(self, api, result, number=27853)
                self.assertFalse([call for call in api.calls if call.startswith("rerun-job")], api.calls)
                self.assertTrue(any("2 unfinished jobs" in line for line in lines), lines)
                self.assertNotIn("::notice title=Open-head failover::", out)

    def test_a_stalled_job_that_finishes_or_goes_before_the_cancel_drops_it(self):
        # The guard right before the cancel: the stalled job finished (or left the listing) since the failover's
        # look while the run still reads in progress, so a cancel and a re-run of it would repeat a finished job.
        def finishes(jobs):
            jobs[-1].update(status="completed", conclusion="success", runner_name="mini-7")
            return jobs

        def goes(jobs):
            return jobs[:-1]
        for change, why in ((finishes, "finished before the cancel"),
                            (goes, f"job {self.COMPILE_ID} is no longer listed")):
            with self.subTest(change=change.__name__):
                state = {"looks": 0}

                def jobs_at(seconds, change=change):
                    state["looks"] += 1
                    jobs = self.shape_27853(seconds)
                    # the failover's look and the receipt, then the guard's read
                    return change(jobs) if state["looks"] > 2 else jobs
                clock, api, target = self.world(jobs_at)
                result, _, _ = self.run_rescue(api, clock, target)
                assert_left_at_open_head(self, api, result, number=27853)
                self.assertFalse([call for call in api.calls if call.startswith("rerun-job")], api.calls)
                self.assertIn(why, result)

    def test_a_job_that_queues_before_the_cancel_drops_it(self):
        # The guard right before the cancel: a second job queued since the failover's look would be cancelled and
        # left behind by the re-run of the stalled job alone.
        state = {"looks": 0}

        def queues(seconds):
            state["looks"] += 1
            jobs = self.shape_27853(seconds)
            if state["looks"] > 2:  # the failover's look and the receipt, then the guard's read
                late = job("cmux-next app scheme compile", labels=[MINI])
                late["id"] = 97
                jobs.append(late)
            return jobs
        clock, api, target = self.world(queues)
        result, _, _ = self.run_rescue(api, clock, target)
        assert_left_at_open_head(self, api, result, number=27853)
        self.assertIn("would leave it cancelled", result)

    def test_a_running_or_assigned_job_keeps_the_open_head_rule(self):
        def running(seconds):
            busy = job("cmux-next daemon tests", labels=[SESSION], status="in_progress", runner="mini-11")
            return [*self.shape_27853(seconds), busy]

        def assigned(seconds):
            taken = job("cmux-next generated files", labels=[SESSION], runner="mini-4")
            return [*self.shape_27853(seconds), taken]

        def in_setup(seconds):
            setup = job("cmux-next generated files", labels=[SESSION], status="in_progress")
            setup["runner_id"] = 7
            return [*self.shape_27853(seconds), setup]
        for jobs in (running, assigned, in_setup):
            with self.subTest(jobs=jobs.__name__):
                clock, api, target = self.world(jobs)
                result, _, _ = self.run_rescue(api, clock, target)
                assert_left_at_open_head(self, api, result, number=27853)

    def test_a_label_that_runs_a_job_keeps_the_open_head_rule(self):
        clock, api, target = self.world(self.shape_27853,
                                        pools={MINI: {"queued": 40, "running": 2, "oldest_queued_minutes": 110}})
        result, _, _ = self.run_rescue(api, clock, target)
        assert_left_at_open_head(self, api, result, number=27853)

    def test_a_job_that_starts_before_the_cancel_drops_it(self):
        state = {"looks": 0}

        def starts(seconds):
            state["looks"] += 1
            jobs = self.shape_27853(seconds)
            if state["looks"] > 2:  # the failover's look and the receipt, then the guard's read
                jobs[-1].update(status="in_progress", runner="mini-7")
            return jobs
        clock, api, target = self.world(starts)
        result, lines, out = self.run_rescue(api, clock, target)
        assert_left_at_open_head(self, api, result, number=27853)
        self.assertIn("started before the cancel", result)
        # The receipt says the run was cancelled: a dropped cancel gives none.
        self.assertFalse([line for line in lines if "receipt" in line], lines)
        self.assertNotIn("::notice title=Open-head failover::", out)

    def test_a_refused_job_re_run_is_reported_not_widened(self):
        # A re-run of the failed jobs would repeat the red swift test and fast tier the failover keeps.
        clock, api, target = self.world(self.shape_27853)

        def refused(run_id, job_id, next_attempt):
            api.calls.append(f"refused-job:{job_id}")
            raise rescue.urllib.error.HTTPError("u", 403, "cannot re-run", {}, None)
        api.rerun_job = refused
        result, _, _ = self.run_rescue(api, clock, target)
        self.assertIn(f"refused-job:{self.COMPILE_ID}", api.calls)
        self.assertNotIn("rerun-failed", api.calls)
        self.assertNotIn("rerun", api.calls)
        self.assertIn(f"GitHub refused the re-run of job {self.COMPILE_ID}", result)

    def test_a_job_that_starts_while_the_guard_reads_the_run_drops_the_cancel(self):
        # settled_guard() reads the jobs after the run: a job that started while the run read was slow (a retry, a
        # rate limit) shows in that later read, not only in one taken before it.
        state = {"looks": 0, "started": False}
        clock, api, target = self.world(lambda seconds: self.shape_27853(seconds))

        def jobs(run_id, attempt):
            state["looks"] += 1
            found = FakeAPI.jobs(api, run_id, attempt)
            if state["started"]:
                found[-1].update(status="in_progress", runner="mini-7")
            return found
        read_run = api.run

        def run(run_id):
            if state["looks"] >= 2:  # past the failover's look and the receipt: the guard's run read
                state["started"] = True
            return read_run(run_id)
        api.jobs, api.run = jobs, run
        result, _, _ = self.run_rescue(api, clock, target)
        assert_left_at_open_head(self, api, result, number=27853)
        self.assertIn("started before the cancel", result)

    def test_nightly_dev_dispatch_and_push_targets_never_fail_over(self):
        for extra in ({"path": DEV_DAILY}, {"path": rescue.NIGHTLY_WORKFLOW_PATH, "nightly": True},
                      {"e2e": True, "path": ".github/workflows/test-ios.yml"}, {"push_branch": "feat-cmux-next"}):
            with self.subTest(**extra):
                clock, api, target = self.world(self.shape_27853, extra=extra)
                found = rescue.open_head_failover(api, target, now=clock.now, sleep=clock.sleep, log=lambda _: None)
                self.assertFalse(found)
                self.assertNotIn("cancel", api.calls)

    def test_a_watch_moves_a_dead_label_beside_a_refusal_and_a_failure_of_its_own(self):
        # A refused Mac sibling made assess() answer "refused", and the watch waited for the run to finish before the
        # failover's offer; at the deadline follow() declined the refusal path, the run having failed on its own (the
        # swift test). The offer now comes before that wait, so the stalled compile still moves.
        def shape(seconds):
            return [*self.shape_27853(seconds), refused_job("cmux-next daemon tests", labels=(SESSION,))]
        clock, api, target = self.world(shape, extra={"attempt_started_at": START})
        with unittest.mock.patch("sys.stdout", io.StringIO()):
            result = rescue.follow(api, target, seconds=30, queue_rounds="0", now=clock.now, sleep=clock.sleep,
                                   log=lambda _: None, side_seconds=30)
        self.assertIn("cancel", api.calls, (result, api.calls))
        self.assertIn(f"rerun-job:{self.COMPILE_ID}", api.calls, (result, api.calls))
        self.assertNotIn("rerun-failed", api.calls)

    def test_a_watch_moves_a_dead_label_behind_red_siblings_whatever_blacksmiths_state(self):
        # assess() leaves a run with a red job queued (leave_decided), and the destination hold kept a job queued
        # while Blacksmith was stalled; a label that runs nothing is no queue to wait in.
        stalled = {BLACKSMITH: {"queued": 39, "running": 8, "oldest_queued_minutes": 110}}
        for refusals_only in (False, True):
            with self.subTest(refusals_only=refusals_only):
                pools = {MINI: {"queued": 40, "running": 0, "oldest_queued_minutes": 110}, **stalled}
                clock, api, target = self.world(self.shape_27853, pools=pools,
                                                extra={"refusals_only": refusals_only, "attempt_started_at": START})
                with unittest.mock.patch("sys.stdout", io.StringIO()):
                    result = rescue.follow(api, target, seconds=30, queue_rounds="0", now=clock.now,
                                           sleep=clock.sleep, log=lambda _: None, side_seconds=30)
                self.assertIn("cancel", api.calls, (result, api.calls))
                self.assertIn(f"rerun-job:{self.COMPILE_ID}", api.calls, (result, api.calls))


class OpenHeadPlacementRerun(unittest.TestCase):
    """A cmux-next pull request run's open-head failover re-runs its macOS placement and the jobs that need it,
    keeping every other finished job (placement_rerun()); run 40993742146's shape (PR #27797, 2026-10-30)."""

    PLACEMENT_ID = 10

    def shape(self, *extra):
        """Run 40993742146 at 02:58Z: the Linux jobs done, `checks` red, the fast tier queued on the side label."""
        def jobs(seconds):
            return [finished("cmux-next path routing", "success"), finished("cmux-next push head preflight", "success"),
                    finished(rescue.CMUX_NEXT_PLACEMENT_JOB, "success", job_id=self.PLACEMENT_ID),
                    finished("cmux-next checks (god files, concurrency, crash safety, l10n)", "failure",
                             labels=("blacksmith-16vcpu-ubuntu-2404",)),
                    finished("pr-red-checks / comment", "success"),
                    finished("cmux-next fast tier (cargo)", "success", labels=("blacksmith-32vcpu-ubuntu-2404",)),
                    finished("cmux-next fleet Release compile", "success"),
                    finished("cmux-next Release compile (Xcode 26)", "skipped", labels=(SIDE_STD,)),
                    job("cmux-next fast tier", labels=[SIDE_STD], created=-240), *[make() for make in extra]]
        return jobs

    def world(self, jobs, *, running=0, workflow=CMUX_NEXT_FIXTURE, extra=None):
        clock = Clock()
        pools = {SIDE_STD: {"queued": 17, "running": running, "oldest_queued_minutes": 60}}
        api = FakeAPI(clock, jobs, workflow=workflow,
                      snapshot=lambda seconds: {"generated_at": stamp(seconds), "pools": pools},
                      rerun_jobs=lambda seconds: [job("cmux-next fast tier", labels=[BLACKSMITH])])
        target = rescue.Target(**{"run_id": RUN_ID, "attempt": 1, "head_sha": HEAD, "pr_number": 27797,
                                  "side": True, "path": rescue.CMUX_NEXT_WORKFLOW_PATH,
                                  "attempt_started_at": START - dt.timedelta(minutes=10), **(extra or {})})
        return clock, api, target

    def run_rescue(self, api, clock, target):
        lines = []
        with unittest.mock.patch("sys.stdout", io.StringIO()):
            result = rescue.rescue(api, target, now=clock.now, sleep=clock.sleep, log=lines.append, failed_only=True)
        return result, lines

    def test_run_40993742146_reruns_its_placement_and_keeps_its_linux_results(self):
        clock, api, target = self.world(self.shape())
        result, lines = self.run_rescue(api, clock, target)
        self.assertIn("cancel", api.calls)
        self.assertIn(f"rerun-job:{self.PLACEMENT_ID}", api.calls)
        self.assertNotIn("rerun", api.calls)  # not every job: the red checks and the cargo tier keep their results
        self.assertNotIn("rerun-failed", api.calls)  # a re-run of failed jobs would keep the old placement outputs
        self.assertIn(rescue.CMUX_NEXT_PLACEMENT_JOB, result)
        self.assertIn(f"{rescue.CANCEL_SENT} run {RUN_ID} attempt 1 of job {self.PLACEMENT_ID}", lines)
        receipt = next(line for line in lines if "receipt" in line)
        self.assertIn("cmux-next fast tier on " + SIDE_STD, receipt)
        self.assertIn("finished jobs kept: ", receipt)
        self.assertIn("cmux-next checks (god files, concurrency, crash safety, l10n)", receipt)
        self.assertIn("pr-red-checks / comment", receipt)

    def test_a_label_that_runs_a_job_keeps_the_open_head_rule(self):
        clock, api, target = self.world(self.shape(), running=1)
        result, _ = self.run_rescue(api, clock, target)
        assert_left_at_open_head(self, api, result, number=27797)

    def test_a_placement_failover_stopped_after_its_cancel_resumes_only_the_placement(self):
        # The rescue job ends (cancelled, killed, out of time) between its cancel and its re-run: its CANCEL_SENT
        # mark names the placement job, so the successor re-runs that job and the jobs that need it, never every
        # job, which would repeat the red checks and the cargo tier the failover keeps.
        clock, api, target = self.world(self.shape())

        def stopped(run_id, job_id, next_attempt):
            raise KeyboardInterrupt
        api.rerun_job = stopped
        lines = []
        with unittest.mock.patch("sys.stdout", io.StringIO()), self.assertRaises(KeyboardInterrupt):
            rescue.rescue(api, target, now=clock.now, sleep=clock.sleep, log=lines.append, failed_only=True)
        self.assertIn("cancel", api.calls)
        marks = rescue.cancel_marks(lines)
        self.assertEqual(marks, {(RUN_ID, 1): f"sent job {self.PLACEMENT_ID}"})
        del api.rerun_job
        meant = marks[(RUN_ID, 1)].removeprefix("sent job ")
        with unittest.mock.patch("sys.stdout", io.StringIO()):
            rescue.resume_rerun(api, target, now=clock.now, sleep=clock.sleep, log=lines.append, every_job=False,
                                only_job=int(meant))
        self.assertIn(f"rerun-job:{self.PLACEMENT_ID}", api.calls)
        self.assertNotIn("rerun", api.calls)
        self.assertNotIn("rerun-failed", api.calls)

    def test_a_label_that_started_nothing_since_the_job_queued_is_moved_though_a_job_runs_there(self):
        # Run 40993742146: glaeda-side-std ran one job, started before the fast tier queued, and started nothing
        # in the five hours after (the janitor's label_started).
        for started, moved in ((-600, True), (-60, False), (None, True)):
            with self.subTest(started=started):
                clock, api, target = self.world(self.shape(), running=1)
                starts = {} if started is None else {SIDE_STD: stamp(started)}

                def snapshot(seconds, starts=starts):
                    return {"generated_at": stamp(seconds), rescue.LABEL_STARTED_KEY: starts,
                            "pools": {SIDE_STD: {"queued": 17, "running": 1, "oldest_queued_minutes": 60}}}
                api.snapshot = snapshot
                result, lines = self.run_rescue(api, clock, target)
                if moved:
                    self.assertIn(f"rerun-job:{self.PLACEMENT_ID}", api.calls, result)
                    self.assertTrue(any("has started nothing since it queued" in line for line in lines), lines)
                else:
                    assert_left_at_open_head(self, api, result, number=27797)

    def test_label_quiet_needs_a_snapshot_that_covers_the_wait(self):
        since = START
        snap = {"generated_at": stamp(rescue.UNSTARTED_STALL_SECONDS - 1), rescue.LABEL_STARTED_KEY: {},
                "pools": {SIDE_STD: {"running": 1}}}
        self.assertFalse(rescue.label_quiet(snap, SIDE_STD, since))
        snap["generated_at"] = stamp(rescue.UNSTARTED_STALL_SECONDS)
        self.assertTrue(rescue.label_quiet(snap, SIDE_STD, since))
        self.assertFalse(rescue.label_quiet(snap, "glaeda-std-xcode-26.6", since), "an unlisted label proves nothing")
        self.assertFalse(rescue.label_quiet({**snap, rescue.LABEL_STARTED_KEY: None}, SIDE_STD, since),
                         "an older janitor's snapshot proves nothing")
        self.assertFalse(rescue.label_quiet(snap, SIDE_STD, None))

    def test_the_janitor_records_each_labels_newest_start(self):
        janitor = load("queue_janitor", ROOT / "scripts/ci/queue_janitor.py")
        self.assertEqual(janitor.LABEL_STARTED_KEY, rescue.LABEL_STARTED_KEY)
        run = {"id": 9, "status": "in_progress", "path": rescue.CMUX_NEXT_WORKFLOW_PATH}
        old = job("cmux app scheme compile (Debug)", labels=[SIDE_STD], status="in_progress", created=-7200,
                  runner="mini-12")
        old["started_at"] = stamp(-7000)
        newer = finished("cmux-next swift test", "success", labels=("glaeda-gui-std-xcode-26.6",), runner="mini-11")
        newer["started_at"] = stamp(-100)
        queued = job("cmux-next fast tier", labels=[SIDE_STD], created=-30)
        queued["started_at"] = stamp(-30)  # GitHub dates a queued job's start by its creation: never counted
        skipped = finished("cmux-next Swift canary", "skipped", labels=(SIDE_STD,))
        skipped["started_at"] = stamp(-5)
        linux = finished("cmux-next checks", "failure", labels=("blacksmith-16vcpu-ubuntu-2404",))
        linux["started_at"] = stamp(-5)
        snapshot = janitor.pool_load_snapshot([run], {9: [old, newer, queued, skipped, linux]}, now=START)
        self.assertEqual(snapshot[rescue.LABEL_STARTED_KEY],
                         {SIDE_STD: stamp(-7000), "glaeda-gui-std-xcode-26.6": stamp(-100)})

    def test_a_job_the_rerun_would_repeat_or_kill_keeps_the_open_head_rule(self):
        def mac_done():
            return finished("cmux-next swift test", "success", labels=("glaeda-gui-std-xcode-26.6",), runner="mini-11")

        def mac_failed():
            return finished("cmux-next swift test", "failure", labels=("glaeda-gui-std-xcode-26.6",), runner="mini-11")

        def mac_running():
            return job("cmux-next swift test", labels=["glaeda-gui-std-xcode-26.6"], status="in_progress",
                       runner="mini-11")

        def linux_running():
            return job("cmux-next web bundles (source-keyed cache)", labels=["blacksmith-32vcpu-ubuntu-2404"],
                       status="in_progress", runner="bs")

        def unknown_finished():
            return finished("a job this file does not name", "success")

        def assigned():
            queued = job("cmux-next swift test", labels=["glaeda-gui-std-xcode-26.6"])
            queued["runner_id"] = 7
            return queued

        def linux_queued():
            # A queued job outside the placement's subtree would be cancelled and never re-run.
            return job("cmux-next fleet Release compile", labels=["blacksmith-2vcpu-ubuntu-2404"])
        # A queued job outside the placement's subtree, beside the stalled one: no one re-run brings both back.
        for make in (mac_running, linux_running, assigned, linux_queued):
            with self.subTest(job=make.__name__):
                clock, api, target = self.world(self.shape(make))
                result, _ = self.run_rescue(api, clock, target)
                assert_left_at_open_head(self, api, result, number=27797)
        # A finished job the placement re-run would repeat takes the settled-sibling failover instead: nothing runs,
        # so only the waiting job is re-run and every result is kept.
        for make in (mac_done, mac_failed, unknown_finished):
            with self.subTest(job=make.__name__):
                clock, api, target = self.world(with_ids(self.shape(make)))
                result, _ = self.run_rescue(api, clock, target)
                assert_settled_failover(self, api)

    def test_without_a_placement_rerun_the_full_rerun_rule_holds(self):
        # No file at the head, a file with no placement job, a later attempt, another workflow: finished Linux jobs
        # keep the run where it is, as before.
        no_placement = CMUX_NEXT_FIXTURE.replace("macos-placement", "some-other-job")
        cases = {"no file": {"workflow": None}, "no placement job": {"workflow": no_placement},
                 "attempt 2": {"extra": {"attempt": 2}},
                 "relay-tls": {"extra": {"path": ".github/workflows/relay-tls.yml"}}}
        for name, kwargs in cases.items():
            with self.subTest(case=name):
                clock, api, target = self.world(with_ids(self.shape()), **kwargs)
                if name == "attempt 2":
                    api.attempt = 2
                    api.rerun_jobs = with_ids(self.shape())
                result, _ = self.run_rescue(api, clock, target)
                # Without a placement re-run the finished Linux jobs rule out a full re-run, and nothing runs, so
                # the settled-sibling failover re-runs only what waited.
                assert_settled_failover(self, api)

    def test_a_placement_that_did_not_succeed_gives_no_placement_rerun(self):
        for conclusion in ("failure", "cancelled"):
            jobs = self.shape()(0)
            for found in jobs:
                if found["name"] == rescue.CMUX_NEXT_PLACEMENT_JOB:
                    found["conclusion"] = conclusion
            plan, why = rescue.placement_rerun(CMUX_NEXT_FIXTURE, jobs)
            self.assertIsNone(plan, conclusion)
            self.assertIn("not succeeded", why)

    def test_the_placement_subtree_follows_needs(self):
        plan, _ = rescue.placement_rerun(CMUX_NEXT_FIXTURE, self.shape()(0))
        self.assertEqual(plan.below, {"fast-tier", "swift-test", "release-compile"})
        self.assertFalse(plan.reruns({"name": "pr-red-checks / comment"}))
        self.assertFalse(plan.reruns({"name": "cmux-next fast tier (cargo)"}))
        self.assertTrue(plan.reruns({"name": "cmux-next fast tier"}))
        self.assertTrue(plan.reruns({"name": "not in the file"}))
        self.assertFalse(rescue.failover_loses(job("cmux-next swift test", labels=["glaeda-gui-std-xcode-26.6"]),
                                               plan), "a queued job the re-run runs again loses nothing")
        checks = job("cmux-next checks (god files, concurrency, crash safety, l10n)")
        self.assertTrue(rescue.failover_loses(checks, plan), "a queued job the re-run would leave cancelled")

    def test_a_refused_placement_rerun_is_reported_not_widened(self):
        # A re-run of every job would repeat the red checks and the cargo tier the placement failover keeps.
        clock, api, target = self.world(self.shape())

        def refused(run_id, job_id, next_attempt):
            api.calls.append(f"rerun-job:{job_id}")
            raise rescue.urllib.error.HTTPError("u", 403, "cannot re-run", {}, None)
        api.rerun_job = refused
        result, lines = self.run_rescue(api, clock, target)
        self.assertEqual([call for call in api.calls if call.startswith("rerun")], [f"rerun-job:{self.PLACEMENT_ID}"])
        self.assertIn(f"GitHub refused the re-run of {rescue.CMUX_NEXT_PLACEMENT_JOB}", result)

    def test_a_job_that_queues_while_the_guard_reads_the_run_drops_the_cancel(self):
        # open_head_guard() reads the jobs after the run: a job outside the placement's subtree that queued while the
        # run read was slow (a retry, a rate limit) shows in that later read, so the cancel never leaves it behind.
        state = {"looks": 0, "queued": False}
        clock, api, target = self.world(with_ids(self.shape()))

        def jobs(run_id, attempt):
            state["looks"] += 1
            found = FakeAPI.jobs(api, run_id, attempt)
            if state["queued"]:
                late = job("pr-red-checks / comment", labels=["blacksmith-2vcpu-ubuntu-2404"])
                late["id"] = 4242
                found.append(late)
            return found
        read_run = api.run

        def run(run_id):
            if state["looks"] >= 2:  # past the failover's look and the receipt: the guard's run read
                state["queued"] = True
            return read_run(run_id)
        api.jobs, api.run = jobs, run
        result, _ = self.run_rescue(api, clock, target)
        assert_left_at_open_head(self, api, result, number=27797)
        self.assertFalse([call for call in api.calls if call.startswith("rerun-job")], api.calls)
        self.assertIn("pr-red-checks / comment", result)

    def test_a_queued_job_the_placement_rerun_may_not_bring_back_is_never_cancelled(self):
        # A stalled Mac job beside an unrelated queued job whose name maps to no workflow job, or to a job inside the
        # placement's subtree and one outside it: the placement re-run is not shown to run it again, so no cancel.
        ambiguous = CMUX_NEXT_FIXTURE + """  fast-tier-lint:
    name: cmux-next fast tier
    needs: [path_route]
    strategy: {matrix: {shard: [a]}}
    runs-on: ubuntu-latest
    steps: [{run: "true"}]
"""
        def unmatched():
            return job("a job this file does not name", labels=["blacksmith-2vcpu-ubuntu-2404"], created=-60)

        def twin():
            return job("cmux-next fast tier", labels=["blacksmith-2vcpu-ubuntu-2404"], created=-60)
        for make, workflow in ((unmatched, CMUX_NEXT_FIXTURE), (twin, ambiguous)):
            with self.subTest(job=make.__name__):
                clock, api, target = self.world(with_ids(self.shape(make)), workflow=workflow)
                result, _ = self.run_rescue(api, clock, target)
                assert_left_at_open_head(self, api, result, number=27797)
                self.assertFalse([call for call in api.calls if call.startswith("rerun-job")], api.calls)
        plan, _ = rescue.placement_rerun(ambiguous, self.shape()(0))
        self.assertTrue(plan.reruns({"name": "cmux-next fast tier"}), "a finished twin is still kept conservatively")
        self.assertFalse(plan.brings_back({"name": "cmux-next fast tier"}))
        self.assertFalse(plan.brings_back({"name": "a job this file does not name"}))
        self.assertTrue(plan.brings_back({"name": "cmux-next swift test"}))

    def test_follow_moves_a_run_left_queued_behind_a_red_job(self):
        # assess() leaves a stuck job queued once `checks` failed on its own (a full re-run would repeat it), and
        # before this the failover was never looked at: run 40993742146 waited from 02:58Z past 08:00Z.
        for running, moved in ((0, True), (1, False)):
            for refusals_only in (False, True):
                with self.subTest(running=running, refusals_only=refusals_only):
                    clock, api, target = self.world(self.shape(), running=running,
                                                    extra={"refusals_only": refusals_only})
                    with unittest.mock.patch("sys.stdout", io.StringIO()):
                        result = rescue.follow(api, target, seconds=30, queue_rounds="0", now=clock.now,
                                               sleep=clock.sleep, log=lambda _: None, side_seconds=30)
                    self.assertEqual(f"rerun-job:{self.PLACEMENT_ID}" in api.calls, moved, (result, api.calls))
                    self.assertEqual("cancel" in api.calls, moved, (result, api.calls))
                    self.assertNotIn("rerun", api.calls)
                    self.assertNotIn("rerun-failed", api.calls)

    def test_a_queued_job_is_offered_the_failover_only_every_few_minutes(self):
        clock, api, target = self.world(self.shape(), running=1)
        with unittest.mock.patch("sys.stdout", io.StringIO()):
            rescue.follow(api, target, seconds=30, queue_rounds="0", now=clock.now, sleep=clock.sleep,
                          log=lambda _: None, side_seconds=30)
        offers = api.snapshot_reads
        self.assertGreater(offers, 1)
        self.assertLessEqual(offers, target.watch_limit // rescue.FAILOVER_LOOK_SECONDS + 2)


class Budget(unittest.TestCase):
    """The cmux-bot pool's budget: conditional and shared reads, the floor, the token's refresh."""

    def serve(self, answers):
        """urlopen answering each request from `answers(request)`: (code, headers, body)."""
        seen = []

        class Response(io.BytesIO):
            def __init__(self, body, headers):
                super().__init__(body)
                self.headers = headers

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        def urlopen(request, timeout):
            seen.append((request.get_method(), request.full_url, dict(request.header_items())))
            code, headers, body = answers(request)
            if code >= 300:
                raise rescue.urllib.error.HTTPError(request.full_url, code, "no", headers, io.BytesIO(body))
            return Response(body, headers)
        return seen, unittest.mock.patch.object(rescue.urllib.request, "urlopen", urlopen)

    def test_a_repeated_read_is_conditional_and_a_304_returns_the_last_answer(self):
        def answers(request):
            if request.get_header("If-none-match") == '"e1"':
                return 304, {}, b""
            return 200, {"ETag": '"e1"'}, b'{"jobs": [{"name": "a"}]}'
        seen, patch = self.serve(answers)
        clock = [100.0]
        with patch, unittest.mock.patch.object(rescue.time, "monotonic", lambda: clock[0]):
            api = rescue.GitHub("bot", "o/r", read_token="bot")
            first = api.jobs(7, 1)
            clock[0] += 30
            second = api.jobs(7, 1)
        self.assertEqual(first, second)
        self.assertEqual(len(seen), 2)
        self.assertEqual(seen[1][2].get("If-none-match"), '"e1"')
        self.assertEqual(api.counts, {("/actions/runs/{n}/attempts/{n}/jobs", "charged"): 1,
                                      ("/actions/runs/{n}/attempts/{n}/jobs", "not modified"): 1})
        self.assertIn("1 charged", api.usage())

    def test_every_read_asks_github_even_right_after_another_watch_read_it(self):
        # A cancel or re-run decision never rests on a stored answer: the second read is conditional.
        seen, patch = self.serve(lambda request: (304, {}, b"") if request.get_header("If-none-match")
                                 else (200, {"ETag": '"x"'}, b'{"status": "queued"}'))
        with patch:
            api = rescue.GitHub("bot", "o/r")
            self.assertEqual(api.run(9), api.run(9))
        self.assertEqual(len(seen), 2)
        self.assertEqual(api.counts[("/actions/runs/{n}", "not modified")], 1)

    def test_each_answer_keeps_the_budget_current_between_rate_limit_reads(self):
        now = 1_000_000.0
        reads = []

        def answers(request):
            reads.append(request.full_url)
            if request.full_url.endswith("/rate_limit"):
                return 200, {}, json.dumps({"resources": {"core": {"remaining": 4000, "reset": now + 600}}}).encode()
            return 200, {"X-RateLimit-Remaining": "50", "X-RateLimit-Reset": str(now + 600)}, b"{}"
        seen, patch = self.serve(answers)
        with patch, unittest.mock.patch.object(rescue.time, "time", lambda: now):
            api = rescue.GitHub("bot", "o/r")
            self.assertEqual(api.pace(20), 20)
            api.run(1)
            self.assertEqual(api.pace(20), 605)
        self.assertEqual(sum(url.endswith("/rate_limit") for url in reads), 1)

    def test_the_budget_takes_the_lowest_reading_of_a_window_and_only_the_read_tokens(self):
        api = rescue.GitHub("repo", "o/r", read_token="bot")
        api._note_budget({"X-RateLimit-Remaining": "50", "X-RateLimit-Reset": "900"}, 0)
        api._note_budget({"X-RateLimit-Remaining": "70", "X-RateLimit-Reset": "900"}, 0)  # older, out of order
        self.assertEqual(api._budget[1:], (50, 900.0))
        api._note_budget({"X-RateLimit-Remaining": "4999", "X-RateLimit-Reset": "4500"}, 0)  # the next window
        self.assertEqual(api._budget[1:], (4999, 4500.0))
        seen, patch = self.serve(lambda request: (200, {"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "9000"}, b""))
        with patch:
            api.cancel(1)  # GITHUB_TOKEN's own pool says nothing about the App's
        self.assertEqual(api._budget[1:], (4999, 4500.0))

    def test_an_answer_from_a_pool_the_reads_have_left_is_not_counted(self):
        # A read sent on the App's pool whose answer arrives after another thread fell back to GITHUB_TOKEN.
        api = rescue.GitHub("repo", "o/r", read_token="app")

        def answers(request):
            with api._lock:  # the other thread's 401 fallback, while this answer is in flight
                api.read_headers = api.headers
                api._budget = (-1e9, None, None)
                api._pool += 1
            return 200, {"X-RateLimit-Remaining": "5", "X-RateLimit-Reset": "9000"}, b"{}"
        seen, patch = self.serve(answers)
        with patch:
            api.run(1)
        self.assertEqual(api._budget[1:], (None, None))

    def test_a_304_keeps_the_budget_current(self):
        seen, patch = self.serve(lambda request: (304, {"X-RateLimit-Remaining": "40", "X-RateLimit-Reset": "900"}, b"")
                                 if request.get_header("If-none-match")
                                 else (200, {"ETag": '"x"', "X-RateLimit-Remaining": "41", "X-RateLimit-Reset": "900"}, b"{}"))
        with patch:
            api = rescue.GitHub("bot", "o/r")
            api.run(1)
            api.run(1)
        self.assertEqual(api._budget[1], 40)

    def test_a_write_refused_for_an_expired_token_is_checked_again_before_it_is_resent(self):
        def answers(request):
            return (401, {}, b"") if request.get_header("Authorization") == "Bearer old" else (200, {}, b"")
        seen, patch = self.serve(answers)
        checks = []
        with patch, unittest.mock.patch("sys.stdout", io.StringIO()):
            api = rescue.GitHub("old", "o/r")
            api.mint = lambda: "new"
            api.request("POST", "/actions/runs/1/rerun", before_retry=lambda: checks.append(1))
        self.assertEqual(checks, [1])
        self.assertEqual(len(seen), 2)

    def test_falling_back_to_github_token_forgets_the_apps_budget(self):
        def answers(request):
            if request.get_header("Authorization") == "Bearer app":
                return 401, {}, b""
            return 200, {"X-RateLimit-Remaining": "900", "X-RateLimit-Reset": "100"}, b"{}"
        seen, patch = self.serve(answers)
        with patch:
            api = rescue.GitHub("repo", "o/r", read_token="app")
            api._note_budget({"X-RateLimit-Remaining": "50", "X-RateLimit-Reset": "900"}, 0)
            api.run(1)
        self.assertEqual(api._budget[1:], (900, 100.0))

    def test_waiting_for_a_refused_shards_siblings_is_paced_too(self):
        def jobs(seconds):
            sibling = job("macos / app-host unit tests (1/7)", labels=[MINI], created=40, runner="mini-2",
                          status="in_progress")
            sibling["started_at"] = stamp(41)
            return [changes()(seconds), refused_job("macos / app-host unit tests (2/7)"), sibling]
        clock = Clock()
        api = FakeAPI(clock, jobs, marker=True)
        paced = []
        api.pace = lambda interval: paced.append(interval) or 3600.0
        rescue.watch(api, rescue.target_from_event(event(), "manaflow-ai/cmux"), budget_seconds=90, now=clock.now,
                     sleep=clock.sleep, log=lambda text: None, deadline=START + dt.timedelta(seconds=900))
        self.assertTrue(paced)
        self.assertLessEqual(api.calls.count("jobs"), 4)

    def test_a_different_read_tokens_401_mints_nothing_and_falls_back_as_before(self):
        def answers(request):
            return (401, {}, b"") if request.get_header("Authorization") == "Bearer route" else (200, {}, b"{}")
        seen, patch = self.serve(answers)
        minted = []
        with patch:
            api = rescue.GitHub("bot", "o/r", read_token="route")
            api.mint = lambda: minted.append(1) or "new"
            api.run(1)
        self.assertEqual(minted, [])
        self.assertEqual([headers["Authorization"] for _, _, headers in seen], ["Bearer route", "Bearer bot"])

    def test_concurrent_401s_mint_one_token(self):
        def answers(request):
            return (401, {}, b"") if request.get_header("Authorization") == "Bearer old" else (200, {}, b"{}")
        seen, patch = self.serve(answers)
        minted = []
        with patch, unittest.mock.patch("sys.stdout", io.StringIO()):
            api = rescue.GitHub("old", "o/r", read_token="old")
            api.mint = lambda: minted.append(1) or f"new{len(minted)}"
            api._fresh_token(stale="Bearer old")  # a second thread's refusal, already handled
            api._fresh_token(stale="Bearer old")
            api.run(1)
        self.assertEqual(minted, [1])
        self.assertEqual([headers["Authorization"] for _, _, headers in seen], ["Bearer new1"])

    def test_writes_are_never_cached(self):
        seen, patch = self.serve(lambda request: (200, {"ETag": '"x"'}, b""))
        with patch:
            api = rescue.GitHub("bot", "o/r")
            api.cancel(1)
            api.cancel(1)
        self.assertEqual(len(seen), 2)
        self.assertTrue(all("If-none-match" not in headers for _, _, headers in seen))

    def budget_api(self, remaining, reset_in=600.0):
        now = 1_000_000.0
        body = json.dumps({"resources": {"core": {"remaining": remaining, "reset": now + reset_in}}}).encode()
        seen, patch = self.serve(lambda request: (200, {}, body))
        return seen, patch, now

    def test_the_floor_slows_the_looks_and_a_spent_budget_waits_for_its_reset(self):
        for remaining, expected in ((4000, 20), (rescue.BUDGET_FLOOR - 1, rescue.IDLE_POLL_SECONDS),
                                    (rescue.BUDGET_RESERVE - 1, 605)):
            with self.subTest(remaining=remaining):
                seen, patch, now = self.budget_api(remaining)
                with patch, unittest.mock.patch.object(rescue.time, "time", lambda: now):
                    api = rescue.GitHub("bot", "o/r")
                    self.assertEqual(api.pace(20), expected)
                    api.pace(20)  # read once per BUDGET_READ_SECONDS
                self.assertEqual([url for _, url, _ in seen], [f"{rescue.API}/rate_limit"])

    def test_an_unreadable_budget_never_slows_the_watch(self):
        seen, patch = self.serve(lambda request: (500, {}, b"{}"))
        with patch, unittest.mock.patch("sys.stdout", io.StringIO()):
            self.assertEqual(rescue.GitHub("bot", "o/r").pace(20), 20)

    def test_a_watch_on_a_low_budget_looks_less_often_but_still_at_its_deadline(self):
        clock = Clock()
        api = FakeAPI(clock, lambda seconds: [job(rescue.PICKER_JOB, status="in_progress")])
        api.pace = lambda interval: 3600.0  # spent, an hour to the reset
        outcome = rescue.watch(api, rescue.target_from_event(event(), "manaflow-ai/cmux"), budget_seconds=90, now=clock.now, sleep=clock.sleep,
                               log=lambda text: None, deadline=START + dt.timedelta(seconds=600))
        self.assertEqual(outcome, ("stop", "watch limit reached"))
        # The first look, then one at the deadline: not a look every IDLE_POLL_SECONDS.
        self.assertEqual(api.calls.count("jobs"), 2)

    def test_the_sweeper_lists_failed_side_lane_runs_only_above_the_floor(self):
        for remaining, listings in ((rescue.BUDGET_FLOOR, 1), (rescue.BUDGET_FLOOR - 1, 0)):
            with self.subTest(remaining=remaining):
                api = SweepAPI([])
                api.budget_left = lambda: (remaining, None)
                api.pace = lambda interval: interval
                clock = Clock()
                with unittest.mock.patch.object(rescue, "follow", lambda *a, **k: "stopped"):
                    rescue.sweep(api, "manaflow-ai/cmux", seconds=90, queue_rounds="0", now=clock.now,
                                 log=lambda text: None, sweep_seconds=3 * 60, tick_seconds=60, wait=clock.sleep)
                self.assertEqual(api.failed_listings, listings)

    def test_a_spent_budget_holds_the_sweeper_tick_until_the_reset_within_the_sweep(self):
        api = SweepAPI([])
        api.budget_left = lambda: (0, None)
        api.pace = lambda interval: 1800.0
        clock, waits = Clock(), []

        def wait(seconds):
            waits.append(seconds)
            clock.sleep(seconds)
        with unittest.mock.patch.object(rescue, "follow", lambda *a, **k: "stopped"):
            rescue.sweep(api, "manaflow-ai/cmux", seconds=90, queue_rounds="0", now=clock.now,
                         log=lambda text: None, sweep_seconds=3600, tick_seconds=60, wait=wait)
        self.assertEqual(waits, [1800.0, 1800.0])

    def test_the_token_is_minted_again_before_its_hour_is_up_for_reads_and_writes(self):
        seen, patch = self.serve(lambda request: (200, {}, b"{}"))
        clock = [0.0]
        with patch, unittest.mock.patch.object(rescue.time, "monotonic", lambda: clock[0]), \
                unittest.mock.patch("sys.stdout", io.StringIO()):
            api = rescue.GitHub("old", "o/r", read_token="old")
            api.mint = lambda: "new"
            api.run(1)
            clock[0] += rescue.TOKEN_REFRESH_SECONDS
            api.run(2)
            api.cancel(2)
        self.assertEqual([headers["Authorization"] for _, _, headers in seen],
                         ["Bearer old", "Bearer new", "Bearer new"])

    def test_a_401_mints_a_token_and_sends_the_read_again_once(self):
        def answers(request):
            return (401, {}, b"") if request.get_header("Authorization") == "Bearer old" else (200, {}, b"{}")
        seen, patch = self.serve(answers)
        with patch, unittest.mock.patch("sys.stdout", io.StringIO()):
            api = rescue.GitHub("old", "o/r", read_token="old")
            api.mint = lambda: "new"
            api.run(1)
        self.assertEqual([headers["Authorization"] for _, _, headers in seen], ["Bearer old", "Bearer new"])

    def test_the_app_jwt_is_signed_by_openssl_from_a_key_file_never_on_argv(self):
        calls = []

        def run(argv, **kwargs):
            calls.append((argv, kwargs["input"], Path(argv[-1]).read_text()))
            return unittest.mock.Mock(stdout=b"sig")
        token = rescue.app_jwt("5486910", "PEM KEY", now=1000, run=run)
        head, claims, signature = token.split(".")
        self.assertEqual(json.loads(rescue.base64.urlsafe_b64decode(claims + "==")),
                         {"iat": 940, "exp": 1540, "iss": 5486910})
        self.assertEqual(signature, rescue._b64(b"sig"))
        argv, signed, key = calls[0]
        self.assertEqual(argv[:4], ["openssl", "dgst", "-sha256", "-sign"])
        self.assertEqual((signed, key), (f"{head}.{claims}".encode(), "PEM KEY"))
        self.assertNotIn("PEM KEY", " ".join(argv))
        self.assertFalse(Path(argv[-1]).exists())

    def test_the_workflow_passes_the_app_key_only_when_the_cmux_bot_mint_worked(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/ci-owned-pool-rescue.yml").read_text())
        steps = workflow["jobs"]["rescue"]["steps"]
        watch = next(step for step in steps if step.get("run") == "python3 scripts/ci/owned_pool_rescue.py")
        self.assertEqual(watch["env"]["BOT_APP_KEY"],
                         "${{ steps.cmux-bot-token.outputs.token && secrets.CMUX_BOT_APP_KEY || '' }}")
        self.assertEqual(watch["env"]["BOT_APP_ID"],
                         "${{ steps.cmux-bot-token.outputs.token && vars.CMUX_BOT_APP_ID || '' }}")
        mint = next(step for step in steps if step.get("id") == "cmux-bot-token")
        self.assertEqual({key.removeprefix("permission-").replace("-", "_"): value
                          for key, value in mint["with"].items() if key.startswith("permission-")},
                         rescue.BOT_PERMISSIONS)


class SnapshotToken(unittest.TestCase):
    """The janitor snapshot reads send the client's current token (GitHub.snapshot_token())."""

    def test_snapshot_reads_follow_the_minted_token(self):
        # Run 41006853342 (2026-10-30): its sweeper minted new tokens at 05:55Z and 06:40Z, but read every
        # snapshot with the token it started with, refused (401) from 06:12Z on.
        clock = [0.0]
        tokens = []

        class Reader:
            def __init__(self, token, repo):
                tokens.append(token)

            def snapshot(self, *, now):
                return {"generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "pools": {MINI: {"running": 0}}}
        with unittest.mock.patch.object(rescue.time, "monotonic", lambda: clock[0]), \
                unittest.mock.patch.object(rescue.pr_runner_pool, "GitHub", Reader), \
                unittest.mock.patch("sys.stdout", io.StringIO()):
            api = rescue.GitHub("old", "o/r", read_token="old")
            api.mint = lambda: "new"
            self.assertTrue(api.pool_snapshot(START))
            clock[0] += rescue.TOKEN_REFRESH_SECONDS
            self.assertTrue(api.pool_snapshot(START))
        self.assertEqual(tokens, ["old", "new"])

    def test_one_read_serves_every_watch_for_a_minute(self):
        clock = [0.0]
        reads = []

        class Reader:
            def __init__(self, token, repo):
                pass

            def snapshot(self, *, now):
                reads.append(now)
                return {"generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "pools": {MINI: {"running": 0}}}
        with unittest.mock.patch.object(rescue.time, "monotonic", lambda: clock[0]), \
                unittest.mock.patch.object(rescue.pr_runner_pool, "GitHub", Reader):
            api = rescue.GitHub("tok", "o/r")
            api.pool_snapshot(START)
            clock[0] += rescue.SNAPSHOT_CACHE_SECONDS - 1
            api.pool_snapshot(START)
            self.assertEqual(len(reads), 1)
            clock[0] += 2
            api.pool_snapshot(START)
        self.assertEqual(len(reads), 2)

    def test_another_apps_read_token_gives_way_to_the_minted_one(self):
        with unittest.mock.patch("sys.stdout", io.StringIO()):
            api = rescue.GitHub("bot", "o/r", read_token="route-app")
            self.assertEqual(api.snapshot_token(), "route-app")  # nothing minted: the read token, as before
            api.mint = lambda: "bot2"
            self.assertEqual(api.snapshot_token(), "bot")


class SpendLess(unittest.TestCase):
    """The cmux-bot budget: repeatable listing URLs, immutable reads read once, the capped rescue history, a spent budget."""


    def test_moving_listing_bounds_ask_the_same_url(self):
        asked = []
        api = rescue.GitHub("bot", "o/r")
        oldest = START + dt.timedelta(minutes=7)
        listed = [{"id": 1, "run_attempt": 1, "path": ".github/workflows/cmux-next.yml", "event": "push",
                   "created_at": stamp(480), "updated_at": stamp(9000)},
                  # Let in by the rounded bound only: older than `oldest`, so dropped.
                  {"id": 2, "run_attempt": 1, "path": ".github/workflows/cmux-next.yml", "event": "push",
                   "created_at": stamp(60), "updated_at": stamp(9000)}]
        side = next(iter(rescue.SIDE_WORKFLOW_PATHS))
        for run in listed:
            run["path"] = side

        def request(method, path, **_):
            asked.append(path)
            return {"workflow_runs": listed if "status=failure" in path and "page=1&" in path else []}
        api.request = request
        with unittest.mock.patch.object(rescue, "never_fails_over", lambda path, event: False):
            first = api.failed_runs(100, oldest)
            api.failed_runs(100, oldest + dt.timedelta(minutes=3))
        self.assertEqual(first, [(1, 1)])
        self.assertEqual(asked[0], asked[2], "a bound that moved by minutes asks the same URL, so a 304 can answer")
        self.assertIn(f"created=%3E%3D{rescue.created_floor(oldest):%Y-%m-%dT%H:%M:%SZ}", asked[0])
        self.assertLessEqual(rescue.created_floor(oldest), oldest)

    def test_a_finished_jobs_annotations_are_read_once(self):
        api = rescue.GitHub("bot", "o/r")
        asked = []

        def request(method, path, **_):
            asked.append(path)
            return [{"message": "The run was canceled by @someone."}]
        api.request = request
        jobs = [{"id": 5, "status": "completed", "conclusion": "cancelled"}]
        for _ in range(3):
            self.assertEqual(rescue.canceller(api, jobs, lambda seconds: None, lambda text: None), "someone")
        self.assertEqual(asked, ["/check-runs/5/annotations?per_page=100&page=1"])
        api.annotations(6)
        api.annotations(6)
        self.assertEqual(len(asked), 3, "a job not known to be finished is read every time")

    def test_a_finished_rescue_runs_jobs_are_listed_once(self):
        api = rescue.GitHub("bot", "o/r")
        asked = []
        runs = {"workflow_runs": [
            {"id": 1, "status": "completed", "conclusion": "success", "run_attempt": 2,
             "run_started_at": stamp(-600), "updated_at": stamp(60)},
            {"id": 3, "status": "in_progress", "conclusion": None, "run_attempt": 1, "display_title": "other",
             "run_started_at": stamp(-600), "updated_at": stamp(60)}]}

        def request(method, path, **_):
            asked.append(path)
            if path.startswith("/actions/workflows/"):
                return runs if "&page=1&" in path else {}
            return {"jobs": [{"id": int(path.split("/")[3]) * 10, "status": "completed", "conclusion": "success"}]}
        api.request = request
        for _ in range(2):
            self.assertEqual(api.rescue_jobs(START), [10, 10, 30])
        jobs = [path for path in asked if not path.startswith("/actions/workflows/")]
        self.assertEqual(jobs, ["/actions/runs/1/attempts/2/jobs?per_page=20", "/actions/runs/1/attempts/1/jobs?per_page=20",
                                "/actions/runs/3/attempts/1/jobs?per_page=20", "/actions/runs/3/attempts/1/jobs?per_page=20"])

    def spent_refusal(self):
        reset = str(int(rescue.time.time()) + 3000)
        return (403, {"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": reset},
                b'{"message": "API rate limit exceeded for installation."}')

    def test_a_spent_budget_far_from_its_reset_ends_a_single_watchs_read(self):
        seen, patch = Tokens.refusing(self, [self.spent_refusal()])
        waits = []
        with patch, unittest.mock.patch("sys.stderr", io.StringIO()):
            api = rescue.GitHub("repo-token", "o/r")
            api.sleep = waits.append
            api.end_on_spent = True
            with self.assertRaises(rescue.QuotaSpent) as raised:
                api.run(7)
        self.assertEqual((len(seen), waits), (1, []))
        self.assertIsInstance(raised.exception, rescue.urllib.error.HTTPError, "still a failed read to its callers")
        self.assertIn("resets in", rescue.quota_skip(raised.exception))
        self.assertIsNone(rescue.quota_skip(RuntimeError("x")))

    def test_a_write_and_every_read_after_it_still_wait_through_a_spent_budget(self):
        # A rescue that cancelled a run must still get to its re-run (review on #28844): nothing after a write ends
        # the watch early, and neither does the write itself.
        for calls in (("cancel",), ("cancel", "run")):
            with self.subTest(calls=calls):
                seen, patch = Tokens.refusing(self, [self.spent_refusal()])
                waits = []
                with patch, unittest.mock.patch("sys.stderr", io.StringIO()):
                    api = rescue.GitHub("repo-token", "o/r")
                    api.sleep = waits.append
                    api.end_on_spent = True
                    if calls == ("cancel", "run"):
                        api._limits.wrote = True  # a cancel this thread already sent
                        api.run(7)
                    else:
                        api.cancel(7)
                self.assertEqual(len(seen), 2)
                self.assertEqual(len(waits), 1)
                self.assertFalse(api.may_end_on_spent())

    def test_the_sweeper_and_a_nightlys_watch_still_wait(self):
        seen, patch = Tokens.refusing(self, [self.spent_refusal()])
        waits = []
        with patch, unittest.mock.patch("sys.stderr", io.StringIO()):
            api = rescue.GitHub("repo-token", "o/r")
            api.sleep = waits.append
            api.run(7)  # end_on_spent is off
        self.assertEqual((len(seen), len(waits)), (2, 1))

    def test_a_single_watch_ends_instead_of_pacing_through_a_far_reset(self):
        now = 1_000_000.0
        api = rescue.GitHub("bot", "o/r")
        api._budget = (rescue.time.monotonic(), 3, now + 3000)
        with unittest.mock.patch.object(rescue.time, "time", lambda: now):
            self.assertEqual(api.pace(20), 3005, "the sweeper (and a nightly's watch) still waits")
            api.end_on_spent = True
            with self.assertRaises(rescue.QuotaSpent):
                api.pace(20)
            api._limits.wrote = True
            self.assertEqual(api.pace(20), 3005, "a watch that has cancelled a run waits for its re-run")
            api._limits.wrote = False
            api._budget = (rescue.time.monotonic(), 3, now + 300)
            self.assertEqual(api.pace(20), 305, "a reset within the wait allowance is still waited for")

    def test_a_watch_out_of_budget_ends_green_with_a_warning(self):
        class SpentAPI(FakeAPI):
            def jobs(self, run_id, attempt):
                raise rescue.QuotaSpent(rescue.urllib.error.HTTPError("u", 403, "no", {}, None), "",
                                        "the API budget is spent")
        clock = Clock()
        api = SpentAPI(clock, persistent_run())
        api.end_on_spent = False
        code, summary = run_main(api, clock)
        self.assertEqual(code, 0, summary)
        self.assertIn("::warning title=GitHub API budget::infra skip: the API budget is spent", summary)
        self.assertTrue(api.end_on_spent, "a pull request's watch does not wait through the reset")
        nightly = SpentAPI(clock, persistent_run())
        nightly.end_on_spent = True
        code, summary = run_main(nightly, clock, payload=event(path=".github/workflows/nightly.yml", event="push",
                                                               head_branch="main"))
        self.assertFalse(nightly.end_on_spent, "a nightly's watch waits for the reset")
        self.assertEqual(code, 0, summary)
        self.assertIn("the nightly-next tick re-runs it", summary)

    def test_any_other_failed_watch_is_still_red(self):
        class BrokenAPI(FakeAPI):
            def jobs(self, run_id, attempt):
                raise rescue.urllib.error.URLError("down")
        clock = Clock()
        code, summary = run_main(BrokenAPI(clock, persistent_run()), clock)
        self.assertEqual(code, 1)
        self.assertIn("gave up", summary)

    def test_a_rescue_history_github_counts_past_the_cap_costs_one_page(self):
        api = rescue.GitHub("bot", "o/r")
        asked = []

        def request(method, path, **_):
            asked.append(path)
            return {"total_count": 100 * rescue.RESCUE_RUN_PAGES + 1, "workflow_runs": [
                {"id": index, "status": "completed", "conclusion": "skipped", "run_attempt": 1} for index in range(100)]}
        api.request = request
        with self.assertRaises(rescue.RescueHistoryCapped):
            api.rescue_jobs(START)
        self.assertEqual(len(asked), 1)

    def test_a_rescue_history_within_the_cap_is_read_to_its_end(self):
        api = rescue.GitHub("bot", "o/r")
        asked = []

        def request(method, path, **_):
            asked.append(path)
            if "&page=1&" in path:
                return {"total_count": 100 * rescue.RESCUE_RUN_PAGES, "workflow_runs": [
                    {"id": index, "status": "completed", "conclusion": "skipped", "run_attempt": 1}
                    for index in range(100)]}
            return {"total_count": 100 * rescue.RESCUE_RUN_PAGES, "workflow_runs": []}
        api.request = request
        self.assertEqual(api.rescue_jobs(START), [])
        self.assertEqual(len(asked), 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
