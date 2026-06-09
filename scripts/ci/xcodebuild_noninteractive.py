#!/usr/bin/env python3
"""Run xcodebuild under a PTY and dismiss Swift crash prompts in CI."""

from __future__ import annotations

import os
import pty
import select
import signal
import sys
import time


SWIFT_CRASH_PROMPT = b"Press space to interact, D to debug, or any other key to quit"
TERMINATION_SIGNAL: int | None = None


def child_exit_code(status: int) -> int:
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return 1


def request_termination(signum: int, _frame: object) -> None:
    global TERMINATION_SIGNAL
    TERMINATION_SIGNAL = signum


def signal_child(pid: int, signum: int) -> None:
    try:
        child_pgid = os.getpgid(pid)
    except OSError:
        child_pgid = None

    if child_pgid is not None and child_pgid != os.getpgrp():
        try:
            os.killpg(child_pgid, signum)
        except OSError:
            pass

    try:
        os.kill(pid, signum)
    except OSError:
        pass


def terminate_child(pid: int, fd: int, signum: int) -> int:
    signal_child(pid, signal.SIGTERM)
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline:
        try:
            waited_pid, status = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            return 128 + signum
        if waited_pid == pid:
            return child_exit_code(status)
        time.sleep(0.1)

    signal_child(pid, signal.SIGKILL)
    try:
        os.close(fd)
    except OSError:
        pass
    try:
        _, status = os.waitpid(pid, 0)
    except ChildProcessError:
        return 128 + signum
    return child_exit_code(status)


def main() -> int:
    if len(sys.argv) < 2:
        print(
            "usage: xcodebuild_noninteractive.py <command> [args...]",
            file=sys.stderr,
        )
        return 2

    signal.signal(signal.SIGTERM, request_termination)
    signal.signal(signal.SIGINT, request_termination)
    signal.signal(signal.SIGHUP, request_termination)

    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(sys.argv[1], sys.argv[1:])

    prompt_window = b""
    while True:
        if TERMINATION_SIGNAL is not None:
            return terminate_child(pid, fd, TERMINATION_SIGNAL)

        try:
            readable, _, _ = select.select([fd], [], [], 0.5)
        except OSError:
            break
        if fd not in readable:
            continue

        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break

        os.write(sys.stdout.fileno(), chunk)
        prompt_window = (prompt_window + chunk)[-4096:]
        if SWIFT_CRASH_PROMPT in prompt_window:
            # The Swift crash backtracer asks for one key. Send q to choose the
            # noninteractive quit path and let xcodebuild continue reporting.
            os.write(fd, b"q")
            prompt_window = b""

    _, status = os.waitpid(pid, 0)
    return child_exit_code(status)


if __name__ == "__main__":
    raise SystemExit(main())
