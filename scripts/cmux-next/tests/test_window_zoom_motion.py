#!/usr/bin/env python3
"""Exercise the window-motion measurement with synthetic native display samples.

Run: python3 -I scripts/cmux-next/tests/test_window_zoom_motion.py
No app, display, subprocess or sleep is needed. Execute the actual measurement function
without the script's top-level app launch, using the shared golden motion analysis.
"""
import ast
import contextlib
import io
import math
from pathlib import Path
from types import SimpleNamespace
import unittest


ROOT = Path(__file__).resolve().parents[1]
PERIOD = 1000 / 120
NORMAL = [0, 0, 900, 600]
ZOOMED = [0, 0, 1440, 600]


def definitions(path, names):
    """Load selected definitions without executing an app driver's launch block."""
    tree = ast.parse(path.read_text(), filename=str(path))
    nodes = [node for node in tree.body
             if (isinstance(node, ast.FunctionDef) and node.name in names)
             or (isinstance(node, (ast.Assign, ast.AnnAssign))
                 and any(isinstance(target, ast.Name) and target.id in names
                         for target in (node.targets if isinstance(node, ast.Assign) else [node.target])))]
    return compile(ast.Module(body=nodes, type_ignores=[]), str(path), "exec")


GOLDEN = definitions(ROOT.parent / "ci/frame-pacing/golden.py", {"EPS", "THRESHOLDS", "motion", "percentile"})
MEASURE = definitions(ROOT / "pane-perf-terminal.py",
                      {"WINDOW_ACTIONS", "WINDOW_RESTORE", "WINDOW_TARGET_HZ", "WINDOW_REFRESH_TOLERANCE", "WINDOW_MAX_STEP",
                       "finite_nonnegative", "first_window", "measure"})


def measured(values=None, *, name="window-zoom", refresh=PERIOD, monitor_refresh=PERIOD,
             intervals=None, missed=0, frame_count=144, trace_missing=False, restore=True,
             after=None, action_error=None):
    values = values if values is not None else [900 + 45 * i for i in range(13)]
    times = [0]
    for interval in intervals if intervals is not None else [refresh or PERIOD] * (len(values) - 1):
        times.append(times[-1] + interval)
    trace = {"refresh_ms": refresh, "samples": [
        {"t": t, "window": [width, 600]} for t, width in zip(times, values)]}
    before = NORMAL if name == "window-zoom" else ZOOMED
    after = after if after is not None else (ZOOMED if name == "window-zoom" else NORMAL)
    geometries = iter([{"frame": before, "screen_visible_frame": ZOOMED}, {"frame": after}])
    frames = {"frames": frame_count, "refresh_ms": monitor_refresh, "missed": missed}

    def rpc(method, params=None):
        if method == "debug.layers":
            return {"windows": [next(geometries)]}
        if method == "debug.motion" and params.get("action") == "trace_stop":
            return None if trace_missing else trace
        if method == "debug.frames" and params.get("action") == "stop":
            return frames
        return {}

    namespace = {"math": math, "opts": SimpleNamespace(browser=False), "time": SimpleNamespace(sleep=lambda _: None),
                 "rpc": rpc, "perform": lambda _: action_error}
    exec(GOLDEN, namespace)
    namespace["frame_motion"] = namespace["motion"]
    namespace["MOTION_THRESHOLDS"] = namespace["THRESHOLDS"]
    exec(MEASURE, namespace)
    namespace["WINDOW_RESTORE"] = NORMAL if restore else None
    with contextlib.redirect_stdout(io.StringIO()):
        return namespace["measure"]("synthetic", name)


