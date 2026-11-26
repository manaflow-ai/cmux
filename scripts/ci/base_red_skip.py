#!/usr/bin/env python3
"""Base-red skip: a pull request job that is red on the base branch right now is not run again on the pull request.

Leo, 2026-11-23 21:10Z: "we're drowning in our own workflow". On 2026-11-23 11:12-23:12Z (controller timing feed)
two PR jobs were red on every base push run that decided them, and their PR runs were red too, so a PR run told
nobody anything gh-merge-green does not already excuse (scripts/ci/base_red_excuse.py: a red the base shares is no
PR's red):
- tooling-tests: base 23 red and 0 green, PR 15 of 326 green, 110 runner-h a day;
- the Cloud journey (PR CLI on staging): 7 of 101 green on PRs while journey-staging was red, 77 runner-h a day.
CmuxMobileKit tests (base 21 of 21 red, PR 0 of 258 green) is not skipped: Leo wants every pull request to get a
proper run of it (his words of 2026-11-22 in cmux-next-ios-kit.yml).

A pre-job the PR job already waits on (or a one-step job) runs `decide`. It reads the newest base push runs of the
job's workflow on the base branch, newest first, and takes that job's newest decided verdict (success or failure;
skipped, cancelled and unfinished runs are passed over, at most --runs runs, none created over --max-age-hours
ago: a red no base push has re-judged in that long, say a workflow whose paths the fixing push did not touch,
runs the job again). When it is a failure the PR job is
skipped, and the annotation names the base run that is red. A green, a missing verdict, or any read that fails or
runs past the deadline runs the job: the skip fails open.

`--events push,workflow_dispatch --dispatch-title PREFIX` also reads the base's dispatched runs whose title starts
with PREFIX (one page of 100, each event keeping its own --runs): cmux-next.yml's generated files job is judged on
the base only by the `cmux-next base tier` dispatch (cmux-next-base-tier-kick.yml); its push runs skip it.

What runs anyway:
- a pull request labeled full-ci (a PR that fixes the base red proves it there, or merges and the next base push
  run proves it);
- AUDIT_PERCENT (default 10) of skips, seeded by the run id and attempt, so a PR that adds its own red to a job
  already red on the base is still seen on some runs (detector);
- every push, dispatch and schedule run: only pull_request runs are skipped.
`vars.CI_SKIP_WHILE_BASE_RED == '0'` turns the skip off everywhere (the workflows read it as
format('{0}', vars.CI_SKIP_WHILE_BASE_RED) != '0', docs/handbook unset-var-reads-as-zero).

The miss: a PR that adds a new red inside a job already red on the base merges. The next base push run of that job
is red where it was red already; base-red-watch bisects its new failing tests over the covered pushes.

A workflow with several such jobs runs `decide-many` once, in one pre-job, and each job checks its own name in the
`red_jobs` list it prints (one list read and at most --runs jobs reads in all).

usage:
  base_red_skip.py decide-many --workflow FILE --job NAME [--job NAME ...] [same options] -> `red_jobs=["NAME",...]`
  base_red_skip.py decide --workflow FILE --job NAME [--base feat-cmux-next] [--events push] [--dispatch-title PREFIX] [--runs 6]
      [--max-age-hours 12]
      [--audit-percent 10] -> `base_red=true|false` and `base_run=<url>` lines on stdout (for $GITHUB_OUTPUT)
Environment: GITHUB_REPOSITORY, GH_TOKEN (actions: read), GH_TOKEN_FALLBACK (optional, actions: read: read with it
once GH_TOKEN is refused with a 403 or 429), GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT, GITHUB_EVENT_NAME.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import http.client
import json
import os
import sys
import time
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deadline_http  # noqa: E402

API = os.environ.get("GITHUB_API_URL", "https://api.github.com")
# The whole read set (one list, then at most --runs jobs reads) ends by DEADLINE_S; each read try by READ_S of it, so
# one slow answer is tried again instead of eating the budget. 2026-11-25 from 12Z GitHub answered slowly, and with
# one 40 s budget for up to 13 reads and no retry, decide-many failed open on PRs whose base was red (~2.0k PR
# minutes of cargo that day). The cmux-next.yml step that runs it allows 3 minutes.
DEADLINE_S = 90.0
READ_S = 20.0
READ_TRIES = 3
RETRY_STATUSES = frozenset({429, 500, 502, 503, 504})
DECIDED = {"success": False, "failure": True}


class Refused(RuntimeError):
    """A 403 or 429: this token's quota (or its rights) refused the read; another token may still be let in."""


