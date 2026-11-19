#!/usr/bin/env python3
"""Exercise the exact embedded observer without macOS libraries or real processes."""
import contextlib
import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


SOURCE = (Path(__file__).parents[1] / 'published-idle-power.sh').read_text().split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]


class ObserverTests(unittest.TestCase):
    def observe(self, *, exits=False, unreadable=False, capture_hangs=False, top_hangs=False, measure_fails=False):
        with tempfile.TemporaryDirectory() as root:
            bundle = Path(root) / 'Test.app'
            (bundle / 'Contents').mkdir(parents=True)
            with (bundle / 'Contents/Info.plist').open('wb') as f:
                plistlib.dump({'CFBundleIdentifier': 'test.observer', 'CFBundleShortVersionString': '1'}, f)
            membership = {42: ('app', str(bundle) + '/Contents/MacOS/Test')}
            bm = types.ModuleType('bench_memory')
            calls = []
            def owned(*_):
                calls.append(True)
                return {} if exits and len(calls) > 1 else membership
            bm.owned = owned
            bm.process_table = lambda: []
            bp = types.ModuleType('bench_power')
            counter_calls = []
            def counters(_):
                counter_calls.append(True)
                return None if unreadable and len(counter_calls) > 1 else (100, 100, 1, 100)
            bp.counters = counters
            def measure(*_):
                if measure_fails:
                    raise RuntimeError('sampler failed')
                return {'total': {'mw': 1}}
            bp.measure = measure
            child = types.SimpleNamespace(returncode=None, terminated=False, killed=False)
            def wait(timeout):
                if top_hangs and not child.killed:
                    raise subprocess.TimeoutExpired('top', timeout)
                child.returncode = -9 if child.killed else 0
                return child.returncode
            child.wait = wait
            child.poll = lambda: child.returncode
            child.terminate = lambda: setattr(child, 'terminated', True)
            child.kill = lambda: setattr(child, 'killed', True)
            capture = subprocess.CompletedProcess([], 0, '', '')
            error = None
            with patch.dict(sys.modules, bench_memory=bm, bench_power=bp), \
                 patch.object(sys, 'argv', ['observer', str(bundle), '42', 'test', '1', root]), \
                 patch.object(sys, 'path', sys.path.copy()), \
                 patch.object(subprocess, 'Popen', return_value=child), \
                 patch.object(subprocess, 'run', side_effect=subprocess.TimeoutExpired('capture', 20) if capture_hangs else None,
                              return_value=capture), contextlib.redirect_stdout(io.StringIO()):
                try:
                    exec(compile(SOURCE, 'published-idle-power.sh', 'exec'), {})
                except (SystemExit, RuntimeError) as exc:
                    error = exc
            report = json.loads((Path(root) / 'report.json').read_text()) if (Path(root) / 'report.json').exists() else None
            return report, child, error

    def test_stable_app_is_valid(self):
        report, _, error = self.observe()
        self.assertIsNone(error)
        self.assertTrue(report['valid'])

    def test_exited_app_is_not_zero_energy_success(self):
        report, _, error = self.observe(exits=True)
        self.assertFalse(report['valid'])
        self.assertIsInstance(error, SystemExit)

    def test_unreadable_counter_invalidates(self):
        report, _, error = self.observe(unreadable=True)
        self.assertFalse(report['valid'])
        self.assertIsInstance(error, SystemExit)

    def test_capture_timeout_is_recorded(self):
        report, _, error = self.observe(capture_hangs=True)
        self.assertIsNone(error)
        self.assertIsNone(report['capture_status'])

    def test_hung_top_is_reaped(self):
        report, child, error = self.observe(top_hangs=True)
        self.assertIsNone(error)
        self.assertTrue(child.terminated and child.killed)
        self.assertEqual(report['top_status'], -9)

    def test_sampler_failure_still_ends_top(self):
        _, child, error = self.observe(measure_fails=True)
        self.assertIsInstance(error, RuntimeError)
        self.assertTrue(child.terminated)


if __name__ == '__main__':
    unittest.main()
