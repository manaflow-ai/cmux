#!/usr/bin/env python3
"""Merge a feat-cmux-next pull request only on a head that is fresh against the tip.

Two Swift or Rust pull requests can each pass on their own and still break the
base once both land (#18994 with #18991, #19079): each was checked against the
tip of when it was pushed. This closes that gap at merge time.

A pull request that changes Swift (or Rust) is fresh when feat-cmux-next has no
Swift or Rust change the head has not merged. A fresh head merges as it is,
under the gate its lane already ran. A stale one gets the current tip merged in
(one merge commit, pushed to its branch) and merges only once that merged head
passes:
  - Swift: the cmux-next Swift canary on the merged head (its push starts the
    pull request's checks again), or --check where the canary does not run
    (it covers package-only edits; App changes have no pull request compile);
  - Rust: --check (the lane's Rust build or test), run in a worktree of the
    merged head with FRESH_SHA set to it.
Without the --check a class needs, it pushes the merged head, prints its SHA
and exits 3: run the check on it, then run this again with --check. When the
tip gains another Swift or Rust change meanwhile, it merges again, up to
--rounds times. It always merges with --squash --match-head-commit, never
--admin. A fork's branch cannot be pushed: a stale fork head is refused.

GitHub's pull request head lags a push by seconds to minutes. After it pushes
(or when the branch is ahead of what GitHub shows), it polls the head until
GitHub shows the pushed SHA, up to FRESH_MERGE_HEAD_SECONDS; only a third SHA
counts as the branch moving. A fetch that races another worktree's fetch is
retried a few times.

With --wait-checks it also waits for every pull request check on the head it
merges (glaeda-gh wait pr --until done --sha) and refuses on any check that is
not green, except report-only jobs (macOS 27), Tour the app and cancelled
autofix or bot jobs.

Usage: scripts/cmux-next/fresh-merge.py N [--check CMD] [--wait-checks] [--rounds 3] [--dry-run]
Run it from a checkout of manaflow-ai/cmux whose origin is GitHub.
"""
from __future__ import annotations

import argparse
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

REPO = "manaflow-ai/cmux"
BASE = "feat-cmux-next"
CANARY = "cmux-next Swift canary"
POLL_SECONDS = float(os.environ.get("FRESH_MERGE_POLL_SECONDS", "30"))
# A just-pushed head has no checks yet; give CI this long to report before
# reading "no canary pending" as "no canary will run".
GRACE_SECONDS = float(os.environ.get("FRESH_MERGE_GRACE_SECONDS", "120"))
WAIT_SECONDS = float(os.environ.get("FRESH_MERGE_WAIT_SECONDS", str(40 * 60)))
# How long GitHub may take to show a pushed head on the pull request, and the
# first poll interval (it doubles up to HEAD_POLL_MAX_SECONDS).
HEAD_SECONDS = float(os.environ.get("FRESH_MERGE_HEAD_SECONDS", "300"))
HEAD_POLL_SECONDS = float(os.environ.get("FRESH_MERGE_HEAD_POLL_SECONDS", "5"))
HEAD_POLL_MAX_SECONDS = 30.0
FETCH_ATTEMPTS = 4
FETCH_RETRY_SECONDS = float(os.environ.get("FRESH_MERGE_FETCH_RETRY_SECONDS", "2"))
# --wait-checks: how long every check on the head may take to finish.
CHECKS_SECONDS = int(os.environ.get("FRESH_MERGE_CHECKS_SECONDS", str(2 * 60 * 60)))
GREEN = {"SUCCESS", "SKIPPED", "NEUTRAL"}
PENDING = {"QUEUED", "IN_PROGRESS", "PENDING", "WAITING", "REQUESTED", "EXPECTED"}


class Refused(Exception):
    def __init__(self, message: str, code: int = 1):
        super().__init__(message)
        self.code = code


def classes(paths) -> set[str]:
    found = set()
    for path in paths:
        name = path.rsplit("/", 1)[-1]
        if name.endswith(".swift") or name in ("Package.swift", "Package.resolved", "project.pbxproj"):
            found.add("swift")
        if name.endswith(".rs") or name in ("Cargo.toml", "Cargo.lock", "rust-toolchain.toml"):
            found.add("rust")
    return found


