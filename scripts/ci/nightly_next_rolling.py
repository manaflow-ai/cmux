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
push or the loop's retry dispatch; run_holds_group): a run whose nightly-next-one ran
holds it only until that job ends (the push slot is that job's group, nightly-next-one-push,
and its finish asks this tick through wake-nightly-next-tick), and holds it while that job
is queued or pending however long; a run of the split jobs still holds it through its tail;
and a run that has sat 10 minutes with nothing running and every queued job without a
runner holds nothing. A promotion run on
main that is still moving nightly-next counts as building for --promotion-minutes.
One exception: a retry of nightly-next's own head while a newer commit waits neither
holds nor counts as a start (retry_of). It leaves the slot only when a newer push
arrives, which waiting for it never let happen (19-41 min per retry, runs
43395284047 and 43440656795), so the rule promotes: a retry not yet past that step
yields, and one past it finishes with the newer push queued behind it, which then
starts at once. Its head is no longer nightly-next's then, so it holds again.

A run waiting in its leave-slot step holds nothing either (leaving_slot): a stale run (a loop retry, or a push
that waited in the group behind another build) waits there for this promotion before any build job starts, and
leaves once nightly-next moves. The same holds for nightly-next-one's first step (LEAVE_ONE_STEP), where a run
admitted after a long wait at nightly-next-one-push checks again and leaves by skipping its build.

