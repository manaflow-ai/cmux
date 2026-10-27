#!/usr/bin/env python3
"""The cmux NEXT DEV tip feed (cmux-next-dev-daily.yml, job tip).

    tip_feed.py previous FEED --build N --keep K
        Reads the live feed. Prints "fresh" and then the DMG URLs of the newest
        K-1 items (the bases the new build's deltas start from), or
        "stale <newest>" when the feed already has build N or a newer one, so
        the feed never rolls back.

    tip_feed.py newest FEED
        Prints the newest build the live feed offers (0 when it offers none).

    tip_feed.py merge NEW LIVE --build N --keep K --out OUT
        Writes NEW's item for build N on top of LIVE's items (the feed as R2
        holds it now, kept verbatim), K items in all. The appcast generated
        from an earlier read of the feed may lack a build published since;
        merging with the latest read never drops one.

    tip_feed.py check FEED --build N
        Fails unless the generated feed offers build N, every item is signed,
        untagged (every ring accepts it) and served from the tip prefix.

    tip_feed.py bases FEED --build N --url URL --keep K
        For the deltas that follow a full-DMG publish: prints "ours" and then
        the DMG URLs of the newest K-1 items older than N, when the feed's
        newest item is build N served from URL and has no deltas yet. Prints
        "skip <why>" otherwise (a newer build, another attempt's DMG, build N
        gone, or deltas already there): then no deltas are added.

    tip_feed.py add-deltas NEW LIVE --build N --url URL --files DIR --out OUT
        Writes LIVE (the feed as R2 holds it now) verbatim, with NEW's
        <sparkle:deltas> for build N added to LIVE's item for build N. Every
        other item, a newer build included, stays byte for byte. Exits 4,
        writing nothing, when bases would print "skip"; fails unless NEW's
        item for N is the same signed DMG at URL and every delta it names is
        a file in DIR (uploaded before the feed names it).
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import urllib.parse
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


def newest(feed: str) -> int:
    entries = items(feed)
    return entries[0]["build"] if entries else 0


ITEM = re.compile(r"[ \t]*<item>.*?</item>[ \t]*\n?", re.S)
VERSION = re.compile(r"<sparkle:version>\s*(\d+)\s*</sparkle:version>")


def _build_of(item: str) -> int | None:
    match = VERSION.search(item) or re.search(r'sparkle:version="(\d+)"', item)
    return int(match.group(1)) if match else None


def merge(new: str, live: str | None, build: int, keep: int) -> str:
    """NEW's text with its items replaced by its item for `build` and then
    LIVE's older items, verbatim, `keep` items in all."""
    text = open(new, encoding="utf-8").read()
    ours = [item for item in ITEM.findall(text) if _build_of(item) == build]
    if len(ours) != 1:
        raise ValueError(f"the generated feed has {len(ours)} items for build {build}")
    older = []
    if live is not None:
        for item in ITEM.findall(open(live, encoding="utf-8").read()):
            other = _build_of(item)
            if other is None:
                continue
            if other >= build:
                raise ValueError(f"the live feed already has build {other}, not older than {build}")
            older.append((other, item))
    older.sort(key=lambda entry: entry[0], reverse=True)
    kept = [ours[0], *(item for _, item in older[: max(keep - 1, 0)])]
    first = ITEM.search(text)
    body = ITEM.sub("", text)
    return body[: first.start()] + "".join(kept) + body[first.start():]


class NothingToAdd(Exception):
    """The live feed's item for this build takes no deltas (bases says skip)."""


def bases(feed: str, build: int, url: str, keep: int) -> list[str]:
    entries = items(feed)
    if not entries:
        return ["skip the feed is empty"]
    top = entries[0]
    if top["build"] > build:
        return [f"skip the feed has a newer build {top['build']}"]
    if top["build"] != build:
        return [f"skip build {build} is not in the feed"]
    if top["url"] != url:
        return [f"skip the feed serves build {build} from {top['url']}, another attempt's DMG"]
    if top["deltas"]:
        return [f"skip build {build} already has deltas"]
    older = [
        entry["url"] for entry in entries[1:]
        if entry["build"] < build and entry["url"].startswith(TIP_PREFIX) and entry["url"].endswith(".dmg")
    ]
    return ["ours", *older[: max(keep - 1, 0)]]


