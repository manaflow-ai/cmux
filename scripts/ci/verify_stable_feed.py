#!/usr/bin/env python3
"""Fail when a stable Sparkle feed cannot deliver an update.

Installed stable apps check releases/latest/download/appcast.xml (thin builds
rewrite it to appcast-<arch>.xml), and files.cmux.com/stable/ serves the same
feeds from R2. On 2026-10-27 v0.65.2.2 was tagged from a hotfix branch that
still carried the publish-by-tag release workflow: the published release had 0
assets while all 12 sat on a hidden draft, so every latest/download feed URL
404ed and every 0.65.2 install showed "error retrieving update information"
(https://github.com/manaflow-ai/cmux/issues/26729). The release run was green.

Each feed must load, parse, and list at least one enclosure carrying an EdDSA
signature. Every enclosure must return the requested byte. Its reported full
size must match the feed's declared length; when the response reports no full
size, the enclosure passes without a length comparison. This probe does not
verify complete DMG contents or cryptographically validate the signature.
release.yml runs it after publishing with --tag, which adds the new release's
own feed URLs. stable-feed-watch.yml checks the default feeds hourly from main,
regardless of which branch published the release. A non-latest backport's own
feeds are checked only by its release workflow when it includes this check.

Right after an upload GitHub can serve a cached 404 for a few minutes, so
--settle-seconds retries failing feeds in rounds, 404 included, within one
shared window. The deadline limits retry starts; HTTP calls already running
can finish afterward, and the workflows enforce their own job timeouts.
Retry windows are cancellation-aware: SIGINT/SIGTERM stops further requests
and interrupts a pending backoff; an in-flight HTTP call retains its timeout.

usage: verify_stable_feed.py [--feed URL ...] [--tag vX.Y.Z [--tag-only]] [--attempts 3] [--settle-seconds 0]
Exits 1 with one line per problem.
"""
from __future__ import annotations

import argparse
import http.client
import re
import signal
import sys
import threading
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DEFAULT_FEEDS = (
    "https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml",
    "https://github.com/manaflow-ai/cmux/releases/latest/download/appcast-arm64.xml",
    "https://github.com/manaflow-ai/cmux/releases/latest/download/appcast-x86_64.xml",
    "https://files.cmux.com/stable/appcast.xml",
    "https://files.cmux.com/stable/appcast-arm64.xml",
    "https://files.cmux.com/stable/appcast-x86_64.xml",
)
FEED_NAMES = ("appcast.xml", "appcast-arm64.xml", "appcast-x86_64.xml")
USER_AGENT = "cmux-stable-feed-check"


class FetchError(Exception):
    pass


class RetryCancelled(Exception):
    """The caller cancelled verification; no further request may start."""


class RetryWindow:
    """Bound retry starts by a monotonic deadline and an interruptible event.

    A successful HTTP response establishes readiness. Waiting only spaces
    attempts; it never turns a failed response into a successful result.
    In-flight HTTP requests retain their own 30-second timeout.
    """

    def __init__(self, seconds: float, *, cancelled: threading.Event | None = None):
        """Capture one absolute deadline and share the caller's cancellation."""
        self.deadline = time.monotonic() + max(0, seconds)
        self.cancelled = cancelled if cancelled is not None else threading.Event()

    def check_cancelled(self):
        """Stop before another request or retry if cancellation was signalled."""
        if self.cancelled.is_set():
            raise RetryCancelled()

    def ready(self) -> bool:
        """Whether a retry can start now, excluding the deadline itself."""
        self.check_cancelled()
        return time.monotonic() < self.deadline

    def wait(self, seconds: float) -> bool:
        """Wait for a retry slot, waking on cancellation or the deadline."""
        self.check_cancelled()
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            return False
        if self.cancelled.wait(min(seconds, remaining)):
            raise RetryCancelled()
        return self.ready()


