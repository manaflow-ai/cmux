#!/usr/bin/env python3
"""Tests for cmux-next-ios/scripts/asc_review_package.py against a loopback App Store Connect."""

from __future__ import annotations

import http.server
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "cmux-next-ios" / "scripts" / "asc_review_package.py"
sys.path.insert(0, str(SCRIPT.parent))
sys.path.insert(0, str(ROOT / "tests"))
import asc_review_package as pkg  # noqa: E402
import test_ios_appstore_listing_text as listing_text  # noqa: E402  (the app-string scan)

APP = "6783338052"
VERSION = pkg.marketing_version()
LISTING = pkg.version_listing(VERSION)
SUPPORT = "https://cmux.com/support"
LIVE_ENV = {"CMUX_IOS_REVIEW_CHIEF_NAME": "App Review"}
# Info.plist usage keys in project.yml, by the name the notes give each permission.
PERMISSION_NAMES = {
    "NSCameraUsageDescription": "Camera",
    "NSFaceIDUsageDescription": "Face ID",
    "NSLocalNetworkUsageDescription": "Local Network",
    "NSMicrophoneUsageDescription": "Microphone",
    "NSPhotoLibraryAddUsageDescription": "Photos",
    "NSPhotoLibraryUsageDescription": "Photos",
    "NSSpeechRecognitionUsageDescription": "Speech Recognition",
}


class FakeAsc:
    """A loopback App Store Connect with just the endpoints the package uses."""

    def __init__(self, notes="", detail=None, locales=None, sticky=()):
        self.locales = dict(locales or {"en-US": SUPPORT})
        self.sticky = set(sticky)  # locales whose supportUrl writes do not take
        self.detail = detail if detail is not None else {
            "demoAccountName": "cmux-review@mailinator.com",
            "contactEmail": "review-contact@example.com",
            "contactPhone": "+1 555 0100",
            "notes": notes,
        }
        self.requests: list[tuple[str, str, dict]] = []
        fake = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def _send(self, status, body):
                raw = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def do_GET(self):
                fake.requests.append(("GET", self.path, {}))
                self._send(*fake.get(self.path))

            def do_PATCH(self):
                length = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(length) or b"{}")
                fake.requests.append(("PATCH", self.path, body))
                self._send(*fake.patch(self.path, body))

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()

    def get(self, full_path):
        path = full_path.split("?")[0]
        if path == f"/v1/apps/{APP}/appStoreVersions":
            if f"filter%5BversionString%5D={VERSION}" not in full_path:
                return 200, {"data": []}
            return 200, {"data": [{"id": "version-1"}]}
        if path == "/v1/appStoreVersions/version-1/appStoreVersionLocalizations":
            return 200, {"data": [
                {"id": f"loc-{locale}", "attributes": {"locale": locale, "supportUrl": url}}
                for locale, url in self.locales.items()
            ]}
        if path == "/v1/appStoreVersions/version-1/appStoreReviewDetail":
            return 200, {"data": {"id": "detail-1", "attributes": self.detail}}
        return 404, {"errors": [{"code": "NOT_FOUND"}]}

    def patch(self, path, body):
        if path.startswith("/v1/appStoreVersionLocalizations/loc-"):
            locale = path.rsplit("loc-", 1)[1]
            if locale not in self.sticky:
                self.locales[locale] = body["data"]["attributes"]["supportUrl"]
            return 200, {"data": {"id": f"loc-{locale}"}}
        if path == "/v1/appStoreReviewDetails/detail-1":
            self.detail["notes"] = body["data"]["attributes"]["notes"]
            return 200, {"data": {"id": "detail-1"}}
        return 404, {"errors": [{"code": "NOT_FOUND"}]}


def fake_env(fake: FakeAsc, extra: dict[str, str]) -> dict[str, str]:
    values = {"CMUX_ASC_API_BASE_URL": fake.url, "CMUX_ASC_TEST_TOKEN": "test-token", "ASC_TIMEOUT_SECONDS": "5"}
    values.update(extra)
    return values


