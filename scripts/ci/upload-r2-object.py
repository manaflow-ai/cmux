#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import hmac
import http.client
import json
import mimetypes
import os
import signal
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


class _RejectRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # A SigV4 signature is bound to its original host and path. Never
        # forward it or a session token to a redirect destination.
        return None


def _open_signed_request(request: urllib.request.Request, *, timeout: int):
    return urllib.request.build_opener(_RejectRedirects()).open(request, timeout=timeout)


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
    if parsed.scheme != "https" or not parsed.netloc:
        raise SystemExit("R2 endpoint URL must use HTTPS and include a host")

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
        headers["content-type"] = args.content_type
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


class ImmutableConflict(RuntimeError):
    """An immutable object exists with other bytes. Never retry: report it."""


class ReplaceConflict(RuntimeError):
    """--replace-sha256: the object no longer has the bytes the caller planned from."""


def _etag_of_planned_object(
    args: argparse.Namespace,
    *,
    amz_date: str,
) -> str:
    """The ETag of the current object when its bytes are the ones the caller
    planned from (--replace-sha256), for an If-Match write."""

    get = _build_signed_request(args, b"", amz_date, method="GET")
    with _open_signed_request(get, timeout=120) as response:
        existing = response.read()
        etag = response.headers.get("ETag")
    actual_digest = hashlib.sha256(existing).hexdigest()
    if actual_digest != args.replace_sha256.lower():
        raise ReplaceConflict(
            f"{args.key} changed since it was read: expected SHA-256 {args.replace_sha256.lower()}, "
            f"found {actual_digest}"
        )
    if not etag:
        raise RuntimeError(f"R2 returned no ETag for {args.key}")
    return etag


def _report_immutable_conflict(error: ImmutableConflict) -> None:
    # The GitHub annotation title is the contract with the cmux-tui artifacts
    # retry workflow (scripts/ci/cmux_tui_artifacts_retry.py): it never reruns
    # a run that has it, because a rebuild is not byte-identical.
    print(f"::error title=immutable-r2-conflict::{error} (a retry cannot fix this; "
          "publish from a new commit, or repair the object deliberately)", flush=True)


