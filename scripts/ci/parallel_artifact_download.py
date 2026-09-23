#!/usr/bin/env python3
"""Fetch an exact-run GitHub artifact ZIP over parallel HTTP range requests.

actions/download-artifact reads the provider blob over one connection. On the
Blacksmith macOS fleet that connection sustains about 2 MB/s, so every app-host
consumer spent 7-10 minutes pulling the ~860 MB product while compile admission
uploaded the same bytes (in parallel blocks) in about 10 seconds. This helper
reads the same GitHub artifact, from the same signed blob URL, over several
concurrent range requests instead.

Only the transport changes. The artifact must belong to this workflow run, the
whole ZIP must match the provider SHA-256 pinned by compile admission, and the
restore step still checks the inner archive SHA-256 before anything is used.
Any miss leaves the destination untouched and the canonical
actions/download-artifact step enabled.
"""
from __future__ import annotations

import concurrent.futures
import hashlib
import json
import lzma
import os
import re
import stat
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import zipfile
import zlib
from pathlib import Path
from urllib.parse import urlsplit

API = "https://api.github.com"
MAX_BYTES = 8 * 1024**3
CHUNK_BYTES = 16 * 1024 * 1024
CONNECTIONS = 16
ATTEMPTS = 4
REQUEST_TIMEOUT_SECONDS = 60
DEADLINE_SECONDS = 360
AGGREGATE_MEMBERS = {"app-host-products.tar.gz"}
PRODUCTS = {
    "app-host": ("app-host-products.tar.gz", "app-host-products"),
    "ios": ("ios-test-product.tar.gz", "ios-test-product"),
}


class TransportError(RuntimeError):
    """The fast path cannot deliver verified bytes; use the canonical download."""


def _product(kind):
    try:
        return PRODUCTS[kind]
    except (KeyError, TypeError):
        raise TransportError("unknown artifact product kind") from None


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D401
        return None


def _positive(value, name):
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise TransportError(f"invalid {name}")
    return value


def _repository(value):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", value or ""):
        raise TransportError("invalid repository")
    return value


def _token(token=None):
    token = token if token is not None else os.environ.get("GH_TOKEN", "")
    if not token:
        raise TransportError("GH_TOKEN is not set")
    return token


def _api_request(path, token):
    request = urllib.request.Request(f"{API}/{path}")
    # Unredirected: the token must never follow a redirect to the blob host.
    request.add_unredirected_header("Authorization", f"Bearer {token}")
    request.add_unredirected_header("Accept", "application/vnd.github+json")
    request.add_unredirected_header("X-GitHub-Api-Version", "2022-11-28")
    return request


def artifact_metadata(repository, artifact_id, token=None):
    opener = urllib.request.build_opener(_NoRedirect)
    path = f"repos/{_repository(repository)}/actions/artifacts/{_positive(artifact_id, 'artifact id')}"
    with opener.open(_api_request(path, _token(token)), timeout=30) as response:
        raw = response.read(1024 * 1024 + 1)
    if len(raw) > 1024 * 1024:
        raise TransportError("artifact metadata exceeds limit")
    return json.loads(raw)


def blob_url(repository, artifact_id, token=None):
    """Resolve the signed blob URL the canonical download would also read."""
    opener = urllib.request.build_opener(_NoRedirect)
    path = f"repos/{_repository(repository)}/actions/artifacts/{_positive(artifact_id, 'artifact id')}/zip"
    try:
        with opener.open(_api_request(path, _token(token)), timeout=30):
            raise TransportError("artifact download did not redirect")
    except urllib.error.HTTPError as error:
        location = error.headers.get("Location", "") if error.code in (301, 302, 303, 307, 308) else ""
        error.close()
        if not location:
            raise TransportError(f"artifact redirect unavailable (HTTP {error.code})") from None
    parsed = urlsplit(location)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise TransportError("artifact redirect is not a plain https URL")
    return location