def git(*args: str, cwd: str | None = None) -> str:
    result = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        raise Refused(f"git {' '.join(args)} failed: {(result.stderr or result.stdout).strip()}")
    return result.stdout.strip()


def fetch_retrying(*refs: str) -> None:
    """git fetch origin refs, retried: another worktree fetching at the same moment
    updates the shared origin/* refs under it ("incorrect old value provided",
    "cannot lock ref")."""
    for attempt in range(1, FETCH_ATTEMPTS + 1):
        try:
            git("fetch", "--quiet", "origin", *refs)
            return
        except Refused as refusal:
            if attempt == FETCH_ATTEMPTS:
                raise
            say(f"fetch failed (attempt {attempt}/{FETCH_ATTEMPTS}), retrying: {str(refusal).splitlines()[-1]}")
            time.sleep(FETCH_RETRY_SECONDS * attempt)


def fetch(ref: str) -> str:
    fetch_retrying(f"refs/heads/{ref}")
    return git("rev-parse", "FETCH_HEAD")  # per worktree, so lanes do not race on it


def pull_request(number: int) -> dict:
    fields = "number,headRefOid,headRefName,baseRefName,isCrossRepository,mergeable,files,statusCheckRollup"
    result = subprocess.run(["gh", "pr", "view", str(number), "-R", REPO, "--json", fields],
                            capture_output=True, text=True)
    if result.returncode != 0:
        raise Refused(f"gh pr view {number}: {(result.stderr or result.stdout).strip()}")
    return json.loads(result.stdout)


def say(message: str) -> None:
    print(f"fresh-merge: {message}", flush=True)


def wait_for_head(number: int, sha: str, previous: str) -> dict:
    """Polls until GitHub shows sha as the head of #number and returns the pull request.
    previous (the head before the push) is GitHub lagging; any other SHA means the
    branch moved."""
    started = time.monotonic()
    interval = HEAD_POLL_SECONDS
    while True:
        pr = pull_request(number)
        shown = pr["headRefOid"]
        if shown == sha:
            return pr
        if shown != previous:
            raise Refused(f"#{number} moved to {shown[:12]} while waiting on {sha[:12]}")
        waited = time.monotonic() - started
        if waited >= HEAD_SECONDS:
            raise Refused(f"GitHub still shows #{number} at {previous[:12]} {waited:.0f}s after "
                          f"{sha[:12]} was pushed; run again once it shows {sha[:12]}")
        say(f"GitHub still shows #{number} at {previous[:12]}; waiting for {sha[:12]}")
        time.sleep(min(interval, max(HEAD_SECONDS - waited, 0)))
        interval = min(interval * 2, HEAD_POLL_MAX_SECONDS)


def waived(check: dict) -> bool:
    name = check.get("name") or check.get("context") or ""
    workflow = check.get("workflowName") or ""
    if ("report-only" in name and "macOS 27" in name) or name == "Tour the app":
        return True
    cancelled = check.get("conclusion") == "CANCELLED"
    return cancelled and re.search(r"\b(autofix|bot)\b|\[bot\]", f"{workflow} {name}", re.I) is not None


def wait_for_checks(number: int, sha: str) -> None:
    """Waits for every check on sha to finish; refuses on any red that is not waived."""
    say(f"waiting for every check on {sha[:12]} (glaeda-gh, up to {CHECKS_SECONDS // 60} min)")
    try:
        result = subprocess.run(["glaeda-gh", "wait", "pr", f"{REPO}#{number}", "--until", "done",
                                 "--sha", sha, "--timeout", str(CHECKS_SECONDS)],
                                stdout=subprocess.DEVNULL)
    except FileNotFoundError:
        raise Refused("--wait-checks needs glaeda-gh on PATH; not merging")
    if result.returncode == 2:
        raise Refused(f"the checks on {sha[:12]} did not finish in {CHECKS_SECONDS // 60} min")
    if result.returncode == 4:
        raise Refused(f"#{number} conflicts with {BASE}; merge it yourself first", 2)
    pr = pull_request(number)
    if pr["headRefOid"] != sha:
        raise Refused(f"#{number} moved to {pr['headRefOid'][:12]} while waiting on its checks")
    checks = pr.get("statusCheckRollup") or []
    if not checks:
        raise Refused(f"GitHub reports no checks on {sha[:12]}; not merging")
    red = []
    for check in checks:
        outcome = check.get("conclusion") or check.get("state") or check.get("status") or "PENDING"
        if outcome not in GREEN and not waived(check):
            red.append(f"{outcome} {check.get('name') or check.get('context')}")
    if red:
        raise Refused(f"checks on {sha[:12]} are not green; not merging:\n  " + "\n  ".join(red))
    say(f"every check on {sha[:12]} is green or waived")


