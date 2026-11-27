#!/usr/bin/env python3
"""Download a workflow run's artifact over parallel HTTP ranges.

<<<<<<< HEAD
    download-run-artifact.py (--name <artifact> | --pattern <glob> | --artifact-id <id>) --out <dir>
                             [--run-id <run>] [--connections 16]
=======
    download-run-artifact.py --name <artifact> --out <dir> [--connections 16]
        [--read-timeout 20] [--deadline 600]
>>>>>>> origin/main

actions/download-artifact fetches the artifact's blob over one connection. On
Blacksmith macOS runners one connection to the Azure blob store sustains about
1.8 MB/s, so the 242 MB unsigned nightly app took 130-150 s in every signing
job, while 16 ranged connections to the same URL finish in about 10 s
(run 35801338411). The archive is checked against the artifact's recorded
SHA-256 digest before it is extracted, exactly as download-artifact does.

<<<<<<< HEAD
--run-id reads another run's artifacts (download-artifact's run-id), as the sign, deltas and dSYMs jobs do; it
defaults to GITHUB_RUN_ID. --pattern downloads every artifact whose name matches the glob into the one --out
(download-artifact's pattern with merge-multiple), and --artifact-id one artifact by id (its artifact-ids),
refused unless it belongs to the run. On the signing Mac download-artifact's one stream took 7m06s for the
prepared app, 8m20s for publish-nightly's variants and 5m57s for the deltas job's DMG (runs 43300596948,
43318988406), all while the job held the whole Mac.

Needs GH_TOKEN with actions:read and GITHUB_REPOSITORY, and GITHUB_RUN_ID without --run-id.
=======
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
>>>>>>> origin/main
"""

from __future__ import annotations

import argparse
import concurrent.futures
import email.utils
import fnmatch
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
from pathlib import Path

# resume-unsigned-nightly.py and nightly_ghostty_helper_reuse.py load this file by path, so its folder may
# not be on sys.path.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import deadline_http  # noqa: E402

