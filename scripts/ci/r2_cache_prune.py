#!/usr/bin/env python3
"""Delete CI cache archives nothing will restore again.

    r2_cache_prune.py --endpoint-url URL --bucket NAME [--delete]

`r2-cache.sh` saves `v1/<os>-<arch>/objects/<key>.tar.zst|.tar.gz` plus one
`v1/<os>-<arch>/latest/<prefix>` pointer per dash-terminated prefix of the key,
and nothing ever deletes. This removes archives older than their family's
retention, with one rule that is never relaxed: an archive any `latest/`
pointer names is kept, whatever its age, because prefix restores read it.

Without `--delete` this is a dry run: it lists, reads every pointer, and
reports what it would delete, but sends no DELETE. Only `objects/` archives are
candidates. Pointers, and anything outside `v1/*/objects/`, are never touched.

Retention, by the first matching key prefix:

  admission-derived-data-  1 day. One snapshot per main commit, and every
                           consumer adopts the newest by prefix; an exact key
                           only matters for a pull request on a base that old
                           (2026-09-24: 92 of the 100 most recently updated
                           open pull requests had a base under a day old).
  xcode-compilation-       1 day. Restored newest by prefix, and a cache from
                           an older main misses for every changed module
                           (#14015: 3 of 2,665 app jobs hit). On 2026-09-24
                           these were 141 GiB of a 143 GiB bucket after five
                           days, about 35 GiB a day.
  everything else          30 days. Keyed by content (a Package.resolved or
                           toolchain hash), so an old key stays exact for a
                           pull request whose base still has that input.

Credentials come from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import sys
import urllib.parse
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent))
import r2_cache_census as census  # noqa: E402

RETENTION_DAYS = (
    ("admission-derived-data-", 1),
    ("xcode-compilation-", 1),
    ("", 30),
)
ARCHIVE = re.compile(r"^(v1/[^/]+)/objects/(?P<name>[A-Za-z0-9._-]+)\.(?:tar\.zst|tar\.gz)$")
POINTER = re.compile(r"^(v1/[^/]+)/latest/[A-Za-z0-9._-]+$")
VALID_NAME = re.compile(r"^[A-Za-z0-9._-]+$")
# One run never deletes more than this; a larger backlog drains over days.
MAX_DELETES = 2000


def retention_days(name: str) -> int:
    return next(days for prefix, days in RETENTION_DAYS if name.startswith(prefix))


def signed(method: str, endpoint_url: str, bucket: str, key: str, *, timeout: int = 30) -> bytes:
    """One SigV4 request against a single object, in census.list_page's style."""
    access_key = os.environ.get("AWS_ACCESS_KEY_ID", "")
    secret_key = os.environ.get("AWS_SECRET_ACCESS_KEY", "")
    region = os.environ.get("AWS_DEFAULT_REGION", "auto")
    if not access_key or not secret_key:
        raise SystemExit("AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are required")
    parsed = urllib.parse.urlsplit(endpoint_url.rstrip("/"))
    if parsed.scheme != "https" or not parsed.netloc:
        raise SystemExit("R2 endpoint URL must use HTTPS and include a host")
    canonical_uri = "/" + urllib.parse.quote(bucket, safe="~") + "/" + urllib.parse.quote(key, safe="~/")
    amz_date = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    date_stamp = amz_date[:8]
    payload_hash = hashlib.sha256(b"").hexdigest()
    canonical_request = "\n".join([
        method, canonical_uri, "",
        f"host:{parsed.netloc}\nx-amz-content-sha256:{payload_hash}\nx-amz-date:{amz_date}\n",
        "host;x-amz-content-sha256;x-amz-date", payload_hash,
    ])
    scope = f"{date_stamp}/{region}/s3/aws4_request"
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope,
                         hashlib.sha256(canonical_request.encode()).hexdigest()])
    signature = hmac.new(census._signing_key(secret_key, date_stamp, region),
                         to_sign.encode(), hashlib.sha256).hexdigest()
    request = urllib.request.Request(
        urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, canonical_uri, "", "")), method=method)
    request.add_header("x-amz-content-sha256", payload_hash)
    request.add_header("x-amz-date", amz_date)
    request.add_header("Authorization",
                       f"AWS4-HMAC-SHA256 Credential={access_key}/{scope}, "
                       "SignedHeaders=host;x-amz-content-sha256;x-amz-date, "
                       f"Signature={signature}")
    with urllib.request.build_opener(census._RejectRedirects()).open(request, timeout=timeout) as response:
        return response.read()


