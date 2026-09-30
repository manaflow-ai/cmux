#!/usr/bin/env python3
"""Pick the newest main commit whose guards passed, to merge into a branch.

Merging main while main is red hands the branch main's failure. On 2026-09-25
#14724 broke tests/test_runner_label_policy.py on main; a branch merged main
in the hour before #14742 fixed it, its guards failed on push, the macOS
admission gate declined compile admission, and nobody knew the failure came
from main until they read the logs. Merging the last green commit instead
keeps a branch's red checks its own.

The verdict is the "CI fast guards" workflow (ci-fast-guards.yml): ci-guards.yml's
`ci` group, run whole on every push to main. ci.yml's `guards / Guard status`
is not used: it runs only the guard groups a commit's own diff routes, so a
green one does not say main's guards pass at that commit. A commit is

- success: its newest fast-guard run on main concluded success,
- failure: that run concluded failure, timed_out, startup_failure or
  action_required,
- pending: that run is still queued or running,
- missing: no run (a commit from before #14757, or a cancelled/skipped run).

Candidates are main's first-parent commits the branch does not have yet,
newest first, at most `limit` (capped at 100) of them. The newest success
wins; every newer commit is reported as skipped with its verdict. All verdicts
come from one REST request (the workflow's last 100 push runs on main, cached
by gh for a minute), never a per-commit call or a polling loop. Only push runs
count: the workflow also runs on pull requests, and a fork's pull request from
its own `main` reports head_branch `main`, which would both crowd main's runs
out of the one page and attach a pull request's verdict to a sha.

Stdlib only, so pr-catch-up.yml can run the trusted copy with `python3 -I`.

Usage:
  last_green_base.py --repo DIR --ref origin/main [--head HEAD] [--limit 40] [--json]
Exit codes: 0 a green commit was chosen or the branch already has main's tip,
1 no green commit among the candidates, 2 error (git, GitHub).
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable
from urllib.parse import quote

GITHUB_REPOSITORY = "manaflow-ai/cmux"
GUARD_WORKFLOW = "ci-fast-guards.yml"
GUARD_CHECK = "CI fast guards"
DEFAULT_LIMIT = 40
# One page of runs; one push to main starts at most one run, so the page covers
# at least this many first-parent commits.
RUNS_PER_PAGE = 100
FAILED = frozenset({"failure", "timed_out", "startup_failure", "action_required"})
PENDING = frozenset({"queued", "in_progress", "waiting", "pending", "requested"})

Verdicts = dict[str, str]
# (candidate shas) -> {sha: verdict}; GitHub in production, a dict in tests.
VerdictSource = Callable[[list[str]], Verdicts]


class SelectionError(Exception):
    """Git or GitHub could not answer; the caller decides whether to fall back."""


@dataclass
class Selection:
    tip: str
    chosen: str | None
    # Newer candidates passed over, newest first, as (sha, verdict).
    skipped: list[tuple[str, str]] = field(default_factory=list)
    candidates: int = 0

    @property
    def up_to_date(self) -> bool:
        return self.candidates == 0

    def as_json(self) -> dict:
        return {
            "tip": self.tip,
            "chosen": self.chosen,
            "up_to_date": self.up_to_date,
            "candidates": self.candidates,
            "skipped": [{"sha": sha, "verdict": verdict} for sha, verdict in self.skipped],
        }


def run_verdict(run: dict) -> str:
    status = str(run.get("status") or "").lower()
    conclusion = str(run.get("conclusion") or "").lower()
    if status in PENDING:
        return "pending"
    if conclusion == "success":
        return "success"
    if conclusion in FAILED:
        return "failure"
    return "missing"


def verdicts_from_runs(runs: Iterable[dict], shas: Iterable[str]) -> Verdicts:
    """Each sha's verdict from its newest workflow run; a rerun updates the same run."""
    newest: dict[str, dict] = {}
    for run in runs:
        if run.get("event", "push") != "push":
            continue
        sha = run.get("head_sha")
        if sha and (sha not in newest or str(run.get("created_at")) > str(newest[sha].get("created_at"))):
            newest[sha] = run
    return {sha: run_verdict(newest[sha]) if sha in newest else "missing" for sha in shas}


def choose(candidates: list[str], verdicts: Verdicts, tip: str) -> Selection:
    """The newest candidate whose verdict is success; candidates are newest first."""
    selection = Selection(tip=tip, chosen=None, candidates=len(candidates))
    for sha in candidates:
        verdict = verdicts.get(sha, "missing")
        if verdict == "success":
            selection.chosen = sha
            return selection
        selection.skipped.append((sha, verdict))
    return selection


