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
- a nightly-next push run is building (any commit's, not only the head's): wait.
  nightly-next pushes share one concurrency group (nightly.yml on feat-cmux-next,
  nightly-build-nightly-next-push, since 2026-11-05), so a promotion beside a
  running build starts nothing beside it: GitHub cancels the run already waiting
  on the group. Promoting every window that way cancelled 13 of 17 nightly-next
  builds on 2026-11-12 00:40-02:56Z (Leo, ask-4f5b99b22b: "I THOUGHT WE FUCKING
  STOPPED DOING THAT BULLSHIT LONG AGO"). The build's own finish starts a tick
  (workflow_run on Nightly macOS build), which promotes the newest tip then, so
  a burst of landings still becomes one build of the newest tip and no build is
  ever cancelled. --window-minutes now only spaces starts when a run list lags.

"Building" means holding the push group (nightly_next_feed_watch.holds_push_group: a
push or the loop's retry dispatch; run_holds_group): a published run still holds it
through its tail, and a run that has sat 10 minutes with nothing running and every
queued job without a runner holds nothing. A promotion run on
main that is still moving nightly-next counts as building for --promotion-minutes.
One exception: a retry of nightly-next's own head while a newer commit waits neither
holds nor counts as a start (retry_of). It leaves the slot only when a newer push
arrives, which waiting for it never let happen (19-41 min per retry, runs
43395284047 and 43440656795), so the rule promotes: a retry not yet past that step
yields, and one past it finishes with the newer push queued behind it, which then
starts at once. Its head is no longer nightly-next's then, so it holds again.

A dispatch for one commit (a person, or the feed watch's starvation guard) never
reaches this rule: the tick runs it only when its `sha` input is empty.

nightly-next's head comes from `git ls-remote` against the public repository
(no token, no API budget: on 2026-11-04 an exhausted installation budget failed
the refs API read and ticks 41791114042 and 41791169626 promoted nothing), and
from the refs API only when that fails. The gap from that head to the tip comes
from the tick's own checkout of feat-cmux-next (git_oldest_after), and from the
compare API only when the head is not in it; a tip already on nightly-next
reads nothing more and waits (there is nothing to promote). Every other read goes through the
API with the job's token. A head neither can read waits, with a
warning: the feed watch's dispatch for one commit skips this rule, so that costs
at most the backstop's delay. Any other failed read, and a gap to the tip that cannot be
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


def retry_of(run: dict, head: str) -> bool:
    """Whether a run is the loop's retry dispatch ('Retry nightly-next (N of 2)') of `head`."""
    return (run.get("event") == "workflow_dispatch" and bool(watch.RETRY_TITLE.match(str(run.get("display_title") or "")))
            and (run.get("head_sha") or "").lower() == head.lower())


def decide(now: dt.datetime, *, head: str, head_runs: list[dict], jobs_of,
           promotions: list[dict], oldest_waiting,
           window_minutes: float = WINDOW_MINUTES,
           promotion_minutes: float = PROMOTION_MINUTES,
           starts: list[dict] | None = None) -> tuple[bool, str]:
    """(promote now, why). head: nightly-next's commit; head_runs: nightly.yml runs on nightly-next
    for it; promotions: recent nightly.yml workflow_dispatch runs on main; oldest_waiting: the
    oldest feat-cmux-next commit after head and when it landed, None when nothing waits, or
    UNKNOWN (oldest_after); starts: recent nightly.yml push runs on nightly-next (any commit).

    No new build starts while a nightly-next push run builds (they share one concurrency group,
    so it could only get the run waiting there cancelled); the next start is the newest
    buildable commit (the request walks from the tip). Measuring the window only from landing
    let every tick after a cmux-tui tree stall promote again (2026-10-29 04:25-04:30: three
    starts in four minutes, five builds in flight on contended runners); now the newest start
    must be a window old too. A started build is never cancelled."""
    if not head:
        return True, "nightly-next is unreadable; asking as before"
    if oldest_waiting is not None:
        # A retry of nightly-next's own head while a newer commit waits rebuilds a commit that already
        # failed, and it leaves the build slot only when a newer push arrives (feat-cmux-next's
        # resolve-leave-build-slot.sh). Waiting for it meant no newer push ever came: 19-41 min per
        # retry (runs 43395284047, 43440656795; tick 43440928169). It is neither a holder nor a start.
        # A retry of an older commit (nightly-next already moved past it) and every push still hold.
        head_runs = [run for run in head_runs if not retry_of(run, head)]
        starts = [run for run in starts or [] if not retry_of(run, head)]
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
        # Every recent push run, not only the head's: an older commit's build holding the push group
        # while the head's run waits on it is the case a promotion would cancel.
        seen = set()
        for run in [*head_runs, *(starts or [])]:
            if run.get("id") in seen or run.get("status") == "completed" or not watch.holds_push_group(run):
                continue
            seen.add(run.get("id"))
            try:
                if now - watch.parse_time(run["created_at"]) > RUN_LOOKBACK:
                    continue
            except (KeyError, TypeError, ValueError):
                pass
            if watch.run_holds_group(run, jobs_of(run), now):
                building = (f"nightly-next run {run.get('html_url', run.get('id'))} is building "
                            f"{(run.get('head_sha') or head)[:12]}")
                break
    if not building:
        return True, f"nothing is building nightly-next ({head[:12]}); promoting the newest buildable commit now"
    if oldest_waiting is None:
        return False, f"{building}, and no feat-cmux-next commit waits after it"
    if since_start is not None and since_start < window_minutes:
        return False, (f"{building}, and the newest build started {since_start:.0f} of {window_minutes:g} min ago; "
                       "the next start, for the newest buildable commit, waits for it to finish")
    return False, (f"{building}; nightly-next pushes share one concurrency group, so a promotion now would get "
                   "the run waiting on it cancelled. Its finish ticks again and promotes the newest tip")


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


def git_oldest_after(head: str, tip: str, git=None):
    """oldest_after from the tick's own checkout of feat-cmux-next (150 commits deep), no API read:
    None when nothing waits, (sha, committer date) of the oldest commit after head, or UNKNOWN when
    head is not an ancestor of tip and tip not one of head (a train commit), as the compare API
    reports those. Raises LookupError when head is not in this checkout (an older or a train head
    past the shallow history, or no checkout): the caller reads the compare API instead."""
    def run(*args: str) -> str:
        if git is not None:
            return git(*args)
        return subprocess.run(["git", *args], check=True, capture_output=True, text=True,
                              stdin=subprocess.DEVNULL, timeout=60).stdout

    try:
        run("cat-file", "-e", f"{head}^{{commit}}")
        run("cat-file", "-e", f"{tip}^{{commit}}")
    except (OSError, subprocess.SubprocessError) as error:
        raise LookupError(f"{head[:12]} or {tip[:12]} is not in this checkout") from error

    def ancestor(a: str, b: str) -> bool:
        try:
            run("merge-base", "--is-ancestor", a, b)
            return True
        except subprocess.CalledProcessError as error:
            if error.returncode == 1:
                return False
            raise LookupError(f"merge-base {a[:12]} {b[:12]} failed") from error
        except (OSError, subprocess.SubprocessError) as error:
            raise LookupError(f"merge-base {a[:12]} {b[:12]} failed") from error

    if head == tip or ancestor(tip, head):
        return None
    if not ancestor(head, tip):
        return UNKNOWN
    try:
        # A shallow checkout's boundary commits (their parents were not fetched) inside head..tip mean
        # the range may be missing older commits of a merged side history: the compare API answers.
        boundary = set()
        if run("rev-parse", "--is-shallow-repository").strip() == "true":
            path = Path(run("rev-parse", "--path-format=absolute", "--git-path", "shallow").strip())
            boundary = set(path.read_text(encoding="utf-8").split()) if path.is_file() else set()
        if boundary and boundary & set(run("rev-list", f"{head}..{tip}").split()):
            raise LookupError(f"the shallow checkout cuts history between {head[:12]} and {tip[:12]}")
    except (OSError, subprocess.SubprocessError) as error:
        raise LookupError(f"could not check the checkout's depth after {head[:12]}") from error
    try:
        # The oldest landing by committer date (squash merges set it at landing), not the first in
        # topological order: in a merge history a newer mainline commit can sort before an older
        # side-branch one.
        commits = []
        for line in run("log", "--format=%H %cI", f"{head}..{tip}").splitlines():
            sha, landed = line.split()
            commits.append((dt.datetime.fromisoformat(landed.replace("Z", "+00:00")), sha))
        landed, first = min(commits)
        return first, landed
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        raise LookupError(f"could not read the commits after {head[:12]}") from error


def gh_api(path: str):
    out = subprocess.run(["gh", "api", path], check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def evaluate(now: dt.datetime, repo: str, tip: str, api=gh_api,
             window_minutes: float = WINDOW_MINUTES, ls_remote=None, local_gap=None) -> tuple[bool, str]:
    """Read the head with `ls_remote` (main passes git ls-remote) and then the API, the rest
    through the API (the job's token), and decide. The gap to the tip comes from `local_gap`
    (main passes git_oldest_after, the tick's checkout) when it can answer, else the compare API.

    nightly-next's head unreadable: wait, with a warning. The rule's purpose is to coalesce, and
    the feed watch (every 10 minutes) dispatches a build for one commit, which skips this rule, so
    a failed read here costs at most that backstop's delay and never a burst of builds. Any other
    failed read promotes, with a warning: the promotion ignores a request that moves nothing."""
    head = None
    if ls_remote is not None:
        try:
            head = ls_remote(repo, "nightly-next")
        except Exception as error:  # noqa: BLE001 - the refs API below is the fallback
            print(f"git ls-remote nightly-next failed ({error!r}); reading it through the API")
    try:
        if head is None:
            head = api(f"repos/{repo}/git/ref/heads/nightly-next")["object"]["sha"]
    except Exception as error:  # noqa: BLE001
        print(f"::warning title=nightly-next rolling rule::could not read nightly-next ({error!r}); "
              "waiting for the feed watch's backstop dispatch")
        return False, f"could not read nightly-next ({error!r}); the feed watch's backstop covers this"
    # The gap to the tip, from the tick's checkout when it can answer (no API read). Nothing after
    # nightly-next's head (the tip is on it already, which a finished build or the cron backstop
    # often finds) needs no promotion and none of the reads below: the request would stop at the
    # tip with "already on nightly-next".
    local = None
    if local_gap is not None:
        try:
            local = (local_gap(head, tip),)
        except LookupError as error:
            print(f"{error}; reading the gap to the tip through the compare API")
    if local == (None,):
        return False, f"nightly-next ({head[:12]}) already has the tip {tip[:12]}; nothing waits to be promoted"
    try:
        base = f"repos/{repo}/actions/workflows/nightly.yml/runs?"
        # One listing of nightly-next's recent runs, kept to the push group's (pushes and the loop's
        # retry dispatches, watch.holds_push_group): its head's runs, and the newest start.
        recent = [run for run in api(base + urllib.parse.urlencode(
            {"branch": "nightly-next", "per_page": 50}))["workflow_runs"] if watch.holds_push_group(run)]
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

        def gap():
            return local[0] if local is not None else oldest_after(api, repo, head, tip)

        def jobs_of(run: dict) -> list[dict]:
            return api(f"repos/{repo}/actions/runs/{run['id']}/jobs?filter=latest&per_page=100")["jobs"]

        return decide(now, head=head, head_runs=head_runs, jobs_of=jobs_of, promotions=promotions,
                      oldest_waiting=gap(), window_minutes=window_minutes,
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
    go, reason = evaluate(dt.datetime.now(dt.timezone.utc), args.repo, args.tip, window_minutes=args.window_minutes,
                          ls_remote=watch.ls_remote_sha, local_gap=git_oldest_after)
    print(f"rolling rule: {'promote' if go else 'wait'}: {reason}")
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"go={'true' if go else 'false'}\nreason={reason}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
