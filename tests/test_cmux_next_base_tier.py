#!/usr/bin/env python3
"""feat-cmux-next's base Mac tier runs at most once every 15 minutes, on the tip (cmuxterm-hq#5424).

Leo (2026-10-30): "do we REALLY need to be compiling/testing THAT often...?" A feat-cmux-next push ran
daemon tests, generated files and the Debug app scheme compile on every landing (557 a day, a median
1.4 minutes apart). A push now leaves those three to `cmux-next base tier · <tip>`, which
cmux-next-base-tier-kick.yml dispatches at most once per window (scripts/ci/cmux_next_base_tier.py).
The Release compiles, the DEV landing compile and the fast tier stay on every push.
"""

from __future__ import annotations

import io
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import cmux_next_base_tier as tier  # noqa: E402
import cmux_next_tree_notify as notify  # noqa: E402
import github_quota_client as quota  # noqa: E402
import deadline_http  # noqa: E402

WORKFLOW = ROOT / ".github/workflows/cmux-next.yml"
KICK = ROOT / ".github/workflows/cmux-next-base-tier-kick.yml"
REPO = "manaflow-ai/cmux"
OLD, MID, TIP = "a" * 40, "b" * 40, "c" * 40
T0 = 1_800_000_000.0


def stamp(at: float) -> str:
    import datetime as dt
    return dt.datetime.fromtimestamp(at, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class FakeApi:
    def __init__(self, runs: list[tuple[str, float]], tip: str, files: list[str] | None = None,
                 compare_error: bool = False, dispatch_status: int = 204):
        self.runs = [{"display_title": f"{tier.TITLE}{sha}", "created_at": stamp(at)} for sha, at in runs]
        self.runs.append({"display_title": f"cmux NEXT DEV daily · {OLD}", "created_at": stamp(T0)})
        self.tip = tip
        self.files = files if files is not None else ["Packages/macOS/CmuxNext/Sources/CmuxNextApp/App.swift"]
        self.compare_error = compare_error
        self.dispatch_status = dispatch_status
        self.dispatched: list[tuple[str, dict]] = []
        self.cancelled: list[int] = []
        self.landed: str | None = None  # a commit that lands between the tip read and the dispatch
        self.jobs: dict[int, list[dict]] = {}
        self.gets: list[str] = []
        self.covering: set[str] = set()  # base tier run shas whose commit contains the tip (compare: behind)
        self.listed_late = False  # GitHub lists a dispatched run only after a while: the listing misses it
        self.during_dispatch = lambda: None  # a slow dispatch POST: the time GitHub takes to answer it

    def open_run(self, run_id: int, sha: str, at: float, status: str = "queued",
                 jobs: list[dict] | None = None, title: str = tier.TITLE) -> None:
        """A listed run with an id and a status, and its jobs (None: its job list cannot be read)."""
        self.runs.insert(0, {"id": run_id, "status": status, "display_title": f"{title}{sha}",
                             "created_at": stamp(at)})
        if jobs is not None:
            self.jobs[run_id] = jobs

    def get(self, path: str):
        self.gets.append(path)
        if "/actions/workflows/cmux-next.yml/runs?" in path:
            return {"workflow_runs": self.runs}
        if (match := re.search(r"/actions/runs/(\d+)/jobs\?", path)):
            jobs = self.jobs.get(int(match.group(1)))
            if jobs is None:
                raise RuntimeError("HTTP 502")
            return {"jobs": jobs}
        if path.endswith(f"/git/ref/heads/{tier.BRANCH}"):
            return {"object": {"sha": self.tip}}
        if "/compare/" in path:
            if self.compare_error:
                raise RuntimeError("HTTP 502")
            if path.split("/compare/")[1].split("...")[0] in self.covering:
                return {"status": "behind", "files": []}
            return {"status": "ahead", "files": [{"filename": name} for name in self.files]}
        raise AssertionError(path)

    def post(self, path: str, body: dict) -> int:
        if (match := re.fullmatch(rf"repos/{REPO}/actions/runs/(\d+)/cancel", path)):
            self.cancelled.append(int(match.group(1)))
            return 202
        self.dispatched.append((path, body))
        self.during_dispatch()
        if self.dispatch_status == 204 and not self.listed_late:
            # The run the dispatch starts, titled with the branch tip when GitHub took it.
            self.runs.insert(0, {"id": 99, "status": "queued", "display_title": f"{tier.TITLE}{self.landed or self.tip}",
                                 "created_at": stamp(T0 + 10**6)})
        return self.dispatch_status


class Clock:
    def __init__(self, at: float):
        self.at = at
        self.slept: list[float] = []
        self.during_wait = lambda: None  # landings or dispatches that happen while a kick waits

    def now(self) -> float:
        return self.at

    def sleep(self, seconds: float) -> None:
        self.slept.append(seconds)
        self.at += seconds
        self.during_wait()


def kick(api: FakeApi, clock: Clock, patterns: list[str] | None = None):
    patterns = tier.push_paths(WORKFLOW.read_text()) if patterns is None else patterns
    return tier.kick(api, REPO, patterns, now=clock.now, sleep=clock.sleep, log=lambda _: None)


def job(name: str, status: str, conclusion: str | None = None) -> dict:
    return {"name": name, "status": status, "conclusion": conclusion}


QUEUED_MAC = [job("cmux-next path routing", "completed", "success"), job("cmux-next daemon tests", "queued"),
              job("cmux-next generated files", "queued"), job("cmux app scheme compile (Debug)", "queued")]


class CancelSuperseded(unittest.TestCase):
    """Once the tip has a base tier run, older ones whose Mac jobs never started are cancelled."""

    def test_a_dispatch_cancels_older_runs_waiting_for_a_mac(self):
        api, clock = FakeApi([(OLD, T0)], TIP), Clock(T0 + 20 * 60)
        api.open_run(11, OLD, T0, "in_progress", QUEUED_MAC)
        api.open_run(12, MID, T0 + 5 * 60, "queued", [])
        self.assertEqual(kick(api, clock), TIP)
        self.assertEqual(len(api.dispatched), 1)
        self.assertEqual(sorted(api.cancelled), [11, 12])

    def test_a_run_titled_with_a_commit_that_landed_after_the_tip_read_is_kept(self):
        # The dispatch takes the branch ref, so its run may name a newer commit than the tip read.
        api, clock = FakeApi([(OLD, T0)], TIP), Clock(T0 + 20 * 60)
        api.landed = "d" * 40
        api.jobs[99] = QUEUED_MAC
        api.open_run(11, OLD, T0, "queued", QUEUED_MAC)
        self.assertEqual(kick(api, clock), TIP)
        self.assertEqual(api.cancelled, [11])

    def test_a_re_run_is_left_alone(self):
        # An earlier attempt may have run its Mac jobs; the latest attempt's list would not show them.
        api, clock = FakeApi([(OLD, T0)], TIP), Clock(T0 + 20 * 60)
        api.open_run(11, OLD, T0, "queued", QUEUED_MAC)
        api.runs[0]["run_attempt"] = 2
        kick(api, clock)
        self.assertEqual(api.cancelled, [])

    def test_a_tip_that_already_has_a_run_still_cancels_the_older_waiting_ones(self):
        # A hand dispatch on the tip leaves the older waiting runs to the next kick.
        api, clock = FakeApi([(TIP, T0)], TIP), Clock(T0 + 20 * 60)
        api.open_run(11, OLD, T0 - 60, "queued", QUEUED_MAC)
        self.assertIsNone(kick(api, clock))
        self.assertEqual(api.dispatched, [])
        self.assertEqual(api.cancelled, [11])

    def test_a_run_whose_mac_job_started_or_finished_is_left_alone(self):
        api, clock = FakeApi([(OLD, T0)], TIP), Clock(T0 + 20 * 60)
        running = [job("cmux-next daemon tests", "in_progress")] + QUEUED_MAC[2:]
        finished = [job("cmux-next generated files", "completed", "failure"), job("cmux-next daemon tests", "queued")]
        api.open_run(11, OLD, T0, "in_progress", running)
        api.open_run(12, MID, T0 + 60, "in_progress", finished)
        kick(api, clock)
        self.assertEqual(api.cancelled, [])

    def test_skipped_or_cancelled_mac_jobs_never_started(self):
        api, clock = FakeApi([(OLD, T0)], TIP), Clock(T0 + 20 * 60)
        api.open_run(11, OLD, T0, "in_progress", [job("cmux app scheme compile (Debug)", "completed", "skipped"),
                                                   job("cmux-next daemon tests", "completed", "cancelled"),
                                                   job("cmux-next generated files", "queued")])
        kick(api, clock)
        self.assertEqual(api.cancelled, [11])

    def test_an_unreadable_job_list_counts_as_started(self):
        api, clock = FakeApi([(OLD, T0)], TIP), Clock(T0 + 20 * 60)
        api.open_run(11, OLD, T0, "queued", None)
        kick(api, clock)
        self.assertEqual(api.cancelled, [])

    def test_the_tips_own_runs_finished_runs_and_other_titles_are_never_cancelled(self):
        api, clock = FakeApi([(TIP, T0)], TIP), Clock(T0 + 20 * 60)
        api.open_run(11, TIP, T0 + 60, "queued", QUEUED_MAC)  # the tip's same-tree run
        api.open_run(12, OLD, T0 - 60, "completed", QUEUED_MAC)
        api.open_run(13, OLD, T0 - 60, "queued", QUEUED_MAC, title="cmux NEXT DEV daily · ")
        api.open_run(14, OLD, T0 - 60, "queued", QUEUED_MAC, title="cmux-next tip daemon suite · ")
        kick(api, clock)
        self.assertEqual(api.cancelled, [])

    def test_no_dispatch_cancels_nothing(self):
        # Not due (no cmux-next push path changed): the last run is the newest verdict and stays.
        api = FakeApi([(OLD, T0)], TIP, files=["README.md"])
        api.open_run(11, OLD, T0, "queued", QUEUED_MAC)
        self.assertIsNone(kick(api, Clock(T0 + 20 * 60)))
        self.assertEqual(api.cancelled, [])

    def test_mac_jobs_are_the_base_tier_jobs_of_cmux_next(self):
        jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
        names = {jobs["daemon-test"]["name"], jobs["generated-files"]["name"]}
        self.assertEqual(names | {"cmux app scheme compile (Debug)"}, set(tier.MAC_JOBS))
        # The scheme compile's name outside the DEV daily (the base tier is never a DEV daily).
        self.assertIn("|| 'cmux app scheme compile (Debug)' }}", jobs["cmux-scheme-compile"]["name"])


class Kick(unittest.TestCase):
    def test_a_landing_with_the_window_open_is_dispatched_at_once(self):
        api, clock = FakeApi([(OLD, T0)], TIP), Clock(T0 + 20 * 60)
        self.assertEqual(kick(api, clock), TIP)
        [(path, body)] = api.dispatched
        self.assertEqual(path, f"repos/{REPO}/actions/workflows/cmux-next.yml/dispatches")
        self.assertEqual(body, {"ref": "refs/heads/feat-cmux-next", "inputs": {"base_tier": "true"}})
        # No wait before the dispatch; only the settle after it, so the next kick lists the new run.
        self.assertEqual(clock.slept, [tier.SETTLE_S])

    def test_a_landing_inside_the_window_waits_once_and_takes_the_tip_then(self):
        api, clock = FakeApi([(OLD, T0)], MID), Clock(T0 + 5 * 60)

        clock.during_wait = lambda: setattr(api, "tip", TIP)  # landings during the wait

        self.assertEqual(tier.kick(api, REPO, ["Packages/**"], now=clock.now, sleep=clock.sleep, log=lambda _: None), TIP)
        self.assertEqual(clock.slept[0], 10 * 60)
        self.assertEqual(len(api.dispatched), 1)

    def test_a_new_base_tier_run_while_waiting_owns_its_full_window(self):
        # A hand dispatch can start while this kick sleeps. The first run's
        # deadline must never let a second Mac tier start inside the new window.
        # The older run still waits for a Mac: the new run supersedes it, so it is
        # cancelled even though this kick dispatches nothing.
        # The hand dispatch took the branch tip then, which contains this kick's tip.
        api, clock = FakeApi([], TIP), Clock(T0 + 5 * 60)
        api.open_run(11, OLD, T0, "queued", QUEUED_MAC)
        api.covering.add(MID)

        clock.during_wait = lambda: api.open_run(12, MID, T0 + 12 * 60, "queued", QUEUED_MAC)

        self.assertIsNone(tier.kick(api, REPO, ["Packages/**"], now=clock.now,
                                    sleep=clock.sleep, log=lambda _: None))
        self.assertEqual(clock.slept, [10 * 60])
        self.assertEqual(api.dispatched, [])
        self.assertEqual(api.cancelled, [11])
        self.assertEqual(sum("/actions/workflows/cmux-next.yml/runs?" in p for p in api.gets), 3)

    def test_a_kick_never_waits_longer_than_the_window(self):
        # A clock behind the run's created_at (skew) still waits at most one window.
        api, clock = FakeApi([(OLD, T0)], TIP), Clock(T0 - 3600)
        kick(api, clock)
        self.assertEqual(clock.slept[0], tier.WINDOW_S)

    def test_a_skewed_clock_still_dispatches_after_the_capped_wait(self):
        # The run seen before the sleep is not a new run: a clock still behind its
        # created_at after the capped wait must dispatch, not return (that starved
        # the base tier on every kick).
        api, clock = FakeApi([(OLD, T0)], TIP), Clock(T0 - 3600)
        self.assertEqual(kick(api, clock), TIP)
        self.assertEqual(clock.slept[0], tier.WINDOW_S)
        self.assertEqual(len(api.dispatched), 1)

    def test_a_tip_that_already_has_a_base_tier_run_is_left_alone(self):
        api, clock = FakeApi([(TIP, T0)], TIP), Clock(T0 + 20 * 60)
        self.assertIsNone(kick(api, clock))
        self.assertEqual(api.dispatched, [])

    def test_a_tip_whose_landings_change_no_cmux_next_push_path_is_left_alone(self):
        # The same paths that start a cmux-next push run: a docs-only burst runs no base tier.
        api = FakeApi([(OLD, T0)], TIP, files=["README.md", "docs/blog/post.md"])
        self.assertIsNone(kick(api, Clock(T0 + 20 * 60)))
        self.assertEqual(api.dispatched, [])

    def test_an_unreadable_compare_runs_the_base_tier(self):
        api = FakeApi([(OLD, T0)], TIP, compare_error=True)
        self.assertEqual(kick(api, Clock(T0 + 20 * 60)), TIP)

    def test_no_earlier_base_tier_run_dispatches_at_once(self):
        api, clock = FakeApi([], TIP), Clock(T0)
        self.assertEqual(kick(api, clock), TIP)
        self.assertFalse([path for path in api.gets if "/compare/" in path])

    def test_the_first_run_of_a_commit_counts_not_its_same_tree_run(self):
        # A same-tree run of OLD, created later, carries the same name: the window starts at the first.
        api, clock = FakeApi([(OLD, T0), (OLD, T0 + 12 * 60)], TIP), Clock(T0 + 16 * 60)
        kick(api, clock)
        self.assertEqual(clock.slept, [tier.SETTLE_S])

    def test_a_refused_dispatch_fails_the_kick(self):
        with self.assertRaisesRegex(RuntimeError, "HTTP 403"):
            kick(FakeApi([(OLD, T0)], TIP, dispatch_status=403), Clock(T0 + 20 * 60))


class PushEventTip(unittest.TestCase):
    """2026-11-10: 14 of the last 40 kicks died on `HTTP 403` from the repository token's spent REST
    quota (runs 42800611965 and 42800199912 on the branch ref read, six more on the run listing), so
    those pushes never got a base tier. A push kick takes its own event's sha as the tip; it reads
    the ref only when no push event names the branch."""

    PUSH = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/feat-cmux-next", "GITHUB_SHA": TIP}

    def test_the_event_names_the_tip_only_for_a_push_to_the_branch(self):
        self.assertEqual(tier.event_tip(self.PUSH), TIP)
        self.assertIsNone(tier.event_tip({**self.PUSH, "GITHUB_EVENT_NAME": "workflow_dispatch"}))
        self.assertIsNone(tier.event_tip({**self.PUSH, "GITHUB_EVENT_NAME": "schedule"}))
        self.assertIsNone(tier.event_tip({**self.PUSH, "GITHUB_REF": "refs/heads/main"}))
        self.assertIsNone(tier.event_tip({**self.PUSH, "GITHUB_SHA": "not-a-sha"}))
        self.assertIsNone(tier.event_tip({}))

    def test_a_push_kick_dispatches_at_its_own_sha_with_no_ref_read(self):
        api, clock = FakeApi([(OLD, T0)], "f" * 40), Clock(T0 + 20 * 60)
        self.assertEqual(tier.kick(api, REPO, ["Packages/**"], now=clock.now, sleep=clock.sleep,
                                   log=lambda _: None, pushed=TIP), TIP)
        self.assertFalse([path for path in api.gets if "/git/ref/" in path], api.gets)
        self.assertIn(f"repos/{REPO}/compare/{OLD}...{TIP}", api.gets)
        self.assertEqual(len(api.dispatched), 1)

    def test_a_push_that_already_has_a_base_tier_run_is_left_alone(self):
        api, clock = FakeApi([(TIP, T0)], "f" * 40), Clock(T0 + 20 * 60)
        self.assertIsNone(tier.kick(api, REPO, ["Packages/**"], now=clock.now, sleep=clock.sleep,
                                    log=lambda _: None, pushed=TIP))
        self.assertEqual(api.dispatched, [])
        self.assertFalse([path for path in api.gets if "/git/ref/" in path], api.gets)

    def test_a_push_behind_the_last_base_tier_run_is_covered_by_it(self):
        # An earlier kick dispatched at a branch tip newer than this push: its run covers this push.
        api, clock = FakeApi([(MID, T0)], "f" * 40), Clock(T0 + 20 * 60)
        original = api.get
        api.get = lambda path: {"status": "behind", "files": []} if "/compare/" in path else original(path)
        self.assertIsNone(tier.kick(api, REPO, ["Packages/**"], now=clock.now, sleep=clock.sleep,
                                    log=lambda _: None, pushed=TIP))
        self.assertEqual(api.dispatched, [])


class CancelAfterAWait(unittest.TestCase):
    """Review of #40369: a cancel is posted only right after a fresh read of the run's Mac jobs, never
    after a quota wait. The real client against a fake GitHub: the job read waits out the quota and
    reads again; a cancel refused on the quota is not retried and the kick goes on."""

    NOW = T0 + 20 * 60

    def client(self, responses: dict[str, list]):
        clock = {"at": self.NOW}
        slept, sent = [], []

        def sleep(seconds):
            slept.append(seconds)
            clock["at"] += seconds

        api = quota.QuotaGitHub("t", deadline=quota.Deadline(900, clock=lambda: clock["at"]), now=lambda: clock["at"],
                                sleep=sleep)

        def send(method, url, body=None):
            sent.append((method, url))
            for key, queue in responses.items():
                if key in url:
                    status, payload = queue.pop(0) if len(queue) > 1 else queue[0]
                    headers = {}
                    if status == 403:
                        headers = {"x-ratelimit-remaining": "0", "x-ratelimit-reset": str(int(clock["at"] + 300))}
                    return status, json.dumps(payload).encode(), headers
            raise AssertionError(url)

        api._send = send
        return api, slept, sent

    RUNS = {"workflow_runs": [
        {"id": 11, "status": "queued", "display_title": f"{tier.TITLE}{OLD}", "created_at": stamp(T0)},
        {"id": 12, "status": "queued", "display_title": f"{tier.TITLE}{TIP}", "created_at": stamp(T0 + 60)},
    ]}

    def test_a_cancel_after_a_wait_rechecks_the_job_status_first(self):
        # The job read hits the spent quota and waits; the Mac job started during the wait, so the
        # read after it finds it running and nothing is cancelled.
        api, slept, sent = self.client({
            "/runs?": [(200, self.RUNS)],
            "/runs/11/jobs": [(403, {"message": "API rate limit exceeded"}),
                              (200, {"jobs": [job("cmux-next daemon tests", "in_progress")]})],
            "/cancel": [(202, {})],
        })
        self.assertEqual(tier.cancel_superseded(api, REPO, TIP, log=lambda _: None), [])
        self.assertEqual(slept, [301])
        self.assertFalse([url for _, url in sent if url.endswith("/cancel")])

    def test_a_cancel_refused_on_the_quota_is_not_retried(self):
        lines = []
        api, slept, sent = self.client({
            "/runs?": [(200, self.RUNS)],
            "/runs/11/jobs": [(200, {"jobs": QUEUED_MAC})],
            "/cancel": [(403, {"message": "API rate limit exceeded"})],
        })
        self.assertEqual(tier.cancel_superseded(api, REPO, TIP, log=lines.append), [])
        self.assertEqual(slept, [])
        self.assertEqual(len([url for _, url in sent if url.endswith("/cancel")]), 1)
        self.assertTrue(any("could not cancel base tier run 11" in line for line in lines), lines)


class QuotaLine(unittest.TestCase):
    def run_main(self, error: Exception | None):
        import contextlib
        import io

        calls = []

        def fake_kick(api, repo, patterns, **kwargs):
            calls.append((api, kwargs))
            if error:
                raise error

        original, env = tier.kick, dict(os.environ)
        tier.kick = fake_kick
        os.environ.update({"GH_TOKEN": "t", **PushEventTip.PUSH})
        err = io.StringIO()
        try:
            with contextlib.redirect_stderr(err):
                code = tier.main(["kick", "--repo", REPO, "--workflow-file", "/nonexistent"])
        finally:
            tier.kick = original
            os.environ.clear()
            os.environ.update(env)
        return code, err.getvalue(), calls

    def test_a_spent_quota_fails_with_one_line_and_no_traceback(self):
        error = tier.QuotaExhausted("GET repos/manaflow-ai/cmux/actions/workflows/cmux-next.yml/runs: HTTP 403: "
                                    "the repository token's core REST quota (shared by every workflow) is spent; "
                                    "it resets at 2027-01-15T08:00:00Z, past this job's budget (2027-01-15T07:20:00Z)")
        code, err, _ = self.run_main(error)
        self.assertEqual(code, 1)
        self.assertEqual(len(err.splitlines()), 1, err)
        self.assertIn("REST quota", err)
        self.assertIn("resets at 2027-01-15T08:00:00Z", err)
        self.assertNotIn("Traceback", err)

    def test_main_passes_the_push_sha_and_one_deadline_inside_the_job(self):
        code, _, [(api, kwargs)] = self.run_main(None)
        self.assertEqual(code, 0)
        self.assertEqual(kwargs["pushed"], TIP)
        # One deadline: the client's quota retries and kick()'s window read the same one.
        self.assertIs(api.deadline, kwargs["deadline"])
        self.assertLessEqual(api.deadline.left(), tier.JOB_TIMEOUT_S - tier.MARGIN_S)
        self.assertGreater(api.deadline.left(), 0)
        # It is derived from the job's real timeout, not a constant that can drift from it.
        timeout = yaml.safe_load(KICK.read_text())["jobs"]["kick"]["timeout-minutes"]
        self.assertEqual(tier.JOB_TIMEOUT_S, timeout * 60)

    def test_a_window_past_the_deadline_fails_with_one_line(self):
        code, err, _ = self.run_main(tier.PastDeadline("the window opens in 899 s but this job has 479 s left"))
        self.assertEqual(code, 1)
        self.assertEqual(len(err.splitlines()), 1, err)
        self.assertIn("ran out of job time", err)
        self.assertNotIn("Traceback", err)


class OneDeadline(unittest.TestCase):
    """Review of #40369 (cmuxterm-hq docs/handbook/budget-summed-from-constants.md): the quota retry fit
    its own budget, then kick()'s window wait ran after it with none, so a 601 s quota wait plus the
    window dispatched at 1400 s, past the job's 1200 s timeout. The real client and kick() on one fake
    clock, with one deadline: whatever the waits add up to, nothing is dispatched past the deadline."""

    BUDGET = tier.JOB_TIMEOUT_S - tier.MARGIN_S

    def run_kick(self, quota_wait: float, last_run_at: float):
        clock = Clock(T0)
        deadline = quota.Deadline(self.BUDGET, clock=clock.now)
        fake = FakeApi([(OLD, last_run_at)], TIP)
        dispatched_at: list[float] = []
        refused = {"left": 1 if quota_wait else 0}
        api = quota.QuotaGitHub("t", deadline=deadline, now=clock.now, sleep=clock.sleep)

        def send(method, url, body=None):
            path = url.removeprefix(api.api_url + "/")
            if method == "GET":
                if refused["left"]:
                    refused["left"] -= 1
                    return 403, b'{"message": "API rate limit exceeded"}', {
                        "x-ratelimit-remaining": "0", "x-ratelimit-reset": str(int(clock.at + quota_wait - 1))}
                return 200, json.dumps(fake.get(path)).encode(), {}
            if path.endswith("/dispatches"):
                dispatched_at.append(clock.at)
            return fake.post(path, body or {}), b"", {}

        api._send = send
        lines: list[str] = []
        try:
            result = tier.kick(api, REPO, ["Packages/**"], now=clock.now, sleep=clock.sleep, log=lines.append,
                               pushed=TIP, deadline=deadline)
        except (tier.PastDeadline, tier.QuotaExhausted) as error:
            result = error
        return result, clock, fake, dispatched_at, deadline

    def test_a_long_quota_wait_then_the_window_dispatches_nothing_past_the_deadline(self):
        # The last base tier run started as the kick began its listing: the listing waits 601 s on the
        # quota, then the window still has 899 s to go. 601 + 899 s is past the deadline.
        result, clock, fake, dispatched_at, deadline = self.run_kick(quota_wait=601, last_run_at=T0 + 600)
        self.assertIsInstance(result, tier.PastDeadline)
        message = str(result)
        self.assertEqual(len(message.splitlines()), 1, message)
        self.assertIn("the window opens in 899 s", message)
        self.assertIn(f"{int(deadline.at - (T0 + 601))} s left", message)
        self.assertEqual(fake.dispatched, [])
        self.assertEqual(dispatched_at, [])
        # It failed before the window's sleep: only the quota wait was slept.
        self.assertEqual(clock.slept, [601])
        self.assertLessEqual(clock.at, deadline.at)

    def test_a_quota_wait_and_a_window_that_fit_dispatch_inside_the_deadline(self):
        result, clock, fake, dispatched_at, deadline = self.run_kick(quota_wait=121, last_run_at=T0 - 300)
        self.assertEqual(result, TIP)
        self.assertEqual(len(fake.dispatched), 1)
        self.assertEqual(clock.slept[:2], [121, 900 - 300 - 121])
        self.assertLessEqual(dispatched_at[0] + tier.SETTLE_S, deadline.at)
        self.assertLessEqual(clock.at, deadline.at)

    def test_every_combination_of_waits_stays_inside_the_deadline(self):
        for quota_wait in (0, 60, 301, 601, 900, 1100):
            for since_last in (0, 300, 600, 899):
                with self.subTest(quota_wait=quota_wait, since_last=since_last):
                    result, clock, fake, dispatched_at, deadline = self.run_kick(quota_wait, T0 - since_last)
                    for at in dispatched_at:
                        self.assertLessEqual(at, deadline.at)
                    self.assertLessEqual(clock.at, deadline.at)
                    # It dispatches, or fails with one line; never a dispatch the job timeout would kill.
                    self.assertTrue(result == TIP or isinstance(result, (tier.PastDeadline, tier.QuotaExhausted)),
                                    result)
                    self.assertEqual(len(fake.dispatched), 1 if result == TIP else 0)

    def test_a_dispatch_whose_settle_does_not_fit_is_not_made(self):
        # Codex review of #40471 (P2): a dispatch that skipped its settle freed the concurrency slot before
        # GitHub listed the new run, and the next kick, 5 s later, saw no run at the tip and dispatched
        # again: duplicate Mac work. The settle's time is reserved before the dispatch; without it the
        # kick dispatches nothing and says so in one line, and the next kick dispatches once.
        clock = Clock(T0 + 20 * 60)
        api = FakeApi([(OLD, T0)], TIP)
        api.listed_late = True  # the next kick's listing does not show this kick's dispatch yet
        api.open_run(11, OLD, T0, "queued", QUEUED_MAC)
        late = quota.Deadline(tier.SETTLE_S - 1, clock=clock.now)
        with self.assertRaises(tier.PastDeadline) as raised:
            tier.kick(api, REPO, ["Packages/**"], now=clock.now, sleep=clock.sleep, log=lambda _: None,
                      pushed=TIP, deadline=late)
        self.assertEqual(len(str(raised.exception).splitlines()), 1)
        self.assertEqual(api.dispatched, [])
        clock.at += 5
        self.assertEqual(tier.kick(api, REPO, ["Packages/**"], now=clock.now, sleep=clock.sleep,
                                   log=lambda _: None, pushed=TIP,
                                   deadline=quota.Deadline(600, clock=clock.now)), TIP)
        self.assertEqual(len(api.dispatched), 1)


    def test_a_slow_dispatch_post_still_settles_inside_the_deadline(self):
        # Codex review of #40520 (F1): the guard reserved only SETTLE_S, but the dispatch POST can wait up
        # to the client's request timeout. With 21 s left and a 10 s POST that succeeds, the settle ended 9 s
        # past the deadline. The POST's time is reserved with the settle: such a kick dispatches nothing,
        # and one with room for both settles before the deadline even when its POST takes the whole timeout.
        clock = Clock(T0 + 20 * 60)
        api = FakeApi([(OLD, T0)], TIP)
        api.open_run(11, OLD, T0, "queued", QUEUED_MAC)
        api.during_dispatch = lambda: setattr(clock, "at", clock.at + 10)
        short = quota.Deadline(tier.SETTLE_S + 1, clock=clock.now)
        with self.assertRaises(tier.PastDeadline):
            tier.kick(api, REPO, ["Packages/**"], now=clock.now, sleep=clock.sleep, log=lambda _: None,
                      pushed=TIP, deadline=short)
        self.assertEqual(api.dispatched, [])
        api.during_dispatch = lambda: setattr(clock, "at", clock.at + quota.REQUEST_TIMEOUT_S)
        room = quota.Deadline(quota.REQUEST_TIMEOUT_S + tier.SETTLE_S, clock=clock.now)
        self.assertEqual(tier.kick(api, REPO, ["Packages/**"], now=clock.now, sleep=clock.sleep,
                                   log=lambda _: None, pushed=TIP, deadline=room), TIP)
        self.assertEqual(len(api.dispatched), 1)
        self.assertGreaterEqual(room.left(), 0)

class RunDuringAWait(unittest.TestCase):
    """Codex review of #40369 (F1): after any wait the kick reads the run history again before it
    dispatches. A 601 s quota wait with a manual base tier run starting 300 s into it dispatched only
    301 s after that run, inside its 15 minute window. The real client and kick() on one fake clock."""

    MANUAL_AT = T0 + 300

    OLDER_OPEN = "0" * 39 + "1"

    def run_kick(self, budget: float, covering: bool = False, refused_read: str = "/compare/",
                 older_open: bool = False):
        clock = Clock(T0)
        deadline = quota.Deadline(budget, clock=clock.now)
        fake = FakeApi([(OLD, T0 - 20 * 60)], TIP)  # the window is open when the kick starts
        if older_open:
            # An older base tier run still queued, no Mac job started: the newer run supersedes it.
            fake.open_run(11, self.OLDER_OPEN, T0 - 25 * 60, "queued", QUEUED_MAC)
        if covering:
            fake.covering.add(MID)
        dispatched_at: list[float] = []
        refused = {"left": 1}
        api = quota.QuotaGitHub("t", deadline=deadline, now=clock.now, sleep=clock.sleep)

        def manual_run():
            # Started by hand 300 s into the quota wait, titled with the branch tip then.
            if not any(MID in run["display_title"] for run in fake.runs):
                fake.open_run(12, MID, self.MANUAL_AT, "queued", QUEUED_MAC)

        def send(method, url, body=None):
            path = url.removeprefix(api.api_url + "/")
            if method == "GET":
                if refused_read in path and refused["left"]:
                    refused["left"] -= 1
                    return 403, b'{"message": "API rate limit exceeded"}', {
                        "x-ratelimit-remaining": "0", "x-ratelimit-reset": str(int(clock.at + 600))}
                return 200, json.dumps(fake.get(path)).encode(), {}
            if path.endswith("/dispatches"):
                dispatched_at.append(clock.at)
            return fake.post(path, body or {}), b"", {}

        api._send = send
        clock.during_wait = manual_run
        try:
            result = tier.kick(api, REPO, ["Packages/**"], now=clock.now, sleep=clock.sleep, log=lambda _: None,
                               pushed=TIP, deadline=deadline)
        except tier.PastDeadline as error:
            result = error
        return result, clock, fake, dispatched_at

    def test_a_manual_run_during_a_quota_wait_gets_its_full_window(self):
        # The job's real deadline: 601 s of quota wait leaves 479 s, and the manual run's window has 599 s
        # to go. The kick exits with the deadline line; nothing is dispatched.
        result, clock, fake, dispatched_at = self.run_kick(tier.JOB_TIMEOUT_S - tier.MARGIN_S)
        self.assertEqual(clock.slept, [601])
        self.assertIsInstance(result, tier.PastDeadline)
        self.assertEqual(len(str(result).splitlines()), 1)
        self.assertIn("the window opens in 599 s", str(result))
        self.assertEqual(fake.dispatched, [])
        self.assertEqual(dispatched_at, [])

    def test_with_time_left_it_waits_out_the_manual_runs_window_then_dispatches(self):
        result, clock, fake, dispatched_at = self.run_kick(3600)
        self.assertEqual(clock.slept[:2], [601, 599])
        self.assertEqual(result, TIP)
        self.assertEqual(len(fake.dispatched), 1)
        self.assertGreaterEqual(dispatched_at[0], self.MANUAL_AT + tier.WINDOW_S)

    def test_a_manual_run_that_covers_the_push_ends_the_kick(self):
        result, clock, fake, dispatched_at = self.run_kick(tier.JOB_TIMEOUT_S - tier.MARGIN_S, covering=True)
        self.assertIsNone(result)
        self.assertEqual(clock.slept, [601])
        self.assertEqual(fake.dispatched, [])
        self.assertEqual(dispatched_at, [])

    def test_a_covering_run_during_the_first_history_reads_wait_ends_the_kick(self):
        # Codex review of #40471 (P2): the first history read itself waits out the quota (601 s) and a
        # run covering the push starts 300 s in. The kick sees it as the last run, not as one that started
        # during a wait, and its window has 599 s to go. Nothing needs dispatching, so the kick ends
        # without the deadline error and still cancels the older run no Mac has started.
        result, clock, fake, dispatched_at = self.run_kick(
            tier.JOB_TIMEOUT_S - tier.MARGIN_S, covering=True, refused_read="/actions/workflows/cmux-next.yml/runs?",
            older_open=True)
        self.assertNotIsInstance(result, tier.PastDeadline)
        self.assertIsNone(result)
        self.assertEqual(clock.slept, [601])
        self.assertEqual(fake.dispatched, [])
        self.assertEqual(dispatched_at, [])
        self.assertIn(11, fake.cancelled)


class QuotaRetry(unittest.TestCase):
    """Every workflow's GITHUB_TOKEN in a repository shares one REST quota (2026-11-10: the base tier
    kick died on `HTTP 403` from it 14 times in 40 runs). With a deadline, the client waits out a
    spent quota with one sleep when the reset fits the deadline, and otherwise raises QuotaExhausted
    with one line naming the quota and its reset."""

    NOW = 1_800_000_000.0

    def client(self, responses, deadline):
        clock = {"at": self.NOW}
        slept: list[float] = []

        def sleep(seconds):
            slept.append(seconds)
            clock["at"] += seconds

        # DEADLINE is given as a time on the fake clock; the client reads what is left of it.
        budget = None if deadline is None else quota.Deadline(deadline - self.NOW, clock=lambda: clock["at"])
        api = quota.QuotaGitHub("t", deadline=budget, now=lambda: clock["at"], sleep=sleep)
        sent = []

        def send(method, url, body=None):
            sent.append((method, url))
            return responses.pop(0)

        api._send = send
        return api, slept, sent

    def spent(self, reset_in: float):
        return (403, b'{"message": "API rate limit exceeded for installation ID 1."}',
                {"x-ratelimit-remaining": "0", "x-ratelimit-reset": str(int(self.NOW + reset_in)),
                 "x-ratelimit-resource": "core"})

    def test_a_reset_within_the_budget_sleeps_once_and_succeeds(self):
        api, slept, sent = self.client([self.spent(120), (200, b'{"ok": 1}', {})], self.NOW + 600)
        self.assertEqual(api.get("repos/o/r/git/ref/heads/x"), {"ok": 1})
        self.assertEqual(slept, [121])
        self.assertEqual(len(sent), 2)

    def test_a_reset_past_the_budget_raises_one_line_naming_the_quota(self):
        api, slept, sent = self.client([self.spent(3000)], self.NOW + 600)
        with self.assertRaises(tier.QuotaExhausted) as raised:
            api.get("repos/o/r/actions/workflows/cmux-next.yml/runs")
        message = str(raised.exception)
        self.assertIsInstance(raised.exception, RuntimeError)  # callers that catch RuntimeError still do
        self.assertEqual(len(message.splitlines()), 1)
        self.assertIn("GET repos/o/r/actions/workflows/cmux-next.yml/runs: HTTP 403", message)
        self.assertIn("core REST quota", message)
        self.assertIn(f"resets at {quota.utc(self.NOW + 3000)}", message)
        self.assertRegex(message, r"resets at \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ")
        self.assertEqual(slept, [])
        self.assertEqual(len(sent), 1)

    def test_a_secondary_limit_backs_off_then_gives_up_at_the_deadline(self):
        limited = (403, b'{"message": "You have exceeded a secondary rate limit."}', {})
        api, slept, _ = self.client([limited, limited, (200, b"{}", {})], self.NOW + 600)
        self.assertEqual(api.get("repos/o/r/actions/runs/1"), {})
        self.assertEqual(slept, [30, 60])
        api, slept, _ = self.client([(429, b"", {"retry-after": "90"})], self.NOW + 60)
        with self.assertRaisesRegex(tier.QuotaExhausted, "secondary rate limit; retry after 90 s"):
            api.get("repos/o/r/actions/runs/1")
        self.assertEqual(slept, [])

    def test_a_write_is_never_retried_after_a_wait(self):
        """A cancel decided on a job read must not fire minutes later, after the job may have started
        (review of #40369: a retried cancel stopped a running Mac job after a 601 s wait). A write
        refused on the quota raises at once, even when the reset fits the deadline."""
        for method, call in (("POST", lambda api: api.post("repos/o/r/actions/runs/1/cancel", {})),
                             ("DELETE", lambda api: api.delete("repos/o/r/actions/artifacts/1"))):
            api, slept, sent = self.client([self.spent(60), (202, b"", {})], self.NOW + 600)
            with self.assertRaises(tier.QuotaExhausted) as raised:
                call(api)
            self.assertIn(f"{method} repos/o/r/", str(raised.exception))
            self.assertIn("not retried", str(raised.exception))
            self.assertEqual(len(str(raised.exception).splitlines()), 1)
            self.assertEqual(slept, [])
            self.assertEqual(len(sent), 1)

    def test_the_retry_reads_the_time_left_not_a_budget_of_its_own(self):
        """The deadline is the job's: time another step spent (a window wait) comes out of what a quota
        retry may wait (review of #40369: a 601 s quota wait plus the window ran past the job timeout)."""
        clock = {"at": self.NOW}
        deadline = quota.Deadline(600, clock=lambda: clock["at"])
        api = quota.QuotaGitHub("t", deadline=deadline, now=lambda: clock["at"], sleep=lambda _: None)
        clock["at"] += 500  # another step of the same job used 500 s of it
        api._send = lambda method, url, body=None: self.spent(500 + 119)  # resets in 120 s
        with self.assertRaisesRegex(quota.QuotaExhausted, r"past this job's deadline \(100 s left\)"):
            api.get("repos/o/r/actions/runs/1")

    def test_a_refusal_that_is_not_a_rate_limit_is_returned_as_before(self):
        # The takeover reads `This workflow is already running` as a 403 status.
        api, slept, _ = self.client([(403, b'{"message": "This workflow is already running"}', {})], self.NOW + 600)
        self.assertEqual(api.post("repos/o/r/actions/runs/1/rerun", {}), 403)
        self.assertEqual(slept, [])

    def test_no_deadline_never_retries(self):
        api, slept, _ = self.client([self.spent(60), self.spent(60)], None)
        with self.assertRaisesRegex(RuntimeError, r"^GET repos/o/r/pulls/1: HTTP 403$"):
            api.get("repos/o/r/pulls/1")
        self.assertEqual(api.post("repos/o/r/actions/runs/1/cancel", {}), 403)
        self.assertEqual(slept, [])

    def test_it_reads_the_rate_limit_headers_off_the_http_error(self):
        body = b'{"message": "API rate limit exceeded"}'
        answer = (f"HTTP/1.1 403 rate limit exceeded\r\nX-RateLimit-Remaining: 0\r\n"
                  f"X-RateLimit-Reset: {int(self.NOW + 9999)}\r\nContent-Length: {len(body)}\r\n\r\n").encode() + body
        server = TricklingServer(answer, 0)
        self.addCleanup(server.stop)
        api = quota.QuotaGitHub("t", server.url, deadline=quota.Deadline(60, clock=lambda: self.NOW),
                                now=lambda: self.NOW, sleep=lambda _: None)
        with self.assertRaisesRegex(tier.QuotaExhausted, "core REST quota"):
            api.get("repos/o/r/git/ref/heads/x")

class TricklingServer:
    """One HTTP server on 127.0.0.1 that answers every connection with ANSWER, a byte every GAP seconds
    (0: all at once). It stops trickling when stop() is called or the client hangs up."""

    def __init__(self, answer: bytes, gap: float):
        self.answer, self.gap = answer, gap
        self.done = threading.Event()
        # When each request reached the server (time.monotonic()), in order.
        self.arrivals: list[float] = []
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen()
        self.listener.settimeout(0.05)
        self.url = f"http://127.0.0.1:{self.listener.getsockname()[1]}"
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self) -> None:
        while not self.done.is_set():
            try:
                conn, _ = self.listener.accept()
            except OSError:
                continue
            # One thread a connection: a call abandoned at its bound must not hold up the next one.
            threading.Thread(target=self.answer_one, args=(conn,), daemon=True).start()

    def answer_one(self, conn: socket.socket) -> None:
        with conn:
            try:
                conn.settimeout(1)
                if conn.recv(65536):  # the request (small enough for one read here)
                    self.arrivals.append(time.monotonic())
                if not self.gap:
                    conn.sendall(self.answer)
                    return
                for byte in self.answer:
                    if self.done.wait(self.gap):
                        return
                    conn.sendall(bytes([byte]))
            except OSError:
                return

    def stop(self) -> None:
        self.done.set()
        self.thread.join(2)
        self.listener.close()


