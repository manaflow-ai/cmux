#!/usr/bin/env python3
"""cmux-next's macOS cascade: idle minis, Blacksmith 12 vCPU, 6 vCPU, hosted macos-26, then the minis' queue.

The placement decides from live counts (Blacksmith's scale-set runner groups)
and the janitor's queued counts and waits; the workflow's runs-on reads its outputs.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import contextlib
import io
import itertools
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts/ci"
WORKFLOW = ROOT / ".github/workflows/cmux-next.yml"
LARGE, SMALL, HOSTED = "blacksmith-12vcpu-macos-26", "blacksmith-6vcpu-macos-26", "macos-26"
MACOS_15 = "blacksmith-6vcpu-macos-15"
SIDE = "glaeda-side-light-xcode-26.6"
GUI = "glaeda-gui-std-xcode-26.6"
CASCADED = ("fast-tier", "swift-canary", "cmux-scheme-compile", "release-compile")
PROMOTE = "glaeda-promote-side-trusted-std-xcode-26.6"
GUI_JOBS = ("swift-test", "daemon-test", "generated-files")
ALL_JOBS = "fast-tier swift-canary cmux-scheme-compile release-compile swift-test daemon-test generated-files"
NOW = dt.datetime(2026, 10, 19, 22, 0, tzinfo=dt.timezone.utc)
BOT = "github-actions[bot]"

sys.path.insert(0, str(ROOT / "tests"))
from test_seed_derived_data import evaluate, github_context  # noqa: E402


def load(name: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


cascade = load("next_macos_cascade")
placement = load("side_lane_placement")


def env(**overrides: str) -> dict:
    return {"SIDE_LABEL": SIDE, "JOBS": ALL_JOBS, "GITHUB_RUN_ATTEMPT": "1",
            "CASCADE_RUNS": " fast-tier swift-canary cmux-scheme-compile ", **overrides}


def snapshot(minutes_old: float = 2, oldest: dict | None = None, hosted: tuple[int, int] = (0, 0),
             **queued: int) -> dict:
    """A janitor snapshot; `oldest` maps "large"/"small" to oldest_queued_minutes, `hosted` is
    macos-26's (queued, running)."""
    generated = (NOW - dt.timedelta(minutes=minutes_old)).strftime("%Y-%m-%dT%H:%M:%SZ")
    oldest = oldest or {}
    return {"generated_at": generated,
            "pools": {LARGE: {"queued": queued.get("large", 0), "running": 0,
                              "oldest_queued_minutes": oldest.get("large", 0)},
                      SMALL: {"queued": queued.get("small", 0), "running": 0,
                              "oldest_queued_minutes": oldest.get("small", 0)},
                      HOSTED: {"queued": hosted[0], "running": hosted[1], "oldest_queued_minutes": 0}}}


def none_placed(**jobs: tuple) -> dict:
    return {LARGE: (), SMALL: (), **jobs}


class Counts(unittest.TestCase):
    GROUPS = [{"id": 15, "name": f"Blacksmith scale sets - {LARGE}"},
              {"id": 10, "name": f"Blacksmith scale sets - {SMALL}"},
              {"id": 8, "name": "Blacksmith scale sets - blacksmith-6vcpu-macos-15"}]

    def test_in_flight_counts_each_labels_online_runners(self):
        runners = {15: [{"status": "online", "busy": True}] * 4 + [{"status": "offline", "busy": False}] * 3,
                   10: [{"status": "online", "busy": True}] * 9 + [{"status": "online", "busy": False}],
                   8: [{"status": "online", "busy": True}] * 7}
        # The macOS 15 label draws on the same organization pool, so its runners count too.
        self.assertEqual(cascade.in_flight(self.GROUPS, runners.__getitem__),
                         {LARGE: 4, SMALL: 10, MACOS_15: 7})
        # Its group is optional: without it the snapshot's running jobs stand in (with_running()).
        self.assertEqual(cascade.in_flight(self.GROUPS[:2], runners.__getitem__), {LARGE: 4, SMALL: 10})

    def test_a_missing_scale_set_group_counts_nothing(self):
        self.assertIsNone(cascade.in_flight(self.GROUPS[1:], lambda group: []))

    def test_queued_comes_from_a_fresh_snapshot_only(self):
        self.assertEqual(cascade.queued(snapshot(large=3, small=1), NOW), {LARGE: 3, SMALL: 1})
        self.assertIsNone(cascade.queued(snapshot(minutes_old=cascade.QUEUE_SNAPSHOT_MINUTES + 1), NOW))
        self.assertIsNone(cascade.queued({"generated_at": "not a time", "pools": {}}, NOW))
        self.assertIsNone(cascade.queued(None, NOW))
        # A label the janitor saw nothing on has nothing queued.
        self.assertEqual(cascade.queued({"generated_at": "2026-10-19T21:58:00Z", "pools": {}}, NOW),
                         {LARGE: 0, SMALL: 0})

    def test_the_pools_other_labels_count_from_the_snapshot(self):
        shot = snapshot(large=1, small=2)
        shot["pools"][MACOS_15] = {"queued": 4, "running": 3}
        shot["pools"]["glaeda-side-std-xcode-26.6"] = {"queued": 121, "running": 10}
        # Queued counts every Blacksmith macOS label, never an owned or hosted one.
        self.assertEqual(cascade.queued(shot, NOW), {LARGE: 1, SMALL: 2, MACOS_15: 4})
        self.assertEqual(cascade.pool_queued(cascade.queued(shot, NOW)), 7)
        # A label no visible scale-set group counted takes the snapshot's running jobs; a live count wins.
        self.assertEqual(cascade.with_running({LARGE: 0, SMALL: 5}, shot, NOW), {LARGE: 0, SMALL: 5, MACOS_15: 3})
        self.assertEqual(cascade.with_running({LARGE: 0, SMALL: 5, MACOS_15: 1}, shot, NOW),
                         {LARGE: 0, SMALL: 5, MACOS_15: 1})
        self.assertEqual(cascade.with_running({LARGE: 0, SMALL: 5}, None, NOW), {LARGE: 0, SMALL: 5})
        self.assertEqual((cascade.vcpus(LARGE), cascade.vcpus(SMALL), cascade.vcpus(MACOS_15)), (12, 6, 6))
        self.assertFalse(cascade.pool_label(HOSTED) or cascade.pool_label("blacksmith-4vcpu-ubuntu-2404"))


class Cascade(unittest.TestCase):
    def test_twelve_vcpu_first_then_six_then_the_queue(self):
        # 30 of the pool's 60 vCPU are free: two 12 vCPU jobs (this run's share), then one 6 vCPU job.
        placed = cascade.cascade(CASCADED, {LARGE: 1, SMALL: 3}, {LARGE: 0, SMALL: 0})
        self.assertEqual(placed, none_placed(**{LARGE: ("fast-tier", "swift-canary"),
                                                SMALL: ("cmux-scheme-compile",)}))

    def test_a_queue_anywhere_sends_the_jobs_to_six_not_twelve(self):
        # A 12 vCPU job needs twelve vCPUs freed at once; while 6 vCPU jobs queue, they take each one first.
        placed = cascade.cascade(CASCADED[:2], {LARGE: 0, SMALL: 2}, {LARGE: 0, SMALL: 1})
        self.assertEqual(placed, none_placed(**{SMALL: CASCADED[:2]}))
        # A queue on the macOS 15 label is the same pool's queue.
        placed = cascade.cascade(CASCADED[:2], {LARGE: 0, SMALL: 2}, {LARGE: 0, SMALL: 0, MACOS_15: 1})
        self.assertEqual(placed, none_placed(**{SMALL: CASCADED[:2]}))

    def test_twelve_vcpu_waits_behind_a_pool_its_own_count_calls_free(self):
        """Runs 40386035282 and 40386506758 (2026-10-26): the placement read 12 vCPU as "0 in flight + 0
        queued of 5" and 6 vCPU as "9 in flight + 3 queued of 10", sent both DEV Release compiles to 12 vCPU,
        and they queued from 19:25Z to 20:42Z and 20:52Z. 6 vCPU's nine are 54 of the pool's 60 vCPU."""
        live, waiting = {LARGE: 0, SMALL: 9}, {LARGE: 0, SMALL: 3}
        self.assertEqual(cascade.cascade(("cmux-scheme-compile",), live, waiting), none_placed())
        self.assertEqual(cascade.retry_label(live, waiting), "")
        result = cascade.place(env(CASCADE_RUNS=" cmux-scheme-compile "), (), live, waiting)
        self.assertEqual(result.jobs, none_placed())
        self.assertIn("pool 72 of 60 vCPU in flight or queued", result.why)
        self.assertIn("cmux-scheme-compile stay queued on the owned label", result.why)
        # The pool's other label holds vCPUs as well: five 6 vCPU jobs on each fill it.
        self.assertEqual(cascade.cascade(("cmux-scheme-compile",), {LARGE: 0, SMALL: 5, MACOS_15: 5},
                                         {LARGE: 0, SMALL: 0}), none_placed())
        # With room for twelve and nothing queued anywhere, 12 vCPU still comes first.
        self.assertEqual(cascade.cascade(("cmux-scheme-compile",), {LARGE: 0, SMALL: 8}, {LARGE: 0, SMALL: 0}),
                         none_placed(**{LARGE: ("cmux-scheme-compile",)}))

    def test_a_stalled_twelve_vcpu_queue_holds_no_six_vcpu_room(self):
        # 2026-10-26 20:38Z to 20:47Z: six jobs queued on 12 vCPU for 78 to 83 minutes while 6 vCPU ran
        # seven and five with no queue, so a 12 vCPU job that waits does not hold the pool's vCPUs.
        self.assertEqual(cascade.pool_room({LARGE: 0, SMALL: 7}, {LARGE: 6, SMALL: 0}), 18)
        placed = cascade.cascade(CASCADED[:2], {LARGE: 0, SMALL: 7}, {LARGE: 6, SMALL: 0})
        self.assertEqual(placed, none_placed(**{SMALL: CASCADED[:2]}))

    def test_one_run_takes_at_most_max_per_run_slots_on_a_label(self):
        # A burst of runs in one snapshot window sees the same free slots; each takes few of them.
        placed = cascade.cascade(CASCADED, {LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0})
        self.assertEqual(cascade.MAX_PER_RUN, 2)
        self.assertEqual(placed, none_placed(**{LARGE: ("fast-tier", "swift-canary"),
                                                SMALL: ("cmux-scheme-compile", "release-compile")}))

    def test_queued_jobs_take_free_slots_first(self):
        # Five free 12 vCPU slots on the runner count, but five jobs already wait for them.
        placed = cascade.cascade(CASCADED, {LARGE: 0, SMALL: 10}, {LARGE: 5, SMALL: 0})
        self.assertEqual(placed, none_placed())

    def test_retry_goes_to_the_least_loaded_label(self):
        self.assertEqual(cascade.retry_label({LARGE: 1, SMALL: 4}, {LARGE: 1, SMALL: 0}), SMALL)
        # No free slot anywhere: no Blacksmith label, so the overflow waits on the owned label.
        self.assertEqual(cascade.retry_label({LARGE: 5, SMALL: 10}, {LARGE: 6, SMALL: 0}), "")
        self.assertEqual(cascade.retry_label({LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0}), LARGE)
        # Ten 6 vCPU jobs fill the pool: 12 vCPU's five idle slots are no room.
        self.assertEqual(cascade.retry_label({LARGE: 0, SMALL: 10}, {LARGE: 0, SMALL: 0}), "")

    def test_a_full_fleet_overflows_to_6_vcpu_whose_slots_turn_over(self):
        # 2026-10-20 01:04-02:35Z: other workflows' long jobs held 12 vCPU's five slots. The
        # overflow sent 25 cmux-next jobs there by load ratio and none started (14 queued over
        # 15 minutes, up to 89, then cancelled) while 6 vCPU started 69 at a median 2.5 minutes.
        # Both full: never a Blacksmith queue (5+ hour waits on 12 vCPU, 2026-10-20); the owned label.
        self.assertEqual(cascade.retry_label({LARGE: 5, SMALL: 10}, {LARGE: 0, SMALL: 0}), "")
        self.assertEqual(cascade.retry_label({LARGE: 0, SMALL: 9}, {LARGE: 0, SMALL: 0}), SMALL)
        # The placement log of run 39358219316: 12 vCPU 5 + 1 of 5, 6 vCPU 10 + 4 of 10.
        self.assertEqual(cascade.retry_label({LARGE: 5, SMALL: 10}, {LARGE: 1, SMALL: 4}), "")
        self.assertEqual(cascade.retry_label({LARGE: 7, SMALL: 30}, {LARGE: 0, SMALL: 9}), "")
        # A stalled label is never the overflow, however free it looks.
        self.assertEqual(cascade.retry_label({LARGE: 0, SMALL: 9}, {LARGE: 0, SMALL: 0}, (LARGE,)), SMALL)
        self.assertEqual(cascade.retry_label({LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0}, (LARGE, SMALL)), "")


