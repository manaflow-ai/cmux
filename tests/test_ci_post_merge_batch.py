#!/usr/bin/env python3
"""The post-merge batch tier (scripts/ci/post_merge_batch.py): the tick, the plan, the red
judgement and the bisect, plus the manifest, the caller jobs and the callees kept in step."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from argparse import Namespace
from unittest import mock
import os
from datetime import datetime, timezone
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
_git_fixture_spec = importlib.util.spec_from_file_location("git_fixture_env", ROOT / "tests" / "git_fixture_env.py")
git_fixture_env = importlib.util.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import post_merge_batch as pmb  # noqa: E402

WORKFLOW = ROOT / ".github" / "workflows" / pmb.WORKFLOW
NOW = datetime(2026, 11, 21, 12, 0, tzinfo=timezone.utc)


def run(run_id: int, sha: str, created: str, *, status: str = "completed", title: str = "batch tick") -> dict:
    return {"id": run_id, "head_sha": sha, "created_at": created, "status": status, "display_title": title}


class TickTest(unittest.TestCase):
    def test_dispatches_with_no_batch_yet(self) -> None:
        self.assertEqual(pmb.tick_decision("a" * 40, [], NOW, 120)[0], "dispatch")

    def test_skips_a_tested_tip(self) -> None:
        runs = [run(1, "a" * 40, "2026-11-21T08:00:00Z")]
        self.assertEqual(pmb.tick_decision("a" * 40, runs, NOW, 120)[0], "skip")

    def test_waits_out_the_window(self) -> None:
        runs = [run(1, "b" * 40, "2026-11-21T11:00:00Z")]
        self.assertEqual(pmb.tick_decision("a" * 40, runs, NOW, 120)[0], "skip")
        self.assertEqual(pmb.tick_decision("a" * 40, runs, NOW, 30)[0], "dispatch")

    def test_skips_while_a_batch_runs_and_ignores_probes(self) -> None:
        runs = [run(3, "c" * 40, "2026-11-21T11:59:00Z", status="in_progress", title="probe drill drill at x")]
        runs.append(run(2, "b" * 40, "2026-11-21T09:00:00Z", status="queued"))
        self.assertEqual(pmb.tick_decision("a" * 40, runs, NOW, 120)[0], "skip")
        self.assertEqual(pmb.tick_decision("a" * 40, runs[:1], NOW, 120)[0], "dispatch")

    def test_redispatches_a_tip_batch_with_no_verdict_once(self) -> None:
        # Drill-8 run 44966393364: the plan lost its runner, so the tip was never tested.
        runs = [run(1, "a" * 40, "2026-11-21T11:50:00Z")]
        self.assertEqual(pmb.tick_decision("a" * 40, runs, NOW, 120, judged=lambda rid: False)[0], "dispatch")
        self.assertEqual(pmb.tick_decision("a" * 40, runs, NOW, 120, judged=lambda rid: True)[0], "skip")
        runs.insert(0, run(2, "a" * 40, "2026-11-21T11:55:00Z"))
        self.assertEqual(pmb.tick_decision("a" * 40, runs, NOW, 120, judged=lambda rid: False)[0], "skip")

    def test_a_batch_with_no_verdict_on_an_older_tip_opens_no_window(self) -> None:
        # Run 45105503067 (2026-11-23): its plan failed on 4ec58f90a4 and the tip moved on; the window held the
        # next batch back two hours.
        runs = [run(1, "b" * 40, "2026-11-21T11:30:00Z")]
        self.assertEqual(pmb.tick_decision("a" * 40, runs, NOW, 120, judged=lambda rid: False)[0], "dispatch")
        self.assertEqual(pmb.tick_decision("a" * 40, runs, NOW, 120, judged=lambda rid: True)[0], "skip")

    def test_dispatches_inside_the_window_once_ten_merges_pile_up(self) -> None:
        # Leo, 2026-11-21: "de facto, im asking for 99% fewer minutes of ci time, period." A batch every ~10 merges.
        runs = [run(1, "b" * 40, "2026-11-21T11:50:00Z")]
        asked = []

        def ahead(base):
            asked.append(base)
            return 10

        self.assertEqual(pmb.tick_decision("a" * 40, runs, NOW, 120, every_merges=10, ahead=ahead)[0], "dispatch")
        self.assertEqual(asked, ["b" * 40])
        action, reason = pmb.tick_decision("a" * 40, runs, NOW, 120, every_merges=10, ahead=lambda base: 9)
        self.assertEqual(action, "skip")
        self.assertIn("9 of 10 merges", reason)
        # An unknown count (the compare call failed) and a count of 0 (off) leave the window alone in charge.
        self.assertEqual(pmb.tick_decision("a" * 40, runs, NOW, 120, every_merges=10, ahead=lambda base: None)[0], "skip")
        self.assertEqual(pmb.tick_decision("a" * 40, runs, NOW, 120, every_merges=0, ahead=lambda base: 50)[0], "skip")
        self.assertEqual(pmb.tick_decision("a" * 40, runs, NOW, 5, every_merges=10, ahead=lambda base: 1)[0], "dispatch")

    def test_the_count_never_overrides_a_batch_in_flight_or_a_tested_tip(self) -> None:
        def ahead(base):
            raise AssertionError("no compare call needed")

        live = [run(2, "b" * 40, "2026-11-21T11:55:00Z", status="in_progress")]
        self.assertEqual(pmb.tick_decision("a" * 40, live, NOW, 120, every_merges=10, ahead=ahead)[0], "skip")
        tested = [run(1, "a" * 40, "2026-11-21T11:50:00Z")]
        self.assertEqual(pmb.tick_decision("a" * 40, tested, NOW, 120, every_merges=10, ahead=ahead)[0], "skip")

    def test_a_finishing_batch_starts_the_next(self) -> None:
        # The judge's last step ticks with its own run id: that run is in progress and its judge job has not
        # concluded yet, but it is neither in flight nor unjudged for the tick.
        own = [run(7, "b" * 40, "2026-11-21T11:40:00Z", status="in_progress"), run(6, "c" * 40, "2026-11-21T11:20:00Z")]
        unjudged = lambda rid: rid != 7  # noqa: E731
        self.assertEqual(pmb.tick_decision("a" * 40, own, NOW, 120, unjudged, 10, lambda base: 12, self_run_id=7)[0], "dispatch")
        self.assertEqual(pmb.tick_decision("a" * 40, own, NOW, 120, unjudged, 10, lambda base: 3, self_run_id=7)[0], "skip")
        self.assertEqual(pmb.tick_decision("b" * 40, own, NOW, 120, unjudged, 10, lambda base: 0, self_run_id=7)[0], "skip")
        # Another batch already queued behind it still holds the next one back.
        queued = [run(8, "d" * 40, "2026-11-21T11:58:00Z", status="queued"), *own]
        self.assertEqual(pmb.tick_decision("a" * 40, queued, NOW, 120, unjudged, 10, lambda base: 12, self_run_id=7)[0], "skip")
        # Without its id the same run reads as in flight.
        self.assertEqual(pmb.tick_decision("a" * 40, own, NOW, 120, unjudged, 10, lambda base: 12)[0], "skip")

    def test_every_merges_value(self) -> None:
        self.assertEqual(pmb.every_merges(None), 100)
        self.assertEqual(pmb.every_merges("bad"), 100)
        self.assertEqual(pmb.every_merges("0"), 0)
        self.assertEqual(pmb.every_merges("25"), 25)

    def test_ahead_by_reads_one_compare(self) -> None:
        calls = []

        def api(path, **_):
            calls.append(path)
            return {"ahead_by": 11}

        self.assertEqual(pmb.ahead_by("o/r", "b" * 40, "a" * 40, api=api), 11)
        self.assertEqual(calls, [f"repos/o/r/compare/{'b' * 40}...{'a' * 40}?per_page=1"])

        def broken(path, **_):
            raise RuntimeError("HTTP 404")

        with unittest.mock.patch("sys.stdout"):
            self.assertIsNone(pmb.ahead_by("o/r", "b" * 40, "a" * 40, api=broken))
        self.assertIsNone(pmb.ahead_by("o/r", "", "a" * 40, api=api))

    def test_the_judge_ticks_the_next_batch_and_never_fails_for_it(self) -> None:
        steps = yaml.safe_load(WORKFLOW.read_text())["jobs"]["judge"]["steps"]
        last = steps[-1]
        self.assertIn("tick", last["run"])
        self.assertIn('--self-run-id "$GITHUB_RUN_ID"', last["run"])
        self.assertTrue(last["continue-on-error"])
        self.assertIn("inputs.mode != 'probe'", last["if"])

    def test_window_value(self) -> None:
        self.assertEqual(pmb.window_minutes(""), 240)
        self.assertEqual(pmb.window_minutes("bad"), 240)
        self.assertEqual(pmb.window_minutes("45"), 45)


class WebTickTest(unittest.TestCase):
    """The batch's `web` suite replaced cmux-next-web.yml's coalescing tick: a tick dispatches no web run."""

    def test_a_tick_dispatches_no_web_workflow(self) -> None:
        calls = []

        def api(path, method="GET", fields=None, **_):
            calls.append((method, path, fields))
            return {"sha": "a" * 40} if path.endswith("/commits/feat-cmux-next") else None

        args = Namespace(repo="o/r", branch="feat-cmux-next", window_minutes="120", dry_run=True)
        with unittest.mock.patch.object(pmb, "gh_api", api), \
                unittest.mock.patch.object(pmb, "list_runs", lambda repo, branch: [run(1, "a" * 40, "2026-11-21T11:00:00Z")]), \
                unittest.mock.patch("sys.stdout"):
            self.assertEqual(pmb.cmd_tick(args), 0)
        self.assertFalse([call for call in calls if "cmux-next-web.yml" in call[1]])


class PlanAndJudgeTest(unittest.TestCase):
    suites = {
        "web": pmb.Suite("web", "ci-web.yml", ["webviews/**"], {"check": "check"}),
        "rust": pmb.Suite("rust", "rust.yml", ["cmux-tui/**", "Cargo.lock"], {"test": "test"}),
    }

    def test_plan_reaches_by_paths_since_last_batch(self) -> None:
        runs = [run(1, "b" * 40, "2026-11-21T09:00:00Z")]
        plan = pmb.plan_batch("a" * 40, runs, self.suites, lambda base: ["webviews/src/x.ts"])
        self.assertEqual((plan["base"], plan["suites"]), ("b" * 40, ["web"]))
        self.assertEqual(pmb.plan_batch("a" * 40, [], self.suites, lambda base: [])["suites"], ["web", "rust"])

    def test_plan_skips_a_batch_whose_judge_never_succeeded(self) -> None:
        # Drill-2 (2026-11-21): run 2's plan died, so it tested nothing; the base is run 1's head.
        runs = [run(2, "b" * 40, "2026-11-21T10:00:00Z"), run(1, "c" * 40, "2026-11-21T09:00:00Z")]
        plan = pmb.plan_batch("a" * 40, runs, self.suites, lambda base: [], lambda rid: rid == 1)
        self.assertEqual(plan["base"], "c" * 40)
        self.assertEqual(pmb.plan_batch("a" * 40, runs, self.suites, lambda base: None or [], lambda rid: False)["suites"], ["web", "rust"])

    def test_job_id_matches_matrix_legs(self) -> None:
        self.assertEqual(self.suites["rust"].job_id("test (linux, 1)"), "test")
        self.assertEqual(self.suites["rust"].job_id("other"), "")

    def test_new_red_needs_an_earlier_green(self) -> None:
        verdicts = {"web / check": ("web", "failure"), "rust / test": ("rust", "failure")}
        runs = [run(2, "b" * 40, "2026-11-21T10:00:00Z"), run(1, "c" * 40, "2026-11-21T08:00:00Z")]
        older = {2: {"rust / test": ("rust", "failure")}, 1: {"web / check": ("web", "success")}}
        found, notes = pmb.new_reds("a" * 40, verdicts, runs, lambda rid: older[rid])
        self.assertEqual(found, [("web / check", "web", "c" * 40)])
        self.assertEqual(len(notes), 1)
        self.assertIn("known red", notes[0])


    def test_a_red_on_an_unjudged_run_is_still_bisected(self) -> None:
        # Run 2's judge died (rate limit), so its red was never bisected: look past it to run 1's green.
        verdicts = {"web / check": ("web", "failure")}
        runs = [run(2, "b" * 40, "2026-11-21T10:00:00Z"), run(1, "c" * 40, "2026-11-21T08:00:00Z")]
        older = {2: ({"web / check": ("web", "failure")}, False), 1: ({"web / check": ("web", "success")}, True)}
        found, _ = pmb.new_reds("a" * 40, verdicts, runs, lambda rid: older[rid])
        self.assertEqual(found, [("web / check", "web", "c" * 40)])
        older[2] = ({"web / check": ("web", "failure")}, True)
        found, notes = pmb.new_reds("a" * 40, verdicts, runs, lambda rid: older[rid])
        self.assertEqual(found, [])
        self.assertIn("known red", notes[0])

    def stuck_setup(self):
        verdicts = {"rust / test (linux, 1)": ("rust", "failure"), "rust / test (linux, 2)": ("rust", "failure")}
        runs = [run(3, "b" * 40, "2026-11-21T10:00:00Z"), run(2, "c" * 40, "2026-11-21T08:00:00Z"),
                run(1, "d" * 40, "2026-11-21T06:00:00Z")]
        red = {"rust / test (linux, 1)": ("rust", "failure"), "rust / test (linux, 2)": ("rust", "failure")}
        older = {3: (red, True), 2: (red, True), 1: ({k: ("rust", "success") for k in red}, True)}
        return verdicts, runs, older

    def test_a_known_red_is_bisected_between_its_last_green_and_first_red(self) -> None:
        # Batch run 45768539377 (2026-11-26) skipped 43 of 48 reds as known: they get a bisect, legs collapsed.
        verdicts, runs, older = self.stuck_setup()
        found, _ = pmb.new_reds("a" * 40, verdicts, runs, lambda rid: older[rid])
        self.assertEqual(found, [])
        stuck = pmb.stuck_reds("a" * 40, verdicts, runs, lambda rid: older[rid], self.suites)
        self.assertEqual(stuck, [("rust / test (linux, 1)", "rust", "d" * 40, "c" * 40)])

    def test_a_stuck_red_waits_for_its_running_bisect_and_stops_after_rebisects(self) -> None:
        verdicts, runs, older = self.stuck_setup()
        start = lambda good, bad: "c" * 40
        probe = run(4, "c" * 40, "2026-11-21T08:30:00Z", status="in_progress", title=f"probe rust test at {'c' * 40}")
        older[4] = ({}, True)
        self.assertEqual(pmb.stuck_reds("a" * 40, verdicts, [probe] + runs, lambda rid: older[rid], self.suites, start), [])
        probe["status"] = "completed"
        self.assertEqual(len(pmb.stuck_reds("a" * 40, verdicts, [probe] + runs, lambda rid: older[rid], self.suites, start)), 1)
        # MAX_REBISECTS judged bisects started at the chain's first sha: named only.
        again = [run(5 + i, "c" * 40, f"2026-11-21T09:{i:02d}:00Z", title=f"probe rust test at {'c' * 40}")
                 for i in range(pmb.MAX_REBISECTS - 1)]
        for r in again:
            older[r["id"]] = ({}, True)
        self.assertEqual(pmb.stuck_reds("a" * 40, verdicts, again + [probe] + runs, lambda rid: older[rid], self.suites, start), [])

    def test_a_bisect_whose_judge_died_is_not_a_rebisect(self) -> None:
        # 2026-11-27: web-typecheck and five more reds were capped after chains whose judge hit the rate limit
        # (cmux#60709); red batch runs were counted, not finished bisects.
        verdicts, runs, older = self.stuck_setup()
        start = lambda good, bad: "c" * 40
        dead = [run(4 + i, "c" * 40, f"2026-11-21T08:3{i}:00Z", title=f"probe rust test at {'c' * 40}")
                for i in range(pmb.MAX_REBISECTS + 1)]
        for r in dead:
            older[r["id"]] = ({}, False)
        more = [run(20 + i, f"{i:x}" * 40, f"2026-11-21T09:{i:02d}:30Z") for i in range(5)]
        for r in more:
            older[r["id"]] = (older[3][0], True)
        runs2 = more[::-1] + runs
        # A probe at another sha (a later step of a chain) is not a chain start either.
        step = run(30, "e" * 40, "2026-11-21T08:50:00Z", title=f"probe rust test at {'e' * 40}")
        older[30] = ({}, True)
        got = pmb.stuck_reds("a" * 40, verdicts, [step] + dead + runs2, lambda rid: older[rid], self.suites, start)
        self.assertEqual(len(got), 1)

    def test_a_stuck_red_needs_a_green_in_reach(self) -> None:
        verdicts, runs, older = self.stuck_setup()
        older[1] = (older[2][0], True)
        self.assertEqual(pmb.stuck_reds("a" * 40, verdicts, runs, lambda rid: older[rid], self.suites), [])

    def test_a_stuck_probe_starts_mid_range_and_its_judge_accepts_it(self) -> None:
        commits = ["c1", "c2", "c3", "c4", "c5"]
        probe = pmb.stuck_probe("rust / test", "rust", "test", "g", "c5", "9", commits)
        self.assertEqual((probe.sha, probe.good, probe.bad), ("c3", "g", "c5"))
        self.assertEqual(pmb.stuck_probe("rust / test", "rust", "test", "c4", "c5", "9", commits).sha, "c5")
        origin = {"id": 9, "head_sha": "c7", "path": f".github/workflows/{pmb.WORKFLOW}", "head_branch": "main",
                  "display_title": "batch tick"}
        covered = lambda good, head: ["c1", "c2", "c3", "c4", "c5", "c6", "c7"]
        self.assertEqual(pmb.probe_refusal(probe, "main", origin, [("rust / test", "rust", "g")], covered), "")

    def test_a_one_commit_stuck_range_that_passes_is_a_flake(self) -> None:
        probe = pmb.Probe("s", "s / j", "j", "c5", "c4", "c5", "1")
        self.assertEqual(pmb.next_step(probe, "success", ["c5"])[0], "flake")
        self.assertEqual(pmb.next_step(probe, "failure", ["c5"]), ("culprit", "c5"))


class RateLimitTest(unittest.TestCase):
    def setUp(self) -> None:
        self.saved = pmb.API_WAIT_BUDGET["seconds"]

    def tearDown(self) -> None:
        pmb.API_WAIT_BUDGET["seconds"] = self.saved

    def call(self, replies: list[tuple[int, str]], budget: float) -> tuple[object, list[float]]:
        pmb.API_WAIT_BUDGET["seconds"] = budget
        slept: list[float] = []

        def fake_run(argv, **_):
            code, text = replies.pop(0)
            return subprocess.CompletedProcess(argv, code, stdout=text if not code else "", stderr=text if code else "")

        got = pmb.gh_api("repos/x/y/actions/runs/1/jobs", run=fake_run, sleep=slept.append, clock=lambda: 1000.0, reset_at=lambda: 1100.0)
        return got, slept

    def test_waits_for_the_reset_then_retries(self) -> None:
        limited = "gh: API rate limit exceeded for installation ID 1. (HTTP 403)"
        got, slept = self.call([(1, limited), (0, '{"jobs": []}')], 600)
        self.assertEqual(got, {"jobs": []})
        self.assertEqual(slept, [105.0])

    def test_gives_up_past_the_budget_and_never_retries_other_errors(self) -> None:
        limited = "gh: API rate limit exceeded for installation ID 1. (HTTP 403)"
        with self.assertRaises(RuntimeError):
            self.call([(1, limited), (1, limited), (1, limited)], 120)
        with self.assertRaises(RuntimeError):
            self.call([(1, "HTTP 404: Not Found")], 600)
        self.assertEqual(pmb.rate_limit_wait(0, None, 30), 30)
        self.assertEqual(pmb.rate_limit_wait(0, 1, 0), 0)

    def test_a_read_answered_5xx_is_tried_again(self) -> None:
        # A probe's read of its origin run that GitHub answered 5xx used to refuse the probe and end the bisect.
        got, slept = self.call([(1, "gh: Server Error (HTTP 502)"), (1, "HTTP 503: Service Unavailable"), (0, '{"id": 7}')], 0)
        self.assertEqual(got, {"id": 7})
        self.assertEqual(slept, list(pmb.READ_RETRY_WAITS))

    def test_a_read_still_5xx_after_its_retries_fails(self) -> None:
        with self.assertRaises(RuntimeError):
            self.call([(1, "HTTP 502")] * (len(pmb.READ_RETRY_WAITS) + 1), 0)

    def test_a_write_answered_5xx_is_not_retried_here(self) -> None:
        replies = [(1, "HTTP 500: Failed to run workflow dispatch")]

        def fake_run(argv, **_):
            code, text = replies.pop(0)
            return subprocess.CompletedProcess(argv, code, stdout="", stderr=text)

        slept: list[float] = []
        with self.assertRaises(RuntimeError):
            pmb.gh_api("repos/x/y/dispatches", method="POST", fields={}, run=fake_run, sleep=slept.append, tokens=["t"])
        self.assertEqual(slept, [])

    def test_a_spent_token_falls_to_the_next_before_waiting(self) -> None:
        limited = "gh: API rate limit exceeded for installation ID 1. (HTTP 403)"
        replies = [(1, limited), (0, '{"jobs": []}')]
        used: list[str] = []

        def fake_run(argv, env=None, **_):
            used.append((env or {}).get("GH_TOKEN", ""))
            code, text = replies.pop(0)
            return subprocess.CompletedProcess(argv, code, stdout=text if not code else "", stderr=text if code else "")

        slept: list[float] = []
        got = pmb.gh_api("repos/x/y/actions/runs/1/jobs", run=fake_run, sleep=slept.append, clock=lambda: 1000.0,
                         reset_at=lambda: 1100.0, tokens=["app", "job"])
        self.assertEqual(got, {"jobs": []})
        self.assertEqual(used, ["app", "job"])
        self.assertEqual(slept, [])


    def test_plan_runs_every_suite_when_the_runs_are_unreadable(self) -> None:
        def refused(*_a, **_k):
            raise RuntimeError("gh: API rate limit exceeded for installation (HTTP 403)")

        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "out"
            saved = pmb.list_runs
            pmb.list_runs = refused
            try:
                pmb.main(["plan", "--github-output", str(out), "--summary", str(Path(tmp) / "s"), "--sha", "a" * 40])
            finally:
                pmb.list_runs = saved
            self.assertIn("suites= drill ", out.read_text())

    def test_a_probe_is_judged_against_its_known_good_commit(self) -> None:
        # A bisect probe's suite judges its reds against `good` (gallery-health's `base`): a standing red
        # there too is not the probed merge's, so the bisect hunts only the red that is new.
        for good, base in (("c" * 40, "c" * 40), ("", "")):
            with tempfile.TemporaryDirectory() as tmp:
                out = Path(tmp) / "out"
                pmb.main(["plan", "--github-output", str(out), "--summary", str(Path(tmp) / "s"), "--mode", "probe",
                          "--suite", "drill", "--probe-sha", "a" * 40, "--good", good])
                self.assertIn(f"base={base}\n", out.read_text())

class BisectTest(unittest.TestCase):
    def walk(self, commits: list[str], culprit: str) -> tuple[str, int]:
        """Drives next_step from the confirming probe to its end with a red from culprit on."""
        good, tip = "g", commits[-1]
        probe = pmb.Probe("s", "s / j", "j", tip, good, "", "1")
        runs = 0
        while True:
            runs += 1
            red = commits.index(probe.sha) >= commits.index(culprit)
            head = probe.bad or probe.sha
            span = commits[: commits.index(head) + 1] if probe.good == good else commits[commits.index(probe.good) + 1 : commits.index(head) + 1]
            step, value = pmb.next_step(probe, "failure" if red else "success", span)
            if step == "culprit":
                return value, runs
            self.assertEqual(step, "probe")
            probe = value

    def test_every_culprit_in_31_commits_in_six_runs(self) -> None:
        commits = [f"c{i:02d}" for i in range(31)]
        for culprit in commits:
            found, runs = self.walk(commits, culprit)
            self.assertEqual(found, culprit)
            self.assertLessEqual(runs, 6, culprit)  # one confirming run, then log2(31) = 5

    def test_one_commit_needs_no_bisect(self) -> None:
        self.assertEqual(self.walk(["c0"], "c0"), ("c0", 1))

    def test_a_red_that_does_not_repeat_is_a_flake(self) -> None:
        probe = pmb.Probe("s", "s / j", "j", "c3", "g", "", "1")
        self.assertEqual(pmb.next_step(probe, "success", ["c1", "c2", "c3"])[0], "flake")

    def test_a_probe_without_verdict_retries_then_stops(self) -> None:
        probe = pmb.Probe("s", "s / j", "j", "c1", "g", "c3", "1")
        for n in range(1, pmb.MAX_PROBE_RETRIES + 1):
            step, probe = pmb.next_step(probe, "cancelled", ["c1", "c2", "c3"])
            self.assertEqual((step, probe.tries), ("retry", n))
        self.assertEqual(pmb.next_step(probe, "", ["c1", "c2", "c3"])[0], "lost")

    def test_a_probe_judge_runs_when_its_plan_died(self) -> None:
        # Drill-8 probe run 44980687386: the plan job lost its runner and the bisect stopped with no judge.
        judge = yaml.safe_load(WORKFLOW.read_text())["jobs"]["judge"]
        self.assertIn("inputs.mode == 'probe'", judge["if"])
        self.assertIn("!cancelled()", judge["if"])

    def test_first_parent_range_on_a_real_repo(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            def g(*argv: str) -> str:
                return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *argv], cwd=tmp, check=True,
                                      capture_output=True, text=True, env=git_fixture_env.fixture_env()).stdout.strip()
            git_fixture_env.init_repo(tmp)
            shas = []
            for i in range(4):
                Path(tmp, "f").write_text(str(i))
                g("add", "f")
                g("commit", "-qm", f"c{i} (#{100 + i})")
                shas.append(g("rev-parse", "HEAD"))
            self.assertEqual(pmb.first_parent_range(shas[0], shas[3], cwd=Path(tmp)), shas[1:])
            self.assertEqual(pmb.PR_RE.search(g("log", "-1", "--format=%s")).group(1), "103")


class WiringTest(unittest.TestCase):
    """The manifest, the caller jobs and the callees agree."""

    def setUp(self) -> None:
        self.suites = pmb.load_manifest()
        self.workflow = yaml.safe_load(WORKFLOW.read_text())

    def test_each_suite_has_its_caller_job(self) -> None:
        jobs = self.workflow["jobs"]
        callers = {k for k, v in jobs.items() if "uses" in v}
        self.assertEqual(callers, set(self.suites))
        for key, suite in self.suites.items():
            job = jobs[key]
            self.assertEqual(job["uses"], f"./.github/workflows/{suite.workflow}", key)
            self.assertEqual(job["if"], f"contains(needs.plan.outputs.suites, ' {key} ')", key)
            # sha and only always; a suite may take more of plan's outputs (gallery-health's base, cmux#57172).
            self.assertEqual({k: v for k, v in job["with"].items() if k in ("sha", "only")},
                             {"sha": "${{ needs.plan.outputs.sha }}", "only": "${{ needs.plan.outputs.only }}"}, key)
            for k, v in job["with"].items():
                self.assertEqual(v, f"${{{{ needs.plan.outputs.{k} }}}}", f"{key}: {k}")
            self.assertNotIn("name", job, f"{key}: the caller job's name must be the suite key")
        self.assertEqual(set(jobs["judge"]["needs"]), {"plan", *self.suites})

    def test_the_table_suites_reach_every_input_of_their_job(self) -> None:
        # A suite that runs `ci/run run --job J` must start for any path a step of J reads, or a merge that
        # changes only that path never runs the step after the merge.
        sys.path.insert(0, str(ROOT / "scripts" / "ci"))
        import ci_steps  # noqa: PLC0415

        steps = ci_steps.load().steps.values()
        for key, job in (("pr-pipeline-mac", "mac"), ("pr-pipeline-ios", "ios")):
            with self.subTest(suite=key):
                suite = self.suites[key]
                self.assertEqual(set(suite.jobs), {job})
                want = set(ci_steps.PIPELINE_PATHS) | {f".github/workflows/{suite.workflow}"}
                want |= {p for s in steps if s.job == job for p in s.inputs}
                self.assertLessEqual(want, set(suite.paths), sorted(want - set(suite.paths)))
                text = (WORKFLOW.parent / suite.workflow).read_text()
                self.assertIn(f"ci/run run --job {job}", text)
                self.assertIn("inputs.base", text)

    def test_each_callee_takes_sha_and_only_and_gates_its_jobs(self) -> None:
        for key, suite in self.suites.items():
            callee = yaml.safe_load((WORKFLOW.parent / suite.workflow).read_text())
            on = callee.get(True) or callee.get("on")
            inputs = on["workflow_call"]["inputs"]
            self.assertTrue({"sha", "only"} <= set(inputs), key)
            for job_id in suite.jobs:
                # A gateway job's id ends in -fleet while its manifest id does not (cmux#56548).
                callee_id = job_id if job_id in callee["jobs"] else f"{job_id}-fleet"
                gate = str(callee["jobs"][callee_id].get("if", ""))
                self.assertIn(f"inputs.only == '{job_id}'", gate, f"{key}/{job_id}")
            self.assertIn("inputs.sha", (WORKFLOW.parent / suite.workflow).read_text(), key)

    def test_a_hung_checkout_is_bounded_and_tried_once_more(self) -> None:
        """A fetch that hangs must not take the job's whole budget and its verdict with it (plan job
        137288423007 and judge job 137302455752, 2026-11-22: cancelled in "Fetching the repository")."""
        for key in ("plan", "judge", "revert"):
            job = self.workflow["jobs"][key]
            steps = [s for s in job["steps"] if str(s.get("uses", "")).startswith("actions/checkout@")]
            self.assertEqual(len(steps), 2, f"{key}: one checkout and one retry")
            first, again = steps
            self.assertTrue(first.get("continue-on-error"), key)
            self.assertEqual(again.get("if"), f"steps.{first.get('id')}.outcome != 'success'", key)
            self.assertEqual(first["with"], again["with"], key)
            self.assertEqual(first["uses"], again["uses"], key)
            bound = first.get("timeout-minutes", 0) + again.get("timeout-minutes", 0)
            self.assertTrue(0 < first.get("timeout-minutes", 0) and 0 < again.get("timeout-minutes", 0), key)
            history = next(s for s in job["steps"] if s.get("name") == "Fetch this ref's history")
            self.assertGreater(job["steps"].index(history), job["steps"].index(again), key)
            bound += history["timeout-minutes"]
            self.assertLess(bound, job["timeout-minutes"], f"{key}: every try fits inside the job's budget")
            # Only this ref: fetch-depth 0 fetches every branch of the repository, which is what hung.
            self.assertNotIn("fetch-depth", first["with"], key)
            self.assertIn('origin "$(git rev-parse HEAD)"', history["run"], key)
            self.assertIn("--unshallow", history["run"], key)


class GuardTest(unittest.TestCase):
    """A probe's inputs are checked against the batch run that found the red; a teammate's culprit gets a held revert."""

    COMMITS = ["c1", "c2", "c3", "c4"]
    ORIGIN = {"id": 50, "display_title": "batch schedule", "path": ".github/workflows/cmux-next-post-merge.yml", "head_branch": "feat-cmux-next", "head_sha": "c4"}
    FOUND = [("s / j", "s", "g")]

    def refusal(self, probe, origin=ORIGIN, found=FOUND) -> str:
        return pmb.probe_refusal(probe, "feat-cmux-next", origin, found, lambda good, head: self.COMMITS if (good, head) == ("g", "c4") else [])

    def test_the_bisect_the_batch_started_passes(self) -> None:
        self.assertEqual(self.refusal(pmb.Probe("s", "s / j", "j", "c4", "g", "", "50")), "")
        self.assertEqual(self.refusal(pmb.Probe("s", "s / j", "j", "c2", "g", "c4", "50")), "")
        self.assertEqual(self.refusal(pmb.Probe("s", "s / j", "j", "c3", "c2", "c4", "50")), "")

    def test_a_forged_range_is_refused(self) -> None:
        # bad=X, good=X^ naming any X: X is not in the batch's covered commits.
        self.assertIn("sha", self.refusal(pmb.Probe("s", "s / j", "j", "x", "x0", "x", "50")))
        self.assertIn("bad", self.refusal(pmb.Probe("s", "s / j", "j", "c2", "g", "x", "50")))
        self.assertIn("good", self.refusal(pmb.Probe("s", "s / j", "j", "c3", "x0", "c4", "50")))
        self.assertIn("confirming", self.refusal(pmb.Probe("s", "s / j", "j", "c2", "g", "", "50")))

    def test_a_job_that_was_not_a_new_red_is_refused(self) -> None:
        self.assertIn("not a new red", self.refusal(pmb.Probe("s", "s / k", "k", "c4", "g", "", "50")))
        self.assertIn("not a new red", self.refusal(pmb.Probe("s", "s / j", "j", "c4", "g", "", "50"), found=[]))

    def test_an_origin_that_is_not_our_batch_run_is_refused(self) -> None:
        probe = pmb.Probe("s", "s / j", "j", "c4", "g", "", "50")
        self.assertIn("unreadable", self.refusal(probe, origin=None))
        for change in ({"display_title": "probe s j at c4"}, {"path": ".github/workflows/other.yml"}, {"head_branch": "lane/x"}):
            self.assertIn("not a batch run", self.refusal(probe, origin={**self.ORIGIN, **change}))

    def test_a_teammates_culprit_is_held(self) -> None:
        self.assertEqual(pmb.merged_by_teammate("o/r", "7", api=lambda path: {"user": {"login": "lawrencecchen"}}), "lawrencecchen")
        self.assertEqual(pmb.merged_by_teammate("o/r", "7", api=lambda path: {"user": {"login": "some-agent"}}), "")
        self.assertEqual(pmb.merged_by_teammate("o/r", "", api=lambda path: 1 / 0), "")

        def unreadable(path):
            raise RuntimeError("gh api: 403")

        self.assertTrue(pmb.merged_by_teammate("o/r", "7", api=unreadable))
        self.assertTrue(pmb.TEAMMATE_HOLD.format(login="x").startswith("HOLD: "))

    def test_an_agents_revert_is_handed_to_autoland_and_a_teammates_is_not(self) -> None:
        # Goal base-batch-reverts-culprit: "reverts it with no person". The label is next_autoland's hand-off.
        calls = []
        line = pmb.hand_off("o/r", 12, "", api=lambda path, **kw: calls.append((path, kw)))
        self.assertEqual(calls, [("repos/o/r/issues/12/labels", {"method": "POST", "fields": {"labels": ["ready-to-land"]}})])
        self.assertIn("ready-to-land", line)
        calls.clear()
        self.assertIn("Held for lucasr1b", pmb.hand_off("o/r", 12, "lucasr1b", api=lambda path, **kw: calls.append(path)))
        self.assertEqual(calls, [])

        def refused(path, **kw):
            raise RuntimeError("gh api: 403")

        self.assertIn("normal landing", pmb.hand_off("o/r", 12, "", api=refused))

    def _conflict_api(self, tip_conclusion: str, comments=()):
        calls = []
        job = "web / Web tests 1/2"

        def api(path, **kw):
            calls.append((path, kw))
            if "/workflows/" in path:
                return {"workflow_runs": [
                    {"id": 90, "display_title": "batch next", "status": "completed", "head_sha": "b" * 40, "created_at": "2"},
                    {"id": 50, "display_title": "batch next", "status": "completed", "head_sha": "a" * 40, "created_at": "1"},
                ]}
            if path.startswith("repos/o/r/actions/runs/90/jobs"):
                return {"jobs": [{"name": job, "status": "completed", "conclusion": tip_conclusion}]}
            if path.endswith("/comments?per_page=100"):
                return list(comments)
            if kw.get("method") == "POST":
                return {"html_url": "https://x/c/1"}
            return {}

        args = Namespace(repo="o/r", branch="feat-cmux-next", origin="60", job=job, manifest=str(pmb.MANIFEST), good="c" * 40,
                         server_url="https://github.com", run_id="70", dry_run=False)
        return api, calls, args

    def test_a_conflicted_revert_already_fixed_forward_stops_quietly(self) -> None:
        # Goal base-batch-reverts-culprit: b672c956's revert conflicted because #59537 had fixed it forward.
        api, calls, args = self._conflict_api("success")
        line = pmb.revert_conflict(args, "d" * 40, "123", [], api=api)
        self.assertIn("fixed forward, nothing to revert", line)
        self.assertFalse([c for c in calls if c[1].get("method") == "POST"])

    def test_a_conflicted_revert_still_red_tells_the_culprits_pr_once(self) -> None:
        api, calls, args = self._conflict_api("failure")
        # Fleet source bundles and shallow checkouts need not contain a parent.
        culprit = "d" * 40
        with mock.patch.object(pmb, "git", return_value="abc1234 Fix forward\n") as history:
            line = pmb.revert_conflict(args, culprit, "123", ["scripts/ci/post_merge_batch.py"], api=api)
        history.assert_called_once_with("log", "--format=%h %s", f"{culprit}..HEAD", "--", "scripts/ci/post_merge_batch.py")
        posts = [c for c in calls if c[1].get("method") == "POST"]
        self.assertEqual([p[0] for p in posts], ["repos/o/r/issues/123/comments"])
        body = posts[0][1]["fields"]["body"]
        self.assertIn(pmb.CONFLICT_MARK.format(culprit=culprit, job=args.job), body)
        self.assertIn("`web / Web tests 1/2`", body)
        self.assertIn("abc1234 Fix forward", body)
        self.assertIn("told #123's owner", line)
        mark = pmb.CONFLICT_MARK.format(culprit=culprit, job=args.job)
        api, calls, args = self._conflict_api("failure", comments=[{"body": mark}])
        self.assertIn("already told", pmb.revert_conflict(args, culprit, "123", [], api=api))
        self.assertFalse([c for c in calls if c[1].get("method") == "POST"])


class PushTest(unittest.TestCase):
    """GitHub's workflow-scope check timing out is retried; any other refusal is not."""

    def pusher(self, errors):
        calls = []

        def run(*argv):
            calls.append(argv)
            if errors:
                raise RuntimeError(errors.pop(0))
            return ""

        return run, calls

    def test_a_timed_out_workflow_check_is_retried(self) -> None:
        run, calls = self.pusher(["! [remote rejected] HEAD -> x (Unable to determine if workflow can be created or updated due to timeout; `workflows` scope may be required.)"] * 2)
        waits = []
        pmb.push_branch("u", "HEAD:refs/heads/x", run=run, sleep=waits.append)
        self.assertEqual((len(calls), waits), (3, [15, 45]))

    def test_other_refusals_and_a_lasting_timeout_raise(self) -> None:
        run, calls = self.pusher(["! [remote rejected] (protected branch)"])
        with self.assertRaises(RuntimeError):
            pmb.push_branch("u", "r", run=run, sleep=lambda s: None)
        self.assertEqual(len(calls), 1)
        run, calls = self.pusher(["due to timeout"] * 9)
        with self.assertRaises(RuntimeError):
            pmb.push_branch("u", "r", run=run, sleep=lambda s: None)
        self.assertEqual(len(calls), 4)


