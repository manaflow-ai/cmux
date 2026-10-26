"""Bench migration p12-perf-process-069: the stat helpers outside scripts/cmux-next use perf_stats.

browser_engine_bench.py, perf-10x-drag-daemon.py, frame-probe-tui.py and measure-frames.py had their own
percentile functions. They now load scripts/perf-lab/perf_stats.py by file path, so corrected MQ1 lists
none of them. The old definitions are copied here only to record old against new on one fixed vector
(p12-perf-process.md R8).

Run: python3 -m unittest scripts/perf-lab/tests/test_stats_helpers_migration.py
"""

import importlib.util
import os
import statistics
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
PERF_LAB = os.path.join(ROOT, "scripts", "perf-lab")

FILES = {
    "browser_engine_bench": "scripts/perf/browser_engine_bench.py",
    "perf_10x_drag_daemon": "scripts/measure/perf-10x-drag-daemon.py",
    "frame_probe_tui": "scripts/frame-probe-tui.py",
    "measure_frames": "cmux-tui/scripts/measure-frames.py",
}

VECTOR = [3.1, 4.0, 4.2, 5.5, 6.0, 7.9, 8.3, 9.0, 12.4, 20.1]


def load(name, rel):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, os.path.join(ROOT, rel))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # before exec: a dataclass resolves its module through sys.modules
    spec.loader.exec_module(module)
    return module


queues = load("perf_lab_queues", "scripts/perf-lab/queues.py")
perf_stats = load("perf_stats", "scripts/perf-lab/perf_stats.py")


def old_linear(values, p):
    """browser_engine_bench.stats' inner pct and frame-probe-tui's percentile (same definition)."""
    ordered = sorted(values)
    idx = (len(ordered) - 1) * p
    lo = int(idx)
    hi = min(lo + 1, len(ordered) - 1)
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (idx - lo)


def old_rounded_rank(values, p):
    """perf-10x-drag-daemon's pct and measure-frames' percentile (p as a fraction here)."""
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round((len(ordered) - 1) * p)))]


class MigratedFilesTest(unittest.TestCase):
    def test_corrected_mq1_lists_none_of_the_files(self):
        hits = sorted(item.where for item in queues._private_stat_hits(ROOT) if item.key in FILES.values())
        self.assertEqual(hits, [])
        self.assertFalse(set(FILES.values()) & {item.key for item in queues.private_stats(ROOT)})

    def test_each_file_shares_the_perf_stats_module(self):
        for name, rel in FILES.items():
            with self.subTest(rel):
                self.assertIs(load(name, rel).perf_stats, perf_stats)

    def test_each_file_runs_help_under_isolated_python(self):
        for rel in FILES.values():
            with self.subTest(rel):
                run = subprocess.run([sys.executable, "-I", os.path.join(ROOT, rel), "--help"],
                                     capture_output=True, text=True, cwd="/", timeout=60)
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assertIn("usage:", run.stdout)


class OldAgainstNewTest(unittest.TestCase):
    """Old and new values on VECTOR, as recorded in the commit message."""

    def test_browser_engine_bench_stats_keys_and_values_unchanged(self):
        bench = load("browser_engine_bench", FILES["browser_engine_bench"])
        got = bench.stats(VECTOR)
        self.assertEqual(list(got), ["n", "mean", "p50", "p95", "p99", "max"])
        self.assertEqual(got, {
            "n": 10,
            "mean": round(statistics.mean(VECTOR), 3),
            "p50": round(old_linear(VECTOR, 0.5), 3),
            "p95": round(old_linear(VECTOR, 0.95), 3),
            "p99": round(old_linear(VECTOR, 0.99), 3),
            "max": 20.1,
        })
        self.assertEqual((got["p50"], got["p95"], got["p99"]), (6.95, 16.635, 19.407))
        self.assertEqual(bench.stats([]), {})

    def test_frame_probe_summary_unchanged(self):
        probe = load("frame_probe_tui", FILES["frame_probe_tui"])
        frames = probe.FrameStats(hz=120.0, history_limit=100)
        now = 0
        frames.record_frame(now)
        for gap_ms in VECTOR:
            now += int(gap_ms * 1_000_000)
            frames.record_frame(now)
        summary = frames.summary()
        gaps = list(frames.gaps_ms)
        self.assertAlmostEqual(summary["p95_gap_ms"], old_linear(gaps, 0.95), places=9)
        self.assertAlmostEqual(summary["p99_gap_ms"], old_linear(gaps, 0.99), places=9)
        empty = probe.FrameStats(hz=120.0, history_limit=100).summary()
        self.assertEqual((empty["p95_gap_ms"], empty["p99_gap_ms"]), (0.0, 0.0))

    def test_rounded_rank_files_move_to_linear_interpolation(self):
        # perf-10x-drag-daemon rtt_p50/p95 and measure-frames p95 were a rounded rank; measure-frames'
        # median was statistics.median (equal to pct 0.5). p99 is new in both.
        self.assertEqual(old_rounded_rank(VECTOR, 0.5), 6.0)  # round(4.5) is 4
        self.assertEqual(old_rounded_rank(VECTOR, 0.95), 20.1)
        self.assertEqual(statistics.median(VECTOR), 6.95)
        self.assertAlmostEqual(perf_stats.pct(VECTOR, 0.5), 6.95, places=9)
        self.assertAlmostEqual(perf_stats.pct(VECTOR, 0.95), 16.635, places=9)
        self.assertAlmostEqual(perf_stats.pct(VECTOR, 0.99), 19.407, places=9)


if __name__ == "__main__":
    unittest.main()
