#!/usr/bin/env python3
"""cef-tab-bench.py's host arms (p01-process-086): `--host` launches with the debug tunable `browserHost.helper`, and
`--host-no-spare-window` adds the bench-only feature `chromiumHostNoSpareWindow` as a Labs local choice, so one bench
measures the first Chromium tab in the host with and without the spare window. The bench refuses an app that does
not run the arm (`debug.cef` `backend`, `warmup_spare_windows`), and each arm records into its own story.

Runs on any host (Linux included): no app, no daemon, no fleet, no network.

    python3 -m unittest scripts/cmux-next/tests/test_cef_tab_bench_host.py
"""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
FEATURES = HERE.parent.parent / "schemas" / "features" / "features.d"
sys.path.insert(0, str(HERE))


def load_bench():
    spec = importlib.util.spec_from_file_location("cef_tab_bench", HERE / "cef-tab-bench.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class HostArmTests(unittest.TestCase):
    def setUp(self):
        self.bench = load_bench()
        self.scratch = tempfile.mkdtemp(prefix="cef-tab-host-test-")

    def options(self, *flags):
        return self.bench.parse([*self.required(), *flags])

    def test_no_flag_launches_in_process_unchanged(self):
        env, features = self.bench.host_launch(self.options(), self.scratch)
        self.assertEqual((env, features), ({}, {}))

    def test_host_writes_the_tunable_and_no_feature(self):
        env, features = self.bench.host_launch(self.options("--host"), self.scratch)
        self.assertEqual(features, {})
        with open(env["CMUX_NEXT_DEBUG_TUNABLES_FILE"]) as handle:
            self.assertEqual(json.load(handle), {"version": 1, "values": {"browserHost.helper": True}})

    def test_host_no_spare_window_turns_the_bench_feature_on(self):
        env, features = self.bench.host_launch(self.options("--host", "--host-no-spare-window"), self.scratch)
        self.assertIn("CMUX_NEXT_DEBUG_TUNABLES_FILE", env)
        self.assertEqual(features, {"chromiumHostNoSpareWindow": True})

    def test_no_spare_window_without_host_is_refused(self):
        with self.assertRaises(SystemExit):
            self.bench.host_launch(self.options("--host-no-spare-window"), self.scratch)

    def test_the_feature_is_a_default_off_bench_only_app_feature(self):
        with open(FEATURES / "chromiumHostNoSpareWindow.json") as handle:
            feature = json.load(handle)
        self.assertEqual(feature["defaults"], {"dev": False, "nightly": False, "release": False})
        self.assertTrue(feature["benchOnly"])
        self.assertEqual(feature["process"], "app")

    def test_an_in_process_backend_refuses_the_host_arms(self):
        # A build where the host is not selectable (every non-Debug build, or no host supervisor) runs Chromium in
        # process: the host arms refuse instead of labelling those numbers as the host's.
        cef = {"backend": "inProcess", "warmup_spare_windows": True}
        for flags in (("--host",), ("--host", "--host-no-spare-window")):
            refusal = self.bench.arm_refusal(self.options(*flags), cef)
            self.assertIn("backend 'inProcess'", refusal or "", flags)
        self.assertIsNone(self.bench.arm_refusal(self.options(), cef))
        self.assertIsNotNone(self.bench.arm_refusal(self.options("--host"), {"error": "no socket"}))
        self.assertIsNotNone(self.bench.arm_refusal(self.options("--host"), None))

    def test_the_arm_must_take_effect(self):
        host = self.options("--host")
        no_spare = self.options("--host", "--host-no-spare-window")
        self.assertIsNone(self.bench.arm_refusal(host, {"backend": "host", "warmup_spare_windows": True}))
        self.assertIsNone(self.bench.arm_refusal(no_spare, {"backend": "host", "warmup_spare_windows": False}))
        self.assertIn("--host-no-spare-window",
                      self.bench.arm_refusal(no_spare, {"backend": "host", "warmup_spare_windows": True}) or "")
        self.assertIsNotNone(self.bench.arm_refusal(host, {"backend": "host", "warmup_spare_windows": False}))
        # A warm-up that never started, or a build without the field, proves neither arm.
        self.assertIsNotNone(self.bench.arm_refusal(no_spare, {"backend": "host", "warmup_spare_windows": None}))
        self.assertIsNotNone(self.bench.arm_refusal(host, {"backend": "host"}))

    def test_each_arm_records_into_its_own_story(self):
        story = self.bench.results.NEW_BROWSER_TAB_STORY
        stories = [self.bench.arm_story(self.options(*flags))
                   for flags in ((), ("--host",), ("--host", "--host-no-spare-window"))]
        self.assertEqual(stories, [story, f"{story}-host", f"{story}-host-no-spare-window"])
        rows = [{"session": "light", "case": "cold_pane", "visible_ms": 50.0}]
        series = self.bench.results.new_browser_tab_series(rows, ["cold_pane"], stories[1])
        self.assertTrue(series)
        self.assertEqual({entry.story for entry in series}, {f"{story}-host"})

    def test_no_chromium_feature_turns_content_spare_renderer_off(self):
        # Chrome desktop keeps its spare RenderProcessHost at all times only under site-per-process with
        # kSpareRendererForSitePerProcess (content/browser/renderer_host/render_process_host_impl.cc,
        # IsSpareProcessKeptAtAllTimes): no app feature may name either Chromium feature.
        names = set()
        for path in FEATURES.glob("*.json"):
            with open(path) as handle:
                names.add(json.load(handle).get("chromium_feature"))
        self.assertFalse(names & {"SpareRendererForSitePerProcess", "SitePerProcess"}, names)

    @staticmethod
    def required():
        return ["--tag", "t", "--app", "/nonexistent/cmux DEV t.app"]


if __name__ == "__main__":
    unittest.main()
