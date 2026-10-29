#!/usr/bin/env python3
"""Download one artifact of the current workflow run over parallel HTTP ranges.

    download-run-artifact.py --name <artifact> --out <dir> [--connections 16]

actions/download-artifact fetches the artifact's blob over one connection. On
Blacksmith macOS runners one connection to the Azure blob store sustains about
1.8 MB/s, so the 242 MB unsigned nightly app took 130-150 s in every signing
job, while 16 ranged connections to the same URL finish in about 10 s
(run 35801338411). The archive is checked against the artifact's recorded
SHA-256 digest before it is extracted, exactly as download-artifact does.

Needs GH_TOKEN with actions:read, GITHUB_REPOSITORY and GITHUB_RUN_ID.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import email.utils
import hashlib
import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile

API = os.environ.get("GITHUB_API_URL", "https://api.github.com")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D102
        return None


# GitHub refuses a call over the installation's rate limit with 403 or 429, and its
# secondary limit sends a 403 with no rate-limit headers. A refused lookup made the
# prepare job fall back to download-artifact's single connection: 611 s for the
# unsigned app on run 40378565252 instead of about 2 min. Wait and retry instead,
# within a bound far below what that fallback costs.
def retryable(code: int) -> bool:
    """A refusal over a limit (403, 429) or a server error (any 5xx)."""
    return code in (403, 429) or 500 <= code < 600


RETRY_BUDGET_SECONDS = float(os.environ.get("CMUX_ARTIFACT_RETRY_BUDGET_SECONDS", "240"))
# At most this many attempts per call, whatever the waits, so the calls' own time
# (60 s timeouts) stays bounded too: 8 attempts of a call are at most 8 minutes.
MAX_ATTEMPTS = 8
sleep = time.sleep
clock = time.monotonic
# One wall-clock deadline for the whole download (lookup, redirect and its
# refreshes), set by the first retry: no retry starts after it.
retry_deadline: float | None = None


def retry_wait(error: urllib.error.HTTPError, attempt: int, now: float | None = None) -> float:
    """Seconds to wait before retrying a refused call: Retry-After, the limit's reset, else backoff.

    Never less than one second, so retries never spin.
    """
    now = time.time() if now is None else now
    headers = error.headers or {}
    retry_after = (headers.get("Retry-After") or "").strip()
    if retry_after.isdigit():
        return max(1.0, float(retry_after))
    if retry_after:
        try:
            return max(1.0, email.utils.parsedate_to_datetime(retry_after).timestamp() - now)
        except (TypeError, ValueError):
            pass
    if headers.get("X-RateLimit-Remaining") == "0" and (headers.get("X-RateLimit-Reset") or "").isdigit():
        return max(1.0, float(headers["X-RateLimit-Reset"]) - now + 1)
    return min(120.0, 10.0 * 2 ** (attempt - 1))


def with_retries(call, what: str):
    """Run call(); retry a refused or failed GitHub response until the shared deadline or MAX_ATTEMPTS."""
    global retry_deadline
    attempt = 0
    while True:
        attempt += 1
        try:
            return call()
        except urllib.error.HTTPError as error:
            if not retryable(error.code) or attempt >= MAX_ATTEMPTS:
                raise
            if retry_deadline is None:
                retry_deadline = clock() + RETRY_BUDGET_SECONDS
            wait = retry_wait(error, attempt)
            if clock() + wait > retry_deadline:
                raise
            print(f"{what}: HTTP {error.code}; retrying in {wait:.0f}s (attempt {attempt})", file=sys.stderr)
            sleep(wait)


def api_json(path: str, token: str) -> dict:
    def call() -> dict:
        req = urllib.request.Request(
            f"{API}{path}",
            headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"},
        )
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.load(resp)

    return with_retries(call, f"GET {path}")


def find_artifact(repo: str, run_id: str, name: str, token: str) -> dict:
    data = api_json(f"/repos/{repo}/actions/runs/{run_id}/artifacts?name={urllib.request.quote(name)}&per_page=100", token)
    matches = [a for a in data.get("artifacts", []) if a.get("name") == name and not a.get("expired")]
    if not matches:
        raise SystemExit(f"artifact {name!r} not found in run {run_id}")
    # A re-run attempt can leave more than one; the newest belongs to the attempt that feeds this job.
    return max(matches, key=lambda a: a.get("created_at", ""))


def blob_url(artifact: dict, token: str) -> str:
    def call() -> str:
        opener = urllib.request.build_opener(NoRedirect)
        req = urllib.request.Request(artifact["archive_download_url"], headers={"Authorization": f"Bearer {token}"})
        try:
            opener.open(req, timeout=60)
        except urllib.error.HTTPError as error:
            if error.code in (301, 302, 303, 307, 308) and error.headers.get("Location"):
                return error.headers["Location"]
            raise
        raise SystemExit("artifact download did not redirect to blob storage")

    return with_retries(call, "artifact redirect")


def fetch_range(url: str, fd: int, lo: int, hi: int) -> None:
    req = urllib.request.Request(url, headers={"Range": f"bytes={lo}-{hi}"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        if resp.status != 206:
            raise OSError(f"range {lo}-{hi}: HTTP {resp.status}, expected 206")
        offset = lo
        while True:
            chunk = resp.read(1 << 20)
            if not chunk:
                break
            os.pwrite(fd, chunk, offset)
            offset += len(chunk)
    if offset != hi + 1:
        raise OSError(f"range {lo}-{hi}: short read ending at {offset}")


def download(artifact: dict, token: str, dest: str, connections: int) -> None:
    size = int(artifact["size_in_bytes"])
    url = blob_url(artifact, token)
    part = max(1, -(-size // connections))
    ranges = [(lo, min(size, lo + part) - 1) for lo in range(0, size, part)]
    fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    try:
        os.ftruncate(fd, size)
        pending = ranges
        for attempt in range(1, 4):
            failed = []
            with concurrent.futures.ThreadPoolExecutor(len(pending)) as pool:
                futures = {pool.submit(fetch_range, url, fd, lo, hi): (lo, hi) for lo, hi in pending}
                for future in concurrent.futures.as_completed(futures):
                    try:
                        future.result()
                    except (OSError, urllib.error.URLError) as error:
                        print(f"attempt {attempt}: {error}", file=sys.stderr)
                        failed.append(futures[future])
            if not failed:
                return
            pending = failed
            time.sleep(2 * attempt)
            # The signed blob URL is short-lived; resolve a fresh one for retries.
            url = blob_url(artifact, token)
        raise SystemExit(f"{len(pending)} range(s) failed after retries")
    finally:
        os.close(fd)


def verify(path: str, artifact: dict) -> None:
    size = os.path.getsize(path)
    if size != int(artifact["size_in_bytes"]):
        raise SystemExit(f"size {size} != recorded {artifact['size_in_bytes']}")
    digest = artifact.get("digest") or ""
    if not digest.startswith("sha256:"):
        raise SystemExit("artifact has no recorded sha256 digest; refusing unverified input")
    sha = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            sha.update(chunk)
    if sha.hexdigest() != digest.removeprefix("sha256:"):
        raise SystemExit(f"sha256 {sha.hexdigest()} != recorded {digest}")
    print(f"verified {digest}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--name", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--connections", type=int, default=16)
    args = parser.parse_args()
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    repo, run_id = os.environ.get("GITHUB_REPOSITORY"), os.environ.get("GITHUB_RUN_ID")
    if not (token and repo and run_id):
        raise SystemExit("GH_TOKEN, GITHUB_REPOSITORY and GITHUB_RUN_ID are required")

    artifact = find_artifact(repo, run_id, args.name, token)
    os.makedirs(args.out, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        archive = os.path.join(tmp, "artifact.zip")
        started = time.monotonic()
        download(artifact, token, archive, max(1, args.connections))
        elapsed = time.monotonic() - started
        print(f"downloaded {args.name} ({artifact['size_in_bytes']} bytes) in {elapsed:.1f}s")
        verify(archive, artifact)
        with zipfile.ZipFile(archive) as bundle:
            bundle.extractall(args.out)
            for info in bundle.infolist():
                print(f"extracted {info.filename}")


if __name__ == "__main__":
    main()
