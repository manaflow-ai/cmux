#!/usr/bin/env python3
"""A GitHub API read that outlasts a passing refusal: deadline_http.request, asked again on a refusal that
can change.

A CI script that reads GitHub once turns one passing refusal into a red job that passes on rerun (a false
red). On 2026-11-26 21:44Z cmux run 45900200033's private-names check read a PR, every token answered 403,
and the job failed; its rerun was green (cmuxterm-hq#30529 fixed that reader, hq#30294 step_times.py's).
This is the same policy for every reader under scripts/ci, in one place:

- asked again: 429, a 403 on a rate limit (x-ratelimit-remaining 0, a Retry-After, or a body naming a
  rate limit), 500/502/503/504, a timeout and a network error;
- answered at once: 401, 404, any other 4xx, and a 403 that names a permission, since asking again cannot
  change them;
- each wait honors Retry-After, else x-ratelimit-reset, else 5, 15, 30 s; never over MAX_WAIT_S;
- at most TRIES calls and BUDGET_S seconds in all: a wait that would pass the budget is not taken, and the
  last answer (or error) is the caller's.

A write (POST, PATCH, PUT, DELETE) is never asked again: the first may have landed (deadline_http's rule).
A refused write comes back as its answer. This is a bounded retry of one call, not a polling loop: it waits
only after a refusal and gives up within BUDGET_S (github_token_polling.py's rule is about loops that read
on every pass).
"""

from __future__ import annotations

import io
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
import deadline_http  # noqa: E402

TRIES = 4
BUDGET_S = 110.0
MAX_WAIT_S = 60.0
BACKOFF_S = (5.0, 15.0, 30.0)
CALL_S = 30.0
RETRY_STATUSES = frozenset({429, 500, 502, 503, 504})
READS = frozenset({"GET", "HEAD"})


def refusal_wait(status: int, headers, body: bytes, attempt: int, now: float) -> float | None:
    """How long to wait before asking again after answer STATUS, or None when asking again cannot change
    it (a success, 401, 404, a permission 403, any other 4xx)."""
    headers = headers or {}
    if status == 403:
        lowered = body.lower()
        limited = (headers.get("x-ratelimit-remaining") == "0" or headers.get("retry-after")
                   or b"rate limit" in lowered or b"abuse" in lowered)
        if not limited:
            return None
    elif status not in RETRY_STATUSES:
        return None
    retry_after = str(headers.get("retry-after") or "").strip()
    if retry_after.isdigit():
        return min(MAX_WAIT_S, max(1.0, float(retry_after)))
    reset = str(headers.get("x-ratelimit-reset") or "").strip()
    if headers.get("x-ratelimit-remaining") == "0" and reset.isdigit():
        return min(MAX_WAIT_S, max(1.0, int(reset) - now + 1))
    return BACKOFF_S[min(attempt, len(BACKOFF_S) - 1)]


def request(req: urllib.request.Request | str, seconds: float = CALL_S, *, raise_errors: bool = False,
            follow_redirects: bool = True, max_bytes: int | None = None, tries: int = TRIES,
            budget_s: float = BUDGET_S, sleep: Callable[[float], None] = time.sleep,
            clock: Callable[[], float] = time.monotonic, now: Callable[[], float] = time.time,
            log: Callable[[str], None] | None = None) -> tuple[int, bytes, deadline_http.Headers]:
    """deadline_http.request(REQ, SECONDS, ...), asked again on a refusal that can change (module doc).
    Returns the last answer; with raise_errors a final HTTP error status raises urllib's HTTPError. A
    timeout or network error that outlasts the tries is raised."""
    if isinstance(req, str):
        req = urllib.request.Request(req)
    method = req.get_method()
    tries = tries if method in READS else 1
    log = log or (lambda line: print(line, file=sys.stderr))
    start = clock()
    for attempt in range(tries):
        left = budget_s - (clock() - start)
        call_s = max(1.0, min(seconds, left)) if attempt else seconds
        error: BaseException | None = None
        try:
            status, body, headers = deadline_http.request(req, call_s, follow_redirects=follow_redirects,
                                                          max_bytes=max_bytes)
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as caught:
            if isinstance(caught, urllib.error.HTTPError):
                raise
            error, status, body, headers = caught, 0, b"", deadline_http.Headers({})
            wait = BACKOFF_S[min(attempt, len(BACKOFF_S) - 1)]
        else:
            wait = refusal_wait(status, headers, body, attempt, now())
            if wait is None:
                break
        last = attempt + 1 >= tries
        if not last and clock() - start + wait > budget_s:
            last = True
        what = f"{method} {req.full_url}: " + (f"{type(error).__name__}: {error}" if error else f"HTTP {status}")
        if last:
            if error is not None:
                raise error
            log(f"gh_http: {what}; gave up after {attempt + 1} tries")
            break
        log(f"gh_http: {what}; asking again in {wait:.0f} s (try {attempt + 2} of {tries})")
        sleep(wait)
    if raise_errors and status >= 400:
        raise urllib.error.HTTPError(req.full_url, status, "", headers, io.BytesIO(body))
    return status, body, headers