class FakeAscCase(unittest.TestCase):
    def start(self, env=None, **kwargs) -> FakeAsc:
        fake = FakeAsc(**kwargs)
        self.addCleanup(fake.close)
        values = fake_env(fake, LIVE_ENV if env is None else env)
        old = {key: os.environ.get(key) for key in [*values, *LIVE_ENV]}
        for key in LIVE_ENV:
            os.environ.pop(key, None)
        os.environ.update(values)
        self.addCleanup(lambda: [os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v) for k, v in old.items()])
        return fake

    def writes(self, fake, method):
        return [r for r in fake.requests if r[0] == method]


class NotesTests(FakeAscCase):
    TEMPLATE = pkg.DEFAULT_NOTES_TEMPLATE.read_text(encoding="utf-8")
    DETAIL = {"demoAccountName": "cmux-review@mailinator.com", "contactEmail": "c@example.com", "contactPhone": "1"}

    def rendered(self) -> str:
        return pkg.render_notes(self.TEMPLATE, self.DETAIL, LIVE_ENV)

    def test_template_names_only_screens_this_app_has(self):
        notes = self.rendered()
        # Classic screens and flows this app does not have.
        for phrase in (
            "Tailscale", "Add Computer", "Host:", "Port:", "Demo Mac", "Your Mac is connected",
            "Open Workspaces", "Subscription", "In-App Purchase", "Scan Pairing Code", "Connection Method",
            "Chat Server", "Self-Hosted", "New Group",
        ):
            self.assertNotIn(phrase, notes)
        # Every double-quoted label is a string the release app shows.
        strings = listing_text.app_strings()
        quoted = re.findall(r'"([^"\n]+)"', pkg.TEMPLATE_COMMENT.sub("", self.TEMPLATE))
        self.assertTrue(quoted)
        for label in quoted:
            if "{{" in label:
                continue
            with self.subTest(label=label):
                self.assertIn(label, strings, f"the notes quote {label!r}, which the app does not show")

    def test_template_walks_sign_in_chief_and_account_deletion(self):
        for label in ('"Continue with email"', '"Check your email"', '"Message Chief"', '"Delete Account"',
                      '"Delete your cmux account?"', "Settings", '"Account"', '"Not now"'):
            self.assertIn(label, self.TEMPLATE)

    def test_template_explains_every_permission_in_project_yml(self):
        project = (ROOT / "cmux-next-ios/project.yml").read_text(encoding="utf-8")
        keys = set(re.findall(r"^\s*(NS\w+UsageDescription):", project, re.MULTILINE))
        self.assertTrue(keys)
        unknown = keys - set(PERMISSION_NAMES)
        self.assertFalse(unknown, f"name these permissions in PERMISSION_NAMES and the notes: {sorted(unknown)}")
        permissions = self.TEMPLATE.split("Permissions", 1)[1].split("\n\n", 1)[0]
        for key in sorted(keys):
            with self.subTest(key=key):
                self.assertIn(f"- {PERMISSION_NAMES[key]}:", permissions)
        self.assertIn("- Notifications:", permissions)

    def test_the_review_demo_steps_spot_is_marked_and_dropped(self):
        self.assertEqual(self.TEMPLATE.count("## REVIEW DEMO STEPS: START"), 1)
        self.assertEqual(self.TEMPLATE.count("## REVIEW DEMO STEPS: END"), 1)
        start = self.TEMPLATE.index("## REVIEW DEMO STEPS: START")
        end = self.TEMPLATE.index("## REVIEW DEMO STEPS: END")
        self.assertIn("Review path", self.TEMPLATE[start:end])
        notes = self.rendered()
        self.assertNotIn("##", notes)
        self.assertNotIn("REVIEW DEMO STEPS", notes)
        self.assertIn("Review path (no Mac needed):", notes)

    def test_render_fills_live_values_and_derives_the_public_inbox(self):
        notes = self.rendered()
        self.assertNotIn("{{", notes)
        self.assertIn("https://www.mailinator.com/v4/public/inboxes.jsp?to=cmux-review", notes)
        self.assertIn('the Chief named "App Review"', notes)
        self.assertLessEqual(len(notes), pkg.NOTES_LIMIT)

    def test_render_keeps_the_inbox_url_already_in_app_store_connect(self):
        notes = pkg.render_notes(self.TEMPLATE, {
            **self.DETAIL,
            "demoAccountName": "reviewer@example.com",
            "notes": "old notes: https://www.mailinator.com/v4/public/inboxes.jsp?to=reviewer.",
        }, LIVE_ENV)
        self.assertIn("https://www.mailinator.com/v4/public/inboxes.jsp?to=reviewer (no", notes)

    def test_a_new_mailinator_demo_account_gets_its_own_inbox(self):
        notes = pkg.render_notes(self.TEMPLATE, {
            **self.DETAIL,
            "demoAccountName": "new-review@mailinator.com",
            "notes": "old notes: https://www.mailinator.com/v4/public/inboxes.jsp?to=old-review.",
        }, LIVE_ENV)
        self.assertIn("inboxes.jsp?to=new-review", notes)
        self.assertNotIn("old-review", notes)

    def test_render_refuses_missing_review_information(self):
        with self.assertRaises(pkg.PackageError) as raised:
            pkg.render_notes(self.TEMPLATE, {**self.DETAIL, "contactEmail": ""}, LIVE_ENV)
        self.assertIn("REVIEW_CONTACT_EMAIL", str(raised.exception))

    def test_render_refuses_an_unset_review_chief(self):
        with self.assertRaises(pkg.PackageError) as raised:
            pkg.render_notes(self.TEMPLATE, self.DETAIL, {"CMUX_IOS_REVIEW_CHIEF_NAME": "  "})
        self.assertIn("CMUX_IOS_REVIEW_CHIEF_NAME", str(raised.exception))

    def test_render_refuses_a_placeholder_with_no_source(self):
        with self.assertRaises(pkg.PackageError) as raised:
            pkg.render_notes(self.TEMPLATE + "\n{{REVIEW_MAC_HOST}}\n", self.DETAIL, LIVE_ENV)
        self.assertIn("REVIEW_MAC_HOST", str(raised.exception))

    def test_a_placeholder_only_in_a_comment_line_needs_no_value(self):
        notes = pkg.render_notes("## {{REVIEW_MAC_HOST}}\nHello\n", self.DETAIL, LIVE_ENV)
        self.assertEqual(notes, "Hello\n")

    def test_sync_writes_once_then_is_a_no_op(self):
        fake = self.start(notes="old notes with a Tailscale fallback")
        api = pkg.Api()
        self.assertTrue(pkg.sync_notes(api, APP, VERSION, pkg.DEFAULT_NOTES_TEMPLATE, dry_run=False))
        self.assertIn("Chief", fake.detail["notes"])
        self.assertNotIn("Tailscale", fake.detail["notes"])
        self.assertFalse(pkg.sync_notes(api, APP, VERSION, pkg.DEFAULT_NOTES_TEMPLATE, dry_run=False))
        self.assertEqual(len(self.writes(fake, "PATCH")), 1)

    def test_sync_without_the_review_chief_writes_nothing(self):
        fake = self.start(env={}, notes="old notes")
        with self.assertRaises(pkg.PackageError):
            pkg.sync_notes(pkg.Api(), APP, VERSION, pkg.DEFAULT_NOTES_TEMPLATE, dry_run=False)
        self.assertEqual(self.writes(fake, "PATCH"), [])
        self.assertEqual(fake.detail["notes"], "old notes")

    def test_dry_run_reports_without_writing(self):
        fake = self.start(notes="old notes")
        self.assertTrue(pkg.sync_notes(pkg.Api(), APP, VERSION, pkg.DEFAULT_NOTES_TEMPLATE, dry_run=True))
        self.assertEqual(self.writes(fake, "PATCH"), [])