def _read_existing_object(
    args: argparse.Namespace,
    *,
    amz_date: str,
    expected_digest: str,
) -> bool:
    """Return true when an existing immutable object has the same bytes."""

    head = _build_signed_request(args, b"", amz_date, method="HEAD")
    try:
        with _open_signed_request(head, timeout=30) as response:
            response.read()
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return False
        raise

    get = _build_signed_request(args, b"", amz_date, method="GET")
    with _open_signed_request(get, timeout=120) as response:
        existing = response.read()
    actual_digest = hashlib.sha256(existing).hexdigest()
    if actual_digest != expected_digest:
        raise ImmutableConflict(
            f"immutable R2 object already exists with a different SHA-256: "
            f"{args.key} expected={expected_digest} actual={actual_digest}"
        )
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description="Upload one object to Cloudflare R2 using AWS SigV4.")
    parser.add_argument("--file", help="Local file to upload (required for an upload)")
    parser.add_argument("--endpoint-url", required=True, help="R2 S3 endpoint URL")
    parser.add_argument("--bucket", required=True, help="R2 bucket name")
    parser.add_argument("--key", required=True, help="Object key inside the bucket")
    parser.add_argument("--cache-control", help="Cache-Control metadata (required for an upload)")
    parser.add_argument(
        "--content-type",
        help="Content-Type metadata (default: infer from file extension, otherwise application/octet-stream)",
    )
    parser.add_argument(
        "--write-once",
        action="store_true",
        help="Refuse to overwrite an immutable object; accept an identical existing object",
    )
    parser.add_argument(
        "--conflict-exit-code",
        type=int,
        help="With --write-once: exit with this code, with no immutable-r2-conflict annotation, when the "
             "object exists with other bytes. For a caller that then waits for the other publisher's "
             "upload and keeps it (two runs of one commit or tree key at once).",
    )
    parser.add_argument(
        "--replace-sha256",
        metavar="HEX",
        help="Overwrite the object only while its bytes have this SHA-256 (the copy the caller planned "
             "from), with If-Match on its ETag. A changed object is not written: exit "
             "--conflict-exit-code (default 1).",
    )
    parser.add_argument("--dry-run-json", action="store_true", help="Print the signed request instead of uploading")
    parser.add_argument(
        "--download-to",
        metavar="PATH",
        help="Read the object into PATH (written whole or not at all) instead of uploading. Straight "
             "from R2: files.cmux.com served a 31 MB binary at 4-35 KB/s to a publish job that keeps an "
             "earlier publication (run 40637082673).",
    )
    args = parser.parse_args()
    if args.download_to:
        return _download(args)
    if not args.file or not args.cache_control:
        parser.error("--file and --cache-control are required for an upload")
    if args.replace_sha256 and args.write_once:
        parser.error("--replace-sha256 and --write-once are exclusive")
    if not args.content_type:
        content_type, encoding = mimetypes.guess_type(args.file)
        # A compressed file is not the unencoded type returned by guess_type.
        # Keep its bytes opaque unless the caller supplies the archive type.
        args.content_type = content_type if content_type and not encoding else "application/octet-stream"

    with open(args.file, "rb") as file:
        body = file.read()

    amz_date = os.environ.get("CMUX_R2_UPLOAD_AMZ_DATE")
    if not amz_date:
        amz_date = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")

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

    if args.replace_sha256:
        conflict_code = args.conflict_exit_code if args.conflict_exit_code is not None else 1
        try:
            etag = _etag_of_planned_object(args, amz_date=amz_date)
            request = _build_signed_request(args, body, amz_date, extra_headers={"if-match": etag})
            with _open_signed_request(request, timeout=30) as response:
                response.read()
                print(f"Replaced s3://{args.bucket}/{args.key} (ETag {etag}, {response.status})")
                return 0
        except ReplaceConflict as error:
            sys.stderr.write(f"not written: {error}\n")
            return conflict_code
        except urllib.error.HTTPError as error:
            if error.code == 412:
                sys.stderr.write(f"not written: s3://{args.bucket}/{args.key} changed before the write (HTTP 412)\n")
                return conflict_code
            sys.stderr.write(f"R2 upload failed: HTTP {error.code} {error.reason}\n")
            return 1
        except (OSError, RuntimeError) as error:
            sys.stderr.write(f"R2 upload failed: {error}\n")
            return 1

    # A transfer that stalls or drops (a write timeout, a reset, a 5xx) is
    # retried: one stalled PUT failed the whole cmux-tui tree publication
    # (run 40629788539, "The write operation timed out"). Each attempt signs
    # afresh. A write-once retry first reads the object back, so a PUT that
    # landed before its response was lost reads as already present.
    attempts = max(1, int(os.environ.get("CMUX_R2_UPLOAD_ATTEMPTS", "4")))
    retry_delay = float(os.environ.get("CMUX_R2_UPLOAD_RETRY_DELAY", "5"))
    for attempt in range(1, attempts + 1):
        if attempt > 1 and not os.environ.get("CMUX_R2_UPLOAD_AMZ_DATE"):
            amz_date = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        try:
            return _upload_once(args, body, amz_date, body_digest)
        except (urllib.error.HTTPError, OSError, http.client.HTTPException) as error:
            if attempt == attempts or not _transient(error):
                return _report_upload_error(args, error, amz_date, body_digest)
            sys.stderr.write(
                f"R2 upload of s3://{args.bucket}/{args.key} attempt {attempt} of {attempts} failed "
                f"({error}); retrying in {retry_delay * attempt:g}s\n"
            )
            time.sleep(retry_delay * attempt)
        except RuntimeError as error:
            return _report_upload_error(args, error, amz_date, body_digest)
    return 1


class DownloadDeadline(Exception):
    """A download attempt ran past its deadline. Not an OSError: the socket
    layer (create_connection over several addresses, urllib's open) catches
    OSError and would go on past an expired one-shot alarm."""


def _download(args: argparse.Namespace) -> int:
    attempts = max(1, int(os.environ.get("CMUX_R2_UPLOAD_ATTEMPTS", "4")))
    retry_delay = float(os.environ.get("CMUX_R2_UPLOAD_RETRY_DELAY", "5"))
    partial = f"{args.download_to}.partial"
    # A read that trickles (files.cmux.com at 4-35 KB/s) never trips the idle
    # socket timeout: each attempt also has a whole-attempt deadline, from
    # before the request opens to the last byte, enforced by SIGALRM so no
    # blocking connect, header wait or read outlives it.
    deadline = float(os.environ.get("CMUX_R2_DOWNLOAD_ATTEMPT_SECONDS", "300"))

    def expire(_signum, _frame):
        raise DownloadDeadline(f"the download did not finish within {deadline:g}s, too slow")

    previous = signal.signal(signal.SIGALRM, expire)
    try:
        return _download_attempts(args, attempts, retry_delay, partial, deadline)
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


