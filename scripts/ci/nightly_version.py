#!/usr/bin/env python3
"""Version numbers for nightly.yml's publish tracks.

  marketing --track T --project-version V --build B --next-base N
      Prints CFBundleShortVersionString for the track. main's nightly and RC
      use the project version (`<V>-<channel>.<B>`); cmux-next (track
      nightly-next) starts its own line at N (`<N>-nightly.<B>`, N = 1.0.0).

  next-base [--root DIR]
      Prints the cmux-next version (N above): `version` in
      cmux-tui/Cargo.toml [workspace.package]. It is the one source of truth:
      the bundled CLIs inherit it as their crate version, nightly.yml passes it
      as --next-base, scripts/reload.sh stamps it as MARKETING_VERSION, and
      scripts/cmux-next/check-version-surfaces.sh fails a bundle that disagrees.

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
      With --superseded-ok as well, a build some feed is already above (a
      newer build published first: builds run side by side and publication
      is latest-wins) prints `superseded=true` and exits 0 instead of
      refusing; otherwise `superseded=false` follows.

CFBundleVersion is the run-derived number (`<run id><attempt, 2 digits>`),
which only grows; Sparkle compares it, never the marketing version.
"""

import argparse
import http.client
import os
import re
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
# Feed prefixes, bound on the <rss> root when a feed uses one without declaring
# it there (publish-nightly-next-r2.py bind_feed_prefixes writes them since 11-01).
FEED_PREFIXES = {"sparkle": SPARKLE_NS, "cmux": "https://cmux.com/xml-namespaces/cmux"}
RSS_OPEN = re.compile(rb"<rss\b[^>]*>")
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


WORKSPACE_PACKAGE_VERSION = re.compile(r'^version\s*=\s*"([^"]+)"\s*(?:#.*)?$')


def next_base(root):
    """The cmux-next version from cmux-tui/Cargo.toml [workspace.package]."""
    path = os.path.join(root, "cmux-tui", "Cargo.toml")
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError as error:
        raise Refused(f"cannot read {path}: {error}") from error
    section = None
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("["):
            section = stripped
            continue
        if section == "[workspace.package]":
            match = WORKSPACE_PACKAGE_VERSION.match(stripped)
            if match:
                if not VERSION.match(match.group(1)):
                    raise Refused(f"{path} [workspace.package] version {match.group(1)!r} is not MAJOR.MINOR.PATCH")
                return match.group(1)
    raise Refused(f"{path} has no [workspace.package] version")


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
    # IncompleteRead (a body cut off mid-transfer) is an HTTPException, not an OSError.
    return isinstance(error, (OSError, http.client.HTTPException))


def fetch(source):
    # The feed CDN refuses the default Python user agent.
    request = urllib.request.Request(source, headers={"User-Agent": "cmux-nightly-ci"})
    delays = retry_delays()
    for attempt in range(len(delays) + 1):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.read()
        except (OSError, http.client.HTTPException) as error:
            if not transient(error) or attempt == len(delays):
                raise
            print(f"nightly_version: {source}: {error}; trying again in {delays[attempt]:g} s", file=sys.stderr)
            time.sleep(delays[attempt])


def bind_feed_prefixes(data):
    """DATA with every feed prefix it uses declared on the <rss> root.

    A feed whose carried-over item used a bare <cmux:sourceCommit> without the
    root declaring cmux: (nightly-next, 2026-11-01) is otherwise unreadable here,
    and this reader runs before the writer that repairs the feed.
    """
    root = RSS_OPEN.search(data)
    if root is None:
        return data
    opening = root.group(0)
    for prefix, uri in FEED_PREFIXES.items():
        used = re.search(rb"[<\s]" + prefix.encode() + rb":[A-Za-z_]", data) is not None
        if used and re.search(rb"\sxmlns:" + prefix.encode() + rb"\s*=", opening) is None:
            opening = opening[:-1] + f' xmlns:{prefix}="{uri}">'.encode()
    return data[:root.start()] + opening + data[root.end():]


def read_feed(source):
    try:
        # http:// only for a loopback test server; real feeds are https.
        if source.startswith(("https://", "http://127.0.0.1:")):
            data = fetch(source)
        else:
            with open(source, "rb") as handle:
                data = handle.read()
        return ET.fromstring(bind_feed_prefixes(data))
    except urllib.error.HTTPError as error:
        if error.code == 404:
            raise Missing(f"cannot read feed {source}: it does not exist") from error
        raise Refused(f"cannot read feed {source}: {error}") from error
    except FileNotFoundError as error:
        raise Missing(f"cannot read feed {source}: it does not exist") from error
    except (OSError, http.client.HTTPException, ET.ParseError) as error:
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


class Superseded(Exception):
    """A feed is already above the build: a newer build published first."""


def check_build(build, feeds, optional_feeds=(), already_published_ok=False, superseded_ok=False):
    """`optional_feeds` may not exist yet (a track's new feed before its first
    publication); any other read failure still refuses. Returns whether a feed
    already offers exactly `build` (only allowed with `already_published_ok`).
    With `superseded_ok`, a feed above the build raises Superseded instead of
    Refused, after every feed was read (an unreadable feed still refuses)."""
    published_in = None
    above = None
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
            if not superseded_ok:
                raise Refused(f"build {build} is not above {highest} in {source}")
            above = above or f"build {build} is superseded by {highest} in {source}"
            print(above)
            continue
        print(f"build {build} is above {source} (highest {highest})")
    if above:
        raise Superseded(above)
    return published_in is not None


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    m = commands.add_parser("marketing")
    m.add_argument("--track", required=True)
    m.add_argument("--project-version", required=True)
    m.add_argument("--build", required=True)
    m.add_argument("--next-base", required=True)
    n = commands.add_parser("next-base")
    n.add_argument("--root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    c = commands.add_parser("check-build")
    c.add_argument("--build", required=True)
    c.add_argument("--feed", action="append", required=True)
    c.add_argument("--feed-if-present", action="append", default=[], help="a feed that may not exist yet")
    c.add_argument("--already-published-ok", action="store_true", help="a feed already offering this build is not a refusal")
    c.add_argument("--superseded-ok", action="store_true",
                   help="a feed already above this build (a newer build published first) is not a refusal")
    args = parser.parse_args(argv)
    try:
        if args.command == "marketing":
            print(marketing(args.track, args.project_version, args.build, args.next_base))
        elif args.command == "next-base":
            print(next_base(args.root))
        else:
            try:
                published = check_build(args.build, args.feed, args.feed_if_present, args.already_published_ok,
                                        args.superseded_ok)
            except Superseded:
                print("superseded=true")
                return 0
            if args.already_published_ok:
                print(f"already_published={'true' if published else 'false'}")
            if args.superseded_ok:
                print("superseded=false")
    except Refused as error:
        print(f"nightly_version: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
