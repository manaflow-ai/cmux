"""Exercise native-runner receipt validation without importing either app-launch script."""
import ast
import copy
import math
from pathlib import Path
import statistics
from types import SimpleNamespace
import unittest


ROOT = Path(__file__).resolve().parents[1]


def helpers(filename, names, **dependencies):
    path = ROOT / "scripts/cmux-next" / filename
    tree = ast.parse(path.read_text())
    nodes = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in names]
    if {node.name for node in nodes} != set(names):
        raise AssertionError(f"missing helpers in {path}")
    namespace = {"math": math, "statistics": statistics, **dependencies}
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(path), "exec"), namespace)
    return namespace


class TranscriptMetricsTests(unittest.TestCase):
    def setUp(self):
        self.api = helpers("agent-engine-bench.py", ["finite_number", "fling_metrics", "flings_complete"])
        self.seed = {"rows": 3000, "commit_ms": 4}
        self.fling = {"running": False, "frames": 181, "rows": 3000, "distance_px": 80_000,
                      "nominal_ms": 16.67, "dropped_frames": 0, "p95_ms": 16.67, "max_ms": 16.67}
        self.perf = {"running": False, "blank_frames": 2,
                     "samples": [{"interval_ms": 16.67, "blank": False} for _ in range(180)]}

    def metrics(self, seconds=3, target_hz=None, requested_rows=3000):
        return self.api["fling_metrics"](self.fling, self.perf, self.seed, requested_rows, seconds, target_hz)

    def test_full_observed_duration_is_complete_even_with_bad_performance(self):
        metrics = self.metrics(target_hz=120)
        self.assertTrue(metrics["complete"])
        self.assertAlmostEqual(metrics["observed_duration_ms"], 3000.6)
        self.assertEqual(metrics["dropped_slots"], 180)
        self.assertAlmostEqual(metrics["dropped_slots_per_s"], 60, delta=0.02)
        self.assertEqual(metrics["measured_interval_p50_ms"], 16.67)
        self.assertEqual(metrics["blank_model_frames"], 2)
        self.assertIsNone(metrics["blank_ms"])
        self.assertTrue(self.api["flings_complete"]([{"frame_metrics": metrics}], 1))

    def test_cancelled_200ms_recording_cannot_satisfy_requested_three_seconds(self):
        self.perf["samples"] = self.perf["samples"][:12]
        self.fling["frames"] = 13
        metrics = self.metrics()
        self.assertTrue(metrics["full_ring"])
        self.assertFalse(metrics["full_duration"])
        self.assertFalse(metrics["complete"])
        self.assertIsNone(metrics["dropped_slots_per_s"])

    def test_rounding_tolerance_accepts_120hz_three_second_recording(self):
        self.perf["samples"] = [{"interval_ms": 8.33} for _ in range(360)]
        self.fling["frames"] = 361
        self.assertTrue(self.metrics(target_hz=120)["complete"])

    def test_truncated_ring_retains_diagnostics_but_not_whole_fling_rate(self):
        self.fling["frames"] = 1001
        metrics = self.metrics()
        self.assertFalse(metrics["complete"])
        self.assertGreater(metrics["sampled_duration_ms"], 0)
        self.assertIsNone(metrics["observed_duration_ms"])
        self.assertIsNone(metrics["dropped_slots_per_s"])

    def test_failed_or_uncommitted_seed_and_changed_transcript_are_incomplete(self):
        for seed in (None, {"error": "seed failed"}, {"rows": 3000, "commit_ms": None},
                     {"rows": 2997, "commit_ms": 0}):
            with self.subTest(seed=seed):
                self.seed = seed
                self.assertFalse(self.metrics()["complete"])
        self.seed = {"rows": 3000, "commit_ms": 0}
        self.fling["rows"] = 2997
        self.assertFalse(self.metrics()["complete"])

    def test_default_seed_normalization_keeps_complete_three_row_turns(self):
        self.seed["rows"] = self.fling["rows"] = 4998
        self.assertTrue(self.metrics(requested_rows=5000)["complete"])

    def test_zero_movement_or_running_fling_is_incomplete(self):
        self.fling["distance_px"] = 0
        self.assertFalse(self.metrics()["complete"])
        self.fling["distance_px"] = 80_000
        self.fling["running"] = True
        self.assertFalse(self.metrics()["complete"])

    def test_missing_or_partial_requested_flings_fail_completeness(self):
        done = {"frame_metrics": self.metrics()}
        check = self.api["flings_complete"]
        self.assertFalse(check([], 1))
        self.assertFalse(check([done], 2))
        self.assertFalse(check([done, {"frame_metrics": {"complete": False}}], 2))
        self.assertTrue(check([done, done], 2))

    def test_malformed_samples_do_not_raise_or_complete(self):
        for samples in (None, [], [None], [{"interval_ms": "8"}], [{"interval_ms": math.nan}],
                        [{"interval_ms": -1}], [{"interval_ms": True}]):
            with self.subTest(samples=samples):
                self.perf["samples"] = samples
                self.assertFalse(self.metrics()["complete"])

    def test_target_is_forwarded_to_existing_fling_api_and_raw_data_is_retained(self):
        calls = []

        def pane(action, **kwargs):
            calls.append((action, kwargs))
            return copy.deepcopy(self.fling if action == "fling" else self.perf)

        opts = SimpleNamespace(rows=3000, fling_seconds=3, target_hz=120)
        api = helpers("agent-engine-bench.py", ["finite_number", "fling_metrics", "measured_fling"],
                      opts=opts, pane=pane)
        result = api["measured_fling"](self.seed)
        self.assertEqual(calls[0][1]["nominal_ms"], 1000 / 120)
        self.assertEqual(calls[1], ("perf_stats", {"raw": True}))
        self.assertEqual(result["perf_stats"], self.perf)
        self.assertEqual(result["p95_ms"], self.fling["p95_ms"])
        calls.clear()
        opts.target_hz = None
        api["measured_fling"](self.seed)
        self.assertNotIn("nominal_ms", calls[0][1])


