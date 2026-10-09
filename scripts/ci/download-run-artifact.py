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


def blob_url(artifact: dict, token: str) -> str:
    opener = urllib.request.build_opener(NoRedirect)
    req = urllib.request.Request(artifact["archive_download_url"], headers={"Authorization": f"Bearer {token}"})
    try:
        opener.open(req, timeout=60)
    except urllib.error.HTTPError as error:
        if error.code in (301, 302, 303, 307, 308) and error.headers.get("Location"):
            return error.headers["Location"]
        raise
    raise SystemExit("artifact download did not redirect to blob storage")


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
