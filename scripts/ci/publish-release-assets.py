#!/usr/bin/env python3
"""Resumable GitHub release uploads: immutable files, aliases, then feeds.

GitHub can accept an upload before its response times out, or leave a `starter`
asset after a 502. Reconcile the server's size, state and SHA-256 before retrying.
The workflows serialize writers to each release; this is not a distributed lock.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, replace
import glob
import hashlib
import json
import mimetypes
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from urllib.parse import quote, urlencode


class RequestError(RuntimeError):
    def __init__(self, message: str, *, status: int = 0):
        super().__init__(message)
        self.status = status

    @property
    def retryable(self) -> bool:
        return self.status in (0, 408, 429) or self.status >= 500


def backoff(attempt: int) -> None:
    time.sleep(2 ** (attempt + 1))


@dataclass(frozen=True)
class Asset:
    path: Path
    size: int
    digest: str
    replace: bool = False

    @classmethod
    def read(cls, path: Path, *, replace: bool = False) -> Asset:
        digest = hashlib.sha256()
        size = 0
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                size += len(chunk)
                digest.update(chunk)
        if not size:
            raise ValueError(f"Empty release asset: {path}")
        return cls(path.resolve(), size, "sha256:" + digest.hexdigest(), replace)

    def matches(self, remote: dict) -> bool:
        return (remote.get("name") == self.path.name and remote.get("state") == "uploaded"
                and remote.get("size") == self.size and remote.get("digest") == self.digest)


class GitHub:
    def __init__(self, repo: str, token: str, *, api_url: str = "https://api.github.com",
                 upload_url: str = "https://uploads.github.com"):
        if not re.fullmatch(r"[\w.-]+/[\w.-]+", repo):
            raise ValueError("Expected --repo owner/name")
        if not token or any(char in token for char in '\r\n"\\'):
            raise ValueError("GH_TOKEN must contain a valid token")
        self.repo, self.token = repo, token
        self.api_url, self.upload_url = api_url, upload_url

    def request(self, method: str, url: str, *, file: Path | None = None,
                body: bytes | None = None, content_type: str | None = None):
        """curl streams large files and bounds both stalled and total transfer time.

        Pass credentials on stdin, never argv, and do not follow redirects.
        JSON reads/deletes can retry directly; uploads reconcile in ensure_asset.
        """
        if file is not None and body is not None:
            raise ValueError("file and body are mutually exclusive")
        attempts = 1 if file or method in {"POST", "PATCH"} else 3
        for attempt in range(attempts):
            try:
                return self._request(method, url, file=file, body=body, content_type=content_type)
            except RequestError as error:
                if not error.retryable or attempt + 1 == attempts:
                    raise
                backoff(attempt)

    def _request(self, method: str, url: str, *, file: Path | None = None,
                 body: bytes | None = None, content_type: str | None = None):
        timeout = 600 if file else 60
        content_type = content_type or ((mimetypes.guess_type(file.name)[0] or "application/octet-stream") if file else "application/json")
        config = (f'header = "Authorization: Bearer {self.token}"\n'
                  'header = "Accept: application/vnd.github+json"\n'
                  'header = "X-GitHub-Api-Version: 2022-11-28"\n')
        with tempfile.TemporaryDirectory(prefix="cmux-release-upload-") as directory:
            output = Path(directory) / "response.json"
            body_path = None
            if body is not None:
                body_path = Path(directory) / "request-body"
                body_path.write_bytes(body)
            command = ["curl", "--disable", "--config", "-", "--silent", "--show-error",
                       "--request", method, "--connect-timeout", "30", "--max-time", str(timeout),
                       "--speed-limit", "1024", "--speed-time", "60", "--retry", "0",
                       "--header", f"Content-Type: {content_type}", "--output", str(output),
                       "--write-out", "%{http_code}", url]
            if file:
                command += ["--data-binary", "@" + str(file)]
            elif body_path:
                command += ["--data-binary", "@" + str(body_path)]
            try:
                result = subprocess.run(command, input=config, capture_output=True, text=True, timeout=timeout + 10)
            except subprocess.TimeoutExpired as error:
                raise RequestError(f"{method} transfer exceeded {timeout}s") from error
            if result.returncode:
                # curl's diagnostics never contain our stdin config, but redact
                # defensively before reporting any external command output.
                detail = result.stderr.strip().replace(self.token, "***")
                raise RequestError(f"{method} curl exit {result.returncode}: {detail}")
            status = int(result.stdout)
            if not 200 <= status < 300:
                raise RequestError(f"{method} HTTP {status}", status=status)
            body = output.read_text()
            if not body:
                return None
            try:
                return json.loads(body)
            except json.JSONDecodeError as error:
                raise RequestError(f"{method} returned invalid JSON") from error

    def release_id(self, tag: str) -> int:
        url = f"{self.api_url}/repos/{self.repo}/releases/tags/{quote(tag, safe='')}"
        try:
            release = self.request("GET", url)
        except RequestError as error:
            if error.status != 404:
                raise
            release = self.request(
                "POST",
                f"{self.api_url}/repos/{self.repo}/releases",
                body=json.dumps({"tag_name": tag, "name": tag, "draft": True, "prerelease": True}).encode(),
            )
        return int(release["id"])

    def assets(self, release_id: int) -> dict[str, dict]:
        result = {}
        page = 1
        while True:
            entries = self.request("GET", f"{self.api_url}/repos/{self.repo}/releases/{release_id}/assets?per_page=100&page={page}")
            for asset in entries:
                result[asset["name"]] = asset
            if len(entries) < 100:
                return result
            page += 1

    def delete(self, asset_id: int) -> None:
        try:
            self.request("DELETE", f"{self.api_url}/repos/{self.repo}/releases/assets/{asset_id}")
        except RequestError as error:
            if error.status != 404:
                raise

    def upload(self, release_id: int, asset: Asset) -> dict:
        query = urlencode({"name": asset.path.name})
        return self.request("POST", f"{self.upload_url}/repos/{self.repo}/releases/{release_id}/assets?{query}", file=asset.path)

    def rename(self, asset_id: int, name: str) -> dict:
        return self.request(
            "PATCH",
            f"{self.api_url}/repos/{self.repo}/releases/assets/{asset_id}",
            body=json.dumps({"name": name}).encode(),
        )

    def asset_digest(self, remote: dict) -> str:
        """Hash an asset when GitHub's nullable API digest is absent."""
        url = remote.get("browser_download_url") or remote.get("url")
        if not isinstance(url, str) or not url.startswith("https://"):
            raise RequestError("release asset has no safe download URL")
        request = urllib.request.Request(
            url,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Accept": "application/octet-stream",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        digest = hashlib.sha256()
        size = 0
        try:
            with urllib.request.urlopen(request, timeout=600) as response:
                for chunk in iter(lambda: response.read(1024 * 1024), b""):
                    size += len(chunk)
                    digest.update(chunk)
        except (OSError, urllib.error.URLError) as error:
            raise RequestError(f"could not hash release asset {remote.get('name')}: {error}") from error
        if remote.get("size") is not None and int(remote["size"]) != size:
            raise RequestError(f"release asset size changed while hashing: {remote.get('name')}")
        return "sha256:" + digest.hexdigest()


def _asset_matches(client: GitHub, asset: Asset, remote: dict | None) -> bool:
    return _remote_matches(client, remote, name=asset.path.name, size=asset.size, digest=asset.digest)


def _remote_matches(client: GitHub, remote: dict | None, *, name: str, size: int, digest: str) -> bool:
    if not (remote and remote.get("name") == name and remote.get("state") == "uploaded"
            and remote.get("size") == size):
        return False
    return (remote.get("digest") or client.asset_digest(remote)) == digest


def _rename_verified(client: GitHub, release_id: int, remote: dict, name: str,
                     *, size: int, digest: str) -> dict:
    """PATCH an asset name and reconcile a response lost after GitHub committed."""
    try:
        renamed = client.rename(int(remote["id"]), name)
    except RequestError:
        renamed = client.assets(release_id).get(name)
        if not _remote_matches(client, renamed, name=name, size=size, digest=digest):
            raise
        print(f"Verified rename of {name} after ambiguous response", flush=True)
        return renamed
    if not _remote_matches(client, renamed, name=name, size=size, digest=digest):
        renamed = client.assets(release_id).get(name)
        if not _remote_matches(client, renamed, name=name, size=size, digest=digest):
            raise RuntimeError(f"Rename verification failed: {name}")
    return renamed


def _upload_verified(client: GitHub, release_id: int, asset: Asset, existing: dict | None) -> dict:
    """Upload an asset under its final name, repairing only an incomplete starter."""
    name = asset.path.name
    for attempt in range(3):
        if existing and _asset_matches(client, asset, existing):
            print(f"Verified {name} ({asset.size} bytes), reusing", flush=True)
            return existing
        if existing:
            # A failed POST can leave an empty starter under the reserved name.
            # Completed immutable files must never be silently overwritten.
            if existing.get("state") != "starter":
                raise RuntimeError(f"Refusing to replace immutable asset with different or unverified bytes: {name}")
            client.delete(int(existing["id"]))
        print(f"Uploading {name} ({asset.size} bytes), attempt {attempt + 1}/3", flush=True)
        try:
            uploaded = client.upload(release_id, asset)
        except RequestError as error:
            # 422 can mean a previously timed-out upload finished on GitHub.
            if not error.retryable and error.status != 422:
                raise
            existing = client.assets(release_id).get(name)
            if existing and _asset_matches(client, asset, existing):
                print(f"Verified {name} after ambiguous upload response", flush=True)
                return existing
            if attempt == 2:
                raise
            backoff(attempt)
            continue
        if not _asset_matches(client, asset, uploaded):
            raise RuntimeError(f"Upload verification failed (state/size/SHA-256): {name}")
        print(f"Verified {name}", flush=True)
        return uploaded
    raise RuntimeError(f"Upload did not complete: {name}")


def ensure_asset(client: GitHub, release_id: int, asset: Asset, existing: dict | None) -> None:
    name = asset.path.name
    if existing and _asset_matches(client, asset, existing):
        print(f"Verified {name} ({asset.size} bytes), reusing", flush=True)
        return
    if not asset.replace:
        _upload_verified(client, release_id, asset, existing)
        return

    # Upload replacements under a unique temporary name first. The temporary
    # name must exist both remotely and locally because curl streams the local
    # path; clean it up even when GitHub or the network fails.
    temporary_name = f"cmux-upload-{name}-{asset.digest[7:19]}"
    temporary_path = asset.path.with_name(temporary_name)
    shutil.copyfile(asset.path, temporary_path)
    try:
        temporary = replace(asset, path=temporary_path, replace=False)
        backup_name = f"cmux-backup-{name}"
        listing = client.assets(release_id)
        temp_existing = listing.get(temporary_name)
        if temp_existing and not _asset_matches(client, temporary, temp_existing):
            client.delete(int(temp_existing["id"]))
            temp_existing = None
        temp_remote = _upload_verified(client, release_id, temporary, temp_existing)

        listing = client.assets(release_id)
        current = listing.get(name)
        backup = listing.get(backup_name)
        if current and _asset_matches(client, asset, current):
            client.delete(int(temp_remote["id"]))
            if backup:
                client.delete(int(backup["id"]))
            return

        # Keep the old bytes under a deterministic backup name while the new
        # temp is renamed. If the second PATCH is ambiguous or fails, the
        # backup remains available for immediate restoration and next-run
        # reconciliation.
        if current and current.get("state") == "starter":
            client.delete(int(current["id"]))
            current = None
        if current:
            if backup:
                client.delete(int(backup["id"]))
                backup = None
            backup = _rename_verified(
                client, release_id, current, backup_name,
                size=int(current["size"]), digest=str(current["digest"]),
            )
        try:
            _rename_verified(client, release_id, temp_remote, name, size=asset.size, digest=asset.digest)
        except Exception:
            # The old public name is absent only after the backup rename
            # succeeded. Restore it before propagating the failure; if
            # restoration is ambiguous, _rename_verified leaves the backup for
            # the next run.
            if backup:
                _rename_verified(
                    client, release_id, backup, name,
                    size=int(backup["size"]), digest=str(backup["digest"]),
                )
            raise
        if backup:
            client.delete(int(backup["id"]))
        print(f"Verified replacement {name}", flush=True)
    finally:
        temporary_path.unlink(missing_ok=True)


def publish(client: GitHub, release_id: int, phases: list[list[Asset]]) -> None:
    # Do not schedule an alias or feed until the entire preceding phase passed.
    # Feed writes are serial so the legacy feed is changed last.
    for index, assets in enumerate(phases):
        if not assets:
            continue
        existing = client.assets(release_id)
        if index == 2:
            for asset in assets:
                ensure_asset(client, release_id, asset, existing.get(asset.path.name))
            continue
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(ensure_asset, client, release_id, asset, existing.get(asset.path.name)) for asset in assets]
            for future in futures:
                future.result()


