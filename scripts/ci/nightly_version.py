#!/usr/bin/env python3
"""Version numbers for nightly.yml's publish tracks.

  marketing --track T --project-version V --build B --next-base N
      Prints CFBundleShortVersionString for the track. main's nightly and RC
      use the project version (`<V>-<channel>.<B>`); cmux-next (track
      nightly-next) starts its own line at N (`<N>-nightly.<B>`, N = 1.0.0).

  check-build --build B --feed FILE_OR_URL [--feed ...]
      Exits 1 unless B is numerically above every sparkle:version in every
      feed. nightly.yml runs it for a cmux-next build against the cmux-next
      feeds and main's NIGHTLY feeds. Both tracks install as cmux NIGHTLY
      (one bundle id), so a cmux-next build is always above every nightly
      build that existed when it was published, on either feed.
      With --already-published-ok, a build no feed is above and some feed
      already offers (another run published it) prints
      `already_published=true` and exits 0; otherwise the last line is
      `already_published=false`.

CFBundleVersion is the run-derived number (`<run id><attempt, 2 digits>`),
which only grows; Sparkle compares it, never the marketing version.
"""

import argparse
import os
import re
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
TRACK_CHANNEL = {"nightly": "nightly", "rc": "rc", "nightly-next": "nightly"}
VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
BUILD = re.compile(r"^[0-9]+$")


class Refused(Exception):
    pass


def marketing(track, project_version, build, next_base):
    if track not in TRACK_CHANNEL:
        raise Refused(f"unknown track {track!r}")
    if not BUILD.match(build):
        raise Refused(f"build {build!r} is not a number")
    base = next_base if track == "nightly-next" else project_version
    if not VERSION.match(base):
        raise Refused(f"base version {base!r} is not MAJOR.MINOR.PATCH")
    return f"{base}-{TRACK_CHANNEL[track]}.{build}"


class Missing(Refused):
    pass


# A feed read that fails in transit (TLS handshake timeout, reset, 5xx) is
# tried again after these delays; run 39296746784 failed its nightly-next
# build on one handshake timeout. A 404, another 4xx or a feed that does not
# parse is an answer, not a transit failure, and refuses at once.
# CMUX_NIGHTLY_FEED_RETRY_DELAYS (comma-separated seconds) overrides the delays.
DEFAULT_RETRY_DELAYS = (2, 5, 10)


def retry_delays():
    value = os.environ.get("CMUX_NIGHTLY_FEED_RETRY_DELAYS")
    if value is None:
        return DEFAULT_RETRY_DELAYS
    return tuple(float(part) for part in value.split(",") if part.strip())


def transient(error):
    if isinstance(error, urllib.error.HTTPError):
        return error.code >= 500 or error.code == 429
    return isinstance(error, OSError)


def fetch(source):
    # The feed CDN refuses the default Python user agent.
    request = urllib.request.Request(source, headers={"User-Agent": "cmux-nightly-ci"})
    delays = retry_delays()
    for attempt in range(len(delays) + 1):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.read()
        except OSError as error:
            if not transient(error) or attempt == len(delays):
                raise
            print(f"nightly_version: {source}: {error}; trying again in {delays[attempt]:g} s", file=sys.stderr)
            time.sleep(delays[attempt])


def read_feed(source):
    try:
        # http:// only for a loopback test server; real feeds are https.
        if source.startswith(("https://", "http://127.0.0.1:")):
            data = fetch(source)
        else:
            with open(source, "rb") as handle:
                data = handle.read()
        return ET.fromstring(data)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            raise Missing(f"cannot read feed {source}: it does not exist") from error
        raise Refused(f"cannot read feed {source}: {error}") from error
    except FileNotFoundError as error:
        raise Missing(f"cannot read feed {source}: it does not exist") from error
    except (OSError, ET.ParseError) as error:
        raise Refused(f"cannot read feed {source}: {error}") from error


def feed_builds(root):
    builds = []
    for element in root.iter():
        if element.tag == f"{{{SPARKLE_NS}}}version" and element.text:
            builds.append(element.text.strip())
        value = element.get(f"{{{SPARKLE_NS}}}version")
        if value:
            builds.append(value.strip())
    numeric = []
    for build in builds:
        if not BUILD.match(build):
            raise Refused(f"feed has a non-numeric sparkle:version {build!r}")
        numeric.append(int(build))
    return numeric


def check_build(build, feeds, optional_feeds=(), already_published_ok=False):
    """`optional_feeds` may not exist yet (a track's new feed before its first
    publication); any other read failure still refuses. Returns whether a feed
    already offers exactly `build` (only allowed with `already_published_ok`)."""
    published_in = None
    if not BUILD.match(build):
        raise Refused(f"build {build!r} is not a number")
    for source in [*feeds, *optional_feeds]:
        try:
            root = read_feed(source)
        except Missing:
            if source not in optional_feeds:
                raise
            print(f"build {build}: {source} does not exist yet")
            continue
        builds = feed_builds(root)
        highest = max(builds, default=None)
        if highest is not None and int(build) == highest and already_published_ok:
            published_in = published_in or source
            print(f"build {build} is already the highest in {source}")
            continue
        if highest is not None and int(build) <= highest:
            raise Refused(f"build {build} is not above {highest} in {source}")
        print(f"build {build} is above {source} (highest {highest})")
    return published_in is not None


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    m = commands.add_parser("marketing")
    m.add_argument("--track", required=True)
    m.add_argument("--project-version", required=True)
    m.add_argument("--build", required=True)
    m.add_argument("--next-base", required=True)
    c = commands.add_parser("check-build")
    c.add_argument("--build", required=True)
    c.add_argument("--feed", action="append", required=True)
    c.add_argument("--feed-if-present", action="append", default=[], help="a feed that may not exist yet")
    c.add_argument("--already-published-ok", action="store_true", help="a feed already offering this build is not a refusal")
    args = parser.parse_args(argv)
    try:
        if args.command == "marketing":
            print(marketing(args.track, args.project_version, args.build, args.next_base))
        else:
            published = check_build(args.build, args.feed, args.feed_if_present, args.already_published_ok)
            if args.already_published_ok:
                print(f"already_published={'true' if published else 'false'}")
    except Refused as error:
        print(f"nightly_version: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
