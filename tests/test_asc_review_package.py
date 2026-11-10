#!/usr/bin/env python3
"""Tests for ios/scripts/asc_review_package.py against a loopback App Store Connect."""

from __future__ import annotations

import hashlib
import http.server
import json
import os
import sys
import tempfile
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ios" / "scripts"))
import asc_review_package as pkg  # noqa: E402

REVIEW_DIR = ROOT / "ios" / "AppStoreReview"
APP = "6783338052"
LISTING = pkg.version_listing("1.0.0")
SUBS = {
    "com.cmux.app.max.monthly": "6818444182",
    "com.cmux.app.pro.monthly": "6818444960",
    "com.cmux.app.go.monthly": "6818445194",
    "com.cmux.app.pro.trial.monthly": "6822947304",
}

# The strict report of run 42786056399 (build 20261110092522), the run that
# stopped before its submit step on these findings.
RUN_42786056399_REPORT = {
    "appId": APP,
    "versionString": "1.0.0",
    "strict": True,
    "checks": [
        {"id": "subscriptions.images.recommended", "severity": "warning", "resourceType": "subscription",
         "resourceId": SUBS["com.cmux.app.pro.trial.monthly"],
         "message": 'Subscription "Pro Monthly Trial" (com.cmux.app.pro.trial.monthly) has no subscription promotional image'},
        {"id": "subscriptions.review_readiness.needs_attention", "severity": "warning", "resourceType": "subscription",
         "resourceId": SUBS["com.cmux.app.go.monthly"],
         "message": 'Subscription "Go Monthly" (com.cmux.app.go.monthly) is READY_TO_SUBMIT'},
        {"id": "subscriptions.review_readiness.needs_attention", "severity": "warning", "resourceType": "subscription",
         "resourceId": SUBS["com.cmux.app.max.monthly"],
         "message": 'Subscription "Max Monthly" (com.cmux.app.max.monthly) is READY_TO_SUBMIT'},
        {"id": "subscriptions.review_readiness.needs_attention", "severity": "warning", "resourceType": "subscription",
         "resourceId": SUBS["com.cmux.app.pro.monthly"],
         "message": 'Subscription "Pro Monthly" (com.cmux.app.pro.monthly) is READY_TO_SUBMIT'},
        {"id": "subscriptions.review_readiness.needs_attention", "severity": "warning", "resourceType": "subscription",
         "resourceId": f"subscription:{SUBS['com.cmux.app.pro.trial.monthly']}",
         "message": 'Subscription "Pro Monthly Trial" (com.cmux.app.pro.trial.monthly) is READY_TO_SUBMIT'},
        {"id": "release.type_manual", "severity": "info", "message": "Release type is MANUAL"},
        {"id": "privacy.publish_state.unverified", "severity": "info", "message": "App Privacy publish state is not verifiable"},
    ],
}