def _fetch_range(url, start, end, fd, deadline):
    expected = end - start + 1
    request = urllib.request.Request(url, headers={"Range": f"bytes={start}-{end}"})
    timeout = max(1.0, min(REQUEST_TIMEOUT_SECONDS, deadline - time.monotonic()))
    with urllib.request.urlopen(request, timeout=timeout) as response:
        if response.status != 206:
            raise TransportError(f"range request returned HTTP {response.status}")
        content_range = response.headers.get("Content-Range", "")
        if not content_range.startswith(f"bytes {start}-{end}/"):
            raise TransportError("range response does not match the request")
        offset = start
        while offset <= end:
            if time.monotonic() > deadline:
                raise TransportError("parallel download deadline exceeded")
            block = response.read(min(1024 * 1024, end + 1 - offset))
            if not block:
                break
            written = os.pwrite(fd, block, offset)
            if written != len(block):
                raise TransportError("short write")
            offset += written
        if offset - start != expected or response.read(1):
            raise TransportError("range body length mismatch")


def download_ranges(url_factory, target, size, *, connections=CONNECTIONS,
                    chunk_bytes=CHUNK_BYTES, deadline_seconds=DEADLINE_SECONDS, fetch=_fetch_range):
    """Write exactly `size` bytes into target from concurrent range requests.

    url_factory() returns a signed URL; it is called again after an HTTP 403 so
    an expired signature re-resolves instead of failing the transfer.
    """
    size = _positive(size, "size")
    if size > MAX_BYTES:
        raise TransportError("artifact exceeds size limit")
    deadline = time.monotonic() + deadline_seconds
    lock = threading.Lock()
    state = {"url": url_factory()}

    def current_url(stale=None):
        with lock:
            if stale is not None and state["url"] == stale:
                state["url"] = url_factory()
            return state["url"]

    fd = os.open(target, os.O_RDWR | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.ftruncate(fd, size)
        ranges = [(start, min(start + chunk_bytes, size) - 1) for start in range(0, size, chunk_bytes)]

        def worker(span):
            last_error = None
            for attempt in range(ATTEMPTS):
                url = current_url()
                try:
                    fetch(url, span[0], span[1], fd, deadline)
                    return
                except urllib.error.HTTPError as error:
                    error.close()
                    last_error = error
                    if error.code == 403:
                        current_url(stale=url)
                    elif error.code < 500 and error.code != 429:
                        break
                except (OSError, TransportError) as error:
                    last_error = error
                if time.monotonic() > deadline:
                    break
                time.sleep(min(2 ** attempt, 8))
            raise TransportError(f"range {span[0]}-{span[1]} failed: {last_error}")

        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, connections)) as pool:
            futures = [pool.submit(worker, span) for span in ranges]
            try:
                for future in concurrent.futures.as_completed(futures):
                    future.result()
            except BaseException:
                for future in futures:
                    future.cancel()
                raise
    finally:
        os.close(fd)
    if os.path.getsize(target) != size:
        raise TransportError("downloaded size mismatch")


