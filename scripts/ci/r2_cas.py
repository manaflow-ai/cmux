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
        Exits 3 when another writer changed it first (HTTP 412 or 409).

    r2_cas.py delete --key KEY
        Removes an object this run alone created (a name unique to the run).
        Unconditional: R2 does not document conditional DELETE.

    r2_cas.py lock --key KEY --owner ID --ttl SECONDS --wait SECONDS
        Takes the lease at KEY: creates it only while absent, or replaces a
        released or expired lease only while it still holds the bytes read.
        Expiry is judged on R2's clock (the response Date against the lease's
        Last-Modified), never a runner's, so runners' clock skew cannot end a
        live lease early. Exits 3 when the wait runs out.

    r2_cas.py holds --key KEY --owner ID
        Exits 0 while ID holds the lease, 3 when it does not.

    r2_cas.py unlock --key KEY --owner ID
        Marks the lease released (a conditional PUT; R2 does not document
        conditional DELETE) while it still names ID and holds the bytes read.

Every call reads AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, R2_ENDPOINT and
R2_BUCKET from the environment.
"""

from __future__ import annotations

import argparse
import datetime as dt
import email.utils
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


def read(key: str) -> tuple[str | None, bytes, float]:
    """The object's ETag, bytes and age in seconds on R2's clock; (None, b"", 0) when absent."""
    request = r2._build_signed_request(_target(key), b"", _now(), method="GET")
    try:
        with r2._open_signed_request(request, timeout=120) as response:
            body = response.read()
            now = email.utils.parsedate_to_datetime(response.headers["Date"])
            modified = email.utils.parsedate_to_datetime(response.headers["Last-Modified"])
            return response.headers.get("ETag"), body, (now - modified).total_seconds()
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None, b"", 0.0
        raise


def get(key: str) -> tuple[str | None, bytes]:
    """The object's ETag and bytes, or (None, b"") when it does not exist."""
    etag, body, _ = read(key)
    return etag, body


def put(key: str, body: bytes, *, etag: str | None, cache_control: str, content_type: str) -> bool:
    """Writes body while the object still has etag (None: while it does not exist)."""
    condition = {"if-match": etag} if etag else {"if-none-match": "*"}
    request = r2._build_signed_request(_target(key, cache_control, content_type), body, _now(), extra_headers=condition)
    try:
        with r2._open_signed_request(request, timeout=300) as response:
            response.read()
        return True
    except urllib.error.HTTPError as error:
        # 412: the condition failed; 409: R2 refused a concurrent write to the key.
        if error.code in (409, 412):
            return False
        raise


def delete(key: str) -> None:
    request = r2._build_signed_request(_target(key), b"", _now(), method="DELETE")
    try:
        with r2._open_signed_request(request, timeout=60) as response:
            response.read()
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise


def _lease(body: bytes) -> dict:
    try:
        lease = json.loads(body or b"{}")
    except ValueError:
        return {}
    return lease if isinstance(lease, dict) else {}


def _store(key: str, lease: dict, etag: str | None) -> bool:
    return put(key, json.dumps(lease).encode(), etag=etag, cache_control="no-store", content_type="application/json")


def lock(key: str, owner: str, ttl: int, wait: int, clock=time.monotonic, sleep=time.sleep) -> bool:
    deadline = clock() + wait
    while True:
        etag, body, age = read(key)
        lease = _lease(body)
        free = etag is None or lease.get("released") or age > ttl
        if free and _store(key, {"owner": owner}, etag):
            return True
        if clock() >= deadline:
            return False
        sleep(10)


def holds(key: str, owner: str) -> bool:
    etag, body, _ = read(key)
    lease = _lease(body)
    return etag is not None and lease.get("owner") == owner and not lease.get("released")


def unlock(key: str, owner: str) -> bool:
    etag, body, _ = read(key)
    lease = _lease(body)
    if etag is None or lease.get("owner") != owner or lease.get("released"):
        return False
    return _store(key, {"owner": owner, "released": True}, etag)


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
    dl = sub.add_parser("delete")
    dl.add_argument("--key", required=True)
    lk = sub.add_parser("lock")
    lk.add_argument("--key", required=True)
    lk.add_argument("--owner", required=True)
    lk.add_argument("--ttl", type=int, required=True)
    lk.add_argument("--wait", type=int, required=True)
    hd = sub.add_parser("holds")
    hd.add_argument("--key", required=True)
    hd.add_argument("--owner", required=True)
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
    if args.command == "delete":
        delete(args.key)
        return 0
    if args.command == "lock":
        return 0 if lock(args.key, args.owner, args.ttl, args.wait) else CONFLICT
    if args.command == "holds":
        return 0 if holds(args.key, args.owner) else CONFLICT
    unlock(args.key, args.owner)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
