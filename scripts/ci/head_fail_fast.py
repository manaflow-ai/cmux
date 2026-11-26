#!/usr/bin/env python3
"""Head fail-fast: when a pull request job fails red of its own, cancel that head's other heavy runs still queued or
running, and say so in the check summary.

Leo, 2026-11-21: "de facto, im asking for 99% fewer minutes of ci time, period." (cmuxterm-hq
goals/ci-runner-min-per-day-10k.md, cut 5: "stop sibling jobs when a required one fails").

Measured over 2026-11-23T20..2026-11-24T20Z (controller timing feed, manaflow-ai/cmux pull request jobs): once a
non-advisory job of a head had failed, that head's other jobs kept running for 238,776 runner-min a day
(failure 62,189, cancelled 39,836, success 136,751). A red head never lands as it is: its author pushes a fix, and
the new head runs every workflow again. The minutes spent after the first red bought nothing.

A failed job's workflow calls head-fail-fast.yml with a caller job that `needs:` only that job (so it starts the
moment that job fails, not when its whole run ends). This script then:
1. lists the failed jobs of the caller's run attempt (advisory, autofix and comment jobs, and its own, left out);
2. asks base_red_skip.base_verdict whether each is red on the base right now. A red the base shares is excused by
   gh-merge-green / land-judge's base-red rule, and the head can still land once its other checks are green, so
   when EVERY failed job is red on the base nothing is cancelled. A failed job that is green on the base, or has no
   base verdict, is this head's own red;
3. cancels the head's other pull_request runs of the HEAVY workflows that are still queued or running (never the
   caller's own run: cancelling it would turn the failed check's run into a cancelled one, and the failed check must
   stay what the head shows), and writes which check failed and which runs it cancelled into the step summary.

What it never does: cancel a run of a workflow outside HEAVY (routers, autofix, size budget, body checks: an edit or
a repair can turn those green with no new push), cancel anything on a push, dispatch or schedule run, or on a head
labeled full-ci, or touch a fork's pull request (its token cannot write). Every read or cancel that fails is a
notice and the job passes: the step fails open, and the failed check stays the head's verdict.

A cancelled check has no verdict: after a flake rerun of the failed run turns it green, land-judge asks for the
cancelled runs' rerun (`gh run rerun ID --failed`). `vars.CI_HEAD_FAIL_FAST == '0'` turns this off everywhere (the
callers read format('{0}', vars.CI_HEAD_FAIL_FAST) != '0').

usage:
  head_fail_fast.py cancel --workflow FILE [--base feat-cmux-next] [--base-events push] [--dispatch-title PREFIX]
      [--dry-run]
Environment: GITHUB_REPOSITORY, GH_TOKEN (actions: write), GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT, GITHUB_EVENT_NAME,
HEAD_SHA (the pull request head), GITHUB_STEP_SUMMARY (optional), GITHUB_SERVER_URL (optional).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import base_red_skip  # noqa: E402
import deadline_http  # noqa: E402

API = os.environ.get("GITHUB_API_URL", "https://api.github.com")
DEADLINE_S = 60.0
FAILED = ("failure", "timed_out")
UNFINISHED = ("queued", "in_progress", "waiting", "requested", "pending")
# Not a head's verdict: the same jobs time-to-answer leaves out (cmuxterm-hq build-fleet/data/ci_per_pr.py
# TTA_ADVISORY), and this workflow's own job.
ADVISORY = re.compile(r"advisory|autofix|/ comment$|^comment$|head fail-fast", re.I)
# The workflows whose runs are cancelled: the heavy pull request suites, by runner-minutes after a first red on
# 2026-11-24 (ci.yml 39.6k, cmux-next.yml 30.6k, guards 6.9k, fast gates 4.7k, chat-open 4.6k, backend 4.4k, ...).
# A workflow a body edit, a label or a repair re-judges without a new push is not here.
HEAVY = frozenset({
    "ci.yml",
    "cmux-next.yml",
    "cmux-next-guards.yml",
    "cmux-next-fast-gates.yml",
    "chat-open-perf-report.yml",
    "backend.yml",
    "cmux-tui-spec.yml",
    "cmux-next-hot-verify.yml",
    "ios-reliability-matrix.yml",
    "test-ios.yml",
    "cmux-next-ios-kit.yml",
    "cloud-journey-pr.yml",
    "cmux-tui-artifacts.yml",
    "cmux-next-terminal.yml",
    "rust-workspaces.yml",
    "cmux-tui-sdks.yml",
})


def _request(method: str, path: str, token: str, deadline: deadline_http.Deadline):
    req = urllib.request.Request(f"{API}{path}", method=method, headers={
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    status, body, _ = deadline_http.request(req, deadline=deadline)
    return status, body


def failed_jobs(repo: str, run_id: str, attempt: str, read) -> list[str]:
    """The names of the failed jobs of RUN_ID's ATTEMPT that are a head's verdict (ADVISORY ones left out)."""
    names: list[str] = []
    for page in range(1, 6):
        got = read(f"/repos/{repo}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100&page={page}")
        jobs = got.get("jobs") or []
        for job in jobs:
            name = job.get("name") or ""
            if job.get("conclusion") in FAILED and name and not ADVISORY.search(name):
                names.append(name)
        if len(jobs) < 100:
            break
    return names


def own_reds(failed: list[str], verdict) -> tuple[list[str], list[tuple[str, str]]]:
    """(the failed jobs that are this head's own red, [(failed job, base run url)] of those red on the base too).
    VERDICT(name) -> (red | None, url), base_red_skip.base_verdict's answer; one that raises is an own red."""
    own: list[str] = []
    shared: list[tuple[str, str]] = []
    for name in failed:
        try:
            red, url = verdict(name)
        except Exception:  # noqa: BLE001  (an unread base is no excuse: the head's own red)
            red, url = None, ""
        if red:
            shared.append((name, url))
        else:
            own.append(name)
    return own, shared


def targets(runs: list[dict], own_run: str) -> list[dict]:
    """The runs to cancel: unfinished pull_request runs of a HEAVY workflow, never OWN_RUN."""
    out = []
    for run in runs:
        if str(run.get("id")) == str(own_run) or run.get("status") not in UNFINISHED:
            continue
        if run.get("event") != "pull_request":
            continue
        if os.path.basename(run.get("path") or "").split("@")[0] not in HEAVY:
            continue
        out.append(run)
    return out


def head_runs(repo: str, head: str, read) -> list[dict]:
    runs: list[dict] = []
    for page in range(1, 4):
        query = urllib.parse.urlencode({"head_sha": head, "event": "pull_request", "per_page": 100, "page": page})
        got = read(f"/repos/{repo}/actions/runs?{query}")
        batch = got.get("workflow_runs") or []
        runs.extend(batch)
        if len(batch) < 100:
            break
    return runs


def summary(head: str, base: str, own: list[str], shared: list[tuple[str, str]], cancelled: list[dict],
            failed_cancels: list[tuple[dict, str]], dry_run: bool) -> str:
    lines = ["### Head fail-fast", ""]
    if not own:
        lines.append(f"Every failed job is red on `{base}` too, so nothing was cancelled: land-judge excuses a red "
                     "the base shares, and this head can still land once its other checks are green.")
        lines += [f"- `{name}`: red on the base ({url or 'base run'})" for name, url in shared]
        return "\n".join(lines) + "\n"
    lines.append(f"Failed at `{head[:12]}` and not red on `{base}`: " + ", ".join(f"`{n}`" for n in own) + ".")
    lines.append("")
    lines.append("This head cannot land as it is, so its other heavy runs still queued or running were "
                 + ("**would be** cancelled (dry run)" if dry_run else "cancelled") + " to stop spending runner "
                 "minutes on it. The failed check above is the verdict; the cancelled ones have none.")
    lines.append("")
    if cancelled:
        lines += [f"- [{run.get('name') or run.get('path')}]({run.get('html_url', '')}) ({run.get('status')})"
                  for run in cancelled]
    else:
        lines.append("- none: no other heavy run of this head was still queued or running.")
    if failed_cancels:
        lines.append("")
        lines += [f"- not cancelled ({why}): [{run.get('name')}]({run.get('html_url', '')})"
                  for run, why in failed_cancels]
    lines += ["", "Push a fix (the new head runs everything). After a flake rerun of the failed run, rerun the "
              "cancelled ones with `gh run rerun ID --failed`. `vars.CI_HEAD_FAIL_FAST=0` turns this off "
              "(scripts/ci/head_fail_fast.py)."]
    return "\n".join(lines) + "\n"


def cancel(args, env=os.environ, read=None, post=None) -> tuple[int, str]:
    """(cancelled count, the summary markdown)."""
    if env.get("GITHUB_EVENT_NAME") != "pull_request":
        return 0, "### Head fail-fast\n\nNot a pull_request run: nothing cancelled.\n"
    repo = env.get("GITHUB_REPOSITORY", "")
    token = env.get("GH_TOKEN") or env.get("GITHUB_TOKEN") or ""
    run_id = env.get("GITHUB_RUN_ID", "")
    attempt = env.get("GITHUB_RUN_ATTEMPT", "1")
    head = env.get("HEAD_SHA", "")
    deadline = deadline_http.Deadline(DEADLINE_S)
    if read is None:
        def read(path):
            status, body = _request("GET", path, token, deadline)
            if status != 200:
                raise RuntimeError(f"GET {path}: HTTP {status}")
            return json.loads(body)
    if post is None:
        def post(path):
            return _request("POST", path, token, deadline)[0]
    failed = failed_jobs(repo, run_id, attempt, read)
    if not failed:
        return 0, "### Head fail-fast\n\nNo failed blocking job in this run: nothing cancelled.\n"
    events = tuple(e.strip() for e in (args.base_events or "push").split(",") if e.strip()) or ("push",)
    own, shared = own_reds(failed, lambda name: base_red_skip.base_verdict(
        repo, args.workflow, name, args.base, 6, read, events=events, dispatch_title=args.dispatch_title or ""))
    if not own:
        return 0, summary(head, args.base, own, shared, [], [], args.dry_run)
    done: list[dict] = []
    refused: list[tuple[dict, str]] = []
    for run in targets(head_runs(repo, head, read), run_id):
        if args.dry_run:
            done.append(run)
            continue
        try:
            status = post(f"/repos/{repo}/actions/runs/{run['id']}/cancel")
        except Exception as err:  # noqa: BLE001  (fail open: the failed check is still the verdict)
            refused.append((run, str(err)))
            continue
        if status in (202, 200):
            done.append(run)
        elif status != 409:  # 409: it finished meanwhile
            refused.append((run, f"HTTP {status}"))
    return len(done), summary(head, args.base, own, shared, done, refused, args.dry_run)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("cancel")
    c.add_argument("--workflow", required=True, help="the caller's workflow file name, e.g. cmux-next.yml")
    c.add_argument("--base", default="feat-cmux-next")
    c.add_argument("--base-events", default="push", help="comma-separated base run events (base_red_skip)")
    c.add_argument("--dispatch-title", default="", help="keep only dispatched base runs whose title starts with this")
    c.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    try:
        count, text = cancel(args)
    except Exception as err:  # noqa: BLE001  (fail open)
        print(f"::notice title=head fail-fast::not run ({err}); the failed check is still this head's verdict")
        return 0
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(text)
    print(text)
    if count:
        print(f"::notice title=head fail-fast::cancelled {count} other heavy run(s) of this head after its own red "
              "(see the job summary)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
