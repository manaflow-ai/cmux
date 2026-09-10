#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import hmac
import json
import os
import random
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Callable


def _sign(key: bytes, message: str) -> bytes:
    return hmac.new(key, message.encode("utf-8"), hashlib.sha256).digest()


def _canonical_path(bucket: str, key: str) -> str:
    parts = [bucket] + [part for part in key.split("/") if part]
    return "/" + "/".join(urllib.parse.quote(part, safe="~") for part in parts)


def _get_signing_key(secret_key: str, date_stamp: str, region: str) -> bytes:
    date_key = _sign(("AWS4" + secret_key).encode("utf-8"), date_stamp)
    region_key = _sign(date_key, region)
    service_key = _sign(region_key, "s3")
    return _sign(service_key, "aws4_request")


def _amz_date() -> str:
    """SigV4 timestamp, fresh per attempt so retries never reuse a stale date.

    CMUX_R2_UPLOAD_AMZ_DATE pins it for signature tests.
    """

    pinned = os.environ.get("CMUX_R2_UPLOAD_AMZ_DATE")
    if pinned:
        return pinned
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def _retry_budget() -> tuple[int, float]:
    """Attempt count and base delay for transient failures.

    R2 answers some PutObject calls with HTTP 500 InternalError ("Please try
    again") and occasionally 429/503. Those are safe to retry: PutObject is
    idempotent and write-once uploads fall back to the digest check on 412.
    """

    attempts = int(os.environ.get("CMUX_R2_UPLOAD_MAX_ATTEMPTS", "5"))
    base = float(os.environ.get("CMUX_R2_UPLOAD_RETRY_BASE_SECONDS", "2"))
    return max(1, attempts), max(0.0, base)


def _is_transient(error: BaseException) -> bool:
    if isinstance(error, urllib.error.HTTPError):
        return error.code == 429 or error.code >= 500
    # urllib.error.URLError covers refused connections, DNS, and TLS
    # failures; socket.timeout and other OSErrors cover stalled reads.
    return isinstance(error, OSError)


def _describe(error: BaseException) -> str:
    if isinstance(error, urllib.error.HTTPError):
        return f"HTTP {error.code} {error.reason}"
    return str(error)


def _open_with_retry(
    build_request: Callable[[], urllib.request.Request],
    *,
    timeout: float,
    what: str,
) -> tuple[int, bytes]:
    """Send a request, retrying transient failures with jittered backoff.

    `build_request` runs on every attempt so each retry carries a fresh
    SigV4 date; the final failure propagates to the caller unchanged.
    """

    attempts, base = _retry_budget()
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(build_request(), timeout=timeout) as response:
                return response.status, response.read()
        except (urllib.error.HTTPError, OSError) as error:
            if attempt >= attempts or not _is_transient(error):
                raise
            if isinstance(error, urllib.error.HTTPError):
                error.read()
            delay = min(base * (2 ** (attempt - 1)), 30.0) * random.uniform(0.5, 1.5)
            sys.stderr.write(
                f"R2 {what} attempt {attempt}/{attempts} failed: {_describe(error)}; "
                f"retrying in {delay:.1f}s\n"
            )
            time.sleep(delay)
    raise AssertionError("unreachable")


