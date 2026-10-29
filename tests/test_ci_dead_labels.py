#!/usr/bin/env python3
"""Tests for scripts/ci/dead_labels.py over fixture job JSON (no network)."""

from __future__ import annotations

import datetime as dt
import importlib.util
import io
import json
import sys
import unittest
import zipfile
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock
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
POOLED_RUNS_ON = "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || fromJSON(vars.RUNNER_POOLS).linux }}"
PICKED_RUNS_ON = "${{ needs.pick.outputs.runner || fromJSON(vars.RUNNER_POOLS).linux }}"


def workflow(runs_on=POOLED_RUNS_ON, name="lint", extra=""):
    return f"name: CI\non: push\njobs:\n  lint:\n    name: {name}\n    runs-on: \"{runs_on}\"\n    steps: []\n{extra}"


class FakePoolsModule:
    """runner_pools.py's interface (cmux#27129): load_pools, parse_value, value_problems, members, DEAD_KEY. Its
    validation mirrors the real one; RealRunnerPoolsTests runs the same cases through the real module when present."""
    DEAD_KEY = "_dead"

    def __init__(self, pools):
        self.pools = pools

    def load_pools(self):
        return {k: v for k, v in self.pools.items() if not k.startswith("$")}

    @staticmethod
    def members(spec):
        return list(dict.fromkeys(spec["members"]))

    def parse_value(self, raw, pools):
        try:
            value = json.loads(raw)
        except ValueError:
            return {}, ["not JSON"]
        if not isinstance(value, dict):
            return {}, ["not an object"]
        clean, dropped = {}, []
        for name, spec in pools.items():
            if name in value:
                if isinstance(value[name], str) and value[name] in self.members(spec):
                    clean[name] = value[name]
                else:
                    dropped.append(f"{name} not a member")
        marks = value.get("_dead", {})
        if isinstance(marks, dict):
            good = {k: v for k, v in marks.items() if isinstance(k, str) and isinstance(v, str) and "T" in v}
            if len(good) != len(marks):
                dropped.append("_dead entries")
            clean["_dead"] = good
        else:
            dropped.append("_dead not an object")
        return clean, dropped

    def value_problems(self, value, pools):
        return [f"no {name}" for name in pools if not isinstance(value.get(name), str)]


POOLS = {"linux": {"why": "x", "members": [B32, B16]}, "$comment": ["x"]}
MODULE = FakePoolsModule(POOLS)


def state(value):
    return dead_labels.pools_state(json.dumps(value), module=MODULE)[0]


LIVE = {"linux": B32, "_dead": {B16: "2026-10-28T22:30:00Z"}}
VALUES = {"LINUX_RUNNER": B32}


