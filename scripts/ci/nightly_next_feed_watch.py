#!/usr/bin/env python3
"""Alarm when feat-cmux-next work waits too long to reach the nightly-next feed.

nightly-next ships feat-cmux-next: a green push is promoted to the
`nightly-next` branch, whose nightly.yml run publishes appcast-arm64.xml. Any
stage can stall: a red Release compile or an unpublished cmux-tui tree stops
promotion, a red nightly stops publication. Lawrence and Leo daily-drive the
feed, so this checks it every 30 minutes from main (schedule runs only there).

Waiting is measured from the oldest feat-cmux-next push after the published
commit's own push (cmux-next guards runs on every such push), so a quiet spell
never alarms however old the feed is, and a push that landed while the
published build ran still counts. Past --max-lag-hours it keeps ONE open
`nightly-next-feed-stale` issue, updated in place, naming the last published
commit and the stage that is stuck; it comments only when that reason changes,
and closes the issue once nothing has waited that long.

usage: nightly_next_feed_watch.py --repo OWNER/NAME [--max-lag-hours 4] [--dry-run]
Needs GH_TOKEN with actions: read and issues: write.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import datetime as dt
import email.utils
import json
import os
import re
import sys
import urllib.parse
import urllib.request

FEED_URL = "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml"  # cmux NEXT (cx-x7hwx)
LABEL = "nightly-next-feed-stale"
PUSH_WORKFLOW = "cmux-next-guards.yml"  # every feat-cmux-next push, no path filter
RELEASE_COMPILE_JOB = "cmux-next Release compile (Xcode 26)"
PUBLISHED_MARKER = re.compile(r"<!--\s*cmux-published-sha:\s*([0-9a-f]{40})\s*-->", re.IGNORECASE)


@dataclass(frozen=True)
class Stage:
    """What the watcher found; `reason` is the issue line that names the stuck stage."""
    stale: bool
    waited_hours: float
    since: dt.datetime | None
    reason: str


def parse_time(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def newest_item(feed_xml: str) -> dt.datetime | None:
    dates = [email.utils.parsedate_to_datetime(m) for m in re.findall(r"<pubDate>([^<]+)</pubDate>", feed_xml)]
    return max(dates) if dates else None


def failed_steps(jobs: list[dict]) -> str:
    out = []
    for job in jobs:
        if job.get("conclusion") not in ("failure", "timed_out"):
            continue
        steps = [step["name"] for step in job.get("steps") or [] if step.get("conclusion") == "failure"]
        out.append(f"{job['name']} (step: {', '.join(steps)})" if steps else job["name"])
    return "; ".join(out) or "no failed job recorded"


def assess(now: dt.datetime, newest: dt.datetime, pushes: list[dict], nightly: list[dict],
           jobs_of, artifacts: list[dict], compiles: list[dict], max_lag_hours: float) -> Stage:
    """pushes: the waiting feat-cmux-next push runs (only the oldest matters); nightly: nightly-next push runs since
    `newest` (newest first); artifacts / compiles: the latest feat-cmux-next cmux-tui artifacts
    and cmux-next push runs (newest first); jobs_of(run) lists a run's jobs."""
    if not pushes:
        return Stage(False, 0.0, None, "No feat-cmux-next push since the feed's newest item.")
    since = min(parse_time(run["created_at"]) for run in pushes)
    waited = (now - since).total_seconds() / 3600
    # The newest nightly-next run that is building or decided: a newer build supersedes an older failure.
    latest = next((run for run in nightly if run.get("status") != "completed" or run.get("conclusion") in ("success", "failure", "timed_out")), None)
    if latest and latest.get("status") != "completed":
        reason = f"nightly-next run {latest['html_url']} on {latest['head_sha'][:12]} is still building."
    elif latest and latest.get("conclusion") == "success":
        reason = f"nightly-next run {latest['html_url']} on {latest['head_sha'][:12]} passed but did not publish (debounced or skipped publication)."
    elif latest:
        reason = f"nightly-next run {latest['html_url']} on {latest['head_sha'][:12]} failed: {failed_steps(jobs_of(latest))}."
    else:
        reason = "Nothing was promoted to nightly-next since the feed's newest item."
        artifact = artifacts[0] if artifacts else None
        if artifact and artifact.get("conclusion") == "failure":
            reason += f" The latest feat-cmux-next cmux-tui artifacts run {artifact['html_url']} failed, so its tree is unpublished: {failed_steps(jobs_of(artifact))}."
        # Superseded pushes cancel or skip their compile; read the newest one that finished.
        for compile_run in (run for run in compiles if run.get("status") == "completed"):
            compile_job = next((job for job in jobs_of(compile_run) if job["name"] == RELEASE_COMPILE_JOB), None)
            conclusion = compile_job.get("conclusion") if compile_job else None
            if conclusion in ("failure", "timed_out"):
                reason += f" The latest feat-cmux-next {RELEASE_COMPILE_JOB} is {conclusion}: {compile_run['html_url']}."
            if conclusion in ("success", "failure", "timed_out"):
                break
    return Stage(waited > max_lag_hours, waited, since, reason)


