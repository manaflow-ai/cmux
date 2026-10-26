#!/usr/bin/env python3
"""Give every item of a regenerated appcast the pubDate of its own first publish.

    appcast_keep_pubdates.py TARGET_FEED [--feed REFERENCE_FEED]... [--dates DATES_JSON]

generate_appcast rebuilds every item when it adds Sparkle deltas and dates each
one by its archive's modification time. The delta job downloads the earlier
builds just before, so every item in the nightly-next feed got the same
pubDate, the minute of the latest delta run (2026-10-26: three builds all dated
19:38:52Z). Sparkle and the app read pubDate (PendingDeltaWait holds a build
for a window after it), so a rewritten date also re-held older builds.

For each TARGET item, by its sparkle:version, the first source that knows it wins:
  --feed     an already published feed holding that item (the full feed this
             build was first published with, or the live feed), in the order given;
  --dates    a JSON object {"<build>": "<ISO 8601 time>"}, the release asset
             upload time of an earlier build (fetch-previous-nightly-dmgs.py --dates-out).
An item no source knows keeps the date generate_appcast gave it.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
from email.utils import format_datetime
import json
import sys
from xml.dom import minidom

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def version_of(item) -> str | None:
    for node in item.getElementsByTagNameNS(SPARKLE, "version"):
        if node.firstChild and node.firstChild.nodeValue.strip():
            return node.firstChild.nodeValue.strip()
    return None


def child(item, tag):
    return next((n for n in item.childNodes if n.nodeType == n.ELEMENT_NODE and n.tagName == tag), None)


def text_of(node) -> str:
    return "".join(n.nodeValue for n in node.childNodes if n.nodeType in (n.TEXT_NODE, n.CDATA_SECTION_NODE)).strip()


def feed_dates(path: str) -> dict[str, str]:
    dates: dict[str, str] = {}
    for item in minidom.parse(path).getElementsByTagName("item"):
        version, date = version_of(item), child(item, "pubDate")
        if version and date is not None and text_of(date) and version not in dates:
            dates[version] = text_of(date)
    return dates


def json_dates(path: str) -> dict[str, str]:
    dates: dict[str, str] = {}
    with open(path, encoding="utf-8") as stream:
        for build, stamp in json.load(stream).items():
            moment = datetime.fromisoformat(str(stamp).replace("Z", "+00:00"))
            if moment.tzinfo is None:
                moment = moment.replace(tzinfo=timezone.utc)
            dates[str(build)] = format_datetime(moment.astimezone(timezone.utc).replace(microsecond=0))
    return dates


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("target")
    parser.add_argument("--feed", action="append", default=[])
    parser.add_argument("--dates")
    args = parser.parse_args(argv)

    known: dict[str, str] = {}
    for path in args.feed:
        for version, date in feed_dates(path).items():
            known.setdefault(version, date)
    if args.dates:
        for version, date in json_dates(args.dates).items():
            known.setdefault(version, date)

    doc = minidom.parse(args.target)
    kept = 0
    for item in doc.getElementsByTagName("item"):
        version = version_of(item)
        if version is None or version not in known:
            continue
        node = child(item, "pubDate")
        if node is None:
            node = doc.createElement("pubDate")
            item.appendChild(node)
        if text_of(node) == known[version]:
            continue
        while node.firstChild:
            node.removeChild(node.firstChild)
        node.appendChild(doc.createTextNode(known[version]))
        kept += 1
    with open(args.target, "wb") as out:
        out.write(doc.toxml(encoding="utf-8"))
    print(f"kept the first-publish pubDate of {kept} item(s) in {args.target}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
