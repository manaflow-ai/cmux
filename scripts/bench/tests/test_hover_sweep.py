"""hover-sweep bench: a step log into per-quantile rows.

Fixture (fixtures/hover-sweep/step.log): the line HoverCardSweepBench prints, in the format of its print statement,
three test processes (one echoed twice, as a suite runner may repeat a line) among hover-sweep.sh's HS lines and
the suite runner's noise. The numbers are illustrative, not a measurement: replace the file with a real step log
once one is recorded.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benchlib.registry import load_all  # noqa: E402

FIX = Path(__file__).resolve().parent / "fixtures" / "hover-sweep"


def _ctx(bench):
    return Context(bench=bench, build={"channel": "sha", "version": None, "sha": "a" * 40}, host_role="fleet")


class StepLog(unittest.TestCase):
    def test_rows_per_quantile(self):
        bench = load_all()["hover-sweep"]
        ctx = _ctx(bench)
        bench.ingest(ctx, FIX / "step.log")
        rows = {r["metric"]: r for r in ctx.rows}
        self.assertEqual(sorted(rows), ["moves", "pointer_move_max", "pointer_move_p50", "pointer_move_p95",
                                        "pointer_move_p99"])
        self.assertEqual(rows["moves"]["value"], 96000.0)
        self.assertEqual(rows["pointer_move_p50"]["n"], 3)  # the echoed line counts once
        self.assertEqual(rows["pointer_move_p50"]["value"], 0.25)
        self.assertEqual(rows["pointer_move_p95"]["value"], 0.625)
        self.assertEqual(rows["pointer_move_p99"]["value"], 1.042)
        self.assertTrue(all(r["unit"] == "us" for m, r in rows.items() if m != "moves"))
        self.assertEqual(ctx.host["chip"], "Apple M4 Pro")
        self.assertEqual(ctx.host["name"], "aws-m4pro-3")

    def test_no_line_is_an_error(self):
        bench = load_all()["hover-sweep"]
        with self.assertRaises(BenchError):
            bench.ingest(_ctx(bench), FIX.parent / "omnibar" / "omnibar.log")


if __name__ == "__main__":
    unittest.main()
