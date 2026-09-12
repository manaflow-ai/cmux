#!/usr/bin/env python3
"""Behavioral guard for the CI xcodebuild prompt wrapper."""

from __future__ import annotations

import subprocess
import sys
import textwrap
import os
import signal
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "ci" / "xcodebuild_noninteractive.py"
PROMPT = "Press space to interact, D to debug, or any other key to quit"


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
        timeout=5,
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
        timeout=5,
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
        timeout=5,
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
        timeout=5,
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
    # The helper may spend a short, platform-dependent interval draining the
    # terminated PTY group. Assert the semantic contract directly: post-test
    # deadline handling must not be rearmed by every line of noise.
    if noisy_post_test_result.stdout.count("post-summary-noise") > 5:
        print(noisy_post_test_result.stdout, end="")
        print(noisy_post_test_result.stderr, end="", file=sys.stderr)
        print(
            "FAIL: noisy post-test timeout was rearmed; "
            f"saw {noisy_post_test_result.stdout.count('post-summary-noise')} lines"
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
        timeout=5,
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

    mixed_framework_child = textwrap.dedent(
        """
        import time

        print("Test Suite 'Selected tests' passed at now", flush=True)
        print("\\t Executed 1 test, with 0 failures (0 unexpected) in 0.001 seconds", flush=True)
        print("Test run started.", flush=True)
        time.sleep(0.35)
        print("Test run with 1 test in 1 suite passed after 0.350 seconds.", flush=True)
        time.sleep(10)
        """
    )
    mixed_framework_result = subprocess.run(
        [sys.executable, str(HELPER), sys.executable, "-c", mixed_framework_child],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=5,
        env=post_test_env,
    )
    if mixed_framework_result.returncode != 0:
        print(mixed_framework_result.stdout, end="")
        print(mixed_framework_result.stderr, end="", file=sys.stderr)
        print(
            "FAIL: expected the completed mixed-framework run to exit 0, "
            f"got {mixed_framework_result.returncode}"
        )
        return 1
    if "Test run with 1 test in 1 suite passed" not in mixed_framework_result.stdout:
        print(mixed_framework_result.stdout, end="")
        print(mixed_framework_result.stderr, end="", file=sys.stderr)
        print("FAIL: helper killed Swift Testing after the XCTest summary")
        return 1

    failing_mixed_framework_child = textwrap.dedent(
        """
        import time

        print("Test Suite 'Selected tests' passed at now", flush=True)
        print("\\t Executed 1 test, with 0 failures (0 unexpected) in 0.001 seconds", flush=True)
        print("Test run started.", flush=True)
        time.sleep(0.35)
        print("Test run with 1 test in 1 suite failed after 0.350 seconds.", flush=True)
        time.sleep(10)
        """
    )
    failing_mixed_framework_result = subprocess.run(
        [
            sys.executable,
            str(HELPER),
            sys.executable,
            "-c",
            failing_mixed_framework_child,
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=5,
        env=post_test_env,
    )
    if failing_mixed_framework_result.returncode != 125:
        print(failing_mixed_framework_result.stdout, end="")
        print(failing_mixed_framework_result.stderr, end="", file=sys.stderr)
        print(
            "FAIL: expected failed Swift Testing summary to exit 125, "
            f"got {failing_mixed_framework_result.returncode}"
        )
        return 1

    direct_output_child = "import sys; sys.stdout.write('x' * 262144); sys.stdout.flush()"
    direct_output_result = subprocess.run(
        [sys.executable, str(HELPER), sys.executable, "-c", direct_output_child],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=5,
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

    # A child can exit while a descendant keeps the PTY slave open. The helper
    # must reap the leader independently of PTY EOF and clean that owned
    # descendant instead of blocking forever in waitpid().
    with tempfile.TemporaryDirectory() as tmp:
        descendant_pid_path = Path(tmp) / "descendant.pid"
        descendant = textwrap.dedent(
            f"""
            import os, signal, time
            with open({str(descendant_pid_path)!r}, "w", encoding="utf-8") as marker:
                marker.write(str(os.getpid()))
                marker.flush()
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            while True:
                time.sleep(0.05)
            """
        )
        leader = textwrap.dedent(
            f"""
            import os, subprocess, sys, time
            subprocess.Popen([sys.executable, "-c", {descendant!r}])
            for _ in range(500):
                if os.path.exists({str(descendant_pid_path)!r}):
                    break
                time.sleep(0.01)
            os._exit(0)
            """
        )
        orphan_result = subprocess.run(
            [sys.executable, str(HELPER), sys.executable, "-c", leader],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
            timeout=15,
        )
        if orphan_result.returncode != 0:
            print(orphan_result.stdout, end="")
            print(orphan_result.stderr, end="", file=sys.stderr)
            print("FAIL: helper did not return the leader status after PTY EOF")
            return 1
        try:
            descendant_pid = int(descendant_pid_path.read_text(encoding="utf-8"))
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                try:
                    os.kill(descendant_pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.01)
            else:
                print(orphan_result.stdout, end="")
                print(orphan_result.stderr, end="", file=sys.stderr)
                print("FAIL: PTY descendant survived leader exit")
                os.kill(descendant_pid, signal.SIGKILL)
                return 1
        except (FileNotFoundError, ValueError):
            print("FAIL: orphan test did not publish descendant PID")
            return 1

    print(
        "PASS: xcodebuild noninteractive helper dismisses crash prompts, "
        "heartbeats quiet children, and idle-times out stuck children"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