def issue_body(stage: Stage, newest: dt.datetime, now: dt.datetime, published_sha: str, max_lag_hours: float, run_url: str) -> str:
    feed_hours = (now - newest).total_seconds() / 3600
    return "\n\n".join([
        f"feat-cmux-next pushes have waited {stage.waited_hours:.1f} hours (limit {max_lag_hours:g}h) for the nightly-next feed, "
        f"since {stage.since.isoformat(timespec='minutes') if stage.since else '?'}. The feed's newest item is {feed_hours:.1f} hours old "
        f"({newest.isoformat(timespec='minutes')}). Installed nightly-next apps report \"Up to Date\".",
        f"Last published commit: {published_sha or '(unknown)'}.",
        stage.reason,
        f"Checked by {run_url}. This issue is updated in place every 30 minutes, gets a comment when the stuck stage changes, and closes when the feed catches up.",
    ])


def stamp(when: dt.datetime) -> str:
    return when.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class GitHub:
    def __init__(self, repo: str, token: str, dry_run: bool):
        self.base = f"https://api.github.com/repos/{repo}"
        self.token = token
        self.dry_run = dry_run

    def call(self, method: str, path: str, body: dict | None = None):
        if self.dry_run and method != "GET":
            print(f"dry run: {method} {path} {json.dumps(body)[:200] if body else ''}")
            return {}
        request = urllib.request.Request(
            self.base + path, method=method, data=json.dumps(body).encode() if body is not None else None,
            headers={"Authorization": f"Bearer {self.token}", "Accept": "application/vnd.github+json",
                     "X-GitHub-Api-Version": "2022-11-28"})
        with urllib.request.urlopen(request, timeout=30) as response:
            data = response.read()
        return json.loads(data) if data else None

    def runs_page(self, workflow: str, branch: str, created: str | None = None, per_page: int = 100, page: int = 1, **extra) -> dict:
        query = {"branch": branch, "event": "push", "per_page": per_page, "page": page, **extra}
        if created:
            query["created"] = created
        return self.call("GET", f"/actions/workflows/{workflow}/runs?{urllib.parse.urlencode(query)}")

    def runs(self, workflow: str, branch: str, created_since: dt.datetime | None = None, per_page: int = 100):
        return self.runs_page(workflow, branch, ">=" + stamp(created_since) if created_since else None, per_page)["workflow_runs"]

    def jobs(self, run: dict) -> list[dict]:
        return self.call("GET", f"/actions/runs/{run['id']}/jobs?filter=latest&per_page=100")["jobs"]


def published_commit(gh: GitHub) -> str:
    try:
        body = gh.call("GET", "/releases/tags/nightly-next").get("body") or ""
    except Exception:  # noqa: BLE001 - the issue only loses one line
        return ""
    match = PUBLISHED_MARKER.search(body)  # scripts/ci/nightly-publication-marker.py
    return match.group(1).lower() if match else ""


