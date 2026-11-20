#!/usr/bin/env python3
"""Today's worktree path: a plain `git worktree add` (full checkout, nothing shared)."""
import subprocess
import sys

args = sys.argv[1:]
repo = "."
if args[:1] == ["-C"]:
    repo, args = args[1], args[2:]
if args[:1] == ["--seed-dir"]:
    args = args[2:]
if args[:1] == ["add"]:
    rest = [a for a in args[1:] if a != "--json"]
    sys.exit(subprocess.run(["git", "-C", repo, "worktree", "add", *rest]).returncode)
print(f"cmux-worktree: {args[:1]} is not implemented", file=sys.stderr)
sys.exit(2)