class FakeAsc:
    """A loopback App Store Connect with just the endpoints the package uses."""

    def __init__(self, states=None, notes="", images=None, detail=None, locales=None, sticky=(), descriptions=None):
        self.locales = dict(locales or {"en-US": "https://cmux.com/support"})
        self.descriptions = dict(descriptions or {})
        self.sticky = set(sticky)  # locales whose supportUrl writes do not take
        self.states = dict(states or {p: "READY_TO_SUBMIT" for p in SUBS})
        self.detail = detail if detail is not None else {
            "demoAccountName": "cmux-review@mailinator.com",
            "contactEmail": "review-contact@example.com",
            "contactPhone": "+1 555 0100",
            "notes": notes,
        }
        self.images = dict(images or {})
        self.requests: list[tuple[str, str, dict]] = []
        self.uploaded: list[bytes] = []
        self.cancelled: list[str] = []
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

            def _body(self):
                length = int(self.headers.get("Content-Length") or 0)
                return self.rfile.read(length) if length else b""

            def do_GET(self):
                fake.requests.append(("GET", self.path, {}))
                self._send(*fake.get(self.path.split("?")[0]))

            def do_POST(self):
                body = json.loads(self._body() or b"{}")
                fake.requests.append(("POST", self.path, body))
                self._send(*fake.post(self.path, body))

            def do_PATCH(self):
                body = json.loads(self._body() or b"{}")
                fake.requests.append(("PATCH", self.path, body))
                self._send(*fake.patch(self.path, body))

            def do_PUT(self):
                fake.uploaded.append(self._body())
                fake.requests.append(("PUT", self.path, {}))
                self._send(200, {})

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
                {"id": f"loc-{locale}", "attributes": {
                    "locale": locale, "supportUrl": url, "description": self.descriptions.get(locale, LISTING["description"]),
                }}
                for locale, url in self.locales.items()
            ]}
        if path == "/v1/appStoreVersions/version-1/appStoreReviewDetail":
            return 200, {"data": {"id": "detail-1", "attributes": self.detail}}
        if path == "/v1/subscriptionGroups/22433557/subscriptions":
            return 200, {"data": [
                {"id": sid, "attributes": {"productId": product, "state": self.states[product]}}
                for product, sid in SUBS.items()
            ]}
        if path.startswith("/v1/subscriptions/") and path.endswith("/images"):
            sid = path.split("/")[3]
            return 200, {"data": self.images.get(sid, [])}
        if path == f"/v1/apps/{APP}/reviewSubmissions":
            return 200, {"data": [{"id": "submission-1"}]}
        return 404, {"errors": [{"code": "NOT_FOUND"}]}

    def post(self, path, body):
        if path == "/v1/subscriptionImages":
            size = body["data"]["attributes"]["fileSize"]
            return 201, {"data": {"id": "image-1", "attributes": {"uploadOperations": [
                {"method": "PUT", "url": self.url + "/upload/image-1", "offset": 0, "length": size,
                 "requestHeaders": [{"name": "Content-Type", "value": "image/png"}]},
            ]}}}
        return 404, {"errors": [{"code": "NOT_FOUND"}]}

    def patch(self, path, body):
        if path.startswith("/v1/appStoreVersionLocalizations/loc-"):
            locale = path.rsplit("loc-", 1)[1]
            attrs = body["data"]["attributes"]
            if locale not in self.sticky:
                self.locales[locale] = attrs.get("supportUrl", self.locales[locale])
                if "description" in attrs:
                    self.descriptions[locale] = attrs["description"]
            return 200, {"data": {"id": f"loc-{locale}"}}
        if path == "/v1/appStoreReviewDetails/detail-1":
            self.detail["notes"] = body["data"]["attributes"]["notes"]
            return 200, {"data": {"id": "detail-1"}}
        if path == "/v1/subscriptionImages/image-1":
            return 200, {"data": {"id": "image-1"}}
        if path == "/v1/reviewSubmissions/submission-1":
            self.cancelled.append("submission-1")
            return 200, {"data": {"id": "submission-1"}}
        return 404, {"errors": [{"code": "NOT_FOUND"}]}


class FakeAscCase(unittest.TestCase):
    def start(self, **kwargs) -> FakeAsc:
        fake = FakeAsc(**kwargs)
        self.addCleanup(fake.close)
        env = {"CMUX_ASC_API_BASE_URL": fake.url, "CMUX_ASC_TEST_TOKEN": "test-token", "ASC_TIMEOUT_SECONDS": "5"}
        old = {key: os.environ.get(key) for key in env}
        os.environ.update(env)
        self.addCleanup(lambda: [os.environ.pop(k) if v is None else os.environ.__setitem__(k, v) for k, v in old.items()])
        return fake

    def writes(self, fake, method):
        return [r for r in fake.requests if r[0] == method]


class ManifestTests(unittest.TestCase):
    def test_manifest_submits_only_products_the_review_account_sees(self):
        manifest = pkg.load_manifest(pkg.DEFAULT_MANIFEST)
        self.assertEqual(set(manifest["submit_with_version"]), {"com.cmux.app.pro.monthly", "com.cmux.app.max.monthly"})
        self.assertEqual(
            set(manifest["not_in_this_version"]), {"com.cmux.app.go.monthly", "com.cmux.app.pro.trial.monthly"}
        )

    def test_promotional_images_are_1024_png_named_by_product(self):
        manifest = pkg.load_manifest(pkg.DEFAULT_MANIFEST)
        known = set(manifest["submit_with_version"]) | set(manifest["not_in_this_version"])
        images = sorted(pkg.DEFAULT_IMAGES_DIR.glob("*.png"))
        self.assertTrue(images)
        for path in images:
            self.assertIn(path.stem, known)
            self.assertEqual(pkg.png_size(path.read_bytes()), (1024, 1024), path.name)


