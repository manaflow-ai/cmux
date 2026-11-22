#!/usr/bin/env python3
"""bench_arms.py: the warm, quick and cold arms of a felt bench and its headline, the worst arm.

Runs on any host (Linux included): no app, no fleet.

    python3 -m unittest scripts/cmux-next/tests/test_bench_arms.py
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import bench_arms  # noqa: E402


class BenchArmsTests(unittest.TestCase):
    def test_stats_give_every_percentile_and_count_missed_runs(self):
        s = bench_arms.stats([10, 20, None, 30, 40])
        self.assertEqual((s["n"], s["missed"]), (5, 1))
        self.assertEqual((s["p50"], s["max"]), (25.0, 40))
        self.assertEqual(s["p95"], 38.5)
        self.assertEqual(s["p99"], 39.7)

    def test_the_headline_is_the_worst_arm_not_the_warm_one(self):
        lines = []
        got = bench_arms.report("b", "visible_ms", "ms", {"warm": [5, 6, 7], "quick": [40, 50, 60], "cold": [9, 10, 11]},
                                out=lines.append)
        self.assertEqual(got["headline"], "quick")
        self.assertTrue(any(line.startswith("HEADLINE b visible_ms = quick arm") for line in lines))
        self.assertTrue(all(any(line.startswith(f"ARM b visible_ms {arm}:") for line in lines) for arm in bench_arms.ARMS))

    def test_a_missed_run_makes_its_arm_the_worst(self):
        arms = {"warm": bench_arms.stats([90, 95]), "cold": bench_arms.stats([1, None])}
        self.assertEqual(bench_arms.worst(arms), "cold")

    def test_an_arm_that_did_not_run_is_never_the_headline(self):
        lines = []
        got = bench_arms.report("b", "ms", "ms", {"warm": [5], "quick": [], "cold": []}, out=lines.append)
        self.assertEqual(got["headline"], "warm")
        self.assertEqual(got["not_run"], ["quick", "cold"])
        self.assertIn("not run: quick, cold", lines[-1])

    def test_ties_on_p95_go_to_the_higher_max(self):
        arms = {"warm": bench_arms.stats([10, 10, 10]), "quick": bench_arms.stats([10] * 99 + [80])}
        self.assertEqual(bench_arms.worst(arms), "quick")

    def test_an_arm_with_a_defect_is_the_headline_and_names_its_count(self):
        lines = []
        got = bench_arms.report("p", "bad_frames", "frames", {"warm": [9, 9], "cold": [0, 1]}, out=lines.append,
                                defects={"warm": 0, "cold": 2}, defect_name="blank_frames")
        self.assertEqual(got["headline"], "cold")
        self.assertTrue(lines[-1].startswith("HEADLINE p bad_frames = cold arm"))
        self.assertIn("blank_frames=2", lines[-1])
        self.assertEqual(bench_arms.worst({"a": bench_arms.stats([1]), "b": bench_arms.stats([1])}, {"a": 1, "b": 3}), "b")

    def test_the_rule_is_printed_with_the_headline(self):
        lines = []
        bench_arms.report("b", "ms", "ms", {"warm": [1]}, out=lines.append)
        self.assertIn(bench_arms.RULE, lines[-1])


if __name__ == "__main__":
    unittest.main()
