#!/usr/bin/env python3
"""package-test-lane.sh downloads GhosttyKit for the ghostty gitlink's revision on a fleet step.

A fleet step's worktree has no ghostty submodule checkout, only the empty
directory git leaves for the gitlink. `git -C ghostty` there resolves to the
superproject, so a check based on it would download GhosttyKit for the
superproject commit instead of the pinned ghostty revision.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LANE = ROOT / "scripts" / "ci" / "package-test-lane.sh"


def git(cwd: Path, *args: str) -> str:
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
           "GIT_COMMITTER_EMAIL": "t@t", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"}
    return subprocess.run(["git", *args], cwd=cwd, env=env, check=True, capture_output=True, text=True).stdout.strip()


def lane_sha(repo: Path) -> str:
    env = {k: v for k, v in os.environ.items() if k not in ("GHOSTTY_SHA", "GITHUB_OUTPUT")}
    result = subprocess.run(["bash", str(LANE), "ghostty-sha"], cwd=repo, env=env, capture_output=True, text=True)
    if result.returncode != 0:
        raise AssertionError(f"lane failed: {result.stderr}")
    return result.stdout.strip()


def main() -> int:
    scratch = Path(tempfile.mkdtemp(prefix="lane-ghostty-sha-"))
    try:
        ghostty = scratch / "ghostty-src"
        ghostty.mkdir()
        git(ghostty, "init", "-q", "-b", "main")
        (ghostty / "README").write_text("ghostty\n")
        git(ghostty, "add", "README")
        git(ghostty, "commit", "-q", "-m", "ghostty")
        pinned = git(ghostty, "rev-parse", "HEAD")

        repo = scratch / "cmux"
        repo.mkdir()
        git(repo, "init", "-q", "-b", "main")
        git(repo, "update-index", "--add", "--cacheinfo", f"160000,{pinned},ghostty")
        (repo / "README").write_text("cmux\n")
        git(repo, "add", "README")
        git(repo, "commit", "-q", "-m", "cmux")

        # A clone without submodules is what a fleet step's worktree looks like.
        step = scratch / "step"
        git(scratch, "clone", "-q", str(repo), str(step))
        if not (step / "ghostty").is_dir() or any((step / "ghostty").iterdir()):
            print("FAIL: fixture expected an empty ghostty directory")
            return 1
        superproject = git(step, "rev-parse", "HEAD")
        got = lane_sha(step)
        if got != pinned:
            print(f"FAIL: uninitialized gitlink resolved to {got!r}, want the pinned {pinned} "
                  f"(superproject is {superproject})")
            return 1

        # With a submodule checkout, the downloader reads the checkout itself.
        (step / "ghostty").rmdir()
        git(scratch, "clone", "-q", str(ghostty), str(step / "ghostty"))
        got = lane_sha(step)
        if got != "":
            print(f"FAIL: with a ghostty checkout the lane must leave GHOSTTY_SHA unset, got {got!r}")
            return 1
    finally:
        shutil.rmtree(scratch, ignore_errors=True)

    print("PASS: the lane resolves GhosttyKit from the ghostty gitlink on a fleet step")
    return 0


if __name__ == "__main__":
    sys.exit(main())
