#!/usr/bin/env python3
import argparse
import datetime as dt
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


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


def _build_signed_request(args: argparse.Namespace, body: bytes, amz_date: str) -> urllib.request.Request:
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
        "cache-control": args.cache_control,
        "host": parsed.netloc,
        "x-amz-content-sha256": payload_hash,
        "x-amz-date": amz_date,
    }
    session_token = os.environ.get("AWS_SESSION_TOKEN")
    if session_token:
        headers["x-amz-security-token"] = session_token

    signed_headers = ";".join(sorted(headers))
    canonical_headers = "".join(f"{name}:{headers[name].strip()}\n" for name in sorted(headers))
    canonical_request = "\n".join(
        [
            "PUT",
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
    return urllib.request.Request(url, data=body, headers=request_headers, method="PUT")


def _cache_busted(url: str, token: str) -> str:
    parsed = urllib.parse.urlsplit(url)
    query = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
    query.append(("cmux_verify", token))
    return urllib.parse.urlunsplit(
        (parsed.scheme, parsed.netloc, parsed.path, urllib.parse.urlencode(query), parsed.fragment)
    )


def verify_publication(url: str, expected_body: bytes, *, attempts: int, delay: float) -> tuple[bool, str]:
    expected_hash = hashlib.sha256(expected_body).hexdigest()
    last_error = "no response"
    for attempt in range(1, attempts + 1):
        request = urllib.request.Request(
            _cache_busted(url, f"{expected_hash}-{time.time_ns()}-{attempt}"),
            headers={"Cache-Control": "no-cache", "User-Agent": "cmux-r2-publication-verifier"},
        )
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                actual_body = response.read()
            actual_hash = hashlib.sha256(actual_body).hexdigest()
            if actual_body == expected_body:
                return True, actual_hash
            last_error = f"served SHA-256 {actual_hash}, expected {expected_hash}"
        except (OSError, urllib.error.URLError) as error:
            last_error = str(error)
        if attempt < attempts:
            time.sleep(delay)
    return False, last_error


def main() -> int:
    parser = argparse.ArgumentParser(description="Upload one object to Cloudflare R2 using AWS SigV4.")
    parser.add_argument("--file", required=True, help="Local file to upload")
    parser.add_argument("--endpoint-url", required=True, help="R2 S3 endpoint URL")
    parser.add_argument("--bucket", required=True, help="R2 bucket name")
    parser.add_argument("--key", required=True, help="Object key inside the bucket")
    parser.add_argument("--cache-control", required=True, help="Cache-Control metadata")
    parser.add_argument("--verify-url", help="Public URL that must serve the uploaded bytes")
    parser.add_argument("--verify-attempts", type=int, default=10)
    parser.add_argument("--verify-delay", type=float, default=2.0)
    parser.add_argument("--dry-run-json", action="store_true", help="Print the signed request instead of uploading")
    args = parser.parse_args()

    with open(args.file, "rb") as file:
        body = file.read()

    amz_date = os.environ.get("CMUX_R2_UPLOAD_AMZ_DATE")
    if not amz_date:
        amz_date = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")

    request = _build_signed_request(args, body, amz_date)
    if args.dry_run_json:
        print(
            json.dumps(
                {
                    "method": request.get_method(),
                    "url": request.full_url,
                    "headers": dict(request.header_items()),
                    "body_sha256": hashlib.sha256(body).hexdigest(),
                },
                sort_keys=True,
            )
        )
        return 0

    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            response.read()
            print(f"Uploaded {args.file} to s3://{args.bucket}/{args.key} ({response.status})")
        if args.verify_url:
            verified, detail = verify_publication(
                args.verify_url,
                body,
                attempts=args.verify_attempts,
                delay=args.verify_delay,
            )
            if not verified:
                sys.stderr.write(
                    f"R2 upload succeeded but public verification failed for {args.verify_url}: {detail}\n"
                )
                return 1
            print(f"Verified public appcast bytes at {args.verify_url} (SHA-256 {detail})")
        return 0
    except urllib.error.HTTPError as error:
        sys.stderr.write(f"R2 upload failed: HTTP {error.code} {error.reason}\n")
        sys.stderr.write(error.read().decode("utf-8", errors="replace"))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
