#!/usr/bin/env python3
"""Tests for scripts/ci/dead_labels.py over fixture job JSON (no network)."""

from __future__ import annotations

import datetime as dt
import importlib.util
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
SPEC = importlib.util.spec_from_file_location("dead_labels", ROOT / "scripts/ci/dead_labels.py")
dead_labels = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules["dead_labels"] = dead_labels
SPEC.loader.exec_module(dead_labels)

NOW = dt.datetime(2026, 10, 28, 22, 30, tzinfo=dt.timezone.utc)
B16 = "blacksmith-16vcpu-ubuntu-2404"
B32 = "blacksmith-32vcpu-ubuntu-2404"
B4 = "blacksmith-4vcpu-ubuntu-2404"
STD = "glaeda-std-xcode-26.6"
SIDE = "glaeda-side-std-xcode-26.6"
_ids = iter(range(1000, 10**6))


def iso(minutes_ago: float) -> str:
    return (NOW - dt.timedelta(minutes=minutes_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")


def job(label=B16, *, status="queued", created=10.0, started=None, runner=None, name="lint", conclusion=None,
        attempt=1, completed=0.0):
    return {"id": next(_ids), "name": name, "status": status, "conclusion": conclusion, "labels": [label],
            "created_at": iso(created), "started_at": iso(created if started is None else started),
            "completed_at": iso(completed) if status == "completed" else None, "runner_name": runner, "run_attempt": attempt}


def ran(label, minutes_ago=1.0, *, status="in_progress", name="build"):
    return job(label, status=status, created=minutes_ago + 0.5, started=minutes_ago, runner=f"{label}-vm",
               name=name, conclusion="success" if status == "completed" else None, completed=max(minutes_ago - 5, 0))


def run(run_id, *, event="pull_request", path=".github/workflows/ci.yml", name="CI", attempt=1, status="queued",
        branch="feature", created=12.0):
    return {"id": run_id, "event": event, "path": path, "name": name, "display_title": name, "run_attempt": attempt,
            "status": status, "head_branch": branch, "created_at": iso(created)}


class DeadLabelTests(unittest.TestCase):
    def dead(self, jobs_by_run, runs=None, **kw):
        runs = runs or [run(rid) for rid in jobs_by_run]
        return dead_labels.dead_labels(runs, jobs_by_run, now=NOW, **kw)

    def test_the_2026_10_28_shape_16_dead_while_32_starts(self) -> None:
        found = self.dead({1: [job(B16, created=40)], 2: [ran(B32, 1)]})
        self.assertEqual([item.name() for item in found], [B16])
        self.assertEqual(found[0].live, (B32,))
        self.assertEqual(found[0].family, "linux")
        self.assertEqual(found[0].as_json()["oldest_queued_minutes"], 40)

    def test_under_three_minutes_is_not_dead(self) -> None:
        self.assertEqual(self.dead({1: [job(B16, created=2)], 2: [ran(B32, 1)]}), [])

    def test_a_start_on_the_label_within_the_window_keeps_it_alive(self) -> None:
        # A backed-up label that still starts jobs is slow, not dead.
        self.assertEqual(self.dead({1: [job(B16, created=40)], 2: [ran(B16, 2)], 3: [ran(B32, 1)]}), [])

    def test_a_blacksmith_job_running_since_before_the_stall_is_no_service(self) -> None:
        found = self.dead({1: [job(B16, created=40)], 2: [ran(B16, 30)], 3: [ran(B32, 1)]})
        self.assertEqual([item.name() for item in found], [B16])

    def test_a_running_owned_job_is_service(self) -> None:
        # A busy pool of minis is not dead: the listener is online.
        self.assertEqual(self.dead({1: [job(STD, created=40)], 2: [ran(STD, 30)], 3: [ran(SIDE, 1)]}), [])

    def test_an_owned_label_with_nothing_running_and_nothing_started_is_dead(self) -> None:
        found = self.dead({1: [job(SIDE, created=40)], 2: [ran(STD, 1)]})
        self.assertEqual([(item.name(), item.family) for item in found], [(SIDE, "macos")])

    def test_no_live_member_of_the_family_means_nothing_moves(self) -> None:
        # Every Linux label stalled (or the inventory saw no start): a re-run would only queue again.
        self.assertEqual(self.dead({1: [job(B16, created=40)], 2: [job(B32, created=40)], 3: [ran(STD, 1)]}), [])

    def test_a_job_behind_a_running_sibling_has_not_begun_waiting(self) -> None:
        self.assertEqual(self.dead({1: [job(B16, created=40), ran(B32, 20)], 2: [ran(B32, 1)]}), [])

    def test_hosted_labels_are_never_a_family(self) -> None:
        self.assertEqual(self.dead({1: [job("ubuntu-24.04", created=40)], 2: [ran(B32, 1)]}), [])

    def test_evidence_jobs_count_as_service(self) -> None:
        self.assertEqual(self.dead({1: [job(B16, created=40)], 2: [ran(B32, 1)]}, evidence={9: [ran(B16, 1)]}), [])


class PlanTests(unittest.TestCase):
    def plan(self, runs, jobs_by_run, **kw):
        dead = dead_labels.dead_labels(runs, jobs_by_run, now=NOW)
        return dead_labels.plan(runs, jobs_by_run, dead, **kw)

    def inventory(self, stuck_run, stuck_jobs):
        return [stuck_run, run(99, status="in_progress")], {stuck_run["id"]: stuck_jobs, 99: [ran(B32, 1)]}

    def test_a_stuck_pull_request_run_goes(self) -> None:
        runs, jobs = self.inventory(run(1), [job(B16, created=40)])
        decisions = self.plan(runs, jobs, routes=[B32])
        self.assertEqual([(d.run["id"], d.label, d.why_not) for d in decisions], [(1, B16, None)])

    def test_main_push_runs_go_too_since_the_re_run_keeps_them(self) -> None:
        runs, jobs = self.inventory(run(1, event="push", branch="main"), [job(B16, created=40)])
        self.assertIsNone(self.plan(runs, jobs, routes=[B32])[0].why_not)

    def test_a_started_nightly_is_never_cancelled(self) -> None:
        nightly = run(1, event="push", path=".github/workflows/nightly.yml", name="Nightly macOS build",
                      branch="nightly-next")
        runs, jobs = self.inventory(nightly, [ran(B32, 20, status="completed", name="build nightly inputs"),
                                              job(B16, created=40, name="build-nightly-ghostty-cli-helper")])
        decision = self.plan(runs, jobs, routes=[B32])[0]
        self.assertIn("nightly, DEV or promote run that has started", decision.why_not)

    def test_an_unstarted_dev_daily_run_may_move(self) -> None:
        dev = run(1, event="workflow_dispatch", path=".github/workflows/cmux-next-dev-daily.yml",
                  name="cmux NEXT DEV daily", branch="main")
        runs, jobs = self.inventory(dev, [ran(B32, 20, status="completed", name="decide"),
                                          job(B16, created=40, name="build-app")])
        self.assertIsNone(self.plan(runs, jobs, routes=[B32])[0].why_not)

    def test_a_running_sibling_holds_the_run(self) -> None:
        runs, jobs = self.inventory(run(1), [job(B16, created=40), ran(STD, 30)])
        decisions = self.plan(runs, jobs, routes=[B32])
        # The running sibling also means the stuck job may be waiting on it: no decision, or a held one.
        self.assertTrue(all(d.why_not for d in decisions))

    def test_release_and_merge_queue_runs_are_left_alone(self) -> None:
        for stuck in (run(1, event="merge_group"), run(1, path=".github/workflows/release.yml", name="Release")):
            runs, jobs = self.inventory(stuck, [job(B16, created=40)])
            self.assertIsNotNone(self.plan(runs, jobs, routes=[B32])[0].why_not)

    def test_attempt_three_is_left_alone(self) -> None:
        runs, jobs = self.inventory(run(1, attempt=3), [job(B16, created=40, attempt=3)])
        self.assertIn("attempt 3", self.plan(runs, jobs, routes=[B32])[0].why_not)

    def test_a_dead_label_that_is_the_current_route_waits_for_the_switch(self) -> None:
        runs, jobs = self.inventory(run(1), [job(B16, created=40)])
        self.assertIn("route a re-run takes again", self.plan(runs, jobs, routes=[B16])[0].why_not)

    def test_the_unset_linux_runner_default_is_a_route(self) -> None:
        self.assertIn(dead_labels.DEFAULT_LINUX_ROUTE, dead_labels.routes_from_env({}))
        self.assertNotIn(dead_labels.DEFAULT_LINUX_ROUTE, dead_labels.routes_from_env(
            {"DEAD_LABEL_LINUX_RUNNER": B32, "DEAD_LABEL_ROUTES": f"{B32} {STD}"}))

    def test_runs_already_acted_on_and_the_cap(self) -> None:
        runs = [run(1, created=50), run(2, created=40), run(3, created=30), run(99, status="in_progress")]
        jobs = {1: [job(B16, created=45)], 2: [job(B16, created=35)], 3: [job(B16, created=25)], 99: [ran(B32, 1)]}
        dead = dead_labels.dead_labels(runs, jobs, now=NOW)
        decisions = dead_labels.plan(runs, jobs, dead, routes=[B32], exclude={1}, max_runs=1)
        self.assertEqual([(d.run["id"], d.why_not is None) for d in decisions], [(2, True), (3, False)])
        self.assertIn("cap", decisions[1].why_not)


class FakeGitHub:
    def __init__(self, settle_after=1, rerun_error=None, attempt_moves=False):
        self.calls: list[tuple[str, int]] = []
        self.reads: dict[int, int] = {}
        self.settle_after = settle_after
        self.rerun_error = rerun_error
        self.attempt_moves = attempt_moves

    def force_cancel(self, run_id):
        self.calls.append(("force-cancel", run_id))

    def run(self, run_id):
        self.reads[run_id] = self.reads.get(run_id, 0) + 1
        done = self.reads[run_id] >= self.settle_after
        return {"id": run_id, "status": "completed" if done else "in_progress",
                "run_attempt": 2 if self.attempt_moves else 1}

    def rerun_failed(self, run_id):
        self.calls.append(("rerun", run_id))
        if self.rerun_error:
            raise RuntimeError(self.rerun_error)


class RedispatchTests(unittest.TestCase):
    def decisions(self):
        return [dead_labels.Redispatch(run(1), "lint", B16, None), dead_labels.Redispatch(run(2), "lint", B16, "held")]

    def test_cancel_then_rerun_and_held_runs_untouched(self) -> None:
        github = FakeGitHub(settle_after=2)
        clock = iter(range(0, 1000))
        results, failures = dead_labels.redispatch(github, self.decisions(), dry_run=False,
                                                   now=lambda: next(clock), sleep=lambda _: None)
        self.assertEqual(github.calls, [("force-cancel", 1), ("rerun", 1)])
        self.assertEqual(failures, 0)
        self.assertIn("re-run", results[1])

    def test_dry_run_touches_nothing(self) -> None:
        github = FakeGitHub()
        results, _ = dead_labels.redispatch(github, self.decisions(), dry_run=True)
        self.assertEqual(github.calls, [])
        self.assertIn("dry run", results[1])

    def test_a_cancel_that_never_settles_is_named_for_a_person(self) -> None:
        github = FakeGitHub(settle_after=10**9)
        clock = iter(range(0, 10**6, 50))
        results, failures = dead_labels.redispatch(github, self.decisions(), dry_run=False,
                                                   now=lambda: next(clock), sleep=lambda _: None)
        self.assertEqual(failures, 1)
        self.assertIn("by hand", results[1])
        self.assertNotIn(("rerun", 1), github.calls)

    def test_someone_elses_rerun_is_not_doubled(self) -> None:
        github = FakeGitHub(attempt_moves=True)
        results, failures = dead_labels.redispatch(github, self.decisions(), dry_run=False, sleep=lambda _: None)
        self.assertEqual(github.calls, [("force-cancel", 1)])
        self.assertEqual(failures, 0)
        self.assertIn("someone else", results[1])

    def test_a_failed_rerun_is_a_failure(self) -> None:
        results, failures = dead_labels.redispatch(FakeGitHub(rerun_error="(403)"), self.decisions(), dry_run=False,
                                                   sleep=lambda _: None)
        self.assertEqual(failures, 1)
        self.assertIn("by hand", results[1])


class WiringTests(unittest.TestCase):
    def test_the_janitor_runs_the_pass_and_passes_the_routes(self) -> None:
        janitor = (ROOT / "scripts/ci/queue_janitor.py").read_text(encoding="utf-8")
        self.assertIn("dead_labels.redispatch(", janitor)
        self.assertIn('snapshot["dead_labels"]', janitor)
        workflow = yaml.safe_load((ROOT / ".github/workflows/ci-queue-janitor.yml").read_text(encoding="utf-8"))
        step = next(s for s in workflow["jobs"]["sweep"]["steps"] if s.get("name") == "Cancel wasted macOS runs")
        self.assertIn("vars.LINUX_RUNNER", step["env"]["DEAD_LABEL_ROUTES"])
        self.assertEqual(step["env"]["DEAD_LABEL_LINUX_RUNNER"], "${{ vars.LINUX_RUNNER }}")


if __name__ == "__main__":
    unittest.main()