API = os.environ.get("GITHUB_API_URL", "https://api.github.com")
# The archive is fetched in pieces of this size, pulled by --connections
# workers, so a slow connection holds up one small piece rather than a
# 1/connections share of the archive.
PIECE = 8 << 20


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
# (60 s timeouts) stays bounded too: 8 attempts of a call are at most 8 minutes. A longer budget
# (the sign stage's restore sets 1800 s) gets one more attempt per 120 s backoff step in it, so the
# cap never ends the retries before the budget does (8 attempts gave up at 510 s of 1800).
MAX_ATTEMPTS = max(8, int(RETRY_BUDGET_SECONDS // 120) + 5)
sleep = time.sleep
clock = time.monotonic
# One wall-clock deadline for the whole download (lookup, redirect and its
# refreshes), set by the first retry: no retry starts after it.
retry_deadline: float | None = None
# A range read waits at most RANGE_STALL_SECONDS for each byte, as urlopen(timeout=120) did, and ends as a whole
# by RANGE_DEADLINE_SECONDS. Before, nothing bounded the whole range: a server trickling bytes under the stall
# held it forever. 30 minutes is far past any range that is moving (the whole 242 MB app takes about 10 s over
# 16 ranges, and 611 s over download-artifact's one connection) and no tighter than the steps that run this,
# which have no step timeout of their own.
RANGE_STALL_SECONDS = 120
RANGE_DEADLINE_SECONDS = 30 * 60


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


def explain(error: urllib.error.HTTPError, what: str) -> None:
    """Name why GitHub refused before giving up: a bare "403 Forbidden" hid whether two nightly-next sign
    stages (runs 43129190893, 43139032769 on 2026-11-12) lost their finished build to a spent token
    quota or to a permission."""
    headers = error.headers or {}
    limits = " ".join(f"{k}={headers.get(k)}" for k in
                      ("X-RateLimit-Limit", "X-RateLimit-Remaining", "X-RateLimit-Reset", "X-RateLimit-Resource",
                       "Retry-After") if headers.get(k) is not None)
    try:
        body = (error.read() or b"")[:300].decode("utf-8", "replace").replace("\n", " ")
    except Exception:  # noqa: BLE001 - a diagnostic never replaces the error it explains
        body = ""
    print(f"{what}: gave up on HTTP {error.code} {limits or '(no rate-limit headers)'} {body}".rstrip(),
          file=sys.stderr)


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
                explain(error, what)
                raise
            if retry_deadline is None:
                retry_deadline = clock() + RETRY_BUDGET_SECONDS
            wait = retry_wait(error, attempt)
            if clock() + wait > retry_deadline:
                print(f"{what}: HTTP {error.code}; the next try ({wait:.0f}s away) is past this download's "
                      f"{RETRY_BUDGET_SECONDS:.0f}s retry budget (CMUX_ARTIFACT_RETRY_BUDGET_SECONDS)", file=sys.stderr)
                explain(error, what)
                raise
            print(f"{what}: HTTP {error.code}; retrying in {wait:.0f}s (attempt {attempt})", file=sys.stderr)
            sleep(wait)


def api_json(path: str, token: str) -> dict:
    def call() -> dict:
        req = urllib.request.Request(
            f"{API}{path}",
            headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"},
        )
        _, body, _ = deadline_http.request(req, 60, raise_errors=True)
        return json.loads(body)

    return with_retries(call, f"GET {path}")


def find_artifact(repo: str, run_id: str, name: str, token: str) -> dict:
    data = api_json(f"/repos/{repo}/actions/runs/{run_id}/artifacts?name={urllib.request.quote(name)}&per_page=100", token)
    matches = [a for a in data.get("artifacts", []) if a.get("name") == name and not a.get("expired")]
    if not matches:
        raise SystemExit(f"artifact {name!r} not found in run {run_id}")
    # A re-run attempt can leave more than one; the newest belongs to the attempt that feeds this job.
    return max(matches, key=lambda a: a.get("created_at", ""))


<<<<<<< HEAD
def find_artifacts(repo: str, run_id: str, pattern: str, token: str) -> list[dict]:
    """Every unexpired artifact of the run whose name matches PATTERN, the newest of each name. One listing of
    100: a run with more fails here, and download-artifact takes over (no page loop: a loop that reaches the
    API through with_retries' sleep reads as polling to tests/test_ci_no_github_token_polling.py)."""
    data = api_json(f"/repos/{repo}/actions/runs/{run_id}/artifacts?per_page=100", token)
    listed = data.get("artifacts", [])
    if int(data.get("total_count", len(listed))) > len(listed):
        raise SystemExit(f"run {run_id} has {data.get('total_count')} artifacts, more than one listing reads")
    newest: dict[str, dict] = {}
    for artifact in listed:
        name = artifact.get("name", "")
        if artifact.get("expired") or not fnmatch.fnmatchcase(name, pattern):
            continue
        if name not in newest or artifact.get("created_at", "") > newest[name].get("created_at", ""):
            newest[name] = artifact
    if not newest:
        raise SystemExit(f"no artifact matching {pattern!r} in run {run_id}")
    return [newest[name] for name in sorted(newest)]


def find_artifact_by_id(repo: str, run_id: str, artifact_id: str, token: str) -> dict:
    artifact = api_json(f"/repos/{repo}/actions/artifacts/{urllib.request.quote(artifact_id)}", token)
    owner = str((artifact.get("workflow_run") or {}).get("id") or "")
    if owner != str(run_id):
        raise SystemExit(f"artifact {artifact_id} belongs to run {owner or 'unknown'}, not {run_id}")
    if artifact.get("expired"):
        raise SystemExit(f"artifact {artifact_id} has expired")
    return artifact


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
    with deadline_http.stream(req, RANGE_DEADLINE_SECONDS, stall=RANGE_STALL_SECONDS, raise_errors=True) as resp:
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
=======
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
>>>>>>> origin/main


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
    which = parser.add_mutually_exclusive_group(required=True)
    which.add_argument("--name")
    which.add_argument("--pattern")
    which.add_argument("--artifact-id")
    parser.add_argument("--out", required=True)
    parser.add_argument("--run-id", default=os.environ.get("GITHUB_RUN_ID"))
    parser.add_argument("--connections", type=int, default=16)
    parser.add_argument("--read-timeout", type=float, default=20, help="seconds a range may send nothing")
    parser.add_argument("--deadline", type=float, default=600, help="seconds for the whole download")
    args = parser.parse_args()
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    repo, run_id = os.environ.get("GITHUB_REPOSITORY"), args.run_id
    if not (token and repo and run_id):
        raise SystemExit("GH_TOKEN, GITHUB_REPOSITORY and GITHUB_RUN_ID (or --run-id) are required")

    if args.name:
        artifacts = [find_artifact(repo, run_id, args.name, token)]
    elif args.pattern:
        artifacts = find_artifacts(repo, run_id, args.pattern, token)
    else:
        artifacts = [find_artifact_by_id(repo, run_id, args.artifact_id, token)]
    os.makedirs(args.out, exist_ok=True)
<<<<<<< HEAD
    for artifact in artifacts:
        with tempfile.TemporaryDirectory() as tmp:
            archive = os.path.join(tmp, "artifact.zip")
            started = time.monotonic()
            download(artifact, token, archive, max(1, args.connections))
            elapsed = time.monotonic() - started
            print(f"downloaded {artifact['name']} ({artifact['size_in_bytes']} bytes) in {elapsed:.1f}s")
            verify(archive, artifact)
            # download-artifact puts an artifact-ids download (no name, no merge-multiple) in <path>/<name>/;
            # match it, so the files land where the fallback would put them.
            out = os.path.join(args.out, artifact["name"]) if args.artifact_id else args.out
            with zipfile.ZipFile(archive) as bundle:
                bundle.extractall(out)
                for info in bundle.infolist():
                    print(f"extracted {info.filename}")
=======
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
>>>>>>> origin/main


if __name__ == "__main__":
    main()
