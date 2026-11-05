#!/usr/bin/env python3
"""nightly.yml build-sign-notarize-nightly: "Yield the sign slot to a newer build" (cmuxterm-hq#7079).

GitHub hands a free runner the oldest queued job on its label, and no runner can pick another
(teamleaderleo/glaeda#1815). The nightly-next sign jobs share a few owned slots, and publication is
latest-wins, so on 2026-11-04 the newest tip's sign job waited about 20 minutes per slot behind older
builds whose nightlies the next one replaced within minutes (runs 41866781601 to 41873130397).

When this job gets its runner, it reads whether a newer nightly-next push run already has its own sign
job queued, running or signed. If one does, this job hands its slot over (exit 1, output yielded=true)
before any secret or signing work, and the runner takes the next queued job. Nothing is cancelled.
report-nightly-failure does not report a yielded sign whose run had nothing else fail.

This narrows the rule of sign-pick-overtaken.sh (#33109): "Only a published newer build counts,
never a newer push alone: a newer run that then fails must not leave the feed with nothing
(#28961)." A newer push alone still never counts. What counts now is a newer run whose build has
finished and whose sign job exists, since GitHub creates a sign job only once its build jobs pass.
That newest sign job never yields (no newer run has one), so the newest finished build always signs.
#28961's starvation came from a run skipping its build as soon as nightly-next moved, before any
newer build existed; that can't happen here. The one thing given up: if that newest sign then fails,
the older builds that yielded to it are not signed, and the next tip builds as usual.

Never past 30 minutes (Leo, 2026-11-05: "If something hasn't f***ing ran for thirty minutes, f***ing build it.
Stop f***ing canceling it."). A run is due when its landing has waited PIN_AFTER_S (30 min) and the NEXT feed's
newest build is older than it (a lower run id), so its commits are not published. The newest due run with a sign
job never yields: it signs and publishes to the end, whatever newer run exists. An older run yields to it, so due
runs never sign oldest first, and runs newer than it, not yet due, coalesce behind it into one follow-up. An
unreadable feed, run start or run listing is doubt, and doubt signs.

Scope: attempt 1 of a nightly-next push run on the nightly-next track, unless
NIGHTLY_NEXT_SIGN_YIELD is 0. A re-run, a dispatch, main's nightly, and any doubt (an unreadable
answer, a malformed field, a listing longer than MAX_PAGES pages) sign as before.

    nightly_sign_yield.py
Env: GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT, GITHUB_EVENT_NAME, GITHUB_REF_NAME,
TRACK, GH_TOKEN (actions: read), GITHUB_OUTPUT; NIGHTLY_NEXT_SIGN_YIELD, GITHUB_API_URL optional.
Exit 1 only when it yields; 0 otherwise.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import re
import sys
import urllib.request
from collections.abc import Callable
from typing import Any

SIGN_JOB = "build-sign-notarize-nightly"
# A sign job that holds or waits for a slot, or already signed. Any other state (failed, cancelled,
# skipped) is no reason to yield.
WAITING = frozenset({"queued", "in_progress", "waiting", "pending", "requested"})
# Every unfinished run status. A newer run waiting on an environment or a concurrency slot can hold a queued
# sign job (cmuxterm-hq#7091), and so can a queued one: once its builds finish and only its sign job waits for
# a runner, GitHub reports the whole run as queued.
ACTIVE_RUN_STATUSES = ("in_progress", "queued", "waiting", "pending", "requested")
PAGE = 100
MAX_PAGES = 5
# Leo's rule: a landing that has waited this long unpublished is built, signed and published to the end.
PIN_AFTER_S = 30 * 60
NEXT_FEED = "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml"
# A NEXT build number is <run id><two-digit attempt>.
BUILD = re.compile(r"<sparkle:version>\s*([0-9]{3,})\s*</sparkle:version>")

Get = Callable[[str], Any]


class Unreadable(Exception):
    pass


def http_get(api: str, token: str) -> Get:
    def get(path: str) -> Any:
        request = urllib.request.Request(f"{api}/{path}", headers={
            "Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "cmux-nightly-sign-yield/1"})
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                return json.load(response)
        except Exception as error:  # any failure reads as doubt: this job signs
            raise Unreadable(f"{path}: {error}") from error
    return get


def read_feed(url: str = NEXT_FEED) -> bytes:
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "cmux-nightly-sign-yield/1"}),
                                    timeout=20) as response:
            return response.read(2_000_001)
    except Exception as error:  # doubt: this job signs
        raise Unreadable(f"{url}: {error}") from error


def last_published_run(feed: bytes) -> int | None:
    """The run id of the NEXT feed's newest build, or None for a feed with no build yet."""
    if len(feed) > 2_000_000:
        raise Unreadable("feed over 2 MB")
    text = feed.decode("utf-8", "replace")
    builds = [int(build) // 100 for build in BUILD.findall(text)]
    if not builds and "<item" in text:
        raise Unreadable("a feed item with no build number")
    return max(builds) if builds else None


def created(run: dict[str, Any]) -> dt.datetime:
    """When a push run was created, within a minute of its landing on nightly-next."""
    value = run.get("created_at")
    if not isinstance(value, str):
        raise Unreadable(f"run {run.get('id')!r}: no created_at")
    try:
        when = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise Unreadable(f"run {run.get('id')!r}: created_at {value!r}") from error
    if when.tzinfo is None:
        raise Unreadable(f"run {run.get('id')!r}: created_at {value!r} has no zone")
    return when


def due(now: dt.datetime, run_id: int, landed: dt.datetime, published_run: int | None) -> bool:
    """Leo's rule: its landing has waited PIN_AFTER_S and the feed's newest build is older than it."""
    return (now - landed).total_seconds() >= PIN_AFTER_S and (published_run is None or published_run < run_id)


def landed_at(get: Get, repo: str, run_id: int) -> dt.datetime:
    run = get(f"repos/{repo}/actions/runs/{run_id}")
    if not isinstance(run, dict) or run.get("id") != run_id:
        raise Unreadable(f"run {run_id}: unreadable")
    return created(run)


def listing(get: Get, path: str, key: str) -> list[dict[str, Any]]:
    """Every item of a paginated listing, read until an empty page, as signing_runner.every_page: total_count is not
    trusted (it runs ahead of a status-filtered list). More than MAX_PAGES pages is doubt."""
    items: list[dict[str, Any]] = []
    for page in range(1, MAX_PAGES + 2):
        body = get(f"{path}{'&' if '?' in path else '?'}per_page={PAGE}&page={page}")
        if not isinstance(body, dict) or not isinstance(body.get(key), list):
            raise Unreadable(f"{path}: not a {key} listing")
        batch = body[key]
        if not all(isinstance(item, dict) for item in batch):
            raise Unreadable(f"{path}: an item that is not an object")
        if not batch:
            return items
        if page > MAX_PAGES:
            break
        items.extend(batch)
    raise Unreadable(f"{path}: more than {MAX_PAGES} pages")


def signing(job: dict[str, Any]) -> bool:
    """Whether a newer run's sign job holds or waits for a slot, or signed."""
    status, conclusion = job.get("status"), job.get("conclusion")
    if not isinstance(status, str):
        raise Unreadable(f"job {job.get('id')!r}: no status")
    return status in WAITING or (status == "completed" and conclusion == "success")


def newer_signers(get: Get, repo: str, run_id: int) -> list[tuple[int, dt.datetime, str]]:
    """Every nightly-next push run above RUN_ID whose sign job is queued, running or signed, newest first, with
    its landing time and that job's state."""
    newer: dict[int, dt.datetime] = {}
    for status in ACTIVE_RUN_STATUSES:
        for run in listing(get, f"repos/{repo}/actions/workflows/nightly.yml/runs?branch=nightly-next&event=push&status={status}",
                           "workflow_runs"):
            rid = run.get("id")
            if not isinstance(rid, int) or isinstance(rid, bool):
                raise Unreadable(f"a run id {rid!r}")
            if rid > run_id:
                newer[rid] = created(run)
    found = []
    for rid in sorted(newer, reverse=True):
        for job in listing(get, f"repos/{repo}/actions/runs/{rid}/jobs?filter=latest", "jobs"):
            name = job.get("name")
            if isinstance(name, str) and name.split(" (", 1)[0] == SIGN_JOB and signing(job):
                state = f"{job['status']}{'/' + str(job.get('conclusion')) if job['status'] == 'completed' else ''}"
                found.append((rid, newer[rid], state))
                break
    return found


def utcnow() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def decide(env: dict[str, str], get: Get, log: Callable[[str], None] = print,
           feed: Callable[[], bytes] | None = None, now: Callable[[], dt.datetime] | None = None) -> tuple[bool, str]:
    """(yield, why)."""
    if env.get("NIGHTLY_NEXT_SIGN_YIELD", "1") == "0":
        return False, "NIGHTLY_NEXT_SIGN_YIELD is 0"
    if not (env.get("TRACK") == "nightly-next" and env.get("GITHUB_EVENT_NAME") == "push"
            and env.get("GITHUB_REF_NAME") == "nightly-next" and env.get("GITHUB_RUN_ATTEMPT") == "1"):
        return False, "not attempt 1 of a nightly-next push"
    run_id, repo = env.get("GITHUB_RUN_ID", ""), env.get("GITHUB_REPOSITORY", "")
    if not run_id.isdigit() or repo.count("/") != 1:
        return False, "no run id or repository"
    try:
        rid = int(run_id)
        landed = landed_at(get, repo, rid)
        published = last_published_run((feed or read_feed)())
        signers = newer_signers(get, repo, rid)
    except Unreadable as why:
        log(f"::warning title=Sign yield::could not read the newer nightly-next runs or the NEXT feed ({why}); "
            "signing as usual")
        return False, "unreadable"
    current = (now or utcnow)()
    # A newer due run takes the slot first: due runs sign newest first, never oldest first.
    for newer, newer_landed, state in signers:
        if due(current, newer, newer_landed, published):
            return True, f"newer nightly-next run {newer}, also waiting 30 min unpublished, has its sign job {state}"
    if due(current, rid, landed, published):
        waited = int((current - landed).total_seconds() // 60)
        return False, (f"due: this landing has waited {waited} min and the feed's newest build (run {published}) "
                       "is older, so nothing newer takes its slot")
    if not signers:
        return False, "no newer nightly-next run has a sign job yet"
    newer, _, state = signers[0]
    return True, f"newer nightly-next run {newer} has its sign job {state}"

def main() -> int:
    env = dict(os.environ)
    get = http_get(env.get("GITHUB_API_URL", "https://api.github.com"), env.get("GH_TOKEN", ""))
    yielded, why = decide(env, get)
    output = env.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"yielded={'true' if yielded else 'false'}\n")
    if yielded:
        print(f"::notice title=Sign yield::{why}; this older build gives up its sign slot (cmuxterm-hq#7079)")
        return 1
    print(f"signing: {why}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
