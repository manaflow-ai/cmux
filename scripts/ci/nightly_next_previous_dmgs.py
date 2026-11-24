#!/usr/bin/env python3
"""The nearest earlier nightly-next DMGs, from the feed's own R2 base, for the deltas a build ships with.

nightly-next-one's "Generate Sparkle appcasts (nightly)" builds the deltas from the nearest earlier builds
before the feed is written, so a build is never published full-only (hq#13299: the dispatched tail landed
deltas 60-100 min after the feed, and a newer build every ~30 min threw them away).

Which builds: the live feed names them, so this needs no listing, no token and no GitHub API. Its items are
the newest published builds, and the newest item's sparkle:deltas name the builds before those
(sparkle:deltaFrom). Every published DMG stays on R2 at <base>/<prefix>-<variant>-<build>.dmg. The first
build after this lands finds the feed's two items; the next one finds three.

usage: nightly_next_previous_dmgs.py --feed-url URL --base URL --prefix P --variant V --build N
                                     [--count 3] --out DIR
Downloads at most --count DMGs below --build, newest first, each checked against the length R2 serves.
A missing or failed one is skipped with a warning: deltas are optional, the publication never waits on them.
Exit 0 unless the arguments are wrong.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import deadline_http  # noqa: E402

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
USER_AGENT = "cmux-nightly-next-previous/1"
# One DMG download ends within this (about 150 MB from the CDN); 60 s of silence ends it sooner as a stall.
DOWNLOAD_SECONDS = 900


def earlier_builds(xml: bytes, below: int) -> list[int]:
    builds: set[int] = set()
    root = ET.fromstring(xml)
    for item in root.iter("item"):
        version = (item.findtext(f"{SPARKLE}version") or "").strip()
        if version.isdigit():
            builds.add(int(version))
        for delta in item.findall(f"{SPARKLE}deltas/enclosure"):
            source = (delta.get(f"{SPARKLE}deltaFrom") or "").strip()
            if source.isdigit():
                builds.add(int(source))
    return sorted((b for b in builds if b < below), reverse=True)


def fetch(url: str, timeout: float = 30) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Cache-Control": "no-cache"})
    _, body, _ = deadline_http.request(request, timeout, raise_errors=True)
    return body


def download(url: str, destination: Path) -> str:
    started = time.monotonic()
    partial = destination.with_name(f".{destination.name}.partial")
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        # A DMG streams: 60 s of silence is a stall, as urlopen(timeout=60) was; the whole download ends by
        # DOWNLOAD_SECONDS (tests/test_ci_no_bare_urlopen.py).
        with deadline_http.stream(request, DOWNLOAD_SECONDS, stall=60, raise_errors=True) as response, \
                partial.open("wb") as out:
            expected = int(response.headers.get("Content-Length") or -1)
            for chunk in iter(lambda: response.read(1 << 20), b""):
                out.write(chunk)
        size = partial.stat().st_size
        if expected < 0 or size != expected:
            raise RuntimeError(f"got {size} bytes, the server announced {expected}")
        partial.replace(destination)
        return f"{destination.name}: {size / 1e6:.1f} MB in {time.monotonic() - started:.1f} s"
    finally:
        partial.unlink(missing_ok=True)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--feed-url", required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--prefix", required=True)
    parser.add_argument("--variant", required=True)
    parser.add_argument("--build", type=int, required=True)
    parser.add_argument("--count", type=int, default=3)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)
    args.out.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    try:
        builds = earlier_builds(fetch(args.feed_url), args.build)[: args.count]
    except Exception as error:  # an unreadable feed means no deltas this time, never a failed publication
        print(f"::warning::could not read {args.feed_url}: {error}; publishing without deltas")
        return 0
    if not builds:
        print(f"no earlier build on {args.feed_url}; publishing without deltas")
        return 0
    base = args.base.rstrip("/") + "/"
    jobs = {b: (base + f"{args.prefix}-{args.variant}-{b}.dmg", args.out / f"{args.prefix}-{args.variant}-{b}.dmg")
            for b in builds}
    fetched = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(jobs)) as pool:
        futures = {pool.submit(download, url, path): build for build, (url, path) in jobs.items()}
        for future in concurrent.futures.as_completed(futures):
            try:
                print(future.result(), flush=True)
                fetched += 1
            except Exception as error:
                print(f"::warning::skipping build {futures[future]}: {error}")
    print(f"fetched {fetched} of {len(builds)} earlier build(s) ({', '.join(map(str, builds))}) "
          f"in {time.monotonic() - started:.1f} s into {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
