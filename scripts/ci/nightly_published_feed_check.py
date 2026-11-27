#!/usr/bin/env python3
"""Before a nightly-next run says it published, read the live feeds back and fail when they did not move.

nightly.yml dispatch-published-in asks for "Finish a published nightly-next build" (the post-publication
run) once nightly-next-one or publish-nightly ends green. Run 45607031207 (2026-11-25): nightly-next-one's
final gate refused build 4560703120701 (its App Store shelf job died on a full disk), the job still ended
green, and dispatch-published-in asked for the post-publication run anyway. Every job said published while
appcast-arm64.xml stayed on 4557519416001 for four hours. Leo: "are nightlies not publishin? where the
priority?"

This runs first in dispatch-published-in. A build the publisher refused (a gate refusal, a stand-down, a
supersede: publish_refused) published nothing, so it writes published=false and the job asks for no
post-publication run; nightly-next-one's own refusal step says in red which refusals were failures. Every
other build said it published: this fails, naming why, when the run has no build number or any feed's
newest item is older than the build. A newer item is fine: a later run already moved the feed past it.

usage: nightly_published_feed_check.py --feed-base URL --feeds "appcast-arm64.xml ..." --build N [--refused true]
Exit 0 with published=true (GITHUB_OUTPUT) when every feed's newest item is build N or newer, or with
published=false when the build was refused; 1 with an ::error line for each reason it did not publish.
"""
from __future__ import annotations

import argparse
import os
import sys
import time
import xml.etree.ElementTree as ET

# Imported by name (tests/test_script_module_loads.py): the live read-back's feed parser and fetch.
from nightly_next_live_feed_check import fetch, items


def verdict(build: str, newest: dict[str, int | None]) -> list[str]:
    """Each reason this run must not say it published; empty when every feed moved to the build or past it."""
    if not build.isdigit():
        return [f"the run names no published build ('{build}')"]
    if not newest:
        return ["the run names no feed to read back"]
    errors = []
    for url, top in newest.items():
        if top is None:
            errors.append(f"{url} lists no build")
        elif top < int(build):
            errors.append(f"{url} still offers {top}, not build {build}: the feed did not move")
    return errors


def newest_build(url: str, build: int, attempts: int, delay: float) -> int | None:
    top = None
    for attempt in range(1, attempts + 1):
        try:
            feed = items(fetch(url))
            top = feed[0].build if feed else None
        except (OSError, ET.ParseError, UnicodeDecodeError) as error:
            print(f"::warning::read {attempt} of {url} failed: {error}")
        if top is not None and top >= build:
            break
        if attempt < attempts:
            time.sleep(delay)
    return top


def output(published: str) -> int:
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(f"published={published}\n")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--feed-base", required=True)
    parser.add_argument("--feeds", required=True)
    parser.add_argument("--build", default="")
    parser.add_argument("--refused", default="")
    parser.add_argument("--attempts", type=int, default=3)
    parser.add_argument("--delay", type=float, default=5.0)
    args = parser.parse_args(argv)
    if args.refused == "true":
        print(f"::notice title=Nothing published::build {args.build or '(none)'} was refused, stood down or "
              "superseded; no post-publication run is asked for")
        return output("false")
    newest: dict[str, int | None] = {}
    if args.build.isdigit():
        for name in args.feeds.split():
            url = f"{args.feed_base.rstrip('/')}/{name}"
            newest[url] = newest_build(url, int(args.build), max(1, args.attempts), args.delay)
    errors = verdict(args.build, newest)
    for error in errors:
        print(f"::error title=Nightly not published::{error}; no post-publication run is asked for")
    if errors:
        return 1
    for url, top in newest.items():
        print(f"{url}: newest build {top}, at or past build {args.build}")
    return output("true")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
