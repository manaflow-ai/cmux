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
    def test_profiles(self):
        self.assertEqual(list(rdnl.PROFILES), ['clean', 'jitter-5', 'jitter-15-burst', 'jitter-30-loss2', 'stall',
                                               'wifi-away', 'wifi-away-short', 'wifi-away-long', 'wifi-away-loss',
                                               'loss-0.5', 'loss-1', 'loss-2', 'loss-5'])
        self.assertEqual(set(rdnl.PROFILES), set(rdnl.PROFILE_LABELS))
        self.assertEqual(rdnl.netem_args('jitter-5'), ['netem', 'delay', '5ms', '5ms', 'limit', '100000'])
        self.assertIn('gemodel', rdnl.netem_args('jitter-15-burst'))
        self.assertEqual(rdnl.netem_args('jitter-30-loss2')[1:7], ['delay', '30ms', '30ms', 'loss', 'random', '2%'])

    def test_loss_sweep_reads_reassembly_over_rtt(self):
        self.assertEqual(rdnl.netem_args('loss-0.5')[1:6], ['delay', '10ms', 'loss', 'random', '0.5%'])
        self.assertEqual(rdnl.nominal_rtt_ms('loss-2'), 20.0)
        self.assertIsNone(rdnl.nominal_rtt_ms('wifi-away'))
        ledger = {'schema': 'cmux.rd-stage-ledger/1',
                  'stages': [{'stage': 'Decode', 'p95_ms': 4.0}, {'stage': 'Reassembly', 'p50_ms': 0.2, 'p95_ms': 27.5}]}
        r = rdnl.reassembly_row('loss-1', {'stage_ledger': ledger, 'repair_rtt_ms': 21.3})
        self.assertEqual(r, {'p95_ms': 27.5, 'rtt_ms': 20.0, 'repair_rtt_ms': 21.3, 'over_rtt_ms': 7.5})
        self.assertIsNone(rdnl.reassembly_row('loss-1', {})['over_rtt_ms'])
        row = {'commit': 'a' * 40, 'profile': 'loss-1', 'openh264': 'cisco', 'key': {}, 'passive': {}, 'reassembly': r}
        self.assertIn('| 7.50 (27.50, 20.0) |', rdnl.markdown_table([row]))

    def test_sparse_checkout_covers_every_path_dependency(self):
        import re
        manifest = Path(__file__).resolve().parents[3] / 'cmux-tui' / 'Cargo.toml'
        for dep in re.findall(r'path\s*=\s*"([^"]+)"', manifest.read_text()):
            full = f'cmux-tui/{dep}'
            self.assertTrue(any(full == p or full.startswith(p + '/') for p in rdnl.SPARSE_PATHS), full)

    def test_last_json_line_skips_log_noise(self):
        text = 'passive: first frame\n{"a": 1}\nnot json\n{"b": 2}\n'
        self.assertEqual(rdnl.last_json_line(text), {'b': 2})
        self.assertIsNone(rdnl.last_json_line('nothing\n'))

    def test_passive_series_gives_mbps_and_target_per_second(self):
        report = {'seconds': 2.0, 'bytes': 2_000_000, 'fps': 30, 'decoded_frames': 60, 'ended': None,
                  'series': [{'bytes': 1_250_000, 'duration_ms': 1000, 'decoded_frames': 30,
                              'host_stats': {'kbps': 8000, 'keyframes': 1}},
                             {'bytes': 1_000_000, 'duration_ms': 500, 'decoded_frames': 10,
                              'host_stats': {'kbps': 16000, 'keyframes': 3}},
                             {'bytes': 0, 'duration_ms': 1000, 'host_stats': None}],
                  'stage_ledger': LEDGER}
        s = rdnl.summarize_passive(report)
        self.assertTrue(s['ok'])
        self.assertEqual(s['mbps_per_s'], [10.0, 16.0, 0.0])
        self.assertEqual(s['target_kbps_per_s'], [8000, 16000, None])
        self.assertEqual(s['decoded_fps_per_s'], [30.0, 20.0, None])
        self.assertEqual((s['target_s_to_15mbps'], s['received_s_to_15mbps']), (2, 2))
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
        self.assertEqual(rdnl.count_idrs(text), {'frames': 2, 'idrs': 1, 'reasons': {'unlogged': 1}})

    def test_idr_reasons_when_the_host_logs_them(self):
        lines = [{'encoded_bytes': 9, 'idr': True, 'idr_reason': 'loss'},
                 {'encoded_bytes': 9, 'idr': True, 'idr_reason': 'loss'},
                 {'encoded_bytes': 9, 'idr': True, 'force_idr': False},
                 {'encoded_bytes': 9, 'idr': True, 'force_idr': True}]
        self.assertEqual(rdnl.count_idrs(''.join(json.dumps(x) + '\n' for x in lines))['reasons'],
                         {'loss': 2, 'encoder': 1, 'requested': 1})

    def test_wire_summary_from_counter_samples(self):
        w = rdnl.wire_summary([(0.0, 0, 0), (1.0, 1_250_000, 12_500), (1.5, 2_000_000, 12_500)])
        self.assertEqual(w['down_mbps_per_s'], [10.0, 12.0])
        self.assertEqual(w['up_mbps_per_s'], [0.1, 0.0])
        self.assertEqual(rdnl.wire_summary([(0.0, 5, 5)])['down_mbps_per_s'], [])

    def test_stall_metrics(self):
        # One stall from 10.0 s to 10.6 s on the monotonic clock, wall 100_000..100_600 ms.
        stall = {'start_us': 10_000_000, 'end_us': 10_600_000, 'start_ms': 100_000, 'end_ms': 100_600}
        records = ([{'release_us': 9_000_000 + i * 100_000, 'decoded_us': 9_020_000 + i * 100_000} for i in range(11)]
                   # held frames, captured during the hold, decoded in the burst
                   + [{'release_us': 10_100_000, 'decoded_us': 10_610_000},
                      {'release_us': 10_200_000, 'decoded_us': 10_612_000},
                      # the first fresh frame: captured at the release, decoded 30 ms after it
                      {'release_us': 10_600_000, 'decoded_us': 10_630_000},
                      {'release_us': 10_700_000, 'decoded_us': 10_720_000}])
        series = [{'unix_ms': 99_500, 'host_stats': {'kbps': 20000}},
                  {'unix_ms': 100_500, 'host_stats': {'kbps': 19000}},
                  {'unix_ms': 101_500, 'host_stats': {'kbps': 12000}},
                  {'unix_ms': 102_500, 'host_stats': {'kbps': 15000}}]
        [m] = rdnl.stall_metrics({'decode_records': records, 'series': series}, [stall])
        self.assertEqual((m['target_before_kbps'], m['target_after_kbps'], m['target_min_within_3s_kbps']),
                         (20000, 15000, 12000))
        self.assertEqual(m['fresh_frame_ms'], 30.0)
        self.assertEqual(m['fps_second_after'], 4)
        self.assertEqual((m['decoded_during_hold'], m['decoded_in_100ms_after']), (0, 3))
        self.assertIn('| 1 | 20000 → 15000 (12000) | 30.0 | 4 | 0 / 3 |',
                      rdnl.stall_table([{'commit': 'd' * 40, 'stalls': [m]}]))
        self.assertEqual(rdnl.stall_table([{'commit': 'd' * 40}]), '')

    def test_wifi_away_holds_file_is_the_seeded_schedule(self):
        on_disk = json.loads(Path(__file__).with_name('wifi-away-holds.json').read_text())
        self.assertEqual(on_disk, json.loads(json.dumps(rdnl.wifi_away_schedule(7, 120.0))))
        self.assertTrue(all(0.05 <= d <= 0.10 for _, d in on_disk['short']))
        self.assertTrue(all(0.30 <= d <= 0.58 for _, d in on_disk['long']))
        starts = [a for a, _ in on_disk['short']]
        self.assertTrue(all(abs((b - a) - 0.53) < 0.002 for a, b in zip(starts, starts[1:])))

    def test_profile_holds_split_the_schedule(self):
        sched = {'seconds': 10.0, 'loss_pct': 2.0, 'short': [[0.5, 0.25], [1.5, 0.125]], 'long': [[1.25, 0.5]]}
        self.assertEqual(rdnl.profile_holds('wifi-away', sched), ([(0.5, 0.75), (1.25, 1.75)], 10.0, 2.0))
        self.assertEqual(rdnl.profile_holds('wifi-away-short', sched)[0], [(0.5, 0.75), (1.5, 1.625)])
        self.assertEqual(rdnl.profile_holds('wifi-away-long', sched)[2], 0.0)
        self.assertEqual(rdnl.profile_holds('wifi-away-loss', sched), ([], 10.0, 2.0))
        self.assertEqual(rdnl.profile_holds('stall'), ([(5.0, 5.6)], 5.0, 0.0))

    def test_target_drawdown(self):
        d = rdnl.target_drawdown([8000, 20000, 40000, 30000, 10000, 20000, 40000, 50000])
        self.assertEqual((d['peak_kbps'], d['trough_kbps'], d['drop_pct'], d['fall_s'], d['recover_s'],
                          d['seconds_falling']), (40000, 10000, 75.0, 2, 2, 2))
        self.assertEqual(rdnl.target_drawdown([1000, 2000, None, 3000])['drop_pct'], 0.0)

    def test_gate_wait_and_key_pct_over(self):
        text = ''.join(json.dumps({'damage_us': 0, 'release_us': i * 1000}) + '\n' for i in range(1, 21))
        self.assertEqual(rdnl.gate_wait(text), {'n': 20, 'p50_ms': 11.0, 'p95_ms': 20.0})
        self.assertIsNone(rdnl.gate_wait('{"inject_us": 1}\n'))
        times = [{'sent_ns': 0, 'decoded_ns': ms * 1_000_000} for ms in (10, 40, 60, 90)]
        self.assertEqual(rdnl.pct_over(times, 50), 50.0)
        self.assertIsNone(rdnl.pct_over(None, 50))

    def test_first_seconds_max_counts_only_the_first_two_seconds(self):
        times = [{'sent_ns': s * 1_000_000_000, 'decoded_ns': s * 1_000_000_000 + ms * 1_000_000}
                 for s, ms in ((0.0, 20), (0.5, 230), (1.9, 30), (2.5, 400))]
        self.assertEqual(rdnl.first_seconds_max(times), 230.0)
        self.assertIsNone(rdnl.first_seconds_max([]))

    def test_seconds_to_level(self):
        self.assertEqual(rdnl.seconds_to([None, 9, 15, 20], 15), 3)
        self.assertIsNone(rdnl.seconds_to([1, 2], 15))


