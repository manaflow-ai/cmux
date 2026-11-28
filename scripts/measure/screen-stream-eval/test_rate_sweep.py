#!/usr/bin/env python3
"""rate-sweep.py's pure parts: --var parsing, cc.rs rewrites, NOW's scoring and the table."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("rate_sweep", HERE / "rate-sweep.py")
rs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rs)
CC = HERE.parents[2] / rs.CC_RS


class RateSweepTests(unittest.TestCase):
    def test_parse_var(self):
        self.assertEqual(rs.parse_var("pg3:PROBE_GROWTH_PER_S=3.0,start_bps=12_000_000"),
                         ("pg3", {"PROBE_GROWTH_PER_S": "3.0", "start_bps": "12_000_000"}))
        for bad in ("nolabel", "base:BETA=0.9", "x:BETA", "x:BETA=abc", "x y:BETA=1"):
            with self.assertRaises(ValueError, msg=bad):
                rs.parse_var(bad)

    def test_apply_edits_on_real_cc(self):
        src = CC.read_text()
        out = rs.apply_edits(src, {"PROBE_GROWTH_PER_S": "3.0", "lan_start_bps": "40_000_000",
                                   "OUTAGE_MIN_US": "150_000"})
        self.assertIn("const PROBE_GROWTH_PER_S: f64 = 3.0;", out)
        self.assertIn("lan_start_bps: 40_000_000,", out)
        self.assertIn("pub const OUTAGE_MIN_US: u64 = 150_000;", out)
        self.assertEqual(len(out.splitlines()), len(src.splitlines()))
        with self.assertRaises(ValueError):
            rs.apply_edits(src, {"NO_SUCH_CONST": "1"})

    def test_score_unreached_is_length_plus_one(self):
        self.assertEqual(rs.score({"s_to_15mbps_100ms": 0.3}, 10), (0.3, True))
        self.assertEqual(rs.score({"s_to_15mbps_100ms": None}, 10), (11.0, False))
        self.assertEqual(rs.score(None, 10), (11.0, False))

    def test_table(self):
        rows = [{"variant": "base", "edits": {}, "profile": "clean", "s_to_15mbps": s, "reached": s < 11,
                 "target_s": 0.1, "received_s": s} for s in (0.1, 0.2, 11.0)]
        rows.append({"variant": "base", "edits": {}, "profile": "clean", "error": "x", "s_to_15mbps": 11.0,
                     "reached": False})
        md = rs.table(rows)
        self.assertIn("| base | (main) | clean | 3 | 0.20 | 11.00 | 11.00 | 1 | 0.10 | 0.20 | 1 |", md)


if __name__ == "__main__":
    unittest.main()
