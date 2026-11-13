#!/usr/bin/env python3
"""The nightly-next tick's rolling rule (scripts/ci/nightly_next_rolling.py).

The tick runs at landing; this rule decides whether it promotes now. Nothing building:
promote at once. A nightly-next push run building (any commit's): wait, because nightly-next
pushes share one concurrency group and a promotion now would get the run waiting on it
cancelled; the build's own finish ticks again and promotes the newest tip. A run that has
not started (queued 10 minutes without a runner) is not building anything.
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

    def test_a_landing_that_waited_the_window_still_waits_for_the_running_build(self):
        """ask-4f5b99b22b (2026-11-12 00:40-02:56Z): nightly-next pushes share one concurrency group, so
        each promotion beside a running build got the run waiting on that group cancelled, 13 of 17."""
        go, reason = decide(head_runs=[run(3, 25)], waited_minutes=10.5)
        self.assertFalse(go, reason)
        self.assertIn("cancel", reason)

    def test_an_older_commit_s_running_build_holds_the_promotion(self):
        """nightly-next moved on (its head's run waits on the push group) while an older commit's run
        builds: that build holds the group, so promoting would cancel the head's waiting run."""
        holder = run(15, 30, head_sha="e" * 40)
        waiting = run(16, 12, status="pending", head_sha=HEAD)
        go, reason = rolling.decide(NOW, head=HEAD, head_runs=[waiting],
                                    jobs_of=lambda r: BUILDING if r["id"] == 15 else [], promotions=[],
                                    oldest_waiting=(WAITING, NOW - dt.timedelta(minutes=24)),
                                    starts=[holder, waiting])
        self.assertFalse(go, reason)
        self.assertIn("runs/15", reason)

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

    def test_a_published_run_still_holds_the_push_group_while_its_tail_runs(self):
        """Run 40799674473 published at 34 min and ran deltas until 47. The feed had it, but the run held
        the push group until 47, so a promotion before then got the run waiting on it cancelled."""
        published = {8: [job("publish-nightly", "completed", 13, "r"),
                         job("generate-nightly-deltas (arm64)", "in_progress", 13, "mac")]}
        go, reason = decide(head_runs=[run(8, 47)], jobs=published, waited_minutes=5)
        self.assertFalse(go, reason)
        go, reason = decide(head_runs=[run(8, 47, status="completed")], jobs=published, waited_minutes=5)
        self.assertTrue(go, reason)

    def test_the_loop_s_retry_holds_the_push_group(self):
        """Review of e39fee31: a retry (workflow_dispatch, 'Retry nightly-next (N of 2)') takes the push
        group; another dispatch on nightly-next (a sign stage, a resume) does not."""
        retry = run(17, 20, event="workflow_dispatch", display_title="Retry nightly-next (1 of 2)", head_sha="e" * 40)
        sign = run(18, 20, event="workflow_dispatch", display_title="Sign nightly-next run 1 attempt 1", head_sha="e" * 40)
        for holder, holds in ((retry, True), (sign, False)):
            with self.subTest(title=holder["display_title"]):
                go, reason = rolling.decide(NOW, head=HEAD, head_runs=[], jobs_of=lambda r: BUILDING, promotions=[],
                                            oldest_waiting=(WAITING, NOW - dt.timedelta(minutes=24)),
                                            starts=[holder])
                self.assertEqual(go, not holds, reason)

    def test_a_retry_of_nightly_next_s_head_does_not_hold_a_newer_landing(self):
        """Tick 43440928169 (2026-11-13 14:15:01Z) waited on retry 43440656795 ('Retry nightly-next (2 of 2)',
        created 14:13:19Z) of 6ed5ffc2e386, nightly-next's head, a build that had already failed: "the newest
        build started 3 of 5 min ago; the next start ... waits for it to finish". The retry leaves the build
        slot only when a newer nightly-next push arrives (resolve-leave-build-slot.sh on feat-cmux-next),
        and no tick promoted one while it ran, so each such retry cost 19-41 min (43395284047, 43440656795).
        A retry of the head with a newer commit waiting is neither a holder nor a start: promote."""
        head = "6ed5ffc2e386abe13409809e500022e1a73586ef"
        retry = run(43440656795, 1.7, event="workflow_dispatch", display_title="Retry nightly-next (2 of 2)",
                    head_sha=head)
        go, reason = rolling.decide(NOW, head=head, head_runs=[retry], jobs_of=lambda r: BUILDING, promotions=[],
                                    oldest_waiting=(WAITING, NOW - dt.timedelta(minutes=24)), starts=[retry],
                                    window_minutes=5)
        self.assertTrue(go, reason)
        self.assertIn("nothing is building", reason)
        with self.subTest("nothing waits after the head: the retry is the newest build, so it holds"):
            go, reason = rolling.decide(NOW, head=head, head_runs=[retry], jobs_of=lambda r: BUILDING,
                                        promotions=[], oldest_waiting=None, starts=[retry], window_minutes=5)
            self.assertFalse(go, reason)
        with self.subTest("a retry of an older commit (nightly-next moved past it) still holds"):
            older = {**retry, "head_sha": "e" * 40}
            go, reason = rolling.decide(NOW, head=head, head_runs=[], jobs_of=lambda r: BUILDING, promotions=[],
                                        oldest_waiting=(WAITING, NOW - dt.timedelta(minutes=24)), starts=[older],
                                        window_minutes=5)
            self.assertFalse(go, reason)
        with self.subTest("an ordinary push build of the head still holds"):
            push = run(43440000000, 1.7, head_sha=head)
            go, reason = rolling.decide(NOW, head=head, head_runs=[push], jobs_of=lambda r: BUILDING, promotions=[],
                                        oldest_waiting=(WAITING, NOW - dt.timedelta(minutes=24)), starts=[push],
                                        window_minutes=5)
            self.assertFalse(go, reason)
        with self.subTest("a promotion seconds old still counts as a start"):
            promo = run(43440000002, 0.07, status="completed", display_title="Promote nightly-next to tick:" + WAITING)
            go, reason = rolling.decide(NOW, head=head, head_runs=[retry], jobs_of=lambda r: BUILDING,
                                        promotions=[promo], oldest_waiting=(WAITING, NOW - dt.timedelta(minutes=24)),
                                        starts=[retry], window_minutes=5)
            self.assertFalse(go, reason)

    def test_evaluate_promotes_past_a_retry_of_the_head(self):
        """The same tick through evaluate's one listing (retries are dispatches in it)."""
        retry = run(43440656795, 1.7, event="workflow_dispatch", display_title="Retry nightly-next (2 of 2)",
                    head_sha=HEAD)
        api = api_for(compare("ahead", [(WAITING, 30)]), runs=[retry])
        go, reason = rolling.evaluate(NOW, "o/r", TIP, api=api, window_minutes=5)
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
        self.assertFalse(go, "a running build holds even an unknown gap")
        go, reason = rolling.decide(NOW, head=HEAD, head_runs=[run(14, 40, status="completed")],
                                    jobs_of=lambda r: [], promotions=[], oldest_waiting=rolling.UNKNOWN)
        self.assertTrue(go, reason)


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

    def test_a_window_old_start_still_waits_while_it_builds(self):
        start = run(31, 12, head_sha=HEAD)
        go, reason = rolling.decide(NOW, head=HEAD, head_runs=[start], jobs_of=lambda r: BUILDING, promotions=[],
                                    oldest_waiting=(WAITING, NOW - dt.timedelta(minutes=24)), starts=[start])
        self.assertFalse(go, reason)
        done = {**start, "status": "completed"}
        go, reason = rolling.decide(NOW, head=HEAD, head_runs=[done], jobs_of=lambda r: [], promotions=[],
                                    oldest_waiting=(WAITING, NOW - dt.timedelta(minutes=24)), starts=[done])
        self.assertTrue(go, "its finish promotes the newest tip")

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
        # Every tick waits while a build runs (one push group: a promotion would cancel the waiting
        # run); the builds' own finishes promote the newest tip. Before: 04:28:13 and 04:29:13 started
        # 68e51e81 and 913e9372 as well, and 04:25:35 and 04:36:20 promoted beside a running build.
        self.assertEqual(decisions, [("04:25:35", False), ("04:25:53", False), ("04:28:13", False),
                                     ("04:29:13", False), ("04:31:41", False), ("04:36:20", False)])

    def test_evaluate_reads_one_listing_of_nightly_next_runs(self):
        api = api_for(compare("ahead", [(WAITING, 30)]), runs=[run(37, 4, head_sha=HEAD)])
        go, reason = rolling.evaluate(NOW, "o/r", TIP, api=api)
        self.assertFalse(go, reason)
        listing = [p for p in api.paths if "branch=nightly-next" in p]
        self.assertEqual(len(listing), 1)
        self.assertNotIn("event=", listing[0], "the loop's retries are dispatches; one listing reads both")
        self.assertNotIn("head_sha=", listing[0])


TIP = "c" * 40
# nightly-next's head built and finished: nothing holds the push group, so the rule promotes.
IDLE = [run(21, 40, status="completed", head_sha=HEAD)]


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
    """nightly-next's head comes from git ls-remote of the public repository (no token, no API
    budget), the refs API as its fallback; every other read is an API read with the job's token
    and no shallow history (it fetches 150 commits)."""

    def test_the_head_comes_from_the_refs_api_and_the_gap_from_compare(self):
        api = api_for(compare("ahead", [(WAITING, 4), ("d" * 40, 2)]))
        go, reason = rolling.evaluate(NOW, "o/r", TIP, api=api)
        self.assertFalse(go, reason)
        self.assertIn("repos/o/r/git/ref/heads/nightly-next", api.paths)
        self.assertIn(f"repos/o/r/compare/{HEAD}...{TIP}?per_page=1&page=1", api.paths)

    def test_the_head_comes_from_ls_remote_first_and_spends_no_api_read(self):
        """2026-11-04: an exhausted installation budget failed the refs API read, and ticks
        41791114042 and 41791169626 promoted nothing. git ls-remote costs no API budget."""
        api = api_for(compare("ahead", [(WAITING, 4), ("d" * 40, 2)]))
        asked = []
        go, reason = rolling.evaluate(NOW, "o/r", TIP, api=api,
                                      ls_remote=lambda repo, branch: asked.append((repo, branch)) or HEAD)
        self.assertFalse(go, reason)
        self.assertEqual(asked, [("o/r", "nightly-next")])
        self.assertNotIn("repos/o/r/git/ref/heads/nightly-next", api.paths)
        self.assertIn(f"repos/o/r/compare/{HEAD}...{TIP}?per_page=1&page=1", api.paths)

    def test_a_rate_limited_refs_api_still_decides_when_ls_remote_answers(self):
        api = api_for(compare("ahead", [(WAITING, 30)]), ref=OSError("HTTP 403: API rate limit exceeded for installation"),
                      runs=IDLE)
        go, reason = rolling.evaluate(NOW, "o/r", TIP, api=api, ls_remote=lambda repo, branch: HEAD)
        self.assertNotIn("could not read nightly-next", reason)
        self.assertTrue(go, reason)

    def test_a_failed_ls_remote_falls_back_to_the_refs_api(self):
        def broken(repo, branch):
            raise OSError("git: not found")
        api = api_for(compare("ahead", [(WAITING, 4), ("d" * 40, 2)]))
        go, reason = rolling.evaluate(NOW, "o/r", TIP, api=api, ls_remote=broken)
        self.assertFalse(go, reason)
        self.assertIn("repos/o/r/git/ref/heads/nightly-next", api.paths)

    def test_main_reads_the_head_with_ls_remote(self):
        self.assertIn("ls_remote=watch.ls_remote_sha", SCRIPT.read_text(encoding="utf-8"))

    def test_the_oldest_waiting_commit_is_page_one_of_a_one_per_page_compare(self):
        """Page 1 at per_page=1 is the oldest commit after nightly-next (the API's documented order)."""
        api = api_for(compare("ahead", [(WAITING, 11)], ahead_by=2), runs=[run(20, 12, head_sha=HEAD)])
        self.assertEqual(rolling.oldest_after(api, "o/r", HEAD, TIP)[0], WAITING)
        self.assertIn(f"repos/o/r/compare/{HEAD}...{TIP}?per_page=1&page=1", api.paths)

    def test_a_gap_past_250_commits_still_finds_its_oldest_landing(self):
        """An unpaginated compare stops at 250 commits ending at the newest; page 1 of one per page
        is the oldest whatever the gap, and no shallow checkout is involved."""
        api = api_for(compare("ahead", [(WAITING, 300)], ahead_by=400), runs=IDLE)
        go, reason = rolling.evaluate(NOW, "o/r", TIP, api=api)
        self.assertTrue(go, reason)
        sha, landed = rolling.oldest_after(api, "o/r", HEAD, TIP)
        self.assertEqual((sha, round((NOW - landed).total_seconds() / 60)), (WAITING, 300))
        self.assertTrue(all("/compare/" not in p or p.endswith("?per_page=1&page=1") for p in api.paths), api.paths)

    def test_a_tip_at_or_behind_nightly_next_waits_for_nothing(self):
        for status in ("identical", "behind"):
            with self.subTest(status=status):
                go, reason = rolling.evaluate(NOW, "o/r", TIP, api=api_for(compare(status, [])))
                self.assertFalse(go, reason)

    def test_an_unknown_gap_promotes(self):
        """A failed compare, a diverged nightly-next (a train commit) or an empty list: unknown, which
        promotes when nothing builds (and waits, like any gap, while a push run builds)."""
        for answer in (OSError("502"), compare("diverged", [(WAITING, 1)]), compare("ahead", [], ahead_by=3)):
            with self.subTest(answer=repr(answer)[:40]):
                self.assertEqual(rolling.oldest_after(api_for(answer), "o/r", HEAD, TIP), rolling.UNKNOWN)
                go, reason = rolling.evaluate(NOW, "o/r", TIP, api=api_for(answer, runs=IDLE))
                self.assertTrue(go, reason)

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



def git_repo(scratch: str):
    """A linear history of four commits a minute apart (committer dates set), and a side commit off
    the second: git(*args) runs in it."""
    env = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
           "GIT_COMMITTER_EMAIL": "t@t", "HOME": scratch, "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"}

    def git(*args: str, when: str | None = None) -> str:
        extra = {"GIT_COMMITTER_DATE": when, "GIT_AUTHOR_DATE": when} if when else {}
        return subprocess.run(["git", "-C", scratch, *args], check=True, capture_output=True, text=True,
                              env={**env, **extra}).stdout

    git("init", "-q", "-b", "main")
    shas = []
    for minutes in (40, 30, 20, 10):
        git("commit", "-q", "--allow-empty", "-m", f"c{minutes}", when=at(minutes))
        shas.append(git("rev-parse", "HEAD").strip())
    git("checkout", "-q", "-b", "side", shas[1])
    git("commit", "-q", "--allow-empty", "-m", "side", when=at(5))
    shas.append(git("rev-parse", "HEAD").strip())
    return git, shas


