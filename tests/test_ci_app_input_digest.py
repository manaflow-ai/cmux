#!/usr/bin/env python3
"""scripts/ci/app_input_digest.py: app inputs change the digest, docs and tests-only trees do not."""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "scripts" / "ci" / "app_input_digest.py"
sys.path.insert(0, str(HERE))
import git_fixture_env  # noqa: E402

ENV = git_fixture_env.fixture_env({**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
                                   "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"})
BASE = {
    ".github/workflows/nightly.yml": "run: scripts/ci/nightly-steps/a.sh\nrun: scripts/ci/helper.py\n",
    "scripts/ci/nightly-steps/a.sh": "echo a\n",
    "scripts/ci/helper.py": "import other_helper.py\n",
    "scripts/ci/other_helper.py": "x\n",
    "scripts/ci/unrelated.py": "u\n",
    ".github/workflows/lint.yml": "l\n",
    "Sources/App.swift": "app\n",
    "cmux-tui/src/main.rs": "fn main(){}\n",
    "docs/guide.md": "d\n",
    "tests/test_x.py": "t\n",
    "web/page.tsx": "w\n",
    "README.md": "r\n",
}


class DigestTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        git_fixture_env.init_repo(self.repo, "-b", "main", env=ENV)
        self.n = 0
        self.change(BASE)

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], env=ENV, check=True,
                              capture_output=True, text=True).stdout.strip()

    def change(self, files):
        for rel, text in files.items():
            p = self.repo / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            # Append so an edit keeps the references a file already makes.
            p.write_text(p.read_text() + text if p.exists() else text)
        self.git("add", "-A")
        self.n += 1
        self.git("commit", "-q", "-m", f"c{self.n}")

    def digest(self, rev="HEAD"):
        out = subprocess.run([sys.executable, "-I", str(SCRIPT), "--ref", rev], cwd=self.repo, env=ENV,
                             check=True, capture_output=True, text=True).stdout.strip()
        self.assertRegex(out, r"^[0-9a-f]{64}$")
        return out

    def assertSame(self, files):
        before = self.digest()
        self.change(files)
        self.assertEqual(before, self.digest(), files)

    def assertChanged(self, files):
        before = self.digest()
        self.change(files)
        self.assertNotEqual(before, self.digest(), files)

    def test_non_inputs_do_not_change_digest(self):
        for rel in ("docs/guide.md", "tests/test_x.py", "web/page.tsx", "README.md",
                    ".github/workflows/lint.yml", "scripts/ci/unrelated.py"):
            with self.subTest(rel):
                self.assertSame({rel: f"edit {self.n}\n"})

    def test_inputs_change_digest(self):
        for rel in ("Sources/App.swift", "cmux-tui/src/main.rs", ".github/workflows/nightly.yml",
                    "scripts/ci/nightly-steps/a.sh", "scripts/ci/helper.py", "scripts/ci/other_helper.py"):
            with self.subTest(rel):
                self.assertChanged({rel: f"edit {self.n}\n"})

    def test_new_unknown_path_is_an_input(self):
        self.assertChanged({"Newdir/thing.bin": "x\n"})

    def test_digest_is_stable_and_replay_counts(self):
        self.assertEqual(self.digest(), self.digest())
        self.change({"docs/guide.md": "e\n"})
        self.change({"Sources/App.swift": "app2\n"})
        out = subprocess.run([sys.executable, "-I", str(SCRIPT), "--replay", "2"], cwd=self.repo, env=ENV,
                             check=True, capture_output=True, text=True).stdout
        self.assertIn("commits: 2", out)
        self.assertIn("distinct_digests: 2", out)
        self.assertIn("same_as_parent: 1", out)
        self.change({"docs/guide.md": "f\n"})
        out = subprocess.run([sys.executable, "-I", str(SCRIPT), "--replay", "1"], cwd=self.repo, env=ENV,
                             check=True, capture_output=True, text=True).stdout
        self.assertIn("no_build_needed_rate: 1.0000", out)


if __name__ == "__main__":
    unittest.main()
