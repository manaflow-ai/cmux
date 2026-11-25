#!/usr/bin/env python3
"""Regression tests for the in-job ci-oops retry wrapper."""
from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import retry  # noqa: E402


class RetryTests(unittest.TestCase):
    def test_infra_failure_retries_once_and_publishes_both_records(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "first"
            ledger = Path(directory) / "ci_oops.jsonl"
            command = [sys.executable, "-c", (
                "from pathlib import Path; p=Path(%r); "
                "first=not p.exists(); p.touch(); "
                "print('Could not resolve host' if first else 'recovered'); "
                "raise SystemExit(7 if first else 0)" % str(marker))]
            rules = [{"id": "infra.test", "class": "infra", "any": ["Could not resolve host"]}]
            self.assertEqual(retry.run(command, "test-job", ledger, rules), 0)
            records = [json.loads(line) for line in ledger.read_text().splitlines()]
            self.assertEqual([record["outcome"] for record in records], ["retried", "passed"])
            self.assertEqual(records[0]["class"], "infra")

    def test_code_failure_is_returned_without_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            ledger = Path(directory) / "ci_oops.jsonl"
            command = [sys.executable, "-c", "print('assertion failed'); raise SystemExit(9)"]
            rules = [{"id": "code.test", "class": "real", "any": ["assertion failed"]}]
            with mock.patch.dict(os.environ, {"GITHUB_REF_NAME": "lane/test"}, clear=False):
                self.assertEqual(retry.run(command, "test-job", ledger, rules), 9)
            records = [json.loads(line) for line in ledger.read_text().splitlines()]
            self.assertEqual(len(records), 1)
            self.assertEqual(records[0]["outcome"], "gave_up")
            self.assertEqual(records[0]["class"], "real")

    def test_repeated_infra_failure_gives_up_after_one_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "attempts"
            ledger = Path(directory) / "ci_oops.jsonl"
            command = [sys.executable, "-c", (
                "from pathlib import Path; p=Path(%r); n=int(p.read_text()) if p.exists() else 0; "
                "p.write_text(str(n + 1)); print('Could not resolve host'); raise SystemExit(7)" % str(marker))]
            rules = [{"id": "infra.test", "class": "infra", "any": ["Could not resolve host"]}]
            self.assertEqual(retry.run(command, "test-job", ledger, rules), 7)
            records = [json.loads(line) for line in ledger.read_text().splitlines()]
            self.assertEqual([record["attempt"] for record in records], [1, 2])
            self.assertEqual([record["outcome"] for record in records], ["retried", "gave_up"])


if __name__ == "__main__":
    unittest.main()
