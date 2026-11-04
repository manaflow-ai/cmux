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

Scope: attempt 1 of a nightly-next push run on the nightly-next track, unless
NIGHTLY_NEXT_SIGN_YIELD is 0. A re-run, a dispatch, main's nightly, and any doubt (an unreadable
answer, a malformed field, a listing longer than MAX_PAGES pages) sign as before.

    nightly_sign_yield.py
Env: GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT, GITHUB_EVENT_NAME, GITHUB_REF_NAME,
TRACK, GH_TOKEN (actions: read), GITHUB_OUTPUT; NIGHTLY_NEXT_SIGN_YIELD, GITHUB_API_URL optional.
Exit 1 only when it yields; 0 otherwise.
"""
from __future__ import annotations

import json
import os
import sys
import urllib.request
from collections.abc import Callable
from typing import Any

SIGN_JOB = "build-sign-notarize-nightly"
# A sign job that holds or waits for a slot, or already signed. Any other state (failed, cancelled,
# skipped) is no reason to yield.
WAITING = frozenset({"queued", "in_progress", "waiting", "pending", "requested"})
# Every unfinished run status but queued, as signing_runner.ACTIVE_RUN_STATUSES: a newer run waiting on an
# environment or a concurrency slot can hold a queued sign job too (cmuxterm-hq#7091). A queued run has no job yet.
ACTIVE_RUN_STATUSES = ("in_progress", "waiting", "pending", "requested")
PAGE = 100
MAX_PAGES = 5

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


def newer_signer(get: Get, repo: str, run_id: int) -> tuple[int, str] | None:
    """The newest nightly-next push run above RUN_ID whose sign job is queued, running or signed,
    with that job's state; or None."""
    newer: set[int] = set()
    for status in ACTIVE_RUN_STATUSES:
        for run in listing(get, f"repos/{repo}/actions/workflows/nightly.yml/runs?branch=nightly-next&event=push&status={status}",
                           "workflow_runs"):
            rid = run.get("id")
            if not isinstance(rid, int) or isinstance(rid, bool):
                raise Unreadable(f"a run id {rid!r}")
            if rid > run_id:
                newer.add(rid)
    for rid in sorted(newer, reverse=True):
        for job in listing(get, f"repos/{repo}/actions/runs/{rid}/jobs?filter=latest", "jobs"):
            name = job.get("name")
            if isinstance(name, str) and name.split(" (", 1)[0] == SIGN_JOB and signing(job):
                return rid, f"{job['status']}{'/' + str(job.get('conclusion')) if job['status'] == 'completed' else ''}"
    return None


def decide(env: dict[str, str], get: Get, log: Callable[[str], None] = print) -> tuple[bool, str]:
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
        found = newer_signer(get, repo, int(run_id))
    except Unreadable as why:
        log(f"::warning title=Sign yield::could not read the newer nightly-next runs ({why}); signing as usual")
        return False, "unreadable"
    if found is None:
        return False, "no newer nightly-next run has a sign job yet"
    rid, state = found
    return True, f"newer nightly-next run {rid} has its sign job {state}"


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
