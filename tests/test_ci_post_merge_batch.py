#!/usr/bin/env python3
"""The post-merge batch tier (scripts/ci/post_merge_batch.py): the tick, the plan, the red
judgement and the bisect, plus the manifest, the caller jobs and the callees kept in step."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
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

    def test_window_value(self) -> None:
        self.assertEqual(pmb.window_minutes(""), 120)
        self.assertEqual(pmb.window_minutes("bad"), 120)
        self.assertEqual(pmb.window_minutes("45"), 45)


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

    def test_a_probe_without_verdict_retries_once(self) -> None:
        probe = pmb.Probe("s", "s / j", "j", "c1", "g", "c3", "1")
        step, again = pmb.next_step(probe, "cancelled", ["c1", "c2", "c3"])
        self.assertEqual((step, again.tries), ("retry", 1))
        self.assertEqual(pmb.next_step(again, "cancelled", ["c1", "c2", "c3"])[0], "lost")

    def test_first_parent_range_on_a_real_repo(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            def g(*argv: str) -> str:
                return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *argv], cwd=tmp, check=True, capture_output=True, text=True).stdout.strip()
            g("init", "-q")
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
            self.assertEqual(job["with"], {"sha": "${{ needs.plan.outputs.sha }}", "only": "${{ needs.plan.outputs.only }}"}, key)
            self.assertNotIn("name", job, f"{key}: the caller job's name must be the suite key")
        self.assertEqual(set(jobs["judge"]["needs"]), {"plan", *self.suites})

    def test_each_callee_takes_sha_and_only_and_gates_its_jobs(self) -> None:
        for key, suite in self.suites.items():
            callee = yaml.safe_load((WORKFLOW.parent / suite.workflow).read_text())
            on = callee.get(True) or callee.get("on")
            inputs = on["workflow_call"]["inputs"]
            self.assertTrue({"sha", "only"} <= set(inputs), key)
            for job_id in suite.jobs:
                gate = str(callee["jobs"][job_id].get("if", ""))
                self.assertIn(f"inputs.only == '{job_id}'", gate, f"{key}/{job_id}")
            self.assertIn("inputs.sha", (WORKFLOW.parent / suite.workflow).read_text(), key)


if __name__ == "__main__":
    unittest.main()