class StartBranchTest(unittest.TestCase):
    """The revert branch is created by API at the tip; one left by an earlier try is reused."""

    def test_creates_the_ref_at_the_tip(self) -> None:
        calls = []
        pmb.start_branch("o/r", "revert/x", "abc", api=lambda path, **kw: calls.append((path, kw)))
        with mock.patch.dict(os.environ, {"PUSH_TOKEN": "push", "GH_TOKEN": "job"}):
            pmb.start_branch("o/r", "revert/y", "abc", api=lambda path, **kw: calls.append((path, kw)))
        self.assertEqual(calls[0][0], "repos/o/r/git/refs")
        self.assertEqual(calls[0][1]["fields"], {"ref": "refs/heads/revert/x", "sha": "abc"})
        self.assertEqual(calls[1][1]["tokens"], ["push"])

    def test_an_existing_branch_is_reused_and_other_errors_raise(self) -> None:
        def exists(path, **kw):
            raise RuntimeError("gh api POST repos/o/r/git/refs: Reference already exists (HTTP 422)")

        pmb.start_branch("o/r", "revert/x", "abc", api=exists)

        def denied(path, **kw):
            raise RuntimeError("gh api POST repos/o/r/git/refs: Resource not accessible by integration (HTTP 403)")

        with self.assertRaises(RuntimeError):
            pmb.start_branch("o/r", "revert/x", "abc", api=denied, sleep=lambda s: None)

    def test_a_github_5xx_is_retried_then_raises(self) -> None:
        tries, waits = [], []

        def flaky(path, **kw):
            tries.append(1)
            if len(tries) < 2:
                raise RuntimeError("gh api POST repos/o/r/git/refs: gh: Server Error (HTTP 502)")

        pmb.start_branch("o/r", "revert/x", "abc", api=flaky, sleep=waits.append)
        self.assertEqual((len(tries), waits), (2, [15]))

        def down(path, **kw):
            raise RuntimeError("gh: Server Error (HTTP 502)")

        with self.assertRaises(RuntimeError):
            pmb.start_branch("o/r", "revert/x", "abc", api=down, sleep=lambda s: None)


