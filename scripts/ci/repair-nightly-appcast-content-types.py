#!/usr/bin/env python3
"""Repair only the four existing nightly feeds, preserving their current bytes."""

import argparse
import datetime as dt
import hashlib
import importlib.util
from pathlib import Path
import sys
import xml.etree.ElementTree as ET


spec = importlib.util.spec_from_file_location("r2_upload", Path(__file__).with_name("upload-r2-object.py"))
uploader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(uploader)

APPCASTS = ("appcast-arm64.xml", "appcast-x86_64.xml", "appcast-universal.xml", "appcast.xml")
METADATA = {"cache-control", "content-disposition", "content-encoding", "content-language", "expires", "x-amz-storage-class"}


def request(args, method, body=b"", headers=None):
    date = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    signed = uploader._build_signed_request(args, body, date, method=method, extra_headers=headers)
    with uploader._open_signed_request(signed, timeout=30) as response:
        return response.read(), {k.lower(): v for k, v in response.headers.items()}


def repair(endpoint_url, execute=False):
    for name in APPCASTS:
        args = argparse.Namespace(endpoint_url=endpoint_url, bucket="cmux-binaries", key=f"nightly/{name}",
                                  content_type="application/xml", cache_control="")
        body, original = request(args, "GET")
        if ET.fromstring(body).tag != "rss":
            raise RuntimeError(f"{args.key}: refusing to modify a non-RSS object")
        if not original.get("etag") or not original.get("cache-control"):
            raise RuntimeError(f"{args.key}: missing ETag or Cache-Control; refusing to modify")
        digest = hashlib.sha256(body).hexdigest()
        metadata = {k: v for k, v in original.items() if k in METADATA or k.startswith("x-amz-meta-")}
        if not execute:
            print(f"Would repair {args.key}: type={original.get('content-type')} sha256={digest}")
            continue
        if original.get("content-type") != "application/xml":
            args.cache_control = original["cache-control"]
            # Sign the precondition as well as every preserved metadata field.
            # A concurrent publication returns 412; never retry with stale bytes.
            request(args, "PUT", body, {**metadata, "if-match": original["etag"]})
        current, verified = request(args, "GET", headers={"if-match": original["etag"]})
        if current != body or verified.get("content-type") != "application/xml":
            raise RuntimeError(f"{args.key}: body or Content-Type verification failed")
        if any(verified.get(k) != v for k, v in metadata.items()):
            raise RuntimeError(f"{args.key}: metadata verification failed")
        print(f"Verified {args.key}: application/xml sha256={digest} etag={verified['etag']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint-url", required=True)
    parser.add_argument("--execute", action="store_true", help="Apply conditional metadata repairs (default: read only)")
    args = parser.parse_args()
    try:
        repair(args.endpoint_url, args.execute)
    except (OSError, RuntimeError, ET.ParseError) as error:
        # Never print request headers or signed requests containing credentials.
        sys.stderr.write(f"Nightly appcast repair stopped: {error}\n")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
