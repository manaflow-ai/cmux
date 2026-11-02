#!/usr/bin/env python3
"""Coalesce feat-cmux-next's base Mac tier: at most one run per WINDOW, at the tip.

Leo (2026-10-30, on the fleet dashboard): "do we REALLY need to be compiling/testing THAT often...?"
feat-cmux-next took 557 pushes in a day, a median 1.4 minutes apart, and each one ran the base Mac
tier (daemon tests, generated files, the Debug app scheme compile). 203 Mac hours of it started after
a newer landing already existed (cmuxterm-hq#5424). So a push no longer runs those three. This kick,
started by every push, dispatches one `cmux-next base tier · <tip>` run of cmux-next.yml
(inputs.base_tier) at most once per WINDOW, at the tip it reads then, and only when a file
cmux-next.yml's push paths name changed since the last base tier run. Its tip contains every landing
before it, so each landing gets a base-tier run within WINDOW of landing.

Never touched: the Release compile and its fleet fast check (nightly-next's input), the DEV landing
compile, the DEV daily, the fast tier and every nightly, DEV or promote build. They still run per push.

    cmux_next_base_tier.py defer ROUTE_OUTPUT [--keep TIER]
                                                   path_route on a feat-cmux-next push: the router's
                                                   key=value outputs with the base tier's tiers off
    cmux_next_base_tier.py kick [--window S]       cmux-next-base-tier-kick.yml: wait until the window
                                                   opens, then dispatch the base tier at the tip if due

The kick runs serialized (its workflow's concurrency group, cancel-in-progress false): one waits for
the window and the newest pending one replaces older pending ones, which never started. It waits once
(one sleep, never a polling loop), reads the tip, and dispatches.

Once the tip has a base tier run, an older base tier run none of whose Mac jobs (MAC_JOBS) has started
and created before the newest base tier run is superseded and the kick cancels it (first attempts
only): the tip's run covers every landing it would have, and
base_red_excuse.py reads the newest base verdict, not a given commit's. With the Mac pools saturated
(2026-10-31) base tier runs waited up to two hours and 682 of their 826 Mac minutes in a day started
after a newer base tier run had been dispatched. A run whose Mac job had started when read is never
cancelled, nor is anything that is not a base tier run (a nightly, DEV or promote build above all).
Needs GH_TOKEN with actions: write and contents: read.
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import re
import sys
import time
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cmux_next_tree_notify import Api, GitHub  # noqa: E402

REPO = "manaflow-ai/cmux"
BRANCH = "feat-cmux-next"
WORKFLOW = "cmux-next.yml"
# cmux-next.yml's run-name for a base tier run (and its same-tree run): base_red_excuse.py,
# push attribution and this kick look runs up by it.
TITLE = "cmux-next base tier · "
# The tiers a feat-cmux-next push leaves to the base tier run (path_route outputs).
TIERS = ("daemon", "scheme", "generated")
WINDOW_S = 15 * 60
# After a dispatch: long enough that the next kick's listing shows the new run.
SETTLE_S = 20
# The compare API lists at most this many files; a longer diff counts as relevant.
COMPARE_FILES_MAX = 300
# The base tier's Mac jobs (cmux-next.yml's daemon-test, generated-files and cmux-scheme-compile names).
# A base tier run where one of these has started (or finished) is never cancelled.
MAC_JOBS = ("cmux-next daemon tests", "cmux-next generated files", "cmux app scheme compile (Debug)")
# A run in one of these states has not finished.
OPEN = ("queued", "in_progress", "waiting", "pending", "requested")
SHA = re.compile(r"^[0-9a-f]{40}$")
ROOT = Path(__file__).resolve().parents[2]


def defer(lines: list[str], keep: tuple[str, ...] = ()) -> list[str]:
    """The router's key=value lines with TIERS (but KEEP) off, and base_tier=deferred when one was on."""
    out, deferred = [], []
    for line in lines:
        key, sep, value = line.partition("=")
        if sep and key in TIERS and key not in keep:
            if value == "true":
                deferred.append(key)
            line = f"{key}=false"
        out.append(line)
    out.append(f"base_tier={'deferred' if deferred else 'none'}")
    out.append(f"base_tier_deferred={','.join(deferred)}")
    return out


def push_paths(workflow_text: str) -> list[str]:
    """cmux-next.yml's `on: push: paths:` patterns, in order."""
    lines = workflow_text.splitlines()
    try:
        start = lines.index("  push:")
    except ValueError:
        return []
    out, in_paths = [], False
    for line in lines[start + 1:]:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        if indent <= 2:
            break
        if indent == 4:
            in_paths = line.strip() == "paths:"
            continue
        if in_paths and line.strip().startswith("- "):
            out.append(line.strip()[2:].strip().strip("'\""))
    return out


