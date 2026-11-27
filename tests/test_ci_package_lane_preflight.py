from __future__ import annotations

import os
import json
import importlib.util
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parents[1]
OUTCOMES = ROOT / 'scripts/ci/package-test-lane/swift_suite_outcomes.py'


class SuiteOutcomeSignalTests(unittest.TestCase):
    def test_only_recognized_completed_failures_are_reusable(self):
        spec = importlib.util.spec_from_file_location('swift_suite_outcomes', OUTCOMES)
        outcomes = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(outcomes)
        for phase, code, log, expected in (
            ('compile', 1, 'Foo.swift:12:4: error: missing symbol', True),
            ('compile', 1, 'error: disk full', False),
            ('compile', 124, 'Foo.swift:12:4: error: missing symbol', False),
            ('discovery', 2, 'no discovered test matches MissingSuite', True),
            ('discovery', 1, 'process crashed', False),
            ('assertion', 1, '✘ Test run with 1 test failed after 1 second.', True),
            ('assertion', 133, '✘ Test run with 1 test failed after 1 second.', False),
            ('assertion', 1, '◇ Test run started.\nfatal error', False),
        ):
            with self.subTest(phase=phase, code=code, log=log):
                self.assertEqual(outcomes.eligible_failure(phase, code, log), expected)