DELTAS = re.compile(r"[ \t]*<sparkle:deltas>.*?</sparkle:deltas>[ \t]*\n?", re.S)
CLOSE = re.compile(r"[ \t]*</item>")


def _enclosure(item: str) -> dict:
    """The full-archive enclosure's attributes (the one outside <sparkle:deltas>)."""
    root = ET.fromstring(f'<rss xmlns:sparkle="{SPARKLE}">{item}</rss>')
    enclosure = root.find("item/enclosure")
    if enclosure is None:
        raise ValueError("an item has no enclosure")
    return {"url": enclosure.get("url", ""), "length": enclosure.get("length", ""),
            "signature": _attr(enclosure, "edSignature") or ""}


def add_deltas(new: str, live: str, build: int, url: str, files: str) -> str:
    """LIVE's text with NEW's deltas for `build` added to its item, nothing else changed."""
    live_text = open(live, encoding="utf-8").read()
    why = bases(live, build, url, 1)[0]
    if why != "ours":
        raise NothingToAdd(why)
    ours_live = [item for item in ITEM.findall(live_text) if _build_of(item) == build]
    ours_new = [item for item in ITEM.findall(open(new, encoding="utf-8").read()) if _build_of(item) == build]
    if len(ours_live) != 1 or len(ours_new) != 1:
        raise ValueError(f"build {build} has {len(ours_live)} live and {len(ours_new)} generated items")
    live_item, new_item = ours_live[0], ours_new[0]
    if _enclosure(new_item) != _enclosure(live_item):
        raise ValueError(f"the generated item for build {build} is not the signed DMG the feed serves")
    block = DELTAS.search(new_item)
    if not block:
        raise NothingToAdd(f"no deltas were generated for build {build}")
    root = ET.fromstring(f'<rss xmlns:sparkle="{SPARKLE}">{new_item}</rss>')
    names = [delta.get("url", "") for delta in root.findall(f"item/{{{SPARKLE}}}deltas/enclosure")]
    if not names:
        raise NothingToAdd(f"no deltas were generated for build {build}")
    for delta_url in names:
        name = urllib.parse.unquote(delta_url.rsplit("/", 1)[-1])
        if not delta_url.startswith(TIP_PREFIX) or not os.path.isfile(os.path.join(files, name)):
            raise ValueError(f"the deltas name {delta_url}, which this run did not upload")
    close = list(CLOSE.finditer(live_item))[-1]
    indent = re.match(r"[ \t]*", block.group(0)).group(0)
    merged_item = live_item[: close.start()] + indent + block.group(0).strip() + "\n" + live_item[close.start():]
    start = live_text.index(live_item)
    return live_text[:start] + merged_item + live_text[start + len(live_item):]


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
    new = sub.add_parser("newest")
    new.add_argument("feed")
    mrg = sub.add_parser("merge")
    mrg.add_argument("new")
    mrg.add_argument("live", help='the live feed, or "absent"')
    mrg.add_argument("--build", type=int, required=True)
    mrg.add_argument("--keep", type=int, required=True)
    mrg.add_argument("--out", required=True)
    chk = sub.add_parser("check")
    chk.add_argument("feed")
    chk.add_argument("--build", type=int, required=True)
    bas = sub.add_parser("bases")
    bas.add_argument("feed")
    bas.add_argument("--build", type=int, required=True)
    bas.add_argument("--url", required=True)
    bas.add_argument("--keep", type=int, required=True)
    add = sub.add_parser("add-deltas")
    add.add_argument("new")
    add.add_argument("live")
    add.add_argument("--build", type=int, required=True)
    add.add_argument("--url", required=True)
    add.add_argument("--files", required=True)
    add.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    if args.command == "bases":
        print("\n".join(bases(args.feed, args.build, args.url, args.keep)))
        return 0
    if args.command == "add-deltas":
        try:
            merged = add_deltas(args.new, args.live, args.build, args.url, args.files)
        except NothingToAdd as why:
            print(f"nothing to add: {why}", file=sys.stderr)
            return 4
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(merged)
        return 0
    if args.command == "previous":
        print("\n".join(previous(args.feed, args.build, args.keep)))
        return 0
    if args.command == "merge":
        merged = merge(args.new, None if args.live == "absent" else args.live, args.build, args.keep)
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(merged)
        return 0
    if args.command == "newest":
        print(newest(args.feed))
        return 0
    problems = check(args.feed, args.build)
    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