def download_zip(repository, artifact_id, target, size, token=None, **options):
    """Download one GitHub artifact ZIP; callers verify its provider digest."""
    token = _token(token)
    download_ranges(lambda: blob_url(repository, artifact_id, token), Path(target), size, **options)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for block in iter(lambda: source.read(4 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def unpack_single_member(archive, destination, allowed=AGGREGATE_MEMBERS):
    with zipfile.ZipFile(archive) as zipped:
        entries = zipped.infolist()
        if len(entries) != 1 or entries[0].filename not in allowed:
            raise TransportError("unexpected artifact contents")
        entry = entries[0]
        mode = entry.external_attr >> 16
        if (entry.is_dir() or stat.S_IFMT(mode) not in (0, stat.S_IFREG)
                or entry.flag_bits & 1 or not 0 < entry.file_size <= MAX_BYTES):
            raise TransportError("invalid archive entry")
        destination.mkdir()
        with zipped.open(entry) as source, (destination / entry.filename).open("wb") as output:
            copied = 0
            while block := source.read(4 * 1024 * 1024):
                copied += len(block)
                if copied > entry.file_size:
                    raise TransportError("archive expansion exceeded declared size")
                output.write(block)
        if copied != entry.file_size:
            raise TransportError("truncated archive")


def restore_aggregate(repository, artifact_id, run_id, expected_digest, destination, *,
                      token=None, metadata=artifact_metadata, fetch_zip=download_zip, product_kind="app-host"):
    """Restore one exact product kind; existing callers default to app-host."""
    member, _ = _product(product_kind)
    artifact_id = int(artifact_id) if str(artifact_id).isdecimal() else 0
    _positive(artifact_id, "artifact id")
    run_id = int(run_id) if str(run_id).isdecimal() else 0
    _positive(run_id, "run id")
    expected = str(expected_digest).removeprefix("sha256:").lower()
    if not re.fullmatch(r"[a-f0-9]{64}", expected):
        raise TransportError("expected provider digest is missing")
    info = metadata(repository, artifact_id, token)
    size = info.get("size_in_bytes")
    producer = info.get("workflow_run") or {}
    if (info.get("id") != artifact_id or info.get("expired") is not False
            or info.get("digest") != "sha256:" + expected
            or not isinstance(size, int) or not 0 < size <= MAX_BYTES
            or not isinstance(producer, dict) or producer.get("id") != run_id):
        raise TransportError("artifact does not match this run's pinned product")
    if destination.exists():
        destination.rmdir()  # Only an empty placeholder; never merge into stale products.
    destination.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="cmux-parallel-artifact-", dir=destination.parent) as work:
        staging = Path(work)
        zip_path = staging / "artifact.zip"
        fetch_zip(repository, artifact_id, zip_path, size, token)
        transfer_seconds = time.monotonic() - started
        if zip_path.stat().st_size != size or sha256_file(zip_path) != expected:
            raise TransportError("provider ZIP digest mismatch")
        unpack_single_member(zip_path, staging / "products", allowed={member})
        zip_path.unlink()
        (staging / "products").rename(destination)
    elapsed = time.monotonic() - started
    return {
        "artifact_id": artifact_id,
        "zip_bytes": size,
        "transfer_seconds": round(transfer_seconds, 3),
        "elapsed_seconds": round(elapsed, 3),
        "effective_mib_per_second": round(size / (1024 * 1024) / transfer_seconds, 3) if transfer_seconds > 0 else None,
    }


def main() -> int:
    output_path = os.environ.get("GITHUB_OUTPUT")

    def emit(**values):
        if output_path:
            with open(output_path, "a") as output:
                for key, value in values.items():
                    output.write(f"{key}={value}\n")

    emit(hit="false")
    try:
        kind = os.environ.get("ARTIFACT_PRODUCT_KIND", "app-host")
        _, directory = _product(kind)
        destination = Path(os.environ["RUNNER_TEMP"]) / directory
        record = restore_aggregate(
            os.environ.get("GITHUB_REPOSITORY", ""), os.environ.get("ARTIFACT_ID", ""),
            os.environ.get("GITHUB_RUN_ID", ""), os.environ.get("ARTIFACT_PROVIDER_DIGEST", ""),
            destination, product_kind=kind,
        )
    except (TransportError, OSError, ValueError, TypeError, urllib.error.URLError,
            zipfile.BadZipFile, EOFError, zlib.error, lzma.LZMAError,
            NotImplementedError, concurrent.futures.CancelledError) as error:
        print(f"::warning::Parallel artifact download missed ({type(error).__name__}: {error}); "
              "using actions/download-artifact.")
        return 0
    record.update({"run_id": os.environ.get("GITHUB_RUN_ID"), "job": os.environ.get("GITHUB_JOB"),
                   "shard": os.environ.get("CMUX_APP_HOST_SHARD"), "runner_name": os.environ.get("RUNNER_NAME")})
    print("CMUX_TEST_PRODUCT_PARALLEL_TRANSFER " + json.dumps(record, sort_keys=True))
    emit(hit="true", transfer_seconds=record["transfer_seconds"])
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as handle:
            handle.write("### Parallel compiled test product transfer\n\n```json\n")
            handle.write(json.dumps(record, indent=2, sort_keys=True))
            handle.write("\n```\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
