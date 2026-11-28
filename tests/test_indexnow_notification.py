#!/usr/bin/env python3
import importlib.util
import io
import json
from pathlib import Path
import sys
import unittest
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
        workflow = (ROOT / ".github/workflows/indexnow.yml").read_text()
        self.assertNotIn("secrets.", workflow)
        self.assertNotIn("api/cron/indexnow", workflow)
        self.assertIn("web/app/lib/indexnow.ts", workflow)
        self.assertIn("scripts/ci/notify-indexnow.py", workflow)
        self.assertIn("timeout-minutes: 6", workflow)
        self.assertIn("ref: ${{ github.event.deployment.sha || github.sha }}", workflow)

if __name__ == "__main__":
    unittest.main()
