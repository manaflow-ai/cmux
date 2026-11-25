#!/usr/bin/env python3
"""Carry a pull request's Mac tiers across a clean base merge whose older head already passed them.

merge_hold asks a feat-cmux-next pull request whose fast-gates green went stale to merge the base in
(update-branch), and lands that base merge M on its merged-tree checks alone: cmux-next/fast-gates (Linux),
cmux-next/compile (the build fleet) and the web compile. Every other check at M is carried from the older head
H, whose checks passed (merge_hold merged_tree_hold; it only asks for the update-branch once H's checks have all
finished). Yet cmux-next.yml ran every Mac tier again at M: the fast tier, the generated files, the daemon tests,
the scheme compile, the Swift tests and canary. On 2026-11-16 at 05:44Z, 18 of the 60 open cmux-next pull request
runs were on such base-merge heads, and 13 more same-tree dispatches tested their trees: Mac jobs nobody waits on,
queued for hours on the glaeda-side-std pool in front of pull requests that do wait on theirs.

So path_route asks this script after the router. The Mac tiers are carried (turned off, with a summary line
naming H and its run) only when all of this holds, and anything unread means no carry:

  - the run is a same-repository pull_request run without `full-ci`;
  - the PR head M is a merge commit of two parents, one (B) in the base branch (GitHub's compare of B and the
    base: `behind` or `identical`), the other (H) the older head;
  - M's tree is exactly what git merges H and B into (git merge-tree at their merge base, in a scratch bare
    repository with blob:none fetches, never the workspace): no hand-resolved conflict and no change slipped
    into the merge commit;
  - a cmux-next.yml pull_request run at H concluded success.

H's success is transitive: H may itself be a carried base merge. The native tier stays as routed (cmux-next/compile
is a merged-tree check). Exits 0 always: a carry it cannot prove is no carry, never a red routing job.

    cmux_next_base_merge_carry.py --repo OWNER/NAME --head SHA --base-ref BRANCH --labels CSV
                                  [--github-output PATH] [--summary PATH]

Needs GH_TOKEN with actions: read and contents: read. The detector is tests/test_cmux_next_base_merge_carry.py.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))

SHA = re.compile(r"^[0-9a-f]{40}$")
WORKFLOW = "cmux-next.yml"
FULL_LABEL = "full-ci"
# The router outputs of cmux-next.yml's Mac Actions tiers that merge_hold carries from H. `native` (and
# `mac_release`, `cmuxnext_swift`, which only the Release compile reads) stay as routed: cmux-next/compile is one of
# M's merged-tree checks.
CARRIED_TIERS = ("fast_tier", "generated", "scheme", "swift", "daemon", "swift_canary")
GIT_TIMEOUT_S = 120

Git = Callable[..., str]


def run_git(*args: str, cwd: str | None = None) -> str:
    """One git command's stdout; CalledProcessError (or TimeoutExpired) when it fails."""
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True,
                          timeout=GIT_TIMEOUT_S).stdout.strip()


def commit_parents(git: Git, sha: str) -> list[str]:
    """The parent ids recorded in commit SHA's object (readable in a shallow checkout, whose parents are absent)."""
    body = git("cat-file", "commit", sha)
    parents = []
    for line in body.splitlines():
        if not line:
            break
        if line.startswith("parent "):
            parents.append(line.split(" ", 1)[1].strip())
    return parents


def in_base(api, repo: str, sha: str, base_ref: str) -> bool:
    """Whether the base branch contains SHA (compare SHA...base: the base is ahead of it, or it is the base)."""
    answer = api.get(f"repos/{repo}/compare/{sha}...{base_ref}?per_page=1")
    return isinstance(answer, dict) and answer.get("status") in ("ahead", "identical")


def merge_base(api, repo: str, one: str, two: str) -> str:
    answer = api.get(f"repos/{repo}/compare/{one}...{two}?per_page=1")
    found = str(((answer or {}).get("merge_base_commit") or {}).get("sha") or "")
    return found if SHA.match(found) else ""


def passed_at(api, repo: str, sha: str) -> int | None:
    """The id of a cmux-next.yml pull_request run at SHA that concluded success, else None."""
    listed = api.get(f"repos/{repo}/actions/workflows/{WORKFLOW}/runs?head_sha={sha}&event=pull_request&per_page=20")
    for run in (listed or {}).get("workflow_runs") or []:
        if (isinstance(run, dict) and run.get("head_sha") == sha and run.get("status") == "completed"
                and run.get("conclusion") == "success" and isinstance(run.get("id"), int)):
            return run["id"]
    return None


