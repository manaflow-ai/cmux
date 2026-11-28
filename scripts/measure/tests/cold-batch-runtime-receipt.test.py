#!/usr/bin/env python3
"""Behavioral fixtures for scripts/measure/cold-batch-runtime-receipt.py."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'cold-batch-runtime-receipt.py'
spec = importlib.util.spec_from_file_location('receipt', SCRIPT)
receipt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receipt)
RUN = 1795868520538
OPEN = 1795868833155
DUE = OPEN + 204000
SESSION = '01a2221a-f462-7327-8cbd-4f76825eb1dc'
ACP = 'efd32de4-77d0-481d-8992-c20dfb1b22e7'
MARKERS = ['cold-proof-A', 'cold-proof-B']


def raw(at, kind, msg, receiver=SESSION):
    return {'kind': 'raw_event', 'event': {'at': at, 'kind': kind, 'msg': msg, 'sessionId': receiver}}


def usage(at, used, receiver=SESSION):
    return raw(at, 'usage_update', {'params': {'sessionId': ACP, 'update': {'used': used}}}, receiver)


def fixture(delivered=True):
    # Absolute timings reproduce the 2026-11-28 private restart failure; contents
    # are minimal test data, with no listener/MCP config or original prompt context.
    events = [
        {'kind': 'binary', 'at': RUN, 'source': '3dabea8f1731a4cb1b13035c951007bbb0b0263d',
         'sha256': '9008c8e8f15f6bb7162ffca49424e16a9570a0451cc5c97bd3eafec6024df2d5',
         'version': 'acpmux 1.0.0 (3dabea8f1 2026-11-28)', 'merge_ancestor_exit': 0},
        usage(RUN + 1000, 120000),
        {'kind': 'restart_begin', 'at': 1795868858207},
        {'kind': 'restart_complete', 'at': 1795868858644},
        {'kind': 'capture_complete', 'at': 1795869141479},
        raw(1795868833443, 'turn_started', {'prompt': '/compact', 'promptId': 'cold-wake-compact-test', 'turnId': 'compact-turn'}),
        {'kind': 'acp_prompt_received', 'at': 1795868833445, 'sessionId': ACP, 'prompt': [{'text': '/compact'}]},
        usage(1795868833445, 10000),
        raw(1795868833447, 'turn_end', {'turnId': 'compact-turn', 'stopReason': 'end_turn'}),
    ]
    for i, marker in enumerate(MARKERS):
        events += [raw(OPEN - 1 + i * 43, 'inbox', {'text': marker, 'class': 'fyi',
                     '_meta': {'provenance': {'to': SESSION, 'gather': True}}}),
                   {'kind': 'cli', 'at': OPEN + 10 + i * 43, 'code': 0,
                    'args': ['send', 'cold-rx', '--class', 'fyi', '--gather', '--no-wait', marker]}]
    if delivered:
        events += [{'kind': 'acp_prompt_received', 'sessionId': ACP, 'at': DUE + 24,
                    'prompt': [{'text': '\n'.join(MARKERS)}]},
                   raw(DUE + 20, 'turn_started', {'turnId': 'delivery-turn', 'prompt': '\n'.join(MARKERS)})]
    return {'events': events, 'cold_log': [
        '2026-11-28T12:27:13.155631Z INFO cold wake batch opened session=' + SESSION +
        ' window_ms=204000 tokens=120000 cold_ms=10285']}


def run(data):
    return receipt.check(data, RUN, SESSION, ACP, MARKERS)


class ReceiptTests(unittest.TestCase):
    def test_good_compact_warm_restart_original_deadline(self):
        result = run(fixture())
        self.assertEqual(result['status'], 'PASS')
        self.assertEqual(result['original_due_ms'], DUE)
        self.assertEqual(result['deadline_lateness_ms'], 24)

    def test_recorded_failure_after_completed_capture(self):
        result = run(fixture(False))
        self.assertEqual((result['status'], result['reason']), ('FAIL', 'NO_DELIVERY_BY_COLD_DEADLINE'))

    def test_missing_or_early_completion_is_incomplete_not_failure(self):
        for complete in (None, DUE + receipt.LATENESS_MS - 1):
            data = fixture(False)
            data['events'] = [r for r in data['events'] if r['kind'] != 'capture_complete']
            if complete is not None:
                data['events'].append({'kind': 'capture_complete', 'at': complete})
            result = run(data)
            self.assertEqual(result['status'], 'INCOMPLETE')
            self.assertEqual(result['reason'], 'CAPTURE_NOT_COMPLETE_THROUGH_DEADLINE')

    def test_exact_capture_boundary_is_conclusive(self):
        data = fixture(False)
        next(r for r in data['events'] if r['kind'] == 'capture_complete')['at'] = DUE + receipt.LATENESS_MS
        self.assertEqual(run(data)['status'], 'FAIL')

    def test_failed_setup_and_other_receiver_do_not_supply_proof(self):
        data = fixture()
        old = copy.deepcopy(data['events'][0]); old['at'] = RUN - 1000
        data['events'] += [old, {'kind': 'FAILED', 'at': RUN - 500},
                           raw(DUE, 'inbox', {'class': 'question'}, 'unrelated'),
                           {'kind': 'acp_prompt_received', 'at': DUE, 'sessionId': 'unrelated', 'prompt': [{'text': '/compact'}]}]
        data['cold_log'].append(data['cold_log'][0].replace(SESSION, 'unrelated'))
        self.assertEqual(run(data)['status'], 'PASS')
        for row in data['events']:
            if row['kind'] == 'acp_prompt_received' and 'cold-proof-A' in receipt.text_of(row):
                row['sessionId'] = 'unrelated'
        self.assertEqual(run(data)['reason'], 'NO_DELIVERY_BY_COLD_DEADLINE')

    def test_next_run_cannot_complete_current_capture(self):
        data = fixture(False)
        old_end = next(r for r in data['events'] if r['kind'] == 'capture_complete')
        later = copy.deepcopy(data['events'][0]); later['at'] = old_end['at'] - 1
        data['events'].append(later)
        self.assertEqual(run(data)['status'], 'INCOMPLETE')

    def test_compaction_must_finish_before_restart(self):
        for finished in (None, 1795868858207):
            data = fixture()
            ends = [r for r in data['events'] if r['kind'] == 'raw_event' and r['event']['kind'] == 'turn_end']
            if finished is None:
                data['events'].remove(ends[0])
            else:
                ends[0]['event']['at'] = finished
            self.assertEqual(run(data)['reason'], 'COMPACTION_NOT_COMPLETED_BEFORE_RESTART')

    def test_duplicate_compaction_after_restart_rejected(self):
        data = fixture()
        data['events'].append({'kind': 'acp_prompt_received', 'at': DUE - 1000, 'sessionId': ACP, 'prompt': [{'text': '/compact'}]})
        self.assertEqual(run(data)['reason'], 'COMPACTION_AFTER_RESTART')

    def test_warm_usage_is_required(self):
        data = fixture()
        for row in data['events']:
            if row['kind'] == 'raw_event' and row['event']['kind'] == 'usage_update':
                row['event']['msg']['params']['update']['used'] = 120000
        self.assertEqual(run(data)['reason'], 'WARM_USAGE_BEFORE_RESTART_MISSING')

    def test_reset_deadline_or_one_hour_window_rejected(self):
        data = fixture(); data['cold_log'].append(data['cold_log'][0].replace('12:27:13', '12:27:39'))
        self.assertEqual(run(data)['reason'], 'BATCH_REOPENED')
        data = fixture(); data['cold_log'][0] = data['cold_log'][0].replace('204000', '3600000')
        self.assertEqual(run(data)['reason'], 'COLD_WINDOW_OUT_OF_RANGE')

    def test_ordinary_one_hour_delivery_rejected(self):
        data = fixture()
        for row in data['events']:
            if row['kind'] == 'acp_prompt_received' and MARKERS[0] in receipt.text_of(row):
                row['at'] = OPEN + 3600504
            if row['kind'] == 'capture_complete': row['at'] = OPEN + 3620000
        self.assertEqual(run(data)['reason'], 'DELIVERY_NOT_AT_ORIGINAL_DEADLINE')

    def test_no_urgent_within_or_extra_turn_can_pass(self):
        for trigger in ('within', 'question', 'other_turn'):
            data = fixture()
            if trigger == 'within':
                next(r for r in data['events'] if r['kind'] == 'cli')['args'] += ['--within', '5s']
            elif trigger == 'question':
                next(r for r in data['events'] if r['kind'] == 'raw_event' and r['event']['kind'] == 'inbox')['event']['msg']['class'] = 'question'
            else:
                data['events'].append(raw(DUE + 23, 'turn_started', {'turnId': 'other', 'prompt': 'wake'}))
            self.assertEqual(run(data)['status'], 'FAIL')

    def test_missing_delivery_with_unrelated_wake_is_not_deadline_failure(self):
        for wake_at in (DUE - 5000, DUE + receipt.LATENESS_MS + 1):
            data = fixture(False)
            data['events'].append(raw(wake_at, 'turn_started', {'turnId': 'other', 'prompt': 'wake'}))
            result = run(data)
            self.assertEqual((result['status'], result['reason']),
                             ('FAIL', 'OTHER_TURN_INVALIDATES_TIMER_ONLY'))

    def test_wrong_binary_or_unlinked_receiver_is_incomplete(self):
        data = fixture(); data['events'][0]['merge_ancestor_exit'] = 1
        self.assertEqual(run(data)['reason'], 'BINARY_IDENTITY_OR_ANCESTRY_MISSING')
        data = fixture()
        result = receipt.check(data, RUN, SESSION, 'wrong-acp-session', MARKERS)
        self.assertEqual(result['reason'], 'RECEIVER_ID_LINK_MISSING')

    def test_duplicate_or_partial_delivery_fails(self):
        data = fixture()
        delivery = next(r for r in data['events'] if r['kind'] == 'acp_prompt_received' and MARKERS[0] in receipt.text_of(r))
        data['events'].append(copy.deepcopy(delivery))
        self.assertEqual(run(data)['reason'], 'NOT_EXACTLY_ONE_BATCHED_DELIVERY')
        data['events'].pop(); delivery['prompt'][0]['text'] = MARKERS[0]
        self.assertEqual(run(data)['reason'], 'MISSING_DELIVERED_MARKER')

    def test_optimized_python_still_rejects_real_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'receipt.json'; path.write_text(json.dumps(fixture(False)))
            result = subprocess.run([sys.executable, '-O', str(SCRIPT), str(path), '--run-start-ms', str(RUN),
                                     '--session', SESSION, '--acp-session', ACP,
                                     '--marker', MARKERS[0], '--marker', MARKERS[1]], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)['reason'], 'NO_DELIVERY_BY_COLD_DEADLINE')


if __name__ == '__main__':
    unittest.main()
