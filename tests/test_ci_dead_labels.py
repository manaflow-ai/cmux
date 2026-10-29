#!/usr/bin/env python3
"""Tests for scripts/ci/dead_labels.py over fixture job JSON (no network)."""

from __future__ import annotations

import datetime as dt
import importlib.util
import io
import json
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
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


LINUX_RUNS_ON = ("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.LINUX_RUNNER || "
                 "'blacksmith-4vcpu-ubuntu-2404' }}")
PICKED_RUNS_ON = "${{ needs.pick.outputs.runner || vars.MACOS_RUNNER_26 || 'blacksmith-6vcpu-macos-26' }}"


def workflow(runs_on=LINUX_RUNS_ON, name="lint", extra=""):
    return f"name: CI\non: push\njobs:\n  lint:\n    name: {name}\n    runs-on: \"{runs_on}\"\n    steps: []\n{extra}"


VALUES = {"LINUX_RUNNER": B32, "MACOS_RUNNER_26": ""}


class PlanTests(unittest.TestCase):
    def plan(self, runs, jobs_by_run, *, text=None, values=VALUES, **kw):
        dead = dead_labels.dead_labels(runs, jobs_by_run, now=NOW)
        reads = []

        def read(run, path):
            reads.append(path)
            return workflow() if text is None else text
        self.reads = reads
        return dead_labels.plan(runs, jobs_by_run, dead, values=values, repo="manaflow-ai/cmux", workflow_text=read,
                                **kw)

    def inventory(self, stuck_run, stuck_jobs):
        return [stuck_run, run(99, status="in_progress")], {stuck_run["id"]: stuck_jobs, 99: [ran(B32, 1)]}

    def test_a_job_whose_variable_now_names_a_live_label_goes(self) -> None:
        runs, jobs = self.inventory(run(1), [job(B16, created=40)])
        decisions = self.plan(runs, jobs)
        self.assertEqual([(d.run["id"], d.label, d.why_not, d.whole) for d in decisions], [(1, B16, None, False)])
        self.assertIn(B32, decisions[0].note)
        self.assertEqual(self.reads, [".github/workflows/ci.yml"])

    def test_a_variable_still_naming_the_dead_label_is_left(self) -> None:
        runs, jobs = self.inventory(run(1), [job(B16, created=40)])
        self.assertIn("lands on", self.plan(runs, jobs, values={"LINUX_RUNNER": B16})[0].why_not)

    def test_an_unset_variable_falls_back_to_its_literal(self) -> None:
        # MACOS_RUNNER_15 unset falls back to the literal: if that literal is the dead label, nothing moves.
        runs, jobs = self.inventory(run(1), [job(B4, created=40)])
        self.assertIn("lands on", self.plan(runs, jobs, values={"LINUX_RUNNER": ""})[0].why_not)

    def test_a_literal_or_single_host_runs_on_is_flagged_not_moved(self) -> None:
        runs, jobs = self.inventory(run(1), [job(B16, created=40)])
        for runs_on in (B16, "${{ 'blacksmith-16vcpu-ubuntu-2404' }}", "${{ inputs.runner }}",
                        "${{ matrix.runner }}", "${{ vars.NOT_PASSED }}"):
            decision = self.plan(runs, jobs, text=workflow(runs_on))[0]
            self.assertIsNotNone(decision.why_not, runs_on)

    def test_a_picker_routed_job_reruns_the_whole_run(self) -> None:
        runs, jobs = self.inventory(run(1), [job(B16, created=40)])
        decision = self.plan(runs, jobs, text=workflow(PICKED_RUNS_ON))[0]
        self.assertEqual((decision.why_not, decision.whole), (None, True))

    def test_a_reusable_workflow_job_is_followed_to_its_callee(self) -> None:
        runs, jobs = self.inventory(run(1), [job(B16, created=40, name="guards / lint (linux)")])
        caller = "name: CI\non: push\njobs:\n  guards:\n    uses: ./.github/workflows/g.yml\n"
        texts = {".github/workflows/ci.yml": caller,
                 ".github/workflows/g.yml": workflow(name="lint (${{ matrix.os }})")}
        dead = dead_labels.dead_labels(runs, jobs, now=NOW)
        decisions = dead_labels.plan(runs, jobs, dead, values=VALUES, repo="manaflow-ai/cmux",
                                     workflow_text=lambda r, path: texts.get(path))
        self.assertIsNone(decisions[0].why_not)

    def test_no_values_moves_nothing(self) -> None:
        runs, jobs = self.inventory(run(1), [job(B16, created=40)])
        self.assertIn("not passed", self.plan(runs, jobs, values=None)[0].why_not)

    def test_main_push_runs_go_too_since_the_re_run_keeps_them(self) -> None:
        runs, jobs = self.inventory(run(1, event="push", branch="main"), [job(B16, created=40)])
        self.assertIsNone(self.plan(runs, jobs)[0].why_not)

    def test_a_started_nightly_is_never_cancelled(self) -> None:
        nightly = run(1, event="push", path=".github/workflows/nightly.yml", name="Nightly macOS build",
                      branch="nightly-next")
        runs, jobs = self.inventory(nightly, [ran(B32, 20, status="completed", name="build nightly inputs"),
                                              job(B16, created=40, name="build-nightly-ghostty-cli-helper")])
        decision = self.plan(runs, jobs)[0]
        self.assertIn("nightly, DEV or promote run that has started", decision.why_not)
        self.assertEqual(self.reads, [])

    def test_an_unstarted_dev_daily_run_may_move(self) -> None:
        dev = run(1, event="workflow_dispatch", path=".github/workflows/cmux-next-dev-daily.yml",
                  name="cmux NEXT DEV daily", branch="main")
        runs, jobs = self.inventory(dev, [ran(B32, 20, status="completed", name="decide"),
                                          job(B16, created=40, name="lint")])
        self.assertIsNone(self.plan(runs, jobs)[0].why_not)

    def test_a_running_sibling_holds_the_run(self) -> None:
        runs, jobs = self.inventory(run(1), [job(B16, created=40), ran(STD, 30)])
        self.assertTrue(all(d.why_not for d in self.plan(runs, jobs)))

    def test_release_and_merge_queue_runs_are_left_alone(self) -> None:
        for stuck in (run(1, event="merge_group"), run(1, path=".github/workflows/release.yml", name="Release")):
            runs, jobs = self.inventory(stuck, [job(B16, created=40)])
            self.assertIsNotNone(self.plan(runs, jobs)[0].why_not)

    def test_a_run_is_moved_at_most_once(self) -> None:
        runs, jobs = self.inventory(run(1, attempt=2), [job(B16, created=40, attempt=2)])
        self.assertIn("attempt 2", self.plan(runs, jobs)[0].why_not)

    def test_runs_already_acted_on_and_the_cap(self) -> None:
        runs = [run(1, created=50), run(2, created=40), run(3, created=30), run(99, status="in_progress")]
        jobs = {1: [job(B16, created=45)], 2: [job(B16, created=35)], 3: [job(B16, created=25)], 99: [ran(B32, 1)]}
        decisions = self.plan(runs, jobs, exclude={1}, max_runs=1)
        self.assertEqual([(d.run["id"], d.why_not is None) for d in decisions], [(2, True), (3, False)])
        self.assertIn("cap", decisions[1].why_not)


