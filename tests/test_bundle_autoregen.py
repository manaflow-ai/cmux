#!/usr/bin/env python3
"""Exercise base conflict repair in real temporary Git repositories."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('bundle_autoregen', ROOT / 'scripts/ci/bundle_autoregen.py')
repair = importlib.util.module_from_spec(spec)
if spec.loader:
    spec.loader.exec_module(repair)


class BundleRepairTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git('init', '-q', '-b', 'base')
        self.git('config', 'user.name', 'Test')
        self.git('config', 'user.email', 'test@example.invalid')
        self.write(repair.PANE, 'base\n')
        self.write(repair.APP + '/chunks/old.mjs', 'base\n')
        self.write('webviews/src/main.tsx', 'base\n')
        self.commit('base')
        self.git('checkout', '-q', '-b', 'pane')

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], text=True).strip()

    def write(self, path, content):
        file = self.root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(content)

    def commit(self, message):
        self.git('add', '-A')
        self.git('commit', '-q', '-m', message)

    def diverge(self, source_conflict=False, delete_chunk=False):
        self.write(repair.PANE, 'pane\n')
        self.write(repair.APP + '/chunks/old.mjs', 'pane\n')
        if source_conflict:
            self.write('webviews/src/main.tsx', 'pane source\n')
        self.commit('pane changes')
        self.git('checkout', '-q', 'base')
        self.write(repair.PANE, 'new base\n')
        if delete_chunk:
            self.git('rm', repair.APP + '/chunks/old.mjs')
        if source_conflict:
            self.write('webviews/src/main.tsx', 'base source\n')
        self.commit('base changes')
        self.git('checkout', '-q', 'pane')

    def test_generated_conflicts_prepare_merge_for_regeneration(self):
        self.diverge()
        self.assertTrue(repair.prepare(self.root, 'base'))
        self.assertTrue((self.root / '.git/MERGE_HEAD').exists())
        self.assertEqual(self.git('diff', '--name-only', '--diff-filter=U'), '')

    def test_modify_delete_generated_chunk_is_rebuilt(self):
        self.diverge(delete_chunk=True)
        self.assertTrue(repair.prepare(self.root, 'base'))
        self.assertEqual(self.git('diff', '--name-only', '--diff-filter=U'), '')

    def test_any_source_conflict_leaves_head_and_worktree_untouched(self):
        self.diverge(source_conflict=True)
        head = self.git('rev-parse', 'HEAD')
        self.assertFalse(repair.prepare(self.root, 'base'))
        self.assertEqual(self.git('rev-parse', 'HEAD'), head)
        self.assertEqual(self.git('status', '--porcelain'), '')
        self.assertFalse((self.root / '.git/MERGE_HEAD').exists())

    def test_clean_base_move_is_left_for_owner(self):
        self.git('checkout', '-q', 'base')
        self.write('readme.md', 'new documentation\n')
        self.commit('clean base move')
        self.git('checkout', '-q', 'pane')
        head = self.git('rev-parse', 'HEAD')
        self.assertFalse(repair.prepare(self.root, 'base'))
        self.assertEqual(self.git('rev-parse', 'HEAD'), head)
        self.assertEqual(self.git('status', '--porcelain'), '')


if __name__ == '__main__':
    unittest.main()
