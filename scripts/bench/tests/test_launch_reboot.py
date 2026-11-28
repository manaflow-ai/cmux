"""Reboot measurements keep synthetic cat and production reader evidence separate."""
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from benchlib.bench import BenchError, Context
from benches.launch_reboot import BENCH


class LaunchRebootTests(unittest.TestCase):
    def ingest(self, text):
        ctx = Context(bench=BENCH, build={"channel": "sha", "sha": "a" * 40}, host_role="fleet", args={})
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "after.log"
            path.write_text(text)
            BENCH.ingest(ctx, path)
        return ctx.rows

    def test_production_cost_and_launch(self):
        rows = self.ingest('helper said "unterminated quote\n'
                           'LB-READ reboot=3 arm=read file=cmux wall_ms=12 cpu_ms=6 maxrss=4096\n'
                           'LB-PREREAD reboot=3 arm=preread wall_ms=120 cpu_ms=60 maxrss=1179648\n'
                           'LB-LAUNCH arm=preread reboot=3 window_on_screen=420.7 first_frame=null\n')
        metrics = {row['metric']: row for row in rows}
        self.assertEqual(metrics['preread_cpu_ms']['value'], 60)
        self.assertEqual(metrics['preread_maxrss']['unit'], 'bytes')
        self.assertEqual(metrics['read_wall_ms']['value'], 12)
        self.assertEqual(metrics['read_wall_ms']['labels']['file'], 'cmux')
        self.assertEqual(metrics['window_on_screen']['value'], 420.7)
        self.assertEqual(metrics['preread_cpu_ms']['labels']['arm'], 'preread')
        self.assertNotIn('first_frame', metrics)

    def test_failed_or_incomplete_phase_refused(self):
        for log in ('LB-FAIL reboot=3 no bundled reader\n',
                    'LB-PREREAD reboot=3 arm=preread cpu_ms=60\n'):
            with self.assertRaises(BenchError):
                self.ingest(log)


if __name__ == '__main__':
    unittest.main()