FAKE_SWIFT = """#!/bin/bash
printf '%s\\n' "$*" >> "$FAKE_SWIFT_CALLS"
case "$1 ${2:-}" in
  '--version '*) echo "${FAKE_SWIFT_TOOLCHAIN:-Swift version 6.3 (test toolchain)}"; exit 0 ;;
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
if [ "${FAKE_TEST_FAILURE:-0}" = 1 ]; then
  echo '✘ Test run with 1 test failed after 0.001 seconds with 1 issue.'
  exit 1
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
        (binaries / 'xcodebuild').write_text('#!/bin/bash\nprintf "Xcode 26.6\\nBuild version fixture1\\n"\n')
        (binaries / 'swift').chmod(0o755)
        (binaries / 'xcrun').chmod(0o755)
        (binaries / 'xcodebuild').chmod(0o755)
        self.calls = self.scratch / 'swift.calls'
        self.env = {
            'PATH': str(binaries) + os.pathsep + os.environ['PATH'],
            'HOME': str(self.scratch),
            'RUNNER_TEMP': str(self.scratch),
            'DEVELOPER_DIR': '/Applications/Xcode_26.6.app/Contents/Developer',
            'CMUX_PACKAGE_LANE_TEST_OS': 'Darwin',
            'FAKE_SWIFT_CALLS': str(self.calls),
        }
        self.history = []
        self.receipt = self.scratch / 'failure.json'

    def invoke(self, filters='FastSuite,LongSuite', **environment):
        return subprocess.run(
            ['bash', 'scripts/ci/package-test-lane.sh', 'suite', 'Packages/macOS/Fixture', filters],
            cwd=self.repo, env={**self.env, **environment}, capture_output=True, text=True, timeout=30,
        )

    def executions(self):
        return [line for line in self.calls.read_text().splitlines()
                if line.startswith('test ') and not line.startswith('test list ')]

    def enable_failure_cache(self):
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({'jobs': owner.history, 'has_more': False}).encode())

            def log_message(self, *arguments):
                pass

        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.env.update({
            'CMUX_CI_CONTROLLER': f'http://127.0.0.1:{server.server_port}',
            'CMUX_CI_SUITE_FAILURE_CONTEXT': 'c' * 64,
            'CMUX_CI_SUITE_FAILURE_REF': 'a' * 40,
            'CMUX_CI_SUITE_FAILURE_REPO': 'manaflow-ai/cmux',
            'CMUX_CI_SUITE_FAILURE_FILE': str(self.receipt),
        })

    def publish_failure(self, age_hours=0):
        if not self.receipt.exists():
            return
        receipt = json.loads(self.receipt.read_text())
        receipt['context'] = self.env['CMUX_CI_SUITE_FAILURE_CONTEXT']
        receipt['reported_at'] = (datetime.now(timezone.utc) - timedelta(hours=age_hours)).isoformat()
        self.history = [{
            'id': 'original-failed-job', 'kind': 'ci-step',
            'state': 'done' if receipt['exit_code'] == 0 else 'failed',
            'ref': self.env['CMUX_CI_SUITE_FAILURE_REF'],
            'script': 'scripts/ci/package-test-lane.sh',
            'exit_code': receipt['exit_code'], 'suite_result': receipt,
        }]

    def builds(self):
        return [line for line in self.calls.read_text().splitlines() if line.startswith('build ')]

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

    def test_identical_compile_failure_stays_red_without_another_build(self):
        self.enable_failure_cache()
        first = self.invoke(FAKE_BUILD_STATUS='1')
        self.publish_failure()
        second = self.invoke(FAKE_BUILD_STATUS='1')
        self.assertEqual((first.returncode, second.returncode), (1, 1))
        self.assertEqual(len(self.builds()), 1, self.calls.read_text())
        self.assertEqual(json.loads(self.receipt.read_text())['reused_from'], 'original-failed-job')

    def test_identical_assertion_failure_stays_red_without_rerunning_suites(self):
        self.enable_failure_cache()
        first = self.invoke(FAKE_TEST_FAILURE='1')
        self.publish_failure()
        second = self.invoke(FAKE_TEST_FAILURE='1')
        self.assertEqual((first.returncode, second.returncode), (1, 1))
        self.assertEqual(len(self.builds()), 1)
        self.assertEqual(len(self.executions()), 2)

    def test_source_toolchain_filter_and_retest_invalidate_failure_reuse(self):
        self.enable_failure_cache()
        self.invoke(FAKE_BUILD_STATUS='1')
        self.publish_failure()
        for environment in (
            {'CMUX_CI_SUITE_FAILURE_REF': 'b' * 40},
            {'FAKE_SWIFT_TOOLCHAIN': 'Swift version 6.4 (other toolchain)'},
            {'CMUX_CI_SUITE_FAILURE_CONTEXT': 'd' * 64},
            {'CMUX_SWIFT_RETRY_FAILED': '1'},
            {'CMUX_SWIFT_SUITE_CONFIGURATION': 'release'},
        ):
            with self.subTest(environment=environment):
                before = len(self.builds())
                self.assertEqual(self.invoke(FAKE_BUILD_STATUS='1', **environment).returncode, 1)
                self.assertEqual(len(self.builds()), before + 1)
        before = len(self.builds())
        self.assertEqual(self.invoke('LongSuite', FAKE_BUILD_STATUS='1').returncode, 1)
        self.assertEqual(len(self.builds()), before + 1)

    def test_expired_or_reused_failures_do_not_keep_extending_the_cache(self):
        self.enable_failure_cache()
        self.invoke(FAKE_BUILD_STATUS='1')
        self.publish_failure(age_hours=25)
        self.invoke(FAKE_BUILD_STATUS='1')
        self.assertEqual(len(self.builds()), 2)
        self.publish_failure()
        if self.history:
            self.history[0]['suite_result']['reused_from'] = 'an-older-job'
        self.invoke(FAKE_BUILD_STATUS='1')
        self.assertEqual(len(self.builds()), 3)

    def test_timeout_is_never_a_cached_compile_failure(self):
        self.enable_failure_cache()
        self.assertEqual(self.invoke(FAKE_BUILD_STATUS='124').returncode, 124)
        self.assertFalse(self.receipt.exists())
        self.publish_failure()
        self.assertEqual(self.invoke(FAKE_BUILD_STATUS='124').returncode, 124)
        self.assertEqual(len(self.builds()), 2)

    def test_successful_explicit_retest_invalidates_the_older_failure(self):
        self.enable_failure_cache()
        self.invoke(FAKE_BUILD_STATUS='1')
        self.publish_failure()
        older = list(self.history)
        self.assertEqual(self.invoke(CMUX_SWIFT_RETRY_FAILED='1').returncode, 0)
        self.publish_failure()
        self.history[0]['id'] = 'successful-retest'
        self.history.extend(older)
        self.assertEqual(self.invoke(FAKE_BUILD_STATUS='1').returncode, 1)
        self.assertEqual(len(self.builds()), 3)

    def test_newer_equivalent_unclassified_result_prevents_stale_failure_reuse(self):
        self.enable_failure_cache()
        self.invoke(FAKE_BUILD_STATUS='1')
        self.publish_failure()
        self.history.insert(0, {
            'id': 'older-worker-retest', 'kind': 'ci-step', 'state': 'done',
            'ref': self.env['CMUX_CI_SUITE_FAILURE_REF'],
            'script': 'scripts/ci/package-test-lane.sh',
            'suite_request_context': self.env['CMUX_CI_SUITE_FAILURE_CONTEXT'],
            'updated_at': datetime.now(timezone.utc).isoformat(),
        })
        self.invoke(FAKE_BUILD_STATUS='1')
        self.assertEqual(len(self.builds()), 2)


if __name__ == '__main__':
    unittest.main()