class EvaluateTests(unittest.TestCase):
    def test_the_repository_shapes(self) -> None:
        context = dead_labels.run_context(run(1), "manaflow-ai/cmux")
        for expression, values, want in (
                (LINUX_RUNS_ON[3:-2], {"LINUX_RUNNER": ""}, B4),
                (LINUX_RUNS_ON[3:-2], {"LINUX_RUNNER": B32}, B32),
                ("!startsWith(vars.LINUX_RUNNER, 'blacksmith-') && vars.LINUX_RUNNER || vars.CI_CLOUD_OVERFLOW_SAVED "
                 "&& 'blacksmith-16vcpu-ubuntu-2404' || 'blacksmith-32vcpu-ubuntu-2404'",
                 {"LINUX_RUNNER": B4, "CI_CLOUD_OVERFLOW_SAVED": ""}, B32),
                ("vars.CI_PAID_MACOS_OVERFLOW == '1' && vars.MACOS_RUNNER_15 || 'blacksmith-6vcpu-macos-15'",
                 {"CI_PAID_MACOS_OVERFLOW": "1", "MACOS_RUNNER_15": STD}, STD),
                ("vars.UNKNOWN || 'x'", {}, dead_labels.UNKNOWN)):
            self.assertEqual(dead_labels.evaluate(expression, values, context), want, expression)


