#!/usr/bin/env python3
"""Behavioral guard for the CI xcodebuild prompt wrapper."""

from __future__ import annotations

import fcntl
import importlib.util
import os
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
from pathlib import Path
from unittest import mock


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
        tmp_path = Path(tmp)
        lock_path = tmp_path / "detached-app-host.lock"
        pid_path = tmp_path / "detached-app-host.pid"
        receipt_path = tmp_path / "detached-app-host.receipt"
        cleanup_path = tmp_path / "cleanup-receipted-app-host.py"
        receipt_token = "owned-timeout-descendant"
        cleanup_path.write_text(
            textwrap.dedent(
                f"""\
                #!{sys.executable}
                import os
                import signal
                from pathlib import Path

                receipt_path = Path(os.environ["CMUX_TEST_TIMEOUT_RECEIPT"])
                fields = dict(
                    line.split("=", 1)
                    for line in receipt_path.read_text(encoding="utf-8").splitlines()
                )
                if fields.get("token") != os.environ["CMUX_TEST_TIMEOUT_TOKEN"]:
                    raise SystemExit("receipt token mismatch")
                pid = int(fields["pid"])
                os.kill(pid, signal.SIGKILL)
                """
            ),
            encoding="utf-8",
        )
        cleanup_path.chmod(0o700)
        detached_app_host = textwrap.dedent(
            f"""
            import os
            import signal
            import time

            receipt = open({str(receipt_path)!r}, "w", encoding="utf-8")
            receipt.write("token={receipt_token}\\n")
            receipt.write(f"pid={{os.getpid()}}\\n")
            receipt.flush()
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
        pty_owner_with_detached_app_host = textwrap.dedent(
            f"""
            import os
            import subprocess
            import sys
            import time

            subprocess.Popen(
                [sys.executable, "-c", {detached_app_host!r}],
                start_new_session=True,
            )
            for _ in range(300):
                if os.path.exists({str(pid_path)!r}):
                    print("detached app host ready", flush=True)
                    break
                time.sleep(0.01)
            else:
                raise SystemExit("detached app host did not publish its receipt")
            while True:
                time.sleep(0.05)
            """
        )
        detached_timeout_result = subprocess.Popen(
            [
                sys.executable,
                str(LOCK_HELPER),
                str(lock_path),
                "10",
                str(HELPER),
                sys.executable,
                "-c",
                pty_owner_with_detached_app_host,
            ],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={
                **os.environ,
                "CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS": "0.5",
                "CMUX_XCODEBUILD_NONINTERACTIVE_TIMEOUT_CLEANUP_COMMAND": str(
                    cleanup_path
                ),
                "CMUX_TEST_TIMEOUT_RECEIPT": str(receipt_path),
                "CMUX_TEST_TIMEOUT_TOKEN": receipt_token,
            },
            start_new_session=True,
        )
        detached_app_host_pid = 0
        try:
            detached_app_host_pid = wait_for_pid_file(pid_path)
            detached_stdout, detached_stderr = detached_timeout_result.communicate(
                timeout=8
            )
            if detached_timeout_result.returncode != 124:
                print(detached_stdout, end="")
                print(detached_stderr, end="", file=sys.stderr)
                print(
                    "FAIL: detached app-host timeout must return 124, "
                    f"got {detached_timeout_result.returncode}"
                )
                return 1
            released_lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
            try:
                fcntl.flock(released_lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                print(detached_stdout, end="")
                print(detached_stderr, end="", file=sys.stderr)
                print("FAIL: timed-out app-host lock remained held")
                return 1
            finally:
                os.close(released_lock_fd)
            if not wait_for_pid_exit(detached_app_host_pid):
                print(detached_stdout, end="")
                print(detached_stderr, end="", file=sys.stderr)
                print(
                    "FAIL: receipted app-host descendant survived after timeout lock release"
                )
                return 1
        finally:
            if detached_timeout_result.poll() is None:
                kill_process_group(detached_timeout_result.pid)
                detached_timeout_result.wait(timeout=3)
            if detached_app_host_pid and pid_is_alive(detached_app_host_pid):
                os.kill(detached_app_host_pid, signal.SIGKILL)

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
                    "1",
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
                },
            )
        finally:
            os.close(lock_fd)
        if lock_timeout_result.returncode != 1 or command_marker.exists():
            print(lock_timeout_result.stdout, end="")
            print(lock_timeout_result.stderr, end="", file=sys.stderr)
            print("FAIL: app-host lock wait did not fail closed")
            return 1

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        lock_path = tmp_path / "queued-app-host.lock"
        command_marker = tmp_path / "queued-command-env"
        lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        queued_result = subprocess.Popen(
            [
                sys.executable,
                str(LOCK_HELPER),
                str(lock_path),
                "3",
                sys.executable,
                "-c",
                (
                    "import os; from pathlib import Path; "
                    f"Path({str(command_marker)!r}).write_text("
                    "os.environ['CMUX_APP_HOST_XCODEBUILD_TOTAL_TIMEOUT_SECONDS'], "
                    "encoding='utf-8')"
                ),
            ],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={
                **os.environ,
                # The lock remains held past this deadline. A queued shard must
                # still receive the complete execution budget after admission.
                "CMUX_APP_HOST_XCODEBUILD_TOTAL_TIMEOUT_SECONDS": "1",
            },
        )
        try:
            time.sleep(1.2)
            if queued_result.poll() is not None:
                queued_stdout, queued_stderr = queued_result.communicate()
                print(queued_stdout, end="")
                print(queued_stderr, end="", file=sys.stderr)
                print(
                    "FAIL: queued app-host execution budget expired before lock admission"
                )
                return 1
        finally:
            os.close(lock_fd)
        queued_stdout, queued_stderr = queued_result.communicate(timeout=3)
        if (
            queued_result.returncode != 0
            or not command_marker.exists()
            or command_marker.read_text(encoding="utf-8") != "1"
        ):
            print(queued_stdout, end="")
            print(queued_stderr, end="", file=sys.stderr)
            print(
                "FAIL: queued app-host command did not receive its full execution budget"
            )
            return 1

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        lock_path = tmp_path / "timed-out-owner.lock"
        descendant_pid_path = tmp_path / "timed-out-descendant.pid"
        timed_out_owner = textwrap.dedent(
            f"""
            import os
            import signal
            import time

            descendant_pid = os.fork()
            if descendant_pid == 0:
                with open({str(descendant_pid_path)!r}, "w", encoding="utf-8") as marker:
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
            os._exit(124)
            """
        )
        timed_out_result = subprocess.run(
            [
                sys.executable,
                str(LOCK_HELPER),
                str(lock_path),
                "3",
                sys.executable,
                "-c",
                timed_out_owner,
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
            timeout=5,
        )
        timed_out_descendant_pid = wait_for_pid_file(descendant_pid_path)
        try:
            if timed_out_result.returncode != 124:
                print(timed_out_result.stdout, end="")
                print(timed_out_result.stderr, end="", file=sys.stderr)
                print(
                    "FAIL: simulated timeout owner did not preserve its hard failure"
                )
                return 1

            competing_lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
            try:
                try:
                    fcntl.flock(
                        competing_lock_fd,
                        fcntl.LOCK_EX | fcntl.LOCK_NB,
                    )
                except BlockingIOError:
                    pass
                else:
                    print(
                        "FAIL: timed-out descendant survived after machine-lock release"
                    )
                    return 1
            finally:
                os.close(competing_lock_fd)
        finally:
            if pid_is_alive(timed_out_descendant_pid):
                os.kill(timed_out_descendant_pid, signal.SIGKILL)

        released_lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            deadline = time.monotonic() + 3
            while True:
                try:
                    fcntl.flock(
                        released_lock_fd,
                        fcntl.LOCK_EX | fcntl.LOCK_NB,
                    )
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        print(
                            "FAIL: descendant exit did not release the inherited machine lock"
                        )
                        return 1
                    time.sleep(0.01)
        finally:
            os.close(released_lock_fd)

    helper_spec = importlib.util.spec_from_file_location(
        "cmux_xcodebuild_noninteractive",
        HELPER,
    )
    if helper_spec is None or helper_spec.loader is None:
        print("FAIL: xcodebuild helper could not be loaded for state validation")
        return 1
    helper_module = importlib.util.module_from_spec(helper_spec)
    helper_spec.loader.exec_module(helper_module)

    cleanup_timeout_seen: list[float] = []

    def record_cleanup_timeout(
        _args: list[str], *, check: bool, timeout: float
    ) -> subprocess.CompletedProcess[str]:
        if check:
            raise AssertionError("timeout cleanup must inspect its exit status")
        cleanup_timeout_seen.append(timeout)
        return subprocess.CompletedProcess(args=_args, returncode=0)

    # Receipt cleanup can verify and terminate several launchd-restored app
    # hosts from one xcodebuild attempt. Its work must use the attempt's one
    # remaining deadline, not an independent short cap that can fail while the
    # admitted execution still has time.
    overall_cleanup_deadline = time.monotonic() + 60
    with mock.patch.object(
        helper_module.subprocess,
        "run",
        side_effect=record_cleanup_timeout,
    ):
        try:
            cleanup_completed = helper_module.run_timeout_cleanup(
                "/tmp/receipt-verified-cleanup",
                overall_cleanup_deadline,
            )
        except TypeError:
            cleanup_completed = False
    if (
        not cleanup_completed
        or len(cleanup_timeout_seen) != 1
        or cleanup_timeout_seen[0] <= helper_module.TIMEOUT_CLEANUP_SECONDS
    ):
        print(
            "FAIL: receipt cleanup did not receive the one remaining execution deadline"
        )
        return 1

    exiting_group = subprocess.CompletedProcess(
        args=["/bin/ps"],
        returncode=0,
        stdout=(
            " 700 700 UE   /usr/bin/xcodebuild\n"
            " 701 700 Z    cmux DEV\n"
            " 800 800 S    unrelated\n"
        ),
        stderr="",
    )
    with mock.patch.object(
        helper_module.subprocess,
        "run",
        return_value=exiting_group,
    ):
        if helper_module.process_group_has_live_members(700):
            print(
                "FAIL: SIGKILL-terminal exiting and zombie members were treated as active"
            )
            return 1

    active_group = subprocess.CompletedProcess(
        args=["/bin/ps"],
        returncode=0,
        stdout=" 702 700 S    /usr/bin/xctest\n",
        stderr="",
    )
    with mock.patch.object(
        helper_module.subprocess,
        "run",
        return_value=active_group,
    ):
        if not helper_module.process_group_has_live_members(700):
            print("FAIL: an active PTY member was accepted as terminal")
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