class LocalGapTests(unittest.TestCase):
    """The gap from nightly-next's head to the tip comes from the tick's checkout of feat-cmux-next
    (150 commits deep), not the compare API: one REST read less per request job, on a budget that
    ran dry every hour on 2026-11-04. The compare API stays the fallback when the head is not in
    the checkout."""

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.git, self.shas = git_repo(self.scratch.name)

    def gap(self, head: str, tip: str):
        return rolling.git_oldest_after(head, tip, git=lambda *args: self.git(*args))

    def test_the_oldest_commit_after_head_and_when_it_landed(self):
        sha, landed = self.gap(self.shas[0], self.shas[3])
        self.assertEqual(sha, self.shas[1])
        self.assertEqual(landed, NOW - dt.timedelta(minutes=30))

    def test_the_oldest_landing_is_by_date_not_topological_order(self):
        """A merge of an older side commit: the side commit landed first, whatever rev-list's order."""
        self.git("checkout", "-q", "-b", "merged", self.shas[3])
        self.git("merge", "-q", "--no-ff", "-m", "merge side", self.shas[4], when=at(1))
        # A side commit older than every mainline commit after shas[2].
        self.git("checkout", "-q", "-b", "older", self.shas[2])
        self.git("commit", "-q", "--allow-empty", "-m", "older side", when=at(15))
        self.git("checkout", "-q", "merged")
        self.git("merge", "-q", "--no-ff", "-m", "merge older", "older", when=at(0.5))
        sha, landed = self.gap(self.shas[2], self.git("rev-parse", "HEAD").strip())
        self.assertEqual(sha, self.git("rev-parse", "older").strip())
        self.assertEqual(landed, NOW - dt.timedelta(minutes=15))

    def test_a_shallow_cut_inside_the_gap_falls_back(self):
        """A merged side history cut by the 150-commit fetch: the range may miss older commits, so the
        compare API answers instead."""
        clone = Path(self.scratch.name) / "shallow"
        self.git("checkout", "-q", "-b", "merged", self.shas[3])
        self.git("merge", "-q", "--no-ff", "-m", "merge side", self.shas[4], when=at(1))
        tip = self.git("rev-parse", "HEAD").strip()
        subprocess.run(["git", "clone", "-q", "--depth", "2", "--no-local", "-b", "merged",
                        f"file://{self.scratch.name}", str(clone)], check=True, capture_output=True)
        run = lambda *args: subprocess.run(["git", "-C", str(clone), *args], check=True, capture_output=True,
                                           text=True).stdout
        self.assertEqual(run("rev-parse", "--is-shallow-repository").strip(), "true")
        with self.assertRaises(LookupError):
            rolling.git_oldest_after(self.shas[3], tip, git=run)
        # Deep enough, the same shallow kind of checkout answers on its own.
        deep = Path(self.scratch.name) / "deep"
        subprocess.run(["git", "clone", "-q", "--depth", "10", "--no-local", "-b", "merged",
                        f"file://{self.scratch.name}", str(deep)], check=True, capture_output=True)
        run = lambda *args: subprocess.run(["git", "-C", str(deep), *args], check=True, capture_output=True,
                                           text=True).stdout
        self.assertEqual(rolling.git_oldest_after(self.shas[3], tip, git=run)[0], self.shas[4])

    def test_nothing_waits_at_or_behind_head(self):
        self.assertIsNone(self.gap(self.shas[3], self.shas[3]))
        self.assertIsNone(self.gap(self.shas[3], self.shas[1]))

    def test_a_diverged_head_is_unknown(self):
        self.assertEqual(self.gap(self.shas[4], self.shas[3]), rolling.UNKNOWN)

    def test_a_head_outside_the_checkout_falls_back(self):
        with self.assertRaises(LookupError):
            self.gap("e" * 40, self.shas[3])

    def test_evaluate_reads_no_compare_when_the_checkout_answers(self):
        api = api_for(compare("ahead", [(WAITING, 30)]))
        go, reason = rolling.evaluate(NOW, "o/r", TIP, api=api, ls_remote=lambda repo, branch: HEAD,
                                      local_gap=lambda head, tip: (WAITING, NOW - dt.timedelta(minutes=4)))
        self.assertFalse(go, reason)
        self.assertFalse([p for p in api.paths if "/compare/" in p], api.paths)
        self.assertFalse([p for p in api.paths if "/git/ref/" in p], api.paths)

    def test_evaluate_reads_compare_when_the_head_is_not_in_the_checkout(self):
        def missing(head, tip):
            raise LookupError("not here")
        api = api_for(compare("ahead", [(WAITING, 30)]), runs=IDLE)
        go, reason = rolling.evaluate(NOW, "o/r", TIP, api=api, ls_remote=lambda repo, branch: HEAD, local_gap=missing)
        self.assertTrue(go, reason)
        self.assertIn(f"repos/o/r/compare/{HEAD}...{TIP}?per_page=1&page=1", api.paths)

    def test_a_tip_already_on_nightly_next_reads_nothing_and_waits(self):
        """A finished build or the cron backstop often finds the tip promoted: no listing, no jobs
        read, no request (it would stop at the tip with "already on nightly-next")."""
        api = api_for(compare("ahead", [(WAITING, 30)]))
        go, reason = rolling.evaluate(NOW, "o/r", TIP, api=api, ls_remote=lambda repo, branch: HEAD,
                                      local_gap=lambda head, tip: None)
        self.assertFalse(go, reason)
        self.assertIn("nothing waits", reason)
        self.assertEqual(api.paths, [])

    def test_a_real_checkout_at_the_head_reads_nothing(self):
        api = api_for(compare("ahead", [(WAITING, 30)]))
        go, reason = rolling.evaluate(NOW, "o/r", self.shas[3], api=api, ls_remote=lambda repo, branch: self.shas[3],
                                      local_gap=lambda head, tip: self.gap(head, tip))
        self.assertFalse(go, reason)
        self.assertEqual(api.paths, [])

    def test_main_reads_the_gap_from_the_checkout(self):
        self.assertIn("local_gap=git_oldest_after", SCRIPT.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
