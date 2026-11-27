from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from benchlib.bench import BenchError, Context
from benches.phone_speed import BENCH

FIXTURE = Path(__file__).parent / "fixtures" / "phone-speed" / "check.log"


class PhoneSpeedTest(unittest.TestCase):
    def context(self):
        return Context(bench=BENCH, build={"channel": "local"}, host_role="fleet")

    def test_actual_run_has_every_case(self):
        context = self.context()
        BENCH.ingest(context, FIXTURE)
        self.assertEqual(len(context.rows), 6)
        self.assertTrue(all(row["unit"] == "count" and row["value"] > 0 for row in context.rows))
        self.assertEqual({row["labels"]["history_rows"] for row in context.rows}, {"100", "10000"})

    def test_incomplete_or_duplicated_run_is_not_a_measurement(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "partial.log"
            path.write_text("echo-100\t42 Ir / 10 operations\n")
            with self.assertRaises(BenchError):
                BENCH.ingest(self.context(), path)
            path.write_text(FIXTURE.read_text() + FIXTURE.read_text())
            with self.assertRaises(BenchError):
                BENCH.ingest(self.context(), path)


if __name__ == "__main__":
    unittest.main()
