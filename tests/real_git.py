#!/usr/bin/env python3
"""The real git binary for a test's fake `git`, and a bounded way to run a test's subprocesses.

A test that puts a fake `git` first on PATH and has it exec "the real git" must name a git binary,
never the first `git` on PATH. On a fleet host that first git is a wrapper (~/.local/bin/git, the
lane git guard) that execs the next git on PATH: with the fake first on PATH that is the fake, so
the fake and the wrapper exec each other forever in one process. exec keeps the pid, so no timeout
saw it. cosmic-gray, 2026-11-10: four orphaned tests/test_pr_checks_base_only.py runs each spun a
core this way for 3 to 15 hours (load ~265). Leo: "well this should just be fixed/prevented in teh
future".

    real_git()        the git binary: the first git on PATH that is not a script (a wrapper), else
                      Homebrew's or the system's; nothing on PATH is run to find it
    run_bounded(...)  subprocess.run with a timeout, in its own process group, the whole group
                      killed on timeout, error or exit, so a hang fails the test and nothing it
                      started outlives it

`python3 tests/real_git.py` prints real_git() for shell tests.
Importing this module refuses to run on a fleet host that runs no tests (tests/fleet_test_host.py).
"""

from __future__ import annotations

import functools
import os
import signal
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fleet_test_host  # noqa: E402

fleet_test_host.refuse_here()

DEFAULT_TIMEOUT_S = 120
FALLBACKS = ("/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git")


def _is_binary(path: str) -> bool:
    """An executable file that is not a script: a wrapper is a script (#!), the real git is not."""
    try:
        if not (os.path.isfile(path) and os.access(path, os.X_OK)):
            return False
        with open(path, "rb") as handle:
            return handle.read(2) != b"#!"
    except OSError:
        return False


def _killpg(process: subprocess.Popen) -> None:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


def run_bounded(args, *, timeout: float = DEFAULT_TIMEOUT_S, check: bool = False, input=None,
                capture_output: bool = False, kill_group: bool = True, **kwargs) -> subprocess.CompletedProcess:
    """subprocess.run in a new session with a timeout; the process group is killed when it ends (kill_group)
    and always on timeout or an error, so a spinning or leftover child never outlives the test."""
    if capture_output:
        kwargs["stdout"] = kwargs["stderr"] = subprocess.PIPE
    if input is not None:
        kwargs["stdin"] = subprocess.PIPE
    process = subprocess.Popen(args, start_new_session=True, **kwargs)
    try:
        stdout, stderr = process.communicate(input, timeout=timeout)
    except subprocess.TimeoutExpired:
        _killpg(process)
        stdout, stderr = process.communicate()
        raise subprocess.TimeoutExpired(args, timeout, output=stdout, stderr=stderr) from None
    except BaseException:
        _killpg(process)
        process.wait()
        raise
    finally:
        if kill_group:
            _killpg(process)
    result = subprocess.CompletedProcess(args, process.returncode, stdout, stderr)
    if check:
        result.check_returncode()
    return result


@functools.lru_cache(maxsize=1)
def real_git() -> str:
    """The absolute path of a real git binary, past any wrapper named git on PATH.

    Nothing found on PATH is run to find it: running `git --exec-path` through PATH is the very loop this
    avoids. The first `git` on PATH that is a binary (not a #! script) wins, then Homebrew's, then the system's."""
    candidates = [os.path.join(d or ".", "git") for d in os.environ.get("PATH", "").split(os.pathsep)]
    candidates.extend(FALLBACKS)
    for candidate in candidates:
        if _is_binary(candidate):
            return os.path.realpath(candidate)
    raise RuntimeError(f"no git binary found on PATH or in {', '.join(FALLBACKS)}; a wrapper script is never used")


if __name__ == "__main__":
    print(real_git())