def http_get(url: str) -> bytes:
    """Load a feed with a finite request timeout and uniform fetch errors."""
    request = urllib.request.Request(url, headers={"Cache-Control": "no-cache", "User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        raise FetchError(f"HTTP {error.code}") from error
    except (urllib.error.URLError, OSError, http.client.HTTPException, ValueError) as error:
        raise FetchError(str(getattr(error, "reason", error))) from error


def served_length(status: int, content_range: str | None, content_length: str | None) -> int | None:
    """The full size from a one-byte range response, or None if unknown."""
    if status == 206 and content_range:
        match = re.fullmatch(r"bytes \d+-\d+/(\d+)", content_range.strip())
        return int(match.group(1)) if match else None
    return int(content_length) if content_length and content_length.isdigit() else None


def http_content_length(url: str) -> int | None:
    """Asks for one byte and returns the full size the server reports.

    urllib turns a redirected HEAD into a GET, so a HEAD to GitHub's release
    URL would start a full DMG download; a range request follows the redirect
    and transfers one byte."""
    request = urllib.request.Request(url, headers={"Range": "bytes=0-0", "User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            if not response.read(1):
                raise FetchError("response closed before the requested byte")
            return served_length(response.status, response.headers.get("Content-Range"),
                                 response.headers.get("Content-Length"))
    except urllib.error.HTTPError as error:
        raise FetchError(f"HTTP {error.code}") from error
    except (urllib.error.URLError, OSError, http.client.HTTPException, ValueError) as error:
        raise FetchError(str(getattr(error, "reason", error))) from error


def with_retries(attempts: int, call, *args, retry: RetryWindow | None = None,
                 cancelled: threading.Event | None = None):
    """GitHub's release CDN returns a transient 5xx or reset now and then; a
    404 is the failure this check exists for, so it is never retried here.
    The window bounds the attempt timeouts plus their backoff intervals."""
    retry = retry or RetryWindow(30 * attempts + attempts * (attempts - 1), cancelled=cancelled)
    for attempt in range(1, attempts + 1):
        retry.check_cancelled()
        try:
            result = call(*args)
            retry.check_cancelled()
            return result
        except FetchError as error:
            if attempt == attempts or str(error).startswith("HTTP 4"):
                raise
            if not retry.wait(2 * attempt):
                raise


def enclosures(feed_xml: bytes) -> list[dict[str, str]]:
    """Returns each item's enclosure attributes; raises ValueError on bad XML."""
    try:
        root = ET.fromstring(feed_xml)
    except ET.ParseError as error:
        raise ValueError(f"does not parse as XML ({error})") from error
    found = []
    for item in root.iter("item"):
        enclosure = item.find("enclosure")
        if enclosure is None:
            continue
        found.append({
            "url": enclosure.get("url", ""),
            "length": enclosure.get("length", ""),
            "signature": enclosure.get(f"{{{SPARKLE_NS}}}edSignature", ""),
        })
    return found


def check_feed(feed_url: str, attempts: int, get=http_get, content_length=http_content_length,
               *, cancelled: threading.Event | None = None) -> list[str]:
    """Returns one line per problem with the feed or any enclosure it lists."""
    try:
        body = with_retries(attempts, get, feed_url, cancelled=cancelled)
    except FetchError as error:
        return [f"{feed_url}: feed did not load ({error})"]
    try:
        items = enclosures(body)
    except ValueError as error:
        return [f"{feed_url}: feed {error}"]
    if not items:
        return [f"{feed_url}: feed lists no item with an enclosure"]
    problems = []
    for item in items:
        url = item["url"]
        if not url:
            problems.append(f"{feed_url}: an enclosure has no url")
            continue
        if not item["signature"]:
            problems.append(f"{feed_url}: {url} has no sparkle:edSignature")
        try:
            if not (item["length"].isascii() and item["length"].isdigit()):
                raise ValueError("length must contain ASCII digits")
            declared_length = int(item["length"])
        except ValueError:
            problems.append(f"{feed_url}: {url} has no numeric length")
            continue
        try:
            served = with_retries(attempts, content_length, url, cancelled=cancelled)
        except FetchError as error:
            problems.append(f"{feed_url}: {url} does not download ({error})")
            continue
        if served is not None and served != declared_length:
            problems.append(f"{feed_url}: {url} serves {served} bytes, the feed declares {item['length']}")
    return problems


def main(argv: list[str] | None = None, *, cancelled: threading.Event | None = None) -> int:
    """Check every selected feed, retry failures fairly, and report final results."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--feed", action="append", help="feed URL to check (repeatable; default: every stable feed)")
    parser.add_argument("--tag", help="also check this release's own feeds (releases/download/TAG/...)")
    parser.add_argument("--tag-only", action="store_true", help="check only the --tag feeds (a backport release)")
    parser.add_argument("--repo", default="manaflow-ai/cmux")
    parser.add_argument("--attempts", type=int, default=3)
    parser.add_argument("--settle-seconds", type=int, default=0,
                        help="retry failing feeds in rounds within this shared window (404 included)")
    args = parser.parse_args(argv)
    if args.tag_only and not args.tag:
        parser.error("--tag-only needs --tag")
    feeds = [] if args.tag_only else list(args.feed or DEFAULT_FEEDS)
    if args.tag:
        feeds += [f"https://github.com/{args.repo}/releases/download/{args.tag}/{name}" for name in FEED_NAMES]
    retries = RetryWindow(args.settle_seconds, cancelled=cancelled)
    try:
        results = [check_feed(feed_url, max(1, args.attempts), cancelled=retries.cancelled) for feed_url in feeds]
        while any(results) and retries.wait(15):
            for index, feed_url in enumerate(feeds):
                if results[index] and retries.ready():
                    print(f"wait {feed_url}: {results[index][0]}")
                    results[index] = check_feed(feed_url, max(1, args.attempts), cancelled=retries.cancelled)
    except RetryCancelled:
        print("Feed verification cancelled")
        return 130
    problems = []
    for feed_url, found in zip(feeds, results):
        print(f"{'FAIL' if found else 'ok  '} {feed_url}")
        problems.extend(found)
    for problem in problems:
        print(f"::error::{problem}")
    return 1 if problems else 0


def cli() -> int:
    """Let SIGINT/SIGTERM cancel retry waits and restore the caller's handlers."""
    cancelled = threading.Event()
    previous = {}

    def cancel(_signum, _frame):
        cancelled.set()

    try:
        for signum in (signal.SIGINT, signal.SIGTERM):
            previous[signum] = signal.signal(signum, cancel)
        return main(cancelled=cancelled)
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


if __name__ == "__main__":
    sys.exit(cli())
