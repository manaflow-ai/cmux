#!/usr/bin/env python3
"""The cmux NEXT DEV tip feed (cmux-next-dev-daily.yml, job tip).

    tip_feed.py previous FEED --build N --keep K
        Reads the live feed. Prints "fresh" and then the DMG URLs of the newest
        K-1 items (the bases the new build's deltas start from), or
        "stale <newest>" when the feed already has build N or a newer one, so
        the feed never rolls back.

    tip_feed.py check FEED --build N
        Fails unless the generated feed offers build N, every item is signed,
        untagged (every ring accepts it) and served from the tip prefix.
"""

from __future__ import annotations

import argparse
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
TIP_PREFIX = "https://files.cmux.com/nightly-next/tip/"


def _attr(element: ET.Element, name: str) -> str | None:
    return element.get(f"{{{SPARKLE}}}{name}")


def items(feed: str) -> list[dict]:
    """Each item's build, DMG URL, signature and channel, newest first."""
    root = ET.parse(feed).getroot()
    found = []
    for item in root.iter("item"):
        enclosure = item.find("enclosure")
        if enclosure is None:
            continue
        version = item.findtext(f"{{{SPARKLE}}}version") or _attr(enclosure, "version") or ""
        if not version.strip().isdigit():
            continue
        found.append({
            "build": int(version.strip()),
            "url": enclosure.get("url", ""),
            "signed": bool(_attr(enclosure, "edSignature")),
            "channel": item.findtext(f"{{{SPARKLE}}}channel"),
            "deltas": [
                delta.get("url", "")
                for delta in item.findall(f"{{{SPARKLE}}}deltas/enclosure")
            ],
        })
    return sorted(found, key=lambda entry: entry["build"], reverse=True)


def previous(feed: str, build: int, keep: int) -> list[str]:
    entries = items(feed)
    if entries and entries[0]["build"] >= build:
        return [f"stale {entries[0]['build']}"]
    bases = [
        entry["url"] for entry in entries
        if entry["url"].startswith(TIP_PREFIX) and entry["url"].endswith(".dmg")
    ]
    return ["fresh", *bases[: max(keep - 1, 0)]]


def check(feed: str, build: int) -> list[str]:
    entries = items(feed)
    problems = []
    if not entries or entries[0]["build"] != build:
        problems.append(f"the newest item is not build {build}")
    for entry in entries:
        name = f"build {entry['build']}"
        if not entry["signed"]:
            problems.append(f"{name} has no sparkle:edSignature")
        if entry["channel"]:
            problems.append(f"{name} is tagged {entry['channel']!r}; tip items stay untagged")
        for url in [entry["url"], *entry["deltas"]]:
            if not url.startswith(TIP_PREFIX):
                problems.append(f"{name} names {url}, outside {TIP_PREFIX}")
    return problems


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    prev = sub.add_parser("previous")
    prev.add_argument("feed")
    prev.add_argument("--build", type=int, required=True)
    prev.add_argument("--keep", type=int, required=True)
    chk = sub.add_parser("check")
    chk.add_argument("feed")
    chk.add_argument("--build", type=int, required=True)
    args = parser.parse_args(argv)
    if args.command == "previous":
        print("\n".join(previous(args.feed, args.build, args.keep)))
        return 0
    problems = check(args.feed, args.build)
    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
