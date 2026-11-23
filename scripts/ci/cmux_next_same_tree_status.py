#!/usr/bin/env python3
"""A same-tree run's `(same-tree)` status, posted by a job outside the job it reports on.

STATUS_FROM_OUTSIDE (2026-11-15, cmux#43368 and #43027). A same-tree run of cmux-next.yml (dispatched by
cmux_next_tree_notify.py once a deferred cmux-tui tree is published or failed) posts its tiers' verdicts as
commit statuses on the commit it was for, and a pull request requires them. The posts used to be the last
step of the tested job itself, so whenever that job never ran its steps, nothing posted and nothing on the
pull request turned red:
- run 43666282494 (#43368 at 9cc846fc): `cmux-next daemon tests` failed with "The self-hosted runner lost
  communication with the server", every step was lost with the runner, and `cmux-next daemon tests
  (same-tree)` never posted;
- the scheme compile's post sat in `crash-ends-app`, a job with `permissions: {}` (every post refused) that a
  DEV daily skips, so `cmux NEXT DEV Release compile (same-tree)` never posted at all;
- a tested job skipped because a job it needs failed (web bundles, placement) posted nothing either.

So the jobs same-tree-status-daemon and same-tree-status-scheme run `if: always()` after the tested jobs, on
a Linux runner of their own, and this script turns `toJSON(needs)` into the one status with a reason:

  ready run, every tested job passed     -> success
  ready run, a tested job failed         -> failure, naming the job and its first error annotation
                                            (a lost runner is `error`: no verdict, re-run the failed jobs)
  ready run, a tested job never judged   -> error `no verdict: ...` (cancelled, timed out, skipped because
                                            a job it needs ended red: that job is named)
  failed run, same-tree-cmux-tui passed  -> nothing (it re-dispatched the ready jobs or a feat-cmux-next
                                            commit took the tree over, and said so)
  failed run, otherwise                  -> failure `same-tree cmux-tui unavailable: <reason>` (a pull
                                            request's failed tree too: its same-tree-cmux-tui is skipped)

The results are judged by scripts/ci/needs_verdict.py's rule (judge). A post refused on a rate limit waits for it
to lift, up to RATE_LIMIT_BUDGET_S; a 403 that is no rate limit, a rate limit past that, or any other refusal
three times is this job's red (exit 1), never a warning. Every other exit is 0: the status carries the verdict.

usage: cmux_next_same_tree_status.py --tier daemon|scheme --repo OWNER/NAME --status-sha SHA
       --state ready|failed --needs JSON [--reason TEXT] [--dev-daily] [--run-id ID] [--attempt N]
Needs GH_TOKEN with statuses: write, actions: read and checks: read.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cmux_next_same_tree_failed as failed  # noqa: E402
import cmux_next_tree_notify as notify  # noqa: E402
import needs_verdict as nv  # noqa: E402

SHA = re.compile(r"^[0-9a-f]{40}$")
DESCRIPTION_MAX = 140
POST_WAITS = (0, 20, 60)
# A post refused on a rate limit waits for it to lift (Retry-After, x-ratelimit-reset), this long in all; the
# reporter jobs' timeout-minutes leaves room for it. A spent installation resets up to an hour later, and 600 s
# gave up at once on any reset past it (hq#11485: cmux#43659's passed check stayed pending 2.5 h), so the wait
# runs to just under the hour the cmux-bot spare token, minted at the job's start, stays valid.
RATE_LIMIT_BUDGET_S = 3540
# Waits after a rate-limit refusal that names no time to wait (a secondary limit), in order; the last repeats.
SECONDARY_BACKOFF_S = (30, 60, 120, 180)
LOST_RUNNER = re.compile(r"lost communication|runner .*(?:shut ?down|was deprovisioned|stopped)|"
                         r"operation was canceled", re.I)
# The tested jobs of each tier, by job id, and the check names GitHub lists them under.
TESTED = {"daemon": ("daemon-test",), "scheme": ("cmux-scheme-compile", "crash-ends-app")}
DISPLAY = {
    "daemon-test": "cmux-next daemon tests",
    "cmux-scheme-compile": "cmux app scheme compile (Debug)",
    "crash-ends-app": "cmux-next crash ends the app",
}
DEV_DAILY_DISPLAY = {"cmux-scheme-compile": "cmux NEXT DEV Release compile"}
# The reporters themselves: never named as the upstream red.
REPORTERS = re.compile(r"^same-tree status ")


def tested_jobs(tier: str, dev_daily: bool) -> tuple[str, ...]:
    """The jobs whose results decide TIER's status. A DEV daily has no crash gate (crash-ends-app skips it)."""
    return tuple(job for job in TESTED[tier] if not (dev_daily and job == "crash-ends-app"))


def display(job: str, dev_daily: bool) -> str:
    return (DEV_DAILY_DISPLAY if dev_daily else {}).get(job) or DISPLAY.get(job, job)


def short(text: str, limit: int = DESCRIPTION_MAX) -> str:
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[: limit - 3].rstrip() + "..."


