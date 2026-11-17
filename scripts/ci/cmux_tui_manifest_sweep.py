#!/usr/bin/env python3
"""Re-run the runs of feat-cmux-next commits whose tree is published but whose manifest is missing.

A run that defers its tree key to an owner builds nothing and writes its commit
manifest once the tree is published. The owner re-runs it after it publishes
(cmux_tui_tree_handoff.py --published), but GitHub refuses to re-run a run
still in progress. A deferring run that read the tree before the owner
published, and was still running when the owner looked, therefore ended with no
cmux-tui/<sha>/manifest.json while every check was green (review of
cmux#42580, F1).

This sweep is the post-publish 404 detector for that gap. mark-tree-commits
runs it on every feat-cmux-next push, after it writes the tree-commit markers.
It looks at the last WINDOW first-parent commits of this run's commit and of
the branch tip. A commit whose tree-commit marker exists (its tree is
published) and whose manifest answers 404 has its newest feat-cmux-next push
run re-run, if that run has completed. The re-run finds the tree published and
writes the manifest from it (adopt-commit-manifest). A run still in progress is
left for the next push's sweep, so nothing here waits (cx-urd.26: no runner
minutes spent waiting on owners). Only commits whose workflow has the
adopt-commit-manifest job are re-run: an older commit's re-run runs that
commit's workflow, which would rebuild on macOS or write nothing.

The commits' runs come from one listing of the branch's newest 100 push runs,
not one call per commit; a commit past it is asked for by itself. A GitHub rate
limit does not fail the sweep (2026-11-17: feat-cmux-next run 44024006431 went
red on "could not list the runs of 298219a6b387: gh: API rate limit
exceeded"): the sweep stops spending the quota, warns naming the commits it
did not judge and passes, and the next push's sweep looks again. It does not
wait for the limit to lift. A refused re-run that is not the rate limit, or a
malformed answer, still fails the step.

usage: cmux_tui_manifest_sweep.py --repo OWNER/NAME [--window N] [--tip-branch B]
Needs GH_TOKEN with actions: write; GH_TOKEN_SPARE as cmux_tui_tree_handoff.py.
"""
from __future__ import annotations

import argparse
import http.client
import json
import os
import subprocess
import sys
import time
from typing import Callable, Iterable, Mapping, Any
from urllib.error import URLError
from urllib.request import Request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cmux_tui_tree_handoff as handoff  # noqa: E402
import deadline_http  # noqa: E402

BASE = "https://files.cmux.com/cmux-tui"
WORKFLOW = ".github/workflows/cmux-tui-artifacts.yml"
# A commit whose workflow has this job writes its manifest on a re-run.
ADOPT_JOB = "\n  adopt-commit-manifest:\n"


def cdn_status(url: str) -> int:
    """The HTTP status of a complete read, 0 when none came."""
    try:
        status, _, _ = deadline_http.request(Request(f"{url}?sweep={int(time.time())}"), 30)
        return status
    except (URLError, http.client.HTTPException, OSError):
        return 0


def sweep(
    revs: Iterable[str],
    *,
    adopts: Callable[[str], bool],
    status: Callable[[str], int],
    find_run: Callable[[str], Mapping[str, Any] | None],
    rerun: Callable[[int], bool],
) -> tuple[list[str], list[str]]:
    """(the commits whose run was re-run, the problems that fail the step)."""
    rerun_commits: list[str] = []
    problems: list[str] = []
    for rev in revs:
        if status(f"{BASE}/tree-commits/{rev}.json") != 200:
            continue  # not marked: its tree is not published (or the read failed; the next push reads again)
        manifest = status(f"{BASE}/{rev}/manifest.json")
        if manifest != 404:
            if manifest != 200:
                print(f"::warning::could not read the manifest of {rev[:12]} (HTTP {manifest or 'none'}); not judged this run")
            continue
        if not adopts(rev):
            print(f"{rev[:12]}: tree published, manifest missing; its workflow predates adopt-commit-manifest, not re-run")
            continue
        run = find_run(rev)
        if run is None:
            print(f"::warning title=commit manifest missing::{rev[:12]}: tree published, manifest missing, and no feat-cmux-next push run found")
            continue
        allowed, why = handoff.may_rerun(run, handoff.PUBLISHED_MAX_ATTEMPT)
        if not allowed:
            # In progress: its own adopt step or the next push's sweep covers it. Capped: say so, loudly.
            level = "notice" if run.get("status") != "completed" else "warning"
            print(f"::{level} title=commit manifest missing::{rev[:12]}: tree published, manifest missing; run {run['id']} not re-run: {why}")
            continue
        if rerun(int(run["id"])):
            print(f"{rev[:12]}: tree published, manifest missing; re-ran run {run['id']} ({why}), which writes it")
            rerun_commits.append(rev)
        else:
            problems.append(f"could not re-run run {run['id']} of {rev[:12]}")
    return rerun_commits, problems


