#!/usr/bin/env python3
"""Which release ring each cmux NEXT appcast item is on (its sparkle:channel).

One cmux NEXT feed serves every ring. The app accepts its own ring's tag and
every slower ring's (Packages/macOS/CmuxUpdater/Sources/CmuxUpdater/UpdateRing.swift):
Dev accepts `cmux-next-dev` and `cmux-next`, Nightly only `cmux-next`, and a
build from before rings allows only `cmux-next`. Sparkle never offers an item
whose channel the updater does not allow, so an item tagged `cmux-next-dev` is
invisible to Nightly and to every older build.

Repository variable NIGHTLY_NEXT_DEV_RING picks the mode:
  on   a new build is published as `cmux-next-dev` and moves to `cmux-next`
       once its durable canary verdict (verdicts/<build>.json next to the feed,
       nightly-next-verdict.yml) is `pass`; the same signal the train uses for
       its base.
  off  (unset or anything else) every item is `cmux-next`, as before rings.

The verdict documents are the one source of truth: every feed writer derives
each item's channel from them, so a writer that ran before a verdict landed is
corrected by the next one.

  channel --mode MODE
      the tag of a newly published build (no verdict yet)
  retag --feed FILE --out FILE --mode MODE --verdicts-base URL|DIR
      set every item's channel from its verdict; the rest of the feed is copied
      byte for byte. Prints {"changed": bool, "channels": {build: tag}}; writes
      FILE only when something changed.
  select --feed FILE --out FILE --channel TAG
      keep only the items on TAG. Prints {"kept": [...], "dropped": [...]};
      always writes FILE.
  legacy --new FILE [--current FILE] --out FILE --mode MODE --verdicts-base URL|DIR
      the old cmux NIGHTLY-identity feed after a build is copied to it: the
      new build's item and the current feed's items, one per build (the new
      build's wins), each tagged from its verdict as retag does, keeping the
      newest Nightly item and the newest LEGACY_DEV_ITEMS (5) Dev items above
      it, so a canary pass on any of them promotes it there too. Its
      installs follow updates.channel like cmux NEXT's (the same updater), so a
      Mac on Nightly always has a Nightly item to update to while Dev is ahead.
      Prints {"channels": {build: tag}, "dropped": [...]}; always writes FILE.

A verdict that cannot be read counts as no verdict: the item stays on Dev, the
side that never shows Nightly an unpromoted build.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

NIGHTLY = "cmux-next"
DEV = "cmux-next-dev"
# Every tag a cmux NEXT item may carry (UpdateRing.sparkleChannel). Main's
# builds allow none of them.
RING_CHANNELS = ("cmux-next-stable", NIGHTLY, "cmux-next-canary", DEV)
MODES = ("on", "off")
LEGACY_DEV_ITEMS = 5

ITEM = re.compile(r"[ \t]*<item>.*?</item>[ \t]*\n?", re.S)
VERSION = re.compile(r"<sparkle:version>\s*([^<]*?)\s*</sparkle:version>")
CHANNEL = re.compile(r"<sparkle:channel>[^<]*</sparkle:channel>")
EXTRA_CHANNEL = re.compile(r"[ \t]*\n?[ \t]*<sparkle:channel>[^<]*</sparkle:channel>")
OPEN = re.compile(r"<item>([ \t]*\n?)([ \t]*)")


class Refused(Exception):
    pass


def new_build_channel(mode: str) -> str:
    check_mode(mode)
    return DEV if mode == "on" else NIGHTLY


def check_mode(mode: str) -> None:
    if mode not in MODES:
        raise Refused(f"mode {mode!r} is not one of {', '.join(MODES)}")


def item_build(item: str) -> str:
    version = VERSION.search(item)
    if version is None or not version.group(1).isdigit():
        raise Refused(f"an item has no numeric sparkle:version: {item[:200]!r}")
    return version.group(1)


def set_channel(item: str, channel: str) -> str:
    first = CHANNEL.search(item)
    if first is not None:
        # Sparkle reads the first tag only; keep exactly one.
        head = item[:first.start()] + f"<sparkle:channel>{channel}</sparkle:channel>"
        return head + EXTRA_CHANNEL.sub("", item[first.end():])
    match = OPEN.search(item)
    newline, indent = match.group(1), match.group(2)
    if newline:
        inserted = f"<item>{newline}{indent}<sparkle:channel>{channel}</sparkle:channel>\n{indent}"
    else:
        inserted = f"<item><sparkle:channel>{channel}</sparkle:channel>"
    return item[:match.start()] + inserted + item[match.end():]


def retag(text: str, mode: str, verdict_of) -> tuple[str, dict]:
    """(new text, summary). verdict_of(build) is "pass", "fail", "skipped" or None."""
    check_mode(mode)
    out, last, channels = [], 0, {}
    found = list(ITEM.finditer(text))
    if not found:
        raise Refused("the feed has no items")
    for match in found:
        item = match.group(0)
        build = item_build(item)
        channel = NIGHTLY if mode == "off" or verdict_of(build) == "pass" else DEV
        channels[build] = channel
        out.append(text[last:match.start()])
        out.append(set_channel(item, channel))
        last = match.end()
    out.append(text[last:])
    new = "".join(out)
    return new, {"changed": new != text, "channels": channels}


def select(text: str, channel: str) -> tuple[str, dict]:
    if channel not in RING_CHANNELS:
        raise Refused(f"{channel!r} is not a ring channel")
    out, last, kept, dropped = [], 0, [], []
    for match in ITEM.finditer(text):
        item = match.group(0)
        build = item_build(item)
        tag = CHANNEL.search(item)
        out.append(text[last:match.start()])
        if tag is not None and tag.group(0) == f"<sparkle:channel>{channel}</sparkle:channel>":
            out.append(item)
            kept.append(build)
        else:
            dropped.append(build)
        last = match.end()
    out.append(text[last:])
    return "".join(out), {"kept": kept, "dropped": dropped}


def legacy(new: str, current: str | None, mode: str, verdict_of) -> tuple[str, dict]:
    check_mode(mode)
    fresh = [match.group(0) for match in ITEM.finditer(new)]
    if not fresh:
        raise Refused("the new build's appcast has no items")
    by_build: dict[str, str] = {}
    for item in [m.group(0) for m in ITEM.finditer(current or "")] + fresh:
        by_build[item_build(item)] = item
    channels = {build: NIGHTLY if mode == "off" or verdict_of(build) == "pass" else DEV for build in by_build}
    ordered = sorted(by_build, key=int, reverse=True)
    nightly = next((build for build in ordered if channels[build] == NIGHTLY), None)
    above = [build for build in ordered if channels[build] == DEV and (nightly is None or int(build) > int(nightly))]
    kept = [build for build in ordered if build == nightly or build in above[:LEGACY_DEV_ITEMS]]
    first = new.index(fresh[0])
    last = new.rindex(fresh[-1]) + len(fresh[-1])
    items = (set_channel(by_build[build], channels[build]) for build in kept)
    body = "".join(item if item.endswith("\n") else item + "\n" for item in items)
    text = new[:first] + body + new[last:]
    # Copied items may inherit prefixes from the old rss root (for example a
    # sourceCommit preserved by the delta writer). Keep those bindings too.
    old_root = re.search(r"<rss\b[^>]*>", current or "")
    new_root = re.search(r"<rss\b[^>]*>", text)
    if old_root and new_root:
        opening = new_root.group(0)
        for declaration in re.finditer(r'''\s+xmlns:([\w.-]+)\s*=\s*(["'])(.*?)\2''', old_root.group(0)):
            prefix = declaration.group(1)
            if re.search(rf"\bxmlns:{re.escape(prefix)}\s*=", opening) is None:
                opening = opening[:-1] + declaration.group(0) + ">"
        text = text[:new_root.start()] + opening + text[new_root.end():]
    return text, {"channels": {build: channels[build] for build in kept},
                  "dropped": [build for build in ordered if build not in kept]}


def verdict_reader(base: str):
    """verdict_of(build) from BASE/verdicts/<build>.json (an https URL or a directory)."""
    cache: dict[str, str | None] = {}

    def read(build: str) -> str | None:
        if build in cache:
            return cache[build]
        verdict = None
        try:
            if re.match(r"https?://", base):
                url = f"{base.rstrip('/')}/verdicts/{build}.json"
                request = urllib.request.Request(url, headers={
                    "User-Agent": "cmux-nightly-next-ring/1", "Cache-Control": "no-cache"})
                with urllib.request.urlopen(request, timeout=30) as response:
                    document = json.load(response)
            else:
                with open(os.path.join(base, "verdicts", f"{build}.json"), encoding="utf-8") as handle:
                    document = json.load(handle)
            if isinstance(document, dict) and str(document.get("build")) == build:
                verdict = document.get("verdict")
            else:
                print(f"warning: verdict document for {build} names another build; counted as none",
                      file=sys.stderr)
        except FileNotFoundError:
            pass
        except urllib.error.HTTPError as error:
            if error.code != 404:
                print(f"warning: verdict of {build}: HTTP {error.code}; counted as none", file=sys.stderr)
        except (OSError, ValueError) as error:
            print(f"warning: verdict of {build}: {error}; counted as none", file=sys.stderr)
        cache[build] = verdict
        return verdict

    return read


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    c = sub.add_parser("channel")
    c.add_argument("--mode", required=True)
    r = sub.add_parser("retag")
    r.add_argument("--feed", required=True)
    r.add_argument("--out", required=True)
    r.add_argument("--mode", required=True)
    r.add_argument("--verdicts-base", required=True)
    s = sub.add_parser("select")
    s.add_argument("--feed", required=True)
    s.add_argument("--out", required=True)
    s.add_argument("--channel", required=True)
    g = sub.add_parser("legacy")
    g.add_argument("--new", required=True)
    g.add_argument("--current")
    g.add_argument("--out", required=True)
    g.add_argument("--mode", required=True)
    g.add_argument("--verdicts-base", required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "channel":
            print(new_build_channel(args.mode))
            return 0
        if args.command == "legacy":
            with open(args.new, encoding="utf-8") as handle:
                fresh = handle.read()
            current = None
            if args.current:
                with open(args.current, encoding="utf-8") as handle:
                    current = handle.read()
            new, summary = legacy(fresh, current, args.mode, verdict_reader(args.verdicts_base))
            with open(args.out, "w", encoding="utf-8") as handle:
                handle.write(new)
            print(json.dumps(summary))
            return 0
        with open(args.feed, encoding="utf-8") as handle:
            text = handle.read()
        if args.command == "retag":
            new, summary = retag(text, args.mode, verdict_reader(args.verdicts_base))
            write = summary["changed"]
        else:
            new, summary = select(text, args.channel)
            write = True
    except (OSError, UnicodeDecodeError, Refused) as error:
        print(f"refused: {error}", file=sys.stderr)
        return 1
    if write:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(new)
    print(json.dumps(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