class PlanTests(unittest.TestCase):
    def plan(self, runs, jobs_by_run, *, text=None, values=VALUES, pools="live", **kw):
        dead = dead_labels.dead_labels(runs, jobs_by_run, now=NOW)
        reads = []

        def read(run, path):
            reads.append(path)
            return workflow() if text is None else text
        self.reads = reads
        return dead_labels.plan(runs, jobs_by_run, dead, values=values, repo="manaflow-ai/cmux", workflow_text=read,
                                pools=state(LIVE) if pools == "live" else pools, **kw)

    def inventory(self, stuck_run, stuck_jobs):
        return [stuck_run, run(99, status="in_progress")], {stuck_run["id"]: stuck_jobs, 99: [ran(B32, 1)]}

    def test_a_pooled_job_whose_pool_points_at_a_live_member_goes(self) -> None:
        runs, jobs = self.inventory(run(1), [job(B16, created=40)])
        decisions = self.plan(runs, jobs)
        self.assertEqual([(d.run["id"], d.label, d.why_not) for d in decisions], [(1, B16, None)])
        self.assertIn(B32, decisions[0].note)
        self.assertEqual(self.reads, [".github/workflows/ci.yml"])

    def test_only_a_runs_on_reading_runner_pools_moves(self) -> None:
        # Review finding 5 (31d9f9e): a job reading vars.LINUX_RUNNER (or a literal, an input, a matrix value, a
        # picker's output) is never moved, however the pool moved.
        runs, jobs = self.inventory(run(1), [job(B16, created=40)])
        for runs_on in (LINUX_RUNS_ON, B16, "${{ 'blacksmith-16vcpu-ubuntu-2404' }}", "${{ inputs.runner }}",
                        "${{ matrix.runner }}", "${{ vars.NOT_PASSED }}", "${{ needs.pick.outputs.runner }}"):
            decision = self.plan(runs, jobs, text=workflow(runs_on))[0]
            self.assertIsNotNone(decision.why_not, runs_on)

    def test_a_picker_that_falls_through_to_the_pool_moves(self) -> None:
        runs, jobs = self.inventory(run(1), [job(B16, created=40)])
        # The picker's output is unknown, so the branch taken cannot be shown: not moved.
        self.assertIsNotNone(self.plan(runs, jobs, text=workflow(PICKED_RUNS_ON))[0].why_not)

    def test_a_pool_still_on_the_dead_label_or_on_a_dead_member_is_left(self) -> None:
        runs, jobs = self.inventory(run(1), [job(B16, created=40)])
        self.assertIn("still points", self.plan(runs, jobs, pools=state({"linux": B16, "_dead": {}}))[0].why_not)
        both = state({"linux": B32, "_dead": {B16: "2026-10-28T22:30:00Z", B32: "2026-10-28T22:31:00Z"}})
        self.assertIn("dead too", self.plan(runs, jobs, pools=both)[0].why_not)

    def test_a_reusable_workflow_job_is_followed_to_its_callee(self) -> None:
        runs, jobs = self.inventory(run(1), [job(B16, created=40, name="guards / lint (linux)")])
        caller = "name: CI\non: push\njobs:\n  guards:\n    uses: ./.github/workflows/g.yml\n"
        texts = {".github/workflows/ci.yml": caller,
                 ".github/workflows/g.yml": workflow(name="lint (${{ matrix.os }})")}
        dead = dead_labels.dead_labels(runs, jobs, now=NOW)
        decisions = dead_labels.plan(runs, jobs, dead, values=VALUES, repo="manaflow-ai/cmux", pools=state(LIVE),
                                     workflow_text=lambda r, path: texts.get(path))
        self.assertIsNone(decisions[0].why_not)

    def test_no_values_or_no_pools_moves_nothing(self) -> None:
        runs, jobs = self.inventory(run(1), [job(B16, created=40)])
        self.assertIn("not passed", self.plan(runs, jobs, values=None)[0].why_not)
        self.assertIn("RUNNER_POOLS", self.plan(runs, jobs, pools=None)[0].why_not)

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


sys.path.insert(0, str(ROOT / "scripts/ci"))
import janitor_guard  # noqa: E402


class Store:
    """A janitor_guard.OwedStore and the save() the janitor gives redispatch(), recording each publish."""

    def __init__(self, dead=(), lost=(), cap=25, unknown=False):
        self.store = janitor_guard.OwedStore({janitor_guard.LOST_KEY: None if unknown else [dict(e) for e in lost],
                                              janitor_guard.DEAD_KEY: [dict(e) for e in dead]}, cap)
        self.history: list[list[dict]] = []

    def __call__(self, entries):
        self.store.set(janitor_guard.DEAD_KEY, entries)
        self.history.append([dict(e) for e in entries])

    @property
    def last(self):
        return self.store.entries(janitor_guard.DEAD_KEY)


def go(r):
    return dead_labels.Redispatch(r, "lint", B16, None)


def owed_ids(entries):
    return [e["run_id"] for e in entries]


