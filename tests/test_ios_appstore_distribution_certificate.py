#!/usr/bin/env python3
"""The production App Store job signs only with the team's active Apple Distribution certificate.

ios/scripts/asc_verify_distribution_certificate.py runs in ios-app-store.yml's
upload-and-validate job after the certificate is imported and before anything
signs. These tests run it against a loopback App Store Connect and hold the
workflow to running it in that place.
"""

from __future__ import annotations

import base64
import http.server
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "ios" / "scripts" / "asc_verify_distribution_certificate.py"
WORKFLOW = ROOT / ".github" / "workflows" / "ios-app-store.yml"
TEAM = "7WLXT3NR37"


def _openssl(*args: str, cwd: Path) -> None:
    subprocess.run(["openssl", *args], cwd=cwd, check=True, capture_output=True)


class FakeASC(http.server.BaseHTTPRequestHandler):
    rows: list[dict] = []
    status = 200
    requests: list[str] = []

    def do_GET(self) -> None:  # noqa: N802
        FakeASC.requests.append(self.path)
        if not self.headers.get("Authorization", "").startswith("Bearer "):
            self._send(401, {"errors": [{"code": "NOT_AUTHORIZED"}]})
            return
        if FakeASC.status != 200:
            self._send(FakeASC.status, {"errors": [{"code": "FORBIDDEN_ERROR"}]})
            return
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        kind = (query.get("filter[certificateType]") or [""])[0]
        rows = [r for r in FakeASC.rows if not kind or r["attributes"]["certificateType"] == kind]
        self._send(200, {"data": rows})

    def _send(self, status: int, body: dict) -> None:
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_: object) -> None:
        pass


class DistributionCertificateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.tmp = Path(tempfile.mkdtemp(prefix="asc-dist-cert-"))
        _openssl("ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "asc.p8", cwd=cls.tmp)
        cls.pem = {}
        cls.der = {}
        for name, ou in (("team", TEAM), ("other", "ZZZZZZZZZZ")):
            _openssl(
                "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
                "-keyout", f"{name}.key", "-out", f"{name}.pem", "-days", "30", "-set_serial", "0x0A1B2C3D4E5F",
                "-subj", f"/CN=Apple Distribution: Example ({ou})/OU={ou}/O=Example/C=US",
                cwd=cls.tmp,
            )
            cls.pem[name] = cls.tmp / f"{name}.pem"
            body = re.search(r"-----BEGIN CERTIFICATE-----(.+?)-----END", cls.pem[name].read_text(), re.S)
            cls.der[name] = "".join(body.group(1).split())
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeASC)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()

    def setUp(self) -> None:
        FakeASC.rows = []
        FakeASC.status = 200
        FakeASC.requests = []

    def row(self, **attrs: object) -> dict:
        base = {
            "certificateType": "DISTRIBUTION",
            "serialNumber": "0A1B2C3D4E5F",
            "expirationDate": "2099-01-01T00:00:00.000+0000".replace("+0000", "+00:00"),
            "activated": True,
            "certificateContent": self.der["team"],
        }
        base.update(attrs)
        return {"type": "certificates", "id": "CERT1", "attributes": base}

    def run_check(self, pem: Path) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env.update(
            {
                "ASC_API_KEY_ID": "TESTKEY123",
                "ASC_API_ISSUER_ID": "00000000-0000-0000-0000-000000000000",
                "ASC_API_KEY_PATH": str(self.tmp / "asc.p8"),
                "CMUX_ASC_API_BASE_URL": f"http://127.0.0.1:{self.server.server_port}",
            }
        )
        env.pop("ASC_API_KEY_P8_BASE64", None)
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--certificate-pem", str(pem)],
            env=env, capture_output=True, text=True, check=False,
        )

    def test_the_teams_active_distribution_certificate_passes(self) -> None:
        FakeASC.rows = [self.row()]
        result = self.run_check(self.pem["team"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("serial A1B2C3D4E5F, team 7WLXT3NR37", result.stdout)
        self.assertIn("filter%5BcertificateType%5D=DISTRIBUTION", FakeASC.requests[0])

    def test_a_certificate_of_another_team_fails_before_asking(self) -> None:
        result = self.run_check(self.pem["other"])
        self.assertEqual(result.returncode, 1)
        self.assertIn("::error::", result.stdout)
        self.assertIn("team ZZZZZZZZZZ, not 7WLXT3NR37", result.stdout)
        self.assertEqual(FakeASC.requests, [])

    def test_unlisted_wrong_type_expired_revoked_or_other_content_fails(self) -> None:
        cases = {
            "unlisted": [],
            "type": [self.row(certificateType="IOS_DEVELOPMENT")],
            "expired": [self.row(expirationDate="2001-01-01T00:00:00.000+00:00")],
            "deactivated": [self.row(activated=False)],
            "content": [self.row(certificateContent=self.der["other"])],
        }
        for name, rows in cases.items():
            with self.subTest(name):
                FakeASC.rows = rows
                result = self.run_check(self.pem["team"])
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("::error::no active DISTRIBUTION certificate with serial A1B2C3D4E5F on team 7WLXT3NR37", result.stdout)

    def test_a_key_without_access_says_which_role_it_needs(self) -> None:
        FakeASC.status = 403
        result = self.run_check(self.pem["team"])
        self.assertEqual(result.returncode, 1)
        self.assertIn("HTTP 403 (code=FORBIDDEN_ERROR)", result.stdout)
        self.assertIn("Admin role", result.stdout)

    def test_nothing_secret_is_printed(self) -> None:
        FakeASC.rows = [self.row()]
        result = self.run_check(self.pem["team"])
        printed = result.stdout + result.stderr
        key = (self.tmp / "asc.p8").read_text()
        for secret in (key, "TESTKEY123", "00000000-0000-0000-0000-000000000000", self.der["team"][:40], "Bearer"):
            self.assertNotIn(secret.strip()[:40], printed)

    def test_the_release_job_checks_the_certificate_after_import_and_before_signing(self) -> None:
        text = WORKFLOW.read_text()
        job = text[text.index("\n  upload-and-validate:"):]
        imported = job.index("security import ")
        check = job.index("python3 -I .workflow-src/ios/scripts/asc_verify_distribution_certificate.py")
        ensure = job.index("python3 -I cmux-next-ios/scripts/asc_ensure_signing.py")
        signing = job.index("--from-archive \"$RUNNER_TEMP/archive")
        self.assertLess(imported, check)
        self.assertLess(check, ensure)
        self.assertLess(check, signing)
        # It runs the workflow commit's own script, not the app ref's.
        self.assertIn("ref: ${{ github.sha }}", job[:check])
        # The certificate goes to the check as an exported public PEM only.
        self.assertNotIn("IOS_DISTRIBUTION_CERTIFICATE_PASSWORD", job[job.index("name: Verify the release certificate"):check])


if __name__ == "__main__":
    unittest.main()