class SidebarMetricsTests(unittest.TestCase):
    def setUp(self):
        self.api = helpers("sidebar-stress-bench.py", ["sidebar_frame_metrics", "scrolls_complete"])
        self.stats = {"running": True, "frames": 1, "refresh_ms": 1000 / 120, "intervals_ms": [33.33]}

    def metrics(self, target_hz=None):
        return self.api["sidebar_frame_metrics"](self.stats, target_hz)

    def test_33ms_at_120hz_loses_three_slots_not_one_long_interval(self):
        metrics = self.metrics()
        self.assertTrue(metrics["complete"])
        self.assertEqual(metrics["dropped_slots"], 3)
        self.assertAlmostEqual(metrics["observed_duration_ms"], 33.33)
        self.assertIsNone(metrics["blank_frames"])
        self.assertIsNone(metrics["blank_ms"])

    def test_60hz_display_against_120hz_target_loses_about_60_slots_per_second(self):
        self.stats.update(frames=180, refresh_ms=1000 / 60, intervals_ms=[16.67] * 180)
        metrics = self.metrics(target_hz=120)
        self.assertTrue(metrics["complete"])
        self.assertAlmostEqual(metrics["dropped_slots_per_s"], 60, delta=0.02)
        self.assertEqual(metrics["measured_refresh_ms"], 1000 / 60)
        self.assertEqual(self.metrics()["dropped_slots"], 0)

    def test_expired_probe_and_frame_count_mismatch_are_incomplete(self):
        self.stats["running"] = False
        self.assertFalse(self.metrics()["complete"])
        self.assertIsNone(self.metrics()["dropped_slots_per_s"])
        self.stats.update(running=True, frames=2)
        self.assertFalse(self.metrics()["complete"])

    def test_malformed_intervals_or_refresh_are_incomplete(self):
        for intervals in (None, [], [None], ["8"], [math.nan], [math.inf], [-1], [True], [0]):
            with self.subTest(intervals=intervals):
                self.stats["intervals_ms"] = intervals
                self.assertFalse(self.metrics()["complete"])
        self.stats["intervals_ms"] = [8.33]
        for refresh in (None, 0, math.nan, "8", True):
            with self.subTest(refresh=refresh):
                self.stats["refresh_ms"] = refresh
                self.assertFalse(self.metrics(target_hz=120)["complete"])

    def test_requested_scrolls_require_complete_receipts(self):
        entry = {"scroll": {"frames": {"frame_metrics": self.metrics()}}}
        check = self.api["scrolls_complete"]
        self.assertTrue(check(entry, {"scroll"}))
        self.assertFalse(check(entry, {"scroll", "scroll_ticking"}))
        entry["scroll_while_ticking"] = {"frames": {"frame_metrics": {"complete": False}}}
        self.assertFalse(check(entry, {"scroll", "scroll_ticking"}))


if __name__ == "__main__":
    unittest.main()
