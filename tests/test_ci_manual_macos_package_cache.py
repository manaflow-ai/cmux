#!/usr/bin/env python3
"""Exercise the manual macOS workflow's real package-resolution script."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
STEPS = yaml.safe_load((ROOT / '.github/workflows/test-macos-suite.yml').read_text())['jobs']['tests']['steps']


def step(name):
    return next(s for s in STEPS if s.get('name') == name)


class ManualPackageCache(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.packages = self.root / '.ci-source-packages'
        self.packages.mkdir()
        self.counter = self.root / 'counter'
        self.counter.write_text('0')
        tools = self.root / 'bin'
        tools.mkdir()
        xcode = tools / 'xcodebuild'
        xcode.write_text('''#!/usr/bin/env python3
import os
from pathlib import Path
n = int(Path(os.environ['FIXTURE_COUNTER']).read_text()) + 1
Path(os.environ['FIXTURE_COUNTER']).write_text(str(n))
mode = os.environ['FIXTURE_MODE']
if mode == 'resolve-error' and n == 1:
    raise SystemExit(1)
if mode == 'missing' or (mode == 'incomplete' and n == 1):
    raise SystemExit(0)
paths = ('sparkle/Sparkle/Sparkle.xcframework', 'sentry-cocoa/Sentry/Sentry.xcframework')
if n == 1 and mode == 'only-sparkle':
    paths = paths[:1]
if n == 1 and mode == 'only-sentry':
    paths = paths[1:]
for path in paths:
    Path('.ci-source-packages/artifacts', path).mkdir(parents=True, exist_ok=True)
''')
        xcode.chmod(0o755)
        sleep = tools / 'sleep'
        sleep.write_text('#!/bin/sh\nexit 0\n')
        sleep.chmod(0o755)
        self.env = dict(os.environ, PATH=str(tools) + ':' + os.environ['PATH'],
                        FIXTURE_COUNTER=str(self.counter), FIXTURE_MODE='valid')

    def resolve(self, mode='valid'):
        return subprocess.run(['bash', '-eu', '-o', 'pipefail', '-c', step('Resolve Swift packages')['run']],
                              cwd=self.root, env=dict(self.env, FIXTURE_MODE=mode),
                              text=True, capture_output=True)

    def test_valid_cached_sources_survive_resolution(self):
        sentinel = self.packages / 'cached-source'
        sentinel.write_text('downloaded dependency')
        result = self.resolve()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(sentinel.exists())
        self.assertEqual(self.counter.read_text(), '1')

    def test_cache_miss_resolves_normally(self):
        self.packages.rmdir()
        self.assertEqual(self.resolve().returncode, 0)
        self.assertEqual(self.counter.read_text(), '1')

    def test_incomplete_artifacts_and_resolve_errors_retry_cleanly(self):
        for mode in ('incomplete', 'only-sparkle', 'only-sentry', 'resolve-error'):
            with self.subTest(mode=mode):
                shutil.rmtree(self.packages)
                self.packages.mkdir()
                self.counter.write_text('0')
                sentinel = self.packages / 'poisoned-source'
                sentinel.write_text('old state')
                result = self.resolve(mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.counter.read_text(), '2')
                self.assertFalse(sentinel.exists())

    def test_repeated_incomplete_artifacts_fail_after_three_attempts(self):
        self.assertNotEqual(self.resolve('missing').returncode, 0)
        self.assertEqual(self.counter.read_text(), '3')

    def test_restore_is_read_only_and_after_workspace_cleanup(self):
        restore = step('Restore Swift packages')
        self.assertIn('actions/cache/restore@', restore['uses'])
        self.assertTrue(restore['continue-on-error'])
        names = [s.get('name') for s in STEPS]
        self.assertLess(names.index('Prepare clean package cache directory'), names.index('Restore Swift packages'))
        self.assertLess(names.index('Restore Swift packages'), names.index('Sanitize Swift package cache'))
        self.assertLess(names.index('Sanitize Swift package cache'), names.index('Resolve Swift packages'))


if __name__ == '__main__':
    unittest.main()
