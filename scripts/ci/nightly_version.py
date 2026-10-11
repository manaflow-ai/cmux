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

CFBundleVersion is the run-derived number (`<run id><attempt, 2 digits>`),
which only grows; Sparkle compares it, never the marketing version.
"""

import argparse
import re
import sys
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


def read_feed(source):
    try:
        if source.startswith("https://"):
            # The feed CDN refuses the default Python user agent.
            request = urllib.request.Request(source, headers={"User-Agent": "cmux-nightly-ci"})
            with urllib.request.urlopen(request, timeout=30) as response:
                data = response.read()
        else:
            with open(source, "rb") as handle:
                data = handle.read()
        return ET.fromstring(data)
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


def check_build(build, feeds):
    if not BUILD.match(build):
        raise Refused(f"build {build!r} is not a number")
    for source in feeds:
        builds = feed_builds(read_feed(source))
        highest = max(builds, default=None)
        if highest is not None and int(build) <= highest:
            raise Refused(f"build {build} is not above {highest} in {source}")
        print(f"build {build} is above {source} (highest {highest})")


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
    args = parser.parse_args(argv)
    try:
        if args.command == "marketing":
            print(marketing(args.track, args.project_version, args.build, args.next_base))
        else:
            check_build(args.build, args.feed)
    except Refused as error:
        print(f"nightly_version: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
