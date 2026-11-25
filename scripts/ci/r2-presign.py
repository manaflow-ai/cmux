#!/usr/bin/env python3
"""Prints a SigV4 presigned URL for one R2 (S3 API) object, so a machine that holds no R2 key (a throwaway image VM)
can PUT or GET exactly that object until the URL expires. The key comes from AWS_ACCESS_KEY_ID and
AWS_SECRET_ACCESS_KEY, as for upload-r2-object.py.

  r2-presign.py --endpoint-url https://ACCOUNT.r2.cloudflarestorage.com --bucket B --key K [--method PUT] [--expires 3600]

AWS_DEFAULT_REGION (default "auto", R2's region) and CMUX_R2_PRESIGN_AMZ_DATE (YYYYMMDDTHHMMSSZ, for tests) are read
from the environment.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import hmac
import os
import sys
import urllib.parse


def _quote(value: str, safe: str = "-_.~") -> str:
    return urllib.parse.quote(value, safe=safe)


def presign(*, endpoint_url: str, bucket: str, key: str, method: str, expires: int, access_key: str,
            secret_key: str, region: str, amz_date: str) -> str:
    parsed = urllib.parse.urlsplit(endpoint_url)
    if parsed.scheme != "https" or not parsed.netloc:
        raise ValueError(f"endpoint must be an https URL: {endpoint_url}")
    if not 1 <= expires <= 604800:
        raise ValueError("expires must be 1..604800 seconds")
    host = parsed.netloc
    date_stamp = amz_date[:8]
    scope = f"{date_stamp}/{region}/s3/aws4_request"
    path = f"/{_quote(bucket)}/{_quote(key, safe='-_.~/')}"
    query = {
        "X-Amz-Algorithm": "AWS4-HMAC-SHA256",
        "X-Amz-Credential": f"{access_key}/{scope}",
        "X-Amz-Date": amz_date,
        "X-Amz-Expires": str(expires),
        "X-Amz-SignedHeaders": "host",
    }
    canonical_query = "&".join(f"{_quote(k)}={_quote(v)}" for k, v in sorted(query.items()))
    canonical_request = "\n".join([method, path, canonical_query, f"host:{host}\n", "host", "UNSIGNED-PAYLOAD"])
    string_to_sign = "\n".join(
        ["AWS4-HMAC-SHA256", amz_date, scope, hashlib.sha256(canonical_request.encode()).hexdigest()]
    )
    signing_key = f"AWS4{secret_key}".encode()
    for part in (date_stamp, region, "s3", "aws4_request"):
        signing_key = hmac.new(signing_key, part.encode(), hashlib.sha256).digest()
    signature = hmac.new(signing_key, string_to_sign.encode(), hashlib.sha256).hexdigest()
    return f"https://{host}{path}?{canonical_query}&X-Amz-Signature={signature}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--endpoint-url", required=True)
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--method", default="PUT", choices=["PUT", "GET", "HEAD"])
    parser.add_argument("--expires", type=int, default=3600)
    args = parser.parse_args()
    access_key = os.environ.get("AWS_ACCESS_KEY_ID", "")
    secret_key = os.environ.get("AWS_SECRET_ACCESS_KEY", "")
    if not access_key or not secret_key:
        print("r2-presign: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are required", file=sys.stderr)
        return 2
    amz_date = os.environ.get("CMUX_R2_PRESIGN_AMZ_DATE") or dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    print(presign(endpoint_url=args.endpoint_url, bucket=args.bucket, key=args.key, method=args.method,
                  expires=args.expires, access_key=access_key, secret_key=secret_key,
                  region=os.environ.get("AWS_DEFAULT_REGION") or "auto", amz_date=amz_date))
    return 0


if __name__ == "__main__":
    sys.exit(main())
