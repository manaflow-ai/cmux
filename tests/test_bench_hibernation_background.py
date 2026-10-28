#!/usr/bin/env python3
"""The hidden-renderer phase of scripts/cmux-next/bench_hibernation.py (task p07-memory-110): the task role
read through idle-budget's observed_role, one sample point, the per-mode summary and the follow-up verdict.
Runs on any OS: the macOS-only modules the bench imports (bench_power, bench_renderer_sharing) are stubs."""
from __future__ import annotations

import argparse
import contextlib
import io
import os
import sys
import types
import unittest

SCRIPTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts", "cmux-next")


def load_bench():
    for name in ("bench_power", "bench_renderer_sharing"):
        sys.modules.setdefault(name, types.ModuleType(name))
    sys.path.insert(0, SCRIPTS)
    try:
        import bench_hibernation
    finally:
        sys.path.remove(SCRIPTS)
    return bench_hibernation


bench = load_bench()
MB = int(bench.bm.MB)


def quiet(call, *args, **kwargs):
    with contextlib.redirect_stdout(io.StringIO()):
        return call(*args, **kwargs)


def row(at_s, pmf, roles, frozen=0, tabs=4):
    return {"at_s": at_s, "per_hidden_tab_pmf_mb": pmf, "renderer_task_role": roles, "frozen": frozen, "tabs": tabs}


class TaskRoleTests(unittest.TestCase):
    def test_roles_come_from_the_idle_audit_reader(self):
        priorities = {10: {"base": 4, "darwinbg": False}, 11: {"base": 31, "darwinbg": True},
                      12: {"base": 31, "darwinbg": False}, 13: {"base": None, "darwinbg": None}}
        got = bench.task_roles([10, 11, 12, 13, 14], priorities_of=lambda pids: {p: priorities[p] for p in pids
                                                                                 if p in priorities})
        self.assertEqual(got, {10: {"role": "suppressed", "base": 4}, 11: {"role": "darwinbg", "base": 31},
                               12: {"role": "default", "base": 31}, 13: {"role": None, "base": None}})

    def test_chrome_best_effort_roles_count_as_backgrounded(self):
        self.assertEqual(bench.backgrounded_roles(), {"darwinbg", "suppressed"})


class PointTests(unittest.TestCase):
    def test_a_point_averages_each_hidden_pages_own_renderers(self):
        renderers = {"tab_a": [1], "tab_b": [2, 3], "tab_c": [4], "front": [9]}
        footprints = {1: 100 * MB, 2: 50 * MB, 3: 30 * MB, 9: 200 * MB}  # pid 4 is gone
        roles = {1: {"role": "suppressed", "base": 4}, 2: {"role": "suppressed", "base": 4},
                 3: {"role": "default", "base": 31}, 4: {"role": "default", "base": 31},
                 9: {"role": "default", "base": 31}}
        got = quiet(bench.hidden_point, "off", 30, 0.0, ["tab_a", "tab_b", "tab_c"], renderers, "front", {"tab_a"},
                    footprint_of=footprints.get, roles_of=lambda pids: {p: roles[p] for p in pids})
        self.assertEqual(got["measured_tabs"], 2)
        self.assertEqual(got["per_hidden_tab_pmf_mb"], 90.0)
        self.assertEqual(got["max_hidden_tab_pmf_mb"], 100.0)
        self.assertEqual(got["renderer_task_role"], {"suppressed": 2, "default": 1})
        self.assertEqual(got["renderer_base_priority"], [4, 4, 31])
        self.assertEqual(got["front_task_role"], "default")
        self.assertEqual(got["frozen"], 1)


class SummaryTests(unittest.TestCase):
    BACKGROUND = {"darwinbg", "suppressed"}

    def summary(self, mode, rows):
        return quiet(bench.timeline_summary, mode, rows, self.BACKGROUND)

    def test_backgrounded_and_purged_needs_no_follow_up(self):
        rows = [row(0, 120.0, {"default": 4}), row(30, 118.0, {"suppressed": 4}),
                row(300, 70.0, {"suppressed": 4}), row(600, 60.0, {"darwinbg": 4}, frozen=4)]
        got = self.summary("on", rows)
        self.assertTrue(got["backgrounded"])
        self.assertTrue(got["pmf_falls"])
        self.assertEqual(got["fell_mb"], 60.0)
        self.assertEqual(got["pmf_mb"], {"0s": 120.0, "30s": 118.0, "300s": 70.0, "600s": 60.0})
        self.assertEqual(bench.background_verdict([got, got]), "none")

    def test_pmf_that_stays_files_the_shim_visibility_fix(self):
        rows = [row(0, 120.0, {"default": 4}), row(30, 121.0, {"default": 4}),
                row(300, 119.0, {"default": 4}), row(600, 118.0, {"default": 4})]
        got = self.summary("off", rows)
        self.assertFalse(got["backgrounded"])
        self.assertFalse(got["pmf_falls"])
        self.assertEqual(bench.background_verdict([got]), "shim-visibility")

    def test_one_renderer_left_in_the_foreground_is_not_backgrounded(self):
        got = self.summary("off", [row(0, 100.0, {}), row(30, 99.0, {"suppressed": 3, "default": 1}),
                                   row(600, 50.0, {"suppressed": 4})])
        self.assertFalse(got["backgrounded"])
        self.assertTrue(got["pmf_falls"])

    def test_one_mode_without_a_purge_files_the_fix(self):
        purged = self.summary("on", [row(0, 100.0, {"suppressed": 4}), row(30, 99.0, {"suppressed": 4}),
                                     row(600, 50.0, {"suppressed": 4})])
        kept = self.summary("off", [row(0, 100.0, {"suppressed": 4}), row(30, 99.0, {"suppressed": 4}),
                                    row(600, 98.0, {"suppressed": 4})])
        self.assertEqual(bench.background_verdict([kept, purged]), "shim-visibility")

    def test_no_measured_renderer_is_unmeasured_not_a_follow_up(self):
        got = self.summary("off", [row(0, None, {}), row(30, None, {}), row(600, None, {})])
        self.assertFalse(got["backgrounded"])
        self.assertFalse(got["measured"])
        self.assertIsNone(got["fell_mb"])
        self.assertEqual(bench.background_verdict([got]), "unmeasured")
        self.assertEqual(bench.background_verdict([]), "unmeasured")

    def test_a_missing_first_or_last_pmf_is_unmeasured(self):
        for pmf in ((None, 99.0, 50.0), (100.0, 99.0, None)):
            got = self.summary("on", [row(0, pmf[0], {"suppressed": 4}), row(30, pmf[1], {"suppressed": 4}),
                                      row(600, pmf[2], {"suppressed": 4})])
            self.assertFalse(got["measured"])
            self.assertEqual(bench.background_verdict([got]), "unmeasured")

    def test_unread_roles_at_the_role_point_are_unmeasured(self):
        for roles in ({}, {"unread": 4}, {"suppressed": 3, "unread": 1}):
            got = self.summary("off", [row(0, 100.0, {"default": 4}), row(30, 99.0, roles),
                                       row(600, 98.0, {"default": 4})])
            self.assertFalse(got["measured"])
            self.assertEqual(bench.background_verdict([got]), "unmeasured")

    def test_one_unmeasured_mode_makes_the_run_unmeasured(self):
        kept = self.summary("off", [row(0, 100.0, {"default": 4}), row(30, 99.0, {"default": 4}),
                                    row(600, 98.0, {"default": 4})])
        broken = self.summary("on", [row(0, None, {}), row(30, None, {}), row(600, None, {})])
        self.assertTrue(kept["measured"])
        self.assertEqual(bench.background_verdict([kept]), "shim-visibility")
        self.assertEqual(bench.background_verdict([kept, broken]), "unmeasured")


