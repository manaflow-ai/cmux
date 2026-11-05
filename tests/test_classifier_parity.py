#!/usr/bin/env python3
"""scripts/ci/classifier_parity.py: main's base-red classifier must be feat-cmux-next's bytes."""
from __future__ import annotations

import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("classifier_parity", ROOT / "scripts/ci/classifier_parity.py")
parity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parity)


def git(root: Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True)


class ClassifierParity(unittest.TestCase):
    def repo(self, directory: str) -> Path:
        root = Path(directory)
        git(root, "init", "-q", "-b", "canonical")
        git(root, "config", "user.email", "t@example.com")
        git(root, "config", "user.name", "t")
        for path in parity.SHARED:
            (root / path).parent.mkdir(parents=True, exist_ok=True)
            (root / path).write_text(f"# {path}\n")
        git(root, "add", "-A")
        git(root, "commit", "-q", "-m", "canonical")
        return root

    def test_the_same_bytes_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.repo(directory)
            self.assertEqual(parity.differences(root, "canonical"), [])
            self.assertEqual(parity.main(["--ref", "canonical", "--root", str(root)]), 0)

    def test_a_changed_or_missing_file_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.repo(directory)
            (root / parity.SHARED[0]).write_text("# drifted\n")
            (root / parity.SHARED[1]).unlink()
            found = parity.differences(root, "canonical")
            self.assertEqual(len(found), 2)
            self.assertIn("differs from canonical", found[0])
            self.assertIn("missing here", found[1])
            self.assertEqual(parity.main(["--ref", "canonical", "--root", str(root)]), 1)

    def test_an_unreadable_ref_is_its_own_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.repo(directory)
            self.assertEqual(parity.main(["--ref", "nowhere", "--root", str(root)]), 2)

    def test_every_shared_file_is_in_this_checkout(self):
        for path in parity.SHARED:
            self.assertTrue((ROOT / path).is_file(), path)


if __name__ == "__main__":
    unittest.main()
