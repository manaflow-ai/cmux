#!/usr/bin/env python3
"""The nightly-next tick's rolling rule (scripts/ci/nightly_next_rolling.py).

The tick runs at landing; this rule decides whether it promotes now. Nothing building:
promote at once. A build running: promote once the oldest landing it does not carry has
waited the window (10 minutes), so a burst of landings becomes one build of the newest tip
beside the running one. A run that has not started (queued 10 minutes without a runner)
is not building anything.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/ci/nightly_next_rolling.py"
spec = importlib.util.spec_from_file_location("nightly_next_rolling", SCRIPT)
rolling = importlib.util.module_from_spec(spec)
sys.modules["nightly_next_rolling"] = rolling
spec.loader.exec_module(rolling)

NOW = dt.datetime(2026, 10, 29, 2, 0, tzinfo=dt.timezone.utc)
HEAD = "a" * 40
WAITING = "b" * 40


def at(minutes_ago: float) -> str:
    return (NOW - dt.timedelta(minutes=minutes_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")


LIVE = json.loads((Path(__file__).resolve().parent / "fixtures/nightly_next_live_run_jobs.json").read_text(encoding="utf-8"))


def run(run_id: int, minutes_ago: float, status: str = "in_progress", **extra) -> dict:
    """The recorded runs API payload of a nightly-next run, re-timed."""
    stamp = at(minutes_ago)
    return {**LIVE["run"], "id": run_id, "status": status, "conclusion": None, "created_at": stamp,
            "run_started_at": stamp, "html_url": f"https://github.com/o/r/actions/runs/{run_id}", **extra}


def job(name: str, status: str, minutes_ago: float = 1.0, runner: str = "", drop: tuple[str, ...] = ()) -> dict:
    """A recorded jobs API payload (tests/fixtures/nightly_next_live_run_jobs.json), re-timed: a queued
    job with no runner has runner_name "" and runner_id 0, as GitHub sends it."""
    base = LIVE["jobs"]["queued_deltas" if not runner else "mac_build_done"]
    stamp = at(minutes_ago)
    out = {**base, "name": name, "status": status, "created_at": stamp, "started_at": stamp,
           "conclusion": "success" if status == "completed" else None,
           "runner_name": runner or "", "runner_id": 1 if runner else 0}
    for field in drop:
        out.pop(field, None)
    return out


BUILDING = [job("decide", "completed", 12, "r"), job("build-nightly-app", "in_progress", 11, "mac")]


def decide(head_runs=(), jobs=None, promotions=(), waited_minutes: float | None = 5.0, head: str = HEAD):
    jobs_by_run = jobs or {}
    oldest = None if waited_minutes is None else (WAITING, NOW - dt.timedelta(minutes=waited_minutes))
    return rolling.decide(NOW, head=head, head_runs=list(head_runs),
                          jobs_of=lambda r: jobs_by_run.get(r["id"], BUILDING),
                          promotions=list(promotions), oldest_waiting=oldest)


class RollingRuleTests(unittest.TestCase):
    def test_nothing_building_promotes_at_once(self):
        """A landing on a quiet branch starts its build within minutes, not at the next cron."""
        go, reason = decide(head_runs=[run(1, 40, status="completed")])
        self.assertTrue(go, reason)
        self.assertIn("nothing is building", reason)

    def test_a_running_build_holds_a_landing_inside_the_window(self):
        """A burst of landings coalesces: the running build covers a wait under 10 minutes."""
        go, reason = decide(head_runs=[run(2, 12)], waited_minutes=5)
        self.assertFalse(go, reason)
        self.assertIn("runs/2", reason)

    def test_a_landing_that_waited_the_window_builds_beside_the_running_one(self):
        """Rulebook, Nightly freshness: a newer tip builds alongside a running one."""
        go, reason = decide(head_runs=[run(3, 25)], waited_minutes=10.5)
        self.assertTrue(go, reason)
        self.assertIn("beside", reason)

    def test_a_queued_run_that_never_started_is_not_building(self):
        """Run 40738012059: `decide` queued 73 minutes on a label that started nothing."""
        stuck = {4: [job("decide", "queued", 15)]}
        go, reason = decide(head_runs=[run(4, 15, status="queued")], jobs=stuck, waited_minutes=5)
        self.assertTrue(go, reason)
        self.assertIn("nothing is building", reason)

    def test_a_run_whose_mac_job_waits_without_a_runner_is_not_building(self):
        stuck = {5: [job("decide", "completed", 30, "r"), job("build-nightly-app", "queued", 25)]}
        go, _ = decide(head_runs=[run(5, 31)], jobs=stuck, waited_minutes=5)
        self.assertTrue(go)

    def test_a_queued_job_without_times_is_aged_from_its_run(self):
        """The jobs API may omit a queued job's times; a missing time is never zero age."""
        bare = {13: [job("decide", "queued", drop=("created_at", "started_at"))]}
        go, _ = decide(head_runs=[run(13, 30, status="queued")], jobs=bare, waited_minutes=5)
        self.assertTrue(go, "a 30-minute-old run whose job has no time is not building")
        go, _ = decide(head_runs=[run(13, 3, status="queued")], jobs=bare, waited_minutes=5)
        self.assertFalse(go, "a 3-minute-old one still is")

    def test_a_job_queued_briefly_still_counts_as_building(self):
        fresh = {6: [job("decide", "completed", 3, "r"), job("build-nightly-app", "queued", 2)]}
        go, _ = decide(head_runs=[run(6, 3)], jobs=fresh, waited_minutes=5)
        self.assertFalse(go)

    def test_a_job_waiting_on_an_environment_is_gated_not_stuck(self):
        gated = {7: [job("publish-nightly", "waiting", 40)]}
        go, _ = decide(head_runs=[run(7, 45, status="waiting")], jobs=gated, waited_minutes=5)
        self.assertFalse(go)

    def test_a_published_run_is_done_even_while_its_deltas_run(self):
        """Run 40799674473 published at 34 min and ran deltas until 47: the feed already had it."""
        published = {8: [job("publish-nightly", "completed", 13, "r"),
                         job("generate-nightly-deltas (arm64)", "in_progress", 13, "mac")]}
        go, reason = decide(head_runs=[run(8, 47)], jobs=published, waited_minutes=5)
        self.assertTrue(go, reason)

    def test_a_fresh_promotion_counts_as_building(self):
        promo = run(9, 3, status="in_progress", display_title="Promote nightly-next to " + WAITING)
        go, reason = decide(promotions=[promo], waited_minutes=5)
        self.assertFalse(go, reason)
        self.assertIn("promotion run", reason)

    def test_a_stale_or_unrelated_promotion_does_not(self):
        stale = run(10, 40, status="queued", display_title="Promote nightly-next to " + WAITING)
        other = run(11, 2, status="in_progress", display_title="Nightly macOS build")
        go, _ = decide(promotions=[stale, other], waited_minutes=5)
        self.assertTrue(go)

    def test_unknowns_fail_open(self):
        """The promotion ignores a request that moves nothing, so asking is the safe side."""
        self.assertTrue(decide(head="")[0])
        self.assertTrue(decide(head_runs=[run(12, 12)], waited_minutes=None)[0])

    def test_main_fails_open_when_reads_fail(self):
        with tempfile.TemporaryDirectory() as scratch:
            out = Path(scratch) / "out"
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--repo", "o/r", "--checkout", scratch],
                capture_output=True, text=True, env={"GITHUB_OUTPUT": str(out), "PATH": "/nonexistent"})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("go=true", out.read_text())


