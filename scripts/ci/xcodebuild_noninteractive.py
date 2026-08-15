#!/usr/bin/env python3
"""Run xcodebuild under a PTY and dismiss Swift crash prompts in CI."""

from __future__ import annotations

import os
import pty
import re
import select
import signal
import subprocess
import sys
import time
from typing import BinaryIO


SWIFT_CRASH_PROMPT = b"Press space to interact, D to debug, or any other key to quit"
TIMEOUT_EXIT_CODE = 124
POST_TEST_FAILED_EXIT_CODE = 125
SELECTED_TESTS_DONE_RE = re.compile(rb"Test Suite 'Selected tests' (passed|failed) at ")
SUCCESS_MARKER = b"** TEST SUCCEEDED **"
TOTAL_TIMEOUT_MARKER = b"CMUX_XCODEBUILD_TIMEOUT_KIND=total\n"


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


def total_timeout_seconds() -> float | None:
    raw = os.environ.get("CMUX_XCODEBUILD_NONINTERACTIVE_TOTAL_TIMEOUT_SECONDS")
    if not raw:
        return None
    try:
        seconds = float(raw)
    except ValueError:
        print(
            "CMUX_XCODEBUILD_NONINTERACTIVE_TOTAL_TIMEOUT_SECONDS must be numeric",
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


def process_group_has_live_members(pgid: int) -> bool | None:
    """Return whether a process group has runnable members, excluding zombies."""

    try:
        result = subprocess.run(
            ["/bin/ps", "-axo", "pid=,pgid=,stat="],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError:
        return None
    if result.returncode != 0:
        return None

    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) < 3:
            continue
        try:
            member_pgid = int(fields[1])
        except ValueError:
            continue
        if member_pgid == pgid and "Z" not in fields[2]:
            return True
    return False


def process_group_exists(pgid: int) -> bool:
    live_members = process_group_has_live_members(pgid)
    if live_members is not None:
        return live_members
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def terminate_child(pid: int) -> bool:
    """Terminate the PTY session, including descendants that outlive its leader."""

    process_group_id = pid
    try:
        os.killpg(process_group_id, signal.SIGTERM)
    except ProcessLookupError:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            return True
    except OSError:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            return True

    deadline = time.monotonic() + 5
    leader_reaped = False
    while time.monotonic() < deadline:
        if not leader_reaped:
            try:
                finished, _ = os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                leader_reaped = True
            else:
                leader_reaped = bool(finished)
        if leader_reaped:
            if not process_group_exists(process_group_id):
                return True
            # The PTY leader is gone, so no owner remains to coordinate a
            # graceful shutdown for its descendants. Escalate the owned group
            # now instead of allowing those descendants to outlive this helper.
            break
        time.sleep(0.1)

    group_exists = process_group_exists(process_group_id)
    if group_exists:
        try:
            os.killpg(process_group_id, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except OSError:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    elif not leader_reaped:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if not leader_reaped:
            try:
                finished, _ = os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                leader_reaped = True
            else:
                leader_reaped = bool(finished)
        if leader_reaped and not process_group_exists(process_group_id):
            return True
        time.sleep(0.1)

    print(
        f"FAIL: timed-out PTY process group {process_group_id} remained live after SIGKILL",
        file=sys.stderr,
    )
    return False


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


def report_timeout(
    message: str,
    log_file: BinaryIO | None,
    marker: bytes | None = None,
) -> None:
    print(message, file=sys.stderr)
    if log_file is not None:
        if marker is not None:
            log_file.write(marker)
        log_file.write(f"{message}\n".encode())
        log_file.close()


def main() -> int:
    if len(sys.argv) < 2:
        print(
            "usage: xcodebuild_noninteractive.py <command> [args...]",
            file=sys.stderr,
        )
        return 2

    timeout = idle_timeout_seconds()
    post_test_timeout = post_test_timeout_seconds()
    total_timeout = total_timeout_seconds()
    heartbeat = heartbeat_seconds()
    started_at = time.monotonic()
    idle_deadline = started_at + timeout if timeout else None
    total_deadline = started_at + total_timeout if total_timeout else None
    heartbeat_deadline = started_at + heartbeat if heartbeat else None
    post_test_deadline: float | None = None
    selected_tests_result: str | None = None
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

    try:
        process_group_id = os.getpgid(pid)
    except ProcessLookupError:
        # A very short command can exit before the parent records its session
        # leader. PTY sessions use the leader PID as their process-group ID.
        process_group_id = pid
    prompt_window = b""
    timed_out = False
    total_timed_out = False
    post_test_timed_out = False
    pty_open = True
    status: int | None = None
    while True:
        now = time.monotonic()
        if not pty_open:
            try:
                finished, status = os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                finished = pid
                # waitpid status values are encoded bit fields. A bare 1 is
                # decoded as termination by SIGHUP (129), not exit status 1.
                status = 1 << 8
            if finished:
                break

        if total_deadline is not None and now >= total_deadline:
            total_timed_out = True
            break
        if idle_deadline is not None and now >= idle_deadline:
            timed_out = True
            break
        if post_test_deadline is not None and now >= post_test_deadline:
            post_test_timed_out = True
            break

        select_timeout = None
        if total_deadline is not None:
            remaining = total_deadline - now
            select_timeout = min(1, remaining)
        if idle_deadline is not None:
            remaining = idle_deadline - now
            select_timeout = min(
                select_timeout if select_timeout is not None else remaining,
                remaining,
                1,
            )
        if post_test_deadline is not None:
            remaining = post_test_deadline - now
            select_timeout = min(
                select_timeout if select_timeout is not None else remaining,
                remaining,
                1,
            )
        if heartbeat_deadline is not None:
            remaining = max(0, heartbeat_deadline - now)
            select_timeout = min(
                select_timeout if select_timeout is not None else remaining,
                remaining,
            )
        if not pty_open:
            select_timeout = min(
                select_timeout if select_timeout is not None else 0.1,
                0.1,
            )

        try:
            readable, _, _ = select.select(
                [fd] if pty_open else [], [], [], select_timeout
            )
        except (OSError, ValueError):
            pty_open = False
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
        if not pty_open or fd not in readable:
            continue

        try:
            chunk = os.read(fd, 4096)
        except OSError:
            pty_open = False
            try:
                os.close(fd)
            except OSError:
                pass
            continue
        if not chunk:
            pty_open = False
            try:
                os.close(fd)
            except OSError:
                pass
            continue

        write_child_output(chunk, log_file, stdout_fd)
        if heartbeat:
            heartbeat_deadline = time.monotonic() + heartbeat
        if timeout:
            idle_deadline = time.monotonic() + timeout
        prompt_window = (prompt_window + chunk)[-4096:]
        selected_match = SELECTED_TESTS_DONE_RE.search(prompt_window)
        if post_test_timeout and selected_match and post_test_deadline is None:
            selected_tests_result = selected_match.group(1).decode("ascii")
            post_test_deadline = time.monotonic() + post_test_timeout
        if SUCCESS_MARKER in prompt_window:
            saw_passing_terminal_summary = True
        if SWIFT_CRASH_PROMPT in prompt_window:
            # The Swift crash backtracer asks for one key. Send q to choose the
            # noninteractive quit path and let xcodebuild continue reporting.
            os.write(fd, b"q")
            prompt_window = b""

    if total_timed_out:
        assert total_timeout is not None
        message = f"Total timed out after {total_timeout:g}s: {' '.join(sys.argv[1:])}"
        report_timeout(message, log_file, TOTAL_TIMEOUT_MARKER)
        terminate_child(pid)
        return TIMEOUT_EXIT_CODE

    if timed_out:
        assert timeout is not None
        message = f"Idle timed out after {timeout:g}s: {' '.join(sys.argv[1:])}"
        report_timeout(message, log_file)
        terminate_child(pid)
        return TIMEOUT_EXIT_CODE

    if post_test_timed_out:
        assert post_test_timeout is not None
        message = (
            f"Post-test timed out after {post_test_timeout:g}s; terminating "
            f"xcodebuild after terminal XCTest summary"
        )
        report_timeout(message, log_file)
        if not terminate_child(pid):
            return TIMEOUT_EXIT_CODE
        if selected_tests_result == "passed" or saw_passing_terminal_summary:
            return 0
        if selected_tests_result == "failed":
            return POST_TEST_FAILED_EXIT_CODE
        return TIMEOUT_EXIT_CODE

    assert status is not None
    # A PTY descendant can keep the terminal open after the direct child has
    # already exited. Do not release the caller with an owned live process
    # group. Reuse the same group-scoped cleanup and preserve the child's
    # reported status when cleanup succeeds.
    if process_group_exists(process_group_id):
        print(
            "WARNING: PTY process group survived child exit; cleaning owned descendants",
            file=sys.stderr,
        )
        if not terminate_child(pid):
            if log_file is not None:
                log_file.close()
            return 1
    if log_file is not None:
        log_file.close()
    return child_exit_code(status)


if __name__ == "__main__":
    raise SystemExit(main())