class PushTokenTest(unittest.TestCase):
    """The swap-out, probe or revert branch is created and pushed with the workflows-write token when the job has one
    (a ref at a feat-cmux-next commit needs it, drill 9); else with the contents-write token, and a diff that
    touches .github/workflows/** then stops with the command and the issue to fix it, never a skip.
    The routing App had no Workflows permission, so a combined contents+workflows mint failed every revert job
    (run 45021631601, hq#18499)."""

    ENV = {"PUSH_TOKEN": "contents", "WORKFLOWS_TOKEN": "workflows", "GH_TOKEN": "job"}

    def test_any_diff_takes_the_workflows_token_when_minted(self) -> None:
        # A ref at a feat-cmux-next commit needs workflows write whatever the diff: drill 9 run 45096141472 got
        # HTTP 403 creating its piece probe branch with the contents token.
        with mock.patch.dict(os.environ, self.ENV):
            self.assertEqual(pmb.push_token([".github/post-merge-drill-red", "webviews/src/pages/a.tsx"]), "workflows")
            self.assertEqual(pmb.push_token([]), "workflows")

    def test_a_diff_with_no_workflow_file_falls_back_to_the_contents_token(self) -> None:
        with mock.patch.dict(os.environ, {"PUSH_TOKEN": "contents", "GH_TOKEN": "job"}, clear=True):
            self.assertEqual(pmb.push_token([".github/post-merge-drill-red", "webviews/src/pages/a.tsx"]), "contents")
            self.assertEqual(pmb.push_token([]), "contents")
        with mock.patch.dict(os.environ, {"GH_TOKEN": "job"}, clear=True):
            self.assertEqual(pmb.push_token(["a.txt"]), "job")

    def test_a_workflow_file_takes_the_workflows_token(self) -> None:
        with mock.patch.dict(os.environ, self.ENV):
            self.assertEqual(pmb.push_token(["a.txt", ".github/workflows/x.yml"]), "workflows")

    def test_a_workflow_file_with_no_workflows_token_stops_with_the_fix(self) -> None:
        with mock.patch.dict(os.environ, {"PUSH_TOKEN": "contents", "GH_TOKEN": "job"}, clear=True):
            with self.assertRaises(pmb.WorkflowsTokenMissing) as caught:
                pmb.push_token([".github/workflows/x.yml"], command="git push origin abc:refs/heads/swapout/x")
        text = str(caught.exception)
        self.assertIn("hq#18499", text)
        self.assertIn(".github/workflows/x.yml", text)
        self.assertIn("git push origin abc:refs/heads/swapout/x", text)

    def test_the_push_url_takes_the_chosen_token(self) -> None:
        self.assertEqual(pmb.push_url("https://x-access-token:{token}@github.com/o/r.git", "t"), "https://x-access-token:t@github.com/o/r.git")
        self.assertEqual(pmb.push_url("origin", "t"), "origin")

    def test_start_branch_uses_the_token_it_is_given(self) -> None:
        calls = []
        pmb.start_branch("o/r", "swapout/x", "abc", api=lambda path, **kw: calls.append(kw), token="contents")
        self.assertEqual(calls[0]["tokens"], ["contents"])

    def test_the_workflow_mints_contents_and_workflows_tokens_apart(self) -> None:
        steps = {s.get("id"): s for s in yaml.safe_load(WORKFLOW.read_text())["jobs"]["revert"]["steps"] if s.get("id")}
        push, wf = steps["push-token"], steps["workflows-token"]
        self.assertEqual(push["with"].get("permission-contents"), "write")
        self.assertNotIn("permission-workflows", push["with"])
        self.assertEqual(wf["with"].get("permission-workflows"), "write")
        self.assertTrue(wf.get("continue-on-error"))
        run = next(s for s in yaml.safe_load(WORKFLOW.read_text())["jobs"]["revert"]["steps"] if "post_merge_batch.py revert" in str(s.get("run")))
        self.assertIn("steps.workflows-token.outputs.token", run["env"]["WORKFLOWS_TOKEN"])
        self.assertIn("{token}", run["run"])