class Bucket:
    """The three operations pruning needs. Tests replace it with a fake."""

    def __init__(self, endpoint_url: str, bucket: str):
        self.endpoint_url, self.bucket = endpoint_url, bucket

    def list(self) -> tuple[list[dict], bool]:
        return census.collect(self.endpoint_url, self.bucket)

    def read(self, key: str) -> str:
        return signed("GET", self.endpoint_url, self.bucket, key)[:512].decode("utf-8", "replace")

    def delete(self, key: str) -> None:
        signed("DELETE", self.endpoint_url, self.bucket, key)


def protected(bucket, objects: list[dict]) -> set[str]:
    """Every archive a pointer names. Any unreadable pointer aborts the run."""
    keep: set[str] = set()
    for item in objects:
        match = POINTER.match(item["key"])
        if not match:
            continue
        target = bucket.read(item["key"]).strip()
        if not VALID_NAME.match(target):
            raise RuntimeError(f"pointer {item['key']} names an invalid key; refusing to prune")
        keep.update(f"{match.group(1)}/objects/{target}.{ext}" for ext in ("tar.zst", "tar.gz"))
    return keep


def plan(objects: list[dict], keep: set[str], now: dt.datetime) -> tuple[list[dict], dict]:
    candidates, families = [], {}
    for item in objects:
        match = ARCHIVE.match(item["key"])
        if not match:
            continue
        name = match.group("name")
        days = retention_days(name)
        family = next(prefix for prefix, limit in RETENTION_DAYS if name.startswith(prefix)) or "other"
        row = families.setdefault(family, {"retention_days": days, "archives": 0, "bytes": 0,
                                           "delete": 0, "delete_bytes": 0, "kept_by_pointer": 0})
        row["archives"] += 1
        row["bytes"] += int(item["size"])
        age = census.age_days(item.get("last_modified", ""), now)
        if age is None or age <= days:
            continue
        if item["key"] in keep:
            row["kept_by_pointer"] += 1
            continue
        row["delete"] += 1
        row["delete_bytes"] += int(item["size"])
        candidates.append(item)
    candidates.sort(key=lambda item: item.get("last_modified", ""))
    return candidates, families


def prune(bucket, now: dt.datetime, delete: bool) -> dict:
    objects, complete = bucket.list()
    if not complete:
        # A partial listing can miss pointers, and a missed pointer would let
        # its target look unreferenced. Delete nothing.
        return {"complete": False, "deleted": 0, "families": {}}
    candidates, families = plan(objects, protected(bucket, objects), now)
    deleted = 0
    if delete and candidates:
        # A save can publish a pointer between the first read and a delete
        # (a prefix's first pointer is written regardless of generation).
        # Read every pointer again right before deleting.
        keep = protected(bucket, objects)
        for item in candidates[:MAX_DELETES]:
            if item["key"] in keep:
                continue
            bucket.delete(item["key"])
            deleted += 1
    return {
        "complete": True,
        "dry_run": not delete,
        "would_delete": len(candidates),
        "would_delete_bytes": sum(int(item["size"]) for item in candidates),
        "deleted": deleted,
        "families": families,
    }


def render(summary: dict) -> str:
    gib = 1024**3
    if not summary["complete"]:
        return "R2 cache prune: listing incomplete; deleted nothing"
    verb = "would delete" if summary["dry_run"] else "deleted"
    count = summary["would_delete"] if summary["dry_run"] else summary["deleted"]
    lines = [f"R2 cache prune ({'dry run' if summary['dry_run'] else 'delete'}): {verb} {count} archives, "
             f"{summary['would_delete_bytes'] / gib:.1f} GiB eligible", ""]
    lines.append("| family | retention | archives | GiB | eligible | eligible GiB | kept by pointer |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|")
    for family, row in sorted(summary["families"].items()):
        lines.append(f"| `{family}` | {row['retention_days']} d | {row['archives']} | {row['bytes'] / gib:.1f} | "
                     f"{row['delete']} | {row['delete_bytes'] / gib:.1f} | {row['kept_by_pointer']} |")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--endpoint-url", required=True)
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--delete", action="store_true", help="send deletes; the default is a dry run")
    args = parser.parse_args(argv)
    summary = prune(Bucket(args.endpoint_url, args.bucket), dt.datetime.now(dt.timezone.utc), args.delete)
    print(json.dumps(summary, sort_keys=True))
    text = render(summary)
    print(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as handle:
            handle.write(text + "\n")
    return 0 if summary["complete"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
