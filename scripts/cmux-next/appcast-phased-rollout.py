#!/usr/bin/env python3
"""Roll this release's appcast item out in phases (Sparkle's phased rollout).

  appcast-phased-rollout.py APPCAST.xml DMG_NAME SECONDS

Sets <sparkle:phasedRolloutInterval>SECONDS</sparkle:phasedRolloutInterval> on the one item whose
enclosure file is DMG_NAME. Sparkle splits installs into 7 groups and offers the item to one more
group every SECONDS after the item's pubDate (86400: about a seventh of automatic updaters a day,
everyone after a week). It applies only to automatic checks: "Check for Updates…" always offers it.
The item must carry a pubDate, or Sparkle ignores the interval, so this refuses one without it.
The EdDSA signature covers the archive, not the item, so it stays valid. Running it twice changes
nothing. release.yml runs it when vars.CMUX_STABLE_PHASED_ROLLOUT_INTERVAL is set
(docs/cmux-next/release-channels.md).
"""
import re
import sys
import urllib.parse
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("dc", "http://purl.org/dc/elements/1.1/")


def phase(path: str, dmg_name: str, seconds: str) -> int:
    if not re.fullmatch(r"[1-9][0-9]{0,7}", seconds):
        sys.exit(f"SECONDS must be a positive whole number of seconds, got {seconds!r}")
    if "/" in dmg_name or not dmg_name:
        sys.exit(f"DMG_NAME is a file name, got {dmg_name!r}")
    names = {dmg_name, urllib.parse.quote(dmg_name)}
    tree = ET.parse(path)
    items = [i for i in tree.getroot().iter("item")
             if i.find("enclosure") is not None
             and i.find("enclosure").get("url", "").rsplit("/", 1)[-1] in names]
    if len(items) != 1:
        sys.exit(f"{path}: expected one {dmg_name} item, found {len(items)}")
    item = items[0]
    if not (item.findtext("pubDate") or "").strip():
        sys.exit(f"{path}: the {dmg_name} item has no pubDate; Sparkle would ignore the rollout interval")
    tag = f"{{{SPARKLE}}}phasedRolloutInterval"
    element = item.find(tag)
    if element is None:
        element = ET.SubElement(item, tag)
    element.text = seconds
    tree.write(path, xml_declaration=True, encoding="utf-8")
    print(f"{path}: the {dmg_name} item rolls out to one of 7 groups every {seconds} s")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    raise SystemExit(phase(*sys.argv[1:]))
