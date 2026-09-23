#!/usr/bin/env python3
"""Execute E2E compilation-cache setup, cleanup and compiler command construction.

The E2E build job reads the seed nightly.yml writes for ci-macos.yml compile
admission. These tests pin that it builds where that seed can hit, never
writes the seed, and cleans up only the paths it owns.
"""
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
CI_MACOS = yaml.safe_load((ROOT / '.github/workflows/ci-macos.yml').read_text())
NIGHTLY = yaml.safe_load((ROOT / '.github/workflows/nightly.yml').read_text())
COMPILE = ROOT / 'scripts/ci/compile-app-host-test-product.sh'
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
        self.canonical = self.root / 'cmux-ci'
        self.env = dict(os.environ, GITHUB_WORKSPACE=str(self.workspace),
                        CMUX_CI_CANONICAL_ROOT=str(self.canonical),
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
        cas = Path(first['CMUX_E2E_COMPILATION_CACHE'])
        cas.mkdir()
        (cas / 'stale-entry').write_text('last job')
        self.env.update(GITHUB_RUN_ID='12', GITHUB_RUN_ATTEMPT='2')
        second = self.prepare()
        self.assertEqual(first['CMUX_DERIVED_DATA_PATH'], second['CMUX_DERIVED_DATA_PATH'])
        self.assertEqual(first['CMUX_E2E_COMPILATION_CACHE'], second['CMUX_E2E_COMPILATION_CACHE'])
        self.assertFalse(product.exists())
        self.assertFalse(cas.exists())

    def test_build_paths_are_compile_admissions_canonical_paths(self):
        # The seed's key hashes the DerivedData basename, so any other name,
        # or a path outside the canonical root, is a permanent miss.
        values = self.prepare()
        self.assertEqual(values['CMUX_DERIVED_DATA_PATH'],
                         str(self.canonical / 'derived-data-compile-admission'))
        self.assertEqual(values['CMUX_E2E_COMPILATION_CACHE'],
                         str(self.canonical / 'compile-admission-cas'))
        admission = next(s for s in CI_MACOS['jobs']['macos-compile-admission']['steps']
                         if s.get('name') == 'Prepare isolated admission DerivedData')['run']
        seeder = next(s for s in NIGHTLY['jobs']['refresh-test-compilation-cache']['steps']
                      if s.get('name') == 'Prepare admission build paths')['run']
        for name in ('derived-data-compile-admission', 'compile-admission-cas'):
            self.assertIn('/' + name, admission)
            self.assertIn('/' + name, seeder)

    def fingerprint(self, derived, cwd=None):
        result = subprocess.run(['bash', str(COMPILE), 'canonical-fingerprint', derived],
                                cwd=cwd or self.workspace, env=self.env,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_fingerprint_matches_the_seed_from_any_workspace(self):
        # The old E2E key hashed the absolute workspace path, so it could never
        # share the nightly seed. The canonical key hashes only the toolchain
        # and the DerivedData basename.
        derived = self.prepare()['CMUX_DERIVED_DATA_PATH']
        original = self.fingerprint(derived)
        other = self.root / 'other-workspace'
        other.mkdir()
        self.assertEqual(original, self.fingerprint(derived, cwd=other))
        self.env['FIXTURE_XCODE'] = 'Xcode 26.7'
        self.assertNotEqual(original, self.fingerprint(derived))
        self.env['FIXTURE_XCODE'] = 'Xcode 26.6'
        self.assertNotEqual(original, self.fingerprint(str(self.canonical / 'derived-data-e2e')))

    def test_steps_run_through_the_canonical_entry_points(self):
        for name, command in (('Resolve Swift packages', 'canonical-resolve'),
                              ('Compute test compilation cache key', 'canonical-fingerprint'),
                              ('Build the app-host and UI test product', 'canonical-build')):
            with self.subTest(step=name):
                self.assertIn('compile-app-host-test-product.sh ' + command, step(name, 'build')['run'])
        order = [s.get('name') for s in JOBS['build']]
        self.assertLess(order.index('Download pre-built GhosttyKit.xcframework'),
                        order.index('Resolve Swift packages'),
                        'canonical-resolve copies the workspace, so GhosttyKit must be there first')
        self.assertLess(order.index('Resolve Swift packages'),
                        order.index('Restore test compilation cache'))

    def test_restore_reads_the_admission_seed_key(self):
        restore = step('Restore test compilation cache', 'build')
        admission = next(s for s in CI_MACOS['jobs']['macos-compile-admission']['steps']
                         if s.get('name') == 'Restore test compilation cache')
        self.assertEqual(restore['uses'], './.github/actions/cache-restore')
        self.assertEqual(restore['with']['backend'], "${{ vars.CI_CACHE_BACKEND || 'r2' }}")
        self.assertEqual(restore['with']['path'], '${{ env.CMUX_E2E_COMPILATION_CACHE }}')
        self.assertEqual(restore['with']['restore-keys'], admission['with']['restore-keys'])
        prefix = admission['with']['restore-keys'].strip()
        self.assertEqual(restore['with']['key'], prefix + '${{ env.TEST_REF }}')
        self.assertNotIn('continue-on-error', restore)
        # R2 restores need the public URL and nothing else.
        self.assertEqual(WORKFLOW['env']['CI_CACHE_R2_PUBLIC_URL'],
                         CI_MACOS['env']['CI_CACHE_R2_PUBLIC_URL'])

    def test_the_lane_never_writes_a_cache(self):
        # Nightly is the only writer of the seed. A dispatch runs any selected
        # revision, so a save here could plant entries pull requests restore.
        text = (ROOT / '.github/workflows/test-e2e.yml').read_text()
        self.assertNotIn('e2e-compilation-v1', text)
        for job, steps in JOBS.items():
            for entry in steps:
                uses = entry.get('uses', '')
                with self.subTest(job=job, step=entry.get('name')):
                    self.assertFalse(uses.startswith('actions/cache@'), 'actions/cache saves in its post step')
                    self.assertFalse(uses.startswith('actions/cache/save@'))
                    self.assertNotIn('cache-save', uses)

    def test_xcode_is_pinned_only_for_the_default_runner(self):
        env = WORKFLOW['jobs']['build']['env']
        self.assertEqual(env['CMUX_CI_XCODE_APP'],
            "${{ (!inputs.runner || inputs.runner == 'auto') && vars.CMUX_CI_XCODE_APP_PR || '' }}")
        # The default runner here and the seeder both read CMUX_CI_XCODE_APP_PR.
        seeder = NIGHTLY['jobs']['refresh-test-compilation-cache']['env']['CMUX_CI_XCODE_APP']
        self.assertTrue(seeder.startswith('${{ vars.CMUX_CI_XCODE_APP_PR ||'), seeder)
        admission = CI_MACOS['jobs']['macos-compile-admission']['env']['CMUX_CI_XCODE_APP']
        self.assertIn("github.event_name == 'pull_request' && (vars.CMUX_CI_XCODE_APP_PR", admission)
        # Select Xcode reads it, so it has to be job-level, not a later step's.
        self.assertLess([s.get('name') for s in JOBS['build']].index('Select Xcode'),
                        [s.get('name') for s in JOBS['build']].index('Compute test compilation cache key'))

    def run_package_prefix(self, reuse_hit):
        # Execute the package step up to the archive, with a python3 that
        # records where each stamp/restore ran.
        values = self.prepare()
        src = self.canonical / 'src'
        src.mkdir(parents=True, exist_ok=True)
        trace = self.root / 'trace'
        trace.write_text('')
        stub = self.root / 'bin' / 'python3'
        stub.write_text('#!/bin/sh\nprintf "%s %s\\n" "$PWD" "$2" >> "$PACKAGE_TRACE"\n')
        stub.chmod(0o755)
        script = step('Package the compiled test product', 'build')['run']
        prefix = script[:script.index('archive=')]
        result = subprocess.run(['bash', '-eu', '-o', 'pipefail', '-c', prefix],
            cwd=self.workspace, env=dict(self.env, **values, REUSE_HIT=reuse_hit,
                                         PACKAGE_TRACE=str(trace)),
            text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return [line.split(' ')[:2] for line in trace.read_text().splitlines()], src

    def test_fresh_products_are_stamped_at_the_canonical_checkout_first(self):
        calls, src = self.run_package_prefix('false')
        self.assertEqual(calls, [
            [str(src), 'stamp'],
            [str(self.workspace), 'restore'],
            [str(self.workspace), 'stamp'],
            [str(self.workspace), 'seal'],
        ])

    def test_adopted_products_are_only_stamped_here(self):
        calls, _ = self.run_package_prefix('true')
        self.assertEqual(calls, [[str(self.workspace), 'stamp'], [str(self.workspace), 'seal']])

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
        compiles = [s for s in build if 'compile-app-host-test-product.sh canonical-build' in (s.get('run') or '')]
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
        Path(values['CMUX_E2E_COMPILATION_CACHE']).mkdir()
        src = self.canonical / 'src'
        src.mkdir()
        unrelated = self.root / 'keep'
        unrelated.mkdir()
        for name in ('CMUX_DERIVED_DATA_PATH', 'CMUX_E2E_COMPILATION_CACHE'):
            for path in (unrelated, src, self.canonical, self.canonical / 'derived-data-e2e'):
                with self.subTest(variable=name, path=path):
                    rejected = self.run_step('Clean owned DerivedData', **dict(values, **{name: str(path)}))
                    self.assertNotEqual(rejected.returncode, 0)
                    self.assertTrue(path.exists() or path.name == 'derived-data-e2e')
                    self.assertTrue(Path(values['CMUX_DERIVED_DATA_PATH']).exists())
        result = self.run_step('Clean owned DerivedData', **values)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(Path(values['CMUX_DERIVED_DATA_PATH']).exists())
        self.assertFalse(Path(values['CMUX_E2E_COMPILATION_CACHE']).exists())
        # The canonical source copy and anything else under the root survive.
        self.assertTrue(src.is_dir())
        self.assertTrue(unrelated.is_dir())

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

    def test_failure_guard_only_allows_optional_reuse_steps(self):
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
            (workflow.replace('  test:\n', '  test:\n    continue-on-error: true\n'), False),
            # The seed restore is read-only and fails open by itself.
            (workflow.replace('        id: compilation-cache-restore\n',
                              '        id: compilation-cache-restore\n        continue-on-error: true\n'), False),
            (workflow.replace('        id: reuse\n', '        id: unrelated-setup\n'), False),
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
