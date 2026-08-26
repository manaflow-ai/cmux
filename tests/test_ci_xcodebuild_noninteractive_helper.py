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
        # PTY-backed interpreter startup can exceed five seconds on a busy
        # macOS builder. The assertion is about recurring heartbeats, not
        # launch latency, so leave enough room for the child to start and
        # finish its short quiet interval.
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

    post_test_env = {
        **os.environ,
        "CMUX_XCODEBUILD_NONINTERACTIVE_POST_TEST_TIMEOUT_SECONDS": "0.2",
    }
    expected_mixed_framework_env = {
        **post_test_env,
        "CMUX_XCODEBUILD_NONINTERACTIVE_EXPECT_SWIFT_TESTING": "1",
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
        env=expected_mixed_framework_env,
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
