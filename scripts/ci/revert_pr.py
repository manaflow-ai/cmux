#!/usr/bin/env python3
"""gh-merge-green --revert OWNER/REPO#NUMBER: roll back a merged pull request in one command.

Reverts the PR's merge commit on a fresh branch (revert/pr-NUMBER) cut from the tip of
the same base, opens a "Revert" PR, waits for its checks, then lands it with plain
gh-merge-green. A revert touches the same paths as the PR, so it gets the same CI tier.

Nothing is forced. If a later commit conflicts with the revert, the tool names the files
and stops, and pushes nothing. If a revert PR for NUMBER is already open, it lands that
one instead of opening a second.

Usage: gh-merge-green --revert OWNER/REPO#NUMBER [--checkout PATH] [--no-merge]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class RevertError(Exception):
    pass


def run(argv: list[str], cwd: Path | None = None, check: bool = True) -> subprocess.CompletedProcess:
    result = subprocess.run(argv, cwd=cwd, capture_output=True, text=True)
    if check and result.returncode:
        raise RevertError(f"{' '.join(argv[:3])} failed: {(result.stderr or result.stdout).strip()[-600:]}")
    return result


def gh_json(argv: list[str]):
    return json.loads(run(["gh", *argv]).stdout or "null")


def changelog(body: str, number: int) -> str:
    """The revert's changelog line: none stays none; a user-visible change is undone."""
    match = re.search(r"^## Changelog\s*\n(.*?)(?=^## |\Z)", body or "", re.S | re.M)
    original = " ".join((match.group(1) if match else "").split())
    if not original or original.lower().strip(".` ") == "none":
        return "none"
    return f"Changed: reverts #{number} ({original})"


def revert_commit(checkout: Path, base: str, merged: str, title: str, number: int, branch: str) -> None:
    """Commits the revert on a temporary worktree of origin/base and pushes it as branch."""
    run(["git", "fetch", "--quiet", "origin", base, merged], cwd=checkout)
    parents = run(["git", "rev-list", "--parents", "-n", "1", merged], cwd=checkout).stdout.split()[1:]
    with tempfile.TemporaryDirectory(prefix="revert-pr-") as tmp:
        tree = Path(tmp) / "tree"
        run(["git", "worktree", "add", "--quiet", "--detach", str(tree), f"origin/{base}"], cwd=checkout)
        try:
            argv = ["git", "revert", "--no-edit"] + (["-m", "1"] if len(parents) > 1 else []) + [merged]
            result = run(argv, cwd=tree, check=False)
            if result.returncode:
                conflicts = run(["git", "diff", "--name-only", "--diff-filter=U"], cwd=tree, check=False).stdout.split()
                run(["git", "revert", "--abort"], cwd=tree, check=False)
                raise RevertError(
                    f"reverting #{number} ({merged[:11]}) conflicts with later changes on {base}: "
                    + (", ".join(conflicts) or result.stderr.strip()[-300:])
                    + "; revert it by hand or fix forward")
            message = f'Revert "{title}" (#{number})\n\nThis reverts commit {merged}.\n'
            run(["git", "commit", "--quiet", "--amend", "-m", message], cwd=tree)
            run(["git", "push", "--quiet", "origin", f"HEAD:refs/heads/{branch}"], cwd=tree)
        finally:
            run(["git", "worktree", "remove", "--force", str(tree)], cwd=checkout, check=False)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="gh-merge-green --revert",
        description="Revert a merged pull request and land the revert. Usage: gh-merge-green --revert OWNER/REPO#NUMBER")
    parser.add_argument("ref", metavar="OWNER/REPO#NUMBER")
    parser.add_argument("--checkout", type=Path, default=ROOT, help="git checkout whose origin is the repository")
    parser.add_argument("--no-merge", action="store_true", help="open the revert PR but do not land it")
    a = parser.parse_args(argv)
    match = re.fullmatch(r"([\w.-]+/[\w.-]+)#(\d+)", a.ref)
    if not match:
        parser.error("pass OWNER/REPO#NUMBER")
    repo, number = match.group(1), int(match.group(2))
    branch = f"revert/pr-{number}"
    try:
        pr = gh_json(["pr", "view", str(number), "--repo", repo, "--json", "number,state,title,baseRefName,mergeCommit,body"])
        if pr.get("state") != "MERGED" or not (pr.get("mergeCommit") or {}).get("oid"):
            raise RevertError(f"#{number} is not merged ({pr.get('state')}); nothing to revert")
        base, merged = pr["baseRefName"], pr["mergeCommit"]["oid"]
        existing = gh_json(["pr", "list", "--repo", repo, "--head", branch, "--state", "open", "--json", "number"]) or []
        if existing:
            revert_number = existing[0]["number"]
            print(f"revert: #{revert_number} already reverts #{number}; landing it", file=sys.stderr)
        else:
            revert_commit(a.checkout, base, merged, pr["title"], number, branch)
            body = (f"## Summary\n\nReverts #{number} ({merged[:11]}), opened by `gh-merge-green --revert`.\n\n"
                    f"## Changelog\n\n{changelog(pr.get('body', ''), number)}\n")
            url = run(["gh", "pr", "create", "--repo", repo, "--base", base, "--head", branch,
                       "--title", f'Revert "{pr["title"]}"', "--body", body]).stdout.strip().splitlines()[-1]
            revert_number = int(url.rstrip("/").rsplit("/", 1)[-1])
            print(f"revert: opened {url}", file=sys.stderr)
        if a.no_merge:
            return 0
        # A red check is judged by gh-merge-green (base reds are excused there), so the
        # watch's own exit status does not decide.
        run(["gh", "pr", "checks", str(revert_number), "--repo", repo, "--watch", "--interval", "30"], check=False)
        merge = os.environ.get("GH_REVERT_MERGE_CMD") or str(ROOT / "scripts" / "gh-merge-green")
        return subprocess.call([merge, f"{repo}#{revert_number}"])
    except RevertError as error:
        print(f"revert: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
