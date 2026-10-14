#!/usr/bin/env python3
"""Check the private R2 download URL signer without contacting R2."""

import os
from pathlib import Path
import subprocess
import unittest
from urllib.parse import parse_qs, urlsplit


SIGNER = Path(__file__).resolve().parents[1] / "scripts/ci/presign-r2-url.py"


class R2PresignTests(unittest.TestCase):
    def setUp(self):
        self.env = os.environ.copy()
        self.env.update(
            {
                "AWS_ACCESS_KEY_ID": "example-access",
                "AWS_SECRET_ACCESS_KEY": "example-secret",
                "AWS_SESSION_TOKEN": "example-session",
                "AWS_DEFAULT_REGION": "auto",
                "CMUX_R2_PRESIGN_AMZ_DATE": "20260102T030405Z",
            }
        )

    def run_signer(self, *extra):
        return subprocess.run(
            [
                "python3",
                str(SIGNER),
                "--endpoint-url",
                "https://account.r2.cloudflarestorage.com",
                "--bucket",
                "cmux-fleet-artifacts",
                "--key",
                "artifacts/" + "a" * 64,
                *extra,
            ],
            env=self.env,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_url_contains_private_object_and_expiry(self):
        result = self.run_signer()
        self.assertEqual(result.returncode, 0, result.stderr)
        url = urlsplit(result.stdout.strip())
        self.assertEqual(url.scheme, "https")
        self.assertEqual(url.netloc, "account.r2.cloudflarestorage.com")
        self.assertEqual(url.path, "/cmux-fleet-artifacts/artifacts/" + "a" * 64)
        query = parse_qs(url.query)
        self.assertEqual(query["X-Amz-Algorithm"], ["AWS4-HMAC-SHA256"])
        self.assertEqual(query["X-Amz-Date"], ["20260102T030405Z"])
        self.assertEqual(query["X-Amz-Expires"], ["900"])
        self.assertEqual(query["X-Amz-SignedHeaders"], ["host"])
        self.assertEqual(query["X-Amz-Security-Token"], ["example-session"])
        self.assertEqual(len(query["X-Amz-Signature"][0]), 64)

    def test_expiry_is_bounded(self):
        result = self.run_signer("--expires-in", "901")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("between 1 and 900", result.stderr)

    def test_plaintext_endpoint_is_refused(self):
        result = subprocess.run(
            [
                "python3",
                str(SIGNER),
                "--endpoint-url",
                "http://account.r2.cloudflarestorage.com",
                "--bucket",
                "bucket",
                "--key",
                "artifact",
            ],
            env=self.env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HTTPS", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
