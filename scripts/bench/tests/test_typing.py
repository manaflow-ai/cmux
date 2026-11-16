"""Reject misleading typing receipts: lost/reordered keys, missing clocks and partial load runs."""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts/bench"))
sys.path.insert(0, str(ROOT / "scripts/cmux-next"))
from benchlib.bench import BenchError, Context  # noqa: E402
from benches.typing import BENCH  # noqa: E402
from typing_load_bench import verdict  # noqa: E402


class TypingReceipt(unittest.TestCase):
    def setUp(self):
        self.text = "abcdefghijklmnopqrstuvwxyz" * 10
        self.dispatch = [{"epoch_ms": 100000 + i * 20} for i in range(len(self.text))]
        self.report = {"composer_text": self.text, "samples": [
            {"key": key, "frame": 5, "paint": 7, "listener": 1, "work": 3,
             "paint_epoch_ms": sent["epoch_ms"] + 12}
            for key, sent in zip(self.text, self.dispatch)]}

    def test_clock_join_includes_native_admission(self):
        got = verdict(self.report, self.text, self.dispatch)
        self.assertTrue(got["complete"])
        self.assertEqual(got["paint_p99_ms"], 7)
        self.assertEqual(got["dispatch_to_after_frame_p99_ms"], 12)

    def test_reordered_dropped_or_unpainted_keys_are_incomplete(self):
        for change in ("order", "loss", "work", "clock", "text", "negative"):
            with self.subTest(change=change):
                report = copy.deepcopy(self.report)
                if change == "order":
                    report["samples"][:2] = reversed(report["samples"][:2])
                elif change == "loss":
                    report["samples"].pop()
                elif change == "work":
                    report["samples"][0].pop("work")
                elif change == "clock":
                    report["samples"][0].pop("paint_epoch_ms")
                elif change == "text":
                    report["composer_text"] = self.text[:-1]
                else:
                    report["samples"][0]["paint_epoch_ms"] = 1
                self.assertFalse(verdict(report, self.text, self.dispatch)["complete"])

    def test_p99_retains_tail_not_average(self):
        for sample in self.report["samples"][-4:]:
            sample["paint"] = 80
        got = verdict(self.report, self.text, self.dispatch)
        self.assertEqual(got["paint_p99_ms"], 80)
        self.assertFalse(got["renderer_budget_met"])

    def ingest(self, row):
        ctx = Context(bench=BENCH, build={"channel": "sha", "sha": "a" * 40}, host_role="fleet")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "report.json"
            path.write_text(json.dumps({"host": "fixture-mac", "modes": {"chromium": {"typing_loads": [row]}}}))
            BENCH.ingest(ctx, path)
        return ctx

    def test_partial_run_keeps_integrity_diagnostic_without_fast_timing(self):
        ctx = self.ingest({"load": "cpu", "complete": False})
        self.assertEqual({r["metric"] for r in ctx.rows}, {"measurement_complete", "key_integrity"})

    def test_ledger_has_p99_and_native_dispatch(self):
        row = {"load": "streaming-3", "typing": self.report, **verdict(self.report, self.text, self.dispatch)}
        ctx = self.ingest(row)
        values = {r["metric"]: r["value"] for r in ctx.rows}
        self.assertEqual(values["keydown_to_paint_p99_ms"], 7)
        self.assertEqual(values["dispatch_to_after_frame_p99_ms"], 12)
        self.assertTrue(all(r["host"]["name"] == "fixture-mac" for r in ctx.rows))
        row["typing"]["samples"].pop()
        with self.assertRaises(BenchError):
            self.ingest(row)


if __name__ == "__main__":
    unittest.main()