def glob_regex(pattern: str) -> re.Pattern[str]:
    """GitHub's path filter glob: `**` crosses directories, `*` and `?` do not."""
    out, i = [], 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("".join(out) + r"\Z")


def matches(path: str, patterns: list[str]) -> bool:
    """Whether GitHub's push path filter would start a run for a change to PATH (a later `!` wins)."""
    hit = False
    for pattern in patterns:
        negated = pattern.startswith("!")
        if glob_regex(pattern[1:] if negated else pattern).match(path):
            hit = not negated
    return hit


def stamp(value: str) -> float:
    return dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc).timestamp()


def base_tier_runs(api: Api, repo: str) -> dict[str, float]:
    """sha -> when its first base tier run was created (a same-tree rerun of it comes later)."""
    listed = api.get(f"repos/{repo}/actions/workflows/{WORKFLOW}/runs?branch={BRANCH}"
                     f"&event=workflow_dispatch&per_page=100")
    firsts: dict[str, float] = {}
    for run in listed.get("workflow_runs") or []:
        title = run.get("display_title") or run.get("name") or ""
        sha = title[len(TITLE):].strip() if title.startswith(TITLE) else ""
        if not SHA.match(sha) or not run.get("created_at"):
            continue
        at = stamp(run["created_at"])
        firsts[sha] = min(at, firsts.get(sha, at))
    return firsts


def mac_job_started(api: Api, repo: str, run_id: int) -> bool:
    """Whether a Mac job of the base tier run has started. Anything unreadable counts as started."""
    try:
        listed = api.get(f"repos/{repo}/actions/runs/{run_id}/jobs?filter=latest&per_page=100")
    except RuntimeError:
        return True
    for job in listed.get("jobs") or []:
        if job.get("name") not in MAC_JOBS:
            continue
        if job.get("status") == "in_progress":
            return True
        if job.get("status") == "completed" and job.get("conclusion") not in ("skipped", "cancelled"):
            return True
    return False


def cancel_superseded(api: Api, repo: str, newest: str, log: Callable[[str], None] = print) -> list[int]:
    """Cancel the open base tier runs that a newer base tier run supersedes and whose Mac jobs have not
    started; returns their ids. A run is superseded only when it was created before the newest listed
    base tier run and names another commit than that run and than NEWEST (the tip read before the
    dispatch): a run the dispatch titled with a commit that landed after that read is the newest listed,
    so it is kept. First attempts only (a re-run may have finished its Mac jobs in an earlier attempt).
    Finished runs, runs whose Mac job started and every other workflow's or title's runs are left alone.
    Each run's jobs are read just before its cancel; a Mac job that starts in the instant between that
    read and the cancel loses seconds of superseded work, never a verdict anything waits on."""
    listed = api.get(f"repos/{repo}/actions/workflows/{WORKFLOW}/runs?branch={BRANCH}"
                     f"&event=workflow_dispatch&per_page=100")
    tier_runs = []
    for run in listed.get("workflow_runs") or []:
        title = run.get("display_title") or run.get("name") or ""
        sha = title[len(TITLE):].strip() if title.startswith(TITLE) else ""
        if SHA.match(sha) and run.get("created_at"):
            tier_runs.append((stamp(run["created_at"]), sha, run))
    if not tier_runs:
        return []
    latest_at, latest_sha, _ = max(tier_runs, key=lambda item: item[0])
    keep = {newest, latest_sha}
    cancelled: list[int] = []
    for at, sha, run in tier_runs:
        run_id = run.get("id")
        if (sha in keep or at >= latest_at or not isinstance(run_id, int) or run.get("status") not in OPEN
                or run.get("run_attempt", 1) != 1):
            continue
        if mac_job_started(api, repo, run_id):
            log(f"base tier run {run_id} ({sha[:12]}) has a Mac job running or done; left alone")
            continue
        status = api.post(f"repos/{repo}/actions/runs/{run_id}/cancel", {})
        if status in (202, 204):
            cancelled.append(run_id)
            log(f"cancelled base tier run {run_id} ({sha[:12]}): superseded by {latest_sha[:12]}, no Mac job started")
        else:
            log(f"could not cancel base tier run {run_id} ({sha[:12]}): HTTP {status}")
    return cancelled


