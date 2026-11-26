#!/usr/bin/env python3
"""ios-live-duress.py's idle phase on stand-in ps output: the always-on simulator's CPU % and resident MB while nobody edits.

The checks: ps TIME in every form macOS prints parses to seconds; only processes whose command names the device count,
and the app's are split out; a process that started during the window counts from zero and one that ended drops out;
idle_cost reports CPU % of one core over the measured window next to the memory reader's numbers.
Run: python3 -I scripts/measure/tests/ios-live-duress-idle.test.py
"""
import importlib.util
import types
import unittest
from unittest import mock
from pathlib import Path

HERE = Path(__file__).resolve().parent
UDID = "11111111-2222-3333-4444-555555555555"
APP = f"/Users/x/sims/{UDID}/data/Containers/Bundle/Application/A/CmuxMobileApp.app/CmuxMobileApp"


def load():
    spec = importlib.util.spec_from_file_location("ios_live_duress", HERE.parent / "ios-live-duress.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Idle(unittest.TestCase):
    def setUp(self):
        self.m = load()

    def stub_ps(self, outputs):
        outputs = list(outputs)

        def sh(*args, env=None, check=True):
            if args[:2] == ("ps", "-axo") and args[2] == "pid=,time=,command=":
                return types.SimpleNamespace(stdout=outputs.pop(0), returncode=0)
            if args[:2] == ("ps", "-axo") and args[2] == "rss=,command=":
                return types.SimpleNamespace(stdout=f"204800 {APP}\n409600 launchd_sim /Users/x/sims/{UDID}/data\n", returncode=0)
            if args[0] == "memory_pressure":
                return types.SimpleNamespace(stdout="System-wide memory free percentage: 61%\n", returncode=0)
            raise AssertionError(args)

        self.m.sh = sh

    def test_cpu_seconds_forms(self):
        self.assertEqual(self.m.cpu_seconds("0:01.50"), 1.5)
        self.assertEqual(self.m.cpu_seconds("12:00.00"), 720)
        self.assertEqual(self.m.cpu_seconds("1:02:03.00"), 3723)
        self.assertEqual(self.m.cpu_seconds("2-00:00:01"), 172801)

    def test_only_the_device_counts_and_app_is_split(self):
        self.stub_ps([f"10 0:02.00 {APP}\n11 0:05.00 launchd_sim /Users/x/sims/{UDID}/data\n12 9:00.00 /usr/bin/other\n"])
        app, sim = self.m.cpu_used(UDID)
        self.assertEqual(app, {10: 2.0})
        self.assertEqual(sim, {10: 2.0, 11: 5.0})

    def test_window_counts_new_processes_from_zero(self):
        self.assertEqual(self.m.window_pct({1: 1.0, 2: 5.0}, {1: 2.0, 3: 0.5}, 10), 15.0)
        self.assertIsNone(self.m.window_pct({}, {}, 0))

    def test_idle_cost(self):
        self.stub_ps([f"10 0:02.00 {APP}\n11 0:05.00 launchd_sim {UDID}\n",
                      f"10 0:02.60 {APP}\n11 0:06.20 launchd_sim {UDID}\n"])
        ticks = iter([100.0, 160.0])
        with mock.patch.object(self.m.time, "sleep", lambda s: None), mock.patch.object(self.m.time, "monotonic", lambda: next(ticks)):
            got = self.m.idle_cost(UDID, 60)
        self.assertEqual(got["idle_s"], 60)
        self.assertEqual(got["app_cpu_pct"], 1.0)
        self.assertEqual(got["sim_cpu_pct"], 3.0)
        self.assertEqual((got["app_mb"], got["sim_mb"], got["host_free"]), (200, 600, "61%"))


if __name__ == "__main__":
    unittest.main()
