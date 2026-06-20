#!/usr/bin/env python3
"""Run xcodebuild under a PTY and dismiss Swift crash prompts in CI."""

from __future__ import annotations

import os
import pty
import select
import signal
import sys
import time
from typing import BinaryIO


SWIFT_CRASH_PROMPT = b"Press space to interact, D to debug, or any other key to quit"
TIMEOUT_EXIT_CODE = 124


def child_exit_code(status: int) -> int:
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return 1


def idle_timeout_seconds() -> float | None:
    raw = os.environ.get("CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS")
    if raw is None:
        raw = os.environ.get("CMUX_XCODEBUILD_NONINTERACTIVE_TIMEOUT_SECONDS")
    if not raw:
        return None
    try:
        seconds = float(raw)
    except ValueError:
        print(
            "CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS must be numeric",
            file=sys.stderr,
        )
        raise SystemExit(2)
    if seconds <= 0:
        return None
    return seconds


def terminate_child(pid: int) -> None:
    try:
        os.killpg(pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    except OSError:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            return

    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            finished, _ = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            return
        if finished:
            return
        time.sleep(0.1)

    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        return
    except OSError:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            return


def write_child_output(chunk: bytes, log_file: BinaryIO | None, stdout_fd: int) -> None:
    if log_file is not None:
        log_file.write(chunk)
        log_file.flush()

        try:
            os.write(stdout_fd, chunk)
        except BlockingIOError:
            # GitHub log streaming can apply backpressure during very noisy
            # xcodebuild phases. Keep the timeout loop moving; the full output
            # is still persisted to the per-attempt log file.
            return
        return

    view = memoryview(chunk)
    while view:
        written = os.write(stdout_fd, view)
        if written <= 0:
            return
        view = view[written:]


def main() -> int:
    if len(sys.argv) < 2:
        print(
            "usage: xcodebuild_noninteractive.py <command> [args...]",
            file=sys.stderr,
        )
        return 2

    timeout = idle_timeout_seconds()
    deadline = time.monotonic() + timeout if timeout else None
    log_path = os.environ.get("CMUX_XCODEBUILD_NONINTERACTIVE_LOG_PATH")
    log_file: BinaryIO | None = None
    if log_path:
        log_file = open(log_path, "ab", buffering=0)
    stdout_fd = sys.stdout.fileno()
    if log_file is not None:
        try:
            os.set_blocking(stdout_fd, False)
        except OSError:
            pass

    # Forward a fast, non-interactive Swift crash backtrace into the XCTest
    # host process (cmux DEV.app). The crash that matters happens in the app
    # host, not in xcodebuild, and the job-level SWIFT_BACKTRACE only reaches
    # xcodebuild itself. xcodebuild copies TEST_RUNNER_-prefixed env vars (with
    # the prefix stripped) into the test host's environment, so this is what
    # actually makes an app-host crash backtrace cheap instead of an 80s+
    # symbolicated, interactive hang that eats the CI budget.
    os.environ.setdefault(
        "TEST_RUNNER_SWIFT_BACKTRACE",
        os.environ.get(
            "SWIFT_BACKTRACE", "interactive=no,timeout=0s,symbolicate=off,color=no"
        ),
    )

    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.setsid()
        except OSError:
            pass
        os.execvp(sys.argv[1], sys.argv[1:])

    prompt_window = b""
    timed_out = False
    while True:
        select_timeout = None
        if deadline is not None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                timed_out = True
                break
            select_timeout = min(1, remaining)

        try:
            readable, _, _ = select.select([fd], [], [], select_timeout)
        except OSError:
            break
        if not readable:
            continue
        if fd not in readable:
            continue

        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break

        write_child_output(chunk, log_file, stdout_fd)
        if timeout:
            deadline = time.monotonic() + timeout
        prompt_window = (prompt_window + chunk)[-4096:]
        if SWIFT_CRASH_PROMPT in prompt_window:
            # The Swift crash backtracer asks for one key. Send q to choose the
            # noninteractive quit path and let xcodebuild continue reporting.
            os.write(fd, b"q")
            prompt_window = b""

    if timed_out:
        assert timeout is not None
        print(f"Idle timed out after {timeout:g}s: {' '.join(sys.argv[1:])}", file=sys.stderr)
        if log_file is not None:
            log_file.write(
                f"Idle timed out after {timeout:g}s: {' '.join(sys.argv[1:])}\n".encode()
            )
            log_file.close()
        terminate_child(pid)
        return TIMEOUT_EXIT_CODE

    _, status = os.waitpid(pid, 0)
    if log_file is not None:
        log_file.close()
    return child_exit_code(status)


if __name__ == "__main__":
    raise SystemExit(main())
