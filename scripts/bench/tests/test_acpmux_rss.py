"""acpmux-rss: a real daemon_rss_growth log (sends only, 200 rounds of 20, at the base of the inbox fix) -> rows."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benches.acpmux_rss import BENCH  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "acpmux-rss"


def find(rows, metric):
    got = [r for r in rows if r["metric"] == metric]
    assert len(got) == 1, (metric, len(got))
    return got[0]


class AcpmuxRssTest(unittest.TestCase):
    def test_sends_only_run(self):
        ctx = Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": "d" * 40}, host_role="fleet",
                      timestamp="2026-11-19T00:00:00Z")
        BENCH.ingest(ctx, FIXTURES / "base-sends.log")
        rows = ctx.rows
        self.assertAlmostEqual(find(rows, "mb_per_1000_ops")["value"], 160.09, places=2)
        self.assertEqual(find(rows, "rss_start")["value"], 93)
        self.assertEqual(find(rows, "rss_end")["value"], 657)
        self.assertEqual(find(rows, "cpu_end")["value"], 82.5)
        self.assertTrue(all(r["labels"] == {"mix": "sends"} for r in rows))
        self.assertTrue(all(r["better"] == "lower" for r in rows))

    def test_not_a_log(self):
        ctx = Context(bench=BENCH, build={"channel": "local"}, host_role="fleet")
        with self.assertRaises(BenchError):
            BENCH.ingest(ctx, Path(__file__))


if __name__ == "__main__":
    unittest.main()
