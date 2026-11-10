#!/usr/bin/env python3
"""Offline tests for ios/scripts/check_app_store_urls.py (fetch is injected)."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "ios/scripts/check_app_store_urls.py"


def load():
    spec = importlib.util.spec_from_file_location("check_app_store_urls", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


M = load()


def fixture(root: Path, fastlane: dict[str, dict[str, str]], review: dict[str, dict]) -> tuple[Path, Path]:
    fastlane_dir = root / "fastlane"
    review_dir = root / "review"
    for locale, files in fastlane.items():
        (fastlane_dir / locale).mkdir(parents=True)
        for name, value in files.items():
            (fastlane_dir / locale / name).write_text(value + "\n")
    for rel, body in review.items():
        path = review_dir / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(body))
    return fastlane_dir, review_dir


def ok_fetch(url):
    return 200, url


class CollectTests(unittest.TestCase):
    def test_reads_fastlane_and_review_metadata(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fl, rv = fixture(
                root,
                {"en-US": {"support_url.txt": "https://cmux.com/support", "marketing_url.txt": "https://cmux.com"}},
                {
                    "app-info/en-US.json": {"name": "cmux", "privacyPolicyUrl": "https://cmux.com/privacy-policy"},
                    "version/1.0.0/en-US.json": {"supportUrl": "https://cmux.com/support", "marketingUrl": ""},
                },
            )
            urls, problems = M.collect_urls(fl, rv, root)
        self.assertEqual(problems, [])
        self.assertEqual(
            sorted((u.kind, u.url) for u in urls),
            [
                ("marketing", "https://cmux.com"),
                ("privacy", "https://cmux.com/privacy-policy"),
                ("support", "https://cmux.com/support"),
                ("support", "https://cmux.com/support"),
            ],
        )

    def test_locale_without_support_url_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fl, rv = fixture(root, {"ja": {"marketing_url.txt": "https://cmux.com"}}, {})
            _, problems = M.collect_urls(fl, rv, root)
        self.assertEqual(len(problems), 1)
        self.assertIn("no support_url.txt", problems[0])


class StaticRuleTests(unittest.TestCase):
    def item(self, url, kind="support"):
        return M.ListingUrl("x", kind, url)

    def test_bare_home_page_is_not_a_support_url(self):
        for url in ("https://cmux.com", "https://cmux.com/", "https://CMUX.com/"):
            with self.subTest(url=url):
                problems = M.check([self.item(url)], ok_fetch)
                self.assertEqual(len(problems), 1)
                self.assertIn("home page", problems[0])

    def test_home_page_is_fine_as_marketing_url(self):
        self.assertEqual(M.check([self.item("https://cmux.com", "marketing")], ok_fetch), [])

    def test_urls_off_cmux_com_fail(self):
        for url in (
            "http://cmux.com/support",
            "https://www.cmux.com/support",
            "https://cmux.dev/support",
            "https://github.com/manaflow-ai/cmux",
            "https://cmux.com.evil.example/support",
            "https://cmux.com:8443/support",
            "cmux.com/support",
        ):
            with self.subTest(url=url):
                problems = M.check([self.item(url, "privacy")], ok_fetch)
                self.assertEqual(len(problems), 1)
                self.assertIn("not under https://cmux.com/", problems[0])

    def test_static_failures_are_not_fetched(self):
        calls = []
        M.check([self.item("https://cmux.com")], lambda u: calls.append(u) or (200, u))
        self.assertEqual(calls, [])


class FetchRuleTests(unittest.TestCase):
    def run_check(self, fetch, url="https://cmux.com/support", kind="support"):
        return M.check([M.ListingUrl("f", kind, url)], fetch, sleep=lambda s: None)

    def test_200_passes(self):
        self.assertEqual(self.run_check(ok_fetch), [])

    def test_non_200_fails_after_two_tries(self):
        calls = []

        def fetch(url):
            calls.append(url)
            return 404, url

        problems = self.run_check(fetch)
        self.assertEqual(len(calls), 2)
        self.assertEqual(len(problems), 1)
        self.assertIn("HTTP 404", problems[0])

    def test_network_error_fails(self):
        def fetch(url):
            raise urllib.error.URLError("timed out")

        problems = self.run_check(fetch)
        self.assertEqual(len(problems), 1)
        self.assertIn("timed out", problems[0])

    def test_second_try_can_pass(self):
        answers = iter([TimeoutError("slow"), (200, "https://cmux.com/support")])

        def fetch(url):
            answer = next(answers)
            if isinstance(answer, Exception):
                raise answer
            return answer

        self.assertEqual(self.run_check(fetch), [])

    def test_support_url_redirecting_to_home_page_fails(self):
        problems = self.run_check(lambda u: (200, "https://cmux.com/"))
        self.assertEqual(len(problems), 1)
        self.assertIn("redirects to the home page", problems[0])

    def test_redirect_off_cmux_com_fails(self):
        problems = self.run_check(lambda u: (200, "https://example.com/"), kind="privacy",
                                  url="https://cmux.com/privacy-policy")
        self.assertEqual(len(problems), 1)
        self.assertIn("redirects off cmux.com", problems[0])

    def test_each_distinct_url_is_fetched_once(self):
        calls = []
        items = [M.ListingUrl(f"f{i}", "support", "https://cmux.com/support") for i in range(14)]
        M.check(items, lambda u: calls.append(u) or (200, u))
        self.assertEqual(calls, ["https://cmux.com/support"])


class RepositoryMetadataTests(unittest.TestCase):
    def test_checked_in_listing_urls_pass_the_static_rules(self):
        """Every locale's support URL is a real support page under cmux.com (no live fetch)."""
        urls, problems = M.collect_urls()
        self.assertGreater(len(urls), 0)
        problems += M.check(urls, None)
        self.assertEqual(problems, [])


if __name__ == "__main__":
    unittest.main()