def oldest_waiting_push(gh: GitHub, published_sha: str, newest: dt.datetime) -> dict | None:
    """The oldest feat-cmux-next push after the published commit's push (else since the
    feed's newest item). Runs list newest first and a busy day has hundreds, so read
    the count and then the last page; a filtered listing stops at 1000 results, which
    is still far past the limit."""
    created = ">=" + stamp(newest)
    if published_sha:
        own = gh.runs_page(PUSH_WORKFLOW, "feat-cmux-next", per_page=1, head_sha=published_sha)["workflow_runs"]
        if own:
            created = ">" + stamp(parse_time(own[0]["created_at"]))
    total = gh.runs_page(PUSH_WORKFLOW, "feat-cmux-next", created, per_page=1)["total_count"]
    if not total:
        return None
    return gh.runs_page(PUSH_WORKFLOW, "feat-cmux-next", created, per_page=1, page=min(total, 1000))["workflow_runs"][0]


def read_feed(url: str) -> dt.datetime | None:
    # The CDN answers Python's default user agent with 403.
    request = urllib.request.Request(url, headers={"Cache-Control": "no-cache", "User-Agent": "cmux-nightly-next-feed-watch"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return newest_item(response.read().decode("utf-8", "replace"))


def sync_issue(gh: GitHub, stage: Stage, body: str, max_lag_hours: float, run_url: str) -> str:
    """One open issue while stale (oldest kept, duplicates closed); closed when not."""
    open_issues = sorted(gh.call("GET", f"/issues?labels={LABEL}&state=open&per_page=100"), key=lambda issue: issue["number"])
    if not stage.stale:
        for issue in open_issues:
            gh.call("POST", f"/issues/{issue['number']}/comments", {"body": f"The nightly-next feed caught up: {run_url}"})
            gh.call("PATCH", f"/issues/{issue['number']}", {"state": "closed"})
        return f"current ({stage.waited_hours:.1f}h waited); closed {len(open_issues)} issue(s)"
    title = f"nightly-next feed: feat-cmux-next pushes waiting more than {max_lag_hours:g}h"
    if not open_issues:
        gh.call("POST", "/issues", {"title": title, "body": body, "labels": [LABEL]})
        return "stale; opened an issue"
    keep, *duplicates = open_issues
    gh.call("PATCH", f"/issues/{keep['number']}", {"title": title, "body": body})
    if stage.reason not in (keep.get("body") or ""):
        gh.call("POST", f"/issues/{keep['number']}/comments", {"body": stage.reason})
    for issue in duplicates:
        gh.call("POST", f"/issues/{issue['number']}/comments", {"body": f"Duplicate of #{keep['number']}."})
        gh.call("PATCH", f"/issues/{issue['number']}", {"state": "closed"})
    return f"stale; updated #{keep['number']}"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--max-lag-hours", type=float, default=4.0)
    parser.add_argument("--feed-url", default=FEED_URL)
    parser.add_argument("--run-url", default="this check")
    parser.add_argument("--dry-run", action="store_true", help="read and decide, never write issues")
    args = parser.parse_args(argv)
    token = os.environ.get("GH_TOKEN", "")
    if not token:
        print("GH_TOKEN is required", file=sys.stderr)
        return 2
    try:
        newest = read_feed(args.feed_url)
    except OSError as error:
        print(f"::warning::could not read {args.feed_url}: {error}")
        return 0
    if newest is None:
        print(f"::warning::{args.feed_url} has no dated item")
        return 0
    gh = GitHub(args.repo, token, args.dry_run)
    now = dt.datetime.now(dt.timezone.utc)
    try:
        published_sha = published_commit(gh)
        oldest = oldest_waiting_push(gh, published_sha, newest)
        stage = assess(
            now, newest,
            pushes=[oldest] if oldest else [],
            nightly=gh.runs("nightly.yml", "nightly-next", newest),
            jobs_of=gh.jobs,
            artifacts=gh.runs("cmux-tui-artifacts.yml", "feat-cmux-next", per_page=1),
            compiles=gh.runs("cmux-next.yml", "feat-cmux-next", per_page=5),
            max_lag_hours=args.max_lag_hours,
        )
        print(f"feed newest {newest.isoformat()}, waited {stage.waited_hours:.1f}h: {stage.reason}")
        if stage.stale:
            print(f"::warning title=nightly-next feed stale::{stage.reason}")
        print(sync_issue(gh, stage, issue_body(stage, newest, now, published_sha, args.max_lag_hours, args.run_url), args.max_lag_hours, args.run_url))
    except OSError as error:  # urllib.error.URLError and HTTPError; the next check runs in 30 minutes
        print(f"::warning::GitHub API error, skipped this check: {error}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