def get_json(path: str, token: str, deadline: deadline_http.Deadline, sleep=time.sleep):
    """GET PATH as JSON: a timeout, a dropped connection or a 5xx is tried again (READ_TRIES tries, each at
    most READ_S, all inside DEADLINE); a 403 or 429 raises Refused at once, so token_reader moves to the next token
    instead of spending the deadline on a spent quota; any other status, or the last try's failure, raises."""
    req = urllib.request.Request(f"{API}{path}", headers={
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    last = ""
    for attempt in range(READ_TRIES):
        left = deadline.at - deadline.clock()
        if left <= 0:
            break
        if attempt:
            pause = min(2.0 ** attempt, left / 2)
            sleep(pause)
            left -= pause
        try:
            status, body, headers = deadline_http.request(
                req, deadline=deadline_http.Deadline(min(READ_S, left), clock=deadline.clock))
        except (OSError, http.client.HTTPException) as err:  # RequestTimeout and URLError are OSErrors
            last = f"{type(err).__name__}: {err}"
            continue
        if status in (403, 429):
            rate_left = headers.get("x-ratelimit-remaining") if headers is not None else None
            raise Refused(f"GET {path}: HTTP {status}" + (f" (rate limit left: {rate_left})" if rate_left is not None else ""))
        if status in RETRY_STATUSES:
            last = f"HTTP {status}"
            continue
        if status != 200:
            raise RuntimeError(f"GET {path}: HTTP {status}")
        return json.loads(body)
    raise RuntimeError(f"GET {path}: {last or 'no time left'} (after {READ_TRIES} tries or the {deadline.seconds:g} s deadline)")


def token_reader(tokens: list[str], deadline: deadline_http.Deadline, get=get_json):
    """A read that moves to the next token when one is refused (403/429), and keeps it for the reads after.

    The workflow's GITHUB_TOKEN shares one hourly quota with every job of the repository: on 2026-11-24 18-19Z it
    answered 403 to 4 of 6 generated-files decides, so each ran the 20-60 min job the base already had red. The
    jobs pass a GitHub App token as GH_TOKEN_FALLBACK, which has its own quota."""
    state = {"at": 0}

    def read(path: str):
        errors = []
        while state["at"] < len(tokens):
            try:
                return get(path, tokens[state["at"]], deadline)
            except Refused as err:
                errors.append(str(err))
                state["at"] += 1
        raise RuntimeError("; ".join(errors) or "no token to read the base with")
    return read


def tokens_of(env) -> list[str]:
    """GH_TOKEN (or GITHUB_TOKEN), then GH_TOKEN_FALLBACK when set: the order token_reader tries them in."""
    tokens = [t for t in (env.get("GH_TOKEN") or env.get("GITHUB_TOKEN") or "", env.get("GH_TOKEN_FALLBACK") or "")
              if t]
    return list(dict.fromkeys(tokens)) or [""]


def base_verdicts(repo: str, workflow: str, jobs: list[str], base: str, runs: int, read, max_age_hours: float = 12.0,
                  now: dt.datetime | None = None, events: tuple[str, ...] = ("push",),
                  dispatch_title: str = "") -> dict[str, tuple[bool, str]]:
    """{job: (red, url)} for each of JOBS with a decided verdict on BASE's newest EVENTS runs of WORKFLOW.

    One list read per event, then one jobs read per run until every job has its newest decided verdict, so a
    workflow's pre-job decides all of its jobs for the price one job cost (row 12 of hq RFD 0148: a breaker per job,
    not per workflow)."""
    now = now or dt.datetime.now(dt.timezone.utc)
    listed_runs = []
    for event in events:
        titled = event == "workflow_dispatch" and bool(dispatch_title)
        # A titled list reads one page of 100 (about 12 h of cmux-next.yml dispatches, 2026-11-24) and keeps --runs.
        query = urllib.parse.urlencode({"branch": base, "event": event, "status": "completed",
                                        "per_page": 100 if titled else runs})
        listed = read(f"/repos/{repo}/actions/workflows/{urllib.parse.quote(workflow)}/runs?{query}")
        kept = 0
        for run in listed.get("workflow_runs") or []:
            # cmux-next.yml's dispatches are mostly DEV daily runs without the job; only the base tier judges it.
            if titled and not (run.get("display_title") or "").startswith(dispatch_title):
                continue
            listed_runs.append(run)
            kept += 1
            if kept >= runs:
                break
    # Newest first across the events (ISO timestamps sort as text); one event keeps GitHub's own order. Each event
    # keeps its own --runs: base pushes come every few minutes, and a shared cap would leave out the slower dispatch.
    if len(events) > 1:
        listed_runs.sort(key=lambda run: run.get("created_at") or "", reverse=True)
    want = set(jobs)
    found: dict[str, tuple[bool, str]] = {}
    for run in listed_runs:
        if not want - set(found):
            break
        created = run.get("created_at") or ""
        try:
            age_h = (now - dt.datetime.strptime(created, "%Y-%m-%dT%H:%M:%SZ").replace(
                tzinfo=dt.timezone.utc)).total_seconds() / 3600
        except ValueError:
            break  # no readable age: no verdict past here to skip on
        if age_h > max_age_hours:
            break
        listed_jobs = read(f"/repos/{repo}/actions/runs/{run['id']}/jobs?filter=latest&per_page=100")
        for item in listed_jobs.get("jobs") or []:
            name = item.get("name")
            if name in want and name not in found and item.get("conclusion") in DECIDED:
                found[name] = (DECIDED[item["conclusion"]], item.get("html_url") or run.get("html_url", ""))
    return found


def base_verdict(repo: str, workflow: str, job: str, base: str, runs: int, read, max_age_hours: float = 12.0,
                 now: dt.datetime | None = None, events: tuple[str, ...] = ("push",),
                 dispatch_title: str = "") -> tuple[bool | None, str]:
    """(red, run url) of JOB's newest decided verdict on BASE's EVENTS runs of WORKFLOW; (None, '') when none is."""
    return base_verdicts(repo, workflow, [job], base, runs, read, max_age_hours, now, events,
                         dispatch_title).get(job, (None, ""))


def events_of(args) -> tuple[str, ...]:
    return tuple(e.strip() for e in (getattr(args, "events", None) or "push").split(",") if e.strip()) or ("push",)


def audited(percent: int, run_id: str, attempt: str, job: str) -> bool:
    if percent <= 0:
        return False
    seed = hashlib.sha256(f"{run_id}:{attempt}:{job}".encode()).digest()
    return int.from_bytes(seed[:4], "big") % 100 < percent


def decide(args, env=os.environ, read=None, now=None) -> list[str]:
    job = args.job
    if env.get("GITHUB_EVENT_NAME") != "pull_request":
        return ["base_red=false"]
    repo = env.get("GITHUB_REPOSITORY", "")
    if read is None:
        read = token_reader(tokens_of(env), deadline_http.Deadline(DEADLINE_S))
    try:
        red, url = base_verdict(repo, args.workflow, job, args.base, args.runs, read,
                                getattr(args, "max_age_hours", 12.0), now, events_of(args),
                                getattr(args, "dispatch_title", "") or "")
    except Exception as err:  # fail open: an unread base runs the job
        print(f"::notice title=base-red skip: {job}::the base verdict could not be read ({err}); running it",
              file=sys.stderr)
        return ["base_red=false"]
    if not red:
        return ["base_red=false"]
    if audited(args.audit_percent, env.get("GITHUB_RUN_ID", ""), env.get("GITHUB_RUN_ATTEMPT", "1"), job):
        print(f"::notice title=base-red skip: {job} (audit)::red on {args.base} ({url}); this run is the "
              f"{args.audit_percent}% audit and runs in full", file=sys.stderr)
        return ["base_red=false", f"base_run={url}"]
    print(f"::notice title=base-red skip: {job}::not run on this pull request: it is red on {args.base} now "
          f"({url}), so gh-merge-green excuses the same red here. The next base push run judges it; label full-ci "
          f"to run it anyway (scripts/ci/base_red_skip.py)", file=sys.stderr)
    return ["base_red=true", f"base_run={url}"]


def decide_many(args, env=os.environ, read=None, now=None) -> list[str]:
    """`red_jobs=<JSON list>`: the jobs of ARGS.job red on the base now, less the audited ones; `[]` on any doubt.

    A job reads it as `!contains(fromJSON(needs.base-red.outputs.red_jobs || '[]'), '<its check name>')`."""
    jobs = list(dict.fromkeys(args.job))
    if env.get("GITHUB_EVENT_NAME") != "pull_request" or not jobs:
        return ["red_jobs=[]"]
    repo = env.get("GITHUB_REPOSITORY", "")
    if read is None:
        read = token_reader(tokens_of(env), deadline_http.Deadline(DEADLINE_S))
    try:
        found = base_verdicts(repo, args.workflow, jobs, args.base, args.runs, read,
                              getattr(args, "max_age_hours", 12.0), now, events_of(args),
                              getattr(args, "dispatch_title", "") or "")
    except Exception as err:  # fail open: an unread base runs every job
        print(f"::notice title=base-red skip::the base verdicts could not be read ({err}); running every job",
              file=sys.stderr)
        return ["red_jobs=[]"]
    red = []
    for job in jobs:
        is_red, url = found.get(job, (False, ""))
        if not is_red:
            continue
        if audited(args.audit_percent, env.get("GITHUB_RUN_ID", ""), env.get("GITHUB_RUN_ATTEMPT", "1"), job):
            print(f"::notice title=base-red skip: {job} (audit)::red on {args.base} ({url}); this run is the "
                  f"{args.audit_percent}% audit and runs in full", file=sys.stderr)
            continue
        print(f"::notice title=excused: base red: {job}::not run on this pull request: it is red on {args.base} now "
              f"({url}), so gh-merge-green excuses the same red here. The next push after {args.base} goes green runs "
              f"it; label full-ci to run it anyway (scripts/ci/base_red_skip.py)", file=sys.stderr)
        red.append(job)
    return [f"red_jobs={json.dumps(red, separators=(',', ':'))}"]


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    for name in ("decide", "decide-many"):
        d = sub.add_parser(name)
        d.add_argument("--workflow", required=True, help="workflow file name, e.g. backend.yml")
        if name == "decide":
            d.add_argument("--job", required=True, help="the job's check name")
        else:
            d.add_argument("--job", required=True, action="append", help="a job's check name (repeat it)")
        d.add_argument("--base", default="feat-cmux-next")
        d.add_argument("--runs", type=int, default=6)
        d.add_argument("--events", default="push",
                       help="comma-separated base run events; cmux-next.yml's base tier runs are workflow_dispatch")
        d.add_argument("--dispatch-title", default="", help="keep only dispatched runs whose title starts with this")
        d.add_argument("--max-age-hours", type=float, default=12.0)
        d.add_argument("--audit-percent", type=int, default=int(os.environ.get("AUDIT_PERCENT") or 10))
    args = parser.parse_args(argv)
    for line in (decide if args.cmd == "decide" else decide_many)(args):
        print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
