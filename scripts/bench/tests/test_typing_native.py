"""typing-native: a typing-frame-bench.py report -> rows; an incomplete run is a note, never a timing row."""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benchlib.registry import load_all  # noqa: E402
from benches.typing_native import BENCH  # noqa: E402


def context():
    return Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": "d" * 40}, host_role="fleet",
                   timestamp="2026-11-20T00:00:00Z", args={})


def ingest(report):
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "report.json"
        path.write_text(json.dumps(report), encoding="utf-8")
        ctx = context()
        BENCH.ingest(ctx, path)
        return ctx


COMPLETE = {
    "session": "light", "surface": "agentpane", "phase": "load", "mode": "L4", "complete": True,
    "mode_missing": ["100k-row chat"], "capabilities": {"load_source": "real"},
    "key_to_frame_ms": {"p50": 4.0, "p95": 9.5, "p99": 12.0, "max": 20.0},
    "dispatch_to_after_frame_ms": {"p50": 3.0, "p95": 8.0, "p99": 11.0, "max": 18.0},
    "frame_metrics": {"frames_over_16ms": 2, "main_thread_cost": {"total_ms": 40.5}},
}


class TypingNativeTest(unittest.TestCase):
    def test_registered_beside_the_web_bench(self):
        benches = load_all()
        self.assertIs(benches["typing-native"], BENCH)
        self.assertIn("typing", benches)
        self.assertIsNot(benches["typing"], BENCH)

    def test_complete_run_rows(self):
        ctx = ingest({"host": "aws-m4pro-1", "macos": "26.1", "runs": [COMPLETE]})
        rows = {(r["metric"]): r for r in ctx.rows}
        self.assertEqual(rows["key_to_frame_p95"]["value"], 9.5)
        self.assertEqual(rows["dispatch_to_after_frame_p99"]["value"], 11.0)
        self.assertEqual(rows["frames_over_16ms"]["value"], 2)
        self.assertEqual(rows["key_to_frame_p95"]["labels"]["mode"], "L4")
        self.assertEqual(rows["key_to_frame_p95"]["labels"]["native_missing"], "100k-row chat")
        self.assertEqual(ctx.host["name"], "aws-m4pro-1")

    def test_incomplete_run_is_a_note(self):
        incomplete = dict(COMPLETE, complete=False, text_exact=False)
        ctx = ingest({"runs": [COMPLETE, incomplete]})
        self.assertEqual(len([r for r in ctx.rows if r["metric"] == "key_to_frame_p95"]), 1)
        self.assertTrue(any("typing-native: unmeasured incomplete run" in n for n in ctx.notes))

    def test_nothing_complete_raises(self):
        with self.assertRaises(BenchError):
            ingest({"runs": [dict(COMPLETE, complete=False)]})


if __name__ == "__main__":
    unittest.main()