def git(repo: Path, *args: str) -> str:
    completed = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    if completed.returncode != 0:
        raise SelectionError(f"git {' '.join(args)}: {completed.stderr.strip()}")
    return completed.stdout.strip()


def candidates(repo: Path, ref: str, limit: int = DEFAULT_LIMIT, head: str = "HEAD") -> tuple[str, list[str]]:
    """The base tip and its first-parent commits not yet in `head`, newest first."""
    tip = git(repo, "rev-parse", "--verify", f"{ref}^{{commit}}")
    limit = max(1, min(limit, RUNS_PER_PAGE))
    listed = git(repo, "rev-list", "--first-parent", f"--max-count={limit}", tip, "--not", head)
    return tip, listed.split()


def github_verdicts(repository: str = GITHUB_REPOSITORY, branch: str = "main") -> VerdictSource:
    def read(shas: list[str]) -> Verdicts:
        if not shas:
            return {}
        completed = subprocess.run(
            ["gh", "api", "--cache", "60s",
             f"repos/{repository}/actions/workflows/{GUARD_WORKFLOW}/runs"
             f"?branch={quote(branch, safe='')}&event=push&per_page={RUNS_PER_PAGE}"],
            capture_output=True, text=True,
        )
        if completed.returncode != 0:
            message = (completed.stderr.strip() or completed.stdout.strip()).splitlines()
            raise SelectionError(f"gh api could not read {GUARD_CHECK} runs: {message[0] if message else 'no output'}")
        try:
            runs = json.loads(completed.stdout)["workflow_runs"]
        except (ValueError, KeyError, TypeError) as error:
            raise SelectionError(f"unreadable {GUARD_CHECK} runs from GitHub ({error.__class__.__name__})") from error
        return verdicts_from_runs(runs, shas)

    return read


def select(repo: Path, ref: str, source: VerdictSource, limit: int = DEFAULT_LIMIT,
           head: str = "HEAD") -> Selection:
    tip, listed = candidates(repo, ref, limit, head)
    return choose(listed, source(listed) if listed else {}, tip)


def describe(selection: Selection, subject: Callable[[str], str] = lambda sha: "") -> list[str]:
    """Human lines: what was chosen and why each newer commit was passed over."""
    tip = selection.tip[:11]
    if selection.up_to_date:
        return [f"the branch already contains main {tip}"]
    if selection.chosen is None:
        return [f"none of the {selection.candidates} newest main commits the branch lacks has a green"
                f" {GUARD_CHECK} run:"] + skipped_lines(selection, subject)
    if selection.chosen == selection.tip:
        return [f"main tip {tip} has green guards"]
    counts: dict[str, int] = {}
    for _, verdict in selection.skipped:
        counts[verdict] = counts.get(verdict, 0) + 1
    summary = ", ".join(f"{count} {verdict}" for verdict, count in sorted(counts.items()))
    return [f"main tip {tip} is not green; using {selection.chosen[:11]}, the newest main commit with"
            f" green guards, and skipping {len(selection.skipped)} newer commit(s) ({summary}):"
            ] + skipped_lines(selection, subject)


def skipped_lines(selection: Selection, subject: Callable[[str], str]) -> list[str]:
    return [f"  {sha[:11]} {verdict:<8} {subject(sha)}".rstrip() for sha, verdict in selection.skipped]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=".", help="checkout of the branch")
    parser.add_argument("--ref", default="origin/main", help="base ref, already fetched")
    parser.add_argument("--head", default="HEAD", help="the branch commit to catch up")
    parser.add_argument("--github-repo", default=GITHUB_REPOSITORY)
    parser.add_argument("--branch", default="main", help="base branch name on GitHub")
    parser.add_argument("--limit", type=int, default=DEFAULT_LIMIT)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    repo = Path(args.repo)
    try:
        selection = select(repo, args.ref, github_verdicts(args.github_repo, args.branch), args.limit, args.head)
    except SelectionError as error:
        if args.json:
            print(json.dumps({"error": str(error)}))
        else:
            print(f"last_green_base: {error}", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps(selection.as_json(), indent=2))
    else:
        print("\n".join(describe(selection, lambda sha: git(repo, "log", "-1", "--format=%s", sha))))
    return 0 if selection.chosen or selection.up_to_date else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