def _download_attempts(args: argparse.Namespace, attempts: int, retry_delay: float, partial: str,
                       deadline: float) -> int:
    for attempt in range(1, attempts + 1):
        amz_date = os.environ.get("CMUX_R2_UPLOAD_AMZ_DATE") or dt.datetime.now(dt.timezone.utc).strftime(
            "%Y%m%dT%H%M%SZ"
        )
        try:
            signal.setitimer(signal.ITIMER_REAL, deadline)
            try:
                get = _build_signed_request(args, b"", amz_date, method="GET")
                with _open_signed_request(get, timeout=60) as response, open(partial, "wb") as out:
                    expected = response.headers.get("Content-Length")
                    size = 0
                    while chunk := response.read1(1 << 16):
                        out.write(chunk)
                        size += len(chunk)
            finally:
                signal.setitimer(signal.ITIMER_REAL, 0)
            if expected is not None and size != int(expected):
                raise ConnectionError(f"read {size} of {expected} bytes")
            os.replace(partial, args.download_to)
            print(f"Downloaded s3://{args.bucket}/{args.key} to {args.download_to} ({size} bytes)")
            return 0
        except (urllib.error.HTTPError, OSError, http.client.HTTPException, DownloadDeadline) as error:
            try:
                os.remove(partial)
            except FileNotFoundError:
                pass
            if attempt == attempts or not _transient(error):
                detail = f"HTTP {error.code} {error.reason}" if isinstance(error, urllib.error.HTTPError) else error
                sys.stderr.write(f"R2 download of s3://{args.bucket}/{args.key} failed: {detail}\n")
                return 22 if isinstance(error, urllib.error.HTTPError) and error.code == 404 else 1
            sys.stderr.write(
                f"R2 download of s3://{args.bucket}/{args.key} attempt {attempt} of {attempts} failed "
                f"({error}); retrying in {retry_delay * attempt:g}s\n"
            )
            time.sleep(retry_delay * attempt)
    return 1


def _transient(error: BaseException) -> bool:
    """A failure a later attempt can get past: no answer, or a 5xx or 429."""
    if isinstance(error, urllib.error.HTTPError):
        return error.code >= 500 or error.code == 429
    return isinstance(error, (OSError, http.client.HTTPException, DownloadDeadline))


def _upload_once(args: argparse.Namespace, body: bytes, amz_date: str, body_digest: str) -> int:
    if args.write_once and _read_existing_object(
        args,
        amz_date=amz_date,
        expected_digest=body_digest,
    ):
        print(f"Already present with matching digest: s3://{args.bucket}/{args.key}")
        return 0

    request = _build_signed_request(
        args,
        body,
        amz_date,
        extra_headers={"if-none-match": "*"} if args.write_once else None,
    )
    with _open_signed_request(request, timeout=30) as response:
        response.read()
        print(f"Uploaded {args.file} to s3://{args.bucket}/{args.key} ({response.status})")
        return 0


def _report_upload_error(args: argparse.Namespace, error: BaseException, amz_date: str, body_digest: str) -> int:
    try:
        raise error
    except urllib.error.HTTPError as error:
        if args.write_once and error.code == 412:
            try:
                if _read_existing_object(
                    args,
                    amz_date=amz_date,
                    expected_digest=body_digest,
                ):
                    print(f"Already present with matching digest: s3://{args.bucket}/{args.key}")
                    return 0
            except (urllib.error.HTTPError, RuntimeError, OSError, http.client.HTTPException) as retry_error:
                if isinstance(retry_error, ImmutableConflict):
                    if args.conflict_exit_code is not None:
                        sys.stderr.write(f"another publisher wrote it first: {retry_error}\n")
                        return args.conflict_exit_code
                    _report_immutable_conflict(retry_error)
                sys.stderr.write(f"R2 immutable-object check failed: {retry_error}\n")
                return 1
        sys.stderr.write(f"R2 upload failed: HTTP {error.code} {error.reason}\n")
        sys.stderr.write(error.read().decode("utf-8", errors="replace"))
        return 1
    except (OSError, RuntimeError, http.client.HTTPException) as error:
        if isinstance(error, ImmutableConflict):
            if args.conflict_exit_code is not None:
                sys.stderr.write(f"another publisher wrote it first: {error}\n")
                return args.conflict_exit_code
            _report_immutable_conflict(error)
        sys.stderr.write(f"R2 upload failed: {error}\n")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