def stale_paths(head: str, tip: str, wanted: set[str]) -> list[str]:
    base = git("merge-base", head, tip)
    changed = git("diff", "--name-only", base, tip).splitlines()
    return [path for path in changed if classes([path]) & wanted]


def merge_tip(pr: dict, head: str, tip: str) -> str:
    """Merges the tip into the head in a scratch worktree and pushes it; returns the new head
    once GitHub shows it on the pull request."""
    scratch = tempfile.mkdtemp(prefix="cmux-fresh-merge-")
    tree = os.path.join(scratch, "tree")
    git("worktree", "add", "--quiet", "--detach", tree, head)
    try:
        result = subprocess.run(["git", "merge", "--no-ff", "--no-verify", "--quiet", "-m",
                                 f"Merge {BASE} into {pr['headRefName']} (fresh-merge)", tip],
                                cwd=tree, capture_output=True, text=True)
        if result.returncode != 0:
            raise Refused(f"the tip does not merge cleanly into #{pr['number']}; merge {BASE} yourself "
                          f"and push:\n{(result.stdout + result.stderr).strip()}", 2)
        fresh = git("rev-parse", "HEAD", cwd=tree)
        git("push", "--quiet", "origin", f"{fresh}:refs/heads/{pr['headRefName']}", cwd=tree)
    finally:
        subprocess.run(["git", "worktree", "remove", "--force", tree], capture_output=True)
        shutil.rmtree(scratch, ignore_errors=True)
    wait_for_head(pr["number"], fresh, head)
    return fresh


def wait_for_canary(number: int, sha: str) -> str | None:
    """The canary's conclusion on sha, or None when it does not run there."""
    started = time.monotonic()
    while True:
        pr = pull_request(number)
        if pr["headRefOid"] != sha:
            raise Refused(f"#{number} moved to {pr['headRefOid'][:12]} while waiting on {sha[:12]}")
        checks = pr.get("statusCheckRollup") or []
        canary = [check for check in checks if check.get("name") == CANARY]
        if canary and all(check.get("status") == "COMPLETED" for check in canary):
            conclusions = {check.get("conclusion") for check in canary}
            if "SUCCESS" in conclusions:
                return "SUCCESS"
            return None if conclusions <= {"SKIPPED", "NEUTRAL"} else sorted(conclusions)[0]
        waited = time.monotonic() - started
        settled = not any((check.get("status") or check.get("state")) in PENDING for check in checks)
        if not canary and settled and waited >= GRACE_SECONDS:
            return None
        if waited >= WAIT_SECONDS:
            raise Refused(f"the Swift canary on {sha[:12]} did not finish in {WAIT_SECONDS / 60:.0f} min")
        time.sleep(POLL_SECONDS)


def run_check(command: str, sha: str) -> None:
    scratch = tempfile.mkdtemp(prefix="cmux-fresh-check-")
    tree = os.path.join(scratch, "tree")
    git("worktree", "add", "--quiet", "--detach", tree, sha)
    try:
        say(f"running --check on {sha[:12]}")
        result = subprocess.run(command, shell=True, cwd=tree, env=dict(os.environ, FRESH_SHA=sha))
        if result.returncode != 0:
            raise Refused(f"--check failed on {sha[:12]} (exit {result.returncode}); not merging")
    finally:
        subprocess.run(["git", "worktree", "remove", "--force", tree], capture_output=True)
        shutil.rmtree(scratch, ignore_errors=True)