class FamilyTests(unittest.TestCase):
    def test_single_host_labels_are_no_member(self) -> None:
        self.assertEqual(dead_labels.family(["glaeda-runner-cmux7s-mac-mini-nightly-next"]), None)
        self.assertEqual(dead_labels.family([STD]), "macos")
        self.assertEqual(dead_labels.family(["glaeda-ios-sim"]), "macos")
        self.assertEqual(dead_labels.family(["blacksmith-6vcpu-macos-26"]), "macos")
        self.assertEqual(dead_labels.family([B16]), "linux")
        self.assertEqual(dead_labels.family(["macos-26"]), None)

    def test_a_dead_single_host_label_is_never_reported(self) -> None:
        pinned = "glaeda-runner-cmux9s-mac-mini-ios-internal"
        found = dead_labels.dead_labels([run(1), run(2)], {1: [job(pinned, created=40)], 2: [ran(STD, 1)]}, now=NOW)
        self.assertEqual(found, [])


class RateLimited(RuntimeError):
    """Named as queue_janitor's is: dead_labels tells a rate limit by its class name."""


class FakeGitHub:
    """Runs that are queued until force-cancelled, then complete (cancelled) after `settle_after` reads; a re-run
    moves the run to its next attempt."""

    def __init__(self, settle_after=1, rerun_error=None, cancel_error=None, cancel_limit_on=None, rerun_limit=False,
                 cancel_takes=True):
        self.calls: list[tuple[str, int]] = []
        self.state: dict[int, dict] = {}
        self.jobs_of: dict[int, list] = {}
        self.settle_after = settle_after
        self.rerun_error = rerun_error
        self.cancel_error = cancel_error
        self.cancel_limit_on = cancel_limit_on
        self.rerun_limit = rerun_limit
        self.cancel_takes = cancel_takes

    def add(self, r, jobs=None, **state):
        self.state[r["id"]] = {**r, "reads": 0, "cancelled": False, "conclusion": None, **state}
        self.jobs_of[r["id"]] = jobs if jobs is not None else [job(B16, created=40)]

    def run(self, run_id):
        st = self.state[run_id]
        if st["cancelled"] and st["status"] != "completed":
            st["reads"] += 1
            if st["reads"] >= self.settle_after:
                st.update(status="completed", conclusion="cancelled")
        return {k: v for k, v in st.items() if k not in ("reads", "cancelled")}

    def jobs(self, run_id):
        return self.jobs_of[run_id]

    def force_cancel(self, run_id):
        if self.cancel_limit_on == run_id:
            raise RateLimited("POST force-cancel failed (403: rate limit)")
        self.calls.append(("force-cancel", run_id))
        if self.cancel_takes:
            self.state[run_id]["cancelled"] = True
        if self.cancel_error:
            raise RuntimeError(self.cancel_error)  # GitHub may have taken it all the same

    def _rerun(self, run_id, kind):
        if self.rerun_limit:
            raise RateLimited("POST rerun failed (403: rate limit)")
        self.calls.append((kind, run_id))
        if self.rerun_error:
            raise RuntimeError(self.rerun_error)
        st = self.state[run_id]
        st.update(status="queued", conclusion=None, run_attempt=st.get("run_attempt", 1) + 1, cancelled=False)

    def rerun_failed(self, run_id):
        self._rerun(run_id, "rerun")

    def rerun(self, run_id):
        self._rerun(run_id, "rerun-all")


