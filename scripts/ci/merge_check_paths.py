#!/usr/bin/env python3
"""The check-path gate gh-merge-green applies to pull requests into feat-cmux-next.

    merge_check_paths.py OWNER/REPO NUMBER SHA [--base feat-cmux-next] [--timeout SECONDS] [--budget SECONDS]
        [--rerun] [--interval SECONDS] [--check-only]

A pull request's CI judges it against the base it ran on. When a check path changed on the base after that, the
result is stale though no file of the pull request changed: on 2026-10-21 #22967, #22975 and #23094 merged after
#23365 added check:fixed-waits, never ran it, and turned it red on feat-cmux-next. The check paths are the base's
scripts/ci/check-paths.txt (fnmatch patterns, one list shared with next-autoland): the check scripts, their
baselines, the fast gates and the workflows that run them.

The pull request's CI base is the `base <sha>` its `cmux-next/fast-gates` status names (the merge's first parent).
The gate passes when that status is a success and its base is the tip, or an ancestor of it whose newer commits
change no check path. Otherwise (no status, a status that is not a success, such as a red or a stopped run's
"no verdict", a status that names no base, or a base that is not an ancestor, too far behind, or older than a check
path change) it
dispatches cmux-next-fast-gates.yml for the pull request, which merges the head into the current tip and runs the
cheap gates and the webviews checks there, and waits for that run's status: a success whose base is fresh again
passes; a red, or a run that never reports within --timeout, refuses. When the base changed a check path again
during the run (feat-cmux-next lands often: on 2026-11-09 this race refused #39632, #39631 twice and #39705), the
success proves nothing for the new tip, so it dispatches again there and waits again, while --budget lasts
(gh-merge-green passes what its --wait left; the default is --timeout). The first run always gets its full
--timeout (default 1200s; not with --rerun: gh-merge-green dispatched one earlier in this merge); any other run starts only with
one run's time (MIN_RUN) of the budget left and stops at its end, and a budget that runs out refuses with the
last reason. A run that stopped with no verdict (a pending "stopped ..., no verdict" status, or the dispatched run
completed with no status: a whole-run cancel skips the post job) is dispatched again the same way. The list is read
again after each run, so a pattern that landed meanwhile counts. Not strict up-to-date protection or a merge
queue: only a stale pull request gets cheap Linux runs, and nothing is rebased. gh-merge-green runs this gate again
right before gh pr merge (the base may change a check path after the first pass).

Before each dispatch it reads the pull request's mergeable state: a pull request GitHub reports as conflicting
(mergeable false, or mergeable_state dirty) refuses with "conflicting: rebase" and dispatches nothing, since every
run of it is red and gh pr merge refuses it. UNKNOWN (GitHub computes it lazily) is no evidence of a conflict: the
gate goes on at once with a note, never polling for it; the next dispatch reads it again, and gh pr merge refuses a
real conflict.

--check-only (gh-merge-green --dry-run) says whether it would dispatch and dispatches nothing. Before the file
is on the base (its read answers 404) the gate passes with a note. Each poll is one REST read of
the head's combined status and one of the dispatched run (a dispatch whose answer names no workflow_run_id
refuses).
Prints `checked=<what>` and `waited=<seconds>`. Exit 0: pass; 1: refused (the reason on stderr); 3: GitHub
rate-limited a read (the reset time on stderr).
"""
from __future__ import annotations

import argparse
import fnmatch
import importlib.util
import json
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Callable

BRANCH = "feat-cmux-next"
CHECK_PATHS = "scripts/ci/check-paths.txt"
CONTEXT = "cmux-next/fast-gates"
WORKFLOW = "cmux-next-fast-gates.yml"
STATUS_BASE = re.compile(r"\bbase ([0-9a-f]{40})\b")
MAX_AHEAD = 250  # as next-autoland: further behind than this, the compare is not trusted
MAX_FILES = 300  # GitHub's compare lists at most 300 files
# A rerun is dispatched only with this much of the budget left: the fastest successful dispatched run on
# 2026-11-09 took 370s (most 440-830s), so a rerun with less could not report and would waste a Linux run.
MIN_RUN = 370
# How long one dispatched run may take to post its result: successful runs took up to 826s on 2026-11-09.
TIMEOUT = 1200
NO_VERDICT = "no verdict"  # a pending fast-gates status whose gates job was cancelled or timed out


class Refused(Exception):
    pass


class RateLimited(Refused):
    pass


