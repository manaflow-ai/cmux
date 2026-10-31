#!/usr/bin/env python3
"""Compose the cmux NEXT Edge feed (plans/cmux-next/edge-ring-DESIGN.md, step E1).

Edge is the team ring that gets each signed build before notarization. Its
feed, `nightly-next/edge/appcast-arm64.xml`, is separate from the cmux NEXT
feed: only a Mac on Edge reads it (the updater's feed override), so no other
app can see an unnotarized item whatever its channel filter. Its items carry
no `sparkle:channel` for the same reason: the feed itself is the ring.

  compose --new FILE [--feed FILE] [--pulled FILE] [--keep N] --out FILE
      FILE --new is the new build's appcast (the generator's output, one or
      more items). --feed is the current Edge feed, if any. The result is the
      new build's channel header with the union of items: one per
      sparkle:version (the new build's wins), newest first, at most N (10),
      every pulled build dropped (pulled.json: [{"build": ...}]). Every item
      must have a numeric sparkle:version and an enclosure with a
      sparkle:edSignature; an item without one refuses the whole feed, so a
      bad build never replaces a good feed. Prints {"builds": [...],
      "dropped": [...]}.
"""

from __future__ import annotations

import argparse
import json
import re
import sys

ITEM = re.compile(r"[ \t]*<item>.*?</item>[ \t]*\n?", re.S)
VERSION = re.compile(r"<sparkle:version>\s*([^<]*?)\s*</sparkle:version>")
SIGNED_ENCLOSURE = re.compile(r"<enclosure\b[^>]*\bsparkle:edSignature=\"[A-Za-z0-9+/=]{40,}\"", re.S)
CHANNEL = re.compile(r"[ \t]*<sparkle:channel>[^<]*</sparkle:channel>[ \t]*\n?")
KEEP = 10


class Refused(Exception):
    pass


def items(feed: str) -> list[str]:
    return ITEM.findall(feed)


def build_of(item: str) -> str:
    version = VERSION.search(item)
    if version is None or not version.group(1).isdigit():
        raise Refused(f"an item has no numeric sparkle:version: {item[:200]!r}")
    return version.group(1)


def checked(item: str) -> str:
    build = build_of(item)
    if not SIGNED_ENCLOSURE.search(item):
        raise Refused(f"build {build} has no enclosure with a sparkle:edSignature")
    return CHANNEL.sub("", item)


def pulled_builds(text: str | None) -> set[str]:
    if not text:
        return set()
    entries = json.loads(text)
    if not isinstance(entries, list):
        raise Refused("pulled.json is not a list")
    return {str(entry["build"]) for entry in entries if isinstance(entry, dict) and "build" in entry}


def compose(new: str, current: str | None, pulled: set[str], keep: int = KEEP) -> tuple[str, list[str], list[str]]:
    fresh = items(new)
    if not fresh:
        raise Refused("the new build's appcast has no item")
    by_build: dict[str, str] = {}
    for item in items(current or "") + fresh:
        by_build[build_of(item)] = checked(item)
    ordered = sorted(by_build, key=int, reverse=True)
    dropped = [build for build in ordered if build in pulled]
    kept = [build for build in ordered if build not in pulled]
    dropped += kept[keep:]
    kept = kept[:keep]
    head = new[: new.index(fresh[0])] if fresh[0] in new else new
    tail = new[new.rindex(fresh[-1]) + len(fresh[-1]):]
    body = "".join(item if item.endswith("\n") else item + "\n" for item in (by_build[build] for build in kept))
    return head + body + tail, kept, dropped


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("compose")
    run.add_argument("--new", required=True)
    run.add_argument("--feed")
    run.add_argument("--pulled")
    run.add_argument("--keep", type=int, default=KEEP)
    run.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    try:
        if args.keep < 1:
            raise Refused("--keep must be at least 1")
        with open(args.new, encoding="utf-8") as handle:
            new = handle.read()
        current = None
        if args.feed:
            with open(args.feed, encoding="utf-8") as handle:
                current = handle.read()
        pulled_text = None
        if args.pulled:
            with open(args.pulled, encoding="utf-8") as handle:
                pulled_text = handle.read()
        feed, kept, dropped = compose(new, current, pulled_builds(pulled_text), args.keep)
    except (Refused, OSError, ValueError, KeyError) as error:
        print(f"edge_feed: {error}", file=sys.stderr)
        return 1
    with open(args.out, "w", encoding="utf-8") as handle:
        handle.write(feed)
    print(json.dumps({"builds": kept, "dropped": dropped}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
