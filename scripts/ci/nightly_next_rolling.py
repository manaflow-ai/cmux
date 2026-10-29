#!/usr/bin/env python3
"""The nightly-next tick's rolling rule: promote now, or let a running build cover the wait.

The tick (nightly-next-tick.yml) runs at landing (a feat-cmux-next Release
compile or cmux-tui tree finishing), when a nightly-next build finishes, and on
a 10-minute backstop cron. Promoting on every one of those would start a
Release build per landing, which is what six concurrent builds on 2026-10-28
came from. Waiting for a 30-minute cron instead kept the feed 45-50 minutes
behind each landing. The rule in between (Leo, 2026-10-28: "every 30 mins or so
you do it / within 30min you replace"; rulebook, Nightly freshness: "a newer tip
builds alongside a running one instead of waiting behind it"):

- nothing is building the newest nightly-next commit: promote now, so a landing
  on a quiet branch starts its build within minutes;
- a build is running: promote once the oldest feat-cmux-next commit it does not
  carry has waited --window-minutes (10). A burst of landings becomes one build
  of the newest tip, started beside the running one, never cancelling it. The
  window bounds the builds that run at once to about one per 10 minutes of
  build time, and keeps landing-to-feed under the feed watch's 30 minutes once
  a build takes under ~15.

"Building" uses nightly_next_feed_watch.run_is_building: a run whose
publication job finished, or that has sat 10 minutes with nothing running and
every queued job without a runner, is not building anything. A promotion run on
main that is still moving nightly-next counts as building for --promotion-minutes.

A dispatch for one commit (a person, or the feed watch's starvation guard) never
reaches this rule: the tick runs it only when its `sha` input is empty.

Any read that fails answers "go": the promotion is the step that already ignores
a request that does not move nightly-next forward, so failing open costs at most
one extra build, while failing closed could hold the feed.

usage: nightly_next_rolling.py --repo OWNER/NAME [--checkout DIR] [--window-minutes 10]
Writes go=true|false and reason=... to $GITHUB_OUTPUT when it is set.
"""
from __future__ import annotations

import argparse
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.parse

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("nightly_next_feed_watch", HERE / "nightly_next_feed_watch.py")
watch = importlib.util.module_from_spec(_spec)
sys.modules.setdefault("nightly_next_feed_watch", watch)
_spec.loader.exec_module(watch)

WINDOW_MINUTES = 10.0
# A promotion run is created, decides and moves nightly-next in a few minutes;
# one older than this that has not finished is stuck, not about to start a build.
PROMOTION_MINUTES = 15.0
PROMOTION_TITLE = "Promote nightly-next to"
# A nightly run outlives its timeouts by less than this; an older one is not building.
RUN_LOOKBACK = dt.timedelta(hours=3)


def decide(now: dt.datetime, *, head: str, head_runs: list[dict], jobs_of,
           promotions: list[dict], oldest_waiting: tuple[str, dt.datetime] | None,
           window_minutes: float = WINDOW_MINUTES,
           promotion_minutes: float = PROMOTION_MINUTES) -> tuple[bool, str]:
    """(promote now, why). head: nightly-next's commit; head_runs: nightly.yml runs on nightly-next
    for it; promotions: recent nightly.yml workflow_dispatch runs on main; oldest_waiting: the
    oldest first-parent feat-cmux-next commit after head and when it landed (None when nothing
    waits, or when head is not in the branch's history)."""
    if not head:
        return True, "nightly-next is unreadable; asking as before"
    building = ""
    for run in promotions:
        if not (run.get("display_title") or "").startswith(PROMOTION_TITLE) or run.get("status") == "completed":
            continue
        try:
            age = (now - watch.parse_time(run["created_at"])).total_seconds() / 60
        except (KeyError, TypeError, ValueError):
            continue
        if age < promotion_minutes:
            building = f"promotion run {run.get('html_url', run.get('id'))} is moving nightly-next"
            break
    if not building:
        for run in head_runs:
            if run.get("status") == "completed":
                continue
            try:
                if now - watch.parse_time(run["created_at"]) > RUN_LOOKBACK:
                    continue
            except (KeyError, TypeError, ValueError):
                pass
            if watch.run_is_building(run, jobs_of(run), now):
                building = f"nightly-next run {run.get('html_url', run.get('id'))} is building {head[:12]}"
                break
    if not building:
        return True, f"nothing is building nightly-next ({head[:12]}); promoting the newest buildable commit now"
    if oldest_waiting is None:
        return True, f"{building}, and no commit after it is known to wait; asking anyway"
    sha, landed = oldest_waiting
    waited = (now - landed).total_seconds() / 60
    if waited >= window_minutes:
        return True, (f"{building}, and {sha[:12]} has waited {waited:.0f} min "
                      f"(rolling window {window_minutes:g}); a newer build starts beside it")
    return False, (f"{building}; the oldest waiting landing {sha[:12]} has waited {waited:.0f} of "
                   f"{window_minutes:g} min, so the next landing, a finished build or the backstop cron asks again")


def git(checkout: str, *args: str) -> str:
    return subprocess.run(["git", "-C", checkout, *args], check=True, capture_output=True, text=True).stdout.strip()


def oldest_after(checkout: str, head: str) -> tuple[str, dt.datetime] | None:
    """The oldest first-parent commit after head on the checked-out branch, and its committer date
    (squash merges set it at landing). None when head is not in this history."""
    try:
        if subprocess.run(["git", "-C", checkout, "merge-base", "--is-ancestor", head, "HEAD"],
                          capture_output=True).returncode != 0:
            return None
        first = git(checkout, "rev-list", "--first-parent", "--reverse", f"{head}..HEAD").split("\n")[0]
        if not first:
            return None
        return first, watch.parse_time(git(checkout, "log", "-1", "--format=%cI", first))
    except (subprocess.CalledProcessError, ValueError):
        return None


def gh_api(path: str):
    out = subprocess.run(["gh", "api", path], check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--checkout", default=".")
    parser.add_argument("--window-minutes", type=float, default=WINDOW_MINUTES)
    args = parser.parse_args(argv)
    now = dt.datetime.now(dt.timezone.utc)
    try:
        line = subprocess.run(["git", "-C", args.checkout, "ls-remote", "origin", "refs/heads/nightly-next"],
                              check=True, capture_output=True, text=True).stdout.split()
        head = line[0] if line else ""
        base = f"repos/{args.repo}/actions/workflows/nightly.yml/runs?"
        head_runs = gh_api(base + urllib.parse.urlencode(
            {"branch": "nightly-next", "head_sha": head, "per_page": 10}))["workflow_runs"] if head else []
        promotions = gh_api(base + urllib.parse.urlencode(
            {"branch": "main", "event": "workflow_dispatch", "per_page": 10}))["workflow_runs"]

        def jobs_of(run: dict) -> list[dict]:
            return gh_api(f"repos/{args.repo}/actions/runs/{run['id']}/jobs?filter=latest&per_page=100")["jobs"]

        go, reason = decide(now, head=head, head_runs=head_runs, jobs_of=jobs_of, promotions=promotions,
                            oldest_waiting=oldest_after(args.checkout, head) if head else None,
                            window_minutes=args.window_minutes)
    except Exception as error:  # noqa: BLE001 - fail open, see the docstring
        go, reason = True, f"could not read the running builds ({error!r}); asking as before"
    print(f"rolling rule: {'promote' if go else 'wait'}: {reason}")
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"go={'true' if go else 'false'}\nreason={reason}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
