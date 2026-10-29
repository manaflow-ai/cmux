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
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import signal
import subprocess
import sys
import threading
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/ci/verify_stable_feed.py"
spec = importlib.util.spec_from_file_location("verify_stable_feed", SCRIPT)
feed = importlib.util.module_from_spec(spec)
sys.modules["verify_stable_feed"] = feed
spec.loader.exec_module(feed)

FEED_URL = "https://github.com/o/r/releases/latest/download/appcast.xml"
DMG = "https://github.com/o/r/releases/download/v1.2.3/cmux-macos.dmg"
EXPECTED_FEED_NAMES = ("appcast.xml", "appcast-arm64.xml", "appcast-x86_64.xml")


def appcast(*enclosures: str) -> bytes:
    """Build an RSS feed containing exactly the supplied enclosures."""
    items = "".join(f"<item><title>1.2.3</title>{e}</item>" for e in enclosures)
    return (
        '<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" '
        f'version="2.0"><channel><title>cmux</title>{items}</channel></rss>'
    ).encode()


def enclosure(url=DMG, length="100", signature="c2ln") -> str:
    """Build an enclosure, optionally omitting its signature."""
    sig = f' sparkle:edSignature="{signature}"' if signature else ""
    return f'<enclosure url="{url}" length="{length}" type="application/octet-stream"{sig}/>'


class Server:
    """Answers GET and HEAD from a URL table; a missing URL is a 404."""

    def __init__(self, bodies=None, lengths=None, failures=None):
        """Set up response fixtures and a log independent of production code."""
        self.bodies = bodies or {}
        self.lengths = lengths or {}
        self.failures = dict(failures or {})
        self.calls = []

    def _fail(self, url):
        """Consume one queued failure before serving a fixture response."""
        queued = self.failures.get(url)
        if queued:
            raise feed.FetchError(queued.pop(0))

    def get(self, url):
        """Record the feed request and serve its body or a fetch failure."""
        self.calls.append(("GET", url))
        self._fail(url)
        if url not in self.bodies:
            raise feed.FetchError("HTTP 404")
        return self.bodies[url]

    def head(self, url):
        """Record an enclosure probe and serve its reported full size."""
        self.calls.append(("HEAD", url))
        self._fail(url)
        if url not in self.lengths:
            raise feed.FetchError("HTTP 404")
        return self.lengths[url]


def quiet_main(argv):
    """main() prints ::error:: lines; keep them out of the CI run's annotations."""
    with contextlib.redirect_stdout(io.StringIO()):
        return feed.main(argv)


def quiet_main_with_cancellation(argv, cancelled):
    """Capture cancellation diagnostics just like ordinary CLI diagnostics."""
    with contextlib.redirect_stdout(io.StringIO()):
        return feed.main(argv, cancelled=cancelled)


def check(server, attempts=1):
    return feed.check_feed(FEED_URL, attempts, get=server.get, content_length=server.head)


class Clock:
    def __init__(self):
        self.now = 0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


@contextlib.contextmanager
def range_server(body):
    """Serve an actual one-byte range response and record the request header."""
    ranges = []

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            """Advertise one byte even when the test deliberately omits it."""
            ranges.append(self.headers.get("Range"))
            self.send_response(206)
            self.send_header("Content-Range", "bytes 0-0/100")
            self.send_header("Content-Length", "1")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass

    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield f"http://127.0.0.1:{server.server_port}/update.dmg", ranges
        finally:
            server.shutdown()
            thread.join()


