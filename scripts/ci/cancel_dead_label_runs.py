#!/usr/bin/env python3
"""Cancel queued Actions runs whose waiting jobs sit on Linux labels that will never start them.

Leo, 2026-11-20: "[we] need to be getting rid of the hardcoded blacksmith jobs [...] blank cheque cancel the
doomed ones, we're scaling with Freestyle and GCP, we just need to go". At 02:39Z 9,067 queued cmux runs held
17,380 jobs on GitHub-hosted `ubuntu-*` labels (hosted runners refused on billing) and on the starved
`blacksmith-8vcpu/16vcpu/32vcpu-ubuntu-*` labels. GitHub never re-routes a queued job, so these runs are
cancelled; the branch's next push runs on the fleet labels. blacksmith-2vcpu/4vcpu drain and are left alone.

One sweep (.github/workflows/ci-cancel-dead-label-runs.yml, every 15 minutes on an owned runner):
  1. every queued run, listing created= windows bisected until each holds at most 1,000 results
     (GitHub's cap on a filtered run listing),
  2. run_keep_reason() per run (no reads), then one `runs/N/jobs?filter=latest` read per remaining run,
  3. decide() per run, then cancel, CANCEL_SPACING_SECONDS apart (default 0.1), at most MAX_CANCELS.
A primary rate-limit 403/429 stops the sweep cleanly and prints the rate-limit headers.

A run is cancelled only when every rule holds:
  - at least one of its jobs is queued on a dead label (DEAD_LABEL_PATTERN) and was created MIN_AGE_MINUTES
    (default 61) or more ago,
  - none of its jobs is in progress,
  - it is not a delivery run (queue_janitor.is_delivery_run, plus a nightly/dev/promote/release/sign/publish
    check on the workflow name and path),
  - it is not the newest head of main or feat-cmux-next.
Every cancel is one row in the step summary.

usage: cancel_dead_label_runs.py [--dry-run] [--max N] [--hours H] [--spacing S] [--min-age M]
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable, Mapping

sys.path.insert(0, str(Path(__file__).resolve().parent))
from queue_janitor import is_delivery_run  # noqa: E402

API = "https://api.github.com"
LIST_CAP = 1000  # GitHub answers a filtered run listing with at most this many results.
MIN_WINDOW = dt.timedelta(seconds=2)
MAX_DEPTH = 16

DEFAULT_DEAD_LABELS = r"^(blacksmith-(8|16|32)vcpu-ubuntu.*|ubuntu-.*)$"
DEFAULT_MIN_AGE_MINUTES = 61
BASE_BRANCHES = ("main", "feat-cmux-next")
PROTECTED_WORKFLOW = re.compile(
    r"nightly|\bdev\b|dev[- ]build|promot|release|testflight|app ?store|deploy|publish|sign", re.I)
RATE_HEADERS = ("x-ratelimit-limit", "x-ratelimit-remaining", "x-ratelimit-used", "x-ratelimit-reset",
                "x-ratelimit-resource", "retry-after")


def parse_time(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def newest_base_heads(runs: list[Mapping[str, Any]], tips: Mapping[str, str]) -> dict[str, set[str]]:
    """Per base branch, the heads that count as its newest: the branch tip and the newest listed run's head."""
    heads: dict[str, set[str]] = {b: {tips[b]} if tips.get(b) else set() for b in BASE_BRANCHES}
    newest: dict[str, tuple[str, str]] = {}
    for run in runs:
        branch = run.get("head_branch")
        if branch in heads:
            created = run.get("created_at") or ""
            if created > newest.get(branch, ("", ""))[0]:
                newest[branch] = (created, run.get("head_sha") or "")
    for branch, (_, sha) in newest.items():
        heads[branch].add(sha)
    return heads


def run_keep_reason(run: Mapping[str, Any], base_heads: Mapping[str, set[str]]) -> str | None:
    """Why RUN is kept before its jobs are read, or None when its jobs decide. Pure: no I/O."""
    if run.get("status") != "queued":
        return f"keep:status-{run.get('status')}"
    if is_delivery_run(run):
        return "keep:delivery"
    if any(PROTECTED_WORKFLOW.search(str(run.get(key) or "")) for key in ("name", "path")):
        return "keep:protected-workflow"
    branch = run.get("head_branch")
    if branch in base_heads and run.get("head_sha") in base_heads[branch]:
        return "keep:newest-base-head"
    return None


