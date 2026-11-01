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
  carry has waited --window-minutes (10) and the newest build started at least that
  long ago, so at most one build starts per window and it is the newest tip. A burst of landings becomes one build
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

Every read goes through the API with the job's token (no git remote, no
shallow history). A failed read of nightly-next waits, with a warning: the feed
watch's dispatch for one commit skips this rule, so that costs at most the
backstop's delay. Any other failed read, and a gap to the tip that cannot be
read, promotes, with a warning: the promotion ignores a request that does not
move nightly-next forward.

usage: nightly_next_rolling.py --repo OWNER/NAME --tip SHA [--window-minutes 10]
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
# oldest_after's answer when the gap to the tip cannot be read.
UNKNOWN = "unknown"
# A promotion moves nightly-next in about 20 s and its push run appears within about 20 s more:
# a promotion created this recently counts as a start whatever its status reads, so a run list
# that has not caught up never reads as "nothing is building" (tick 40817979989 at 04:29:13
# promoted again 4 s after the promotion that moved nightly-next, before its run existed).
PROMOTION_RACE_MINUTES = 2.0


def youngest_start(now: dt.datetime, starts: list[dict], promotions: list[dict],
                   promotion_minutes: float = PROMOTION_MINUTES) -> float | None:
    """Minutes since the newest build start: a nightly-next push run's creation, or a promotion that
    may still start one (its run may not be listed yet): one still running and younger than
    `promotion_minutes`, or a finished one younger than PROMOTION_RACE_MINUTES. None when there is
    none."""
    ages = []
    for run in starts:
        try:
            ages.append((now - watch.parse_time(run["created_at"])).total_seconds() / 60)
        except (KeyError, TypeError, ValueError):
            continue
    for run in promotions:
        if not (run.get("display_title") or "").startswith(PROMOTION_TITLE):
            continue
        try:
            age = (now - watch.parse_time(run["created_at"])).total_seconds() / 60
        except (KeyError, TypeError, ValueError):
            continue
        if age < PROMOTION_RACE_MINUTES or (run.get("status") != "completed" and age < promotion_minutes):
            ages.append(age)
    ages = [age for age in ages if age >= 0]
    return min(ages) if ages else None


def decide(now: dt.datetime, *, head: str, head_runs: list[dict], jobs_of,
           promotions: list[dict], oldest_waiting,
           window_minutes: float = WINDOW_MINUTES,
           promotion_minutes: float = PROMOTION_MINUTES,
           starts: list[dict] | None = None) -> tuple[bool, str]:
    """(promote now, why). head: nightly-next's commit; head_runs: nightly.yml runs on nightly-next
    for it; promotions: recent nightly.yml workflow_dispatch runs on main; oldest_waiting: the
    oldest feat-cmux-next commit after head and when it landed, None when nothing waits, or
    UNKNOWN (oldest_after); starts: recent nightly.yml push runs on nightly-next (any commit).

    At most one new build starts per window while builds run, and it is always the newest
    buildable commit (the request walks from the tip). Measuring the window only from landing
    let every tick after a cmux-tui tree stall promote again (2026-10-29 04:25-04:30: three
    starts in four minutes, five builds in flight on contended runners); now the newest start
    must be a window old too. A started build is never cancelled."""
    if not head:
        return True, "nightly-next is unreadable; asking as before"
    building = ""
    since_start = youngest_start(now, starts or [], promotions, promotion_minutes)
    if since_start is not None and since_start < PROMOTION_RACE_MINUTES:
        building = f"a build started {since_start * 60:.0f} s ago"
    for run in promotions if not building else []:
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
        return False, f"{building}, and no feat-cmux-next commit waits after it"
    if since_start is not None and since_start < window_minutes:
        return False, (f"{building}, and the newest build started {since_start:.0f} of {window_minutes:g} min ago; "
                       "the next start, for the newest buildable commit, waits for the window")
    if oldest_waiting == UNKNOWN:
        return True, f"{building}, and the gap to the tip is unknown, so the oldest landing counts as old; promoting"
    sha, landed = oldest_waiting
    waited = (now - landed).total_seconds() / 60
    if waited >= window_minutes:
        return True, (f"{building}, and {sha[:12]} has waited {waited:.0f} min "
                      f"(rolling window {window_minutes:g}); a newer build starts beside it")
    return False, (f"{building}; the oldest waiting landing {sha[:12]} has waited {waited:.0f} of "
                   f"{window_minutes:g} min, so the next landing, a finished build or the backstop cron asks again")


