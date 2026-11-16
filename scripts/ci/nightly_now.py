#!/usr/bin/env python3
"""nightly-now: ship a feat-cmux-next commit to cmux NIGHTLY now.

    scripts/ci/nightly_now.py [SHA] [--repo OWNER/REPO] [--dry-run]

1. Dispatches nightly-next-tick.yml on main for SHA (default: the tip of feat-cmux-next). A dispatch for one
   commit skips the rolling rule's wait: the tick asks main's promote job to move nightly-next to the newest
   buildable commit at or before SHA, and that push starts the build.
2. Dispatches nightly-next-supersede.yml on nightly-next, which drops an older nightly-next run that holds the
   push or sign group with none of its build, sign or publish jobs started
   (scripts/ci/nightly_next_supersede.py). The promotion's own push starts that workflow again, and it waits
   out a holder's last minutes (--settle) so the new run never sits behind a stale holder.
Nothing here cancels anything, and the build request goes first: a failed or missing cleanup only warns.
--dry-run prints both dispatches without sending them.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from collections.abc import Callable, Sequence

TICK, SUPERSEDE = "nightly-next-tick.yml", "nightly-next-supersede.yml"
SOURCE_BRANCH, NIGHTLY_BRANCH = "feat-cmux-next", "nightly-next"
FULL_SHA = re.compile(r"[0-9a-f]{40}")
SHORT_SHA = re.compile(r"[0-9a-f]{7,39}")

Run = Callable[[Sequence[str]], str]


def run_gh(args: Sequence[str]) -> str:
    try:
        result = subprocess.run(["gh", *args], capture_output=True, text=True, stdin=subprocess.DEVNULL)
    except OSError as error:
        raise RuntimeError(f"gh could not run: {error}") from error
    if result.returncode:
        raise RuntimeError(f"gh {' '.join(args[:3])} failed: {result.stderr.strip()[:300]}")
    return result.stdout


def ls_remote_sha(repo: str, branch: str) -> str:
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com").rstrip("/")
    try:
        out = subprocess.run(["git", "ls-remote", "--exit-code", f"{server}/{repo}", f"refs/heads/{branch}"],
                             capture_output=True, text=True, timeout=60, check=True, stdin=subprocess.DEVNULL,
                             env={**os.environ, "GIT_TERMINAL_PROMPT": "0"}).stdout
    except (OSError, subprocess.SubprocessError) as error:
        raise RuntimeError(f"git ls-remote {branch} failed: {error}") from error
    sha = out.split()[0].lower() if out.split() else ""
    if not FULL_SHA.fullmatch(sha):
        raise RuntimeError(f"{branch} is {sha!r}")
    return sha


def resolve(sha: str | None, repo: str, gh: Run, tip: Callable[[str, str], str]) -> str:
    """The full commit to ask for: SHA as given (a short one through the API), else the source branch's tip."""
    if not sha:
        return tip(repo, SOURCE_BRANCH)
    sha = sha.strip().lower()
    if FULL_SHA.fullmatch(sha):
        return sha
    if not SHORT_SHA.fullmatch(sha):
        raise ValueError(f"{sha!r} is not a commit sha")
    full = gh(["api", f"repos/{repo}/commits/{sha}", "--jq", ".sha"]).strip().lower()
    if not FULL_SHA.fullmatch(full):
        raise ValueError(f"{sha} did not resolve to one commit ({full!r})")
    return full


def dispatches(repo: str, sha: str) -> list[list[str]]:
    return [["workflow", "run", TICK, "--repo", repo, "--ref", "main", "-f", f"sha={sha}"],
            ["workflow", "run", SUPERSEDE, "--repo", repo, "--ref", NIGHTLY_BRANCH]]


def main(argv: Sequence[str] | None = None, *, gh: Run = run_gh, tip: Callable[[str, str], str] = ls_remote_sha,
         log: Callable[[str], None] = print) -> int:
    parser = argparse.ArgumentParser(prog="nightly-now", description=__doc__.split("\n\n")[0])
    parser.add_argument("sha", nargs="?", help=f"commit on {SOURCE_BRANCH} (default: its tip)")
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY") or "manaflow-ai/cmux")
    parser.add_argument("--dry-run", action="store_true", help="print the dispatches without sending them")
    args = parser.parse_args(argv)
    try:
        sha = resolve(args.sha, args.repo, gh, tip)
    except (ValueError, RuntimeError) as error:
        log(f"nightly-now: {error}")
        return 2
    build, cleanup = dispatches(args.repo, sha)
    if args.dry_run:
        for command in (build, cleanup):
            log("nightly-now: would run gh " + " ".join(command))
        return 0
    try:
        gh(build)
    except RuntimeError as error:
        log(f"nightly-now: the build request failed: {error}")
        return 1
    log(f"nightly-now: asked for {sha} ({TICK} on main, rolling wait skipped); the tick promotes the newest "
        "buildable commit at or before it.")
    try:
        gh(cleanup)
        log(f"nightly-now: started {SUPERSEDE} on {NIGHTLY_BRANCH}: it drops older runs that never started and "
            "hold the tip's group.")
    except RuntimeError as error:
        log(f"nightly-now: warning: {SUPERSEDE} could not start ({error}); the promotion's push starts it")
    return 0


if __name__ == "__main__":
    sys.exit(main())
