#!/usr/bin/env python3
"""scripts/cmux-next/scale-fixture-bench.py: its verdict and its config fixture, without a Mac.

Leo, 2026-11-27: "Scale fixtures. Seed one profile with about 1,000 workspaces, several Chiefs and a big cmux.json,
run the sidebar and switch flows, and fail if the main thread is blocked for more than ~250 ms."

  - pass / fail at the 250 ms budget, on either the watchdog's longest gap or its longest record;
  - blind (exit 2, never a pass) when the watchdog missed the probe stall or the rows did not ask for avatars;
  - skipped (exit 0, fail open) when the run measured nothing for a reason outside the change;
  - the config fixture is the RFD's 160 KB.
"""
from __future__ import annotations

import importlib.util
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/scale-fixture-bench.py"
sys.path.insert(0, str(SCRIPT.parent))
spec = importlib.util.spec_from_file_location("scale_fixture_bench", SCRIPT)
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


def report(**over):
    base = {
        "probe": {"seen_ms": 410},
        "fixture": {"owned": 1100},
        "workspaces_wanted": 1100,
        "flows": {"flush": {"max_gap_ms": 40, "max_ms": 0}, "scroll": {"max_gap_ms": 60, "max_ms": 0},
                  "switch": {"max_gap_ms": 120, "max_ms": 0}},
    }
    base.update(over)
    return base


class Verdict(unittest.TestCase):
    def test_pass_under_budget(self):
        self.assertEqual(bench.verdict(report())[:2], ("pass", 0))

    def test_fail_on_gap_over_budget(self):
        flows = report()["flows"]
        flows["flush"] = {"max_gap_ms": 2400, "max_ms": 0}
        name, code, reasons = bench.verdict(report(flows=flows))
        self.assertEqual((name, code), ("fail", 1))
        self.assertIn("flush", reasons[0])

    def test_fail_on_recorded_hang_over_budget(self):
        flows = report()["flows"]
        flows["switch"] = {"max_gap_ms": 0, "max_ms": 300}
        self.assertEqual(bench.verdict(report(flows=flows))[:2], ("fail", 1))

    def test_blind_when_probe_unseen(self):
        name, code, _ = bench.verdict(report(probe={"seen_ms": 0}))
        self.assertEqual((name, code), ("blind", 2))

    def test_blind_when_rows_ask_for_no_avatar(self):
        name, code, _ = bench.verdict(report(fixture={"owned": 10}))
        self.assertEqual((name, code), ("blind", 2))

    def test_blind_beats_a_quiet_pass(self):
        # A run that saw nothing must not read as green.
        self.assertNotEqual(bench.verdict(report(probe={}, fixture={}))[1], 0)

    def test_skipped_fails_open(self):
        self.assertEqual(bench.verdict({"skipped": "no GUI session"}), ("skipped", 0, ["no GUI session"]))


class Config(unittest.TestCase):
    def test_big_config_is_160_kb(self):
        size = len(json.dumps(bench.big_config()))
        self.assertGreaterEqual(size, 160_000)
        self.assertLess(size, 200_000)

    def test_big_config_names_a_chief_mascot(self):
        self.assertEqual(bench.big_config(1_000)["home"]["chiefPetMascot"], "fox")


if __name__ == "__main__":
    unittest.main()