class Jobs:
    """This run attempt's jobs, read once, and a failed job's first error annotation."""

    def __init__(self, api: notify.Api, repo: str, run_id: str, attempt: str):
        self.api, self.repo, self.run_id, self.attempt = api, repo, run_id, attempt or "1"
        self._jobs: list[dict] | None = None

    def all(self) -> list[dict]:
        if self._jobs is None:
            self._jobs = []
            if self.run_id.isdigit():
                for page in range(1, 6):  # a cmux-next run has ~150 jobs: two pages, five at most
                    listing = self.api.get(f"repos/{self.repo}/actions/runs/{self.run_id}/attempts/"
                                           f"{self.attempt}/jobs?per_page=100&page={page}")
                    jobs = listing.get("jobs") or []
                    self._jobs.extend(jobs)
                    if len(jobs) < 100:
                        break
        return self._jobs

    def named(self, name: str) -> dict | None:
        return next((job for job in self.all() if job.get("name") == name), None)

    def upstream_reds(self) -> list[str]:
        return [f"{job.get('name')} {job.get('conclusion')}" for job in self.all()
                if job.get("conclusion") in ("failure", "cancelled", "timed_out")
                and not REPORTERS.match(str(job.get("name", "")))]

    def first_error(self, job: dict) -> str:
        """The job's first failure annotation, else its first failed step, else ''."""
        if not job.get("id"):
            return ""
        try:
            for note in self.api.get(f"repos/{self.repo}/check-runs/{job['id']}/annotations?per_page=50") or []:
                if note.get("annotation_level") == "failure" and note.get("message"):
                    return str(note["message"])
        except (RuntimeError, OSError, ValueError, KeyError, TypeError):
            pass
        step = next((s for s in job.get("steps") or [] if s.get("conclusion") == "failure"), None)
        return f"step `{step['name']}` failed" if step else ""


def verdict(args: argparse.Namespace, needs: dict, jobs: Jobs | None,
            log: Callable[[str], None] = print) -> tuple[str, str] | None:
    """(state, description) for the tier's status, or None when nothing is to be posted."""
    def result(job: str) -> str:
        return str((needs.get(job) or {}).get("result") or "")

    if args.state == "failed":
        if result("same-tree-cmux-tui") == "success":
            log("same-tree-cmux-tui passed: the tree was published or taken over since, and it said so; nothing to post")
            return None
        return "failure", short(f"same-tree cmux-tui unavailable: {args.reason or 'no reason given'}")
    names = tested_jobs(args.tier, args.dev_daily)
    state, reds, unjudged = nv.judge({job: result(job) for job in names})
    if state == nv.PASS:
        return "success", "same-tree cmux-tui run: success"

    def safely(read: Callable[[Jobs], str]) -> str:
        """READ of this run's jobs, or '' when there are none to read or GitHub could not be read."""
        if jobs is None:
            return ""
        try:
            return read(jobs)
        except (RuntimeError, OSError, ValueError, KeyError, TypeError) as error:
            log(f"::warning::could not read this run's jobs for the reason: {error}")
            return ""

    if state == nv.FAIL:
        job = display(next(iter(reds)), args.dev_daily)
        why = safely(lambda listed: listed.first_error(listed.named(job) or {}))
        if LOST_RUNNER.search(why):
            return "error", short(f"no verdict: {job}: {why}; re-run the failed jobs")
        return "failure", short(f"{job} failed" + (f": {why}" if why else ""))
    name, value = next(iter(unjudged.items()))
    upstream = safely(lambda listed: ", ".join(listed.upstream_reds()[:3])) if value in ("skipped", "") else ""
    return "error", short(f"no verdict: {display(name, args.dev_daily)} {value or 'none'}"
                          + (f" (red upstream: {upstream})" if upstream else "") + "; re-run the run")


def utc(at: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(at))


def rate_limit_wait(status: int, payload: bytes, headers: dict[str, str], backoffs: int,
                    now: float) -> tuple[float, str] | None:
    """How long until a post refused on a rate limit may pass, and why; None when the refusal is not a rate
    limit (a real permission 403 has no rate-limit header and does not say "rate limit")."""
    if status not in (403, 429):
        return None
    lowered = {str(name).lower(): str(value) for name, value in (headers or {}).items()}
    retry_after = lowered.get("retry-after", "").strip()
    if retry_after.isdigit():
        return max(1.0, float(retry_after)), f"Retry-After {retry_after} s"
    reset = lowered.get("x-ratelimit-reset", "").strip()
    if lowered.get("x-ratelimit-remaining") == "0" and reset.isdigit():
        return max(1.0, int(reset) - now + 1), f"the token's rate limit is spent until {utc(int(reset))}"
    if status == 429 or b"rate limit" in (payload or b"").lower():
        wait = SECONDARY_BACKOFF_S[min(backoffs, len(SECONDARY_BACKOFF_S) - 1)]
        return float(wait), f"a secondary rate limit; backing off {wait} s"
    return None


