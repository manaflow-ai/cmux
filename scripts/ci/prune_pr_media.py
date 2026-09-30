#!/usr/bin/env python3
"""Keep the pr-media branch small: drop media of long-closed pull requests.

The branch holds screenshots and GIFs that pull request comments embed
(scripts/pr-media.py, pr-media.yml), one top-level folder per pull request
number. Every app push adds a few hundred kilobytes, and a default clone
fetches every branch, so without pruning each clone pays for years of media.

`prune` keeps every entry that is not a pull request folder (README.md,
ui-lab/ and the like), the folders of open pull requests, those of pull
requests closed within RETAIN_DAYS, and any folder an upload touched within
RETAIN_DAYS (media added to an old pull request later). It then replaces the branch with one
commit of what is kept, so the dropped files leave history too, and pushes
with a lease: an upload that lands meanwhile makes the push fail, and the
next run tries again. Without --apply it only reports.

Images in comments of pull requests closed longer ago stop loading; the PR
itself and its CI runs still carry the evidence that mattered at merge.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import sys

BRANCH = "pr-media"
PRUNE_SUBJECT = "PR media, pruned"
RETAIN_DAYS = 30
PR_FOLDER = re.compile(r"[1-9][0-9]{0,6}")
GRAPHQL_BATCH = 50


def git(*args: str, cwd: Path, input: str | None = None) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True,
                          input=input).stdout


def pull_states(repository: str, numbers: list[int]) -> dict[int, dict]:
    """{number: {"state", "closedAt"}} through batched GraphQL; a number that is
    not a pull request (an issue, or deleted) is absent."""
    owner, name = repository.split("/", 1)
    found: dict[int, dict] = {}
    for start in range(0, len(numbers), GRAPHQL_BATCH):
        batch = numbers[start:start + GRAPHQL_BATCH]
        fields = " ".join(f"p{n}: pullRequest(number: {n}) {{ state closedAt }}" for n in batch)
        query = f'query {{ repository(owner: "{owner}", name: "{name}") {{ {fields} }} }}'
        done = subprocess.run(["gh", "api", "graphql", "-f", f"query={query}"], capture_output=True, text=True)
        # A missing number makes GraphQL report an error beside partial data.
        data = json.loads(done.stdout or "{}").get("data") or {}
        if not data and done.returncode != 0:
            raise RuntimeError(f"GraphQL failed: {done.stderr.strip()[:300]}")
        for key, value in ((data.get("repository") or {}).items()):
            if isinstance(value, dict):
                found[int(key[1:])] = value
    return found


def plan(entries: list[str], states: dict[int, dict], now: dt.datetime, touched: frozenset[str] = frozenset(),
         retain_days: int = RETAIN_DAYS) -> tuple[list[str], list[str]]:
    """(keep, drop) of the branch's top-level entries.

    A pull request folder GitHub knows nothing about is kept: a lookup gap
    must never delete media. So is one in `touched`, uploaded to lately.
    """
    keep, drop = [], []
    cutoff = now - dt.timedelta(days=retain_days)
    for entry in entries:
        if not PR_FOLDER.fullmatch(entry) or entry in touched:
            keep.append(entry)
            continue
        state = states.get(int(entry))
        closed = (state or {}).get("closedAt")
        if state and state.get("state") != "OPEN" and closed and \
                dt.datetime.fromisoformat(closed.replace("Z", "+00:00")) < cutoff:
            drop.append(entry)
        else:
            keep.append(entry)
    return keep, drop


def prune(repository: str, checkout: Path, apply: bool, now: dt.datetime) -> int:
    git("fetch", "--no-tags", "origin", f"+refs/heads/{BRANCH}:refs/remotes/origin/{BRANCH}",
        cwd=checkout)
    tip = git("rev-parse", f"refs/remotes/origin/{BRANCH}", cwd=checkout).strip()
    listing = [line for line in git("ls-tree", "-z", tip, cwd=checkout).split("\0") if line]
    entries = {line.split("\t", 1)[1]: line for line in listing}
    numbers = sorted(int(entry) for entry in entries if PR_FOLDER.fullmatch(entry))
    # Uploads since the cutoff; a squash commit re-dates every file, so skip those.
    cutoff = now - dt.timedelta(days=RETAIN_DAYS)
    paths = git("log", f"--since={cutoff.isoformat()}", "--invert-grep", f"--grep=^{PRUNE_SUBJECT}",
                "--name-only", "--format=", tip, cwd=checkout).split()
    touched = frozenset(path.split("/", 1)[0] for path in paths)
    keep, drop = plan(list(entries), pull_states(repository, numbers), now, touched)
    print(f"{BRANCH} at {tip[:12]}: {len(entries)} entries; keeping {len(keep)}, "
          f"dropping {len(drop)} (closed over {RETAIN_DAYS} days ago): {' '.join(drop) or 'none'}", flush=True)
    commits = int(git("rev-list", "--count", tip, cwd=checkout).strip())
    if (not drop and commits <= 1) or not keep:
        return 0
    if not apply:
        print("Dry run; pass --apply to rewrite the branch.", flush=True)
        return 0
    # The kept tree is built from the existing tree entries, so no blob is read.
    tree = git("mktree", "-z", cwd=checkout, input="".join(entries[entry] + "\0" for entry in keep)).strip()
    message = (f"{PRUNE_SUBJECT} {now:%Y-%m-%d}\n\nKept {len(keep)} entries; dropped media of pull requests "
               f"closed over {RETAIN_DAYS} days ago: {' '.join(drop) or 'none'}.\n")
    commit = git("commit-tree", tree, "-m", message, cwd=checkout).strip()
    try:
        git("push", f"--force-with-lease=refs/heads/{BRANCH}:{tip}", "origin", f"{commit}:refs/heads/{BRANCH}",
            cwd=checkout)
    except subprocess.CalledProcessError as error:
        if "stale info" in error.stderr or "rejected" in error.stderr:
            print(f"::notice::An upload landed on {BRANCH} meanwhile; the next run prunes it.", flush=True)
            return 0
        print(error.stderr, file=sys.stderr, flush=True)
        raise
    print(f"{BRANCH} is now {commit[:12]}, one commit.", flush=True)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--apply", action="store_true", help="rewrite and push the branch")
    parser.add_argument("--checkout", type=Path, default=Path.cwd())
    args = parser.parse_args(argv)
    return prune(os.environ["REPOSITORY"], args.checkout, args.apply, dt.datetime.now(dt.timezone.utc))


if __name__ == "__main__":
    sys.exit(main())
