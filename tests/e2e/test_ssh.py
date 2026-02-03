import os
import subprocess
import time

import pytest
from protocol import b64encode, read_until, send_msg, wait_for_output

CMUXD_BIN = os.environ.get("CMUXD_BIN", "/opt/cmuxterm/cmuxd/zig-out/bin/cmuxd")
DOCKER_E2E = os.environ.get("CMUX_E2E_DOCKER") == "1"

SSH_CMD = [
    "ssh",
    "-i",
    "/root/.ssh/cmux_test",
    "-o",
    "StrictHostKeyChecking=no",
    "-o",
    "UserKnownHostsFile=/dev/null",
    "-o",
    "BatchMode=yes",
    "-p",
    "2222",
    "cmux@127.0.0.1",
    CMUXD_BIN,
    "--stdio",
]


def start_ssh():
    return subprocess.Popen(
        SSH_CMD,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def test_ssh_handshake_snapshot_resize():
    proc = start_ssh()
    try:
        send_msg(proc, {"type": "hello", "version": 1})
        msg = read_until(proc, lambda m: m.get("type") == "welcome")
        assert msg["type"] == "welcome"
        pane_id = msg["pane_id"]

        send_msg(proc, {"type": "snapshot_request", "pane_id": pane_id})
        snap = read_until(proc, lambda m: m.get("type") == "snapshot")
        assert snap["type"] == "snapshot"
        assert snap["cols"] == 80
        assert snap["rows"] == 24
        assert snap["data"]

        send_msg(proc, {"type": "resize", "pane_id": pane_id, "cols": 100, "rows": 40})
        send_msg(proc, {"type": "snapshot_request", "pane_id": pane_id})
        snap = read_until(proc, lambda m: m.get("type") == "snapshot")
        assert snap["cols"] == 100
        assert snap["rows"] == 40
    finally:
        proc.terminate()
        proc.wait(timeout=5)


def test_ssh_input_output():
    proc = start_ssh()
    try:
        send_msg(proc, {"type": "hello", "version": 1})
        msg = read_until(proc, lambda m: m.get("type") == "welcome")
        pane_id = msg["pane_id"]
        payload = b"echo CMUXE2E\n"
        send_msg(proc, {"type": "input", "pane_id": pane_id, "data": b64encode(payload)})
        wait_for_output(proc, b"CMUXE2E", timeout=15.0, pane_id=pane_id)
    finally:
        proc.terminate()
        proc.wait(timeout=5)


def test_ssh_new_pane_snapshot_output():
    proc = start_ssh()
    try:
        send_msg(proc, {"type": "hello", "version": 1})
        read_until(proc, lambda m: m.get("type") == "welcome")

        send_msg(proc, {"type": "new_pane"})
        created = read_until(proc, lambda m: m.get("type") == "pane_created", timeout=10.0)
        pane_id = created["pane_id"]
        time.sleep(0.2)

        snap = None
        for _ in range(2):
            send_msg(proc, {"type": "snapshot_request", "pane_id": pane_id})
            try:
                snap = read_until(proc, lambda m: m.get("type") == "snapshot", timeout=15.0)
                break
            except TimeoutError:
                time.sleep(0.2)
        if snap is None:
            raise TimeoutError("timed out waiting for snapshot")
        assert snap["data"]

        payload = b"echo CMUXE2E_SSH_PANE\n"
        send_msg(proc, {"type": "input", "pane_id": pane_id, "data": b64encode(payload)})
        wait_for_output(proc, b"CMUXE2E_SSH_PANE", timeout=15.0, pane_id=pane_id)
    finally:
        proc.terminate()
        proc.wait(timeout=5)


def test_ssh_new_pane_cwd():
    proc = start_ssh()
    try:
        send_msg(proc, {"type": "hello", "version": 1})
        read_until(proc, lambda m: m.get("type") == "welcome")

        send_msg(proc, {"type": "new_pane", "cwd": "/tmp"})
        created = read_until(proc, lambda m: m.get("type") == "pane_created", timeout=10.0)
        pane_id = created["pane_id"]
        time.sleep(0.2)
        payload = b"echo READY\n"
        send_msg(proc, {"type": "input", "pane_id": pane_id, "data": b64encode(payload)})
        wait_for_output(proc, b"READY", timeout=20.0, pane_id=pane_id)

        last_err = None
        for _ in range(3):
            payload = b"pwd\n"
            send_msg(proc, {"type": "input", "pane_id": pane_id, "data": b64encode(payload)})
            try:
                wait_for_output(proc, b"/tmp", timeout=45.0, pane_id=pane_id)
                last_err = None
                break
            except TimeoutError as err:
                last_err = err
        if last_err is not None:
            raise last_err
    finally:
        proc.terminate()
        proc.wait(timeout=5)


@pytest.mark.xfail(DOCKER_E2E, reason="flaky pane_exited over ssh in docker e2e")
def test_ssh_pane_exit_event():
    proc = start_ssh()
    try:
        send_msg(proc, {"type": "hello", "version": 1})
        read_until(proc, lambda m: m.get("type") == "welcome")

        send_msg(proc, {"type": "new_pane"})
        created = read_until(proc, lambda m: m.get("type") == "pane_created", timeout=10.0)
        pane_id = created["pane_id"]
        payload = b"echo READY\n"
        send_msg(proc, {"type": "input", "pane_id": pane_id, "data": b64encode(payload)})
        wait_for_output(proc, b"READY", timeout=10.0, pane_id=pane_id)

        payload = b"kill -TERM $$\n"
        send_msg(proc, {"type": "input", "pane_id": pane_id, "data": b64encode(payload)})

        msg = read_until(
            proc,
            lambda m: m.get("type") == "pane_exited" and m.get("pane_id") == pane_id,
            timeout=30.0,
        )
        assert "exit_code" in msg
    finally:
        proc.terminate()
        proc.wait(timeout=5)
