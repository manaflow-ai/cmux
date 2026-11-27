"""Shared bounded subprocess runner for the CLI regression tests."""
from __future__ import annotations

import os
import signal
import subprocess


def run_bounded(
    command: list[str], timeout: float, env: dict[str, str] | None = None, input_text: str | None = None
) -> subprocess.CompletedProcess[str]:
    """Like subprocess.run, but a timeout kills the child's whole process group
    and reaps it, so a descendant cannot outlive the test and keep touching the
    forced socket or temp home. Raises TimeoutExpired as subprocess.run does.
    """
    proc = subprocess.Popen(
        command,
        stdin=subprocess.PIPE if input_text is not None else None,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
        start_new_session=True,
    )
    try:
        stdout, stderr = proc.communicate(input=input_text, timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.communicate()
        raise
    return subprocess.CompletedProcess(command, proc.returncode, stdout, stderr)