class WholeRequestBound(unittest.TestCase):
    """Codex review of #40530 (F1): urlopen(timeout=30) bounds each socket wait, not the call, so a POST
    whose answer trickles in could run past REQUEST_TIMEOUT_S, and DISPATCH_RESERVE_S could still overrun
    the settle (a 204 after 0.293 s with a 0.1 s timeout). Every call of tree notify's client, and so of
    QuotaGitHub and the takeover's client, now ends within its bound on one monotonic clock."""

    BOUND = 0.3
    SLACK = 0.4
    # Each header byte comes 0.03 s after the last (well under the 0.3 s socket timeout); all of them take
    # about 2 s, far past the bound.
    SLOW = b"HTTP/1.1 204 No Content\r\nX-Trickle: " + b"a" * 30 + b"\r\nContent-Length: 0\r\n\r\n"
    FAST = b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 12\r\n\r\n{"ok": true}'

    def serve(self, answer: bytes, gap: float) -> TricklingServer:
        server = TricklingServer(answer, gap)
        self.addCleanup(server.stop)
        return server

    def clients(self, url: str):
        tree = notify.GitHub("t", url)
        kick = quota.QuotaGitHub("t", url, deadline=quota.Deadline(60), sleep=lambda _: self.fail("slept"))
        for api in (tree, kick):
            api.timeout = self.BOUND
        return {"tree notify": tree, "QuotaGitHub": kick}

    def test_trickled_headers_end_the_call_at_its_bound(self):
        self.assertGreater(len(self.SLOW) * 0.03, 4 * self.BOUND)
        server = self.serve(self.SLOW, 0.03)
        for name, api in self.clients(server.url).items():
            for method, call in (("POST", lambda: api.post("repos/o/r/actions/workflows/w/dispatches", {})),
                                 ("GET", lambda: api.get("repos/o/r"))):
                with self.subTest(client=name, method=method):
                    started = time.monotonic()
                    try:
                        outcome = call()
                    except Exception as error:  # noqa: BLE001
                        outcome = error
                    elapsed = time.monotonic() - started
                    self.assertLess(elapsed, self.BOUND + self.SLACK, f"{name} {method} returned {outcome!r}")
                    # Never a success: a timed-out write may have been taken, so it is reported as unknown.
                    self.assertIsInstance(outcome, TimeoutError)
                    self.assertIsInstance(outcome, notify.RequestTimeout)
                    self.assertGreaterEqual(elapsed, self.BOUND * 0.9)

    def test_a_fast_answer_still_returns_its_body(self):
        server = self.serve(self.FAST, 0)
        for name, api in self.clients(server.url).items():
            with self.subTest(client=name):
                self.assertEqual(api.get("repos/o/r"), {"ok": True})

    def test_the_dispatch_reserve_is_the_bound_plus_the_settle(self):
        self.assertEqual(quota.REQUEST_TIMEOUT_S, notify.GitHub.timeout)
        self.assertEqual(tier.DISPATCH_RESERVE_S, notify.REQUEST_TIMEOUT_S + tier.SETTLE_S)