class OldestAfterTests(unittest.TestCase):
    def test_the_oldest_first_parent_commit_after_head(self):
        with tempfile.TemporaryDirectory() as repo:
            def git(*args, date=None):
                env = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                       "GIT_COMMITTER_EMAIL": "t@t", "PATH": "/usr/bin:/bin"}
                if date:
                    env.update(GIT_AUTHOR_DATE=date, GIT_COMMITTER_DATE=date)
                return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True,
                                      text=True, env=env).stdout.strip()
            git("init", "-q")
            git("commit", "-q", "--allow-empty", "-m", "head", date="2026-10-29T01:00:00Z")
            head = git("rev-parse", "HEAD")
            git("commit", "-q", "--allow-empty", "-m", "first", date="2026-10-29T01:10:00Z")
            first = git("rev-parse", "HEAD")
            git("commit", "-q", "--allow-empty", "-m", "second", date="2026-10-29T01:20:00Z")
            sha, landed = rolling.oldest_after(repo, head)
            self.assertEqual(sha, first)
            self.assertEqual(landed, dt.datetime(2026, 10, 29, 1, 10, tzinfo=dt.timezone.utc))
            self.assertIsNone(rolling.oldest_after(repo, "c" * 40), "a head outside this history")
            self.assertIsNone(rolling.oldest_after(repo, git("rev-parse", "HEAD")), "nothing waits")


if __name__ == "__main__":
    unittest.main(verbosity=2)
