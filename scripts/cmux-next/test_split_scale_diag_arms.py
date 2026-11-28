#!/usr/bin/env python3
"""split-scale-bench.py's diagnostic arms: each arm measures one cell in its own app, and its rows stay out of the
matrix (cells, verdicts, headline), so benches.split_scale.score never reads them."""
import importlib.util
import os
import sys
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))


def load(*args):
    argv, sys.argv = sys.argv, [sys.argv[0], "--app", "/nonexistent.app", *args]  # the bench parses on import
    stubs = {} if sys.platform == "darwin" else {
        "bench_memory": types.ModuleType("bench_memory"), "bench_power": types.SimpleNamespace(wipe_state=None)}
    for name, stub in stubs.items():
        sys.modules.setdefault(name, stub)
    try:
        spec = importlib.util.spec_from_file_location("split_scale_bench_diag", os.path.join(HERE, "split-scale-bench.py"))
        bench = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(bench)
        return bench
    finally:
        sys.argv = argv
        for name, stub in stubs.items():
            if sys.modules.get(name) is stub:
                del sys.modules[name]


class DiagArms(unittest.TestCase):
    def test_no_arm_by_default(self):
        self.assertEqual(load().DIAG_ARMS, [])

    def test_arm_spec_parses(self):
        bench = load("--diag-arm=fence0:CMUX_CEF_RESIZE_FENCE=0", "--diag-arm=both:A=1;B=2")
        self.assertEqual(bench.DIAG_ARMS, [("fence0", {"CMUX_CEF_RESIZE_FENCE": "0"}), ("both", {"A": "1", "B": "2"})])
        self.assertEqual(bench.DIAG_TRANSITIONS, ["close_right", "close_down", "bottom_close"])

    def test_bad_specs_refuse(self):
        for spec in ("fence0", "control:A=1", "x y:A=1", "f:=1"):
            with self.assertRaises(SystemExit, msg=spec):
                load(f"--diag-arm={spec}")
        with self.assertRaises(SystemExit):
            load("--diag-arm=f:A=1", "--diag-cell=s9-chat-w10")
        with self.assertRaises(SystemExit):
            load("--diag-arm=f:A=1", "--diag-transitions=close_sideways")

    def test_arms_measure_apart_from_the_matrix(self):
        bench = load("--diag-arm=fence0:CMUX_CEF_RESIZE_FENCE=0", "--diag-arm=broken:X=1", "--rounds=1")
        launched, closed = [], []

        class FakeRun:
            def __init__(self, env):
                self.env = env
                launched.append(env)

            def end(self):
                closed.append(self.env)

        def start_app(run, results):
            if run.env.get("X"):
                raise RuntimeError("no window")

        def run_cell(run, workspace, columns, results, cell, content):
            self.assertEqual(bench.WANTED, ["close_right", "close_down", "bottom_close"])
            results["raw"].setdefault(cell, {}).setdefault("close_right", []).append({"settled_ms": 500})

        bench.Run, bench.start_app, bench.run_cell = FakeRun, start_app, run_cell
        bench.wipe_state = lambda app: None
        bench.build_cell = lambda run, splits, content, chats: ("w", [["p"]])
        bench.background = lambda run, count, workspace: None
        bench.close_cell = lambda run, workspace: None
        bench.ssm = types.SimpleNamespace(summarize=lambda rows: {"rounds": len(rows)})
        wanted = list(bench.WANTED)
        results = {"raw": {"s1-empty-w1": {}}, "errors": {}}
        bench.run_diag_arms(results, {"BASE": "1"})
        arms = results["diagnostic_arms"]["arms"]
        self.assertEqual(list(arms), ["control", "fence0", "broken"])
        self.assertEqual(launched, [{"BASE": "1"}, {"BASE": "1", "CMUX_CEF_RESIZE_FENCE": "0"}, {"BASE": "1", "X": "1"}])
        self.assertEqual(len(closed), 3)  # every arm's app ends, the failed one too
        self.assertEqual(arms["fence0"]["cells"], {"s9-browser-w10": {"close_right": {"rounds": 1}}})
        self.assertIn("no window", arms["broken"]["errors"]["arm"])
        self.assertEqual(results["raw"], {"s1-empty-w1": {}})  # the matrix's rows are untouched
        self.assertEqual(results["errors"], {})
        self.assertEqual(bench.WANTED, wanted)

    def test_an_arm_names_its_own_cell(self):
        bench = load("--diag-arm=fence0:CMUX_CEF_RESIZE_FENCE=0",
                     "--diag-arm=keep@s9-browser-w30/divider_drag:CMUX_CEF_DRAG_KEEP_ATTACHED=1", "--rounds=1")
        self.assertEqual(bench.DIAG_ARMS[1], ("keep", {"CMUX_CEF_DRAG_KEEP_ATTACHED": "1"}))
        groups = bench.diag_groups()
        self.assertEqual([(cell, moves, control, [n for n, _ in arms]) for cell, moves, control, arms in groups], [
            ("s9-browser-w10", ["close_right", "close_down", "bottom_close"], "control", ["fence0"]),
            ("s9-browser-w30", ["divider_drag"], "control@s9-browser-w30", ["keep"])])
        seen = []

        class FakeRun:
            def __init__(self, env):
                self.env = env

            def end(self):
                pass

        def run_cell(run, workspace, columns, results, cell, content):
            seen.append((cell, list(bench.WANTED), dict(run.env)))

        bench.Run, bench.start_app, bench.run_cell = FakeRun, lambda run, results: None, run_cell
        bench.wipe_state = lambda app: None
        bench.build_cell = lambda run, splits, content, chats: ("w", [["p"]])
        bench.background = lambda run, count, workspace: None
        bench.close_cell = lambda run, workspace: None
        bench.ssm = types.SimpleNamespace(summarize=lambda rows: {"rounds": len(rows)})
        results = {"raw": {}, "errors": {}}
        bench.run_diag_arms(results, {})
        self.assertEqual(list(results["diagnostic_arms"]["arms"]), ["control", "fence0", "control@s9-browser-w30", "keep"])
        self.assertEqual(seen[3], ("s9-browser-w30", ["divider_drag"], {"CMUX_CEF_DRAG_KEEP_ATTACHED": "1"}))
        self.assertEqual(results["diagnostic_arms"]["arms"]["keep"]["cell"], "s9-browser-w30")

    def test_a_bad_arm_scope_refuses(self):
        for spec in ("k@s9-chat-w10:A=1", "k@s9-browser-w10/sideways:A=1", "k@nope:A=1"):
            with self.assertRaises(SystemExit, msg=spec):
                load(f"--diag-arm={spec}")


if __name__ == "__main__":
    unittest.main()
