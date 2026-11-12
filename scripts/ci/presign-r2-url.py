#!/usr/bin/env python3
"""Create a short-lived AWS SigV4 GET URL for one private R2 object."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import hmac
import os
import urllib.parse


def _sign(key: bytes, message: str) -> bytes:
    return hmac.new(key, message.encode("utf-8"), hashlib.sha256).digest()


def _signing_key(secret: str, date_stamp: str, region: str) -> bytes:
    date_key = _sign(("AWS4" + secret).encode("utf-8"), date_stamp)
    region_key = _sign(date_key, region)
    service_key = _sign(region_key, "s3")
    return _sign(service_key, "aws4_request")


def _canonical_path(bucket: str, key: str) -> str:
    parts = [bucket] + [part for part in key.split("/") if part]
    return "/" + "/".join(urllib.parse.quote(part, safe="~") for part in parts)


def _canonical_query(values: dict[str, str]) -> str:
    return "&".join(
        f"{urllib.parse.quote(name, safe='~')}={urllib.parse.quote(value, safe='~')}"
        for name, value in sorted(values.items())
    )


def presign(args: argparse.Namespace) -> str:
    access_key = os.environ.get("AWS_ACCESS_KEY_ID", "")
    secret_key = os.environ.get("AWS_SECRET_ACCESS_KEY", "")
    if not access_key or not secret_key:
        raise SystemExit("AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are required")
    parsed = urllib.parse.urlsplit(args.endpoint_url.rstrip("/"))
    if parsed.scheme != "https" or not parsed.netloc:
        raise SystemExit("R2 endpoint URL must use HTTPS and include a host")
    if not args.bucket or not args.key or any(part in {".", ".."} for part in args.key.split("/")):
        raise SystemExit("bucket and key are required and key path traversal is refused")
    if not 1 <= args.expires_in <= 900:
        raise SystemExit("--expires-in must be between 1 and 900 seconds")

    amz_date = os.environ.get("CMUX_R2_PRESIGN_AMZ_DATE")
    if not amz_date:
        amz_date = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    if len(amz_date) != 16 or not amz_date.endswith("Z"):
        raise SystemExit("CMUX_R2_PRESIGN_AMZ_DATE must be an AWS timestamp")
    date_stamp = amz_date[:8]
    region = os.environ.get("AWS_DEFAULT_REGION", "auto")
    scope = f"{date_stamp}/{region}/s3/aws4_request"
    query = {
        "X-Amz-Algorithm": "AWS4-HMAC-SHA256",
        "X-Amz-Credential": f"{access_key}/{scope}",
        "X-Amz-Date": amz_date,
        "X-Amz-Expires": str(args.expires_in),
        "X-Amz-SignedHeaders": "host",
    }
    session_token = os.environ.get("AWS_SESSION_TOKEN")
    if session_token:
        query["X-Amz-Security-Token"] = session_token
    canonical_uri = _canonical_path(args.bucket, args.key)
    canonical_query = _canonical_query(query)
    canonical_request = "\n".join(
        ["GET", canonical_uri, canonical_query, f"host:{parsed.netloc}\n", "host", "UNSIGNED-PAYLOAD"]
    )
    string_to_sign = "\n".join(
        [
            "AWS4-HMAC-SHA256",
            amz_date,
            scope,
            hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
        ]
    )
    signature = hmac.new(
        _signing_key(secret_key, date_stamp, region),
        string_to_sign.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    query["X-Amz-Signature"] = signature
    return urllib.parse.urlunsplit(
        (parsed.scheme, parsed.netloc, canonical_uri, _canonical_query(query), "")
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint-url", required=True)
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--expires-in", type=int, default=900)
    print(presign(parser.parse_args()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
