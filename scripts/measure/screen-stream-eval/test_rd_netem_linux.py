"""Pure parsing and table checks for rd-netem-linux.py (no netns, no build)."""
import importlib.util
import json
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('rdnl', Path(__file__).with_name('rd-netem-linux.py'))
rdnl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rdnl)

LEDGER = {'schema': 'cmux.rd-stage-ledger/1', 'stages': []}


class ParseTests(unittest.TestCase):
    def test_profiles_are_the_four_asked_for(self):
        self.assertEqual(list(rdnl.PROFILES), ['clean', 'jitter-5', 'jitter-15-burst', 'jitter-30-loss2'])
        self.assertEqual(rdnl.netem_args('jitter-5'), ['netem', 'delay', '5ms', '5ms', 'limit', '100000'])
        self.assertIn('gemodel', rdnl.netem_args('jitter-15-burst'))
        self.assertEqual(rdnl.netem_args('jitter-30-loss2')[1:7], ['delay', '30ms', '30ms', 'loss', 'random', '2%'])

    def test_last_json_line_skips_log_noise(self):
        text = 'passive: first frame\n{"a": 1}\nnot json\n{"b": 2}\n'
        self.assertEqual(rdnl.last_json_line(text), {'b': 2})
        self.assertIsNone(rdnl.last_json_line('nothing\n'))

    def test_passive_series_gives_mbps_and_target_per_second(self):
        report = {'seconds': 2.0, 'bytes': 2_000_000, 'fps': 30, 'decoded_frames': 60, 'ended': None,
                  'series': [{'bytes': 1_250_000, 'duration_ms': 1000, 'host_stats': {'kbps': 8000, 'keyframes': 1}},
                             {'bytes': 750_000, 'duration_ms': 500, 'host_stats': {'kbps': 1100, 'keyframes': 3}},
                             {'bytes': 0, 'duration_ms': 1000, 'host_stats': None}],
                  'stage_ledger': LEDGER}
        s = rdnl.summarize_passive(report)
        self.assertTrue(s['ok'])
        self.assertEqual(s['mbps_per_s'], [10.0, 12.0, 0.0])
        self.assertEqual(s['target_kbps_per_s'], [8000, 1100, None])
        self.assertEqual(s['host_keyframes_delta'], 2)
        self.assertEqual(s['mbps_mean'], 8.0)
        self.assertEqual(s['stage_ledger'], LEDGER)

    def test_passive_without_ledger_or_report(self):
        self.assertIsNone(rdnl.summarize_passive({'series': [], 'ended': None})['stage_ledger'])
        self.assertFalse(rdnl.summarize_passive(None)['ok'])
        self.assertFalse(rdnl.summarize_passive({'series': [{'bytes': 1, 'duration_ms': 1000}],
                                                 'ended': 'timeout'})['ok'])

    def test_key_report(self):
        k = rdnl.summarize_key({'g2g_ms': {'n': 58, 'p50': 21.5, 'p95': 80.25}, 'lost': 2, 'mbit_per_s': 3.2,
                                'host_stats_last': {'kbps': 1000, 'loss_pct': 1.5}, 'ended': None})
        self.assertTrue(k['ok'])
        self.assertEqual((k['p50_ms'], k['p95_ms'], k['lost'], k['target_kbps_last']), (21.5, 80.25, 2, 1000))
        self.assertIsNone(k['stage_ledger'])
        self.assertFalse(rdnl.summarize_key({'g2g_ms': None, 'lost': 60})['ok'])

    def test_idr_count_skips_inputs_skips_and_partial_lines(self):
        lines = [{'inject_us': 1, 'recv_us': 2},
                 {'release_us': 1, 'encoded_bytes': 900, 'idr': True},
                 {'release_us': 2, 'encoded_bytes': 100, 'idr': False},
                 {'release_us': 3, 'encoded_bytes': 0, 'idr': True}]
        text = ''.join(json.dumps(x) + '\n' for x in lines) + '{"release_us": 4, "enco'
        self.assertEqual(rdnl.count_idrs(text), {'frames': 2, 'idrs': 1})


class TableTests(unittest.TestCase):
    def test_table_has_one_row_per_result_and_marks_errors(self):
        good = {'commit': 'a' * 40, 'profile': 'jitter-5',
                'key': {'p50_ms': 20.0, 'p95_ms': 40.0, 'lost': 0, 'stage_ledger': LEDGER},
                'passive': {'mbps_per_s': [8.0, 1.0, 1.2], 'target_kbps_per_s': [8000, 1000, 1000]},
                'idr_passive': {'idrs': 1}, 'idr_key': {'idrs': 3}}
        bad = {'commit': 'b' * 40, 'profile': 'clean', 'error': 'host did not listen'}
        table = rdnl.markdown_table([good, bad])
        lines = table.strip().splitlines()
        self.assertEqual(len(lines), 4)
        self.assertIn('| `aaaaaaaaaaaa` | 5±5 ms | 20.0 / 40.0 (0) | 1.20 (1.00–8.00) | 8.0 1.0 1.2 | 8000 1000 1000 | 1 / 3 | yes |',
                      lines[2])
        self.assertIn('error: host did not listen', lines[3])

    def test_table_cli_reads_jsonl(self):
        import io, tempfile, contextlib
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'r.jsonl'
            p.write_text(json.dumps({'commit': 'c' * 40, 'profile': 'clean', 'key': {}, 'passive': {}}) + '\n')
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(rdnl.main(['table', str(p)]), 0)
            self.assertIn('`cccccccccccc` | clean | – / – (–) | – |', out.getvalue())


if __name__ == '__main__':
    unittest.main()