class Saved:
    def __init__(self):
        self.history: list[list[dict]] = []

    def __call__(self, entries):
        self.history.append([dict(e) for e in entries])

    @property
    def last(self):
        return self.history[-1] if self.history else []


def go(r, whole=False):
    return dead_labels.Redispatch(r, "lint", B16, None, whole)


def owed_ids(saved):
    return [e["run_id"] for e in saved.last]


class RedispatchTests(unittest.TestCase):
    def move(self, github, decisions, **kw):
        saved = kw.pop("save", Saved())
        clock = iter(range(0, 10**6, kw.pop("step", 1)))
        kw.setdefault("cap", 25)
        out = dead_labels.redispatch(github, decisions, dry_run=False, save=saved, now=lambda: next(clock),
                                     sleep=lambda _: None, **kw)
        return out, saved

    def next_sweep(self, github, saved):
        return dead_labels.resume(github, saved.last, now=100.0)

    def test_owed_before_the_cancel_and_cleared_only_once_the_rerun_is_seen(self) -> None:
        github = FakeGitHub(settle_after=2)
        github.add(run(1))
        (results, failures), saved = self.move(github, [go(run(1)), dead_labels.Redispatch(run(2), "lint", B16, "held")])
        self.assertEqual(github.calls, [("force-cancel", 1), ("rerun", 1)])
        self.assertEqual(failures, 0)
        self.assertEqual([e["run_id"] for e in saved.history[0]], [1])  # written before the cancel
        self.assertEqual(owed_ids(saved), [1])  # a re-run asked is not yet a confirmed outcome
        owed, results, _ = self.next_sweep(github, saved)
        self.assertEqual(owed, [])  # the next sweep sees attempt 2: cleared
        self.assertIn("later attempt", results[1])
        self.assertEqual(github.calls.count(("rerun", 1)), 1)  # never asked twice

    def test_a_nightly_build_that_started_since_the_inventory_is_never_cancelled(self) -> None:
        nightly = run(1, event="push", path=".github/workflows/nightly.yml", name="Nightly macOS build",
                      branch="nightly-next")
        github = FakeGitHub()
        github.add(nightly, [ran(B32, 1, name="build-nightly-app"), job(B16, created=40)])
        (results, _), saved = self.move(github, [go(nightly)])
        self.assertEqual(github.calls, [])
        self.assertIn("nightly, DEV or promote run that has started", results[1])
        self.assertEqual(saved.history, [])

    def test_recheck_keeps_runs_that_moved_or_got_served(self) -> None:
        for jobs, state, why in (([ran(B16, 0.5, name="lint")], {}, "running"),
                                 ([job(B16, created=40, runner="vm-1")], {}, "no longer queued"),
                                 (None, {"run_attempt": 2}, "attempt moved"),
                                 (None, {"status": "completed"}, "completed now")):
            github = FakeGitHub()
            github.add(run(1), jobs, **state)
            (results, _), _ = self.move(github, [go(run(1))])
            self.assertEqual(github.calls, [], why)
            self.assertIn(why, results[1])

    def test_an_ambiguous_cancel_error_keeps_the_obligation(self) -> None:
        # Review finding 1 (e9f7c53): a timeout or 5xx after GitHub took the cancel. The entry stays, and the next
        # sweep re-reads the run and re-runs it.
        github = FakeGitHub(cancel_error="POST force-cancel failed (502)")
        github.add(run(1))
        (results, _), saved = self.move(github, [go(run(1))])
        self.assertEqual(owed_ids(saved), [1])
        self.assertIn("kept owed", results[1])
        owed, _, _ = self.next_sweep(github, saved)
        self.assertEqual(github.calls[-1], ("rerun", 1))
        self.assertEqual(owed_ids(type("S", (), {"last": owed})()), [1])  # cleared only once attempt 2 is seen
        self.assertEqual(dead_labels.resume(github, owed, now=200.0)[0], [])

    def test_an_ambiguous_cancel_that_never_took_clears_when_the_run_finishes_on_its_own(self) -> None:
        github = FakeGitHub(cancel_error="POST force-cancel failed (502)", cancel_takes=False)
        github.add(run(1))
        (_, _), saved = self.move(github, [go(run(1))])
        self.assertEqual(owed_ids(saved), [1])
        self.assertEqual(self.next_sweep(github, saved)[0], [{**saved.last[0]}])  # still running: kept
        github.state[1].update(status="completed", conclusion="success")
        owed, results, _ = self.next_sweep(github, saved)
        self.assertEqual(owed, [])
        self.assertIn("on its own", results[1])
        self.assertNotIn(("rerun", 1), github.calls)

    def test_a_rate_limit_on_the_second_cancel_keeps_the_first_runs_rerun_owed(self) -> None:
        github = FakeGitHub(cancel_limit_on=2)
        github.add(run(1))
        github.add(run(2))
        saved = Saved()
        with self.assertRaises(RateLimited):
            self.move(github, [go(run(1)), go(run(2))], save=saved)
        self.assertEqual(github.calls, [("force-cancel", 1)])
        self.assertIn(1, owed_ids(saved))
        owed, results, _ = self.next_sweep(github, saved)
        self.assertIn(("rerun", 1), github.calls)

    def test_a_rate_limit_on_the_rerun_keeps_it_owed(self) -> None:
        github = FakeGitHub(rerun_limit=True)
        github.add(run(1))
        saved = Saved()
        with self.assertRaises(RateLimited):
            self.move(github, [go(run(1))], save=saved)
        self.assertEqual(owed_ids(saved), [1])
        with self.assertRaises(RateLimited):
            dead_labels.resume(github, saved.last, now=5.0)

    def test_a_failed_rerun_stays_owed_and_is_asked_again(self) -> None:
        github = FakeGitHub(rerun_error="(422)")
        github.add(run(1))
        (results, failures), saved = self.move(github, [go(run(1))])
        self.assertEqual(failures, 1)
        self.assertIn("asks again", results[1])
        self.assertEqual(owed_ids(saved), [1])
        github.rerun_error = None
        owed, _, _ = self.next_sweep(github, saved)
        self.assertEqual(github.calls.count(("rerun", 1)), 2)  # the failed ask, then one more
        self.assertEqual(dead_labels.resume(github, owed, now=200.0)[0], [])

    def test_the_cap_refuses_new_cancels_and_never_evicts(self) -> None:
        # Review finding 2 (e9f7c53): obligations were cut to make room. Now a full cap stops new cancels.
        github = FakeGitHub()
        github.add(run(9))
        owed = [{"run_id": n, "attempt": 1, "whole": False, "at": 0} for n in range(100, 125)]
        (results, _), saved = self.move(github, [go(run(9))], owed=owed, cap=25)
        self.assertEqual(github.calls, [])
        self.assertIn("cap of 25", results[9])
        self.assertEqual(saved.history, [])

    def test_resume_never_drops_an_unsettled_or_unreadable_entry(self) -> None:
        github = FakeGitHub(settle_after=10**9)
        github.add(run(2))
        github.state[2]["cancelled"] = True
        entry = {"run_id": 2, "attempt": 1, "whole": False, "at": 0}
        owed, results, failures = dead_labels.resume(github, [entry, {"run_id": "x"}],
                                                     now=dead_labels.OBLIGATION_ALARM_S + 1.0)
        self.assertEqual(owed, [entry, {"run_id": "x"}])
        self.assertEqual(failures, 2)
        self.assertIn("by hand", results[2])

    def test_without_a_snapshot_nothing_is_cancelled(self) -> None:
        github = FakeGitHub()
        github.add(run(1))
        results, _ = dead_labels.redispatch(github, [go(run(1))], dry_run=False, save=None, cap=25)
        self.assertEqual(github.calls, [])
        self.assertIn("no snapshot", results[1])

    def test_a_picker_routed_run_is_rerun_whole(self) -> None:
        github = FakeGitHub()
        github.add(run(1))
        self.move(github, [go(run(1), whole=True)])
        self.assertEqual(github.calls, [("force-cancel", 1), ("rerun-all", 1)])

    def test_dry_run_touches_nothing(self) -> None:
        github = FakeGitHub()
        results, _ = dead_labels.redispatch(github, [go(run(1))], dry_run=True, save=Saved(), cap=25)
        self.assertEqual(github.calls, [])
        self.assertIn("dry run", results[1])

    def test_a_cancel_that_never_settles_stays_owed_for_the_next_sweep(self) -> None:
        github = FakeGitHub(settle_after=10**9)
        github.add(run(1))
        (results, failures), saved = self.move(github, [go(run(1))], step=50)
        self.assertEqual(failures, 0)
        self.assertIn("next sweep", results[1])
        self.assertNotIn(("rerun", 1), github.calls)
        self.assertEqual(owed_ids(saved), [1])

    def test_someone_elses_rerun_clears_it_without_a_second(self) -> None:
        github = FakeGitHub(settle_after=10**9)
        github.add(run(1))
        (_, _), saved = self.move(github, [go(run(1))], step=50)
        github.state[1].update(run_attempt=2, status="queued")
        owed, results, _ = self.next_sweep(github, saved)
        self.assertEqual(owed, [])
        self.assertEqual([c for c in github.calls if c[0].startswith("rerun")], [])