def decide(run: Mapping[str, Any], jobs: list[Mapping[str, Any]], base_heads: Mapping[str, set[str]],
           now: dt.datetime, dead: re.Pattern[str],
           min_age_minutes: int = DEFAULT_MIN_AGE_MINUTES) -> tuple[str, dict[str, Any]]:
    """("cancel", detail) or ("keep:<why>", detail) for RUN given its latest jobs. Pure: no I/O.

    detail carries the dead labels and the oldest dead job's queued minutes for the summary row."""
    detail: dict[str, Any] = {"labels": [], "queued_minutes": 0, "dead_jobs": 0}
    why = run_keep_reason(run, base_heads)
    if why:
        return why, detail
    labels: set[str] = set()
    oldest: dt.datetime | None = None
    for job in jobs:
        status = job.get("status")
        if status == "in_progress":
            return "keep:job-in-progress", detail
        if status != "queued":
            continue
        job_labels = [str(lb) for lb in job.get("labels") or []]
        if not any(dead.match(lb) for lb in job_labels):
            continue
        created = parse_time(job.get("created_at"))
        if created is None:
            continue
        detail["dead_jobs"] += 1
        labels.update(lb for lb in job_labels if dead.match(lb))
        oldest = created if oldest is None or created < oldest else oldest
    detail["labels"] = sorted(labels)
    if oldest is None:
        return "keep:no-dead-queued-job", detail
    detail["queued_minutes"] = int((now - oldest).total_seconds() // 60)
    if detail["queued_minutes"] < min_age_minutes:
        return "keep:too-young", detail
    return "cancel", detail


def windows(since: dt.datetime, until: dt.datetime,
            total: Callable[[dt.datetime, dt.datetime], int]) -> list[tuple[dt.datetime, dt.datetime]]:
    """Split since..until (inclusive, whole seconds) until each window's total(...) is at most LIST_CAP."""
    out: list[tuple[dt.datetime, dt.datetime]] = []
    stack = [(since, until, 0)]
    while stack:
        lo, hi, depth = stack.pop()
        if total(lo, hi) <= LIST_CAP or hi - lo < MIN_WINDOW or depth >= MAX_DEPTH:
            out.append((lo, hi))
            continue
        mid = (lo + (hi - lo) / 2).replace(microsecond=0)
        stack.append((mid + dt.timedelta(seconds=1), hi, depth + 1))
        stack.append((lo, mid, depth + 1))
    return out


class RateLimited(RuntimeError):
    """A primary rate limit: the sweep stops; the next one picks up where this one ended."""


class GitHub:
    def __init__(self, repo: str, token: str, spacing: float) -> None:
        self.repo = repo
        self.spacing = spacing
        self.calls = 0
        self.last_headers: dict[str, str] = {}
        self.headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "cmux-ci-cancel-dead-label-runs",
        }
        self._totals: dict[str, dict[str, Any]] = {}

    def _remember(self, headers: Any) -> None:
        self.last_headers = {h: headers.get(h) for h in RATE_HEADERS if headers.get(h) is not None}

    def request(self, method: str, path: str) -> Any:
        for attempt in range(4):
            if self.calls:
                time.sleep(self.spacing)
            self.calls += 1
            req = urllib.request.Request(API + path, headers=self.headers, method=method)
            try:
                with urllib.request.urlopen(req, timeout=30) as response:
                    self._remember(response.headers)
                    raw = response.read()
                    return json.loads(raw) if raw else {}
            except urllib.error.HTTPError as error:
                self._remember(error.headers)
                body = error.read().decode(errors="replace")[:300]
                if error.code in (403, 429):
                    secondary = "secondary" in body.lower()
                    if not secondary and (error.headers.get("x-ratelimit-remaining") == "0"
                                          or "rate limit" in body.lower()):
                        raise RateLimited(f"{method} {path.split('?')[0]}: {error.code} {body}") from error
                    if secondary:
                        time.sleep(min(60, int(error.headers.get("Retry-After") or 0) or 10 * (attempt + 1)))
                        continue
                if error.code in (502, 503, 504):
                    time.sleep(5 * (attempt + 1))
                    continue
                raise RuntimeError(f"{method} {path.split('?')[0]} failed ({error.code}): {body}") from error
            except urllib.error.URLError as error:
                if attempt < 3:
                    time.sleep(5)
                    continue
                raise RuntimeError(f"{method} {path.split('?')[0]} failed ({error.reason})") from error
        raise RuntimeError(f"{method} {path.split('?')[0]} kept failing")

    def _page(self, lo: dt.datetime, hi: dt.datetime, page: int) -> dict[str, Any]:
        rng = f"{lo:%Y-%m-%dT%H:%M:%SZ}..{hi:%Y-%m-%dT%H:%M:%SZ}"
        query = urllib.parse.urlencode({"status": "queued", "per_page": 100, "page": page, "created": rng})
        return self.request("GET", f"/repos/{self.repo}/actions/runs?{query}")

    def queued_total(self, lo: dt.datetime, hi: dt.datetime) -> int:
        payload = self._page(lo, hi, 1)
        self._totals[f"{lo}|{hi}"] = payload  # page 1 is reused by queued_runs, so bisection costs no extra read
        return int(payload.get("total_count") or 0)

    def queued_runs(self, since: dt.datetime, until: dt.datetime) -> list[dict[str, Any]]:
        runs: list[dict[str, Any]] = []
        for lo, hi in windows(since, until, self.queued_total):
            first = self._totals.pop(f"{lo}|{hi}", None) or self._page(lo, hi, 1)
            runs += first.get("workflow_runs") or []
            pages = min(LIST_CAP // 100, (int(first.get("total_count") or 0) + 99) // 100)
            for page in range(2, pages + 1):
                batch = self._page(lo, hi, page).get("workflow_runs") or []
                runs += batch
                if len(batch) < 100:
                    break
        return runs

    def branch_tip(self, branch: str) -> str:
        try:
            return str(((self.request("GET", f"/repos/{self.repo}/branches/{branch}") or {}).get("commit") or {})
                       .get("sha") or "")
        except RuntimeError:
            return ""

    def jobs(self, run_id: int) -> list[dict[str, Any]]:
        return self.request("GET", f"/repos/{self.repo}/actions/runs/{run_id}/jobs?filter=latest&per_page=100"
                            ).get("jobs") or []

    def cancel(self, run_id: int) -> None:
        self.request("POST", f"/repos/{self.repo}/actions/runs/{run_id}/cancel")


def summary_line(text: str) -> None:
    print(text, flush=True)
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with Path(path).open("a", encoding="utf-8") as handle:
            handle.write(text + "\n")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", default=os.environ.get("DRY_RUN") == "true")
    ap.add_argument("--max", type=int, default=int(os.environ.get("MAX_CANCELS") or 3000))
    ap.add_argument("--hours", type=float, default=float(os.environ.get("LOOKBACK_HOURS") or 168))
    ap.add_argument("--spacing", type=float, default=float(os.environ.get("CANCEL_SPACING_SECONDS") or 0.1))
    ap.add_argument("--min-age", type=int,
                    default=int(os.environ.get("MIN_AGE_MINUTES") or DEFAULT_MIN_AGE_MINUTES))
    args = ap.parse_args(argv)
    dead = re.compile(os.environ.get("DEAD_LABEL_PATTERN") or DEFAULT_DEAD_LABELS)
    repo = os.environ["GH_REPO"]
    gh = GitHub(repo, os.environ["GH_TOKEN"], args.spacing)

    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    summary_line(f"## Cancel queued runs on dead labels{' (dry run)' if args.dry_run else ''}\n")
    tips = {b: gh.branch_tip(b) for b in BASE_BRANCHES}
    summary_line(f"GITHUB_TOKEN x-ratelimit-limit: {gh.last_headers.get('x-ratelimit-limit', '?')} "
                 f"(remaining {gh.last_headers.get('x-ratelimit-remaining', '?')}, "
                 f"resource {gh.last_headers.get('x-ratelimit-resource', '?')}); dead labels `{dead.pattern}`, "
                 f"queued {args.min_age}+ min, cap {args.max}.\n")

    counts: dict[str, int] = {}
    done = errors = jobs_read = 0
    stopped = ""
    rows: list[str] = []
    try:
        runs = list({r["id"]: r for r in gh.queued_runs(now - dt.timedelta(hours=args.hours), now)}.values())
        runs.sort(key=lambda r: (r.get("created_at") or "", r["id"]))
        base_heads = newest_base_heads(runs, tips)
        cutoff = now - dt.timedelta(minutes=args.min_age)
        summary_line(f"{len(runs)} queued runs listed.\n")
        for run in runs:
            if done >= args.max:
                stopped = f"cap {args.max} reached"
                break
            why = run_keep_reason(run, base_heads)
            created = parse_time(run.get("created_at"))
            if why is None and created is not None and created > cutoff:
                why = "keep:too-young"  # no job of a run this young can have waited min_age yet
            if why is None:
                jobs_read += 1
                why, detail = decide(run, gh.jobs(run["id"]), base_heads, now, dead, args.min_age)
            counts[why] = counts.get(why, 0) + 1
            if why != "cancel":
                continue
            result = "dry run"
            if not args.dry_run:
                try:
                    gh.cancel(run["id"])
                    done += 1
                    result = "cancelled"
                except RateLimited:
                    raise
                except RuntimeError as error:
                    errors += 1
                    result = f"error: {str(error)[:80]}"
            else:
                done += 1
            rows.append(f"| [{run['id']}]({run.get('html_url', '')}) | {(run.get('name') or '').replace('|', '/')} "
                        f"| {run.get('head_branch')} | {', '.join(detail['labels'])} | {detail['queued_minutes']} "
                        f"| {result} |")
    except RateLimited as error:
        stopped = f"primary rate limit: {str(error)[:160]}"
        print(f"::warning::stopping on a primary rate limit; headers {json.dumps(gh.last_headers)}", flush=True)

    summary_line("| verdict | runs |\n|---|---|")
    for why, n in sorted(counts.items(), key=lambda kv: -kv[1]):
        summary_line(f"| {why} | {n} |")
    summary_line("\n| run | workflow | branch | labels | queued min | result |\n|---|---|---|---|---|---|")
    for row in rows:
        summary_line(row)
    summary_line(f"\n{'would cancel' if args.dry_run else 'cancelled'} {done}, errors {errors}, jobs reads "
                 f"{jobs_read}, API calls {gh.calls}{'; stopped: ' + stopped if stopped else ''}; "
                 f"rate limit now {json.dumps(gh.last_headers)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
