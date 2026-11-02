"""Count the GitHub REST requests a CI picker makes, per token, and report them when the step exits.

The routing App's installation ran out of REST quota on 2026-11-01 (403 "API rate limit exceeded for installation
ID 164690637" in run 41344566214), and every picker that reads runners went blind at once. Nothing measured which
picker spends what. Each request made through pr_runner_pool.GitHub or next_macos_cascade.Api is recorded here, and
at exit the step's log gets one line per token: its request count, and the limit and remaining the last response
carried, so a run shows both a picker's spend and the installation's budget (5000 vs 12500) and headroom.

Tokens are never printed: each is named by a short hash. The report goes to stderr, because some pickers' stdout
is appended to $GITHUB_OUTPUT. It is skipped when no request was made.
"""
from __future__ import annotations

import atexit
import hashlib
import sys
from typing import Any, Mapping, TextIO

_spend: dict[str, dict[str, Any]] = {}


def token_id(authorization: str) -> str:
    token = authorization.split()[-1] if authorization else ""
    return hashlib.sha256(token.encode()).hexdigest()[:8] if token else "none"


def record(authorization: str, headers: Mapping[str, str] | None, status: int) -> None:
    """One request made with `authorization` (the request's Authorization header), answered with `status`.
    Never raises: a count must not fail the pick it measures."""
    try:
        _record(authorization, headers, status)
    except Exception:  # noqa: BLE001
        pass


def _record(authorization: str, headers: Mapping[str, str] | None, status: int) -> None:
    entry = _spend.setdefault(token_id(authorization), {"requests": 0, "refused": 0})
    entry["requests"] += 1
    if status in (403, 429):
        entry["refused"] += 1
    for header, key in (("X-RateLimit-Limit", "limit"), ("X-RateLimit-Remaining", "remaining"),
                        ("X-RateLimit-Resource", "resource")):
        value = headers.get(header) if hasattr(headers, "get") else None
        if value is not None:
            entry[key] = value


def spend() -> dict[str, dict[str, Any]]:
    return {name: dict(entry) for name, entry in _spend.items()}


def report(stream: TextIO | None = None) -> None:
    stream = stream or sys.stderr
    for name, entry in sorted(_spend.items()):
        print(f"GitHub API spend: token {name}: {entry['requests']} requests ({entry['refused']} refused); "
              f"{entry.get('resource', '?')} limit {entry.get('limit', '?')}, remaining {entry.get('remaining', '?')}",
              file=stream)


atexit.register(report)
