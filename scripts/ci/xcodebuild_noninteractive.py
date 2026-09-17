#!/usr/bin/env python3
"""Run xcodebuild under a PTY and dismiss Swift crash prompts in CI."""

from __future__ import annotations

import os
import pty
import re
import select
import shutil
import signal
import subprocess
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
# The app host (cmux DEV) logs to the same PTY as xcodebuild. Its lines carry
# an NSLog-style prefix: "2026-09-08 14:03:49.521479+0000 cmux DEV[13904:67193] ".
# Background work (fleet polling, renderer wakeups) keeps emitting them while
# no test makes progress, so they must not count as activity for the idle
# timeout; otherwise a stalled test host looks alive until the job-level cap.
APP_HOST_LOG_LINE_RE = re.compile(
    rb"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+[+-]\d{4} [^\r\n\[]*\[\d+:\d+\] "
)


def contains_test_progress(chunk: bytes, pending: bytearray) -> bool:
    """Whether `chunk` completes at least one line that is not app-host log noise.

    `pending` carries the unterminated tail between chunks so a line split
    across reads is classified once, as a whole.
    """
    pending.extend(chunk)
    progress = False
    while True:
        newline = pending.find(b"\n")
        if newline < 0:
            break
        line = bytes(pending[:newline]).rstrip(b"\r")
        del pending[: newline + 1]
        if line.strip() and not APP_HOST_LOG_LINE_RE.match(line):
            progress = True
    # A stray line with no newline for a very long time would otherwise pin
    # memory; the prefix is all that classification needs.
    if len(pending) > 65536:
        del pending[:-4096]
    return progress


def app_host_pids(derived_data_path: str) -> list[int]:
    """PIDs of the XCTest app host xcodebuild launched from this run's DerivedData.

    Scoped to the DerivedData path so a developer's other cmux instances are
    never inspected; CI exports `CMUX_DERIVED_DATA_PATH` per job.
    """
    if shutil.which("pgrep") is None:
        return []
    pattern = re.escape(derived_data_path.rstrip("/")) + r"/Build/Products/[^/]+/cmux[^/]*\.app/Contents/MacOS/"
    try:
        result = subprocess.run(
            ["pgrep", "-f", pattern],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    pids = []
    for token in result.stdout.split():
        try:
            pids.append(int(token))
        except ValueError:
            continue
    return pids


def sample_app_host(log_file: BinaryIO | None, stdout_fd: int) -> None:
    """Record where the app host is stuck before an idle timeout kills it.

    Best effort: `sample` may be missing or refuse, and diagnostics must never
    change the timeout outcome.
    """
    derived_data_path = os.environ.get("CMUX_DERIVED_DATA_PATH", "")
    sampler = shutil.which("sample")
    if sampler is None or not derived_data_path:
        return
    for pid in app_host_pids(derived_data_path)[:2]:
        try:
            result = subprocess.run(
                [sampler, str(pid), "2", "-mayDie"],
                capture_output=True,
                timeout=45,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            continue
        output = result.stdout or result.stderr
        if not output:
            continue
        header = f"[idle timeout] app-host pid {pid} sample:\n".encode()
        if log_file is not None:
            try:
                log_file.write(header + output + b"\n")
            except OSError:
                pass
        # Keep stdout bounded: the call graph's head names the stuck frames.
        excerpt = b"\n".join(output.splitlines()[:160]) + b"\n"
        write_child_output(header + excerpt, None, stdout_fd)


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

    # An outer timeout (the CI batch runner) terminates this wrapper; forward
    # that to the whole xcodebuild process group so the test host cannot
    # outlive the wrapper and hold the batch's output pipe open.
    def forward_termination(signum: int, _frame: object) -> None:
        message = f"Terminated by signal {signum}; stopping xcodebuild process group\n"
        write_child_output(message.encode(), log_file, stdout_fd)
        if log_file is not None:
            try:
                log_file.close()
            except OSError:
                pass
        terminate_child(pid)
        os._exit(TIMEOUT_EXIT_CODE)

    signal.signal(signal.SIGTERM, forward_termination)
    signal.signal(signal.SIGINT, forward_termination)
    prompt_window = b""
    pending_line = bytearray()
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
        if heartbeat_deadline is not None:
            remaining = max(0, heartbeat_deadline - time.monotonic())
            select_timeout = min(
                select_timeout if select_timeout is not None else remaining,
                remaining,
            )

        try:
            readable, _, _ = select.select([fd], [], [], select_timeout)
        except OSError:
            break
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
            break
        if not chunk:
            break

        write_child_output(chunk, log_file, stdout_fd)
        if heartbeat:
            heartbeat_deadline = time.monotonic() + heartbeat
        if timeout and contains_test_progress(chunk, pending_line):
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
        message = (
            f"Idle timed out after {timeout:g}s (no test progress; app-host log "
            f"lines do not count): {' '.join(sys.argv[1:])}"
        )
        print(message, file=sys.stderr)
        if log_file is not None:
            log_file.write(f"{message}\n".encode())
        sample_app_host(log_file, stdout_fd)
        if log_file is not None:
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
        if selected_tests_result == "passed" or saw_passing_terminal_summary:
            return 0
        if selected_tests_result == "failed":
            return POST_TEST_FAILED_EXIT_CODE
        return TIMEOUT_EXIT_CODE

    if heartbeat is None:
        _, status = os.waitpid(pid, 0)
    else:
        while True:
            finished, status = os.waitpid(pid, os.WNOHANG)
            if finished:
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
    if log_file is not None:
        log_file.close()
    return child_exit_code(status)


if __name__ == "__main__":
    raise SystemExit(main())
