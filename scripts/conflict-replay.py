#!/usr/bin/env python3
"""Replay a file's merges and count the ones that would conflict, with and without a merge driver.

How many PRs touched a file says little about its conflicts: git merges edits to different
lines cleanly. This answers the question a fix needs instead. For each commit B that changed
FILE on the branch's first-parent history, take its PR as if it had branched --behind
commits of FILE earlier, before commit A, and merge it with what the base gained since:
base B^, ours B, theirs A^ (the base's newer commits taken back). A pair where B rewrote
lines that only exist after A is skipped, since B could not have branched there.

Each conflicted pair is classified by its hunks (import lines or code; both sides inserted,
or a line both changed), then run through --driver (default scripts/merge-insertions.py, as
git runs it: %O %A %B %P %L) to count what it settles.

  scripts/conflict-replay.py --since 2026-11-01 --behind 30 webviews/src/agent-session/acpmux/App.tsx
  scripts/conflict-replay.py --since 2026-11-01 --top 12 --glob '*.ts' --glob '*.tsx'
"""
from __future__ import annotations

import argparse
import collections
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HUNK = re.compile(r"^<<<<<<< .*?\n(.*?)^\|\|\|\|\|\|\| .*?\n(.*?)^=======\n(.*?)^>>>>>>> .*?$", re.M | re.S)
IMPORT_LINE = re.compile(r"^(import |\s+(type )?[\w$]+( as [\w$]+)?,?$|\} from |\s*$)")


def git(*args: str) -> str:
    return subprocess.run(["git", *args], capture_output=True, text=True).stdout


def show(rev: str, path: str) -> str | None:
    result = subprocess.run(["git", "show", f"{rev}:{path}"], capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else None


def replay(path: str, ref: str, since: str, behind: int, driver: Path, scratch: Path) -> collections.Counter:
    commits = git("log", "--reverse", "--first-parent", f"--since={since}", "--format=%H", ref, "--", path).split()
    counts: collections.Counter = collections.Counter()
    for older, commit in zip(commits, commits[behind:]):
        base, parent, mine = show(older + "^", path), show(commit + "^", path), show(commit, path)
        if not base or not parent or mine is None:
            continue
        files = {}
        for name, text in (("O", parent), ("A", mine), ("B", base)):
            files[name] = scratch / name
            files[name].write_text(text)
        merged = subprocess.run(["git", "merge-file", "-p", "--diff3", files["A"], files["O"], files["B"]],
                                capture_output=True, text=True).stdout
        hunks = HUNK.findall(merged)
        if any(orig.strip() and not theirs.strip() for _, orig, theirs in hunks):
            continue
        counts["pairs"] += 1
        if not hunks:
            continue
        counts["conflicted"] += 1
        for ours, orig, theirs in hunks:
            kind = "import" if all(IMPORT_LINE.match(line) for line in (ours + orig + theirs).splitlines()) else "code"
            counts[f"hunks {kind} {'both inserted' if not orig.strip() else 'line both changed'}"] += 1
        settled = subprocess.run([sys.executable, str(driver), files["O"], files["A"], files["B"], path, "7"],
                                 capture_output=True)
        if settled.returncode == 0:
            counts["settled by driver"] += 1
    return counts


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("files", nargs="*")
    parser.add_argument("--ref", default="origin/feat-cmux-next")
    parser.add_argument("--since", required=True)
    parser.add_argument("--behind", type=int, default=30, help="how many of the file's commits a PR branched before")
    parser.add_argument("--driver", type=Path, default=Path(__file__).resolve().parent / "merge-insertions.py")
    parser.add_argument("--top", type=int, help="also replay the N files changed most often since --since")
    parser.add_argument("--glob", action="append", default=[], help="limit --top to these pathspecs")
    args = parser.parse_args()
    files = list(args.files)
    if args.top:
        changed = git("log", "--first-parent", f"--since={args.since}", "--format=", "--name-only", args.ref, "--", *args.glob)
        ranked = collections.Counter(line for line in changed.splitlines() if line and "generated" not in line)
        files += [name for name, _ in ranked.most_common(args.top) if name not in files]
    if not files:
        parser.error("name files or --top N")
    total: collections.Counter = collections.Counter()
    with tempfile.TemporaryDirectory(prefix="conflict-replay-") as scratch:
        for path in files:
            counts = replay(path, args.ref, args.since, args.behind, args.driver, Path(scratch))
            total.update(counts)
            print(f"{path}: {counts['conflicted']} of {counts['pairs']} conflicted, "
                  f"{counts['settled by driver']} settled by the driver; "
                  + ", ".join(f"{key[6:]} {value}" for key, value in sorted(counts.items()) if key.startswith("hunks ")))
    print(f"total: {total['conflicted']} of {total['pairs']} conflicted, {total['settled by driver']} settled by the driver")
    return 0


if __name__ == "__main__":
    sys.exit(main())
