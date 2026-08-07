#!/usr/bin/env python3
"""Run xcodebuild under a PTY and dismiss Swift crash prompts in CI."""

from __future__ import annotations

import os
import pty
import re
import select
import signal
import sys
import time
from typing import BinaryIO


SWIFT_CRASH_PROMPT = b"Press space to interact, D to debug, or any other key to quit"
TIMEOUT_EXIT_CODE = 124
POST_TEST_FAILED_EXIT_CODE = 125
SELECTED_TESTS_DONE_RE = re.compile(rb"Test Suite 'Selected tests' (passed|failed) at ")
SWIFT_TESTING_STARTED_MARKER = b"Test run started."
SWIFT_TESTING_DONE_RE = re.compile(
    rb"Test run with [0-9]+ tests? (passed|failed) after "
)
SUCCESS_MARKER = b"** TEST SUCCEEDED **"
TEST_OUTPUT_TAIL_BYTES = 4096


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


def post_test_timeout_seconds() -> float | None:
    raw = os.environ.get("CMUX_XCODEBUILD_NONINTERACTIVE_POST_TEST_TIMEOUT_SECONDS")
    if not raw:
        return None
    try:
        seconds = float(raw)
    except ValueError:
        print(
            "CMUX_XCODEBUILD_NONINTERACTIVE_POST_TEST_TIMEOUT_SECONDS must be numeric",
            file=sys.stderr,
        )
        raise SystemExit(2)
    if seconds <= 0:
        return None
    return seconds


def expects_swift_testing() -> bool:
    raw = os.environ.get("CMUX_XCODEBUILD_NONINTERACTIVE_EXPECT_SWIFT_TESTING", "")
    if raw in ("", "0"):
        return False
    if raw == "1":
        return True
    print(
        "CMUX_XCODEBUILD_NONINTERACTIVE_EXPECT_SWIFT_TESTING must be 0 or 1",
        file=sys.stderr,
    )
    raise SystemExit(2)


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
    post_test_timeout = post_test_timeout_seconds()
    swift_testing_expected = expects_swift_testing()
    deadline = time.monotonic() + timeout if timeout else None
    post_test_deadline: float | None = None
    selected_tests_result: str | None = None
    swift_testing_result: str | None = None
    swift_testing_active = False
    saw_passing_terminal_summary = False
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
    test_output_buffer = b""
    timed_out = False
    post_test_timed_out = False
    while True:
        select_timeout = None
        if deadline is not None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                timed_out = True
                break
            select_timeout = min(1, remaining)
        if post_test_deadline is not None:
            remaining = post_test_deadline - time.monotonic()
            if remaining <= 0:
                post_test_timed_out = True
                break
            select_timeout = min(select_timeout if select_timeout is not None else remaining, remaining, 1)

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
        test_output_buffer += chunk
        while b"\n" in test_output_buffer:
            line, test_output_buffer = test_output_buffer.split(b"\n", 1)
            selected_match = SELECTED_TESTS_DONE_RE.search(line)
            if selected_match:
                selected_tests_result = selected_match.group(1).decode("ascii")
                if post_test_timeout and not swift_testing_active:
                    post_test_deadline = time.monotonic() + post_test_timeout

            # Xcode runs XCTest and Swift Testing as separate phases inside one
            # xcodebuild invocation. An XCTest summary is not terminal when a
            # Swift Testing phase follows it, so suspend the post-test deadline
            # until Swift Testing emits its own terminal summary.
            if SWIFT_TESTING_STARTED_MARKER in line:
                swift_testing_active = True
                swift_testing_result = None
                post_test_deadline = None

            swift_testing_match = SWIFT_TESTING_DONE_RE.search(line)
            if swift_testing_match:
                swift_testing_active = False
                swift_testing_result = swift_testing_match.group(1).decode("ascii")
                if post_test_timeout:
                    post_test_deadline = time.monotonic() + post_test_timeout
        if len(test_output_buffer) > TEST_OUTPUT_TAIL_BYTES:
            test_output_buffer = test_output_buffer[-TEST_OUTPUT_TAIL_BYTES:]
        if SUCCESS_MARKER in prompt_window:
            saw_passing_terminal_summary = True
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

    if post_test_timed_out:
        assert post_test_timeout is not None
        message = (
            f"Post-test timed out after {post_test_timeout:g}s; terminating "
            f"xcodebuild after terminal test summary"
        )
        print(message, file=sys.stderr)
        if log_file is not None:
            log_file.write(f"{message}\n".encode())
            log_file.close()
        terminate_child(pid)
        if saw_passing_terminal_summary:
            return 0
        if "failed" in (selected_tests_result, swift_testing_result):
            return POST_TEST_FAILED_EXIT_CODE
        if swift_testing_expected and swift_testing_result is None:
            return TIMEOUT_EXIT_CODE
        if "passed" in (selected_tests_result, swift_testing_result):
            return 0
        return TIMEOUT_EXIT_CODE

    _, status = os.waitpid(pid, 0)
    if log_file is not None:
        log_file.close()
    return child_exit_code(status)


if __name__ == "__main__":
    raise SystemExit(main())