class TableTests(unittest.TestCase):
    def test_table_has_one_row_per_result_and_marks_errors(self):
        good = {'commit': 'a' * 40, 'profile': 'jitter-5', 'openh264': 'cisco',
                'key': {'p50_ms': 20.0, 'p95_ms': 40.0, 'lost': 0, 'stage_ledger': LEDGER},
                'passive': {'mbps_per_s': [8.0, 1.0, 1.2], 'target_kbps_per_s': [8000, 1000, 1000],
                            'decoded_fps_per_s': [30.0, 10.0, 20.0], 'target_s_to_15mbps': None,
                            'received_s_to_15mbps': None},
                'wire': {'down_mbps_per_s': [8.0, 9.0, 10.0]},
                'idr_passive': {'idrs': 1, 'frames': 60, 'reasons': {'unlogged': 1}},
                'idr_key': {'idrs': 3, 'frames': 40}}
        bad = {'commit': 'b' * 40, 'profile': 'clean', 'error': 'host did not\nlisten\n'}
        table = rdnl.markdown_table([good, bad])
        lines = table.strip().splitlines()
        self.assertEqual(len(lines), 4)
        self.assertIn('| `aaaaaaaaaaaa` | 5±5 ms | 20.0 / 40.0 (0) | 1.20 (1.00–8.00) | 8.0 1.0 1.2 | 8000 1000 1000 '
                      '| 9.00 | – / – | 20.0 | 1/60 (unlogged 1), 3/40 | yes |',
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
            self.assertIn('`cccccccccccc` (source-built, about 3x slower) | clean | – / – (–) | – |', out.getvalue())

    def test_rows_say_which_openh264_encoded(self):
        self.assertEqual(rdnl.rd_cell({'commit': 'd' * 40, 'openh264': 'cisco'}), '`dddddddddddd`')
        for source in ({'commit': 'd' * 40, 'openh264': 'source'}, {'commit': 'd' * 40}):
            self.assertEqual(rdnl.rd_cell(source), '`dddddddddddd` (source-built, about 3x slower)')

    def test_openh264_flags_for_the_host(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            fake = Path(d) / 'cmux-rd'
            fake.write_text('#!/bin/sh\necho "fetching"\necho "$3/libopenh264.so"\n')
            fake.chmod(0o755)
            try:
                rdnl.OPENH264[:] = ['source']
                self.assertEqual(rdnl.openh264_lib(fake, Path(d)), [])
                rdnl.OPENH264[:] = ['/opt/libopenh264.so']
                self.assertEqual(rdnl.openh264_lib(fake, Path(d)), ['--openh264-lib', '/opt/libopenh264.so'])
                rdnl.OPENH264[:] = ['cisco']
                self.assertEqual(rdnl.openh264_lib(fake, Path(d)),
                                 ['--openh264-lib', f'{d}/openh264/libopenh264.so'])
            finally:
                rdnl.OPENH264[:] = ['cisco']


if __name__ == '__main__':
    unittest.main()