class ArgumentTests(unittest.TestCase):
    def test_points_are_sorted_unique_seconds(self):
        self.assertEqual(bench.seconds_list("600,0,30,300,30"), [0.0, 30.0, 300.0, 600.0])
        for bad in ("", "-1,30", "a,b"):
            with self.assertRaises(argparse.ArgumentTypeError):
                bench.seconds_list(bad)

    def test_freeze_modes(self):
        self.assertEqual(bench.freeze_modes("off,on"), ["off", "on"])
        self.assertEqual(bench.freeze_modes("on"), ["on"])
        for bad in ("", "maybe", "on,on"):
            with self.assertRaises(argparse.ArgumentTypeError):
                bench.freeze_modes(bad)

    def test_the_timeline_parses_with_its_defaults(self):
        args = bench.parse(["--app", "/tmp/cmux DEV p110.app", "--background-timeline", "0,30,300,600"])
        self.assertEqual(args.background_timeline, [0.0, 30.0, 300.0, 600.0])
        self.assertEqual(args.background_freeze, ["off", "on"])
        # No pinned heap: a live array is memory no purge can free, and it would dilute the PMF fall.
        self.assertEqual(args.heap_mb, 0)
        self.assertEqual(args.feature, [])

    def test_heap_defaults_to_a_site_heap_outside_the_timeline(self):
        self.assertEqual(bench.parse(["--app", "/tmp/cmux DEV p110.app"]).heap_mb, 40)
        self.assertEqual(bench.parse(["--app", "/tmp/cmux DEV p110.app", "--background-timeline", "0,30",
                                      "--heap-mb", "8"]).heap_mb, 8)
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            bench.parse(["--app", "/tmp/cmux DEV p110.app", "--heap-mb", "-1"])

    def test_feature_choices(self):
        args = bench.parse(["--app", "/tmp/cmux DEV p110.app", "--background-timeline", "0,30",
                            "--feature", "chromiumTabVisibility=on", "--feature", "other=off"])
        self.assertEqual(dict(args.feature), {"chromiumTabVisibility": True, "other": False})
        for bad in ("chromiumTabVisibility", "=on", "chromiumTabVisibility=yes"):
            with self.assertRaises(argparse.ArgumentTypeError):
                bench.feature_choice(bad)

    def test_an_attached_app_keeps_its_own_features(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            bench.parse(["--app", "/tmp/cmux DEV p110.app", "--socket", "/tmp/s.sock", "--app-pid", "1",
                         "--feature", "chromiumTabVisibility=on"])


class FeatureTests(unittest.TestCase):
    def test_the_launch_snapshot_names_the_features(self):
        launched = types.SimpleNamespace(features=({"chromiumTabVisibility": {"state": "on", "source": "local"}},
                                                   "hash", False))
        self.assertEqual(bench.launched_features(launched, "/unused.sock"),
                         {"chromiumTabVisibility": {"state": "on", "source": "local"}})

    def test_an_attached_app_answers_features_list(self):
        replies = {"features.list": {"features": [{"name": "chromiumTabVisibility", "state": "off",
                                                   "source": "default"}]}}
        stub = sys.modules["bench_power"]
        had = getattr(stub, "rpc", None)
        stub.rpc = lambda sock, method, params=None, timeout=None: replies.get(method, {"error": "unknown"})
        try:
            self.assertEqual(bench.launched_features(None, "/tmp/s.sock"),
                             {"chromiumTabVisibility": {"state": "off", "source": "default"}})
            replies.clear()
            self.assertIsNone(bench.launched_features(None, "/tmp/s.sock"))
        finally:
            if had is None:
                del stub.rpc
            else:
                stub.rpc = had


if __name__ == "__main__":
    unittest.main()
