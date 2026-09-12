#!/usr/bin/env python3
"""Behavioral guard for the CI xcodebuild prompt wrapper."""

from __future__ import annotations

import subprocess
import sys
import textwrap
import os
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "ci" / "xcodebuild_noninteractive.py"
PROMPT = "Press space to interact, D to debug, or any other key to quit"
# PTY-backed interpreter startup can be several seconds on a busy macOS
# builder. Keep the harness timeout separate from the short behavioral
# deadlines exercised by each child process.
HELPER_TEST_TIMEOUT_SECONDS = 15
SWIFT_TESTING_FAILED_EXIT_CODE = 123
POST_TEST_FAILED_EXIT_CODE = 125
EXPECTED_SWIFT_TESTING_MISSING_EXIT_CODE = 126
TOTAL_TIMEOUT_EXIT_CODE = 127


def main() -> int:
    child = textwrap.dedent(
        f"""
        import sys
        import termios
        import tty

        prompt = {PROMPT!r}
        fd = sys.stdin.fileno()
        old = termios.tcgetattr(fd)
        tty.setraw(fd)
        try:
            for _ in range(2):
                print(prompt, flush=True)
                ch = sys.stdin.read(1)
                print('received=' + ch, flush=True)
                termios.tcflush(fd, termios.TCIFLUSH)
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)
        raise SystemExit(7)
        """
    )
    result = subprocess.run(
        [sys.executable, str(HELPER), sys.executable, "-c", child],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )

    if result.returncode != 7:
        print(result.stdout, end="")
        print(result.stderr, end="", file=sys.stderr)
        print(f"FAIL: expected wrapped command exit 7, got {result.returncode}")
        return 1
    if result.stdout.count("received=q") != 2:
        print(result.stdout, end="")
        print("FAIL: helper did not answer each crash prompt with q")
        return 1

    timeout_child = textwrap.dedent(
        """
        import time

        print("ready", flush=True)
        time.sleep(10)
        """
    )
    timeout_env = {
        **os.environ,
        "CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS": "0.2",
    }
    timeout_result = subprocess.run(
        [sys.executable, str(HELPER), sys.executable, "-c", timeout_child],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=HELPER_TEST_TIMEOUT_SECONDS,
        env=timeout_env,
    )
    if timeout_result.returncode != 124:
        print(timeout_result.stdout, end="")
        print(timeout_result.stderr, end="", file=sys.stderr)
        print(f"FAIL: expected timeout exit 124, got {timeout_result.returncode}")
        return 1
    if "Idle timed out after 0.2s" not in timeout_result.stderr:
        print(timeout_result.stdout, end="")
        print(timeout_result.stderr, end="", file=sys.stderr)
        print("FAIL: helper did not report idle timeout")
        return 1

    # App-host log lines (NSLog-style prefix) are background noise: a stalled
    # test host that keeps polling must still idle-time out.
    noisy_idle_child = textwrap.dedent(
        """
        import time

        print("ready", flush=True)
        for _ in range(60):
            print("2026-09-08 14:03:49.521479+0000 cmux DEV[13904:67193] [CloudVM] GET /api/vm not_signed_in 1ms", flush=True)
            time.sleep(0.05)
        """
    )
    noisy_idle_env = {
        **os.environ,
        "CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS": "0.5",
    }
    noisy_idle_result = subprocess.run(
        [sys.executable, str(HELPER), sys.executable, "-c", noisy_idle_child],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=10,
        env=noisy_idle_env,
    )
    if noisy_idle_result.returncode != 124 or "no test progress" not in noisy_idle_result.stderr:
        print(noisy_idle_result.stdout, end="")
        print(noisy_idle_result.stderr, end="", file=sys.stderr)
        print(
            "FAIL: app-host log noise kept the idle timeout from firing "
            f"(exit {noisy_idle_result.returncode})"
        )
        return 1

    # Real test progress interleaved with the same noise keeps the run alive.
    progressing_child = textwrap.dedent(
        """
        import time

        for index in range(6):
            print("2026-09-08 14:03:49.521479+0000 cmux DEV[13904:67193] [generic_renderer] tick", flush=True)
            print(f"\u25c7 Test example{index}() started.", flush=True)
            time.sleep(0.25)
        print("done", flush=True)
        raise SystemExit(3)
        """
    )
    # A generous idle window relative to the child's cadence: this asserts the
    # reset, not scheduling latency on a loaded machine.
    progressing_env = {
        **os.environ,
        "CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS": "3",
    }
    progressing_result = subprocess.run(
        [sys.executable, str(HELPER), sys.executable, "-c", progressing_child],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=20,
        env=progressing_env,
    )
    if progressing_result.returncode != 3:
        print(progressing_result.stdout, end="")
        print(progressing_result.stderr, end="", file=sys.stderr)
        print(
            "FAIL: test progress should reset the idle timeout "
            f"(expected exit 3, got {progressing_result.returncode})"
        )
        return 1

    # An outer timeout terminates the wrapper; the wrapped process group must
    # go with it instead of surviving to hold the batch's output pipe open.
    with tempfile.TemporaryDirectory() as sigterm_dir:
        pid_file = Path(sigterm_dir) / "child.pid"
        sigterm_child = textwrap.dedent(
            f"""
            import os
            import time

            open({str(pid_file)!r}, "w").write(str(os.getpid()))
            print("ready", flush=True)
            time.sleep(30)
            """
        )
        wrapper = subprocess.Popen(
            [sys.executable, str(HELPER), sys.executable, "-c", sigterm_child],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        deadline = time.monotonic() + 10
        while not pid_file.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        wrapper.send_signal(15)
        try:
            wrapper_stdout, wrapper_stderr = wrapper.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            wrapper.kill()
            print("FAIL: helper did not exit after SIGTERM")
            return 1
        if wrapper.returncode != 124 or "Terminated by signal 15" not in wrapper_stdout:
            print(wrapper_stdout, end="")
            print(wrapper_stderr, end="", file=sys.stderr)
            print(f"FAIL: expected SIGTERM to exit 124, got {wrapper.returncode}")
            return 1
        child_pid = int(pid_file.read_text())
        alive_deadline = time.monotonic() + 6
        child_alive = True
        while time.monotonic() < alive_deadline:
            try:
                os.kill(child_pid, 0)
            except ProcessLookupError:
                child_alive = False
                break
            time.sleep(0.1)
        if child_alive:
            os.kill(child_pid, 9)
            print("FAIL: wrapped child survived the helper's SIGTERM")
            return 1

    heartbeat_result = subprocess.run(
        [
            sys.executable,
            str(HELPER),
            sys.executable,
            "-c",
            "import os, time; os.close(1); os.close(2); time.sleep(0.35)",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=HELPER_TEST_TIMEOUT_SECONDS,
        env={
            **os.environ,
            "CMUX_XCODEBUILD_NONINTERACTIVE_HEARTBEAT_SECONDS": "0.1",
        },
    )
    if heartbeat_result.returncode != 0 or heartbeat_result.stdout.count(
        "[xcodebuild still running after"
    ) < 2:
        print(heartbeat_result.stdout, end="")
        print(heartbeat_result.stderr, end="", file=sys.stderr)
        print("FAIL: helper did not emit recurring heartbeats for a quiet child")
        return 1

    total_timeout_child = textwrap.dedent(
        """
        import time

        for index in range(10):
            print(f"active={index}", flush=True)
            time.sleep(0.05)
        """
    )
    total_timeout_result = subprocess.run(
        [sys.executable, str(HELPER), sys.executable, "-c", total_timeout_child],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=HELPER_TEST_TIMEOUT_SECONDS,
        env={
            **os.environ,
            "CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS": "1",
            "CMUX_XCODEBUILD_NONINTERACTIVE_TOTAL_TIMEOUT_SECONDS": "0.2",
        },
    )
    if total_timeout_result.returncode != TOTAL_TIMEOUT_EXIT_CODE:
        print(total_timeout_result.stdout, end="")
        print(total_timeout_result.stderr, end="", file=sys.stderr)
        print(
            "FAIL: continuously active output must not extend the total deadline, "
            f"got {total_timeout_result.returncode}"
        )
        return 1
    if "Total timed out after 0.2s" not in total_timeout_result.stderr:
        print(total_timeout_result.stdout, end="")
        print(total_timeout_result.stderr, end="", file=sys.stderr)
        print("FAIL: helper did not report total timeout")
        return 1

    post_test_env = {
        **os.environ,
        "CMUX_XCODEBUILD_NONINTERACTIVE_POST_TEST_TIMEOUT_SECONDS": "0.2",
    }
    expected_mixed_framework_env = {
        **post_test_env,
        "CMUX_XCODEBUILD_NONINTERACTIVE_EXPECT_SWIFT_TESTING": "1",
    }
    mixed_framework_env = {
        **expected_mixed_framework_env,
        "CMUX_XCODEBUILD_NONINTERACTIVE_POST_TEST_TIMEOUT_SECONDS": "5",
    }
    passing_post_test_child = textwrap.dedent(
        """
        import time

        print("Test Suite 'Selected tests' passed at now", flush=True)
        print("\\t Executed 1 test, with 0 failures (0 unexpected) in 0.001 seconds", flush=True)
        time.sleep(10)
        """
    )
    passing_post_test_result = subprocess.run(
        [sys.executable, str(HELPER), sys.executable, "-c", passing_post_test_child],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=HELPER_TEST_TIMEOUT_SECONDS,
        env=post_test_env,
    )
    if passing_post_test_result.returncode != 0:
        print(passing_post_test_result.stdout, end="")
        print(passing_post_test_result.stderr, end="", file=sys.stderr)
        print(
            "FAIL: expected post-test timeout after passing Selected tests summary to exit 0, "
            f"got {passing_post_test_result.returncode}"
        )
        return 1

    noisy_post_test_child = textwrap.dedent(
        """
        import time

        print("Test Suite 'Selected tests' passed at now", flush=True)
        print("\\t Executed 1 test, with 0 failures (0 unexpected) in 0.001 seconds", flush=True)
        for _ in range(20):
            print("post-summary-noise", flush=True)
            time.sleep(0.1)
        """
    )
    noisy_post_test_result = subprocess.run(
        [sys.executable, str(HELPER), sys.executable, "-c", noisy_post_test_child],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=HELPER_TEST_TIMEOUT_SECONDS,
        env=post_test_env,
    )
    if noisy_post_test_result.returncode != 0:
        print(noisy_post_test_result.stdout, end="")
        print(noisy_post_test_result.stderr, end="", file=sys.stderr)
        print(
            "FAIL: expected noisy post-test timeout after passing Selected tests summary "
            f"to exit 0, got {noisy_post_test_result.returncode}"
        )
        return 1
    # The child startup cost varies substantially across CI hosts. Count the
    # captured post-summary lines instead of using wall-clock startup time: a
    # re-armed deadline lets the child emit all 20 lines, while a one-shot
    # deadline captures only the first couple before terminating it.
    if noisy_post_test_result.stdout.count("post-summary-noise") >= 20:
        print(noisy_post_test_result.stdout, end="")
        print(noisy_post_test_result.stderr, end="", file=sys.stderr)
        print("FAIL: noisy post-test timeout was rearmed")
        return 1

    for marker in (
        "application message: Test run started. (not a framework event)",
        "2026-09-10 14:03:49.521479+0000 cmux DEV[13904:67193] Test run started.",
    ):
        incidental_marker_child = textwrap.dedent(
            f"""
            import time

            print({marker!r}, flush=True)
            print("Test Suite 'Selected tests' passed at now", flush=True)
            print({marker!r}, flush=True)
            for _ in range(20):
                print("post-summary-noise", flush=True)
                time.sleep(0.1)
            """
        )
        result = subprocess.run(
            [sys.executable, str(HELPER), sys.executable, "-c", incidental_marker_child],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
            timeout=HELPER_TEST_TIMEOUT_SECONDS,
            env=post_test_env,
        )
        if result.returncode != 0 or "Post-test timed out" not in result.stderr:
            print(result.stdout, end="")
            print(result.stderr, end="", file=sys.stderr)
            print("FAIL: incidental app-host marker canceled the post-test deadline")
            return 1

    delayed_swift_testing_child = textwrap.dedent(
        """
        import time

        print("Test Suite 'Selected tests' passed at now", flush=True)
        print("\\t Executed 1 test, with 0 failures (0 unexpected) in 0.001 seconds", flush=True)
        time.sleep(0.4)
        print("◇ Test run started.", flush=True)
        print("✔ Test run with 1 test passed after 0.001 seconds.", flush=True)
        """
    )
    delayed_swift_testing_result = subprocess.run(
        [sys.executable, str(HELPER), sys.executable, "-c", delayed_swift_testing_child],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=HELPER_TEST_TIMEOUT_SECONDS,
        env=expected_mixed_framework_env,
    )
    if (
        delayed_swift_testing_result.returncode
        != EXPECTED_SWIFT_TESTING_MISSING_EXIT_CODE
    ):
        print(delayed_swift_testing_result.stdout, end="")
        print(delayed_swift_testing_result.stderr, end="", file=sys.stderr)
        print(
            "FAIL: expected a missing or delayed Swift Testing phase to fail closed, "
            f"got {delayed_swift_testing_result.returncode}"
        )
        return 1

    missing_swift_testing_child = textwrap.dedent(
        """
        print("Test Suite 'Selected tests' passed at now", flush=True)
        print("\\t Executed 1 test, with 0 failures (0 unexpected) in 0.001 seconds", flush=True)
        """
    )
    missing_swift_testing_result = subprocess.run(
        [sys.executable, str(HELPER), sys.executable, "-c", missing_swift_testing_child],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=HELPER_TEST_TIMEOUT_SECONDS,
        env=expected_mixed_framework_env,
    )
    if (
        missing_swift_testing_result.returncode
        != EXPECTED_SWIFT_TESTING_MISSING_EXIT_CODE
    ):
        print(missing_swift_testing_result.stdout, end="")
        print(missing_swift_testing_result.stderr, end="", file=sys.stderr)
        print(
            "FAIL: expected a clean child exit without Swift Testing to fail closed, "
            f"got {missing_swift_testing_result.returncode}"
        )
        return 1

    incidental_swift_testing_child = textwrap.dedent(
        """
        import time

        print("Test Suite 'Selected tests' passed at now", flush=True)
        print("\\t Executed 1 test, with 0 failures (0 unexpected) in 0.001 seconds", flush=True)
        print("application message: Test run with 1 test passed after 0.001 seconds.", flush=True)
        time.sleep(10)
        """
    )
    incidental_swift_testing_result = subprocess.run(
        [sys.executable, str(HELPER), sys.executable, "-c", incidental_swift_testing_child],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=HELPER_TEST_TIMEOUT_SECONDS,
        env=expected_mixed_framework_env,
    )
    if (
        incidental_swift_testing_result.returncode
        != EXPECTED_SWIFT_TESTING_MISSING_EXIT_CODE
    ):
        print(incidental_swift_testing_result.stdout, end="")
        print(incidental_swift_testing_result.stderr, end="", file=sys.stderr)
        print(
            "FAIL: an incidental Swift Testing completion line without a start event "
            "must not satisfy the required phase, "
            f"got {incidental_swift_testing_result.returncode}"
        )
        return 1

    missing_swift_testing_nonzero_child = textwrap.dedent(
        """
        print("Test Suite 'Selected tests' passed at now", flush=True)
        print("\\t Executed 1 test, with 0 failures (0 unexpected) in 0.001 seconds", flush=True)
        raise SystemExit(65)
        """
    )
    missing_swift_testing_nonzero_result = subprocess.run(
        [
            sys.executable,
            str(HELPER),
            sys.executable,
            "-c",
            missing_swift_testing_nonzero_child,
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=HELPER_TEST_TIMEOUT_SECONDS,
        env=expected_mixed_framework_env,
    )
    if (
        missing_swift_testing_nonzero_result.returncode
        != EXPECTED_SWIFT_TESTING_MISSING_EXIT_CODE
    ):
        print(missing_swift_testing_nonzero_result.stdout, end="")
        print(missing_swift_testing_nonzero_result.stderr, end="", file=sys.stderr)
        print(
            "FAIL: expected a nonzero child exit after XCTest but before Swift Testing "
            "to fail as an incomplete mixed-framework run, "
            f"got {missing_swift_testing_nonzero_result.returncode}"
        )
        return 1

    expected_xctest_failure_without_swift_child = textwrap.dedent(
        """
        print("Test Suite 'Selected tests' failed at now", flush=True)
        print("\\t Executed 1 test, with 1 failure (0 unexpected) in 0.001 seconds", flush=True)
        """
    )
    expected_xctest_failure_without_swift_result = subprocess.run(
        [
            sys.executable,
            str(HELPER),
            sys.executable,
            "-c",
            expected_xctest_failure_without_swift_child,
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=HELPER_TEST_TIMEOUT_SECONDS,
        env=expected_mixed_framework_env,
    )
    if (
        expected_xctest_failure_without_swift_result.returncode
        != EXPECTED_SWIFT_TESTING_MISSING_EXIT_CODE
    ):
        print(expected_xctest_failure_without_swift_result.stdout, end="")
        print(
            expected_xctest_failure_without_swift_result.stderr,
            end="",
            file=sys.stderr,
        )
        print(
            "FAIL: an expected XCTest failure must not hide a missing Swift Testing phase "
            "after child exit, "
            f"got {expected_xctest_failure_without_swift_result.returncode}"
        )
        return 1

    expected_xctest_failure_timeout_child = textwrap.dedent(
        """
        import time

        print("Test Suite 'Selected tests' failed at now", flush=True)
        print("\\t Executed 1 test, with 1 failure (0 unexpected) in 0.001 seconds", flush=True)
        time.sleep(10)
        """
    )
    expected_xctest_failure_timeout_result = subprocess.run(
        [
            sys.executable,
            str(HELPER),
            sys.executable,
            "-c",
            expected_xctest_failure_timeout_child,
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=HELPER_TEST_TIMEOUT_SECONDS,
        env=expected_mixed_framework_env,
    )
    if (
        expected_xctest_failure_timeout_result.returncode
        != EXPECTED_SWIFT_TESTING_MISSING_EXIT_CODE
    ):
        print(expected_xctest_failure_timeout_result.stdout, end="")
        print(expected_xctest_failure_timeout_result.stderr, end="", file=sys.stderr)
        print(
            "FAIL: an expected XCTest failure must not hide a missing Swift Testing phase "
            "after post-test timeout, "
            f"got {expected_xctest_failure_timeout_result.returncode}"
        )
        return 1

    mixed_framework_child = textwrap.dedent(
        """
        import time

        print("Test Suite 'Selected tests' passed at now", flush=True)
        print("\\t Executed 1 test, with 0 failures (0 unexpected) in 0.001 seconds", flush=True)
        print("◇ Test run started.", flush=True)
        time.sleep(0.4)
        print("✔ Test run with 1 test passed after 0.4 seconds.", flush=True)
        print("swift-testing-complete", flush=True)
        """
    )
    mixed_framework_result = subprocess.run(
        [sys.executable, str(HELPER), sys.executable, "-c", mixed_framework_child],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=HELPER_TEST_TIMEOUT_SECONDS,
        env=mixed_framework_env,
    )
    if mixed_framework_result.returncode != 0:
        print(mixed_framework_result.stdout, end="")
        print(mixed_framework_result.stderr, end="", file=sys.stderr)
        print(
            "FAIL: expected a Swift Testing run after the XCTest summary to exit 0, "
            f"got {mixed_framework_result.returncode}"
        )
        return 1
    if "swift-testing-complete" not in mixed_framework_result.stdout:
        print(mixed_framework_result.stdout, end="")
        print(mixed_framework_result.stderr, end="", file=sys.stderr)
        print("FAIL: helper terminated active Swift Testing after the XCTest summary")
        return 1

    suite_count_swift_testing_child = textwrap.dedent(
        """
        print("Test Suite 'Selected tests' passed at now", flush=True)
        print("\\t Executed 1 test, with 0 failures (0 unexpected) in 0.001 seconds", flush=True)
        print("◇ Test run started.", flush=True)
        print("✔ Test run with 2 tests in 2 suites passed after 0.001 seconds.", flush=True)
        """
    )
    suite_count_swift_testing_result = subprocess.run(
        [sys.executable, str(HELPER), sys.executable, "-c", suite_count_swift_testing_child],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=HELPER_TEST_TIMEOUT_SECONDS,
        env=expected_mixed_framework_env,
    )
    if suite_count_swift_testing_result.returncode != 0:
        print(suite_count_swift_testing_result.stdout, end="")
        print(suite_count_swift_testing_result.stderr, end="", file=sys.stderr)
        print(
            "FAIL: expected a Swift Testing suite-count summary to be terminal, "
            f"got {suite_count_swift_testing_result.returncode}"
        )
        return 1

    active_swift_testing_timeout_child = textwrap.dedent(
        """
        import time

        print("Test Suite 'Selected tests' passed at now", flush=True)
        print("\\t Executed 1 test, with 0 failures (0 unexpected) in 0.001 seconds", flush=True)
        print("◇ Test run started.", flush=True)
        time.sleep(10)
        """
    )
    active_swift_testing_timeout_result = subprocess.run(
        [
            sys.executable,
            str(HELPER),
            sys.executable,
            "-c",
            active_swift_testing_timeout_child,
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=HELPER_TEST_TIMEOUT_SECONDS,
        env={
            **expected_mixed_framework_env,
            # Leave room for the PTY child to start before exercising the
            # incomplete Swift Testing classification on an idle phase.
            "CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS": "5",
        },
    )
    if (
        active_swift_testing_timeout_result.returncode
        != EXPECTED_SWIFT_TESTING_MISSING_EXIT_CODE
    ):
        print(active_swift_testing_timeout_result.stdout, end="")
        print(active_swift_testing_timeout_result.stderr, end="", file=sys.stderr)
        print(
            "FAIL: an active Swift Testing phase that times out must fail as incomplete, "
            f"got {active_swift_testing_timeout_result.returncode}"
        )
        return 1

    failing_mixed_framework_child = textwrap.dedent(
        """
        import time

        print("Test Suite 'Selected tests' passed at now", flush=True)
        print("\\t Executed 1 test, with 0 failures (0 unexpected) in 0.001 seconds", flush=True)
        print("◇ Test run started.", flush=True)
        time.sleep(0.4)
        print("✘ Test run with 1 test failed after 0.4 seconds with 1 issue.", flush=True)
        time.sleep(10)
        """
    )
    failing_mixed_framework_result = subprocess.run(
        [sys.executable, str(HELPER), sys.executable, "-c", failing_mixed_framework_child],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=HELPER_TEST_TIMEOUT_SECONDS,
        env=expected_mixed_framework_env,
    )
    if failing_mixed_framework_result.returncode != SWIFT_TESTING_FAILED_EXIT_CODE:
        print(failing_mixed_framework_result.stdout, end="")
        print(failing_mixed_framework_result.stderr, end="", file=sys.stderr)
        print(
            "FAIL: expected a failed Swift Testing summary to override the passing "
            f"XCTest summary, got {failing_mixed_framework_result.returncode}"
        )
        return 1

    failed_then_passing_swift_testing_child = textwrap.dedent(
        """
        print("Test Suite 'Selected tests' passed at now", flush=True)
        print("\\t Executed 1 test, with 0 failures (0 unexpected) in 0.001 seconds", flush=True)
        print("◇ Test run started.", flush=True)
        print("✘ Test run with 1 test failed after 0.001 seconds with 1 issue.", flush=True)
        print("◇ Test run started.", flush=True)
        print("✔ Test run with 1 test passed after 0.001 seconds.", flush=True)
        """
    )
    failed_then_passing_swift_testing_result = subprocess.run(
        [
            sys.executable,
            str(HELPER),
            sys.executable,
            "-c",
            failed_then_passing_swift_testing_child,
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=HELPER_TEST_TIMEOUT_SECONDS,
        env=expected_mixed_framework_env,
    )
    if (
        failed_then_passing_swift_testing_result.returncode
        != SWIFT_TESTING_FAILED_EXIT_CODE
    ):
        print(failed_then_passing_swift_testing_result.stdout, end="")
        print(
            failed_then_passing_swift_testing_result.stderr,
            end="",
            file=sys.stderr,
        )
        print(
            "FAIL: a later passing Swift Testing phase must not hide an earlier failure, "
            f"got {failed_then_passing_swift_testing_result.returncode}"
        )
        return 1

    failed_then_passing_xctest_child = textwrap.dedent(
        """
        print("Test Suite 'Selected tests' failed at now", flush=True)
        print("\\t Executed 1 test, with 1 failure (1 unexpected) in 0.001 seconds", flush=True)
        print("Test Suite 'Selected tests' passed at later", flush=True)
        print("\\t Executed 1 test, with 0 failures (0 unexpected) in 0.001 seconds", flush=True)
        """
    )
    failed_then_passing_xctest_result = subprocess.run(
        [
            sys.executable,
            str(HELPER),
            sys.executable,
            "-c",
            failed_then_passing_xctest_child,
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=HELPER_TEST_TIMEOUT_SECONDS,
        env=post_test_env,
    )
    if failed_then_passing_xctest_result.returncode != POST_TEST_FAILED_EXIT_CODE:
        print(failed_then_passing_xctest_result.stdout, end="")
        print(failed_then_passing_xctest_result.stderr, end="", file=sys.stderr)
        print(
            "FAIL: a later passing XCTest summary must not hide an earlier failure, "
            f"got {failed_then_passing_xctest_result.returncode}"
        )
        return 1

    failing_post_test_child = textwrap.dedent(
        """
        import time

        print("Test Suite 'Selected tests' failed at now", flush=True)
        print("\\t Executed 1 test, with 1 failure (1 unexpected) in 0.001 seconds", flush=True)
        time.sleep(10)
        """
    )
    failing_post_test_result = subprocess.run(
        [sys.executable, str(HELPER), sys.executable, "-c", failing_post_test_child],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=HELPER_TEST_TIMEOUT_SECONDS,
        env=post_test_env,
    )
    if failing_post_test_result.returncode != 125:
        print(failing_post_test_result.stdout, end="")
        print(failing_post_test_result.stderr, end="", file=sys.stderr)
        print(
            "FAIL: expected post-test timeout after failed Selected tests summary to exit 125, "
            f"got {failing_post_test_result.returncode}"
        )
        return 1

    direct_output_child = "import sys; sys.stdout.write('x' * 262144); sys.stdout.flush()"
    direct_output_result = subprocess.run(
        [sys.executable, str(HELPER), sys.executable, "-c", direct_output_child],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=HELPER_TEST_TIMEOUT_SECONDS,
    )
    if direct_output_result.returncode != 0:
        print(direct_output_result.stdout, end="")
        print(direct_output_result.stderr, end="", file=sys.stderr)
        print(f"FAIL: expected direct output child exit 0, got {direct_output_result.returncode}")
        return 1
    if direct_output_result.stdout.count("x") != 262144:
        print(direct_output_result.stderr, end="", file=sys.stderr)
        print(
            f"FAIL: direct helper output was truncated to {direct_output_result.stdout.count('x')} bytes"
        )
        return 1

    with tempfile.TemporaryDirectory() as tmp:
        log_path = Path(tmp) / "helper.log"
        log_child = "print('child-log-line', flush=True)"
        log_result = subprocess.run(
            [sys.executable, str(HELPER), sys.executable, "-c", log_child],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
            env={
                **os.environ,
                "CMUX_XCODEBUILD_NONINTERACTIVE_LOG_PATH": str(log_path),
            },
        )
        if log_result.returncode != 0:
            print(log_result.stdout, end="")
            print(log_result.stderr, end="", file=sys.stderr)
            print(f"FAIL: expected log child exit 0, got {log_result.returncode}")
            return 1
        if "child-log-line" not in log_path.read_text():
            print(log_result.stdout, end="")
            print(log_result.stderr, end="", file=sys.stderr)
            print("FAIL: helper did not write child output to log path")
            return 1

    print(
        "PASS: xcodebuild noninteractive helper dismisses crash prompts, "
        "heartbeats quiet children, and idle-times out stuck children"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
