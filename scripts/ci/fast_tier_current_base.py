#!/usr/bin/env python3
"""Rebuild a pull request run's merge commit on the base branch's current tip before the fast tier builds it.

A pull_request run checks out `github.sha`, the `pull/N/merge` commit GitHub made when the run was queued. The Mac
fast tier waits for a runner for 1 to 4 hours, so by the time it starts, the base under that merge can be hundreds of
commits old. A base red that was fixed in the meantime still fails every waiting run. On 2026-11-24 from 01:30 to
03:02Z the fast tier failed 50 times and passed 3. Every failure sampled was the BrowserPageTunables compile error
from #48267 that #53025 had fixed at 01:07Z: job 138099435473 started at 02:16Z on a base from 23:34Z, 151 commits
behind. That was 34 runner-hours (cmuxterm-hq docs/findings/2026-11-24-fast-tier-stale-merge-ref.md).

So when the checkout is a two-parent merge commit whose first parent is not the base's tip, this script:

  1. reads the tip with `git ls-remote` and fetches it at depth 1;
  2. takes the pull request's change as merged, the diff from the first parent to the merge commit;
  3. applies that diff to the tip's tree in a scratch index (`git apply --cached`, then `--3way`);
  4. writes a merge commit with parents (tip, pull request head) and checks it out.

The result has the same shape as GitHub's merge ref, at a newer base: HEAD^1 is the base and HEAD^2 the pull request
head. When anything cannot be done (no tip, a fetch that fails or times out, a conflict, a dirty tree), the run's own
merge commit stays checked out, as before. The script exits 0 and logs one line saying why. It never makes a red.

    fast_tier_current_base.py --base-ref BRANCH [--remote origin] [--github-output PATH] [--summary PATH]

Writes `rebased=true|false`, plus `base=SHA` and `commit=SHA` when rebased, to --github-output. The detector is
tests/test_ci_fast_tier_current_base.py.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

LS_REMOTE_TIMEOUT_S = 30
FETCH_TIMEOUT_S = 300
GIT_TIMEOUT_S = 120
IDENTITY = ["-c", "user.name=cmux-ci", "-c", "user.email=ci@cmux.invalid"]


class Skip(Exception):
    """A reason the run's own merge commit stays checked out."""


def git(*args: str, env: dict[str, str] | None = None, timeout: int = GIT_TIMEOUT_S, data: bytes | None = None) -> str:
    try:
        done = subprocess.run(["git", *args], input=data, capture_output=True, timeout=timeout,
                              env={**os.environ, **(env or {})})
    except subprocess.TimeoutExpired as error:
        raise Skip(f"git {args[0]} took over {timeout} s") from error
    if done.returncode != 0:
        tail = (done.stderr or done.stdout).decode(errors="replace").strip().splitlines()[-1:] or [""]
        raise Skip(f"git {args[0]} exited {done.returncode}: {tail[0][:200]}")
    return done.stdout.decode(errors="replace").strip()


def rebuild(base_ref: str, remote: str) -> dict[str, str]:
    """Check out the run's merge rebuilt on the tip of base_ref; returns the outputs, or raises Skip."""
    parents = git("rev-list", "--parents", "-n", "1", "HEAD").split()
    if len(parents) != 3:
        raise Skip("HEAD is not a two-parent merge commit")
    merge, old_base, pr_head = parents
    listed = git("ls-remote", remote, f"refs/heads/{base_ref}", timeout=LS_REMOTE_TIMEOUT_S).split()
    if not listed:
        raise Skip(f"{remote} has no branch {base_ref}")
    tip = listed[0]
    if tip == old_base:
        raise Skip(f"the merge is already on the tip of {base_ref} ({tip[:12]})")
    if git("status", "--porcelain", "--untracked-files=no"):
        raise Skip("the checkout has tracked changes")
    shallow = git("rev-parse", "--is-shallow-repository").strip() == "true"
    git("fetch", "-q", "--no-tags", *(["--depth=1"] if shallow else []), remote, tip, timeout=FETCH_TIMEOUT_S)
    patch = subprocess.run(["git", "diff", "--binary", "--full-index", "--no-renames", old_base, merge],
                           capture_output=True, timeout=GIT_TIMEOUT_S, check=True).stdout
    with tempfile.TemporaryDirectory() as scratch:
        index = {"GIT_INDEX_FILE": str(Path(scratch) / "index")}
        git("read-tree", tip, env=index)
        if patch:
            try:
                git("apply", "--cached", "--whitespace=nowarn", env=index, data=patch)
            except Skip:
                git("read-tree", tip, env=index)
                try:
                    git("apply", "--cached", "--3way", "--whitespace=nowarn", env=index, data=patch)
                except Skip as error:
                    raise Skip(f"the pull request does not apply to {tip[:12]}: {error}") from error
        tree = git("write-tree", env=index)
    message = f"Merge {pr_head} into {tip}\n\nThe fast tier's merge on the base tip; the run's merge was {merge}.\n"
    commit = git(*IDENTITY, "commit-tree", tree, "-p", tip, "-p", pr_head, "-m", message)
    git("checkout", "-q", "--detach", commit)
    behind = git("rev-list", "--count", f"{old_base}..{tip}") if git("rev-parse", "--is-shallow-repository") == "false" else ""
    return {"rebased": "true", "base": tip, "commit": commit, "old_base": old_base, "merge": merge, "behind": behind}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base-ref", required=True)
    parser.add_argument("--remote", default="origin")
    parser.add_argument("--github-output")
    parser.add_argument("--summary")
    args = parser.parse_args(argv)
    try:
        out = rebuild(args.base_ref, args.remote)
        line = (f"Built on the tip of {args.base_ref} ({out['base'][:12]}), not the run's merge "
                f"{out['merge'][:12]} on {out['old_base'][:12]}: commit {out['commit'][:12]}.")
    except (Skip, subprocess.SubprocessError, OSError) as error:
        out = {"rebased": "false"}
        line = f"Built the run's own merge commit: {error}."
    print(line)
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as handle:
            handle.writelines(f"{key}={out[key]}\n" for key in ("rebased", "base", "commit") if key in out)
    if args.summary and out["rebased"] == "true":
        with open(args.summary, "a", encoding="utf-8") as handle:
            handle.write(f"### cmux-next fast tier base\n\n{line}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
