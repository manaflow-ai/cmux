"""Behavioral checks for the native eval report contract."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


class MetricsTests(unittest.TestCase):
    def report(self, raw, timing):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / 'raw.json').write_text(json.dumps(raw))
            (root / 'out.json').write_text('{"extra":{}}')
            (root / 'timing.jsonl').write_text(''.join(json.dumps(x)+'\n' for x in timing))
            subprocess.run([sys.executable, str(Path(__file__).with_name('rd-metrics.py')),
                            str(root/'raw.json'), str(root/'out.json'), str(root/'timing.jsonl'),
                            str(root/'missing.png'), str(root/'missing.ppm')], check=True)
            return json.loads((root/'out.json').read_text())['extra']['netem_metrics']

    def test_late_frames_are_not_on_time_and_seconds_are_supported(self):
        m = self.report({'seconds':2, 'decoded_frames':20,
                         'eval_clock':'same-host protocol monotonic microseconds',
                         'decode_records_truncated':False,
                         'decode_records':[{'release_us':1,'decoded_us':100_000 if i < 4 else 100_001} for i in range(20)],
                         'series':[{'frames':20,'bytes':1000}]},
                        [{'release_us':1,'shown_us':0,'encoded_bytes':10,'idr':True},
                         {'release_us':2,'encoded_bytes':0,'idr':False}])
        self.assertEqual(m['on_time_fps'], 2)
        self.assertEqual(m['decoded_fps'], 10)
        self.assertEqual(m['bitrate_bps'], 4000)
        self.assertEqual(m['attempts'], 2)
        self.assertEqual(m['skips'], 1)
        self.assertEqual(m['idrs'], 1)

    def test_absent_decode_timing_does_not_claim_on_time_fps(self):
        m = self.report({'seconds':2,'series':[{'frames':20,'bytes':1000}]}, [])
        self.assertIsNone(m['on_time_fps'])
        self.assertIsNone(m['skips'])
        self.assertIsNone(m['psnr_db'])

    def test_missing_capture_timestamp_does_not_count_encode_start(self):
        m = self.report({'seconds':1,'decoded_frames':1,
                         'eval_clock':'same-host protocol monotonic microseconds',
                         'decode_records_truncated':False,
                         'decode_records':[{'release_us':100,'decoded_us':101}]},
                        [{'release_us':100,'encoded_bytes':10,'idr':False}])
        self.assertIsNone(m['on_time_fps'])

    def test_quality_needs_verified_frame_identity(self):
        m = self.report({'seconds':2,'quality_samples':[{'mse':4,'capture_us':123}]}, [])
        self.assertIsNone(m['psnr_db'])


if __name__ == '__main__':
    unittest.main()
