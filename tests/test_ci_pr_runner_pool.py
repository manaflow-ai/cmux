#!/usr/bin/env python3
"""Tests for scripts/ci/pr_runner_pool.py and its wiring (no network)."""

from __future__ import annotations

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

NOW = dt.datetime(2026, 9, 24, 10, 30, tzinfo=dt.timezone.utc)
SMALL, LARGE, OLD = pool.DEFAULT_RUNNER, pool.LARGE_RUNNER, pool.MACOS_15_RUNNER
XCODE_15 = "/Applications/Xcode_26.3.app"
PINS = {"CMUX_CI_XCODE_APP_MACOS_15": XCODE_15}


FORK_SETTINGS = {"lane": SMALL, "overflow": "", "order": "", "max_queued": ""}


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
           owned_slots="", jobs=pool.MAX_RUN_JOBS, split=""):
    def count_routed(since):
        if isinstance(routed, Exception):
            raise routed
        return routed
    return pool.choose(
        event=event, repo="manaflow-ai/cmux", head_repo=head, default_runner=default,
        overflow=overflow, order=order, max_queued=max_queued, xcode_pins=pins, owned=owned,
        owned_slots=owned_slots, jobs=jobs, split=split,
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
                                              f"retry_runner=\njobs={pool.MAX_RUN_JOBS}\nowned_jobs=\n")
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
        for change in ({"event": "push"}, {"run_attempt": 2}, {"head_repository": {"id": 8}},
                       {"path": ".github/workflows/nightly.yml"}):
            self.assertFalse(janitor.may_hold_owned_pool({**run, **change}, []), change)

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
    return (f"(github.run_attempt > 1 || !contains(inputs.pr_owned_jobs, {key})) && inputs.pr_retry_runner "
            "|| inputs.pr_runner || vars.MACOS_RUNNER_PR || 'blacksmith-6vcpu-macos-15'")
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
    # A compile-only run: admission beside the CLI pipe and remote daemon lanes.
    kwargs.setdefault("jobs", 3)
    return choose(snap, pins=OWNED_PINS, owned=owned, **kwargs)


