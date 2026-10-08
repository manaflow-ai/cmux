#!/usr/bin/env python3
"""Portable contracts for App Store Connect notarization status polling."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "poll_notary_submission", ROOT / "scripts/ci/poll-notary-submission.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PollNotarySubmissionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.state = Path(self.temp.name) / "submission.state"
        self.output = Path(self.temp.name) / "status.json"
        self.state.write_text("submission_id=fixture-id\n", encoding="utf-8")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_status(self, status: str, http_status: int = 200) -> tuple[int, dict]:
        with patch.object(MODULE, "_token", return_value="fixture-token"), patch.object(
            MODULE, "_api", return_value=(http_status, {"id": "fixture-id", "status": status})
        ):
            result = MODULE.main([str(self.state), "--output", str(self.output)])
        return result, json.loads(self.output.read_text(encoding="utf-8"))

    def test_accepted_is_admitted(self) -> None:
        result, body = self.run_status("Accepted")
        self.assertEqual(result, 0)
        self.assertEqual(body["status"], "Accepted")

    def test_in_progress_is_retryable(self) -> None:
        result, body = self.run_status("In Progress")
        self.assertEqual(result, 2)
        self.assertEqual(body["status"], "In Progress")

    def test_terminal_status_fails_closed(self) -> None:
        result, body = self.run_status("Invalid")
        self.assertEqual(result, 1)
        self.assertEqual(body["status"], "Invalid")

    def test_http_failure_fails_closed(self) -> None:
        result, body = self.run_status("", http_status=401)
        self.assertEqual(result, 1)
        self.assertEqual(body["http_status"], 401)


if __name__ == "__main__":
    unittest.main()
