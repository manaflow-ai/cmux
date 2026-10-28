#!/usr/bin/env python3
"""Stable Sparkle feed check (scripts/ci/verify_stable_feed.py).

v0.65.2.2 was published with 0 assets, so every releases/latest/download feed
URL 404ed and 0.65.2 installs showed "error retrieving update information"
(https://github.com/manaflow-ai/cmux/issues/26729). These cases pin what the
check refuses: a missing feed, a feed that does not parse, an unsigned or
empty feed, an enclosure that 404s, and one whose size disagrees.
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/ci/verify_stable_feed.py"
spec = importlib.util.spec_from_file_location("verify_stable_feed", SCRIPT)
feed = importlib.util.module_from_spec(spec)
sys.modules["verify_stable_feed"] = feed
spec.loader.exec_module(feed)

FEED_URL = "https://github.com/o/r/releases/latest/download/appcast.xml"
DMG = "https://github.com/o/r/releases/download/v1.2.3/cmux-macos.dmg"


def appcast(*enclosures: str) -> bytes:
    items = "".join(f"<item><title>1.2.3</title>{e}</item>" for e in enclosures)
    return (
        '<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" '
        f'version="2.0"><channel><title>cmux</title>{items}</channel></rss>'
    ).encode()


def enclosure(url=DMG, length="100", signature="c2ln") -> str:
    sig = f' sparkle:edSignature="{signature}"' if signature else ""
    return f'<enclosure url="{url}" length="{length}" type="application/octet-stream"{sig}/>'


class Server:
    """Answers GET and HEAD from a URL table; a missing URL is a 404."""

    def __init__(self, bodies=None, lengths=None, failures=None):
        self.bodies = bodies or {}
        self.lengths = lengths or {}
        self.failures = dict(failures or {})
        self.calls = []

    def _fail(self, url):
        queued = self.failures.get(url)
        if queued:
            raise feed.FetchError(queued.pop(0))

    def get(self, url):
        self.calls.append(("GET", url))
        self._fail(url)
        if url not in self.bodies:
            raise feed.FetchError("HTTP 404")
        return self.bodies[url]

    def head(self, url):
        self.calls.append(("HEAD", url))
        self._fail(url)
        if url not in self.lengths:
            raise feed.FetchError("HTTP 404")
        return self.lengths[url]


def quiet_main(argv):
    """main() prints ::error:: lines; keep them out of the CI run's annotations."""
    with contextlib.redirect_stdout(io.StringIO()):
        return feed.main(argv)


def check(server, attempts=1):
    return feed.check_feed(FEED_URL, attempts, get=server.get, content_length=server.head)


