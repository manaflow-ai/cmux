from __future__ import annotations

import sys
import importlib.util
import os
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from benchlib.bench import BenchError, Context
from benches.phone_default_speed import BENCH

FIXTURE = Path(__file__).parent / "fixtures" / "phone-default-speed" / "check.log"


MEASURE_PATH = Path(__file__).resolve().parents[1] / "phone-default-speed/measure.py"
spec = importlib.util.spec_from_file_location("phone_default_measure", MEASURE_PATH)
measure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measure)


class PhoneDefaultSpeedTest(unittest.TestCase):
    def context(self):
        return Context(bench=BENCH, build={"channel": "local"}, host_role="fleet")

    @unittest.skipUnless(sys.platform == "linux", "process ownership uses Linux proc")
    def test_timeout_stops_owned_descendant_and_inherits_outer_group(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp)
            child_file = output / "child"
            program = ("import os,subprocess,sys,time; from pathlib import Path; "
                       "p=subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)'], start_new_session=True); "
                       f"Path({str(child_file)!r}).write_text(str(p.pid)+' '+str(os.getpgrp())); "
                       "time.sleep(30)")
            with self.assertRaisesRegex(RuntimeError, "unexpected exit 124"):
                measure.run("timeout", [sys.executable, "-c", program], output, dict(os.environ), timeout=2)
            child, group = map(int, child_file.read_text().split())
            self.assertEqual(group, os.getpgrp())
            stat = Path(f"/proc/{child}/stat")
            if stat.exists():
                self.assertEqual(stat.read_text().split()[2], "Z", "descendant still executes")

    def test_actual_run_has_every_case(self):
        context = self.context()
        BENCH.ingest(context, FIXTURE)
        self.assertEqual(len(context.rows), 4)
        self.assertTrue(all(row["unit"] == "count" and row["value"] > 0 for row in context.rows))
        self.assertEqual({row["labels"]["seeded_lines"] for row in context.rows}, {"100", "10000"})

    def test_incomplete_or_duplicated_run_is_not_a_measurement(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "partial.log"
            path.write_text("primary-100\t42 Ir / 10 operations\n")
            with self.assertRaises(BenchError):
                BENCH.ingest(self.context(), path)
            path.write_text(FIXTURE.read_text() + FIXTURE.read_text())
            with self.assertRaises(BenchError):
                BENCH.ingest(self.context(), path)


if __name__ == "__main__":
    unittest.main()
