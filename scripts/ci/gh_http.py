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
- each wait honors Retry-After, else x-ratelimit-reset, else 5, 15, 30 s; never over MAX_WAIT_S, except a
  rate limit that NAMES its end (Retry-After, or x-ratelimit-remaining 0 with x-ratelimit-reset): that wait
  is taken to the end, up to RATE_MAX_WAIT_S, and any number of times inside rate_budget_s, which DEFAULTS to the caller's budget_s (BUDGET_S 110 s) so a job with a short
  timeout-minutes is never cancelled by a sleep; only a caller that opts in (rate_budget_s=RATE_BUDGET_S, 1200 s) waits
  longer (an installation
  limit lasts minutes; cmux run 46019347396 gave up after 2 tries and 60 s and went red). A caller with
  another token to try, or a job shorter than the wait, passes a smaller rate_budget_s: 0 gives up on a named
  limit at once, so the caller's next token reads it (cmux's `ios fast verdict status`, a 5-min job, slept 900 s
  on its run token's 403 and was cancelled at its timeout 23 times in 22:00-23:30Z 11-27, never trying the pool);
- a job's own bound caps every wait: GH_HTTP_DEADLINE_S, set in the env of every workflow job with a
  timeout-minutes that runs a reader (tests/test_ci_gh_http.py checks the workflows), is a budget no wait passes,
  so a 403 gives up loudly, naming when the limit ends, before GitHub cancels the job silently (cmux run
  46109204066: ios-fast-verdict-dispatch's 5-min resolve waited 405 s and was cancelled). It counts from the
  job's first reader: that process writes the epoch GH_HTTP_DEADLINE_AT to $GITHUB_ENV for the later steps;
- otherwise at most TRIES calls and BUDGET_S seconds in all: a wait that would pass the budget is not taken,
  and the last answer (or error) is the caller's. Giving up on a named rate limit logs
  "rate-limited until HH:MMZ" (limited_until) so the red names when to retry.

A write (POST, PATCH, PUT, DELETE) is never asked again: the first may have landed (deadline_http's rule).
A refused write comes back as its answer. This is a bounded retry of one call, not a polling loop: it waits
only after a refusal and gives up within BUDGET_S (github_token_polling.py's rule is about loops that read
on every pass).
"""

from __future__ import annotations

import io
import os
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
RATE_MAX_WAIT_S = 900.0
RATE_BUDGET_S = 1200.0
BACKOFF_S = (5.0, 15.0, 30.0)
CALL_S = 30.0
RETRY_STATUSES = frozenset({429, 500, 502, 503, 504})
READS = frozenset({"GET", "HEAD"})
DEADLINE_ENV = "GH_HTTP_DEADLINE_S"
DEADLINE_AT_ENV = "GH_HTTP_DEADLINE_AT"
STARTED = time.monotonic()


def _bound(env, name: str) -> float | None:
    try:
        return float(str(env.get(name) or "").strip())
    except ValueError:
        return None


def share_deadline(env=None, now: Callable[[], float] = time.time) -> None:
    """The first reader in a job turns GH_HTTP_DEADLINE_S into an epoch GH_HTTP_DEADLINE_AT for the job's later
    steps ($GITHUB_ENV), so a second script in the same job does not start the clock again."""
    env = os.environ if env is None else env
    bound, path = _bound(env, DEADLINE_ENV), env.get("GITHUB_ENV")
    if bound is None or _bound(env, DEADLINE_AT_ENV) is not None or not path:
        return
    at = f"{now() + bound:.0f}"
    try:
        with open(path, "a", encoding="utf-8") as out:
            out.write(f"{DEADLINE_AT_ENV}={at}\n")
    except OSError:
        return
    env[DEADLINE_AT_ENV] = at


def deadline_left(clock: Callable[[], float] = time.monotonic, now: Callable[[], float] = time.time,
                  env=None) -> float | None:
    """Seconds left before the job's bound, or None when no bound is set: GH_HTTP_DEADLINE_AT (epoch, written by
    the job's first reader) else GH_HTTP_DEADLINE_S from this process's start."""
    env = os.environ if env is None else env
    at = _bound(env, DEADLINE_AT_ENV)
    if at is not None:
        return max(0.0, at - now())
    bound = _bound(env, DEADLINE_ENV)
    if bound is None:
        return None
    return max(0.0, bound - (clock() - STARTED))


share_deadline()


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
    named = named_wait(headers, now)
    if named is not None:
        return min(RATE_MAX_WAIT_S, named)
    return BACKOFF_S[min(attempt, len(BACKOFF_S) - 1)]


def named_wait(headers, now: float) -> float | None:
    """Seconds until the rate limit HEADERS name as over (Retry-After, else x-ratelimit-reset when the quota
    is 0), or None when they name none."""
    headers = headers or {}
    retry_after = str(headers.get("retry-after") or "").strip()
    if retry_after.isdigit():
        return max(1.0, float(retry_after))
    reset = str(headers.get("x-ratelimit-reset") or "").strip()
    if headers.get("x-ratelimit-remaining") == "0" and reset.isdigit():
        return max(1.0, int(reset) - now + 1)
    return None


def limited_until(headers, now: float | None = None) -> str | None:
    """"HH:MMZ" when the rate limit in HEADERS ends, or None when they name none."""
    now = time.time() if now is None else now
    wait = named_wait(headers, now)
    return None if wait is None else time.strftime("%H:%MZ", time.gmtime(now + wait))


def request(req: urllib.request.Request | str, seconds: float = CALL_S, *, raise_errors: bool = False,
            follow_redirects: bool = True, max_bytes: int | None = None, tries: int = TRIES,
            budget_s: float = BUDGET_S, rate_budget_s: float | None = None, sleep: Callable[[float], None] = time.sleep,
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
    # A caller that does not opt in (rate_budget_s=RATE_BUDGET_S) never sleeps on a rate limit past its own
    # budget_s: Actions jobs have timeout-minutes of 5-15, and a 20 min default cancelled them.
    rate_budget_s = budget_s if rate_budget_s is None else rate_budget_s
    start = clock()
    job_left = deadline_left(clock, now)
    if job_left is not None:
        budget_s, rate_budget_s = min(budget_s, job_left), min(rate_budget_s, job_left)
    attempt = -1
    while True:
        attempt += 1
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
            if method in READS and named_wait(headers, now()) is not None:
                # a rate limit that names its end: wait it out, bounded by RATE_BUDGET_S, not by tries
                tries, budget_s = max(tries, attempt + 2), max(budget_s, rate_budget_s)
        last = attempt + 1 >= tries
        if not last and clock() - start + wait > budget_s:
            last = True
        what = f"{method} {req.full_url}: " + (f"{type(error).__name__}: {error}" if error else f"HTTP {status}")
        if last:
            if error is not None:
                raise error
            until = limited_until(headers, now())
            log(f"gh_http: {what}; gave up after {attempt + 1} tries"
                + (f"; rate-limited until {until}" if until else "")
                + (f"; the job's {DEADLINE_ENV} bound leaves no time to wait" if job_left is not None
                   and clock() - start + wait > budget_s else ""))
            break
        log(f"gh_http: {what}; asking again in {wait:.0f} s (try {attempt + 2} of {tries})")
        sleep(wait)
    if raise_errors and status >= 400:
        raise urllib.error.HTTPError(req.full_url, status, "", headers, io.BytesIO(body))
    return status, body, headers


RATE_WAIT_BUDGET_S = 600.0


def request_through_rate_limit(req: urllib.request.Request, seconds: float = CALL_S, *,
                               budget_s: float = RATE_WAIT_BUDGET_S, sleep: Callable[[float], None] = time.sleep,
                               clock: Callable[[], float] = time.monotonic, now: Callable[[], float] = time.time,
                               log: Callable[[str], None] | None = None) -> tuple[int, bytes, deadline_http.Headers]:
    """request(REQ, SECONDS) for a WRITE that a rate limit refused, asked again until the limit resets.

    request() never repeats a write, since the first may have landed. A 429, or a 403 that names a rate limit or
    carries x-ratelimit-remaining 0 or a Retry-After, is GitHub refusing before it runs the call, so asking again
    cannot double it. A status post left pending forever is a land that waits on it: cmux#60053's cmux/ios-fast
    pending (2026-11-27 07:20Z, 'API rate limit exceeded for installation') was never answered because the post
    gave up after three short rounds. This waits out the refusal (each wait as refusal_wait says, at most
    MAX_WAIT_S) within BUDGET_S seconds in all. Every other answer, a 5xx included, is returned as request() gives it."""
    log = log or (lambda line: print(line, file=sys.stderr))
    job_left = deadline_left(clock, now)  # a wait past the job's GH_HTTP_DEADLINE_S bound is a silent cancel
    if job_left is not None:
        budget_s = min(budget_s, job_left)
    start = clock()
    attempt = 0
    while True:
        status, body, headers = request(req, seconds)
        if status not in (403, 429):
            return status, body, headers
        wait = refusal_wait(status, headers, body, attempt, now())
        if wait is None or clock() - start + wait > budget_s:
            return status, body, headers
        log(f"gh_http: {req.get_method()} {req.full_url}: HTTP {status} (rate limit); asking again in {wait:.0f} s")
        sleep(wait)
        attempt += 1
