#!/usr/bin/env python3
"""split-scale-bench.py's background(): a window restored with many workspaces still comes to the cell's count."""
import importlib.util
import os
import sys
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ARGV, sys.argv = sys.argv, [sys.argv[0], "--app", "/nonexistent.app"]  # the bench parses its options on import
if sys.platform != "darwin":  # bench_memory and bench_power load libproc, which only macOS has; background() uses neither
    sys.modules.setdefault("bench_memory", types.ModuleType("bench_memory"))
    sys.modules.setdefault("bench_power", types.SimpleNamespace(wipe_state=None))
spec = importlib.util.spec_from_file_location("split_scale_bench", os.path.join(HERE, "split-scale-bench.py"))
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)
sys.argv = ARGV


class FakeStress:
    """The window: Home (whose close is refused) plus restored workspaces; every terminal is already busy."""

    def __init__(self, restored):
        self.ids = ["home"] + [f"w{i}" for i in range(restored)]
        self.refusals = []

    def workspaces(self):
        return [{"id": w} for w in self.ids]

    def workspace(self, wid):
        return {"id": wid} if wid in self.ids else None

    def action(self, name, params, target, focus):
        wid = target.split(":", 1)[1]
        if wid == "home":
            self.refusals.append(f"{name}: Home can't be closed.")
            return {"error": "Home can't be closed."}
        self.ids.remove(wid)
        return {}

    def new_workspace(self):
        self.ids.append(f"n{len(self.ids)}")
        return True

    def show(self, wid):
        self.shown = wid


class BackgroundTests(unittest.TestCase):
    def setUp(self):
        self.wait = bench.STRESS.wait
        bench.STRESS.wait = lambda predicate, seconds, step=0.25: predicate()

    def tearDown(self):
        bench.STRESS.wait = self.wait

    def test_a_window_restored_with_many_workspaces_comes_to_one(self):
        stress = FakeStress(restored=14)
        run = types.SimpleNamespace(stress=stress, busy_workspaces={f"w{i}" for i in range(14)})
        bench.background(run, 1, "w0")
        self.assertEqual(stress.ids, ["home", "w0"])
        self.assertEqual(run.home_workspaces, {"home"})
        self.assertEqual(stress.shown, "w0")


if __name__ == "__main__":
    unittest.main()
