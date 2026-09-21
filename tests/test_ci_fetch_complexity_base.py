#!/usr/bin/env python3
"""Exercise comparison-commit fetching against actual shallow Git repositories."""

from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts/ci/fetch-complexity-base.sh"


class ComparisonBaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.origin = root / "origin"
        self.origin.mkdir()
        self.git(self.origin, "init", "-q")
        (self.origin / "web").mkdir()
        (self.origin / "web/oxlint-complexity-baseline.txt").write_text("original baseline\n")
        self.git(self.origin, "add", ".")
        self.git(self.origin, "commit", "-qm", "base")
        self.base = self.git(self.origin, "rev-parse", "HEAD")
        for number in range(8):
            (self.origin / "web/change.ts").write_text(f"export const value = {number};\n")
            self.git(self.origin, "add", ".")
            self.git(self.origin, "commit", "-qm", f"change {number}")
        self.head = self.git(self.origin, "rev-parse", "HEAD")
        self.clone = root / "checkout"
        self.git(root, "clone", "-q", "--depth=1", self.origin.as_uri(), str(self.clone))

    def git(self, cwd, *args):
        return subprocess.check_output([
            "git", "-c", "user.name=CI", "-c", "user.email=ci@example.test",
            "-c", "core.hooksPath=/dev/null", *args,
        ], cwd=cwd, text=True, stderr=subprocess.PIPE).strip()

    def fetch(self, revision):
        return subprocess.run(["bash", str(HELPER), revision], cwd=self.clone,
                              text=True, capture_output=True)

    def test_old_base_is_available_without_unshallowing_or_moving_head(self):
        self.assertEqual(self.git(self.clone, "rev-list", "--count", "HEAD"), "1")
        result = self.fetch(self.base)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git(self.clone, "show", f"{self.base}:web/oxlint-complexity-baseline.txt"),
                         "original baseline")
        self.assertEqual(self.git(self.clone, "diff", "--name-only", self.base, self.head), "web/change.ts")
        self.assertEqual(self.git(self.clone, "rev-parse", "HEAD"), self.head)
        self.assertEqual(self.git(self.clone, "rev-parse", "--is-shallow-repository"), "true")
        self.assertEqual(self.git(self.clone, "rev-list", "--count", self.head, self.base), "2")

    def test_available_commit_needs_no_network(self):
        self.git(self.clone, "remote", "set-url", "origin", "/nonexistent/cmux-comparison-test")
        result = self.fetch(self.head)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_initial_push_without_a_base_needs_no_network(self):
        self.git(self.clone, "remote", "set-url", "origin", "/nonexistent/cmux-comparison-test")
        for revision in ("", "0" * 40):
            result = self.fetch(revision)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_invalid_or_unavailable_base_fails(self):
        for revision in ("main", "--upload-pack=anything", "a" * 40):
            result = self.fetch(revision)
            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
