from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]

FAKE_SWIFT = """#!/bin/bash
printf '%s\\n' "$*" >> "$FAKE_SWIFT_CALLS"
case "$1 ${2:-}" in
  '--version '*) echo 'Swift version 6.3 (test toolchain)'; exit 0 ;;
  'package resolve') exit 0 ;;
  'test list')
    printf '%s\\n' "${FAKE_DISCOVERY_OUTPUT:-PkgTests.FastSuite/check()
PkgTests.LongSuite/check()}"
    exit "${FAKE_DISCOVERY_STATUS:-0}" ;;
esac
if [ "$1" = build ]; then
  if [ "${FAKE_BUILD_STATUS:-0}" != 0 ]; then
    echo 'Fixture.swift:1:1: error: cannot find symbol'
    exit "$FAKE_BUILD_STATUS"
  fi
  echo 'Build complete!'
  exit 0
fi
echo '✔ Test run with 1 test in 1 suite passed after 0.001 seconds.'
"""


class PackageLanePreflightTests(unittest.TestCase):
    def setUp(self):
        self.scratch = Path(tempfile.mkdtemp(prefix='suite-preflight-'))
        self.addCleanup(shutil.rmtree, self.scratch)
        self.repo = self.scratch / 'repo'
        (self.repo / 'scripts').mkdir(parents=True)
        shutil.copytree(ROOT / 'scripts/ci', self.repo / 'scripts/ci')
        package = self.repo / 'Packages/macOS/Fixture'
        package.mkdir(parents=True)
        (package / 'Package.swift').write_text('// swift-tools-version: 6.0\n')
        binaries = self.scratch / 'bin'
        binaries.mkdir()
        (binaries / 'swift').write_text(FAKE_SWIFT)
        sdk = self.scratch / 'MacOSX.sdk'
        sdk.mkdir()
        (binaries / 'xcrun').write_text(f'#!/bin/bash\nprintf "%s\\n" "{sdk}"\n')
        (binaries / 'swift').chmod(0o755)
        (binaries / 'xcrun').chmod(0o755)
        self.calls = self.scratch / 'swift.calls'
        self.env = {
            'PATH': str(binaries) + os.pathsep + os.environ['PATH'],
            'HOME': str(self.scratch),
            'RUNNER_TEMP': str(self.scratch),
            'DEVELOPER_DIR': '/Applications/Xcode_26.6.app/Contents/Developer',
            'CMUX_PACKAGE_LANE_TEST_OS': 'Darwin',
            'FAKE_SWIFT_CALLS': str(self.calls),
        }

    def invoke(self, filters='FastSuite,LongSuite', **environment):
        return subprocess.run(
            ['bash', 'scripts/ci/package-test-lane.sh', 'suite', 'Packages/macOS/Fixture', filters],
            cwd=self.repo, env={**self.env, **environment}, capture_output=True, text=True, timeout=30,
        )

    def executions(self):
        return [line for line in self.calls.read_text().splitlines()
                if line.startswith('test ') and not line.startswith('test list ')]

    def test_compile_failure_starts_no_suites(self):
        result = self.invoke(FAKE_BUILD_STATUS='1')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.executions(), [])

    def test_missing_named_filter_fails_before_any_suite_runs(self):
        result = self.invoke('MissingSuite,LongSuite')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.executions(), [])
        self.assertIn('MissingSuite', result.stdout + result.stderr)

    def test_discovery_process_failure_starts_no_suites(self):
        result = self.invoke(FAKE_DISCOVERY_STATUS='17')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.executions(), [])

    def test_empty_discovery_starts_no_suites(self):
        result = self.invoke(FAKE_DISCOVERY_OUTPUT=' ')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.executions(), [])

    def test_valid_filters_still_execute_after_one_discovery(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls.read_text().splitlines()
        listings = [line for line in calls if line.startswith('test list ')]
        self.assertEqual(len(listings), 1, calls)
        self.assertEqual(len(self.executions()), 2, calls)
        self.assertLess(calls.index(listings[0]), calls.index(self.executions()[0]))


if __name__ == '__main__':
    unittest.main()