if __name__ == "__main__":
    unittest.main()


class DispatchProbeRetryTests(unittest.TestCase):
    probe = pmb.Probe("web", "web / Web tests (2/4)", "web-tests", "f" * 40, "a" * 40, "b" * 40, "1")
    title = f"probe web web-tests at {'f' * 40}"

    def fake(self, answers: list, listed: list[dict] | None = None):
        calls: list[str] = []

        def api(path, method="GET", **_):
            calls.append(method)
            if method == "GET":
                return {"workflow_runs": listed or []}
            answer = answers.pop(0)
            if answer:
                raise RuntimeError(f"gh api POST {path}: {answer}")
            return None
        return api, calls

    def test_a_5xx_is_retried_until_the_dispatch_goes_through(self) -> None:
        api, calls = self.fake(["gh: Failed to run workflow dispatch (HTTP 500)", "gh: Server Error (HTTP 502)", None])
        waits: list[float] = []
        with unittest.mock.patch("sys.stderr"):
            pmb.dispatch_probe("o/r", "feat-cmux-next", self.probe, api=api, sleep=waits.append)
        self.assertEqual((calls, waits), (["POST", "GET", "POST", "GET", "POST"], [15, 45]))

    def test_a_5xx_whose_run_started_is_not_dispatched_again(self) -> None:
        api, calls = self.fake(["gh: Server Error (HTTP 502)"], listed=[{"display_title": self.title, "status": "queued"}])
        with unittest.mock.patch("sys.stderr"):
            pmb.dispatch_probe("o/r", "feat-cmux-next", self.probe, api=api, sleep=lambda s: None)
        self.assertEqual(calls, ["POST", "GET"])

    def test_other_errors_and_a_lasting_5xx_raise(self) -> None:
        api, calls = self.fake(["gh: Not Found (HTTP 404)"])
        with self.assertRaises(RuntimeError):
            pmb.dispatch_probe("o/r", "feat-cmux-next", self.probe, api=api, sleep=lambda s: None)
        self.assertEqual(calls, ["POST"])
        api, calls = self.fake(["gh: Server Error (HTTP 502)"] * 3)
        with self.assertRaises(RuntimeError), unittest.mock.patch("sys.stderr"):
            pmb.dispatch_probe("o/r", "feat-cmux-next", self.probe, api=api, sleep=lambda s: None)
        self.assertEqual(calls.count("POST"), 3)


