"""snappy: a snappy-bench.sh log (or snappy.json, or snappy-bench.py --summarize's line) -> one run's rows."""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benches.snappy import BENCH  # noqa: E402

LOG = Path(__file__).resolve().parent / "fixtures" / "snappy" / "snappy.log"


def ingest(path=LOG):
    ctx = Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": None}, host_role="fleet",
                  args={}, timestamp="2026-11-25T00:00:00Z")
    BENCH.ingest(ctx, path)
    return {(r["metric"], r["labels"]["duress"]): r for r in ctx.rows}


class SnappyTest(unittest.TestCase):
    def test_rows_per_duress(self):
        rows = ingest()
        self.assertEqual(rows[("send_paint", "none")]["p95"], 24.0)
        self.assertEqual(rows[("reserved_same_frame", "none")]["value"], 75.0)
        self.assertEqual(rows[("reserved_same_frame", "none")]["better"], "higher")
        self.assertEqual(rows[("shifts_per_send", "none")]["p95"], 2)
        self.assertEqual(rows[("failed_sends", "none")]["value"], 1)
        self.assertEqual(rows[("send_paint", "offline")]["value"], 9.0)
        self.assertNotIn(("send_first_token", "offline"), rows)

    def test_one_shift_counter_over_every_transition(self):
        report = {"schema": "snappy-bench/v1", "duress": "none", "surface": "local", "mode": "active", "rows": {
            "sends": 2, "failed_sends": 0, "shifts_per_send_mean": 1.0, "shifts_per_send_max": 1,
            "transitions": 4, "failed_transitions": 1, "shifts_per_transition_mean": 0.75,
            "shifts_per_transition_max": 2, "shifts_per_mid_turn_mean": 0.0, "shifts_per_compaction_mean": 2.0,
            "shifts_per_mid_compaction_mean": 1.0}}
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "snappy.json"
            path.write_text(json.dumps({"schema": "snappy-bench/v1", "reports": [report]}))
            rows = ingest(path)
        self.assertEqual(rows[("shifts_per_transition", "none")]["value"], 0.75)
        self.assertEqual(rows[("shifts_per_transition", "none")]["p95"], 2)
        self.assertEqual(rows[("shifts_per_compaction", "none")]["value"], 2.0)
        self.assertEqual(rows[("shifts_per_mid_turn", "none")]["value"], 0.0)
        self.assertEqual(rows[("shifts_per_mid_compaction", "none")]["value"], 1.0)
        self.assertEqual(rows[("failed_transitions", "none")]["value"], 1)

    def test_a_report_without_transitions_has_no_transition_rows(self):
        self.assertNotIn(("shifts_per_transition", "none"), ingest())

    def test_a_log_without_a_report_is_refused(self):
        with self.assertRaises(BenchError):
            ingest(Path(__file__))


if __name__ == "__main__":
    unittest.main()
