#!/usr/bin/env python3
"""Measure what every R2 bucket a key can see is storing, by key family.

    r2_storage_census.py --endpoint-url URL [--bucket NAME ...] [--json-out PATH]

This lists each bucket the credentials can list (ListBuckets; when the key is
scoped to buckets and cannot list them, the --bucket names), walks every
object, and groups keys into families: the directory path up to and including
the first segment that names one build (a commit, a version, a content hash or
a number), so `cmux-tui/<sha>`, `cmux-tui/tree/<key>` and `cef/<version>` each
read as one row. Each row reports objects, bytes, how many builds it holds,
and how its bytes split by age, which is what a keep rule is chosen against.

It never writes, deletes or prints credentials. Credentials come from
AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY, matching r2_cache_census.py.
"""
from __future__ import annotations

import argparse
import datetime as dt
import functools
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ElementTree

sys.path.insert(0, str(Path(__file__).resolve().parent))
import r2_cache_census as census  # noqa: E402

# R2 Standard storage, per GB-month (https://developers.cloudflare.com/r2/pricing/).
USD_PER_GB_MONTH = 0.015
AGE_BANDS = ((7, "<7d"), (30, "7-30d"), (90, "30-90d"), (None, ">90d"))
MAX_DIRECTORY_DEPTH = 3

_SHA = re.compile(r"^[0-9a-f]{7,40}$")
_HASH = re.compile(r"^[0-9a-f]{41,128}$")
_VERSION = re.compile(r"^v?\d+(\.\d+)+")
_NUMBER = re.compile(r"^\d+$")
_DATE = re.compile(r"\d{4}-\d{2}-\d{2}")
# A long token with digits and letters: a cache key, a tree key, a run id with a prefix.
_KEY = re.compile(r"^(?=.*\d)(?=.*[A-Za-z])[A-Za-z0-9._+=-]{24,}$")


def placeholder(segment: str) -> str | None:
    """The placeholder for a segment that names one build, else None."""
    if _SHA.match(segment) and any(ch.isdigit() for ch in segment):
        return "<sha>"
    if _HASH.match(segment):
        return "<hash>"
    if _VERSION.match(segment):
        return "<version>"
    if _NUMBER.match(segment):
        return "<n>"
    if _DATE.search(segment):
        return "<date>"
    if _KEY.match(segment):
        return "<key>"
    return None


def family_of(key: str) -> tuple[str, str]:
    """(family, unit): the family row and the one build inside it.

    `cmux-tui/0123abcd.../linux/cmux-tui` -> (`cmux-tui/<sha>`, `cmux-tui/0123abcd...`).
    A file at the bucket root is its own family, `(root)`.
    """
    parts = key.split("/")
    directories = parts[:-1]
    if not directories:
        return "(root)", "(root)"
    family: list[str] = []
    unit: list[str] = []
    for segment in directories[:MAX_DIRECTORY_DEPTH]:
        marker = placeholder(segment)
        family.append(marker or segment)
        unit.append(segment)
        if marker:
            break
    return "/".join(family), "/".join(unit)


def band_of(age: float) -> str:
    return next(label for limit, label in AGE_BANDS if limit is None or age < limit)


def summarize(objects: list[dict], now: dt.datetime) -> dict:
    families: dict[str, dict] = {}
    for item in objects:
        family, unit = family_of(item["key"])
        row = families.setdefault(family, {
            "objects": 0, "bytes": 0, "units": set(),
            "bands": {label: 0 for _, label in AGE_BANDS},
            "oldest_days": None, "newest_days": None,
        })
        size = int(item["size"])
        row["objects"] += 1
        row["bytes"] += size
        row["units"].add(unit)
        age = census.age_days(item.get("last_modified", ""), now)
        if age is None:
            continue
        row["bands"][band_of(age)] += size
        row["oldest_days"] = age if row["oldest_days"] is None else max(row["oldest_days"], age)
        row["newest_days"] = age if row["newest_days"] is None else min(row["newest_days"], age)
    rows = []
    for family, row in families.items():
        rows.append({**row, "family": family, "units": len(row["units"])})
    rows.sort(key=lambda row: (-row["bytes"], row["family"]))
    return {
        "objects": sum(row["objects"] for row in rows),
        "bytes": sum(row["bytes"] for row in rows),
        "families": rows,
    }


def gib(value: int) -> str:
    return f"{value / 1024 ** 3:.1f}"


def usd_per_month(value: int) -> str:
    return f"{value / 1000 ** 3 * USD_PER_GB_MONTH:.2f}"


