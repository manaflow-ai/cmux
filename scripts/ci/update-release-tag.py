#!/usr/bin/env python3
"""Move a channel completion tag through GitHub's refs API and verify it.

Retries are limited to bounded transient HTTP and network failures. Permission
errors are reported immediately because replaying an unauthorized ref write
cannot make it valid. The operation is safe to retry because every request
targets the same exact commit and the final read-back is the completion check.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from urllib.parse import quote


class TagUpdateError(RuntimeError):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.message = message


def _setting(name: str, default: float, *, integer: bool = False) -> float:
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        value = int(raw) if integer else float(raw)
    except ValueError:
        return default
    return value if value >= 0 else default


def _retryable(status: int) -> bool:
    return status in {408, 425, 429} or status >= 500


def _api_url(path: str) -> str:
    base = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    return f"{base}/{path.lstrip('/')}"


def api_request(method: str, path: str, *, payload: dict | None = None) -> dict:
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        raise TagUpdateError(0, "GH_TOKEN or GITHUB_TOKEN is required")
    body = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(
        _api_url(path),
        data=body,
        method=method,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "cmux-nightly-tag-finalizer",
            "X-GitHub-Api-Version": "2022-11-28",
            "Content-Type": "application/json",
        },
    )
    attempts = max(int(_setting("CMUX_NIGHTLY_TAG_API_MAX_ATTEMPTS", 4, integer=True)), 1)
    delay = _setting("CMUX_NIGHTLY_TAG_API_RETRY_DELAY_SECONDS", 2.0)
    for attempt in range(attempts):
        try:
            # Without a timeout a stalled connection blocks until the job
            # ceiling and the retry loop never runs; TimeoutError is an OSError.
            with urllib.request.urlopen(request, timeout=30) as response:
                raw = response.read()
            return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            # A stalled or proxied failure can arrive without a body.
            message = (error.fp.read() if error.fp else b"").decode("utf-8", errors="replace")
            if not _retryable(error.code) or attempt + 1 == attempts:
                raise TagUpdateError(error.code, message) from error
        except (OSError, urllib.error.URLError) as error:
            if attempt + 1 == attempts:
                raise TagUpdateError(0, str(error)) from error
        time.sleep(min(delay * (2 ** attempt), 30.0))
    raise AssertionError("unreachable")


def _ref_sha(repo: str, ref: dict) -> str:
    obj = ref.get("object") or {}
    if obj.get("type") == "commit":
        return str(obj.get("sha", ""))
    if obj.get("type") == "tag":
        tag = api_request(
            "GET", f"repos/{repo}/git/tags/{quote(str(obj.get('sha', '')), safe='')}"
        )
        return str((tag.get("object") or {}).get("sha", ""))
    return ""


def update_tag(repo: str, tag: str, sha: str, *, allow_non_descendant: bool = False) -> None:
    if not repo or "/" not in repo:
        raise TagUpdateError(0, "repo must be owner/name")
    if not tag or "/" in tag:
        raise TagUpdateError(0, "tag must be a non-empty simple ref name")
    if len(sha) != 40 or any(char not in "0123456789abcdef" for char in sha.lower()):
        raise TagUpdateError(0, "sha must be a 40-character hexadecimal commit")
    ref_path = f"repos/{repo}/git/refs/tags/{quote(tag, safe='')}"
    try:
        current_ref = api_request("GET", ref_path)
    except TagUpdateError as error:
        if error.status != 404:
            raise
        try:
            api_request(
                "POST", f"repos/{repo}/git/refs", payload={"ref": f"refs/tags/{tag}", "sha": sha}
            )
        except TagUpdateError as create_error:
            # 422 means the ref already exists: a retried create whose first
            # response was lost, or a concurrent run. The read-back decides.
            if create_error.status != 422:
                raise
    else:
        current_sha = _ref_sha(repo, current_ref)
        if current_sha == sha:
            print(f"Verified {tag} -> {sha}", flush=True)
            return
        if current_sha and not allow_non_descendant:
            comparison = api_request(
                "GET", f"repos/{repo}/compare/{current_sha}...{sha}"
            )
            if comparison.get("status") != "ahead":
                raise TagUpdateError(
                    0,
                    f"refusing to move {tag!r} from {current_sha} to non-descendant {sha}",
                )
        # Without force GitHub enforces the fast-forward in the same request,
        # so a concurrent move between the compare and here cannot regress it.
        api_request("PATCH", ref_path, payload={"sha": sha, "force": allow_non_descendant})

    observed = _ref_sha(repo, api_request("GET", ref_path))
    if observed != sha:
        raise TagUpdateError(0, f"tag {tag!r} points to {observed or 'an unknown object'}, expected {sha}")
    print(f"Verified {tag} -> {sha}", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument(
        "--allow-non-descendant",
        action="store_true",
        help="force-move a tag shared by divergent branches (the rc channel)",
    )
    args = parser.parse_args()
    try:
        update_tag(args.repo, args.tag, args.sha, allow_non_descendant=args.allow_non_descendant)
    except TagUpdateError as error:
        status = f" (HTTP {error.status})" if error.status else ""
        print(f"Nightly tag update failed{status}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
