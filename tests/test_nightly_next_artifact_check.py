#!/usr/bin/env python3
"""scripts/ci/nightly_next_artifact_check.py: a downloaded cmux NEXT DMG is checked against the
feed's sparkle:edSignature over its exact bytes, not only its byte length.

Run: python3 tests/test_nightly_next_artifact_check.py
"""
from __future__ import annotations

import base64
import contextlib
import importlib.util
import io
import os
import re
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("nightly_next_artifact_check",
                                              ROOT / "scripts" / "ci" / "nightly_next_artifact_check.py")
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)

# RFC 8032 section 7.1, TEST 2: a one-byte message (0x72), its key and signature.
PUBLIC = base64.b64encode(bytes.fromhex("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")).decode()
SIGNATURE = base64.b64encode(bytes.fromhex(
    "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da"
    "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00")).decode()
SIGNED = bytes.fromhex("72")


class DmgTests(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.summary = Path(self.dir.name) / "summary.md"
        patcher = mock.patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(self.summary)})
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_check(self, body: bytes, length: str = "1", signature: str = SIGNATURE, key: str = PUBLIC):
        dmg = Path(self.dir.name) / "cmux-nightly-next-macos-arm64-200.dmg"
        dmg.write_bytes(body)
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = check.main(["dmg", "--dmg", str(dmg), "--length", length, "--ed-signature", signature,
                               "--public-key", key])
        return code, out.getvalue(), err.getvalue()

    def test_the_signed_bytes_pass_and_print_their_sha256(self) -> None:
        code, out, _ = self.run_check(SIGNED)
        self.assertEqual(code, 0)
        self.assertRegex(out, r"^sha256=[0-9a-f]{64}$")
        self.assertIn("edSignature verified", self.summary.read_text())

    def test_other_bytes_of_the_feed_length_fail(self) -> None:
        code, out, err = self.run_check(b"\x73")
        self.assertEqual(code, 1)
        self.assertEqual(out, "")
        self.assertIn("does not verify", err)
        self.assertIn("mismatch", self.summary.read_text())

    def test_another_length_fails(self) -> None:
        self.assertEqual(self.run_check(SIGNED, length="2")[0], 1)

    def test_a_missing_or_malformed_signature_fails(self) -> None:
        self.assertEqual(self.run_check(SIGNED, signature="")[0], 1)
        self.assertEqual(self.run_check(SIGNED, signature="not base64!")[0], 1)

    def test_another_key_fails(self) -> None:
        self.assertEqual(self.run_check(SIGNED, key=base64.b64encode(bytes(32)).decode())[0], 1)

    def test_the_default_key_is_the_one_nightly_pins(self) -> None:
        nightly = (ROOT / ".github" / "workflows" / "nightly.yml").read_text(encoding="utf-8")
        pinned = re.search(r"^\s+NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY:\s*(\S+)\s*$", nightly, re.M)
        self.assertIsNotNone(pinned)
        self.assertEqual(check.NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY, pinned.group(1))


if __name__ == "__main__":
    unittest.main(verbosity=2)
