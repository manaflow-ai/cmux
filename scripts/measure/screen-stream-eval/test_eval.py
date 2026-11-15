"""Report contract: complete buckets, required bytes, and honest repeats."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('report', Path(__file__).with_name('eval.py'))
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class ReportTests(unittest.TestCase):
    def test_buckets_crossing_phase_or_guard_are_discarded(self):
        phases = {'idle': {'start_unix_ms':2000, 'end_unix_ms':6000}}
        rows = [{'unix_ms':4000,'duration_ms':2500,'bytes':1000,'frames':100},
                {'unix_ms':4500,'duration_ms':2000,'bytes':1000,'frames':100},
                {'unix_ms':6000,'duration_ms':1000,'bytes':1000,'frames':4},
                {'unix_ms':6500,'duration_ms':1000,'bytes':1000,'frames':100}]
        self.assertEqual(report.phase_numbers(rows, phases)[1]['idle'], 4)
        self.assertIsNone(report.phase_numbers(rows[:2], phases)[1]['idle'])

    def test_transport_counts_use_elapsed_time_and_exact_boundary(self):
        phases = {'scroll':{'start_unix_ms':0,'end_unix_ms':5000}}
        rows = [{'unix_ms':3000,'duration_ms':2000,'bytes':2000,'frames':100},
                {'unix_ms':4000,'bytes':1000,'frames':50}]
        kbps, fps, _, _ = report.phase_numbers(rows, phases)
        self.assertEqual(kbps['scroll'], 8)
        self.assertEqual(fps['scroll'], 50)

    def test_invalid_duration_is_not_a_rate(self):
        phases = {'idle':{'start_unix_ms':0,'end_unix_ms':6000}}
        for duration in (0, -1, None, True, '1000', float('nan'), float('inf')):
            with self.subTest(duration=duration):
                rows = [{'unix_ms':4000,'duration_ms':duration,'bytes':1000,'frames':60}]
                self.assertIsNone(report.phase_numbers(rows, phases)[0]['idle'])

    def fixture(self, folder, missing_bytes=False):
        for kind in ('key','pointer'):
            (folder/f'latency-{kind}.json').write_text(json.dumps({'g2g_ms':{'p50':10}}))
        for repeat, metrics in enumerate(({'on_time_fps':24,'psnr_db':42},
                                         {'on_time_fps':None,'psnr_db':None}, {}), 1):
            row = {'unix_ms':2000,'frames':60}
            if not missing_bytes:
                row['bytes'] = 1000
            (folder/f'window-{repeat}.json').write_text(json.dumps({'series':[row],
                'extra':{'netem_metrics':metrics}}))
            (folder/f'phases-{repeat}.jsonl').write_text(''.join(json.dumps({'phase':phase,
                'start_unix_ms':0,'end_unix_ms':3000})+'\n' for phase in report.WINDOW_PHASES))
            (folder/f'ocr-{repeat}.json').write_text('{"cer":0.01}')

    def test_rd_requires_bytes_even_when_frames_are_present(self):
        with tempfile.TemporaryDirectory() as name:
            folder = Path(name)
            self.fixture(folder, missing_bytes=True)
            report.target('rd', folder, folder/'out.json')
            result = json.loads((folder/'out.json').read_text())
            self.assertFalse(result['ok'])
            self.assertTrue(any('no numbers' in e for e in result['errors']))

    def test_mixed_repeats_keep_missing_evidence_without_first_repeat_aggregate(self):
        with tempfile.TemporaryDirectory() as name:
            folder = Path(name)
            self.fixture(folder)
            report.target('rd', folder, folder/'out.json')
            result = json.loads((folder/'out.json').read_text())
            self.assertTrue(result['ok'])
            self.assertNotIn('netem_metrics', result['extra'])
            repeats = result['extra']['repeats']
            self.assertEqual(repeats[0]['window_netem_metrics']['on_time_fps'], 24)
            self.assertIsNone(repeats[1]['window_netem_metrics']['on_time_fps'])
            self.assertEqual(repeats[2]['window_netem_metrics'], {})

    def test_window_only_exemption_does_not_invent_window_data(self):
        with tempfile.TemporaryDirectory() as name:
            folder = Path(name)
            (folder/'window-only').touch()
            report.target('window-only', folder, folder/'out.json')
            errors = json.loads((folder/'out.json').read_text())['errors']
            self.assertFalse(any(e.startswith('latency') for e in errors))
            self.assertIn('window: no repeat ran', errors)


if __name__ == '__main__':
    unittest.main()