class Place(unittest.TestCase):
    def test_bot_rerun_can_place_after_a_refusal_but_a_person_rerun_stays_owned(self):
        result = cascade.place(env(GITHUB_RUN_ATTEMPT="2", GITHUB_TRIGGERING_ACTOR=BOT), (),
                               {LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0})
        self.assertTrue(result.jobs[LARGE] or result.jobs[SMALL])
        person = cascade.place(env(GITHUB_RUN_ATTEMPT="2", GITHUB_TRIGGERING_ACTOR="teamleaderleo"), (),
                               {LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0})
        self.assertEqual(person.why, "a person re-run keeps its own route")

    def test_jobs_an_idle_mini_took_and_gui_jobs_stay_off_blacksmith(self):
        result = cascade.place(env(), ("fast-tier",), {LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0})
        self.assertEqual(result.jobs, none_placed(**{LARGE: ("swift-canary", "cmux-scheme-compile")}))
        # 12 vCPU is now 2 of 5 with this run's jobs, 6 vCPU 0 of 10.
        self.assertEqual(result.retry_runner, SMALL)

    def test_an_idle_mini_given_a_job_that_does_not_run_still_takes_one_that_does(self):
        # fast-tier is on its fast-lane runner (not in CASCADE_RUNS), yet idle_placement named it for
        # the one idle mini: that mini still takes swift-canary, and only the scheme compile pays Blacksmith.
        result = cascade.place(env(CASCADE_RUNS=" swift-canary cmux-scheme-compile "), ("fast-tier",),
                               {LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0})
        self.assertEqual(result.jobs, none_placed(**{LARGE: ("cmux-scheme-compile",)}))

    def test_only_jobs_that_run_on_this_route_take_a_slot(self):
        # fast-tier on its own fast-lane runner, or a canary the pull request's labels skip, spends no slot.
        result = cascade.place(env(CASCADE_RUNS=" cmux-scheme-compile "), (), {LARGE: 4, SMALL: 0},
                               {LARGE: 0, SMALL: 0})
        self.assertEqual(result.jobs, none_placed(**{LARGE: ("cmux-scheme-compile",)}))
        self.assertEqual(cascade.place(env(CASCADE_RUNS=""), (), {LARGE: 0, SMALL: 0},
                                       {LARGE: 0, SMALL: 0}).jobs, none_placed())
        # A Release compile that does not run (a same-repository PR without full-ci) takes no slot either.
        result = cascade.place(env(CASCADE_RUNS=" cmux-scheme-compile "), (), {LARGE: 0, SMALL: 0},
                               {LARGE: 0, SMALL: 0})
        self.assertNotIn("release-compile", result.jobs[LARGE] + result.jobs[SMALL])

    def test_a_release_compile_no_idle_mini_took_overflows_to_blacksmith(self):
        """2026-10-21 ~20:10Z: 76 Release compiles queued on the minis. The CEF shim check it skips off a
        mini is advisory (a Blacksmith re-run already skips it)."""
        self.assertIn("release-compile", cascade.CASCADE_JOBS)
        runs = " swift-canary cmux-scheme-compile release-compile "
        result = cascade.place(env(CASCADE_RUNS=runs), (), {LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0})
        self.assertEqual(result.jobs, none_placed(**{LARGE: ("swift-canary", "cmux-scheme-compile"),
                                                     SMALL: ("release-compile",)}))
        # Two idle minis take the canary and the scheme compile; the Release compile gets 12 vCPU.
        result = cascade.place(env(CASCADE_RUNS=runs), ("fast-tier", "swift-canary"), {LARGE: 0, SMALL: 0},
                               {LARGE: 0, SMALL: 0})
        self.assertEqual(result.jobs, none_placed(**{LARGE: ("release-compile",)}))

    def test_a_feat_push_release_compile_keeps_an_idle_promotion_mini(self):
        # Attempt 1 of a feat-cmux-next push compiles on vars.CI_NEXT_PROMOTE_POOL; while one of its
        # runners is idle the Release compile stays there and takes no side mini's share or Blacksmith slot.
        runs = " cmux-scheme-compile release-compile "
        free = {LARGE: 0, SMALL: 0}
        idle = cascade.place(env(CASCADE_RUNS=runs, PROMOTE_LABEL=PROMOTE), (), free, free, promote_busy=False)
        self.assertEqual(idle.jobs, none_placed(**{LARGE: ("cmux-scheme-compile",)}))
        # One idle side mini takes the scheme compile, not the promoted Release compile's turn.
        self.assertEqual(cascade.place(env(CASCADE_RUNS=runs, PROMOTE_LABEL=PROMOTE), ("fast-tier",), free, free,
                                       promote_busy=False).jobs, none_placed())

    def test_a_feat_push_release_compile_takes_the_runs_first_slot(self):
        # Run 40298786351 (2026-10-26 09:21Z): 6 vCPU had room, but MAX_PER_RUN went to fast-tier and the
        # scheme compile ahead of it in JOBS, and the Release compile queued on the owned label.
        runs = " fast-tier cmux-scheme-compile release-compile "
        live, waiting = {LARGE: 0, SMALL: 5}, {LARGE: 7, SMALL: 0}
        stalled = cascade.Seen(waits={LARGE: 227.0}, age=1.0)
        before = cascade.place(env(CASCADE_RUNS=runs), (), live, waiting, stalled)
        self.assertEqual(before.jobs[SMALL], ("fast-tier", "cmux-scheme-compile"))
        first = env(CASCADE_RUNS=runs, FIRST_JOBS="release-compile")
        self.assertEqual(cascade.place(first, (), live, waiting, stalled).jobs[SMALL], ("release-compile", "fast-tier"))
        # The idle minis are spent on the run's other jobs first: one idle mini, and the Release compile still
        # has its slot (fast-tier races for the mini); as many idle minis as side jobs, and nothing cascades.
        one = cascade.place(first, ("fast-tier",), live, waiting, stalled)
        self.assertEqual(one.jobs[SMALL], ("release-compile", "cmux-scheme-compile"))
        three = cascade.place(first, ("fast-tier", "swift-canary", "cmux-scheme-compile"), live, waiting, stalled)
        self.assertEqual(three.jobs, none_placed())
        two = cascade.place(first, ("fast-tier", "swift-canary"), live, waiting, stalled)
        self.assertEqual(two.jobs[SMALL], ("release-compile",))

    def test_the_placement_names_the_first_jobs_only_on_a_feat_push_attempt_1(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        place = next(step for step in jobs["macos-placement"]["steps"] if step.get("id") == "place")
        expression = place["env"]["FIRST_JOBS"]
        for event, ref, attempt, expected in (("push", "refs/heads/feat-cmux-next", "1", "release-compile"),
                                              ("push", "refs/heads/feat-cmux-next", "2", ""),
                                              ("push", "refs/heads/next-batch/abc", "1", ""),
                                              ("pull_request", "refs/pull/1/merge", "1", "")):
            with self.subTest(event=event, ref=ref, attempt=attempt):
                context = {"github": {"event_name": event, "ref": ref, "run_attempt": attempt}}
                self.assertEqual(evaluate(expression, context), expected)

    def test_a_busy_promotion_mini_sends_the_feat_push_release_compile_to_blacksmith_first(self):
        runs = " swift-canary cmux-scheme-compile release-compile "
        free = {LARGE: 0, SMALL: 0}
        busy = cascade.place(env(CASCADE_RUNS=runs, PROMOTE_LABEL=PROMOTE), (), free, free, promote_busy=True)
        # It gates the nightly-next request, so it goes first; it never counts against an idle side mini.
        self.assertEqual(busy.jobs, none_placed(**{LARGE: ("release-compile", "swift-canary"),
                                                   SMALL: ("cmux-scheme-compile",)}))
        busy = cascade.place(env(CASCADE_RUNS=runs, PROMOTE_LABEL=PROMOTE), ("fast-tier", "swift-canary", "x"),
                             free, free, promote_busy=True)
        self.assertEqual(busy.jobs, none_placed(**{LARGE: ("release-compile",)}))

    def test_a_partly_free_fleet_splits_and_leaves_the_rest_queued(self):
        result = cascade.place(env(), (), {LARGE: 1, SMALL: 5}, {LARGE: 0, SMALL: 0})
        self.assertEqual(result.jobs, none_placed(**{LARGE: ("fast-tier",), SMALL: ("swift-canary",)}))
        self.assertIn("cmux-scheme-compile stay queued on the owned label", result.why)

    def test_the_overflow_counts_the_slots_this_run_just_took(self):
        # The pool had one 6 vCPU job's room and this run's fast-tier took it: the overflow has none left.
        result = cascade.place(env(), (), {LARGE: 0, SMALL: 9}, {LARGE: 0, SMALL: 0})
        self.assertEqual(result.jobs, none_placed(**{SMALL: ("fast-tier",)}))
        self.assertEqual(result.retry_runner, "")

    def test_a_feeds_run_never_takes_hosted(self):
        """Leo, 2026-10-27: "THE GITHUB HOSTED MACS / ARE THE SLOWEST THINGS". #25798 sent a DEV daily's compile
        to hosted macos-26 while Blacksmith was full; with hosted free it now keeps the owned label."""
        full = {LARGE: 5, SMALL: 10}
        seen = cascade.Seen(waits={LARGE: 0.0, SMALL: 0.0})
        dev = env(CASCADE_RUNS=" cmux-scheme-compile ", FRESH_JOBS="cmux-scheme-compile")
        self.assertEqual(cascade.place(dev, (), full, {LARGE: 0, SMALL: 0}, seen).jobs, none_placed())
        # A PR's scheme compile keeps the owned label too.
        self.assertEqual(cascade.place(env(CASCADE_RUNS=" cmux-scheme-compile "), (), full, {LARGE: 0, SMALL: 0},
                                       seen).jobs, none_placed())
        # Neither a feed's run nor a PR's run sends a job to hosted macos-26: the cascade has no hosted route.
        both = " fast-tier swift-canary cmux-scheme-compile "
        self.assertEqual(cascade.place(env(CASCADE_RUNS=both, FRESH_JOBS="cmux-scheme-compile"), (), full,
                                       {LARGE: 0, SMALL: 0}, seen).jobs, none_placed())
        self.assertEqual(cascade.place(env(CASCADE_RUNS=both), (), full, {LARGE: 0, SMALL: 0}, seen).jobs,
                         none_placed())
        # A free Blacksmith slot still comes first.
        self.assertEqual(cascade.place(dev, (), {LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0}, seen).jobs,
                         none_placed(**{LARGE: ("cmux-scheme-compile",)}))
        # A push's Release compile, whose runs-on reads no hosted route, still takes 6 vCPU unread.
        push = env(CASCADE_RUNS=" release-compile ", FRESH_JOBS="release-compile")
        self.assertEqual(cascade.place(push, (), None, None).jobs, none_placed(**{SMALL: ("release-compile",)}))

    def test_unread_counts_place_nothing(self):
        self.assertEqual(cascade.place(env(), (), None, None).jobs, none_placed())
        result = cascade.place(env(), (), {LARGE: 0, SMALL: 0}, None)
        self.assertEqual(result.jobs, none_placed())
        # Without the queue count no slot is known free: the overflow keeps the owned label.
        self.assertEqual(result.retry_runner, "")

    def test_unread_counts_send_a_feeds_compile_to_the_last_resort(self):
        """2026-10-26: the route token read 403 and the snapshot was stale, so DEV daily 40415036753's Release
        compile (cmux-scheme-compile) queued on the owned label behind ~260 jobs and the DEV feed fell 100
        minutes behind. A feed's compile (FRESH_JOBS) takes 6 vCPU when the counts cannot be read."""
        dev = env(CASCADE_RUNS=" cmux-scheme-compile ", FRESH_JOBS="cmux-scheme-compile")
        for live, waiting in ((None, None), ({LARGE: 0, SMALL: 0}, None)):
            with self.subTest(live=live, waiting=waiting):
                # A DEV compile takes 6 vCPU too, never hosted macos-26 (Leo, 2026-10-27: hosted Macs are the
                # slowest); a stalled 6 vCPU queue keeps it on the owned label (below).
                result = cascade.place(dev, (), live, waiting)
                self.assertEqual(result.jobs, none_placed(**{SMALL: ("cmux-scheme-compile",)}))
                self.assertEqual(result.retry_runner, "")
                self.assertIn(f"take `{SMALL}`", result.why)
        push = env(CASCADE_RUNS=" fast-tier cmux-scheme-compile release-compile ", FRESH_JOBS="release-compile")
        self.assertEqual(cascade.place(push, (), None, None).jobs, none_placed(**{SMALL: ("release-compile",)}))
        # An idle mini is spent on the run's other jobs first; as many idle minis as jobs, and nothing moves.
        self.assertEqual(cascade.place(push, ("fast-tier",), None, None).jobs,
                         none_placed(**{SMALL: ("release-compile",)}))
        self.assertEqual(cascade.place(push, ("a", "b", "c"), None, None).jobs, none_placed())
        # A job that does not run here, or a run with no FRESH_JOBS, still places nothing.
        self.assertEqual(cascade.place(env(FRESH_JOBS="release-compile"), (), None, None).jobs, none_placed())
        self.assertEqual(cascade.place(env(), (), None, None).jobs, none_placed())
        # A person's re-run reads nothing and keeps its own route, as before.
        self.assertEqual(cascade.place(env(GITHUB_RUN_ATTEMPT="2", GITHUB_TRIGGERING_ACTOR="teamleaderleo",
                                           FRESH_JOBS="cmux-scheme-compile",
                                           CASCADE_RUNS=" cmux-scheme-compile "), (), None, None).jobs,
                         none_placed())

    def test_a_feeds_compile_counts_a_label_stalled_fifteen_minutes_as_full(self):
        """2026-10-27 01:11Z: 92 jobs queued on 6 vCPU (oldest 148 min) and 27 on 12 vCPU (oldest 165 min, no
        runner online). A feed's compile treats a label whose oldest job waited FRESH_STALL_MINUTES as full."""
        minutes = float(cascade.FRESH_STALL_MINUTES)
        stuck = cascade.Seen(waits={LARGE: 0.0, SMALL: minutes})
        moving = cascade.Seen(waits={LARGE: 0.0, SMALL: minutes - 1})
        self.assertEqual(cascade.fresh_stalled(stuck.waits), (SMALL,))
        self.assertEqual(cascade.fresh_stalled(moving.waits), ())
        # One rule (simple_pool_picker.blacksmith_stalled): the same wait stalls the label for every job.
        self.assertEqual(cascade.FRESH_STALL_MINUTES, cascade.STALL_MINUTES)
        live, waiting = {LARGE: 0, SMALL: 4}, {LARGE: 0, SMALL: 1}
        self.assertEqual(cascade.stalled(live, waiting, stuck.waits), (SMALL,))
        self.assertEqual(cascade.stalled(live, waiting, moving.waits), ())
        self.assertEqual(cascade.place(env(CASCADE_RUNS=" fast-tier "), (), live, waiting, moving).jobs,
                         none_placed(**{SMALL: ("fast-tier",)}))
        # A DEV daily's compile and a push's Release compile both stay on the owned label, never hosted.
        dev = env(CASCADE_RUNS=" cmux-scheme-compile ", FRESH_JOBS="cmux-scheme-compile")
        self.assertEqual(cascade.place(dev, (), live, waiting, stuck).jobs, none_placed())
        self.assertEqual(cascade.place(dev, (), live, waiting, moving).jobs,
                         none_placed(**{SMALL: ("cmux-scheme-compile",)}))
        push = env(CASCADE_RUNS=" release-compile ", FRESH_JOBS="release-compile")
        self.assertEqual(cascade.place(push, (), live, waiting, stuck).jobs, none_placed())
        self.assertEqual(cascade.place(push, (), live, waiting, moving).jobs,
                         none_placed(**{SMALL: ("release-compile",)}))
        # Runner groups unread: the last resort skips a stalled 6 vCPU queue the snapshot saw.
        result = cascade.place(push, (), None, None, stuck)
        self.assertEqual(result.jobs, none_placed())
        self.assertIn("no job leaves the minis' queue", result.why)
        self.assertEqual(cascade.place(push, (), None, None, moving).jobs, none_placed(**{SMALL: ("release-compile",)}))
        self.assertEqual(cascade.place(dev, (), None, None, stuck).jobs, none_placed())
        # The overflow skips the stalled label, a feed's compile and every other run's alike (one rule).
        free = {LARGE: 0, SMALL: 2}, {LARGE: 0, SMALL: 1}
        self.assertEqual(cascade.place(push, ("release-compile",), *free, stuck).retry_runner, "")
        self.assertEqual(cascade.place(env(CASCADE_RUNS=" fast-tier "), ("fast-tier",), *free, stuck).retry_runner, "")
        self.assertEqual(cascade.place(env(CASCADE_RUNS=" fast-tier "), ("fast-tier",), *free, moving).retry_runner,
                         SMALL)
        self.assertEqual(cascade.place(push, (), live, waiting, stuck).fresh_stall, (SMALL,))
        self.assertEqual(cascade.place(push, (), None, None, stuck).fresh_stall, (SMALL,))
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            cascade.write(cascade.place(push, (), live, waiting, stuck), {"GITHUB_OUTPUT": str(output)})
            self.assertIn(f"fresh_stalled= {SMALL} \n", output.read_text(encoding="utf-8"))

    def test_queued_freshness_work_keeps_a_blacksmith_label_for_feed_compiles(self):
        """2026-10-26: nightly-next's build-sign-notarize-nightly queued on blacksmith-6vcpu-macos-26 from 19:38Z
        behind 68 PR compiles. While the snapshot shows release or nightly work queued for a label
        (`reserved_queued`), a PR's jobs take no slot there, nor its overflow, and a feed's compile still does."""
        snap = snapshot(large=1, small=1)
        snap["pools"][LARGE]["reserved_queued"] = snap["pools"][SMALL]["reserved_queued"] = 1
        found = cascade.seen(snap, NOW)
        self.assertEqual(found.reserved, {LARGE: 1, SMALL: 1})
        free, waiting = {LARGE: 0, SMALL: 0}, {LARGE: 1, SMALL: 1}
        pr = cascade.place(env(CASCADE_RUNS=" cmux-scheme-compile release-compile "), (), free, waiting, found)
        self.assertEqual(pr.jobs, none_placed())
        self.assertEqual(pr.retry_runner, "")
        self.assertIn("freshness work is queued", pr.why)
        dev = cascade.place(env(CASCADE_RUNS=" cmux-scheme-compile ", FRESH_JOBS="cmux-scheme-compile"), (), free,
                            waiting, found)
        self.assertEqual(sum(len(jobs) for jobs in dev.jobs.values()), 1)
        self.assertIn("cmux-scheme-compile", dev.jobs[LARGE] + dev.jobs[SMALL])
        # A label with no freshness work queued is open to PR jobs as before.
        clear = cascade.seen(snapshot(large=1, small=1), NOW)
        self.assertEqual(clear.reserved, {})
        self.assertNotEqual(cascade.place(env(CASCADE_RUNS=" release-compile "), (), free, waiting, clear).jobs,
                            none_placed())

    def test_a_feeds_compile_leads_the_runs_other_jobs(self):
        dev = env(CASCADE_RUNS=" fast-tier swift-canary cmux-scheme-compile ", FRESH_JOBS="cmux-scheme-compile")
        result = cascade.place(dev, (), {LARGE: 4, SMALL: 0}, {LARGE: 0, SMALL: 0})
        self.assertEqual(result.jobs, none_placed(**{LARGE: ("cmux-scheme-compile",)}))

    def test_the_placement_names_the_fresh_jobs_on_attempt_1_of_a_feed_run_only(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        place = next(step for step in jobs["macos-placement"]["steps"] if step.get("id") == "place")
        expression = place["env"]["FRESH_JOBS"]
        for event, ref, attempt, dev_daily, expected in (
                ("push", "refs/heads/feat-cmux-next", "1", False, "release-compile"),
                ("push", "refs/heads/feat-cmux-next", "2", False, ""),
                ("push", "refs/heads/next-batch/abc", "1", False, ""),
                ("workflow_dispatch", "refs/heads/feat-cmux-next", "1", True, "cmux-scheme-compile"),
                ("workflow_dispatch", "refs/heads/feat-cmux-next", "2", True, ""),
                ("workflow_dispatch", "refs/heads/feat-cmux-next", "1", False, ""),
                ("pull_request", "refs/pull/1/merge", "1", False, "")):
            with self.subTest(event=event, ref=ref, attempt=attempt, dev_daily=dev_daily):
                context = {"github": {"event_name": event, "ref": ref, "run_attempt": attempt},
                           "inputs": {"dev_daily": dev_daily}}
                self.assertEqual(evaluate(expression, context), expected)

    def test_only_attempt_1_of_an_owned_side_label_cascades(self):
        free = {LARGE: 0, SMALL: 0}
        for overrides in ({"GITHUB_RUN_ATTEMPT": "2"}, {"SIDE_LABEL": "blacksmith-6vcpu-macos-26"}, {"SIDE_LABEL": ""}):
            with self.subTest(**overrides):
                self.assertEqual(cascade.place(env(**overrides), (), free, free).jobs, none_placed())

    def test_a_skipped_run_reads_nothing(self):
        pool = mock.Mock()
        with mock.patch.object(cascade, "Api") as api:
            self.assertEqual(cascade.read(env(GITHUB_RUN_ATTEMPT="2", ROUTE_TOKEN="t", SNAPSHOT_TOKEN="s",
                                              GITHUB_REPOSITORY="manaflow-ai/cmux"), pool, now=NOW), (None, None, None))
        api.assert_not_called()
        pool.GitHub.assert_not_called()

    def test_reads_fail_closed(self):
        pool = mock.Mock()
        pool.GitHub.return_value.snapshot.return_value = snapshot(large=1, oldest={"large": 3})
        live_env = env(ROUTE_TOKEN="t", SNAPSHOT_TOKEN="s", GITHUB_REPOSITORY="manaflow-ai/cmux")
        with mock.patch.object(cascade.Api, "in_flight", return_value={LARGE: 2, SMALL: 3}):
            self.assertEqual(cascade.read(live_env, pool, now=NOW, log=lambda _: None),
                             ({LARGE: 2, SMALL: 3}, {LARGE: 1, SMALL: 0},
                              cascade.Seen(waits={LARGE: 5.0, SMALL: 0.0}, age=2.0)))
        # A refused runner read (the route token's 403s, 2026-10-26 22:47Z) is not replaced by the snapshot,
        # which counts only this repository's share of the organization's pool.
        # Its waits are still read, so a feed's compile can skip a stalled queue (fresh_stalled()).
        with mock.patch.object(cascade.Api, "in_flight", side_effect=OSError("HTTP Error 403: Forbidden")):
            self.assertEqual(cascade.read(live_env, pool, now=NOW, log=lambda _: None),
                             (None, None, cascade.Seen(waits={LARGE: 5.0, SMALL: 0.0}, age=2.0)))
        # cmux-bot's token (ROUTE_TOKEN_FALLBACK) reads again when the routing App's read is refused.
        tokens = []

        def in_flight(api):
            tokens.append(api.route_token)
            if api.route_token == "t":
                raise OSError("HTTP Error 403: Forbidden")
            return {LARGE: 2, SMALL: 3}

        with mock.patch.object(cascade.Api, "in_flight", autospec=True, side_effect=in_flight):
            live, waiting, _ = cascade.read({**live_env, "ROUTE_TOKEN_FALLBACK": "bot"}, pool, now=NOW,
                                            log=lambda _: None)
        self.assertEqual((tokens, live, waiting), (["t", "bot"], {LARGE: 2, SMALL: 3}, {LARGE: 1, SMALL: 0}))
        tokens.clear()
        with mock.patch.object(cascade.Api, "in_flight", autospec=True, side_effect=in_flight):
            cascade.read({**live_env, "ROUTE_TOKEN": "ok", "ROUTE_TOKEN_FALLBACK": "bot"}, pool, now=NOW,
                         log=lambda _: None)
        self.assertEqual(tokens, ["ok"])
        pool.GitHub.return_value.snapshot.side_effect = OSError("boom")
        with mock.patch.object(cascade.Api, "in_flight", return_value={LARGE: 2, SMALL: 3}):
            self.assertEqual(cascade.read(live_env, pool, now=NOW, log=lambda _: None),
                             ({LARGE: 2, SMALL: 3}, None, None))

    def test_the_reads_hit_the_scale_set_groups_and_the_snapshot(self):
        calls = []
        groups = {"runner_groups": [{"id": 15, "name": f"Blacksmith scale sets - {LARGE}"},
                                    {"id": 10, "name": f"Blacksmith scale sets - {SMALL}"}]}
        runners = {15: [{"status": "online"}] * 3, 10: [{"status": "online"}, {"status": "offline"}]}

        def get(_self, path):
            calls.append(path)
            if "/runner-groups?" in path:
                return groups
            return {"runners": runners[int(path.split("/runner-groups/")[1].split("/")[0])]}

        class Snapshots:
            def __init__(self, token, repository):
                self.token, self.repository = token, repository

            def snapshot(self, *, now, branch="main"):  # pr_runner_pool.GitHub.snapshot's signature
                calls.append(("snapshot", self.token, self.repository))
                return snapshot(large=2)

        pool = mock.Mock(GitHub=Snapshots)
        with mock.patch.object(cascade.Api, "_get", get):
            live, waiting, seen = cascade.read(env(ROUTE_TOKEN="route", SNAPSHOT_TOKEN="gh",
                                                   GITHUB_REPOSITORY="manaflow-ai/cmux"), pool, now=NOW)
        self.assertEqual((live, waiting), ({LARGE: 3, SMALL: 1}, {LARGE: 2, SMALL: 0}))
        self.assertEqual(seen, cascade.Seen(waits={LARGE: 2.0, SMALL: 0.0}, age=2.0))
        self.assertEqual(calls, ["/orgs/manaflow-ai/actions/runner-groups?per_page=100&visible_to_repository=cmux",
                                 "/orgs/manaflow-ai/actions/runner-groups/15/runners?per_page=100",
                                 "/orgs/manaflow-ai/actions/runner-groups/10/runners?per_page=100",
                                 ("snapshot", "gh", "manaflow-ai/cmux")])

    def test_slow_group_reads_skip_the_snapshot(self):
        pool = mock.Mock()
        ticks = iter([0.0, cascade.READ_BUDGET_SECONDS + 1])
        with mock.patch.object(cascade.Api, "in_flight", return_value={LARGE: 0, SMALL: 0}):
            result = cascade.read(env(ROUTE_TOKEN="t", SNAPSHOT_TOKEN="s", GITHUB_REPOSITORY="manaflow-ai/cmux"),
                                  pool, now=NOW, log=lambda _: None, clock=lambda: next(ticks))
        self.assertEqual(result, ({LARGE: 0, SMALL: 0}, None, None))
        pool.GitHub.assert_not_called()

    def test_side_lane_placement_writes_the_cascade_outputs(self):
        runners = [{"name": "mini", "status": "online", "busy": False,
                    "labels": [{"name": label} for label in ("self-hosted", "glaeda-light-xcode-26.6", SIDE)]}]
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            fake = mock.Mock()
            fake.return_value.runners.return_value = runners
            with mock.patch.object(placement.pool, "GitHub", fake), \
                    mock.patch.object(placement.cascade, "read",
                                      return_value=({LARGE: 0, SMALL: 7}, {LARGE: 0, SMALL: 0}, None)):
                placement.main(env(ROUTE_TOKEN="t", GITHUB_REPOSITORY="manaflow-ai/cmux", GITHUB_OUTPUT=str(output)))
            lines = dict(line.split("=", 1) for line in output.read_text().splitlines())
        # The idle mini takes the first job; the pool's 18 free vCPU take one 12 vCPU job, then one 6 vCPU job.
        self.assertEqual(lines["owned_jobs"], " fast-tier ")
        self.assertEqual(lines["blacksmith_12_jobs"], " swift-canary ")
        self.assertEqual(lines["blacksmith_6_jobs"], " cmux-scheme-compile ")
        self.assertEqual(lines["retry_runner"], "")
        self.assertNotIn("hosted_jobs", lines)

    def test_side_lane_placement_reads_the_promotion_minis_load(self):
        side = {"name": "side-mini", "status": "online", "busy": True,
                "labels": [{"name": label} for label in ("self-hosted", "glaeda-light-xcode-26.6", SIDE)]}

        def outputs(promote_busy: bool | None, **extra: str) -> dict:
            runners = [side]
            if promote_busy is not None:
                runners.append({"name": "cmux14-glaeda", "status": "online", "busy": promote_busy,
                                "labels": [{"name": label} for label in
                                           ("self-hosted", "glaeda-promote-trusted-std-xcode-26.6", PROMOTE)]})
            with tempfile.TemporaryDirectory() as tmp:
                output = Path(tmp) / "out"
                fake = mock.Mock()
                fake.return_value.runners.return_value = runners
                with mock.patch.object(placement.pool, "GitHub", fake), \
                        mock.patch.object(placement.cascade, "read",
                                          return_value=({LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0}, None)):
                    placement.main(env(ROUTE_TOKEN="t", GITHUB_REPOSITORY="manaflow-ai/cmux", GITHUB_OUTPUT=str(output),
                                       CASCADE_RUNS=" release-compile ", **extra))
                return dict(line.split("=", 1) for line in output.read_text().splitlines())

        # A feat-cmux-next push (PROMOTE_LABEL set) with the promotion mini busy: Blacksmith 12 vCPU.
        self.assertEqual(outputs(True, PROMOTE_LABEL=PROMOTE)["blacksmith_12_jobs"], " release-compile ")
        # No online promotion runner at all (the mini is down) overflows the same way.
        self.assertEqual(outputs(None, PROMOTE_LABEL=PROMOTE)["blacksmith_12_jobs"], " release-compile ")
        # An idle promotion mini keeps it.
        self.assertEqual(outputs(False, PROMOTE_LABEL=PROMOTE)["blacksmith_12_jobs"], "")
        # Any other run (no promotion label) cascades it as a side job: the side mini is busy.
        self.assertEqual(outputs(False)["blacksmith_12_jobs"], " release-compile ")

    def test_dedicated_nightly_builder_gets_release_compile_before_blacksmith(self):
        side = {"name": "side-mini", "status": "online", "busy": True,
                "labels": [{"name": label} for label in ("self-hosted", "glaeda-light-xcode-26.6", SIDE)]}
        dedicated = {"name": "cmux22", "status": "online", "busy": False,
                     "labels": [{"name": label} for label in
                                ("self-hosted", "glaeda-trusted-light-xcode-26.6",
                                 "glaeda-runner-cmux22-nightly-next", "glaeda-trusted-next-nightly")]}

        def run(busy: bool):
            dedicated_copy = {**dedicated, "busy": busy}
            with tempfile.TemporaryDirectory() as tmp:
                output = Path(tmp) / "out"
                fake = mock.Mock()
                fake.return_value.runners.return_value = [side, dedicated_copy]
                with mock.patch.object(placement.pool, "GitHub", fake), \
                        mock.patch.object(placement.cascade, "read",
                                          return_value=({LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0}, None)):
                    placement.main(env(ROUTE_TOKEN="t", GITHUB_REPOSITORY="manaflow-ai/cmux",
                                       GITHUB_OUTPUT=str(output), CASCADE_RUNS=" release-compile ",
                                       PROMOTE_LABEL=PROMOTE,
                                       NIGHTLY_POOL="glaeda-trusted-light-xcode-26.6",
                                       NIGHTLY_RUNNER="glaeda-runner-cmux22-nightly-next"))
                return dict(line.split("=", 1) for line in output.read_text().splitlines())

        ready = run(False)
        self.assertEqual(ready["nightly_runner_ready"], "true")
        self.assertEqual(ready["blacksmith_12_jobs"], "")
        overflow = run(True)
        self.assertEqual(overflow["nightly_runner_ready"], "")
        self.assertEqual(overflow["blacksmith_12_jobs"], " release-compile ")


class Stall(unittest.TestCase):
    """A Blacksmith label whose queue is not moving gets no job; the overflow stays on the owned label."""

    # Run 39409184395's placement, 2026-10-20 10:38Z, during Blacksmith's macOS start delay:
    # neither label had a runner online, 12 vCPU's oldest queued job had waited 41 min,
    # and the cascade still sent fast-tier to 12 vCPU, where it never started.
    INCIDENT_LIVE = {LARGE: 0, SMALL: 0}
    INCIDENT_QUEUED = {LARGE: 4, SMALL: 6}

    def incident_seen(self):
        return cascade.Seen(waits={LARGE: 46.0, SMALL: 13.0})

    def test_seen_reads_each_labels_wait_by_now(self):
        shot = snapshot(5, oldest={"large": 41, "small": 8}, hosted=(1, 2), large=3, small=6)
        shot["pools"]["macos-15"] = {"queued": 0, "running": 1}
        shot["pools"]["blacksmith-6vcpu-macos-15"] = {"queued": 4, "running": 3}
        seen = cascade.seen(shot, NOW)
        # The oldest job has waited the snapshot's age longer by now; a hosted macOS pool counts for nothing.
        self.assertEqual(seen, cascade.Seen(waits={LARGE: 46.0, SMALL: 13.0}, age=5.0))
        # An empty queue has no wait, whatever a stale oldest field says.
        self.assertEqual(cascade.seen(snapshot(5, oldest={"large": 41}), NOW).waits, {LARGE: 0.0, SMALL: 0.0})
        self.assertIsNone(cascade.seen(snapshot(minutes_old=cascade.QUEUE_SNAPSHOT_MINUTES + 1), NOW))
        self.assertIsNone(cascade.seen(None, NOW))

    def test_the_stall_figure_is_the_pickers_one_rule(self):
        """pick-nightly-sign-runner, cmux-next's placement and ci.yml's pick read one stall figure."""
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/ci"))
        import simple_pool_picker

        self.assertEqual(cascade.STALL_MINUTES, simple_pool_picker.BLACKSMITH_STALL_MINUTES)
        self.assertEqual(cascade.STALL_MINUTES, 10)
        # 2026-10-27 06:13Z: both macOS 26 labels queued for hours with 3 running.
        self.assertEqual(cascade.stalled({LARGE: 0, SMALL: 3}, {LARGE: 44, SMALL: 38},
                                         {LARGE: 396.0, SMALL: 359.0}), (LARGE, SMALL))

    def test_a_long_wait_or_an_unserved_queue_is_a_stall(self):
        self.assertEqual(cascade.stalled(self.INCIDENT_LIVE, self.INCIDENT_QUEUED, self.incident_seen().waits),
                         (LARGE, SMALL))
        # Busy but moving: jobs start within minutes.
        self.assertEqual(cascade.stalled({LARGE: 5, SMALL: 3}, {LARGE: 1, SMALL: 1}, {LARGE: cascade.STALL_MINUTES - 1.0, SMALL: 3.0}), ())
        # A queue nobody serves for IDLE_STALL_MINUTES is a stall even before STALL_MINUTES.
        idle = cascade.IDLE_STALL_MINUTES
        self.assertEqual(cascade.stalled({LARGE: 0, SMALL: 2}, {LARGE: 1, SMALL: 1},
                                         {LARGE: float(idle), SMALL: float(idle)}), (LARGE,))
        self.assertEqual(cascade.stalled({LARGE: 0, SMALL: 0}, {LARGE: 1, SMALL: 0},
                                         {LARGE: idle - 1.0, SMALL: 0.0}), ())
        # An idle scale set has no runner online: a job the snapshot saw queued only briefly
        # is not a stall however old the snapshot is (it may have run since).
        self.assertEqual(cascade.stalled({LARGE: 0, SMALL: 0}, {LARGE: 1, SMALL: 0},
                                         {LARGE: cascade.STALL_MINUTES - 1.0, SMALL: 0.0}, age=7.0), ())
        # A runner online does not excuse a queue that has waited STALL_MINUTES.
        self.assertEqual(cascade.stalled({LARGE: 3, SMALL: 0}, {LARGE: 1, SMALL: 0},
                                         {LARGE: float(cascade.STALL_MINUTES), SMALL: 0.0}), (LARGE,))
        # Nothing queued is never a stall.
        self.assertEqual(cascade.stalled({LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0}, {LARGE: 90.0, SMALL: 90.0}), ())

    def test_the_incident_sends_nothing_to_blacksmith_or_hosted(self):
        result = cascade.place(env(), (), self.INCIDENT_LIVE, self.INCIDENT_QUEUED, self.incident_seen())
        self.assertEqual(result.jobs, none_placed())
        self.assertIn("fast-tier, swift-canary, cmux-scheme-compile stay queued on the owned label", result.why)
        self.assertIn("stalled", result.why)
        self.assertNotIn(f"`{HOSTED}`", result.why)

    def test_a_full_blacksmith_keeps_the_owned_label(self):
        # Free, moving Blacksmith slots come first.
        result = cascade.place(env(), (), {LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0},
                               cascade.Seen(waits={LARGE: 0.0, SMALL: 0.0}))
        self.assertEqual(result.jobs, none_placed(**{LARGE: ("fast-tier", "swift-canary"),
                                                     SMALL: ("cmux-scheme-compile",)}))
        # A full but moving fleet places nothing: the jobs wait behind the fleet on the owned label, never on
        # GitHub-hosted macos-26 (Leo, 2026-10-27: "THE GITHUB HOSTED MACS / ARE THE SLOWEST THINGS").
        result = cascade.place(env(), (), {LARGE: 5, SMALL: 10}, {LARGE: 0, SMALL: 0},
                               cascade.Seen(waits={LARGE: 0.0, SMALL: 0.0}))
        self.assertEqual(result.jobs, none_placed())

    def test_the_cascade_has_no_hosted_route(self):
        for name in ("HOSTED", "HOSTED_CAPACITY", "HOSTED_JOBS"):
            self.assertFalse(hasattr(cascade, name), name)
        self.assertEqual(cascade.LABELS, (LARGE, SMALL))
        self.assertTrue(all(label.startswith("blacksmith-") for label in cascade.LABELS))

    def test_without_the_snapshots_waits_nothing_changes(self):
        # Fail toward the current behavior: no stall known, no hosted spill.
        result = cascade.place(env(), (), {LARGE: 4, SMALL: 0}, {LARGE: 0, SMALL: 0}, None)
        self.assertEqual(result.jobs, none_placed(**{LARGE: ("fast-tier",)}))

    def test_the_bots_overflow_avoids_a_stalled_label(self):
        live, waiting = {LARGE: 0, SMALL: 9}, {LARGE: 1, SMALL: 0}
        # A job already waits on 12 vCPU, so the overflow takes the pool's last 6 vCPU job instead.
        self.assertEqual(cascade.retry_label(live, waiting), SMALL)
        seen = cascade.Seen(waits={LARGE: 30.0, SMALL: 0.0})
        self.assertEqual(cascade.place(env(), (), {LARGE: 0, SMALL: 5}, waiting, seen).retry_runner, SMALL)
        # The one free 6 vCPU slot goes to this run's fast-tier, so no label is left for the overflow.
        self.assertEqual(cascade.place(env(), (), live, waiting, seen).retry_runner, "")
        # Both stalled: no Blacksmith label; the overflow waits on the owned label.
        both = cascade.Seen(waits={LARGE: 30.0, SMALL: 30.0})
        self.assertEqual(cascade.place(env(), (), live, {LARGE: 1, SMALL: 1}, both).retry_runner, "")

    def test_no_job_reads_a_hosted_route(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        for key in ("hosted_jobs", "hosted_runner"):
            self.assertNotIn(f"outputs.{key}", text)
        jobs = yaml.safe_load(text)["jobs"]
        # The fast tier and the canary keep their own budget: no cold hosted build needs 45 minutes.
        self.assertEqual(jobs["fast-tier"]["timeout-minutes"], 20)
        canary = jobs["swift-canary"]["timeout-minutes"]
        self.assertEqual(evaluate(canary, {"needs": {"swift-canary-fleet": {"outputs": {"verdict": ""}}}}), 20)
        self.assertEqual(jobs["cmux-scheme-compile"]["timeout-minutes"], 60)

    def test_the_placement_writes_no_hosted_route(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            placed = cascade.place(env(), (), self.INCIDENT_LIVE, self.INCIDENT_QUEUED, self.incident_seen())
            cascade.write(placed, {"GITHUB_OUTPUT": str(output)})
            lines = dict(line.split("=", 1) for line in output.read_text().splitlines())
        self.assertNotIn("hosted_jobs", lines)
        self.assertNotIn("hosted_runner", lines)
        self.assertNotIn(HOSTED, lines.values())
        self.assertEqual((lines["blacksmith_12_jobs"], lines["blacksmith_6_jobs"]), ("", ""))


class FeedNeverHosted(unittest.TestCase):
    """Leo, 2026-10-27: "THE GITHUB HOSTED MACS / ARE THE SLOWEST THINGS". No DEV, nightly or promote path
    resolves to hosted macos-26: a run with FRESH_JOBS places nothing there, whatever Blacksmith's state."""

    def test_no_feed_run_places_a_job_on_hosted(self):
        runs = " fast-tier swift-canary cmux-scheme-compile release-compile "
        waits = (0.0, float(cascade.FRESH_STALL_MINUTES), float(cascade.STALL_MINUTES) + 60)
        counts = (None, ({LARGE: 0, SMALL: 0}, None), ({LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0}),
                  ({LARGE: 5, SMALL: 10}, {LARGE: 0, SMALL: 0}), ({LARGE: 0, SMALL: 0}, {LARGE: 9, SMALL: 40}))
        for fresh in ("cmux-scheme-compile", "release-compile"):
            for count in counts:
                live, waiting = count if count is not None else (None, None)
                for large, small in ((a, b) for a in waits for b in waits):
                    for owned in ((), ("fast-tier",)):
                        seen = cascade.Seen(waits={LARGE: large, SMALL: small})
                        with self.subTest(fresh=fresh, live=live, waiting=waiting, waits=(large, small), owned=owned):
                            placed = cascade.place(env(CASCADE_RUNS=runs, FRESH_JOBS=fresh), owned, live, waiting,
                                                   seen)
                            self.assertEqual(placed.jobs.get(HOSTED, ()), ())
                            self.assertFalse(set(placed.jobs.get(HOSTED, ())) & set(cascade.CASCADE_JOBS))

    def test_no_feed_compile_reads_the_hosted_route(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        for name in ("cmux-scheme-compile", "release-compile"):
            with self.subTest(job=name):
                self.assertNotIn("hosted_runner", str(jobs[name]["runs-on"]))
                self.assertNotIn("hosted_jobs", str(jobs[name]["runs-on"]))
                self.assertNotIn("hosted", str(jobs[name].get("env", {}).get("CMUX_NEXT_RUNNER", "")))
                self.assertNotIn("hosted_jobs", str(jobs[name].get("timeout-minutes", "")))


class Rerun(unittest.TestCase):
    """The rescue's full re-run (attempt 2 by github-actions[bot]) is placed afresh.

    Until 2026-10-26 every attempt after 1 skipped the placement's steps, so the re-run's outputs were
    empty and its cascade jobs rejoined the end of the side queue they had waited in. Run 40287033454's
    DEV Release compile (DEV daily 7cf3398a) waited on glaeda-side-std-xcode-26.6 from 07:39Z and a
    mini refused it at 08:02Z; a re-run would have queued there again.
    """

    RUNS = " cmux-scheme-compile "

    def rerun(self, **overrides: str) -> dict:
        return env(**{"CASCADE_RUNS": self.RUNS, "GITHUB_RUN_ATTEMPT": "2", "GITHUB_TRIGGERING_ACTOR": BOT,
                      **overrides})

    def test_the_rescues_attempt_2_reads_what_is_free_now(self):
        live, waiting = {LARGE: 0, SMALL: 5}, {LARGE: 0, SMALL: 0}
        self.assertTrue(cascade.bot_rerun(self.rerun()))
        self.assertEqual(cascade.skipped(self.rerun()), "")
        result = cascade.place(self.rerun(), (), live, waiting)
        self.assertEqual(result.jobs, none_placed(**{LARGE: ("cmux-scheme-compile",)}))
        self.assertIn("the rescue's re-run (attempt 2) is placed afresh", result.why)
        # The same pool rule as attempt 1: with a queue, 6 vCPU; with no room, the owned label.
        self.assertEqual(cascade.place(self.rerun(), (), live, {LARGE: 0, SMALL: 1}).jobs,
                         none_placed(**{SMALL: ("cmux-scheme-compile",)}))
        self.assertEqual(cascade.place(self.rerun(), (), {LARGE: 0, SMALL: 10}, waiting).jobs, none_placed())

    def test_a_persons_rerun_and_later_attempts_keep_their_route(self):
        free = {LARGE: 0, SMALL: 0}
        for attempt, actor in (("2", "teamleaderleo"), ("3", BOT), ("2", "")):
            with self.subTest(attempt=attempt, actor=actor):
                overrides = self.rerun(GITHUB_RUN_ATTEMPT=attempt, GITHUB_TRIGGERING_ACTOR=actor)
                self.assertFalse(cascade.bot_rerun(overrides))
                # Attempt 3 by the bot too: it is the rescue's last overflow attempt, not a fresh placement.
                self.assertEqual(cascade.skipped(overrides), "a person re-run keeps its own route")
                self.assertEqual(cascade.place(overrides, (), free, free).jobs, none_placed())

    def test_an_idle_mini_still_comes_first_on_the_rerun(self):
        # A re-run job no Blacksmith label lists takes the overflow label before the side label, so while
        # an idle mini would take one the overflow is empty and that job takes the side label.
        runs = " fast-tier cmux-scheme-compile "
        free = {LARGE: 0, SMALL: 0}
        result = cascade.place(self.rerun(CASCADE_RUNS=runs), ("fast-tier",), free, free)
        self.assertEqual(result.jobs, none_placed(**{LARGE: ("cmux-scheme-compile",)}))
        self.assertEqual(result.retry_runner, "")
        self.assertIn("an idle mini takes the re-run", result.why)
        # With no idle mini the overflow is the free label, as on attempt 1.
        self.assertEqual(cascade.place(self.rerun(CASCADE_RUNS=runs), (), free, free).retry_runner, SMALL)

    def placement_job(self) -> dict:
        return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["macos-placement"]

    def route_context(self, attempt: str, actor: str) -> dict:
        context = github_context("workflow_dispatch", CI_PR_POOL_OWNED="1", CI_SIDE_LANE_RUNNER=SIDE,
                                 MACOS_RUNNER_26=SMALL)
        context["github"].update(repository="manaflow-ai/cmux", run_attempt=attempt, triggering_actor=actor)
        return context

    def test_the_placement_steps_run_on_the_rescues_rerun_only(self):
        workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        job = workflow["jobs"]["macos-placement"]
        own, shared = job["env"]["CMUX_NEXT_SIDE_ROUTE"], workflow["env"]["CMUX_NEXT_SIDE_ROUTE"]
        for attempt, actor, expected in (("1", "teamleaderleo", SIDE), ("2", BOT, SIDE),
                                         ("2", "teamleaderleo", SMALL), ("3", BOT, SMALL)):
            with self.subTest(attempt=attempt, actor=actor):
                context = self.route_context(attempt, actor)
                self.assertEqual(evaluate(own, context), expected)
                # Every other case is the workflow's route, which the Mac jobs restate.
                if (attempt, actor) != ("2", BOT):
                    self.assertEqual(evaluate(own, context), evaluate(shared, context))
                # The job itself runs on attempt 1 and the bot's attempt 2.
                self.assertIn("github.run_attempt == 2 && contains(fromJSON('[\"github-actions[bot]\",\"cmux-bot[bot]\"]'), github.triggering_actor)",
                              job["if"])
        place = next(step for step in job["steps"] if step.get("id") == "place")
        self.assertEqual(place["env"]["SIDE_LABEL"], "${{ env.CMUX_NEXT_SIDE_ROUTE }}")

    def test_the_rerun_writes_the_cascade_and_no_owned_route(self):
        place = next(step for step in self.placement_job()["steps"] if step.get("id") == "place")
        call = "python3 scripts/ci/side_lane_placement.py\n"
        self.assertEqual(place["run"].count(call), 1)
        shell = place["run"].replace(call, ":\n")
        idle = {"name": "mini", "status": "online", "busy": False,
                "labels": [{"name": label} for label in ("self-hosted", "glaeda-light-xcode-26.6", SIDE)]}
        for attempt, actor in (("2", BOT), ("1", "teamleaderleo")):
            with self.subTest(attempt=attempt), tempfile.TemporaryDirectory() as tmp:
                output = Path(tmp) / "out"
                values = env(ROUTE_TOKEN="t", GITHUB_REPOSITORY="manaflow-ai/cmux", GITHUB_OUTPUT=str(output),
                             GITHUB_RUN_ATTEMPT=attempt, GITHUB_TRIGGERING_ACTOR=actor,
                             CASCADE_RUNS=" swift-canary cmux-scheme-compile ")
                fake = mock.Mock()
                fake.return_value.runners.return_value = [idle]
                with mock.patch.object(placement.pool, "GitHub", fake), \
                        mock.patch.object(placement.cascade, "read",
                                          return_value=({LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0}, None)), \
                        contextlib.redirect_stdout(io.StringIO()):
                    placement.main(values)
                subprocess.run(["bash", "-e", "-c", shell], check=True,
                               env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), **values})
                lines = dict(line.split("=", 1) for line in output.read_text().splitlines())
                # The idle mini races for the canary; the scheme compile gets 12 vCPU either way.
                self.assertEqual(lines["owned_jobs"], " fast-tier ")
                self.assertEqual(lines["blacksmith_12_jobs"], " cmux-scheme-compile ")
                routes = ("runner", "gui_runner", "session_runner", "free_gui_runner", "free_session_runner",
                          "fast_runner", "gateway_runner", "gateway_attempt", "nightly_runner_ready")
                if attempt == "2":
                    # The GUI, session, fast and gateway jobs keep the routes a re-run always had.
                    self.assertEqual({key: lines[key] for key in routes if key in lines}, {})
                    self.assertEqual(lines["retry_runner"], "")
                else:
                    self.assertEqual(lines["runner"], SIDE)

    def rerun_outputs(self, runners: list, live: dict, waiting: dict, **extra: str) -> dict:
        """placement.main() on the bot's attempt 2, then the step's shell, as the runner runs them."""
        place = next(step for step in self.placement_job()["steps"] if step.get("id") == "place")
        call = "python3 scripts/ci/side_lane_placement.py\n"
        shell = place["run"].replace(call, ":\n")
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            values = env(**{"ROUTE_TOKEN": "t", "GITHUB_REPOSITORY": "manaflow-ai/cmux",
                            "GITHUB_OUTPUT": str(output), "GITHUB_RUN_ATTEMPT": "2",
                            "GITHUB_TRIGGERING_ACTOR": BOT, **extra})
            fake = mock.Mock()
            fake.return_value.runners.return_value = runners
            with mock.patch.object(placement.pool, "GitHub", fake), \
                    mock.patch.object(placement.cascade, "read", return_value=(live, waiting, None)), \
                    contextlib.redirect_stdout(io.StringIO()):
                placement.main(values)
            subprocess.run(["bash", "-e", "-c", shell], check=True, cwd=ROOT,
                           env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), **values})
            return dict(line.split("=", 1) for line in output.read_text().splitlines())

    def test_the_rerun_counts_idle_minis_only_on_the_label_it_asks_for(self):
        # Review of #25707: attempt 1 counts a wider class's idle runners (side_route()), but a re-run's
        # cascade jobs fall back to SIDE_LABEL itself, so an idle std mini is no room for a light re-run.
        std = SIDE.replace("-light-", "-std-")
        idle_std = {"name": "std-mini", "status": "online", "busy": False,
                    "labels": [{"name": label} for label in ("self-hosted", "glaeda-std-xcode-26.6", std)]}
        busy_light = {"name": "light-mini", "status": "online", "busy": True,
                      "labels": [{"name": label} for label in ("self-hosted", "glaeda-light-xcode-26.6", SIDE)]}
        free = {LARGE: 0, SMALL: 0}
        lines = self.rerun_outputs([idle_std, busy_light], free, dict(free), CASCADE_RUNS=" cmux-scheme-compile ")
        self.assertEqual(lines["owned_jobs"], "")
        self.assertEqual(lines["blacksmith_12_jobs"], " cmux-scheme-compile ")
        self.assertNotIn("runner", lines)

    def test_a_feat_push_rerun_places_no_release_compile(self):
        # Its runs-on reads the placement on attempt 1 only and takes 6 vCPU on a re-run, so a slot
        # placed for it would be spent on nothing.
        free = {LARGE: 0, SMALL: 0}
        runs = " cmux-scheme-compile release-compile "
        push = self.rerun_outputs([], free, dict(free), CASCADE_RUNS=runs, GITHUB_EVENT_NAME="push",
                                  GITHUB_REF="refs/heads/feat-cmux-next")
        self.assertEqual(push["blacksmith_12_jobs"], " cmux-scheme-compile ")
        self.assertEqual(push["blacksmith_6_jobs"], "")
        dispatch = self.rerun_outputs([], free, dict(free), CASCADE_RUNS=runs, GITHUB_EVENT_NAME="workflow_dispatch",
                                      GITHUB_REF="refs/heads/feat-cmux-next")
        self.assertEqual(dispatch["blacksmith_12_jobs"], " cmux-scheme-compile release-compile ")
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        context = Wiring().context("2", BOT, large=" release-compile ", runner="")
        context["github"].update(event_name="push", ref="refs/heads/feat-cmux-next", event={})
        context["needs"]["release-compile-fast"] = {"result": "skipped", "outputs": {"verdict": ""}}
        self.assertEqual(evaluate(jobs["release-compile"]["runs-on"], context), SMALL)
        # 6 vCPU fresh-stalled (next_macos_cascade.fresh_stalled()): the re-run takes the owned label instead.
        # (A feat-cmux-next push's re-run lists no release-compile on a Blacksmith label, as above.)
        context["needs"]["macos-placement"]["outputs"].update(fresh_stalled=f" {SMALL} ", blacksmith_12_jobs="")
        for key in ("runs-on", "CMUX_NEXT_RUNNER"):
            expression = jobs["release-compile"]["runs-on"] if key == "runs-on" else jobs["release-compile"]["env"][key]
            self.assertEqual(evaluate(expression, context), SIDE, key)
        # The same with the fleet fast check failed with no verdict, and a carried (older) placement keeps 6 vCPU.
        context["needs"]["release-compile-fast"] = {"result": "failure", "outputs": {"verdict": ""}}
        self.assertEqual(evaluate(jobs["release-compile"]["runs-on"], context), SIDE)
        context["needs"]["macos-placement"]["outputs"]["placed_attempt"] = "1"
        self.assertEqual(evaluate(jobs["release-compile"]["runs-on"], context), SMALL)

    def test_a_feat_push_rerun_counts_no_idle_mini_for_release_compile(self):
        # Review of #25707: JOBS lists release-compile first, so an idle mini counted for it left the
        # scheme compile on the owned label with no mini to take it.
        idle = {"name": "light-mini", "status": "online", "busy": False,
                "labels": [{"name": label} for label in ("self-hosted", "glaeda-light-xcode-26.6", SIDE)]}
        free = {LARGE: 0, SMALL: 0}
        push = self.rerun_outputs([idle], free, dict(free), JOBS="release-compile cmux-scheme-compile",
                                  CASCADE_RUNS=" cmux-scheme-compile release-compile ", GITHUB_EVENT_NAME="push",
                                  GITHUB_REF="refs/heads/feat-cmux-next")
        self.assertEqual(push["owned_jobs"], " cmux-scheme-compile ")
        self.assertEqual(push["blacksmith_12_jobs"], "")
        self.assertEqual(push["blacksmith_6_jobs"], "")

    def test_the_rescues_dev_compile_leaves_the_queue_when_counts_are_unread(self):
        # #25739 sends a DEV daily's compile to the last resort (6 vCPU, never hosted) when attempt 1 cannot read the
        # counts; the rescue's attempt 2 is placed afresh, so it reads FRESH_JOBS too, and a person's re-run does not.
        place = next(step for step in self.placement_job()["steps"] if step.get("id") == "place")
        fresh = place["env"]["FRESH_JOBS"]
        context = github_context("workflow_dispatch", ref="refs/heads/feat-cmux-next")
        context["inputs"] = {"dev_daily": True}
        for attempt, actor, expected in (("1", "teamleaderleo", "cmux-scheme-compile"),
                                         ("2", BOT, "cmux-scheme-compile"), ("2", "teamleaderleo", ""),
                                         ("3", BOT, "")):
            with self.subTest(attempt=attempt, actor=actor):
                context["github"].update(run_attempt=attempt, triggering_actor=actor)
                self.assertEqual(evaluate(fresh, context), expected)
        values = self.rerun(JOBS="cmux-scheme-compile", FRESH_JOBS="cmux-scheme-compile")
        placed = cascade.place(values, (), None, None)
        self.assertEqual(placed.jobs[SMALL], ("cmux-scheme-compile",))
        self.assertNotIn(HOSTED, placed.jobs)
        # The workflow's own JOBS, through main(): idle_placement() names the first JOBS (here skipped ones)
        # once per idle mini, so `owned` is the idle-mini count. With no idle mini the compile takes the last
        # resort (6 vCPU); with one, it stays on the side label, where that mini takes it.
        jobs = self.placement_job()["steps"]
        jobs = next(step for step in jobs if step.get("id") == "place")["env"]["JOBS"]
        self.assertTrue(jobs.startswith("fast-tier swift-canary cmux-scheme-compile"))
        idle = {"name": "side-mini", "status": "online", "busy": False,
                "labels": [{"name": label} for label in ("self-hosted", "glaeda-light-xcode-26.6", SIDE)]}
        for runners, small, owned in (([], " cmux-scheme-compile ", ""),
                                     ([idle], "", " fast-tier "),
                                     ([idle, dict(idle, name="side-mini-2")], "", " fast-tier swift-canary ")):
            with self.subTest(idle=len(runners)):
                lines = self.rerun_outputs(runners, None, None, JOBS=jobs, CASCADE_RUNS=" cmux-scheme-compile ",
                                           FRESH_JOBS="cmux-scheme-compile", GITHUB_EVENT_NAME="workflow_dispatch",
                                           GITHUB_REF="refs/heads/feat-cmux-next")
                self.assertEqual(lines["owned_jobs"], owned)
                self.assertNotIn("hosted_jobs", lines)
                self.assertEqual(lines["blacksmith_6_jobs"], small)

    def test_an_older_trusted_placement_writes_nothing_on_the_rerun(self):
        # Review of #25707: the steps check out the base's script. One that predates rerun_main() would
        # write owned, GUI, session and gateway routes on attempt 2; the step's shell runs none of it.
        place = next(step for step in self.placement_job()["steps"] if step.get("id") == "place")
        with tempfile.TemporaryDirectory() as tmp:
            scripts = Path(tmp) / "scripts/ci"
            scripts.mkdir(parents=True)
            (scripts / "side_lane_placement.py").write_text(
                "import os\nopen(os.environ['GITHUB_OUTPUT'], 'a').write('runner=x\\ngui_runner=y\\n')\n")
            output = Path(tmp) / "out"
            output.write_text("")
            for attempt, written in (("2", ""), ("1", "runner=x\ngui_runner=y\n")):
                with self.subTest(attempt=attempt):
                    output.write_text("")
                    subprocess.run(["bash", "-e", "-c", place["run"]], check=True, cwd=tmp, capture_output=True,
                                   env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "GITHUB_OUTPUT": str(output),
                                        "GITHUB_RUN_ATTEMPT": attempt, "SIDE_LABEL": SIDE})
                    self.assertEqual(output.read_text(), written)

    def test_a_rerun_of_failed_jobs_never_takes_a_carried_blacksmith_reading(self):
        """Run 40398277457 (2026-10-26, #25446): the rescue re-ran the failed jobs as attempt 2 by
        github-actions[bot], so macos-placement was carried from attempt 1 (started 20:44:52) with its
        outputs. The Release compile read that 39-minute-old blacksmith_6_jobs, took
        blacksmith-6vcpu-macos-26, sat 55 minutes with no runner and was cancelled by the queue janitor.
        placed_attempt names the attempt a reading belongs to; a carried one routes to the owned label."""
        workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        self.assertEqual(workflow["jobs"]["macos-placement"]["outputs"]["placed_attempt"], "${{ github.run_attempt }}")
        gate = "needs.macos-placement.outputs.placed_attempt == format('{0}', github.run_attempt)"
        text = WORKFLOW.read_text(encoding="utf-8")
        # Every read of a placement-time Blacksmith or retry reading carries the gate.
        for key in ("blacksmith_12_jobs", "blacksmith_6_jobs", "retry_runner"):
            for match in re.finditer(r"[^|\n]*needs\.macos-placement\.outputs\." + key + r"\b[^|\n]*", text):
                line = text[:match.start()].count("\n") + 1
                with self.subTest(key=key, line=line):
                    self.assertIn(gate, match.group(0))
        wiring = Wiring()
        jobs = workflow["jobs"]
        for name in CASCADED:
            for attempt in ("2", "3", "4"):
                for actor in (BOT, "teamleaderleo"):
                    for key in ("large", "small", "retry", "hosted"):
                        value = {"large": f" {name} ", "small": f" {name} ", "hosted": f" {name} ",
                                 "retry": SMALL}[key]
                        with self.subTest(job=name, attempt=attempt, actor=actor, reading=key):
                            context = wiring.context(attempt, actor, runner="", placed="1", **{key: value})
                            for expression in (jobs[name]["runs-on"], jobs[name].get("env", {}).get("CMUX_NEXT_RUNNER")):
                                if expression is None:
                                    continue
                                # Exactly the label it takes with no reading at all: the owned side label
                                # (attempts 2 and 3), or attempt 4's configured fallback.
                                self.assertEqual(evaluate(expression, context),
                                                 evaluate(expression, wiring.context(attempt, actor, runner="",
                                                                                     placed="1")))
                    # The same reading, fresh (the bot's attempt 2 placed afresh), is taken.
                    if actor == BOT:
                        fresh = wiring.context("2", BOT, runner="", small=f" {name} ")
                        self.assertEqual(evaluate(jobs[name]["runs-on"], fresh), SMALL, name)

    def test_the_rerun_scheme_compile_takes_the_fresh_slot(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        runs_on = jobs["cmux-scheme-compile"]["runs-on"]
        wiring = Wiring()
        self.assertEqual(evaluate(runs_on, wiring.context("2", BOT, small=" cmux-scheme-compile ", runner="")), SMALL)
        self.assertEqual(evaluate(runs_on, wiring.context("2", BOT, large=" cmux-scheme-compile ", runner="")), LARGE)
        # No slot and no overflow: the owned side label, where an idle mini (or the queue) takes it.
        self.assertEqual(evaluate(runs_on, wiring.context("2", BOT, runner="")), SIDE)


class Wiring(unittest.TestCase):
    def setUp(self):
        self.jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]

    def context(self, attempt: str = "1", actor: str = "teamleaderleo", large: str = "", small: str = "",
                retry: str = "", runner: str = SIDE, fork: bool = False, hosted: str = "",
                placed: str | None = None) -> dict:
        context = github_context("pull_request", ref="refs/pull/1/merge", CI_PR_POOL_OWNED="1",
                                 CI_SIDE_LANE_RUNNER=SIDE, MACOS_RUNNER_26=LARGE)
        context["vars"].pop("MACOS_RUNNER_PR", None)
        head = "someone/cmux" if fork else "manaflow-ai/cmux"
        context["github"].update(repository="manaflow-ai/cmux", run_attempt=attempt, triggering_actor=actor,
                                 event={"pull_request": {"head": {"repo": {"full_name": head}},
                                                         "labels": [{"name": "full-ci"}]}})
        context["needs"] = {"macos-placement": {"outputs": {
            "runner": runner, "gui_runner": GUI if runner else "", "fallback_jobs": "",
            "blacksmith_12_jobs": large, "blacksmith_6_jobs": small, "retry_runner": retry,
            "hosted_jobs": hosted, "hosted_runner": HOSTED if hosted else "",
            # The attempt the placement ran in: by default where it really runs (attempt 1, the bot's
            # attempt 2); any other attempt carries attempt 1's job and outputs.
            "placed_attempt": placed if placed is not None else (
                attempt if attempt == "1" or attempt == "2" and actor == BOT else "1")}}}
        return context

    def test_attempt_1_takes_the_blacksmith_slot_the_placement_found(self):
        for name in CASCADED:
            runs_on = self.jobs[name]["runs-on"]
            with self.subTest(job=name):
                if name == "release-compile":
                    # A same-repository PR uses a free owned Mac first; Blacksmith is spillover.
                    self.assertEqual(evaluate(runs_on, self.context(large=f" x {name} ")), SIDE)
                    self.assertEqual(evaluate(runs_on, self.context(small=f" {name} y ")), SIDE)
                    self.assertEqual(evaluate(runs_on, self.context(runner="", large=f" x {name} ")), LARGE)
                    self.assertEqual(evaluate(runs_on, self.context(runner="", small=f" {name} y ")), SMALL)
                else:
                    self.assertEqual(evaluate(runs_on, self.context(large=f" x {name} ")), LARGE)
                    self.assertEqual(evaluate(runs_on, self.context(small=f" {name} y ")), SMALL)
                # Whole keys only: another job's slot is not this job's.
                self.assertEqual(evaluate(runs_on, self.context(large=f" {name}-x ", small=f" x{name} ")), SIDE)
                self.assertEqual(evaluate(runs_on, self.context()), SIDE)
                # The bot's attempt 2 (the rescue moved a stuck sibling) keeps the slot.
                self.assertEqual(evaluate(runs_on, self.context("2", BOT, large=f" {name} ")), LARGE)
                # A person's re-run goes back to the minis first: attempt 1's count is stale by then.
                self.assertEqual(evaluate(runs_on, self.context("2", large=f" {name} ")), SIDE)
                self.assertEqual(evaluate(runs_on, self.context("3", large=f" {name} ")), SIDE)
                self.assertEqual(evaluate(runs_on, self.context(fork=True, large=f" {name} ")), SMALL)

    def test_release_compile_pr_is_owned_first_and_spills_to_blacksmith(self):
        runs_on = self.jobs["release-compile"]["runs-on"]
        self.assertEqual(self.jobs["release-compile"]["env"]["CMUX_NEXT_RUNNER"], runs_on)
        owned = self.context(runner="glaeda-side-std-xcode-26.6", large=" release-compile ")
        spill = self.context(runner="", large=" release-compile ")
        self.assertEqual(evaluate(runs_on, owned), "glaeda-side-std-xcode-26.6")
        self.assertEqual(evaluate(runs_on, spill), LARGE)

    def test_no_attempt_takes_a_hosted_spill(self):
        """An old placement's hosted_jobs/hosted_runner (a PR on an older base) is never read: the Mac jobs
        route as if it were empty (Leo, 2026-10-27: "THE GITHUB HOSTED MACS / ARE THE SLOWEST THINGS")."""
        for name in CASCADED:
            for expression in (self.jobs[name]["runs-on"], self.jobs[name].get("env", {}).get("CMUX_NEXT_RUNNER")):
                if expression is None:
                    continue
                with self.subTest(job=name):
                    self.assertEqual(evaluate(expression, self.context(hosted=f" x {name} ")),
                                     evaluate(expression, self.context()))
                    self.assertEqual(evaluate(expression, self.context("2", BOT, hosted=f" {name} ")),
                                     evaluate(expression, self.context("2", BOT)))
                    self.assertEqual(evaluate(expression, self.context(fork=True, hosted=f" {name} ")), SMALL)

    def test_a_feat_push_release_compile_uses_a_free_fleet_mac_then_blacksmith(self):
        runs_on = self.jobs["release-compile"]["runs-on"]

        def push(**outputs: str) -> dict:
            context = self.context(**outputs)
            context["github"].update(event_name="push", ref="refs/heads/feat-cmux-next")
            context["github"]["event"] = {}
            context["vars"]["CI_NEXT_PROMOTE_POOL"] = PROMOTE
            return context

        # An idle owned Mac wins: the cascade then gives the compile no Blacksmith slot and it takes the
        # owned label. The cascade places it on Blacksmith only when no idle mini took it, so its slot comes
        # before the owned label, which is then a queue (2026-10-26: 10-40 min on the std side label).
        self.assertEqual(evaluate(runs_on, push(runner="free-owned-mac")), "free-owned-mac")
        self.assertEqual(evaluate(runs_on, push()), SIDE)
        self.assertEqual(evaluate(runs_on, push(runner="")), SMALL)
        self.assertEqual(evaluate(runs_on, push(large=" release-compile ")), LARGE)
        self.assertEqual(evaluate(runs_on, push(small=" release-compile ")), SMALL)
        self.assertEqual(evaluate(runs_on, push(runner="", large=" release-compile ")), LARGE)
        self.assertEqual(evaluate(runs_on, push(runner="", small=" release-compile ")), SMALL)
        # Another job's slot is not the Release compile's.
        self.assertEqual(evaluate(runs_on, push(large=" cmux-scheme-compile ")), SIDE)
        # A re-run of the push does not reuse attempt 1's slot.
        rerun = push(large=" release-compile ")
        rerun["github"]["run_attempt"] = "2"
        self.assertEqual(evaluate(runs_on, rerun), SIDE)
        # The job's own label variable agrees with its runs-on.
        runner_env = self.jobs["release-compile"]["env"]["CMUX_NEXT_RUNNER"]
        for outputs in ({}, {"large": " release-compile "}, {"small": " release-compile "}, {"runner": ""}):
            self.assertEqual(evaluate(runner_env, push(**outputs)), evaluate(runs_on, push(**outputs)))
        self.assertEqual(evaluate(runs_on, self.context("2", BOT, retry=SMALL, runner="")), SMALL)
        self.assertEqual(evaluate(runs_on, self.context("3", BOT, retry=SMALL)), SIDE)
        # Release compile never targets the dedicated nightly runner.
        self.assertNotIn("CI_NIGHTLY_NEXT_TRUSTED_RUNNER", self.jobs["release-compile"]["runs-on"])
        self.assertNotIn("CI_NIGHTLY_NEXT_TRUSTED_RUNNER", self.jobs["release-compile"]["env"]["CMUX_NEXT_RUNNER"])

    NIGHTLY_POOL = "glaeda-trusted-light-xcode-26.6"
    NIGHTLY_RUNNER = "glaeda-runner-cmux22-nightly-next"

    # The events release-compile runs on: a push to either branch, a dispatch, and a same-repo or fork pull request.
    EVENTS = (("push", "refs/heads/feat-cmux-next", False), ("push", "refs/heads/main", False),
              ("workflow_dispatch", "refs/heads/feat-cmux-next", False), ("pull_request", "refs/pull/1/merge", False),
              ("pull_request", "refs/pull/1/merge", True))

    def nightly_push(self, ready: str, attempt: str = "1", fast: tuple[str, str] = ("skipped", ""),
                     event: tuple[str, str, bool] = EVENTS[0], actor: str = "teamleaderleo", config: str = "owned",
                     **outputs: str) -> dict:
        name, ref, fork = event
        context = self.context(attempt, actor, fork=fork, **outputs)
        if config == "another owner":
            context["github"]["repository_owner"] = "someone"
        elif config == "pool not owned":
            context["vars"].pop("CI_PR_POOL_OWNED")
        elif config == "no side route":
            context["vars"].update(CI_SIDE_LANE_RUNNER="", MACOS_RUNNER_26="")
        # The fleet fast check: skipped (no idle gateway), no verdict, or an unavailable fleet.
        context["needs"]["release-compile-fast"] = {"result": fast[0], "outputs": {"verdict": fast[1]}}
        context["github"].update(event_name=name, ref=ref)
        if name != "pull_request":
            context["github"]["event"] = {}
        context["vars"].update(CI_NIGHTLY_NEXT_TRUSTED_POOL=self.NIGHTLY_POOL,
                               CI_NIGHTLY_NEXT_TRUSTED_RUNNER=self.NIGHTLY_RUNNER, CI_NEXT_PROMOTE_POOL=PROMOTE)
        # The job sees placement's step outputs through the workflow's own `outputs:` mapping, evaluated here,
        # so a mapping that names a nightly variable reaches the runs-on.
        placed = dict(context["needs"]["macos-placement"]["outputs"], nightly_runner_ready=ready)
        mapping = self.jobs["macos-placement"]["outputs"]
        step = {}
        for key, expression in mapping.items():
            match = re.fullmatch(r"\$\{\{ steps\.place\.outputs\.(\w+) \}\}", expression)
            if match:
                step[match.group(1)] = placed.get(key, "")
        scope = dict(context, steps={"place": {"outputs": step}})
        context["needs"]["macos-placement"]["outputs"] = {key: evaluate(expression, scope)
                                                          for key, expression in mapping.items()}
        if config == "placement skipped":
            context["needs"]["macos-placement"] = {"result": "skipped", "outputs": {}}
        return context

    def off_the_nightly_runner(self, label) -> bool:
        """`label` (a runs-on value: one label, or a list every runner must carry) is set and names no nightly label."""
        labels = label if isinstance(label, list) else [label]
        return bool(labels) and all(isinstance(name, str) and name and name not in (self.NIGHTLY_POOL, self.NIGHTLY_RUNNER)
                                    and "nightly" not in name for name in labels)

    CONFIGS = ("owned", "another owner", "pool not owned", "no side route", "placement skipped")

    def test_a_feeds_compile_takes_the_freshness_slot_first(self):
        """The DEV compile slot (glaeda-dev-std-xcode-<v>), then the owned side label, then Blacksmith: the slot
        is taken only on attempt 1 and only when placement named the job and the label."""
        fresh = "glaeda-dev-std-xcode-26.6"
        feat = "refs/heads/" + "feat-cmux-next"
        # The slot's hook (glaeda#1636) admits cmux-scheme-compile and a push's Release compile, the
        # nightly-next promote gate.
        for name, event in (("cmux-scheme-compile", "workflow_dispatch"), ("release-compile", "push")):
            job = self.jobs[name]
            for attempt, outputs, expected in (
                    ("1", {"fresh_runner": fresh, "fresh_jobs": f" {name} "}, fresh),
                    ("1", {"fresh_runner": fresh, "fresh_jobs": " other "}, SIDE),
                    ("1", {"fresh_runner": "", "fresh_jobs": f" {name} "}, SIDE),
                    ("2", {"fresh_runner": fresh, "fresh_jobs": f" {name} "}, SIDE)):
                with self.subTest(job=name, attempt=attempt, outputs=outputs):
                    context = self.context(attempt)
                    context["github"].update(event_name=event, ref=feat, event={})
                    context["needs"]["macos-placement"]["outputs"].update(outputs)
                    context["needs"]["release-compile-fast"] = {"result": "skipped", "outputs": {"verdict": ""}}
                    context["inputs"] = {"dev_daily": event == "workflow_dispatch"}
                    self.assertEqual(evaluate(job["runs-on"], context), expected)
                    self.assertEqual(evaluate(job["env"]["CMUX_NEXT_RUNNER"], context), expected)
                    if name == "release-compile":
                        # A fleet fast check that failed without a verdict sends the compile to Blacksmith, but
                        # an idle slot placement named comes first (review of #25817).
                        context["needs"]["release-compile-fast"] = {"result": "failure", "outputs": {"verdict": ""}}
                        failed = expected if expected == fresh else "blacksmith-6vcpu-macos-26"
                        self.assertEqual(evaluate(job["runs-on"], context), failed)
                        self.assertEqual(evaluate(job["env"]["CMUX_NEXT_RUNNER"], context), failed)

    def test_release_compile_never_targets_the_dedicated_nightly_runner(self):
        """The nightly runner builds and signs nightly-next; the Release compile that gates it never takes it,
        whatever placement read about it. The runs-on and the job's own label variable are evaluated, as a
        single label or a label list, on every event the workflow runs on, for every attempt, owner and pool
        configuration, fast-check state and placement output it can see."""
        job = self.jobs["release-compile"]
        seen = {event: set() for event in self.EVENTS}
        failures = []
        attempts = (("1", "teamleaderleo"), ("2", "teamleaderleo"), ("2", BOT), ("3", "teamleaderleo"), ("3", BOT),
                    ("4", BOT))
        # Every fast-check state release-compile runs after: skipped, no verdict (failed, or the
        # continue-on-error step left success with none), or an unavailable fleet.
        fasts = (("skipped", ""), ("failure", ""), ("success", ""), ("success", "unavailable"),
                 ("failure", "unavailable"))
        placed = ({}, {"runner": ""}, {"large": " release-compile "}, {"small": " release-compile "}, {"retry": SMALL})
        for event, config, ready, (attempt, actor), fast, outputs in itertools.product(
                self.EVENTS, self.CONFIGS, ("true", ""), attempts, fasts, placed):
            context = self.nightly_push(ready, attempt, fast, event, actor, config, **outputs)
            label = evaluate(job["runs-on"], context)
            if config == "owned" and attempt in ("1", "2"):
                seen[event].add(tuple(label) if isinstance(label, list) else label)
            for name, value in (("runs-on", label), ("CMUX_NEXT_RUNNER", evaluate(job["env"]["CMUX_NEXT_RUNNER"],
                                                                                   context))):
                if not self.off_the_nightly_runner(value):
                    failures.append(f"{name}={value!r}: {event} {config} ready={ready!r} attempt={attempt} {actor} "
                                    f"fast={fast} outputs={outputs}")
        self.assertEqual(failures[:10], [], f"{len(failures)} cases name the nightly runner")
        # Every route each event can take was evaluated: the cascade's two slots and the owned side label
        # (a feat push also takes 6 vCPU with no placement runner, or a fast check that died before its
        # verdict); a fork pull request takes 6 vCPU only. side_lane_placement never writes a nightly label
        # into the runner outputs (test_ci_side_lane_placement.NightlyRunnerStaysOffTheRoutes).
        for event in self.EVENTS:
            self.assertEqual(seen[event], {SMALL} if event[2] else {LARGE, SMALL, SIDE}, event)
        self.assertEqual(evaluate(job["runs-on"], self.nightly_push("", fast=("failure", ""))), SMALL)

    def test_a_configured_but_unavailable_dedicated_runner_overflows_to_blacksmith(self):
        # Dedicated runner configured but not ready: the Blacksmith slot placement gave, else the owned route.
        runs_on = self.jobs["release-compile"]["runs-on"]
        self.assertEqual(evaluate(runs_on, self.nightly_push("", large=" release-compile ")), LARGE)
        self.assertEqual(evaluate(runs_on, self.nightly_push("", small=" release-compile ")), SMALL)
        self.assertEqual(evaluate(runs_on, self.nightly_push("")), SIDE)
        self.assertEqual(evaluate(runs_on, self.nightly_push("", runner="")), SMALL)

    def test_the_placement_knows_the_promotion_label_only_on_a_feat_push(self):
        place = next(step for step in self.jobs["macos-placement"]["steps"] if step.get("id") == "place")
        expression = place["env"]["PROMOTE_LABEL"]
        context = self.context()
        context["vars"]["CI_NEXT_PROMOTE_POOL"] = PROMOTE
        self.assertEqual(evaluate(expression, context), "")
        context["github"].update(event_name="push", ref="refs/heads/feat-cmux-next")
        self.assertEqual(evaluate(expression, context), PROMOTE)
        context["github"].update(ref="refs/heads/next-batch/abc")
        self.assertEqual(evaluate(expression, context), "")
        context["github"].update(ref="refs/heads/feat-cmux-next", run_attempt="2")
        self.assertEqual(evaluate(expression, context), "")

    def test_cascade_runs_names_only_jobs_that_run_on_this_route(self):
        place = next(step for step in self.jobs["macos-placement"]["steps"] if step.get("id") == "place")
        expression = place["env"]["CASCADE_RUNS"]

        def runs(event="pull_request", labels=("full-ci",), fast_lane="", canary="true", scheme="true",
                 association="MEMBER", inputs=None, native="true"):
            context = self.context()
            context["inputs"] = inputs or {"same_tree_sha": ""}
            context["github"]["event"]["pull_request"]["author_association"] = association
            context["github"].update(event_name=event, base_ref="feat-cmux-next",
                                     ref="refs/heads/feat-cmux-next" if event == "push" else "refs/pull/1/merge")
            context["github"]["event"]["pull_request"]["labels"] = [{"name": label} for label in labels]
            context["vars"]["CI_FAST_LANE_RUNNER"] = fast_lane
            context["needs"]["path_route"] = {"outputs": {"swift_canary": canary, "scheme": scheme, "native": native}}
            return set(evaluate(expression, context).split())

        self.assertEqual(runs(), set(CASCADED))
        self.assertEqual(runs(native="false"), set(CASCADED) - {"release-compile"})
        # A same-repository pull request runs its routed canary with no label (#22303); the two heavy
        # compiles need full-ci again, except a member's dev-build scheme compile (its dogfood app).
        self.assertEqual(runs(labels=()), {"fast-tier", "swift-canary"})
        self.assertEqual(runs(labels=(), canary="false", scheme="false"), {"fast-tier"})
        # The fast lane's label is a preference the placement takes only while it is idle
        # (side_lane_placement.fast_route()), so the fast tier is always a cascade candidate.
        self.assertEqual(runs(fast_lane="glaeda-fast-std-xcode-26.6"), set(CASCADED))
        self.assertEqual(runs("push", labels=(), canary="false"), {"fast-tier", "cmux-scheme-compile", "release-compile"})
        self.assertEqual(runs(labels=("dev-build",), association="CONTRIBUTOR"), {"fast-tier", "swift-canary"})
        self.assertEqual(runs(labels=("dev-build",)), {"fast-tier", "swift-canary", "cmux-scheme-compile"})
        # A same-tree dispatch asking for the scheme tier has no path routing output.
        self.assertEqual(runs("workflow_dispatch", labels=(), canary="", scheme="", native="",
                              inputs={"same_tree_sha": "a" * 40, "same_tree_state": "ready",
                                      "same_tree_tiers": "scheme,swift"}), {"cmux-scheme-compile"})

    def test_the_bots_overflow_takes_the_placements_retry_label(self):
        for name in CASCADED:
            runs_on = self.jobs[name]["runs-on"]
            with self.subTest(job=name):
                # The bot's attempt 2, placed afresh, takes its retry label; an earlier reading never.
                self.assertEqual(evaluate(runs_on, self.context("2", BOT, retry=SMALL, runner="")), SMALL)
                self.assertEqual(evaluate(runs_on, self.context("3", BOT, retry=SMALL)), SIDE)
                self.assertEqual(evaluate(runs_on, self.context("2", BOT, retry=SMALL, runner="", placed="1")), SIDE)
                # No free slot (an empty label), or no placement output: the owned side label, never
                # vars.MACOS_RUNNER_26, a Blacksmith label with no free-slot check.
                self.assertEqual(evaluate(runs_on, self.context("3", BOT)), SIDE)
                self.assertEqual(evaluate(runs_on, self.context("3", BOT, retry="")), SIDE)

    def test_gui_jobs_keep_their_route(self):
        for name in GUI_JOBS:
            runs_on = self.jobs[name]["runs-on"]
            with self.subTest(job=name):
                self.assertNotIn("blacksmith_12_jobs", runs_on)
                self.assertEqual(evaluate(runs_on, self.context(large=f" {name} ", small=f" {name} ")), GUI)

    def test_each_jobs_own_label_copy_matches_runs_on(self):
        for name in CASCADED:
            job_env = self.jobs[name].get("env") or {}
            if "CMUX_NEXT_RUNNER" in job_env and name != "release-compile":
                self.assertEqual(job_env["CMUX_NEXT_RUNNER"], self.jobs[name]["runs-on"], name)

    def test_the_placement_job_reads_the_snapshot_and_exports_the_cascade(self):
        job = self.jobs["macos-placement"]
        self.assertEqual(job["permissions"].get("actions"), "read")
        place = next(step for step in job["steps"] if step.get("id") == "place")
        # The pool snapshot reads with the glaeda read token (its own budget), else GITHUB_TOKEN.
        self.assertEqual(place["env"]["SNAPSHOT_TOKEN"], "${{ steps.snapshot-read-token.outputs.token || github.token }}")
        for output in ("blacksmith_12_jobs", "blacksmith_6_jobs", "nightly_runner_ready"):
            self.assertEqual(job["outputs"][output], f"${{{{ steps.place.outputs.{output} }}}}")
        self.assertFalse({"hosted_jobs", "hosted_runner"} & set(job["outputs"]))
        # A placement script that predates the free-slot rule (a pull request's old base) writes only
        # retry_runner, which may name a full label; the job reads the key only the new rule writes.
        self.assertEqual(job["outputs"]["retry_runner"], "${{ steps.place.outputs.free_retry_runner }}")
        self.assertEqual(set(cascade.CASCADE_JOBS), set(CASCADED))
        self.assertTrue(set(cascade.CASCADE_JOBS) <= set(place["env"]["JOBS"].split()))


if __name__ == "__main__":
    unittest.main()