class JudgeOriginUnreadableTest(unittest.TestCase):
    def judge(self, tries: int):
        args = Namespace(mode=pmb.PROBE, manifest=str(pmb.MANIFEST), repo="o/r", branch="feat-cmux-next", run_id="70",
                         sha="f" * 40, suite="web", job="web / Web tests (2/4)", only="web-tests", probe_sha="f" * 40,
                         good="a" * 40, bad="b" * 40, origin="60", tries=str(tries), pieces="", dry_run=False,
                         summary=None, github_output=None)
        sent: list = []

        def gh_api(path, *a, **k):
            raise RuntimeError(f"gh api {path}: API rate limit exceeded (HTTP 403)")

        with mock.patch.object(pmb, "run_jobs", return_value=[]), mock.patch.object(pmb, "gh_api", gh_api), \
                mock.patch.object(pmb, "dispatch_probe", lambda repo, branch, probe: sent.append(probe)), \
                mock.patch.object(pmb, "first_parent_range", return_value=[]):
            return pmb.cmd_judge(args), sent

    def test_an_unreadable_origin_runs_the_same_probe_again(self) -> None:
        code, sent = self.judge(0)
        self.assertEqual(code, 0)
        self.assertEqual([(p.sha, p.good, p.bad, p.origin, p.tries) for p in sent], [("f" * 40, "a" * 40, "b" * 40, "60", 1)])

    def test_an_origin_unreadable_past_the_retries_is_refused(self) -> None:
        code, sent = self.judge(pmb.MAX_PROBE_RETRIES)
        self.assertEqual((code, sent), (1, []))


