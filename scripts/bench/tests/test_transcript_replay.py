"""transcript-replay: a real harness run (feat-cmux-next e244410a856, 50k rows, lane VM) -> rows."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benches.transcript_replay import BENCH  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "transcript-replay"


def find(found, metric, **labels):
    got = [r for r in found if r["metric"] == metric and all(r["labels"].get(k) == v for k, v in labels.items())]
    assert len(got) == 1, (metric, labels, len(got))
    return got[0]


def context():
    return Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": "e" * 40}, host_role="fleet",
                   timestamp="2026-11-17T00:00:00Z")


class TranscriptReplayTest(unittest.TestCase):
    def test_base_run(self):
        ctx = context()
        BENCH.ingest(ctx, FIXTURES / "base-e244410a856.log")
        rows = ctx.rows
        self.assertEqual(find(rows, "row_shifts", phase="total")["value"], 6)
        self.assertEqual(find(rows, "row_shifts", phase="stream")["value"], 6)
        self.assertEqual(find(rows, "row_shifts", phase="fold")["value"], 0)
        self.assertEqual(find(rows, "max_shift", phase="total")["unit"], "px")
        self.assertEqual(find(rows, "first_paint", rows="500")["value"], 1370)
        self.assertEqual(find(rows, "socket_to_paint", rows="50582")["value"], 1311)

    def test_no_line(self):
        empty = BENCH_DIR / "tests" / "fixtures" / "transcript-replay" / "missing.log"
        with self.assertRaises(Exception):
            BENCH.ingest(context(), empty)
        with self.assertRaises(BenchError):
            BENCH.ingest(context(), Path(__file__))


if __name__ == "__main__":
    unittest.main()
