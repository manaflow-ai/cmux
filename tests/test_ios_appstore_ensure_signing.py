#!/usr/bin/env python3
"""cmux-next-ios/scripts/asc_ensure_signing.py against a loopback App Store Connect.

The ensure step of ios-app-store.yml registers what is missing (bundle ids,
capabilities, App Store profiles listing CI's certificate), reuses what is
already right, and on a second run changes nothing.
"""

from __future__ import annotations

import base64
import hashlib
import importlib.util
import json
import os
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "cmux-next-ios" / "scripts" / "asc_ensure_signing.py"

CERT = b"ci distribution certificate der"
OTHER_CERT = b"someone else's certificate der"


def load():
    spec = importlib.util.spec_from_file_location("asc_ensure_signing", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class FakeAsc:
    """Just enough of the provisioning API: bundle ids, capabilities, certificates, profiles."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.next_id = 100
        self.bundles: dict[str, dict] = {}
        self.capabilities: dict[str, set[str]] = {}
        self.certificates = {
            "cert-ci": {"certificateType": "DISTRIBUTION", "certificateContent": base64.b64encode(CERT).decode()},
            "cert-other": {"certificateType": "DISTRIBUTION", "certificateContent": base64.b64encode(OTHER_CERT).decode()},
            "cert-dev": {"certificateType": "DEVELOPMENT", "certificateContent": base64.b64encode(CERT).decode()},
        }
        self.profiles: dict[str, dict] = {}
        self.writes: list[str] = []

    def new_id(self) -> str:
        self.next_id += 1
        return str(self.next_id)

    def add_bundle(self, identifier: str, capabilities: set[str] | None = None) -> str:
        pk = self.new_id()
        self.bundles[pk] = {"identifier": identifier, "name": identifier, "platform": "IOS"}
        self.capabilities[pk] = set(capabilities or ())
        return pk

    def add_profile(self, bundle_pk: str, name: str, state: str = "ACTIVE", certs: tuple[str, ...] = ("cert-ci",)) -> str:
        pk = self.new_id()
        self.profiles[pk] = {
            "name": name,
            "profileType": "IOS_APP_STORE",
            "profileState": state,
            "bundle": bundle_pk,
            "certs": list(certs),
            "profileContent": base64.b64encode(f"profile {pk} {name}".encode()).decode(),
        }
        return pk

    def handle(self, method: str, path: str, query: dict, body: dict | None) -> tuple[int, dict]:
        with self.lock:
            if method != "GET":
                self.writes.append(f"{method} {path}")
            parts = path.strip("/").split("/")
            if method == "GET" and path == "/v1/bundleIds":
                want = query.get("filter[identifier]", [""])[0]
                rows = [{"id": pk, "attributes": b} for pk, b in self.bundles.items() if b["identifier"].startswith(want)]
                return 200, {"data": rows}
            if method == "POST" and path == "/v1/bundleIds":
                attrs = body["data"]["attributes"]
                pk = self.add_bundle(attrs["identifier"])
                self.bundles[pk]["name"] = attrs["name"]
                return 201, {"data": {"id": pk, "attributes": self.bundles[pk]}}
            if method == "GET" and parts[:2] == ["v1", "bundleIds"] and parts[3] == "bundleIdCapabilities":
                rows = [{"id": f"{parts[2]}_{c}", "attributes": {"capabilityType": c}} for c in sorted(self.capabilities[parts[2]])]
                return 200, {"data": rows}
            if method == "POST" and path == "/v1/bundleIdCapabilities":
                bundle_pk = body["data"]["relationships"]["bundleId"]["data"]["id"]
                capability = body["data"]["attributes"]["capabilityType"]
                if capability == "APPLE_ID_AUTH":
                    assert body["data"]["attributes"]["settings"][0]["key"] == "APPLE_ID_AUTH_APP_CONSENT"
                self.capabilities[bundle_pk].add(capability)
                for profile in self.profiles.values():
                    if profile["bundle"] == bundle_pk:
                        profile["profileState"] = "INVALID"
                return 201, {"data": {"id": f"{bundle_pk}_{capability}"}}
            if method == "GET" and path == "/v1/certificates":
                types = query.get("filter[certificateType]", [""])[0].split(",")
                rows = [{"id": pk, "attributes": c} for pk, c in self.certificates.items() if c["certificateType"] in types]
                return 200, {"data": rows}
            if method == "GET" and parts[:2] == ["v1", "bundleIds"] and parts[3] == "profiles":
                rows = [{"id": pk, "attributes": p} for pk, p in self.profiles.items() if p["bundle"] == parts[2]]
                return 200, {"data": rows}
            if method == "GET" and parts[:2] == ["v1", "profiles"] and parts[3] == "certificates":
                return 200, {"data": [{"id": c} for c in self.profiles[parts[2]]["certs"]]}
            if method == "DELETE" and parts[:2] == ["v1", "profiles"]:
                del self.profiles[parts[2]]
                return 204, {}
            if method == "POST" and path == "/v1/profiles":
                data = body["data"]
                bundle_pk = data["relationships"]["bundleId"]["data"]["id"]
                certs = tuple(c["id"] for c in data["relationships"]["certificates"]["data"])
                if any(p["name"] == data["attributes"]["name"] for p in self.profiles.values()):
                    return 409, {"errors": [{"code": "ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE"}]}
                pk = self.add_profile(bundle_pk, data["attributes"]["name"], certs=certs)
                return 201, {"data": {"id": pk, "attributes": self.profiles[pk]}}
            return 404, {"errors": [{"code": "NOT_FOUND"}]}


class Handler(BaseHTTPRequestHandler):
    fake: FakeAsc

    def log_message(self, *_args) -> None:
        pass

    def _serve(self) -> None:
        if self.headers.get("Authorization") != "Bearer test-token":
            self._reply(401, {"errors": [{"code": "NOT_AUTHORIZED"}]})
            return
        url = urlsplit(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length)) if length else None
        status, payload = self.fake.handle(self.command, url.path, parse_qs(url.query), body)
        self._reply(status, payload)

    def _reply(self, status: int, payload: dict) -> None:
        raw = b"" if status == 204 else json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    do_GET = do_POST = do_DELETE = _serve


class EnsureSigningTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fake = FakeAsc()
        handler = type("BoundHandler", (Handler,), {"fake": self.fake})
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.tmp = tempfile.TemporaryDirectory()
        self.env = {
            "CMUX_ASC_API_BASE_URL": f"http://127.0.0.1:{self.server.server_address[1]}",
            "CMUX_ASC_TEST_TOKEN": "test-token",
            "ASC_TIMEOUT_SECONDS": "5",
        }
        self.saved = {k: os.environ.get(k) for k in self.env}
        os.environ.update(self.env)
        self.module = load()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.tmp.cleanup()
        for key, value in self.saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def run_ensure(self) -> int:
        return self.module.main([
            "--bundle-id", "com.cmux.app",
            "--app-profile", "cmux App Store CI",
            "--content-profile", "cmux App Store CI Notification Content",
            "--service-profile", "cmux App Store CI Notification Service",
            "--certificate-sha1", hashlib.sha1(CERT).hexdigest(),
            "--out-dir", self.tmp.name,
        ])

    def written(self, role: str) -> bytes:
        return (Path(self.tmp.name) / f"{role}.mobileprovision").read_bytes()

    def test_a_fresh_team_gets_every_bundle_id_capability_and_profile(self) -> None:
        # The classic app's record exists; the extensions do not yet.
        app = self.fake.add_bundle("com.cmux.app", {"PUSH_NOTIFICATIONS"})
        self.assertEqual(self.run_ensure(), 0)
        identifiers = sorted(b["identifier"] for b in self.fake.bundles.values())
        self.assertEqual(identifiers, ["com.cmux.app", "com.cmux.app.notification-content", "com.cmux.app.notification-service"])
        self.assertEqual(self.fake.capabilities[app], {"PUSH_NOTIFICATIONS", "APPLE_ID_AUTH"})
        names = sorted(p["name"] for p in self.fake.profiles.values())
        self.assertEqual(names, ["cmux App Store CI", "cmux App Store CI Notification Content", "cmux App Store CI Notification Service"])
        for profile in self.fake.profiles.values():
            self.assertEqual(profile["certs"], ["cert-ci"])
        self.assertIn(b"cmux App Store CI Notification Service", self.written("service"))
        self.assertEqual(os.stat(Path(self.tmp.name) / "app.mobileprovision").st_mode & 0o777, 0o600)

    def test_a_second_run_changes_nothing(self) -> None:
        self.assertEqual(self.run_ensure(), 0)
        first = self.written("app")
        writes = len(self.fake.writes)
        self.assertEqual(self.run_ensure(), 0)
        self.assertEqual(len(self.fake.writes), writes)
        self.assertEqual(self.written("app"), first)

    def test_stale_or_foreign_profiles_of_its_names_are_replaced_and_others_kept(self) -> None:
        app = self.fake.add_bundle("com.cmux.app", {"PUSH_NOTIFICATIONS", "APPLE_ID_AUTH"})
        invalid = self.fake.add_profile(app, "cmux App Store CI", state="INVALID")
        content = self.fake.add_bundle("com.cmux.app.notification-content")
        foreign = self.fake.add_profile(content, "cmux App Store CI Notification Content", certs=("cert-other",))
        # The classic app's own profile has another name: never touched.
        classic = self.fake.add_profile(app, "cmux App Store", certs=("cert-other",))
        self.assertEqual(self.run_ensure(), 0)
        self.assertNotIn(invalid, self.fake.profiles)
        self.assertNotIn(foreign, self.fake.profiles)
        self.assertIn(classic, self.fake.profiles)

    def test_a_capability_turned_on_now_remakes_the_profile(self) -> None:
        app = self.fake.add_bundle("com.cmux.app", {"PUSH_NOTIFICATIONS"})
        old = self.fake.add_profile(app, "cmux App Store CI")
        self.assertEqual(self.run_ensure(), 0)
        self.assertNotIn(old, self.fake.profiles)
        self.assertIn("cmux App Store CI", [p["name"] for p in self.fake.profiles.values()])

    def test_an_unknown_certificate_fails_before_any_write(self) -> None:
        code = self.module.main([
            "--bundle-id", "com.cmux.app",
            "--app-profile", "a", "--content-profile", "b", "--service-profile", "c",
            "--certificate-sha1", "00" * 20,
            "--out-dir", self.tmp.name,
        ])
        self.assertEqual(code, 1)
        self.assertEqual(self.fake.writes, [])

    def test_the_api_base_override_is_loopback_only(self) -> None:
        os.environ["CMUX_ASC_API_BASE_URL"] = "https://example.com"
        with self.assertRaises(self.module.EnsureError):
            self.module.api_base()

    def test_openssl_der_signatures_become_raw_es256(self) -> None:
        r = b"\x00" + b"\x81" * 32  # a leading zero byte for a high bit
        s = b"\x01" * 31
        der = b"\x30" + bytes([4 + len(r) + len(s)]) + b"\x02" + bytes([len(r)]) + r + b"\x02" + bytes([len(s)]) + s
        raw = self.module._der_to_raw(der)
        self.assertEqual(raw, b"\x81" * 32 + b"\x00" + b"\x01" * 31)


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
