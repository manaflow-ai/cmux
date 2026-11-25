#!/usr/bin/env python3
"""Sparkle deltas on the nightly-next feed: drop the ones R2 does not serve, and check the live feed has them.

A Mac on cmux NIGHTLY downloads a delta only when the newest item lists one from its installed build
(sparkle:deltas, matched on sparkle:deltaFrom); with no delta from its build, or a delta that fails to apply,
Sparkle downloads the full DMG on its own. A delta is 13-35 MB where the DMG is 243 MB (run 44152453711,
2026-11-17: 13.6 MB from the previous build, 16.4 MB from three builds back, 34.3 MB from a day back).

On 2026-11-17 republish-nightly-deltas of run 44152453711 built five deltas, one R2 upload of them failed
(Connection reset by peer, four tries), and the step's set -e dropped all five: the feed stayed full-only.

prune FEED --base URL
    Removes from FEED each delta enclosure whose URL is not under URL (an upload that failed keeps the
    GitHub release URL, where nightly-next never uploads deltas), and drops an emptied sparkle:deltas.
    Prints what it kept and dropped. Exit 0.

check --feed-url URL --build N [--min-deltas 1] [--full-length BYTES]
    The detector. Reads the live feed. When its newest item is build N, that item must list at least
    --min-deltas deltas, and each must serve its declared length at its URL. Prints each delta's size
    beside the full archive's. Exit 1 on a missing or unserved delta, so the publish that wrote the feed
    fails red; exit 0 with a notice when a newer build already serves (its own tail owns its deltas).

keep-item FEED --build N
    nightly-next-one's appcast step: generate_appcast writes one item per archive it was given, the earlier
    builds' too. Keeps only build N's item (with its sparkle:deltas); the feed write merges the live items.

merge LIVE GENERATED --build N --out PATH
    The tail (older bases, ~1 and ~3 days): adds GENERATED's delta enclosures for build N to LIVE's item for
    build N, skipping a sparkle:deltaFrom LIVE already lists, so the nearest deltas the publication shipped
    stay byte for byte. Exit 1 when LIVE has no item for build N.

usage: nightly_next_delta_check.py newest --feed-url URL --build N   (exit 0 only while N is the feed's newest)
       nightly_next_delta_check.py prune FEED --base URL
       nightly_next_delta_check.py check --feed-url URL --build N [--min-deltas 1]
       nightly_next_delta_check.py keep-item FEED --build N
       nightly_next_delta_check.py merge LIVE GENERATED --build N --out PATH
"""
from __future__ import annotations

import argparse
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
import deadline_http  # noqa: E402

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
S = f"{{{SPARKLE_NS}}}"
USER_AGENT = "cmux-delta-check/1"
DELTAS_BLOCK = re.compile(r"(\s*<sparkle:deltas>)(.*?)(\s*</sparkle:deltas>)", re.S)
DELTA_ENCLOSURE = re.compile(r"\s*<enclosure\b[^>]*?/>", re.S)
URL_ATTR = re.compile(r'\burl="([^"]+)"')


def prune(feed: Path, base: str) -> tuple[list[str], list[str]]:
    """Text edit, so every other byte of the signed feed stays as generate_appcast wrote it."""
    text = feed.read_text(encoding="utf-8")
    kept: list[str] = []
    dropped: list[str] = []

    def block(match: re.Match) -> str:
        def enclosure(m: re.Match) -> str:
            url = URL_ATTR.search(m.group(0))
            name = url.group(1) if url else ""
            if name.startswith(base):
                kept.append(name)
                return m.group(0)
            dropped.append(name)
            return ""

        inner = DELTA_ENCLOSURE.sub(enclosure, match.group(2))
        return "" if not DELTA_ENCLOSURE.search(inner) else match.group(1) + inner + match.group(3)

    feed.write_text(DELTAS_BLOCK.sub(block, text), encoding="utf-8")
    return kept, dropped


ITEM = re.compile(r"[ \t]*<item>.*?</item>[ \t]*\n?", re.S)
ITEM_VERSION = re.compile(r"<sparkle:version>\s*(\d+)\s*</sparkle:version>")
DELTA_FROM = re.compile(r'sparkle:deltaFrom="(\d+)"')


def _item_for(text: str, build: int) -> re.Match | None:
    return next((m for m in ITEM.finditer(text)
                 if (v := ITEM_VERSION.search(m.group(0))) and int(v.group(1)) == build), None)


def keep_item(feed: Path, build: int) -> int:
    text = feed.read_text(encoding="utf-8")
    ours = _item_for(text, build)
    if ours is None:
        raise SystemExit(f"{feed}: no item for build {build}")
    others = [m for m in ITEM.finditer(text) if m.start() != ours.start()]
    for match in reversed(others):
        text = text[:match.start()] + text[match.end():]
    feed.write_text(text, encoding="utf-8")
    return len(others)


def merge(live: str, generated: str, build: int) -> tuple[str, list[str]]:
    ours, theirs = _item_for(live, build), _item_for(generated, build)
    if ours is None:
        raise SystemExit(f"the live feed has no item for build {build}")
    if theirs is None:
        return live, []
    have = set(DELTA_FROM.findall(ours.group(0)))
    block = DELTAS_BLOCK.search(theirs.group(0))
    new = DELTA_ENCLOSURE.findall(block.group(2)) if block else []
    new = [e for e in new if (m := DELTA_FROM.search(e)) and m.group(1) not in have]
    if not new:
        return live, []
    item = ours.group(0)
    existing = DELTAS_BLOCK.search(item)
    if existing:
        item = item[:existing.end(2)] + "".join(new) + item[existing.end(2):]
    else:
        close = item.rindex("</item>")
        item = (item[:close] + "    <sparkle:deltas>" + "".join(new) + "\n            </sparkle:deltas>\n        "
                + item[close:])
    added = [DELTA_FROM.search(e).group(1) for e in new]
    return live[:ours.start()] + item + live[ours.end():], added


