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
# A test bundle that mixes XCTest and Swift Testing runs XCTest first and then
# starts a Swift Testing run. The XCTest summary is therefore only terminal
# when no Swift Testing run follows it; otherwise the Swift Testing run summary
# is the terminal marker.
SWIFT_TESTING_RUN_STARTED_MARKER = b"Test run started."
SWIFT_TESTING_RUN_DONE_RE = re.compile(
    rb"Test run with \d+ tests? in \d+ suites? (passed|failed) after "
)
SUCCESS_MARKER = b"** TEST SUCCEEDED **"


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


def heartbeat_seconds() -> float | None:
    raw = os.environ.get("CMUX_XCODEBUILD_NONINTERACTIVE_HEARTBEAT_SECONDS")
    if not raw:
        return None
    try:
        seconds = float(raw)
    except ValueError:
        print(
            "CMUX_XCODEBUILD_NONINTERACTIVE_HEARTBEAT_SECONDS must be numeric",
            file=sys.stderr,
        )
        raise SystemExit(2)
    if seconds <= 0:
        return None
    return seconds


PTY_LEADER_EXIT_GRACE_SECONDS = 1.0
TERMINATION_GRACE_SECONDS = 5.0


def process_group_exists(process_group_id: int) -> bool:
    """Return whether the kernel still exposes a process group."""

    try:
        os.killpg(process_group_id, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def terminate_child(pid: int, process_group_id: int | None = None) -> None:
    """Terminate the PTY leader and descendants without an unbounded wait."""

    # The child calls setsid(), so its PID is normally its process-group ID. If
    # ownership was not proven, signal only the direct child; never infer a
    # group from a PID that may already have been reaped and reused.
    owned_group_id = process_group_id

    def signal_owned_processes(signum: signal.Signals) -> None:
        if owned_group_id is not None:
            try:
                os.killpg(owned_group_id, signum)
                return
            except (ProcessLookupError, OSError):
                pass
        try:
            os.kill(pid, signum)
        except ProcessLookupError:
            pass

    signal_owned_processes(signal.SIGTERM)
    leader_reaped = False
    deadline = time.monotonic() + TERMINATION_GRACE_SECONDS
    while not leader_reaped and time.monotonic() < deadline:
        if not leader_reaped:
            try:
                finished, _ = os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                finished = pid
            if finished:
                leader_reaped = True
        if leader_reaped:
            # The leader has exited. If a descendant still owns the group,
            # terminate it immediately rather than spending the graceful
            # deadline waiting on a process that can no longer coordinate its
            # own teardown.
            if owned_group_id is not None and process_group_exists(owned_group_id):
                signal_owned_processes(signal.SIGKILL)
            return
        time.sleep(0.1)

    # SIGKILL the group even when waitpid already reaped the leader. A
    # descendant retaining the PTY must not survive to hold the next test.
    signal_owned_processes(signal.SIGKILL)
    try:
        os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        pass


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
    heartbeat = heartbeat_seconds()
    started_at = time.monotonic()
    deadline = time.monotonic() + timeout if timeout else None
    heartbeat_deadline = started_at + heartbeat if heartbeat else None
    post_test_deadline: float | None = None
    selected_tests_result: str | None = None
    saw_passing_terminal_summary = False
    swift_testing_run_started = False
    swift_testing_run_finished = False
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

    # Verify that the PTY leader owns a private process group before using
    # killpg. The child calls setsid() immediately after fork; retry briefly
    # across that handoff so a descendant that outlives the leader remains
    # attributable without ever guessing at the caller's process group.
    process_group_id: int | None = None
    for _ in range(100):
        try:
            candidate = os.getpgid(pid)
        except (ProcessLookupError, OSError):
            break
        if candidate == pid:
            process_group_id = pid
            break
        try:
            select.select([], [], [], 0.001)
        except OSError:
            pass

    prompt_window = b""
    timed_out = False
    post_test_timed_out = False
    pty_open = True
    child_status: int | None = None
    leader_exit_deadline: float | None = None

    def close_pty() -> None:
        nonlocal pty_open
        if not pty_open:
            return
        try:
            os.close(fd)
        except OSError:
            pass
        pty_open = False

    while True:
        now = time.monotonic()
        if child_status is None:
            try:
                finished, observed_status = os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                finished, observed_status = pid, 1 << 8
            if finished:
                child_status = observed_status
                leader_exit_deadline = now + PTY_LEADER_EXIT_GRACE_SECONDS

        # PTY EOF is not a reliable child-exit signal: a descendant can keep
        # the slave open, while a closed slave can produce EIO before the
        # leader has been reaped. Poll waitpid independently and bound the
        # post-leader drain so the helper never falls into blocking waitpid().
        if child_status is not None:
            if not pty_open:
                break
            if leader_exit_deadline is not None and now >= leader_exit_deadline:
                terminate_child(pid, process_group_id)
                close_pty()
                break

        if not pty_open:
            if heartbeat_deadline is not None and now >= heartbeat_deadline:
                elapsed = now - started_at
                write_child_output(
                    f"[xcodebuild still running after {elapsed:.0f}s]\n".encode(),
                    log_file,
                    stdout_fd,
                )
                heartbeat_deadline = now + heartbeat
            time.sleep(0.1)
            continue

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
        if heartbeat_deadline is not None:
            remaining = max(0, heartbeat_deadline - time.monotonic())
            select_timeout = min(
                select_timeout if select_timeout is not None else remaining,
                remaining,
            )

        try:
            readable, _, _ = select.select([fd], [], [], select_timeout)
        except (OSError, ValueError):
            close_pty()
            continue
        if not readable:
            if heartbeat_deadline is not None and time.monotonic() >= heartbeat_deadline:
                elapsed = time.monotonic() - started_at
                write_child_output(
                    f"[xcodebuild still running after {elapsed:.0f}s]\n".encode(),
                    log_file,
                    stdout_fd,
                )
                heartbeat_deadline = time.monotonic() + heartbeat
            continue
        if fd not in readable:
            continue

        try:
            chunk = os.read(fd, 4096)
        except OSError:
            close_pty()
            continue
        if not chunk:
            close_pty()
            continue

        write_child_output(chunk, log_file, stdout_fd)
        if heartbeat:
            heartbeat_deadline = time.monotonic() + heartbeat
        if timeout:
            deadline = time.monotonic() + timeout
        prompt_window = (prompt_window + chunk)[-4096:]
        if post_test_timeout:
            selected_match = SELECTED_TESTS_DONE_RE.search(prompt_window)
            if selected_match and selected_tests_result is None:
                selected_tests_result = selected_match.group(1).decode("ascii")
                post_test_deadline = time.monotonic() + post_test_timeout
            if (
                selected_tests_result is not None
                and not swift_testing_run_started
                and SWIFT_TESTING_RUN_STARTED_MARKER in prompt_window
            ):
                # Swift Testing runs after XCTest inside the same xcodebuild
                # invocation. Its suites can legitimately run for minutes, so
                # the deadline armed by the XCTest summary must wait for the
                # Swift Testing run summary.
                swift_testing_run_started = True
                post_test_deadline = None
            swift_testing_match = SWIFT_TESTING_RUN_DONE_RE.search(prompt_window)
            if (
                swift_testing_run_started
                and not swift_testing_run_finished
                and swift_testing_match
            ):
                swift_testing_run_finished = True
                if swift_testing_match.group(1) == b"failed":
                    selected_tests_result = "failed"
                post_test_deadline = time.monotonic() + post_test_timeout
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
        terminate_child(pid, process_group_id)
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
        terminate_child(pid, process_group_id)
        if selected_tests_result == "passed" or saw_passing_terminal_summary:
            return 0
        if selected_tests_result == "failed":
            return POST_TEST_FAILED_EXIT_CODE
        return TIMEOUT_EXIT_CODE

    if child_status is None:
        # This is only reachable when the child closed its PTY before waitpid
        # observed its status. Keep the fallback bounded as a final guard.
        wait_deadline = time.monotonic() + (timeout or TERMINATION_GRACE_SECONDS)
        while time.monotonic() < wait_deadline:
            try:
                finished, observed_status = os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                finished, observed_status = pid, 1 << 8
            if finished:
                child_status = observed_status
                break
            if heartbeat_deadline is not None and time.monotonic() >= heartbeat_deadline:
                elapsed = time.monotonic() - started_at
                write_child_output(
                    f"[xcodebuild still running after {elapsed:.0f}s]\n".encode(),
                    log_file,
                    stdout_fd,
                )
                heartbeat_deadline = time.monotonic() + heartbeat
            time.sleep(0.1)
        if child_status is None:
            terminate_child(pid, process_group_id)
            child_status = 1 << 8
    if log_file is not None:
        log_file.close()
    return child_exit_code(child_status)


if __name__ == "__main__":
    raise SystemExit(main())