def clean_merge_tree(repo: str, older: str, base: str, ancestor: str, head: str,
                     git: Git = run_git, url: str = "") -> bool:
    """Whether HEAD's tree is exactly git's merge of OLDER and BASE at ANCESTOR. Read in a scratch bare repository
    (blob:none, depth 1: merge-tree fetches only the blobs both sides changed), so the workspace's checkout and its
    config are never touched."""
    origin = url or f"https://github.com/{repo}.git"
    with tempfile.TemporaryDirectory(prefix="base-merge-carry-") as scratch:
        git("init", "--quiet", "--bare", scratch)
        git("-C", scratch, "remote", "add", "origin", origin)
        git("-C", scratch, "fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--filter=blob:none",
            "--depth=1", "origin", older, base, ancestor, head)
        merged = git("-C", scratch, "merge-tree", "--write-tree", f"--merge-base={ancestor}", older, base)
        tree = git("-C", scratch, "rev-parse", f"{head}^{{tree}}")
    return bool(merged) and merged.splitlines()[0].strip() == tree


def decide(api, repo: str, head: str, base_ref: str, labels: str, git: Git = run_git,
           tree_check: Callable[..., bool] = clean_merge_tree) -> tuple[str, int | None, str]:
    """(H, H's passing run, why) when the Mac tiers are carried to HEAD; ("", None, why not) otherwise."""
    if FULL_LABEL in {label.strip() for label in labels.split(",")}:
        return "", None, f"`{FULL_LABEL}` asks for every tier"
    if not SHA.match(head):
        return "", None, "no pull request head to read"
    try:
        parents = commit_parents(git, head)
    except (subprocess.SubprocessError, OSError) as error:
        return "", None, f"the head commit could not be read ({type(error).__name__})"
    if len(parents) != 2 or not all(SHA.match(parent) for parent in parents):
        return "", None, "the head is not a merge commit"
    try:
        for older, base in (parents, parents[::-1]):
            if not in_base(api, repo, base, base_ref):
                continue
            run_id = passed_at(api, repo, older)
            if run_id is None:
                return "", None, (f"the head merges {base_ref} {base[:12]} into {older[:12]}, which has no passing "
                                  f"{WORKFLOW} pull_request run")
            ancestor = merge_base(api, repo, older, base)
            if not ancestor:
                return "", None, f"the merge base of {older[:12]} and {base[:12]} could not be read"
            if not tree_check(repo, older, base, ancestor, head, git=git):
                return "", None, (f"the head's tree is not git's clean merge of {older[:12]} and {base_ref} "
                                  f"{base[:12]} (a resolved conflict or a change in the merge commit)")
            return older, run_id, f"a clean merge of {base_ref} {base[:12]} into {older[:12]}"
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        return "", None, f"GitHub or git could not be read ({type(error).__name__}: {str(error)[:160]})"
    return "", None, f"neither parent of the merge is in {base_ref}"


def outputs(older: str) -> list[str]:
    """The key=value lines that turn the carried tiers off (appended after the router's: the last value wins)."""
    return [f"{tier}=false" for tier in CARRIED_TIERS] + [f"base_merge_carry={older}"]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--base-ref", required=True)
    parser.add_argument("--labels", default="")
    parser.add_argument("--github-output", default="")
    parser.add_argument("--summary", default="")
    args = parser.parse_args(argv)
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from cmux_next_tree_notify import GitHub
        older, run_id, why = decide(GitHub(os.environ.get("GH_TOKEN", "")), args.repo, args.head, args.base_ref,
                                    args.labels)
    except Exception as error:  # noqa: BLE001  (a carry it cannot prove is no carry, never a red routing job)
        older, run_id, why = "", None, f"the carry check failed ({type(error).__name__}: {str(error)[:160]})"
    if older:
        line = (f"- base-merge carry: {why}; its run {run_id} passed, so the Mac tiers "
                f"({', '.join(CARRIED_TIERS)}) are carried from it, as merge_hold carries their checks "
                f"(scripts/ci/cmux_next_base_merge_carry.py).")
        if args.github_output:
            with open(args.github_output, "a", encoding="utf-8") as handle:
                handle.write("".join(f"{item}\n" for item in outputs(older)))
    else:
        line = f"- base-merge carry: none ({why})."
    print(line)
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as handle:
            handle.write(line + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