class ReviewFourTests(unittest.TestCase):
    """Findings on 06815ce, each reproduced."""

    def test_an_owed_run_still_queued_is_never_cancelled_twice(self) -> None:
        # Finding 1: the force-cancel took but the run stays queued; the next sweep must not cancel it again.
        github = FakeGitHub(settle_after=10**9)
        github.add(run(1))
        owed = [{"run_id": 1, "attempt": 1, "whole": False, "at": 0}]
        saved = Saved()
        results, _ = dead_labels.redispatch(github, [go(run(1))], dry_run=False, save=saved, owed=owed, cap=25,
                                            now=lambda: 10.0, sleep=lambda _: None)
        self.assertEqual(github.calls, [])
        self.assertIn("never cancelled twice", results[1])
        self.assertEqual(saved.history, [])
        janitor = (ROOT / "scripts/ci/queue_janitor.py").read_text(encoding="utf-8")
        self.assertIn('exclude=acted | {entry.get("run_id") for entry in owed_reruns or ()}', janitor)

    def test_every_failed_listing_reaches_the_fail_closed_gate(self) -> None:
        # Finding 2: a failed delivery-run listing and the main inventory's unread runs count as partial.
        janitor = (ROOT / "scripts/ci/queue_janitor.py").read_text(encoding="utf-8")
        self.assertIn('partial_reads.append(f"the jobs of delivery run {run[\'id\']}")', janitor)
        self.assertIn('*(f"the jobs of run {run_id}" for run_id in sorted(unread))', janitor)
        runs, jobs = [run(1), run(2)], {1: [job(B16, created=40)], 2: [ran(B32, 1)]}
        with redirect_stdout(io.StringIO()):
            self.assertEqual(dead_labels.dead_labels_if_complete(runs, jobs, now=NOW,
                                                                 unread=["the jobs of delivery run 9"]), [])

    def test_a_completed_run_with_no_conclusion_stays_owed(self) -> None:
        # Finding 3: completed with a null conclusion is unread, not an outcome.
        github = FakeGitHub()
        github.add(run(1), status="completed", conclusion=None)
        owed, results, failures = dead_labels.resume(github, [{"run_id": 1, "attempt": 1, "whole": False, "at": 0}],
                                                     now=5.0)
        self.assertEqual([e["run_id"] for e in owed], [1])
        self.assertEqual(failures, 1)
        self.assertEqual(github.calls, [])


