"""tui-idle: real tui-idle-ram.sh logs (Linux CI, runs 43834927681 and 43830705256) -> rows."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benches.tui_idle import BENCH  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "tui-idle"
BEFORE, AFTER, TIP = "babcb18cd895", "8c515cc54097", "c27a9e09ec99"


def find(rows, metric, **labels):
    got = [r for r in rows if r["metric"] == metric and all(r["labels"].get(k) == v for k, v in labels.items())]
    assert len(got) == 1, (metric, labels, len(got))
    return got[0]


def ingest(name):
    ctx = Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": "d" * 40}, host_role="fleet",
                  timestamp="2026-11-16T00:00:00Z")
    BENCH.ingest(ctx, FIXTURES / name)
    return ctx


class TuiIdleTest(unittest.TestCase):
    def test_two_commits_from_one_run(self):
        rows = ingest("tui-idle-ram.log").rows
        before = find(rows, "anon", commit=BEFORE)
        after = find(rows, "anon", commit=AFTER)
        self.assertEqual((before["n"], after["n"]), (3, 3))
        self.assertEqual(before["value"], 14.9)  # median of 14.4, 15.0, 14.9
        self.assertEqual(after["value"], 15.9)
        self.assertEqual(find(rows, "threads", commit=AFTER)["value"], 40)
        self.assertAlmostEqual(find(rows, "section", commit=AFTER, section="got")["value"], 374160 / 1048576)
        self.assertAlmostEqual(find(rows, "binary", commit=BEFORE)["value"], 162467480 / 1048576)
        self.assertTrue(all(r["better"] == "lower" for r in rows))

    def test_dhat_heap_and_its_launch_left_out(self):
        rows = ingest("tui-idle-ram-dhat.log").rows
        self.assertAlmostEqual(find(rows, "heap_end", commit=TIP)["value"], 3796424 / 1048576)
        self.assertAlmostEqual(find(rows, "heap_peak", commit=TIP)["value"], 6571779 / 1048576)
        anon = find(rows, "anon", commit=TIP)
        self.assertEqual(anon["n"], 3)  # r1-r3; the dhat launch (28.1 MB with dhat's bookkeeping) is not a sample
        self.assertLess(anon["value"], 20)

    def test_not_a_log(self):
        ctx = Context(bench=BENCH, build={"channel": "local"}, host_role="fleet")
        with self.assertRaises(BenchError):
            BENCH.ingest(ctx, Path(__file__))

    def test_commits_resolve_to_full_ids(self):
        ctx = Context(bench=BENCH, build={"channel": "local"}, host_role="fleet", args={"commits": "HEAD"})
        (full,) = BENCH.commits(ctx)
        self.assertRegex(full, r"^[0-9a-f]{40}$")
        bad = Context(bench=BENCH, build={"channel": "local"}, host_role="fleet", args={"commits": "zzzzzzz"})
        with self.assertRaises(BenchError):
            BENCH.commits(bad)


if __name__ == "__main__":
    unittest.main()
