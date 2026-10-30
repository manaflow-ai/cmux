#!/usr/bin/env python3
"""The cmux NEXT feed's critical path: this build's files to R2, then the feed.

Leo, 2026-10-26: "how are we even spending more than one minute on uploads?" The
GitHub release upload sat 13 to 18 minutes in secondary rate-limit backoff
(runs 40357982361, 40376320918) while the feed waited on it. The feed and its
downloads now live on R2 (files-next.cmux.com); the GitHub release copy is a
follow-up job that never holds the feed.

  upload --file F [--file ...]
      Writes each file to <prefix><name>, write-once, all at once (one thread
      per file), then reads each back from the public base and checks its size.
  rewrite --feed F --name N [--name ...]
      Points every enclosure <github-prefix><N> in F at <public-base>/<N>.
      --if-public rewrites only names the public base serves at the enclosure's
      length (the delta republish, which may carry older GitHub-only builds).
  write-feed --feed F [--same-build]
      Replaces <prefix><basename F> only while the live feed's newest build is
      below this feed's newest build, with If-Match on the bytes it read, so two
      runs never move the feed back (a lost race re-reads and decides again).
      --same-build (the delta republish): only while the live feed's newest
      build is this feed's. Either way the feed written keeps the live feed's
      newest earlier builds until it holds KEEP_BUILDS (2) builds, so a pull
      (nightly-next-rollback.yml) always has a published build to fall back
      to: every build on the live feed passed the publish gate, and a pulled
      one is no longer on it.

Environment: AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (the nightly-next scoped
token), R2_ENDPOINT, NIGHTLY_NEXT_R2_BUCKET, NIGHTLY_NEXT_R2_PREFIX,
NIGHTLY_NEXT_FEED_BASE. Every key passes nightly-next-guard.py r2-key first.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import hashlib
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
UPLOADER = HERE / "upload-r2-object.py"
GUARD = HERE / "nightly-next-guard.py"
GITHUB_PREFIX = "https://github.com/manaflow-ai/cmux/releases/download/nightly-next/"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
IMMUTABLE_CACHE = "public, max-age=31536000, immutable"
FEED_CACHE = "no-cache, no-store, must-revalidate"
CONFLICT = 3
# The feed keeps this many builds: the new one and the newest earlier one, so a rollback can serve it.
KEEP_BUILDS = 2
ITEM = re.compile(rb"[ \t]*<item>.*?</item>[ \t]*\n?", re.S)
ITEM_VERSION = re.compile(rb"<sparkle:version>\s*(\d+)\s*</sparkle:version>")
ITEM_CHANNEL = re.compile(rb"<sparkle:channel>\s*([^<]*?)\s*</sparkle:channel>")
NIGHTLY_CHANNELS = (None, b"cmux-next")  # what a Nightly-ring app is offered (untagged or cmux-next)
_sleep = time.sleep


def env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"{name} is not set")
    return value


def public_base() -> str:
    return env("NIGHTLY_NEXT_FEED_BASE").rstrip("/") + "/"


def guard_key(key: str) -> None:
    subprocess.run([sys.executable, str(GUARD), "r2-key", env("NIGHTLY_NEXT_R2_BUCKET"), key], check=True)


def uploader_args(path: Path, key: str, cache: str, content_type: str) -> list[str]:
    return [sys.executable, str(UPLOADER), "--file", str(path), "--endpoint-url", env("R2_ENDPOINT"),
            "--bucket", env("NIGHTLY_NEXT_R2_BUCKET"), "--key", key,
            "--content-type", content_type, "--cache-control", cache]


def public_length(url: str, attempts: int = 5) -> int | None:
    """The Content-Length the public base serves for url, None on a 404 after retries."""
    for attempt in range(attempts):
        request = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "cmux-nightly-next-r2/1"})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return int(response.headers.get("Content-Length", "-1"))
        except (urllib.error.URLError, OSError, ValueError) as error:
            if attempt == attempts - 1:
                print(f"{url}: {error}", file=sys.stderr)
                return None
            _sleep(2 * (attempt + 1))
    return None


def upload_one(path: Path) -> str:
    key = env("NIGHTLY_NEXT_R2_PREFIX") + path.name
    guard_key(key)
    started = time.monotonic()
    content_type = "application/x-apple-diskimage" if path.suffix == ".dmg" else "application/octet-stream"
    if path.suffix in (".json",):
        content_type = "application/json"
    elif path.suffix == ".txt":
        content_type = "text/plain; charset=utf-8"
    subprocess.run(uploader_args(path, key, IMMUTABLE_CACHE, content_type) + ["--write-once"], check=True)
    size = path.stat().st_size
    url = public_base() + path.name
    served = public_length(url)
    if served != size:
        raise RuntimeError(f"{url} serves {served} bytes, expected {size}")
    return f"{path.name}: {size} bytes in {time.monotonic() - started:.1f} s, live at {url}"


def upload(files: list[Path]) -> int:
    missing = [str(f) for f in files if not f.is_file()]
    if missing:
        raise SystemExit(f"missing: {', '.join(missing)}")
    started = time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(files)) as pool:
        futures = {pool.submit(upload_one, f): f for f in files}
        failed = []
        for future in concurrent.futures.as_completed(futures):
            try:
                print(future.result(), flush=True)
            except Exception as error:  # report every failure, not only the first
                failed.append(f"{futures[future].name}: {error}")
    if failed:
        print("\n".join(failed), file=sys.stderr)
        return 1
    print(f"{len(files)} files on R2 in {time.monotonic() - started:.1f} s")
    return 0


ENCLOSURE_URL = re.compile(r'(url=")([^"]+)(")')


def rewrite(feed: Path, names: set[str], if_public: bool) -> int:
    text = feed.read_text(encoding="utf-8")
    base = public_base()
    lengths = {}
    if if_public:
        # Each enclosure's declared length, to check the public copy against.
        root = ET.fromstring(text)
        for element in root.iter("enclosure"):
            url = element.get("url") or ""
            if url.startswith(GITHUB_PREFIX):
                lengths[url[len(GITHUB_PREFIX):]] = element.get("length")
    changed = []

    def replace(match: re.Match) -> str:
        url = match.group(2)
        if not url.startswith(GITHUB_PREFIX):
            return match.group(0)
        name = url[len(GITHUB_PREFIX):]
        if "/" in name or not name.startswith("cmux-nightly-next-macos-"):
            return match.group(0)
        if names and name not in names:
            return match.group(0)
        if if_public:
            served = public_length(base + name, attempts=1)
            if served is None or str(served) != str(lengths.get(name)):
                return match.group(0)
        changed.append(name)
        return f"{match.group(1)}{base}{name}{match.group(3)}"

    text = ENCLOSURE_URL.sub(replace, text)
    feed.write_text(text, encoding="utf-8")
    for name in changed:
        print(f"{feed.name}: {name} -> {base}{name}")
    if names and not if_public and not set(names) <= set(changed):
        print(f"{feed.name}: no GitHub enclosure for {sorted(set(names) - set(changed))}", file=sys.stderr)
        return 1
    return 0


def newest_build(xml: bytes) -> int:
    root = ET.fromstring(xml)
    builds = [0]
    for element in root.iter():
        if element.tag == f"{{{SPARKLE_NS}}}version" and (element.text or "").strip().isdigit():
            builds.append(int(element.text.strip()))
        value = element.get(f"{{{SPARKLE_NS}}}version")
        if value and value.isdigit():
            builds.append(int(value))
    return max(builds)


def item_builds(xml: bytes) -> list[tuple[re.Match, int]]:
    found = []
    for match in ITEM.finditer(xml):
        version = ITEM_VERSION.search(match.group(0))
        if version is not None:
            found.append((match, int(version.group(1))))
    return found


def nightly_item(item: bytes) -> bool:
    channel = ITEM_CHANNEL.search(item)
    return (channel.group(1) if channel else None) in NIGHTLY_CHANNELS


def keep_earlier_builds(ours: bytes, live: bytes, keep: int = KEEP_BUILDS) -> bytes:
    """OURS, holding a Nightly-ring item (untagged or cmux-next) for each of the KEEP - 1 newest builds
    below OURS' newest that either feed offers Nightly apps, taken from the live feed when OURS lacks it.

    Counting over both feeds means a feed combined from an older read (a lost race) still takes a
    build that landed meanwhile. A Dev-tagged (cmux-next-dev) item never counts: a Nightly app rejects
    it, so it could not serve a rollback. Where OURS has a wanted build only as Dev items (a promotion
    raced this write), those items give way to the live feed's Nightly item. Kept items are the live
    feed's bytes, after OURS' last item."""
    mine = item_builds(ours)
    if not mine:
        return ours
    newest = max(build for _, build in mine)
    nightly_mine = {build for match, build in mine if nightly_item(match.group(0))}
    theirs = [(match, build) for match, build in item_builds(live) if nightly_item(match.group(0))]
    earlier = {build for build in nightly_mine if build < newest} | {build for _, build in theirs if build < newest}
    wanted = set(sorted(earlier, reverse=True)[:keep - 1]) - nightly_mine
    added, taken = [], set()
    for match, build in sorted(theirs, key=lambda entry: entry[1], reverse=True):
        if build in wanted and build not in taken:
            item = match.group(0)
            added.append(item if item.endswith(b"\n") else item + b"\n")
            taken.add(build)
    if not added:
        return ours
    kept, cursor = [], 0
    for match, build in mine:
        kept.append(ours[cursor:match.start()])
        if build not in taken:  # a Dev item of a build whose Nightly item is added gives way to it
            kept.append(match.group(0))
        cursor = match.end()
    end = len(b"".join(kept))
    kept.append(ours[cursor:])
    body = b"".join(kept)
    return body[:end] + b"".join(added) + body[end:]


def _uploader_module():
    spec = importlib.util.spec_from_file_location("upload_r2_object", UPLOADER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def read_live(key: str) -> bytes | None:
    """The feed object's bytes through the S3 API (not the cached public URL), None when absent."""
    module = _uploader_module()
    args = argparse.Namespace(endpoint_url=env("R2_ENDPOINT"), bucket=env("NIGHTLY_NEXT_R2_BUCKET"), key=key,
                              cache_control=FEED_CACHE, content_type="application/xml")
    amz_date = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    request = module._build_signed_request(args, b"", amz_date, method="GET")
    try:
        with module._open_signed_request(request, timeout=60) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def write_feed(feed: Path, github_output: str | None, same_build: bool = False, attempts: int = 5) -> int:
    key = env("NIGHTLY_NEXT_R2_PREFIX") + feed.name
    guard_key(key)
    original = feed.read_bytes()
    ours = newest_build(original)
    for _ in range(attempts):
        live = read_live(key)
        if live is None and same_build:
            print(f"{feed.name}: no live feed to revise; left as it is")
            return 0
        if live is not None:
            theirs = newest_build(live)
            if (theirs != ours) if same_build else (theirs >= ours):
                print(f"{feed.name}: the live feed serves build {theirs}, this feed's newest is {ours}; "
                      "left as it is")
                if github_output:
                    with open(github_output, "a", encoding="utf-8") as out:
                        out.write("feed_written=false\n")
                return 0
            mode = ["--replace-sha256", hashlib.sha256(live).hexdigest(), "--conflict-exit-code", str(CONFLICT)]
            merged = keep_earlier_builds(original, live)
            if merged != original:
                kept = sorted({b for _, b in item_builds(merged)} - {b for _, b in item_builds(original)}, reverse=True)
                print(f"{feed.name}: keeps the live feed's build {', '.join(map(str, kept))} beside {ours}, "
                      "for a rollback to serve")
            feed.write_bytes(merged)
        else:
            feed.write_bytes(original)
            mode = ["--write-once", "--conflict-exit-code", str(CONFLICT)]
        result = subprocess.run(uploader_args(feed, key, FEED_CACHE, "application/xml") + mode)
        if result.returncode == 0:
            print(f"{feed.name}: build {ours} is live at {public_base()}{feed.name}")
            if github_output:
                with open(github_output, "a", encoding="utf-8") as out:
                    out.write("feed_written=true\n")
            return 0
        if result.returncode != CONFLICT:
            return result.returncode
        print(f"{feed.name}: another run wrote the feed meanwhile; reading it again", flush=True)
    print(f"{feed.name}: the feed kept changing under {attempts} attempts", file=sys.stderr)
    return 1


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    up = sub.add_parser("upload")
    up.add_argument("--file", action="append", type=Path, required=True)
    rw = sub.add_parser("rewrite")
    rw.add_argument("--feed", type=Path, required=True)
    rw.add_argument("--name", action="append", default=[])
    rw.add_argument("--if-public", action="store_true")
    wf = sub.add_parser("write-feed")
    wf.add_argument("--feed", type=Path, required=True)
    wf.add_argument("--github-output")
    wf.add_argument("--same-build", action="store_true")
    args = parser.parse_args(argv)
    if args.command == "upload":
        return upload(args.file)
    if args.command == "rewrite":
        if not args.name and not args.if_public:
            parser.error("rewrite needs --name or --if-public")
        return rewrite(args.feed, set(args.name), args.if_public)
    return write_feed(args.feed, args.github_output, args.same_build)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
