#!/usr/bin/env python3
"""The check-path gate gh-merge-green applies to pull requests into feat-cmux-next.

    merge_check_paths.py OWNER/REPO NUMBER SHA [--base feat-cmux-next] [--timeout SECONDS] [--interval SECONDS]
        [--check-only]

A pull request's CI judges it against the base it ran on. When a check path changed on the base after that, the
result is stale though no file of the pull request changed: on 2026-10-21 #22967, #22975 and #23094 merged after
#23365 added check:fixed-waits, never ran it, and turned it red on feat-cmux-next. The check paths are the base's
scripts/ci/check-paths.txt (fnmatch patterns, one list shared with next-autoland): the check scripts, their
baselines, the fast gates and the workflows that run them.

The pull request's CI base is the `base <sha>` its `cmux-next/fast-gates` status names (the merge's first parent).
The gate passes when that base is the tip, or an ancestor of it whose newer commits change no check path. Otherwise
(the status names no base, or its base is not an ancestor, too far behind, or a check path changed since) it
dispatches cmux-next-fast-gates.yml for the pull request, which merges the head into the current tip and runs the
cheap gates and the webviews checks there, and waits for that run's status: a success whose base is fresh again
passes; a red, a run that never reports within --timeout, or a base that changed a check path again during the
wait refuses. Not strict up-to-date protection or a merge queue: only a stale pull request gets one cheap Linux run,
and nothing is rebased.

--check-only (gh-merge-green --dry-run) says whether it would dispatch and dispatches nothing. Before the file
is on the base (its read answers 404) the gate passes with a note. Each poll is one REST read of
the head's combined status.
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

    def dispatch(self, number: str, branch: str) -> None:
        self.gh("-X", "POST", f"repos/{self.repo}/actions/workflows/{WORKFLOW}/dispatches",
                "-f", f"ref={branch}", "-f", f"inputs[pr]={number}")


def patterns(text: str) -> list[str]:
    return [line.strip() for line in text.splitlines() if line.strip() and not line.lstrip().startswith("#")]


def hits(files, pats: list[str]) -> list[str]:
    """The files a check path pattern matches, sorted."""
    return sorted(path for path in set(files) if any(fnmatch.fnmatchcase(path, p) for p in pats))


def stale(api: Api, status: dict | None, tip: str, pats: list[str]) -> str:
    """Why a fast-gates status is stale for TIP as far as check paths go ("" when it is not)."""
    if not status:
        return f"{CONTEXT} has not run on this head"
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


def gate(api: Api, number: str, sha: str, branch: str, timeout: float, interval: float,
         clock: Callable[[], float] = time.time, sleep: Callable[[float], None] = time.sleep,
         check_only: bool = False) -> tuple[str, float]:
    """(what was checked, seconds waited), or Refused."""
    started = clock()
    text = api.check_paths(branch)
    if text is None:
        print(f"note: {CHECK_PATHS} is not on {branch}; the check-path gate is skipped", file=sys.stderr)
        return f"check paths (no {CHECK_PATHS} on {branch})", 0.0
    pats = patterns(text)
    before = api.status(sha)
    why = stale(api, before, api.tip(branch), pats)
    if not why:
        return "check paths fresh", 0.0
    if check_only:
        print(f"note: {why}; a merge would dispatch {WORKFLOW} for #{number} against the current tip and wait",
              file=sys.stderr)
        return "check paths stale (check only: nothing dispatched)", 0.0
    print(f"note: {why}; dispatching {WORKFLOW} for #{number} against the current tip", file=sys.stderr)
    api.dispatch(number, branch)
    # The run's post job writes only its final state; a status other than the one read before the dispatch is it.
    seen = (before or {}).get("updated_at"), (before or {}).get("description")
    while True:
        sleep(interval)
        status = api.status(sha)
        if status and (status.get("updated_at"), status.get("description")) != seen \
                and (status.get("state") or "") != "pending":
            break
        if clock() - started > timeout:
            raise Refused(f"{why}; the dispatched {WORKFLOW} posted no result within {int(timeout)}s; "
                          "retry once it reports")
    waited = clock() - started
    if status.get("state") != "success":
        raise Refused(f"{CONTEXT} is {status.get('state')} on the pull request merged with the current tip "
                      f"({status.get('target_url') or 'no run link'}): a check that landed since fails it")
    again = stale(api, status, api.tip(branch), pats)
    if again:
        raise Refused(f"after the dispatched run, {again}; retry")
    return "check paths (fast gates rerun on the current tip)", waited


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("repo")
    parser.add_argument("number")
    parser.add_argument("sha")
    parser.add_argument("--base", default=BRANCH)
    parser.add_argument("--timeout", type=float, default=900)
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
                               check_only=args.check_only)
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