class GateTests(FakeAscCase):
    def run_gate(self, report, strict=True):
        fake = self.start()
        api = pkg.Api()
        manifest = pkg.load_manifest(pkg.DEFAULT_MANIFEST)
        return pkg.gate([report], manifest, lambda: pkg.subscriptions(api, manifest["group_id"]), strict)

    def test_run_42786056399_findings_are_all_explained(self):
        self.assertEqual(self.run_gate(RUN_42786056399_REPORT), [])

    def test_an_unexplained_warning_still_blocks_in_strict_mode(self):
        report = json.loads(json.dumps(RUN_42786056399_REPORT))
        report["checks"].append({"id": "screenshots.missing", "severity": "warning", "message": "no iPad screenshots"})
        self.assertEqual(self.run_gate(report), ["screenshots.missing: no iPad screenshots"])

    def test_a_submitted_product_without_a_promotional_image_blocks(self):
        report = {"strict": True, "checks": [{
            "id": "subscriptions.images.recommended", "severity": "warning",
            "resourceId": SUBS["com.cmux.app.pro.monthly"], "message": "Pro Monthly has no promotional image",
        }]}
        self.assertEqual(len(self.run_gate(report)), 1)

    def test_a_submitted_product_in_another_state_blocks(self):
        report = {"strict": True, "checks": [{
            "id": "subscriptions.review_readiness.needs_attention", "severity": "warning",
            "resourceId": SUBS["com.cmux.app.max.monthly"], "message": "Max Monthly is MISSING_METADATA",
        }]}
        self.assertEqual(len(self.run_gate(report)), 1)

    def test_errors_block_without_strict_and_warnings_do_not(self):
        report = {"checks": [
            {"id": "metadata.missing", "severity": "error", "message": "no description"},
            {"id": "screenshots.missing", "severity": "warning", "message": "no iPad screenshots"},
        ]}
        self.assertEqual(self.run_gate(report, strict=False), ["metadata.missing: no description"])

    def test_a_report_with_null_checks_is_clean(self):
        self.assertEqual(self.run_gate({"summary": {"blocking": 0}, "checks": None}), [])

    def test_a_report_without_checks_fails_closed(self):
        with self.assertRaises(pkg.PackageError):
            self.run_gate({"error": "unauthorized"})


class NotesTests(FakeAscCase):
    TEMPLATE = pkg.DEFAULT_NOTES_TEMPLATE.read_text(encoding="utf-8")

    def test_template_matches_the_app(self):
        for phrase in ("Tailscale", "Add Computer", "Host:", "Port:", "prepared review Mac"):
            self.assertNotIn(phrase, self.TEMPLATE)
        for phrase in ("Demo Mac", "Your Mac is connected", "Open Workspaces", "Settings > Account > Plan", "Email me a code"):
            self.assertIn(phrase, self.TEMPLATE)
        self.assertNotIn("Go", [word.strip(",.") for word in self.TEMPLATE.split()])

    def test_render_fills_live_values_and_derives_the_public_inbox(self):
        notes = pkg.render_notes(self.TEMPLATE, {
            "demoAccountName": "cmux-review@mailinator.com",
            "contactEmail": "review-contact@example.com",
            "contactPhone": "+1 555 0100",
        })
        self.assertNotIn("{{", notes)
        self.assertIn("https://www.mailinator.com/v4/public/inboxes.jsp?to=cmux-review", notes)
        self.assertLessEqual(len(notes), pkg.NOTES_LIMIT)

    def test_render_keeps_the_inbox_url_already_in_app_store_connect(self):
        notes = pkg.render_notes(self.TEMPLATE, {
            "demoAccountName": "reviewer@example.com",
            "contactEmail": "c@example.com",
            "contactPhone": "1",
            "notes": "old notes: https://www.mailinator.com/v4/public/inboxes.jsp?to=reviewer.",
        })
        self.assertIn("https://www.mailinator.com/v4/public/inboxes.jsp?to=reviewer\n", notes.replace(" (no", "\n"))

    def test_render_refuses_missing_review_information(self):
        with self.assertRaises(pkg.PackageError):
            pkg.render_notes(self.TEMPLATE, {"demoAccountName": "x@mailinator.com", "contactEmail": "", "contactPhone": "1"})

    def test_sync_writes_once_then_is_a_no_op(self):
        fake = self.start(notes="old notes with a Tailscale fallback")
        api = pkg.Api()
        self.assertTrue(pkg.sync_notes(api, APP, "1.0.0", pkg.DEFAULT_NOTES_TEMPLATE, dry_run=False))
        self.assertIn("Demo Mac", fake.detail["notes"])
        self.assertNotIn("Tailscale", fake.detail["notes"])
        self.assertFalse(pkg.sync_notes(api, APP, "1.0.0", pkg.DEFAULT_NOTES_TEMPLATE, dry_run=False))
        self.assertEqual(len(self.writes(fake, "PATCH")), 1)