def _call(what: str, *args: str) -> subprocess.CompletedProcess[str]:
    """handoff._gh, with a rate-limit refusal raised as handoff.QuotaRefused that names what was refused."""
    try:
        result = handoff._gh(*args)
    except handoff.QuotaRefused as error:
        raise handoff.QuotaRefused(error.retry_before, f"{what}: {error.detail or error}") from None
    if handoff.rate_limited(result):  # a stand-in _gh may answer the refusal instead of raising it
        raise handoff.QuotaRefused(handoff._rate_limit_retry_before(handoff._refusal_text(result)),
                                   f"{what}: {result.stderr.strip()}")
    return result


def make_find_run(repo: str, tip_branch: str) -> Callable[[str], Mapping[str, Any] | None]:
    """find_run for sweep(): the newest push run of a commit on tip_branch. The first commit asked for reads
    the branch's newest 100 push runs in one call, and it answers every commit in it; a commit past those
    is asked for by itself."""
    base = f"repos/{repo}/actions/workflows/cmux-tui-artifacts.yml/runs?event=push&branch={tip_branch}"
    listed: dict[str, Mapping[str, Any]] | None = None

    def runs_of(query: str, what: str) -> list[Mapping[str, Any]]:
        result = _call(f"could not list the runs of {what}", "api", f"{base}&{query}")
        if result.returncode != 0:
            raise RuntimeError(f"could not list the runs of {what}: {result.stderr.strip()}")
        try:
            return list(json.loads(result.stdout).get("workflow_runs") or [])
        except (ValueError, AttributeError) as error:
            raise RuntimeError(f"the runs of {what} are not a GitHub answer: {error}") from None

    def find_run(rev: str) -> Mapping[str, Any] | None:
        nonlocal listed
        if listed is None:
            listed = {}
            for run in sorted(runs_of("per_page=100", tip_branch), key=lambda run: int(run["id"])):
                listed[str(run.get("head_sha"))] = run  # newest last, so it wins
        if rev in listed:
            return listed[rev]
        runs = runs_of(f"head_sha={rev}&per_page=5", rev[:12])
        return max(runs, key=lambda run: int(run["id"])) if runs else None

    return find_run


def git_revs(window: int, tip_branch: str) -> list[str]:
    def rev_list(ref: str) -> list[str]:
        return subprocess.run(["git", "rev-list", "--first-parent", "-n", str(window), ref],
                              capture_output=True, text=True, check=True).stdout.split()

    revs = rev_list("HEAD")
    shallow = subprocess.run(["git", "rev-parse", "--is-shallow-repository"], capture_output=True, text=True).stdout.strip()
    depth = [f"--depth={window + 1}"] if shallow == "true" else []
    fetched = subprocess.run(["git", "fetch", "-q", "--no-tags", *depth, "origin", f"refs/heads/{tip_branch}"],
                             capture_output=True, text=True)
    if fetched.returncode == 0:
        revs += [rev for rev in rev_list("FETCH_HEAD") if rev not in revs]
    else:
        print(f"::warning::could not fetch {tip_branch}; sweeping this run's window only")
    return revs


def adopts(rev: str) -> bool:
    shown = subprocess.run(["git", "show", f"{rev}:{WORKFLOW}"], capture_output=True, text=True)
    return shown.returncode == 0 and ADOPT_JOB in shown.stdout


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--window", type=int, default=40)
    parser.add_argument("--tip-branch", default="feat-cmux-next")
    args = parser.parse_args(argv)
    if not os.environ.get("GH_TOKEN"):
        print("::error::the manifest sweep needs GH_TOKEN")
        return 2

    # The sweep never waits (each push sweeps again): a rate limit ends it at once.
    handoff.RATE_LIMIT_WAIT_S = 0
    find_run = make_find_run(args.repo, args.tip_branch)
    refused: list[int] = []

    def rerun(run_id: int) -> bool:
        result = _call(f"could not re-run run {run_id}", "run", "rerun", str(run_id), "--repo", args.repo)
        if result.returncode != 0:
            print(f"::warning::could not re-run run {run_id}: {result.stderr.strip()}")
            refused.append(run_id)
        return result.returncode == 0

    revs = git_revs(args.window, args.tip_branch)
    judged: list[str] = []

    def find_run_judged(rev: str) -> Mapping[str, Any] | None:
        judged.append(rev)
        return find_run(rev)

    try:
        rerun_commits, problems = sweep(revs, adopts=adopts, status=cdn_status, find_run=find_run_judged, rerun=rerun)
    except handoff.QuotaRefused as error:
        # The commit asked for last was not judged; with every commit after it, the next push's sweep looks again.
        left = revs[revs.index(judged[-1]):] if judged else revs
        if refused:  # a real refusal before the limit is still the step's red
            print(f"::error title=commit manifests missing::could not re-run runs {', '.join(map(str, refused))}; "
                  f"then {error}")
            return 1
        print(f"::warning title=manifest sweep stopped (rate limit)::{error}. Not judged this run, left for the next "
              f"push's sweep: {', '.join(rev[:12] for rev in left)}")
        return 0
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f"::error title=manifest sweep failed::{error}")
        return 1
    print(f"manifest sweep: {len(rerun_commits)} runs re-run")
    if problems:
        print(f"::error title=commit manifests missing::{'; '.join(problems)}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
