#!/usr/bin/env python3
"""Terminal receipts must identify failed and unexecuted compatibility cells."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("mobile_pair_matrix", ROOT / "scripts/ci/mobile_pair_matrix.py")
matrix = importlib.util.module_from_spec(spec)
spec.loader.exec_module(matrix)


class MatrixReceipts(unittest.TestCase):
    def exercise(self, outcome=None, prep_failure=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rows = [{"role": role, "sha": char * 40, "release_ids": [release]}
                    for role, char, release in (("host", "a", "nightly-1"), ("dial", "b", "ios-1"))]
            window = root / "window.json"
            window.write_text(json.dumps({"include": rows}))
            logs = root / "logs"
            calls = []
            def run(command, **kwargs):
                calls.append(command)
                if command[0] == "bash":
                    if isinstance(outcome, Exception):
                        raise outcome
                    return subprocess.CompletedProcess(command, outcome or 0)
                if prep_failure and "fetch" in command:
                    raise subprocess.CalledProcessError(128, command)
                return subprocess.CompletedProcess(command, 0)
            with patch.object(sys, "argv", ["matrix", str(window), "--head", str(root)]), \
                 patch.dict(os.environ, {"SKEW_LOG_DIR": str(logs)}), \
                 patch.object(matrix.subprocess, "run", side_effect=run), \
                 patch.object(matrix.subprocess, "check_output", return_value="c" * 40 + "\n"):
                try:
                    matrix.main()
                    code = 0
                except SystemExit as exc:
                    code = exc.code
                except subprocess.CalledProcessError as exc:
                    code = exc.returncode
            return code, json.loads((logs / "matrix-result.json").read_text()), calls

    def test_timeout_has_terminal_receipt_and_retains_unrun_release(self):
        code, receipt, calls = self.exercise(124)
        self.assertEqual(code, 124)
        self.assertFalse(receipt["passed"])
        self.assertEqual(receipt["completed"][0]["failed_stage"], "pair-timeout")
        self.assertEqual(receipt["completed"][0]["release_ids"], ["nightly-1"])
        self.assertEqual(receipt["not_run"][0]["release_ids"], ["ios-1"])
        pair_call, = [call for call in calls if call[0] == "bash"]
        self.assertTrue(pair_call[1].endswith("/scripts/ci/timeout.sh"))
        self.assertEqual(pair_call[2:4], ["--kill-after=5", "1800"])

    def test_nonzero_pair_and_launch_error_never_pass(self):
        for outcome, status, stage in ((7, 7, "pair"), (OSError("missing bash"), 127, "pair-launch")):
            with self.subTest(stage=stage):
                code, receipt, _ = self.exercise(outcome)
                self.assertEqual(code, status)
                self.assertFalse(receipt["passed"])
                self.assertEqual(receipt["completed"][0]["failed_stage"], stage)

    def test_source_failure_records_entire_unrun_window(self):
        code, receipt, calls = self.exercise(prep_failure=True)
        self.assertEqual(code, 128)
        self.assertEqual(receipt["completed"], [])
        self.assertEqual(len(receipt["not_run"]), 2)
        self.assertEqual(receipt["failed_stage"], "source-preparation-incomplete")
        self.assertFalse(any(call[0] == "bash" for call in calls))

    def test_success_requires_every_cell_and_removes_worktrees(self):
        code, receipt, calls = self.exercise()
        self.assertEqual(code, 0)
        self.assertTrue(receipt["passed"])
        self.assertEqual(len(receipt["completed"]), 2)
        self.assertEqual(receipt["not_run"], [])
        self.assertTrue(all(row["pr_sha"] == "c" * 40 for row in receipt["completed"]))
        self.assertEqual(len([call for call in calls if "remove" in call]), 2)


if __name__ == "__main__":
    unittest.main()