class ListingTests(FakeAscCase):
    URL = "https://cmux.com/support"
    BANNED = ["cmux Go"]

    def sync(self, dry_run=False):
        return pkg.sync_listing(pkg.Api(), APP, "1.0.0", LISTING, self.BANNED, dry_run=dry_run)

    def test_the_listing_in_git_uses_the_support_page_and_names_only_offered_plans(self):
        self.assertEqual(LISTING["supportUrl"], self.URL)
        manifest = pkg.load_manifest(pkg.DEFAULT_MANIFEST)
        self.assertEqual(sorted(manifest["listing_must_not_name"]), self.BANNED)
        for name in self.BANNED:
            self.assertNotIn(name.casefold(), LISTING["description"].casefold())
        self.assertIn("cmux Pro and cmux Max", LISTING["description"])

    def test_every_store_locale_in_git_uses_the_support_page(self):
        for path in sorted((pkg.IOS_DIR / "fastlane" / "metadata").glob("*/support_url.txt")):
            self.assertEqual(path.read_text(encoding="utf-8").strip(), self.URL, path)

    def test_a_locale_on_the_home_page_is_rewritten_and_read_back(self):
        fake = self.start(locales={"en-US": self.URL, "ja": "https://cmux.com", "de-DE": None})
        self.assertEqual(self.sync(), [])
        self.assertEqual(set(fake.locales.values()), {self.URL})
        self.assertEqual(len(self.writes(fake, "PATCH")), 2)

    def test_the_en_us_description_naming_go_is_rewritten(self):
        old = "cmux Go, Pro, and Max are optional monthly subscriptions."
        fake = self.start(descriptions={"en-US": old})
        self.assertEqual(self.sync(), [])
        self.assertEqual(fake.descriptions["en-US"], LISTING["description"])

    def test_another_locale_naming_go_fails(self):
        self.start(locales={"en-US": self.URL, "fr-FR": self.URL}, descriptions={"fr-FR": "cmux Go, Pro et Max"})
        wrong = self.sync()
        self.assertEqual(len(wrong), 1)
        self.assertIn("fr-FR description names cmux Go", wrong[0])

    def test_matching_locales_make_no_write(self):
        fake = self.start(locales={"en-US": self.URL, "fr-FR": self.URL})
        self.assertEqual(self.sync(), [])
        self.assertEqual(self.writes(fake, "PATCH"), [])

    def test_a_locale_that_keeps_the_wrong_url_fails(self):
        self.start(locales={"en-US": self.URL, "ko": "https://cmux.com"}, sticky={"ko"})
        wrong = self.sync()
        self.assertEqual(len(wrong), 1)
        self.assertIn("ko", wrong[0])

    def test_dry_run_reports_without_writing(self):
        fake = self.start(locales={"en-US": "https://cmux.com"}, descriptions={"en-US": "old"})
        self.assertEqual(len(self.sync(dry_run=True)), 2)
        self.assertEqual(self.writes(fake, "PATCH"), [])

    def test_a_short_banned_name_is_refused(self):
        bad = Path(tempfile.mkdtemp()) / "subscriptions.json"
        manifest = json.loads(pkg.DEFAULT_MANIFEST.read_text(encoding="utf-8"))
        manifest["listing_must_not_name"] = {"Go": "too short, matches any text"}
        bad.write_text(json.dumps(manifest), encoding="utf-8")
        with self.assertRaises(pkg.PackageError):
            pkg.load_manifest(bad)


