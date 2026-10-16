#!/usr/bin/env python3
"""Exercise actual retained Release state and content-checked input timestamps."""
import os
import shutil
from pathlib import Path
import subprocess
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
        subprocess.run(['git', 'init', '-q', str(self.workspace)], check=True)
        self.source = self.workspace / 'main.swift'
        self.source.write_text('old')
        subprocess.run(['git', '-C', str(self.workspace), 'add', 'main.swift'], check=True)

    def prepare(self, runner='cmux15-glaeda', toolchain='Xcode 26.6'):
        return state.prepare(self.workspace, self.home, runner, 'nightly-next', toolchain)

    def test_checkout_cleanup_preserves_build_database_products_and_packages(self):
        self.assertTrue(self.prepare())
        for path in ('build-universal/Build/Intermediates.noindex/build.db',
                     'build-universal/Build/Products/Release/cmux.app/binary', '.spm-cache/checkouts/pkg/source.swift'):
            target = self.workspace / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('kept')
        (self.workspace / 'build-universal').unlink()
        (self.workspace / '.spm-cache').unlink()
        self.prepare()
        self.assertEqual((self.workspace / 'build-universal/Build/Intermediates.noindex/build.db').read_text(), 'kept')
        self.assertEqual((self.workspace / '.spm-cache/checkouts/pkg/source.swift').read_text(), 'kept')
        first = (self.workspace / 'build-universal').resolve()
        self.prepare(toolchain='Xcode 27')
        self.assertNotEqual((self.workspace / 'build-universal').resolve(), first)
        self.prepare(runner='cmux15-glaeda-1')
        self.assertNotEqual((self.workspace / 'build-universal').resolve(), first)
        self.assertTrue((first / 'Build/Products/Release/cmux.app/binary').is_file())

    def test_only_identical_sources_and_rebuilt_resources_reuse_times(self):
        self.prepare()
        resource = self.workspace / state.GENERATED_INPUTS[0] / 'index.html'
        resource.parent.mkdir(parents=True)
        resource.write_text('same output')
        old = 1_000_000_000_000_000_000
        os.utime(self.source, ns=(old, old))
        os.utime(resource, ns=(old, old))
        state.inputs(self.workspace, 'record')
        self.source.write_text('changed')
        os.utime(self.source, ns=(old, old))  # archive or reset gave changed input an old time
        resource.write_text('same output')  # forced web bundle rebuild
        state.inputs(self.workspace, 'replay')
        self.assertGreater(self.source.stat().st_mtime_ns, old)
        self.assertEqual(resource.stat().st_mtime_ns, old)
        resource.write_text('changed output')
        os.utime(resource, ns=(old, old))
        state.inputs(self.workspace, 'replay')
        self.assertGreater(resource.stat().st_mtime_ns, old)

    def test_missing_or_corrupt_retained_state_falls_back_to_fresh_inputs(self):
        self.prepare()
        derived = self.workspace / 'build-universal'
        shutil.rmtree(derived.resolve())
        self.prepare()
        self.assertTrue(derived.is_dir())
        (derived / state.MANIFEST).write_text('incomplete JSON')
        old = 1_000_000_000_000_000_000
        os.utime(self.source, ns=(old, old))
        state.inputs(self.workspace, 'replay')
        self.assertGreater(self.source.stat().st_mtime_ns, old)

    def test_hosted_and_classic_do_not_acquire_next_state(self):
        self.assertFalse(self.prepare(runner='blacksmith-12vcpu-macos-26-1'))
        self.assertFalse(state.prepare(self.workspace, self.home, 'cmux15-glaeda', 'nightly', 'Xcode 26.6'))
        self.assertFalse((self.workspace / 'build-universal').exists())


if __name__ == '__main__':
    unittest.main()
