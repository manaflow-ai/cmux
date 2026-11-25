"""chief-latency: a chief-latency.sh log -> one run's rows per side."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benches.chief_latency import BENCH  # noqa: E402

LOG = Path(__file__).resolve().parent / "fixtures" / "chief-latency" / "chief-latency.log"


def ingest(side=None, path=LOG):
    ctx = Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": None}, host_role="fleet",
                  args={"side": side} if side else {}, timestamp="2026-11-23T00:00:00Z")
    BENCH.ingest(ctx, path)
    return {r["metric"]: r for r in ctx.rows}


class ChiefLatencyTest(unittest.TestCase):
    def test_one_side_per_run(self):
        before, after = ingest("before"), ingest("after")
        self.assertEqual(before["first_request_tokens"]["value"], 40510)
        self.assertEqual(after["first_request_tokens"]["value"], 32510)
        self.assertEqual(before["first_request_tokens"]["unit"], "count")
        self.assertEqual(before["ttft"]["unit"], "ms")
        self.assertEqual(before["cold_share"]["value"], 50.0)
        self.assertEqual(after["cold_share"]["value"], 25.0)
        self.assertEqual(before["refused_sends"]["value"], 2)
        self.assertEqual(after["refused_sends"]["value"], 0)
        self.assertEqual(before["turn"]["n"], 8)
        self.assertEqual(set(before), set(after))

    def test_default_side_is_after(self):
        self.assertEqual(ingest()["first_request_tokens"]["value"], 32510)

    def test_a_side_not_in_the_log(self):
        with self.assertRaises(BenchError):
            ingest("middle")

    def test_not_a_log(self):
        with self.assertRaises(BenchError):
            ingest("before", Path(__file__))


if __name__ == "__main__":
    unittest.main()
