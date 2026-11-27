#!/usr/bin/env python3
"""Download one artifact of the current workflow run over parallel HTTP ranges.

    download-run-artifact.py --name <artifact> --out <dir> [--connections 16]
        [--read-timeout 20] [--deadline 600]

actions/download-artifact fetches the artifact's blob over one connection. On
Blacksmith macOS runners one connection to the Azure blob store sustains about
1.8 MB/s, so the 242 MB unsigned nightly app took 130-150 s in every signing
job, while 16 ranged connections to the same URL finish in about 10 s
(run 35801338411). The archive is checked against the artifact's recorded
SHA-256 digest before it is extracted, exactly as download-artifact does.

Stalls cost seconds, not minutes. The archive is fetched in pieces of at most
8 MiB, at least one per connection, that --connections workers pull in turn,
so one slow connection holds up one piece rather than a whole share of the
archive. A piece that sends nothing for --read-timeout seconds (the old timeout
was 120 s) or is reset is retried from the byte it reached, against a freshly
signed URL, after a 1-4 s pause, and with half as many connections when the
failure looks like throttling (a reset, a timeout, HTTP 429 or 503). Retries go
on while they make progress. A round in which no piece moved, or --deadline,
ends the download with an error, and the workflow's actions/download-artifact
fallback takes over. A link that is merely slow keeps its progress: the
fallback reads the same blob over one connection and would be no faster.

Needs GH_TOKEN with actions:read, GITHUB_REPOSITORY and GITHUB_RUN_ID.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import http.client
import itertools
import json
import os
import socket
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile

API = os.environ.get("GITHUB_API_URL", "https://api.github.com")
# The archive is fetched in pieces of this size, pulled by --connections
# workers, so a slow connection holds up one small piece rather than a
# 1/connections share of the archive.
PIECE = 8 << 20


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D102
        return None


def api_json(path: str, token: str) -> dict:
    req = urllib.request.Request(
        f"{API}{path}",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"},
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)


def find_artifact(repo: str, run_id: str, name: str, token: str) -> dict:
    data = api_json(f"/repos/{repo}/actions/runs/{run_id}/artifacts?name={urllib.request.quote(name)}&per_page=100", token)
    matches = [a for a in data.get("artifacts", []) if a.get("name") == name and not a.get("expired")]
    if not matches:
        raise SystemExit(f"artifact {name!r} not found in run {run_id}")
    # A re-run attempt can leave more than one; the newest belongs to the attempt that feeds this job.
    return max(matches, key=lambda a: a.get("created_at", ""))


def blob_url(artifact: dict, token: str, timeout: float = 60) -> str:
    opener = urllib.request.build_opener(NoRedirect)
    req = urllib.request.Request(artifact["archive_download_url"], headers={"Authorization": f"Bearer {token}"})
    try:
        opener.open(req, timeout=timeout)
    except urllib.error.HTTPError as error:
        if error.code in (301, 302, 303, 307, 308) and error.headers.get("Location"):
            return error.headers["Location"]
        raise
    raise SystemExit("artifact download did not redirect to blob storage")


class DeadlineExceeded(Exception):
    """The download ran past --deadline."""


class RangeFailed(Exception):
    """A range stopped early; `offset` is the first byte it did not write."""

    def __init__(self, offset: int, cause: BaseException) -> None:
        super().__init__(str(cause))
        self.offset = offset
        self.cause = cause


def is_throttle(error: BaseException) -> bool:
    """True for errors that mean the blob store wants fewer connections."""
    if isinstance(error, urllib.error.HTTPError):
        return error.code in (429, 503)
    if isinstance(error, urllib.error.URLError) and isinstance(error.reason, BaseException):
        error = error.reason
    return isinstance(error, (ConnectionResetError, TimeoutError, socket.timeout))


class Overran(OSError):
    """The server sent more bytes than the range asked for."""


def read_timeout_until(read_timeout: float, deadline: float) -> float:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise DeadlineExceeded()
    return min(read_timeout, remaining)


def set_read_timeout(resp, timeout: float) -> None:
    """Re-arm the response socket's timeout before each read."""
    sock = getattr(getattr(getattr(resp, "fp", None), "raw", None), "_sock", None)
    if sock is not None:
        sock.settimeout(timeout)