def oldest_after(api, repo: str, head: str, tip: str):
    """The oldest feat-cmux-next commit after nightly-next's head, and when it landed (squash merges
    set the committer date at landing), from the compare API: no shallow checkout is involved.
    None when nothing waits (tip equals or is behind head). UNKNOWN when the gap cannot be read or
    head is not an ancestor of tip (a train commit): `decide` treats that as an old landing."""
    try:
        # Paginated, one commit a page: page 1 is the oldest commit after head. Unpaginated, the
        # API returns at most 250 commits ending at the newest, which misses the oldest landing
        # of a larger gap.
        data = api(f"repos/{repo}/compare/{head}...{tip}?per_page=1&page=1")
    except Exception as error:  # noqa: BLE001 - an unknown gap promotes
        print(f"::warning title=nightly-next rolling rule::could not compare {head[:12]}...{tip[:12]} ({error!r}); "
              "treating the oldest waiting landing as old")
        return UNKNOWN
    status = data.get("status")
    if status in ("identical", "behind"):
        return None
    commits = data.get("commits") or []
    if status != "ahead" or not commits:
        return UNKNOWN
    first = commits[0]
    try:
        return first["sha"], watch.parse_time(first["commit"]["committer"]["date"])
    except (KeyError, TypeError, ValueError):
        return UNKNOWN


def gh_api(path: str):
    out = subprocess.run(["gh", "api", path], check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def evaluate(now: dt.datetime, repo: str, tip: str, api=gh_api,
             window_minutes: float = WINDOW_MINUTES) -> tuple[bool, str]:
    """Read everything through the API (the job's token) and decide.

    nightly-next's head unreadable: wait, with a warning. The rule's purpose is to coalesce, and
    the feed watch (every 10 minutes) dispatches a build for one commit, which skips this rule, so
    a failed read here costs at most that backstop's delay and never a burst of builds. Any other
    failed read promotes, with a warning: the promotion ignores a request that moves nothing."""
    try:
        head = api(f"repos/{repo}/git/ref/heads/nightly-next")["object"]["sha"]
    except Exception as error:  # noqa: BLE001
        print(f"::warning title=nightly-next rolling rule::could not read nightly-next ({error!r}); "
              "waiting for the feed watch's backstop dispatch")
        return False, f"could not read nightly-next ({error!r}); the feed watch's backstop covers this"
    try:
        base = f"repos/{repo}/actions/workflows/nightly.yml/runs?"
        # One listing of nightly-next's recent push runs: its head's runs, and the newest start.
        recent = api(base + urllib.parse.urlencode(
            {"branch": "nightly-next", "event": "push", "per_page": 20}))["workflow_runs"]
    except Exception as error:  # noqa: BLE001
        print(f"::warning title=nightly-next rolling rule::could not read the running builds ({error!r}); promoting")
        return True, f"could not read the running builds ({error!r}); promoting"
    # A start inside the window holds the next one whatever else can be read: a failed read
    # after this point never adds a build beside a start this young.
    since_start = youngest_start(now, recent, [])
    try:
        head_runs = [run for run in recent if (run.get("head_sha") or "").lower() == head.lower()]
        promotions = api(base + urllib.parse.urlencode(
            {"branch": "main", "event": "workflow_dispatch", "per_page": 10}))["workflow_runs"]

        def jobs_of(run: dict) -> list[dict]:
            return api(f"repos/{repo}/actions/runs/{run['id']}/jobs?filter=latest&per_page=100")["jobs"]

        return decide(now, head=head, head_runs=head_runs, jobs_of=jobs_of, promotions=promotions,
                      oldest_waiting=oldest_after(api, repo, head, tip), window_minutes=window_minutes,
                      starts=recent)
    except Exception as error:  # noqa: BLE001
        if since_start is not None and since_start < window_minutes:
            print(f"::warning title=nightly-next rolling rule::could not read the running builds ({error!r}); "
                  f"a build started {since_start:.0f} min ago, so waiting")
            return False, (f"could not read the running builds ({error!r}); the newest build started "
                           f"{since_start:.0f} of {window_minutes:g} min ago, so waiting")
        print(f"::warning title=nightly-next rolling rule::could not read the running builds ({error!r}); promoting")
        return True, f"could not read the running builds ({error!r}); promoting"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--tip", required=True, help="the feat-cmux-next commit the tick checked out")
    parser.add_argument("--window-minutes", type=float, default=WINDOW_MINUTES)
    args = parser.parse_args(argv)
    go, reason = evaluate(dt.datetime.now(dt.timezone.utc), args.repo, args.tip, window_minutes=args.window_minutes)
    print(f"rolling rule: {'promote' if go else 'wait'}: {reason}")
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"go={'true' if go else 'false'}\nreason={reason}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