class VerifyStableFeedTests(unittest.TestCase):
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

    def test_non_ascii_length_is_reported_without_a_traceback(self):
        server = Server({FEED_URL: appcast(enclosure(length="²"))}, {DMG: 100})
        self.assertEqual(check(server), [f"{FEED_URL}: {DMG} has no numeric length"])

    def test_range_response_that_closes_before_its_byte_fails(self):
        with range_server(b"") as (url, _ranges):
            with self.assertRaises(feed.FetchError):
                feed.http_content_length(url)

    def test_range_response_with_its_byte_passes(self):
        with range_server(b"x") as (url, ranges):
            self.assertEqual(feed.http_content_length(url), 100)
        self.assertEqual(ranges, ["bytes=0-0"])

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
        with patch.object(threading.Event, "wait", return_value=False):
            self.assertEqual(check(server, attempts=3), [])

    def test_404_is_not_retried(self):
        server = Server()
        check(server, attempts=3)
        self.assertEqual(server.calls, [("GET", FEED_URL)])

    def test_cancelled_retry_window_starts_no_request(self):
        cancelled = threading.Event()
        cancelled.set()
        window = feed.RetryWindow(10, cancelled=cancelled)
        server = Server()
        with self.assertRaises(feed.RetryCancelled):
            feed.with_retries(3, server.get, FEED_URL, retry=window)
        self.assertEqual(server.calls, [])

    def test_cancellation_during_backoff_starts_no_more_requests(self):
        cancelled = threading.Event()
        window = feed.RetryWindow(10, cancelled=cancelled)
        server = Server(failures={FEED_URL: ["HTTP 502"]})

        def cancel(_seconds):
            cancelled.set()
            return True

        with patch.object(cancelled, "wait", side_effect=cancel), \
                self.assertRaises(feed.RetryCancelled):
            feed.with_retries(3, server.get, FEED_URL, retry=window)
        self.assertEqual(server.calls, [("GET", FEED_URL)])

    def test_request_retry_does_not_start_at_its_deadline(self):
        clock = Clock()
        cancelled = threading.Event()
        server = Server(failures={FEED_URL: ["HTTP 502"]})
        with patch.object(feed.time, "monotonic", clock.monotonic), \
                patch.object(cancelled, "wait", side_effect=clock.sleep):
            window = feed.RetryWindow(1, cancelled=cancelled)
            with self.assertRaisesRegex(feed.FetchError, "HTTP 502"):
                feed.with_retries(3, server.get, FEED_URL, retry=window)
        self.assertEqual(server.calls, [("GET", FEED_URL)])
        self.assertEqual(clock.now, 1)

    def test_settle_cancellation_stops_feed_rounds(self):
        cancelled = threading.Event()

        def cancel(_seconds):
            cancelled.set()
            return True

        with patch.object(feed, "check_feed", return_value=["HTTP 404"]) as check_url, \
                patch.object(cancelled, "wait", side_effect=cancel):
            self.assertEqual(quiet_main_with_cancellation([
                "--feed", FEED_URL, "--settle-seconds", "60",
            ], cancelled), 130)
        self.assertEqual(check_url.call_count, 1)

    def test_cli_sigterm_cancels_verification(self):
        """A real termination signal stops a CLI checking a broken local feed."""
        requested = threading.Event()

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_error(404)
                requested.set()

            def log_message(self, *_args):
                pass

        with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            process = subprocess.Popen([
                sys.executable, str(SCRIPT), "--feed", f"http://127.0.0.1:{server.server_port}/feed.xml",
                "--attempts", "1", "--settle-seconds", "60",
            ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                self.assertTrue(requested.wait(5), "CLI did not request the feed")
                process.send_signal(signal.SIGTERM)
                stdout, stderr = process.communicate(timeout=5)
                self.assertEqual(process.returncode, 130, stderr)
                self.assertIn("Feed verification cancelled", stdout)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()
                server.shutdown()
                thread.join()

    def test_main_exits_nonzero_on_any_problem(self):
        """The CLI exits nonzero if any selected feed remains broken."""
        original = feed.check_feed
        feed.check_feed = lambda url, attempts, **_kwargs: [] if url.endswith("good.xml") else [f"{url}: bad"]
        try:
            self.assertEqual(quiet_main(["--feed", "https://x/good.xml"]), 0)
            self.assertEqual(quiet_main(["--feed", "https://x/good.xml", "--feed", "https://x/bad.xml"]), 1)
        finally:
            feed.check_feed = original

    def test_tag_adds_the_release_feeds(self):
        """Tag selection adds every architecture to the chosen default scope."""
        seen = []
        original = feed.check_feed
        feed.check_feed = lambda url, attempts, **_kwargs: seen.append(url) or []
        try:
            self.assertEqual(quiet_main(["--feed", "https://x/a.xml", "--tag", "v1.2.3"]), 0)
        finally:
            feed.check_feed = original
        self.assertEqual(seen, ["https://x/a.xml"] + [
            f"https://github.com/manaflow-ai/cmux/releases/download/v1.2.3/{name}" for name in EXPECTED_FEED_NAMES])

    def test_settle_retries_a_404_until_it_clears(self):
        # GitHub serves a cached 404 for a just-uploaded asset for a few minutes.
        results = [["https://x/a.xml: feed did not load (HTTP 404)"], []]
        clock = Clock()
        with patch.object(feed, "check_feed", side_effect=lambda url, attempts, **_kwargs: results.pop(0)), \
                patch.object(feed.time, "monotonic", clock.monotonic), \
                patch.object(threading.Event, "wait", side_effect=clock.sleep):
            self.assertEqual(quiet_main(["--feed", "https://x/a.xml", "--settle-seconds", "60"]), 0)
        self.assertEqual(results, [])

    def test_settle_gives_up_at_the_deadline(self):
        clock = Clock()
        with patch.object(feed, "check_feed", return_value=["feed did not load (HTTP 404)"]), \
                patch.object(feed.time, "monotonic", clock.monotonic), \
                patch.object(threading.Event, "wait", side_effect=clock.sleep):
            self.assertEqual(quiet_main(["--feed", "https://x/a.xml", "--settle-seconds", "60"]), 1)
        self.assertEqual(clock.now, 60)

    def test_settle_retries_failing_feeds_in_rounds(self):
        clock, calls = Clock(), []
        first, second, healthy = (f"https://x/{name}.xml" for name in ("a", "b", "healthy"))

        def check_url(url, _attempts, **_kwargs):
            """Keep one feed failing while another recovers on its second call."""
            calls.append(url)
            if url == healthy or (url == second and calls.count(second) > 1):
                return []
            return [f"{url}: feed did not load (HTTP 404)"]

        with patch.object(feed, "check_feed", side_effect=check_url), \
                patch.object(feed.time, "monotonic", clock.monotonic), \
                patch.object(threading.Event, "wait", side_effect=clock.sleep):
            self.assertEqual(quiet_main([
                "--feed", first, "--feed", second, "--feed", healthy, "--settle-seconds", "30",
            ]), 1)
        self.assertEqual(calls, [first, second, healthy, first, second])
        self.assertEqual(clock.now, 30)

    def test_settle_does_not_start_a_retry_after_the_deadline(self):
        clock = Clock()
        with patch.object(feed, "check_feed", return_value=["HTTP 404"]) as check_url, \
                patch.object(feed.time, "monotonic", clock.monotonic), \
                patch.object(threading.Event, "wait", side_effect=clock.sleep):
            self.assertEqual(quiet_main(["--feed", FEED_URL, "--settle-seconds", "1"]), 1)
        self.assertEqual(check_url.call_count, 1)
        self.assertEqual(clock.now, 1)

    def test_zero_settle_checks_each_feed_once(self):
        with patch.object(feed, "check_feed", return_value=["HTTP 404"]) as check_url:
            self.assertEqual(quiet_main(["--feed", FEED_URL, "--feed", "https://x/b.xml"]), 1)
        self.assertEqual(check_url.call_count, 2)

    def test_tag_only_checks_just_the_release_feeds(self):
        """A backport checks all tagged architectures without probing latest."""
        seen = []
        original = feed.check_feed
        feed.check_feed = lambda url, attempts, **_kwargs: seen.append(url) or []
        try:
            self.assertEqual(quiet_main(["--tag", "v1.2.3", "--tag-only"]), 0)
        finally:
            feed.check_feed = original
        self.assertEqual(seen, [
            f"https://github.com/manaflow-ai/cmux/releases/download/v1.2.3/{name}" for name in EXPECTED_FEED_NAMES])

    def test_served_length_reads_the_range_total(self):
        self.assertEqual(feed.served_length(206, "bytes 0-0/77859900", "1"), 77859900)
        self.assertEqual(feed.served_length(200, None, "77859900"), 77859900)
        self.assertIsNone(feed.served_length(206, "bytes 0-0/*", "1"))
        self.assertIsNone(feed.served_length(200, None, None))

    def test_default_feeds_cover_every_stable_feed_name(self):
        """Each independently named architecture exists on both default hosts."""
        for name in EXPECTED_FEED_NAMES:
            self.assertIn(f"https://github.com/manaflow-ai/cmux/releases/latest/download/{name}", feed.DEFAULT_FEEDS)
            self.assertIn(f"https://files.cmux.com/stable/{name}", feed.DEFAULT_FEEDS)


if __name__ == "__main__":
    unittest.main()
