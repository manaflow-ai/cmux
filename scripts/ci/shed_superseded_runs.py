#!/usr/bin/env python3
"""Cancel queued Actions runs nobody will read: runs of a commit its branch has moved past.

Leo, 2026-11-19: "why are there even 20,000? What are the 20,000 [jobs] doing?" At 20:12Z 28,318 cmux jobs
were queued, 12,848 of them for commits a newer push on the same branch had already replaced. The janitors
that should shed them run on Blacksmith labels and queue behind what they would cancel, and
scripts/ci/queue_janitor.py reads 300 runs per status per sweep, so it never sees a backlog of thousands.

One sweep (.github/workflows/ci-shed-superseded-runs.yml, every 10 minutes on an owned runner):
  1. one `git ls-remote --heads` for every branch tip,
  2. every queued run, listing created= windows bisected until each holds at most 1,000 results
     (GitHub's cap on a filtered run listing),
  3. verdict() per run, then cancels (at most SHED_MAX_CANCELS, default 1500), SHED_CANCEL_SPACING_SECONDS
     apart (default 0.2) against secondary rate limits.

A run is cancelled only when every rule holds (verdict()):
  status queued (never started; in_progress is never touched), run_attempt 1, event push or pull_request,
  head in this repository, branch not main/master/feat-cmux-next/release*/nightly*/gh-pages, workflow name and
  path not nightly/dev/promote/release/testflight/app store/deploy/publish/sign, and then:
    superseded:  the branch tip is another commit,
    branch-gone: the branch no longer exists.
A run at its branch's tip is kept whatever its pull request's state: a host sweep on 2026-11-19 found no queued
pull_request run at a tip without an open pull request, so that check would only cost reads.
Every cancel is one row in the step summary.

usage: shed_superseded_runs.py [--dry-run] [--max N] [--hours H] [--spacing S]
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
import deadline_http  # noqa: E402

API = "https://api.github.com"
LIST_CAP = 1000  # GitHub answers a filtered run listing with at most this many results.
MIN_WINDOW = dt.timedelta(seconds=2)
MAX_DEPTH = 16

PROTECTED_BRANCH = re.compile(r"^(main|master|feat-cmux-next|release.*|nightly.*|gh-pages)$")
PROTECTED_WORKFLOW = re.compile(
    r"nightly|\bdev\b|dev[- ]build|promot|release|testflight|app ?store|deploy|publish|sign", re.I)
SHED_VERDICTS = ("superseded", "branch-gone")


def verdict(run: dict[str, Any], repo: str, tips: dict[str, str]) -> str:
    """Why RUN is kept ("keep:...") or cancelled (one of SHED_VERDICTS). Pure: no I/O.

    tips maps branch name -> tip sha from `git ls-remote --heads`."""
    if run.get("status") != "queued":
        return f"keep:status-{run.get('status')}"
    if (run.get("run_attempt") or 1) > 1:
        return "keep:attempt"
    event = run.get("event")
    if event not in ("push", "pull_request"):
        return f"keep:event-{event}"
    if (run.get("head_repository") or {}).get("full_name") != repo:
        return "keep:fork"
    branch = run.get("head_branch") or ""
    if not branch or PROTECTED_BRANCH.match(branch):
        return "keep:protected-branch"
    if PROTECTED_WORKFLOW.search(run.get("name") or "") or PROTECTED_WORKFLOW.search(run.get("path") or ""):
        return "keep:protected-workflow"
    tip = tips.get(branch)
    if tip is None:
        return "branch-gone"
    if tip != run.get("head_sha"):
        return "superseded"
    return f"keep:current-{event}"


def plan(runs: list[dict[str, Any]], repo: str, tips: dict[str, str],
         max_cancels: int) -> tuple[list[tuple[dict[str, Any], str]], dict[str, int]]:
    """Cancels for this sweep, oldest first and at most max_cancels, plus a count per verdict."""
    unique = {run["id"]: run for run in runs}
    counts: dict[str, int] = {}
    picks: list[tuple[dict[str, Any], str]] = []
    for run in sorted(unique.values(), key=lambda r: (r.get("created_at") or "", r["id"])):
        why = verdict(run, repo, tips)
        counts[why] = counts.get(why, 0) + 1
        if why in SHED_VERDICTS:
            picks.append((run, why))
    return picks[:max(0, max_cancels)], counts


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
        mid = lo + (hi - lo) / 2
        mid = mid.replace(microsecond=0)
        stack.append((mid + dt.timedelta(seconds=1), hi, depth + 1))
        stack.append((lo, mid, depth + 1))
    return out


def parse_ls_remote(text: str) -> dict[str, str]:
    tips: dict[str, str] = {}
    for line in text.splitlines():
        sha, _, ref = line.partition("\t")
        if ref.startswith("refs/heads/"):
            tips[ref.removeprefix("refs/heads/")] = sha.strip()
    return tips


class GitHub:
    def __init__(self, repo: str, token: str) -> None:
        self.repo = repo
        self.token = token
        self.calls = 0
        self.headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "cmux-ci-shed-superseded-runs",
        }
        self._totals: dict[str, dict[str, Any]] = {}

    def request(self, method: str, path: str) -> Any:
        for attempt in range(4):
            self.calls += 1
            req = urllib.request.Request(API + path, headers=self.headers, method=method)
            try:
                status, raw, headers = deadline_http.request(req, 30)
            except (urllib.error.URLError, TimeoutError) as error:
                if attempt < 3:
                    time.sleep(5)
                    continue
                reason = getattr(error, "reason", error)
                raise RuntimeError(f"{method} {path.split('?')[0]} failed ({reason})") from error
            if status < 400:
                return json.loads(raw) if raw else {}
            body = raw.decode(errors="replace")[:300]
            secondary = status in (403, 429) and "secondary" in body.lower()
            if secondary or status in (502, 503, 504):
                time.sleep(min(60, int(headers.get("Retry-After") or 0) or 10 * (attempt + 1)))
                continue
            raise RuntimeError(f"{method} {path.split('?')[0]} failed ({status}): {body}")
        raise RuntimeError(f"{method} {path.split('?')[0]} kept failing")

    def _page(self, lo: dt.datetime, hi: dt.datetime, page: int) -> dict[str, Any]:
        rng = f"{lo:%Y-%m-%dT%H:%M:%SZ}..{hi:%Y-%m-%dT%H:%M:%SZ}"
        query = urllib.parse.urlencode({"status": "queued", "per_page": 100, "page": page, "created": rng})
        return self.request("GET", f"/repos/{self.repo}/actions/runs?{query}")

    def queued_total(self, lo: dt.datetime, hi: dt.datetime) -> int:
        payload = self._page(lo, hi, 1)
        self._totals[f"{lo}|{hi}"] = payload  # page 1 is reused by queued_runs, so bisection costs no extra read
        return int(payload.get("total_count") or 0)

    def queued_runs(self, since: dt.datetime, until: dt.datetime) -> tuple[list[dict[str, Any]], int]:
        runs: list[dict[str, Any]] = []
        failed = 0
        for lo, hi in windows(since, until, self.queued_total):
            first = self._totals.pop(f"{lo}|{hi}", None) or self._page(lo, hi, 1)
            batch = first.get("workflow_runs") or []
            runs += batch
            pages = min(LIST_CAP // 100, (int(first.get("total_count") or 0) + 99) // 100)
            for page in range(2, pages + 1):
                try:
                    batch = self._page(lo, hi, page).get("workflow_runs") or []
                except RuntimeError as error:
                    print(f"::warning::{error}", file=sys.stderr)
                    failed += 1
                    break
                runs += batch
                if len(batch) < 100:
                    break
        return runs, failed

    def cancel(self, run_id: int) -> None:
        self.request("POST", f"/repos/{self.repo}/actions/runs/{run_id}/cancel")

    def branch_tips(self) -> dict[str, str]:
        auth = base64.b64encode(f"x-access-token:{self.token}".encode()).decode()
        env = {**os.environ, "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "http.extraheader",
               "GIT_CONFIG_VALUE_0": f"AUTHORIZATION: basic {auth}", "GIT_TERMINAL_PROMPT": "0"}
        last = ""
        for _ in range(3):
            proc = subprocess.run(["git", "ls-remote", "--heads", f"https://github.com/{self.repo}.git"],
                                  capture_output=True, text=True, env=env, timeout=120)
            tips = parse_ls_remote(proc.stdout) if proc.returncode == 0 else {}
            if tips:
                return tips
            last = proc.stderr.strip()[:200]
            time.sleep(10)
        raise SystemExit(f"git ls-remote failed: {last}")


def summary_line(text: str) -> None:
    print(text)
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with Path(path).open("a", encoding="utf-8") as handle:
            handle.write(text + "\n")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", default=os.environ.get("DRY_RUN") == "true")
    ap.add_argument("--max", type=int, default=int(os.environ.get("SHED_MAX_CANCELS") or 1500))
    ap.add_argument("--hours", type=float, default=float(os.environ.get("SHED_LOOKBACK_HOURS") or 72))
    ap.add_argument("--spacing", type=float, default=float(os.environ.get("SHED_CANCEL_SPACING_SECONDS") or 0.2))
    args = ap.parse_args(argv)
    repo = os.environ["GH_REPO"]
    gh = GitHub(repo, os.environ["GH_TOKEN"])

    # `now` is taken before the tips are read and bounds the listing, so every listed run was created before
    # the ls-remote: a branch missing from it was deleted, and a tip that differs is a newer push.
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    tips = gh.branch_tips()
    runs, failed_pages = gh.queued_runs(now - dt.timedelta(hours=args.hours), now)
    picks, counts = plan(runs, repo, tips, args.max)
    eligible = sum(n for why, n in counts.items() if why in SHED_VERDICTS)

    summary_line(f"## Shed queued runs on superseded heads{' (dry run)' if args.dry_run else ''}\n")
    summary_line(f"{len({r['id'] for r in runs})} queued runs read ({failed_pages} listing pages failed), "
                 f"{len(tips)} branches; {eligible} to shed, cap {args.max}.\n")
    summary_line("| verdict | runs |\n|---|---|")
    for why, n in sorted(counts.items(), key=lambda kv: -kv[1]):
        summary_line(f"| {why} | {n} |")
    summary_line("\n| run | workflow | event | branch | sha | created | why | result |\n|---|---|---|---|---|---|---|---|")
    done = errors = 0
    for run, why in picks:
        result = "dry run"
        if not args.dry_run:
            try:
                gh.cancel(run["id"])
                done += 1
                result = "cancelled"
            except RuntimeError as error:
                errors += 1
                result = f"error: {str(error)[:80]}"
                if "rate limit" in str(error).lower() and "secondary" not in str(error).lower():
                    summary_line(f"| {run['id']} | | | | | | {why} | {result} (stopping) |")
                    break
            time.sleep(args.spacing)
        summary_line(f"| [{run['id']}]({run.get('html_url', '')}) | {(run.get('name') or '').replace('|', '/')} "
                     f"| {run.get('event')} | {run.get('head_branch')} | {(run.get('head_sha') or '')[:10]} "
                     f"| {run.get('created_at')} | {why} | {result} |")
    summary_line(f"\ncancelled {done}, errors {errors}, candidates {eligible}, API calls {gh.calls}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