def newest_item(xml: bytes) -> ET.Element | None:
    items = list(ET.fromstring(xml).iter("item"))

    def build(item: ET.Element) -> int:
        version = (item.findtext(f"{S}version") or "").strip()
        return int(version) if version.isdigit() else -1

    return max(items, key=build, default=None)


def http_length(url: str) -> int | None:
    request = urllib.request.Request(url, method="HEAD", headers={"User-Agent": USER_AGENT})
    try:
        status, _, headers = deadline_http.request(request, 30)
        if status != 200:
            return None
        length = headers.get("Content-Length")
        return int(length) if length and length.isdigit() else None
    except Exception:  # an unserved delta is the finding, whatever the error
        return None


def fetch(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Cache-Control": "no-cache"})
    _, body, _ = deadline_http.request(request, 30, raise_errors=True)
    return body


def check(xml: bytes, build: int, min_deltas: int, served: Callable[[str], int | None]) -> tuple[int, list[str]]:
    lines: list[str] = []
    item = newest_item(xml)
    if item is None:
        return 1, ["the feed has no item"]
    live = (item.findtext(f"{S}version") or "").strip()
    if live != str(build):
        return 0, [f"notice: the feed serves build {live}, not {build}; its own publication owns its deltas"]
    full = item.find("enclosure")
    full_length = int(full.get("length") or 0) if full is not None else 0
    deltas = item.findall(f"{S}deltas/enclosure")
    lines.append(f"build {build}: full archive {full_length / 1e6:.1f} MB, {len(deltas)} delta(s)")
    failures = 0
    for delta in deltas:
        url = delta.get("url") or ""
        source = delta.get(f"{S}deltaFrom") or "?"
        declared = int(delta.get("length") or 0)
        live_length = served(url)
        share = f", {100 * declared / full_length:.1f}% of the full archive" if full_length else ""
        if live_length != declared or not delta.get(f"{S}edSignature"):
            failures += 1
            lines.append(f"  from {source}: {declared / 1e6:.1f} MB declared, served {live_length} at {url}: UNSERVED")
        else:
            lines.append(f"  from {source}: {declared / 1e6:.1f} MB{share}")
    if len(deltas) < min_deltas:
        lines.append(f"error: build {build} lists {len(deltas)} delta(s), expected at least {min_deltas}: "
                     "every Mac on the feed downloads the full archive")
        return 1, lines
    if failures:
        lines.append(f"error: {failures} delta(s) of build {build} are not served at their length")
        return 1, lines
    return 0, lines


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    pr = sub.add_parser("prune")
    pr.add_argument("feed", type=Path)
    pr.add_argument("--base", required=True)
    ch = sub.add_parser("check")
    ch.add_argument("--feed-url", required=True)
    ch.add_argument("--build", type=int, required=True)
    ch.add_argument("--min-deltas", type=int, default=1)
    ki = sub.add_parser("keep-item")
    ki.add_argument("feed", type=Path)
    ki.add_argument("--build", type=int, required=True)
    nw = sub.add_parser("newest")
    nw_src = nw.add_mutually_exclusive_group(required=True)
    nw_src.add_argument("--feed-url")
    nw_src.add_argument("--feed-file", type=Path)
    nw.add_argument("--build", type=int, required=True)
    mg = sub.add_parser("merge")
    mg.add_argument("live", type=Path)
    mg.add_argument("generated", type=Path)
    mg.add_argument("--build", type=int, required=True)
    mg.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)
    if args.command == "keep-item":
        dropped = keep_item(args.feed, args.build)
        print(f"{args.feed.name}: kept build {args.build}'s item, dropped {dropped} earlier item(s)")
        return 0
    if args.command == "newest":
        # Exit 0 only while the live feed's newest item is this build: the post-feed delta part stops at once
        # otherwise (a newer build's own publication owns its deltas).
        # --feed-file: the merged feed about to be written, so the write's newest is checked, not only the live one.
        item = newest_item(args.feed_file.read_bytes() if args.feed_file else fetch(args.feed_url))
        version = (item.findtext(f"{S}version") or "").strip() if item is not None else ""
        print(f"live feed's newest build is {version or 'unknown'}; this build is {args.build}")
        return 0 if version == str(args.build) else 1
    if args.command == "merge":
        text, added = merge(args.live.read_text(encoding="utf-8"), args.generated.read_text(encoding="utf-8"),
                            args.build)
        args.out.write_text(text, encoding="utf-8")
        print(f"build {args.build}: added deltas from {', '.join(added) or 'no new base'} to the live item")
        return 0
    if args.command == "prune":
        kept, dropped = prune(args.feed, args.base if args.base.endswith("/") else args.base + "/")
        for url in dropped:
            print(f"::warning::{args.feed.name}: dropped delta {url}: not on {args.base} (its upload failed)")
        print(f"{args.feed.name}: {len(kept)} delta(s) kept, {len(dropped)} dropped")
        return 0
    status, lines = check(fetch(args.feed_url), args.build, args.min_deltas, http_length)
    for line in lines:
        print(f"::error::{line[len('error: '):]}" if line.startswith("error: ") else line)
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
