#!/usr/bin/env python3
"""ios_verify.fetch() gives up on a slow artifact download instead of hanging the proof post (cmux#62161)."""
from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "ci"))
import ios_verify  # noqa: E402


class FetchBoundTest(unittest.TestCase):
    def test_timeout_returns_no_screens(self) -> None:
        seen = {}

        def slow(cmd, **kw):
            seen.update(kw)
            Path(cmd[-1]).write_bytes(b"partial")
            raise subprocess.TimeoutExpired(cmd, kw["timeout"])

        with tempfile.TemporaryDirectory() as d, mock.patch.object(ios_verify.subprocess, "run", slow):
            self.assertEqual(ios_verify.fetch("abc123", Path(d), timeout=7), [])
            self.assertFalse((Path(d) / "evidence.zip").exists())
        self.assertEqual(seen["timeout"], 7)

    def test_default_bound_is_set(self) -> None:
        seen = {}

        def failed(cmd, **kw):
            seen.update(kw)
            return subprocess.CompletedProcess(cmd, 1)

        with tempfile.TemporaryDirectory() as d, mock.patch.object(ios_verify.subprocess, "run", failed):
            self.assertEqual(ios_verify.fetch("abc123", Path(d)), [])
        self.assertEqual(seen["timeout"], ios_verify.FETCH_TIMEOUT_S)


if __name__ == "__main__":
    unittest.main()
