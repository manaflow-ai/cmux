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
WORKFLOW = yaml.safe_load((ROOT / '.github/workflows/test-e2e.yml').read_text())
JOBS = {name: spec['steps'] for name, spec in WORKFLOW['jobs'].items() if 'steps' in spec}


def step(name, job=None):
    """One named step. `build` and `test` share several step names."""
    found = [(owner, s) for owner, steps in JOBS.items() if job in (None, owner)
             for s in steps if s.get('name') == name]
    if len(found) != 1:
        raise AssertionError(f"expected one {name!r} step in {job or 'the workflow'}, found {len(found)}")
    return found[0][1]


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

    def run_step(self, name, job='build', **env):
        return subprocess.run(['bash', '-eu', '-o', 'pipefail', '-c', step(name, job)['run']],
                              cwd=self.workspace, env=dict(self.env, **env),
                              text=True, capture_output=True)

    def prepare(self):
        for file in ('env', 'output'):
            (self.root / file).write_text('')
        result = self.run_step('Prepare isolated DerivedData', 'build')
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

    def test_both_test_targets_run_the_prebuilt_product(self):
        # The build job compiles every scheme once, so the test job's setup no
        # longer depends on which target was selected, and its xcodebuild
        # invocation must not compile anything.
        values = self.prepare()
        script = step('Run selected tests', 'test')['run']
        start = script.index('if [ "$TEST_TARGET" = "cmuxTests" ]; then')
        end = script.index('\nset +e', start)
        construction = script[start:end]
        for target, variable in (('cmuxTests', 'CMUX_APP_HOST_XCTESTRUN'),
                                 ('cmuxUITests', 'CMUX_UI_XCTESTRUN')):
            with self.subTest(target=target):
                manifest = self.root / (target + '.xctestrun')
                manifest.write_text('fixture')
                command = ('ONLY_TESTING=("-only-testing:' + target + '/Focused")\n' +
                           construction + '\nprintf "%s\\0" "${XCODEBUILD_CMD[@]}"')
                result = subprocess.run(['bash', '-eu', '-c', command], cwd=self.workspace,
                    env=dict(self.env, **values, TEST_TARGET=target, TEST_TIMEOUT='120',
                             **{variable: str(manifest)}),
                    capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                args = result.stdout.decode().strip('\0').split('\0')
                self.assertIn('test-without-building', args)
                self.assertIn('-xctestrun', args)
                self.assertIn(str(manifest), args)
                self.assertIn('-only-testing:' + target + '/Focused', args)
                self.assertNotIn('test', args)
                self.assertNotIn('build-for-testing', args)
                for setting in args:
                    self.assertFalse(setting.startswith('COMPILATION_CACHE_'), setting)
                    self.assertFalse(setting.startswith('CMUX_SKIP_ZIG_BUILD'), setting)

    def test_a_missing_manifest_fails_instead_of_silently_compiling(self):
        values = self.prepare()
        script = step('Run selected tests', 'test')['run']
        start = script.index('if [ "$TEST_TARGET" = "cmuxTests" ]; then')
        end = script.index('\nset +e', start)
        result = subprocess.run(['bash', '-eu', '-c',
            'ONLY_TESTING=()\n' + script[start:end]], cwd=self.workspace,
            env=dict(self.env, **values, TEST_TARGET='cmuxTests', TEST_TIMEOUT='120',
                     CMUX_APP_HOST_XCTESTRUN=str(self.root / 'absent.xctestrun')),
            text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('no cmuxTests test manifest', result.stdout + result.stderr)

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

    def test_one_build_serves_the_test_job_and_every_retry(self):
        # The whole point of the split: compilation happens in `build`, once,
        # and `test` consumes that exact artifact. A rerun of a failed `test`
        # job re-downloads the product instead of recompiling it.
        build = JOBS['build']
        compiles = [s for s in build if 'compile-app-host-test-product.sh build' in (s.get('run') or '')]
        self.assertEqual(len(compiles), 1, 'build must compile exactly once')
        for job in ('test',):
            for entry in JOBS[job]:
                run = entry.get('run') or ''
                self.assertNotIn('compile-app-host-test-product.sh', run, entry.get('name'))
                self.assertNotIn('build-for-testing', run, entry.get('name'))

        upload = step('Upload the compiled test product', 'build')
        self.assertEqual(
            upload['with']['name'],
            'app-host-products-v1-${{ steps.product-key.outputs.key }}-${{ github.run_attempt }}',
            'publish under the name ci.yml uses, so a later run can adopt it')

        outputs = WORKFLOW['jobs']['build']['outputs']
        self.assertEqual(outputs['artifact_id'], '${{ steps.upload-product.outputs.artifact-id }}')
        self.assertEqual(outputs['sha256'], '${{ steps.package.outputs.sha256 }}')
        self.assertEqual(WORKFLOW['jobs']['test']['needs'], ['resolve-ref', 'filter', 'build'])

    def test_the_test_job_verifies_the_product_before_using_it(self):
        # A transport is allowed to miss; it is not allowed to hand over
        # unverified bytes. The restore step checks the archive SHA-256 that
        # the build job published, whichever transport delivered it.
        restore = step('Restore the compiled test product', 'test')
        self.assertEqual(restore['env']['EXPECTED_SHA256'], '${{ needs.build.outputs.sha256 }}')
        self.assertEqual(restore['run'], 'scripts/ci/restore-app-host-test-product.sh')
        self.assertNotIn('continue-on-error', restore)

        fast = step('Read the compiled test product over parallel range requests', 'test')
        self.assertIs(fast['continue-on-error'], True)
        fallback = step('Download the compiled test product', 'test')
        self.assertEqual(fallback['if'], "${{ steps.parallel-product.outputs.hit != 'true' }}")

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

    def prepare_test_job(self):
        for file in ('env', 'output'):
            (self.root / file).write_text('')
        result = self.run_step('Prepare isolated DerivedData', 'test')
        self.assertEqual(result.returncode, 0, result.stderr)
        return dict(line.split('=', 1) for file in ('env', 'output')
                    for line in (self.root / file).read_text().splitlines())

    def test_the_test_job_cleans_up_the_product_it_restored(self):
        # This cleanup runs under `if: always()`, so an ownership pattern that
        # does not match the job's own prepared path turns a passing test run
        # red after the tests have already succeeded. The path also has to stay
        # under RUNNER_TEMP: app-host cleanup refuses to inspect a host whose
        # DerivedData lives anywhere else.
        values = self.prepare_test_job()
        derived = Path(values['CMUX_DERIVED_DATA_PATH'])
        self.assertTrue(derived.is_relative_to(self.root))
        self.assertFalse(derived.is_relative_to(self.workspace))
        self.assertNotIn('CMUX_E2E_COMPILATION_CACHE', values)
        unrelated = self.root / 'keep'
        unrelated.mkdir()
        rejected = self.run_step('Clean owned DerivedData', 'test',
                                 **dict(values, CMUX_DERIVED_DATA_PATH=str(unrelated)))
        self.assertNotEqual(rejected.returncode, 0)
        self.assertTrue(unrelated.exists())
        result = self.run_step('Clean owned DerivedData', 'test', **values)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(derived.exists())

    def test_only_successful_trusted_main_build_can_seed(self):
        values = self.prepare()
        cache = Path(values['CMUX_E2E_COMPILATION_CACHE'])
        (cache / 'compiler-entry').write_bytes(b'cached')
        for ref, selected, on_main, outcome, allowed in (
            # A revision main already contains seeds, whether or not it is the tip.
            ('refs/heads/main', 'a' * 40, 'true', 'success', True),
            ('refs/heads/main', 'b' * 40, 'true', 'success', True),
            ('refs/heads/main', 'a' * 40, 'false', 'success', False),
            # An unreachable containment check leaves the cache read-only.
            ('refs/heads/main', 'a' * 40, '', 'success', False),
            ('refs/heads/main', 'not-a-sha', 'true', 'success', False),
            ('refs/heads/topic', 'a' * 40, 'true', 'success', False),
            ('refs/heads/main', 'a' * 40, 'true', 'failure', False),
        ):
            (self.root / 'output').write_text('')
            result = self.run_step('Bound E2E compilation cache', **values,
                                  WORKFLOW_REF=ref, REVISION_ON_MAIN=on_main,
                                  TEST_REF=selected, TEST_OUTCOME=outcome)
            self.assertEqual(result.returncode, 0, result.stderr)
            outputs = dict(line.split('=', 1) for line in (self.root / 'output').read_text().splitlines())
            self.assertEqual(outputs['save'], str(allowed).lower(),
                             f'{ref} {selected} on_main={on_main!r} {outcome}')

    def test_containment_maps_compare_status_to_seeding_permission(self):
        sys.path.insert(0, str(ROOT / 'scripts/ci'))
        import revision_on_main

        sha = 'a' * 40
        for status, contained in (('identical', True), ('behind', True),
                                  ('ahead', False), ('diverged', False), (None, False)):
            with self.subTest(status=status):
                self.assertEqual(
                    revision_on_main.contained_in_main(
                        'o/r', sha, 'token', compare=lambda *_, s=status: s),
                    contained,
                )
        # Missing repository, token or a non-SHA revision never reaches the API.
        for repository, revision, token in (('', sha, 't'), ('o/r', 'main', 't'), ('o/r', sha, '')):
            with self.subTest(revision=revision, repository=repository, token=token):
                self.assertFalse(revision_on_main.contained_in_main(
                    repository, revision, token,
                    compare=lambda *_: self.fail('API must not be called')))
        # A transport failure is not evidence of containment.
        def explode(*_):
            raise OSError('unreachable')
        self.assertFalse(revision_on_main.contained_in_main('o/r', sha, 't', compare=explode))

    def test_empty_and_oversized_caches_are_not_published(self):
        values = self.prepare()
        # A revision main contains, so both runs reach the cache checks rather
        # than stopping at the containment gate ahead of them.
        env = dict(values, WORKFLOW_REF='refs/heads/main', REVISION_ON_MAIN='true',
                   TEST_REF='a' * 40, TEST_OUTCOME='success')
        result = self.run_step('Bound E2E compilation cache', **env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('cache is empty', result.stdout)
        self.assertNotIn('save=true', (self.root / 'output').read_text())
        (Path(values['CMUX_E2E_COMPILATION_CACHE']) / 'compiler-entry').write_bytes(b'cached')
        fake_du = self.root / 'bin' / 'du'
        fake_du.write_text('#!/bin/sh\nprintf "6291456 cache\\n"\n')
        fake_du.chmod(0o755)
        result = self.run_step('Bound E2E compilation cache', **env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('exceeds 5 GiB', result.stdout)
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
        end = guard.index('\ncheck_xcode_selection()', start)
        invoke = guard[start:end] + '\ncheck_e2e_runner_fallbacks\n'
        workflow = (ROOT / '.github/workflows/test-e2e.yml').read_text()
        candidate = self.root / 'workflow.yml'
        for text, succeeds in (
            (workflow, True),
            (workflow.replace('      - name: Run selected tests\n',
                              '      - name: Run selected tests\n        continue-on-error: true\n'), False),
            (workflow.replace('      - name: Select Xcode\n',
                              '      - name: Select Xcode\n        continue-on-error: true\n'), False),
            (workflow.replace('  test:\n', '  test:\n    continue-on-error: true\n'), False),
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
                for entry in JOBS['test']:
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
