"""Commits a test reads from this checkout's history, fetched when a shallow clone lacks them.

A test that reads a fixed commit of this repository (a merged fix and its parent) used to skip when
the commit was not in the checkout. CI checks out shallow, so the test skipped there every time and a
change that broke it landed green (scripts/cmux-next/tests/test_hot_apply.py's 15 HotApplyRust tests).

`missing_history(root, shas, depth)` fetches each missing commit from `origin` (`--depth` only on a
shallow clone, so a full clone never turns shallow) and returns why it still cannot run, or None.
`require_history` turns that into the test's outcome: on CI (CI set, and not "0" or "false") it
fails with "needs history: ...", anywhere else it skips with the same words. Never a silent skip.

Fetches take a lock: tests that need history run in parallel (threads, or processes on one
checkout), and two `git fetch`es into one shallow clone race on .git/shallow.lock; the loser used
to say "needs history" although the commit was one fetch away. The first caller takes an exclusive
flock on a sidecar file in the git directory and fetches; the others wait on it (at most
LOCK_WAIT_SECONDS, then they fetch anyway), find the commit, and fetch nothing. A fetch that still meets a git lock
(another git process, such as a slow concurrent fetch) is retried while the lock stays, for up to
GIT_LOCK_WAIT_SECONDS; a lock still held past that is "git lock held: ...", its own result, never "needs history"
(cmux#41434 review: four quick retries, 3 s in all, and a slow fetch next door read as missing history).
Only git's own lock line is a held lock (`git_lock_held`): a permission failure on the lock file or a remote
URL with ".lock" in it fails at once with its own error (cmux#41716 review F1: any ".lock" or "Unable to create"
in the error was waited on for up to 600 s, which stalled CI and hid the error).

Load this module by path, never `import git_history`: tests run as `python3 -I` have no script
directory on sys.path.
"""

from __future__ import annotations

import fcntl
import os
import re
import subprocess
import time
import unittest
from collections.abc import Iterable
from pathlib import Path

FETCH_TIMEOUT_SECONDS = 180
LOCK_WAIT_SECONDS = 600
LOCK_FILE = "cmux-history-fetch.lock"
GIT_LOCK_WAIT_SECONDS = 600
# git's line for a lock another process holds (lockfile.c, unable_to_lock_message), as git 2.55 prints it:
#   fatal: Unable to create '/repo/.git/shallow.lock': File exists.
# The same words with another reason ("': Permission denied") are a real error, not a held lock.
GIT_LOCK_LINE = re.compile(r"^(?:fatal|error): Unable to create '(?P<path>[^\n]+\.lock)': File exists\.$", re.MULTILINE)
LOCK_HELD = "git lock held: "


class _GitLockHeld(Exception):
    """A git lock in the clone stayed held past GIT_LOCK_WAIT_SECONDS: contention, not missing history."""


def git_lock_held(stderr: str) -> str | None:
    """The lock file git's error says another git process holds, or None when the error is anything else."""
    match = GIT_LOCK_LINE.search(stderr)
    return match.group("path") if match else None


def _git(root: Path, *args: str, timeout: float | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, timeout=timeout)


def has_commit(root: Path, sha: str, depth: int = 1) -> bool:
    """Whether `sha` and its first `depth - 1` ancestors are here (a shallow boundary has no parent)."""
    oldest = sha if depth <= 1 else f"{sha}~{depth - 1}"
    return _git(root, "cat-file", "-e", f"{oldest}^{{commit}}").returncode == 0


def on_ci(env: dict[str, str] | None = None) -> bool:
    value = (os.environ if env is None else env).get("CI", "").strip().lower()
    return value not in ("", "0", "false", "no")


