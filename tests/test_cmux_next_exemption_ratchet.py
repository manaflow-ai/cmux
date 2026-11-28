#!/usr/bin/env python3
"""scripts/cmux-next/check-exemption-ratchet.py: reviewed-exemption markers only go down."""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts/cmux-next/check-exemption-ratchet.py")
SWIFT = "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Row.swift"


def git(repo: str, *args: str) -> str:
    return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True, text=True).stdout


class ExemptionRatchetTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = self.tmp.name
        git(self.repo, "init", "-q", "-b", "main")
        git(self.repo, "config", "user.email", "t@example.com")
        git(self.repo, "config", "user.name", "t")
        self.write(SWIFT, "let a = 1 // main-actor-ok: tiny\n")
        self.write("Packages/macOS/CmuxNext/Tests/X/T.swift", "// main-actor-ok: fixture\n")
        self.commit()
        self.run_check("--update-baseline")
        self.commit()
        git(self.repo, "update-ref", "refs/remotes/origin/feat-cmux-next", "HEAD")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def write(self, rel: str, text: str) -> None:
        path = os.path.join(self.repo, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)

    def commit(self) -> None:
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", "c", "--allow-empty")

    def run_check(self, *args: str, body: str = "") -> subprocess.CompletedProcess:
        env = dict(os.environ, PR_BODY=body)
        env.pop("GITHUB_BASE_REF", None)
        return subprocess.run([sys.executable, "-I", SCRIPT, "--root", self.repo, *args], capture_output=True,
                              text=True, env=env)

    def test_baseline_counts_source_not_tests(self) -> None:
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("main-actor-ok 1", result.stdout)

    def test_new_marker_fails_and_names_the_site(self) -> None:
        self.write(SWIFT, "let a = 1 // main-actor-ok: tiny\n// main-actor-ok: small\nlet b = decode()\n")
        self.commit()
        result = self.run_check()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("main-actor-ok", result.stdout)
        self.assertIn(f"{SWIFT}: 1 -> 2", result.stdout)

    def test_moved_marker_passes(self) -> None:
        self.write(SWIFT, "let a = 1\n")
        self.write("Packages/macOS/CmuxNext/Sources/CmuxNextApp/Other.swift", "let a = 1 // main-actor-ok: tiny\n")
        self.commit()
        self.assertEqual(self.run_check().returncode, 0)

    def test_fewer_markers_pass_with_a_note(self) -> None:
        self.write(SWIFT, "let a = 1\n")
        self.commit()
        result = self.run_check()
        self.assertEqual(result.returncode, 0)
        self.assertIn("--update-baseline", result.stdout)

    def test_hand_raised_baseline_fails_against_base(self) -> None:
        self.write(SWIFT, "let a = 1 // main-actor-ok: tiny\nlet b = 2 // main-actor-ok: x\n")
        path = os.path.join(self.repo, "scripts/cmux-next/exemption-ratchet-baseline.json")
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text.replace('"total": 1', '"total": 2').replace(f'"{SWIFT}": 1', f'"{SWIFT}": 2'))
        self.commit()
        result = self.run_check()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("raised 1 -> 2", result.stdout)

    def test_update_baseline_never_raises(self) -> None:
        self.write(SWIFT, "let a = 1 // main-actor-ok: tiny\nlet b = 2 // main-actor-ok: x\n")
        self.commit()
        self.run_check("--update-baseline")
        self.assertEqual(self.run_check().returncode, 1)

    def test_pr_body_override_allows_a_reviewed_raise(self) -> None:
        self.write(SWIFT, "let a = 1 // main-actor-ok: tiny\nlet b = 2 // main-actor-ok: x\n")
        self.commit()
        result = self.run_check(body="Summary\nexemption-raise: main-actor-ok a 3-entry table, measured 2 us\n")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("allowed by the PR body", result.stdout)


if __name__ == "__main__":
    unittest.main()
