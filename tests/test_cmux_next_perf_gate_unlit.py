#!/usr/bin/env python3
"""The perf gate's timed scenarios on a window that draws no frames (scripts/cmux-next/perf-gate.py).

debug.tab_switch and debug.new_workspace time each switch or row against the display link's
frames, so an occluded or unlit console (the PR scheme lane's runner) times none. With
--frames auto that is the frame probe's skip (a warning) like every other frame check, not
"timed 0 of 40" failures; with --frames required (the GUI host) it still fails, and a window
that draws but times nothing still fails.
"""
import importlib.util
import itertools
import os
import sys
import types
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
spec = importlib.util.spec_from_file_location("perf_gate", os.path.join(ROOT, "scripts/cmux-next/perf-gate.py"))
perf_gate = importlib.util.module_from_spec(spec)
sys.path.insert(0, os.path.join(ROOT, "scripts/cmux-next"))
spec.loader.exec_module(perf_gate)


class FakeApp:
    """The automation calls the tabs and new_workspaces scenarios make; the timers record nothing."""

    def __init__(self, lit):
        self.lit, self.workspaces, self.tabs = lit, ["w1"], itertools.cycle(["t1", "t2", "t3"])

    def draws(self):
        return (self.lit, {"frames": 60 if self.lit else 8, "refresh_ms": 16.7 if self.lit else 0})

    def rpc(self, method, params=None, timeout=None):
        if method == "action.run" and (params or {}).get("action") == "newTab":
            self.workspaces.append(f"w{len(self.workspaces) + 1}")
        return {}

    def action(self, name, args=None, target=None):
        if name == "closeWorkspace":
            # The app action now carries the workspace id in its typed target
            # (`workspace:<id>`); keep the fixture on that public invocation
            # shape so cleanup exercises the same path as the real gate.
            self.workspaces.remove(target.split(":", 1)[1])

    def workspace_ids(self):
        return list(self.workspaces)

    def topology(self):
        return {"focus": {"tab": next(self.tabs)}}

    def quiet_counters(self, during=None):
        if during:
            during()
        return {**{key: 0 for key in perf_gate.BUDGET["tabs"]}, "sources": {}}

    def settle(self):
        pass


class UnlitWindowTests(unittest.TestCase):
    def setUp(self):
        del perf_gate.failures[:], perf_gate.warnings[:]
        perf_gate.report.update({"checks": [], "phases": {}})

    def gate(self, lit, frames="auto"):
        gate = perf_gate.Gate(FakeApp(lit), types.SimpleNamespace(frames=frames, only=None))
        gate.grid = (16, 48)
        return gate

    def run_timed(self, gate):
        gate.tabs()
        gate.new_workspaces()

    def test_an_unlit_window_skips_the_timed_counts_with_a_warning(self):
        self.run_timed(self.gate(lit=False))
        self.assertEqual(perf_gate.failures, [])
        self.assertTrue(any("draws no frames" in w for w in perf_gate.warnings), perf_gate.warnings)

    def test_an_unlit_window_fails_when_frames_are_required(self):
        self.run_timed(self.gate(lit=False, frames="required"))
        self.assertTrue(perf_gate.failures)
        self.assertTrue(all("draws no frames" in f for f in perf_gate.failures), perf_gate.failures)

    def test_a_lit_window_that_times_nothing_fails(self):
        self.run_timed(self.gate(lit=True))
        self.assertIn("[tabs] debug.tab_switch timed 0 of 40 switches", perf_gate.failures)
        self.assertIn("[new_workspaces] debug.new_workspace timed 0 of 50 new workspace rows", perf_gate.failures)


if __name__ == "__main__":
    unittest.main()
