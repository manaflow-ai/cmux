#!/usr/bin/env python3
import importlib.util
import io
import json
from pathlib import Path
import sys
import unittest
import tempfile
from unittest.mock import patch
import urllib.error
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("notify_indexnow", ROOT / "scripts/ci/notify-indexnow.py")
notify = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = notify
spec.loader.exec_module(notify)
KEY = "a" * 32
CONFIG = {"key": KEY, "endpoint": "https://api.indexnow.org/indexnow", "lookbackHours": 48}
XML = b'''<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
<url><loc>https://cmux.com/old</loc><lastmod>2026-01-01</lastmod></url>
<url><loc>https://cmux.com/new?a=1&amp;b=2</loc><lastmod>2026-03-03</lastmod></url>
<url><loc>https://cmux.com/recent</loc><lastmod>2026-03-02</lastmod></url>
<url><loc>https://cmux.com/new?a=1&amp;b=2</loc><lastmod>2026-03-03</lastmod></url>
<url><loc>https://cmux.com/future</loc><lastmod>2099-01-01</lastmod></url>
<url><loc>https://cmux.com/bad-date</loc><lastmod>oops</lastmod></url>
<url><loc>https://cmux.com/missing-date</loc></url>
</urlset>'''

class IndexNowTests(unittest.TestCase):
    def test_selects_live_recent_content_even_when_deployment_is_delayed(self):
        self.assertEqual(notify.select_urls(XML, 48, datetime(2026, 9, 17, tzinfo=timezone.utc)),
                         ["https://cmux.com/new?a=1&b=2", "https://cmux.com/recent"])

    def test_foreign_sitemap_urls_fail_before_submission(self):
        with self.assertRaises(ValueError):
            notify.select_urls(XML.replace(b"https://cmux.com/old", b"https://evil.example/old"), 48)

    def test_malformed_and_wrong_xml_root_fail(self):
        for data in (b"<urlset", b"<html>unavailable</html>", b"<sitemapindex/>"):
            with self.assertRaises(ValueError):
                notify.select_urls(data, 48)

    def test_public_key_and_live_sitemap_are_sufficient_without_cron_secret(self):
        with patch.object(notify, "request", side_effect=[(200, KEY.encode()), (200, XML), (202, b"")]) as request:
            result = notify.run(CONFIG)
        self.assertEqual(result, {"submitted": 2, "batches": 1, "status": 202})
        self.assertEqual(request.call_args_list[0].args[0], f"https://cmux.com/{KEY}.txt")
        self.assertEqual(request.call_args_list[1].args[0], "https://cmux.com/sitemap.xml")
        payload = json.loads(request.call_args_list[2].kwargs["data"])
        self.assertEqual(payload["key"], KEY)
        self.assertEqual(payload["host"], "cmux.com")
        self.assertEqual(len(payload["urlList"]), 2)
        self.assertNotIn("authorization", str(request.call_args_list).lower())

    def test_large_url_windows_are_submitted_in_indexnow_batches(self):
        urls = [f"https://cmux.com/page-{index}" for index in range(10_001)]
        with patch.object(notify, "request", side_effect=[(202, b""), (200, b"")]) as request:
            result = notify.submit_batches(CONFIG, urls)
        self.assertEqual(result, {"submitted": 10_001, "batches": 2, "status": 200})
        first = json.loads(request.call_args_list[0].kwargs["data"])
        second = json.loads(request.call_args_list[1].kwargs["data"])
        self.assertEqual(len(first["urlList"]), 10_000)
        self.assertEqual(len(second["urlList"]), 1)
        self.assertEqual(second["urlList"][0], urls[-1])

    def test_mismatched_deployed_key_prevents_post(self):
        with patch.object(notify, "request", return_value=(200, b"another-key")) as request:
            with self.assertRaisesRegex(ValueError, "key"):
                notify.run(CONFIG)
        self.assertEqual(request.call_count, 1)

    def test_permanent_http_errors_are_not_retried(self):
        error = urllib.error.HTTPError("https://example.test", 401, "Unauthorized", {}, io.BytesIO())
        with patch.object(notify.urllib.request, "urlopen", side_effect=error) as request:
            with self.assertRaises(urllib.error.HTTPError):
                notify.request("https://example.test")
        self.assertEqual(request.call_count, 1)

    def test_transient_http_errors_are_bounded(self):
        error = urllib.error.HTTPError("https://example.test", 503, "Unavailable", {}, io.BytesIO())
        with patch.object(notify.urllib.request, "urlopen", side_effect=error) as request, patch.object(notify.time, "sleep"):
            with self.assertRaises(urllib.error.HTTPError):
                notify.request("https://example.test")
        self.assertEqual(request.call_count, 3)
        self.assertEqual(request.call_args.kwargs["timeout"], 30)

    def test_empty_sitemap_does_not_post(self):
        with patch.object(notify, "request", side_effect=[(200, KEY.encode()), (200, b'<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"/>')]) as request:
            self.assertEqual(notify.run(CONFIG), {"submitted": 0, "status": 0})
        self.assertEqual(request.call_count, 2)

    def test_workflow_uses_public_shared_configuration_and_no_private_secret(self):
        workflow = (ROOT / ".github/workflows/indexnow-hourly.yml").read_text()
        self.assertNotIn("secrets.", workflow)
        self.assertNotIn("api/cron/indexnow", workflow)
        self.assertIn("web/app/lib/indexnow.ts", workflow)
        self.assertIn("scripts/ci/notify-indexnow.py", workflow)
        self.assertIn("timeout-minutes: 6", workflow)
        self.assertIn("ref: ${{ github.sha }}", workflow)

    def test_retire_legacy_workflow_filename_to_disable_old_identity(self):
        # deployment_status can execute the workflow file from an old PR ref.
        # The original workflow ID is retired after the replacement is active;
        # keeping the file on main would preserve the noisy legacy identity.
        self.assertFalse((ROOT / ".github/workflows/indexnow.yml").exists())
        self.assertTrue((ROOT / ".github/workflows/indexnow-hourly.yml").is_file())

    def test_workflow_is_scheduled_not_triggered_by_every_deployment_status(self):
        # deployment_status cannot be filtered at the trigger, so every Vercel
        # preview status started a skipped run. The schedule plus state marker
        # replaces it.
        workflow = (ROOT / ".github/workflows/indexnow-hourly.yml").read_text()
        triggers = workflow.split("\non:\n", 1)[1].split("\npermissions:", 1)[0]
        self.assertNotIn("deployment_status", triggers)
        self.assertIn("schedule:", triggers)
        self.assertIn("--state .indexnow-state/submitted.json", workflow)
        self.assertIn("actions/cache/restore@", workflow)
        self.assertIn("actions/cache/save@", workflow)
        self.assertIn("steps.submit.outputs.state_changed == 'true'", workflow)
        self.assertIn("shell: bash", workflow)

    def test_state_marker_submits_each_url_lastmod_pair_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state" / "submitted.json"
            with patch.object(notify, "request", side_effect=[(200, KEY.encode()), (200, XML), (202, b"")]):
                first = notify.run(CONFIG, state)
            self.assertEqual(first, {"submitted": 2, "batches": 1, "status": 202, "stateChanged": True})

            # Same sitemap an hour later: nothing new is posted and the marker is untouched.
            with patch.object(notify, "request", side_effect=[(200, KEY.encode()), (200, XML)]) as request:
                second = notify.run(CONFIG, state)
            self.assertEqual(second, {"submitted": 0, "status": 0})
            self.assertEqual(request.call_count, 2)

            # A page whose lastmod changes is sent again, and only that page.
            changed = XML.replace(b"<loc>https://cmux.com/recent</loc><lastmod>2026-03-02", b"<loc>https://cmux.com/recent</loc><lastmod>2026-03-04")
            with patch.object(notify, "request", side_effect=[(200, KEY.encode()), (200, changed), (200, b"")]) as request:
                third = notify.run(CONFIG, state)
            self.assertEqual(third["submitted"], 1)
            self.assertEqual(json.loads(request.call_args_list[2].kwargs["data"])["urlList"], ["https://cmux.com/recent"])

    def test_failed_submission_keeps_the_previous_marker(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "submitted.json"
            error = RuntimeError("IndexNow down")
            with patch.object(notify, "request", side_effect=[(200, KEY.encode()), (200, XML), error]):
                with self.assertRaises(RuntimeError):
                    notify.run(CONFIG, state)
            self.assertFalse(state.exists())

    def test_unreadable_marker_resubmits_instead_of_failing(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "submitted.json"
            state.write_text("not json")
            with patch.object(notify, "request", side_effect=[(200, KEY.encode()), (200, XML), (202, b"")]):
                result = notify.run(CONFIG, state)
            self.assertEqual(result["submitted"], 2)
            self.assertEqual(len(json.loads(state.read_text())["submitted"]), 2)

if __name__ == "__main__":
    unittest.main()
