#!/usr/bin/env python3
"""The hidden-renderer phase of scripts/cmux-next/bench_hibernation.py: the task role read from the
base priority, the per-mode summary and the follow-up verdict. Runs on any OS: the macOS-only
modules the bench imports are replaced by stubs."""
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
    for name in ("bench_memory", "bench_power", "bench_renderer_sharing"):
        sys.modules.setdefault(name, types.ModuleType(name))
    sys.path.insert(0, SCRIPTS)
    try:
        import bench_hibernation
    finally:
        sys.path.remove(SCRIPTS)
    return bench_hibernation


bench = load_bench()


def row(at_s, pmf, roles, frozen=0, tabs=4):
    return {"at_s": at_s, "per_hidden_tab_pmf_mb": pmf, "renderer_task_role": roles, "frozen": frozen, "tabs": tabs}


def summary(mode, rows):
    with contextlib.redirect_stdout(io.StringIO()):
        return bench.timeline_summary(mode, rows)


class TaskRoleTests(unittest.TestCase):
    def test_base_priorities_name_the_role(self):
        self.assertEqual(bench.role_name(47), "foreground")
        self.assertEqual(bench.role_name(46), "background")
        self.assertEqual(bench.role_name(31), "default")
        self.assertEqual(bench.role_name(4), "throttled")
        self.assertEqual(bench.role_name(37), "pri37")


class SummaryTests(unittest.TestCase):
    def test_backgrounded_and_purged_needs_no_follow_up(self):
        rows = [row(0, 120.0, {"foreground": 4}), row(30, 118.0, {"background": 4}),
                row(300, 70.0, {"background": 4}), row(600, 60.0, {"background": 4}, frozen=4)]
        got = summary("on", rows)
        self.assertTrue(got["backgrounded"])
        self.assertTrue(got["pmf_falls"])
        self.assertEqual(got["fell_mb"], 60.0)
        self.assertEqual(got["pmf_mb"], {"0s": 120.0, "30s": 118.0, "300s": 70.0, "600s": 60.0})
        self.assertEqual(bench.background_verdict([got, got]), "none")

    def test_pmf_that_stays_files_the_shim_visibility_fix(self):
        rows = [row(0, 120.0, {"default": 4}), row(30, 121.0, {"default": 4}),
                row(300, 119.0, {"default": 4}), row(600, 118.0, {"default": 4})]
        got = summary("off", rows)
        self.assertFalse(got["backgrounded"])
        self.assertFalse(got["pmf_falls"])
        self.assertEqual(bench.background_verdict([got]), "shim-visibility")

    def test_one_mode_without_a_purge_files_the_fix(self):
        purged = summary("on", [row(0, 100.0, {"background": 4}), row(30, 99.0, {"background": 4}),
                                row(600, 50.0, {"background": 4})])
        kept = summary("off", [row(0, 100.0, {"background": 4}), row(30, 99.0, {"background": 4}),
                               row(600, 98.0, {"background": 4})])
        self.assertEqual(bench.background_verdict([kept, purged]), "shim-visibility")

    def test_no_measured_renderer_is_not_backgrounded(self):
        got = summary("off", [row(0, None, {}), row(30, None, {}), row(600, None, {})])
        self.assertFalse(got["backgrounded"])
        self.assertIsNone(got["fell_mb"])
        self.assertEqual(bench.background_verdict([got]), "shim-visibility")
        self.assertEqual(bench.background_verdict([]), "shim-visibility")


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


if __name__ == "__main__":
    unittest.main()
