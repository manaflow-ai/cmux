#!/usr/bin/env python3
"""Exercise zsh shell-readiness delivery with real local Unix sockets."""

import os
import socket
import subprocess
import tempfile
import threading
import time
from pathlib import Path

SOURCE = Path(os.environ.get(
    "CMUX_TEST_SOURCE",
    Path(__file__).resolve().parents[1]
    / "Resources/shell-integration/cmux-zsh-integration.zsh",
))
TAB_ID = "11111111-1111-1111-1111-111111111111"
PANEL_ID = "22222222-2222-2222-2222-222222222222"
LIFECYCLE_ID = "33333333-3333-3333-3333-333333333333"


def run_shell(socket_path: Path, body: str) -> subprocess.Popen[str]:
    env = {
        "HOME": tempfile.gettempdir(),
        "PATH": "/usr/bin:/bin",
        "CMUX_SOCKET_PATH": str(socket_path),
        "CMUX_TAB_ID": TAB_ID,
        "CMUX_PANEL_ID": PANEL_ID,
        "CMUX_TERMINAL_LIFECYCLE_ID": LIFECYCLE_ID,
    }
    return subprocess.Popen(
        ["/bin/zsh", "-f", "-c", f"source {str(SOURCE)!r}\n{body}"],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def serve(
    path: Path,
    ready: threading.Event,
    received: list[str],
    delay: float = 0,
    responses: tuple[str, ...] = ("ACK:accepted",),
    expected_connections: int = 1,
    bind_before_delay: bool = False,
) -> None:
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    if bind_before_delay:
        listener.bind(str(path))
        ready.set()
        time.sleep(delay)
    else:
        ready.set()
        time.sleep(delay)
        listener.bind(str(path))
    listener.listen()
    listener.settimeout(3)
    try:
        while len(received) < expected_connections:
            try:
                connection, _ = listener.accept()
            except TimeoutError:
                break
            with connection:
                connection.settimeout(1)
                data = b""
                while b"\n" not in data:
                    part = connection.recv(4096)
                    if not part:
                        break
                    data += part
                if data:
                    received.append(data.decode().splitlines()[0])
                    response = responses[min(len(received) - 1, len(responses) - 1)]
                    connection.sendall(f"{response}\n".encode())
    finally:
        listener.close()


def check_late_listener_retries_once(root: Path) -> None:
    path = root / "late.sock"
    received: list[str] = []
    ready = threading.Event()
    thread = threading.Thread(target=serve, args=(path, ready, received, 0.35), daemon=True)
    thread.start()
    assert ready.wait(timeout=2)
    shell = run_shell(
        path,
        "_cmux_report_shell_activity_state prompt\n"
        "_cmux_report_shell_activity_state prompt\n"
        "sleep 1",
    )
    _, stderr = shell.communicate(timeout=3)
    thread.join(timeout=4)
    assert shell.returncode == 0, stderr
    assert received == [f"report_shell_state prompt --tab={TAB_ID} --panel={PANEL_ID} --ack --terminal-lifecycle-id={LIFECYCLE_ID}"], received
    print("PASS late listener: one prompt delivered after initial connection failures")


def check_running_cancels_prompt_retries(root: Path) -> None:
    path = root / "cancel.sock"
    received: list[str] = []
    ready = threading.Event()
    thread = threading.Thread(
        target=serve,
        args=(path, ready, received, 0.5),
        kwargs={"expected_connections": 2, "bind_before_delay": True},
        daemon=True,
    )
    thread.start()
    assert ready.wait(timeout=2)
    shell = run_shell(
        path,
        "_cmux_report_shell_activity_state prompt\nsleep 0.1\n_cmux_report_shell_activity_state running\nsleep 1",
    )
    _, stderr = shell.communicate(timeout=3)
    thread.join(timeout=4)
    assert shell.returncode == 0, stderr
    assert received == [f"report_shell_state running --tab={TAB_ID} --panel={PANEL_ID} --ack --terminal-lifecycle-id={LIFECYCLE_ID}"], received
    print("PASS running cancels pending prompt retries")


def check_saturation_does_not_latch_prompt(root: Path) -> None:
    path = root / "saturation.sock"
    received: list[str] = []
    ready = threading.Event()
    thread = threading.Thread(target=serve, args=(path, ready, received), daemon=True)
    thread.start()
    assert ready.wait(timeout=2)
    body = """
_saturation_checks=0
_cmux_zsh_job_table_saturated() {
  (( _saturation_checks++ == 0 ))
}
_cmux_report_shell_activity_state prompt
_cmux_report_shell_activity_state prompt
sleep 1
"""
    shell = run_shell(path, body)
    _, stderr = shell.communicate(timeout=3)
    thread.join(timeout=4)
    assert shell.returncode == 0, stderr
    assert len(received) == 1 and received[0].startswith("report_shell_state prompt ") and " --ack " in received[0], received
    print("PASS job saturation leaves readiness eligible for retry")


def check_application_rejection_retries_until_ack(root: Path) -> None:
    path = root / "application-rejection.sock"
    received: list[str] = []
    ready = threading.Event()
    thread = threading.Thread(
        target=serve,
        args=(path, ready, received),
        kwargs={"responses": ("ERROR: retry", "ACK:accepted"), "expected_connections": 2},
        daemon=True,
    )
    thread.start()
    assert ready.wait(timeout=2)
    shell = run_shell(path, "_cmux_report_shell_activity_state prompt\nsleep 1")
    _, stderr = shell.communicate(timeout=3)
    thread.join(timeout=4)
    assert shell.returncode == 0, stderr
    assert len(received) == 2 and all(" --ack " in line for line in received), received
    print("PASS application rejection is retried until accepted")


def check_stale_lifecycle_is_not_acknowledged(root: Path) -> None:
    path = root / "stale-lifecycle.sock"
    received: list[str] = []
    ready = threading.Event()
    thread = threading.Thread(
        target=serve,
        args=(path, ready, received),
        kwargs={"responses": ("ERROR: stale-lifecycle",)},
        daemon=True,
    )
    thread.start()
    assert ready.wait(timeout=2)
    payload = f"report_shell_state prompt --tab={TAB_ID} --panel={PANEL_ID} --terminal-lifecycle-id={LIFECYCLE_ID} --ack"
    shell = run_shell(path, f"_cmux_send_shell_activity_ack {payload!r}; print ack_status=$?")
    stdout, stderr = shell.communicate(timeout=3)
    thread.join(timeout=4)
    assert shell.returncode == 0, stderr
    assert "ack_status=2" in stdout, stdout
    assert len(received) == 1, received
    print("PASS stale lifecycle is rejected without retry")


def check_already_current_ack_stops_retries(root: Path) -> None:
    path = root / "already-current.sock"
    received: list[str] = []
    ready = threading.Event()
    thread = threading.Thread(
        target=serve,
        args=(path, ready, received),
        kwargs={"responses": ("ACK:already-current",)},
        daemon=True,
    )
    thread.start()
    assert ready.wait(timeout=2)
    shell = run_shell(path, "_cmux_report_shell_activity_state prompt\nsleep 1")
    _, stderr = shell.communicate(timeout=3)
    thread.join(timeout=4)
    assert shell.returncode == 0, stderr
    assert len(received) == 1 and " --ack " in received[0], received
    print("PASS accepted duplicate stops retries")


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-readiness-") as temp:
        root = Path(temp)
        check_late_listener_retries_once(root)
        check_running_cancels_prompt_retries(root)
        check_saturation_does_not_latch_prompt(root)
        check_application_rejection_retries_until_ack(root)
        check_stale_lifecycle_is_not_acknowledged(root)
        check_already_current_ack_stops_retries(root)
    print("6 offline local-socket checks passed")


if __name__ == "__main__":
    main()
