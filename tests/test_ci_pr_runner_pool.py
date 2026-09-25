#!/usr/bin/env python3
"""Tests for scripts/ci/pr_runner_pool.py and its wiring (no network)."""

from __future__ import annotations

import dataclasses
import datetime as dt
import importlib.util
import io
import json
import re
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


pool = load("pr_runner_pool", ROOT / "scripts/ci/pr_runner_pool.py")
janitor = load("queue_janitor", ROOT / "scripts/ci/queue_janitor.py")
e2e_pool = load("e2e_runner_pool", ROOT / "scripts/ci/e2e_runner_pool.py")
ios_pool = load("ios_runner_pool", ROOT / "scripts/ci/ios_runner_pool.py")

NOW = dt.datetime(2026, 9, 24, 10, 30, tzinfo=dt.timezone.utc)
SMALL, LARGE, OLD = pool.DEFAULT_RUNNER, pool.LARGE_RUNNER, pool.MACOS_15_RUNNER
XCODE_15 = "/Applications/Xcode_26.3.app"
PINS = {"CMUX_CI_XCODE_APP_MACOS_15": XCODE_15}


FORK_SETTINGS = {"lane": SMALL, "overflow": "", "order": "", "max_queued": "", "queue_rounds": "0"}


def backlog(small=21, large=0, old=4, large_reserved=0, old_reserved=0, age=5, settings=None) -> dict:
    return {
        "version": 1,
        "settings": dict(FORK_SETTINGS if settings is None else settings),
        "generated_at": (NOW - dt.timedelta(minutes=age)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "pools": {
            SMALL: {"queued": small, "running": 10},
            LARGE: {"queued": large, "running": 1, "reserved_queued": large_reserved},
            OLD: {"queued": old, "running": 10, "reserved_queued": old_reserved},
        },
    }


def choose(snap, *, event="pull_request", head="manaflow-ai/cmux", default=SMALL,
           overflow="", order="", max_queued="", pins=PINS, fetch=None, routed=0, attempt=1, owned="",
           owned_slots="", jobs=pool.MAX_RUN_JOBS, split="", live_owned=None, root_jobs=0, shards=0, light_retry="",
           actor="", queue_rounds=None):
    def count_routed(since):
        if isinstance(routed, Exception):
            raise routed
        return routed(since) if callable(routed) else routed
    return pool.choose(
        event=event, repo="manaflow-ai/cmux", head_repo=head, default_runner=default,
        overflow=overflow, order=order, max_queued=max_queued, xcode_pins=pins, owned=owned,
        owned_slots=owned_slots, jobs=jobs, split=split, live_owned=live_owned, root_jobs=root_jobs,
        shards=shards, light_retry=light_retry, triggering_actor=actor, queue_rounds=queue_rounds,
        fetch=fetch or (lambda: snap), count_routed=count_routed, now=NOW, run_attempt=attempt,
    )[0]


class PreferenceOrder(unittest.TestCase):
    def test_12vcpu_first_while_it_has_headroom(self):
        choice = choose(backlog(small=0, large=0))
        self.assertEqual((choice.runner, choice.xcode_app), (LARGE, ""))

    def test_6vcpu_26_when_12vcpu_is_backed_up(self):
        choice = choose(backlog(small=1, large=5))
        self.assertEqual((choice.runner, choice.xcode_app), (SMALL, ""))

    def test_macos_15_last_with_its_own_xcode(self):
        # Every pool full: under one round queued on 12vcpu beats a cold
        # compile on macOS 15, more than its extra round does not.
        self.assertEqual(choose(backlog(small=21, large=2, old=2)).runner, LARGE)
        choice = choose(backlog(small=21, large=6, old=2))
        self.assertEqual((choice.runner, choice.xcode_app), (OLD, XCODE_15))

    def test_a_full_pool_rolls_over(self):
        # 2026-09-24 23:16Z: 12vcpu ran 3 with 18 queued, 6vcpu 26 ran 10 with
        # 3 queued, macOS 15 ran 1 of 10. A free machine anywhere in the order
        # beats a queue, the cold pool's included.
        snap = backlog(small=3, large=18, old=0)
        snap["pools"][LARGE]["running"] = 3
        snap["pools"][OLD]["running"] = 1
        choice = choose(snap)
        self.assertEqual((choice.runner, choice.xcode_app), (OLD, XCODE_15))
        self.assertIn("free machine", choice.reason)
        # 12vcpu is full at 5 running, not 10.
        snap = backlog(small=0, large=0)
        snap["pools"][SMALL]["running"] = 9
        snap["pools"][LARGE]["running"] = 4
        self.assertEqual(choose(snap).runner, LARGE)
        snap["pools"][LARGE]["running"] = 5
        self.assertEqual(choose(snap).runner, SMALL)
        self.assertEqual(pool.pool(snap, LARGE)["capacity"], 5)
        self.assertTrue(pool.cold(OLD))
        self.assertFalse(pool.cold(LARGE) or pool.cold(SMALL) or pool.cold("glaeda-std-xcode-26.6"))

    def test_shortest_queue_in_rounds_when_every_pool_is_full(self):
        # Queued jobs over capacity; the macOS 15 pool has no seed, so it
        # counts COLD_ROUNDS more.
        self.assertEqual(choose(backlog(small=21, large=2, old=4)).runner, LARGE)
        self.assertIn("counting 1 more", choose(backlog(small=21, large=2, old=4)).reason)
        self.assertEqual(choose(backlog(small=21, large=8, old=4)).runner, OLD)
        self.assertIn("counting 1 more", choose(backlog(small=21, large=8, old=4)).reason)
        self.assertEqual(choose(backlog(small=5, large=6, old=9)).runner, SMALL)
        self.assertNotIn("counting", choose(backlog(small=5, large=6, old=9)).reason)
        self.assertIn("every pool is full", choose(backlog(small=5, large=6, old=9)).reason)
        self.assertEqual(choose(backlog(small=0, large=0), order=OLD).reason.split(" (")[0],
                         "the only pool this run may take")
        # A tie goes to the earlier pool in the order: 10 of 10 against 5 of 5.
        self.assertEqual(choose(backlog(small=9, large=4, old=20)).runner, LARGE)

    def test_a_queued_release_or_nightly_job_reserves_its_pool(self):
        self.assertEqual(choose(backlog(small=0, large=0, large_reserved=1)).runner, SMALL)
        self.assertEqual(choose(backlog(small=9, large=0, old=0, large_reserved=1, old_reserved=1)).runner, SMALL)

    def test_order_and_threshold_come_from_variables(self):
        order = f"{SMALL},{OLD}"
        self.assertEqual(choose(backlog(small=2, old=0), order=order).runner, SMALL)
        # CI_PR_POOL_MAX_QUEUED lets a pool take a run with that many queued.
        self.assertEqual(choose(backlog(small=2, old=5), order=order, max_queued="3").runner, SMALL)
        self.assertEqual(choose(backlog(small=13, old=0), order=order, max_queued="2").runner, OLD)
        self.assertEqual(choose(backlog(small=0, large=0), order=OLD).runner, OLD)

    def test_runs_since_the_snapshot_spread_a_burst(self):
        # 12vcpu has 4 of its 5 machines free (1 running), 6vcpu 26 has 6
        # queued, macOS 15 is full with nothing queued: pushes after a sweep
        # take 12vcpu's free machines, then every pool is full and each run
        # takes the shortest queue in rounds; macOS 15 joins once the others
        # are about a round deeper than it.
        snap = backlog(small=6, large=0, old=0)
        snap["pools"][OLD]["running"] = pool.POOL_CAPACITIES[OLD]
        picks = "".join({LARGE: "L", SMALL: "S", OLD: "O"}[choose(snap, routed=n).runner] for n in range(30))
        self.assertEqual(picks, "LLLLLLLSLSSLSSOLSOSOLSOSOLSOSO")
        self.assertIn("replaying 4", choose(backlog(small=6), routed=4).reason)

    def test_idle_slots_absorb_recent_runs(self):
        # 12vcpu 0 queued and 3 running: one run since the sweep takes one of
        # its two free machines, and this run the other. After two, it is full.
        snap = backlog(small=2, large=0, old=1)
        snap["pools"][LARGE]["running"] = 3
        self.assertEqual(choose(snap, routed=1).runner, LARGE)
        self.assertIn("free machine", choose(snap, routed=1).reason)
        self.assertIn("every pool is full", choose(snap, routed=2).reason)
        self.assertEqual(pool.effective_queue({"queued": 0, "running": 2}, 8), 0)
        self.assertEqual(pool.effective_queue({"queued": 0, "running": 2}, 10), 2)
        self.assertEqual(pool.effective_queue({"queued": 1, "running": 3}, 2), 3)

    def test_only_runs_still_in_flight_are_replayed(self):
        runs = [{"id": 1, "status": "queued"}, {"id": 2, "status": "in_progress"},
                {"id": 3, "status": "completed"}, {"id": 4, "status": "pending"}, {"id": 5, "status": "waiting"}]
        self.assertEqual(pool.count_in_flight(runs, exclude_run_id=2), 3)

    def test_placed_runs_and_a_narrower_pick_for_e2e(self):
        # e2e_runner_pool.py reuses this rule: runs whose pool is known count
        # where they are, and the final pick may be limited to some pools
        # while the replay still spreads over the whole order.
        snap = backlog(small=0, large=0, old=0)
        snap["pools"][LARGE]["running"] = 0
        args = dict(now=NOW, xcode_pins=PINS)
        self.assertEqual(pool.decide(snap, pool.Settings(), placed={LARGE: 4}, **args).runner, LARGE)
        self.assertEqual(pool.decide(snap, pool.Settings(), placed={LARGE: 5}, **args).runner, SMALL)
        self.assertIn("replaying 5", pool.decide(snap, pool.Settings(), placed={LARGE: 5}, **args).reason)
        # A pool outside the order is ignored rather than trusted.
        self.assertEqual(pool.decide(snap, pool.Settings(), placed={"tart-small": 9}, **args).runner, LARGE)
        busy = backlog(small=13, large=14, old=0)
        self.assertEqual(pool.decide(busy, pool.Settings(), **args).runner, OLD)
        self.assertEqual(pool.decide(busy, pool.Settings(), choose_from=(LARGE, SMALL), **args).runner, SMALL)
        reserved = backlog(large_reserved=1)
        reserved["pools"][SMALL]["reserved_queued"] = 1
        self.assertEqual(pool.decide(reserved, pool.Settings(), choose_from=(LARGE, SMALL), **args).runner, "")

    def test_counting_errors_keep_the_default(self):
        choice = choose(backlog(), routed=RuntimeError("GET /actions/workflows/ci.yml/runs failed (500)"))
        self.assertEqual((choice.runner, choice.xcode_app), ("", ""))
        self.assertIn("500", choice.reason)

    def test_macos_15_needs_an_xcode_pin(self):
        choice = choose(backlog(small=21, large=5, old=0), pins={})
        self.assertEqual(choice.runner, LARGE)  # shortest queue in rounds among the usable pools
        self.assertIn("no Xcode pin", choice.reason)
        self.assertEqual(choose(backlog(), order=OLD, pins={}).runner, "")


class FailSafe(unittest.TestCase):
    def assert_default(self, choice):
        self.assertEqual((choice.runner, choice.xcode_app), ("", ""), choice.reason)

    def test_only_same_repository_pull_requests_move(self):
        self.assert_default(choose(backlog(), event="push"))
        self.assert_default(choose(backlog(), event="merge_group"))
        self.assert_default(choose(backlog(), event="workflow_dispatch"))
        self.assert_default(choose(backlog(), head=""))
        self.assert_default(choose(backlog(), head="someone/cmux", event="push"))

    def test_fork_heads_follow_the_settings_the_janitor_copied(self):
        # A fork run sees no repository variables: empty lane, no Xcode pins,
        # and whatever reached its env is ignored in favour of the snapshot.
        fork = dict(head="someone/cmux", default="", pins={}, overflow="0", order=OLD)
        self.assertEqual(choose(backlog(small=0, large=0), **fork).runner, LARGE)
        choice = choose(backlog(small=21, large=15, old=0), **fork)
        self.assertEqual((choice.runner, choice.xcode_app), (OLD, ""))
        self.assertIn("fork head", choice.reason)
        copied = dict(FORK_SETTINGS, order=f"{SMALL},{OLD}")
        self.assertEqual(choose(backlog(small=21, old=0, settings=copied), **fork).runner, OLD)
        # The kill switch and the lane reach fork runs through the snapshot.
        for off in (dict(FORK_SETTINGS, overflow="0"), dict(FORK_SETTINGS, lane=""),
                    dict(FORK_SETTINGS, lane=OLD), dict(FORK_SETTINGS, order="warp-macos-26-arm64-12x")):
            self.assert_default(choose(backlog(settings=off), **fork))
        no_settings = backlog()
        no_settings.pop("settings")
        self.assert_default(choose(no_settings, **fork))
        self.assert_default(choose(None, **fork))

    def test_fork_heads_only_use_ephemeral_pools(self):
        self.assertTrue(all(label.startswith(pool.EPHEMERAL_PREFIX) for label in pool.DEFAULT_ORDER))
        owned = "cmux-owned-mac-mini"
        original = dict(pool.POOLS)
        pool.POOLS[owned] = ""
        try:
            copied = dict(FORK_SETTINGS, order=f"{owned},{SMALL}")
            snap = backlog(small=0, settings=copied)
            self.assertEqual(choose(snap, head="someone/cmux", default="").runner, SMALL)
            self.assert_default(choose(backlog(settings=dict(FORK_SETTINGS, order=owned)),
                                       head="someone/cmux", default=""))
            # A same-repository run may use it.
            self.assertEqual(choose(snap, order=f"{owned},{SMALL}").runner, owned)
        finally:
            pool.POOLS.clear()
            pool.POOLS.update(original)

    def test_only_moves_off_the_6vcpu_macos_26_lane(self):
        self.assert_default(choose(backlog(), default=""))
        self.assert_default(choose(backlog(), default=OLD))

    def test_kill_switch_and_invalid_settings(self):
        self.assert_default(choose(backlog(), overflow="0"))
        for bad in ({"order": "warp-macos-26-arm64-12x"}, {"order": f"{LARGE},{LARGE}"},
                    {"max_queued": "-1"}, {"max_queued": "many"}):
            self.assert_default(choose(backlog(), **bad))

    def test_unknown_or_stale_snapshot(self):
        self.assert_default(choose(None))
        self.assert_default(choose({"pools": "nope"}))
        self.assert_default(choose(backlog(age=pool.MAX_SNAPSHOT_MINUTES + 1)))
        self.assert_default(choose(backlog(age=-30)))
        self.assert_default(choose({**backlog(), "generated_at": "yesterday"}))
        self.assert_default(choose({**backlog(), "pools": {LARGE: {"queued": "x"}}}))

    def test_fetch_errors_keep_the_default(self):
        def boom():
            raise RuntimeError("GET /actions/artifacts failed (403)")
        choice = choose(None, fetch=boom)
        self.assert_default(choice)
        self.assertIn("403", choice.reason)

    def test_main_writes_outputs_and_summary(self):
        with tempfile.TemporaryDirectory() as tmp:
            snap_path = Path(tmp, "snap.json")
            fresh = backlog(small=21, large=0)
            fresh["generated_at"] = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            snap_path.write_text(json.dumps(fresh))
            out, summary = Path(tmp, "out"), Path(tmp, "summary")
            env = {"EVENT_NAME": "pull_request", "GITHUB_REPOSITORY": "manaflow-ai/cmux",
                   "HEAD_REPO": "manaflow-ai/cmux", "DEFAULT_RUNNER": SMALL,
                   "CMUX_CI_XCODE_APP_MACOS_15": XCODE_15,
                   "GITHUB_OUTPUT": str(out), "GITHUB_STEP_SUMMARY": str(summary)}
            stdout = io.StringIO()
            old, sys.stdout = sys.stdout, stdout
            try:
                self.assertEqual(pool.main(["--snapshot", str(snap_path)], env), 0)
            finally:
                sys.stdout = old
            self.assertEqual(out.read_text(), f"runner={LARGE}\nxcode_app=\npersistent=false\n"
                                              f"retry_runner=\njobs={pool.MAX_RUN_JOBS}\nshard_runner=\n"
                                              f"refused_retry_runner=\nroot_runner=\nqueued=false\nadmission_runner=\nowned_jobs=\n")
            text = summary.read_text()
            self.assertIn(f"Pool: `{LARGE}`", text)
            self.assertIn(f"{SMALL}: 21 queued, 10 running", text)


class TrustedArtifact(unittest.TestCase):
    def artifact(self, **run):
        base = {"head_branch": "main", "repository_id": 1, "head_repository_id": 1}
        return {"expired": False, "workflow_run": {**base, **run}}

    def test_only_main_of_this_repository(self):
        self.assertEqual(pool.SNAPSHOT_BRANCH, "main")
        self.assertTrue(pool.trusted_snapshot_artifact(self.artifact(), "main"))
        self.assertFalse(pool.trusted_snapshot_artifact(self.artifact(head_branch="feature"), "main"))
        self.assertFalse(pool.trusted_snapshot_artifact(self.artifact(head_repository_id=2), "main"))
        self.assertFalse(pool.trusted_snapshot_artifact(self.artifact(repository_id=None, head_repository_id=None),
                                                        "main"))
        self.assertFalse(pool.trusted_snapshot_artifact({**self.artifact(), "expired": True}, "main"))
        self.assertFalse(pool.trusted_snapshot_artifact({"expired": False}, "main"))


    def test_newest_young_artifact_only(self):
        def at(minutes, **run):
            stamp = (NOW - dt.timedelta(minutes=minutes)).strftime("%Y-%m-%dT%H:%M:%SZ")
            return {**self.artifact(**run), "created_at": stamp}
        newest = pool.newest_snapshot_artifact([at(20), at(5), at(1, head_branch="x"), "junk"], now=NOW)
        self.assertEqual(newest["created_at"], at(5)["created_at"])
        self.assertIsNone(pool.newest_snapshot_artifact([at(pool.MAX_SNAPSHOT_MINUTES + 1)], now=NOW))
        self.assertIsNone(pool.newest_snapshot_artifact([], now=NOW))


class JanitorSnapshot(unittest.TestCase):
    def job(self, label, status, created="2026-09-24T09:00:00Z"):
        return {"labels": [label], "status": status, "created_at": created, "name": "x"}

    def test_counts_per_pool_and_reserved_demand(self):
        runs = [
            {"id": 1, "name": "CI", "path": ".github/workflows/ci.yml"},
            {"id": 2, "name": "Nightly", "path": ".github/workflows/nightly.yml"},
        ]
        jobs = {
            1: [self.job(SMALL, "queued", "2026-09-24T09:20:00Z"), self.job(SMALL, "queued"),
                self.job(SMALL, "in_progress"), self.job(OLD, "completed"),
                self.job("blacksmith-4vcpu-ubuntu-2404", "queued")],
            2: [self.job(LARGE, "queued"), self.job(LARGE, "in_progress"), self.job(OLD, "waiting")],
        }
        snap = janitor.pool_load_snapshot(runs, jobs, now=NOW, settings=FORK_SETTINGS)
        self.assertEqual(snap["settings"], FORK_SETTINGS)
        self.assertEqual(snap["generated_at"], "2026-09-24T10:30:00Z")
        self.assertEqual(snap["pools"][SMALL],
                         {"queued": 2, "running": 1, "reserved_queued": 0, "oldest_queued_minutes": 90})
        self.assertEqual(snap["pools"][LARGE]["reserved_queued"], 1)
        self.assertNotIn(OLD, snap["pools"])
        self.assertNotIn("blacksmith-4vcpu-ubuntu-2404", snap["pools"])
        # The picker reads what the janitor writes.
        # 12vcpu is reserved by the queued nightly job and 6vcpu 26 has jobs
        # queued, so the run rolls over to the idle macOS 15 pool.
        self.assertEqual(choose(snap).runner, OLD)

    def test_owned_jobs_are_macos_jobs_to_the_janitor(self):
        mini = {"labels": ["glaeda-std-xcode-26.6"], "status": "queued"}
        self.assertTrue(janitor.is_macos_job(mini))
        self.assertEqual(janitor.runner_pool(mini), "glaeda-std-xcode-26.6")
        self.assertFalse(janitor.is_macos_job({"labels": ["glaeda-mini"], "status": "queued"}))
        self.assertEqual(janitor.runner_pool({"labels": [SMALL]}), SMALL)

    def test_counts_jobs_on_an_owned_pool_label(self):
        runs = [{"id": 1, "name": "CI", "path": ".github/workflows/ci.yml"}]
        mini = "glaeda-std-xcode-26.6"
        jobs = {1: [self.job(mini, "in_progress"), self.job(mini, "in_progress"), self.job(mini, "queued"),
                    self.job("glaeda-mini", "queued"), self.job("blacksmith-4vcpu-ubuntu-2404", "queued")]}
        snap = janitor.pool_load_snapshot(runs, jobs, now=NOW)
        self.assertEqual((snap["pools"][mini]["running"], snap["pools"][mini]["queued"]), (2, 1))
        self.assertEqual(set(snap["pools"]), {mini})

    def test_owned_pool_commitments_count_jobs_not_created_yet(self):
        mini = "glaeda-std-xcode-26.6"
        runs = [{"id": 1, "status": "in_progress", "path": ".github/workflows/ci.yml"},
                {"id": 2, "status": "in_progress", "path": ".github/workflows/ci.yml"},
                {"id": 3, "status": "completed", "path": ".github/workflows/ci.yml"}]
        jobs = {1: [self.job(mini, "in_progress")],
                2: [self.job(mini, "in_progress"), self.job(mini, "queued")],
                3: []}
        # Run 1 declared 9 at its peak; run 2 has no marker; run 3 finished.
        markers = {1: (mini, 9), 3: (mini, 11)}
        snap = janitor.pool_load_snapshot(runs, jobs, now=NOW, markers=markers)
        self.assertEqual(snap["pools"][mini]["committed"], 9 + 2)
        self.assertEqual((snap["pools"][mini]["running"], snap["pools"][mini]["queued"]), (2, 1))
        # A marked run with no job created yet still reserves its peak.
        snap = janitor.pool_load_snapshot([runs[0]], {1: []}, now=NOW, markers={1: (mini, 4)})
        self.assertEqual(snap["pools"][mini], {"queued": 0, "running": 0, "reserved_queued": 0,
                                               "oldest_queued_minutes": 0, "committed": 4})
        self.assertEqual(owned_choice(snap, machines=6, order=f"{mini},{LARGE}").runner, LARGE)
        self.assertEqual(owned_choice(snap, machines=7, order=f"{mini},{LARGE}").runner, mini)
        # Shards exist only after admission: one finished owned job of a peak
        # of 4 still reserves the peak.
        early = [self.job(mini, "completed"), self.job(LARGE, "in_progress")]
        snap = janitor.pool_load_snapshot([runs[0]], {1: early}, now=NOW, markers={1: (mini, 4)})
        self.assertEqual(snap["pools"][mini]["committed"], 4)
        # Its owned jobs done, a run still busy on Blacksmith frees its minis.
        done = [*(self.job(mini, "completed") for _ in range(4)), self.job(LARGE, "in_progress")]
        snap = janitor.pool_load_snapshot([runs[0]], {1: done}, now=NOW, markers={1: (mini, 4)})
        self.assertEqual(snap["pools"].get(mini, {}).get("committed", 0), 0)
        # One owned job still running keeps the whole peak reserved.
        snap = janitor.pool_load_snapshot([runs[0]], {1: [*done, self.job(mini, "queued")]}, now=NOW,
                                          markers={1: (mini, 4)})
        self.assertEqual(snap["pools"][mini]["committed"], 4)

    def test_owned_marker_names_this_attempts_pool_and_peak(self):
        run = {"id": 42, "run_attempt": 1}
        name = "macos-pool-persistent-42-1-5-glaeda-std-xcode-26.6"
        self.assertEqual(janitor.owned_marker(run, ["other", name]), ("glaeda-std-xcode-26.6", 5))
        self.assertIsNone(janitor.owned_marker({"id": 42, "run_attempt": 2}, [name]))
        self.assertIsNone(janitor.owned_marker({"id": 4, "run_attempt": 1}, [name]))
        self.assertIsNone(janitor.owned_marker(run, ["macos-pool-persistent-42-1-5-blacksmith-6vcpu-macos-26"]))
        self.assertEqual(janitor.owned_marker(run, ["macos-pool-persistent-42-1-99-glaeda-std-xcode-26.6"]),
                         ("glaeda-std-xcode-26.6", pool.MAX_RUN_JOBS))

    def test_only_runs_that_may_hold_an_owned_pool_cost_a_listing(self):
        repo = {"id": 7}
        run = {"event": "pull_request", "run_attempt": 1, "path": ".github/workflows/ci.yml",
               "repository": repo, "head_repository": repo}
        self.assertTrue(janitor.may_hold_owned_pool(run, []))
        self.assertTrue(janitor.may_hold_owned_pool(run, [self.job("glaeda-std-xcode-26.6", "queued")]))
        # swift-package-tests sits on Blacksmith beside a full-suite run on an owned pool.
        self.assertTrue(janitor.may_hold_owned_pool(run, [self.job(OLD, "queued")]))
        # Attempt 2 only while CI_OWNED_LIGHT_RETRY is on (the light tier).
        self.assertFalse(janitor.may_hold_owned_pool({**run, "run_attempt": 2}, []))
        self.assertTrue(janitor.may_hold_owned_pool({**run, "run_attempt": 2}, [], light_retry=True))
        for change in ({"event": "push"}, {"run_attempt": 3}, {"head_repository": {"id": 8}},
                       {"path": ".github/workflows/nightly.yml"}):
            self.assertFalse(janitor.may_hold_owned_pool({**run, **change}, [], light_retry=True), change)

    def test_workflow_publishes_the_snapshot(self):
        workflow = yaml.safe_load((WORKFLOWS / "ci-queue-janitor.yml").read_text())
        steps = workflow["jobs"]["sweep"]["steps"]
        sweep = next(step for step in steps if "queue_janitor.py" in str(step.get("run")))
        self.assertIn("macos-pool-load.json", sweep["env"]["POOL_LOAD_OUT"])
        for name, key in janitor.POOL_SETTINGS_ENV.items():
            self.assertIn(key, FORK_SETTINGS)
        self.assertEqual(sweep["env"]["PR_POOL_LANE"], "${{ vars.MACOS_RUNNER_PR }}")
        self.assertEqual(sweep["env"]["PR_POOL_OVERFLOW"], "${{ vars.CI_PR_POOL_OVERFLOW }}")
        self.assertEqual(sweep["env"]["PR_POOL_ORDER"], "${{ vars.CI_PR_POOL_ORDER }}")
        self.assertEqual(sweep["env"]["PR_POOL_MAX_QUEUED"], "${{ vars.CI_PR_POOL_MAX_QUEUED }}")
        self.assertEqual(sweep["env"]["PR_POOL_OWNED"], "${{ vars.CI_PR_POOL_OWNED }}")
        self.assertNotIn("PR_POOL_OWNED", janitor.POOL_SETTINGS_ENV)
        upload = next(step for step in steps if "upload-artifact" in str(step.get("uses")))
        self.assertEqual(upload["with"]["name"], pool.ARTIFACT_NAME)
        self.assertTrue(upload["with"]["path"].endswith(pool.SNAPSHOT_FILE))


# The pull-request lane, wherever its event condition puts it: compile admission
# also takes it for main's full-suite dispatch (#14158), where the inputs are empty.
PR_ROUTE = re.compile(r"&& \((?P<lane>(?:[^()]|\((?:[^()]|\([^()]*\))*\))*vars\.MACOS_RUNNER_PR[^()]*)\)")


def retry_lane(key: str) -> str:
    """The pull-request lane of the job whose owned_jobs key is `key`."""
    return (f"github.run_attempt == 2 && github.triggering_actor == 'github-actions[bot]' && contains(inputs.pr_owned_jobs, {key}) && inputs.pr_refused_retry_runner "
            f"|| (github.run_attempt > 1 || !contains(inputs.pr_owned_jobs, {key})) && inputs.pr_retry_runner "
            "|| inputs.pr_runner || vars.MACOS_RUNNER_PR || 'blacksmith-6vcpu-macos-15'")


def root_lane(key: str) -> str:
    """retry_lane() for a root job: the root label, when the picker named one, before the pool label."""
    return (f"github.run_attempt == 2 && github.triggering_actor == 'github-actions[bot]' && contains(inputs.pr_owned_jobs, {key}) "
            "&& (inputs.pr_root_runner || inputs.pr_refused_retry_runner) "
            f"|| (github.run_attempt > 1 || !contains(inputs.pr_owned_jobs, {key})) && inputs.pr_retry_runner "
            "|| inputs.pr_root_runner || inputs.pr_runner || vars.MACOS_RUNNER_PR || 'blacksmith-6vcpu-macos-15'")


def warm_lane(index: str = "") -> str:
    """root_lane() for compile admission: attempt 1 may take the warm labels first.

    runs-on reads the JSON array itself; CMUX_PRODUCT_RUNNER (index "[0]")
    names its first label, the root label.
    """
    return root_lane("' admission '").replace(
        "&& inputs.pr_retry_runner || inputs.pr_root_runner",
        "&& inputs.pr_retry_runner || github.run_attempt == 1 && inputs.pr_admission_runner "
        f"&& fromJSON(inputs.pr_admission_runner){index} || inputs.pr_root_runner")


PR_XCODE = "/Applications/Xcode_26.6.app"
MINI = "glaeda-std-xcode-26.6"
LIGHT = "glaeda-light-xcode-26.6"
OWNED_PINS = {**PINS, "CMUX_CI_XCODE_APP_PR": PR_XCODE}


def fleet(busy=0, queued=0, age=2, **kwargs) -> dict:
    snap = backlog(age=age, **kwargs)
    snap["pools"][MINI] = {"queued": queued, "running": busy}
    return snap


def owned_choice(snap, *, owned="1", machines=11, **kwargs):
    kwargs.setdefault("owned_slots", json.dumps({MINI: machines}))
    # A compile-only run: admission beside the Claude wrapper and remote daemon lanes.
    kwargs.setdefault("jobs", 3)
    return choose(snap, pins=OWNED_PINS, owned=owned, **kwargs)


class ShardSpread(unittest.TestCase):
    """A full suite's shards may leave admission's pool for another on its Xcode."""

    def decide(self, snap, shards=pool.APP_HOST_SHARDS, **kwargs):
        return pool.decide(snap, pool.Settings(), now=NOW, xcode_pins=PINS, shards=shards, **kwargs)

    def test_shards_leave_a_small_12vcpu_pool_with_no_room_for_them(self):
        # 12vcpu idle takes admission; its 5 machines cannot hold 7 shards
        # beside it, while 6vcpu macOS 26 has 10 idle.
        snap = backlog(small=0, large=0, old=0)
        snap["pools"][SMALL]["running"] = 0
        snap["pools"][LARGE]["running"] = 0
        choice = self.decide(snap)
        self.assertEqual((choice.runner, choice.shard_runner), (LARGE, SMALL))
        self.assertIn("shards take", choice.reason)

    def test_shards_stay_when_admissions_pool_has_the_shorter_queue(self):
        snap = backlog(small=30, large=0, old=0)
        snap["pools"][LARGE]["running"] = 0
        self.assertEqual(self.decide(snap).shard_runner, "")

    def test_never_to_another_xcode_or_an_owned_pool_and_not_without_shards(self):
        snap = backlog(small=40, large=40, old=0)
        snap["pools"][OLD]["running"] = 0
        choice = self.decide(snap)
        self.assertEqual(choice.runner, OLD)
        self.assertEqual(choice.shard_runner, "")  # macOS 15 is on another Xcode
        idle = backlog(small=0, large=0, old=0)
        idle["pools"][SMALL]["running"] = 0
        self.assertEqual(self.decide(idle, shards=1).shard_runner, "")
        self.assertEqual(self.decide(idle, shards=0).shard_runner, "")
        self.assertEqual(self.decide(idle, choose_from=(LARGE,)).shard_runner, SMALL)
        mini = fleet(busy=0)
        owned = pool.decide(mini, pool.Settings(order=(MINI, LARGE, SMALL, OLD)), now=NOW, xcode_pins=OWNED_PINS,
                            owned_slots={MINI: 11}, jobs=3, shards=pool.APP_HOST_SHARDS)
        self.assertEqual((owned.runner, owned.shard_runner), (MINI, ""))

    def test_main_writes_the_shard_runner(self):
        with tempfile.TemporaryDirectory() as tmp:
            snap = backlog(small=0, large=0, old=0)
            snap["pools"][SMALL]["running"] = 0
            snap["pools"][LARGE]["running"] = 0
            snap["generated_at"] = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            path, out = Path(tmp, "snap.json"), Path(tmp, "out")
            path.write_text(json.dumps(snap))
            base = {"EVENT_NAME": "pull_request", "GITHUB_REPOSITORY": "manaflow-ai/cmux",
                    "HEAD_REPO": "manaflow-ai/cmux", "DEFAULT_RUNNER": SMALL, "GITHUB_OUTPUT": str(out),
                    "CMUX_CI_XCODE_APP_MACOS_15": XCODE_15, "RUN_MACOS": "true"}
            for full, expected in (("true", SMALL), ("false", "")):
                out.write_text("")
                with unittest.mock.patch("sys.stdout", io.StringIO()):
                    pool.main(["--snapshot", str(path)], {**base, "RUN_FULL_SUITE": full})
                values = dict(line.split("=", 1) for line in out.read_text().splitlines())
                self.assertEqual((values["runner"], values["shard_runner"]), (LARGE, expected), full)


class OwnedPools(unittest.TestCase):
    """Owned Macs first when switched on, Blacksmith as overflow, never a queue."""

    def test_idle_runners_are_the_live_owned_capacity(self):
        def runner(labels, status="online", busy=False):
            return {"status": status, "busy": busy, "labels": [{"name": name} for name in labels]}
        runners = [runner(["self-hosted", MINI]), runner([MINI], busy=True), runner([MINI], status="offline"),
                   runner([MINI, "glaeda-root-std-xcode-26.6"]), runner([LIGHT]), runner(["cmux15"])]
        self.assertEqual(pool.live_owned_free(runners, (MINI, LIGHT)), {MINI: 2, LIGHT: 1})

    def test_live_capacity_replaces_the_slot_count_and_snapshot_age(self):
        # The snapshot saw every mini busy and the slot variable gives none;
        # the runners say 3 are idle now.
        busy = fleet(busy=11)
        live = owned_choice(busy, owned_slots="", live_owned={MINI: 3, LIGHT: 0})
        self.assertEqual(live.runner, MINI)
        self.assertIn("read live from the runners API", live.reason)
        # None idle: Blacksmith, whatever the snapshot or the slot variable say.
        self.assertEqual(owned_choice(fleet(busy=0), live_owned={MINI: 0, LIGHT: 0}).runner, LARGE)
        # Too few idle for the run's owned peak.
        self.assertEqual(owned_choice(fleet(busy=0), live_owned={MINI: 2}, jobs=3).runner, LARGE)
        # A fork never uses it.
        fork = choose(fleet(busy=0), owned="1", jobs=3, live_owned={MINI: 9}, head="someone/cmux",
                      default="", pins={})
        self.assertFalse(fork.runner.startswith("glaeda-"))

    def test_live_capacity_charges_only_recent_runs_to_the_owned_pool(self):
        windows = []

        def routed(since):
            windows.append(since)
            # The snapshot window saw 5 unknown runs; the last 3 minutes saw 1
            # unknown run and one that took 2 minis.
            return pool.Routed(unknown=5) if len(windows) == 1 else pool.Routed(unknown=1, owned={MINI: 2})

        choice = owned_choice(fleet(busy=0), live_owned={MINI: 5}, jobs=1, routed=routed)
        # 5 idle - 2 taken - 1 replayed run * REPLAYED_RUN_JOBS(3) = 0 < 1: Blacksmith.
        self.assertEqual(choice.runner, LARGE)
        self.assertEqual(windows[1], (NOW - dt.timedelta(minutes=pool.LIVE_WINDOW_MINUTES)).strftime("%Y-%m-%dT%H:%M:%SZ"))
        windows.clear()
        self.assertEqual(owned_choice(fleet(busy=0), live_owned={MINI: 6}, jobs=1, routed=routed).runner, MINI)

    def test_main_reads_the_runners_only_with_the_route_token(self):
        fresh = fleet(busy=11)
        fresh["generated_at"] = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        idle = [{"status": "online", "busy": False, "labels": [{"name": MINI}]}] * 4
        for token, expected, listed in (("app-token", MINI, 1), ("", LARGE, 0)):
            with tempfile.TemporaryDirectory() as tmp, \
                    unittest.mock.patch.object(pool.GitHub, "snapshot", return_value=fresh), \
                    unittest.mock.patch.object(pool.GitHub, "pull_request_routes_since", return_value=pool.Routed()), \
                    unittest.mock.patch.object(pool.GitHub, "runners", return_value=idle) as runners, \
                    unittest.mock.patch("sys.stdout", io.StringIO()):
                out = Path(tmp, "out")
                env = {"EVENT_NAME": "pull_request", "GITHUB_REPOSITORY": "manaflow-ai/cmux", "GH_TOKEN": "t",
                       "HEAD_REPO": "manaflow-ai/cmux", "DEFAULT_RUNNER": SMALL, "POOL_OWNED": "1",
                       "OWNED_SLOTS": json.dumps({MINI: 11}), "ROUTE_TOKEN": token, "POOL_QUEUE_ROUNDS": "0",
                       "CMUX_CI_XCODE_APP_PR": PR_XCODE, "CMUX_CI_XCODE_APP_MACOS_15": XCODE_15,
                       "GITHUB_RUN_ATTEMPT": "1", "GITHUB_OUTPUT": str(out), "RUN_MACOS": "true"}
                pool.main([], env)
                values = dict(line.split("=", 1) for line in out.read_text().splitlines())
            self.assertEqual((values["runner"], runners.call_count), (expected, listed), token)
        # A failed listing falls back to the snapshot and never fails the step.
        with tempfile.TemporaryDirectory() as tmp, \
                unittest.mock.patch.object(pool.GitHub, "snapshot", return_value=fresh), \
                unittest.mock.patch.object(pool.GitHub, "pull_request_routes_since", return_value=pool.Routed()), \
                unittest.mock.patch.object(pool.GitHub, "runners", side_effect=RuntimeError("403")), \
                unittest.mock.patch("sys.stdout", io.StringIO()) as stdout:
            out = Path(tmp, "out")
            env.update(GITHUB_OUTPUT=str(out), ROUTE_TOKEN="app-token")
            self.assertEqual(pool.main([], env), 0)
            self.assertIn("using the snapshot", stdout.getvalue())

    def test_the_route_token_is_minted_for_same_repository_pull_requests_only(self):
        steps = yaml.safe_load((WORKFLOWS / "ci.yml").read_text())["jobs"]["changes"]["steps"]
        ids = [step.get("id") for step in steps]
        mint = steps[ids.index("route-token")]
        self.assertLess(ids.index("route-token"), ids.index("macos-pool"))
        self.assertIn("github.event.pull_request.head.repo.full_name == github.repository", mint["if"])
        self.assertIs(mint["continue-on-error"], True)
        self.assertTrue(mint["uses"].startswith("actions/create-github-app-token@"))
        self.assertEqual(mint["with"]["permission-administration"], "read")
        self.assertEqual(mint["with"]["private-key"], "${{ secrets.GLAEDA_ROUTE_APP_KEY }}")
        self.assertEqual(steps[ids.index("macos-pool")]["env"]["ROUTE_TOKEN"], "${{ steps.route-token.outputs.token }}")

    def test_attempt_2_may_take_the_light_tier_when_switched_on(self):
        # The rescue re-runs a run stuck on a full std pool in full; that
        # attempt picks again and, with CI_OWNED_LIGHT_RETRY, may take light.
        snap = fleet(busy=11)
        snap["pools"][LIGHT] = {"queued": 0, "running": 0}
        slots = json.dumps({MINI: 11, LIGHT: 3})
        bot = pool.RESCUE_ACTOR
        light = owned_choice(snap, owned_slots=slots, attempt=2, light_retry="1", actor=bot)
        self.assertEqual(light.runner, LIGHT)
        self.assertEqual(light.retry_runner, LARGE)
        self.assertIn("retry attempt 2", light.reason)
        # Off by default, never for attempt 3, and never std on a retry.
        self.assertEqual(owned_choice(snap, owned_slots=slots, attempt=2, actor=bot).runner, LARGE)
        self.assertEqual(owned_choice(snap, owned_slots=slots, attempt=3, light_retry="1", actor=bot).runner, LARGE)
        idle = fleet(busy=0)
        idle["pools"][LIGHT] = {"queued": 0, "running": 3}
        self.assertEqual(owned_choice(idle, owned_slots=slots, attempt=2, light_retry="1", actor=bot).runner, LARGE)
        # Light has to fit the whole owned peak, as on attempt 1.
        self.assertEqual(owned_choice(snap, owned_slots=slots, attempt=2, light_retry="1", jobs=4,
                                      actor=bot).runner, LARGE)
        # A retry takes no queue allowance (CI_PR_POOL_QUEUE_ROUNDS): it exists to get off a queue.
        self.assertEqual(owned_choice(snap, owned_slots=slots, attempt=2, light_retry="1", jobs=4,
                                      actor=bot, queue_rounds="").runner, LARGE)
        # A fork never reaches an owned pool.
        fork = choose(snap, owned="1", owned_slots=slots, jobs=3, attempt=2, light_retry="1", actor=bot,
                      head="someone/cmux", default="", pins={})
        self.assertFalse(fork.runner.startswith("glaeda-"))

    def test_the_light_retry_is_only_for_the_rescues_re_run(self):
        # ci.yml sends attempt 2's jobs to the refused-retry (light) label only
        # when github-actions[bot] started it. A person's re-run lands them on
        # Blacksmith, so the picker must not claim light (and its marker) then.
        snap = fleet(busy=11)
        snap["pools"][LIGHT] = {"queued": 0, "running": 0}
        slots = json.dumps({MINI: 11, LIGHT: 3})
        for actor in ("", "teamleaderleo", "github-actions"):
            choice = owned_choice(snap, owned_slots=slots, attempt=2, light_retry="1", actor=actor)
            self.assertEqual(choice.runner, LARGE, actor)
        self.assertIn("github.triggering_actor == 'github-actions[bot]'",
                      (WORKFLOWS / "ci.yml").read_text())
        # main() reads the actor Actions sets on every step.
        fresh = snap
        fresh["generated_at"] = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        for actor, expected in ((pool.RESCUE_ACTOR, LIGHT), ("teamleaderleo", LARGE)):
            with tempfile.TemporaryDirectory() as tmp, \
                    unittest.mock.patch.object(pool.GitHub, "snapshot", return_value=fresh), \
                    unittest.mock.patch.object(pool.GitHub, "pull_request_routes_since", return_value=pool.Routed()), \
                    unittest.mock.patch("sys.stdout", io.StringIO()):
                out = Path(tmp, "out")
                env = {"EVENT_NAME": "pull_request", "GITHUB_REPOSITORY": "manaflow-ai/cmux", "GH_TOKEN": "t",
                       "HEAD_REPO": "manaflow-ai/cmux", "DEFAULT_RUNNER": SMALL, "POOL_OWNED": "1",
                       "OWNED_SLOTS": slots, "OWNED_LIGHT_RETRY": "1", "GITHUB_TRIGGERING_ACTOR": actor,
                       "CMUX_CI_XCODE_APP_PR": PR_XCODE, "CMUX_CI_XCODE_APP_MACOS_15": XCODE_15,
                       "GITHUB_RUN_ATTEMPT": "2", "GITHUB_OUTPUT": str(out), "RUN_MACOS": "true"}
                pool.main([], env)
                values = dict(line.split("=", 1) for line in out.read_text().splitlines() if "=" in line)
            self.assertEqual(values["runner"], expected, actor)

    def test_the_light_retry_variable_reaches_the_picker(self):
        step = next(step for step in yaml.safe_load((WORKFLOWS / "ci.yml").read_text())["jobs"]["changes"]["steps"]
                    if step.get("id") == "macos-pool")
        self.assertEqual(step["env"]["OWNED_LIGHT_RETRY"], "${{ vars.CI_OWNED_LIGHT_RETRY }}")

    def test_label_follows_the_lane_xcode_pin(self):
        self.assertEqual(pool.owned_pools(PR_XCODE), (MINI, LIGHT))
        self.assertEqual(pool.owned_pools("/Applications/Xcode_27.0.1.app"),
                         ("glaeda-std-xcode-27.0.1", "glaeda-light-xcode-27.0.1"))
        self.assertEqual(pool.owned_pools(""), ())
        self.assertEqual(pool.owned_pools("/Applications/Xcode.app"), ())

    def test_persistent_means_a_glaeda_pool_label(self):
        self.assertTrue(pool.persistent(MINI))
        self.assertTrue(pool.persistent("glaeda-light-xcode-26.6"))
        for label in (SMALL, "ubuntu-24.04", "glaeda-mini", "glaeda-class-std", ""):
            self.assertFalse(pool.persistent(label), label)

    def test_off_by_default(self):
        self.assertEqual(owned_choice(fleet(small=0), owned="").runner, LARGE)

    def test_order_naming_an_owned_pool_is_ignored_while_off(self):
        self.assertEqual(owned_choice(fleet(small=0), owned="", order=f"{MINI},{SMALL}").runner, SMALL)

    def test_first_when_on_and_a_whole_run_fits(self):
        choice = owned_choice(fleet(busy=8))
        self.assertEqual((choice.runner, choice.xcode_app), (MINI, ""))
        self.assertIn("3 of 11 owned machines free, this run needs 3", choice.reason)
        # The re-run of failed jobs is named now, on the lane's own Xcode.
        self.assertEqual(choice.retry_runner, LARGE)
        self.assertEqual(owned_choice(fleet(), owned="").retry_runner, "")

    def test_light_is_the_second_owned_pool(self):
        snap = fleet(busy=9)
        snap["pools"][LIGHT] = {"queued": 0, "running": 0}
        both = json.dumps({MINI: 11, LIGHT: 3})
        self.assertEqual(owned_choice(snap, owned_slots=both).runner, LIGHT)
        # Two light minis cannot hold a three-job run, so it overflows.
        self.assertEqual(owned_choice(snap, owned_slots=json.dumps({MINI: 11, LIGHT: 2})).runner, LARGE)
        self.assertEqual(owned_choice(fleet(), owned_slots=both).runner, MINI)

    def test_a_run_needs_a_machine_for_each_of_its_jobs(self):
        # 11 machines, 9 busy: one run's 3 jobs would not all start.
        self.assertEqual(owned_choice(fleet(busy=9)).runner, LARGE)
        self.assertEqual(owned_choice(fleet(busy=9), jobs=2).runner, MINI)
        # A full suite needs all 11 at once.
        self.assertEqual(owned_choice(fleet(), jobs=11).runner, MINI)
        self.assertEqual(owned_choice(fleet(busy=1), jobs=11).runner, LARGE)

    def test_a_runs_peak_comes_from_its_routing(self):
        def jobs(**flags):
            base = dict(macos="true", full_suite="false", unit_suite="false", unit_in_admission="false",
                        claude_wrapper="false", cli="false", remote_daemon="false")
            return pool.run_jobs(**{**base, **flags})
        self.assertEqual(jobs(), 1)
        self.assertEqual(jobs(cli="true", remote_daemon="true"), 2)
        self.assertEqual(jobs(unit_suite="true"), 1)
        # A CLI change adds cli-product-tests after admission, on its machine;
        # admission itself runs the CLI smoke checks.
        self.assertEqual(jobs(unit_suite="true", unit_in_admission="true", cli="true"), 1)
        self.assertEqual(jobs(unit_suite="true", cli="true"), 2)
        # Full suite: seven shards, tests-build-and-lag and cli-product-tests after
        # admission, beside the two side lanes.
        self.assertEqual(jobs(full_suite="true", cli="true", remote_daemon="true"), pool.MAX_RUN_JOBS)
        self.assertEqual(pool.MAX_RUN_JOBS, 11)
        # A CLI-only run still compiles, then tests the bundled CLI.
        self.assertEqual(jobs(macos="false", cli="true"), 1)
        self.assertEqual(jobs(macos="false", claude_wrapper="true", cli="true"), 2)
        self.assertEqual(jobs(macos="false"), 0)

    def test_committed_peaks_count_jobs_not_created_yet(self):
        # Two machines busy, but the runs holding them declared 9 at their peak.
        snap = fleet(busy=2)
        snap["pools"][MINI]["committed"] = 9
        self.assertEqual(owned_choice(snap).runner, LARGE)
        self.assertEqual(owned_choice(snap, jobs=2).runner, MINI)

    def test_queued_jobs_take_machines_without_closing_the_pool(self):
        self.assertEqual(owned_choice(fleet(busy=5, queued=3)).runner, MINI)
        self.assertEqual(owned_choice(fleet(busy=5, queued=4)).runner, LARGE)

    def test_replayed_runs_are_charged_a_compile_only_peak(self):
        # A run created since the snapshot has an unknown peak: any that could
        # have taken the pool is assumed to, and charged REPLAYED_RUN_JOBS (3).
        self.assertEqual(pool.REPLAYED_RUN_JOBS, 3)
        # 11 machines: three newer runs take 9, leaving 2, too few for this
        # 3-job run; two newer runs leave 5.
        self.assertEqual(owned_choice(fleet(), routed=3).runner, LARGE)
        self.assertEqual(owned_choice(fleet(), routed=2).runner, MINI)
        self.assertEqual(owned_choice(fleet(), routed=2, jobs=6).runner, LARGE)
        self.assertEqual(owned_choice(fleet(busy=10), routed=1).runner, LARGE)

    def test_newer_runs_with_known_routes_are_charged_what_they_took(self):
        # 5 machines, 5 newer runs. Guessed, the first two replays would close
        # the pool (3 each); known, only the one on the minis counts, at its peak.
        guessed = owned_choice(fleet(), machines=5, jobs=1, routed=5)
        self.assertEqual(guessed.runner, LARGE)
        known = pool.Routed(owned={MINI: 3}, ephemeral=4)
        choice = owned_choice(fleet(), machines=5, jobs=1, routed=known)
        self.assertEqual(choice.runner, MINI)
        self.assertIn("2 of 5 owned machines free", choice.reason)
        self.assertIn(f"3 machine(s) newer runs took on {MINI}", choice.reason)
        self.assertEqual(owned_choice(fleet(), machines=5, jobs=3, routed=known).runner, LARGE)
        # A run still picking is replayed as before, on top of what is known.
        self.assertEqual(owned_choice(fleet(), machines=5, jobs=2,
                                      routed=pool.Routed(unknown=1, owned={MINI: 1})).runner, LARGE)

    def test_runs_off_the_owned_pools_still_queue_on_blacksmith(self):
        snap = backlog(small=0, large=0)
        snap["pools"][LARGE]["running"] = pool.POOL_CAPACITIES[LARGE] - 1
        self.assertEqual(choose(snap).runner, LARGE)
        self.assertEqual(choose(snap, routed=pool.Routed(ephemeral=1)).runner, SMALL)

    def test_route_lookup_reads_markers_then_the_changes_job(self):
        same = {"head_repository": {"id": 5}, "repository": {"id": 5}}
        skipped = [{"name": pool.MARKER_STEP, "conclusion": "skipped"}]
        runs = [{"id": 1, "run_attempt": 1, "status": "in_progress", **same},
                {"id": 2, "run_attempt": 1, "status": "in_progress", **same},
                {"id": 3, "run_attempt": 1, "status": "queued", **same},
                {"id": 4, "run_attempt": 1, "status": "completed", **same},
                {"id": 5, "run_attempt": 1, "status": "in_progress", **same},
                {"id": 6, "run_attempt": 1, "status": "in_progress", **same},
                {"id": 7, "run_attempt": 1, "status": "in_progress",
                 "head_repository": {"id": 8}, "repository": {"id": 5}},
                {"id": 8, "run_attempt": 2, "status": "in_progress", **same},
                {"id": 9, "run_attempt": 1, "status": "in_progress", **same}]
        responses = {
            # A marker, with an absurd peak capped at MAX_RUN_JOBS.
            "/actions/runs/1/artifacts?per_page=100": {"artifacts": [
                {"name": f"macos-pool-persistent-1-1-999-{MINI}", "expired": False}]},
            # Another run's marker does not count; the skipped marker step does.
            "/actions/runs/2/artifacts?per_page=100": {"artifacts": [
                {"name": f"macos-pool-persistent-7-1-9-{MINI}", "expired": False}]},
            "/actions/runs/2/jobs?filter=latest&per_page=100": {"jobs": [
                {"name": "changes", "status": "completed", "steps": skipped}]},
            # Still picking.
            "/actions/runs/3/artifacts?per_page=100": {"artifacts": []},
            "/actions/runs/3/jobs?filter=latest&per_page=100": {"jobs": [
                {"name": "changes", "status": "in_progress", "steps": skipped}]},
            # Picked an owned pool but the marker upload was lost.
            "/actions/runs/5/artifacts?per_page=100": {"artifacts": []},
            "/actions/runs/5/jobs?filter=latest&per_page=100": {"jobs": [
                {"name": "changes", "status": "completed",
                 "steps": [{"name": pool.MARKER_STEP, "conclusion": "success"}]}]},
            # Run 6's lookup fails. Run 7 (fork) is never looked up. Run 8
            # (attempt 2) is looked up only with CI_OWNED_LIGHT_RETRY on, when
            # it may hold the light tier; its lookup fails, so it is replayed.
        }

        def get(path):
            if path not in responses:
                raise RuntimeError(f"GET {path} failed (500)")
            return responses[path]

        client = pool.GitHub("token", "manaflow-ai/cmux")
        with unittest.mock.patch.object(client, "runs_since", return_value=runs), \
                unittest.mock.patch.object(client, "get", side_effect=get):
            routed = client.pull_request_routes_since("2026-09-24T00:00:00Z", exclude_run_id=9)
            light = client.pull_request_routes_since("2026-09-24T00:00:00Z", exclude_run_id=9, light_retry=True)
        self.assertEqual(routed, pool.Routed(unknown=3, owned={MINI: pool.MAX_RUN_JOBS}, ephemeral=3))
        self.assertEqual(light, pool.Routed(unknown=4, owned={MINI: pool.MAX_RUN_JOBS}, ephemeral=2))

    def test_marker_step_and_routing_job_names_match_ci_yml(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/ci.yml").read_text()
        self.assertIn(f"      - name: {pool.MARKER_STEP}\n", workflow)
        self.assertIn(f"\n  {pool.ROUTING_JOB}:\n", workflow)

    def test_route_lookups_stop_at_the_cap(self):
        same = {"head_repository": {"id": 5}, "repository": {"id": 5}, "run_attempt": 1, "status": "queued"}
        runs = [{"id": n, **same} for n in range(1, pool.ROUTE_LOOKUPS + 4)]
        client = pool.GitHub("token", "manaflow-ai/cmux")
        with unittest.mock.patch.object(client, "runs_since", return_value=runs), \
                unittest.mock.patch.object(client, "get", return_value={}) as get:
            routed = client.pull_request_routes_since("2026-09-24T00:00:00Z", exclude_run_id=None)
        self.assertEqual(routed, pool.Routed(unknown=len(runs)))
        self.assertEqual(get.call_count, 2 * pool.ROUTE_LOOKUPS)

    def test_stale_snapshot_or_no_slots_skips_the_pool(self):
        self.assertNotEqual(owned_choice(fleet(age=pool.MAX_SNAPSHOT_MINUTES + 1)).runner, MINI)
        self.assertEqual(owned_choice(fleet(age=40)).runner, MINI)
        self.assertEqual(owned_choice(fleet(), owned_slots="").runner, LARGE)
        self.assertEqual(owned_choice(fleet(), machines=0).runner, LARGE)

    def test_a_pool_the_janitor_saw_no_job_on_is_idle(self):
        self.assertEqual(owned_choice(backlog()).runner, MINI)

    def test_bad_slot_entries_are_named(self):
        problems = pool.slot_problems('{"%s": 11, "glaeda-std-xcode-26.6x": 2, "%s": "3", "%s": 11.0}'
                                      % (MINI, LIGHT, "glaeda-xl-xcode-26.6"))
        self.assertEqual(len(problems), 3, problems)
        self.assertTrue(any("glaeda-std-xcode-26.6x" in p and "not an owned pool label" in p for p in problems))
        self.assertTrue(any(LIGHT in p and "'3'" in p for p in problems))
        self.assertEqual(pool.slot_problems(""), [])
        self.assertEqual(pool.slot_problems('{"%s": 11}' % MINI), [])
        for side in ("side-std", "glaeda-side-std-xcode-26.6"):
            self.assertIn("names side runners", pool.slot_problems('{"%s": 11, "%s": 4}' % (MINI, side))[0])
        self.assertIn("not JSON", pool.slot_problems("nope")[0])
        self.assertIn("not a JSON object", pool.slot_problems("[1]")[0])

    def test_main_flags_bad_slots_only_on_same_repo_prs_while_owned_pools_are_on(self):
        cases = (("1", "pull_request", "manaflow-ai/cmux", True), ("", "pull_request", "manaflow-ai/cmux", False),
                 ("1", "push", "", False), ("1", "pull_request", "someone/cmux", False))
        for owned, event, head, flagged in cases:
            with tempfile.TemporaryDirectory() as tmp:
                stdout = io.StringIO()
                snapshot = Path(tmp, "snap.json")
                snapshot.write_text(json.dumps(fleet()))
                env = {"EVENT_NAME": event, "GITHUB_REPOSITORY": "manaflow-ai/cmux", "HEAD_REPO": head,
                       "DEFAULT_RUNNER": SMALL, "POOL_OWNED": owned, "OWNED_SLOTS": '{"glaeda-std": 3}',
                       "CMUX_CI_XCODE_APP_PR": PR_XCODE, "GITHUB_STEP_SUMMARY": str(Path(tmp, "summary"))}
                with unittest.mock.patch("sys.stdout", stdout):
                    pool.main(["--snapshot", str(snapshot)], env)
                case = (owned, event, head)
                self.assertEqual("::error title=CI_OWNED_POOL_SLOTS::" in stdout.getvalue(), flagged, case)
                self.assertEqual("**Error:**" in Path(tmp, "summary").read_text(), flagged, case)

    def test_slots_take_a_bare_count_or_a_class_for_the_lane_pin(self):
        pin = "/Applications/Xcode_26.6.app"
        for raw in ("40", " 40\n", '{"std": 40}'):
            self.assertEqual(pool.slots(raw, pin), {MINI: 40}, raw)
            self.assertEqual(pool.slot_problems(raw, pin), [], raw)
        self.assertEqual(pool.slots('{"std": 40, "light": 4}', pin), {MINI: 40, LIGHT: 4})
        self.assertEqual(pool.slots('{"std": 40, "%s": 36}' % MINI, pin), {MINI: 36})
        self.assertEqual(pool.slots("40", ""), {})
        self.assertIn("names no Xcode version", pool.slot_problems("40", "")[0])
        self.assertEqual(pool.slots("0", pin), {})
        self.assertEqual(pool.slots("true", pin), {})
        self.assertEqual(owned_choice(fleet(), owned_slots="40").runner, MINI)

    def test_slots_ignore_anything_malformed(self):
        self.assertEqual(pool.slots('{"%s": 11, "blacksmith-6vcpu-macos-26": 5, "glaeda-std-xcode-26.3": 0,'
                                    ' "glaeda-light-xcode-26.6": true}' % MINI), {MINI: 11})
        for raw in ("", "nope", "[1]", '{"%s": "3"}' % MINI):
            self.assertEqual(pool.slots(raw), {}, raw)

    def test_full_owned_only_order_keeps_todays_route(self):
        choice = owned_choice(fleet(busy=9), order=MINI)
        self.assertEqual(choice.runner, "")
        self.assertIn("busy", choice.reason)

    def test_a_stale_xcode_label_in_the_order_is_dropped_and_reported(self):
        choice = owned_choice(fleet(small=0), order=f"glaeda-std-xcode-26.3,{SMALL}")
        self.assertEqual(choice.runner, SMALL)
        self.assertIn("dropped glaeda-std-xcode-26.3 (not the lane's Xcode pin)", choice.reason)

    def test_fork_never_takes_an_owned_pool(self):
        settings = dict(FORK_SETTINGS, order=f"{MINI},{SMALL}")
        self.assertEqual(owned_choice(fleet(small=0, settings=settings), head="someone/cmux").runner, SMALL)

    def test_retry_skips_the_owned_pool(self):
        choice = owned_choice(fleet(), attempt=2)
        self.assertEqual(choice.runner, LARGE)
        self.assertTrue(choice.reason.startswith("retry attempt 2; "), choice.reason)

    def test_retry_with_only_owned_pools_keeps_todays_route(self):
        choice = owned_choice(fleet(), order=MINI, attempt=2)
        self.assertEqual((choice.runner, choice.xcode_app), ("", ""))
        self.assertIn("no ephemeral pool", choice.reason)

    def test_retry_on_blacksmith_only_changes_nothing(self):
        self.assertEqual(choose(backlog(), attempt=3).runner, choose(backlog()).runner)

    def output(self, attempt, owned="1"):
        with tempfile.TemporaryDirectory() as tmp:
            snapshot = Path(tmp, "snap.json")
            fresh = fleet()
            fresh["generated_at"] = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            snapshot.write_text(json.dumps(fresh))
            out = Path(tmp, "out")
            env = {"EVENT_NAME": "pull_request", "GITHUB_REPOSITORY": "manaflow-ai/cmux",
                   "HEAD_REPO": "manaflow-ai/cmux", "DEFAULT_RUNNER": SMALL, "POOL_OWNED": owned,
                   "OWNED_SLOTS": json.dumps({MINI: 3}),
                   "CMUX_CI_XCODE_APP_PR": PR_XCODE, "CMUX_CI_XCODE_APP_MACOS_15": XCODE_15,
                   "GITHUB_RUN_ATTEMPT": str(attempt), "GITHUB_OUTPUT": str(out),
                   "RUN_MACOS": "true"}
            with unittest.mock.patch("sys.stdout", io.StringIO()):
                pool.main(["--snapshot", str(snapshot)], env)
            return dict(line.split("=", 1) for line in out.read_text().splitlines())

    def test_main_reports_a_persistent_choice(self):
        first = self.output(1)
        self.assertEqual((first["runner"], first["persistent"], first["retry_runner"]), (MINI, "true", LARGE))
        self.assertEqual(first["jobs"], "1")
        retried = self.output(2)
        self.assertEqual((retried["runner"], retried["persistent"], retried["retry_runner"]), (LARGE, "false", ""))
        # A re-run of failed jobs reuses attempt 1's outputs, so its refused
        # owned jobs try the fleet once more; a full re-run picks again and
        # gets no owned label.
        self.assertEqual((first["refused_retry_runner"], retried["refused_retry_runner"]), (MINI, ""))
        self.assertEqual(self.output(1, owned="")["persistent"], "false")


def routing(**flags):
    base = dict(macos="true", full_suite="false", unit_suite="false", unit_in_admission="false",
                claude_wrapper="false", cli="false", remote_daemon="false", unit_selectors="")
    return pool.run_plan(**{**base, **flags})


FULL = dict(full_suite="true", cli="true", remote_daemon="true")


class PerJobPlacement(unittest.TestCase):
    """CI_PR_POOL_OWNED_SPLIT: free owned machines take the jobs that fit, Blacksmith the rest."""

    def test_the_plan_names_each_job(self):
        plan = routing(**FULL)
        self.assertTrue(plan.admission)
        self.assertEqual(plan.after, (*(f"shard-{index}" for index in range(1, 8)), "lag", "cli-product"))
        self.assertEqual(plan.side, ("claude-wrapper", "remote-daemon"))
        self.assertEqual(plan.peak, pool.MAX_RUN_JOBS)
        # The unit-ci label runs all seven shards; selected suites one worker, shard 8.
        self.assertEqual(routing(unit_suite="true").after, tuple(f"shard-{index}" for index in range(1, 8)))
        self.assertEqual(routing(unit_suite="true", unit_selectors="Suite").after, ("shard-8",))
        self.assertEqual(routing(unit_suite="true", unit_in_admission="true", unit_selectors="Suite").after, ())
        # A CLI-only run compiles, then runs cli-product-tests; nothing beside it.
        cli_only = routing(macos="false", cli="true")
        self.assertEqual((cli_only.admission, cli_only.after, cli_only.side), (True, ("cli-product",), ()))

    def test_admission_then_gui_jobs_then_light_jobs(self):
        plan = routing(**FULL)
        shards = tuple(f"shard-{index}" for index in range(1, 8))
        self.assertEqual(pool.place(plan, 0), ((), 0))
        # Shards reuse admission's machine once it finishes.
        self.assertEqual(pool.place(plan, 1), (("admission", "shard-1"), 1))
        self.assertEqual(pool.place(plan, 3), (("admission", "shard-1", "shard-2", "shard-3"), 3))
        self.assertEqual(pool.place(plan, 9), (("admission", *shards, "lag", "cli-product"), 9))
        self.assertEqual(pool.place(plan, 11), (("admission", *shards, "lag", "cli-product",
                                                 "remote-daemon", "claude-wrapper"), 11))
        self.assertEqual(pool.owned_peak(plan), 11)
        self.assertEqual(pool.place(routing(unit_suite="true", unit_selectors="Suite"), 1),
                         (("admission", "shard-8"), 1))

    def test_gui_jobs_stay_off_when_switched_off(self):
        plan = routing(**FULL)
        self.assertEqual(pool.place(plan, 1, gui=False), (("admission", "cli-product"), 1))
        self.assertEqual(pool.place(plan, 2, gui=False), (("admission", "cli-product", "remote-daemon"), 2))
        everything = ("admission", "cli-product", "remote-daemon", "claude-wrapper")
        self.assertEqual(pool.place(plan, 12, gui=False), (everything, 3))
        self.assertEqual(pool.owned_peak(plan, gui=False), 3)
        # A run without admission places its side lanes alone.
        self.assertEqual(pool.place(routing(macos="false", remote_daemon="true"), 1), (("remote-daemon",), 1))

    def test_split_takes_the_free_machines_instead_of_overflowing(self):
        # 11 machines, 9 busy: a 3-machine run does not fit whole.
        self.assertEqual(owned_choice(fleet(busy=9)).runner, LARGE)
        choice = owned_choice(fleet(busy=9), split="1")
        self.assertEqual((choice.runner, choice.retry_runner, choice.owned_budget), (MINI, LARGE, 2))
        self.assertIn("2 of 11", choice.reason)
        # A whole fit keeps the old reason and a budget of the run's peak.
        whole = owned_choice(fleet(busy=2), split="1")
        self.assertEqual((whole.runner, whole.owned_budget), (MINI, 3))
        self.assertIn("first pool in order with headroom", whole.reason)
        # No machine free at all: Blacksmith, as before.
        self.assertEqual(owned_choice(fleet(busy=11), split="1").runner, LARGE)

    def test_split_prefers_a_pool_the_whole_run_fits(self):
        snap = fleet(busy=9)
        snap["pools"][LIGHT] = {"queued": 0, "running": 0}
        both = json.dumps({MINI: 11, LIGHT: 3})
        self.assertEqual(owned_choice(snap, owned_slots=both, split="1").runner, LIGHT)
        # Neither fits: the pool with the most free machines.
        snap["pools"][LIGHT] = {"queued": 0, "running": 2}
        self.assertEqual(owned_choice(snap, owned_slots=both, split="1", jobs=4).runner, MINI)
        # A tie goes to the earlier pool; a full one never takes the run.
        snap["pools"][MINI]["running"] = 10
        self.assertEqual(owned_choice(snap, owned_slots=both, split="1", jobs=4).runner, MINI)
        snap["pools"][MINI]["running"] = 11
        self.assertEqual(owned_choice(snap, owned_slots=both, split="1", jobs=4).runner, LIGHT)

    def test_split_is_off_unless_1(self):
        for value in ("", "0", "true"):
            self.assertEqual(owned_choice(fleet(busy=9), split=value).runner, LARGE, value)

    def output(self, *, busy, split="1", gui="", rounds="0", **routing_env):
        with tempfile.TemporaryDirectory() as tmp:
            snapshot = Path(tmp, "snap.json")
            fresh = fleet(busy=busy)
            fresh["generated_at"] = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            snapshot.write_text(json.dumps(fresh))
            out = Path(tmp, "out")
            env = {"EVENT_NAME": "pull_request", "GITHUB_REPOSITORY": "manaflow-ai/cmux",
                   "HEAD_REPO": "manaflow-ai/cmux", "DEFAULT_RUNNER": SMALL, "POOL_OWNED": "1",
                   "POOL_OWNED_SPLIT": split, "POOL_OWNED_GUI": gui, "OWNED_SLOTS": json.dumps({MINI: 11}),
                   "POOL_QUEUE_ROUNDS": rounds,
                   "CMUX_CI_XCODE_APP_PR": PR_XCODE, "CMUX_CI_XCODE_APP_MACOS_15": XCODE_15,
                   "GITHUB_RUN_ATTEMPT": "1", "GITHUB_OUTPUT": str(out), "RUN_MACOS": "true",
                   **routing_env}
            with unittest.mock.patch("sys.stdout", io.StringIO()):
                pool.main(["--snapshot", str(snapshot)], env)
            return dict(line.split("=", 1) for line in out.read_text().splitlines())

    def test_main_names_the_owned_jobs_and_marks_their_peak(self):
        full = {"RUN_FULL_SUITE": "true", "RUN_CLI": "true", "RUN_REMOTE_DAEMON": "true"}
        partial = self.output(busy=8, **full)
        self.assertEqual((partial["runner"], partial["retry_runner"]), (MINI, LARGE))
        self.assertEqual(partial["owned_jobs"], " admission shard-1 shard-2 shard-3 ")
        # The marker (and so the janitor) counts the owned machines placed.
        self.assertEqual(partial["jobs"], "3")
        # 10 free machines for an 11-machine run: the last light job overflows.
        most = self.output(busy=1, **full)
        self.assertEqual(most["owned_jobs"].split()[-3:], ["lag", "cli-product", "remote-daemon"])
        self.assertEqual(most["jobs"], "10")
        # GUI jobs off: only admission and the light jobs.
        light = self.output(busy=9, gui="0", **full)
        self.assertEqual((light["owned_jobs"], light["jobs"]), (" admission cli-product remote-daemon ", "2"))
        # Selected suites a compile admission would run itself move to shard 8.
        suites = self.output(busy=0, RUN_UNIT_SUITE="true", RUN_UNIT_IN_ADMISSION="true",
                             RUN_UNIT_SELECTORS="cmuxTests/SomeSuite")
        self.assertEqual(suites["owned_jobs"], " admission shard-8 ")
        # Split off: the whole-run rule over the owned-eligible jobs only.
        self.assertEqual(self.output(busy=8, split="", gui="0", **full)["runner"], MINI)
        off = self.output(busy=9, split="", gui="0", **full)
        self.assertEqual((off["runner"], off["owned_jobs"]), (LARGE, ""))


ROOT_MINI = "glaeda-root-std-xcode-26.6"


class QueueBehindBusyRunners(unittest.TestCase):
    """CI_PR_POOL_QUEUE_ROUNDS: a run may queue about one job length behind a busy pool instead of rolling over."""

    def test_rounds_setting(self):
        self.assertEqual(pool.settings("", "", "", queue_rounds="").queue_rounds, pool.DEFAULT_QUEUE_ROUNDS)
        self.assertEqual(pool.DEFAULT_QUEUE_ROUNDS, 1)
        self.assertEqual(pool.settings("", "", "", queue_rounds="0").queue_rounds, 0)
        self.assertEqual(pool.settings("", "", "", queue_rounds=" 2 ").queue_rounds, 2)
        # Capped, so the rescue's longer budget stays inside its watch.
        self.assertEqual(pool.MAX_QUEUE_ROUNDS, 3)
        self.assertEqual(pool.settings("", "", "", queue_rounds="9").queue_rounds, 3)
        for bad in ("-1", "1.5", "x"):
            self.assertIsNone(pool.settings("", "", "", queue_rounds=bad), bad)
            self.assertEqual(choose(backlog(), queue_rounds=bad).runner, "", bad)
        # The E2E and iOS pickers never pass it: their rule is unchanged.
        self.assertEqual(pool.settings("", "", "").queue_rounds, 0)
        self.assertEqual(e2e_pool.settings("", "").queue_rounds, 0)

    def test_12vcpu_takes_a_round_of_queue_before_rolling_over(self):
        # 2026-09-25: a full 12vcpu rolled each run over to 6vcpu's last free
        # machine, and 6vcpu then queued 11 for 15 minutes.
        snap = backlog(small=0, large=0, old=0)
        snap["pools"][SMALL]["running"] = 9
        snap["pools"][LARGE]["running"] = 5
        self.assertEqual(choose(snap, queue_rounds="0").runner, SMALL)
        choice = choose(snap, queue_rounds="")
        self.assertEqual(choice.runner, LARGE)
        self.assertIn("<= 5 queued once this run arrives", choice.reason)
        # Its fifth queued job is the last: a sixth would wait more than a round.
        snap["pools"][LARGE]["queued"] = 4
        self.assertEqual(choose(snap, queue_rounds="").runner, LARGE)
        snap["pools"][LARGE]["queued"] = 5
        self.assertNotEqual(choose(snap, queue_rounds="").runner, LARGE)
        # Two rounds hold twice as many.
        self.assertEqual(choose(snap, queue_rounds="2").runner, LARGE)

    def test_a_round_on_a_seeded_pool_before_a_cold_one(self):
        # macOS 15 costs COLD_ROUNDS more, so up to a round on 6vcpu 26 is no worse.
        snap = backlog(small=3, large=18, old=0)
        snap["pools"][LARGE]["running"] = 3
        snap["pools"][OLD]["running"] = 1
        self.assertEqual(choose(snap, queue_rounds="0").runner, OLD)
        self.assertEqual(choose(snap, queue_rounds="").runner, SMALL)
        snap["pools"][SMALL]["queued"] = 10
        self.assertEqual(choose(snap, queue_rounds="").runner, OLD)

    def test_an_owned_run_queues_behind_busy_runners(self):
        # All 11 minis busy: a compile-only run (3 jobs) waits there, not on Blacksmith.
        self.assertEqual(owned_choice(fleet(busy=11), queue_rounds="0").runner, LARGE)
        choice = owned_choice(fleet(busy=11), queue_rounds="")
        self.assertEqual((choice.runner, choice.owned_budget), (MINI, 3))
        self.assertIn("0 of 11 owned machines free and 11 may queue behind them, this run needs 3", choice.reason)
        # Bounded: taken plus this run's peak stays within 11 x (1 + 1).
        self.assertEqual(owned_choice(fleet(busy=11, queued=8), queue_rounds="").runner, MINI)
        self.assertEqual(owned_choice(fleet(busy=11, queued=9), queue_rounds="").runner, LARGE)
        # Split takes what still fits in the queue, and sends the rest to Blacksmith.
        split = owned_choice(fleet(busy=11, queued=9), queue_rounds="", split="1")
        self.assertEqual((split.runner, split.owned_budget), (MINI, 2))

    def test_root_runners_get_the_same_allowance(self):
        # Run 36101290548 (2026-09-25): 36 std runners, 14 root, "-4 of 14 root
        # runners free" from the janitor's commitments and newer runs' markers,
        # so no job took the fleet. A round of queue over 14 root runners fits.
        slots = json.dumps({MINI: 36, ROOT_MINI: 14})
        snap = fleet(busy=4)
        snap["pools"][ROOT_MINI] = {"queued": 0, "running": 3, "committed": 11}
        routed = pool.Routed(owned={MINI: 7})
        before = owned_choice(snap, machines=36, owned_slots=slots, jobs=2, root_jobs=2, split="1",
                              routed=routed, queue_rounds="0")
        self.assertEqual(before.root_budget, 0)
        after = owned_choice(snap, machines=36, owned_slots=slots, jobs=2, root_jobs=2, split="1",
                             routed=routed, queue_rounds="")
        self.assertEqual((after.runner, after.root_runner, after.root_budget), (MINI, ROOT_MINI, 10))
        self.assertIn("-4 of 14 root runners free and 14 may queue behind them, it needs 2", after.reason)
        self.assertEqual(pool.place(pool.run_plan(macos="true", full_suite="", unit_suite="", unit_in_admission="",
                                                  claude_wrapper="true", cli="", remote_daemon=""),
                                    after.owned_budget, root_budget=after.root_budget)[0],
                         ("admission", "claude-wrapper"))
        # Root queue is bounded too: 14 x 2 root jobs at most.
        snap["pools"][ROOT_MINI]["committed"] = 26
        full = owned_choice(snap, machines=36, owned_slots=slots, jobs=2, root_jobs=2, split="1",
                            routed=routed, queue_rounds="")
        self.assertEqual(full.root_budget, 0)

    def test_live_capacity_queues_a_round_of_the_slot_count(self):
        # Two of 11 idle: a 3-job run fits with a round of queue, not without.
        fresh = fleet(busy=0)
        self.assertEqual(owned_choice(fresh, live_owned={MINI: 2}, queue_rounds="0").runner, LARGE)
        choice = owned_choice(fresh, live_owned={MINI: 2}, queue_rounds="")
        self.assertEqual(choice.runner, MINI)
        self.assertIn("2 of 11 owned machines free and 11 may queue behind them", choice.reason)

    def test_live_busy_fleet_still_queues_but_bounded(self):
        # Every runner busy (the API cannot see a queue): the pool still takes a
        # round, charged against the busy runners and the recent runs' peaks.
        fresh = fleet(busy=0)
        busy = owned_choice(fresh, live_owned={MINI: 0}, queue_rounds="")
        self.assertEqual((busy.runner, busy.owned_budget), (MINI, 3))
        # Runs of the live window that took 9: 11 busy + 9 + 3 > 22.
        recent = pool.Routed(owned={MINI: 9})
        self.assertEqual(owned_choice(fresh, live_owned={MINI: 0}, queue_rounds="", routed=recent).runner, LARGE)
        self.assertEqual(owned_choice(fresh, live_owned={MINI: 0}, queue_rounds="",
                                      routed=pool.Routed(owned={MINI: 8})).runner, MINI)
        # The janitor's queue counts where no runner is idle, and the peaks of
        # runs since the snapshot but before the window (they may still queue).
        self.assertEqual(owned_choice(fleet(busy=11, queued=9), live_owned={MINI: 0}, queue_rounds="").runner,
                         LARGE)
        windows = []

        def routed(since):
            windows.append(since)
            return pool.Routed(owned={MINI: 9}) if len(windows) == 1 else pool.Routed()

        self.assertEqual(owned_choice(fresh, live_owned={MINI: 0}, queue_rounds="", routed=routed).runner, LARGE)
        # An idle runner means that label has no queue: the older runs are running.
        windows.clear()
        self.assertEqual(owned_choice(fresh, live_owned={MINI: 1}, queue_rounds="", routed=routed).runner, MINI)
        # Without a slot count the idle runners are the capacity, as before.
        self.assertEqual(owned_choice(fresh, owned_slots="", live_owned={MINI: 0}, queue_rounds="").runner, LARGE)

    def test_forks_read_the_rounds_the_janitor_copied(self):
        snap = backlog(small=0, large=0, old=0, settings={**FORK_SETTINGS, "queue_rounds": "0"})
        snap["pools"][SMALL]["running"] = 9
        snap["pools"][LARGE]["running"] = 5
        fork = dict(head="someone/cmux", default="", pins={})
        self.assertEqual(choose(snap, **fork).runner, SMALL)
        snap["settings"].pop("queue_rounds")
        self.assertEqual(choose(snap, **fork).runner, LARGE)
        self.assertEqual(janitor.POOL_SETTINGS_ENV["PR_POOL_QUEUE_ROUNDS"], "queue_rounds")

    def main_outputs(self, busy):
        with tempfile.TemporaryDirectory() as tmp:
            snapshot = Path(tmp, "snap.json")
            fresh = fleet(busy=busy)
            fresh["generated_at"] = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            snapshot.write_text(json.dumps(fresh))
            out = Path(tmp, "out")
            env = {"EVENT_NAME": "pull_request", "GITHUB_REPOSITORY": "manaflow-ai/cmux",
                   "HEAD_REPO": "manaflow-ai/cmux", "DEFAULT_RUNNER": SMALL, "POOL_OWNED": "1",
                   "OWNED_SLOTS": json.dumps({MINI: 11}), "POOL_QUEUE_ROUNDS": "",
                   "CMUX_CI_XCODE_APP_PR": PR_XCODE, "CMUX_CI_XCODE_APP_MACOS_15": XCODE_15,
                   "GITHUB_RUN_ATTEMPT": "1", "GITHUB_OUTPUT": str(out), "RUN_MACOS": "true"}
            with unittest.mock.patch("sys.stdout", io.StringIO()):
                pool.main(["--snapshot", str(snapshot)], env)
            return dict(line.split("=", 1) for line in out.read_text().splitlines())

    def test_main_queues_by_default_and_says_so(self):
        # Every mini busy: admission waits in the queue, and the rescue must know.
        busy = self.main_outputs(busy=11)
        self.assertEqual((busy["runner"], busy["owned_jobs"], busy["queued"]), (MINI, " admission ", "true"))
        # Free machines for the whole run: no queue marker, so the rescue keeps its short budget.
        free = self.main_outputs(busy=0)
        self.assertEqual((free["runner"], free["queued"]), (MINI, "false"))

    def test_used_queue_counts_root_runners_too(self):
        plan = pool.run_plan(macos="true", full_suite="", unit_suite="", unit_in_admission="",
                             claude_wrapper="true", cli="", remote_daemon="")
        keys = ("admission", "claude-wrapper")
        choice = pool.Choice(MINI, "", "", free_now=5, root_runner=ROOT_MINI, root_free_now=1)
        self.assertFalse(pool.used_queue(choice, plan, keys, 2))
        self.assertTrue(pool.used_queue(dataclasses.replace(choice, free_now=1), plan, keys, 2))
        self.assertTrue(pool.used_queue(dataclasses.replace(choice, root_free_now=0), plan, keys, 2))
        self.assertFalse(pool.used_queue(pool.Choice(LARGE, "", ""), plan, keys, 2))

    def test_workflows_pass_the_variable(self):
        ci = yaml.safe_load((WORKFLOWS / "ci.yml").read_text())
        step = next(step for step in ci["jobs"]["changes"]["steps"] if step.get("id") == "macos-pool")
        self.assertEqual(step["env"]["POOL_QUEUE_ROUNDS"], "${{ vars.CI_PR_POOL_QUEUE_ROUNDS }}")
        janitor_doc = (WORKFLOWS / "ci-queue-janitor.yml").read_text()
        self.assertIn("PR_POOL_QUEUE_ROUNDS: ${{ vars.CI_PR_POOL_QUEUE_ROUNDS }}", janitor_doc)


class RootRunners(unittest.TestCase):
    """glaeda's canonical-root jobs take the one root runner per mini, counted apart from the pool."""

    def test_root_labels_are_owned_and_pair_with_their_pool(self):
        self.assertTrue(pool.persistent(ROOT_MINI))
        self.assertEqual((pool.root_label(MINI), pool.pool_label(ROOT_MINI)), (ROOT_MINI, MINI))
        self.assertEqual((pool.root_label(ROOT_MINI), pool.root_label(SMALL), pool.pool_label(SMALL)), ("", "", SMALL))
        # The order never names a root label: it is dropped like any other.
        self.assertEqual(pool.owned_pools(PR_XCODE), (MINI, LIGHT))

    def test_slots_take_a_root_class_or_label(self):
        for raw in ('{"std": 40, "root-std": 10}', json.dumps({MINI: 40, ROOT_MINI: 10})):
            self.assertEqual(pool.slots(raw, PR_XCODE), {MINI: 40, ROOT_MINI: 10}, raw)
            self.assertEqual(pool.slot_problems(raw, PR_XCODE), [], raw)
        # More root runners than the pool has machines is a typo, and flagged.
        self.assertEqual(pool.slots('{"std": 4, "root-std": 10}', PR_XCODE), {MINI: 4})
        self.assertIn("more than the 4 machines", pool.slot_problems('{"std": 4, "root-std": 10}', PR_XCODE)[0])
        self.assertEqual(pool.slots('{"root-std": 10}', PR_XCODE), {})

    def test_place_holds_root_jobs_within_the_root_budget(self):
        plan = routing(**FULL)
        # Admission then shards hold root runners; the side lanes do not.
        self.assertEqual(pool.root_peak(plan), 9)
        self.assertEqual(pool.place(plan, 12, root_budget=3),
                         (("admission", "shard-1", "shard-2", "shard-3", "remote-daemon",
                           "claude-wrapper"), 5))
        # No root runner free: only the side lanes take the pool.
        self.assertEqual(pool.place(plan, 12, root_budget=0), (("remote-daemon", "claude-wrapper"), 2))
        self.assertEqual(pool.place(plan, 12, root_budget=None), pool.place(plan, 12))

    def test_a_pool_fits_the_whole_run_only_with_its_root_runners_free(self):
        slots = json.dumps({MINI: 40, ROOT_MINI: 10})
        snap = fleet(busy=10)
        snap["pools"][ROOT_MINI] = {"queued": 0, "running": 9}
        # 30 machines free but one root runner: a run needing two overflows.
        self.assertEqual(owned_choice(snap, owned_slots=slots, jobs=4, root_jobs=2).runner, LARGE)
        fits = owned_choice(snap, owned_slots=slots, jobs=4, root_jobs=1)
        self.assertEqual((fits.runner, fits.root_runner, fits.root_budget), (MINI, ROOT_MINI, 1))
        # shard_runner is Choice's 6th field: a persistent pick leaves it empty
        # and never gets the root label there.
        self.assertEqual(fits.shard_runner, "")
        full = owned_choice(snap, owned_slots=slots, jobs=4, root_jobs=1, shards=pool.APP_HOST_SHARDS)
        self.assertEqual((full.shard_runner, full.root_runner), ("", ROOT_MINI))
        self.assertIn("1 of 10 root runners free", fits.reason)
        # With the split it takes the pool, and place() keeps to one root runner.
        split = owned_choice(snap, owned_slots=slots, jobs=4, root_jobs=2, split="1")
        self.assertEqual((split.runner, split.root_budget), (MINI, 1))
        # Committed root runners and newer runs count too.
        snap["pools"][ROOT_MINI] = {"queued": 0, "running": 2, "committed": 9}
        self.assertEqual(owned_choice(snap, owned_slots=slots, jobs=4, root_jobs=2).runner, LARGE)
        snap["pools"][ROOT_MINI] = {"queued": 0, "running": 0}
        self.assertEqual(owned_choice(snap, owned_slots=slots, jobs=4, root_jobs=2,
                                      routed=pool.Routed(owned={MINI: 9})).runner, LARGE)

    def test_live_capacity_reads_idle_root_runners(self):
        slots = json.dumps({MINI: 40, ROOT_MINI: 10})
        runners = [{"status": "online", "busy": False, "labels": [{"name": MINI}, {"name": ROOT_MINI}]},
                   {"status": "online", "busy": False, "labels": [{"name": MINI}]}]
        self.assertEqual(pool.live_owned_free(runners, (MINI, ROOT_MINI)), {MINI: 2, ROOT_MINI: 1})
        live = owned_choice(fleet(busy=0), owned_slots=slots, live_owned={MINI: 9, ROOT_MINI: 1},
                            jobs=3, root_jobs=1)
        self.assertEqual((live.runner, live.root_runner, live.root_budget), (MINI, ROOT_MINI, 1))
        self.assertEqual(owned_choice(fleet(busy=0), owned_slots=slots, live_owned={MINI: 9, ROOT_MINI: 0},
                                      jobs=3, root_jobs=1).runner, LARGE)
        # Idle root runners without a root count leave root routing off.
        off = owned_choice(fleet(busy=0), owned_slots=json.dumps({MINI: 40}), live_owned={MINI: 9, ROOT_MINI: 0},
                           jobs=3, root_jobs=1)
        self.assertEqual((off.runner, off.root_runner), (MINI, ""))

    def test_no_root_count_keeps_the_pool_label(self):
        choice = owned_choice(fleet(busy=0), jobs=4, root_jobs=2)
        self.assertEqual((choice.runner, choice.root_runner), (MINI, ""))
        # A fork or a Blacksmith pick never gets one.
        slots = json.dumps({MINI: 40, ROOT_MINI: 10})
        fork = choose(fleet(busy=0), owned="1", owned_slots=slots, head="someone/cmux", default="", pins={},
                      root_jobs=1)
        self.assertEqual(fork.root_runner, "")
        self.assertEqual(owned_choice(fleet(busy=40), owned_slots=slots, root_jobs=1).root_runner, "")

    def test_main_writes_the_root_runner(self):
        with tempfile.TemporaryDirectory() as tmp:
            snapshot = Path(tmp, "snap.json")
            fresh = fleet(busy=0)
            fresh["pools"][ROOT_MINI] = {"queued": 0, "running": 7}
            fresh["generated_at"] = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            snapshot.write_text(json.dumps(fresh))
            out = Path(tmp, "out")
            env = {"EVENT_NAME": "pull_request", "GITHUB_REPOSITORY": "manaflow-ai/cmux",
                   "HEAD_REPO": "manaflow-ai/cmux", "DEFAULT_RUNNER": SMALL, "POOL_OWNED": "1",
                   "POOL_OWNED_SPLIT": "1", "OWNED_SLOTS": '{"std": 40, "root-std": 10}', "POOL_QUEUE_ROUNDS": "0",
                   "CMUX_CI_XCODE_APP_PR": PR_XCODE, "CMUX_CI_XCODE_APP_MACOS_15": XCODE_15,
                   "GITHUB_RUN_ATTEMPT": "1", "GITHUB_OUTPUT": str(out), "RUN_MACOS": "true",
                   "RUN_FULL_SUITE": "true", "RUN_CLI": "true", "RUN_REMOTE_DAEMON": "true"}
            with unittest.mock.patch("sys.stdout", io.StringIO()):
                pool.main(["--snapshot", str(snapshot)], env)
            outputs = dict(line.split("=", 1) for line in out.read_text().splitlines())
        self.assertEqual((outputs["runner"], outputs["root_runner"], outputs["refused_retry_runner"]),
                         (MINI, ROOT_MINI, MINI))
        # Three root runners free: admission and two shards, beside every side lane.
        self.assertEqual(outputs["owned_jobs"],
                         " admission shard-1 shard-2 shard-3 remote-daemon claude-wrapper ")
        self.assertEqual(outputs["jobs"], "5")

    def test_the_janitor_counts_root_jobs_toward_both_labels(self):
        def job(label, status):
            return {"labels": [label], "status": status, "created_at": "2026-09-24T10:00:00Z", "name": "x"}
        run = {"id": 1, "name": "CI", "path": ".github/workflows/ci.yml", "status": "in_progress"}
        jobs = {1: [job(ROOT_MINI, "in_progress"), job(ROOT_MINI, "queued"), job(MINI, "in_progress"),
                    job(MINI, "completed")]}
        # The marker reserves 7 machines: 2 side lanes on the pool label, so 5 root runners.
        snap = janitor.pool_load_snapshot([run], jobs, now=NOW, markers={1: (MINI, 7)})
        self.assertEqual({key: snap["pools"][ROOT_MINI][key] for key in ("queued", "running", "committed")},
                         {"queued": 1, "running": 1, "committed": 5})
        self.assertEqual({key: snap["pools"][MINI][key] for key in ("queued", "running", "committed")},
                         {"queued": 1, "running": 2, "committed": 7})
        # An E2E marker names the root label: one root runner, one machine.
        e2e = {"id": 2, "name": "E2E", "path": ".github/workflows/test-e2e.yml", "status": "in_progress"}
        snap = janitor.pool_load_snapshot([e2e], {2: []}, now=NOW, markers={2: (ROOT_MINI, 1)})
        self.assertEqual((snap["pools"][ROOT_MINI]["committed"], snap["pools"][MINI]["committed"]), (1, 1))

    def test_e2e_takes_the_root_label(self):
        snap = fleet(busy=0)
        load = e2e_pool.PoolLoad(snap, {ROOT_MINI: 1})
        limits = e2e_pool.settings("", "", "1", PR_XCODE)
        choice = e2e_pool.decide(load, limits, now=NOW, owned_slots={MINI: 40, ROOT_MINI: 10})
        self.assertEqual((choice.runner, choice.root_runner), (MINI, ROOT_MINI))
        runner = e2e_pool.auto_runner(SMALL, enabled=True, limits=limits, measure=lambda: load, now=NOW,
                                      owned_slots={MINI: 40, ROOT_MINI: 10})
        self.assertEqual(runner, ROOT_MINI)
        self.assertEqual(e2e_pool.retry_runner(ROOT_MINI), SMALL)
        # Every root runner busy: Blacksmith, never a queue on the root label.
        snap["pools"][ROOT_MINI] = {"queued": 0, "running": 10}
        self.assertFalse(e2e_pool.auto_runner(SMALL, enabled=True, limits=limits, measure=lambda: load, now=NOW,
                                              owned_slots={MINI: 40, ROOT_MINI: 10}).startswith("glaeda-"))


WARM = "glaeda-warm-0123456789ab"
MERGE_BASE = "0123456789ab" + "c" * 28


def live_runner(runner_id, *labels, busy=False, status="online"):
    return {"id": runner_id, "name": f"cmux{runner_id}", "status": status, "busy": busy,
            "labels": [{"name": name} for name in labels]}


class WarmAffinity(unittest.TestCase):
    """Compile admission goes to the idle root runner that kept a build of its merge base."""

    def test_warm_label_takes_twelve_hex_digits(self):
        self.assertEqual(pool.warm_label(MERGE_BASE), WARM)
        self.assertEqual(pool.warm_label(MERGE_BASE.upper()), WARM)
        for commit in ("", None, "0123456789a", "not-a-commit-sha", "../../etc/passwd"):
            self.assertEqual(pool.warm_label(commit), "", commit)

    def test_only_an_idle_root_runner_carrying_the_label_is_picked(self):
        expected = json.dumps([ROOT_MINI, WARM], separators=(",", ":"))
        idle = live_runner(1, MINI, ROOT_MINI, WARM)
        self.assertEqual(pool.warm_admission_runner([idle], ROOT_MINI, MERGE_BASE), expected)
        self.assertEqual(json.loads(expected), [ROOT_MINI, WARM])
        for runners in ([live_runner(1, MINI, ROOT_MINI, WARM, busy=True)],
                        [live_runner(1, MINI, ROOT_MINI, WARM, status="offline")],
                        # The label on a runner of another root pool, or on no root runner.
                        [live_runner(1, LIGHT, "glaeda-root-light-xcode-26.6", WARM)],
                        [live_runner(1, MINI, WARM)],
                        [live_runner(1, MINI, ROOT_MINI, "glaeda-warm-ffffffffffff")]):
            self.assertEqual(pool.warm_admission_runner(runners, ROOT_MINI, MERGE_BASE), "", runners)
        # No merge base, or no root label: nothing.
        self.assertEqual(pool.warm_admission_runner([idle], ROOT_MINI, ""), "")
        self.assertEqual(pool.warm_admission_runner([idle], MINI, MERGE_BASE), "")
        # A busy warm runner is skipped for an idle one.
        both = [live_runner(1, MINI, ROOT_MINI, WARM, busy=True), live_runner(2, MINI, ROOT_MINI, WARM)]
        self.assertEqual(pool.warm_admission_runner(both, ROOT_MINI, MERGE_BASE), expected)

    def outputs(self, runners, *, merged_onto=MERGE_BASE, slots='{"std": 40, "root-std": 10}', token="app-token",
                warm_labels="1"):
        fresh = fleet(busy=0)
        fresh["generated_at"] = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        with tempfile.TemporaryDirectory() as tmp, \
                unittest.mock.patch.object(pool.GitHub, "snapshot", return_value=fresh), \
                unittest.mock.patch.object(pool.GitHub, "pull_request_routes_since", return_value=pool.Routed()), \
                unittest.mock.patch.object(pool.GitHub, "runners", return_value=runners), \
                unittest.mock.patch("sys.stdout", io.StringIO()):
            out, summary = Path(tmp, "out"), Path(tmp, "summary")
            env = {"EVENT_NAME": "pull_request", "GITHUB_REPOSITORY": "manaflow-ai/cmux", "GH_TOKEN": "t",
                   "HEAD_REPO": "manaflow-ai/cmux", "DEFAULT_RUNNER": SMALL, "POOL_OWNED": "1",
                   "POOL_OWNED_SPLIT": "1", "OWNED_SLOTS": slots, "ROUTE_TOKEN": token,
                   "CMUX_CI_XCODE_APP_PR": PR_XCODE, "CMUX_CI_XCODE_APP_MACOS_15": XCODE_15,
                   "GITHUB_RUN_ATTEMPT": "1", "GITHUB_OUTPUT": str(out), "GITHUB_STEP_SUMMARY": str(summary),
                   "RUN_MACOS": "true", "MERGED_ONTO": merged_onto, "WARM_LABELS": warm_labels}
            pool.main([], env)
            values = dict(line.split("=", 1) for line in out.read_text().splitlines())
            values["summary"] = summary.read_text()
        return values

    def test_main_names_the_warm_runner_for_admission(self):
        runners = [live_runner(1, MINI, ROOT_MINI), live_runner(2, MINI, ROOT_MINI, WARM), live_runner(3, MINI)]
        values = self.outputs(runners)
        self.assertEqual((values["runner"], values["root_runner"]), (MINI, ROOT_MINI))
        self.assertIn(" admission ", values["owned_jobs"])
        self.assertEqual(json.loads(values["admission_runner"]), [ROOT_MINI, WARM])
        self.assertIn(f"`{WARM}`", values["summary"])
        # Another merge base, a busy warm runner, or no root count: admission keeps the root label.
        self.assertEqual(self.outputs(runners, merged_onto="f" * 40)["admission_runner"], "")
        busy = [live_runner(1, MINI, ROOT_MINI), live_runner(2, MINI, ROOT_MINI, WARM, busy=True)]
        self.assertEqual(self.outputs(busy)["admission_runner"], "")
        self.assertEqual(self.outputs(runners, slots='{"std": 40}')["admission_runner"], "")
        # Without the route token the runners are never read.
        self.assertEqual(self.outputs(runners, token="")["admission_runner"], "")
        # CI_OWNED_WARM_LABELS off ignores labels already on the runners.
        for off in ("", "0"):
            self.assertEqual(self.outputs(runners, warm_labels=off)["admission_runner"], "", off)


class Wiring(unittest.TestCase):
    """Every pull-request macOS route in one CI run reads the one chosen pool."""

    def workflow(self, name):
        return yaml.safe_load((WORKFLOWS / name).read_text())

    def test_changes_job_chooses_once(self):
        changes = self.workflow("ci.yml")["jobs"]["changes"]
        self.assertEqual(changes["outputs"]["macos_pr_runner"], "${{ steps.macos-pool.outputs.runner }}")
        self.assertEqual(changes["outputs"]["macos_pr_xcode_app"], "${{ steps.macos-pool.outputs.xcode_app }}")
        self.assertEqual(changes["permissions"]["actions"], "read")
        step = next(step for step in changes["steps"] if step.get("id") == "macos-pool")
        self.assertIs(step["continue-on-error"], True)
        self.assertEqual(step["run"], "python3 scripts/ci/pr_runner_pool.py")
        self.assertEqual(step["env"]["DEFAULT_RUNNER"], "${{ vars.MACOS_RUNNER_PR }}")

    def test_a_persistent_choice_publishes_the_rescue_marker(self):
        steps = self.workflow("ci.yml")["jobs"]["changes"]["steps"]
        mark = next(step for step in steps if step.get("id") == "macos-pool-marker")
        self.assertEqual(mark["if"], "${{ steps.macos-pool.outputs.persistent == 'true' }}")
        upload = next(step for step in steps if step.get("name") == "Upload the persistent pool marker")
        self.assertEqual(upload["with"]["name"], "macos-pool-persistent-${{ github.run_id }}-${{ github.run_attempt }}"
                                                 "-${{ steps.macos-pool.outputs.jobs }}-${{ steps.macos-pool.outputs.runner }}")

    def test_the_picker_reads_the_runs_routing(self):
        changes = self.workflow("ci.yml")["jobs"]["changes"]
        ids = [step.get("id") for step in changes["steps"]]
        for step_id in ("detect", "standalone", "suite"):
            self.assertLess(ids.index(step_id), ids.index("macos-pool"), step_id)
        env = changes["steps"][ids.index("macos-pool")]["env"]
        self.assertEqual(env["RUN_FULL_SUITE"], "${{ steps.suite.outputs.full_suite }}")
        self.assertEqual(env["RUN_CLI"], "${{ steps.detect.outputs.cli }}")
        self.assertNotIn("OWNED_JOBS_PER_RUN", env)
        self.assertEqual(changes["outputs"]["macos_pr_retry_runner"], "${{ steps.macos-pool.outputs.retry_runner }}")

    def lanes(self, name):
        text = (WORKFLOWS / name).read_text()
        return [match.group("lane") for match in PR_ROUTE.finditer(text)]

    def test_every_pr_route_in_the_run_reads_the_choice(self):
        expected = {
            "ci.yml": "needs.changes.outputs.macos_pr_runner || vars.MACOS_RUNNER_PR || 'blacksmith-6vcpu-macos-15'",
            # Compile admission (and its CMUX_PRODUCT_RUNNER mirror) and
            # tests-build-and-lag each test their own owned_jobs key, and are
            # root jobs; the side lanes are not.
            "ci-macos.yml": {warm_lane(), warm_lane("[0]"), root_lane("' lag '")},
            "remote-daemon.yml": {retry_lane("' remote-daemon '")},
        }
        for name, lane in expected.items():
            lanes = self.lanes(name)
            self.assertTrue(lanes, name)
            self.assertEqual(set(lanes), lane if isinstance(lane, set) else {lane}, name)

    def test_a_rerun_of_failed_shards_leaves_the_owned_pool(self):
        shards = self.workflow("ci-macos.yml")["jobs"]["app-host-unit-tests"]
        self.assertEqual(shards["runs-on"], "${{ github.run_attempt == 2 && github.triggering_actor == 'github-actions[bot]' && contains(inputs.pr_owned_jobs, "
                                            "format(' shard-{0} ', matrix.shard)) && (inputs.pr_root_runner || inputs.pr_refused_retry_runner) "
                                            "|| (github.run_attempt > 1 || !contains(inputs.pr_owned_jobs, "
                                            "format(' shard-{0} ', matrix.shard))) && inputs.pr_retry_runner "
                                            "|| inputs.pr_shard_runner || needs.macos-compile-admission.outputs.runner }}")
        wrapper = self.workflow("ci.yml")["jobs"]["claude-wrapper"]["runs-on"]
        self.assertIn("github.event_name == 'pull_request' && github.run_attempt == 2 && github.triggering_actor == 'github-actions[bot]' && contains("
                      "needs.changes.outputs.macos_pr_owned_jobs, ' claude-wrapper ') && "
                      "needs.changes.outputs.macos_pr_refused_retry_runner || github.event_name == 'pull_request' && "
                      "(github.run_attempt > 1 || !contains(needs.changes.outputs.macos_pr_owned_jobs, "
                      "' claude-wrapper ')) && needs.changes.outputs.macos_pr_retry_runner", wrapper)

    def test_callers_pass_the_choice(self):
        jobs = self.workflow("ci.yml")["jobs"]
        runner = "${{ needs.changes.outputs.macos_pr_runner }}"
        xcode = "${{ needs.changes.outputs.macos_pr_xcode_app }}"
        self.assertEqual(jobs["macos"]["with"]["pr_runner"], runner)
        self.assertEqual(jobs["macos"]["with"]["pr_xcode_app"], xcode)
        self.assertEqual(jobs["remote-daemon"]["with"]["pr_runner"], runner)
        retry = "${{ needs.changes.outputs.macos_pr_retry_runner }}"
        for name in ("macos", "remote-daemon"):
            self.assertEqual(jobs[name]["with"]["pr_retry_runner"], retry, name)
        # Only ci-macos.yml runs root jobs; the side lanes keep the pool label.
        self.assertEqual(jobs["macos"]["with"]["pr_root_runner"], "${{ needs.changes.outputs.macos_pr_root_runner }}")
        self.assertNotIn("pr_root_runner", jobs["remote-daemon"]["with"])
        self.assertEqual(jobs["macos"]["with"]["pr_admission_runner"],
                         "${{ needs.changes.outputs.macos_pr_admission_runner }}")
        self.assertNotIn("pr_admission_runner", jobs["remote-daemon"]["with"])
        for name in ("macos", "remote-daemon", "claude-wrapper"):
            needs = jobs[name]["needs"]
            self.assertIn("changes", [needs] if isinstance(needs, str) else needs, name)

    def test_xcode_pins_follow_the_chosen_pool(self):
        # A fork pull request never reads the lane's pin (see
        # tests/test_ci_fork_runner_routing.py); main's dispatch still does.
        same = "github.event.pull_request.head.repo.full_name == github.repository"
        dispatch_lane = (f"(inputs.pr_xcode_app || (github.event_name != 'pull_request' || {same}) "
                         "&& vars.CMUX_CI_XCODE_APP_PR || vars.CMUX_CI_XCODE_APP_MACOS_15)")
        main_dispatch = ("${{ (github.event_name == 'pull_request' || github.event_name == 'workflow_dispatch' "
                         f"&& github.ref == 'refs/heads/main') && {dispatch_lane} || vars.CMUX_CI_XCODE_APP_MACOS_15 }}}}")
        macos = self.workflow("ci-macos.yml")["jobs"]
        for job in ("macos-compile-admission", "tests-build-and-lag"):
            self.assertEqual(macos[job]["env"]["CMUX_CI_XCODE_APP"], main_dispatch, job)

    def test_build_input_fingerprint_keys_on_the_chosen_xcode(self):
        # A run moved to the macOS 15 pool compiles under another Xcode, so it
        # must not skip its compile on a fingerprint taken under the lane's.
        steps = self.workflow("ci.yml")["jobs"]["changes"]["steps"]
        ids = [step.get("id") for step in steps]
        for step_id in ("inputs", "unchanged_inputs"):
            self.assertLess(ids.index("macos-pool"), ids.index(step_id))
            step = steps[ids.index(step_id)]
            self.assertEqual(step["env"]["XCODE_APP"],
                             "${{ steps.macos-pool.outputs.xcode_app || "
                             "github.event.pull_request.head.repo.full_name == github.repository && vars.CMUX_CI_XCODE_APP_PR "
                             "|| vars.CMUX_CI_XCODE_APP_MACOS_15 }}", step_id)

    def test_reusable_inputs_default_to_todays_route(self):
        for name, keys in (("ci-macos.yml", ("pr_runner", "pr_retry_runner", "pr_xcode_app")),
                           ("remote-daemon.yml", ("pr_runner", "pr_retry_runner"))):
            # PyYAML reads the `on:` key as True.
            inputs = self.workflow(name)[True]["workflow_call"]["inputs"]
            for key in keys:
                self.assertEqual((inputs[key]["required"], inputs[key]["default"], inputs[key]["type"]),
                                 (False, "", "string"), (name, key))

    def test_warm_admission_is_attempt_one_only_and_reads_the_merge_base(self):
        changes = self.workflow("ci.yml")["jobs"]["changes"]
        self.assertEqual(changes["outputs"]["macos_pr_admission_runner"],
                         "${{ steps.macos-pool.outputs.admission_runner }}")
        step = next(step for step in changes["steps"] if step.get("id") == "macos-pool")
        self.assertEqual(step["env"]["MERGED_ONTO"],
                         "${{ steps.source-identity.outputs.parent1 || github.event.pull_request.base.sha }}")
        inputs = self.workflow("ci-macos.yml")[True]["workflow_call"]["inputs"]["pr_admission_runner"]
        self.assertEqual((inputs["required"], inputs["default"], inputs["type"]), (False, "", "string"))
        admission = self.workflow("ci-macos.yml")["jobs"]["macos-compile-admission"]
        self.assertIn("github.run_attempt == 1 && inputs.pr_admission_runner && fromJSON(inputs.pr_admission_runner) ||",
                      admission["runs-on"])
        # Only admission reads it; its consumers follow its root label.
        text = (WORKFLOWS / "ci-macos.yml").read_text()
        self.assertEqual(text.count("fromJSON(inputs.pr_admission_runner)"), 2)

    def test_admission_uploads_its_warm_keys_only_once_the_subcommand_exists(self):
        steps = self.workflow("ci-macos.yml")["jobs"]["macos-compile-admission"]["steps"]
        names = [step.get("name") for step in steps]
        keep = names.index("Keep this owned Mac's DerivedData")
        listed = steps[names.index("List the commits this owned Mac starts from warm")]
        upload = steps[names.index("Upload the owned Mac's warm keys")]
        self.assertLess(keep, names.index("List the commits this owned Mac starts from warm"))
        self.assertIs(listed["continue-on-error"], True)
        self.assertIs(upload["continue-on-error"], True)
        self.assertIn("steps.owned-state.outputs.fingerprint != ''", listed["if"])
        self.assertIn('*"owned_build_state.py warm-keys"*', listed["run"])
        self.assertEqual(upload["with"]["name"], "owned-warm-keys-${{ github.run_id }}-${{ github.run_attempt }}")
        self.assertIn("steps.owned-warm-keys.outputs.path != ''", upload["if"])

    def test_the_labeler_runs_from_main_off_by_default(self):
        labeler = self.workflow("ci-owned-warm-labels.yml")
        self.assertEqual(labeler[True]["workflow_run"], {"workflows": ["CI"], "types": ["completed"]})
        self.assertEqual(labeler["permissions"], {})
        job = labeler["jobs"]["label"]
        self.assertIn("vars.CI_OWNED_WARM_LABELS == '1'", job["if"])
        self.assertIn("vars.GLAEDA_ROUTE_APP_ID != ''", job["if"])
        self.assertIn("github.event.workflow_run.head_repository.full_name == github.repository", job["if"])
        self.assertEqual(job["runs-on"], "ubuntu-24.04")
        steps = {step.get("id") or step.get("name"): step for step in job["steps"]}
        self.assertEqual(steps["Checkout trusted labeler"]["with"]["ref"], "main")
        self.assertEqual(steps["keys"]["with"]["name"], "owned-warm-keys-${{ github.event.workflow_run.id }}-"
                                                        "${{ github.event.workflow_run.run_attempt }}")
        self.assertEqual(steps["route-token"]["with"]["permission-administration"], "write")
        self.assertEqual(steps["Label the runner"]["run"], "python3 scripts/ci/owned_warm_labels.py")

    def test_package_tests_stay_off_the_pr_lane(self):
        # swift-package-tests builds the SDK 15 helper and must never move.
        block = yaml.safe_dump(self.workflow("ci-macos.yml")["jobs"]["swift-package-tests"])
        self.assertNotIn("pr_runner", block)


IOS_SIM = "glaeda-ios-sim"
SIGNING_WORKFLOWS = ("ios-testflight.yml", "ios-app-store.yml", "ios-appstore-upload.yml")
IOS_SLOTS = {MINI: 40, ROOT_MINI: 10, IOS_SIM: 2}


def ios_route(snap=None, *, lane="test-ios", requested="auto", variable="", ios_owned="1", owned="1",
              slots=None, ios_version="", device_family="", upload="", called="", ios_since=0, measure=None,
              swift_package="", seed_cache="", tart_fleet="1"):
    calls = []

    def measured():
        calls.append(1)
        if measure is not None:
            return measure()
        return ios_pool.IOSLoad(e2e_pool.PoolLoad(snap), ios_since)

    route = ios_pool.resolve(
        lane, requested, variable, ios_owned=ios_owned, owned=owned,
        owned_slots=json.dumps(IOS_SLOTS if slots is None else slots),
        pr_xcode_app=PR_XCODE, order="", max_queued="",
        ios_version=ios_version, device_family=device_family, upload=upload, called=called,
        swift_package=swift_package, seed_cache=seed_cache, measure=measured, now=NOW, tart_fleet=tart_fleet)
    return route, len(calls)


def sim_fleet(running=0, queued=0, committed=0, **kwargs) -> dict:
    snap = fleet(**kwargs)
    snap["pools"][IOS_SIM] = {"running": running, "queued": queued, "committed": committed}
    return snap


class IOSRouting(unittest.TestCase):
    """ios_runner_pool.py: the E2E rule, owned Macs only, with counted simulator capacity."""

    def test_an_owned_pick_asks_for_the_pool_and_simulator_labels(self):
        route, calls = ios_route(sim_fleet())
        self.assertEqual(calls, 1)
        self.assertTrue(route.persistent)
        # glaeda knows these jobs, so they take the pool label even with a root count.
        self.assertEqual(json.loads(route.runs_on), [MINI, IOS_SIM])
        # mobile-core-package needs no simulator.
        self.assertEqual(json.loads(route.package_runs_on), MINI)
        self.assertEqual(json.loads(route.retry_runs_on), SMALL)

    def test_a_simulator_job_never_asks_for_the_pool_label_alone(self):
        for route in (ios_route(sim_fleet())[0], ios_route(requested="owned")[0],
                      ios_route(lane="screenshots", requested="owned")[0]):
            labels = json.loads(route.runs_on)
            self.assertEqual(labels[-1], IOS_SIM)
            self.assertEqual([label for label in labels if pool.persistent(label)], [MINI])

    def test_simulator_capacity_is_counted_before_routing(self):
        # Two simulator minis; both families need two.
        self.assertTrue(ios_route(sim_fleet(running=0))[0].persistent)
        self.assertFalse(ios_route(sim_fleet(running=1))[0].persistent)
        self.assertFalse(ios_route(sim_fleet(queued=1))[0].persistent)
        self.assertFalse(ios_route(sim_fleet(committed=1))[0].persistent)
        # One family needs one.
        self.assertTrue(ios_route(sim_fleet(running=1), device_family="iphone")[0].persistent)
        self.assertFalse(ios_route(sim_fleet(running=2), device_family="ipad")[0].persistent)
        # Every iOS run since the snapshot is charged two simulators, wherever it went.
        self.assertFalse(ios_route(sim_fleet(), device_family="iphone", ios_since=1)[0].persistent)
        self.assertTrue(ios_route(sim_fleet(), device_family="iphone",
                                  slots={**IOS_SLOTS, IOS_SIM: 3}, ios_since=1)[0].persistent)

    def test_no_simulator_slots_entry_never_routes_or_reads(self):
        route, calls = ios_route(sim_fleet(), slots={MINI: 40, ROOT_MINI: 10})
        self.assertEqual((route.label, route.persistent, calls), (SMALL, False, 0))

    def test_a_busy_pool_keeps_the_ios_variable_not_the_12vcpu_overflow(self):
        snap = sim_fleet(busy=40, small=0, large=0)
        route, calls = ios_route(snap, variable=SMALL)
        self.assertEqual(calls, 1)
        self.assertEqual((route.label, json.loads(route.runs_on), route.persistent), (SMALL, SMALL, False))

    def test_a_run_needs_two_pool_machines_but_no_root_runner(self):
        self.assertEqual(ios_pool.LANES["test-ios"].jobs, 2)
        self.assertFalse(ios_route(sim_fleet(busy=39))[0].persistent)
        self.assertTrue(ios_route(sim_fleet(busy=38))[0].persistent)
        snap = sim_fleet()
        snap["pools"][ROOT_MINI] = {"queued": 0, "running": 10}
        self.assertTrue(ios_route(snap)[0].persistent)

    def test_both_switches_are_needed_and_off_reads_nothing(self):
        for ios_owned, owned in (("", "1"), ("1", ""), ("0", "1"), ("", "")):
            route, calls = ios_route(sim_fleet(), ios_owned=ios_owned, owned=owned)
            self.assertEqual((route.label, route.persistent, calls), (SMALL, False, 0), (ios_owned, owned))

    def test_explicit_runners_and_other_defaults_are_never_rerouted(self):
        for requested in ("blacksmith-6vcpu-macos-26", "tart-ios"):
            route, calls = ios_route(sim_fleet(), requested=requested)
            self.assertEqual((route.label, json.loads(route.runs_on), json.loads(route.package_runs_on),
                              route.retry_label, calls), (requested, requested, requested, requested, 0))
        # MACOS_RUNNER_TESTS naming another pool is honored, as for E2E.
        route, calls = ios_route(sim_fleet(), variable="tart-ios")
        self.assertEqual((route.label, route.persistent, calls), ("tart-ios", False, 0))

    def test_a_tart_request_routes_as_auto_while_the_tart_fleet_is_off(self):
        # 2026-09-25: every Tart VM was offline and tart-ios jobs queued for hours.
        auto, _ = ios_route(sim_fleet())
        for fleet in ("", "0"):
            route, _ = ios_route(sim_fleet(), requested="tart-ios", tart_fleet=fleet)
            self.assertEqual((route.label, route.persistent), (auto.label, auto.persistent), fleet)
        route, calls = ios_route(sim_fleet(), requested="tart-ios", tart_fleet="1")
        self.assertEqual((route.label, calls), ("tart-ios", 0))

    def test_ios_version_upload_release_and_seed_runs_stay_off_the_fleet(self):
        # seed_cache runs in the ci-cache-writer environment with the R2 write keys.
        for kwargs in ({"ios_version": "18.5"}, {"upload": "true"}, {"called": "true"}, {"seed_cache": "true"}):
            route, calls = ios_route(sim_fleet(), **kwargs)
            self.assertEqual((route.label, route.persistent, calls), (SMALL, False, 0), kwargs)
            with self.assertRaises(ValueError):
                ios_route(requested="owned", **kwargs)

    def test_owned_forces_the_pool_without_reading_the_queue(self):
        # CI_IOS_OWNED is not needed, so a proof run can precede it.
        route, calls = ios_route(requested="owned", ios_owned="",
                                 measure=lambda: self.fail("owned must not read the queue"))
        self.assertEqual((json.loads(route.runs_on), json.loads(route.retry_runs_on), calls),
                         ([MINI, IOS_SIM], SMALL, 0))
        with self.assertRaises(ValueError):
            ios_pool.resolve("test-ios", "owned", "", ios_owned="", owned="1",
                             owned_slots=json.dumps({IOS_SIM: 2}), pr_xcode_app="", order="", max_queued="",
                             measure=lambda: None, now=NOW)

    def test_owned_fails_where_the_rescue_would_not_watch_or_no_simulator_mini_exists(self):
        # Without CI_PR_POOL_OWNED=1 ci-owned-pool-rescue.yml never runs, so a
        # forced job left queued would wait for good: fail, never fall back.
        for owned in ("", "0"):
            with self.assertRaisesRegex(ValueError, "CI_PR_POOL_OWNED"):
                ios_route(requested="owned", owned=owned)
        for slots in ({MINI: 40, ROOT_MINI: 10}, {MINI: 40, IOS_SIM: 0}, {}):
            with self.assertRaisesRegex(ValueError, IOS_SIM):
                ios_route(requested="owned", slots=slots)
        with self.assertRaisesRegex(ValueError, "seed_cache"):
            ios_route(requested="owned", seed_cache="true")

    def test_a_package_only_run_needs_no_simulator(self):
        self.assertEqual(ios_pool.sim_jobs("test-ios", "", "CmuxMobileShell"), 0)
        self.assertEqual(ios_pool.sim_jobs("test-ios", "both", ""), 2)
        self.assertEqual(ios_pool.run_jobs("test-ios", "CmuxMobileShell"), 1)
        # Every simulator mini busy, or no simulator slots at all: still owned.
        route, calls = ios_route(sim_fleet(running=2, committed=5), swift_package="CmuxMobileShell", ios_since=3)
        self.assertEqual((route.persistent, json.loads(route.package_runs_on), calls), (True, MINI, 1))
        route, _ = ios_route(sim_fleet(), slots={MINI: 40}, swift_package="CmuxMobileShell")
        self.assertTrue(route.persistent)
        # One pool machine is enough.
        self.assertTrue(ios_route(sim_fleet(busy=39), swift_package="CmuxMobileShell")[0].persistent)
        self.assertFalse(ios_route(sim_fleet(busy=39))[0].persistent)

    def test_the_screenshots_lane_never_reads_the_queue(self):
        route, calls = ios_route(sim_fleet(), lane="screenshots")
        self.assertEqual((route.label, route.persistent, calls), (SMALL, False, 0))
        self.assertEqual(ios_pool.sim_jobs("screenshots", ""), 1)

    def test_a_queue_error_or_no_snapshot_keeps_the_default(self):
        def broken():
            raise RuntimeError("GET /actions/artifacts failed (500)")
        route, calls = ios_route(measure=broken, variable=SMALL)
        self.assertEqual((route.label, route.persistent, calls), (SMALL, False, 1))
        route, calls = ios_route(measure=lambda: ios_pool.IOSLoad(None))
        self.assertEqual((route.label, route.persistent, calls), (SMALL, False, 1))

    def test_ios_runs_since_the_snapshot_are_in_flight_runs_of_both_workflows(self):
        class Client:
            def runs_since(self, workflow, since):
                return {"test-ios.yml": [{"id": 1, "status": "in_progress"}, {"id": 2, "status": "completed"},
                                         {"id": 9, "status": "queued"}],
                        "ios-screenshots.yml": [{"id": 3, "status": "queued"}]}[workflow]
        self.assertEqual(ios_pool.ios_runs_since(Client(), "2026-09-24T10:00:00Z", exclude_run_id=9), 2)

    def test_the_simulator_count_is_a_capability_not_a_pool(self):
        raw = json.dumps(IOS_SLOTS)
        self.assertEqual(pool.slot_problems(raw, PR_XCODE), [])
        self.assertNotIn(IOS_SIM, pool.slots(raw, PR_XCODE))
        self.assertEqual(pool.capability_slots(raw), {IOS_SIM: 2})
        self.assertEqual(pool.capability_slots(json.dumps({IOS_SIM: 0})), {})
        self.assertFalse(pool.persistent(IOS_SIM))

    def test_the_janitor_counts_simulator_jobs_and_markers(self):
        def job(labels, status):
            return {"labels": labels, "status": status, "created_at": "2026-09-24T10:00:00Z", "name": "x"}
        run = {"id": 7, "name": "iOS simulator tests", "path": ".github/workflows/test-ios.yml",
               "status": "in_progress"}
        building = {7: [job([MINI], "in_progress"), job([MINI, IOS_SIM], "in_progress")]}
        snap = janitor.pool_load_snapshot([run], building, now=NOW, markers={7: (MINI, 2)},
                                          capability_markers={7: (IOS_SIM, 2)})
        # The build carries the label; the marker reserves both simulators before they exist.
        self.assertEqual({key: snap["pools"][IOS_SIM][key] for key in ("running", "committed")},
                         {"running": 1, "committed": 2})
        self.assertEqual(snap["pools"][MINI]["running"], 2)
        # Released once as many labelled jobs finished as it declared.
        done = {7: [job([MINI], "completed"), job([MINI, IOS_SIM], "completed"),
                    job([MINI, IOS_SIM], "completed")]}
        snap = janitor.pool_load_snapshot([run], done, now=NOW, capability_markers={7: (IOS_SIM, 2)})
        self.assertNotIn(IOS_SIM, snap["pools"])
        self.assertEqual(janitor.capability_marker({"id": 7, "run_attempt": 1},
                                                   [f"macos-pool-persistent-7-1-2-{MINI}",
                                                    f"macos-pool-persistent-7-1-2-{IOS_SIM}"]), (IOS_SIM, 2))
        self.assertEqual(janitor.owned_marker({"id": 7, "run_attempt": 1},
                                              [f"macos-pool-persistent-7-1-2-{IOS_SIM}",
                                               f"macos-pool-persistent-7-1-2-{MINI}"]), (MINI, 2))

    def test_e2e_still_needs_one_machine_and_its_root_label(self):
        self.assertEqual(e2e_pool.E2E_JOBS, 1)
        limits = e2e_pool.settings("", "", "1", PR_XCODE)
        choice = e2e_pool.decide(e2e_pool.PoolLoad(fleet(busy=0)), limits, now=NOW,
                                 owned_slots={MINI: 40, ROOT_MINI: 10})
        self.assertEqual(choice.root_runner, ROOT_MINI)

    def test_main_prints_outputs(self):
        out = io.StringIO()
        with unittest.mock.patch("sys.stdout", out):
            code = ios_pool.main(["--lane", "test-ios", "--requested", "owned", "--device-family", "iphone",
                                  "--owned", "1", "--owned-slots", json.dumps(IOS_SLOTS),
                                  "--pr-xcode-app", PR_XCODE], env={})
        self.assertEqual(code, 0)
        outputs = dict(line.split("=", 1) for line in out.getvalue().splitlines())
        self.assertEqual(outputs, {"label": MINI, "retry_label": SMALL,
                                   "runs_on": json.dumps([MINI, IOS_SIM]), "package_runs_on": json.dumps(MINI),
                                   "retry_runs_on": json.dumps(SMALL), "persistent": "true", "jobs": "2",
                                   "sim_jobs": "1"})
        err = io.StringIO()
        with unittest.mock.patch("sys.stdout", io.StringIO()), unittest.mock.patch("sys.stderr", err):
            code = ios_pool.main(["--lane", "screenshots", "--requested", "owned", "--upload", "true",
                                  "--pr-xcode-app", PR_XCODE], env={})
        self.assertEqual(code, 1)
        self.assertIn("::error::", err.getvalue())
        out = io.StringIO()
        with unittest.mock.patch("sys.stdout", out):
            ios_pool.main(["--lane", "test-ios", "--swift-package", "CmuxSyncStore"], env={})
        outputs = dict(line.split("=", 1) for line in out.getvalue().splitlines())
        self.assertEqual((outputs["jobs"], outputs["sim_jobs"]), ("1", "0"))

class IOSWiring(unittest.TestCase):
    """The unsigned iOS jobs read ios_runner_pool.py; everything that signs or leaks stays on Blacksmith."""

    RUNS_ON = ("${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || fromJSON(github.run_attempt > 1 "
               "&& needs.runner.outputs.retry_runs_on || needs.runner.outputs.runs_on) }}")

    def workflow(self, name):
        return yaml.safe_load((WORKFLOWS / name).read_text())

    def picker_step(self, runner):
        return next(step for step in runner["steps"] if step.get("id") == "pool")

    def test_test_ios_macos_jobs_take_the_runner_jobs_pool(self):
        jobs = self.workflow("test-ios.yml")["jobs"]
        self.assertEqual(jobs["mobile-core-package"]["runs-on"], self.RUNS_ON.replace(
            "needs.runner.outputs.runs_on", "needs.runner.outputs.package_runs_on"))
        for name in ("ios-simulator-build", "ios-simulator"):
            self.assertEqual(jobs[name]["runs-on"], self.RUNS_ON, name)
        for name in ("mobile-core-package", "ios-simulator-build", "ios-simulator"):
            self.assertIn("runner", jobs[name]["needs"], name)
            self.assertIn("needs.runner.result == 'success'", jobs[name]["if"], name)
        self.assertIn("runner", jobs["ios-tests"]["needs"])
        runner = jobs["runner"]
        self.assertEqual(runner["permissions"], {"contents": "read", "actions": "read"})
        step = self.picker_step(runner)
        self.assertIn("--lane test-ios", step["run"])
        self.assertEqual(step["env"]["REQUESTED_RUNNER"], "${{ inputs.runner }}")
        self.assertEqual(step["env"]["RUNNER_VARIABLE"], "${{ vars.MACOS_RUNNER_TESTS || vars.MACOS_RUNNER_IOS }}")
        self.assertEqual(step["env"]["IOS_OWNED"], "${{ vars.CI_IOS_OWNED }}")
        self.assertEqual(step["env"]["IOS_VERSION"], "${{ inputs.ios_version }}")
        self.assertEqual(step["env"]["DEVICE_FAMILY"], "${{ inputs.device_family }}")
        self.assertEqual(step["env"]["SWIFT_PACKAGE"], "${{ inputs.swift_package }}")
        self.assertEqual(step["env"]["SEED_CACHE"], "${{ inputs.seed_cache }}")
        self.assertIn('--seed-cache "$SEED_CACHE"', step["run"])
        pin = "${{ startsWith(needs.runner.outputs.label, 'glaeda-') && vars.CMUX_CI_XCODE_APP_PR || '' }}"
        for name in ("mobile-core-package", "ios-simulator-build", "ios-simulator"):
            self.assertEqual(jobs[name]["env"]["CMUX_CI_XCODE_APP"], pin, name)
        # PyYAML reads the `on:` key as True.
        options = self.workflow("test-ios.yml")[True]["workflow_dispatch"]["inputs"]["runner"]["options"]
        self.assertEqual(options, ["auto", "blacksmith-6vcpu-macos-26", "owned", "tart-ios"])

    def test_screenshots_take_the_runner_jobs_pool_without_actions_read(self):
        workflow = self.workflow("ios-screenshots.yml")
        jobs = workflow["jobs"]
        self.assertEqual(jobs["screenshots"]["runs-on"], self.RUNS_ON)
        # release.yml calls this with `contents: read` only (#12149).
        self.assertNotIn("permissions", jobs["runner"])
        self.assertEqual(workflow["permissions"], {"contents": "read"})
        step = self.picker_step(jobs["runner"])
        self.assertIn("--lane screenshots", step["run"])
        self.assertEqual(step["env"]["UPLOAD"], "${{ inputs.upload }}")
        self.assertEqual(step["env"]["CALLED"],
                         "${{ !contains(github.workflow_ref, '/.github/workflows/ios-screenshots.yml@') }}")
        self.assertNotIn("GH_TOKEN", step["env"])
        screenshots = jobs["screenshots"]
        self.assertEqual(screenshots["env"]["CMUX_CI_XCODE_APP"],
                         "${{ startsWith(needs.runner.outputs.label, 'glaeda-') && vars.CMUX_CI_XCODE_APP_PR || '' }}")
        capture = next(step for step in screenshots["steps"] if step.get("name") == "Capture screenshots")
        self.assertEqual(capture["env"]["SNAPSHOT_DERIVED_DATA_PATH"],
                         "${{ runner.temp }}/cmux-ios-snapshot-derived-data")

    def test_a_persistent_pick_publishes_the_rescue_marker(self):
        for name in ("test-ios.yml", "ios-screenshots.yml"):
            steps = self.workflow(name)["jobs"]["runner"]["steps"]
            mark = next(step for step in steps if step.get("id") == "marker")
            self.assertEqual(mark["if"], "${{ steps.pool.outputs.persistent == 'true' && github.run_attempt == 1 }}")
            upload = next(step for step in steps if step.get("name") == "Upload the persistent pool marker")
            self.assertEqual(upload["with"]["name"], "macos-pool-persistent-${{ github.run_id }}-${{ github.run_attempt }}"
                                                     "-${{ steps.pool.outputs.jobs }}-${{ steps.pool.outputs.label }}")
            sim = next(step for step in steps if step.get("name") == "Upload the simulator capacity marker")
            self.assertEqual(sim["if"], "${{ steps.marker.outputs.path != '' && steps.pool.outputs.sim_jobs != '0' }}")
            self.assertEqual(sim["with"]["name"], "macos-pool-persistent-${{ github.run_id }}-${{ github.run_attempt }}"
                                                  "-${{ steps.pool.outputs.sim_jobs }}-glaeda-ios-sim")
            self.assertTrue(janitor.may_hold_owned_pool(
                {"run_attempt": 1, "event": "workflow_dispatch", "path": f".github/workflows/{name}",
                 "head_repository": {"id": 1}, "repository": {"id": 1}}, []), name)

    def test_streamed_validation_and_signing_stay_on_blacksmith(self):
        for name in ("ios-streamed-validate.yml", *SIGNING_WORKFLOWS):
            text = (WORKFLOWS / name).read_text()
            for routed in ("python3 scripts/ci/ios_runner_pool.py", "needs.runner.outputs", "vars.CI_IOS_OWNED",
                           "vars.CI_PR_POOL_OWNED"):
                self.assertNotIn(routed, text, f"{name} must not route to an owned Mac")
        validate = self.workflow("ios-streamed-validate.yml")["jobs"]["validate"]
        self.assertEqual(validate["runs-on"], "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || "
                                              "vars.MACOS_RUNNER_IOS || 'blacksmith-6vcpu-macos-26' }}")

    def test_home_secrets_are_removed_however_the_job_ends(self):
        # A reused runner keeps $HOME: every job that writes a secret file there
        # must delete it in a later `if: always()` step.
        writes = re.compile(r'>\s*"\$HOME/(\.secrets/[A-Za-z0-9._-]+)"')
        checked = set()
        for path in sorted(WORKFLOWS.glob("*.y*ml")):
            for job_name, job in (yaml.safe_load(path.read_text()).get("jobs") or {}).items():
                steps = job.get("steps") or []
                for index, step in enumerate(steps):
                    for secret in writes.findall(str(step.get("run") or "")):
                        later = [other for other in steps[index + 1:]
                                 if "always()" in str(other.get("if") or "")
                                 and f'rm -f "$HOME/{secret}"' in str(other.get("run") or "")]
                        self.assertTrue(later, f"{path.name} {job_name}: {secret} is never removed")
                        checked.add(path.name)
        self.assertTrue({"ios-streamed-validate.yml", "iroh-release-gate.yml"} <= checked, checked)


if __name__ == "__main__":
    unittest.main(verbosity=2)
