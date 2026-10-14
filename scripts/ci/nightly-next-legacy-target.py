#!/usr/bin/env python3
"""Print the cmux NEXT build the cmux NIGHTLY-identity old feed must get (cx-x7hwx).

Usage: nightly-next-legacy-target.py <next-appcast> <old-appcast> <dmg-prefix>

Prints the newest sparkle:version on the cmux NEXT feed when it is newer than
every build on the old feed, else an empty line. It does not matter which run
published that build (publish-nightly, recovery of a build Apple accepted late,
or a nightly_next_continue_only run). Fails when the cmux NEXT feed has no items
or the newest item's enclosure is not the exact <dmg-prefix><build>.dmg.
"""
import re
import sys
import xml.etree.ElementTree as ET

NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def items(path):
    out = []
    for item in ET.parse(path).getroot().iter("item"):
        version = (item.findtext(f"{NS}version") or "").strip()
        enclosure = item.find("enclosure")
        if re.fullmatch(r"\d+", version) and enclosure is not None:
            out.append((int(version), enclosure.get("url", "")))
    return out


def main(argv):
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    next_path, old_path, prefix = argv
    next_items = items(next_path)
    if not next_items:
        print("cmux NEXT feed has no items", file=sys.stderr)
        return 1
    newest, url = max(next_items)
    current = max((version for version, _ in items(old_path)), default=0)
    expected = f"{prefix}{newest}.dmg"
    if url.rsplit("/", 1)[-1] != expected:
        print(f"cmux NEXT build {newest} enclosure is {url}, not {expected}", file=sys.stderr)
        return 1
    print(newest if newest > current else "")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
