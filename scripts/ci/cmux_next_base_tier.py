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
(one sleep, never a polling loop), takes the tip (a push kick: the push's own sha, not a ref read), and
dispatches. Its calls use the workflow's own cmux-bot App token, never github.token (whose REST budget
every workflow shares; 2026-11-10 kicks crashed on HTTP 403 from it). A read GitHub refuses on that
token's spent quota (github_quota_client.QuotaGitHub; other cmux-bot jobs share the App's budget)
is retried after one sleep until the quota resets while that fits the job's time; past that the kick
fails with one line naming the quota and its reset, not a traceback.

The job has one deadline (JOB_TIMEOUT_S, its workflow's timeout-minutes, less MARGIN_S), taken once on
the monotonic clock when the process starts. The quota retries, the window wait and the settle after the
dispatch all read the time left from it, never a budget of their own: a 601 s quota wait followed by a
full window would otherwise have dispatched at 1400 s, past the 1200 s job timeout, and been killed
(cmuxterm-hq docs/handbook/budget-summed-from-constants.md). When the window would end too late to
dispatch inside the deadline, the kick fails with one line and dispatches nothing: dispatching early
would break the one-run-per-window rule, and the newest push's kick, pending behind this one, takes a
tip that contains this push.

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
from cmux_next_tree_notify import Api  # noqa: E402
from github_quota_client import REQUEST_TIMEOUT_S, Deadline, QuotaExhausted, QuotaGitHub  # noqa: E402

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
# What a dispatch needs before the job's deadline: its POST, which the client ends at REQUEST_TIMEOUT_S
# from its start (a whole-request bound, not urlopen's per-socket-wait one), and then SETTLE_S (Codex
# review of #40520: 21 s left and a 10 s POST ended the settle 9 s late).
DISPATCH_RESERVE_S = REQUEST_TIMEOUT_S + SETTLE_S
# The compare API lists at most this many files; a longer diff counts as relevant.
COMPARE_FILES_MAX = 300
# The base tier's Mac jobs (cmux-next.yml's daemon-test, generated-files and cmux-scheme-compile names).
# A base tier run where one of these has started (or finished) is never cancelled.
MAC_JOBS = ("cmux-next daemon tests", "cmux-next generated files", "cmux app scheme compile (Debug)")
# A run in one of these states has not finished.
OPEN = ("queued", "in_progress", "waiting", "pending", "requested")
SHA = re.compile(r"^[0-9a-f]{40}$")
# cmux-next-base-tier-kick.yml's timeout-minutes (a test reads it), and what the job's one deadline keeps
# back from it for the runner's start, the checkout and the token mint before this process starts.
JOB_TIMEOUT_S = 20 * 60
MARGIN_S = 2 * 60
# Of the time left when the window opens, what the steps after it need: the listing, the compare, the
# dispatch, SETTLE_S and the cancels. A window that would leave less is not waited for.
AFTER_WINDOW_S = DISPATCH_RESERVE_S + 30
STARTED = time.monotonic()
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
    except (RuntimeError, TimeoutError):  # TimeoutError: no full answer within the client's request bound
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
        # Posted right after that fresh job read. The client never retries a write after a wait (a
        # Mac job may have started by then); a cancel refused on the spent quota is left to the next kick.
        try:
            status = api.post(f"repos/{repo}/actions/runs/{run_id}/cancel", {})
        except QuotaExhausted as error:
            log(f"could not cancel base tier run {run_id} ({sha[:12]}): {error}")
            continue
        except TimeoutError as error:
            # No full answer within the client's request bound: GitHub may have taken the cancel, or not.
            # Not counted as cancelled; the next kick reads the run again.
            log(f"no answer to the cancel of base tier run {run_id} ({sha[:12]}); it may or may not be "
                f"cancelled: {error}")
            continue
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
    except (RuntimeError, TimeoutError) as error:
        return True, f"could not compare {since[:12]}...{tip[:12]} ({error}); running the base tier"
    files = [item.get("filename") or "" for item in compare.get("files") or []]
    if compare.get("status") == "behind":
        # TIP is an ancestor of SINCE: the last base tier run already covers it. With the push's own sha
        # as the tip, a kick queued behind one that dispatched at a newer branch tip sees this.
        return False, f"{tip[:12]} is behind the last base tier run at {since[:12]}; it covers it"
    if compare.get("status") not in ("ahead", "identical") or len(files) >= COMPARE_FILES_MAX:
        return True, f"{since[:12]}...{tip[:12]} is {compare.get('status')} with {len(files)} files; running the base tier"
    hit = next((path for path in files if matches(path, patterns)), None)
    if hit:
        return True, f"{hit} changed since {since[:12]}"
    return False, f"no cmux-next push path changed since the last base tier run at {since[:12]} ({len(files)} files)"


def event_tip(env: dict[str, str]) -> str | None:
    """The pushed sha when the event is a push to BRANCH (it is the tip the push made), else None."""
    sha = env.get("GITHUB_SHA") or ""
    if env.get("GITHUB_EVENT_NAME") == "push" and env.get("GITHUB_REF") == f"refs/heads/{BRANCH}" and SHA.match(sha):
        return sha
    return None


def newest(firsts: dict[str, float]) -> tuple[str | None, float | None]:
    """The newest base tier run's sha and when it was created, or (None, None)."""
    return max(firsts.items(), key=lambda item: item[1]) if firsts else (None, None)


def branch_tip(api: Api, repo: str) -> str:
    tip = (api.get(f"repos/{repo}/git/ref/heads/{BRANCH}").get("object") or {}).get("sha") or ""
    if not SHA.match(tip):
        raise RuntimeError(f"could not read the {BRANCH} tip")
    return tip


class PastDeadline(RuntimeError):
    """The window (or the dispatch) would end past the job's deadline; one line saying so."""


class DispatchUnknown(RuntimeError):
    """The dispatch POST got no full answer within the client's request bound (RequestTimeout). GitHub
    may have taken it. The kick settled and cancelled as after a 204, then raises this one line: the
    dispatch is not reported as made."""


def kick(api: Api, repo: str, patterns: list[str], *, window: float = WINDOW_S,
         now: Callable[[], float] = time.time, sleep: Callable[[float], None] = time.sleep,
         log: Callable[[str], None] = print, pushed: str | None = None,
         deadline: Deadline | None = None) -> str | None:
    """Dispatch the base tier at the tip when it is due; returns the sha it asked for, or None.
    PUSHED is the push event's own sha (event_tip); the tip is read from the branch ref only without it.
    NOW is the wall clock (it is compared with GitHub's created_at); DEADLINE is the job's one deadline,
    shared with the client's quota retries. A window that ends too late for the dispatch to follow it
    inside DEADLINE raises PastDeadline before any sleep, and nothing is dispatched. After any wait (the
    window, or a quota wait inside a read) and before the dispatch, the run history is read again; a run
    that started meanwhile opens a fresh window, which this kick waits out (deadline permitting) unless
    that run already covers the push. Nothing is ever dispatched inside a base tier run's window."""
    firsts = base_tier_runs(api, repo)
    last_sha, last_at = newest(firsts)

    def covered() -> bool:
        """Whether the newest base tier run already covers this push; when it does, the runs it supersedes
        are cancelled. Asked before every PastDeadline, so a kick with nothing left to dispatch never ends
        red on the deadline: a run covering the push may first show in any read, the first one too, whose
        own quota wait it started during (Codex review of #40471)."""
        tip = pushed or branch_tip(api, repo)
        if tip not in firsts and (last_sha is None or relevant(api, repo, last_sha, tip, patterns)[0]):
            return False
        keep = tip if tip in firsts else last_sha
        log(f"the base tier run at {keep[:12]} covers {tip[:12]}; nothing to dispatch")
        cancel_superseded(api, repo, keep, log)
        return True

    waited_out = None  # the run whose window this kick has already slept out
    newer = False  # whether LAST is a run that started while this kick waited
    while True:
        decided = False
        if newer:
            # A base tier run started during a wait (the window's, or a quota wait inside any read; Codex
            # review of #40369: a manual run 300 s into a 601 s quota wait got a second dispatch only
            # 301 s after it). It owns a fresh window, and this kick never dispatches inside it. When it
            # already covers this push there is nothing left to do; the older runs no Mac has started are
            # still superseded, and with no later push no other kick would cancel them.
            log(f"a newer base tier run ({last_sha[:12]}) started during the wait")
            tip = pushed or branch_tip(api, repo)
            if tip in firsts or not relevant(api, repo, last_sha, tip, patterns)[0]:
                log(f"it covers {tip[:12]}; leaving its full window to the next kick")
                cancel_superseded(api, repo, last_sha, log)
                return None
            newer = False
        # Only a run created after the one already waited out counts again: the local clock may be behind
        # GitHub's created_at (skew), so re-reading the same run's window after the wait would skip every kick.
        if last_at is not None and last_at != waited_out and (wait := last_at + window - now()) > 0:
            wait = min(wait, window)
            if deadline is not None and wait + AFTER_WINDOW_S > (left := deadline.left()):
                if covered():
                    return None
                raise PastDeadline(f"the window opens in {int(wait)} s but this job has {max(0, int(left))} s left "
                                   f"before its deadline (it needs {AFTER_WINDOW_S} s after the window); "
                                   f"not dispatching; the next push's kick dispatches at a tip that contains "
                                   f"{(pushed or 'this push')[:12]}")
            log(f"the last base tier run ({last_sha[:12]}) started {int(window - wait)} s ago; "
                f"waiting {int(wait)} s for the window to open")
            sleep(wait)
            waited_out = last_at
        else:
            # A push kick takes its own event's sha as the tip instead of reading the ref (a REST call on
            # the repository's shared token quota; 2026-11-10 kicks died on it with HTTP 403). After the
            # wait the branch may be past PUSHED, and that stays correct: a newer push's kick is pending
            # behind this one in the concurrency group (the newest replaces older pending ones), so it
            # judges the newer commits with its own sha. `tip in firsts` asks whether this push already
            # has a run; relevant() compares the last run with this push (a push already behind the last
            # run is covered: "behind"); the dispatch takes the branch ref, so its run is titled with the
            # tip at dispatch time, which cancel_superseded() keeps as the newest listed run, as it keeps
            # NEWEST (PUSHED).
            tip = pushed or branch_tip(api, repo)
            if tip in firsts:
                log(f"{BRANCH} {tip[:12]} already has a base tier run; nothing to dispatch")
                cancel_superseded(api, repo, tip, log)
                return None
            if last_sha is not None:
                due, why = relevant(api, repo, last_sha, tip, patterns)
                log(why)
                if not due:
                    return None
            decided = True
        # After a wait, and before every dispatch, the history is read again: the reads above may each have
        # waited out a spent quota, and a run may have started meanwhile. The listing's GET returns after
        # any quota wait of its own, so what it shows is current.
        seen_at = last_at
        firsts = base_tier_runs(api, repo)
        last_sha, last_at = newest(firsts)
        if last_at is not None and (seen_at is None or last_at > seen_at):
            newer = True
            continue
        if decided:
            break
    # The settle is reserved before the dispatch, never skipped after it (Codex review of #40471): a
    # dispatch with no settle frees the kick's concurrency slot before GitHub lists the new run, and the
    # next kick, seconds later, finds no run at the tip and dispatches the same Mac work again.
    if deadline is not None and deadline.left() < DISPATCH_RESERVE_S:
        if covered():
            return None
        raise PastDeadline(f"{max(0, int(deadline.left()))} s left before this job's deadline, less than the "
                           f"{DISPATCH_RESERVE_S} s a dispatch needs (its POST, then the {SETTLE_S} s settle); "
                           f"not dispatching {tip[:12]}; the next push's kick dispatches at a tip that contains it")
    unknown = None
    try:
        status = api.post(f"repos/{repo}/actions/workflows/{WORKFLOW}/dispatches",
                          {"ref": f"refs/heads/{BRANCH}", "inputs": {"base_tier": "true"}})
    except TimeoutError as error:
        # The client bounds the whole POST (REQUEST_TIMEOUT_S, inside DISPATCH_RESERVE_S), but past the
        # bound GitHub may still have taken it: the answer, not the request, may be what was lost. So it
        # counts as dispatched, unknown: the settle and the cancels run as after a 204 (the cancels read
        # only what GitHub lists, so they are right either way), it is never posted again (that could be
        # the same Mac work twice; the next push's kick dispatches if it was lost), and the kick then
        # fails with one line instead of reporting a dispatch.
        unknown = (f"the base tier dispatch at {tip[:12]} got no answer ({error}); GitHub may or may not "
                   f"have taken it; settled and cancelled as after one")
    else:
        if status != 204:
            raise RuntimeError(f"the base tier dispatch was refused (HTTP {status})")
        log(f"dispatched the base tier on {BRANCH} at {tip[:12]}")
    sleep(SETTLE_S)
    cancel_superseded(api, repo, tip, log)
    if unknown:
        raise DispatchUnknown(unknown)
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
    # The job's one deadline, from when this process started; every wait below reads what is left of it.
    deadline = Deadline(JOB_TIMEOUT_S - MARGIN_S - (time.monotonic() - STARTED))
    try:
        kick(QuotaGitHub(token, deadline=deadline), args.repo, patterns, window=max(0.0, args.window),
             pushed=event_tip(dict(os.environ)), deadline=deadline)
    except QuotaExhausted as error:
        # One line, no traceback: the quota is another workflow's spend, not a bug here.
        print(f"error: the base tier kick could not reach GitHub: {error}", file=sys.stderr)
        return 1
    except PastDeadline as error:
        print(f"error: the base tier kick ran out of job time: {error}", file=sys.stderr)
        return 1
    except DispatchUnknown as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
