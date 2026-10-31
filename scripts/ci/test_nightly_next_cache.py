#!/usr/bin/env python3
"""Cache identities and clean-source publication, without an Apple toolchain."""
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import nightly_release_product_reuse as product
import dev_release_product_reuse as reuse


class NextCache(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('next_cache', Path(__file__).with_name('nightly_next_cache.py'))
        self.cache = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.cache)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = {'RUNNER_NAME': 'blacksmith-12vcpu-macos-26-1', 'RUNNER_ENVIRONMENT': 'self-hosted',
                    'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF': 'refs/heads/nightly-next'}
        self.identity = {'xcode': 'Xcode 26.6', 'sdk': '26.6 25A1', 'macos': '26.1',
                         'macos_build': '25B1', 'arch': 'arm64', 'developer_dir': '/Applications/Xcode.app'}

    def plan(self, **kw):
        return self.cache.plan(self.root, self.env, kw.get('identity', self.identity), kw.get('packages', 'lock-v1'))

    def test_versions_and_package_contents_change_keys(self):
        old = self.plan()
        for name in self.identity:
            with self.subTest(name=name):
                other = self.plan(identity={**self.identity, name: self.identity[name] + '-changed'})
                self.assertNotEqual(old['prefix'], other['prefix'])
                self.assertNotEqual(old['spm_key'], other['spm_key'])
        self.assertNotEqual(old['spm_key'], self.plan(packages='lock-v2')['spm_key'])
        self.assertNotEqual(old['prefix'], self.plan(packages='lock-v2')['prefix'])

    def test_only_fresh_clean_push_can_publish(self):
        self.assertEqual(self.plan()['clean'], 'true')
        for name, value in [('GITHUB_EVENT_NAME', 'pull_request'), ('GITHUB_REF', 'refs/heads/other'),
                            ('RUNNER_NAME', 'retained-builder')]:
            with self.subTest(name=name):
                previous = self.env[name]
                self.env[name] = value
                self.assertEqual(self.plan()['clean'], 'false')
                self.env[name] = previous
        derived = self.root / 'build-universal'
        derived.mkdir()
        (derived / 'object.o').write_text('stale')
        self.assertEqual(self.plan()['clean'], 'false')

    def test_owned_cache_links_are_never_restored_or_published(self):
        self.env['RUNNER_NAME'] = 'test-glaeda-1'
        self.assertEqual(self.plan()['restore'], 'false')
        self.assertEqual(self.plan()['clean'], 'false')
        self.env['RUNNER_NAME'] = 'blacksmith-12vcpu-macos-26-1'
        retained = self.root / 'retained'
        retained.mkdir()
        (self.root / '.spm-cache').symlink_to(retained)
        self.assertEqual(self.plan()['restore'], 'false')
        self.assertEqual(self.plan()['clean'], 'false')

    def test_restored_compiler_state_cannot_be_a_clean_product_record(self):
        self.assertEqual(reuse.clean_builder(product.builder(self.env, self.root / 'build-universal')), '')
        cas = self.root / 'build-universal/CompilationCache.noindex'
        cas.mkdir(parents=True)
        (cas / 'object').write_text('cached object')
        self.assertNotEqual(reuse.clean_builder(product.builder(self.env, self.root / 'build-universal')), '')


class Workflow(unittest.TestCase):
    def test_restore_precedes_product_clean_start_measurement(self):
        import yaml
        root = Path(__file__).resolve().parents[2]
        steps = yaml.safe_load((root / '.github/workflows/nightly.yml').read_text())['jobs']['build-nightly-app']['steps']
        names = [s.get('name') for s in steps]
        lookup = names.index('Look up the nightly app compiled on the same inputs')
        for name in ('Restore Xcode compilation cache', 'Cache Swift packages'):
            self.assertLess(names.index(name), lookup, 'a warm compiler cache must not be recorded as a clean product build')
            step = steps[names.index(name)]
            self.assertIn('steps.compilation-cache-key.outputs.restore', step['if'])
        for name in ('Save Xcode compilation cache', 'Save Swift packages'):
            step = steps[names.index(name)]
            self.assertIn('steps.compilation-cache-key.outputs.clean', step['if'])
            self.assertIn('cache-matched-key', step['if'])


if __name__ == '__main__':
    unittest.main()