def _build_signed_request(
    args: argparse.Namespace,
    body: bytes,
    amz_date: str,
    *,
    method: str = "PUT",
    extra_headers: dict[str, str] | None = None,
) -> urllib.request.Request:
    access_key = os.environ.get("AWS_ACCESS_KEY_ID", "")
    secret_key = os.environ.get("AWS_SECRET_ACCESS_KEY", "")
    region = os.environ.get("AWS_DEFAULT_REGION", "auto")
    if not access_key or not secret_key:
        raise SystemExit("AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are required")

    parsed = urllib.parse.urlsplit(args.endpoint_url.rstrip("/"))
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise SystemExit(f"Invalid R2 endpoint URL: {args.endpoint_url}")

    date_stamp = amz_date[:8]
    canonical_uri = _canonical_path(args.bucket, args.key)
    url = urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, canonical_uri, "", ""))
    payload_hash = hashlib.sha256(body).hexdigest()

    headers = {
        "host": parsed.netloc,
        "x-amz-content-sha256": payload_hash,
        "x-amz-date": amz_date,
    }
    if method == "PUT":
        headers["cache-control"] = args.cache_control
    if extra_headers:
        headers.update({name.lower(): value for name, value in extra_headers.items()})
    session_token = os.environ.get("AWS_SESSION_TOKEN")
    if session_token:
        headers["x-amz-security-token"] = session_token

    signed_headers = ";".join(sorted(headers))
    canonical_headers = "".join(f"{name}:{headers[name].strip()}\n" for name in sorted(headers))
    canonical_request = "\n".join(
        [
            method,
            canonical_uri,
            "",
            canonical_headers,
            signed_headers,
            payload_hash,
        ]
    )
    credential_scope = f"{date_stamp}/{region}/s3/aws4_request"
    string_to_sign = "\n".join(
        [
            "AWS4-HMAC-SHA256",
            amz_date,
            credential_scope,
            hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
        ]
    )
    signature = hmac.new(
        _get_signing_key(secret_key, date_stamp, region),
        string_to_sign.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    authorization = (
        "AWS4-HMAC-SHA256 "
        f"Credential={access_key}/{credential_scope}, "
        f"SignedHeaders={signed_headers}, "
        f"Signature={signature}"
    )

    request_headers = {name.title(): value for name, value in headers.items() if name != "host"}
    request_headers["Authorization"] = authorization
    request_body = body if method not in {"GET", "HEAD"} else None
    return urllib.request.Request(url, data=request_body, headers=request_headers, method=method)


def _read_existing_object(
    args: argparse.Namespace,
    *,
    expected_digest: str,
) -> bool:
    """Return true when an existing immutable object has the same bytes."""

    try:
        _open_with_retry(
            lambda: _build_signed_request(args, b"", _amz_date(), method="HEAD"),
            timeout=30,
            what=f"HEAD {args.key}",
        )
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return False
        raise

    _, existing = _open_with_retry(
        lambda: _build_signed_request(args, b"", _amz_date(), method="GET"),
        timeout=120,
        what=f"GET {args.key}",
    )
    actual_digest = hashlib.sha256(existing).hexdigest()
    if actual_digest != expected_digest:
        raise RuntimeError(
            f"immutable R2 object already exists with a different SHA-256: "
            f"{args.key} expected={expected_digest} actual={actual_digest}"
        )
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description="Upload one object to Cloudflare R2 using AWS SigV4.")
    parser.add_argument("--file", required=True, help="Local file to upload")
    parser.add_argument("--endpoint-url", required=True, help="R2 S3 endpoint URL")
    parser.add_argument("--bucket", required=True, help="R2 bucket name")
    parser.add_argument("--key", required=True, help="Object key inside the bucket")
    parser.add_argument("--cache-control", required=True, help="Cache-Control metadata")
    parser.add_argument(
        "--write-once",
        action="store_true",
        help="Refuse to overwrite an immutable object; accept an identical existing object",
    )
    parser.add_argument("--dry-run-json", action="store_true", help="Print the signed request instead of uploading")
    args = parser.parse_args()

    with open(args.file, "rb") as file:
        body = file.read()

    amz_date = _amz_date()

    body_digest = hashlib.sha256(body).hexdigest()
    if args.dry_run_json:
        request = _build_signed_request(
            args,
            body,
            amz_date,
            extra_headers={"if-none-match": "*"} if args.write_once else None,
        )
        print(
            json.dumps(
                {
                    "method": request.get_method(),
                    "url": request.full_url,
                    "headers": dict(request.header_items()),
                    "body_sha256": body_digest,
                    "write_once": args.write_once,
                },
                sort_keys=True,
            )
        )
        return 0

    try:
        if args.write_once and _read_existing_object(
            args,
            expected_digest=body_digest,
        ):
            print(f"Already present with matching digest: s3://{args.bucket}/{args.key}")
            return 0

        status, _ = _open_with_retry(
            lambda: _build_signed_request(
                args,
                body,
                _amz_date(),
                extra_headers={"if-none-match": "*"} if args.write_once else None,
            ),
            timeout=30,
            what=f"PUT {args.key}",
        )
        print(f"Uploaded {args.file} to s3://{args.bucket}/{args.key} ({status})")
        return 0
    except urllib.error.HTTPError as error:
        if args.write_once and error.code == 412:
            try:
                if _read_existing_object(
                    args,
                    expected_digest=body_digest,
                ):
                    print(f"Already present with matching digest: s3://{args.bucket}/{args.key}")
                    return 0
            except (urllib.error.HTTPError, RuntimeError) as retry_error:
                sys.stderr.write(f"R2 immutable-object check failed: {retry_error}\n")
                return 1
        sys.stderr.write(f"R2 upload failed: HTTP {error.code} {error.reason}\n")
        sys.stderr.write(error.read().decode("utf-8", errors="replace"))
        return 1
    except (OSError, RuntimeError) as error:
        sys.stderr.write(f"R2 upload failed: {error}\n")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
