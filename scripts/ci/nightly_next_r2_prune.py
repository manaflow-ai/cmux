#!/usr/bin/env python3
"""Retention for cmux NEXT's downloads on R2 (nightly-next/next/ in cmux-nightly-next).

publish-nightly puts every nightly-next DMG there and republish-nightly-deltas its deltas
(publish-nightly-next-r2.py), about 240 MB a build; nothing removed them.

  nightly_next_r2_prune.py --endpoint-url URL --bucket B --prefix P --feed KEY [--feed KEY ...]
                           [--keep-builds N] [--min-age-days D] [--delete]

Only `<prefix>cmux-nightly-next-macos-<arch>-<build>.dmg` and
`<prefix>cmux-nightly-next-macos-<arch>-<build>-<base>.delta` directly under the prefix
are candidates; every other object (feeds, notes, dSYMs, runtime packs) is never touched.
A candidate is kept when any of these holds:
  - a feed names it: every enclosure in every --feed, read from the bucket, not the cache;
  - its build is one of the newest --keep-builds builds on R2 (a delta counts by its
    target build), which covers a rollback to an earlier build;
  - it is younger than --min-age-days (a build publishing now, a feed write in flight).
It fails closed: a feed that is missing, unreadable or names no item, or an incomplete
listing, deletes nothing. Without --delete it is a dry run. One run deletes at most
MAX_DELETES objects. The prefix is fixed (PREFIX): this never lists or deletes elsewhere.

Why reading the feed before each delete is enough: S3 has no delete-if-unreferenced, but no
writer adds an old file to the feed. A publication names its own new files (under the
minimum age) and items the live feed already names (kept); nightly-next-rollback.yml only
takes items off the feed and serves one already on it. So a file outside the newest builds,
older than the minimum age and absent from the feed just read cannot become live meanwhile.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import hmac
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parent))
import r2_cache_census as census  # noqa: E402
import r2_cache_prune  # noqa: E402

ASSET = re.compile(r"^cmux-nightly-next-macos-[a-z0-9_]+-(?P<build>[0-9]{3,})(?:-(?P<base>[0-9]{3,}))?\.(?P<kind>dmg|delta)$")
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
MAX_DELETES = 500
# The only prefix this prunes: cmux NEXT's downloads (NIGHTLY_NEXT_R2_PREFIX in nightly.yml).
PREFIX = "nightly-next/next/"


def list_page(endpoint_url: str, bucket: str, prefix: str, token: str | None, *, timeout: int = 30) -> str:
    """One ListObjectsV2 page under prefix, signed like r2_cache_census.list_page."""
    access_key = os.environ.get("AWS_ACCESS_KEY_ID", "")
    secret_key = os.environ.get("AWS_SECRET_ACCESS_KEY", "")
    region = os.environ.get("AWS_DEFAULT_REGION", "auto")
    if not access_key or not secret_key:
        raise SystemExit("AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are required")
    parsed = urllib.parse.urlsplit(endpoint_url.rstrip("/"))
    if parsed.scheme != "https" or not parsed.netloc:
        raise SystemExit("R2 endpoint URL must use HTTPS and include a host")
    query = {"list-type": "2", "prefix": prefix, "max-keys": "1000"}
    if token:
        query["continuation-token"] = token
    canonical_query = "&".join(f"{urllib.parse.quote(k, safe='~')}={urllib.parse.quote(query[k], safe='~')}"
                               for k in sorted(query))
    canonical_uri = "/" + urllib.parse.quote(bucket, safe="~")
    amz_date = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    date_stamp = amz_date[:8]
    payload_hash = hashlib.sha256(b"").hexdigest()
    canonical_request = "\n".join([
        "GET", canonical_uri, canonical_query,
        f"host:{parsed.netloc}\nx-amz-content-sha256:{payload_hash}\nx-amz-date:{amz_date}\n",
        "host;x-amz-content-sha256;x-amz-date", payload_hash,
    ])
    scope = f"{date_stamp}/{region}/s3/aws4_request"
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope, hashlib.sha256(canonical_request.encode()).hexdigest()])
    signature = hmac.new(census._signing_key(secret_key, date_stamp, region), to_sign.encode(), hashlib.sha256).hexdigest()
    request = urllib.request.Request(urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, canonical_uri, canonical_query, "")))
    request.add_header("x-amz-content-sha256", payload_hash)
    request.add_header("x-amz-date", amz_date)
    request.add_header("Authorization", f"AWS4-HMAC-SHA256 Credential={access_key}/{scope}, "
                                        "SignedHeaders=host;x-amz-content-sha256;x-amz-date, "
                                        f"Signature={signature}")
    with urllib.request.build_opener(census._RejectRedirects()).open(request, timeout=timeout) as response:
        return response.read().decode("utf-8")


class Bucket:
    """List, read and delete. Tests replace it with a fake."""

    def __init__(self, endpoint_url: str, bucket: str, prefix: str):
        self.endpoint_url, self.bucket, self.prefix = endpoint_url, bucket, prefix

    def list(self) -> tuple[list[dict], bool]:
        return census.collect(self.endpoint_url, self.bucket,
                              lister=lambda url, bucket, token: list_page(url, bucket, self.prefix, token))

    def read(self, key: str) -> bytes:
        return r2_cache_prune.signed("GET", self.endpoint_url, self.bucket, key, timeout=60)

    def delete(self, key: str) -> None:
        r2_cache_prune.signed("DELETE", self.endpoint_url, self.bucket, key)


class Refused(Exception):
    pass


def referenced(feed_xml: bytes, feed_key: str) -> set[str]:
    """The basename of every enclosure the feed names (full DMGs and deltas alike)."""
    try:
        root = ET.fromstring(feed_xml)
    except ET.ParseError as error:
        raise Refused(f"{feed_key} does not parse: {error}") from error
    items = list(root.iter("item"))
    if not items:
        raise Refused(f"{feed_key} has no items")
    names = set()
    for element in root.iter():
        if element.tag in ("enclosure", f"{{{SPARKLE_NS}}}enclosure") and element.get("url"):
            names.add(urllib.parse.urlsplit(element.get("url")).path.rsplit("/", 1)[-1])
    if not names:
        raise Refused(f"{feed_key} names no enclosure")
    return names


def age_days(last_modified: str, now: dt.datetime) -> float:
    try:
        when = dt.datetime.fromisoformat(last_modified.replace("Z", "+00:00"))
    except ValueError:
        return 0.0  # unknown age: treated as new, so kept
    return (now - when).total_seconds() / 86400


def plan(objects: list[dict], keep_names: set[str], prefix: str, keep_builds: int, min_age_days: float,
         now: dt.datetime) -> tuple[list[dict], dict]:
    assets = []
    for item in objects:
        key = item["key"]
        if not key.startswith(prefix):
            continue
        name = key[len(prefix):]
        match = ASSET.match(name)
        if "/" in name or not match:
            continue
        assets.append({**item, "name": name, "build": int(match.group("build")), "kind": match.group("kind")})
    newest = set(sorted({a["build"] for a in assets}, reverse=True)[:keep_builds])
    delete, counts = [], {"assets": len(assets), "kept_by_feed": 0, "kept_by_build": 0, "kept_by_age": 0}
    for asset in assets:
        if asset["name"] in keep_names:
            counts["kept_by_feed"] += 1
        elif asset["build"] in newest:
            counts["kept_by_build"] += 1
        elif age_days(asset["last_modified"], now) < min_age_days:
            counts["kept_by_age"] += 1
        else:
            delete.append(asset)
    delete.sort(key=lambda a: (a["build"], a["name"]))
    return delete, counts


def prune(bucket, feeds: list[str], keep_builds: int, min_age_days: float, now: dt.datetime, delete: bool) -> dict:
    keep: set[str] = set()
    for key in feeds:
        try:
            keep |= referenced(bucket.read(key), key)
        except urllib.error.HTTPError as error:
            raise Refused(f"{key}: HTTP {error.code}") from error
    objects, complete = bucket.list()
    if not complete:
        raise Refused("the listing is incomplete")
    candidates, counts = plan(objects, keep, bucket.prefix, keep_builds, min_age_days, now)
    deleted = []
    if delete and candidates:
        # A feed can change between the first read and the deletes: read every feed again just
        # before each delete and never delete what any of them names then (fails closed too).
        for asset in candidates[:MAX_DELETES]:
            now_named: set[str] = set()
            for key in feeds:
                now_named |= referenced(bucket.read(key), key)
            if asset["name"] in now_named:
                continue
            bucket.delete(asset["key"])
            deleted.append(asset["name"])
    return {**counts, "dry_run": not delete, "candidates": [a["name"] for a in candidates],
            "candidate_bytes": sum(int(a["size"]) for a in candidates), "deleted": deleted,
            "feed_names": sorted(keep)}


def render(summary: dict) -> str:
    gib = 1024 ** 3
    verb = "would delete" if summary["dry_run"] else "deleted"
    count = len(summary["candidates"]) if summary["dry_run"] else len(summary["deleted"])
    lines = [f"nightly-next R2 prune ({'dry run' if summary['dry_run'] else 'delete'}): {verb} {count} of "
             f"{summary['assets']} DMGs and deltas ({summary['candidate_bytes'] / gib:.1f} GiB eligible); kept "
             f"{summary['kept_by_feed']} the feeds name, {summary['kept_by_build']} of the newest builds, "
             f"{summary['kept_by_age']} too new", ""]
    names = summary["candidates"] if summary["dry_run"] else summary["deleted"]
    lines += [f"- {name}" for name in names[:200]]
    if len(names) > 200:
        lines.append(f"- ... and {len(names) - 200} more")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--endpoint-url", required=True)
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--prefix", required=True)
    parser.add_argument("--feed", action="append", required=True, help="a feed object key whose enclosures are kept")
    parser.add_argument("--keep-builds", type=int, default=20)
    parser.add_argument("--min-age-days", type=float, default=7.0)
    parser.add_argument("--delete", action="store_true", help="send deletes; the default is a dry run")
    args = parser.parse_args(argv)
    if args.prefix != PREFIX or args.keep_builds < 5 or args.min_age_days < 2:
        parser.error(f"--prefix must be {PREFIX}, --keep-builds at least 5 and --min-age-days at least 2")
    if any(not feed.startswith(PREFIX) or "/" in feed[len(PREFIX):] for feed in args.feed):
        parser.error(f"every --feed must be an object directly under {PREFIX}")
    bucket = Bucket(args.endpoint_url, args.bucket, args.prefix)
    try:
        summary = prune(bucket, args.feed, args.keep_builds, args.min_age_days, dt.datetime.now(dt.timezone.utc),
                        args.delete)
    except Refused as refusal:
        print(f"nightly-next R2 prune: deleted nothing: {refusal}")
        return 1
    print(render(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
