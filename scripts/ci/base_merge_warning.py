#!/usr/bin/env python3
"""Warn before a base merge cancels a pull request's running CI. It never refuses anything.

Merging feat-cmux-next (or main) into a pull request branch is a push, and a push cancels every
job still running on the old head. On 2026-10-21 base-merge pushes cut 167 Mac runner-minutes of
running jobs in 55 minutes (leo-workspace research/cmux-ci-repush-waste-2026-10-21.md). Base reds
never hold a merge, so a branch needs the base once, right before landing, or when GitHub says it
conflicts.

  base_merge_warning.py --pre-push [--repo DIR]   the pre-push hook: reads git's pushed-refs lines
  base_merge_warning.py --claude-hook             a Claude Code PreToolUse(Bash) hook: reads its JSON

--pre-push warns when the pushed commits include a clean merge of the base into the branch while
the old head still has checks queued or running. --claude-hook adds the same warning as context to
a `gh api .../pulls/N/update-branch` call. Either one says nothing when GitHub can't be read.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ZERO_SHA = "0" * 40
BASE_BRANCHES = ("feat-cmux-next", "main")
TIMEOUT = 15  # seconds for one gh or git call: a slow GitHub or a huge range never holds a push long
# `gh api repos/OWNER/REPO/pulls/N/update-branch` ({owner}/{repo} is gh's placeholder for this checkout's repo)
# and `gh pr update-branch N`.
UPDATE_BRANCH = re.compile(r"repos/([\w.-]+/[\w.-]+|\{owner\}/\{repo\})/pulls/(\d+)/update-branch")
PR_UPDATE_BRANCH = re.compile(r"\bgh\s+pr\s+update-branch\s+(?:.*?\s)?#?(\d+)\b")
REPO_FLAG = re.compile(r"(?:-R|--repo)[\s=]+([\w.-]+/[\w.-]+)")
ADVICE = ("Merge the base once, right before landing, or when GitHub says the PR conflicts; "
          "base reds never hold a merge.")


def git(repo: Path, *args: str) -> str:
    try:
        done = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, timeout=TIMEOUT)
    except (OSError, subprocess.SubprocessError):
        return ""
    return done.stdout.strip() if done.returncode == 0 else ""


def is_ancestor(repo: Path, commit: str, ref: str) -> bool:
    try:
        return subprocess.run(["git", "-C", str(repo), "merge-base", "--is-ancestor", commit, ref],
                              capture_output=True, timeout=TIMEOUT).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def gh(*args: str) -> str | None:
    try:
        done = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=TIMEOUT)
    except (OSError, subprocess.SubprocessError):
        return None
    return done.stdout.strip() if done.returncode == 0 else None


def running_checks(slug: str, sha: str) -> int | None:
    """Check runs on `sha` that have not finished, or None when GitHub can't be read."""
    out = gh("api", f"repos/{slug}/commits/{sha}/check-runs?per_page=100",
             "--jq", '[.check_runs[] | select(.status != "completed")] | length')
    return int(out) if out and out.isdigit() else None


def repo_slug(repo: Path) -> str | None:
    url = git(repo, "remote", "get-url", "origin")
    found = re.search(r"github\.com[:/]([\w.-]+/[\w.-]+?)(?:\.git)?$", url)
    return found.group(1) if found else None


def clean_base_merges(repo: Path, old: str, new: str) -> list[str]:
    """The branch's own merges in old..new (first parent, none already on a base branch) whose second parent
    is on a base branch and whose tree is exactly what merging the parents gives (no conflict resolution, no
    other change). A base merge brings in the base's own merge commits; those are not the branch's."""
    bases = [ref for ref in (f"refs/remotes/origin/{name}" for name in BASE_BRANCHES)
             if git(repo, "rev-parse", "-q", "--verify", ref)]
    found = []
    for merge in git(repo, "rev-list", "--first-parent", "--merges", f"{old}..{new}", "--not", *bases).split():
        parents = git(repo, "rev-list", "--parents", "-n", "1", merge).split()[1:]
        if len(parents) != 2:
            continue
        on_base = any(is_ancestor(repo, parents[1], ref) for ref in bases)
        merged = git(repo, "merge-tree", "--write-tree", *parents).splitlines()
        if on_base and merged and merged[0] == git(repo, "rev-parse", f"{merge}^{{tree}}"):
            found.append(merge)
            break  # one is enough to warn
    return found


def pre_push(repo: Path, lines: list[str]) -> list[str]:
    warnings = []
    slug = None
    for line in lines:
        parts = line.split()
        if len(parts) != 4 or ZERO_SHA in (parts[1], parts[3]):
            continue  # a deletion or a new branch: no old head whose CI could be cut
        local, remote_ref, remote = parts[1], parts[2], parts[3]
        branch = remote_ref.removeprefix("refs/heads/")
        # The old head must be here (it was fetched or pushed from here) to see what the push adds.
        if branch in BASE_BRANCHES or not git(repo, "rev-parse", "-q", "--verify", f"{remote}^{{commit}}") \
                or not clean_base_merges(repo, remote, local):
            continue
        slug = slug or repo_slug(repo)
        running = running_checks(slug, remote) if slug else None
        if running:
            warnings.append(f"base-merge warning: this push merges the base into {branch} while {running} check(s) "
                            f"still run on its old head {remote[:12]}; the push cancels them. {ADVICE}")
    return warnings


def claude_hook(payload: dict) -> str | None:
    command = (payload.get("tool_input") or {}).get("command") or ""
    found = UPDATE_BRANCH.search(command)
    if found:
        slug, number = found.groups()
    elif (found := PR_UPDATE_BRANCH.search(command)):
        number = found.group(1)
        repo_flag = REPO_FLAG.search(command)
        slug = repo_flag.group(1) if repo_flag else "{owner}/{repo}"
    else:
        return None
    if slug == "{owner}/{repo}":
        slug = repo_slug(Path(payload.get("cwd") or "."))
        if not slug:
            return None
    head = gh("api", f"repos/{slug}/pulls/{number}", "--jq", ".head.sha")
    running = running_checks(slug, head) if head else None
    if not running:
        return None
    return (f"base-merge warning: update-branch on #{number} cancels the {running} check(s) still running on "
            f"its head {head[:12]}. {ADVICE} If it needs the base now, wait until its checks finish.")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--pre-push", action="store_true")
    mode.add_argument("--claude-hook", action="store_true")
    parser.add_argument("--repo", default=".")
    args = parser.parse_args(argv)
    if args.pre_push:
        for warning in pre_push(Path(args.repo), sys.stdin.read().splitlines()):
            print(warning, file=sys.stderr)
        return 0
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError:
        return 0
    context = claude_hook(payload)
    if context:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": context}}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
