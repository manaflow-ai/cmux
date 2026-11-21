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
take over.

It asks the artifact service download-artifact itself uses (ListArtifacts, GetSignedArtifactURL)
with the job's runtime token, so it needs no GITHUB_TOKEN permission. A run step does not get
that token: the workflow starts this from a pinned actions/github-script step, which hands its
own environment to this process only (never $GITHUB_ENV). The token goes to the artifact service
only, never to the blob host.

Usage: fetch_run_artifact.py --name NAME --dest DIR
Env: ACTIONS_RUNTIME_TOKEN, ACTIONS_RESULTS_URL.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import shutil
import sys
import threading
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

# The workflow runs this as `python3 -I` from a copy of scripts/, so its own folder is not on sys.path.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import deadline_http  # noqa: E402

CHUNK = 1 << 20
MIN_PART = 16 << 20


class Failed(Exception):
    pass


SERVICE = "twirp/github.actions.results.api.v1.ArtifactService/"


def backend_ids(token: str) -> tuple[str, str]:
    """(workflow run, workflow job) backend ids from the runtime token's Actions.Results scope."""
    try:
        payload = token.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    except (IndexError, ValueError) as error:
        raise Failed("the runtime token is not a JWT") from error
    for scope in str(claims.get("scp") or "").split():
        parts = scope.split(":")
        if len(parts) == 3 and parts[0] == "Actions.Results":
            return parts[1], parts[2]
    raise Failed("the runtime token has no Actions.Results scope")


def unwrap(value):
    """A protobuf wrapper value as JSON: a bare value, or {"value": ...} from some encoders."""
    return value.get("value") if isinstance(value, dict) else value


class Api:
    """The artifact service download-artifact itself uses: the job's runtime token, no GITHUB_TOKEN scope."""

    def __init__(self, results_url: str, token: str, *, https_only: bool = True):
        self.base = results_url.rstrip("/") + "/"
        self.token, self.https_only = token, https_only
        self.run_id, self.job_id = backend_ids(token)

    def _call(self, method: str, body: dict) -> dict:
        request = urllib.request.Request(self.base + SERVICE + method, data=json.dumps(body).encode(), method="POST",
                                         headers={"Authorization": f"Bearer {self.token}",
                                                  "Content-Type": "application/json",
                                                  "User-Agent": "cmux-fetch-run-artifact"})
        try:
            _, body, _ = deadline_http.request(request, 30, raise_errors=True)
            return json.loads(body)
        except urllib.error.HTTPError as error:
            raise Failed(f"artifact service {method} answered HTTP {error.code}") from error

    def artifact(self, name: str) -> dict:
        found = self._call("ListArtifacts", {"workflow_run_backend_id": self.run_id,
                                             "workflow_job_run_backend_id": self.job_id,
                                             "name_filter": name}).get("artifacts") or []
        found = [a for a in found if a.get("name") == name]
        if not found:
            raise Failed(f"this run has no artifact named {name}")
        def database_id(a: dict) -> int:
            return int(unwrap(a.get("database_id", a.get("databaseId"))) or 0)
        newest = max(found, key=database_id)
        return {"id": database_id(newest), "name": name,
                "run": newest.get("workflow_run_backend_id") or newest.get("workflowRunBackendId") or self.run_id,
                "job": newest.get("workflow_job_run_backend_id") or newest.get("workflowJobRunBackendId") or self.job_id,
                "digest": str(unwrap(newest.get("digest")) or "")}

    def blob_url(self, artifact: dict) -> str:
        answer = self._call("GetSignedArtifactURL", {"workflow_run_backend_id": artifact["run"],
                                                     "workflow_job_run_backend_id": artifact["job"],
                                                     "name": artifact["name"]})
        url = str(answer.get("signed_url") or answer.get("signedUrl") or "")
        if not url.startswith("https://" if self.https_only else "http"):
            raise Failed("the artifact service gave no https signed URL")
        return url


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
                # Each wait ends after --stall seconds of silence, as urlopen(timeout=stall) did, and the
                # whole range ends by the --budget deadline, so a trickling range cannot outlast it.
                left = max(self.deadline - time.monotonic(), 0.0)
                with deadline_http.stream(request, left, stall=self.stall) as response:
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


def blob_size(url: str, stall: float, deadline: float) -> int:
    """The blob's size from a one-byte range: each wait ends after STALL seconds of silence, the call by
    DEADLINE (the --budget deadline, a monotonic time)."""
    request = urllib.request.Request(url, headers={"Range": "bytes=0-0", "User-Agent": "cmux-fetch-run-artifact"})
    with deadline_http.stream(request, max(deadline - time.monotonic(), 0.0), stall=stall) as response:
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


def fetch(api: Api, name: str, dest: Path, *, parts: int, stall: float, attempts: int,
          budget: float) -> None:
    started = time.monotonic()
    artifact = api.artifact(name)
    digest = str(artifact.get("digest") or "")
    dest.mkdir(parents=True, exist_ok=True)
    archive = dest.parent / f".{dest.name}.{artifact['id']}.zip"
    try:
        url = api.blob_url(artifact)
        ranged = Ranged(api, artifact, url, archive, blob_size(url, stall, started + budget), parts=parts,
                        stall=stall, attempts=attempts, deadline=started + budget)
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
    parser.add_argument("--parts", type=int, default=16)
    parser.add_argument("--stall", type=float, default=20.0, help="seconds a range may send nothing")
    parser.add_argument("--attempts", type=int, default=5, help="tries per range")
    parser.add_argument("--budget", type=float, default=240.0, help="seconds for the whole download")
    args = parser.parse_args(argv)
    token, results_url = os.environ.get("ACTIONS_RUNTIME_TOKEN", ""), os.environ.get("ACTIONS_RESULTS_URL", "")
    if not (token and results_url):
        print("::warning::fetch_run_artifact: no ACTIONS_RUNTIME_TOKEN or ACTIONS_RESULTS_URL (run it from a JavaScript "
              "action step); download-artifact takes over", file=sys.stderr)
        return 2
    try:
        api = Api(results_url, token)
        fetch(api, args.name, args.dest, parts=args.parts, stall=args.stall,
              attempts=args.attempts, budget=args.budget)
    except (Failed, OSError, ValueError, zipfile.BadZipFile, urllib.error.URLError) as error:
        shutil.rmtree(args.dest, ignore_errors=True)
        print(f"::warning title=Ranged artifact download::{args.name}: {error}; download-artifact takes over",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
