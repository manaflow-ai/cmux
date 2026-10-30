#!/usr/bin/env python3
"""Read a cmux NEXT appcast back right after it went live and fail loudly when it offers nothing.

Run by nightly.yml after each nightly-next feed write: publish-nightly's cmux NEXT feed and
publish-nightly-identity-legacy's old cmux NIGHTLY-identity feed. Leo, 2026-10-27, on a feed
whose items were all on cmux-next-dev for hours with every check green: "but why shoudl there
be a delay if we can just listen". The write already knows; this reads the live feed and checks:

  1. its newest item is this build or a newer one (the write reached the public URL);
  2. that item's sparkle:channel is one the default Nightly ring accepts
     (NIGHTLY_ACCEPTED, UpdateRing.acceptedSparkleChannels for .nightly, which
     tests/test_nightly_next_live_feed_check.py derives from UpdateRing.swift). With
     NIGHTLY_NEXT_DEV_RING=on a new build starts on cmux-next-dev by design: that is a
     warning naming the build Nightly is offered instead, not a failure;
  3. that item's enclosure answers a plain GET with 200 at its declared length (Sparkle's request);
  4. the newest build Nightly is offered never moves back, and with the ring off it moved past
     what the feed offered before this write (--before, the feed as read before it).

usage: nightly_next_live_feed_check.py --feed-url URL --build N [--before FILE] [--dev-ring on|off]
Exit 0 when every check holds, 1 with an ::error line naming each one that does not.
"""
from __future__ import annotations

import argparse
import random
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
# UpdateRing.acceptedSparkleChannels for .nightly (the default `updates.channel`): its own tag and
# every slower ring's. Checked against UpdateRing.swift by the test, so a rename fails there.
NIGHTLY_ACCEPTED = ("cmux-next-stable", "cmux-next")
DEV = "cmux-next-dev"
USER_AGENT = "cmux-nightly-next-live-check/1"


class Item:
    def __init__(self, build: int, channel: str | None, url: str | None, length: int | None):
        self.build, self.channel, self.url, self.length = build, channel, url, length

    @property
    def offered(self) -> bool:
        """Whether Sparkle offers it to the default Nightly ring (an untagged item is offered too)."""
        return self.channel is None or self.channel in NIGHTLY_ACCEPTED


def items(xml: str) -> list[Item]:
    out = []
    for element in ET.fromstring(xml).iter("item"):
        enclosure = element.find("enclosure")
        version = element.findtext(f"{{{SPARKLE}}}version")
        if version is None and enclosure is not None:
            version = enclosure.get(f"{{{SPARKLE}}}version")
        if not (version or "").strip().isdigit():
            continue
        channel = element.findtext(f"{{{SPARKLE}}}channel")
        length = enclosure.get("length") if enclosure is not None else None
        out.append(Item(int(version.strip()), channel.strip() if channel is not None else None,
                        enclosure.get("url") if enclosure is not None else None,
                        int(length) if (length or "").isdigit() else None))
    return sorted(out, key=lambda item: item.build, reverse=True)


def newest_offered(feed: list[Item]) -> int | None:
    return next((item.build for item in feed if item.offered), None)


