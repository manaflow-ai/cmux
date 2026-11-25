#!/usr/bin/env python3
"""Tests for scripts/ci/pr_added_namespace_types.py."""
import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/ci/pr_added_namespace_types.py'
spec = importlib.util.spec_from_file_location('pr_added_namespace_types', SCRIPT)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
_git_fixture_spec = importlib.util.spec_from_file_location('git_fixture_env', ROOT / 'tests' / 'git_fixture_env.py')
git_fixture_env = importlib.util.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

ENUM = 'public enum Stages {\n    public static let a = 1\n}\n'
STRUCT = 'public struct Stages {\n    public init() {}\n    public static let a = 1\n}\n'


def git(cwd, *args):
    env = git_fixture_env.fixture_env(dict(os.environ, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@t', GIT_COMMITTER_NAME='t',
               GIT_COMMITTER_EMAIL='t@t'))
    return subprocess.run(('git', *args), cwd=cwd, check=True, capture_output=True, text=True, env=env).stdout


class Repo:
    """A base commit, a PR branch merged into it, then the rewrite left in the tree."""

    def __init__(self, base_files, pr_files, rewrite):
        self.dir = tempfile.TemporaryDirectory()
        d = self.path = self.dir.name
        git_fixture_env.init_repo(d, '-b', 'base')
        self.write({'Packages/README': 'x\n', **base_files})
        git(d, 'add', '-A')
        git(d, 'commit', '-q', '-m', 'base')
        git(d, 'checkout', '-q', '-b', 'pr')
        self.write(pr_files or {'Packages/other.txt': 'y\n'})
        git(d, 'add', '-A')
        git(d, 'commit', '-q', '-m', 'pr')
        git(d, 'checkout', '-q', 'base')
        git(d, 'commit', '-q', '--allow-empty', '-m', 'base moves')
        git(d, 'merge', '-q', '--no-ff', '-m', 'merge', 'pr')
        self.write(rewrite)

    def write(self, files):
        for name, text in files.items():
            p = Path(self.path, name)
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text)

    def run(self):
        return subprocess.run(('python3', str(SCRIPT)), cwd=self.path, capture_output=True, text=True)


class PrAddedNamespaceTypes(unittest.TestCase):
    def test_a_type_the_pr_adds_fails(self):
        repo = Repo({}, {'Packages/A/Stages.swift': ENUM}, {'Packages/A/Stages.swift': STRUCT})
        out = repo.run()
        self.assertEqual(out.returncode, 1, out.stdout + out.stderr)
        self.assertIn('public enum Stages {', out.stdout)
        self.assertIn('namespace-lint-override', out.stdout)

    def test_a_type_already_on_the_base_only_warns(self):
        repo = Repo({'Packages/A/Stages.swift': ENUM},
                    {'Packages/A/Stages.swift': ENUM + '// touched\n'},
                    {'Packages/A/Stages.swift': STRUCT + '// touched\n'})
        out = repo.run()
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertIn('warning only', out.stdout)

    def test_no_rewrite_passes(self):
        repo = Repo({}, {'Packages/A/Plain.swift': 'struct Plain {}\n'}, {})
        self.assertEqual(repo.run().returncode, 0)

    def test_owned_matches_by_file(self):
        rewrite = '--- a/x.swift\n+++ b/x.swift\n@@ -1 +1 @@\n-public enum A {\n+public struct A {\n'
        pr_other = '--- a/y.swift\n+++ b/y.swift\n@@ -0,0 +1 @@\n+public enum A {\n'
        pr_same = '--- /dev/null\n+++ b/x.swift\n@@ -0,0 +1 @@\n+public enum A {\n'
        self.assertEqual(mod.owned(rewrite, pr_other), [])
        self.assertEqual(mod.owned(rewrite, pr_same), [('x.swift', 'public enum A {')])


if __name__ == '__main__':
    unittest.main()
