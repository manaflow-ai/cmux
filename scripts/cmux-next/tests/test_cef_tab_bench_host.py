#!/usr/bin/env python3
"""cef-tab-bench.py's host arms (p01-process-086): `--host` launches with the debug tunable `browserHost.helper`, and
`--host-spare-window` adds the bench-only feature `chromiumHostSpareWindow` as a Labs local choice, so one bench
measures the first Chromium tab with content's spare renderer alone and with a spare window.

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

    def test_no_flag_launches_in_process_unchanged(self):
        env, features = self.bench.host_launch(self.bench.parse([*self.required()]), self.scratch)
        self.assertEqual((env, features), ({}, {}))

    def test_host_writes_the_tunable_and_no_feature(self):
        env, features = self.bench.host_launch(self.bench.parse([*self.required(), "--host"]), self.scratch)
        self.assertEqual(features, {})
        with open(env["CMUX_NEXT_DEBUG_TUNABLES_FILE"]) as handle:
            self.assertEqual(json.load(handle), {"version": 1, "values": {"browserHost.helper": True}})

    def test_host_spare_window_turns_the_bench_feature_on(self):
        options = self.bench.parse([*self.required(), "--host", "--host-spare-window"])
        env, features = self.bench.host_launch(options, self.scratch)
        self.assertIn("CMUX_NEXT_DEBUG_TUNABLES_FILE", env)
        self.assertEqual(features, {"chromiumHostSpareWindow": True})

    def test_spare_window_without_host_is_refused(self):
        with self.assertRaises(SystemExit):
            self.bench.host_launch(self.bench.parse([*self.required(), "--host-spare-window"]), self.scratch)

    def test_the_feature_is_a_default_off_bench_only_app_feature(self):
        with open(FEATURES / "chromiumHostSpareWindow.json") as handle:
            feature = json.load(handle)
        self.assertEqual(feature["defaults"], {"dev": False, "nightly": False, "release": False})
        self.assertTrue(feature["benchOnly"])
        self.assertEqual(feature["process"], "app")

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
