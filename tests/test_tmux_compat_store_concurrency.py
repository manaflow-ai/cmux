#!/usr/bin/env python3
"""Regression: concurrent tmux buffer writes must preserve every buffer."""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import uuid
from pathlib import Path


WRITER_COUNT = 48
VALUE_SIZE = 16 * 1024
PROCESS_TIMEOUT_SECONDS = 30


def fail(message: str) -> int:
    print(f"FAIL: {message}")
    return 1


def serve_connections(server: socket.socket, stop: threading.Event) -> None:
    while not stop.is_set():
        try:
            connection, _ = server.accept()
        except OSError:
            return
        connection.close()


def main() -> int:
    cli = os.environ.get("CMUX_CLI_BIN")
    if not cli or not os.path.isfile(cli) or not os.access(cli, os.X_OK):
        return fail("Set CMUX_CLI_BIN to the executable cmux CLI under test")

    with tempfile.TemporaryDirectory(prefix="cmux-tmux-store-") as temp_dir:
        root = Path(temp_dir)
        socket_path = root / "fixture.sock"
        start_gate = root / "start"
        home = root / "home"
        home.mkdir()

        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(socket_path))
        server.listen(WRITER_COUNT)
        stop = threading.Event()
        server_thread = threading.Thread(
            target=serve_connections,
            args=(server, stop),
            daemon=True,
        )
        server_thread.start()

        run_id = uuid.uuid4().hex
        expected = {
            f"flock-{run_id}-{index}": f"{index}:" + ("x" * VALUE_SIZE)
            for index in range(WRITER_COUNT)
        }
        launcher = """
import os
import sys
import time

cli, socket_path, gate, name, value = sys.argv[1:]
while not os.path.exists(gate):
    time.sleep(0.001)
os.execve(
    cli,
    [cli, "--socket", socket_path, "set-buffer", "--name", name, value],
    os.environ,
)
"""

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["CFFIXED_USER_HOME"] = str(home)
        processes = [
            subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    launcher,
                    cli,
                    str(socket_path),
                    str(start_gate),
                    name,
                    value,
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=env,
            )
            for name, value in expected.items()
        ]

        start_gate.touch()
        failures: list[str] = []
        for process in processes:
            try:
                stdout, stderr = process.communicate(timeout=PROCESS_TIMEOUT_SECONDS)
            except subprocess.TimeoutExpired:
                process.kill()
                stdout, stderr = process.communicate()
                failures.append(f"timed out: stdout={stdout!r} stderr={stderr!r}")
                continue
            if process.returncode != 0:
                failures.append(
                    f"exit={process.returncode}: stdout={stdout!r} stderr={stderr!r}"
                )

        stop.set()
        server.close()
        server_thread.join(timeout=1)

        if failures:
            return fail(f"{len(failures)} writer process(es) failed; first={failures[0]}")

        store_path = home / ".cmuxterm" / "tmux-compat-store.json"
        if not store_path.is_file():
            return fail(f"tmux compatibility store was not written at {store_path}")

        store = json.loads(store_path.read_text(encoding="utf-8"))
        actual_buffers = store.get("buffers") or {}
        missing = sorted(
            name for name, value in expected.items() if actual_buffers.get(name) != value
        )
        if missing:
            return fail(
                f"concurrent set-buffer lost {len(missing)} of {WRITER_COUNT} buffers; "
                f"first missing={missing[0]}"
            )

    print(f"PASS: preserved all {WRITER_COUNT} concurrent tmux buffer writes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