def land(number: int, check: str | None, rounds: int, dry_run: bool, wait_checks: bool = False) -> int:
    pr = pull_request(number)
    if pr["baseRefName"] != BASE:
        raise Refused(f"#{number} targets {pr['baseRefName']}, not {BASE}")
    if pr.get("mergeable") == "CONFLICTING":
        raise Refused(f"#{number} conflicts with {BASE}; merge it yourself first", 2)
    wanted = classes(file["path"] for file in pr.get("files") or [])
    head = pr["headRefOid"]
    for round_number in range(rounds):
        tip = fetch(BASE)
        if not wanted:
            say(f"#{number} changes no Swift or Rust; merging {head[:12]} as it is")
            break
        if pr["isCrossRepository"]:
            fetch_retrying(f"refs/pull/{number}/head")
        else:
            pushed = fetch(pr["headRefName"])
            if pushed != head and round_number > 0:
                raise Refused(f"#{number}'s branch moved to {pushed[:12]} after {head[:12]}; not merging")
            if pushed != head:  # the branch is ahead of what GitHub shows: let it catch up
                pr = wait_for_head(number, pushed, head)
                head = pushed
                wanted = classes(file["path"] for file in pr.get("files") or [])
        stale = stale_paths(git("rev-parse", "FETCH_HEAD") if pr["isCrossRepository"] else head, tip, wanted)
        if not stale:
            say(f"#{number} ({'+'.join(sorted(wanted))}) is fresh against {BASE} {tip[:12]}")
            if check:
                run_check(check, head)
            break
        say(f"{BASE} {tip[:12]} has {len(stale)} {'/'.join(sorted(wanted))} change(s) #{number} lacks, "
            f"e.g. {stale[0]}")
        if pr["isCrossRepository"]:
            raise Refused(f"#{number} is from a fork; its owner must merge {BASE} into it", 2)
        if dry_run:
            say("dry run: would merge the tip into the branch and recheck")
            return 0
        head = merge_tip(pr, head, tip)
        say(f"pushed {head[:12]} (the tip merged into {pr['headRefName']})")
        needs_check = "rust" in wanted
        if "swift" in wanted:
            conclusion = wait_for_canary(number, head)
            if conclusion is None:
                needs_check = True
            elif conclusion != "SUCCESS":
                raise Refused(f"the Swift canary is {conclusion} on the merged head {head[:12]}; not merging")
            else:
                say(f"Swift canary green on {head[:12]}")
        if needs_check:
            if not check:
                raise Refused(f"run your {'/'.join(sorted(wanted))} check on {head[:12]}, then: "
                              f"scripts/cmux-next/fresh-merge.py {number} --check '<command>'", 3)
            run_check(check, head)
        pr = pull_request(number)
        if pr["headRefOid"] != head:
            raise Refused(f"#{number} moved to {pr['headRefOid'][:12]}; not merging")
    else:
        raise Refused(f"{BASE} kept gaining {'/'.join(sorted(wanted))} changes for {rounds} rounds; run again")
    if dry_run:
        say(f"dry run: would merge #{number} at {head[:12]}")
        return 0
    if wait_checks:
        wait_for_checks(number, head)
    result = subprocess.run(["gh", "pr", "merge", str(number), "-R", REPO, "--squash",
                             "--match-head-commit", head])
    if result.returncode != 0:
        raise Refused(f"gh pr merge {number} failed (exit {result.returncode})")
    say(f"merged #{number} at {head[:12]}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("number", type=int, help="the pull request into feat-cmux-next")
    parser.add_argument("--check", help="shell command that validates the head (FRESH_SHA, run in its worktree)")
    parser.add_argument("--rounds", type=int, default=3, help="tip merges before giving up (default 3)")
    parser.add_argument("--dry-run", action="store_true", help="say what it would do; push and merge nothing")
    parser.add_argument("--wait-checks", action="store_true",
                        help="before merging, wait for every check on the head (glaeda-gh) and refuse on "
                             "a red other than report-only, Tour the app or a cancelled autofix/bot job")
    args = parser.parse_args()
    try:
        return land(args.number, args.check, args.rounds, args.dry_run, args.wait_checks)
    except Refused as refusal:
        print(f"fresh-merge: {refusal}", file=sys.stderr)
        return refusal.code


if __name__ == "__main__":
    sys.exit(main())
