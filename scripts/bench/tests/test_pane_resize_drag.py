"""pane-resize-drag bench: webviews/bench/pane-resize-drag.bench.ts's output into rows.

Fixtures (fixtures/pane-resize-drag/): summary.json and bench.log are hand-made in the harness's format (one chromium
case at 700 turns, with two settle frames of 0.9 and 1.2 s as Leo recorded, and one failed case); replace them with
a real CI run's summary.json and bench.log once one exists.
"""
from __future__ import annotations

import json
import statistics
import sys
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benchlib.registry import load_all  # noqa: E402

FIX = Path(__file__).resolve().parent / "fixtures" / "pane-resize-drag"


def ingest(name: str | Path) -> Context:
    bench = load_all()["pane-resize-drag"]
    ctx = Context(bench=bench, build={"channel": "sha", "version": None, "sha": "f" * 40}, host_role="anywhere",
                  host={"name": "ci", "role": "anywhere", "os": "Linux", "chip": "x86_64"})
    bench.ingest(ctx, Path(name) if Path(name).is_absolute() else FIX / name)
    return ctx


def find(ctx: Context, metric: str, **labels: str) -> dict:
    hits = [r for r in ctx.rows if r["metric"] == metric and r["labels"] == labels]
    if len(hits) != 1:
        raise AssertionError(f"{metric} {labels}: {len(hits)} rows")
    return hits[0]


LABELS = {"engine": "chromium", "turns": "700", "driver": "root"}


class PaneResizeDragBenchTest(unittest.TestCase):
    def setUp(self):
        self.doc = json.loads((FIX / "summary.json").read_text())
        self.case = self.doc["cases"][0]
        self.ctx = ingest("summary.json")

    def test_every_frame_is_a_sample_per_phase(self):
        for phase in ("all", "drag", "resume", "settle"):
            row = find(self.ctx, "frame_ms", **LABELS, phase=phase)
            samples = self.case["intervals"][phase]
            self.assertEqual(row["n"], len(samples))
            self.assertAlmostEqual(row["value"], statistics.median(samples), places=6)

    def test_the_harness_stats_are_rows(self):
        settle = self.case["phases"]["settle"]
        self.assertEqual(find(self.ctx, "frame_max_ms", **LABELS, phase="settle")["value"], settle["max_ms"])
        self.assertEqual(find(self.ctx, "frame_p95_ms", **LABELS, phase="settle")["value"], settle["p95_ms"])
        self.assertEqual(find(self.ctx, "frames_over_50ms", **LABELS, phase="settle")["value"], settle["over_50ms"])
        fps = find(self.ctx, "fps_at_p95", **LABELS, phase="drag")
        self.assertEqual(fps["better"], "higher")
        self.assertEqual(fps["unit"], "fps")

    def test_a_failed_case_is_a_note(self):
        self.assertTrue(any("fixture failure" in note for note in self.ctx.notes))

    def test_the_log_lines_alone_give_the_stats(self):
        ctx = ingest("bench.log")
        self.assertEqual(find(ctx, "frame_max_ms", **LABELS, phase="settle")["value"],
                         self.case["phases"]["settle"]["max_ms"])
        self.assertFalse([r for r in ctx.rows if r["metric"] == "frame_ms"])
        self.assertTrue(any("PANE_RESIZE_DRAG lines" in note for note in ctx.notes))

    def test_a_directory_reads_its_summary(self):
        self.assertEqual(len(ingest(FIX).rows), len(self.ctx.rows))

    def test_a_file_with_neither_is_refused(self):
        with self.assertRaises(BenchError):
            ingest(Path(__file__).resolve())


if __name__ == "__main__":
    unittest.main()
