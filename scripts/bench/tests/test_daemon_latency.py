"""daemon-latency: a tui-idle-ram.sh latency=1 log -> one run's rows per commit."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benches.daemon_latency import BENCH  # noqa: E402

LOG = Path(__file__).resolve().parent / "fixtures" / "daemon-latency" / "tui-idle-ram.log"
BASE, HEAD = "70b9ea980559", "8f5a02688465"


def ingest(commit, path=LOG):
    ctx = Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": None}, host_role="fleet",
                  args={"commit": commit}, timestamp="2026-11-20T00:00:00Z")
    BENCH.ingest(ctx, path)
    return {(r["metric"], r["labels"].get("scenario")): r for r in ctx.rows}


class DaemonLatencyTest(unittest.TestCase):
    def test_one_commit_per_run_median_over_rounds(self):
        base, head = ingest(BASE), ingest(HEAD)
        self.assertAlmostEqual(base[("ping", "small")]["value"], 200.0)  # median of 0.1 and 0.3 ms, in us
        self.assertAlmostEqual(head[("ping", "small")]["value"], 130.0)
        self.assertAlmostEqual(head[("ping.p95", "small")]["value"], 230.0)
        self.assertEqual(base[("ping", "small")]["n"], 2)
        self.assertAlmostEqual(base[("cli-ping", "small")]["value"], 5000.0)
        self.assertEqual(base[("acpmux.cold", None)]["value"], 210.0)
        self.assertEqual(head[("acpmux.warm.p95", None)]["value"], 16.0)
        self.assertNotIn(("acpmux.cold", None), head)
        self.assertEqual(set(base) - set(head), {("acpmux.cold", None), ("acpmux.cold.p95", None)})
        self.assertNotIn(("labels", None), base)
        self.assertTrue(all("commit" not in r["labels"] for r in base.values()))

    def test_a_commit_not_in_the_log(self):
        with self.assertRaises(BenchError):
            ingest("deadbeefdead")

    def test_not_a_log(self):
        with self.assertRaises(BenchError):
            ingest(BASE, Path(__file__))


if __name__ == "__main__":
    unittest.main()
