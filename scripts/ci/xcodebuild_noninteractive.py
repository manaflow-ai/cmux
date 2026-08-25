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
SWIFT_TESTING_RUN_STARTED = b"Test run started."
SWIFT_TESTING_RUN_DONE_RE = re.compile(
    rb"Test run with [^\r\n]+ (passed|failed) after "
)
SUCCESS_MARKER = b"** TEST SUCCEEDED **"
TOTAL_TIMEOUT_MARKER = b"CMUX_XCODEBUILD_TIMEOUT_KIND=total\n"
COMMAND_LABEL = "xcodebuild"
PROCESS_CLEANUP_FAILURE_MARKER = "CMUX_XCODEBUILD_PROCESS_CLEANUP_FAILED"
GRACEFUL_TERMINATION_SECONDS = 5
# macOS XCTest processes can stay in an uninterruptible kernel state briefly
# after SIGKILL. Keep the lock while the owned group drains, then fail closed.
FORCED_TERMINATION_SECONDS = 30
TIMEOUT_CLEANUP_SECONDS = 30


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


def timeout_cleanup_command() -> str | None:
    raw = os.environ.get(
        "CMUX_XCODEBUILD_NONINTERACTIVE_TIMEOUT_CLEANUP_COMMAND"
    )
    if not raw:
        return None
    if not os.path.isabs(raw) or not os.access(raw, os.X_OK):
        print(
            "CMUX_XCODEBUILD_NONINTERACTIVE_TIMEOUT_CLEANUP_COMMAND must be "
            "an absolute executable path",
            file=sys.stderr,
        )
        raise SystemExit(2)
    return raw


def process_group_has_live_members(pgid: int) -> bool | None:
    """Return whether a group has active members, excluding terminal states."""

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
        state = fields[2]
        # Darwin ps marks a dead process with Z and a process that has entered
        # the irreversible exit path with E. After SIGKILL, neither state can
        # execute more test code or regain machine ownership. A U state without
        # E is still active and must keep the cleanup failure closed.
        if member_pgid == pgid and "Z" not in state and "E" not in state:
            return True
    return False


def process_group_is_signalable(pgid: int) -> bool:
    """Return whether the kernel still exposes the owned process group."""

    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def process_group_exists(pgid: int) -> bool:
    live_members = process_group_has_live_members(pgid)
    if live_members is not None:
        return live_members
    return process_group_is_signalable(pgid)