class NothingAfterTheBound(unittest.TestCase):
    """Codex review of #40574: running the call on a thread joined with its bound let it outlive the bound.
    F1: a call that timed out could still finish its name lookup and send its POST during the settle, so
    the next kick dispatched the Mac work twice (a localhost repro got two POSTs). F2: join(bound) started
    its clock after the thread started, and a finished thread counted as success whatever the time, so a
    100 ms start delay returned 204 against a 50 ms bound. The call now runs on the caller's thread against
    one deadline taken before the name lookup: nothing is sent after it, and no answer past it succeeds."""

    BOUND = 0.1
    ANSWER = b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n"

    def serve(self) -> TricklingServer:
        server = TricklingServer(self.ANSWER, 0)
        self.addCleanup(server.stop)
        return server

    def clients(self, url: str):
        tree = notify.GitHub("t", url)
        kick = quota.QuotaGitHub("t", url, deadline=quota.Deadline(60), sleep=lambda _: self.fail("slept"))
        for api in (tree, kick):
            api.timeout = self.BOUND
        return {"tree notify": tree, "QuotaGitHub": kick}

    def slow_lookup(self, seconds: float) -> None:
        """Every name lookup takes SECONDS more (urllib and the transport both call socket.getaddrinfo)."""
        real = socket.getaddrinfo

        def lookup(*args, **kwargs):
            time.sleep(seconds)
            return real(*args, **kwargs)

        socket.getaddrinfo = lookup
        self.addCleanup(setattr, socket, "getaddrinfo", real)

    def slow_start(self, seconds: float) -> None:
        """The caller is held SECONDS right after it starts a request thread (a loaded runner)."""
        real = threading.Thread.start

        def start(thread):
            real(thread)
            if thread.name == "github-request":
                time.sleep(seconds)

        threading.Thread.start = start
        self.addCleanup(setattr, threading.Thread, "start", real)

    def dispatch(self, api) -> tuple[object, float, float]:
        started = time.monotonic()
        try:
            outcome = api.post("repos/o/r/actions/workflows/w/dispatches", {})
        except Exception as error:  # noqa: BLE001
            outcome = error
        return outcome, started, time.monotonic()

    def test_a_timed_out_post_is_never_sent_after_its_bound(self):
        """F1: the name lookup outlasts the bound. The call times out, and no POST reaches the server
        after that, however long the lookup takes."""
        server = self.serve()
        self.slow_lookup(2.5 * self.BOUND)
        for name, api in self.clients(server.url).items():
            with self.subTest(client=name):
                server.arrivals.clear()
                outcome, _, ended = self.dispatch(api)
                self.assertIsInstance(outcome, notify.RequestTimeout, f"{name} returned {outcome!r}")
                # Long enough for an abandoned lookup to finish and its POST to land.
                time.sleep(5 * self.BOUND)
                late = [round(at - ended, 3) for at in server.arrivals if at > ended]
                self.assertEqual(late, [], f"{name}: a POST reached the server after the call timed out")
                self.assertLessEqual(len(server.arrivals), 1)

    def test_a_late_start_gets_no_fresh_bound(self):
        """F2: the bound runs from the call, not from when its work got going. With a lookup past the
        bound and the caller held after it starts its work, the call never succeeds."""
        server = self.serve()
        self.slow_lookup(1.5 * self.BOUND)
        self.slow_start(4 * self.BOUND)
        for name, api in self.clients(server.url).items():
            with self.subTest(client=name):
                outcome, started, ended = self.dispatch(api)
                self.assertNotEqual(outcome, 204, f"{name}: a 204 after {ended - started:.3f} s "
                                                  f"against a {self.BOUND} s bound")
                self.assertIsInstance(outcome, notify.RequestTimeout)

    def test_a_slow_lookup_ends_the_call_at_its_bound(self):
        """Codex review of #40631, F2: getaddrinfo takes no timeout, so a 663 ms lookup ran 663 ms against a
        100 ms bound. The lookup is now waited on for the time left, and nothing is sent after it."""
        server = self.serve()
        self.slow_lookup(8 * self.BOUND)
        for name, api in self.clients(server.url).items():
            with self.subTest(client=name):
                server.arrivals.clear()
                outcome, started, ended = self.dispatch(api)
                self.assertIsInstance(outcome, notify.RequestTimeout, f"{name} returned {outcome!r}")
                self.assertLess(ended - started, self.BOUND + 0.3, f"{name} waited out the lookup")
                time.sleep(9 * self.BOUND)
                self.assertEqual(server.arrivals, [], f"{name}: the abandoned lookup led to a request")

    def test_an_answer_buffered_in_time_but_finished_after_the_bound_is_a_timeout(self):
        """Codex review of #40631, F1: the whole answer arrives in one receive, then the caller pauses past
        the deadline. No receive is left to check the time, so the answer used to succeed late."""
        server = self.serve()
        late = [0.0]
        deadline = deadline_http.Deadline(self.BOUND, clock=lambda: time.monotonic() + late[0])
        real = deadline_http._DeadlineReader.readinto

        def readinto(reader, buffer):
            read = real(reader, buffer)
            late[0] += 2 * self.BOUND  # a pause once these bytes sit in the buffer
            return read

        deadline_http._DeadlineReader.readinto = readinto
        self.addCleanup(setattr, deadline_http._DeadlineReader, "readinto", real)
        with self.assertRaises(deadline_http.RequestTimeout):
            deadline_http.request(urllib.request.Request(server.url + "/x", method="POST", data=b"{}"),
                                  deadline=deadline)
        self.assertEqual(len(server.arrivals), 1)

    def test_an_answer_within_the_bound_still_succeeds(self):
        server = self.serve()
        for name, api in self.clients(server.url).items():
            with self.subTest(client=name):
                server.arrivals.clear()
                outcome, started, ended = self.dispatch(api)
                self.assertEqual(outcome, 204)
                self.assertEqual(len(server.arrivals), 1)
                self.assertLess(ended - started, self.BOUND + 0.4)