class JudgeProbeReadsItsOwnJobTest(unittest.TestCase):
    def test_the_origin_check_walks_back_only_to_the_probe_jobs_green(self) -> None:
        probe_job, other = "web / Web tests (2/4)", "web / web-typecheck"
        batch = lambda rid, sha: {"id": rid, "status": "completed", "head_sha": sha * 40, "display_title": f"{pmb.BATCH} at {sha * 40}"}
        runs = [batch(50, "5"), batch(40, "4"), batch(30, "3")]
        judge = {"name": "judge", "status": "completed", "conclusion": "success"}
        jobs = {60: [{"name": probe_job, "status": "completed", "conclusion": "failure"}, {"name": other, "status": "completed", "conclusion": "failure"}, judge],
                50: [{"name": probe_job, "status": "completed", "conclusion": "success"}, {"name": other, "status": "completed", "conclusion": "failure"}, judge],
                40: [{"name": probe_job, "status": "completed", "conclusion": "success"}, {"name": other, "status": "completed", "conclusion": "failure"}, judge],
                30: [{"name": probe_job, "status": "completed", "conclusion": "success"}, {"name": other, "status": "completed", "conclusion": "success"}, judge],
                70: [{"name": probe_job, "status": "completed", "conclusion": "failure"}]}
        read: list[int] = []

        def run_jobs(repo, rid, api=None):
            read.append(int(rid))
            return jobs[int(rid)]

        args = Namespace(mode=pmb.PROBE, manifest=str(pmb.MANIFEST), repo="o/r", branch="feat-cmux-next", run_id="70",
                         sha="6" * 40, suite="web", job=probe_job, only="web-tests", probe_sha="6" * 40,
                         good="5" * 40, bad="", origin="60", tries="0", pieces="", dry_run=True, summary=None, github_output=None)
        with mock.patch.object(pmb, "run_jobs", run_jobs), mock.patch.object(pmb, "list_runs", return_value=runs), \
                mock.patch.object(pmb, "gh_api", return_value=batch(60, "6")), \
                mock.patch.object(pmb, "first_parent_range", return_value=["6" * 40]), mock.patch("sys.stderr"):
            pmb.cmd_judge(args)
        self.assertNotIn(40, read)
        self.assertNotIn(30, read)


    def test_a_stuck_reds_later_probe_is_not_refused_for_its_own_chain_steps(self) -> None:
        # Probe run 45971486391 (11-27 09:10Z): batch 45965089670 dispatched web / Web tests (1/4) at 27712e0b, a
        # stuck red's culprit step past earlier chains' probes; its judge read those judged steps as finished bisects
        # (no chain_start), so stuck_reds dropped the job and the probe was refused as "not a new red".
        job = "web / Web tests (2/4)"
        batch = lambda rid, sha, at: {"id": rid, "status": "completed", "head_sha": sha * 40, "display_title": f"{pmb.BATCH} at {sha * 40}",
                                      "created_at": at, "path": f".github/workflows/{pmb.WORKFLOW}", "head_branch": "feat-cmux-next"}
        step = lambda rid, sha, at: {"id": rid, "status": "completed", "display_title": f"{pmb.PROBE} web web-tests at {sha * 40}", "created_at": at}
        judge = {"name": "judge", "status": "completed", "conclusion": "success"}
        red, green = {"name": job, "status": "completed", "conclusion": "failure"}, {"name": job, "status": "completed", "conclusion": "success"}
        runs = [step(56, "2", "2026-11-27T08:50:00Z"), step(55, "2", "2026-11-27T08:40:00Z"), step(54, "2", "2026-11-27T08:30:00Z"),
                step(53, "2", "2026-11-27T08:20:00Z"), batch(50, "5", "2026-11-27T08:00:00Z"), batch(30, "1", "2026-11-27T07:00:00Z")]
        jobs = {60: [red, judge], 50: [red, judge], 30: [green, judge], 70: [red], **{r: [red, judge] for r in (53, 54, 55, 56)}}
        commits = [c * 40 for c in "23456"]
        args = Namespace(mode=pmb.PROBE, manifest=str(pmb.MANIFEST), repo="o/r", branch="feat-cmux-next", run_id="70",
                         sha="4" * 40, suite="web", job=job, only="web-tests", probe_sha="4" * 40, good="3" * 40, bad="5" * 40,
                         origin="60", tries="0", pieces="", dry_run=True, summary=None, github_output=None)
        out: dict = {}
        with mock.patch.object(pmb, "run_jobs", lambda repo, rid, api=None: jobs.get(int(rid), [])), \
                mock.patch.object(pmb, "list_runs", return_value=runs), \
                mock.patch.object(pmb, "gh_api", return_value=batch(60, "6", "2026-11-27T09:00:00Z")), \
                mock.patch.object(pmb, "first_parent_range", lambda good, head: commits[commits.index(good) + 1:] if good in commits else commits), \
                mock.patch.object(pmb, "write_outputs", lambda path, values: out.update(values)), mock.patch("sys.stderr"):
            code = pmb.cmd_judge(args)
        self.assertEqual(code, 0)  # refused is 1; here the culprit step goes on to its confirm runs


