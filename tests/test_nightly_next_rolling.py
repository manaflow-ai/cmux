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

    def test_nothing_waiting_needs_no_promotion(self):
        go, reason = decide(head_runs=[run(12, 12)], waited_minutes=None)
        self.assertFalse(go, reason)
        self.assertTrue(decide(head="")[0], "an empty head asks as before")

    def test_an_unknown_gap_counts_as_an_old_landing(self):
        go, reason = rolling.decide(NOW, head=HEAD, head_runs=[run(14, 12)], jobs_of=lambda r: BUILDING,
                                    promotions=[], oldest_waiting=rolling.UNKNOWN)
        self.assertTrue(go, reason)
        self.assertIn("unknown", reason)


class OneStartPerWindowTests(unittest.TestCase):
    """At most one new build per window while builds run, always the newest buildable commit.

    2026-10-29: after a cmux-tui tree stall every waiting landing was already past the window, so
    the ticks at 04:25:53, 04:28:13 and 04:29:13 each promoted (three starts in four minutes) and
    five nightly-next builds ran at once on contended runners. A started build is never cancelled."""

    def at_clock(self, hhmmss: str) -> dt.datetime:
        return dt.datetime.fromisoformat(f"2026-10-29T{hhmmss}+00:00")

    def stamp(self, hhmmss: str) -> str:
        return f"2026-10-29T{hhmmss}Z"

    def test_a_build_started_inside_the_window_holds_an_old_landing(self):
        start = run(30, 4, head_sha=HEAD)
        go, reason = rolling.decide(NOW, head=HEAD, head_runs=[start], jobs_of=lambda r: BUILDING, promotions=[],
                                    oldest_waiting=(WAITING, NOW - dt.timedelta(minutes=24)), starts=[start])
        self.assertFalse(go, reason)
        self.assertIn("started 4 of 10 min ago", reason)

    def test_once_the_newest_start_is_a_window_old_the_newest_tip_starts_beside_it(self):
        start = run(31, 12, head_sha=HEAD)
        go, reason = rolling.decide(NOW, head=HEAD, head_runs=[start], jobs_of=lambda r: BUILDING, promotions=[],
                                    oldest_waiting=(WAITING, NOW - dt.timedelta(minutes=24)), starts=[start])
        self.assertTrue(go, reason)
        self.assertIn("beside", reason)

    def test_an_older_commit_s_newer_start_still_counts(self):
        """The newest start may be another commit's run (nightly-next moved on since)."""
        mine = run(32, 30, head_sha=HEAD)
        other = run(33, 3, head_sha="e" * 40)
        go, reason = rolling.decide(NOW, head=HEAD, head_runs=[mine], jobs_of=lambda r: BUILDING, promotions=[],
                                    oldest_waiting=(WAITING, NOW - dt.timedelta(minutes=24)), starts=[mine, other])
        self.assertFalse(go, reason)

    def test_a_promotion_seconds_old_counts_as_a_start_before_its_run_exists(self):
        """Tick 40817979989 promoted at 04:29:13, 4 s after promotion 40818000917 moved nightly-next."""
        promo = run(34, 0.07, status="completed", display_title="Promote nightly-next to tick:" + WAITING)
        go, reason = rolling.decide(NOW, head=HEAD, head_runs=[], jobs_of=lambda r: [], promotions=[promo],
                                    oldest_waiting=(WAITING, NOW - dt.timedelta(minutes=24)), starts=[])
        self.assertFalse(go, reason)
        self.assertRegex(reason, r"a build started [0-9]+ s ago")

    def test_a_running_promotion_past_the_race_window_is_still_a_start(self):
        """Review of 225721ef: a 3-minute-old promotion still running, its push run not listed, let
        an old landing promote a second build."""
        promo = run(38, 3, status="in_progress", display_title="Promote nightly-next to tick:" + WAITING)
        go, reason = rolling.decide(NOW, head=HEAD, head_runs=[], jobs_of=lambda r: [], promotions=[promo],
                                    oldest_waiting=(WAITING, NOW - dt.timedelta(minutes=24)), starts=[])
        self.assertFalse(go, reason)
        self.assertIn("started 3 of 10 min ago", reason)
        stale = run(39, 16, status="in_progress", display_title="Promote nightly-next to tick:" + WAITING)
        self.assertTrue(rolling.decide(NOW, head=HEAD, head_runs=[], jobs_of=lambda r: [], promotions=[stale],
                                       oldest_waiting=(WAITING, NOW - dt.timedelta(minutes=24)), starts=[])[0],
                        "a promotion stuck past PROMOTION_MINUTES is not a start")

    def test_a_failed_read_after_a_young_start_waits(self):
        """Review of 225721ef: a jobs or promotion read that fails must not bypass a start it already saw."""
        for broken in ("event=workflow_dispatch", "/jobs?"):
            with self.subTest(broken=broken):
                api = api_for(compare("ahead", [(WAITING, 30)]), runs=[run(40, 4, head_sha=HEAD)])
                api.routes[broken] = OSError("502")
                go, reason = rolling.evaluate(NOW, "o/r", TIP, api=api)
                self.assertFalse(go, reason)
                self.assertIn("so waiting", reason)
        old = api_for(compare("ahead", [(WAITING, 30)]), runs=[run(41, 30, head_sha=HEAD)])
        old.routes["/jobs?"] = OSError("502")
        self.assertTrue(rolling.evaluate(NOW, "o/r", TIP, api=old)[0], "an old start and a failed read still promote")

    def test_with_nothing_building_and_no_recent_start_it_promotes_at_once(self):
        promo = run(35, 3, status="completed", display_title="Promote nightly-next to tick:" + WAITING)
        done = run(36, 40, status="completed", head_sha=HEAD)
        go, reason = rolling.decide(NOW, head=HEAD, head_runs=[done], jobs_of=lambda r: [], promotions=[promo],
                                    oldest_waiting=(WAITING, NOW - dt.timedelta(minutes=1)), starts=[done])
        self.assertTrue(go, reason)
        self.assertIn("nothing is building", reason)

    def test_replay_of_the_0425_burst_starts_one_build_not_three(self):
        """The ticks of 2026-10-29 04:25-04:32 against the runs that existed when each ran."""
        b0bb = {**run(40815647360, 0), "created_at": self.stamp("04:04:16"), "head_sha": "0bb2eda1" + "0" * 32}
        b1857 = {**run(40817728360, 0), "created_at": self.stamp("04:26:08"), "head_sha": "185716ef" + "0" * 32}
        promo_1857 = {**run(40817698795, 0, status="completed"), "created_at": self.stamp("04:25:49"),
                      "display_title": "Promote nightly-next to tick:185716e"}
        decisions = []
        for clock, head, starts, promos, oldest in (
                # Tick 40817598158 (its decision at 04:25:3x) made promotion 40817698795 for 185716ef.
                ("04:25:35", b0bb["head_sha"], [b0bb], [], "04:03:56"),
                # Tick 40817657120: 4 s after that promotion, before its run existed.
                ("04:25:53", b0bb["head_sha"], [b0bb], [promo_1857], "04:03:56"),
                ("04:28:13", b1857["head_sha"], [b0bb, b1857], [promo_1857], "04:05:00"),
                ("04:29:13", b1857["head_sha"], [b0bb, b1857], [promo_1857], "04:05:00"),
                ("04:31:41", b1857["head_sha"], [b0bb, b1857], [promo_1857], "04:05:00"),
                ("04:36:20", b1857["head_sha"], [b0bb, b1857], [promo_1857], "04:05:00")):
            now = self.at_clock(clock)
            head_runs = [r for r in starts if r["head_sha"] == head]
            go, _ = rolling.decide(now, head=head, head_runs=head_runs, jobs_of=lambda r: BUILDING,
                                   promotions=promos, starts=starts,
                                   oldest_waiting=(WAITING, self.at_clock(oldest)))
            decisions.append((clock, go))
        # 04:25:35 is the promotion that did happen (0bb2's build started 21 min before); every later
        # tick waits until 185716ef's build is a window old (04:36:08), then the newest tip starts.
        # Before: 04:28:13 and 04:29:13 started 68e51e81 and 913e9372 as well.
        self.assertEqual(decisions, [("04:25:35", True), ("04:25:53", False), ("04:28:13", False),
                                     ("04:29:13", False), ("04:31:41", False), ("04:36:20", True)])

    def test_evaluate_reads_one_listing_of_nightly_next_runs(self):
        api = api_for(compare("ahead", [(WAITING, 30)]), runs=[run(37, 4, head_sha=HEAD)])
        go, reason = rolling.evaluate(NOW, "o/r", TIP, api=api)
        self.assertFalse(go, reason)
        listing = [p for p in api.paths if "branch=nightly-next" in p]
        self.assertEqual(len(listing), 1)
        self.assertIn("event=push", listing[0])
        self.assertNotIn("head_sha=", listing[0])