def fetch(url: str) -> str:
    separator = "&" if "?" in url else "?"
    request = urllib.request.Request(f"{url}{separator}check={random.getrandbits(48):x}",
                                     headers={"User-Agent": USER_AGENT, "Cache-Control": "no-cache"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read().decode("utf-8")


def probe_once(url: str) -> tuple[int, int | None]:
    """(status, length) of one try: HEAD, then a plain GET (headers only) when HEAD fails or names no length."""
    head_status = None
    try:
        request = urllib.request.Request(url, method="HEAD", headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(request, timeout=30) as response:
            length = response.headers.get("Content-Length")
            if response.status == 200 and (length or "").isdigit():
                return 200, int(length)
            head_status = response.status
    except urllib.error.HTTPError as error:
        head_status = error.code
    except OSError:
        head_status = 0
    # The request Sparkle makes: a plain GET. Only its status line and headers are read; closing
    # the response drops the body unread.
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            length = response.headers.get("Content-Length")
            if response.status == 200 and (length or "").isdigit():
                return 200, int(length)
            return response.status, None
    except urllib.error.HTTPError as error:
        return error.code, None
    except OSError:
        return head_status or 0, None


def probe(url: str, attempts: int = 3, delay: float = 2.0) -> tuple[int, int | None]:
    """(status, length) of the enclosure, retried briefly through a transient edge error."""
    status, length = 0, None
    for attempt in range(attempts):
        status, length = probe_once(url)
        if status == 200 and length is not None:
            break
        if attempt < attempts - 1:
            time.sleep(delay)
    return status, length


def check(live: list[Item], build: int, before: list[Item] | None, dev_ring: str,
          probe=None) -> tuple[list[str], list[str]]:
    """(errors, warnings) for the live feed after `build` was written."""
    probe = probe or globals()["probe"]  # looked up per call, so a test's patch applies
    errors, warnings = [], []
    if not live:
        return [f"the live feed lists no item; build {build} is not offered"], warnings
    newest = live[0]
    if newest.build < build:
        errors.append(f"the live feed's newest build is {newest.build}, not {build}: the write never reached it")
    if not newest.offered:
        offered = newest_offered(live)
        if dev_ring == "on" and newest.channel == DEV:
            warnings.append(f"build {newest.build} is on {DEV} until its canary verdict passes; "
                            f"the default Nightly app is offered build {offered or 'none'}")
        else:
            errors.append(f"build {newest.build} is tagged {newest.channel!r}, which the default Nightly app "
                          f"does not accept ({', '.join(NIGHTLY_ACCEPTED)}); it is offered build {offered or 'none'}")
    if not newest.url:
        errors.append(f"build {newest.build} has no enclosure URL")
    else:
        status, length = probe(newest.url)
        if status != 200:
            errors.append(f"build {newest.build}'s enclosure {newest.url} answers HTTP {status}")
        elif length is None:
            errors.append(f"build {newest.build}'s enclosure {newest.url} names no length (HTTP {status}), so it is unverified")
        elif newest.length is None:
            errors.append(f"build {newest.build}'s item declares no enclosure length")
        elif length != newest.length:
            errors.append(f"build {newest.build}'s enclosure {newest.url} is {length} bytes; the item says {newest.length}")
    after, prior = newest_offered(live), newest_offered(before or [])
    if prior is not None:
        if after is None or after < prior:
            errors.append(f"the newest build the default Nightly app is offered went back from {prior} to {after or 'none'}")
        elif dev_ring != "on" and newest.build == build and after <= prior:
            errors.append(f"the default Nightly app is still offered build {prior}, not {build}")
    return errors, warnings


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--feed-url", required=True)
    parser.add_argument("--build", type=int, required=True)
    parser.add_argument("--before", help="the feed as read before this write")
    parser.add_argument("--dev-ring", default="off", choices=("on", "off"))
    # The public URL serves the feed uncached (cf-cache-status DYNAMIC) and R2 reads its own write:
    # in run 40454745365 the DMG answered HEAD 0.2 s after its upload, on the first try. Two short
    # retries cover an edge hiccup without turning the read-back into a wait.
    parser.add_argument("--attempts", type=int, default=3, help="reads while the edge still serves an older feed")
    parser.add_argument("--delay", type=float, default=2.0)
    args = parser.parse_args(argv)
    before, before_error = None, ""
    if args.before:
        try:
            with open(args.before, encoding="utf-8") as handle:
                text = handle.read()
            # 404 marker from the before step: no feed existed, so there is no floor.
            before = items(text) if text.strip() != "absent" else []
            if text.strip() != "absent" and not before:
                before_error = (f"the feed from before the write ({args.before}) lists no item, so a "
                                "regression cannot be ruled out")
        except (OSError, ET.ParseError) as error:
            before_error = f"the feed from before the write ({args.before}) is unreadable ({error}), so a regression cannot be ruled out"
    live: list[Item] = []
    for attempt in range(1, max(1, args.attempts) + 1):
        try:
            live = items(fetch(args.feed_url))
        except (OSError, ET.ParseError, UnicodeDecodeError) as error:
            print(f"::warning::read {attempt} of {args.feed_url} failed: {error}")
            live = []
        if live and live[0].build >= args.build:
            break
        if attempt < args.attempts:
            time.sleep(args.delay)
    errors, warnings = check(live, args.build, before, args.dev_ring)
    if before_error:
        errors.append(before_error)
    for warning in warnings:
        print(f"::warning title=nightly-next feed {args.feed_url}::{warning}")
    for error in errors:
        print(f"::error title=nightly-next feed offers nothing new::{args.feed_url}: {error}")
    if errors:
        print(f"{args.feed_url} as read back ({len(live)} items, newest first):")
        for item in live:
            print(f"  {item.build}  channel={item.channel or '(untagged)'}  "
                  f"{'offered' if item.offered else 'NOT offered'} to Nightly  enclosure={item.url} length={item.length}")
    if not errors:
        print(f"{args.feed_url}: newest build {live[0].build} ({live[0].channel}) is live and downloadable; "
              f"the default Nightly app is offered build {newest_offered(live)}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
