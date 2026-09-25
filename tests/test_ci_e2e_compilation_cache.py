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
# The test steps live in a composite action that the build job runs, or the
# fallback test job when the build job did not. Treat it as a job of its own.
TESTS = 'e2e-run-tests'
JOBS[TESTS] = yaml.safe_load((ROOT / '.github/actions/e2e-run-tests/action.yml').read_text())['runs']['steps']


def by_id(step_id, job='build'):
    """One step by id, for names a job uses twice (the product upload)."""
    found = [s for s in JOBS[job] if s.get('id') == step_id]
    if len(found) != 1:
        raise AssertionError(f"expected one {step_id!r} step in {job}, found {len(found)}")
    return found[0]


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
                        PATH=str(tools) + ':' + os.environ['PATH'], FIXTURE_XCODE='Xcode 26.6',
                        CMUX_CI_CANONICAL_ROOT=str(self.root / 'canonical'))

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
        script = step('Run selected tests', TESTS)['run']
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
        script = step('Run selected tests', TESTS)['run']
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
        # Compilation happens in `build`, once, and the tests consume that
        # exact archive: the build job restores what it packaged, and the
        # fallback `test` job downloads it. Neither compiles.
        build = JOBS['build']
        compiles = [s for s in build if 'compile-app-host-test-product.sh canonical-build' in (s.get('run') or '')]
        self.assertEqual(len(compiles), 1, 'build must compile exactly once')
        for job in ('test', TESTS):
            for entry in JOBS[job]:
                run = entry.get('run') or ''
                self.assertNotIn('compile-app-host-test-product.sh', run, entry.get('name'))
                self.assertNotIn('build-for-testing', run, entry.get('name'))

        for upload_id in ('upload-product', 'upload-product-after-tests'):
            upload = by_id(upload_id)
            self.assertEqual(
                upload['with']['name'],
                'app-host-products-v1-${{ steps.reuse.outputs.product_key'
                ' || steps.product-key.outputs.key }}-${{ github.run_attempt }}',
                'publish under the name ci.yml uses, so a later run can adopt it,'
                ' or the name of the root a reused product moved this job to')

        outputs = WORKFLOW['jobs']['build']['outputs']
        self.assertEqual(outputs['artifact_id'],
                         '${{ steps.upload-product.outputs.artifact-id'
                         ' || steps.upload-product-after-tests.outputs.artifact-id }}')
        self.assertEqual(outputs['artifact_digest'],
                         '${{ steps.upload-product.outputs.artifact-digest'
                         ' || steps.upload-product-after-tests.outputs.artifact-digest }}')
        self.assertEqual(outputs['sha256'], '${{ steps.package.outputs.sha256 }}')
        self.assertEqual(WORKFLOW['jobs']['test']['needs'], ['resolve-ref', 'filter', 'runner', 'build'])

    def test_the_build_runner_runs_the_tests_so_a_run_queues_once(self):
        # The test job queued again for a runner of the same label, which on
        # saturated pools cost 10 to 60 minutes (2026-09-25). The build job
        # now runs the tests after publishing the product, and the test job
        # is only the fallback for a build that did not.
        names = [entry.get('name') for entry in JOBS['build']]
        here = step('Run the selected tests here', 'build')
        self.assertEqual(here['id'], 'test-here')
        self.assertEqual(WORKFLOW['jobs']['build']['outputs']['tested'],
                         '${{ steps.test-here.outputs.tested }}')
        self.assertNotIn('always()', here.get('if', ''))
        run = step('Run selected tests', 'build')
        self.assertEqual(run['uses'], './.e2e-workflow/.github/actions/e2e-run-tests')
        self.assertEqual(run['if'], "${{ steps.test-here.outputs.tested == 'true' }}")
        self.assertEqual(run['with']['product-from-producer'], 'true')
        self.assertEqual(run['with']['sha256'], '${{ steps.package.outputs.sha256 }}')
        self.assertEqual(run['with']['artifact-id'], '${{ steps.upload-product.outputs.artifact-id }}')
        # Tests start after the product is published, so later dispatches can
        # adopt it while they run, and after the canonical DerivedData is
        # gone, since the tests restore into a DerivedData of their own.
        for earlier in ('Upload the compiled test product', 'Save E2E compilation cache', 'Clean owned DerivedData'):
            self.assertLess(names.index(earlier), names.index(here['name']), earlier)
        self.assertLess(names.index(here['name']), names.index('Checkout the E2E test steps'))
        self.assertLess(names.index('Checkout the E2E test steps'), names.index(run['name']))
        self.assertEqual(
            WORKFLOW['jobs']['test']['if'],
            "${{ !cancelled() && needs.build.result == 'success' && needs.build.outputs.tested != 'true' }}")
        # Both jobs take the steps from this workflow's revision, so a dispatch
        # of a ref that predates the action still runs them.
        for job in ('build', 'test'):
            checkout = step('Checkout the E2E test steps', job)
            self.assertEqual(checkout['with']['ref'], '${{ github.workflow_sha }}')
            self.assertEqual(checkout['with']['path'], '.e2e-workflow')
            self.assertEqual(checkout['with']['sparse-checkout'], '.github/actions/e2e-run-tests')
        # The build job's budget covers compiling and testing.
        self.assertEqual(WORKFLOW['jobs']['build']['timeout-minutes'],
                         '${{ fromJSON(needs.filter.outputs.build_timeout) }}')

    def test_an_owned_mac_takes_the_gui_token_before_testing_here(self):
        # The tests share the owned Mac's one console session, so this job
        # takes glaeda's gui token just before them, and leaves them to the
        # `test` job when take-gui gives way (3) or times out (1).
        here = step('Run the selected tests here', 'build')
        self.assertEqual(here['env']['OWNED'], "${{ startsWith(env.CMUX_PRODUCT_RUNNER, 'glaeda-') }}")
        run = here['run']
        self.assertIn('/Users/Shared/cmux-build-fleet/bin/glaeda-canonical-root', run)
        self.assertIn('take-gui --wait 300', run)
        self.assertIn('0|2) ;;', run, 'held, or a hook that gave the token at job start')
        self.assertIn('echo "tested=false"', run)
        self.assertNotIn('set -e', run, 'take-gui exit statuses decide, they must not fail the step')
        # Left to the `test` job, the tests still find the product: the late
        # upload runs whenever the early one stood aside.
        self.assertEqual(by_id('late-upload-check')['if'],
                         "${{ always() && steps.package.outcome == 'success' && steps.upload-product.outcome == 'skipped' }}")

    def test_an_owned_mac_uploads_the_product_after_its_tests(self):
        # An owned Mac uploads at 6-7 MB/s, about 130 s for the product, which
        # the tests no longer wait for there: they restore the local archive.
        # Everywhere else, and whenever the `test` job will read the upload,
        # it still goes first.
        names = [entry.get('name') for entry in JOBS['build']]
        ids = [entry.get('id') for entry in JOBS['build']]
        before, after = by_id('upload-product'), by_id('upload-product-after-tests')
        self.assertEqual(
            before['if'],
            "${{ (vars.CI_E2E_TEST_IN_BUILD || '1') == '0' || !startsWith(env.CMUX_PRODUCT_RUNNER, 'glaeda-') }}")
        self.assertEqual(step('Run the selected tests here', 'build')['if'],
                         "${{ (vars.CI_E2E_TEST_IN_BUILD || '1') != '0' }}",
                         'the deferral must defer exactly when this job tests')
        # Runs whatever the tests did, even on a cancel, so a failing or
        # superseded run still publishes an intact product, but only when the
        # first upload stood aside for it and the archive still hashes to what
        # the package step sealed.
        check = by_id('late-upload-check')
        self.assertEqual(
            check['if'],
            "${{ always() && steps.package.outcome == 'success' && steps.upload-product.outcome == 'skipped' }}")
        self.assertIn('shasum -a 256 -c', check['run'])
        self.assertEqual(check['env']['EXPECTED_SHA256'], '${{ steps.package.outputs.sha256 }}')
        self.assertEqual(after['if'], "${{ always() && steps.late-upload-check.outcome == 'success' }}")
        self.assertEqual(ids.index('late-upload-check') + 1, ids.index('upload-product-after-tests'))
        self.assertEqual({k: v for k, v in before.items() if k not in ('id', 'if', 'name')},
                         {k: v for k, v in after.items() if k not in ('id', 'if', 'name')})
        # Both names count as published (reuse_app_host_products.py and
        # e2e_sibling_build.py); product_input_identity.py needs them unique.
        sys.path.insert(0, str(ROOT / 'scripts/ci'))
        import e2e_sibling_build
        import reuse_app_host_products
        published = (before['name'], after['name'])
        self.assertEqual(reuse_app_host_products.PUBLISH_STEPS['.github/workflows/test-e2e.yml'], published)
        self.assertEqual((e2e_sibling_build.PUBLISH_STEP, e2e_sibling_build.PUBLISH_AFTER_TESTS_STEP), published)
        self.assertEqual(len(names), len(set(names)))
        self.assertLess(ids.index('package'), ids.index('upload-product'))
        self.assertLess(ids.index('upload-product'), names.index('Run the selected tests here'))
        for earlier in ('tests', None):
            index = ids.index(earlier) if earlier else names.index('Resolve selectors against the built tests')
            self.assertLess(index, ids.index('upload-product-after-tests'))
        self.assertEqual(ids.index('upload-product-after-tests'), len(ids) - 1)
        # The tests restore the archive this job packaged, never the upload,
        # so an empty artifact id before the deferred upload is expected.
        action = yaml.safe_load((ROOT / '.github/actions/e2e-run-tests/action.yml').read_text())
        for name in ('artifact-id', 'artifact-digest'):
            self.assertIs(action['inputs'][name]['required'], False, name)

    def test_a_producer_restore_needs_no_artifact_id(self):
        # restore-app-host-test-product.sh's measurement record read
        # int(ARTIFACT_ID), which an owned build testing before its upload
        # does not have yet.
        script = (ROOT / 'scripts/ci/restore-app-host-test-product.sh').read_text()
        start = script.index("python3 - <<'PY'\n") + len("python3 - <<'PY'\n")
        body = script[start:script.index('\nPY\n', start)]
        archive = self.root / 'app-host-products' / 'app-host-products.tar.gz'
        archive.parent.mkdir()
        archive.write_bytes(b'archive')
        for artifact_id, expected in (('', None), ('42', 42)):
            with self.subTest(artifact_id=artifact_id):
                result = subprocess.run([sys.executable, '-c', body], env=dict(
                    self.env, CMUX_RESTORE_STARTED_NS='0', CMUX_RESTORE_STATUS='0',
                    CMUX_PRODUCT_FROM_PRODUCER='true', GITHUB_REPOSITORY='manaflow-ai/cmux',
                    ARTIFACT_ID=artifact_id, ARTIFACT_PROVIDER_DIGEST='', EXPECTED_SHA256='abc',
                    CMUX_PRODUCT_CONTRACT='key', CMUX_PRODUCT_SOURCE_REVISION='a' * 40,
                    CMUX_PRODUCT_PRODUCER_RUN_ID='11', CMUX_PRODUCT_PRODUCER_RUN_ATTEMPT='1',
                    GITHUB_STEP_SUMMARY=''), text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                line = next(l for l in result.stdout.splitlines() if l.startswith('CMUX_TEST_PRODUCT_RESTORE '))
                import json
                record = json.loads(line.split(' ', 1)[1])
                self.assertEqual(record['artifact_id'], expected)
                self.assertEqual(record['lookup_source'], 'producer')

    def test_the_build_timeout_doubles_job_timeout(self):
        script = WORKFLOW['jobs']['filter']['steps'][0]['run']
        for value, expected in (('45', '90'), ('7', '14')):
            with self.subTest(value=value):
                (self.root / 'output').write_text('')
                result = subprocess.run(['bash', '-eu', '-o', 'pipefail', '-c', script], cwd=self.workspace,
                    env=dict(self.env, TEST_FILTER_INPUT='cmuxTests/Foo', RECORD_VIDEO_INPUT='false',
                             RUNNER_LABEL='blacksmith-6vcpu-macos-26', JOB_TIMEOUT=value),
                    text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f'build_timeout={expected}', (self.root / 'output').read_text())
        for value in ('', 'ten', '4.5'):
            with self.subTest(value=value):
                result = subprocess.run(['bash', '-eu', '-o', 'pipefail', '-c', script], cwd=self.workspace,
                    env=dict(self.env, TEST_FILTER_INPUT='cmuxTests/Foo', RECORD_VIDEO_INPUT='false',
                             RUNNER_LABEL='blacksmith-6vcpu-macos-26', JOB_TIMEOUT=value),
                    text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0)

    def test_the_build_adopts_the_admission_seed_at_the_canonical_root(self):
        # The seed is only reusable at the paths it was built at, so the build
        # must run at the canonical root under compile admission's DerivedData
        # name, key the seed the way ci-macos.yml does, and adopt it for the
        # tested revision before compiling.
        names = [entry.get('name') for entry in JOBS['build']]
        admission = (ROOT / '.github/workflows/ci-macos.yml').read_text()
        self.assertIn('admission-derived-data-v1-${{ runner.os }}-${{ runner.arch }}-', admission)
        key = step('Compute the DerivedData seed key')
        self.assertIn('canonical-fingerprint "$CMUX_DERIVED_DATA_PATH"', key['run'])
        self.assertIn('admission-derived-data-v1-${{ runner.os }}-${{ runner.arch }}-$fingerprint-', key['run'])
        start = step('Start the DerivedData seed download')
        self.assertIn('seed_derived_data.py start', start['run'])
        self.assertIn('"$TEST_REF"', start['run'])
        adopt = step('Adopt the DerivedData seed')
        self.assertIn('seed_derived_data.py adopt', adopt['run'])
        self.assertIn('"$CMUX_CI_CANONICAL_SRC" "$CMUX_DERIVED_DATA_PATH"', adopt['run'])
        self.assertIn('"$TEST_REF"', adopt['run'])
        self.assertIs(adopt.get('continue-on-error'), True)
        resolve = step('Resolve Swift packages')
        self.assertIn('compile-app-host-test-product.sh canonical-resolve', resolve['run'])
        self.assertLess(names.index('Start the DerivedData seed download'), names.index('Resolve Swift packages'))
        self.assertLess(names.index('Resolve Swift packages'), names.index('Adopt the DerivedData seed'))
        self.assertLess(names.index('Adopt the DerivedData seed'), names.index('Build the app-host and UI test product'))
        values = self.prepare()
        self.assertEqual(values['CMUX_DERIVED_DATA_PATH'],
                         str(self.root / 'canonical' / 'derived-data-compile-admission'))
        # The CAS path is a compiler argument: a different one than admission
        # passes invalidates every compile the seed carries.
        self.assertIn('CMUX_COMPILE_ADMISSION_CAS=${CMUX_CI_CANONICAL_ROOT:-/private/tmp/cmux-ci}/compile-admission-cas', admission)
        self.assertEqual(values['CMUX_E2E_COMPILATION_CACHE'],
                         str(self.root / 'canonical' / 'compile-admission-cas'))

    def test_the_test_job_verifies_the_product_before_using_it(self):
        # A transport is allowed to miss; it is not allowed to hand over
        # unverified bytes. The restore step checks the archive SHA-256 that
        # the build job published, whichever transport delivered it, or the
        # build job's own archive when it runs the tests itself.
        restore = step('Restore the compiled test product', TESTS)
        self.assertEqual(restore['env']['EXPECTED_SHA256'], '${{ inputs.sha256 }}')
        self.assertTrue(restore['run'].rstrip().endswith('scripts/ci/restore-app-host-test-product.sh'))
        self.assertNotIn('continue-on-error', restore)
        self.assertEqual(step('Run selected tests', 'test')['with']['sha256'], '${{ needs.build.outputs.sha256 }}')

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

    def test_the_test_steps_cleanup_after_the_build_cleanup_when_preparation_was_skipped(self):
        # Run 36168944875: the screen-capture preflight failed, which skipped
        # the tests' "Prepare isolated DerivedData", and their always()
        # cleanup then refused the build's canonical path still in the env.
        values = self.prepare()
        (self.root / 'env').write_text('')
        result = self.run_step('Clean owned DerivedData', 'build', **values)
        self.assertEqual(result.returncode, 0, result.stderr)
        handed_over = dict(line.split('=', 1) for line in (self.root / 'env').read_text().splitlines())
        self.assertEqual(handed_over.get('CMUX_DERIVED_DATA_PATH'), '')
        result = self.run_step('Clean owned DerivedData', TESTS, **dict(values, **handed_over))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('nothing to clean', result.stdout)

    def prepare_test_job(self):
        for file in ('env', 'output'):
            (self.root / file).write_text('')
        result = self.run_step('Prepare isolated DerivedData', TESTS)
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
        rejected = self.run_step('Clean owned DerivedData', TESTS,
                                 **dict(values, CMUX_DERIVED_DATA_PATH=str(unrelated)))
        self.assertNotEqual(rejected.returncode, 0)
        self.assertTrue(unrelated.exists())
        result = self.run_step('Clean owned DerivedData', TESTS, **values)
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

    def test_an_owned_mac_neither_restores_nor_saves_the_cache(self):
        # 8 owned builds on 2026-09-25 hit 0 to 6 entries (one outlier, 409)
        # while the transfers cost 1.5 to 3.5 min at the owned Macs' bandwidth.
        owned = "!startsWith(env.CMUX_PRODUCT_RUNNER, 'glaeda-')"
        self.assertIn(owned, step('Restore E2E compilation cache')['if'])
        self.assertIn(owned, step('Bound E2E compilation cache')['if'])
        # The save only follows a bound that allowed it.
        self.assertIn("steps.compilation-cache-bound.outputs.save == 'true'", step('Save E2E compilation cache')['if'])

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
        end = guard.index('\ncheck_ios_runner_routing()', start)
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
                for entry in JOBS[TESTS]:
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
