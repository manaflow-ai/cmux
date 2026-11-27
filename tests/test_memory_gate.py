#!/usr/bin/env python3
"""memory_gate.py's verdict and memory_bisect.py's search, on canned harness lines (no build, no daemons)."""
from __future__ import annotations

import json
import os
import sys
import types
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts", "measure"))
import memory_bisect  # noqa: E402
import memory_gate  # noqa: E402


def row(arm: str, i: int, value: float, name: str = "infinite_items.n100.mb_per_item") -> str:
    return f"{arm} r{i} PERF_ROW " + json.dumps({"name": name, "p50": value, "p95": value, "unit": "MB", "floor": 0.1})


def log(before, after) -> list[str]:
    lines = ["INFINITE-AB before=abc after=def repeat=3 counts=100 days=1", "BEFORE r1 INFINITE n=100 rss_mb=40"]
    for i, (b, a) in enumerate(zip(before, after), 1):
        lines += [row("BEFORE", i, b), row("AFTER", i, a)]
    return lines


class Verdict(unittest.TestCase):
    def state(self, before, after, **kw):
        rows = memory_gate.parse(log(before, after))
        return memory_gate.verdict(rows, memory_gate.DEFAULT_METRICS, kw.get("tolerance", 0.10), kw.get("floor", 0.05))

    def test_same_build_is_flat(self):
        self.assertEqual(self.state([0.40, 0.42, 0.41], [0.41, 0.43, 0.40])[0], "flat")

    def test_a_real_growth_is_flagged(self):
        state, judged = self.state([0.40, 0.42, 0.41], [0.55, 0.56, 0.54])
        self.assertEqual(state, "grew")
        self.assertAlmostEqual(judged["infinite_items.n100.mb_per_item"]["delta"], 0.14, places=3)

    def test_growth_inside_the_before_spread_is_noise(self):
        # The after median beats the before median by 20 %, but one before sample was as high: no verdict.
        self.assertEqual(self.state([0.40, 0.41, 0.52], [0.49, 0.50, 0.51])[0], "flat")

    def test_growth_under_the_floor_is_flat(self):
        self.assertEqual(self.state([0.10, 0.10, 0.10], [0.13, 0.13, 0.13])[0], "flat")

    def test_a_shrink_is_flat(self):
        self.assertEqual(self.state([0.40, 0.42, 0.41], [0.20, 0.21, 0.22])[0], "flat")

    def test_no_rows_is_no_data(self):
        self.assertEqual(memory_gate.verdict(memory_gate.parse(["noise", "BEFORE r1 PERF_ROW {bad"]),
                                             memory_gate.DEFAULT_METRICS, 0.1, 0.05)[0], "no-data")

    def test_cli_exit_codes(self):
        import tempfile
        for after, code in (([0.41, 0.42, 0.40], 0), ([0.60, 0.61, 0.62], 1)):
            with tempfile.NamedTemporaryFile("w", suffix=".log", delete=False) as fh:
                fh.write("\n".join(log([0.40, 0.42, 0.41], after)) + "\n")
            try:
                self.assertEqual(memory_gate.main(["verdict", fh.name, "--markdown"]), code)
            finally:
                os.unlink(fh.name)


class Bisect(unittest.TestCase):
    shas = [f"{i:040x}" for i in range(1, 12)]

    def run_bisect(self, first_bad: int, skip=()):
        probes = []

        def is_bad(sha):
            probes.append(sha)
            i = self.shas.index(sha)
            return None if i in skip else i >= first_bad
        return memory_bisect.bisect(self.shas, is_bad, log=lambda s: None), probes

    def test_finds_each_first_bad(self):
        for first in range(len(self.shas)):
            found, probes = self.run_bisect(first)
            self.assertEqual(found, self.shas[first])
            self.assertLessEqual(len(probes), 5)

    def test_clean_range_names_none(self):
        found, probes = memory_bisect.bisect(self.shas, lambda s: False, log=lambda s: None), None
        self.assertIsNone(found)

    def test_skipped_commit_is_stepped_over(self):
        found, probes = self.run_bisect(6, skip={5})
        self.assertEqual(found, self.shas[6])

    def test_judge_reads_interleaved_runs(self):
        values = {"good": 0.40, "probe": 0.60}

        def measure(bindir):
            return ["INFINITE n=100", "PERF_ROW " + json.dumps({"name": "infinite_items.n100.mb_per_item",
                                                                  "p50": values[bindir]})]
        args = types.SimpleNamespace(repeat=3, metric="infinite_items.n100.mb_per_item", tolerance=0.1,
                                     floor_mb=0.05, direction="grew")
        build = {"G": "good", "P": "probe", "S": None}.get
        is_bad = memory_bisect.make_judge(build, measure, "G", args, log=lambda s: None)
        self.assertTrue(is_bad("P"))
        self.assertIsNone(is_bad("S"))
        values["probe"] = 0.41
        self.assertFalse(is_bad("P"))
        args.direction = "shrank"
        values["probe"] = 0.20
        self.assertTrue(is_bad("P"))


if __name__ == "__main__":
    unittest.main()
