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
  3. that item's enclosure answers 200 (or 206 to a one-byte range) at its declared length;
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


def probe(url: str) -> tuple[int, int | None]:
    """(status, length) of the enclosure: HEAD, then a one-byte GET where HEAD is refused."""
    try:
        request = urllib.request.Request(url, method="HEAD", headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(request, timeout=30) as response:
            length = response.headers.get("Content-Length")
            return response.status, int(length) if (length or "").isdigit() else None
    except urllib.error.HTTPError as error:
        if error.code not in (403, 405):
            return error.code, None
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Range": "bytes=0-0"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            total = (response.headers.get("Content-Range") or "").rpartition("/")[2]
            return response.status, int(total) if total.isdigit() else None
    except urllib.error.HTTPError as error:
        return error.code, None


def check(live: list[Item], build: int, before: list[Item] | None, dev_ring: str,
          probe=probe) -> tuple[list[str], list[str]]:
    """(errors, warnings) for the live feed after `build` was written."""
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
        if status not in (200, 206):
            errors.append(f"build {newest.build}'s enclosure {newest.url} answers HTTP {status}")
        elif newest.length is not None and length is not None and length != newest.length:
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
    before = None
    if args.before:
        try:
            with open(args.before, encoding="utf-8") as handle:
                before = items(handle.read())
        except (OSError, ET.ParseError) as error:
            print(f"::warning::could not read the feed from before the write ({args.before}): {error}")
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