class ImageTests(FakeAscCase):
    def test_upload_reserves_puts_and_commits_with_checksum(self):
        fake = self.start()
        manifest = pkg.load_manifest(pkg.DEFAULT_MANIFEST)
        uploaded = pkg.upload_images(pkg.Api(), manifest, pkg.DEFAULT_IMAGES_DIR)
        self.assertEqual(uploaded, ["com.cmux.app.pro.trial.monthly"])
        data = (pkg.DEFAULT_IMAGES_DIR / "com.cmux.app.pro.trial.monthly.png").read_bytes()
        self.assertEqual(fake.uploaded, [data])
        reserve = next(r for r in fake.requests if r[0] == "POST")
        self.assertEqual(reserve[2]["data"]["relationships"]["subscription"]["data"]["id"], SUBS["com.cmux.app.pro.trial.monthly"])
        commit = next(r for r in fake.requests if r[0] == "PATCH")
        self.assertEqual(commit[2]["data"]["attributes"], {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()})

    def test_upload_skips_a_product_that_has_an_image(self):
        fake = self.start(images={SUBS["com.cmux.app.pro.trial.monthly"]: [{"id": "existing"}]})
        manifest = pkg.load_manifest(pkg.DEFAULT_MANIFEST)
        self.assertEqual(pkg.upload_images(pkg.Api(), manifest, pkg.DEFAULT_IMAGES_DIR), [])
        self.assertEqual(self.writes(fake, "POST"), [])


class VerifySubmissionTests(FakeAscCase):
    def verify(self, states):
        fake = self.start(states=states)
        manifest = pkg.load_manifest(pkg.DEFAULT_MANIFEST)
        return fake, pkg.verify_submission(pkg.Api(), APP, manifest, wait_seconds=0, cancel=True)

    def test_exactly_the_manifest_in_review_passes(self):
        fake, problems = self.verify({
            "com.cmux.app.pro.monthly": "WAITING_FOR_REVIEW", "com.cmux.app.max.monthly": "WAITING_FOR_REVIEW",
            "com.cmux.app.go.monthly": "READY_TO_SUBMIT", "com.cmux.app.pro.trial.monthly": "READY_TO_SUBMIT",
        })
        self.assertEqual(problems, [])
        self.assertEqual(fake.cancelled, [])

    def test_a_subscription_left_behind_cancels_the_submission(self):
        fake, problems = self.verify({
            "com.cmux.app.pro.monthly": "WAITING_FOR_REVIEW", "com.cmux.app.max.monthly": "READY_TO_SUBMIT",
            "com.cmux.app.go.monthly": "READY_TO_SUBMIT", "com.cmux.app.pro.trial.monthly": "READY_TO_SUBMIT",
        })
        self.assertEqual(len(problems), 1)
        self.assertEqual(fake.cancelled, ["submission-1"])

    def test_a_product_the_app_does_not_offer_in_review_cancels_the_submission(self):
        fake, problems = self.verify({
            "com.cmux.app.pro.monthly": "WAITING_FOR_REVIEW", "com.cmux.app.max.monthly": "WAITING_FOR_REVIEW",
            "com.cmux.app.go.monthly": "WAITING_FOR_REVIEW", "com.cmux.app.pro.trial.monthly": "READY_TO_SUBMIT",
        })
        self.assertEqual(len(problems), 1)
        self.assertEqual(fake.cancelled, ["submission-1"])


if __name__ == "__main__":
    unittest.main()
