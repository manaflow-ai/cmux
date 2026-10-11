#!/usr/bin/env python3
"""Refuse anything that would let the cmux-next track touch main's NIGHTLY.

The cmux-next track (branch `nightly-next`) ships the same bundle id as cmux
NIGHTLY, so the only thing that keeps the two apart is where each one reads
updates from and where each one publishes. nightly.yml calls this before it
bakes a feed URL into the app and before every object it uploads:

  feed-url URL           the SUFeedURL baked into the app
  appcast FILE           every download URL and item channel in an appcast
  r2-key BUCKET KEY      every object it writes

The allowed values come from the workflow environment
(NIGHTLY_NEXT_FEED_BASE, NIGHTLY_NEXT_R2_BUCKET, NIGHTLY_NEXT_R2_PREFIX); the
refused ones are main's feeds and objects, written out here so a wrong
environment value cannot allow them. Exit 0 when allowed, 1 with a reason.
"""

import os
import sys
import xml.etree.ElementTree as ET

# Main's channels: the cmux-next track must never read or write these.
MAIN_BUCKET = "cmux-binaries"
MAIN_FEED_PREFIXES = (
    "https://files.cmux.com/nightly/",
    "https://files.cmux.com/rc/",
    "https://files.cmux.com/stable/",
    "https://github.com/manaflow-ai/cmux/releases/latest/",
    "https://github.com/manaflow-ai/cmux/releases/download/nightly/",
    "https://github.com/manaflow-ai/cmux/releases/download/rc/",
)
MAIN_OBJECT_PREFIXES = ("nightly/", "rc/", "stable/")
NEXT_DOWNLOAD_PREFIX = "https://github.com/manaflow-ai/cmux/releases/download/nightly-next/"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
# Every cmux-next item carries this sparkle:channel. Sparkle offers a
# channel-tagged item only to an updater that allows the channel, and only the
# cmux-next build does (UpdateFeedResolver.Channel.allowedSparkleChannels).
NEXT_SPARKLE_CHANNEL = "cmux-next"


class Refused(Exception):
    pass


def env(name):
    value = os.environ.get(name, "").strip()
    if not value and name != "NIGHTLY_NEXT_R2_PREFIX":
        raise Refused(f"{name} is not set")
    return value


def check_feed_url(url):
    base = env("NIGHTLY_NEXT_FEED_BASE").rstrip("/") + "/"
    if not base.startswith("https://") or base.startswith(MAIN_FEED_PREFIXES):
        raise Refused(f"NIGHTLY_NEXT_FEED_BASE {base} is not a separate https feed")
    if url.startswith(MAIN_FEED_PREFIXES):
        raise Refused(f"feed {url} is a main release feed")
    if not url.startswith(base):
        raise Refused(f"feed {url} is outside {base}")


def check_appcast(path):
    try:
        root = ET.parse(path).getroot()
    except (OSError, ET.ParseError) as error:
        raise Refused(f"{path}: {error}") from error
    urls = []
    for element in root.iter():
        url = element.get("url")
        if url is not None and element.tag in ("enclosure", f"{{{SPARKLE_NS}}}enclosure"):
            urls.append(url)
    if not urls:
        raise Refused(f"{path} has no enclosures")
    items = list(root.iter("item"))
    for item in items:
        channels = [c.text for c in item.findall(f"{{{SPARKLE_NS}}}channel")]
        if channels != [NEXT_SPARKLE_CHANNEL]:
            raise Refused(f"{path} item channel {channels} is not [{NEXT_SPARKLE_CHANNEL!r}]")
    for url in urls:
        if not url.startswith(NEXT_DOWNLOAD_PREFIX):
            raise Refused(f"{path} enclosure {url} is not a nightly-next download")
        name = url[len(NEXT_DOWNLOAD_PREFIX):]
        if "/" in name or not name.startswith("cmux-nightly-next-macos-"):
            raise Refused(f"{path} enclosure {url} is not a cmux-nightly-next DMG or delta")


def check_r2_key(bucket, key):
    allowed_bucket = env("NIGHTLY_NEXT_R2_BUCKET")
    prefix = env("NIGHTLY_NEXT_R2_PREFIX")
    if bucket != allowed_bucket:
        raise Refused(f"bucket {bucket} is not NIGHTLY_NEXT_R2_BUCKET {allowed_bucket}")
    if bucket == MAIN_BUCKET and not prefix.startswith("nightly-next/"):
        raise Refused(f"in {MAIN_BUCKET} the prefix must be nightly-next/, got {prefix!r}")
    if not key.startswith(prefix) or ".." in key.split("/"):
        raise Refused(f"key {key} is outside prefix {prefix!r}")
    if bucket == MAIN_BUCKET and key.startswith(MAIN_OBJECT_PREFIXES):
        raise Refused(f"key {key} is a main release object")


def main(argv):
    try:
        if len(argv) == 2 and argv[0] == "feed-url":
            check_feed_url(argv[1])
        elif len(argv) == 2 and argv[0] == "appcast":
            check_appcast(argv[1])
        elif len(argv) == 3 and argv[0] == "r2-key":
            check_r2_key(argv[1], argv[2])
        else:
            print("usage: nightly-next-guard.py feed-url URL | appcast FILE | r2-key BUCKET KEY", file=sys.stderr)
            return 2
    except Refused as refusal:
        print(f"nightly-next guard refused: {refusal}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
