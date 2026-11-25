"""snappy: a snappy-bench.sh log (or snappy.json, or snappy-bench.py --summarize's line) -> one run's rows."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benches.snappy import BENCH  # noqa: E402

LOG = Path(__file__).resolve().parent / "fixtures" / "snappy" / "snappy.log"


def ingest(path=LOG):
    ctx = Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": None}, host_role="fleet",
                  args={}, timestamp="2026-11-25T00:00:00Z")
    BENCH.ingest(ctx, path)
    return {(r["metric"], r["labels"]["duress"]): r for r in ctx.rows}


class SnappyTest(unittest.TestCase):
    def test_rows_per_duress(self):
        rows = ingest()
        self.assertEqual(rows[("send_paint", "none")]["p95"], 24.0)
        self.assertEqual(rows[("reserved_same_frame", "none")]["value"], 75.0)
        self.assertEqual(rows[("reserved_same_frame", "none")]["better"], "higher")
        self.assertEqual(rows[("shifts_per_send", "none")]["p95"], 2)
        self.assertEqual(rows[("failed_sends", "none")]["value"], 1)
        self.assertEqual(rows[("send_paint", "offline")]["value"], 9.0)
        self.assertNotIn(("send_first_token", "offline"), rows)

    def test_a_log_without_a_report_is_refused(self):
        with self.assertRaises(BenchError):
            ingest(Path(__file__))


if __name__ == "__main__":
    unittest.main()
