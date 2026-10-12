#!/usr/bin/env python3
"""Developer ID App ID and profile through the App Store Connect API
(scripts/ci/asc_developer_id_app.py).

nightly-next gets its own identity (com.cmuxterm.app.next) so it installs
beside classic NIGHTLY. The App ID and its Developer ID profile are
registered and fetched with the ASC key the notarization already uses.
`check` never writes; `ensure` creates only what is missing; `download`
prints the active profile.
"""
from __future__ import annotations

import base64
import importlib.util
import io
from pathlib import Path
import sys
import unittest
from contextlib import redirect_stdout

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/ci/asc_developer_id_app.py"
spec = importlib.util.spec_from_file_location("asc_developer_id_app", SCRIPT)
asc = importlib.util.module_from_spec(spec)
sys.modules["asc_developer_id_app"] = asc
spec.loader.exec_module(asc)

CERTS = {"data": [
    {"id": "C1", "attributes": {"certificateType": "DEVELOPER_ID_APPLICATION_G2", "name": "Developer ID Application: Manaflow", "expirationDate": "2031-01-01T00:00:00.000+0000"}},
    {"id": "C0", "attributes": {"certificateType": "DEVELOPER_ID_APPLICATION", "name": "Developer ID Application: Manaflow", "expirationDate": "2020-01-01T00:00:00.000+0000"}},
]}


class FakeASC:
    """Answers like App Store Connect; records every call."""

    def __init__(self, bundle=False, profile=None, status=200):
        self.bundle = bundle
        self.profile = profile  # None, or the profile's state
        self.status = status
        self.calls = []

    def __call__(self, method, path, body=None):
        self.calls.append((method, path.split("?")[0], body))
        if self.status != 200:
            return self.status, {"errors": [{"code": "FORBIDDEN_ERROR"}]}
        if method == "GET" and path.startswith("/v1/bundleIds"):
            return 200, {"data": [{"id": "B1", "attributes": {"identifier": "com.cmuxterm.app.next", "platform": "MAC_OS"}}] if self.bundle else []}
        if method == "GET" and path.startswith("/v1/certificates"):
            return 200, CERTS
        if method == "GET" and path.startswith("/v1/profiles"):
            if self.profile is None:
                return 200, {"data": []}
            return 200, {"data": [{"id": "P1", "attributes": {"name": "cmux NEXT Developer ID", "profileState": self.profile, "profileType": "MAC_APP_DIRECT",
                                                              "profileContent": base64.b64encode(b"profile").decode()}}]}
        if method == "POST" and path == "/v1/bundleIds":
            self.bundle = True
            return 201, {"data": {"id": "B1"}}
        if method == "POST" and path == "/v1/profiles":
            self.profile = "ACTIVE"
            return 201, {"data": {"id": "P1", "attributes": {"profileContent": base64.b64encode(b"profile").decode()}}}
        if method == "DELETE":
            self.profile = None
            return 204, {}
        raise AssertionError(f"unexpected {method} {path}")


def run(fake, mode):
    out = io.StringIO()
    with redirect_stdout(out):
        code = asc.run(fake, mode, "com.cmuxterm.app.next", "cmux NEXT", "cmux NEXT Developer ID")
    return code, out.getvalue()


def writes(fake):
    return [(m, p) for m, p, _ in fake.calls if m != "GET"]


class DeveloperIdAppTests(unittest.TestCase):
    def test_check_reports_what_is_missing_and_never_writes(self):
        fake = FakeASC()
        code, out = run(fake, "check")
        self.assertEqual(code, 0)
        self.assertEqual(writes(fake), [])
        self.assertIn("App ID com.cmuxterm.app.next: missing", out)
        self.assertIn("profile 'cmux NEXT Developer ID': missing", out)
        self.assertIn("Developer ID Application certificates: 1 active", out)

    def test_check_names_a_key_without_provisioning_access(self):
        code, out = run(FakeASC(status=403), "check")
        self.assertEqual(code, 0)
        self.assertIn("HTTP 403", out)
        self.assertIn("cannot read Certificates, Identifiers & Profiles", out)

    def test_ensure_registers_the_app_id_and_a_developer_id_profile(self):
        fake = FakeASC()
        code, _ = run(fake, "ensure")
        self.assertEqual(code, 0)
        self.assertEqual(writes(fake), [("POST", "/v1/bundleIds"), ("POST", "/v1/profiles")])
        bundle = next(b for m, p, b in fake.calls if p == "/v1/bundleIds" and m == "POST")["data"]["attributes"]
        self.assertEqual(bundle, {"identifier": "com.cmuxterm.app.next", "name": "cmux NEXT", "platform": "MAC_OS"})
        profile = next(b for m, p, b in fake.calls if p == "/v1/profiles" and m == "POST")["data"]
        self.assertEqual(profile["attributes"], {"name": "cmux NEXT Developer ID", "profileType": "MAC_APP_DIRECT"})
        self.assertEqual(profile["relationships"]["bundleId"]["data"], {"type": "bundleIds", "id": "B1"})
        # Only the unexpired Developer ID Application certificate.
        self.assertEqual(profile["relationships"]["certificates"]["data"], [{"type": "certificates", "id": "C1"}])

    def test_ensure_is_a_no_op_when_both_exist(self):
        fake = FakeASC(bundle=True, profile="ACTIVE")
        self.assertEqual(run(fake, "ensure")[0], 0)
        self.assertEqual(writes(fake), [])

    def test_ensure_replaces_an_invalid_profile(self):
        fake = FakeASC(bundle=True, profile="INVALID")
        self.assertEqual(run(fake, "ensure")[0], 0)
        self.assertEqual(writes(fake), [("DELETE", "/v1/profiles/P1"), ("POST", "/v1/profiles")])

    def test_download_prints_the_active_profile_only(self):
        code, out = run(FakeASC(bundle=True, profile="ACTIVE"), "download")
        self.assertEqual((code, out), (0, base64.b64encode(b"profile").decode()))
        self.assertEqual(run(FakeASC(bundle=True, profile="INVALID"), "download")[0], 1)
        self.assertEqual(run(FakeASC(bundle=True), "download")[0], 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
