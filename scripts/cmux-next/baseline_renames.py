"""One rename map for every baseline keyed by path: a file that moved is the same code, so its row follows it.

A push that moves code between paths or crates (2026-11-24: acpmux's TUI split into the acpmux-tui crate) kept every
violation it moved, yet each path-keyed baseline read the moved lines as a new file's debt: the pre-push gate judges
the push against the INSTALLED baselines, which have rows for the old paths only, and check-spawn-owner's CI mode
(`--base-ref`) refused a row its base did not have. Both read this map. A new path takes its old path's row only while
the old path has no row of its own left, and never more than the old row held; the push's own baseline still caps it
(a row it did not carry is not taken).

The map is git's rename detection (`git diff -M`: content identical or nearly so, across folders and crates), plus
MOVED_BASELINE_PATHS: seams git does not report as a rename (a file split into a child module).
"""

from __future__ import annotations

import subprocess

# new path -> old path, for a move git does not see as a rename. A new path inherits only from its named old path.
MOVED_BASELINE_PATHS = {
    "cmux-tui/crates/cmux-remote/src/identity/auth_database.rs":
        "cmux-tui/crates/cmux-remote/src/identity.rs",
}


def diff_args(base: str, head: str | None = None) -> list[str]:
    """The `git diff` arguments that list BASE..HEAD's renames (HEAD None: the work tree's tracked files)."""
    return ["diff", "--no-ext-diff", "--no-color", "-M", "--diff-filter=R", "--name-status", "-z", base,
            *([head] if head else []), "--"]


def parse(output: bytes) -> dict[str, str]:
    """{new path: old path} of `git diff -M --name-status -z` OUTPUT (diff_args), plus MOVED_BASELINE_PATHS."""
    moved = dict(MOVED_BASELINE_PATHS)
    fields = output.decode("utf-8", "surrogateescape").split("\0")
    i = 0
    while i + 2 < len(fields):
        status, old, new = fields[i], fields[i + 1], fields[i + 2]
        if not status.startswith("R"):
            break
        moved[new] = old
        i += 3
    return moved


def renames(repo: str, base: str, head: str | None = None) -> dict[str, str]:
    """{new path: old path} for REPO's BASE..HEAD; a git that cannot answer gives the explicit seams only."""
    result = subprocess.run(["git", "-C", repo, *diff_args(base, head)], capture_output=True)
    return parse(result.stdout) if result.returncode == 0 else dict(MOVED_BASELINE_PATHS)
