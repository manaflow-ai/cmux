#!/usr/bin/env python3
"""The shadow landing train's judge: build the combined tip of some PRs in this checkout and run the step table on it.

  scripts/ci/train_shadow_judge.py --base SHA --pr N[@HEAD] [--pr ...] [--job linux] [--dry-run]

Leo, 2026-11-22: "since we're moving so far off vanilla gha, we can make our own train." This is the measuring
half only. It merges nothing, pushes nothing and posts nothing: the tip is a chain of local commits (each PR's
head merged onto the one before, one parent each, as the squash it stands for), checked out in a throwaway
worktree, and judged by `ci/run run --job linux`, the pull request pipeline's own job. The driver is HQ
tools/fleet-reconcilers/train_shadow.py, which starts this through the dispatch-only Fast checks workflow (class
`batch` on the Linux pool) and reads the one result line this prints last:

  train-shadow-judge: {"base": ..., "tip": ..., "kept": [...], "conflicts": [...], "verdict": "green|red|conflict|error", "seconds": ...}

It exits 0 whenever it reached a verdict, red included: a red batch is a reading, not a failed run.
Python, stdlib only.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time

LINE = "train-shadow-judge: "
SHA = re.compile(r"[0-9a-f]{40}")
IDENTITY = ("-c", "user.name=train shadow", "-c", "user.email=train-shadow@users.noreply.github.com")
FAILED = re.compile(r"^::error title=[^\n]*?::step (\S+) ", re.M)  # ci_steps.py's line for a blocking step that failed


def git(root: str, *args: str, timeout: int = 600) -> tuple[int, str]:
    try:
        done = subprocess.run(["git", "-C", root, *args], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as error:
        return 1, str(error)
    return done.returncode, (done.stdout if done.returncode == 0 else done.stderr).strip()


def parse_pr(text: str) -> tuple[int, str]:
    number, _, head = text.partition("@")
    if not number.isdigit() or (head and not SHA.fullmatch(head)):
        raise argparse.ArgumentTypeError(f"want N or N@40-hex-head, got {text!r}")
    return int(number), head


def fetch(root: str, base: str, prs: list[tuple[int, str]]) -> dict[int, str]:
    """Each PR's head as fetched (refs/pull/N/head), after fetching the base. A PR whose ref cannot be read is absent."""
    code, out = git(root, "fetch", "--quiet", "--no-tags", "origin", base)
    if code != 0:
        raise RuntimeError(f"could not fetch the base {base}: {out[-300:]}")
    heads = {}
    for number, _ in prs:
        ref = f"refs/train-shadow/pull/{number}"
        code, _ = git(root, "fetch", "--quiet", "--no-tags", "origin", f"+refs/pull/{number}/head:{ref}")
        if code != 0:
            continue
        code, sha = git(root, "rev-parse", ref)
        if code == 0 and SHA.fullmatch(sha):
            heads[number] = sha
    return heads


def build(root: str, base: str, prs: list[tuple[int, str]], heads: dict[int, str]) -> tuple[str, list[dict], list[dict]]:
    """(tip, kept, conflicts): each PR's head merged onto the prefix before it; one that does not merge is left out."""
    tip, kept, conflicts = base, [], []
    for number, asked in prs:
        head = heads.get(number)
        if head is None:
            conflicts.append({"number": number, "why": "its head could not be fetched"})
            continue
        if asked and asked != head:
            conflicts.append({"number": number, "head": head, "why": f"its head moved from {asked[:12]}"})
            continue
        code, out = git(root, "merge-tree", "--write-tree", tip, head)
        if code != 0:
            conflicts.append({"number": number, "head": head, "why": "does not merge onto the batch before it"})
            continue
        tree = out.splitlines()[0].strip()
        code, sha = git(root, *IDENTITY, "commit-tree", tree, "-p", tip, "-m", f"train shadow: #{number} at {head}")
        if code != 0 or not SHA.fullmatch(sha):
            conflicts.append({"number": number, "head": head, "why": "its commit could not be written"})
            continue
        tip = sha
        code, at = git(root, "show", "-s", "--format=%ct", head)
        kept.append({"number": number, "head": head, "head_at": int(at) if code == 0 and at.isdigit() else 0})
    return tip, kept, conflicts


def judge(root: str, base: str, tip: str, job: str, scratch: str) -> tuple[str, float, str]:
    """(verdict, seconds, failed step or ""): `ci/run run --job JOB` in a worktree at the tip, routed by its diff."""
    tree = os.path.join(scratch, "tip")
    code, out = git(root, "worktree", "add", "--quiet", "--detach", tree, tip)
    if code != 0:
        return "error", 0.0, f"worktree: {out[-200:]}"
    try:
        code, names = git(root, "diff", "--name-only", base, tip)
        if code != 0:
            return "error", 0.0, f"diff: {names[-200:]}"
        paths = os.path.join(scratch, "paths.txt")
        with open(paths, "w") as f:
            f.write(names + "\n")
        began = time.monotonic()
        done = subprocess.run(["ci/run", "run", "--job", job, "--paths-file", paths], cwd=tree,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        seconds = round(time.monotonic() - began, 1)
        tail = done.stdout[-6000:]
        sys.stdout.write(tail if tail.endswith("\n") else tail + "\n")
        if done.returncode == 0:
            return "green", seconds, ""
        found = FAILED.findall(done.stdout)
        return "red", seconds, found[-1] if found else ""
    finally:
        git(root, "worktree", "remove", "--force", tree)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", required=True, help="the base commit the batch stands on (40 hex)")
    parser.add_argument("--pr", action="append", type=parse_pr, required=True, metavar="N[@HEAD]")
    parser.add_argument("--job", default="linux")
    parser.add_argument("--root", default=".")
    parser.add_argument("--dry-run", action="store_true", help="build the tip and stop: no step runs")
    args = parser.parse_args(argv)
    if not SHA.fullmatch(args.base):
        parser.error("--base wants a full commit id")
    result: dict = {"base": args.base, "job": args.job, "prs": [n for n, _ in args.pr]}
    try:
        heads = fetch(args.root, args.base, args.pr)
        tip, kept, conflicts = build(args.root, args.base, args.pr, heads)
        result.update(tip=tip, kept=kept, conflicts=conflicts)
        if not kept:
            result.update(verdict="conflict", seconds=0)
        elif args.dry_run:
            result.update(verdict="none", seconds=0)
        else:
            with tempfile.TemporaryDirectory(prefix="train-shadow-") as scratch:
                verdict, seconds, failed = judge(args.root, args.base, tip, args.job, scratch)
            result.update(verdict=verdict, seconds=seconds)
            if failed:
                result["failed_step"] = failed
    except RuntimeError as error:
        result.update(verdict="error", seconds=0, note=str(error))
    print(LINE + json.dumps(result, sort_keys=True))
    return 0 if result["verdict"] != "error" else 1


if __name__ == "__main__":
    sys.exit(main())
