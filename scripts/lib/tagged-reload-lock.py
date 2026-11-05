#!/usr/bin/env python3
"""Keep each tagged reload's cleanup, build, and launch in one exclusive lease."""

import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

# Sent on the watch pipe once the supervisor saw its reload end on its own.
RELEASED = b"released\n"


def kill_grace_seconds() -> float:
    try:
        return max(0.0, float(os.environ.get("CMUX_RELOAD_TAG_LOCK_KILL_GRACE", "10")))
    except ValueError:
        return 10.0


def session_alive(leader: int) -> bool:
    """True while the process group the supervisor started still has members.

    The reload is a session leader, so its pid is its pgid and sid. A live
    process with that pid must still lead that group; once the leader is gone,
    the id cannot be handed to a new process while the group still exists.
    """
    try:
        if os.getpgid(leader) != leader:
            return False
    except ProcessLookupError:
        pass
    try:
        os.killpg(leader, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return False
    return True


def watch_session(read_fd: int) -> int:
    """End the reload's session if its supervisor dies without releasing it.

    Runs in its own session so a kill of the step's process group, SIGKILL
    included, does not take it down. It holds only the read end of a pipe whose
    write end only the supervisor holds, so EOF means the supervisor is gone.
    """
    for number in (signal.SIGINT, signal.SIGHUP):
        signal.signal(number, signal.SIG_IGN)
    with os.fdopen(read_fd, "rb", buffering=0) as pipe:
        leader_line = b""
        while not leader_line.endswith(b"\n"):
            chunk = pipe.read(1)
            if not chunk:
                return 0  # Supervisor ended before starting the reload.
            leader_line += chunk
        leader = int(leader_line)
        message = b""
        while True:
            chunk = pipe.read(64)
            if not chunk:
                break
            message += chunk
    if message.startswith(RELEASED) or not session_alive(leader):
        return 0
    try:
        os.killpg(leader, signal.SIGTERM)
    except ProcessLookupError:
        return 0
    deadline = time.monotonic() + kill_grace_seconds()
    while time.monotonic() < deadline:
        if not session_alive(leader):
            return 0
        time.sleep(0.1)
    if session_alive(leader):
        try:
            os.killpg(leader, signal.SIGKILL)
        except ProcessLookupError:
            pass
    return 0


def start_watcher():
    read_fd, write_fd = os.pipe()  # Both non-inheritable.
    try:
        watcher = subprocess.Popen(
            [sys.executable, "-I", os.path.abspath(__file__), "--watch-session", str(read_fd)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            # The lease fd must never reach the watcher: it would keep later
            # reloads of the tag locked after the supervisor died.
            close_fds=True,
            pass_fds=(read_fd,),
        )
    finally:
        os.close(read_fd)
    return watcher, write_fd


def main() -> int:
    if sys.argv[1:2] == ["--watch-session"]:
        return watch_session(int(sys.argv[2]))
    tag, script, *arguments = sys.argv[1:]
    lock_directory = Path(tempfile.gettempdir()) / f"cmux-reload-tags-{os.getuid()}"
    lock_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (lock_directory / f"{tag}.lock").open("a") as lease:
        try:
            fcntl.flock(lease.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(f"==> Waiting for the active reload of tag {tag}...", flush=True)
            fcntl.flock(lease.fileno(), fcntl.LOCK_EX)

        # Only this supervisor owns the lease. Build services and the launched
        # app must not inherit it and keep later reloads locked indefinitely.
        environment = os.environ.copy()
        environment["CMUX_RELOAD_TAG_LOCK_OWNER"] = str(os.getpid())
        # Test-only: record the reload's pid here, then SIGKILL this supervisor
        # right after Popen returns, the window before #35952's fix handed the
        # pid to the watcher.
        kill_after_popen = environment.pop("CMUX_RELOAD_TAG_LOCK_TEST_KILL_AFTER_POPEN", "")
        child = None
        pending_signals = []
        forwarded = []

        def forward_signal(number, _frame):
            forwarded.append(number)
            if child is None:
                pending_signals.append(number)
                return
            try:
                os.killpg(child.pid, number)
            except ProcessLookupError:
                pass

        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(number, forward_signal)
        # The reload runs in its own session, so a stop that kills this
        # supervisor's group without letting it forward (SIGKILL) would leave
        # the reload and its build running. The watcher ends that session then.
        watcher, watch_fd = start_watcher()
        environment["CMUX_RELOAD_TAG_LOCK_WATCHER"] = str(watcher.pid)

        def report_pid_to_watcher():
            # Runs in the child after setsid, before exec. The child hands the
            # watcher its own pid, so the watcher knows the session however
            # early the supervisor dies, then drops its copy of the write end so
            # the supervisor stays its only holder. preexec_fn is unsafe only
            # with threads; this supervisor is single-threaded.
            os.write(watch_fd, f"{os.getpid()}\n".encode())
            os.close(watch_fd)

        child = subprocess.Popen(
            ["bash", script, *arguments],
            env=environment,
            start_new_session=True,
            close_fds=True,
            pass_fds=(watch_fd,),
            preexec_fn=report_pid_to_watcher,
        )
        if kill_after_popen:
            Path(kill_after_popen).write_text(f"{child.pid}\n")
            os.kill(os.getpid(), signal.SIGKILL)
        for number in pending_signals:
            forward_signal(number, None)
        result = child.wait()
        if not forwarded:
            # Ended on its own: whatever it left in its session (build
            # services) is not ours to stop.
            os.write(watch_fd, RELEASED)
        os.close(watch_fd)
        if not forwarded:
            try:
                watcher.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
        return result if result >= 0 else 128 - result


if __name__ == "__main__":
    raise SystemExit(main())