class _FetchLock:
    """An exclusive flock on a sidecar file in the git directory, held for one fetch."""

    def __init__(self, root: Path) -> None:
        common = _git(root, "rev-parse", "--path-format=absolute", "--git-common-dir").stdout.strip()
        self.path = Path(common or Path(root) / ".git") / LOCK_FILE
        self.fd: int | None = None
        self.waited = 0.0

    def __enter__(self) -> "_FetchLock":
        self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o644)
        start = time.monotonic()
        while True:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() - start > LOCK_WAIT_SECONDS:
                    os.close(self.fd)
                    self.fd = None
                    raise TimeoutError(f"another history fetch held {self.path} for over {LOCK_WAIT_SECONDS}s")
                time.sleep(0.05)
        self.waited = time.monotonic() - start
        return self

    def __exit__(self, *exc: object) -> None:
        if self.fd is not None:
            fcntl.flock(self.fd, fcntl.LOCK_UN)
            os.close(self.fd)
            self.fd = None


def _fetch(root: Path, shas: list[str], depth: int) -> list[str]:
    """One `git fetch` of SHAS, retried while it meets a git lock (up to GIT_LOCK_WAIT_SECONDS, then _GitLockHeld);
    the errors of a fetch that failed otherwise."""
    shallow = _git(root, "rev-parse", "--is-shallow-repository").stdout.strip() == "true"
    args = ["fetch", "--quiet", "--no-tags", "--no-write-fetch-head"]
    if shallow:
        args.append(f"--depth={depth}")
    deadline = time.monotonic() + GIT_LOCK_WAIT_SECONDS
    pause = 0.5
    while True:
        try:
            done = _git(root, *args, "origin", *shas, timeout=FETCH_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            return [f"git fetch origin took over {FETCH_TIMEOUT_SECONDS}s"]
        if done.returncode == 0:
            return []
        err = done.stderr.strip()
        if git_lock_held(err) is None:
            return [f"git fetch origin: {err or done.returncode}"]
        # Another git process holds a lock (a concurrent fetch while it runs): wait it out, it is not missing history.
        if time.monotonic() + pause > deadline:
            raise _GitLockHeld(f"{LOCK_HELD}git fetch origin met a git lock for over {GIT_LOCK_WAIT_SECONDS}s, not "
                               f"missing history; another git process in this clone still holds it ({err})")
        time.sleep(pause)
        pause = min(pause * 2, 5.0)


def missing_history(root: Path, shas: Iterable[str], depth: int = 1) -> str | None:
    """Fetch the commits `root` lacks (each with `depth` commits of history); why any is still missing."""
    wanted = list(dict.fromkeys(shas))
    if all(has_commit(root, sha, depth) for sha in wanted):
        return None
    errors: list[str] = []
    try:
        try:
            with _FetchLock(root):
                # Whoever held the lock before may have fetched these already: one fetch per checkout.
                missing = [sha for sha in wanted if not has_commit(root, sha, depth)]
                if missing:
                    # One fetch for every missing commit: a fetch per commit took minutes for a task list.
                    errors = _fetch(root, missing, depth)
        except TimeoutError:
            # A lock held too long is not missing history: fetch anyway (git's own locks are retried).
            missing = [sha for sha in wanted if not has_commit(root, sha, depth)]
            if missing:
                errors = _fetch(root, missing, depth)
    except _GitLockHeld as held:
        if all(has_commit(root, sha, depth) for sha in wanted):
            return None
        return str(held)
    still = [sha for sha in wanted if not has_commit(root, sha, depth)]
    if not still:
        return None
    detail = f" ({'; '.join(errors)})" if errors else ""
    have = f" with {depth - 1} parent(s)" if depth > 1 else ""
    return f"needs history: {', '.join(still)}{have} is not in this checkout and could not be fetched{detail}"


def require_history(root: Path, shas: Iterable[str], depth: int = 1) -> None:
    """Return when the commits are here; else fail on CI, skip elsewhere, naming what is missing (or the git lock that
    stayed held, which the words say is not missing history)."""
    reason = missing_history(root, shas, depth)
    if reason is None:
        return
    if on_ci():
        raise AssertionError(reason)
    raise unittest.SkipTest(reason)
