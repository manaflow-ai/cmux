#!/usr/bin/env python3
"""Offer this release's cmux-macos.dmg item to Apple silicon Macs only.

  appcast-require-arm64.py APPCAST.xml [DMG_NAME]

DMG_NAME is the enclosure's file name (default cmux-macos.dmg, release.yml's stable item); the
cmux-next RC (nightly.yml, channel rc) passes its own immutable DMG name.

cmux-next is an Apple silicon app: its cmux-tui CLI and its Chromium engine ship for arm64
only (plans/cmux-next/classic-handoff-go-live-RUNBOOK.md, B0b and B6b). release.yml writes one
appcast for both architectures, so an Intel Mac running classic would take the cmux-next
update. Sparkle 2.9 and later (classic ships 2.9.5) skip an item whose
<sparkle:hardwareRequirements> names arm64 on a Mac without it, so Intel classic installs stay
on classic. Only the item whose enclosure is this run's cmux-macos.dmg changes; a pinned legacy
item keeps its own requirements. Running it twice changes nothing.
"""
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("dc", "http://purl.org/dc/elements/1.1/")


def require_arm64(path: str, dmg_name: str = "cmux-macos.dmg") -> int:
    tree = ET.parse(path)
    items = [i for i in tree.getroot().iter("item")
             if (i.find("enclosure") is not None and i.find("enclosure").get("url", "").endswith("/" + dmg_name))]
    if len(items) != 1:
        sys.exit(f"{path}: expected one {dmg_name} item, found {len(items)}")
    item = items[0]
    tag = f"{{{SPARKLE}}}hardwareRequirements"
    element = item.find(tag)
    if element is None:
        element = ET.SubElement(item, tag)
    words = (element.text or "").split()
    if "arm64" not in words:
        words.append("arm64")
    element.text = " ".join(words)
    tree.write(path, xml_declaration=True, encoding="utf-8")
    print(f"{path}: the {dmg_name} item requires {element.text}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and ("/" in sys.argv[2] or not sys.argv[2])):
        sys.exit(__doc__)
    raise SystemExit(require_arm64(*sys.argv[1:]))