class DispatchWithNoAnswer(unittest.TestCase):
    """A dispatch POST that times out may have been taken by GitHub. The kick counts it as dispatched,
    unknown: it settles and cancels as after a 204, never posts it again, then fails with one line."""

    def test_a_timed_out_dispatch_still_settles_and_cancels_then_fails(self):
        clock = Clock(T0 + 20 * 60)
        api = FakeApi([(OLD, T0)], TIP)
        api.open_run(11, OLD, T0, "queued", QUEUED_MAC)

        def taken_but_unanswered():
            # GitHub took it (the run is listed later); the answer never came back within the bound.
            api.runs.insert(0, {"id": 99, "status": "queued", "display_title": f"{tier.TITLE}{TIP}",
                                "created_at": stamp(T0 + 10**6)})
            clock.at += 30
            raise TimeoutError("no full answer within 30 s")

        api.during_dispatch = taken_but_unanswered
        lines: list[str] = []
        with self.assertRaises(RuntimeError) as raised:
            tier.kick(api, REPO, ["Packages/**"], now=clock.now, sleep=clock.sleep, log=lines.append,
                      pushed=TIP, deadline=quota.Deadline(600, clock=clock.now))
        self.assertEqual(len(str(raised.exception).splitlines()), 1)
        self.assertIn("may or may not", str(raised.exception))
        self.assertEqual(len(api.dispatched), 1)
        self.assertIn(tier.SETTLE_S, clock.slept)
        self.assertEqual(api.cancelled, [11])
        self.assertFalse(any(line.startswith("dispatched") for line in lines))

    def test_a_timed_out_cancel_is_logged_and_not_counted(self):
        api = FakeApi([(OLD, T0)], TIP)
        api.open_run(11, OLD, T0, "queued", QUEUED_MAC)
        api.open_run(12, TIP, T0 + 60, "queued", QUEUED_MAC)
        original = api.post

        def post(path, body):
            if path.endswith("/cancel"):
                raise TimeoutError("no full answer within 30 s")
            return original(path, body)

        api.post = post
        lines: list[str] = []
        self.assertEqual(tier.cancel_superseded(api, REPO, TIP, lines.append), [])
        self.assertTrue(any("may or may not be cancelled" in line for line in lines), lines)