class ListingTests(FakeAscCase):
    def sync(self, dry_run=False):
        return pkg.sync_listing(pkg.Api(), APP, VERSION, LISTING, dry_run=dry_run)

    def test_the_listing_in_git_uses_the_support_page(self):
        self.assertEqual(LISTING["supportUrl"], SUPPORT)

    def test_every_store_locale_in_git_uses_the_support_page(self):
        paths = sorted((pkg.VERSION_METADATA_DIR / VERSION).glob("*.json"))
        self.assertEqual(len(paths), len(listing_text.PRODUCTION_LOCALES))
        for path in paths:
            self.assertEqual(json.loads(path.read_text(encoding="utf-8")).get("supportUrl"), SUPPORT, path)

    def test_a_locale_on_the_home_page_is_rewritten_and_read_back(self):
        fake = self.start(locales={"en-US": SUPPORT, "ja": "https://cmux.com", "de-DE": None})
        self.assertEqual(self.sync(), [])
        self.assertEqual(set(fake.locales.values()), {SUPPORT})
        self.assertEqual(len(self.writes(fake, "PATCH")), 2)

    def test_matching_locales_make_no_write(self):
        fake = self.start(locales={"en-US": SUPPORT, "fr-FR": SUPPORT})
        self.assertEqual(self.sync(), [])
        self.assertEqual(self.writes(fake, "PATCH"), [])

    def test_a_locale_that_keeps_the_wrong_url_fails(self):
        self.start(locales={"en-US": SUPPORT, "ko": "https://cmux.com"}, sticky={"ko"})
        wrong = self.sync()
        self.assertEqual(len(wrong), 1)
        self.assertIn("ko", wrong[0])

    def test_dry_run_reports_without_writing(self):
        fake = self.start(locales={"en-US": "https://cmux.com"})
        self.assertEqual(len(self.sync(dry_run=True)), 1)
        self.assertEqual(self.writes(fake, "PATCH"), [])


