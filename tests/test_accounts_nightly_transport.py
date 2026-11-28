#!/usr/bin/env python3
"""Exercise the shared Nightly probe's real stdio transport with fake cmux children."""
from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "accounts_probe", ROOT / "scripts/measure/accounts-nightly-probe.py")
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class TransportTests(unittest.TestCase):
    def fake_cmux(self, source):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        path = Path(folder.name) / "cmux"
        path.write_text(f"#!{sys.executable}\n" + source)
        path.chmod(0o700)
        patch = mock.patch.object(PROBE.shutil, "which", return_value=str(path))
        patch.start()
        self.addCleanup(patch.stop)
        return path

    def test_startup_failure_names_executable_exit_and_redacts_secret(self):
        path = self.fake_cmux(
            "import os, sys\n"
            "sys.stdin.readline()\n"
            "sys.stderr.write('worker unavailable ' + os.environ['CMUX_GITHUB_TEST_PASSWORD']"
            " + ' Bearer abc123\\n' + os.environ['CMUX_GITHUB_TEST_TOTP_SEED']"
            " + ' ' + os.environ['CMUX_GITHUB_TEST_LOGIN'] + '\\n')\n"
            "sys.exit(23)\n")
        with mock.patch.dict(os.environ, {"CMUX_GITHUB_TEST_PASSWORD": "private-password",
                                         "CMUX_GITHUB_TEST_TOTP_SEED": "private-seed",
                                         "CMUX_GITHUB_TEST_LOGIN": "private-login"}):
            with self.assertRaises(PROBE.ProbeError) as caught:
                PROBE.ComputerUse()
        message = str(caught.exception)
        self.assertIn(str(path), message)
        self.assertIn("exit=23", message)
        self.assertIn("worker unavailable", message)
        self.assertNotIn("private-password", message)
        self.assertNotIn("abc123", message)
        self.assertNotIn("private-seed", message)
        self.assertNotIn("private-login", message)

    def test_large_stderr_does_not_deadlock_and_retention_is_bounded(self):
        self.fake_cmux("import sys\nsys.stdin.readline()\n"
                       "sys.stderr.write('x' * 262144 + '\\nstartup-tail\\n')\n"
                       "sys.exit(17)\n")
        with self.assertRaises(PROBE.ProbeError) as caught:
            PROBE.ComputerUse()
        self.assertIn("startup-tail", str(caught.exception))
        self.assertLess(len(str(caught.exception)), 4600)

    def test_overlapping_credentials_are_redacted_longest_first(self):
        self.fake_cmux("import os, sys\nsys.stdin.readline()\n"
                       "sys.stderr.write(os.environ['CMUX_GITHUB_TEST_PASSWORD'] + '\\n')\n"
                       "sys.exit(21)\n")
        with mock.patch.dict(os.environ, {"CMUX_GITHUB_TEST_LOGIN": "alice",
                                         "CMUX_GITHUB_TEST_PASSWORD": "alice-private-suffix"}):
            with self.assertRaises(PROBE.ProbeError) as caught:
                PROBE.ComputerUse()
        self.assertNotIn("alice", str(caught.exception))
        self.assertNotIn("private-suffix", str(caught.exception))

    def test_truncation_drops_partial_secret_and_redacts_multiline_remainder(self):
        self.fake_cmux("import os, sys\nsys.stdin.readline()\n"
                       "sys.stderr.write(os.environ['TEST_PASSWORD'] + '\\nworker unavailable\\n')\n"
                       "sys.exit(19)\n")
        with mock.patch.dict(os.environ, {"TEST_PASSWORD": "s" * 5000 + "leaked-tail\nsecond-secret"}):
            with self.assertRaises(PROBE.ProbeError) as caught:
                PROBE.ComputerUse()
        self.assertNotIn("leaked-tail", str(caught.exception))
        self.assertNotIn("second-secret", str(caught.exception))
        self.assertIn("worker unavailable", str(caught.exception))

    def test_after_initialize_stderr_is_discarded_and_refusal_is_terminal(self):
        self.fake_cmux(
            "import json, sys\n"
            "for line in sys.stdin:\n"
            " req = json.loads(line)\n"
            " if 'id' not in req: continue\n"
            " if req['method'] == 'initialize':\n"
            "  sys.stderr.write('startup-only\\n'); sys.stderr.flush()\n"
            "  result = {}\n"
            " else:\n"
            "  sys.stderr.write('later-sensitive' * 20000); sys.stderr.flush()\n"
            "  result = {'isError': True, 'content': []}\n"
            " print(json.dumps({'id': req['id'], 'result': result}), flush=True)\n")
        client = PROBE.ComputerUse()
        self.addCleanup(client.close)
        self.assertEqual(client.startup_stderr, b"")
        with self.assertRaisesRegex(PROBE.ProbeError, "refused or failed"):
            client.call("click", window_id="fixture", element_id="fixture")
        self.assertEqual(client.startup_stderr, b"")
        self.assertEqual(client.sequence, 2, "a refusal must not trigger a retry")


if __name__ == "__main__":
    unittest.main()