class KnownVerdictTest(unittest.TestCase):
    commits = [c * 40 for c in "abcdefghi"]  # a good ... i bad

    def judge(self, earlier: dict[str, str]):
        """A probe at e (good a, bad i) failed; earlier finished probe runs gave the verdicts in earlier."""
        a, e, i = "a" * 40, "e" * 40, "i" * 40
        job = "web / Web tests (2/4)"
        runs = [{"id": 100 + n, "status": "completed", "display_title": f"{pmb.PROBE} web web-tests at {sha * 40}"} for n, sha in enumerate(earlier)]
        jobs = {100 + n: [{"name": job, "conclusion": c}] for n, c in enumerate(earlier.values())}
        jobs[70] = [{"name": job, "conclusion": "failure"}]
        args = Namespace(mode=pmb.PROBE, manifest=str(pmb.MANIFEST), repo="o/r", branch="feat-cmux-next", run_id="70",
                         sha=e, suite="web", job=job, only="web-tests", probe_sha=e, good=a, bad=i, origin="60",
                         tries="0", pieces="", dry_run=False, summary=None, github_output=None)
        sent: list = []
        out: dict = {}
        with mock.patch.object(pmb, "run_jobs", lambda repo, rid: jobs.get(int(rid), [])), \
                mock.patch.object(pmb, "gh_api", lambda *a, **k: {"id": 60}), \
                mock.patch.object(pmb, "list_runs", return_value=runs), \
                mock.patch.object(pmb, "probe_refusal", return_value=""), \
                mock.patch.object(pmb, "suite_verdicts", lambda js, suites: {j["name"]: ("web", j["conclusion"]) for j in js}), \
                mock.patch.object(pmb, "dispatch_probe", lambda repo, branch, probe: sent.append(probe)), \
                mock.patch.object(pmb, "write_outputs", lambda path, values: out.update(values)), \
                mock.patch.object(pmb, "first_parent_range", return_value=self.commits):
            self.assertEqual(pmb.cmd_judge(args), 0)
        return sent, out

    def test_no_earlier_probe_dispatches_the_next_one(self) -> None:
        sent, out = self.judge({})
        self.assertEqual([p.sha for p in sent], ["c" * 40])  # b..e, its middle
        self.assertEqual(out["culprit"], "")

    def test_earlier_verdicts_are_read_instead_of_probed_again(self) -> None:
        # e failed (this run); c passed and d failed earlier: d is the culprit with no new probe.
        # It is confirmed before any revert: CONFIRM_RUNS more runs at d and at its parent c, all at once.
        sent, out = self.judge({"c": "success", "d": "failure"})
        self.assertEqual(sorted((p.confirm, p.sha, p.good, p.bad) for p in sent),
                         sorted((f"{side}-{n}", sha * 40, "c" * 40, "d" * 40) for n in range(1, pmb.CONFIRM_RUNS + 1)
                                for side, sha in (("red", "d"), ("green", "c"))))
        self.assertEqual(out["culprit"], "")

    def test_an_earlier_probe_without_verdict_is_probed_again(self) -> None:
        sent, _ = self.judge({"c": "cancelled"})
        self.assertEqual([p.sha for p in sent], ["c" * 40])

    def test_an_earlier_skipped_probe_is_not_probed_again(self) -> None:
        sent, out = self.judge({"c": "skipped"})
        self.assertEqual((sent, out["culprit"]), ([], ""))


class FlakeAwareConfirmTest(unittest.TestCase):
    """Before a culprit's revert opens, it fails CONFIRM_RUNS more times and its parent passes CONFIRM_RUNS more times
    (Henderson et al., Flake Aware Culprit Finding, ICST 2023)."""

    job = "web / Web tests (2/4)"
    culprit, parent = "d" * 40, "c" * 40

    def judge(self, me: str, conclusion: str, others: dict[str, tuple[str, str]], run_id: int = 90):
        """The judge of confirm run me (verdict conclusion, run run_id); others: each other confirm run's
        (verdict, run status), by its label. Run ids follow the labels' order, so red-1 is the oldest."""
        labels = [p.confirm for p in pmb.confirm_probes(pmb.Probe("web", self.job, "web-tests", "", "", "", "60"), self.culprit, self.parent)]
        runs, jobs = [], {run_id: [{"name": self.job, "conclusion": conclusion}]}
        for n, label in enumerate(labels):
            if label not in others:
                continue
            verdict, status = others[label]
            sha = self.culprit if label.startswith("red") else self.parent
            rid = 80 + n
            runs.append({"id": rid, "status": status, "display_title": f"{pmb.PROBE} web web-tests at {sha} confirm {label}"})
            jobs[rid] = [{"name": self.job, "conclusion": verdict}] + ([{"name": "judge", "conclusion": "success"}] if status == "completed" else [])
        sha = self.culprit if me.startswith("red") else self.parent
        args = Namespace(mode=pmb.PROBE, manifest=str(pmb.MANIFEST), repo="o/r", branch="feat-cmux-next", run_id=str(run_id),
                         sha="f" * 40, suite="web", job=self.job, only="web-tests", probe_sha=sha, good=self.parent,
                         bad=self.culprit, origin="60", tries="0", pieces="", confirm=me, dry_run=False, summary=None,
                         github_output=None)
        sent: list = []
        out: dict = {}
        with mock.patch.object(pmb, "run_jobs", lambda repo, rid: jobs.get(int(rid), [])), \
                mock.patch.object(pmb, "gh_api", lambda *a, **k: {"id": 60}), \
                mock.patch.object(pmb, "list_runs", return_value=runs), \
                mock.patch.object(pmb, "probe_refusal", return_value=""), \
                mock.patch.object(pmb, "suite_verdicts", lambda js, suites: {j["name"]: ("web", j["conclusion"]) for j in js if j["name"] != "judge"}), \
                mock.patch.object(pmb, "dispatch_probe", lambda repo, branch, probe: sent.append(probe)):
            with mock.patch.object(pmb, "write_outputs", lambda path, values: out.update(values)):
                self.assertEqual(pmb.cmd_judge(args), 0)
        return sent, out

    def test_a_flaky_red_mid_bisect_is_caught_at_confirm_and_opens_no_revert(self) -> None:
        # The bisect named d off one flaky red run: d passes on a confirm run, so no revert, wherever that run lands.
        done = "completed"
        sent, out = self.judge("green-2", "success", {"red-1": ("success", done), "green-1": ("success", done), "red-2": ("failure", done)})
        self.assertEqual((sent, out["culprit"]), ([], ""))
        sent, out = self.judge("red-1", "success", {})
        self.assertEqual((sent, out["culprit"]), ([], ""))  # a disagreeing run decides at once, with the rest pending
        sent, out = self.judge("red-2", "failure", {"red-1": ("failure", done), "green-1": ("failure", done), "green-2": ("success", done)})
        self.assertEqual(out["culprit"], "")  # the parent failed again: the red is not d's

    def test_a_real_culprit_still_reverts_once(self) -> None:
        done = "completed"
        # The newest confirm run's judge, with the rest settled and agreeing: the revert opens.
        sent, out = self.judge("green-2", "success", {"red-1": ("failure", done), "green-1": ("success", done), "red-2": ("failure", done)})
        self.assertEqual(sent, [])
        self.assertEqual((out["culprit"], out["good"], out["job"], out["origin"]), (self.culprit, self.parent, self.job, "60"))
        # An older run's judge sees every verdict while the newest run's judge is still to come: it leaves it to that one.
        _, out = self.judge("red-1", "failure", {"green-1": ("success", "in_progress"), "red-2": ("failure", done), "green-2": ("success", "in_progress")}, run_id=70)
        self.assertEqual(out["culprit"], "")
        # A run still going with no verdict yet: wait.
        _, out = self.judge("green-2", "success", {"red-1": ("failure", done), "green-1": ("", "in_progress"), "red-2": ("failure", done)})
        self.assertEqual(out["culprit"], "")

    def test_a_confirm_run_with_no_verdict_runs_again(self) -> None:
        sent, out = self.judge("red-1", "cancelled", {})
        self.assertEqual([(p.confirm, p.sha, p.tries) for p in sent], [("red-1", self.culprit, 1)])
        self.assertEqual(out["culprit"], "")

    def test_the_guard_accepts_the_round_and_refuses_a_forged_one(self) -> None:
        g = GuardTest()
        ok = lambda sha, good, bad, c: g.refusal(pmb.Probe("s", "s / j", "j", sha, good, bad, "50", confirm=c))
        self.assertEqual(ok("c3", "c2", "c3", "red-1"), "")
        self.assertEqual(ok("c2", "c2", "c3", "green-2"), "")
        self.assertEqual(ok("g", "g", "c1", "green-1"), "")  # the culprit is the first covered commit: its parent is the last green
        self.assertIn("parent", ok("c1", "c1", "c3", "green-1"))
        self.assertIn("culprit or parent", ok("c4", "c2", "c3", "red-1"))
        self.assertIn("bad", ok("x", "x0", "x", "red-1"))


class SkippedProbeTest(unittest.TestCase):
    """Probes 716208d2c92 and d98c77aec8a (compile-fleet, 11-27): the job's own condition skipped it, and each ran three times."""

    def test_a_skipped_probe_is_not_retried(self) -> None:
        probe = pmb.Probe("s", "s / j", "j", "c1", "g", "c3", "1")
        self.assertEqual(pmb.next_step(probe, "skipped", ["c1", "c2", "c3"]), ("lost", None))

    def test_a_skip_behind_a_lost_job_is_no_verdict(self) -> None:
        probe = pmb.Probe("s", "s / j", "j", "c1", "g", "c3", "1")
        self.assertEqual(pmb.probe_conclusion({"s / j": ("s", "skipped"), "s / plan": ("s", "cancelled")}, probe), "")
        self.assertEqual(pmb.probe_conclusion({"s / j": ("s", "skipped"), "s / plan": ("s", "success")}, probe), "skipped")

    def test_a_matrix_leg_skipped_behind_a_lost_plan_is_no_verdict(self) -> None:
        # Probe run 45969411338: plan lost its runner (failure), the leg is listed by its bare name as skipped.
        probe = pmb.Probe("gallery-health", "gallery-health / health (0)", "health", "c6", "g", "c6", "1")
        lost = {"gallery-health / plan": ("gallery-health", "failure"), "gallery-health / health": ("gallery-health", "skipped")}
        self.assertEqual(pmb.probe_conclusion(lost, probe), "")
        ran = {"gallery-health / plan": ("gallery-health", "success"), "gallery-health / health (0)": ("gallery-health", "failure")}
        self.assertEqual(pmb.probe_conclusion(ran, probe), "failure")


