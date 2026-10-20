#!/usr/bin/env python3
"""A trusted NEXT worker keeps its package checkouts and compilation cache, never its build state.

An incremental Xcode build can keep stale autolink and force-load data in
objects it did not recompile after an import set changed, so a shipped build
starts from an empty DerivedData even on a worker that kept one before.
"""
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts/ci'))
import nightly_build_state as state


class NightlyBuildState(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.workspace = self.root / 'src'
        self.workspace.mkdir()
        self.home = self.root / 'home'

    def prepare(self, runner='cmux15-glaeda', toolchain='Xcode 26.6'):
        return state.prepare(self.workspace, self.home, runner, 'nightly-next', toolchain)

    def retained(self, runner='cmux15-glaeda'):
        return self.home / 'Library/Caches/cmux-nightly-next' / runner

    def test_kept_build_state_is_deleted_and_package_checkouts_stay(self):
        # State that an earlier revision of this script retained, for this
        # toolchain and for an older one, and linked into the workspace.
        for identity in ('current', 'older-xcode'):
            for path in ('DerivedData/Build/Intermediates.noindex/build.db',
                         'DerivedData/Build/Products/Release/cmux.app/binary',
                         'DerivedData/cmux-nightly-inputs.json'):
                target = self.retained() / identity / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text('stale')
        (self.workspace / 'build-universal').symlink_to(self.retained() / 'current/DerivedData')

        self.assertTrue(self.prepare())
        checkout = self.workspace / '.spm-cache/checkouts/pkg/source.swift'
        checkout.parent.mkdir(parents=True)
        checkout.write_text('kept')
        derived = self.workspace / 'build-universal'
        (derived / 'Build').mkdir()
        (derived / 'Build/object.o').write_text('built by this job')
        cas = derived / 'CompilationCache.noindex/v1.1/data'
        cas.parent.mkdir(parents=True)
        cas.write_text('content-keyed')

        # Checkout's clean drops the workspace links; the next job prepares again.
        (self.workspace / '.spm-cache').unlink()
        self.assertTrue(self.prepare())

        self.assertFalse(derived.is_symlink())
        self.assertEqual([path.name for path in derived.iterdir()], ['CompilationCache.noindex'])
        self.assertTrue((derived / 'CompilationCache.noindex').is_symlink())
        self.assertEqual(cas.read_text(), 'content-keyed')
        self.assertEqual(sorted(self.retained().glob('*/DerivedData')), [])
        self.assertEqual(checkout.read_text(), 'kept')

    def test_hosted_and_classic_do_not_acquire_next_state(self):
        self.assertFalse(self.prepare(runner='blacksmith-12vcpu-macos-26-1'))
        self.assertFalse(state.prepare(self.workspace, self.home, 'cmux15-glaeda', 'nightly', 'Xcode 26.6'))
        self.assertFalse((self.workspace / 'build-universal').exists())
        self.assertFalse((self.workspace / '.spm-cache').exists())


if __name__ == '__main__':
    unittest.main()