class RedispatchTests(unittest.TestCase):
    def move(self, github, decisions, saved=None, **kw):
        saved = saved or Store()
        clock = iter(range(0, 10**6, kw.pop("step", 1)))
        out = dead_labels.redispatch(github, decisions, dry_run=False, store=saved.store, save=saved,
                                     now=lambda: next(clock), sleep=lambda _: None, **kw)
        return out, saved

    def next_sweep(self, github, saved):
        return dead_labels.resume(github, saved.last, now=100.0)

    def test_owed_before_the_cancel_and_cleared_only_once_the_rerun_is_seen(self) -> None:
        github = FakeGitHub(settle_after=2)
        github.add(run(1))
        (results, failures), saved = self.move(github, [go(run(1)), dead_labels.Redispatch(run(2), "lint", B16, "held")])
        self.assertEqual(github.calls, [("force-cancel", 1), ("rerun", 1)])
        self.assertEqual(failures, 0)
        self.assertEqual(owed_ids(saved.history[0]), [1])  # written before the cancel
        self.assertEqual(owed_ids(saved.last), [1])  # a re-run asked is not yet a confirmed outcome
        owed, results, _ = self.next_sweep(github, saved)
        self.assertEqual(owed, [])
        self.assertIn("later attempt", results[1])
        self.assertEqual(github.calls.count(("rerun", 1)), 1)

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
        for jobs, state_, why in (([ran(B16, 0.5, name="lint")], {}, "running"),
                                  ([job(B16, created=40, runner="vm-1")], {}, "no longer queued"),
                                  (None, {"run_attempt": 2}, "attempt moved"),
                                  (None, {"status": "completed"}, "completed now")):
            github = FakeGitHub()
            github.add(run(1), jobs, **state_)
            (results, _), _ = self.move(github, [go(run(1))])
            self.assertEqual(github.calls, [], why)
            self.assertIn(why, results[1])

    def test_an_ambiguous_cancel_error_keeps_the_obligation(self) -> None:
        github = FakeGitHub(cancel_error="POST force-cancel failed (502)")
        github.add(run(1))
        (results, _), saved = self.move(github, [go(run(1))])
        self.assertEqual(owed_ids(saved.last), [1])
        self.assertIn("kept owed", results[1])
        owed, _, _ = self.next_sweep(github, saved)
        self.assertEqual(github.calls[-1], ("rerun", 1))
        self.assertEqual(owed_ids(owed), [1])
        self.assertEqual(dead_labels.resume(github, owed, now=200.0)[0], [])

    def test_an_ambiguous_cancel_that_never_took_clears_when_the_run_finishes_on_its_own(self) -> None:
        github = FakeGitHub(cancel_error="POST force-cancel failed (502)", cancel_takes=False)
        github.add(run(1))
        _, saved = self.move(github, [go(run(1))])
        self.assertEqual(owed_ids(self.next_sweep(github, saved)[0]), [1])  # still running: kept
        github.state[1].update(status="completed", conclusion="success")
        owed, results, _ = self.next_sweep(github, saved)
        self.assertEqual(owed, [])
        self.assertIn("on its own", results[1])
        self.assertNotIn(("rerun", 1), github.calls)

    def test_a_rate_limit_on_the_second_cancel_keeps_the_first_runs_rerun_owed(self) -> None:
        github = FakeGitHub(cancel_limit_on=2)
        github.add(run(1))
        github.add(run(2))
        saved = Store()
        with self.assertRaises(RateLimited):
            self.move(github, [go(run(1)), go(run(2))], saved)
        # Run 1 is cancelled and read (and so re-run) before run 2 is touched; run 2's cancel hits the rate limit.
        self.assertEqual(github.calls, [("force-cancel", 1), ("rerun", 1)])
        self.assertIn(1, owed_ids(saved.last))  # kept until a later attempt is read
        # Run 1: cleared once attempt 2 is read. Run 2: its cancel may or may not have reached GitHub, so it stays
        # owed until its outcome is read (it is still queued here).
        self.assertEqual(owed_ids(self.next_sweep(github, saved)[0]), [2])

    def test_a_rate_limit_on_the_rerun_keeps_it_owed(self) -> None:
        github = FakeGitHub(rerun_limit=True)
        github.add(run(1))
        saved = Store()
        with self.assertRaises(RateLimited):
            self.move(github, [go(run(1))], saved)
        self.assertEqual(owed_ids(saved.last), [1])
        with self.assertRaises(RateLimited):
            dead_labels.resume(github, saved.last, now=5.0)

    def test_a_failed_rerun_stays_owed_and_is_asked_again(self) -> None:
        github = FakeGitHub(rerun_error="(422)")
        github.add(run(1))
        (results, failures), saved = self.move(github, [go(run(1))])
        self.assertEqual(failures, 1)
        self.assertIn("asks again", results[1])
        self.assertEqual(owed_ids(saved.last), [1])
        github.rerun_error = None
        owed, _, _ = self.next_sweep(github, saved)
        self.assertEqual(github.calls.count(("rerun", 1)), 2)  # the failed ask, then one more
        self.assertEqual(dead_labels.resume(github, owed, now=200.0)[0], [])

    def test_one_cap_across_every_list_refuses_and_never_evicts(self) -> None:
        # Review finding 2 (31d9f9e): category e's carried re-runs count toward the same cap.
        github = FakeGitHub()
        github.add(run(9))
        lost = [{"run_id": n, "attempt": 1, "cancelled_at": "x"} for n in range(100, 115)]
        dead = [{"run_id": n, "attempt": 1, "at": 0} for n in range(200, 210)]
        saved = Store(dead=dead, lost=lost, cap=25)
        (results, _), _ = self.move(github, [go(run(9))], saved)
        self.assertEqual(github.calls, [])
        self.assertIn("full (25 of 25)", results[9])
        self.assertEqual(saved.history, [])

    def test_a_run_any_list_owes_is_never_cancelled_again(self) -> None:
        # Review finding 1 (31d9f9e) and the one before it: owed by either list, never cancelled twice.
        for lost, dead in (([{"run_id": 1, "attempt": 1}], []), ([], [{"run_id": 1, "attempt": 1, "at": 0}])):
            github = FakeGitHub(settle_after=10**9)
            github.add(run(1))
            (results, _), _ = self.move(github, [go(run(1))], Store(dead=dead, lost=lost))
            self.assertEqual(github.calls, [])
            self.assertIn("never cancelled twice", results[1])

    def test_an_unknown_list_or_a_failed_listing_moves_nothing(self) -> None:
        github = FakeGitHub()
        github.add(run(1))
        (results, _), _ = self.move(github, [go(run(1))], Store(unknown=True))
        self.assertIn("unread", results[1])
        (results, _), _ = self.move(github, [go(run(1))], hold=lambda: "1 listing(s) failed")
        self.assertIn("listing(s) failed", results[1])
        self.assertEqual(github.calls, [])

    def test_resume_never_drops_an_unsettled_or_unreadable_entry(self) -> None:
        github = FakeGitHub(settle_after=10**9)
        github.add(run(2))
        github.state[2]["cancelled"] = True
        entry = {"run_id": 2, "attempt": 1, "at": 0}
        owed, results, failures = dead_labels.resume(github, [entry, {"run_id": "x"}],
                                                     now=dead_labels.OBLIGATION_ALARM_S + 1.0)
        self.assertEqual(owed, [entry, {"run_id": "x"}])
        self.assertEqual(failures, 2)
        self.assertIn("by hand", results[2])

    def test_a_completed_run_with_no_conclusion_stays_owed(self) -> None:
        github = FakeGitHub()
        github.add(run(1), status="completed", conclusion=None)
        owed, _, failures = dead_labels.resume(github, [{"run_id": 1, "attempt": 1, "at": 0}], now=5.0)
        self.assertEqual((owed_ids(owed), failures, github.calls), ([1], 1, []))

    def test_without_a_snapshot_nothing_is_cancelled(self) -> None:
        github = FakeGitHub()
        github.add(run(1))
        results, _ = dead_labels.redispatch(github, [go(run(1))], dry_run=False, store=Store().store, save=None)
        self.assertEqual(github.calls, [])
        self.assertIn("no snapshot", results[1])

    def test_dry_run_touches_nothing(self) -> None:
        github = FakeGitHub()
        results, _ = dead_labels.redispatch(github, [go(run(1))], dry_run=True, store=Store().store, save=Store())
        self.assertEqual(github.calls, [])
        self.assertIn("dry run", results[1])

    def test_a_cancel_that_never_settles_stays_owed_for_the_next_sweep(self) -> None:
        github = FakeGitHub(settle_after=10**9)
        github.add(run(1))
        (results, failures), saved = self.move(github, [go(run(1))], step=50)
        self.assertEqual(failures, 0)
        self.assertIn("next sweep", results[1])
        self.assertNotIn(("rerun", 1), github.calls)
        self.assertEqual(owed_ids(saved.last), [1])

    def test_someone_elses_rerun_clears_it_without_a_second(self) -> None:
        github = FakeGitHub(settle_after=10**9)
        github.add(run(1))
        _, saved = self.move(github, [go(run(1))], step=50)
        github.state[1].update(run_attempt=2, status="queued")
        owed, _, _ = self.next_sweep(github, saved)
        self.assertEqual(owed, [])
        self.assertEqual([c for c in github.calls if c[0].startswith("rerun")], [])