def terminate_child(
    pid: int,
    process_group_id: int | None = None,
    termination_deadline: float | None = None,
) -> bool:
    """Terminate the PTY session, including descendants that outlive its leader."""

    owned_group_id = process_group_id
    if owned_group_id is None:
        # A missing receipt means ownership was not proven. Kill only the
        # direct child, never a process group that could belong to the caller.
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            return True
    else:
        try:
            os.killpg(owned_group_id, signal.SIGTERM)
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

    deadline = time.monotonic() + GRACEFUL_TERMINATION_SECONDS
    if termination_deadline is not None:
        deadline = min(deadline, termination_deadline)
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
            if owned_group_id is None or not process_group_is_signalable(owned_group_id):
                return True
            # The PTY leader is gone, so no owner remains to coordinate a
            # graceful shutdown for its descendants. Escalate the owned group
            # now instead of allowing those descendants to outlive this helper.
            break
        try:
            select.select([], [], [], 0.1)
        except OSError:
            pass

    group_exists = owned_group_id is not None and process_group_is_signalable(owned_group_id)
    if group_exists:
        try:
            os.killpg(owned_group_id, signal.SIGKILL)
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

    deadline = (
        termination_deadline
        if termination_deadline is not None
        else time.monotonic() + FORCED_TERMINATION_SECONDS
    )
    while time.monotonic() < deadline:
        if not leader_reaped:
            try:
                finished, _ = os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                leader_reaped = True
            else:
                leader_reaped = bool(finished)
        if leader_reaped and (
            owned_group_id is None or not process_group_is_signalable(owned_group_id)
        ):
            if owned_group_id is None:
                return True
            break
        try:
            select.select([], [], [], 0.1)
        except OSError:
            pass

    if owned_group_id is None:
        return leader_reaped
    # Perform one non-zombie scan after the inexpensive signalability polling.
    live_members = process_group_has_live_members(owned_group_id)
    if live_members is False or (
        live_members is None and not process_group_is_signalable(owned_group_id)
    ):
        return leader_reaped
    print(
        f"FAIL: timed-out PTY process group {owned_group_id} remained live after SIGKILL",
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


def report_cleanup_failure() -> None:
    print(PROCESS_CLEANUP_FAILURE_MARKER, file=sys.stderr)


def run_timeout_cleanup(
    command: str | None,
    cleanup_deadline: float | None = None,
) -> bool:
    """Run the owner's scoped cleanup before terminating the PTY group."""

    if command is None:
        return True
    cleanup_timeout = TIMEOUT_CLEANUP_SECONDS
    if cleanup_deadline is not None:
        cleanup_timeout = cleanup_deadline - time.monotonic()
        if cleanup_timeout <= 0:
            print(
                "FAIL: no execution time remained for app-host timeout cleanup",
                file=sys.stderr,
            )
            return False
    print("Running receipt-verified app-host timeout cleanup", file=sys.stderr)
    try:
        result = subprocess.run(
            [command],
            check=False,
            timeout=cleanup_timeout,
        )
    except (OSError, subprocess.TimeoutExpired):
        if cleanup_deadline is None:
            print("FAIL: app-host timeout cleanup did not complete", file=sys.stderr)
        else:
            print(
                "FAIL: app-host timeout cleanup exceeded the remaining "
                "execution deadline",
                file=sys.stderr,
            )
        return False
    if result.returncode != 0:
        print(
            "FAIL: app-host timeout cleanup returned a failure",
            file=sys.stderr,
        )
        return False
    return True


def cleanup_timed_out_child(
    pid: int,
    process_group_id: int | None,
    cleanup_command: str | None,
    cleanup_deadline: float | None = None,
) -> bool:
    """Clean external app-host ownership, then drain the owned PTY group."""

    app_host_cleaned = run_timeout_cleanup(cleanup_command, cleanup_deadline)
    process_group_cleaned = terminate_child(
        pid,
        process_group_id,
        cleanup_deadline,
    )
    if not app_host_cleaned or not process_group_cleaned:
        report_cleanup_failure()
        return False
    return True


def read_process_group_receipt(
    fd: int, deadline: float | None
) -> tuple[int | None, bool]:
    """Read the child-owned PGID, returning (pgid, deadline_expired)."""

    os.set_blocking(fd, False)
    receipt = bytearray()
    while len(receipt) < 32:
        timeout = None
        if deadline is not None:
            timeout = deadline - time.monotonic()
            if timeout <= 0:
                return None, True
        try:
            readable, _, _ = select.select([fd], [], [], timeout)
        except OSError:
            continue
        if not readable:
            return None, deadline is not None
        try:
            chunk = os.read(fd, 32 - len(receipt))
        except BlockingIOError:
            continue
        except OSError:
            break
        if not chunk:
            break
        receipt.extend(chunk)
        if b"\n" in receipt:
            break
    try:
        receipt_group_id = int(bytes(receipt).strip())
    except ValueError:
        receipt_group_id = None
    return receipt_group_id, False


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
    cleanup_command = timeout_cleanup_command()
    started_at = time.monotonic()
    idle_deadline = started_at + timeout if timeout else None
    total_deadline = started_at + total_timeout if total_timeout else None
    heartbeat_deadline = started_at + heartbeat if heartbeat else None
    post_test_deadline: float | None = None
    selected_tests_result: str | None = None
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

    group_receipt_read, group_receipt_write = os.pipe()
    pid, fd = pty.fork()
    if pid == 0:
        os.close(group_receipt_read)
        try:
            os.setsid()
        except OSError:
            pass
        try:
            receipt = f"{os.getpgid(0)}\n".encode("ascii")
            written = 0
            while written < len(receipt):
                written += os.write(group_receipt_write, receipt[written:])
        except OSError:
            pass
        try:
            os.close(group_receipt_write)
        except OSError:
            pass
        os.execvp(sys.argv[1], sys.argv[1:])

    os.close(group_receipt_write)
    try:
        receipt_group_id, receipt_timed_out = read_process_group_receipt(
            group_receipt_read, total_deadline
        )
    finally:
        os.close(group_receipt_read)
    process_group_id = receipt_group_id if receipt_group_id == pid else None
    if receipt_timed_out:
        assert total_timeout is not None
        message = f"Total timed out after {total_timeout:g}s while starting {COMMAND_LABEL}"
        report_timeout(message, log_file, TOTAL_TIMEOUT_MARKER)
        if not cleanup_timed_out_child(pid, None, cleanup_command):
            return 1
        report_cleanup_failure()
        return TIMEOUT_EXIT_CODE
    prompt_window = b""
    test_event_window = b""
    timed_out = False
    total_timed_out = False
    post_test_timed_out = False
    pty_open = True
    status: int | None = None
    cleanup_failed = False
    leader_exit_deadline: float | None = None
    while True:
        now = time.monotonic()
        if status is None:
            if total_deadline is not None and now >= total_deadline:
                total_timed_out = True
                break
            if idle_deadline is not None and now >= idle_deadline:
                timed_out = True
                break
            if post_test_deadline is not None and now >= post_test_deadline:
                post_test_timed_out = True
                break
        elif leader_exit_deadline is not None and now >= leader_exit_deadline:
            if pty_open:
                try:
                    os.close(fd)
                except OSError:
                    pass
                pty_open = False
            break

        if status is None:
            try:
                finished, child_status = os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                finished = pid
                # waitpid status values are encoded bit fields. A bare 1 is
                # decoded as termination by SIGHUP (129), not exit status 1.
                child_status = 1 << 8
            if finished:
                status = child_status
                if process_group_id is not None and process_group_exists(process_group_id):
                    print(
                        "WARNING: PTY process group survived child exit; cleaning owned descendants",
                        file=sys.stderr,
                    )
                    cleanup_failed = not terminate_child(
                        pid,
                        process_group_id,
                        total_deadline,
                    )
                leader_exit_deadline = time.monotonic() + 5
                if not pty_open or cleanup_failed:
                    try:
                        os.close(fd)
                    except OSError:
                        pass
                    pty_open = False
                    break

        if not pty_open:
            if status is not None:
                break
            # Keep polling the leader while its PTY is already closed. This
            # avoids an unbounded wait when a child exits without an EOF event.
            select.select([], [], [], 0.1)
            continue

        select_timeout = None
        if status is None and total_deadline is not None:
            remaining = total_deadline - now
            select_timeout = min(1, remaining)
        if status is None and idle_deadline is not None:
            remaining = idle_deadline - now
            select_timeout = min(
                select_timeout if select_timeout is not None else remaining,
                remaining,
                1,
            )
        if status is None and post_test_deadline is not None:
            remaining = post_test_deadline - now
            select_timeout = min(
                select_timeout if select_timeout is not None else remaining,
                remaining,
                1,
            )
        if status is None and heartbeat_deadline is not None:
            remaining = max(0, heartbeat_deadline - now)
            select_timeout = min(
                select_timeout if select_timeout is not None else remaining,
                remaining,
            )
        # Poll waitpid independently of PTY output so a descendant cannot keep
        # the terminal open after its leader has exited.
        select_timeout = min(
            select_timeout if select_timeout is not None else 0.1,
            0.1,
        )

        try:
            readable, _, _ = select.select([fd], [], [], select_timeout)
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
        if fd not in readable:
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
        test_event_window = (test_event_window + chunk)[-4096:]
        while True:
            events: list[tuple[int, int, str, str | None]] = []
            selected_match = SELECTED_TESTS_DONE_RE.search(test_event_window)
            if selected_match is not None:
                events.append(
                    (
                        selected_match.start(),
                        selected_match.end(),
                        "selected-finished",
                        selected_match.group(1).decode("ascii"),
                    )
                )
            swift_start_index = test_event_window.find(SWIFT_TESTING_RUN_STARTED)
            if swift_start_index >= 0:
                events.append(
                    (
                        swift_start_index,
                        swift_start_index + len(SWIFT_TESTING_RUN_STARTED),
                        "swift-started",
                        None,
                    )
                )
            swift_done_match = SWIFT_TESTING_RUN_DONE_RE.search(test_event_window)
            if swift_done_match is not None:
                events.append(
                    (
                        swift_done_match.start(),
                        swift_done_match.end(),
                        "swift-finished",
                        swift_done_match.group(1).decode("ascii"),
                    )
                )
            if not events:
                break

            _, event_end, event_kind, event_result = min(
                events, key=lambda event: event[0]
            )
            test_event_window = test_event_window[event_end:]
            if event_kind == "swift-started":
                swift_testing_active = True
                post_test_deadline = None
                continue

            assert event_result is not None
            if selected_tests_result != "failed":
                selected_tests_result = event_result
            if event_kind == "swift-finished":
                swift_testing_active = False
            if post_test_timeout and not swift_testing_active:
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
        message = f"Total timed out after {total_timeout:g}s while running {COMMAND_LABEL}"
        report_timeout(message, log_file, TOTAL_TIMEOUT_MARKER)
        if not cleanup_timed_out_child(pid, process_group_id, cleanup_command):
            return 1
        if process_group_id is None:
            report_cleanup_failure()
            print(
                "FAIL: PTY process-group ownership was not verified before timeout cleanup",
                file=sys.stderr,
            )
            return 1
        return TIMEOUT_EXIT_CODE

    if timed_out:
        assert timeout is not None
        message = f"Idle timed out after {timeout:g}s while running {COMMAND_LABEL}"
        report_timeout(message, log_file)
        if not cleanup_timed_out_child(
            pid,
            process_group_id,
            cleanup_command,
            total_deadline,
        ):
            return 1
        if process_group_id is None:
            report_cleanup_failure()
            print(
                "FAIL: PTY process-group ownership was not verified before timeout cleanup",
                file=sys.stderr,
            )
            return 1
        return TIMEOUT_EXIT_CODE

    if post_test_timed_out:
        assert post_test_timeout is not None
        message = (
            f"Post-test timed out after {post_test_timeout:g}s; terminating "
            f"xcodebuild after terminal XCTest summary"
        )
        report_timeout(message, log_file)
        if not cleanup_timed_out_child(
            pid,
            process_group_id,
            cleanup_command,
            total_deadline,
        ):
            return 1
        if process_group_id is None:
            report_cleanup_failure()
            return 1
        if selected_tests_result == "passed" or saw_passing_terminal_summary:
            return 0
        if selected_tests_result == "failed":
            return POST_TEST_FAILED_EXIT_CODE
        return TIMEOUT_EXIT_CODE

    assert status is not None
    if process_group_id is None:
        if log_file is not None:
            log_file.close()
        report_cleanup_failure()
        print("FAIL: PTY process-group ownership receipt was missing", file=sys.stderr)
        return 1
    if cleanup_failed:
        if log_file is not None:
            log_file.close()
        report_cleanup_failure()
        return 1
    # A PTY descendant can keep the terminal open after the direct child has
    # already exited. Do not release the caller with an owned live process
    # group. Reuse the same group-scoped cleanup and preserve the child's
    # reported status when cleanup succeeds.
    if process_group_id is not None and process_group_exists(process_group_id):
        print(
            "WARNING: PTY process group survived child exit; cleaning owned descendants",
            file=sys.stderr,
        )
        if not terminate_child(pid, process_group_id, total_deadline):
            if log_file is not None:
                log_file.close()
            report_cleanup_failure()
            return 1
    if log_file is not None:
        log_file.close()
    return child_exit_code(status)


if __name__ == "__main__":
    raise SystemExit(main())
