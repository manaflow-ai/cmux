#!/usr/bin/env python3
"""Tests for ios/scripts/asc_review_package.py against a loopback App Store Connect."""

from __future__ import annotations

import http.server
import json
import os
import sys
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ios" / "scripts"))
import asc_review_package as pkg  # noqa: E402

APP = "6783338052"
LISTING = pkg.version_listing("1.0.0")
SUPPORT = "https://cmux.com/support"
LIVE_ENV = {"CMUX_IOS_REVIEW_CHIEF_NAME": "App Review"}
CHIEF_SOURCES = (
    ROOT / "ios/CmuxiOS/Sources/CmuxHomeUI/Support/HomeText.swift",
    ROOT / "ios/CmuxiOS/Sources/CmuxiOSAuth/SignIn/SignInView.swift",
    ROOT / "ios/CmuxiOS/Sources/CmuxiOSApp/ChatServerSettingsView.swift",
)


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
                self._send(*fake.get(self.path.split("?")[0]))

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

    def get(self, path):
        if path == f"/v1/apps/{APP}/appStoreVersions":
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


class FakeAscCase(unittest.TestCase):
    def start(self, env=None, **kwargs) -> FakeAsc:
        fake = FakeAsc(**kwargs)
        self.addCleanup(fake.close)
        values = {"CMUX_ASC_API_BASE_URL": fake.url, "CMUX_ASC_TEST_TOKEN": "test-token", "ASC_TIMEOUT_SECONDS": "5"}
        values.update(LIVE_ENV if env is None else env)
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

    def test_template_names_only_screens_this_app_has(self):
        # Classic screens and flows this app does not have.
        for phrase in (
            "Tailscale", "Add Computer", "Host:", "Port:", "Demo Mac", "Your Mac is connected",
            "Open Workspaces", "Settings > Account", "Subscription", "Plan", "In-App Purchase", "Delete Account",
            "Scan Pairing Code", "Connection Method",
        ):
            self.assertNotIn(phrase, self.TEMPLATE)
        # Every quoted control label in the notes is a string this app's source shows.
        source = "\n".join(path.read_text(encoding="utf-8") for path in CHIEF_SOURCES)
        for label in ("Email address", "Email me a code", "Check your email", "Verify code", "New Message",
                      "New Group", "New Chief", "Invite", "Chat Server", "cmux Cloud", "Self-Hosted"):
            self.assertIn(label, self.TEMPLATE)
            self.assertIn(f'"{label}"', source, label)

    def test_render_fills_live_values_and_derives_the_public_inbox(self):
        notes = pkg.render_notes(self.TEMPLATE, self.DETAIL, LIVE_ENV)
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

    def test_sync_writes_once_then_is_a_no_op(self):
        fake = self.start(notes="old notes with a Tailscale fallback")
        api = pkg.Api()
        self.assertTrue(pkg.sync_notes(api, APP, "1.0.0", pkg.DEFAULT_NOTES_TEMPLATE, dry_run=False))
        self.assertIn("Chief", fake.detail["notes"])
        self.assertNotIn("Tailscale", fake.detail["notes"])
        self.assertFalse(pkg.sync_notes(api, APP, "1.0.0", pkg.DEFAULT_NOTES_TEMPLATE, dry_run=False))
        self.assertEqual(len(self.writes(fake, "PATCH")), 1)

    def test_sync_without_the_review_chief_writes_nothing(self):
        fake = self.start(env={}, notes="old notes")
        with self.assertRaises(pkg.PackageError):
            pkg.sync_notes(pkg.Api(), APP, "1.0.0", pkg.DEFAULT_NOTES_TEMPLATE, dry_run=False)
        self.assertEqual(self.writes(fake, "PATCH"), [])
        self.assertEqual(fake.detail["notes"], "old notes")

    def test_dry_run_reports_without_writing(self):
        fake = self.start(notes="old notes")
        self.assertTrue(pkg.sync_notes(pkg.Api(), APP, "1.0.0", pkg.DEFAULT_NOTES_TEMPLATE, dry_run=True))
        self.assertEqual(self.writes(fake, "PATCH"), [])


class ListingTests(FakeAscCase):
    def sync(self, dry_run=False):
        return pkg.sync_listing(pkg.Api(), APP, "1.0.0", LISTING, dry_run=dry_run)

    def test_the_listing_in_git_uses_the_support_page(self):
        self.assertEqual(LISTING["supportUrl"], SUPPORT)

    def test_every_store_locale_in_git_uses_the_support_page(self):
        paths = sorted((pkg.IOS_DIR / "fastlane" / "metadata").glob("*/support_url.txt"))
        self.assertTrue(paths)
        for path in paths:
            self.assertEqual(path.read_text(encoding="utf-8").strip(), SUPPORT, path)

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


class WorkflowTests(unittest.TestCase):
    def test_the_app_store_workflow_syncs_before_the_readiness_gate(self):
        text = (ROOT / ".github/workflows/ios-app-store.yml").read_text(encoding="utf-8")
        sync = text.index("- name: Sync App Review notes and store listing")
        gate = text.index("- name: Validate App Store readiness")
        self.assertLess(sync, gate)
        step = text[sync:gate]
        self.assertIn("asc_review_package.py --app \"$ASC_APP_ID\" sync-notes", step)
        self.assertIn("asc_review_package.py --app \"$ASC_APP_ID\" sync-listing", step)
        self.assertIn("CMUX_IOS_REVIEW_CHIEF_NAME: ${{ vars.IOS_APPSTORE_REVIEW_CHIEF_NAME }}", step)


if __name__ == "__main__":
    unittest.main()
