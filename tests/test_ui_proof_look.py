"""Resolve NIGHTLY's short commit and comparison history in shallow fleet sources."""
from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class NightlyHistory(unittest.TestCase):
    """A fleet source has one commit and may have no origin; NIGHTLY names a short SHA."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.source = self.folder / "source"
        self.checkout = self.folder / "checkout"
        self.env = {**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                    "GIT_AUTHOR_NAME": "test", "GIT_COMMITTER_NAME": "test",
                    "GIT_AUTHOR_EMAIL": "test@example.invalid", "GIT_COMMITTER_EMAIL": "test@example.invalid"}
        self.git(self.folder, "init", "-q", "-b", "feat-cmux-next", str(self.source))
        self.common = self.commit("common")
        self.git(self.source, "checkout", "-qb", "lane/test")
        self.head = self.commit("head")
        self.git(self.source, "checkout", "-q", "feat-cmux-next")
        self.nightly = self.commit("nightly")
        self.commit("tip")
        self.git(self.folder, "clone", "-q", "--depth=1", "--branch", "feat-cmux-next",
                 self.source.as_uri(), str(self.checkout))

    def git(self, cwd, *args):
        return subprocess.run(["git", "-C", str(cwd), *args], env=self.env, check=True,
                              text=True, capture_output=True).stdout.strip()

    def commit(self, name):
        (self.source / name).write_text(name)
        self.git(self.source, "add", name)
        self.git(self.source, "-c", "core.hooksPath=/dev/null", "commit", "-qm", name)
        return self.git(self.source, "rev-parse", "HEAD")

    def prepare(self, commit, no_origin=False):
        if no_origin:
            self.git(self.checkout, "remote", "remove", "origin")
        # Redirect the production fallback URL to a real offline Git repository.
        env = {**self.env, "GIT_CONFIG_COUNT": "2",
               "GIT_CONFIG_KEY_0": "url." + self.source.as_uri() + ".insteadOf",
               "GIT_CONFIG_VALUE_0": "https://github.com/manaflow-ai/cmux.git",
               "GIT_CONFIG_KEY_1": "protocol.file.allow", "GIT_CONFIG_VALUE_1": "always"}
        script = (ROOT / "scripts/measure/ui-proof-look.sh").read_text()
        fragment = script.split("# The plan against NIGHTLY:", 1)[1].split('python3 "$hv" plan', 1)[0]
        fragment = fragment.split("\n", 1)[1]
        return subprocess.run(["bash", "-uc", fragment + '\ngit -C "$root" rev-parse "$commit^{commit}"',
                               "test"], env={**env, "root": str(self.checkout), "commit": commit,
                                             "head": self.head}, text=True, capture_output=True)

    def test_missing_short_nightly_with_origin(self):
        result = self.prepare(self.nightly[:7])
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(result.stdout.strip(), self.nightly)
        self.assertEqual(self.git(self.checkout, "merge-base", self.nightly, self.head), self.common)

    def test_missing_short_nightly_without_origin(self):
        result = self.prepare(self.nightly[:7], no_origin=True)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(result.stdout.strip(), self.nightly)
        self.assertEqual(self.git(self.checkout, "merge-base", self.nightly, self.head), self.common)

    def test_present_commits_still_need_ancestry_without_origin(self):
        self.git(self.checkout, "fetch", "-q", "--depth=1", "origin", self.nightly, self.head)
        result = self.prepare(self.nightly, no_origin=True)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(self.git(self.checkout, "merge-base", self.nightly, self.head), self.common)

    def test_non_shallow_checkout_resolves_short_commit_added_after_clone(self):
        self.git(self.checkout, "fetch", "-q", "--unshallow", "origin")
        later = self.commit("later-nightly")
        result = self.prepare(later[:7], no_origin=True)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(result.stdout.strip(), later)
        self.assertEqual(self.git(self.checkout, "merge-base", later, self.head), self.common)

    def test_unknown_short_commit_fails_before_plan(self):
        result = self.prepare("0000000", no_origin=True)
        self.assertEqual(result.returncode, 3, result.stderr + result.stdout)


if __name__ == "__main__":
    unittest.main()