TIP = "c" * 40


class Api:
    """Answers by path prefix, as `gh api` does; a value that is an exception is raised."""

    def __init__(self, routes: dict):
        self.routes, self.paths = routes, []

    def __call__(self, path: str):
        self.paths.append(path)
        for prefix, value in self.routes.items():
            if prefix in path:
                if isinstance(value, Exception):
                    raise value
                return value
        raise AssertionError(f"unexpected read {path}")


def compare(status: str, commits: list[tuple[str, float]], ahead_by: int | None = None) -> dict:
    """The compare API's shape: commits oldest first, each with commit.committer.date."""
    return {"status": status, "ahead_by": len(commits) if ahead_by is None else ahead_by, "behind_by": 0,
            "commits": [{"sha": sha, "commit": {"committer": {"date": at(minutes)}}} for sha, minutes in commits]}


def api_for(compare_answer, ref=None, runs=None, jobs=None) -> Api:
    return Api({
        "/git/ref/heads/nightly-next": ref if ref is not None else {"ref": "refs/heads/nightly-next", "object": {"sha": HEAD, "type": "commit"}},
        f"/compare/{HEAD}...{TIP}?per_page=1&page=1": compare_answer,
        "branch=nightly-next": {"total_count": 1, "workflow_runs": runs if runs is not None else [run(20, 12, head_sha=HEAD)]},
        "event=workflow_dispatch": {"total_count": 0, "workflow_runs": []},
        "/jobs?": {"total_count": 2, "jobs": jobs if jobs is not None else BUILDING},
    })