class GuardTests(unittest.TestCase):
    """janitor_guard.py: the one store and the one read log."""

    def test_the_store_is_carried_whole_and_an_unread_list_is_never_written_empty(self) -> None:
        # Review finding 3 (31d9f9e): a failed read must not publish a copy that loses the list.
        store = janitor_guard.OwedStore({janitor_guard.LOST_KEY: None, janitor_guard.DEAD_KEY: [{"run_id": 7}]})
        snapshot = {}
        store.stamp(snapshot)
        self.assertEqual(snapshot[janitor_guard.DEAD_KEY], [{"run_id": 7}])
        self.assertNotIn(janitor_guard.LOST_KEY, snapshot)
        self.assertTrue(snapshot[janitor_guard.LOST_KEY + janitor_guard.UNREAD_SUFFIX])
        self.assertEqual(store.room(), 0)  # unknown: nothing new is owed

    def test_reading_passes_over_unread_and_missing_copies_however_many(self) -> None:
        key = janitor_guard.DEAD_KEY
        older = {key: [{"run_id": 1}]}
        docs = [{key + "_unread": True}] * 5 + [{}] * 4 + [older]
        self.assertEqual(janitor_guard.entries_in(docs, key), [{"run_id": 1}])
        self.assertIsNone(janitor_guard.entries_in([{key + "_unread": True}], key))
        self.assertEqual(janitor_guard.entries_in([{}, {}], key), [])

    def test_read_store_downloads_only_as_far_as_needed(self) -> None:
        def archive(doc):
            buffer = io.BytesIO()
            with zipfile.ZipFile(buffer, "w") as handle:
                handle.writestr("macos-pool-load.json", json.dumps(doc))
            return buffer.getvalue()
        docs = [{janitor_guard.LOST_KEY: [], janitor_guard.DEAD_KEY + "_unread": True},
                {janitor_guard.DEAD_KEY: [{"run_id": 3}]}, {janitor_guard.DEAD_KEY: [{"run_id": 4}]}]
        fetched = []
        store = janitor_guard.read_store([{"i": i} for i in range(3)],
                                         lambda a: fetched.append(a["i"]) or archive(docs[a["i"]]),
                                         "macos-pool-load.json")
        self.assertEqual(store.lists[janitor_guard.DEAD_KEY], [{"run_id": 3}])
        self.assertEqual(fetched, [0, 1])

    def test_a_malformed_entry_is_kept_and_named_in_the_snapshot(self) -> None:
        # cmux#27114 review (60ef2b4): never dropped, surfaced for a person.
        store = janitor_guard.OwedStore({janitor_guard.LOST_KEY: [{"run_id": "x"}, {"run_id": 4}],
                                         janitor_guard.DEAD_KEY: []})
        snapshot = {}
        store.stamp(snapshot)
        self.assertEqual(snapshot[janitor_guard.LOST_KEY], [{"run_id": "x"}, {"run_id": 4}])
        self.assertEqual(snapshot[janitor_guard.MALFORMED_KEY], [{"run_id": "x"}])
        self.assertEqual(store.count(), 2)  # it still takes room under the cap

    def test_the_read_log_holds_after_any_failure(self) -> None:
        log = janitor_guard.ReadLog()
        self.assertIsNone(log.hold())
        with redirect_stderr(io.StringIO()):
            log.failed("head of main", "502")
        self.assertIn("head of main", log.hold())
        log.reset()
        self.assertIsNone(log.hold())