def _load_rate_limit():
    spec = importlib.util.spec_from_file_location("_merge_check_paths_rate_limit",
                                                  Path(__file__).with_name("gh_rate_limit.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_rate = _load_rate_limit()


class Api:
    """The GitHub reads and the one dispatch, through gh."""

    def __init__(self, repo: str):
        self.repo = repo

    def gh(self, *args: str) -> str:
        try:
            out = subprocess.run(["gh", "api", *args], capture_output=True, text=True, timeout=60)
        except subprocess.TimeoutExpired:
            raise Refused(f"gh api {args[0]} took over 60s") from None
        if out.returncode != 0:
            if _rate.is_rate_limited(out.stderr):
                raise RateLimited(f"GitHub rate-limited gh api {args[0]} ({out.stderr.strip()[:200]}); "
                                  + _rate.describe(_rate.read_limits(), after_limit=True))
            raise Refused(f"gh api {args[0]} failed: {(out.stderr or out.stdout).strip()[:200]}")
        return out.stdout

    def check_paths(self, branch: str) -> str | None:
        """The base's check-paths.txt, or None when it is not there (a real 404)."""
        try:
            return self.gh(f"repos/{self.repo}/contents/{CHECK_PATHS}?ref={branch}",
                           "-H", "Accept: application/vnd.github.raw")
        except RateLimited:
            raise
        except Refused as error:
            if re.search(r"HTTP 404|Not Found", str(error)):
                return None
            raise

    def status(self, sha: str) -> dict | None:
        data = self.json(f"repos/{self.repo}/commits/{sha}/status?per_page=100")
        return next((s for s in data.get("statuses") or [] if isinstance(s, dict) and s.get("context") == CONTEXT),
                    None)

    def json(self, *args: str) -> dict:
        """A JSON object answer; anything else refuses (an unreadable answer proves nothing)."""
        text = self.gh(*args)
        try:
            data = json.loads(text)
        except ValueError:
            data = None
        if not isinstance(data, dict):
            raise Refused(f"gh api {args[0]} answered no JSON object: {text.strip()[:120]!r}")
        return data

    def tip(self, branch: str) -> str:
        sha = self.gh(f"repos/{self.repo}/branches/{branch}", "--jq", ".commit.sha").strip()
        if not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise Refused(f"the {branch} tip read answered {sha[:60]!r}, not a commit sha")
        return sha

    def compare(self, base: str, tip: str) -> dict:
        return self.json(f"repos/{self.repo}/compare/{base}...{tip}", "--jq",
                         "{status, ahead_by, files: [(.files // [])[] | .filename, (.previous_filename // empty)]}")

    def dispatch(self, number: str, branch: str) -> int | None:
        """Dispatch the fast gates; the run's id from GitHub's 200 answer (workflow_run_id), else None (refused)."""
        # return_run_details: without it GitHub (API 2022-11-28) answers 204 with no body, so no run id.
        text = self.gh("-X", "POST", f"repos/{self.repo}/actions/workflows/{WORKFLOW}/dispatches",
                       "-f", f"ref={branch}", "-f", f"inputs[pr]={number}", "-F", "return_run_details=true")
        try:
            run_id = json.loads(text).get("workflow_run_id") if text.strip() else None
        except (ValueError, AttributeError):
            run_id = None
        return run_id if isinstance(run_id, int) and run_id > 0 else None

    def mergeable(self, number: str) -> str:
        """CONFLICTING (mergeable false, or mergeable_state dirty), UNKNOWN (not computed yet) or MERGEABLE."""
        data = self.json(f"repos/{self.repo}/pulls/{number}", "--jq", "{mergeable, mergeable_state}")
        if data.get("mergeable") is False or data.get("mergeable_state") == "dirty":
            return "CONFLICTING"
        return "UNKNOWN" if data.get("mergeable") is None else "MERGEABLE"

    def run(self, run_id: int) -> dict:
        """The dispatched run's {status, conclusion}."""
        return self.json(f"repos/{self.repo}/actions/runs/{run_id}", "--jq", "{status, conclusion}")


def patterns(text: str) -> list[str]:
    return [line.strip() for line in text.splitlines() if line.strip() and not line.lstrip().startswith("#")]


def hits(files, pats: list[str]) -> list[str]:
    """The files a check path pattern matches, sorted."""
    return sorted(path for path in set(files) if any(fnmatch.fnmatchcase(path, p) for p in pats))


def stale(api: Api, status: dict | None, tip: str, pats: list[str]) -> str:
    """Why a fast-gates status does not prove TIP ("" when it does): it must be a success at a fresh base."""
    if not status:
        return f"{CONTEXT} has not run on this head"
    # A red, an error or a stopped run's pending "no verdict" proves nothing at any base: a new run decides.
    if status.get("state") != "success":
        return f"{CONTEXT} is {status.get('state') or 'unknown'} ({(status.get('description') or '')[:160]})"
    found = STATUS_BASE.search(status.get("description") or "")
    if not found:
        return f"{CONTEXT} names no base"
    base = found.group(1)
    if base == tip:
        return ""
    compare = api.compare(base, tip)
    if compare.get("status") not in ("ahead", "identical"):
        return f"{CONTEXT} ran at base {base[:12]}, not an ancestor of {BRANCH}'s tip {tip[:12]}"
    if int(compare.get("ahead_by") or 0) > MAX_AHEAD:
        return f"{CONTEXT} ran at base {base[:12]}, {compare['ahead_by']} commits behind {BRANCH}"
    moved = compare.get("files") or []
    if len(set(moved)) >= MAX_FILES:
        return f"{CONTEXT} ran at base {base[:12]}; {BRANCH} changed too many files since to tell"
    changed = hits(moved, pats)
    if changed:
        return f"{CONTEXT} ran at base {base[:12]}; {BRANCH} has changed the check path {changed[0]} since"
    return ""


def conflicts(api: Api, number: str) -> str:
    """Refused when GitHub reports the pull request as conflicting; else MERGEABLE or UNKNOWN, from one read.

    2026-11-09: the #39027 try spent 4m39s and dispatched the fast gates, then gh pr merge refused ("the merge
    commit cannot be cleanly created"). UNKNOWN (GitHub computes it lazily) is no evidence of a conflict, so the
    gate goes on at once, with no re-read loop; gh pr merge still refuses a real conflict.
    """
    state = api.mergeable(number)
    if state == "CONFLICTING":
        raise Refused(f"conflicting: rebase #{number} onto its base (GitHub reports it cannot be merged cleanly); "
                      "nothing was dispatched")
    if state == "UNKNOWN":
        print(f"note: GitHub is still computing whether #{number} merges cleanly; going on (gh pr merge refuses a "
              "conflict)", file=sys.stderr)
    return state


def gate(api: Api, number: str, sha: str, branch: str, timeout: float, interval: float,
         clock: Callable[[], float] = time.time, sleep: Callable[[float], None] = time.sleep,
         check_only: bool = False, budget: float | None = None, rerun: bool = False,
         min_run: float = MIN_RUN) -> tuple[str, float]:
    """(what was checked, seconds waited), or Refused.

    timeout bounds each dispatched run (no result within it refuses); budget (default: timeout) bounds the whole
    loop. The first run always gets its full timeout, unless rerun (gh-merge-green already dispatched one in this
    merge); any other run is dispatched only with min_run of the budget left, and waits no longer than its end.
    """
    started = clock()
    budget = timeout if budget is None else max(budget, 0.0)
    text = api.check_paths(branch)
    if text is None:
        print(f"note: {CHECK_PATHS} is not on {branch}; the check-path gate is skipped", file=sys.stderr)
        return f"check paths (no {CHECK_PATHS} on {branch})", 0.0
    pats = patterns(text)
    before = api.status(sha)
    tip = api.tip(branch)
    why = stale(api, before, tip, pats)
    if not why:
        return "check paths fresh", 0.0
    if check_only:
        print(f"note: {why}; a merge would dispatch {WORKFLOW} for #{number} against the current tip and wait",
              file=sys.stderr)
        return "check paths stale (check only: nothing dispatched)", 0.0
    runs = 0
    while True:
        first = runs == 0 and not rerun
        left = started + budget - clock()
        if not first and left < min_run:
            raise Refused(f"after {runs} dispatched run(s) of {WORKFLOW}, the wait budget of {int(budget)}s "
                          f"(what gh-merge-green --wait left) has {max(int(left), 0)}s left, less than one run "
                          f"({int(min_run)}s): {why}; retry, or pass --wait with more seconds")
        if runs == 0:
            print(f"note: {why}; dispatching {WORKFLOW} for #{number} against the current tip", file=sys.stderr)
        else:
            print(f"note: after dispatched run {runs}, {why}; dispatching {WORKFLOW} for #{number} again against "
                  f"the new tip {tip[:12]} ({int(left)}s of the {int(budget)}s wait budget left)",
                  file=sys.stderr)
        # A conflict makes every run red and the merge impossible: check before each dispatch.
        conflicts(api, number)
        runs += 1
        run_started = clock()
        # The first run keeps its own timeout (a slow fast gate may have spent the budget before it); any other
        # run also stops at the end of the budget.
        by_budget = not first and started + budget < run_started + timeout
        limit = started + budget if by_budget else run_started + timeout
        run_id = api.dispatch(number, branch)
        if run_id is None:
            # Without it a stop or a whole-run cancel of this run cannot be told from another run's: fail closed.
            raise Refused(f"{why}; dispatched {WORKFLOW}, but GitHub's answer named no workflow_run_id, so the gate "
                          "cannot follow its run; retry (a status that run posts counts then)")
        kind, status = _result(api, sha, before, run_id, limit, interval, clock, sleep)
        if kind is None and by_budget:
            raise Refused(f"{why}; the wait budget of {int(budget)}s (what gh-merge-green --wait left) ran out "
                          f"before dispatched run {runs} of {WORKFLOW} posted its result; retry once it reports, "
                          "or pass --wait with more seconds")
        if kind is None:
            raise Refused(f"{why}; the dispatched {WORKFLOW} posted no result within {int(timeout)}s; "
                          "retry once it reports")
        if kind == "stopped":
            # Cancelled or timed out: it judged nothing, so run it again (its run's own link names why).
            what = (status or {}).get("description") or "the run ended and posted no status"
            why = f"dispatched run {runs} stopped with no verdict ({what})"
            before = status or before
            tip = api.tip(branch)
            continue
        if status.get("state") != "success":
            raise Refused(f"{CONTEXT} is {status.get('state')} on the pull request merged with the current tip "
                          f"({status.get('target_url') or 'no run link'}): a check that landed since fails it")
        # The base's list again: a pattern that landed during the run counts for the next freshness check.
        text = api.check_paths(branch)
        if text is not None:
            pats = patterns(text)
        tip = api.tip(branch)
        again = stale(api, status, tip, pats)
        if not again:
            return "check paths (fast gates rerun on the current tip)", clock() - started
        # A check path changed during the run: its success proves nothing for the new tip, so run it there.
        before, why = status, again


def _new(status: dict | None, seen: tuple) -> bool:
    return bool(status) and (status.get("updated_at"), status.get("description")) != seen


def _result(api: Api, sha: str, before: dict | None, run_id: int, limit: float, interval: float,
            clock: Callable[[], float], sleep: Callable[[float], None]) -> tuple[str | None, dict | None]:
    """("result", status), ("stopped", status or None), or (None, None) after LIMIT.

    A result is the first non-pending status on SHA other than BEFORE. A stopped run is a new pending status
    with no verdict from RUN_ID, or RUN_ID completed with no new status (a whole-run cancel skips the post job).
    """
    # The run's post job writes only its final state; a status other than the one read before the dispatch is it.
    seen = (before or {}).get("updated_at"), (before or {}).get("description")
    while True:
        sleep(interval)
        status = api.status(sha)
        if _new(status, seen):
            if (status.get("state") or "") != "pending":
                return "result", status
            ours = str(status.get("target_url") or "").endswith(f"/actions/runs/{run_id}")
            if NO_VERDICT in (status.get("description") or "") and ours:
                return "stopped", status
        if (api.run(run_id).get("status") or "") == "completed":
            # The post job writes before the run completes: a status still missing now never comes.
            status = api.status(sha)
            if _new(status, seen) and (status.get("state") or "") != "pending":
                return "result", status
            return "stopped", status if _new(status, seen) else None
        if clock() > limit:
            return None, None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("repo")
    parser.add_argument("number")
    parser.add_argument("sha")
    parser.add_argument("--base", default=BRANCH)
    parser.add_argument("--timeout", type=float, default=TIMEOUT)
    parser.add_argument("--budget", type=float, default=None)
    parser.add_argument("--rerun", action="store_true",
                        help="a run was dispatched earlier in this merge: no run gets a timeout past the budget")
    parser.add_argument("--interval", type=float, default=20)
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args(argv)
    if args.base != BRANCH:
        print(f"checked=check paths (not {BRANCH})")
        return 0
    if not re.fullmatch(r"[0-9a-f]{40}", args.sha) or not args.number.isdigit():
        print("merge_check_paths: SHA must be a full commit sha and NUMBER digits", file=sys.stderr)
        return 1
    try:
        checked, waited = gate(Api(args.repo), args.number, args.sha, args.base, args.timeout, args.interval,
                               check_only=args.check_only, budget=args.budget, rerun=args.rerun)
    except RateLimited as error:
        print(f"rate-limited: {error}", file=sys.stderr)
        return 3
    except Refused as error:
        print(str(error), file=sys.stderr)
        return 1
    print(f"checked={checked}")
    print(f"waited={int(waited)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
