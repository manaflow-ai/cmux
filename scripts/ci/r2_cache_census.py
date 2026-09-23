#!/usr/bin/env python3
"""Measure what the CI cache bucket is storing, and what age would reclaim.

`r2-cache.sh` only ever restores and saves. Nothing deletes, and a save skips
re-upload when the key already exists, so an object's age never refreshes.
Archive keys embed a content hash, so every dependency bump mints a new object
and keeps the old one forever.

This reports that footprint. It never deletes and never writes to the bucket:
choosing a retention window is a cost decision, and it should be made against
measured bytes rather than a guess.

  r2_cache_census.py report --endpoint-url URL --bucket NAME
  r2_cache_census.py report --endpoint-url URL --bucket NAME --max-age-days 30

Credentials come from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY, matching
scripts/ci/upload-r2-object.py.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import hmac
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ElementTree

S3_NS = "{http://s3.amazonaws.com/doc/2006-03-01/}"
# r2-cache.sh layout: v1/<os>-<arch>/objects/<key>.tar.zst and v1/<os>-<arch>/latest/<prefix>
ARCHIVE_ROOT = "v1/"


class _RejectRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # A SigV4 signature is bound to its original host and path. Never
        # forward it or a session token to a redirect destination.
        return None


def _sign(key: bytes, message: str) -> bytes:
    return hmac.new(key, message.encode("utf-8"), hashlib.sha256).digest()


def _signing_key(secret_key: str, date_stamp: str, region: str) -> bytes:
    date_key = _sign(("AWS4" + secret_key).encode("utf-8"), date_stamp)
    region_key = _sign(date_key, region)
    service_key = _sign(region_key, "s3")
    return _sign(service_key, "aws4_request")


def list_page(endpoint_url: str, bucket: str, token: str | None, *, timeout: int = 30) -> str:
    """One ListObjectsV2 page as XML text. Split out so tests can replace it."""
    access_key = os.environ.get("AWS_ACCESS_KEY_ID", "")
    secret_key = os.environ.get("AWS_SECRET_ACCESS_KEY", "")
    region = os.environ.get("AWS_DEFAULT_REGION", "auto")
    if not access_key or not secret_key:
        raise SystemExit("AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are required")

    parsed = urllib.parse.urlsplit(endpoint_url.rstrip("/"))
    if parsed.scheme != "https" or not parsed.netloc:
        raise SystemExit("R2 endpoint URL must use HTTPS and include a host")

    query = {"list-type": "2", "prefix": ARCHIVE_ROOT, "max-keys": "1000"}
    if token:
        query["continuation-token"] = token
    # SigV4 needs the canonical query string sorted by key.
    canonical_query = "&".join(
        f"{urllib.parse.quote(key, safe='~')}={urllib.parse.quote(query[key], safe='~')}"
        for key in sorted(query)
    )
    canonical_uri = "/" + urllib.parse.quote(bucket, safe="~")
    amz_date = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    date_stamp = amz_date[:8]
    payload_hash = hashlib.sha256(b"").hexdigest()

    canonical_request = "\n".join([
        "GET",
        canonical_uri,
        canonical_query,
        f"host:{parsed.netloc}\nx-amz-content-sha256:{payload_hash}\nx-amz-date:{amz_date}\n",
        "host;x-amz-content-sha256;x-amz-date",
        payload_hash,
    ])
    scope = f"{date_stamp}/{region}/s3/aws4_request"
    to_sign = "\n".join([
        "AWS4-HMAC-SHA256",
        amz_date,
        scope,
        hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
    ])
    signature = hmac.new(
        _signing_key(secret_key, date_stamp, region), to_sign.encode("utf-8"), hashlib.sha256
    ).hexdigest()

    url = urllib.parse.urlunsplit(
        (parsed.scheme, parsed.netloc, canonical_uri, canonical_query, "")
    )
    request = urllib.request.Request(url, method="GET")
    request.add_header("x-amz-content-sha256", payload_hash)
    request.add_header("x-amz-date", amz_date)
    request.add_header(
        "Authorization",
        f"AWS4-HMAC-SHA256 Credential={access_key}/{scope}, "
        "SignedHeaders=host;x-amz-content-sha256;x-amz-date, "
        f"Signature={signature}",
    )
    with urllib.request.build_opener(_RejectRedirects()).open(request, timeout=timeout) as response:
        return response.read().decode("utf-8")


def parse_page(xml_text: str) -> tuple[list[dict], str | None, bool]:
    """Return this page's objects, the next continuation token, and truncation.

    Truncation is reported separately from the token: a truncated page that
    carries no token means more objects exist that this walk cannot reach, and
    silently treating that as the end would under-count the bucket.
    """
    root = ElementTree.fromstring(xml_text)
    objects = []
    for node in root.findall(f"{S3_NS}Contents"):
        key = node.findtext(f"{S3_NS}Key") or ""
        size = int(node.findtext(f"{S3_NS}Size") or 0)
        modified = node.findtext(f"{S3_NS}LastModified") or ""
        objects.append({"key": key, "size": size, "last_modified": modified})
    truncated = (root.findtext(f"{S3_NS}IsTruncated") or "false").strip().lower() == "true"
    token = root.findtext(f"{S3_NS}NextContinuationToken") if truncated else None
    return objects, (token or None), truncated


def namespace_of(key: str) -> str:
    """v1/<os>-<arch>/objects/<name> -> v1/<os>-<arch>. Unknown shapes group as-is."""
    parts = key.split("/")
    if len(parts) >= 2:
        return "/".join(parts[:2])
    return key


def age_days(last_modified: str, now: dt.datetime) -> float | None:
    try:
        stamp = dt.datetime.fromisoformat(last_modified.replace("Z", "+00:00"))
    except ValueError:
        return None
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=dt.timezone.utc)
    return max(0.0, (now - stamp).total_seconds() / 86400.0)


def summarize(objects: list[dict], now: dt.datetime, max_age_days: float | None,
              complete: bool = True) -> dict:
    namespaces: dict[str, dict] = {}
    total = {"objects": 0, "bytes": 0, "pointers": 0, "archives": 0}
    reclaim = {"objects": 0, "bytes": 0}
    undated = 0

    for item in objects:
        key = item["key"]
        size = int(item["size"])
        namespace = namespace_of(key)
        bucket = namespaces.setdefault(
            namespace, {"objects": 0, "bytes": 0, "archives": 0, "pointers": 0,
                        "reclaim_objects": 0, "reclaim_bytes": 0, "oldest_days": None}
        )
        bucket["objects"] += 1
        bucket["bytes"] += size
        total["objects"] += 1
        total["bytes"] += size
        # Pointers under latest/ are tiny and are the index into objects/.
        is_pointer = "/latest/" in key
        if is_pointer:
            bucket["pointers"] += 1
            total["pointers"] += 1
        else:
            bucket["archives"] += 1
            total["archives"] += 1

        age = age_days(item.get("last_modified", ""), now)
        if age is None:
            undated += 1
            continue
        current_oldest = bucket["oldest_days"]
        bucket["oldest_days"] = age if current_oldest is None else max(current_oldest, age)
        # Model the rule against archives only: expiring a pointer just costs a
        # restore miss, and pointers are negligible bytes.
        if max_age_days is not None and not is_pointer and age > max_age_days:
            bucket["reclaim_objects"] += 1
            bucket["reclaim_bytes"] += size
            reclaim["objects"] += 1
            reclaim["bytes"] += size

    return {
        "total": total,
        "reclaim": reclaim if max_age_days is not None else None,
        "max_age_days": max_age_days,
        "objects_without_timestamp": undated,
        "complete": complete,
        "namespaces": dict(sorted(namespaces.items())),
    }


def human_bytes(value: int) -> str:
    size = float(value)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if size < 1024 or unit == "TiB":
            return f"{size:.1f} {unit}" if unit != "B" else f"{int(size)} B"
        size /= 1024
    return f"{size:.1f} TiB"


def plural(count: int, noun: str) -> str:
    return f"{count} {noun}" if count == 1 else f"{count} {noun}s"


def render(summary: dict) -> str:
    total = summary["total"]
    complete = summary.get("complete", True)
    lines = [
        "CI cache bucket census" if complete else "CI cache bucket census (INCOMPLETE)",
        f"  objects: {total['objects']} "
        f"({plural(total['archives'], 'archive')}, {plural(total['pointers'], 'pointer')})",
        f"  size:    {human_bytes(total['bytes'])}",
    ]
    if not complete:
        # Every number below is a floor. Saying so matters more than the
        # numbers, because an under-count silently understates the cost.
        lines.append("  note:    the listing ended early; these totals are lower bounds")
    if summary["objects_without_timestamp"]:
        lines.append(f"  note:    {plural(summary['objects_without_timestamp'], 'object')} had no readable timestamp")
    reclaim = summary["reclaim"]
    if reclaim is not None:
        share = (reclaim["bytes"] / total["bytes"] * 100) if total["bytes"] else 0.0
        lines.append(
            f"  an age>{summary['max_age_days']:g}d rule over archives would reclaim "
            f"{human_bytes(reclaim['bytes'])} ({share:.0f}%) across "
            f"{plural(reclaim['objects'], 'object')}"
        )
    lines.append("")
    for namespace, row in summary["namespaces"].items():
        oldest = row["oldest_days"]
        age = "oldest unknown" if oldest is None else f"oldest {oldest:.0f}d"
        lines.append(
            f"  {namespace}: {plural(row['objects'], 'object')}, {human_bytes(row['bytes'])}, {age}"
            + (f", reclaimable {human_bytes(row['reclaim_bytes'])}" if reclaim is not None else "")
        )
    return "\n".join(lines)


def collect(endpoint_url: str, bucket: str, *, lister=list_page) -> tuple[list[dict], bool]:
    """Walk every page. Returns the objects and whether the walk is complete."""
    objects: list[dict] = []
    token: str | None = None
    seen_tokens: set[str] = set()
    while True:
        page, token, truncated = parse_page(lister(endpoint_url, bucket, token))
        objects.extend(page)
        if token is None:
            # A truncated final page with no token leaves objects unreachable.
            if truncated:
                print("warning: listing truncated without a continuation token", file=sys.stderr)
            return objects, not truncated
        # Defensive: a server repeating a token must not spin this forever.
        if token in seen_tokens:
            print("warning: continuation token repeated; stopping early", file=sys.stderr)
            return objects, False
        seen_tokens.add(token)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["report"])
    parser.add_argument("--endpoint-url", required=True)
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--max-age-days", type=float, default=None,
                        help="model what an age-based rule would reclaim; nothing is deleted")
    parser.add_argument("--json", action="store_true", help="emit the summary as JSON")
    args = parser.parse_args(argv)

    if args.max_age_days is not None and args.max_age_days <= 0:
        raise SystemExit("--max-age-days must be positive")

    objects, complete = collect(args.endpoint_url, args.bucket)
    summary = summarize(objects, dt.datetime.now(dt.timezone.utc), args.max_age_days, complete)
    print(json.dumps(summary, indent=2) if args.json else render(summary))
    # A partial walk understates the bucket, so it must not read as success.
    return 0 if complete else 1


if __name__ == "__main__":
    raise SystemExit(main())