class RunnerPoolsTests(unittest.TestCase):
    def test_retired_members_from_the_current_member_and_dead(self) -> None:
        pools = state({"linux": B16, "_dead": {B32: "2026-10-28T22:30:00Z"}})
        self.assertEqual(pools.retired(), {B32: B16})
        self.assertEqual(state({"linux": B32, "_dead": {}}).retired(), {B16: B32})

    def test_an_undeclared_member_or_a_malformed_dead_is_no_state(self) -> None:
        # Review finding 6 (31d9f9e): {"linux": B4, "_dead": ["malformed"]} must move nothing.
        for value in ({"linux": B4, "_dead": {}}, {"linux": B32, "_dead": ["malformed"]},
                      {"linux": B32, "_dead": {B16: "not a time"}}, {"_dead": {}}, ["linux"]):
            found, why = dead_labels.pools_state(json.dumps(value), module=MODULE)
            self.assertIsNone(found, value)
            self.assertIn("validation", why)
        self.assertEqual(dead_labels.pools_state("", module=MODULE), (None, "RUNNER_POOLS is unset"))
        self.assertIsNone(dead_labels.pools_state("{not json", module=MODULE)[0])

    def test_without_runner_pools_py_there_is_no_state(self) -> None:
        with mock.patch.dict(sys.modules, {"runner_pools": None}):
            found, why = dead_labels.pools_state(json.dumps(LIVE))
        self.assertIsNone(found)
        self.assertIn("not on this tree", why)

    def test_a_job_on_a_member_the_pool_left_moves_when_its_runs_on_reads_the_pool(self) -> None:
        pools = state({"linux": B16, "_dead": {B32: "2026-10-28T22:30:00Z"}})
        runs = [run(1)]
        jobs = {1: [job(B32, created=10)]}  # no other start evidence: the pool's move is the evidence
        dead = dead_labels.dead_labels_if_complete(runs, jobs, now=NOW, retired=pools.retired())
        self.assertEqual([(d.name(), d.live) for d in dead], [(B32, (B16,))])
        pooled = dead_labels.plan(runs, jobs, dead, values=VALUES, repo="manaflow-ai/cmux", pools=pools,
                                  workflow_text=lambda r, p: workflow(POOLED_RUNS_ON))
        self.assertIsNone(pooled[0].why_not)
        for runs_on in (B32, LINUX_RUNS_ON):
            other = dead_labels.plan(runs, jobs, dead, values={"LINUX_RUNNER": B16}, repo="manaflow-ai/cmux",
                                     pools=pools, workflow_text=lambda r, p, ro=runs_on: workflow(ro))
            self.assertIsNotNone(other[0].why_not, runs_on)

    def test_the_janitor_passes_runner_pools(self) -> None:
        doc = yaml.safe_load((ROOT / ".github/workflows/ci-queue-janitor.yml").read_text(encoding="utf-8"))
        step = next(s for s in doc["jobs"]["sweep"]["steps"] if s.get("name") == "Cancel wasted macOS runs")
        self.assertEqual(step["env"]["RUNNER_POOLS"], "${{ vars.RUNNER_POOLS }}")


