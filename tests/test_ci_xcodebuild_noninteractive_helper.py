#!/usr/bin/env python3
"""Behavioral guard for the CI xcodebuild prompt wrapper."""

from __future__ import annotations

import fcntl
import os
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "ci" / "xcodebuild_noninteractive.py"
LOCK_HELPER = ROOT / "scripts" / "ci" / "app_host_test_lock.py"
PROMPT = "Press space to interact, D to debug, or any other key to quit"


def wait_for_pid_file(path: Path, timeout: float = 3.0) -> int:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            value = path.read_text(encoding="utf-8").strip()
        except FileNotFoundError:
            value = ""
        if value.isdigit() and int(value) > 0:
            return int(value)
        time.sleep(0.01)
    raise AssertionError(f"child PID was not published in {path}")


def pid_is_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def wait_for_pid_exit(pid: int, timeout: float = 2.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not pid_is_alive(pid):
            return True
        time.sleep(0.01)
    return not pid_is_alive(pid)


def kill_process_group(pid: int) -> None:
    try:
        os.killpg(os.getpgid(pid), signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


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
    noisy_started = time.monotonic()
    noisy_post_test_result = subprocess.run(
        [sys.executable, str(HELPER), sys.executable, "-c", noisy_post_test_child],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
        timeout=5,
        env=post_test_env,
    )
    noisy_elapsed = time.monotonic() - noisy_started
    if noisy_post_test_result.returncode != 0:
        print(noisy_post_test_result.stdout, end="")
        print(noisy_post_test_result.stderr, end="", file=sys.stderr)
        print(
            "FAIL: expected noisy post-test timeout after passing Selected tests summary "
            f"to exit 0, got {noisy_post_test_result.returncode}"
        )
        return 1
    if noisy_elapsed > 1.5:
        print(noisy_post_test_result.stdout, end="")
        print(noisy_post_test_result.stderr, end="", file=sys.stderr)
        print(f"FAIL: noisy post-test timeout was rearmed; elapsed {noisy_elapsed:.2f}s")
        return 1

    with tempfile.TemporaryDirectory() as tmp:
        swift_testing_progress = Path(tmp) / "swift-testing-progress"
        mixed_framework_child = textwrap.dedent(
            f"""
            import time
            from pathlib import Path

            print("Test Suite 'Selected tests' passed at now", flush=True)
            print("Test run started.", flush=True)
            time.sleep(0.35)
            Path({str(swift_testing_progress)!r}).write_text("active", encoding="utf-8")
            print(
                "Test run with 1 test in 1 suite passed after 0.35 seconds.",
                flush=True,
            )
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
        if (
            mixed_framework_result.returncode != 0
            or not swift_testing_progress.exists()
        ):
            print(mixed_framework_result.stdout, end="")
            print(mixed_framework_result.stderr, end="", file=sys.stderr)
            print(
                "FAIL: XCTest summary timeout stopped an active Swift Testing run"
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

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        lock_path = tmp_path / "app-host.lock"
        pid_path = tmp_path / "pty-child.pid"
        stubborn_descendant = textwrap.dedent(
            f"""
            import os
            import signal
            import time

            with open({str(pid_path)!r}, "w", encoding="utf-8") as marker:
                marker.write(str(os.getpid()))
                marker.flush()
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.signal(signal.SIGHUP, signal.SIG_IGN)
            for fd in (0, 1, 2):
                try:
                    os.close(fd)
                except OSError:
                    pass
            while True:
                time.sleep(0.05)
            """
        )
        pty_leader = textwrap.dedent(
            f"""
            import os
            import signal
            import subprocess
            import sys
            import time

            subprocess.Popen([sys.executable, "-c", {stubborn_descendant!r}])
            signal.signal(signal.SIGHUP, signal.SIG_IGN)
            for fd in (0, 1, 2):
                try:
                    os.close(fd)
                except OSError:
                    pass
            while True:
                time.sleep(0.05)
            """
        )
        total_timeout_result = subprocess.Popen(
            [
                sys.executable,
                str(LOCK_HELPER),
                str(lock_path),
                "10",
                str(HELPER),
                sys.executable,
                "-c",
                pty_leader,
            ],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={
                **os.environ,
                "CMUX_XCODEBUILD_NONINTERACTIVE_TOTAL_TIMEOUT_SECONDS": "0.2",
            },
            start_new_session=True,
        )
        pty_descendant_pid = 0
        try:
            pty_descendant_pid = wait_for_pid_file(pid_path)
            try:
                total_stdout, total_stderr = total_timeout_result.communicate(timeout=8)
            except subprocess.TimeoutExpired as exc:
                kill_process_group(total_timeout_result.pid)
                total_timeout_result.wait(timeout=3)
                raise AssertionError(
                    "total timeout did not release the app-host lock owner"
                ) from exc
            if total_timeout_result.returncode != 124:
                print(total_stdout, end="")
                print(total_stderr, end="", file=sys.stderr)
                print(
                    "FAIL: total timeout must return 124, "
                    f"got {total_timeout_result.returncode}"
                )
                return 1
            if "Total timed out after 0.2s" not in total_stderr:
                print(total_stdout, end="")
                print(total_stderr, end="", file=sys.stderr)
                print("FAIL: total timeout diagnostic is missing")
                return 1
            if not wait_for_pid_exit(pty_descendant_pid):
                print(total_stdout, end="")
                print(total_stderr, end="", file=sys.stderr)
                print(
                    "FAIL: PTY descendant survived after the lock owner released the lock"
                )
                return 1
        finally:
            if total_timeout_result.poll() is None:
                kill_process_group(total_timeout_result.pid)
                total_timeout_result.wait(timeout=3)
            if pty_descendant_pid and pid_is_alive(pty_descendant_pid):
                os.kill(pty_descendant_pid, signal.SIGKILL)

    with tempfile.TemporaryDirectory() as tmp:
        pid_path = Path(tmp) / "orphaned-pty-child.pid"
        orphaned_descendant = textwrap.dedent(
            f"""
            import os
            import signal
            import time

            with open({str(pid_path)!r}, "w", encoding="utf-8") as marker:
                marker.write(str(os.getpid()))
                marker.flush()
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.signal(signal.SIGHUP, signal.SIG_IGN)
            # Keep stdout open so the descendant retains the PTY after its
            # leader exits. The helper must reap the leader independently of
            # PTY EOF and clean the owned process group.
            for fd in (0, 2):
                try:
                    os.close(fd)
                except OSError:
                    pass
            while True:
                time.sleep(0.05)
            """
        )
        leader_exits_with_live_descendant = textwrap.dedent(
            f"""
            import os
            import subprocess
            import sys
            import time

            subprocess.Popen([sys.executable, "-c", {orphaned_descendant!r}])
            for _ in range(100):
                if os.path.exists({str(pid_path)!r}):
                    break
                time.sleep(0.01)
            for fd in (0, 1, 2):
                try:
                    os.close(fd)
                except OSError:
                    pass
            os._exit(0)
            """
        )
        orphan_result = subprocess.run(
            [
                sys.executable,
                str(HELPER),
                sys.executable,
                "-c",
                leader_exits_with_live_descendant,
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
            timeout=5,
        )
        if orphan_result.returncode != 0:
            print(orphan_result.stdout, end="")
            print(orphan_result.stderr, end="", file=sys.stderr)
            print(
                "FAIL: helper must return the leader's exit status after descendant cleanup"
            )
            return 1
        orphan_pid = wait_for_pid_file(pid_path)
        if not wait_for_pid_exit(orphan_pid):
            print(orphan_result.stdout, end="")
            print(orphan_result.stderr, end="", file=sys.stderr)
            print("FAIL: PTY descendant survived its leader's exit")
            os.kill(orphan_pid, signal.SIGKILL)
            return 1

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        lock_path = tmp_path / "held-app-host.lock"
        command_marker = tmp_path / "command-ran"
        lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            lock_timeout_result = subprocess.run(
                [
                    sys.executable,
                    str(LOCK_HELPER),
                    str(lock_path),
                    "5",
                    sys.executable,
                    "-c",
                    f"open({str(command_marker)!r}, 'w').close()",
                ],
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=False,
                timeout=3,
                env={
                    **os.environ,
                    "CMUX_APP_HOST_XCODEBUILD_TOTAL_TIMEOUT_SECONDS": "1",
                },
            )
        finally:
            os.close(lock_fd)
        if lock_timeout_result.returncode != 124 or command_marker.exists():
            print(lock_timeout_result.stdout, end="")
            print(lock_timeout_result.stderr, end="", file=sys.stderr)
            print("FAIL: total deadline did not bound the app-host lock wait")
            return 1

    for invalid_total_timeout in ("0.5", "1.0", "001"):
        invalid_result = subprocess.run(
            [
                sys.executable,
                str(LOCK_HELPER),
                str(Path(tempfile.gettempdir()) / "unused-app-host.lock"),
                "1",
                sys.executable,
                "-c",
                "raise SystemExit('command must not start')",
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
            env={
                **os.environ,
                "CMUX_APP_HOST_XCODEBUILD_TOTAL_TIMEOUT_SECONDS": invalid_total_timeout,
            },
        )
        if invalid_result.returncode != 2:
            print(invalid_result.stdout, end="")
            print(invalid_result.stderr, end="", file=sys.stderr)
            print(
                "FAIL: invalid total timeout must be rejected before lock acquisition: "
                f"{invalid_total_timeout!r}"
            )
            return 1

    print(
        "PASS: xcodebuild noninteractive helper dismisses crash prompts, "
        "bounds lock waits, and cleans timed-out process groups"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
