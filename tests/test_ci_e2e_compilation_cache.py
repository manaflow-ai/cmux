#!/usr/bin/env python3
"""Execute E2E cache setup, cleanup and compiler command construction."""
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
STEPS = yaml.safe_load((ROOT / '.github/workflows/test-e2e.yml').read_text())['jobs']['e2e']['steps']


def step(name):
    return next(s for s in STEPS if s.get('name') == name)


class E2ECompilationCache(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.workspace = self.root / 'workspace'
        self.workspace.mkdir()
        tools = self.root / 'bin'
        tools.mkdir()
        xcode = tools / 'xcodebuild'
        xcode.write_text('#!/bin/sh\nprintf "%s\\n" "$FIXTURE_XCODE"\n')
        xcode.chmod(0o755)
        self.env = dict(os.environ, GITHUB_WORKSPACE=str(self.workspace),
                        RUNNER_TEMP=str(self.root), GITHUB_RUN_ID='11', GITHUB_RUN_ATTEMPT='1',
                        GITHUB_ENV=str(self.root / 'env'), GITHUB_OUTPUT=str(self.root / 'output'),
                        PATH=str(tools) + ':' + os.environ['PATH'], FIXTURE_XCODE='Xcode 26.6')

    def run_step(self, name, **env):
        return subprocess.run(['bash', '-eu', '-o', 'pipefail', '-c', step(name)['run']],
                              cwd=self.workspace, env=dict(self.env, **env),
                              text=True, capture_output=True)

    def prepare(self):
        for file in ('env', 'output'):
            (self.root / file).write_text('')
        result = self.run_step('Prepare isolated DerivedData')
        self.assertEqual(result.returncode, 0, result.stderr)
        values = dict(line.split('=', 1) for file in ('env', 'output')
                      for line in (self.root / file).read_text().splitlines())
        return values

    def test_repeat_runs_share_cache_paths_but_start_with_clean_products(self):
        first = self.prepare()
        product = Path(first['CMUX_DERIVED_DATA_PATH']) / 'stale-product'
        product.write_text('old app')
        self.env.update(GITHUB_RUN_ID='12', GITHUB_RUN_ATTEMPT='2')
        second = self.prepare()
        self.assertEqual(first['CMUX_DERIVED_DATA_PATH'], second['CMUX_DERIVED_DATA_PATH'])
        self.assertEqual(first['CMUX_E2E_COMPILATION_CACHE'], second['CMUX_E2E_COMPILATION_CACHE'])
        self.assertEqual(first['fingerprint'], second['fingerprint'])
        self.assertFalse(product.exists())

    def test_toolchain_and_absolute_workspace_partition_cache(self):
        original = self.prepare()['fingerprint']
        self.env['FIXTURE_XCODE'] = 'Xcode 26.7'
        self.assertNotEqual(original, self.prepare()['fingerprint'])
        self.env['FIXTURE_XCODE'] = 'Xcode 26.6'
        other = self.root / 'other-workspace'
        other.mkdir()
        self.workspace = other
        self.env['GITHUB_WORKSPACE'] = str(other)
        self.assertNotEqual(original, self.prepare()['fingerprint'])

    def test_both_test_targets_enable_cache_without_changing_selectors(self):
        self.assertEqual(step('Install zig')['if'], "${{ steps.filter.outputs.target == 'cmuxUITests' }}")
        values = self.prepare()
        script = step('Run selected tests')['run']
        start = script.index('if [ "$TEST_TARGET" = "cmuxTests" ]; then')
        end = script.index('\nset +e', start)
        construction = script[start:end]
        for target in ('cmuxTests', 'cmuxUITests'):
            with self.subTest(target=target):
                command = ('ONLY_TESTING=("-only-testing:' + target + '/Focused")\n' +
                           construction + '\nprintf "%s\\0" "${XCODEBUILD_CMD[@]}"')
                result = subprocess.run(['bash', '-eu', '-c', command], cwd=self.workspace,
                    env=dict(self.env, **values, TEST_TARGET=target, TEST_TIMEOUT='120',
                             SOURCE_PACKAGES_DIR=str(self.workspace / '.ci-source-packages')),
                    capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                args = result.stdout.decode().strip('\0').split('\0')
                self.assertIn('COMPILATION_CACHE_ENABLE_CACHING=YES', args)
                self.assertIn('COMPILATION_CACHE_CAS_PATH=' + values['CMUX_E2E_COMPILATION_CACHE'], args)
                self.assertIn('-only-testing:' + target + '/Focused', args)
                self.assertEqual(args[-1], 'test')
                self.assertEqual('CMUX_SKIP_ZIG_BUILD=1' in args, target == 'cmuxTests')

    def test_unit_helper_skip_uses_clang_without_invoking_zig(self):
        zig = self.root / 'bin' / 'zig'
        zig.write_text('#!/bin/sh\necho unexpected-zig-invocation >&2\nexit 99\n')
        zig.chmod(0o755)
        xcrun = self.root / 'bin' / 'xcrun'
        xcrun.write_text('''#!/bin/sh
test "$1" = clang || exit 98
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then
    shift
    printf 'fixture-clang-output' > "$1"
    exit 0
  fi
  shift
done
exit 97
''')
        xcrun.chmod(0o755)
        output = self.root / 'ghostty-helper'
        result = subprocess.run([
            'bash', str(ROOT / 'scripts/build-ghostty-cli-helper.sh'),
            '--target', 'aarch64-macos', '--output', str(output),
        ], env=dict(self.env, CMUX_SKIP_ZIG_BUILD='1', ZIG_REQUIRED='0.0.0'),
            text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.read_text(), 'fixture-clang-output')
        self.assertIn('Skipping zig CLI helper build', result.stdout)

    def test_cleanup_removes_only_owned_paths(self):
        values = self.prepare()
        unrelated = self.root / 'keep'
        unrelated.mkdir()
        rejected = self.run_step('Clean owned DerivedData', **dict(values, CMUX_DERIVED_DATA_PATH=str(unrelated)))
        self.assertNotEqual(rejected.returncode, 0)
        self.assertTrue(unrelated.exists())
        rejected = self.run_step('Clean owned DerivedData', **dict(values, CMUX_E2E_COMPILATION_CACHE=str(unrelated)))
        self.assertNotEqual(rejected.returncode, 0)
        self.assertTrue(Path(values['CMUX_DERIVED_DATA_PATH']).exists())
        result = self.run_step('Clean owned DerivedData', **values)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(Path(values['CMUX_DERIVED_DATA_PATH']).exists())
        self.assertFalse(Path(values['CMUX_E2E_COMPILATION_CACHE']).exists())

    def test_only_successful_trusted_main_build_can_seed(self):
        values = self.prepare()
        cache = Path(values['CMUX_E2E_COMPILATION_CACHE'])
        (cache / 'compiler-entry').write_bytes(b'cached')
        for ref, selected, outcome, allowed in (
            ('refs/heads/main', 'a' * 40, 'success', True),
            ('refs/heads/main', 'b' * 40, 'success', False),
            ('refs/heads/topic', 'a' * 40, 'success', False),
            ('refs/heads/main', 'a' * 40, 'failure', False),
        ):
            (self.root / 'output').write_text('')
            result = self.run_step('Bound E2E compilation cache', **values,
                                  WORKFLOW_REF=ref, WORKFLOW_SHA='a' * 40,
                                  TEST_REF=selected, TEST_OUTCOME=outcome)
            self.assertEqual(result.returncode, 0, result.stderr)
            outputs = dict(line.split('=', 1) for line in (self.root / 'output').read_text().splitlines())
            self.assertEqual(outputs['save'], str(allowed).lower())

    def test_empty_and_oversized_caches_are_not_published(self):
        values = self.prepare()
        env = dict(values, WORKFLOW_REF='refs/heads/main', WORKFLOW_SHA='a' * 40,
                   TEST_REF='a' * 40, TEST_OUTCOME='success')
        result = self.run_step('Bound E2E compilation cache', **env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('save=true', (self.root / 'output').read_text())
        (Path(values['CMUX_E2E_COMPILATION_CACHE']) / 'compiler-entry').write_bytes(b'cached')
        fake_du = self.root / 'bin' / 'du'
        fake_du.write_text('#!/bin/sh\nprintf "6291456 cache\\n"\n')
        fake_du.chmod(0o755)
        result = self.run_step('Bound E2E compilation cache', **env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('save=true', (self.root / 'output').read_text())

    def test_failed_restore_discards_partial_cache_without_removing_products(self):
        values = self.prepare()
        cache = Path(values['CMUX_E2E_COMPILATION_CACHE'])
        (cache / 'partial-database').write_bytes(b'incomplete')
        product = Path(values['CMUX_DERIVED_DATA_PATH']) / 'keep'
        product.write_text('separate build products')
        result = self.run_step('Discard incomplete E2E compilation cache', **values)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(cache.is_dir())
        self.assertEqual(list(cache.iterdir()), [])
        self.assertTrue(product.exists())
        rejected = self.run_step('Discard incomplete E2E compilation cache',
            **dict(values, CMUX_E2E_COMPILATION_CACHE=str(product.parent)))
        self.assertNotEqual(rejected.returncode, 0)
        self.assertTrue(product.exists())

    def test_failure_guard_only_allows_optional_compilation_cache_steps(self):
        guard = (ROOT / 'tests/test_ci_self_hosted_guard.sh').read_text()
        start = guard.index('check_e2e_runner_fallbacks() {')
        end = guard.index('\ncheck_ios_tart_canary()', start)
        invoke = guard[start:end] + '\ncheck_e2e_runner_fallbacks\n'
        workflow = (ROOT / '.github/workflows/test-e2e.yml').read_text()
        candidate = self.root / 'workflow.yml'
        for text, succeeds in (
            (workflow, True),
            (workflow.replace('      - name: Run selected tests\n',
                              '      - name: Run selected tests\n        continue-on-error: true\n'), False),
            (workflow.replace('      - name: Select Xcode\n',
                              '      - name: Select Xcode\n        continue-on-error: true\n'), False),
            (workflow.replace('  e2e:\n', '  e2e:\n    continue-on-error: true\n'), False),
            (workflow.replace('        id: compilation-cache-restore\n',
                              '        id: unrelated-setup\n'), False),
        ):
            candidate.write_text(text)
            result = subprocess.run(['bash', '-eu', '-c', invoke],
                env=dict(self.env, E2E_FILE=str(candidate)), capture_output=True, text=True)
            self.assertEqual(result.returncode == 0, succeeds, result.stdout + result.stderr)




class E2ECapturePreflight(unittest.TestCase):
    def test_capture_failure_stops_before_dependency_setup(self):
        for mode in ('ok', 'failure', 'empty', 'timeout', 'no-user'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as td:
                root = Path(td)
                tools = root / 'bin'
                tools.mkdir()
                trace = root / 'trace'
                child_pipe = root / 'child-lifetime'
                os.mkfifo(child_pipe)
                child_reader = os.open(child_pipe, os.O_RDONLY | os.O_NONBLOCK)
                self.addCleanup(os.close, child_reader)
                fake = '''#!PYTHON
import json, os, pathlib, signal, subprocess, sys
name = pathlib.Path(sys.argv[0]).name
mode = os.environ['CAPTURE_FIXTURE_MODE']
if name == 'stat':
    print('root' if mode == 'no-user' else 'runner')
elif name == 'id':
    print('501')
else:
    pathlib.Path(os.environ['CAPTURE_FIXTURE_TRACE']).write_text(json.dumps(sys.argv[1:]))
    if mode == 'timeout':
        subprocess.Popen([sys.executable, '-c',
            'import os,pathlib,signal; '
            'fd=os.open(os.environ["CAPTURE_CHILD_PIPE"],os.O_WRONLY); '
            'pathlib.Path(os.environ["CAPTURE_CHILD_PID"]).write_text(str(os.getpid())); '
            'signal.pause()'])
        signal.pause()
    if mode == 'failure':
        print('could not create image from display', file=sys.stderr)
        sys.exit(1)
    pathlib.Path(sys.argv[-1]).write_bytes(b'frame' if mode == 'ok' else b'')
'''.replace('PYTHON', sys.executable)
                for name in ('stat', 'id', 'sudo'):
                    command = tools / name
                    source = fake
                    if name == 'stat':
                        source = '#!/bin/sh\nif [ "$CAPTURE_FIXTURE_MODE" = no-user ]; then echo root; else echo runner; fi\n'
                    elif name == 'id':
                        source = '#!/bin/sh\necho 501\n'
                    command.write_text(source)
                    command.chmod(0o755)
                env = dict(os.environ, PATH=str(tools) + ':' + os.environ['PATH'],
                           RUNNER_TEMP=str(root), CAPTURE_FIXTURE_MODE=mode,
                           CAPTURE_FIXTURE_TRACE=str(trace),
                           CAPTURE_CHILD_PIPE=str(child_pipe),
                           CAPTURE_CHILD_PID=str(root / 'child-pid'))
                # Execute the workflow's actual preflight, with a short test-only
                # timeout, before substituting an expensive setup side effect.
                reached = root / 'dependency-setup'
                command = ''
                for entry in STEPS:
                    if entry.get('name') == 'Verify screen capture before dependency setup':
                        timeout = '2' if mode == 'timeout' else '10'
                        command += entry['run'].rstrip() + ' --timeout-seconds ' + timeout + '\n'
                    if entry.get('name') in ('Setup Bun', 'Download pre-built GhosttyKit.xcframework',
                                             'Install zig', 'Install Rust', 'Prepare isolated DerivedData'):
                        command += 'touch "$RUNNER_TEMP/dependency-setup"\n'
                        break
                result = subprocess.run(['bash', '-eu', '-o', 'pipefail', '-c', command],
                                        cwd=ROOT, env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, mode == 'ok', result.stderr)
                self.assertEqual(reached.exists(), mode == 'ok')
                self.assertEqual(list(root.glob('cmux-capture-preflight-*')), [])
                if mode != 'no-user':
                    self.assertTrue(trace.exists(), result.stderr)
                    import json
                    self.assertEqual(json.loads(trace.read_text())[:-1], [
                        '-n', 'launchctl', 'asuser', '501', 'sudo', '-n', '-H', '-u',
                        'runner', '/usr/sbin/screencapture', '-x', '-t', 'jpg', '-D', '1'])
                if mode == 'failure':
                    self.assertIn('could not create image from display', result.stderr)
                if mode == 'timeout':
                    self.assertIn('exceeded 2 seconds', result.stderr)
                    # The PID receipt proves the child opened its lifetime
                    # pipe. EOF is causal proof it no longer owns that pipe;
                    # this bounded wait does not assume a scheduling delay.
                    child_pid = int((root / 'child-pid').read_text())
                    try:
                        ready, _, _ = select.select([child_reader], [], [], 3)
                        self.assertTrue(ready, 'capture descendant survived timeout')
                        self.assertEqual(os.read(child_reader, 1), b'')
                    finally:
                        # Clean up the deliberately surviving negative control.
                        try:
                            os.kill(child_pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass


if __name__ == '__main__':
    unittest.main()