class RealRunnerPoolsTests(unittest.TestCase):
    """The same validation cases through cmux#27129's runner_pools.py, once it is on the tree."""

    def setUp(self) -> None:
        try:
            import runner_pools  # noqa: PLC0415
        except ImportError:
            self.skipTest("scripts/ci/runner_pools.py is not on this tree yet (cmux#27129)")
        self.module = runner_pools

    def test_the_real_validator_refuses_the_review_case(self) -> None:
        pools = self.module.load_pools()
        member = self.module.members(pools["linux"])[0]
        bad = {**{name: self.module.members(spec)[0] for name, spec in pools.items()}, "linux": B4, "_dead": ["x"]}
        self.assertIsNone(dead_labels.pools_state(json.dumps(bad), module=self.module)[0])
        good = {**{name: self.module.members(spec)[0] for name, spec in pools.items()}, "_dead": {}}
        found, why = dead_labels.pools_state(json.dumps(good), module=self.module)
        self.assertIsNotNone(found, why)
        self.assertEqual(found.current["linux"], member)


class FailClosedTests(unittest.TestCase):
    def test_a_partial_read_finds_no_dead_label(self) -> None:
        runs = [run(1), run(2)]
        jobs = {1: [job(B16, created=40)], 2: [ran(B32, 1)]}
        self.assertTrue(dead_labels.dead_labels_if_complete(runs, jobs, now=NOW))
        with redirect_stdout(io.StringIO()):
            self.assertEqual(dead_labels.dead_labels_if_complete(runs, jobs, now=NOW,
                                                                 unread=["the jobs of Linux-only run 7"]), [])

    def test_read_linux_only_jobs_notes_its_failures_in_the_read_log(self) -> None:
        import queue_janitor

        class GH:
            def jobs(self, run_id):
                if run_id == 2:
                    raise RuntimeError("GET jobs failed (502)")
                return []
        runs = [{**run(1), "path": ".github/workflows/x.yml"}, {**run(2), "path": ".github/workflows/x.yml"}]
        queue_janitor.READS.reset()
        with redirect_stderr(io.StringIO()):
            found, failed = queue_janitor.read_linux_only_jobs(GH(), runs, {}, frozenset({".github/workflows/x.yml"}),
                                                               NOW)
        self.assertEqual((sorted(found), failed), ([1], [2]))
        self.assertIn("Linux-only run 2", queue_janitor.READS.hold())
        queue_janitor.READS.reset()


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