def render(bucket: str, summary: dict, complete: bool) -> str:
    title = f"### {bucket}: {gib(summary['bytes'])} GiB, {summary['objects']} objects, " \
            f"${usd_per_month(summary['bytes'])}/month"
    lines = [title + ("" if complete else " (INCOMPLETE: listing ended early, totals are floors)"), ""]
    bands = [label for _, label in AGE_BANDS]
    lines.append("| family | builds | objects | GiB | $/month | " + " | ".join(f"GiB {b}" for b in bands)
                 + " | oldest | newest |")
    lines.append("|" + "---|" * (7 + len(bands)))
    for row in summary["families"]:
        oldest = "?" if row["oldest_days"] is None else f"{row['oldest_days']:.0f}d"
        newest = "?" if row["newest_days"] is None else f"{row['newest_days']:.0f}d"
        lines.append(
            f"| `{row['family']}` | {row['units']} | {row['objects']} | {gib(row['bytes'])} | "
            f"{usd_per_month(row['bytes'])} | " + " | ".join(gib(row["bands"][b]) for b in bands)
            + f" | {oldest} | {newest} |"
        )
    return "\n".join(lines) + "\n"


def signed_get(endpoint_url: str, path: str, query: dict[str, str], *, timeout: int = 30) -> str:
    """One SigV4 GET (ListBuckets or ListObjectsV2), in census.list_page's style."""
    access_key = os.environ.get("AWS_ACCESS_KEY_ID", "")
    secret_key = os.environ.get("AWS_SECRET_ACCESS_KEY", "")
    region = os.environ.get("AWS_DEFAULT_REGION", "auto")
    if not access_key or not secret_key:
        raise SystemExit("AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are required")
    parsed = urllib.parse.urlsplit(endpoint_url.rstrip("/"))
    if parsed.scheme != "https" or not parsed.netloc:
        raise SystemExit("R2 endpoint URL must use HTTPS and include a host")
    canonical_query = "&".join(
        f"{urllib.parse.quote(key, safe='~')}={urllib.parse.quote(query[key], safe='~')}"
        for key in sorted(query)
    )
    amz_date = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    date_stamp = amz_date[:8]
    payload_hash = hashlib.sha256(b"").hexdigest()
    canonical_request = "\n".join([
        "GET", path, canonical_query,
        f"host:{parsed.netloc}\nx-amz-content-sha256:{payload_hash}\nx-amz-date:{amz_date}\n",
        "host;x-amz-content-sha256;x-amz-date", payload_hash,
    ])
    scope = f"{date_stamp}/{region}/s3/aws4_request"
    to_sign = "\n".join([
        "AWS4-HMAC-SHA256", amz_date, scope,
        hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
    ])
    signature = hmac.new(
        census._signing_key(secret_key, date_stamp, region), to_sign.encode("utf-8"), hashlib.sha256
    ).hexdigest()
    url = urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, path, canonical_query, ""))
    request = urllib.request.Request(url, method="GET")
    request.add_header("x-amz-content-sha256", payload_hash)
    request.add_header("x-amz-date", amz_date)
    request.add_header(
        "Authorization",
        f"AWS4-HMAC-SHA256 Credential={access_key}/{scope}, "
        "SignedHeaders=host;x-amz-content-sha256;x-amz-date, "
        f"Signature={signature}",
    )
    with urllib.request.build_opener(census._RejectRedirects()).open(request, timeout=timeout) as response:
        return response.read().decode("utf-8")


def list_buckets(endpoint_url: str, *, getter=signed_get) -> list[str] | None:
    """Every bucket the key can list, or None when the key may not list buckets."""
    try:
        text = getter(endpoint_url, "/", {})
    except urllib.error.HTTPError as error:
        if error.code in (401, 403):
            return None
        raise
    root = ElementTree.fromstring(text)
    return sorted(node.text or "" for node in root.iter(f"{census.S3_NS}Name") if node.text)


def list_page(endpoint_url: str, bucket: str, token: str | None, *, getter=signed_get) -> str:
    query = {"list-type": "2", "max-keys": "1000"}
    if token:
        query["continuation-token"] = token
    return getter(endpoint_url, "/" + urllib.parse.quote(bucket, safe="~"), query)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint-url", required=True)
    parser.add_argument("--bucket", action="append", default=[],
                        help="census this bucket when the key cannot list buckets (repeatable)")
    parser.add_argument("--json-out", type=Path, help="also write every family row as JSON")
    args = parser.parse_args(argv)

    listed = list_buckets(args.endpoint_url)
    buckets = listed if listed else sorted(set(args.bucket))
    if not buckets:
        raise SystemExit("the key cannot list buckets and no --bucket was given")
    print(f"buckets: {', '.join(buckets)}" + ("" if listed else " (from --bucket; ListBuckets refused)"))

    now = dt.datetime.now(dt.timezone.utc)
    report: dict[str, dict] = {}
    all_complete = True
    for bucket in buckets:
        try:
            objects, complete = census.collect(args.endpoint_url, bucket, lister=list_page)
        except urllib.error.HTTPError as error:
            print(f"### {bucket}: not readable with this key (HTTP {error.code})\n")
            report[bucket] = {"error": error.code}
            continue
        all_complete &= complete
        summary = summarize(objects, now)
        print(render(bucket, summary, complete))
        report[bucket] = {**summary, "complete": complete}
    if args.json_out:
        args.json_out.write_text(json.dumps({"generated": now.isoformat(), "buckets": report}, indent=2) + "\n")
    # A partial walk understates a bucket, so it must not read as success.
    return 0 if all_complete else 1


if __name__ == "__main__":
    raise SystemExit(main())