class PushPaths(unittest.TestCase):
    def test_it_reads_cmux_next_push_paths(self):
        patterns = tier.push_paths(WORKFLOW.read_text())
        on = yaml.safe_load(WORKFLOW.read_text()).get(True) or {}
        self.assertEqual(patterns, on["push"]["paths"])

    def test_globs_match_like_github_path_filters(self):
        self.assertTrue(tier.matches("Packages/macOS/CmuxNext/Sources/A/B.swift", ["Packages/macOS/CmuxNext/**"]))
        self.assertTrue(tier.matches("scripts/ci/x.py", ["scripts/ci/*.py"]))
        self.assertFalse(tier.matches("scripts/ci/sub/x.py", ["scripts/ci/*.py"]))
        self.assertTrue(tier.matches("a/b/c.swift", ["**/*.swift"]))
        self.assertTrue(tier.matches("c.swift", ["**/*.swift"]))
        self.assertFalse(tier.matches("docs/a.md", ["docs/**", "!docs/*.md"]))
        self.assertTrue(tier.matches("docs/a.md", ["!docs/*.md", "docs/**"]))


class Defer(unittest.TestCase):
    ROUTED = ["native=true", "macos=true", "scheme=true", "generated=true", "swift=false", "daemon=true",
              "fast_tier=true", "swift_targets="]

    def test_a_push_leaves_only_the_base_tier_to_the_kick(self):
        out = dict(line.split("=", 1) for line in tier.defer(self.ROUTED))
        self.assertEqual((out["daemon"], out["scheme"], out["generated"]), ("false", "false", "false"))
        # The Release compiles (native), the Mac placement and the fast tier still run on the push.
        self.assertEqual((out["native"], out["macos"], out["fast_tier"]), ("true", "true", "true"))
        self.assertEqual(out["base_tier"], "deferred")
        self.assertEqual(out["base_tier_deferred"], "scheme,generated,daemon")

    def test_the_scheme_compile_stays_when_it_is_the_dev_landing_build(self):
        out = dict(line.split("=", 1) for line in tier.defer(self.ROUTED, ("scheme",)))
        self.assertEqual((out["daemon"], out["scheme"], out["generated"]), ("false", "true", "false"))


