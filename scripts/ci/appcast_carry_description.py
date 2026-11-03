#!/usr/bin/env python3
"""Copy one build's <description> from a published appcast into a regenerated one.

generate_appcast rewrites every item when it adds Sparkle deltas, which drops
the changelog that the publish step wrote into the build's <description>.
Usage: appcast_carry_description.py SOURCE_FEED TARGET_FEED BUILD
A source without a description for BUILD leaves the target unchanged.
"""
import sys
from xml.dom import minidom

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def item_for(doc, build):
    for item in doc.getElementsByTagName("item"):
        for version in item.getElementsByTagNameNS(SPARKLE, "version"):
            if version.firstChild and version.firstChild.nodeValue.strip() == build:
                return item
    return None


def main(source, target, build):
    src_item = item_for(minidom.parse(source), build)
    descriptions = [n for n in (src_item.childNodes if src_item else []) if n.nodeType == n.ELEMENT_NODE and n.tagName == "description"]
    if not descriptions:
        print(f"no description for {build} in {source}; {target} unchanged")
        return 0
    text = "".join(n.nodeValue for n in descriptions[0].childNodes if n.nodeType in (n.TEXT_NODE, n.CDATA_SECTION_NODE))
    doc = minidom.parse(target)
    item = item_for(doc, build)
    if item is None:
        raise SystemExit(f"{target} has no item for build {build}")
    for old in [n for n in item.childNodes if n.nodeType == n.ELEMENT_NODE and n.tagName == "description"]:
        item.removeChild(old)
    node = doc.createElement("description")
    node.appendChild(doc.createTextNode(text))
    item.appendChild(node)
    with open(target, "wb") as out:
        out.write(doc.toxml(encoding="utf-8"))
    print(f"carried the {build} description into {target}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    sys.exit(main(*sys.argv[1:]))
