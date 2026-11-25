#!/usr/bin/env python3
"""Entry logs: a record many pull requests add to is a directory of one file per entry, not one file.

Two open pull requests that each add a line at the same place in one file conflict on GitHub, which runs
no merge driver (our `cmux-insertions-v1` driver only helps merges on our own hosts). Measured over the 7,359
pull requests merged into feat-cmux-next in the 14 days to 2026-11-25 (scripts/ci/conflict_hotspots.py),
the append-only logs a rule makes every change edit were among the most conflicted files in the repo:
`plans/cmux-next/sidebar-owner.md` (96 PRs, 47 of them conflict against the base they opened on, 208
sync merges), `cmux-next-ios/verify/parity-mac.md` (107 PRs, 29 conflicts, 339 sync merges) and the
workflow notes (`docs/ci/cmux-next-workflow-notes.md`: 64 PRs, 16 conflicts). 89 of those 92 conflicts
only added lines, so as new files they would not have conflicted. Each new
entry is a new file now, so two entries never share a line.

ENTRY_LOGS maps each frozen log to its entry directory. The old file stays as the history: its entries
can still be corrected in place, but a pull request that grows it (more lines added than removed) fails,
and the message names the directory to add a file to instead.

ENTRY_DIRS maps each registry that was replaced outright by a directory of one file per entry (its readers
read the directory; the old file is gone) to that directory: a pull request that adds the old file back fails
the same way, naming the directory. That is what an older pull request that still edits the old file gets after
it merges its base (git reports modify/delete; keeping the file adds it back).

  entry_logs.py check --base SHA [--head REF]   fail when BASE..HEAD grows a frozen log or adds a removed registry
  entry_logs.py list                            print each frozen log and its directory

The fast gates run `check` on every feat-cmux-next pull request (scripts/ci/cmux_next_fast_gates.py),
against the pull request merged with its base, so only the pull request's own lines count. It never runs
on a push to the base: an older pull request that grew a log before this check existed is not the base's
red.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

# frozen log -> the directory new entries go to (one file each; README.md there says the file's shape).
ENTRY_LOGS: dict[str, str] = {
    "plans/cmux-next/sidebar-owner.md": "plans/cmux-next/sidebar-owner/",
    "cmux-next-ios/verify/parity-mac.md": "cmux-next-ios/verify/parity-mac/",
    # Workflow notes (tests/test_ci_workflow_file_size.py): numbered `## note-N` sections appended at the end, so two
    # PRs both wrote note-557 at the same line (16 conflicts among 64 PRs for cmux-next.yml's, 5 among 19 nightly's).
    "docs/ci/cmux-next-workflow-notes.md": "docs/ci/cmux-next-workflow-notes/",
    "docs/ci/nightly-workflow-notes.md": "docs/ci/nightly-workflow-notes/",
}

# removed registry -> the directory that replaced it (one file per entry; the directory's first file or
# README.md says the shape). Measured with scripts/ci/conflict_hotspots.py over the same 14 days.
ENTRY_DIRS: dict[str, str] = {
    # One <key>.json per setting: 30 of its 118 PRs conflicted against the base they opened on; replayed as one
    # file per key, 2 (both edited the same key's policy).
    "schemas/settings/source/agent-policy.json": "schemas/settings/source/agent-policy/",
}


def readded(repo: Path, base: str, head: str) -> list[str]:
    """Each removed registry BASE..HEAD adds back."""
    out = subprocess.run(["git", "-C", str(repo), "diff", "--name-only", "--no-renames", "--diff-filter=A", base,
                          head, "--", *ENTRY_DIRS], capture_output=True, text=True, check=True).stdout
    return [path for path in out.splitlines() if path in ENTRY_DIRS]


def growth(repo: Path, base: str, head: str) -> list[tuple[str, int, int]]:
    """(log, added, removed) for each frozen log BASE..HEAD adds more lines to than it removes."""
    out = subprocess.run(["git", "-C", str(repo), "diff", "--numstat", "--no-renames", base, head, "--",
                          *ENTRY_LOGS], capture_output=True, text=True, check=True).stdout
    grown = []
    for line in out.splitlines():
        added, removed, path = line.split("\t", 2)
        if added == "-" or path not in ENTRY_LOGS:
            continue
        if int(added) > int(removed):
            grown.append((path, int(added), int(removed)))
    return grown


def findings(repo: Path, base: str, head: str) -> list[str]:
    return [f"{path}: +{added} -{removed} lines. This log is frozen so that two pull requests never add to the same "
            f"place: add your entry as its own file under {ENTRY_LOGS[path]} (see {ENTRY_LOGS[path]}README.md), "
            "and keep edits to old entries to changing lines, not adding them."
            for path, added, removed in growth(repo, base, head)] + [
            f"{path}: added back. It was replaced by one file per entry so that two pull requests never edit the same "
            f"line: put each entry in its own file under {ENTRY_DIRS[path]} and delete {path}."
            for path in readded(repo, base, head)]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    check = sub.add_parser("check")
    check.add_argument("--base", required=True)
    check.add_argument("--head", default="HEAD")
    check.add_argument("--repo", default=".")
    sub.add_parser("list")
    args = ap.parse_args(argv)
    if args.cmd == "list":
        for path, directory in {**ENTRY_LOGS, **ENTRY_DIRS}.items():
            print(f"{path} -> {directory}")
        return 0
    found = findings(Path(args.repo), args.base, args.head)
    for finding in found:
        print(f"::error title=Entry logs::{finding}")
    print(f"entry logs: {len(found)} frozen log(s) grown or removed registries added back by {args.base[:11]}..{args.head[:11]}", file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
