#!/usr/bin/env python3
"""The reuse key of migrate-journey-pr.yml's `migrate` job (ci10k).

Leo: "de facto, im asking for 99% fewer minutes of ci time, period." The migrate journey holds a Linux runner for
25 to 45 minutes, nearly all of it waiting on staging machines, and it ran on every push of every pull request that
touches its paths: 90 runs on 2026-11-27, 44 of them past 5 minutes, about 2,300 runner-minutes of wall time, with
one branch (lane/inline-tests-sweep-7) running it 8 times. Most of those pushes were base merges or edits outside
the journey's inputs, so they re-proved a journey that had already passed.

The key is sha256 of `git ls-tree -r HEAD` over exactly what the workflow's `paths:` filter watches (the files that
make the journey relevant at all), plus KEY_VERSION. The workflow looks `migrate-journey-green-<key>` up in the
Actions cache and skips `migrate` on a hit; `migrate` saves the marker after a run whose verdict is pass (exit 0).
A red, a timeout or staging_unavailable (exit 4) saves nothing, so the next push runs it again.
"""

import hashlib
import subprocess
import sys

KEY_VERSION = "v1"

# What migrate-journey-pr.yml's `on.pull_request.paths` watches: whole trees, and the CLI files and folders by name
# prefix (cli/migrate*, cli/cloud_journey*, cli/cloud_journey/**).
# tests/test_migrate_journey_key.py keeps these in step with the workflow.
TREES = [
    "cmux-tui/crates/cmux-migrate",
    "scripts/cmux-next/migrate-journey-ci.sh",
    ".github/workflows/migrate-journey-pr.yml",
]
CLI_DIR = "cmux-tui/crates/cmux-tui/src/cli"
CLI_PREFIXES = ("migrate", "cloud_journey")


def _ls_tree(rev: str, cwd: str, *paths: str) -> bytes | None:
    done = subprocess.run(["git", "ls-tree", "-r", rev, "--", *paths], capture_output=True, cwd=cwd)
    return done.stdout if done.returncode == 0 else None


def key(rev: str = "HEAD", cwd: str = ".") -> str:
    """The 40-hex key of `rev`'s journey inputs, or "" (never reuse) when the tree cannot be listed."""
    trees = _ls_tree(rev, cwd, *TREES)
    cli = _ls_tree(rev, cwd, CLI_DIR)
    if trees is None or cli is None or not trees:
        return ""
    cli_lines = [
        line
        for line in cli.splitlines()
        if b"\t" in line and line.split(b"\t", 1)[1].startswith(tuple(f"{CLI_DIR}/{p}".encode() for p in CLI_PREFIXES))
    ]
    listing = trees + b"\n".join(cli_lines)
    digest = hashlib.sha256(listing).hexdigest()
    return hashlib.sha256(f"{KEY_VERSION} {digest}".encode()).hexdigest()[:40]


if __name__ == "__main__":
    print(key(*sys.argv[1:2]))