class FirstUnknownProbeTest(unittest.TestCase):
    """A stuck red's bisect starts again about hourly: its first probe skips the commits earlier bisects probed."""
    commits = [c * 40 for c in "bcdefghi"]  # good a, bad i

    def first(self, earlier: dict[str, str]):
        runs = [{"id": 100 + n, "status": "completed", "display_title": f"{pmb.PROBE} s j at {sha * 40}"} for n, sha in enumerate(earlier)]
        verdicts = {100 + n: ({"s / j": ("s", c)}, True) for n, c in enumerate(earlier.values())}
        start = pmb.stuck_probe("s / j", "s", "j", "a" * 40, "i" * 40, "1", self.commits)
        return pmb.first_unknown_probe(runs, start, self.commits, lambda rid: verdicts[rid])

    def test_no_earlier_probe_starts_mid_range(self) -> None:
        probe, notes = self.first({})
        self.assertEqual((probe.sha, notes), ("e" * 40, []))

    def test_known_verdicts_move_the_first_probe(self) -> None:
        # e failed earlier: b..e, its middle c; c passed earlier: d..e, its middle d.
        probe, notes = self.first({"e": "failure", "c": "success"})
        self.assertEqual((probe.sha, probe.good, probe.bad, len(notes)), ("d" * 40, "c" * 40, "e" * 40, 2))

    def test_a_known_verdict_that_ends_the_bisect_keeps_its_probe(self) -> None:
        probe, _ = self.first({"e": "failure", "c": "success", "d": "failure"})
        self.assertEqual(probe.sha, "d" * 40)  # its judge reads d as the culprit, as before

    def test_a_known_skip_dispatches_nothing(self) -> None:
        probe, notes = self.first({"e": "skipped"})
        self.assertIsNone(probe)
        self.assertEqual(len(notes), 1)


class ListRunsLookbackTest(unittest.TestCase):
    """The judge pages past probes until it holds LOOKBACK_BATCHES batch runs older than its own run."""

    def runs_api(self, kinds: str, calls: list):
        runs = [{"id": 1000 - i, "display_title": f"{'batch' if k == 'b' else 'probe'} x", "created_at": f"2026-11-27T{23 - i // 60:02d}:{59 - i % 60:02d}:00Z"}
                for i, k in enumerate(kinds)]

        def api(path, **_kw):
            calls.append(path)
            page = int(path.rpartition("&page=")[2]) if "&page=" in path else 1
            return {"workflow_runs": runs[(page - 1) * pmb.RUNS_PAGE: page * pmb.RUNS_PAGE]}
        return api

    def test_pages_past_probes_to_the_batches_it_needs(self) -> None:
        calls: list = []
        # 250 runs, a batch every 50th; run 1000 (the judging batch) is excluded, so page 1 holds one older
        # batch run and three need page 2.
        api = self.runs_api("".join("b" if i % 50 == 0 else "p" for i in range(250)), calls)
        got = pmb.list_runs("o/r", "feat", api=api, before=1000, batches=3)
        self.assertEqual(len(calls), 2)
        self.assertEqual(sum(map(pmb.is_batch, got)), 3)
        self.assertTrue(all(r["id"] < 1000 for r in got))
        self.assertTrue(pmb.is_batch(got[-1]))

    def test_stops_at_the_last_page_and_at_the_page_cap(self) -> None:
        calls: list = []
        self.assertEqual(len(pmb.list_runs("o/r", "feat", api=self.runs_api("p" * 150, calls), batches=3)), 150)
        self.assertEqual(len(calls), 2)
        calls = []
        pmb.list_runs("o/r", "feat", api=self.runs_api("p" * 2000, calls), batches=3)
        self.assertEqual(len(calls), pmb.MAX_RUNS_PAGES)

    def test_one_page_without_batches(self) -> None:
        calls: list = []
        self.assertEqual(len(pmb.list_runs("o/r", "feat", api=self.runs_api("p" * 250, calls))), 100)
        self.assertEqual(len(calls), 1)


class SameRedTest(unittest.TestCase):
    """A probe is red only when it reproduces the origin's red (its failing step), and a new red's matrix legs are one
    bisect (gallery-health run 45942875725: 22 legs red on gallery:build, probes failing on composer layout flakes)."""

    job = "gallery-health / health (3)"

    def probe(self, step: str = "Build gallery") -> "pmb.Probe":
        return pmb.Probe("gallery-health", self.job, "health", "e" * 40, "c" * 40, "d" * 40, "60", step=step)

    def failed(self, *steps: str, job: str = "gallery-health / health (3)") -> list:
        return [{"name": job, "status": "completed", "conclusion": "failure",
                 "steps": [{"name": n, "conclusion": "failure"} for n in steps] + [{"name": "Set up job", "conclusion": "success"}]}]

    def conclusion(self, probe, jobs) -> str:
        verdicts = {j["name"]: ("gallery-health", j["conclusion"]) for j in jobs}
        return pmb.probe_conclusion(verdicts, probe, pmb.failing_steps(jobs))

    def test_failure_on_the_origins_step_is_red(self) -> None:
        self.assertEqual(self.conclusion(self.probe(), self.failed("Build gallery")), "failure")
        # Legs merge: another leg of the same job failing the origin's step counts.
        jobs = self.failed("Judge the red states against the base") + self.failed("Build gallery", job="gallery-health / health (4)")
        verdicts = {j["name"]: ("gallery-health", j["conclusion"]) for j in jobs}
        p = self.probe()
        p.job = "gallery-health / health (9)"
        self.assertEqual(pmb.probe_conclusion(verdicts, p, pmb.failing_steps(jobs)), "failure")

    def test_failure_on_another_step_is_good_for_this_red(self) -> None:
        self.assertEqual(self.conclusion(self.probe(), self.failed("Judge the red states against the base")), "success")

    def test_no_origin_step_or_no_failed_step_keeps_the_old_verdict(self) -> None:
        self.assertEqual(self.conclusion(self.probe(""), self.failed("Judge the red states against the base")), "failure")
        self.assertEqual(self.conclusion(self.probe(), self.failed()), "failure")  # lost runner: no step to compare
        self.assertEqual(pmb.probe_conclusion({self.job: ("gallery-health", "failure")}, self.probe()), "failure")

    def test_the_step_travels_with_the_probe(self) -> None:
        p = self.probe("Build gallery|Other")
        self.assertEqual(p.inputs()["step"], "Build gallery|Other")
        self.assertNotIn("step", self.probe("").inputs())
        mid = pmb.Probe(p.suite, p.job, p.only, "c" * 40, "a" * 40, "e" * 40, p.origin, step=p.step)
        nxt = pmb.next_step(mid, "failure", ["a" * 40, "b" * 40, "c" * 40, "d" * 40, "e" * 40])
        self.assertEqual((nxt[0], nxt[1].step), ("probe", p.step))
        self.assertTrue(all(c.step == p.step for c in pmb.confirm_probes(p, "d" * 40, "c" * 40)))

    def test_confirm_round_reads_a_different_red_as_a_pass(self) -> None:
        p = self.probe()
        p.confirm = "red-1"
        title = lambda other: pmb.probe_title(other)
        others = pmb.confirm_probes(p, p.bad, p.good)
        runs = [{"id": 80 + n, "status": "completed", "display_title": title(o)} for n, o in enumerate(others) if o.confirm != "red-1"]
        steps = {80 + n: {self.job: frozenset({"Build gallery" if o.confirm.startswith("red") else "Judge the red states against the base"})}
                 for n, o in enumerate(others)}
        jobs_of = lambda rid: ({self.job: ("gallery-health", "failure")}, True)
        got, _ = pmb.judge_confirm(p, "failure", 90, runs, jobs_of, lambda rid: steps[rid])
        # Green runs fail on another step: they read as passes, so the round holds. Without steps they read as failures.
        self.assertEqual(got, "culprit")
        self.assertEqual(pmb.judge_confirm(p, "failure", 90, runs, jobs_of)[0], "flake")

    def test_matrix_legs_of_a_new_red_are_one_bisect(self) -> None:
        suites = {"gallery-health": pmb.Suite("gallery-health", "g.yml", ["x/**"], {"health": "health"}),
                  "web": pmb.Suite("web", "w.yml", ["web/**"], {"check": "check"})}
        legs = {f"gallery-health / health ({n})": ("gallery-health", "failure") for n in range(22)}
        verdicts = {**legs, "web / check": ("web", "failure")}
        runs = [run(1, "c" * 40, "2026-11-21T08:00:00Z")]
        older = {1: {**{k: ("gallery-health", "success") for k in legs}, "web / check": ("web", "success")}}
        found, _ = pmb.new_reds("a" * 40, verdicts, runs, lambda rid: older[rid], suites)
        self.assertEqual([f[0] for f in found], ["gallery-health / health (0)", "web / check"])
        self.assertEqual(len(pmb.new_reds("a" * 40, verdicts, runs, lambda rid: older[rid])[0]), 2)

    def test_the_workflow_passes_the_step_input(self) -> None:
        text = WORKFLOW.read_text()
        self.assertIn('--step "$STEP"', text)
        self.assertIn("STEP: ${{ inputs.step }}", text)
