#!/usr/bin/env python3
"""Conditional R2 writes and a lease lock, for publishers that run side by side.

The DEV publisher (cmux-next-dev-daily.yml) has no concurrency group: a group
replaces a pending run, which the dev-build rule forbids. Its writers stay
correct with R2's conditional requests instead.

    r2_cas.py get --key KEY --out FILE
        Writes the object to FILE and prints its ETag, or prints "absent".

    r2_cas.py put --key KEY --file FILE --cache-control CC [--content-type T]
                  (--if-match ETAG | --if-absent)
        Writes FILE only while the object still has ETAG (or does not exist).
        Exits 3 when another writer changed it first.

    r2_cas.py lock --key KEY --owner ID --ttl SECONDS --wait SECONDS
        Takes the lease at KEY: creates it only while absent, or replaces an
        expired lease only while it still holds the bytes read. Exits 3 when
        the wait runs out.

    r2_cas.py unlock --key KEY --owner ID
        Removes the lease while it still names ID and holds the bytes read.

Every call reads AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, R2_ENDPOINT and
R2_BUCKET from the environment.
"""

from __future__ import annotations

import argparse
import datetime as dt
import importlib.util
import json
import os
import sys
import time
import urllib.error
from pathlib import Path

_spec = importlib.util.spec_from_file_location("upload_r2_object", Path(__file__).with_name("upload-r2-object.py"))
r2 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(r2)

CONFLICT = 3


def _target(key: str, cache_control: str = "no-cache", content_type: str = "application/octet-stream") -> argparse.Namespace:
    return argparse.Namespace(
        endpoint_url=os.environ["R2_ENDPOINT"], bucket=os.environ["R2_BUCKET"], key=key,
        cache_control=cache_control, content_type=content_type,
    )


def _now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def get(key: str) -> tuple[str | None, bytes]:
    """The object's ETag and bytes, or (None, b"") when it does not exist."""
    request = r2._build_signed_request(_target(key), b"", _now(), method="GET")
    try:
        with r2._open_signed_request(request, timeout=120) as response:
            return response.headers.get("ETag"), response.read()
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None, b""
        raise


def put(key: str, body: bytes, *, etag: str | None, cache_control: str, content_type: str) -> bool:
    """Writes body while the object still has etag (None: while it does not exist)."""
    condition = {"if-match": etag} if etag else {"if-none-match": "*"}
    request = r2._build_signed_request(_target(key, cache_control, content_type), body, _now(), extra_headers=condition)
    try:
        with r2._open_signed_request(request, timeout=300) as response:
            response.read()
        return True
    except urllib.error.HTTPError as error:
        if error.code == 412:
            return False
        raise


def delete(key: str, etag: str) -> bool:
    request = r2._build_signed_request(_target(key), b"", _now(), method="DELETE", extra_headers={"if-match": etag})
    try:
        with r2._open_signed_request(request, timeout=60) as response:
            response.read()
        return True
    except urllib.error.HTTPError as error:
        if error.code in (404, 412):
            return False
        raise


def lock(key: str, owner: str, ttl: int, wait: int, clock=time.time, sleep=time.sleep) -> bool:
    deadline = clock() + wait
    while True:
        lease = json.dumps({"owner": owner, "expires": clock() + ttl}).encode()
        etag, body = get(key)
        if etag is None:
            if put(key, lease, etag=None, cache_control="no-store", content_type="application/json"):
                return True
        else:
            try:
                expires = float(json.loads(body or b"{}").get("expires", 0))
            except (ValueError, AttributeError):
                expires = 0
            if expires < clock() and put(key, lease, etag=etag, cache_control="no-store", content_type="application/json"):
                return True
        if clock() >= deadline:
            return False
        sleep(10)


def unlock(key: str, owner: str) -> bool:
    etag, body = get(key)
    if etag is None:
        return False
    try:
        held_by = json.loads(body or b"{}").get("owner")
    except (ValueError, AttributeError):
        held_by = None
    return held_by == owner and delete(key, etag)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    g = sub.add_parser("get")
    g.add_argument("--key", required=True)
    g.add_argument("--out", required=True)
    p = sub.add_parser("put")
    p.add_argument("--key", required=True)
    p.add_argument("--file", required=True)
    p.add_argument("--cache-control", required=True)
    p.add_argument("--content-type", default="application/octet-stream")
    cond = p.add_mutually_exclusive_group(required=True)
    cond.add_argument("--if-match")
    cond.add_argument("--if-absent", action="store_true")
    lk = sub.add_parser("lock")
    lk.add_argument("--key", required=True)
    lk.add_argument("--owner", required=True)
    lk.add_argument("--ttl", type=int, required=True)
    lk.add_argument("--wait", type=int, required=True)
    ul = sub.add_parser("unlock")
    ul.add_argument("--key", required=True)
    ul.add_argument("--owner", required=True)
    args = parser.parse_args(argv)

    if args.command == "get":
        etag, body = get(args.key)
        Path(args.out).write_bytes(body)
        print(etag or "absent")
        return 0
    if args.command == "put":
        written = put(args.key, Path(args.file).read_bytes(), etag=None if args.if_absent else args.if_match,
                      cache_control=args.cache_control, content_type=args.content_type)
        return 0 if written else CONFLICT
    if args.command == "lock":
        return 0 if lock(args.key, args.owner, args.ttl, args.wait) else CONFLICT
    unlock(args.key, args.owner)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
