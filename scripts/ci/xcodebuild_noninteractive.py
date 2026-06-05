#!/usr/bin/env python3
"""Run xcodebuild under a PTY and dismiss Swift crash prompts in CI."""

from __future__ import annotations

import os
import pty
import select
import sys


SWIFT_CRASH_PROMPT = b"Press space to interact, D to debug, or any other key to quit"


def child_exit_code(status: int) -> int:
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return 1


def main() -> int:
    if len(sys.argv) < 2:
        print(
            "usage: xcodebuild_noninteractive.py <command> [args...]",
            file=sys.stderr,
        )
        return 2

    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(sys.argv[1], sys.argv[1:])

    prompt_window = b""
    while True:
        try:
            readable, _, _ = select.select([fd], [], [])
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
