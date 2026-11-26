"""Run a workflow step's shell so that nothing it starts outlives the test.

A step runs with fake tools (git, curl) on PATH. If a fake blocks, the step's whole
process tree must still go away, however the test ends:

- stdin is /dev/null, so nothing in the tree can wait on the test's terminal or pipe;
- the step runs in a session of its own, and its process group is killed on timeout,
  on any error and after it exits (background children it left behind);
- a reaper in that group kills it when the test process dies (pytest under `timeout`,
  SIGKILL, Ctrl-C), when no `finally` in the test runs.

Without the reaper a killed pytest left `bash` -> cmux_tui_tree_key.py -> fake git ->
`cat` alive for hours, reparented to init, holding the checkout busy.
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys

# The session leader: starts a reaper in the group (detached by a double fork, so the step's
# `wait` never waits on it), then becomes the step. The reaper kills the whole group once
# the test's end of the pipe closes: run_step returned, or the test process died.
_WATCHDOG = r"""
import os, signal, sys
fd = int(sys.argv[1])
middle = os.fork()
if middle == 0:
    if os.fork() == 0:
        null = os.open(os.devnull, os.O_RDWR)
        for target in (0, 1, 2):
            os.dup2(null, target)
        while os.read(fd, 1):
            pass
        os.killpg(0, signal.SIGKILL)
    os._exit(0)
os.waitpid(middle, 0)
os.close(fd)
os.execvp(sys.argv[2], sys.argv[2:])
"""


def kill_group(pid: int) -> None:
    # The group may be gone, or (macOS) hold only a zombie leader, which raises EPERM.
    try:
        os.killpg(pid, signal.SIGKILL)
    except OSError:
        pass


def run_step(args: list[str], *, env: dict, timeout: float, cwd: str | os.PathLike | None = None,
             stderr: int = subprocess.PIPE) -> subprocess.CompletedProcess:
    """Run args (a `bash -c STEP` command line) with no stdin in a group that dies with the test.

    On timeout the group is killed and subprocess.TimeoutExpired is raised with the output so far.
    """
    alive_read, alive_write = os.pipe()
    try:
        process = subprocess.Popen(
            [sys.executable, "-I", "-c", _WATCHDOG, str(alive_read), *args],
            env=env, cwd=cwd, text=True, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=stderr, start_new_session=True, pass_fds=(alive_read,))
    finally:
        os.close(alive_read)
    try:
        with process:
            try:
                stdout, err = process.communicate(timeout=timeout)
            except subprocess.TimeoutExpired as error:
                kill_group(process.pid)
                error.output, error.stderr = process.communicate()
                raise
            finally:
                kill_group(process.pid)
    finally:
        os.close(alive_write)
    return subprocess.CompletedProcess(args, process.returncode, stdout, err)
