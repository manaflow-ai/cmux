#!/usr/bin/env python3
"""Download one of this run's artifacts in parallel byte ranges, with stall detection.

actions/download-artifact reads the artifact's blob in one stream with no stall timeout. On the
nightly's Mac runners that stream ran 2 to 5 minutes for a 355 MB artifact (hosted Linux reads
the same blob in about 9 s), and in run 41478567483 both 5-minute attempts of signer-dmg-image's
"Download the signed app" ran out, so that tip was never published. This reads the blob in
parallel ranges instead: a range that sends nothing for --stall seconds is dropped and asked
for again from where it stopped, with a fresh signed URL. The zip's SHA-256 is checked against
the digest GitHub recorded at upload, then it is unpacked into --dest, as download-artifact does.

A failure exits non-zero and leaves --dest empty, so the workflow's download-artifact step can
take over. The token goes to the GitHub API only, never to the blob host.

Usage: fetch_run_artifact.py --name NAME --dest DIR [--run-id ID] [--repo OWNER/REPO]
Env: GH_TOKEN (actions: read), GITHUB_API_URL, GITHUB_REPOSITORY, GITHUB_RUN_ID.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

CHUNK = 1 << 20
MIN_PART = 16 << 20


class Failed(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D401
        return None


class Api:
    def __init__(self, base: str, token: str, repo: str):
        self.base, self.token, self.repo = base.rstrip("/"), token, repo

    def _request(self, url: str) -> urllib.request.Request:
        return urllib.request.Request(url, headers={
            "Authorization": f"Bearer {self.token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "cmux-fetch-run-artifact",
        })

    def artifact(self, run_id: str, name: str) -> dict:
        query = urllib.parse.urlencode({"name": name, "per_page": 100})
        url = f"{self.base}/repos/{self.repo}/actions/runs/{run_id}/artifacts?{query}"
        with urllib.request.urlopen(self._request(url), timeout=30) as response:
            items = json.load(response).get("artifacts") or []
        items = [a for a in items if a.get("name") == name and not a.get("expired")]
        if not items:
            raise Failed(f"run {run_id} has no artifact named {name}")
        return max(items, key=lambda a: int(a.get("id") or 0))

    def blob_url(self, artifact: dict) -> str:
        url = str(artifact.get("archive_download_url") or "")
        if not url.startswith(f"{self.base}/"):
            raise Failed("artifact download URL is not on the GitHub API host")
        try:
            urllib.request.build_opener(NoRedirect).open(self._request(url), timeout=30)
        except urllib.error.HTTPError as error:
            location = error.headers.get("Location")
            if error.code in (301, 302, 303, 307, 308) and location:
                return location
            raise Failed(f"artifact download answered HTTP {error.code}") from error
        raise Failed("artifact download did not redirect to a blob")


class Ranged:
    """Reads [start, end] of the blob into one file at the same offsets, resuming on a stall."""

    def __init__(self, api: Api, artifact: dict, url: str, out: Path, total: int, *, parts: int, stall: float,
                 attempts: int, deadline: float):
        self.api, self.artifact, self.url, self.out, self.total = api, artifact, url, out, total
        self.stall, self.attempts, self.deadline = stall, attempts, deadline
        self.lock = threading.Lock()
        if total <= 0:
            raise Failed("the artifact blob is empty")
        count = max(1, min(parts, -(-total // MIN_PART)))
        size = -(-total // count)
        self.ranges = [(i, min(i + size, total) - 1) for i in range(0, total, size)]
        self.errors: list[str] = []
        self.retries = 0

    def fresh_url(self, stale: str) -> str:
        with self.lock:
            if self.url == stale:
                self.url = self.api.blob_url(self.artifact)
            return self.url

    def part(self, fd: int, start: int, end: int) -> None:
        offset, url = start, self.url
        for attempt in range(1, self.attempts + 1):
            if time.monotonic() > self.deadline:
                break
            try:
                request = urllib.request.Request(url, headers={"Range": f"bytes={offset}-{end}",
                                                               "User-Agent": "cmux-fetch-run-artifact"})
                with urllib.request.urlopen(request, timeout=self.stall) as response:
                    if response.status != 206:
                        raise Failed(f"blob answered HTTP {response.status} to a range request")
                    while offset <= end:
                        if time.monotonic() > self.deadline:
                            raise Failed("deadline passed")
                        data = response.read(min(CHUNK, end + 1 - offset))
                        if not data:
                            raise Failed(f"blob closed the range at byte {offset}")
                        os.pwrite(fd, data, offset)
                        offset += len(data)
                return
            except (OSError, Failed, urllib.error.URLError) as error:
                with self.lock:
                    self.retries += 1
                print(f"range {start}-{end}: attempt {attempt} stopped at byte {offset}: {error}", file=sys.stderr)
                time.sleep(min(2 ** attempt, 8))
                try:
                    url = self.fresh_url(url)
                except (OSError, Failed) as refresh:
                    print(f"range {start}-{end}: could not refresh the blob URL: {refresh}", file=sys.stderr)
        with self.lock:
            self.errors.append(f"range {start}-{end} stopped at byte {offset}")

    def run(self) -> None:
        fd = os.open(self.out, os.O_RDWR | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            os.ftruncate(fd, self.total)
            threads = [threading.Thread(target=self.part, args=(fd, s, e), daemon=True) for s, e in self.ranges]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(max(0.0, self.deadline - time.monotonic()) + self.stall + 5)
            if any(thread.is_alive() for thread in threads):
                raise Failed("a range was still running past the deadline")
        finally:
            os.close(fd)
        if self.errors:
            raise Failed("; ".join(self.errors))


def blob_size(url: str, stall: float) -> int:
    request = urllib.request.Request(url, headers={"Range": "bytes=0-0", "User-Agent": "cmux-fetch-run-artifact"})
    with urllib.request.urlopen(request, timeout=stall) as response:
        content_range = response.headers.get("Content-Range") or ""
        response.read()
    if response.status != 206 or "/" not in content_range:
        raise Failed(f"blob did not answer a range request (HTTP {response.status})")
    return int(content_range.rsplit("/", 1)[1])


def extract(archive: Path, dest: Path) -> list[str]:
    root = dest.resolve()
    names = []
    with zipfile.ZipFile(archive) as zf:
        for info in zf.infolist():
            target = (dest / info.filename).resolve()
            if info.filename.startswith("/") or (target != root and root not in target.parents):
                raise Failed(f"artifact member {info.filename!r} leaves the destination")
            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with zf.open(info) as source, open(target, "wb") as sink:  # zipfile checks each member's CRC
                shutil.copyfileobj(source, sink, CHUNK)
            names.append(info.filename)
    return names


def fetch(api: Api, run_id: str, name: str, dest: Path, *, parts: int, stall: float, attempts: int,
          budget: float) -> None:
    started = time.monotonic()
    artifact = api.artifact(run_id, name)
    digest = str(artifact.get("digest") or "")
    dest.mkdir(parents=True, exist_ok=True)
    archive = dest.parent / f".{dest.name}.{artifact['id']}.zip"
    try:
        url = api.blob_url(artifact)
        ranged = Ranged(api, artifact, url, archive, blob_size(url, stall), parts=parts, stall=stall,
                        attempts=attempts, deadline=started + budget)
        ranged.run()
        sha = hashlib.sha256()
        with open(archive, "rb") as handle:
            for block in iter(lambda: handle.read(CHUNK), b""):
                sha.update(block)
        if digest.startswith("sha256:") and sha.hexdigest() != digest.split(":", 1)[1]:
            raise Failed(f"zip digest sha256:{sha.hexdigest()} is not the uploaded {digest}")
        names = extract(archive, dest)
    finally:
        archive.unlink(missing_ok=True)
    seconds = time.monotonic() - started
    mb = ranged.total / 1e6
    print(f"{name}: {mb:.0f} MB in {seconds:.1f} s ({mb / max(seconds, 0.001):.1f} MB/s) over "
          f"{len(ranged.ranges)} ranges, {ranged.retries} range retries, digest "
          f"{'checked' if digest.startswith('sha256:') else 'not recorded'}; unpacked {', '.join(names)}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--name", required=True)
    parser.add_argument("--dest", required=True, type=Path)
    parser.add_argument("--run-id", default=os.environ.get("GITHUB_RUN_ID", ""))
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--parts", type=int, default=16)
    parser.add_argument("--stall", type=float, default=20.0, help="seconds a range may send nothing")
    parser.add_argument("--attempts", type=int, default=5, help="tries per range")
    parser.add_argument("--budget", type=float, default=240.0, help="seconds for the whole download")
    args = parser.parse_args(argv)
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
    if not (token and args.run_id and args.repo):
        print("::warning::fetch_run_artifact: needs GH_TOKEN, a run id and a repository", file=sys.stderr)
        return 2
    api = Api(os.environ.get("GITHUB_API_URL", "https://api.github.com"), token, args.repo)
    try:
        fetch(api, args.run_id, args.name, args.dest, parts=args.parts, stall=args.stall,
              attempts=args.attempts, budget=args.budget)
    except (Failed, OSError, ValueError, zipfile.BadZipFile, urllib.error.URLError) as error:
        shutil.rmtree(args.dest, ignore_errors=True)
        print(f"::warning title=Ranged artifact download::{args.name}: {error}; download-artifact takes over",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
