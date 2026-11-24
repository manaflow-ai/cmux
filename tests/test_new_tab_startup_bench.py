#!/usr/bin/env python3
"""scripts/cmux-next/new-tab-startup-bench.py: its report has each round's key_to_visible_ms and typed_key_accepted_ms,
p50/p95 over the rounds, and counts a round with no value as missed (goal startup-every-path)."""
import importlib.util
import json
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/new-tab-startup-bench.py"
sys.path.insert(0, str(SCRIPT.parent))
spec = importlib.util.spec_from_file_location("new_tab_startup_bench", SCRIPT)
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


def rounds(n=10, miss=None):
    out = []
    for i in range(n):
        out.append({"round": i + 1, "key_to_visible_ms": 10.0 + i, "typed_key_accepted_ms": 100.0 + 10 * i})
    if miss is not None:
        out[miss]["typed_key_accepted_ms"] = None
    return out


class Report(unittest.TestCase):
    def test_each_round_is_a_sample_with_p50_and_p95(self):
        out = bench.report(rounds(), 10)
        self.assertEqual(out["bench"], "new-tab-startup")
        self.assertEqual(out["samples"]["key_to_visible_ms"], [10.0 + i for i in range(10)])
        self.assertEqual(len(out["samples"]["typed_key_accepted_ms"]), 10)
        stats = out["stats"]["typed_key_accepted_ms"]
        self.assertEqual(stats["n"], 10)
        self.assertGreater(stats["p95"], stats["p50"])
        self.assertTrue(bench.passed(out))
        json.dumps(out)  # the report is JSON

    def test_a_round_with_no_echo_is_missed_and_fails(self):
        out = bench.report(rounds(miss=3), 10)
        self.assertIsNone(out["samples"]["typed_key_accepted_ms"][3])
        self.assertEqual(out["missed"], {"key_to_visible_ms": 0, "typed_key_accepted_ms": 1})
        self.assertFalse(bench.passed(out))

    def test_fewer_rounds_than_asked_fail(self):
        self.assertFalse(bench.passed(bench.report(rounds(4), 10)))

    def test_number_refuses_what_is_no_time(self):
        for bad in (None, True, -1, float("nan"), "12", float("inf")):
            self.assertIsNone(bench.number(bad), bad)
        self.assertEqual(bench.number(12.345), 12.3)

    def test_the_entry_dispatches_the_bench(self):
        entry = (ROOT / "scripts/cmux-next/instant-new-surfaces-bench.py").read_text()
        self.assertIn('"--bench=new-tab-startup"', entry)
        self.assertIn("new-tab-startup-bench.py", entry)


if __name__ == "__main__":
    unittest.main()
