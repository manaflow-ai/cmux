#!/usr/bin/env python3
"""The fast gate gh-merge-green applies to pull requests into feat-cmux-next.

    merge_fast_gate.py OWNER/REPO NUMBER SHA [--next-covered] [--timeout SECONDS] [--interval SECONDS]

It waits only for the PR's fast lanes on the exact head, not the full suites:
path routing, the cmux-next fast tier, and the compile of each touched area that
routing started (the Swift canary, the app scheme Debug compile, the web
react-apps-check). The full suites run after the merge, and the culprit bot and
the base sheriff revert or fix forward. A check that already finished red in a
gating family (web, app size, crash, god-file, l10n or concurrency lint) still
blocks; one still running does not. Risk evidence is waited for, and a red one
refuses outright. gh-merge-green --full keeps the old wait for
every check.

Each poll is one GraphQL read (`gh pr view --json`), never a REST loop.
Prints `waited=<seconds>` and `checked=<names>`, then `red=<name>` for each
completed red that gh-merge-green may still excuse when the base has it.
Exit 0: pass (maybe with reds to excuse); 1: refused (the reason on stderr).
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from typing import Callable

ROUTING = "cmux-next path routing"
FAST = re.compile(r"^(cmux-next fast tier|cmux-next Swift canary|cmux app scheme compile \(Debug\)|(.* / )?react-apps-check)$")
GATING = re.compile(r"react-apps-check|web status|app[- ]?size|size[- ]cap|crash|god[ -]?files?|l10n|locali[sz]ation|concurrency", re.I)
# Never waived or base-excused: it reads only the description, and the risk:waived
# label is its waiver (gh-merge-green full gate, docs/ci/risk-tiers.md on feat-cmux-next).
RISK = re.compile(r"^risk evidence$", re.I)
PASSING = {"SUCCESS", "NEUTRAL", "SKIPPED"}


class Refused(Exception):
    pass


def gh_json(*args: str) -> dict:
    out = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        raise Refused(f"cannot read the pull request ({out.stderr.strip()[:200]})")
    return json.loads(out.stdout)


def latest(rollup: list[dict]) -> dict[str, tuple[str, str]]:
    """name -> (status, conclusion), upper case. The rollup is not ordered by time, so of
    several CheckRuns of one name (a rerun) the latest startedAt wins, then completedAt,
    then list order; one not started yet (no startedAt, not completed) counts as newest."""
    checks: dict[str, tuple[str, str]] = {}
    newest: dict[str, tuple] = {}
    for index, item in enumerate(rollup):
        if item.get("__typename") == "StatusContext" or "context" in item:
            state = (item.get("state") or "").upper()
            checks[item.get("context", "")] = ("COMPLETED" if state not in ("PENDING", "EXPECTED") else "IN_PROGRESS",
                                               {"ERROR": "FAILURE"}.get(state, state))
            continue
        name = item.get("name", "")
        status = (item.get("status") or "").upper()
        started = item.get("startedAt") or ("\uffff" if status != "COMPLETED" else "")
        key = (started, item.get("completedAt") or "", index)
        if name in newest and newest[name] > key:
            continue
        newest[name] = key
        checks[name] = (status, (item.get("conclusion") or "").upper())
    return checks


def evaluate(checks: dict[str, tuple[str, str]], files: list[str], touches_next: bool) -> tuple[list[str], list[str], list[str]]:
    """(fast lanes to wait for, fast lanes seen, completed gating reds). touches_next: the
    change is inside cmux-next.yml's pull_request paths, so a cmux-next run is coming."""
    waiting, seen, reds = [], [], []
    if touches_next and ROUTING not in checks:
        waiting.append(ROUTING)
    for name, (status, conclusion) in sorted(checks.items()):
        if RISK.match(name):
            seen.append(name)
            if status != "COMPLETED":
                waiting.append(name)
            elif conclusion not in PASSING:
                raise Refused(f"'{name}' is {conclusion.lower()} on the exact head; it is never waived "
                              "(a maintainer's risk:waived label is its waiver)")
            continue
        fast = name == ROUTING or bool(FAST.match(name))
        if fast:
            if conclusion == "SKIPPED":
                continue
            seen.append(name)
            if status != "COMPLETED":
                waiting.append(name)
            elif conclusion not in PASSING:
                reds.append(name)
        elif status == "COMPLETED" and conclusion not in PASSING and GATING.search(name):
            reds.append(name)
    routed = checks.get(ROUTING, ("", ""))[0] == "COMPLETED"
    if touches_next and routed and "cmux-next fast tier" not in checks:
        waiting.append("cmux-next fast tier")
    if any(f.startswith("webviews/") for f in files) and not any(n.endswith("react-apps-check") for n in checks):
        # The caller job "web" finishing without one means none is coming: a red caller is a red.
        status, conclusion = checks.get("web", ("", ""))
        if status != "COMPLETED":
            waiting.append("react-apps-check")
        elif conclusion not in PASSING:
            reds.append("web")
    return waiting, seen, reds


def run(repo: str, number: str, sha: str, timeout: float, interval: float, touches_next: bool,
        read: Callable[..., dict] = gh_json, clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep) -> tuple[float, list[str], list[str]]:
    start = clock()
    while True:
        pr = read("pr", "view", number, "--repo", repo, "--json", "headRefOid,statusCheckRollup,files")
        if pr.get("headRefOid") != sha:
            raise Refused(f"the head moved to {pr.get('headRefOid')} while waiting on {sha}")
        files = [f.get("path", "") for f in pr.get("files") or []]
        waiting, seen, reds = evaluate(latest(pr.get("statusCheckRollup") or []), files, touches_next)
        if not waiting:
            return clock() - start, seen, reds
        if clock() - start >= timeout:
            raise Refused(f"still waiting on {', '.join(waiting)} after {int(clock() - start)}s")
        sleep(interval)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("repo")
    parser.add_argument("number")
    parser.add_argument("sha")
    parser.add_argument("--timeout", type=float, default=2400)
    parser.add_argument("--interval", type=float, default=30)
    parser.add_argument("--next-covered", action="store_true",
                        help="the change is inside cmux-next.yml's pull_request paths")
    args = parser.parse_args(argv)
    try:
        waited, seen, reds = run(args.repo, args.number, args.sha, args.timeout, args.interval, args.next_covered)
    except Refused as error:
        print(error, file=sys.stderr)
        return 1
    print(f"waited={int(waited)}")
    print("checked=" + ", ".join(seen))
    for name in reds:
        print(f"red={name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
