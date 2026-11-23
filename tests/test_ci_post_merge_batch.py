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

    def test_window_value(self) -> None:
        self.assertEqual(pmb.window_minutes(""), 120)
        self.assertEqual(pmb.window_minutes("bad"), 120)
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


if __name__ == "__main__":
    unittest.main()