class OwnedPools(unittest.TestCase):
    """Owned Macs first when switched on, Blacksmith as overflow, never a queue."""

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
        self.assertEqual(jobs(cli="true", remote_daemon="true"), 3)
        self.assertEqual(jobs(unit_suite="true"), 1)
        # A CLI change adds the pipe lane and cli-product-tests after admission.
        self.assertEqual(jobs(unit_suite="true", unit_in_admission="true", cli="true"), 2)
        self.assertEqual(jobs(unit_suite="true", cli="true"), 3)
        # Full suite: seven shards, tests-build-and-lag and cli-product-tests after
        # admission, beside the three side lanes.
        self.assertEqual(jobs(full_suite="true", cli="true", remote_daemon="true"), pool.MAX_RUN_JOBS)
        self.assertEqual(pool.MAX_RUN_JOBS, 12)
        # A CLI-only run still compiles, then tests the bundled CLI.
        self.assertEqual(jobs(macos="false", cli="true"), 2)
        self.assertEqual(jobs(macos="false", claude_wrapper="true", cli="true"), 3)
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
        # have taken the pool is assumed to, and charged REPLAYED_RUN_JOBS (4).
        self.assertEqual(pool.REPLAYED_RUN_JOBS, 4)
        # 11 machines: two newer runs take 8, leaving 3 for this 3-job run.
        self.assertEqual(owned_choice(fleet(), routed=2).runner, MINI)
        self.assertEqual(owned_choice(fleet(), routed=2, jobs=4).runner, LARGE)
        self.assertEqual(owned_choice(fleet(busy=10), routed=1).runner, LARGE)

    def test_newer_runs_with_known_routes_are_charged_what_they_took(self):
        # 5 machines, 5 newer runs. Guessed, the first two replays would close
        # the pool (4 each); known, only the one on the minis counts, at its peak.
        guessed = owned_choice(fleet(), machines=5, jobs=1, routed=5)
        self.assertEqual(guessed.runner, LARGE)
        known = pool.Routed(owned={MINI: 3}, ephemeral=4)
        choice = owned_choice(fleet(), machines=5, jobs=1, routed=known)
        self.assertEqual(choice.runner, MINI)
        self.assertIn("2 of 5 owned machines free", choice.reason)
        self.assertIn(f"3 machine(s) newer runs took on {MINI}", choice.reason)
        self.assertEqual(owned_choice(fleet(), machines=5, jobs=3, routed=known).runner, LARGE)
        # A run still picking is replayed as before, on top of what is known.
        self.assertEqual(owned_choice(fleet(), machines=5, jobs=1,
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
            # Run 6's lookup fails; runs 7 (fork) and 8 (retry) are never looked up.
        }

        def get(path):
            if path not in responses:
                raise RuntimeError(f"GET {path} failed (500)")
            return responses[path]

        client = pool.GitHub("token", "manaflow-ai/cmux")
        with unittest.mock.patch.object(client, "runs_since", return_value=runs), \
                unittest.mock.patch.object(client, "get", side_effect=get):
            routed = client.pull_request_routes_since("2026-09-24T00:00:00Z", exclude_run_id=9)
        self.assertEqual(routed, pool.Routed(unknown=3, owned={MINI: pool.MAX_RUN_JOBS}, ephemeral=3))

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
        self.assertEqual(owned_choice(fleet(age=pool.OWNED_MAX_AGE_MINUTES + 1)).runner, LARGE)
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
        self.assertIn("not JSON", pool.slot_problems("nope")[0])
        self.assertIn("not a JSON object", pool.slot_problems("[1]")[0])

    def test_main_warns_about_bad_slots_only_while_owned_pools_are_on(self):
        for owned, warned in (("1", True), ("", False)):
            with tempfile.TemporaryDirectory() as tmp:
                stdout = io.StringIO()
                env = {"EVENT_NAME": "push", "POOL_OWNED": owned, "OWNED_SLOTS": '{"glaeda-std": 3}',
                       "GITHUB_STEP_SUMMARY": str(Path(tmp, "summary"))}
                with unittest.mock.patch("sys.stdout", stdout):
                    pool.main([], env)
                self.assertEqual("::warning title=CI_OWNED_POOL_SLOTS::" in stdout.getvalue(), warned, owned)
                self.assertEqual("**Warning:**" in Path(tmp, "summary").read_text(), warned, owned)

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
        self.assertEqual(plan.side, ("claude-wrapper", "cli-pipe", "remote-daemon"))
        self.assertEqual(plan.peak, pool.MAX_RUN_JOBS)
        # The unit-ci label runs all seven shards; selected suites one worker, shard 8.
        self.assertEqual(routing(unit_suite="true").after, tuple(f"shard-{index}" for index in range(1, 8)))
        self.assertEqual(routing(unit_suite="true", unit_selectors="Suite").after, ("shard-8",))
        self.assertEqual(routing(unit_suite="true", unit_in_admission="true", unit_selectors="Suite").after, ())
        self.assertEqual(routing(macos="false", cli="true").side, ("cli-pipe",))

    def test_admission_then_gui_jobs_then_light_jobs(self):
        plan = routing(**FULL)
        shards = tuple(f"shard-{index}" for index in range(1, 8))
        self.assertEqual(pool.place(plan, 0), ((), 0))
        # Shards reuse admission's machine once it finishes.
        self.assertEqual(pool.place(plan, 1), (("admission", "shard-1"), 1))
        self.assertEqual(pool.place(plan, 3), (("admission", "shard-1", "shard-2", "shard-3"), 3))
        self.assertEqual(pool.place(plan, 9), (("admission", *shards, "lag", "cli-product"), 9))
        self.assertEqual(pool.place(plan, 12), (("admission", *shards, "lag", "cli-product", "cli-pipe",
                                                 "remote-daemon", "claude-wrapper"), 12))
        self.assertEqual(pool.owned_peak(plan), 12)
        self.assertEqual(pool.place(routing(unit_suite="true", unit_selectors="Suite"), 1),
                         (("admission", "shard-8"), 1))

    def test_gui_jobs_stay_off_when_switched_off(self):
        plan = routing(**FULL)
        self.assertEqual(pool.place(plan, 1, gui=False), (("admission", "cli-product"), 1))
        self.assertEqual(pool.place(plan, 2, gui=False), (("admission", "cli-product", "cli-pipe"), 2))
        everything = ("admission", "cli-product", "cli-pipe", "remote-daemon", "claude-wrapper")
        self.assertEqual(pool.place(plan, 12, gui=False), (everything, 4))
        self.assertEqual(pool.owned_peak(plan, gui=False), 4)
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

    def output(self, *, busy, split="1", gui="", **routing_env):
        with tempfile.TemporaryDirectory() as tmp:
            snapshot = Path(tmp, "snap.json")
            fresh = fleet(busy=busy)
            fresh["generated_at"] = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            snapshot.write_text(json.dumps(fresh))
            out = Path(tmp, "out")
            env = {"EVENT_NAME": "pull_request", "GITHUB_REPOSITORY": "manaflow-ai/cmux",
                   "HEAD_REPO": "manaflow-ai/cmux", "DEFAULT_RUNNER": SMALL, "POOL_OWNED": "1",
                   "POOL_OWNED_SPLIT": split, "POOL_OWNED_GUI": gui, "OWNED_SLOTS": json.dumps({MINI: 11}),
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
        # 11 machines for a 12-machine run: the last light job overflows.
        most = self.output(busy=0, **full)
        self.assertEqual(most["owned_jobs"].split()[-3:], ["cli-product", "cli-pipe", "remote-daemon"])
        self.assertEqual(most["jobs"], "11")
        # GUI jobs off: only admission and the light jobs.
        light = self.output(busy=9, gui="0", **full)
        self.assertEqual((light["owned_jobs"], light["jobs"]), (" admission cli-product cli-pipe ", "2"))
        # Selected suites a compile admission would run itself move to shard 8.
        suites = self.output(busy=0, RUN_UNIT_SUITE="true", RUN_UNIT_IN_ADMISSION="true",
                             RUN_UNIT_SELECTORS="cmuxTests/SomeSuite")
        self.assertEqual(suites["owned_jobs"], " admission shard-8 ")
        # Split off: the whole-run rule over the owned-eligible jobs only.
        self.assertEqual(self.output(busy=7, split="", gui="0", **full)["runner"], MINI)
        off = self.output(busy=8, split="", gui="0", **full)
        self.assertEqual((off["runner"], off["owned_jobs"]), (LARGE, ""))


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
            # tests-build-and-lag each test their own owned_jobs key.
            "ci-macos.yml": {retry_lane("' admission '"), retry_lane("' lag '")},
            "cli-pipe-regressions.yml": {retry_lane("' cli-pipe '")},
            "remote-daemon.yml": {retry_lane("' remote-daemon '")},
        }
        for name, lane in expected.items():
            lanes = self.lanes(name)
            self.assertTrue(lanes, name)
            self.assertEqual(set(lanes), lane if isinstance(lane, set) else {lane}, name)

    def test_a_rerun_of_failed_shards_leaves_the_owned_pool(self):
        shards = self.workflow("ci-macos.yml")["jobs"]["app-host-unit-tests"]
        self.assertEqual(shards["runs-on"], "${{ (github.run_attempt > 1 || !contains(inputs.pr_owned_jobs, "
                                            "format(' shard-{0} ', matrix.shard))) && inputs.pr_retry_runner "
                                            "|| needs.macos-compile-admission.outputs.runner }}")
        wrapper = self.workflow("ci.yml")["jobs"]["claude-wrapper"]["runs-on"]
        self.assertIn("(github.run_attempt > 1 || !contains(needs.changes.outputs.macos_pr_owned_jobs, "
                      "' claude-wrapper ')) && needs.changes.outputs.macos_pr_retry_runner", wrapper)

    def test_callers_pass_the_choice(self):
        jobs = self.workflow("ci.yml")["jobs"]
        runner = "${{ needs.changes.outputs.macos_pr_runner }}"
        xcode = "${{ needs.changes.outputs.macos_pr_xcode_app }}"
        self.assertEqual(jobs["macos"]["with"]["pr_runner"], runner)
        self.assertEqual(jobs["macos"]["with"]["pr_xcode_app"], xcode)
        self.assertEqual(jobs["cli"]["with"]["pr_runner"], runner)
        self.assertEqual(jobs["cli"]["with"]["pr_xcode_app"], xcode)
        self.assertEqual(jobs["remote-daemon"]["with"]["pr_runner"], runner)
        retry = "${{ needs.changes.outputs.macos_pr_retry_runner }}"
        for name in ("macos", "cli", "remote-daemon"):
            self.assertEqual(jobs[name]["with"]["pr_retry_runner"], retry, name)
        for name in ("macos", "cli", "remote-daemon", "claude-wrapper"):
            needs = jobs[name]["needs"]
            self.assertIn("changes", [needs] if isinstance(needs, str) else needs, name)

    def test_xcode_pins_follow_the_chosen_pool(self):
        # A fork pull request never reads the lane's pin (see
        # tests/test_ci_fork_runner_routing.py); main's dispatch still does.
        same = "github.event.pull_request.head.repo.full_name == github.repository"
        lane = f"(inputs.pr_xcode_app || {same} && vars.CMUX_CI_XCODE_APP_PR || vars.CMUX_CI_XCODE_APP_MACOS_15)"
        dispatch_lane = (f"(inputs.pr_xcode_app || (github.event_name != 'pull_request' || {same}) "
                         "&& vars.CMUX_CI_XCODE_APP_PR || vars.CMUX_CI_XCODE_APP_MACOS_15)")
        pin = f"${{{{ github.event_name == 'pull_request' && {lane} || vars.CMUX_CI_XCODE_APP_MACOS_15 }}}}"
        main_dispatch = ("${{ (github.event_name == 'pull_request' || github.event_name == 'workflow_dispatch' "
                         f"&& github.ref == 'refs/heads/main') && {dispatch_lane} || vars.CMUX_CI_XCODE_APP_MACOS_15 }}}}")
        macos = self.workflow("ci-macos.yml")["jobs"]
        for job in ("macos-compile-admission", "tests-build-and-lag"):
            self.assertEqual(macos[job]["env"]["CMUX_CI_XCODE_APP"], main_dispatch, job)
        cli = self.workflow("cli-pipe-regressions.yml")["jobs"]["cli-pipe-regressions"]
        self.assertEqual(cli["env"]["CMUX_CI_XCODE_APP"], pin)

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
                           ("cli-pipe-regressions.yml", ("pr_runner", "pr_retry_runner", "pr_xcode_app")),
                           ("remote-daemon.yml", ("pr_runner", "pr_retry_runner"))):
            # PyYAML reads the `on:` key as True.
            inputs = self.workflow(name)[True]["workflow_call"]["inputs"]
            for key in keys:
                self.assertEqual((inputs[key]["required"], inputs[key]["default"], inputs[key]["type"]),
                                 (False, "", "string"), (name, key))

    def test_package_tests_stay_off_the_pr_lane(self):
        # swift-package-tests builds the SDK 15 helper and must never move.
        block = yaml.safe_dump(self.workflow("ci-macos.yml")["jobs"]["swift-package-tests"])
        self.assertNotIn("pr_runner", block)


if __name__ == "__main__":
    unittest.main(verbosity=2)
