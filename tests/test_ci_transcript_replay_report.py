#!/usr/bin/env python3
"""scripts/ci/transcript_replay_report.py: the per-kind table, base against head, from the bench's PERF_ROW lines.

The report is report only: a regression is marked in text and the script still exits 0; a side with no rows is
named with its first error; a kind only one side measured still gets its row.

Run: python3 tests/test_ci_transcript_replay_report.py
"""
from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("transcript_replay_report", ROOT / "scripts/ci/transcript_replay_report.py")
report_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report_mod)


def row(name: str, p50: float, p95: float) -> str:
    return "PERF_ROW " + json.dumps({"name": f"transcript_replay.long.{name}", "p50": p50, "p95": p95}) + "\n"


class ReportTest(unittest.TestCase):
    def write(self, d: Path, name: str, text: str) -> None:
        (d / name).write_text(text)

    def test_table_marks_regression_and_improvement(self) -> None:
        with tempfile.TemporaryDirectory() as t:
            d = Path(t)
            self.write(d, "before-1.log", row("tool_call_ms", 6.1, 8.9) + row("tool_call.hidden_pane_renders_per_record", 1, 1)
                       + row("thought_ms", 2.0, 3.0) + row("token_slope_ms_per_krow", 0.4, 0.4))
            self.write(d, "after-1.log", row("tool_call_ms", 2.5, 2.9) + row("tool_call.hidden_pane_renders_per_record", 0, 0)
                       + row("thought_ms", 2.1, 6.0))
            lines, series = report_mod.report(str(d), "a" * 40, "b" * 40, "test-class")
            text = "\n".join(lines)
            self.assertIn("| tool_call | 6.1 → 2.5 | 8.9 → 2.9 | - → - | 1 → 0 | improvement |", text)
            self.assertIn("| thought | 2 → 2.1 | 3 → 6 |", text)
            self.assertIn("**Reads as a regression:** thought.", text)
            self.assertNotIn("token_slope", text)
            self.assertIn("Duress not run on this class", text)
            self.assertTrue(any(s["series"].endswith("tool_call_ms.p95@test-class") for s in series))

    def test_busy_host_reads_ms_as_noisy_not_regression(self) -> None:
        with tempfile.TemporaryDirectory() as t:
            d = Path(t)
            self.write(d, "before-1.log", row("token_ms", 7.5, 8.6) + row("thought.hidden_pane_renders_per_record", 0, 0)
                       + row("thought_ms", 2, 3))
            self.write(d, "after-1.log", row("token_ms", 13.8, 19.5) + row("thought.hidden_pane_renders_per_record", 1, 1)
                       + row("thought_ms", 2, 3))
            self.write(d, "before-1.load", "4.10\n4.80\n")
            self.write(d, "after-1.load", "4.70\n")
            text = "\n".join(report_mod.report(str(d), "a" * 40, "b" * 40, "c")[0])
            self.assertIn("Host load per core over the runs: base 4.8, head 4.7. Past 1,", text)
            self.assertIn("| token | 7.5 → 13.8 | 8.6 → 19.5 | - → - | - → - | noisy (host load 4.8 per core) |", text)
            # A render count does not move with load: still a regression.
            self.assertIn("**Reads as a regression:** thought.", text)

    def test_rounds_take_the_median(self) -> None:
        with tempfile.TemporaryDirectory() as t:
            d = Path(t)
            for r, v in enumerate((2.0, 9.0, 3.0), 1):
                self.write(d, f"after-{r}.log", row("token_ms", v, v))
            rows = report_mod.side_rows(str(d), "after")
            self.assertEqual(rows["transcript_replay.long.token_ms"]["p95"], 3.0)

    def test_missing_side_names_its_error_and_exits_zero(self) -> None:
        with tempfile.TemporaryDirectory() as t:
            d = Path(t)
            self.write(d, "before-1.log", "transcript-replay: long FAILED: page never attached\n")
            self.write(d, "after-1.log", row("token_ms", 5, 6))
            (d / "duress-after.json").write_text(json.dumps({"frame_p95_ms": 50, "load_per_core": 5.3}))
            lines, _ = report_mod.report(str(d), "a" * 40, "b" * 40, "c")
            text = "\n".join(lines)
            self.assertIn("**No base rows**: `transcript-replay: long FAILED: page never attached`", text)
            self.assertIn("| token | - → 5 | - → 6 |", text)
            self.assertIn("| head | - | 50 ms |", text)
            (d / "duress-before.json").write_text(json.dumps({"frame_p95_ms": None, "error": "error: no playwright\nBun"}))
            text = "\n".join(report_mod.report(str(d), "a" * 40, "b" * 40, "c")[0])
            self.assertIn("**base duress reading failed**: `error: no playwright`", text)
            self.assertEqual(report_mod.main([str(d)]), 0)
            self.assertEqual(report_mod.main([str(d / "missing")]), 0)


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