class VerifyStableFeedTests(unittest.TestCase):
    def setUp(self):
        self._sleep = feed.time.sleep
        feed.time.sleep = lambda _seconds: None

    def tearDown(self):
        feed.time.sleep = self._sleep

    def test_healthy_feed_passes(self):
        server = Server({FEED_URL: appcast(enclosure())}, {DMG: 100})
        self.assertEqual(check(server), [])

    def test_published_release_without_assets_fails(self):
        # The v0.65.2.2 state: latest/download/appcast.xml is a 404.
        problems = check(Server())
        self.assertEqual(problems, [f"{FEED_URL}: feed did not load (HTTP 404)"])

    def test_enclosure_that_404s_fails(self):
        # The R2 feed pointed at DMGs on the empty release.
        problems = check(Server({FEED_URL: appcast(enclosure())}))
        self.assertEqual(problems, [f"{FEED_URL}: {DMG} does not download (HTTP 404)"])

    def test_size_mismatch_fails(self):
        problems = check(Server({FEED_URL: appcast(enclosure())}, {DMG: 99}))
        self.assertIn("serves 99 bytes, the feed declares 100", problems[0])

    def test_missing_content_length_is_not_a_mismatch(self):
        server = Server({FEED_URL: appcast(enclosure())}, {DMG: None})
        self.assertEqual(check(server), [])

    def test_unsigned_enclosure_fails(self):
        problems = check(Server({FEED_URL: appcast(enclosure(signature=""))}, {DMG: 100}))
        self.assertEqual(problems, [f"{FEED_URL}: {DMG} has no sparkle:edSignature"])

    def test_feed_without_items_fails(self):
        problems = check(Server({FEED_URL: appcast()}))
        self.assertEqual(problems, [f"{FEED_URL}: feed lists no item with an enclosure"])

    def test_unparseable_feed_fails(self):
        problems = check(Server({FEED_URL: b"<html>Not Found"}))
        self.assertEqual(len(problems), 1)
        self.assertIn("does not parse as XML", problems[0])

    def test_every_enclosure_is_checked(self):
        arm = DMG.replace("cmux-macos.dmg", "cmux-macos-arm64.dmg")
        server = Server({FEED_URL: appcast(enclosure(), enclosure(url=arm, length="50"))}, {DMG: 100})
        self.assertEqual(check(server), [f"{FEED_URL}: {arm} does not download (HTTP 404)"])

    def test_transient_error_is_retried(self):
        server = Server({FEED_URL: appcast(enclosure())}, {DMG: 100},
                        failures={FEED_URL: ["HTTP 502"], DMG: ["connection reset"]})
        self.assertEqual(check(server, attempts=3), [])

    def test_404_is_not_retried(self):
        server = Server()
        check(server, attempts=3)
        self.assertEqual(server.calls, [("GET", FEED_URL)])

    def test_main_exits_nonzero_on_any_problem(self):
        original = feed.check_feed
        feed.check_feed = lambda url, attempts: [] if url.endswith("good.xml") else [f"{url}: bad"]
        try:
            self.assertEqual(quiet_main(["--feed", "https://x/good.xml"]), 0)
            self.assertEqual(quiet_main(["--feed", "https://x/good.xml", "--feed", "https://x/bad.xml"]), 1)
        finally:
            feed.check_feed = original

    def test_tag_adds_the_release_feeds(self):
        seen = []
        original = feed.check_feed
        feed.check_feed = lambda url, attempts: seen.append(url) or []
        try:
            self.assertEqual(quiet_main(["--feed", "https://x/a.xml", "--tag", "v1.2.3"]), 0)
        finally:
            feed.check_feed = original
        self.assertEqual(seen, ["https://x/a.xml"] + [
            f"https://github.com/manaflow-ai/cmux/releases/download/v1.2.3/{name}" for name in feed.FEED_NAMES])

    def test_settle_retries_a_404_until_it_clears(self):
        # GitHub serves a cached 404 for a just-uploaded asset for a few minutes.
        results = [["https://x/a.xml: feed did not load (HTTP 404)"], []]
        original, clock = feed.check_feed, feed.time.monotonic
        feed.check_feed = lambda url, attempts: results.pop(0)
        feed.time.monotonic = iter([0, 1]).__next__
        try:
            self.assertEqual(quiet_main(["--feed", "https://x/a.xml", "--settle-seconds", "60"]), 0)
        finally:
            feed.check_feed, feed.time.monotonic = original, clock
        self.assertEqual(results, [])

    def test_settle_gives_up_at_the_deadline(self):
        original, clock = feed.check_feed, feed.time.monotonic
        feed.check_feed = lambda url, attempts: [f"{url}: feed did not load (HTTP 404)"]
        feed.time.monotonic = iter([0, 30, 61]).__next__
        try:
            self.assertEqual(quiet_main(["--feed", "https://x/a.xml", "--settle-seconds", "60"]), 1)
        finally:
            feed.check_feed, feed.time.monotonic = original, clock

    def test_tag_only_checks_just_the_release_feeds(self):
        seen = []
        original = feed.check_feed
        feed.check_feed = lambda url, attempts: seen.append(url) or []
        try:
            self.assertEqual(quiet_main(["--tag", "v1.2.3", "--tag-only"]), 0)
        finally:
            feed.check_feed = original
        self.assertEqual(seen, [
            f"https://github.com/manaflow-ai/cmux/releases/download/v1.2.3/{name}" for name in feed.FEED_NAMES])

    def test_served_length_reads_the_range_total(self):
        self.assertEqual(feed.served_length(206, "bytes 0-0/77859900", "1"), 77859900)
        self.assertEqual(feed.served_length(200, None, "77859900"), 77859900)
        self.assertIsNone(feed.served_length(206, "bytes 0-0/*", "1"))
        self.assertIsNone(feed.served_length(200, None, None))

    def test_default_feeds_cover_every_stable_feed_name(self):
        for name in feed.FEED_NAMES:
            self.assertIn(f"https://github.com/manaflow-ai/cmux/releases/latest/download/{name}", feed.DEFAULT_FEEDS)
            self.assertIn(f"https://files.cmux.com/stable/{name}", feed.DEFAULT_FEEDS)


if __name__ == "__main__":
    unittest.main()