def relevant(api: Api, repo: str, since: str, tip: str, patterns: list[str]) -> tuple[bool, str]:
    """Whether a file the push paths name changed in since..tip. Anything unreadable is relevant."""
    if not patterns:
        return True, "no push paths read; running the base tier"
    try:
        compare = api.get(f"repos/{repo}/compare/{since}...{tip}")
    except RuntimeError as error:
        return True, f"could not compare {since[:12]}...{tip[:12]} ({error}); running the base tier"
    files = [item.get("filename") or "" for item in compare.get("files") or []]
    if compare.get("status") not in ("ahead", "identical") or len(files) >= COMPARE_FILES_MAX:
        return True, f"{since[:12]}...{tip[:12]} is {compare.get('status')} with {len(files)} files; running the base tier"
    hit = next((path for path in files if matches(path, patterns)), None)
    if hit:
        return True, f"{hit} changed since {since[:12]}"
    return False, f"no cmux-next push path changed since the last base tier run at {since[:12]} ({len(files)} files)"


def kick(api: Api, repo: str, patterns: list[str], *, window: float = WINDOW_S,
         now: Callable[[], float] = time.time, sleep: Callable[[float], None] = time.sleep,
         log: Callable[[str], None] = print) -> str | None:
    """Dispatch the base tier at the tip when it is due; returns the sha it asked for, or None."""
    firsts = base_tier_runs(api, repo)
    last_sha, last_at = max(firsts.items(), key=lambda item: item[1]) if firsts else (None, None)
    if last_at is not None and (wait := last_at + window - now()) > 0:
        wait = min(wait, window)
        log(f"the last base tier run ({last_sha[:12]}) started {int(window - wait)} s ago; "
            f"waiting {int(wait)} s for the window to open")
        sleep(wait)
        seen_at = last_at
        firsts = base_tier_runs(api, repo)  # what landed while it waited (a hand dispatch)
        last_sha, last_at = max(firsts.items(), key=lambda item: item[1])
        # A hand dispatch may have started during our sleep. It owns a fresh
        # window, so the older run's deadline must not buy another Mac tier.
        # The next queued kick will handle pushes made after that dispatch.
        # Only a run created after the one seen before the sleep counts: the
        # local clock may be behind GitHub's created_at (skew), so comparing
        # the run seen before the sleep against now() would skip every kick.
        if last_at > seen_at:
            log(f"a newer base tier run ({last_sha[:12]}) started during the wait; "
                "leaving its full window to the next kick")
            # It still supersedes the older runs no Mac has started; with no
            # later push, no other kick would cancel them.
            cancel_superseded(api, repo, last_sha, log)
            return None
    tip = (api.get(f"repos/{repo}/git/ref/heads/{BRANCH}").get("object") or {}).get("sha") or ""
    if not SHA.match(tip):
        raise RuntimeError(f"could not read the {BRANCH} tip")
    if tip in firsts:
        log(f"{BRANCH} {tip[:12]} already has a base tier run; nothing to dispatch")
        cancel_superseded(api, repo, tip, log)
        return None
    if last_sha is not None:
        due, why = relevant(api, repo, last_sha, tip, patterns)
        log(why)
        if not due:
            return None
    status = api.post(f"repos/{repo}/actions/workflows/{WORKFLOW}/dispatches",
                      {"ref": f"refs/heads/{BRANCH}", "inputs": {"base_tier": "true"}})
    if status != 204:
        raise RuntimeError(f"the base tier dispatch was refused (HTTP {status})")
    log(f"dispatched the base tier on {BRANCH} at {tip[:12]}")
    sleep(SETTLE_S)
    cancel_superseded(api, repo, tip, log)
    return tip


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    defer_cmd = sub.add_parser("defer")
    defer_cmd.add_argument("route_output", type=Path)
    defer_cmd.add_argument("--keep", action="append", choices=TIERS, default=[],
                           help="a tier the push still runs (scheme: it is the DEV landing build)")
    kick_cmd = sub.add_parser("kick")
    kick_cmd.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", REPO))
    kick_cmd.add_argument("--window", type=float, default=float(os.environ.get("BASE_TIER_WINDOW_S") or WINDOW_S))
    kick_cmd.add_argument("--workflow-file", type=Path, default=ROOT / ".github/workflows" / WORKFLOW)
    args = parser.parse_args(argv)
    if args.command == "defer":
        lines = [line for line in args.route_output.read_text(encoding="utf-8").splitlines() if line]
        print("\n".join(defer(lines, tuple(args.keep))))
        return 0
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
    if not token:
        print("error: GH_TOKEN is not set", file=sys.stderr)
        return 2
    patterns = push_paths(args.workflow_file.read_text(encoding="utf-8")) if args.workflow_file.is_file() else []
    kick(GitHub(token), args.repo, patterns, window=max(0.0, args.window))
    return 0


if __name__ == "__main__":
    sys.exit(main())
