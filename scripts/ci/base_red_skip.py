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

usage:
  base_red_skip.py decide --workflow FILE --job NAME [--base feat-cmux-next] [--runs 6] [--max-age-hours 12]
      [--audit-percent 10] -> `base_red=true|false` and `base_run=<url>` lines on stdout (for $GITHUB_OUTPUT)
Environment: GITHUB_REPOSITORY, GH_TOKEN (actions: read), GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT, GITHUB_EVENT_NAME.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import sys
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deadline_http  # noqa: E402

API = os.environ.get("GITHUB_API_URL", "https://api.github.com")
DEADLINE_S = 40.0
DECIDED = {"success": False, "failure": True}


def get_json(path: str, token: str, deadline: deadline_http.Deadline):
    req = urllib.request.Request(f"{API}{path}", headers={
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    status, body, _ = deadline_http.request(req, deadline=deadline)
    if status != 200:
        raise RuntimeError(f"GET {path}: HTTP {status}")
    return json.loads(body)


def base_verdict(repo: str, workflow: str, job: str, base: str, runs: int, read, max_age_hours: float = 12.0,
                 now: dt.datetime | None = None) -> tuple[bool | None, str]:
    """(red, run url) of JOB's newest decided verdict on BASE's push runs of WORKFLOW; (None, '') when none is."""
    now = now or dt.datetime.now(dt.timezone.utc)
    query = urllib.parse.urlencode({"branch": base, "event": "push", "status": "completed", "per_page": runs})
    listed = read(f"/repos/{repo}/actions/workflows/{urllib.parse.quote(workflow)}/runs?{query}")
    for run in (listed.get("workflow_runs") or [])[:runs]:
        created = run.get("created_at") or ""
        try:
            age_h = (now - dt.datetime.strptime(created, "%Y-%m-%dT%H:%M:%SZ").replace(
                tzinfo=dt.timezone.utc)).total_seconds() / 3600
        except ValueError:
            return None, ""  # no readable age: not a verdict to skip on
        if age_h > max_age_hours:
            return None, ""
        jobs = read(f"/repos/{repo}/actions/runs/{run['id']}/jobs?filter=latest&per_page=100")
        for item in jobs.get("jobs") or []:
            if item.get("name") == job and item.get("conclusion") in DECIDED:
                return DECIDED[item["conclusion"]], item.get("html_url") or run.get("html_url", "")
    return None, ""


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
    token = env.get("GH_TOKEN") or env.get("GITHUB_TOKEN") or ""
    if read is None:
        deadline = deadline_http.Deadline(DEADLINE_S)
        read = lambda path: get_json(path, token, deadline)  # noqa: E731
    try:
        red, url = base_verdict(repo, args.workflow, job, args.base, args.runs, read,
                                getattr(args, "max_age_hours", 12.0), now)
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


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("decide")
    d.add_argument("--workflow", required=True, help="workflow file name, e.g. backend.yml")
    d.add_argument("--job", required=True, help="the job's check name")
    d.add_argument("--base", default="feat-cmux-next")
    d.add_argument("--runs", type=int, default=6)
    d.add_argument("--max-age-hours", type=float, default=12.0)
    d.add_argument("--audit-percent", type=int, default=int(os.environ.get("AUDIT_PERCENT") or 10))
    args = parser.parse_args(argv)
    for line in decide(args):
        print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
