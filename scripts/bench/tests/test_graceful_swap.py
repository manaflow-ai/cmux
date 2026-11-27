"""graceful-swap: a graceful-swap.py run.json -> rows."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import Context  # noqa: E402
from benches.graceful_swap import BENCH  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "graceful-swap"


def find(rows, metric, **labels):
    got = [r for r in rows if r["metric"] == metric and all(r["labels"].get(k) == v for k, v in labels.items())]
    assert len(got) == 1, (metric, labels, len(got))
    return got[0]


class GracefulSwapTest(unittest.TestCase):
    def test_rows(self):
        ctx = Context(bench=BENCH, build={"channel": "nightly", "version": None, "sha": None}, host_role="anywhere",
                      timestamp="2026-11-22T00:00:00Z")
        BENCH.ingest(ctx, FIXTURES / "run.json")
        rows = ctx.rows
        self.assertEqual(find(rows, "transient_frames", region="focused")["value"], 7.0)
        self.assertEqual(find(rows, "shift_px", region="focused")["value"], 8.0)
        self.assertEqual(find(rows, "lost", region="focused")["value"], 1.0)
        self.assertEqual(find(rows, "lost", region="unfocused")["value"], 0.0)
        self.assertEqual(find(rows, "probe_lost", page="agent-chat")["value"], 1.0)
        self.assertEqual(find(rows, "probe_restored_ms", page="agent-chat")["value"], 420.0)
        self.assertTrue(ctx.notes)

    def test_latency_rows(self):
        ctx = Context(bench=BENCH, build={"channel": "nightly", "version": None, "sha": None}, host_role="anywhere",
                      timestamp="2026-11-22T00:00:00Z")
        BENCH.ingest(ctx, FIXTURES / "latency.json")
        row = find(ctx.rows, "hot_swap_mac_unfocused_pane_p95_ms", surface="unfocused")
        self.assertEqual(row["value"], 540.0)
        self.assertEqual(row["p50"], 250.0)
        self.assertEqual(row["n"], 4)
        self.assertEqual(row["labels"]["bar_ms"], "300")
        self.assertEqual(row["labels"]["drafts_kept"], "3/4")
        self.assertTrue(ctx.notes)


if __name__ == "__main__":
    unittest.main()