class WindowZoomMotion(unittest.TestCase):
    def test_smooth_120_hz_zoom_passes_and_keeps_trace(self):
        result = measured()
        self.assertIsNone(result["error"])
        self.assertEqual(result["window_frame_missed"], 0)
        self.assertEqual(result["window_max_step"], 0.083)
        self.assertEqual(len(result["window_trace"]["samples"]), 13)

    def test_smooth_120_hz_restore_passes(self):
        result = measured(list(reversed([900 + 45 * i for i in range(13)])), name="window-unzoom")
        self.assertIsNone(result["error"])
        self.assertEqual(result["window_after"], NORMAL)

    def test_snap_is_rejected(self):
        self.assertIn("no intermediate", measured([900, 1440])["error"] or "")

    def test_one_intermediate_frame_cannot_hide_near_snap(self):
        result = measured([900, 901, 1440])
        self.assertEqual(result["window_intermediate"], 1)
        self.assertEqual(result["window_max_step"], 0.998)
        self.assertIn("geometry step", result["error"] or "")

    def test_shared_max_step_boundary(self):
        self.assertIsNone(measured([900, 1035, 1170, 1305, 1440])["error"])
        self.assertIn("geometry step", measured([900, 1008, 1170, 1305, 1440])["error"] or "")

    def test_smooth_60_hz_trace_is_rejected_even_with_zero_misses(self):
        result = measured(refresh=1000 / 60, monitor_refresh=1000 / 60)
        self.assertEqual(result["window_frame_missed"], 0)
        self.assertEqual(result["missed"], 0)
        self.assertIn("120 Hz", result["error"] or "")

    def test_both_refresh_sources_must_meet_target(self):
        for trace_refresh, monitor_refresh in [(PERIOD, 1000 / 60), (1000 / 60, PERIOD)]:
            with self.subTest(trace_refresh=trace_refresh, monitor_refresh=monitor_refresh):
                self.assertIn("120 Hz", measured(refresh=trace_refresh, monitor_refresh=monitor_refresh)["error"] or "")

    def test_declared_refresh_tolerance(self):
        for ratio in [0.85, 1.15]:
            with self.subTest(accepted_ratio=ratio):
                self.assertIsNone(measured(refresh=PERIOD * ratio, monitor_refresh=PERIOD * ratio)["error"])
        for ratio in [0.849, 1.151]:
            with self.subTest(rejected_ratio=ratio):
                self.assertIn("120 Hz", measured(refresh=PERIOD * ratio, monitor_refresh=PERIOD * ratio)["error"] or "")

    def test_120_hz_header_cannot_hide_60_hz_samples(self):
        result = measured(intervals=[1000 / 60] * 12)
        self.assertEqual(result["window_frame_missed"], 12)
        self.assertIn("missed", result["error"] or "")

    def test_monitor_missed_frame_is_rejected(self):
        self.assertIn("missed", measured(missed=1)["error"] or "")

    def test_monitor_missed_frame_counter_requires_finite_nonnegative_number(self):
        self.assertIsNone(measured(missed=0)["error"])
        for invalid in (None, float("nan"), True, False, -1, "0"):
            with self.subTest(invalid=invalid):
                result = measured(missed=invalid)
                self.assertIn("invalid missed-frame count", result["error"] or "")

    def test_no_refresh_evidence_is_rejected(self):
        for args in [{"refresh": None}, {"monitor_refresh": None}, {"frame_count": 0}, {"trace_missing": True}]:
            with self.subTest(args=args):
                self.assertIsNotNone(measured(**args)["error"])

    def test_noop_or_incomplete_zoom_is_rejected(self):
        self.assertIn("changed no frame", measured(after=NORMAL)["error"] or "")
        self.assertIn("visible frame", measured(after=[0, 0, 1430, 600])["error"] or "")

    def test_restore_failure_or_missing_pair_is_rejected(self):
        for args in [{"after": [0, 0, 950, 600]}, {"restore": False}]:
            with self.subTest(args=args):
                result = measured(list(reversed([900 + 45 * i for i in range(13)])), name="window-unzoom", **args)
                self.assertIn("did not restore", result["error"] or "")

    def test_non_window_actions_keep_informational_frame_metrics(self):
        result = measured(name="idle", refresh=1000 / 60, monitor_refresh=1000 / 60, missed=1)
        self.assertIsNone(result["error"])
        self.assertEqual(result["missed"], 1)
        self.assertNotIn("window_trace", result)

    def test_action_failure_is_preserved(self):
        self.assertEqual(measured(action_error="action failed")["error"], "action failed")


if __name__ == "__main__":
    unittest.main()