def fetch_range(url: str, fd: int, lo: int, hi: int, read_timeout: float, deadline: float) -> None:
    """Write bytes lo..hi of url into fd; raise RangeFailed with the offset reached.

    Nothing is ever written outside lo..hi, and no blocking call outlives the
    deadline: every read's timeout is the smaller of read_timeout and the time
    left.
    """
    offset = lo
    try:
        req = urllib.request.Request(url, headers={"Range": f"bytes={lo}-{hi}"})
        with urllib.request.urlopen(req, timeout=read_timeout_until(read_timeout, deadline)) as resp:
            if resp.status != 206:
                raise OSError(f"range {lo}-{hi}: HTTP {resp.status}, expected 206")
            while True:
                set_read_timeout(resp, read_timeout_until(read_timeout, deadline))
                # read1 returns what has arrived, so a stall keeps the bytes before it.
                chunk = resp.read1(1 << 20)
                if not chunk:
                    break
                if offset + len(chunk) > hi + 1:
                    raise Overran(f"range {lo}-{hi}: server sent more than {hi - lo + 1} bytes")
                os.pwrite(fd, chunk, offset)
                offset += len(chunk)
        if offset != hi + 1:
            raise OSError(f"range {lo}-{hi}: short read ending at {offset}")
    except (OSError, urllib.error.URLError, http.client.HTTPException, DeadlineExceeded) as error:
        raise RangeFailed(offset, error) from error


def plan_ranges(size: int, connections: int, piece: int = PIECE) -> list[tuple[int, int]]:
    """Pieces of at most `piece` bytes, and at least one per connection."""
    part = max(1, min(piece, -(-size // max(1, connections))))
    return [(lo, min(size, lo + part) - 1) for lo in range(0, size, part)]


def download(
    artifact: dict,
    token: str,
    dest: str,
    connections: int,
    read_timeout: float = 20,
    deadline_seconds: float = 600,
    resolve_url=blob_url,
    piece: int = PIECE,
) -> None:
    size = int(artifact["size_in_bytes"])
    deadline = time.monotonic() + deadline_seconds
    url = resolve_url(artifact, token, timeout=min(60, deadline_seconds))
    pending = plan_ranges(size, connections, piece)
    workers = max(1, min(connections, len(pending)))
    fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    try:
        os.ftruncate(fd, size)
        # Rounds go on while they make progress; the deadline bounds them.
        for round_number in itertools.count(1):
            failed: list[tuple[int, int]] = []
            throttled = False
            moved = 0
            with concurrent.futures.ThreadPoolExecutor(min(workers, len(pending))) as pool:
                futures = {
                    pool.submit(fetch_range, url, fd, lo, hi, read_timeout, deadline): (lo, hi)
                    for lo, hi in pending
                }
                for future in concurrent.futures.as_completed(futures):
                    lo, hi = futures[future]
                    try:
                        future.result()
                        moved += hi - lo + 1
                    except RangeFailed as error:
                        # A server that overran the range gets the whole range again.
                        reached = lo if isinstance(error.cause, Overran) else error.offset
                        moved += reached - lo
                        reason = "deadline reached" if isinstance(error.cause, DeadlineExceeded) else error.cause
                        print(f"round {round_number}: range {lo}-{hi} stopped at {reached}: {reason}", file=sys.stderr)
                        throttled = throttled or is_throttle(error.cause)
                        failed.append((reached, hi))
            if not failed:
                return
            pending = sorted(failed)
            remaining = deadline - time.monotonic()
            if moved == 0 or remaining <= 1:
                break
            if throttled:
                workers = max(1, workers // 2)
            time.sleep(min(round_number, 4, remaining / 4))
            # The signed blob URL is short-lived; resolve a fresh one for each retry.
            url = resolve_url(artifact, token, timeout=max(1, min(60, deadline - time.monotonic())))
        left = sum(hi - lo + 1 for lo, hi in pending)
        raise SystemExit(f"{len(pending)} range(s), {left} bytes, unfinished after {round_number} round(s)")
    finally:
        os.close(fd)


def verify(path: str, artifact: dict) -> None:
    size = os.path.getsize(path)
    if size != int(artifact["size_in_bytes"]):
        raise SystemExit(f"size {size} != recorded {artifact['size_in_bytes']}")
    digest = artifact.get("digest") or ""
    if not digest.startswith("sha256:"):
        print("artifact has no recorded sha256 digest; verified size only")
        return
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
    parser.add_argument("--read-timeout", type=float, default=20, help="seconds a range may send nothing")
    parser.add_argument("--deadline", type=float, default=600, help="seconds for the whole download")
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
        download(artifact, token, archive, max(1, args.connections), args.read_timeout, args.deadline)
        elapsed = time.monotonic() - started
        print(f"downloaded {args.name} ({artifact['size_in_bytes']} bytes) in {elapsed:.1f}s")
        verify(archive, artifact)
        with zipfile.ZipFile(archive) as bundle:
            bundle.extractall(args.out)
            for info in bundle.infolist():
                print(f"extracted {info.filename}")


if __name__ == "__main__":
    main()
