#!/usr/bin/env python3
"""scripts/measure/ios_snappy.py: the snappy-bench/v1 rows from a synthetic send trace and marks.

No simulator: the trace and marks below are in the forms SnappySendBenchUITests and the app's
LoadFrameProbe send trace write (CMUX_MOBILE_SEND_TRACE). Run: python3 -I tests/test_ios_snappy.py"""
import importlib.util, json, os, sys, tempfile, unittest
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ios_snappy_under_test", ROOT / "scripts/measure/ios_snappy.py")
M = importlib.util.module_from_spec(spec)
spec.loader.exec_module(M)

TRACE = """t=100.000000 v=1 off=0 rows=a|user|0|40;b|answer|40|100
t=100.500000 ev=send
t=100.520000 v=1 off=0 rows=a|user|0|40;b|answer|40|100;c|user|140|40;d|work|180|30
t=100.900000 v=1 off=10 rows=a|user|0|40;b|answer|40|100;c|user|140|40;e|answer|180|30
t=100.950000 v=1 off=20 rows=a|user|0|40;b|answer|40|100;c|user|140|40;e|answer|180|60
t=101.000000 v=1 off=20 rows=a|user|5|40;b|answer|45|100;c|user|145|40;e|answer|185|60
t=102.000000 ev=send
t=102.040000 v=1 off=20 rows=a|user|5|40;b|answer|45|100;c|user|145|40;e|answer|185|60;f|user|245|40
t=102.060000 v=1 off=20 rows=a|user|5|40;b|answer|45|100;c|user|145|40;e|answer|185|60;f|user|245|40;g|answer|285|20
t=103.000000 v=1 off=0 rows=
t=103.300000 v=2 off=0 rows=a|user|0|40
"""
MARKS = """snap-mark 100.450000 local send.0
snap-mark 101.950000 local send.1
snap-mark 102.500000 local sends.end
snap-mark 103.100000 local switch.0
snap-mark 104.000000 local end
"""


class SnappyTest(unittest.TestCase):
    def test_rows(self):
        sends, switches = M.analyze(TRACE, MARKS)
        self.assertEqual(sends[0]["send_paint_ms"], 20.0)
        self.assertTrue(sends[0]["reserved_same_frame"])
        self.assertEqual(sends[0]["first_token_ms"], 400.0)
        # Scrolled by 10 and 20 while following: no shift; the rows above moving by 5 is one.
        self.assertEqual(sends[0]["shifts"], 1)
        self.assertEqual(sends[1]["send_paint_ms"], 40.0)
        self.assertFalse(sends[1]["reserved_same_frame"])
        self.assertEqual(sends[1]["shifts"], 0)
        self.assertEqual(switches, [200.0])
        rows = M.rows_of(sends, switches)
        self.assertEqual(rows["sends"], 2)
        self.assertEqual(rows["reserved_same_frame_share"], 0.5)
        self.assertEqual(rows["shifts_per_send_max"], 1)
        self.assertEqual(rows["chat_switch_paint_p95_ms"], 200.0)

    def test_report_from_attachments(self):
        with tempfile.TemporaryDirectory() as d:
            folder = Path(d, "ui-attachments")
            folder.mkdir()
            Path(folder, "snappy-trace-local.txt").write_text(TRACE)
            Path(folder, "snappy-marks-local.txt").write_text(MARKS)
            objs = M.report(Path(d), "abc", "sim")
            self.assertEqual(len(objs), 1)
            o = objs[0]
            self.assertEqual((o["schema"], o["platform"], o["surface"], o["mode"]), ("snappy-bench/v1", "ios", "local", "active"))
            self.assertEqual(set(o["rows"]), {"send_paint_p50_ms", "send_paint_p95_ms", "reserved_same_frame_share",
                                              "shifts_per_send_mean", "shifts_per_send_max", "send_first_token_p50_ms",
                                              "send_first_token_p95_ms", "chat_switch_paint_p95_ms", "sends"})
            json.dumps(o)


if __name__ == "__main__":
    unittest.main()