POOLS = {"linux": {"why": "x", "members": [B32, B16]}, "$comment": ["x"]}
POOLED_RUNS_ON = "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || fromJSON(vars.RUNNER_POOLS).linux }}"


class RunnerPoolsTests(unittest.TestCase):
    def test_retired_members_from_the_current_member_and_dead(self) -> None:
        live = json.dumps({"linux": B16, "_dead": {B32: "2026-10-28T22:30:00Z", B4: "x"}, "_updated": "t"})
        self.assertEqual(dead_labels.retired_members(live, POOLS), {B32: B16, B4: ""})
        self.assertEqual(dead_labels.retired_members("", POOLS), {})
        self.assertEqual(dead_labels.retired_members("{not json", POOLS), {})
        self.assertEqual(dead_labels.retired_members(json.dumps({"linux": B32}), None), {})

    def test_a_job_on_a_member_the_pool_left_moves_when_its_runs_on_reads_the_pool(self) -> None:
        live = json.dumps({"linux": B16, "_dead": {B32: "2026-10-28T22:30:00Z"}})
        runs = [run(1)]
        jobs = {1: [job(B32, created=10)]}  # no other start evidence at all: the pool's mark is the evidence
        retired = dead_labels.retired_members(live, POOLS)
        dead = dead_labels.dead_labels_if_complete(runs, jobs, now=NOW, retired=retired)
        self.assertEqual([(d.name(), d.live) for d in dead], [(B32, (B16,))])
        values = {"RUNNER_POOLS": live}
        pooled = dead_labels.plan(runs, jobs, dead, values=values, repo="manaflow-ai/cmux",
                                  workflow_text=lambda r, p: workflow(POOLED_RUNS_ON))
        self.assertEqual((pooled[0].why_not, pooled[0].note), (None, f"a re-run lands on `{B16}`"))
        literal = dead_labels.plan(runs, jobs, dead, values=values, repo="manaflow-ai/cmux",
                                   workflow_text=lambda r, p: workflow(B32))
        self.assertIn("literal", literal[0].why_not)

    def test_runner_pools_unset_or_off_schema_moves_nothing(self) -> None:
        runs, jobs = [run(1)], {1: [job(B32, created=10)]}
        self.assertEqual(dead_labels.dead_labels_if_complete(runs, jobs, now=NOW,
                                                             retired=dead_labels.retired_members(None, POOLS)), [])
        dead = [dead_labels.DeadLabel(frozenset({B32}), "linux", dt.timedelta(minutes=10), 1, (B16,))]
        for values in ({}, {"RUNNER_POOLS": "{}"}, {"RUNNER_POOLS": "nope"}):
            decision = dead_labels.plan(runs, jobs, dead, values=values, repo="manaflow-ai/cmux",
                                        workflow_text=lambda r, p: workflow(POOLED_RUNS_ON))[0]
            self.assertIsNotNone(decision.why_not, values)

    def test_the_janitor_passes_runner_pools(self) -> None:
        doc = yaml.safe_load((ROOT / ".github/workflows/ci-queue-janitor.yml").read_text(encoding="utf-8"))
        step = next(s for s in doc["jobs"]["sweep"]["steps"] if s.get("name") == "Cancel wasted macOS runs")
        self.assertEqual(step["env"]["RUNNER_POOLS"], "${{ vars.RUNNER_POOLS }}")