def refusal_text(payload: bytes) -> str:
    """GitHub's `message` of a refusal, else the start of its body."""
    try:
        message = json.loads(payload or b"{}").get("message")
    except (ValueError, AttributeError):
        message = None
    return short(message or (payload or b"").decode("utf-8", "replace"), 200)


def post(api: notify.Api, args: argparse.Namespace, state: str, description: str, target_url: str,
         sleep: Callable[[float], None] = time.sleep, log: Callable[[str], None] = print,
         now: Callable[[], float] = time.time) -> bool:
    """Post the status. RATE_LIMIT_WAIT (job 132784475164: github.token and the cmux-bot spare were both
    refused with HTTP 403 on a rate limit, three tries in 80 s, and the red blocked merges until a re-run): a
    403 or 429 on a rate limit is retried after its Retry-After, its x-ratelimit-reset or a backoff, for
    RATE_LIMIT_BUDGET_S in all. A 403 that is no rate limit (the token may not post) is red at once. Any other
    refusal (a 5xx, a dropped connection) is tried len(POST_WAITS) times."""
    [context] = failed.contexts([args.tier], args.dev_daily)
    body = {"state": state, "context": context, "description": description}
    if target_url:
        body["target_url"] = target_url
    started, backoffs, others = now(), 0, 0
    while True:
        try:
            code = api.post(f"repos/{args.repo}/statuses/{args.status_sha}", body)
        except (RuntimeError, OSError, ValueError) as error:
            code, error_text, payload, headers = 0, str(error), b"", {}
        else:
            last = getattr(api, "last", None)
            payload, headers = (last[1], last[2]) if last and last[0] == code else (b"", {})
            error_text = f"HTTP {code}" + (f": {refusal_text(payload)}" if payload else "")
        if code == 201:
            log(f"{context}: {state} on {args.status_sha[:12]}: {description}")
            return True
        limited = rate_limit_wait(code, payload, headers, backoffs, now())
        if limited is not None:
            wait, why = limited
            left = RATE_LIMIT_BUDGET_S - (now() - started)
            if wait > left:
                log(f"::error title=same-tree status not posted::{context}={state} on {args.status_sha} was "
                    f"refused on a rate limit ({error_text}; {why}) past this job's {RATE_LIMIT_BUDGET_S} s: NO_VERDICT, "
                    "the status stays as last posted; re-run this job to post it")
                return False
            log(f"::warning::the {context} status post was refused on a rate limit ({error_text}); {why}; "
                f"trying again in {int(wait)} s")
            sleep(wait)
            backoffs += 1
            continue
        if code == 403:
            log(f"::error title=same-tree status not posted::{context}={state} on {args.status_sha} was refused "
                f"with no rate limit ({error_text}): the token may not post statuses; fix the token, then re-run "
                "this job")
            return False
        others += 1
        if others >= len(POST_WAITS):
            break
        log(f"::warning::the {context} status post was refused ({error_text}); trying again")
        sleep(POST_WAITS[others])
    log(f"::error title=same-tree status not posted::could not post {context}={state} on {args.status_sha}: "
        "NO_VERDICT, the status stays as last posted; re-run this job to post it")
    return False


def parse(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--tier", required=True, choices=tuple(TESTED))
    parser.add_argument("--repo", required=True)
    parser.add_argument("--status-sha", required=True)
    parser.add_argument("--state", required=True, choices=("ready", "failed"))
    parser.add_argument("--needs", required=True, help="toJSON(needs)")
    parser.add_argument("--reason", default="")
    parser.add_argument("--dev-daily", action="store_true")
    parser.add_argument("--run-id", default="")
    parser.add_argument("--attempt", default="1")
    return parser.parse_args(argv)


def main(argv: list[str], api: notify.Api | None = None, sleep: Callable[[float], None] = time.sleep) -> int:
    args = parse(argv)
    if not SHA.match(args.status_sha):
        print(f"::error title=same-tree status not posted::not a commit: {args.status_sha!r}")
        return 1
    try:
        needs = json.loads(args.needs or "{}")
    except ValueError:
        needs = {}
    if api is None:
        # SAME_TREE_STATUS_SPARE_TOKEN (hq#11150): github.token shares one hourly budget with every run in the
        # repository; a spent one refused run 43660624788's post with HTTP 403. A rate-limited call moves to the
        # cmux-bot App token (its own budget) at once, through the tree notify client's SPARE_TOKEN_SWITCH.
        api = notify.GitHub(os.environ.get("GH_TOKEN", ""), os.environ.get("GITHUB_API_URL", "https://api.github.com"),
                            os.environ.get("GH_TOKEN_SPARE", ""))
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    target_url = f"{server}/{args.repo}/actions/runs/{args.run_id}" if args.run_id else ""
    jobs = Jobs(api, args.repo, args.run_id, args.attempt) if args.run_id else None
    decided = verdict(args, needs if isinstance(needs, dict) else {}, jobs)
    if decided is None:
        return 0
    return 0 if post(api, args, *decided, target_url, sleep=sleep) else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