A holder whose nightly-next-one reached notarization (FINISH_STEPS; finishing) holds nothing while it is the only
open loop run: the tick promotes ONE run then, whose set-up runs during the notarize and publish and whose
nightly-next-one waits pending on nightly-next-one-push. Once that run is open the holder holds again, so no second
promotion ever replaces the pending job. run_holds_group (the feed watch's starvation guard) is unchanged.

Two slots (2026-11-21, design manaflow-ai/cmuxterm-hq#17011): feat-cmux-next's nightly-next-one picks a signer Mac
(pick-nightly-next-signer) and takes that Mac's group, nightly-next-one-push-<host>, so two builds can run at once,
one per signer Mac, each end to end. Measured: one build holds a signer 32.5 min (build 7.1, notarize 7.4, appcast
deltas 4.3, uploads 4.8), so with one slot a landing just after a build starts reaches the feed in about 65 min;
with two, about 37 min while landings are more than about 16 min apart. NIGHTLY_NEXT_SLOTS (--slots; the tick passes
vars.NIGHTLY_NEXT_SLOTS, default 1) is the cap: the rule promotes while fewer than that many open loop runs hold a
slot (run_holds_group, minus leaving_slot, minus a finishing holder while no more loop runs are open than slots) AND
none of them waits for one or uses the split workflow's shared group. Never a second pending run, so
GitHub never replaces a pending job and nothing is cancelled; PROMOTION_RACE_MINUTES still spaces two starts so two
picks don't see the same free Mac. A cap of 1 restores the one-slot admission rule above. Its early handoff at
notarization serializes execution only when both jobs use the legacy shared group. The holder test reads jobs by
name (nightly-next-one), so it covers both the legacy and per-host groups.

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
at most the backstop's delay. So does a failed run listing, and any other failed read while a
nightly-next push run created within RUN_LOOKBACK is not completed (or its creation is unreadable): that run
may wait at the push slot, and a promotion would get GitHub to cancel its pending job, a cancelled nightly
(may_wait_at_slot). Any other failed read, and a gap to the tip that cannot be
read, promotes, with a warning: the promotion ignores a request that does not
move nightly-next forward.

usage: nightly_next_rolling.py --repo OWNER/NAME --tip SHA [--window-minutes 10] [--slots N]
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
# feat-cmux-next's resolve-nightly-cmux-tui-client step where a stale run (a loop retry, or a push that waited in
# the group behind another build) waits for a newer promotion before any build job starts
# (resolve-leave-build-slot.sh). A run in it builds nothing yet and leaves once nightly-next moves.
RESOLVE_JOB = "resolve-nightly-cmux-tui-client"
LEAVE_SLOT_STEP = "Leave the build slot to a newer nightly-next push"
# The same check again as nightly-next-one's first step, once its group (nightly-next-one-push) admits it: a run that
# waited there while newer commits landed waits in this step for a promotion and leaves by skipping its build.
ONE_JOB = "nightly-next-one"
LEAVE_ONE_STEP = "Leave the push slot to a newer nightly-next push"
LEAVE_STEPS = {RESOLVE_JOB: LEAVE_SLOT_STEP, ONE_JOB: LEAVE_ONE_STEP}
# nightly-next-one's steps from which its run is finishing: feat-cmux-next's nightly-next-one asks this tick in the first,
# just before the second, so the next run's promotion, preflight, decide and resolve run during the holder's notarize
# and publish instead of after it (4.7 min, 21:38:45 to 21:43:25; push runs 43634178843, 43642011551, 43644053566
# waited 19.6-26.8 min from landing to run created). The promoted run's nightly-next-one waits pending on
# nightly-next-one-push until the slot frees (finishing, below).
FINISH_STEPS = ("Ask main's nightly-next tick at notarization", "Notarize app ticket through final DMG")
# How many loop runs may hold a slot at once (NIGHTLY_NEXT_SLOTS; the tick passes vars.NIGHTLY_NEXT_SLOTS). 1 is the
# one-slot rule and the rollback; 2 is one build per signer Mac (design hq#17011).
SLOTS = 1
MAX_SLOTS = 2
# With 2 slots, the second start waits until the first has run SIGNER_STAGGER_MINUTES, half the measured build (run
# 44907462015: 33.6 min from run start to nightly-next-one's end): two builds started together finish together, and a
# landing just after them waits for both. Replaying the 809 feat-cmux-next landings of 2026-11-20 15:00Z to 2026-11-21
# 15:00Z with that build: p95 merge-to-feed 66.2 min on one slot, 58.1 on two started at once, 50.1 on two half a
# build apart.
SIGNER_STAGGER_MINUTES = 16.0


def leaving_slot(jobs: list[dict]) -> bool:
    """Whether a run waits in a leave-slot step (resolve's, or nightly-next-one's first step) with no other job of it
    running: it yields to a promotion. Run 43558081148 of a22a4eb1 waited 23 min in the group, then built the old
    head beside 20 newer commits."""
    leaving = {job.get("name") for job in jobs if job.get("name") in LEAVE_STEPS and job.get("status") == "in_progress"
               and any(step.get("name") == LEAVE_STEPS[job.get("name")] and step.get("status") == "in_progress"
                       for step in job.get("steps") or [])}
    others = [job for job in jobs if job.get("name") not in leaving and (job.get("status") in ("in_progress", "waiting")
              or job.get("status") in ("queued", "pending", "requested") and job.get("runner_name"))]
    return bool(leaving) and not others


def finishing(jobs: list[dict]) -> bool:
    """Whether a run's nightly-next-one is in progress at or past FINISH_STEPS (asking the tick, notarizing,
    publishing, the post-feed uploads): it builds nothing more, and the slot frees when it ends. A skipped step (a run
    that left the slot, or one that failed before notarization) is not reached."""
    for job in jobs:
        if job.get("name") != ONE_JOB or job.get("status") != "in_progress":
            continue
        return any(step.get("name") in FINISH_STEPS and (step.get("status") == "in_progress" or step.get(
            "status") == "completed" and step.get("conclusion") in ("success", "failure"))
            for step in job.get("steps") or [])
    return False


def can_share_slot_capacity(jobs: list[dict]) -> bool:
    """Only a started one-job build is eligible for parallel admission, not setup, a waiter or split jobs."""
    return any(job.get("name") == ONE_JOB and job.get("status") == "in_progress" for job in jobs)


def retry_may_be_replaced(jobs: list[dict]) -> bool:
    """Whether a lone retry of nightly-next's head waits where a promotion would get it replaced: its
    nightly-next-one exists and is queued, pending or waiting (the push slot's one pending job), or the run
    lists no job yet (pending on its concurrency group). Anywhere else (decide, resolve, a running build) it is
    ignored as on main: in one-job mode its group is run-<id> until nightly-next-one exists, so nothing pending
    is replaced, and resolve's "Leave the build slot" only polls the ref for 6 minutes without asking the tick,
    so waiting on it rebuilt the failed commit while the newer one waited ~30 min."""
    if not jobs:
        return True
    one = next((job for job in jobs if job.get("name") == ONE_JOB), None)
    return one is not None and one.get("status") not in ("completed", "in_progress")


def slots_from(value) -> int:
    """Clamp to the signer pool's capacity; unset or unreadable keeps the one-slot rule."""
    try:
        return min(MAX_SLOTS, max(1, int(str(value).strip())))
    except (TypeError, ValueError):
        return SLOTS


def may_wait_at_slot(now: dt.datetime, runs: list[dict]) -> str:
    """A push-group run that may still have a job waiting at the push slot: not completed and created within
    RUN_LOOKBACK, or with a creation that can't be read. A promotion while one waits gets GitHub to replace (cancel)
    its pending job, so a failed read never promotes past it. "" when every run is ruled out."""
    for run in runs:
        if run.get("status") == "completed":
            continue
        try:
            if now - watch.parse_time(run["created_at"]) > RUN_LOOKBACK:
                continue
        except (KeyError, TypeError, ValueError, AttributeError):
            pass
        return f"nightly-next run {run.get('html_url', run.get('id'))} may be waiting at the push slot"
    return ""


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
           starts: list[dict] | None = None, slots: int = SLOTS) -> tuple[bool, str]:
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
    slots = slots_from(slots)
    if not head:
        return True, "nightly-next is unreadable; asking as before"
    every_open = {run.get("id") for run in [*head_runs, *(starts or [])]
                  if run.get("status") != "completed" and watch.holds_push_group(run)}
    timed_starts = [run for run in starts or [] if oldest_waiting is None or not retry_of(run, head)]
    building, skipped_retry = "", False
    since_start = youngest_start(now, timed_starts, promotions, promotion_minutes)
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
        seen, open_runs = set(), []
        for run in [*head_runs, *(starts or [])]:
            if run.get("id") in seen or run.get("status") == "completed" or not watch.holds_push_group(run):
                continue
            seen.add(run.get("id"))
            try:
                if now - watch.parse_time(run["created_at"]) > RUN_LOOKBACK:
                    continue
            except (KeyError, TypeError, ValueError):
                pass
            open_runs.append(run)
        busy_count = 0
        for run in open_runs:
            jobs = jobs_of(run)
            if (oldest_waiting is not None and len(every_open) == 1 and retry_of(run, head)
                    and not retry_may_be_replaced(jobs)):
                skipped_retry = True
                continue
            # A finishing holder lets ONE run be promoted: only while no more loop runs are open than there are
            # slots (a retry of the head included; with one slot, no other loop run) and the holder still builds
            # nightly-next's head. A head past it means a promotion went through whose push run may not be listed
            # yet. A second promotion would get GitHub to replace the first one's pending nightly-next-one (a
            # cancelled nightly).
            may_handoff = (len(every_open) <= slots and (run.get("head_sha") or "").lower() == head.lower())
            if (watch.run_holds_group(run, jobs, now) and not leaving_slot(jobs)
                    and not (may_handoff and finishing(jobs))):
                busy_count += 1
                busy_run = run
                if busy_count >= slots or not can_share_slot_capacity(jobs):
                    building = (f"nightly-next run {run.get('html_url', run.get('id'))} is building "
                                f"{(run.get('head_sha') or head)[:12]}")
                    if busy_count < slots:
                        building += " (the slot may be shared or pending; a second pending run would replace it)"
                    break
        if busy_count and not building and oldest_waiting is None:
            # Nothing newer than nightly-next's head waits: a promotion would have nothing to build, the same
            # answer (and reason) as one slot gives.
            building = (f"nightly-next run {busy_run.get('html_url', busy_run.get('id'))} is building "
                        f"{(busy_run.get('head_sha') or head)[:12]}")
        elif busy_count and not building and since_start is not None and since_start < SIGNER_STAGGER_MINUTES:
            return False, (f"{busy_count} of {slots} nightly-next slots busy, and the newest build started "
                           f"{since_start:.0f} of {SIGNER_STAGGER_MINUTES:g} min ago; the next starts half a build "
                           "after it, so the two finish apart")
        elif busy_count and not building:
            return True, f"{busy_count} of {slots} nightly-next slots busy; promoting the newest buildable commit now"
    if not building and skipped_retry:
        return True, (f"the open run is a retry of nightly-next's head {head[:12]} and a newer commit waits; ignoring "
                      "the retry and promoting the newest buildable commit now")
    if not building:
        return True, f"nothing is building nightly-next ({head[:12]}); promoting the newest buildable commit now"
    if oldest_waiting is None:
        return False, f"{building}, and no feat-cmux-next commit waits after it"
    if since_start is not None and since_start < window_minutes:
        return False, (f"{building}, and the newest build started {since_start:.0f} of {window_minutes:g} min ago; "
                       "the next start, for the newest buildable commit, waits for it to finish")
    if slots > 1:
        return False, (f"{building}; every one of {slots} slots is taken or a run waits for one, so a promotion now "
                       "could get a pending run replaced. A build's finish ticks again and promotes the newest tip")
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


class GhRefused(subprocess.CalledProcessError):
    """A failed `gh api`, whose repr (the rolling rule's warnings) carries what gh said."""

    def __repr__(self) -> str:
        return f"gh api {self.cmd[-1]} exited {self.returncode}: {self.stderr}"


# GitHub's secondary limit (a 403 whose page links the Terms of Service) refuses every token for a while. Its docs
# ask for at least a minute before a retry; the tick waits that once per run, so the serialized tick group is held
# at most this long.
SECONDARY_WAIT_SECONDS = 60.0
SECONDARY_MARKERS = ("secondary rate limit", "terms of service", "abuse detection")
_secondary_waited = False


def secondary_limited(said: str) -> bool:
    lowered = (said or "").lower()
    return any(marker in lowered for marker in SECONDARY_MARKERS)


def public_get(path: str):
    """One unauthenticated GET of the public REST API. Its budget is the runner address's, apart from every
    token's, so a refusal that dried the job's token and the spare one does not cost the tick its answer."""
    import urllib.request
    request = urllib.request.Request(f"https://api.github.com/{path}", headers={
        "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "nightly-next-rolling-rule"})
    with urllib.request.urlopen(request, timeout=20) as answer:  # noqa: S310 - a fixed https host
        return json.loads(answer.read().decode("utf-8"))


def _read_on_tokens(path: str, env, run):
    """(answer, None) from the first token that reads `path`, else (None, (exit code, gh's last words))."""
    tokens = [None, env["SPARE_READ_TOKEN"]] if env.get("SPARE_READ_TOKEN") else [None]
    refused = (1, "")
    for index, token in enumerate(tokens):
        child = None if token is None else {**env, "GH_TOKEN": token}
        done = run(["gh", "api", path], capture_output=True, text=True, env=child)
        if done.returncode == 0:
            if index:
                print(f"gh api {path.split('?')[0]}: the job's token was refused; read on the spare token")
            return json.loads(done.stdout), None
        refused = (done.returncode, " ".join((done.stderr or "").split())[-300:])
        if index + 1 < len(tokens):
            print(f"gh api {path.split('?')[0]} was refused ({refused[1]}); reading it on the spare token")
    return None, refused


def gh_api(path: str, env=None, run=subprocess.run, anonymous=None, sleep=None):
    """One `gh api` GET with the job's token. Refused, it goes out once more on SPARE_READ_TOKEN (a read-only
    App token with a budget of its own, the tick's), so a dry job token does not cost the tick its answer: ticks
    45118875109 and 45119653528 (2026-11-23 05:39 and 05:44Z) could not list the running builds while both
    builds' nightly-next-one had ended, and the promotion waited until 05:52.

    Refused there too, it goes out once with no token through `anonymous` (main passes public_get; the
    repository is public), whose budget is the runner address's. When gh's last words are GitHub's secondary
    limit, `sleep` (main passes time.sleep) waits SECONDARY_WAIT_SECONDS, once per process, and the reads go out
    one more time. Ticks 45700034320 to 45706304238 (2026-11-25 18:12 to 21:43Z) all waited on "could not read
    the running builds", a secondary-limit 403 on both tokens, and nightly-next sat at 4755643e for 3.5 h.
    A refusal carries gh's own words."""
    global _secondary_waited
    env = os.environ if env is None else env
    short = path.split('?')[0]
    for _attempt in range(2):
        answer, refused = _read_on_tokens(path, env, run)
        if refused is None:
            return answer
        code, said = refused
        if anonymous is not None:
            try:
                answer = anonymous(path)
            except Exception as error:  # noqa: BLE001 - the refusal below names the tokens' words
                print(f"gh api {short}: the tokens were refused ({said}); the read with no token failed too ({error!r})")
            else:
                print(f"gh api {short}: the tokens were refused ({said}); read with no token")
                return answer
        if sleep is None or _secondary_waited or not secondary_limited(said):
            break
        _secondary_waited = True
        wait = float(env.get("ROLLING_SECONDARY_WAIT_SECONDS") or SECONDARY_WAIT_SECONDS)
        print(f"gh api {short}: GitHub's secondary limit ({said}); waiting {wait:g} s once, then reading again")
        sleep(wait)
    raise GhRefused(code, ["gh", "api", path], "", said)


def production_api(path: str):
    """gh_api as the tick runs it: both tokens, then no token, then one secondary-limit wait."""
    import time
    return gh_api(path, anonymous=public_get, sleep=time.sleep)


def evaluate(now: dt.datetime, repo: str, tip: str, api=gh_api,
             window_minutes: float = WINDOW_MINUTES, ls_remote=None, local_gap=None,
             slots: int = SLOTS) -> tuple[bool, str]:
    """Read the head with `ls_remote` (main passes git ls-remote) and then the API, the rest
    through the API (the job's token), and decide. The gap to the tip comes from `local_gap`
    (main passes git_oldest_after, the tick's checkout) when it can answer, else the compare API.

    nightly-next's head unreadable: wait, with a warning. The rule's purpose is to coalesce, and
    the feed watch (every 10 minutes) dispatches a build for one commit, which skips this rule, so
    a failed read here costs at most that backstop's delay and never a burst of builds. The run
    listing unreadable, or another read failing while a nightly-next push run created within
    RUN_LOOKBACK is not completed (or its creation is unreadable): wait, with a warning. That run
    may wait at the push slot, and a promotion would get GitHub to cancel its pending job. Any
    other failed read promotes, with a warning: the promotion ignores a request that moves nothing."""
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
        why = (f"could not read the running builds ({error!r}); a nightly-next push run created in the last "
               f"{RUN_LOOKBACK.total_seconds() / 3600:g} h can't be ruled out, and a promotion while one waits at the push "
               "slot gets it cancelled, so waiting for the next tick or the feed watch's backstop")
        print(f"::warning title=nightly-next rolling rule::{why}")
        return False, why
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
                      starts=recent, slots=slots)
    except Exception as error:  # noqa: BLE001
        if since_start is not None and since_start < window_minutes:
            print(f"::warning title=nightly-next rolling rule::could not read the running builds ({error!r}); "
                  f"a build started {since_start:.0f} min ago, so waiting")
            return False, (f"could not read the running builds ({error!r}); the newest build started "
                           f"{since_start:.0f} of {window_minutes:g} min ago, so waiting")
        live = may_wait_at_slot(now, recent)
        if live:
            why = (f"could not read the running builds ({error!r}); {live}, and a promotion now would get it "
                   "cancelled, so waiting")
            print(f"::warning title=nightly-next rolling rule::{why}")
            return False, why
        print(f"::warning title=nightly-next rolling rule::could not read the running builds ({error!r}); promoting")
        return True, f"could not read the running builds ({error!r}); promoting"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--tip", required=True, help="the feat-cmux-next commit the tick checked out")
    parser.add_argument("--window-minutes", type=float, default=WINDOW_MINUTES)
    parser.add_argument("--slots", default=os.environ.get("NIGHTLY_NEXT_SLOTS", ""),
                        help="signer slots (1 or 2; default $NIGHTLY_NEXT_SLOTS, else 1)")
    args = parser.parse_args(argv)
    slots = slots_from(args.slots)
    go, reason = evaluate(dt.datetime.now(dt.timezone.utc), args.repo, args.tip, api=production_api,
                          window_minutes=args.window_minutes,
                          ls_remote=watch.ls_remote_sha, local_gap=git_oldest_after, slots=slots)
    print(f"rolling rule: {'promote' if go else 'wait'}: {reason}")
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"go={'true' if go else 'false'}\nreason={reason}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
