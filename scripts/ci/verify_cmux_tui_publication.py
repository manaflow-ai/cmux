#!/usr/bin/env python3
"""Verify that a cmux-tui commit and its tree metadata reached the CDN.

R2 writes are immutable, while files.cmux.com is eventually consistent.  The
artifact workflow must fail when a successful build did not publish what the
installer consumes, but it should allow a short, bounded propagation window.
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import sys
import time
from typing import Callable
from urllib.error import HTTPError, URLError
from urllib.request import Request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deadline_http  # noqa: E402


Fetch = Callable[[str], bytes]


def fetch_url(url: str) -> bytes:
    # deadline_http sends a User-Agent of its own: files.cmux.com answers urllib's default
    # "Python-urllib/3.x" with 403, so with it every read of this check failed, for a
    # published manifest too (4d01af5b, 2026-11-13).
    request = Request(url, headers={"Cache-Control": "no-cache"})
    _, body, _ = deadline_http.request(request, 15, raise_errors=True)
    return body


def _fetch_json(url: str, fetch: Fetch) -> dict:
    try:
        value = json.loads(fetch(url))
    except (HTTPError, URLError, TimeoutError, OSError, http.client.HTTPException, json.JSONDecodeError) as error:
        raise RuntimeError(f"could not read {url}: {error}") from error
    if not isinstance(value, dict):
        raise RuntimeError(f"{url} is not a JSON object")
    return value


def verify_publication(
    sha: str,
    tree_key: str,
    *,
    fetch: Fetch = fetch_url,
    attempts: int = 4,
    delay_seconds: float = 5.0,
) -> list[str]:
    """Return the verified URLs, retrying CDN reads a bounded number of times."""
    if attempts < 1:
        raise ValueError("attempts must be positive")
    if len(sha) != 40 or any(c not in "0123456789abcdef" for c in sha.lower()):
        raise ValueError("sha must be a 40-character commit")
    urls = [
        f"https://files.cmux.com/cmux-tui/{sha}/manifest.json",
        f"https://files.cmux.com/cmux-tui/tree/{tree_key}/source.json",
    ]
    verified: list[str] = []
    for url in urls:
        last_error: Exception | None = None
        for attempt in range(1, attempts + 1):
            try:
                document = _fetch_json(url, fetch)
                if url.endswith("/manifest.json"):
                    if document.get("commit") != sha or document.get("sourceCommit") != sha:
                        raise RuntimeError(
                            f"{url} commit mismatch: expected {sha}, "
                            f"got {document.get('commit')!r}/{document.get('sourceCommit')!r}"
                        )
                elif document.get("key") != tree_key:
                    raise RuntimeError(
                        f"{url} tree key mismatch: expected {tree_key}, got {document.get('key')!r}"
                    )
                verified.append(url)
                break
            except Exception as error:  # bounded retry is the CDN propagation contract
                last_error = error
                if attempt < attempts:
                    time.sleep(delay_seconds)
        else:
            raise RuntimeError(f"publication check failed after {attempts} attempts: {last_error}")
    return verified


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sha", required=True)
    parser.add_argument("--tree-key", required=True)
    parser.add_argument("--attempts", type=int, default=4)
    parser.add_argument("--delay-seconds", type=float, default=5.0)
    args = parser.parse_args()
    for url in verify_publication(
        args.sha,
        args.tree_key,
        attempts=args.attempts,
        delay_seconds=args.delay_seconds,
    ):
        print(f"verified {url}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