class FailClosedTests(unittest.TestCase):
    def test_a_partial_read_finds_no_dead_label(self) -> None:
        # Review finding 3 (e9f7c53): an unread run may hold the only recent start on a label.
        runs = [run(1), run(2)]
        jobs = {1: [job(B16, created=40)], 2: [ran(B32, 1)]}
        self.assertTrue(dead_labels.dead_labels_if_complete(runs, jobs, now=NOW))
        with redirect_stdout(io.StringIO()):
            self.assertEqual(dead_labels.dead_labels_if_complete(runs, jobs, now=NOW,
                                                                 unread=["the jobs of Linux-only run 7"]), [])

    def test_the_janitor_counts_failed_linux_only_and_evidence_listings_as_partial(self) -> None:
        janitor = (ROOT / "scripts/ci/queue_janitor.py").read_text(encoding="utf-8")
        self.assertIn("dead_labels.dead_labels_if_complete(", janitor)
        self.assertNotIn("dead_labels.dead_labels(runs", janitor)
        self.assertIn('partial_reads.append(f"the evidence runs of {workflow}")', janitor)
        self.assertIn("partial_reads += [f\"the jobs of Linux-only run {run_id}\"", janitor)

    def test_read_linux_only_jobs_names_its_failures(self) -> None:
        sys.path.insert(0, str(ROOT / "scripts/ci"))
        import queue_janitor

        class GH:
            def jobs(self, run_id):
                if run_id == 2:
                    raise RuntimeError("GET jobs failed (502)")
                return []
        runs = [{**run(1), "path": ".github/workflows/x.yml"}, {**run(2), "path": ".github/workflows/x.yml"}]
        with redirect_stderr(io.StringIO()):
            found, failed = queue_janitor.read_linux_only_jobs(GH(), runs, {}, frozenset({".github/workflows/x.yml"}),
                                                               NOW)
        self.assertEqual((sorted(found), failed), ([1], [2]))

    def test_obligations_share_the_janitors_one_cap_and_are_never_cut_on_read(self) -> None:
        janitor = (ROOT / "scripts/ci/queue_janitor.py").read_text(encoding="utf-8")
        self.assertIn("cap=LOST_PENDING_MAX", janitor)
        self.assertNotIn("OBLIGATIONS_MAX", janitor)
        self.assertIn("return kept if key != LOST_RERUNS_KEY else kept[-LOST_PENDING_MAX:]", janitor)


