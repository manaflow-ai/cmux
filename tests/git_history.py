"""Commits a test reads from this checkout's history, fetched when a shallow clone lacks them.

A test that reads a fixed commit of this repository (a merged fix and its parent) used to skip when
the commit was not in the checkout. CI checks out shallow, so the test skipped there every time and a
change that broke it landed green (scripts/cmux-next/tests/test_hot_apply.py's 15 HotApplyRust tests).

`missing_history(root, shas, depth)` fetches each missing commit from `origin` (`--depth` only on a
shallow clone, so a full clone never turns shallow) and returns why it still cannot run, or None.
`require_history` turns that into the test's outcome: on CI (CI set, and not "0" or "false") it
fails with "needs history: ...", anywhere else it skips with the same words. Never a silent skip.

Load this module by path, never `import git_history`: tests run as `python3 -I` have no script
directory on sys.path.
"""

from __future__ import annotations

import os
import subprocess
import unittest
from collections.abc import Iterable
from pathlib import Path

FETCH_TIMEOUT_SECONDS = 180


def _git(root: Path, *args: str, timeout: float | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, timeout=timeout)


def has_commit(root: Path, sha: str, depth: int = 1) -> bool:
    """Whether `sha` and its first `depth - 1` ancestors are here (a shallow boundary has no parent)."""
    oldest = sha if depth <= 1 else f"{sha}~{depth - 1}"
    return _git(root, "cat-file", "-e", f"{oldest}^{{commit}}").returncode == 0


def on_ci(env: dict[str, str] | None = None) -> bool:
    value = (os.environ if env is None else env).get("CI", "").strip().lower()
    return value not in ("", "0", "false", "no")


def missing_history(root: Path, shas: Iterable[str], depth: int = 1) -> str | None:
    """Fetch the commits `root` lacks (each with `depth` commits of history); why any is still missing."""
    wanted = list(dict.fromkeys(shas))
    missing = [sha for sha in wanted if not has_commit(root, sha, depth)]
    if not missing:
        return None
    shallow = _git(root, "rev-parse", "--is-shallow-repository").stdout.strip() == "true"
    # One fetch for every missing commit: a fetch per commit took minutes for a task list.
    args = ["fetch", "--quiet", "--no-tags", "--no-write-fetch-head"]
    if shallow:
        args.append(f"--depth={depth}")
    errors: list[str] = []
    try:
        done = _git(root, *args, "origin", *missing, timeout=FETCH_TIMEOUT_SECONDS)
        if done.returncode != 0:
            errors.append(f"git fetch origin: {done.stderr.strip() or done.returncode}")
    except subprocess.TimeoutExpired:
        errors.append(f"git fetch origin took over {FETCH_TIMEOUT_SECONDS}s")
    still = [sha for sha in wanted if not has_commit(root, sha, depth)]
    if not still:
        return None
    detail = f" ({'; '.join(errors)})" if errors else ""
    have = f" with {depth - 1} parent(s)" if depth > 1 else ""
    return f"needs history: {', '.join(still)}{have} is not in this checkout and could not be fetched{detail}"


def require_history(root: Path, shas: Iterable[str], depth: int = 1) -> None:
    """Return when the commits are here; else fail on CI, skip elsewhere, naming what is missing."""
    reason = missing_history(root, shas, depth)
    if reason is None:
        return
    if on_ci():
        raise AssertionError(reason)
    raise unittest.SkipTest(reason)