def plan(immutable: list[str], optional: list[str], aliases: list[str], feeds: list[str],
         *, replace_feeds: bool = False) -> list[list[Asset]]:
    phases: list[list[Asset]] = [[], [], []]
    names = set()
    for patterns, phase, replace, required in ((immutable, 0, False, True), (optional, 0, False, False),
                                               (aliases, 1, True, True), (feeds, 2, replace_feeds, True)):
        for pattern in patterns:
            paths = sorted(Path(path) for path in glob.glob(pattern))
            if not paths and required:
                raise ValueError(f"No files matched required release asset: {pattern}")
            for path in paths:
                if path.name in names:
                    raise ValueError(f"Duplicate release asset name: {path.name}")
                names.add(path.name)
                phases[phase].append(Asset.read(path, replace=replace))
    if not phases[0]:
        raise ValueError("At least one immutable release asset is required")
    return phases


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    release = parser.add_mutually_exclusive_group(required=True)
    release.add_argument("--tag")
    release.add_argument("--release-id", type=int)
    parser.add_argument("--immutable", action="append", default=[])
    parser.add_argument("--optional-immutable", action="append", default=[])
    parser.add_argument("--alias", action="append", default=[])
    parser.add_argument("--feed", action="append", default=[])
    parser.add_argument("--replace-feeds", action="store_true")
    args = parser.parse_args()
    # Hash and validate every local file before any remote mutation.
    phases = plan(args.immutable, args.optional_immutable, args.alias, args.feed, replace_feeds=args.replace_feeds)
    client = GitHub(args.repo, os.environ.get("GH_TOKEN", ""))
    release_id = args.release_id if args.release_id is not None else client.release_id(args.tag)
    publish(client, release_id, phases)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, ValueError, OSError) as error:
        print(f"Release publication failed: {error}", file=sys.stderr)
        sys.exit(1)