class LinuxOnlyReadTests(unittest.TestCase):
    def test_ineligible_runs_never_fill_the_cap_and_reads_rotate(self) -> None:
        # The review's case: 12 stuck attempt-2 runs ahead of an eligible attempt-1 run.
        runs = [run(i, attempt=2, created=60 - i) for i in range(1, 13)] + [run(100, created=30)]
        self.assertEqual([r["id"] for r in dead_labels.linux_only_candidates(runs, now=NOW)], [100])
        # More eligible runs than the cap: every one is read within a few sweeps.
        many = [run(i, created=200 - i) for i in range(1, 31)]
        seen = set()
        for sweep in range(3):
            moment = NOW + sweep * dead_labels.DEAD_AFTER
            picked = dead_labels.linux_only_candidates(many, now=moment)
            self.assertLessEqual(len(picked), dead_labels.LINUX_ONLY_READS)
            seen |= {r["id"] for r in picked}
        self.assertEqual(seen, {r["id"] for r in many})

    def test_young_and_protected_runs_are_not_read(self) -> None:
        runs = [run(1, created=1), run(2, event="merge_group"), run(3, path=".github/workflows/release.yml")]
        self.assertEqual(dead_labels.linux_only_candidates(runs, now=NOW), [])


class WiringTests(unittest.TestCase):
    def test_the_janitor_runs_the_pass_with_the_runs_on_values_block(self) -> None:
        janitor = (ROOT / "scripts/ci/queue_janitor.py").read_text(encoding="utf-8")
        self.assertIn("dead_labels.redispatch(", janitor)
        self.assertIn('snapshot["dead_labels"]', janitor)

        def env(path, step_name):
            doc = yaml.safe_load((ROOT / path).read_text(encoding="utf-8"))
            return next(s for job in doc["jobs"].values() for s in job["steps"] if s.get("name") == step_name)["env"]
        mine = env(".github/workflows/ci-queue-janitor.yml", "Cancel wasted macOS runs")
        theirs = env(".github/workflows/ci-repo-variables.yml", "Check no runs-on waits on one machine")
        # One list of what a runs-on reads: ci-repo-variables.yml's (tests/test_ci_runs_on_values.py keeps it whole).
        self.assertEqual(mine["CMUX_CI_RUNS_ON_VARIABLES"], theirs["CMUX_CI_RUNS_ON_VARIABLES"])


if __name__ == "__main__":
    unittest.main()
