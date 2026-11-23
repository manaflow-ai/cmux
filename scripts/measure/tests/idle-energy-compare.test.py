#!/usr/bin/env python3
"""idle-energy-compare.py's pure parts: the interleaved schedule, membership, baseline coverage, ranking."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("idle_energy_compare", HERE.parent / "idle-energy-compare.py")
iec = importlib.util.module_from_spec(spec)
spec.loader.exec_module(iec)

# One process over a 60 s window: 30 J, 600 CPU s, 6000 wakeups before; +0.3 J, +6 CPU s, +60 wakeups during
# (the cmuxterm-hq#19931 fixture): 5 mW, 10 % of a core, 1 wakeup/s.
BEFORE = (30_000_000_000, 600_000_000_000, 6000, 100 * 1048576)
AFTER = (30_300_000_000, 606_000_000_000, 6060, 100 * 1048576)
T0 = 1_000_000.0


class Schedule(unittest.TestCase):
    def test_every_app_takes_every_position_once_in_three_rounds(self):
        order = iec.schedule(["next", "claude", "terminal"], 3)
        self.assertEqual(len(order), 9)
        rounds = [[app for r, app in order if r == k] for k in range(3)]
        for position in range(3):
            self.assertEqual(sorted(row[position] for row in rounds), ["claude", "next", "terminal"])

    def test_etime(self):
        self.assertEqual(iec.parse_etime("01:05"), 65)
        self.assertEqual(iec.parse_etime("2-03:00:01"), 2 * 86400 + 3 * 3600 + 1)
        self.assertIsNone(iec.parse_etime("x"))


class Members(unittest.TestCase):
    def test_descendants_and_private_bundle_processes_count_others_do_not(self):
        table = [(10, 1, 501, T0, "/w/claude/Claude.app/Contents/MacOS/Claude"),
                 (11, 10, 501, T0, "/w/claude/Claude.app/Contents/Frameworks/Claude Helper --type=renderer"),
                 (12, 10, 501, T0, "/usr/local/bin/claude --acp"),
                 (13, 12, 501, T0, "/usr/bin/node child"),
                 (20, 1, 501, T0, "/w/claude/Claude.app/Contents/Resources/daemon"),
                 (30, 1, 501, T0, "/usr/local/bin/claude unrelated")]
        found = iec.members(table, 10, ("/w/claude/Claude.app",))
        self.assertEqual(set(found), {10, 11, 12, 13, 20})

    def test_system_app_is_its_pid_and_descendants_only(self):
        table = [(40, 1, 501, T0, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
                 (41, 1, 501, T0, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
                 (42, 40, 0, T0, "login -pfl user /bin/zsh")]
        self.assertEqual(set(iec.members(table, 40, ())), {40, 42})


class Baseline(unittest.TestCase):
    def test_stable_member(self):
        r = iec.window_delta({7: BEFORE}, {7: AFTER}, {7: T0 - 100}, T0, 60)
        self.assertTrue(r["valid"])
        self.assertEqual((r["total"]["mw"], r["total"]["cpu_pct"], r["total"]["wakeups_per_s"]), (5.0, 10.0, 1.0))

    def test_missing_baseline_of_an_old_process_is_invalid_not_101x(self):
        r = iec.window_delta({7: None}, {7: AFTER}, {7: T0 - 100}, T0, 60)
        self.assertFalse(r["valid"])
        self.assertEqual(r["total"]["mw"], 0)

    def test_old_process_that_joined_membership_mid_window_is_invalid(self):
        r = iec.window_delta({}, {7: AFTER}, {7: T0 - 100}, T0, 60)
        self.assertFalse(r["valid"])

    def test_process_born_in_the_window_counts_from_zero(self):
        small = (300_000_000, 6_000_000_000, 60, 1048576)
        r = iec.window_delta({7: BEFORE}, {7: AFTER, 8: small}, {7: T0 - 100, 8: T0 + 10}, T0, 60)
        self.assertTrue(r["valid"])
        self.assertEqual(r["new_in_window"], [8])
        self.assertEqual(r["total"]["mw"], 10.0)

    def test_exit_in_the_window_is_invalid(self):
        r = iec.window_delta({7: BEFORE, 8: BEFORE}, {7: AFTER}, {7: T0 - 100, 8: T0 - 100}, T0, 60)
        self.assertFalse(r["valid"])


class Ranking(unittest.TestCase):
    def window(self, app, mw, valid=True):
        return {"app": app, "valid": valid, "total": {"mw": mw, "cpu_pct": mw / 10, "wakeups_per_s": mw, "footprint_mb": 1}}

    def test_ranked_by_mean_mw_over_valid_windows_only(self):
        windows = [self.window("next", 3), self.window("next", 5), self.window("claude", 20), self.window("claude", 1000, False),
                   self.window("terminal", 1), self.window("terminal", 2)]
        ranking = iec.rank(windows, ["next", "claude", "terminal"])
        self.assertEqual([r["app"] for r in ranking], ["terminal", "next", "claude"])
        claude = ranking[2]
        self.assertEqual((claude["mw"], claude["n_valid"], claude["n"]), (20, 1, 2))
        table = iec.markdown(ranking, {"next": "cmux NEXT"}, {"idle": {}, "control": {}})
        self.assertIn("| 2 | cmux NEXT | 4 (3-5)", table)

    def test_app_with_no_valid_window_is_unranked(self):
        ranking = iec.rank([self.window("next", 3), self.window("claude", 9, False)], ["next", "claude"])
        self.assertEqual(ranking[-1]["app"], "claude")
        self.assertIsNone(ranking[-1]["rank"])


class Import(unittest.TestCase):
    def test_bench_ingests_the_result_line(self):
        sys.path.insert(0, str(HERE.parents[1] / "bench"))
        from benches.idle_compare import BENCH
        rows = []
        ctx = types.SimpleNamespace(host={}, build={}, notes=[], row=lambda *a, **k: rows.append((a, k)))
        ranking = iec.rank([self.window_for("next", 4), self.window_for("terminal", 1)], ["next", "terminal"])
        result = {"host": "m1", "os": "27.0", "chip": "arm64", "start": "2026-11-23T04:00:00Z", "ranking": ranking,
                  "apps": {"next": {"version": "1"}, "terminal": {"version": "2"}}}
        with tempfile.TemporaryDirectory() as root:
            log = Path(root) / "log.txt"
            log.write_text("noise\nIDLE-COMPARE-RESULT " + json.dumps(result) + "\n")
            BENCH.ingest(ctx, log)
        self.assertEqual(len(rows), 6)
        self.assertEqual(rows[0][0][:3], ("cpu_energy", 1.0, "mW"))
        self.assertEqual(rows[0][1]["labels"]["app"], "terminal")

    def window_for(self, app, mw):
        return {"app": app, "valid": True, "total": {"mw": mw, "cpu_pct": 1, "wakeups_per_s": 2, "footprint_mb": 3}}


if __name__ == "__main__":
    unittest.main()
