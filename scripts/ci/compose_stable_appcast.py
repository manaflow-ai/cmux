#!/usr/bin/env python3
"""Compose the stable Sparkle feeds from three single-item appcasts.

Every stable install reads the legacy `appcast.xml`. Since stable ships thin
arm64 and x86_64 DMGs next to the universal one, that feed carries all three
items at one version, ordered so each installed Sparkle picks the right one:

1. universal, with `sparkle:minimumUpdateVersion` set past any real build.
   Sparkle 2.9+ drops the item; Sparkle 2.8.1 (cmux builds from June to
   August 2026) ignores the element and takes it because it comes first, so
   those installs stay universal instead of guessing an architecture.
2. arm64, with `sparkle:hardwareRequirements` arm64. Sparkle 2.9+ drops it
   only in a native Intel process; Apple silicon, Rosetta included, takes it.
3. x86_64, which a Sparkle 2.9+ Intel Mac takes once item 2 is dropped.

Sparkle selects the first item among equal versions, so the order is part of
the contract. The per-architecture feeds (`appcast-arm64.xml`,
`appcast-x86_64.xml`) keep their single item; the arm64 one also carries the
hardware requirement so an Intel process can never install it.

Usage:
  compose_stable_appcast.py --universal appcast-universal.xml \
      --arm64 appcast-arm64.xml --x86_64 appcast-x86_64.xml --out appcast.xml
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# Higher than any CFBundleVersion cmux will ship, so Sparkle 2.9+ never offers
# the universal item to an installed app.
UNIVERSAL_MINIMUM_UPDATE_VERSION = "999999999"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ITEM = re.compile(r"(?P<indent>[ \t]*)<item>(?P<body>.*?)</item>", re.S)
VERSION = re.compile(r"<sparkle:version>([^<]+)</sparkle:version>")
ENCLOSURE_URL = re.compile(r'<enclosure[^>]*\burl="([^"]+)"')


class AppcastError(Exception):
    pass


def single_item(xml: str, expected_dmg: str, label: str) -> re.Match[str]:
    items = list(ITEM.finditer(xml))
    if len(items) != 1:
        raise AppcastError(f"{label} appcast must hold exactly one item, found {len(items)}")
    body = items[0].group("body")
    if "sparkle:edSignature=" not in body:
        raise AppcastError(f"{label} appcast item has no sparkle:edSignature")
    urls = ENCLOSURE_URL.findall(body)
    if len(urls) != 1 or not urls[0].endswith("/" + expected_dmg):
        raise AppcastError(f"{label} appcast must enclose {expected_dmg}, found {urls}")
    if not VERSION.search(body):
        raise AppcastError(f"{label} appcast item has no sparkle:version")
    return items[0]


def with_element(item: re.Match[str], element: str) -> str:
    """Returns the item with `element` added before its enclosure."""
    indent = item.group("indent")
    body = item.group("body")
    child_indent = indent + "    "
    position = body.index("<enclosure")
    line_start = body.rfind("\n", 0, position) + 1
    body = body[:line_start] + f"{child_indent}{element}\n" + body[line_start:]
    return f"{indent}<item>{body}</item>"


def compose(universal: str, arm64: str, x86_64: str) -> tuple[str, str]:
    """Returns (legacy appcast.xml, arm64 appcast with its hardware requirement)."""
    universal_item = single_item(universal, "cmux-macos.dmg", "universal")
    arm64_item = single_item(arm64, "cmux-macos-arm64.dmg", "arm64")
    x86_64_item = single_item(x86_64, "cmux-macos-x86_64.dmg", "x86_64")
    versions = {VERSION.search(item.group("body")).group(1) for item in (universal_item, arm64_item, x86_64_item)}
    if len(versions) != 1:
        raise AppcastError(f"all three items must share one sparkle:version, found {sorted(versions)}")
    if SPARKLE_NS not in universal:
        raise AppcastError("universal appcast does not declare the sparkle namespace")

    requirement = "<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>"
    arm64_with_requirement = with_element(arm64_item, requirement)
    items = "\n".join([
        with_element(
            universal_item,
            f"<sparkle:minimumUpdateVersion>{UNIVERSAL_MINIMUM_UPDATE_VERSION}</sparkle:minimumUpdateVersion>",
        ),
        arm64_with_requirement,
        f"{x86_64_item.group('indent')}<item>{x86_64_item.group('body')}</item>",
    ])
    legacy = universal[: universal_item.start()] + items + universal[universal_item.end():]
    arm64_feed = arm64[: arm64_item.start()] + arm64_with_requirement + arm64[arm64_item.end():]
    return legacy, arm64_feed


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--universal", type=Path, required=True)
    parser.add_argument("--arm64", type=Path, required=True)
    parser.add_argument("--x86_64", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        legacy, arm64_feed = compose(
            args.universal.read_text(encoding="utf-8"),
            args.arm64.read_text(encoding="utf-8"),
            args.x86_64.read_text(encoding="utf-8"),
        )
    except AppcastError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    args.out.write_text(legacy, encoding="utf-8")
    args.arm64.write_text(arm64_feed, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
