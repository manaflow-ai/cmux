#!/usr/bin/env python3
"""GitHub's REST API with a token that may wait out a spent rate limit, for the base tier kick only.

cmux_next_base_tier.py kick builds QuotaGitHub with cmux-next-base-tier-kick.yml's own cmux-bot App
token, which has its own budget (never github.token: a loop that sleeps and calls the API with the
shared GITHUB_TOKEN budget is what tests/test_ci_no_github_token_polling.py refuses). It lives in its
own file because the polling detector reads a whole script: cmux_next_base_tier.py's `defer` (run by
cmux-next.yml's path routing) never calls the API, and must not read as polling. tree notify's own
client (cmux_next_tree_notify.GitHub) never sleeps.
"""

from __future__ import annotations

import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cmux_next_tree_notify import GitHub  # noqa: E402


class QuotaExhausted(RuntimeError):
    """GitHub refused a call on a spent rate limit and it does not reset within the caller's deadline.
    Its message is one line naming the limit and when it resets."""


# Waits before a retry after a secondary rate limit (a 403/429 that names no reset), in order.
SECONDARY_BACKOFF_S = (30, 60, 120)
NO_RETRY = float("inf")


def utc(at: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(at))


def quota_wait(status: int, headers: dict[str, str], payload: bytes, attempt: int,
               now: float) -> tuple[float, str] | None:
    """A refusal on a spent rate limit: how long until a retry may pass (NO_RETRY: give up) and one line
    naming the limit and when it lifts. None when the refusal is not a rate limit (a permission
    refusal, "This workflow is already running")."""
    if status not in (403, 429):
        return None
    reset = headers.get("x-ratelimit-reset") or ""
    if headers.get("x-ratelimit-remaining") == "0" and reset.isdigit():
        resource = headers.get("x-ratelimit-resource") or "core"
        return (max(1.0, int(reset) - now + 1),
                f"the token's {resource} REST quota is spent; "
                f"it resets at {utc(int(reset))}")
    retry_after = headers.get("retry-after") or ""
    if retry_after.isdigit():
        return max(1.0, float(retry_after)), f"GitHub's secondary rate limit; retry after {retry_after} s"
    if b"rate limit" in payload.lower():
        if attempt >= len(SECONDARY_BACKOFF_S):
            return NO_RETRY, f"GitHub's secondary rate limit, still on after {attempt} backoffs"
        wait = SECONDARY_BACKOFF_S[attempt]
        return float(wait), f"GitHub's secondary rate limit; next try in {wait} s"
    return None


class QuotaGitHub(GitHub):
    """tree notify's client, for this kick only (tree notify's own client never sleeps). Its token is
    the kick's cmux-bot App token, whose budget other cmux-bot jobs share and can spend under a job
    that makes a handful of calls. With DEADLINE (an epoch time), a read (GET) refused on a spent rate
    limit (a 403 or 429 with x-ratelimit-remaining 0, a retry-after, or a body that says "rate limit")
    is retried after one sleep until the limit lifts, while that fits DEADLINE; past it,
    QuotaExhausted. A write (POST, PATCH, DELETE: a cancel, a dispatch) refused on a rate limit raises
    QuotaExhausted at once and is never retried after a sleep: what made it right (a run whose Mac job
    had not started) may not hold minutes later, so a caller that wants a retry reads its precondition
    again and calls again. With no DEADLINE nothing is retried and a refusal reads as tree notify's
    client reads it: get() raises RuntimeError, post() and delete() return the status."""

    def __init__(self, token: str, api_url: str = "https://api.github.com", *, deadline: float | None = None,
                 now: Callable[[], float] = time.time, sleep: Callable[[float], None] = time.sleep):
        super().__init__(token, api_url)
        self.deadline = deadline
        self.now = now
        self.sleep = sleep

    def _send(self, method: str, url: str, body: dict | None = None) -> tuple[int, bytes, dict[str, str]]:
        """One call, with its response headers (the rate limit's reset is in them)."""
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, method=method, headers={
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        })
        # Unredirected, as in tree notify's client: a redirect must not receive the token.
        request.add_unredirected_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.status, response.read(), {k.lower(): v for k, v in (response.headers or {}).items()}
        except urllib.error.HTTPError as error:
            return error.code, error.read(), {k.lower(): v for k, v in (error.headers or {}).items()}

    def _request(self, method: str, url: str, body: dict | None = None):
        attempt = 0
        while True:
            status, payload, headers = self._send(method, url, body)
            limited = None if self.deadline is None else quota_wait(status, headers, payload, attempt, self.now())
            if limited is None:
                return status, payload
            wait, why = limited
            where = f"{method} {url.removeprefix(self.api_url + '/')}: HTTP {status}: {why}"
            if method != "GET":
                raise QuotaExhausted(f"{where}; a write is not retried after a wait")
            if self.now() + wait > self.deadline:
                raise QuotaExhausted(f"{where}, past this job's budget ({utc(self.deadline)})")
            # One sleep until the limit lifts, never a polling loop.
            self.sleep(wait)
            attempt += 1
