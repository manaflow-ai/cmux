#!/usr/bin/env python3
"""Make the classic -> cmux-next handoff TEST appcast from a release.yml dry-run appcast.

  classic-handoff-test-feed.py --appcast DRYRUN/appcast.xml --dmg-url URL --out appcast.xml [--title T]

release.yml's dry run (workflow_dispatch on a non-tag ref) signs the DMG with the stable
Sparkle key and writes appcast.xml next to it, with an enclosure URL under a release tag
that does not exist. This keeps that item's EdDSA signature, length, versions and
minimumSystemVersion and points the enclosure at the test copy of the same DMG. The
signature covers the archive bytes, not the URL, so the item stays valid.

Refuses to write a feed that classic would not take or that looks like production:
  - exactly one item, with sparkle:edSignature and a numeric sparkle:version
  - no sparkle:channel (classic stable allows no channels, so it would skip the item)
  - the DMG URL is https and not under the production release paths
"""
import argparse, re, sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("dc", "http://purl.org/dc/elements/1.1/")
PRODUCTION = ("github.com/manaflow-ai/cmux/releases/", "files.cmux.com/stable/", "files.cmux.com/nightly/", "files.cmux.com/rc/")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--appcast", required=True)
    ap.add_argument("--dmg-url", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--title", default="cmux-next release candidate (TEST FEED)")
    a = ap.parse_args()
    if not a.dmg_url.startswith("https://") or any(p in a.dmg_url for p in PRODUCTION):
        sys.exit(f"refusing DMG URL {a.dmg_url}: must be https and outside the production feeds")
    tree = ET.parse(a.appcast)
    channel = tree.getroot().find("channel")
    items = channel.findall("item")
    if len(items) < 1:
        sys.exit("no <item> in the dry-run appcast")
    # The dry run may also carry a pinned legacy item (scripts/cmux-next/legacy-appcast-item.xml);
    # the RC is the item whose enclosure is this run's cmux-macos.dmg.
    ours = [i for i in items if (i.find("enclosure") is not None and i.find("enclosure").get("url", "").endswith("/cmux-macos.dmg"))]
    if len(ours) != 1:
        sys.exit(f"expected one cmux-macos.dmg item, found {len(ours)}")
    item = ours[0]
    for extra in [i for i in items if i is not item]:
        channel.remove(extra)
    if item.find(f"{{{SPARKLE}}}channel") is not None:
        sys.exit("the item has a sparkle:channel; classic stable would skip it")
    version = item.findtext(f"{{{SPARKLE}}}version") or ""
    enclosure = item.find("enclosure")
    if enclosure is None:
        sys.exit("the item has no enclosure")
    version = version or enclosure.get(f"{{{SPARKLE}}}version", "")
    if not re.fullmatch(r"\d+", version):
        sys.exit(f"sparkle:version is not a build number: {version!r}")
    if not enclosure.get(f"{{{SPARKLE}}}edSignature"):
        sys.exit("the enclosure has no sparkle:edSignature")
    enclosure.set("url", a.dmg_url)
    title = item.find("title")
    if title is not None:
        title.text = a.title
    channel.find("title").text = a.title
    tree.write(a.out, xml_declaration=True, encoding="utf-8")
    print(f"wrote {a.out}: build {version}, {enclosure.get('length')} bytes, {a.dmg_url}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