class ApiReadTests(unittest.TestCase):
    """Every read is an API read with the job's token: no git remote (the tick checks out with
    persist-credentials: false) and no shallow history (it fetches 150 commits)."""

    def test_the_head_comes_from_the_refs_api_and_the_gap_from_compare(self):
        api = api_for(compare("ahead", [(WAITING, 4), ("d" * 40, 2)]))
        go, reason = rolling.evaluate(NOW, "o/r", TIP, api=api)
        self.assertFalse(go, reason)
        self.assertIn("repos/o/r/git/ref/heads/nightly-next", api.paths)
        self.assertIn(f"repos/o/r/compare/{HEAD}...{TIP}?per_page=1&page=1", api.paths)
        self.assertNotIn("ls-remote", SCRIPT.read_text(encoding="utf-8"))

    def test_the_oldest_waiting_commit_is_page_one_of_a_one_per_page_compare(self):
        """Page 1 at per_page=1 is the oldest commit after nightly-next (the API's documented order)."""
        api = api_for(compare("ahead", [(WAITING, 11)], ahead_by=2))
        go, reason = rolling.evaluate(NOW, "o/r", TIP, api=api)
        self.assertTrue(go, reason)
        self.assertIn(WAITING[:12], reason)

    def test_a_gap_past_250_commits_still_finds_its_oldest_landing(self):
        """An unpaginated compare stops at 250 commits ending at the newest; page 1 of one per page
        is the oldest whatever the gap, and no shallow checkout is involved."""
        api = api_for(compare("ahead", [(WAITING, 300)], ahead_by=400))
        go, reason = rolling.evaluate(NOW, "o/r", TIP, api=api)
        self.assertTrue(go, reason)
        self.assertIn("waited 300 min", reason)
        self.assertTrue(all("/compare/" not in p or p.endswith("?per_page=1&page=1") for p in api.paths), api.paths)

    def test_a_tip_at_or_behind_nightly_next_waits_for_nothing(self):
        for status in ("identical", "behind"):
            with self.subTest(status=status):
                go, reason = rolling.evaluate(NOW, "o/r", TIP, api=api_for(compare(status, [])))
                self.assertFalse(go, reason)

    def test_an_unknown_gap_promotes(self):
        """A failed compare, a diverged nightly-next (a train commit) or an empty list: the oldest
        landing counts as old."""
        for answer in (OSError("502"), compare("diverged", [(WAITING, 1)]), compare("ahead", [], ahead_by=3)):
            with self.subTest(answer=repr(answer)[:40]):
                go, reason = rolling.evaluate(NOW, "o/r", TIP, api=api_for(answer))
                self.assertTrue(go, reason)
                self.assertIn("unknown", reason)

    def test_an_unreadable_nightly_next_waits_for_the_backstop_and_says_so(self):
        """Never a silent go: the feed watch's dispatch for one commit skips this rule."""
        go, reason = rolling.evaluate(NOW, "o/r", TIP, api=api_for(compare("ahead", []), ref=OSError("401")))
        self.assertFalse(go)
        self.assertIn("could not read nightly-next", reason)

    def test_other_failed_reads_promote_and_say_so(self):
        api = api_for(compare("ahead", [(WAITING, 4)]), jobs=None)
        api.routes["branch=nightly-next"] = OSError("rate limited")
        go, reason = rolling.evaluate(NOW, "o/r", TIP, api=api)
        self.assertTrue(go)
        self.assertIn("could not read the running builds", reason)

    def test_main_writes_its_answer_without_any_git_remote(self):
        with tempfile.TemporaryDirectory() as scratch:
            out = Path(scratch) / "out"
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--repo", "o/r", "--tip", TIP],
                capture_output=True, text=True, cwd=scratch,
                env={"GITHUB_OUTPUT": str(out), "PATH": "/nonexistent"})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("go=false", out.read_text())
            self.assertIn("::warning title=nightly-next rolling rule::", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
