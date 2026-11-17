#!/usr/bin/env python3
"""Print the newest Sparkle build (sparkle:version) an appcast lists.

Usage: live_appcast_build.py URL_OR_PATH
Exit 3 when the URL answers 404 (no feed published yet), 1 when the feed cannot
be read or lists no numeric build: callers fail closed on 1. The nightly
publication guards (auto-resume-nightly-notarization.yml) use it to refuse a
build older than the one the live feed serves: push runs build in parallel,
so an older run can reach publication after a newer one.
"""

from __future__ import annotations

import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET


def newest_build(data: bytes) -> int | None:
    root = ET.fromstring(data)
    builds = []
    for item in root.iter():
        if item.tag.rsplit("}", 1)[-1] != "item":
            continue
        for child in item:
            if child.tag.rsplit("}", 1)[-1] == "version" and (child.text or "").strip().isdigit():
                builds.append(int(child.text.strip()))
        for enclosure in item:
            if enclosure.tag.rsplit("}", 1)[-1] != "enclosure":
                continue
            for key, value in enclosure.attrib.items():
                if key.rsplit("}", 1)[-1] == "version" and value.strip().isdigit():
                    builds.append(int(value.strip()))
    return max(builds) if builds else None


def read(source: str) -> bytes:
    if source.startswith(("https://", "http://")):
        request = urllib.request.Request(source, headers={"User-Agent": "cmux-publication-guard/1", "Cache-Control": "no-cache"})
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.read()
    with open(source, "rb") as handle:
        return handle.read()


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        build = newest_build(read(argv[1]))
    except urllib.error.HTTPError as error:
        print(f"could not read {argv[1]}: {error}", file=sys.stderr)
        return 3 if error.code == 404 else 1
    except Exception as error:  # noqa: BLE001 - any read or parse failure means "unknown"
        print(f"could not read {argv[1]}: {error}", file=sys.stderr)
        return 1
    if build is None:
        print(f"{argv[1]} lists no numeric build", file=sys.stderr)
        return 1
    print(build)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
