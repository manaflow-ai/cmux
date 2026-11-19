#!/usr/bin/env python3
"""Positive and negative contract tests for signed same-tree receipts."""

from __future__ import annotations

import json
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest

# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/same_tree_receipt.py"
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", ROOT / "tests/git_fixture_env.py")
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)
KEY = "11" * 32
TREE = "a" * 40
JOB = "rust-workspaces:cmux-tui:v1"
COMMAND = "python3 .github/scripts/rust-workspaces.py run cmux-tui"


class SameTreeReceiptTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="same-tree-receipt-"))
        self.receipt = self.tmp / "receipt.json"
        self.env = {**os.environ, "CMUX_CI_RECEIPT_SIGNING_KEY": KEY,
                    "CMUX_CI_RECEIPT_VERIFY_KEY": KEY, "CMUX_CI_RECEIPT_KEY_ID": "test"}

    def run_script(self, *args: str, env: dict | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run([sys.executable, str(SCRIPT), *args], env=env or self.env,
                              capture_output=True, text=True)

    def mint(self) -> None:
        result = self.run_script("run", "--repo", str(ROOT), "--tree", subprocess.check_output(
            ["git", "-C", str(ROOT), "rev-parse", "HEAD^{tree}"], text=True).strip(),
            "--receipt", str(self.receipt), "--job", JOB, "--command", COMMAND, "--", "true")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_successful_execution_mints_and_verifies_exact_identity(self) -> None:
        self.mint()
        tree = json.loads(self.receipt.read_text())["tree_sha"]
        result = self.run_script("verify", "--receipt", str(self.receipt), "--tree", tree,
                                "--job", JOB, "--command", COMMAND)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_command_tree_and_job_mismatch_are_unknown(self) -> None:
        self.mint()
        tree = json.loads(self.receipt.read_text())["tree_sha"]
        for args in (("--tree", "b" * 40), ("--job", "other"), ("--command", COMMAND + " --changed")):
            with self.subTest(args=args):
                chosen = {"--tree": tree, "--job": JOB, "--command": COMMAND}
                chosen[args[0]] = args[1]
                result = self.run_script("verify", "--receipt", str(self.receipt), "--tree", chosen["--tree"],
                                         "--job", chosen["--job"], "--command", chosen["--command"])
                self.assertEqual(result.returncode, 2)
                self.assertIn("unknown", result.stderr)

    def test_tampering_signature_or_payload_never_passes(self) -> None:
        self.mint()
        data = json.loads(self.receipt.read_text())
        tree = data["tree_sha"]
        data["result"] = "passed"
        data["job"] = "forged"
        self.receipt.write_text(json.dumps(data))
        result = self.run_script("verify", "--receipt", str(self.receipt), "--tree", tree,
                                "--job", JOB, "--command", COMMAND)
        self.assertEqual(result.returncode, 2)
        self.assertIn("unknown", result.stderr)

    def test_missing_key_is_unknown_and_failed_command_mints_nothing(self) -> None:
        self.mint()
        tree = json.loads(self.receipt.read_text())["tree_sha"]
        no_key = {k: v for k, v in self.env.items() if k != "CMUX_CI_RECEIPT_VERIFY_KEY"}
        result = self.run_script("verify", "--receipt", str(self.receipt), "--tree", tree,
                                "--job", JOB, "--command", COMMAND, env=no_key)
        self.assertEqual(result.returncode, 2)
        failed = self.tmp / "failed.json"
        result = self.run_script("run", "--repo", str(ROOT), "--receipt", str(failed),
                                "--job", JOB, "--command", COMMAND, "--", "false")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(failed.exists())

    def test_command_that_changes_tracked_source_mints_nothing(self) -> None:
        repo = self.tmp / "repo"
        git_fixture_env.init_repo(repo, env=self.env)
        subprocess.run(["git", "-C", str(repo), "config", "user.email", "test@example.com"],
                       check=True, env=self.env)
        subprocess.run(["git", "-C", str(repo), "config", "user.name", "receipt test"],
                       check=True, env=self.env)
        (repo / "tracked.txt").write_text("before\n")
        subprocess.run(["git", "-C", str(repo), "add", "tracked.txt"], check=True, env=self.env)
        subprocess.run(["git", "-C", str(repo), "commit", "-qm", "initial"], check=True, env=self.env)
        tree = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD^{tree}"],
                                       text=True, env=self.env).strip()
        failed = self.tmp / "changed.json"
        result = self.run_script(
            "run", "--repo", str(repo), "--tree", tree, "--receipt", str(failed),
            "--job", JOB, "--command", COMMAND, "--", sys.executable, "-c",
            "from pathlib import Path; Path('tracked.txt').write_text('after\\n')",
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("changed the source tree", result.stderr)
        self.assertFalse(failed.exists())

    def test_command_cannot_read_the_signing_key(self) -> None:
        receipt = self.tmp / "hidden-key.json"
        result = self.run_script(
            "run", "--repo", str(ROOT), "--receipt", str(receipt), "--job", JOB,
            "--command", COMMAND, "--", sys.executable, "-c",
            "import os, sys; sys.exit(1 if os.getenv('CMUX_CI_RECEIPT_SIGNING_KEY') else 0)",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(receipt.exists())


if __name__ == "__main__":
    unittest.main()
