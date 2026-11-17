#!/usr/bin/env python3
"""Resumable GitHub release uploads: immutable files, aliases, then feeds.

GitHub can accept an upload before its response times out, or leave a `starter`
asset after a 502. Reconcile the server's size, state and SHA-256 before retrying.
The workflows serialize writers to each release; this is not a distributed lock.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass, replace
import glob
import hashlib
import json
import math
import mimetypes
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from urllib.parse import quote, urlencode, urlsplit


# A rate-limited 403/429 (GitHub rejects it before processing) is retried
# until the limit resets, but one process waits at most this long in total:
# the publish job has its own timeout (2026-10-24: the Actions installation
# quota ran out and the nightly failed on "POST HTTP 403" with nothing retried).
# CMUX_RELEASE_RATE_LIMIT_SECONDS raises it where the job's timeout leaves room.
RATE_LIMIT_BUDGET_SECONDS = int(os.environ.get("CMUX_RELEASE_RATE_LIMIT_SECONDS") or 600)
# A refusal with no reset to wait for (no retry-after, no x-ratelimit-reset) is GitHub's
# secondary limit on bursts of writes (2026-10-26: 18 upload POSTs refused "API rate limit
# exceeded for installation" with no x-ratelimit headers while core had 4899 of 5000 left).
# It backs off 60, 120, 240 s, then 300 s per wait, within the budget.
SECONDARY_FIRST_WAIT_SECONDS = 60.0
SECONDARY_MAX_WAIT_SECONDS = 300.0
# Writes (uploads, deletes, renames) are made one at a time with this pause between them,
# so a publish never bursts into the secondary limit itself.
WRITE_PAUSE_SECONDS = 1.0
_sleep = time.sleep  # tests replace this, never the shared time module
_pause = time.sleep  # the pause between writes, kept apart from the rate-limit waits
_rate_limit_lock = threading.Lock()
_rate_limit_deadline: float | None = None
_secondary_waits = 0
# One job waits at most GH_BUDGET_WAIT_MAX_SECONDS (an hour) for rate limits in all: the
# publisher and scripts/ci/gh_budget_wait.sh share this ledger of seconds already waited,
# so the steps of one job never add up to more than the job's timeout leaves room for.
_LEDGER = Path(os.environ.get("RUNNER_TEMP") or tempfile.gettempdir()) / "gh-budget-wait" / "waited"
_waited_here = 0.0  # this process's own waits: the cap holds even if the ledger cannot be written
_ledger_at_start: float | None = None  # the ledger when this process first waited


def _job_cap() -> float:
    return float(os.environ.get("GH_BUDGET_WAIT_MAX_SECONDS") or 3600)


def _ledger_spent() -> float:
    """The job's waits so far. No ledger yet is none; one that exists but cannot be read or
    parsed counts as the whole hour spent (fail closed: an earlier step's waits are unknown)."""
    try:
        text = _LEDGER.read_text().strip()
    except FileNotFoundError:
        return 0.0
    except (OSError, UnicodeDecodeError):
        return _job_cap()
    # Only a whole number of seconds is a ledger (both writers write one); anything else, an empty
    # file from an interrupted write included, is unknown and so the whole hour.
    return float(text) if text.isdigit() and text.isascii() else _job_cap()


def _job_spent() -> float:
    """What this job has waited: the ledger, or what it held when this process started waiting plus
    this process's own waits, whichever is more (so a ledger that stops being writable never
    lowers the count). Call with _rate_limit_lock held."""
    global _ledger_at_start
    ledger = _ledger_spent()
    if _ledger_at_start is None:
        _ledger_at_start = ledger
    return max(ledger, _ledger_at_start + _waited_here)


def _job_wait_left() -> float:
    """Seconds this job may still wait; call with _rate_limit_lock held."""
    return _job_cap() - _job_spent()


def _record_job_wait(seconds: float) -> bool:
    """Add a wait to the job's ledger; call with _rate_limit_lock held (one writer at a time).
    False when it could not be recorded: the caller must not wait (later steps could not see it)."""
    global _waited_here
    total = _job_spent() + seconds
    try:
        _LEDGER.parent.mkdir(parents=True, exist_ok=True)
        # Written whole and renamed into place, so a reader never sees a partial file.
        partial = _LEDGER.with_name(f"{_LEDGER.name}.{os.getpid()}")
        partial.write_text(str(math.ceil(total)))  # round up: never under-count
        partial.replace(_LEDGER)
    except OSError as error:
        print(f"could not record the rate-limit wait in {_LEDGER}: {error}", file=sys.stderr, flush=True)
        return False
    _waited_here += seconds
    return True
_write_lock = threading.Lock()
_last_write: float | None = None


class RequestError(RuntimeError):
    def __init__(self, message: str, *, status: int = 0, rate_limited: bool = False,
                 wait: float | None = None):
        super().__init__(message)
        self.status = status
        self.rate_limited = rate_limited
        self.wait = wait

    @property
    def retryable(self) -> bool:
        return self.status in (0, 408, 429) or self.status >= 500 or self.rate_limited


def rate_limit(status: int, headers: dict[str, str], body: str, now: float) -> tuple[bool, float | None]:
    """Whether a 403/429 is GitHub's rate limit, and how long until it resets.

    A permission 403 has none of retry-after, x-ratelimit-remaining: 0 or a
    "rate limit" message, and is not retried.
    """
    if status not in (403, 429):
        return False, None
    retry_after = headers.get("retry-after", "").strip()
    remaining = headers.get("x-ratelimit-remaining", "").strip()
    limited = bool(retry_after) or remaining == "0" or "rate limit" in body.lower()
    if not limited:
        return False, None
    if retry_after.isdigit():
        return True, float(retry_after)
    reset = headers.get("x-ratelimit-reset", "").strip()
    if reset.isdigit():
        return True, max(float(reset) - now, 0.0) + 1
    return True, None


def pause_between_writes() -> None:
    """At most one write starts per WRITE_PAUSE_SECONDS across this process's threads."""
    global _last_write
    with _write_lock:
        now = time.monotonic()
        if _last_write is not None and now - _last_write < WRITE_PAUSE_SECONDS:
            _pause(WRITE_PAUSE_SECONDS - (now - _last_write))
        _last_write = time.monotonic()


def parse_headers(text: str) -> dict[str, str]:
    """The last response's headers from curl --dump-header (lowercased names)."""
    blocks = [block for block in re.split(r"\r?\n\r?\n", text) if block.strip()]
    headers = {}
    for line in (blocks[-1].splitlines()[1:] if blocks else []):
        name, sep, value = line.partition(":")
        if sep:
            headers[name.strip().lower()] = value.strip()
    return headers


def backoff(attempt: int, error: RequestError | None = None) -> None:
    if error is None or not error.rate_limited:
        _sleep(2 ** (attempt + 1))
        return
    global _rate_limit_deadline, _secondary_waits
    with _rate_limit_lock:
        now = time.monotonic()
        if _rate_limit_deadline is None:
            _rate_limit_deadline = now + RATE_LIMIT_BUDGET_SECONDS
        left = min(_rate_limit_deadline - now, _job_wait_left())
        if error.wait is None:
            wanted = min(SECONDARY_FIRST_WAIT_SECONDS * 2 ** _secondary_waits, SECONDARY_MAX_WAIT_SECONDS)
            _secondary_waits += 1
        else:
            wanted = error.wait
        wait = min(max(wanted, 1.0), left)
        # Reserve the wait before sleeping, under the lock, so concurrent waits never overrun the cap.
        if left >= 1 and not _record_job_wait(wait):
            left = 0  # an unrecorded wait could push the job's steps past its cap: fail instead
    if left < 1:
        raise RuntimeError(f"GitHub rate limit did not reset within {RATE_LIMIT_BUDGET_SECONDS} s: {error}") from error
    print(f"GitHub rate limit ({error}); waiting {wait:.0f} s", file=sys.stderr, flush=True)
    _sleep(wait)


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


class _SameHostAuthRedirect(urllib.request.HTTPRedirectHandler):
    """Follow a redirect, but send the token only to the host it was meant for: the asset API
    redirects to a storage host that must not see it."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None and urlsplit(newurl).hostname != urlsplit(req.full_url).hostname:
            new.remove_header("Authorization")
        return new


_OPENER = urllib.request.build_opener(_SameHostAuthRedirect)


def client_from_env(repo: str) -> "GitHub":
    """GH_APP_TOKEN (the release App, a separate actor) first when the job minted one, GH_TOKEN
    (github.token) as its fallback."""
    app, token = os.environ.get("GH_APP_TOKEN", ""), os.environ.get("GH_TOKEN", "")
    return GitHub(repo, app or token, fallback=token if app else "")


class GitHub:
    def __init__(self, repo: str, token: str, *, api_url: str = "https://api.github.com",
                 upload_url: str = "https://uploads.github.com", fallback: str = ""):
        if not re.fullmatch(r"[\w.-]+/[\w.-]+", repo):
            raise ValueError("Expected --repo owner/name")
        if not token or any(char in token for char in '\r\n"\\'):
            raise ValueError("GH_TOKEN must contain a valid token")
        if any(char in fallback for char in '\r\n"\\'):
            raise ValueError("GH_TOKEN must be a valid token")
        self.repo, self.token = repo, token
        # With a fallback, token is the release App's: a refusal of it (401, 403, 429) switches
        # to the fallback (github.token) for the rest of the run.
        self.fallback = fallback if fallback != token else ""
        self._token_lock = threading.Lock()  # upload workers share this client
        self.api_url, self.upload_url = api_url, upload_url

    def request(self, method: str, url: str, *, file: Path | None = None,
                body: bytes | None = None, content_type: str | None = None):
        """curl streams large files and bounds both stalled and total transfer time.

        Pass credentials on stdin, never argv, and do not follow redirects.
        JSON reads/deletes can retry directly; uploads reconcile in ensure_asset.
        """
        if file is not None and body is not None:
            raise ValueError("file and body are mutually exclusive")
        # A POST or PATCH is retried here only when rate-limited: GitHub
        # rejected it unprocessed. Uploads reconcile in _upload_verified.
        single = bool(file) or method in {"POST", "PATCH"}
        attempts = 3
        attempt = 0
        switched = False
        while True:
            used = self.token
            try:
                return self._request(method, url, file=file, body=body, content_type=content_type)
            except RequestError as error:
                # A refused request did nothing on GitHub's side, so it is safe to send again.
                if not switched and self._fall_back(used, error.status, error):
                    switched = True
                    continue
                # A rate-limited refusal is retried until the budget runs out (backoff raises then);
                # it does not use up one of the attempts.
                if error.rate_limited:
                    backoff(attempt, error)
                    continue
                if single or not error.retryable or attempt + 1 == attempts:
                    raise
                backoff(attempt, error)
                attempt += 1

    def _fall_back(self, used: str, status: int, error: Exception) -> bool:
        """After `used` was refused: whether to send the call again (now with the fallback)."""
        if status not in (401, 403, 429):
            return False  # only a refusal of the token is sent again
        with self._token_lock:
            if self.token != used:
                return True  # another worker already switched to the fallback
            if not self.fallback:
                return False
            print(f"GitHub refused the release App token ({error}); using github.token from here on",
                  file=sys.stderr, flush=True)
            self.token, self.fallback = self.fallback, ""
            return True

    def _request(self, method: str, url: str, *, file: Path | None = None,
                 body: bytes | None = None, content_type: str | None = None):
        timeout = 600 if file else 60
        content_type = content_type or ((mimetypes.guess_type(file.name)[0] or "application/octet-stream") if file else "application/json")
        config = (f'header = "Authorization: Bearer {self.token}"\n'
                  'header = "Accept: application/vnd.github+json"\n'
                  'header = "X-GitHub-Api-Version: 2022-11-28"\n')
        if method != "GET":
            pause_between_writes()
        with tempfile.TemporaryDirectory(prefix="cmux-release-upload-") as directory:
            output = Path(directory) / "response.json"
            header_path = Path(directory) / "headers.txt"
            body_path = None
            if body is not None:
                body_path = Path(directory) / "request-body"
                body_path.write_bytes(body)
            command = ["curl", "--disable", "--config", "-", "--silent", "--show-error",
                       "--request", method, "--connect-timeout", "30", "--max-time", str(timeout),
                       "--speed-limit", "1024", "--speed-time", "60", "--retry", "0",
                       "--header", f"Content-Type: {content_type}", "--output", str(output),
                       "--dump-header", str(header_path),
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
                raise self._http_error(method, status, output, header_path)
            body = output.read_text()
            if not body:
                return None
            try:
                return json.loads(body)
            except json.JSONDecodeError as error:
                raise RequestError(f"{method} returned invalid JSON") from error

    def _http_error(self, method: str, status: int, output: Path, header_path: Path) -> RequestError:
        """GitHub's own message and rate-limit headers, so a red names its cause."""
        body = output.read_text(errors="replace") if output.exists() else ""
        headers = parse_headers(header_path.read_text(errors="replace")) if header_path.exists() else {}
        limited, wait = rate_limit(status, headers, body, time.time())
        try:
            message = str(json.loads(body).get("message", "")) if body else ""
        except (json.JSONDecodeError, AttributeError):
            message = ""
        detail = (message or " ".join(body.split()))[:300].replace(self.token, "***")
        shown = ", ".join(f"{name}={headers[name]}" for name in
                          ("retry-after", "x-ratelimit-limit", "x-ratelimit-remaining", "x-ratelimit-reset",
                           "x-ratelimit-resource", "x-github-request-id") if name in headers)
        text = f"{method} HTTP {status}"
        if detail:
            text += f": {detail}"
        if shown:
            text += f" ({shown})"
        if limited and not getattr(self, "_snapshotting", False):
            # Which limit refused it: every response header (GitHub sends no secrets in them) and
            # the token's /rate_limit (free), so a red names the resource and its numbers.
            every = "; ".join(f"{name}={value}" for name, value in sorted(headers.items())).replace(self.token, "***")
            print(f"Rate-limited {method} response headers: {every or 'none'}", file=sys.stderr, flush=True)
            print(f"/rate_limit at the refusal: {self.rate_limit_snapshot()}", file=sys.stderr, flush=True)
        return RequestError(text, status=status, rate_limited=limited, wait=wait)

    def rate_limit_snapshot(self) -> str:
        """This token's /rate_limit, one line; never raises (it costs no budget)."""
        self._snapshotting = True
        try:
            data = self._request("GET", f"{self.api_url}/rate_limit")
            resources = (data or {}).get("resources") or {}
            return ", ".join(f"{name} {value.get('remaining')}/{value.get('limit')} reset {value.get('reset')}"
                             for name, value in sorted(resources.items()) if isinstance(value, dict)) or "empty"
        except Exception as error:  # noqa: BLE001 - diagnostics only
            return f"unreadable ({str(error)[:120]})"
        finally:
            self._snapshotting = False

    def release_id(self, tag: str) -> int:
        url = f"{self.api_url}/repos/{self.repo}/releases/tags/{quote(tag, safe='')}"
        try:
            ids = {int(self.request("GET", url)["id"])}
        except RequestError as error:
            if error.status != 404:
                raise
            ids = set()
        # The tags endpoint 404s for drafts, so list every release for the tag.
        # Exactly one release object may exist: with two, the assets and the
        # release that gets published can differ (v0.65.2 shipped with 0
        # assets that way), so refuse before uploading anything.
        ids.update(int(release["id"]) for release in self.releases() if release.get("tag_name") == tag)
        if len(ids) > 1:
            raise RuntimeError(
                f"Refusing to upload: {len(ids)} releases exist for {tag} "
                f"(ids {', '.join(map(str, sorted(ids)))}). Delete the extra drafts, then rerun."
            )
        if ids:
            return ids.pop()
        release = self.request(
            "POST",
            f"{self.api_url}/repos/{self.repo}/releases",
            body=json.dumps({"tag_name": tag, "name": tag, "draft": True, "prerelease": True}).encode(),
        )
        return int(release["id"])

    def releases(self) -> list[dict]:
        result = []
        page = 1
        while True:
            entries = self.request("GET", f"{self.api_url}/repos/{self.repo}/releases?per_page=100&page={page}")
            result.extend(entries)
            if len(entries) < 100:
                return result
            page += 1

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
        # Draft releases cannot serve browser_download_url; the authenticated
        # API asset endpoint works for both draft and published assets.
        url = remote.get("url") or remote.get("browser_download_url")
        if not isinstance(url, str) or not url.startswith("https://"):
            raise RequestError("release asset has no safe download URL")
        switched = False
        attempt = 0
        while True:
            used = self.token
            request = urllib.request.Request(
                url,
                headers={
                    "Authorization": f"Bearer {used}",
                    "Accept": "application/octet-stream",
                    "X-GitHub-Api-Version": "2022-11-28",
                },
            )
            digest = hashlib.sha256()
            size = 0
            try:
                with _OPENER.open(request, timeout=600) as response:
                    for chunk in iter(lambda: response.read(1024 * 1024), b""):
                        size += len(chunk)
                        digest.update(chunk)
                break
            except urllib.error.HTTPError as error:
                # A refused App token is sent once more with the fallback (github.token).
                if not switched and self._fall_back(used, error.code, error):
                    switched = True
                    continue
                # A rate-limited download backs off like any other request (until the budget ends).
                body = error.read().decode(errors="replace") if error.fp else ""
                headers = {name.lower(): value for name, value in (error.headers or {}).items()}
                limited, wait = rate_limit(error.code, headers, body, time.time())
                if not limited:
                    raise RequestError(f"could not hash release asset {remote.get('name')}: {error}",
                                       status=error.code) from error
                print(f"Rate-limited asset download response headers: "
                      f"{'; '.join(f'{k}={v}' for k, v in sorted(headers.items())) or 'none'}", file=sys.stderr, flush=True)
                backoff(attempt, RequestError(f"GET asset HTTP {error.code}", status=error.code,
                                              rate_limited=True, wait=wait))
                attempt += 1
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
            backoff(attempt, error)
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
        backup_digest = None
        if current and current.get("state") == "starter":
            client.delete(int(current["id"]))
            current = None
        if current:
            if backup:
                client.delete(int(backup["id"]))
                backup = None
            backup_digest = current.get("digest") or client.asset_digest(current)
            backup = _rename_verified(
                client, release_id, current, backup_name,
                size=int(current["size"]), digest=backup_digest,
            )
        elif backup:
            backup_digest = backup.get("digest") or client.asset_digest(backup)
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
                    size=int(backup["size"]), digest=backup_digest,
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
        # One at a time: parallel uploads from one token burst into GitHub's secondary limit.
        for asset in assets:
            ensure_asset(client, release_id, asset, existing.get(asset.path.name))


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
    parser.add_argument("--github-output", type=Path,
                        help="Append release_id, asset_count and asset_names for later workflow steps")
    args = parser.parse_args()
    # Hash and validate every local file before any remote mutation.
    phases = plan(args.immutable, args.optional_immutable, args.alias, args.feed, replace_feeds=args.replace_feeds)
    client = client_from_env(args.repo)
    release_id = args.release_id if args.release_id is not None else client.release_id(args.tag)
    publish(client, release_id, phases)
    if args.github_output:
        # Later steps publish and verify this exact release id, never a tag lookup.
        with args.github_output.open("a") as output:
            names = " ".join(asset.path.name for phase in phases for asset in phase)
            output.write(f"release_id={release_id}\nasset_count={sum(map(len, phases))}\nasset_names={names}\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, ValueError, OSError) as error:
        print(f"Release publication failed: {error}", file=sys.stderr)
        sys.exit(1)
