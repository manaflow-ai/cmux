#!/usr/bin/env python3
"""bench-webui.py priority-roles (task p13-webui-083): the pure parts, on any OS.

1. procs.role_of reads a backgrounded process from its threads' priority ceilings: MAXPRI_THROTTLE (Chrome's
   kBestEffort: low-priority CPU), MAXPRI_SUPPRESSED (App Nap); an uncapped one by its main thread's base priority.
2. The extension renderer is its own kind and never judged.
3. D12: in all-hidden every page renderer is backgrounded; in one-shown at most one is above background.
4. The QoS split names the class that ran most of the window's CPU.
5. The purge row compares page renderer footprint between the arms.
6. The dispatcher parses the mode and refuses an unknown page before it launches anything.
"""
from __future__ import annotations

import importlib.util
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
sys.path.insert(0, SCRIPTS)
sys.path.insert(0, os.path.join(SCRIPTS, "..", "perf-bench"))
import bench_webui_priority as prio  # noqa: E402
import procs  # noqa: E402

spec = importlib.util.spec_from_file_location("bench_webui", os.path.join(SCRIPTS, "bench-webui.py"))
bench_webui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench_webui)

RENDERER = "/A/cmux DEV x.app/Contents/Frameworks/cmux Helper (Renderer).app/Contents/MacOS/cmux Helper (Renderer) --type=renderer"


def process(kind, role, footprint=10.0, qos=None):
    return {"pid": 1, "kind": kind, "role": role, "qos": qos, "footprint_mb": footprint, "cpu_pct": 0.1,
            "wakeups_per_s": 1.0}


class RoleTests(unittest.TestCase):
    def test_best_effort_caps_every_thread_at_throttle(self):
        self.assertEqual(procs.role_of([(4, 4), (4, 4)]), "throttled")

    def test_app_nap_caps_at_suppressed(self):
        self.assertEqual(procs.role_of([(28, 28), (20, 28)]), "suppressed")

    def test_one_uncapped_thread_means_not_backgrounded(self):
        self.assertEqual(procs.role_of([(4, 4), (31, 63)]), "default")

    def test_uncapped_roles_follow_the_main_thread(self):
        self.assertEqual(procs.role_of([(47, 63), (31, 63)]), "foreground")
        self.assertEqual(procs.role_of([(46, 63)]), "background-role")
        self.assertEqual(procs.role_of([(31, 63)]), "default")

    def test_unreadable_is_unknown_and_not_backgrounded(self):
        self.assertEqual(procs.role_of(None), "unknown")
        self.assertNotIn("unknown", procs.BACKGROUNDED_ROLES)
        self.assertNotIn("background-role", procs.BACKGROUNDED_ROLES)

    def test_readers_answer_none_off_macos(self):
        if sys.platform == "darwin":
            self.skipTest("libproc is there")
        self.assertIsNone(procs.thread_priorities(os.getpid()))
        self.assertIsNone(procs.qos_cpu_ns(os.getpid()))


class KindTests(unittest.TestCase):
    def test_extension_renderer_is_apart(self):
        self.assertEqual(prio.kind_of(RENDERER), "renderer")
        self.assertEqual(prio.kind_of(RENDERER + " --extension-process"), "renderer:extension")
        self.assertNotIn("renderer:extension", prio.PAGE_RENDERER_KINDS)

    def test_webkit_web_content_is_a_page_renderer(self):
        cmd = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/x"
        self.assertIn(prio.kind_of(cmd), prio.PAGE_RENDERER_KINDS)


class BreachTests(unittest.TestCase):
    def rows(self, *processes):
        return prio.kind_rows(list(processes))

    def test_all_hidden_needs_every_page_renderer_backgrounded(self):
        rows = self.rows(process("renderer", "throttled"), process("renderer", "default"))
        found = prio.breaches("all-hidden", rows, 0)
        self.assertEqual(len(found), 1)
        self.assertIn("above_background=1 allowed=0", found[0])
        self.assertEqual(prio.breaches("all-hidden", self.rows(process("renderer", "suppressed")), 0), [])

    def test_one_shown_allows_one_renderer_above_background(self):
        rows = self.rows(process("renderer", "foreground"), process("renderer", "throttled"))
        self.assertEqual(prio.breaches("one-shown", rows, 1), [])
        rows = self.rows(process("renderer", "foreground"), process("renderer", "default"))
        self.assertEqual(len(prio.breaches("one-shown", rows, 1)), 1)

    def test_other_kinds_are_reported_not_judged(self):
        rows = self.rows(process("main", "foreground"), process("gpu", "default"), process("renderer:extension", "default"))
        self.assertEqual(prio.breaches("all-hidden", rows, 0), [])
        self.assertEqual(rows["main"]["roles"], {"foreground": 1})

    def test_kind_row_sums(self):
        rows = self.rows(process("renderer", "throttled", 30.0, "background"), process("renderer", "default", 12.5, "user_interactive"))
        row = rows["renderer"]
        self.assertEqual((row["n"], row["backgrounded"], row["footprint_mb"]), (2, 1, 42.5))
        self.assertEqual(row["qos"], {"background": 1, "user_interactive": 1})


class QosTests(unittest.TestCase):
    def test_top_class_and_share(self):
        before = {name: 0 for name in procs.QOS_CLASSES}
        after = dict(before, background=300, user_interactive=100)
        self.assertEqual(prio.top_qos(before, after), ("background", 0.75))

    def test_no_cpu_is_none(self):
        zeros = {name: 5 for name in procs.QOS_CLASSES}
        self.assertEqual(prio.top_qos(zeros, zeros), (None, None))
        self.assertEqual(prio.top_qos(None, None), (None, None))


class SpreadTests(unittest.TestCase):
    def test_percentiles_skip_misses(self):
        got = prio.spread([10.0, None, 30.0, 20.0])
        self.assertEqual((got["n"], got["landed"], got["p50"], got["max"]), (4, 3, 20.0, 30.0))
        self.assertIsNone(prio.spread([None])["p95"])


class PurgeTests(unittest.TestCase):
    def test_gain_counts_page_renderers_only(self):
        base = {"kinds": prio.kind_rows([process("renderer", "throttled", 80.0), process("main", "foreground", 300.0)])}
        purge = {"kinds": prio.kind_rows([process("renderer", "throttled", 55.0), process("main", "foreground", 310.0)])}
        self.assertEqual(prio.purge_gain(base, purge), {"base_mb": 80.0, "purge_mb": 55.0, "gain_mb": 25.0})


class DispatcherTests(unittest.TestCase):
    def test_priority_arguments(self):
        args = bench_webui.module_parser("priority-roles").parse_args(
            ["--app", "/x.app", "--engine", "webkit", "--pages", "apps,settings"])
        self.assertEqual((args.mode, args.engine, args.pages, args.purge_arm),
                         ("priority-roles", "webkit", ["apps", "settings"], False))

    def test_unknown_page_is_refused_before_launch(self):
        with self.assertRaises(SystemExit) as raised:
            bench_webui.main(["priority-roles", "--app", "/x.app", "--pages", "nope"])
        self.assertIn("--pages takes", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