def route_step() -> dict:
    steps = yaml.safe_load(WORKFLOW.read_text())["jobs"]["path_route"]["steps"]
    return next(step for step in steps if step.get("id") == "route")


class RouteStep(unittest.TestCase):
    """path_route's route step, run with a stub router: what a push and a base tier dispatch route."""

    def run_step(self, event: str, **env: str) -> dict[str, str]:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "scripts/ci").mkdir(parents=True)
            shutil.copy(ROOT / "scripts/ci/cmux_next_base_tier.py", root / "scripts/ci/")
            shutil.copy(ROOT / "scripts/ci/cmux_next_tree_notify.py", root / "scripts/ci/")
            shutil.copy(ROOT / "scripts/ci/github_quota_client.py", root / "scripts/ci/")
            shutil.copy(ROOT / "scripts/ci/deadline_http.py", root / "scripts/ci/")
            (root / "scripts/ci/cmux_next_route.py").write_text(
                "import sys\nout = sys.argv[sys.argv.index('--github-output') + 1]\n"
                "open(out, 'a').write('native=true\\nmacos=true\\nscheme=true\\ngenerated=true\\n"
                "daemon=true\\nfast_tier=true\\n')\n")
            output, summary = root / "out", root / "summary"
            values = {"PATH": os.environ["PATH"], "EVENT_NAME": event, "GITHUB_REF": "refs/heads/feat-cmux-next",
                      "GITHUB_OUTPUT": str(output), "GITHUB_STEP_SUMMARY": str(summary), "RUNNER_TEMP": tmp,
                      "GITHUB_RUN_ATTEMPT": "1", "DEV_DAILY": "false", "TIP_SWIFT_SUITE": "false",
                      "TIP_DAEMON_SUITE": "false", "BASE_TIER": "false", "BASE_TIER_COALESCE": "true",
                      "DEV_LANDING_COMPILE": "", **env}
            subprocess.run(["bash", "-c", route_step()["run"]], cwd=root, env=values, check=True,
                           capture_output=True, text=True)
            return dict(line.split("=", 1) for line in output.read_text().splitlines() if "=" in line)

    def test_a_feat_cmux_next_push_defers_the_base_tier(self):
        out = self.run_step("push")
        self.assertEqual((out["daemon"], out["scheme"], out["generated"]), ("false", "false", "false"))
        self.assertEqual((out["native"], out["fast_tier"]), ("true", "true"))

    def test_coalescing_off_or_another_branch_runs_the_base_tier_on_the_push(self):
        for env in ({"BASE_TIER_COALESCE": "false"}, {"GITHUB_REF": "refs/heads/next-batch/1"}):
            with self.subTest(env=env):
                out = self.run_step("push", **env)
                self.assertEqual((out["daemon"], out["scheme"], out["generated"]), ("true", "true", "true"))

    def test_a_push_whose_scheme_compile_is_the_dev_landing_build_keeps_it(self):
        out = self.run_step("push", DEV_LANDING_COMPILE="0")
        self.assertEqual((out["daemon"], out["scheme"], out["generated"]), ("false", "true", "false"))

    def test_the_base_tier_dispatch_runs_exactly_the_base_tier(self):
        out = self.run_step("workflow_dispatch", BASE_TIER="true")
        self.assertEqual((out["daemon"], out["scheme"], out["generated"], out["macos"]), ("true",) * 4)
        for name in ("native", "swift", "full", "swift_canary", "cmuxnext_swift"):
            self.assertEqual(out[name], "false", name)

    def test_the_base_tier_dispatch_runs_only_on_feat_cmux_next(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_step("workflow_dispatch", BASE_TIER="true", GITHUB_REF="refs/heads/lane/x")


def tier_suites():
    sys.path.insert(0, str(ROOT / "scripts/ci"))
    import base_red_excuse
    return base_red_excuse.SUITES


class Workflows(unittest.TestCase):
    def test_the_dispatch_input_names_the_tested_commit(self):
        text = WORKFLOW.read_text()
        self.assertRegex(text, r"\n      base_tier:\n(?:        .*\n)*?        type: boolean\n")
        self.assertIn("format('cmux-next base tier · {0}', inputs.same_tree_sha || github.sha)", text)
        self.assertEqual(tier.TITLE, "cmux-next base tier · ")

    def test_its_tree_wait_marker_is_a_base_tier_suite(self):
        route = yaml.safe_load(WORKFLOW.read_text())["jobs"]["path_route"]
        marker = next(step for step in route["steps"] if step.get("id") == "marker")
        self.assertEqual(marker["env"]["BASE_TIER"], "${{ inputs.base_tier || false }}")
        self.assertIn('marker.update(tip_suite="base")', marker["run"])

    def test_push_attribution_runs_for_a_red_base_tier(self):
        jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
        self.assertIn("inputs.base_tier == true", jobs["push-attribution"]["if"])

    def test_a_red_crash_gate_alone_starts_push_attribution(self):
        # failure() reads only the needed jobs: the crash gate is one of the base tier's jobs.
        jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
        self.assertIn("crash-ends-app", jobs["push-attribution"]["needs"])

    def test_a_base_tier_run_checks_generated_files_on_their_own_job(self):
        # A pull request's standalone `cmux-next generated files` red is compared with the base tier's
        # verdict for that job, so a base tier run never folds it into daemon-test's build.
        jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
        host = jobs["path_route"]["outputs"]["generated_host"]
        self.assertTrue(host.startswith("${{ steps.route.outputs.generated != 'true' && 'none' || "
                                        "inputs.base_tier == true && 'generated-files' || "), host)
        self.assertIn("cmux-next generated files", tier_suites()["cmux-next base tier · "])
        self.assertNotIn("cmux-next generated files (shared build)", tier_suites()["cmux-next base tier · "])

    def test_the_kick_is_serialized_and_its_own_runs_are_never_cancelled(self):
        kick_doc = yaml.safe_load(KICK.read_text())
        on = kick_doc.get(True) or kick_doc.get("on")
        self.assertEqual(on, {"push": {"branches": ["feat-cmux-next"]}})
        self.assertEqual(kick_doc["concurrency"], {"group": "cmux-next-base-tier-kick", "cancel-in-progress": False})
        job = kick_doc["jobs"]["kick"]
        self.assertIn("CMUX_NEXT_BASE_TIER_COALESCE", job["if"])
        self.assertGreater(job["timeout-minutes"] * 60, tier.WINDOW_S + tier.SETTLE_S)
        self.assertEqual(job["permissions"], {"contents": "read"})
        self.assertIn("cmux_next_base_tier.py kick", job["steps"][-1]["run"])

    def test_the_kick_calls_github_with_its_own_app_token_and_no_fallback(self):
        # github.token's REST budget is every workflow's; a kick waiting it out is a polling loop on it
        # (tests/test_ci_no_github_token_polling.py), and 2026-11-10 kicks crashed on its HTTP 403s.
        steps = yaml.safe_load(KICK.read_text())["jobs"]["kick"]["steps"]
        mint = next(step for step in steps if step.get("id") == "cmux-bot-token")
        self.assertEqual(mint["uses"], "actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1")
        self.assertEqual(mint["with"]["app-id"], "${{ vars.CMUX_BOT_APP_ID }}")
        self.assertEqual(mint["with"]["private-key"], "${{ secrets.CMUX_BOT_APP_KEY }}")
        # The least the kick needs: runs, jobs, dispatch and cancel (actions), the ref and compare (contents).
        self.assertEqual({k: v for k, v in mint["with"].items() if k.startswith("permission-")},
                         {"permission-actions": "write", "permission-contents": "read"})
        # A failed mint fails the kick red: nothing lets it go on to a github.token fallback.
        self.assertNotIn("continue-on-error", mint)
        self.assertNotIn("if", mint)
        kick_step = steps[-1]
        self.assertLess(steps.index(mint), steps.index(kick_step))
        self.assertEqual(kick_step["env"], {"GH_TOKEN": "${{ steps.cmux-bot-token.outputs.token }}"})
        checkout = next(step for step in steps if "actions/checkout@" in step.get("uses", ""))
        self.assertIn("scripts/ci/github_quota_client.py", checkout["with"]["sparse-checkout"])

    def test_sleeping_dispatcher_reads_the_linux_pool(self):
        # A pure Python timer/API call reads the reconciled Linux pool, never a fixed
        # Blacksmith size that can stall (tests/test_ci_linux_single_size.py).
        expression = yaml.safe_load(KICK.read_text())["jobs"]["kick"]["runs-on"]
        self.assertIn("'ubuntu-24.04'", expression)
        self.assertNotIn("32vcpu", expression)
        self.assertNotIn("vars.LINUX_RUNNER", expression)
        self.assertTrue(expression.rstrip().endswith("|| fromJSON(vars.RUNNER_POOLS).linux }}"), expression)

    def test_the_push_and_the_kick_read_the_same_switch(self):
        env = route_step()["env"]
        self.assertIn("vars.CMUX_NEXT_BASE_TIER_COALESCE) != '0'", env["BASE_TIER_COALESCE"])
        self.assertIn("vars.CMUX_NEXT_BASE_TIER_COALESCE) != '0'", yaml.safe_load(KICK.read_text())["jobs"]["kick"]["if"])

    def test_nightly_dev_and_release_producers_are_not_deferred(self):
        # Only the three base tier outputs are rewritten; nightly-next's Release compile (native), the DEV
        # landing compile (its own job) and the fast tier keep their push routing.
        self.assertEqual(tier.TIERS, ("daemon", "scheme", "generated"))
        text = route_step()["run"]
        self.assertTrue(re.search(r'"\$EVENT_NAME" == push && "\$GITHUB_REF" == refs/heads/feat-cmux-next && '
                                  r'"\$BASE_TIER_COALESCE" == true', text))


if __name__ == "__main__":
    unittest.main()