class ApiTests(unittest.TestCase):
    def test_a_test_base_url_off_loopback_is_refused(self):
        old = os.environ.get("CMUX_ASC_API_BASE_URL")
        os.environ["CMUX_ASC_API_BASE_URL"] = "https://example.com"
        self.addCleanup(lambda: os.environ.pop("CMUX_ASC_API_BASE_URL") if old is None
                        else os.environ.__setitem__("CMUX_ASC_API_BASE_URL", old))
        with self.assertRaises(pkg.PackageError):
            pkg.Api()

    def test_a_missing_key_names_what_to_set(self):
        names = ("ASC_API_KEY_ID", "ASC_KEY_ID", "ASC_API_ISSUER_ID", "ASC_ISSUER_ID", "ASC_API_KEY_PATH",
                 "ASC_PRIVATE_KEY_PATH", "ASC_API_KEY_P8_BASE64")
        old = {name: os.environ.pop(name, None) for name in names}
        self.addCleanup(lambda: [os.environ.__setitem__(k, v) for k, v in old.items() if v is not None])
        with self.assertRaises(pkg.PackageError) as raised:
            pkg.asc_token()
        self.assertIn("ASC_API_KEY_ID", str(raised.exception))

    def test_der_signatures_become_raw_r_and_s(self):
        der = bytes([0x30, 0x08, 0x02, 0x02, 0x00, 0x81, 0x02, 0x02, 0x01, 0x02])
        raw = pkg._der_to_raw(der)
        self.assertEqual(len(raw), 64)
        self.assertEqual(raw[31], 0x81)
        self.assertEqual(raw[62:], b"\x01\x02")

    def test_the_default_version_is_project_yml_marketing_version(self):
        text = (ROOT / "cmux-next-ios/project.yml").read_text(encoding="utf-8")
        self.assertIn(f"MARKETING_VERSION: {VERSION}", text)


class CheckoutTests(unittest.TestCase):
    """A workflow on another branch runs the script from a feat-cmux-next checkout at any path."""

    def test_runs_from_a_copied_checkout_in_another_directory(self):
        fake = FakeAsc(locales={"en-US": SUPPORT, "it": "https://cmux.com"})
        self.addCleanup(fake.close)
        with tempfile.TemporaryDirectory() as tmp:
            checkout = Path(tmp) / "next-checkout" / "cmux-next-ios"
            shutil.copytree(SCRIPT.parent, checkout / "scripts", ignore=shutil.ignore_patterns("host", "*.swift", "*.sh"))
            shutil.copytree(ROOT / "cmux-next-ios/AppStoreReview", checkout / "AppStoreReview")
            shutil.copy(ROOT / "cmux-next-ios/project.yml", checkout / "project.yml")
            env = {k: v for k, v in os.environ.items() if not k.startswith("ASC_")}
            env.update(fake_env(fake, LIVE_ENV))
            script = checkout / "scripts" / "asc_review_package.py"
            for command in ("sync-listing", "sync-notes"):
                result = subprocess.run([sys.executable, "-I", str(script), "--app", APP, command],
                                        cwd=tmp, env=env, capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(set(fake.locales.values()), {SUPPORT})
        self.assertIn("Review path (no Mac needed):", fake.detail["notes"])


if __name__ == "__main__":
    unittest.main()
