#!/usr/bin/env python3
"""Pin how the manual macOS test lane consumes the shared build caches.

test-depot.yml builds a dispatcher-chosen revision. It restores the Swift
package cache and the nightly Debug compilation-cache seed that ci-macos.yml
compile admission restores, and must never write either. A seed entry only
hits a compiler invocation with the same absolute paths and flags, so the lane
builds through compile-app-host-test-product.sh at admission's paths.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = yaml.safe_load((ROOT / '.github/workflows/test-depot.yml').read_text())
JOB = WORKFLOW['jobs']['tests']
STEPS = JOB['steps']
NAMES = [s.get('name') for s in STEPS]
CI_MACOS = yaml.safe_load((ROOT / '.github/workflows/ci-macos.yml').read_text())
ADMISSION = CI_MACOS['jobs']['macos-compile-admission']
NIGHTLY = yaml.safe_load((ROOT / '.github/workflows/nightly.yml').read_text())
SEEDER = NIGHTLY['jobs']['refresh-test-compilation-cache']


def step(name, steps=STEPS):
    return next(s for s in steps if s.get('name') == name)


class ManualCompilationCache(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.canonical = self.root / 'cmux-ci'
        self.runner_temp = self.root / 'runner-temp'
        self.runner_temp.mkdir()
        self.github_env = self.root / 'github-env'
        self.env = dict(os.environ, CMUX_CI_CANONICAL_ROOT=str(self.canonical),
                        RUNNER_TEMP=str(self.runner_temp), GITHUB_ENV=str(self.github_env),
                        GITHUB_RUN_ID='41', GITHUB_RUN_ATTEMPT='2')

    def run_step(self, name, env=None):
        return subprocess.run(['bash', '-eu', '-o', 'pipefail', '-c', step(name)['run']],
                              cwd=self.root, env=env or self.env, text=True, capture_output=True)

    def exported(self):
        return dict(line.split('=', 1) for line in self.github_env.read_text().splitlines())

    def test_builds_at_the_paths_the_seed_was_written_from(self):
        stale = self.canonical / 'derived-data-compile-admission'
        stale.mkdir(parents=True)
        (stale / 'old-product').write_text('previous job')
        result = self.run_step('Prepare build and test paths')
        self.assertEqual(result.returncode, 0, result.stderr)
        exported = self.exported()
        self.assertEqual(exported['CMUX_COMPILE_DERIVED_DATA'], f'{self.canonical}/derived-data-compile-admission')
        self.assertEqual(exported['CMUX_COMPILATION_CACHE'], f'{self.canonical}/compile-admission-cas')
        self.assertFalse(stale.exists())
        # App-host cleanup refuses to inspect a DerivedData outside RUNNER_TEMP.
        tests = Path(exported['CMUX_DERIVED_DATA_PATH'])
        self.assertEqual(tests, self.runner_temp / 'cmux-depot-products-41-2')
        self.assertTrue(tests.is_dir())
        # Admission and the seeder name the same two paths.
        admission = step('Prepare isolated admission DerivedData', ADMISSION['steps'])['run']
        for line in ('${CMUX_CI_CANONICAL_ROOT:-/private/tmp/cmux-ci}/derived-data-compile-admission',
                     '${CMUX_CI_CANONICAL_ROOT:-/private/tmp/cmux-ci}/compile-admission-cas'):
            self.assertIn(line, admission)

    def test_resolves_fingerprints_and_builds_through_the_shared_script(self):
        script = 'scripts/ci/compile-app-host-test-product.sh'
        self.assertIn(f'{script} canonical-resolve', step('Resolve Swift packages')['run'])
        self.assertIn(f'{script} canonical-fingerprint', step('Compute test compilation cache key')['run'])
        self.assertIn(f'{script} canonical-build', step('Build the app-host and UI test product')['run'])
        for name in ('Run unit tests', 'Run UI tests'):
            with self.subTest(step=name):
                body = step(name)['run']
                self.assertIn('test-without-building', body)
                self.assertNotIn('-project cmux.xcodeproj', body)

    def test_restores_the_admission_seed_key_after_fingerprinting(self):
        restore = step('Restore test compilation cache')
        admission = step('Restore test compilation cache', ADMISSION['steps'])
        self.assertEqual(restore['uses'], './.github/actions/cache-restore')
        prefix = admission['with']['restore-keys'].strip()
        self.assertEqual(restore['with']['restore-keys'].strip(), prefix)
        self.assertTrue(restore['with']['key'].startswith(prefix))
        self.assertEqual(restore['with']['path'], '${{ env.CMUX_COMPILATION_CACHE }}')
        self.assertLess(NAMES.index('Resolve Swift packages'), NAMES.index('Compute test compilation cache key'))
        self.assertLess(NAMES.index('Compute test compilation cache key'), NAMES.index('Restore test compilation cache'))
        self.assertLess(NAMES.index('Restore test compilation cache'), NAMES.index('Build the app-host and UI test product'))

    def test_never_saves_a_cache(self):
        for entry in STEPS:
            uses = entry.get('uses', '')
            with self.subTest(step=entry.get('name')):
                self.assertFalse(uses.startswith('actions/cache@'), uses)
                self.assertNotIn('cache/save', uses)
                self.assertNotIn('actions/cache-save', uses)
                self.assertNotIn('r2-cache.sh save', entry.get('run', ''))

    def test_package_restore_is_read_only_and_after_workspace_cleanup(self):
        restore = step('Restore Swift packages')
        self.assertEqual(restore['uses'], './.github/actions/cache-restore')
        admission = step('Cache Swift packages', ADMISSION['steps'])
        self.assertEqual(restore['with']['key'], admission['with']['key'])
        self.assertLess(NAMES.index('Prepare clean package cache directory'), NAMES.index('Restore Swift packages'))
        self.assertLess(NAMES.index('Restore Swift packages'), NAMES.index('Sanitize Swift package cache'))
        self.assertLess(NAMES.index('Sanitize Swift package cache'), NAMES.index('Resolve Swift packages'))

    def test_default_runner_uses_the_seeder_xcode_and_build_phases(self):
        # The seed key carries `xcodebuild -version`; the seeder pins the pull
        # request Xcode, so the default runner must pin the same variable.
        self.assertIn('vars.CMUX_CI_XCODE_APP_PR', SEEDER['env']['CMUX_CI_XCODE_APP'])
        self.assertIn('vars.CMUX_CI_XCODE_APP_PR', JOB['env']['CMUX_CI_XCODE_APP'])
        self.assertIn('!vars.MACOS_RUNNER_TESTS', JOB['env']['CMUX_CI_XCODE_APP'])
        self.assertEqual(JOB['env']['CMUX_SKIP_ZIG_BUILD'], SEEDER['env']['CMUX_SKIP_ZIG_BUILD'])
        # The product carries CMUX_CI_APP_HOST_ISOLATION_REQUIRED, so the app
        # host needs the prepared home and the wrapper's isolation marker.
        self.assertEqual(JOB['env']['CMUX_CI_APP_HOST_ISOLATION_REQUIRED'], '1')
        self.assertIn('prepare-app-host-home.sh', step('Prepare isolated app-host home')['run'])
        self.assertIn('cleanup-app-host-home.sh', step('Clean owned app-host home')['run'])

    def test_cleanup_removes_only_the_owned_paths(self):
        self.assertEqual(self.run_step('Prepare build and test paths').returncode, 0)
        exported = self.exported()
        for key in ('CMUX_COMPILE_DERIVED_DATA', 'CMUX_COMPILATION_CACHE'):
            Path(exported[key]).mkdir(parents=True, exist_ok=True)
        keep = self.canonical / 'src'
        keep.mkdir(parents=True)
        env = dict(self.env, **exported)
        result = self.run_step('Clean owned DerivedData', env)
        self.assertEqual(result.returncode, 0, result.stderr)
        for key in ('CMUX_COMPILE_DERIVED_DATA', 'CMUX_COMPILATION_CACHE', 'CMUX_DERIVED_DATA_PATH'):
            self.assertFalse(Path(exported[key]).exists(), key)
        self.assertTrue(keep.exists())

        foreign = self.root / 'someone-else'
        foreign.mkdir()
        result = self.run_step('Clean owned DerivedData', dict(env, CMUX_COMPILATION_CACHE=str(foreign)))
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(foreign.exists())


if __name__ == '__main__':
    unittest.main()
