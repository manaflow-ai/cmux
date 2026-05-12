#!/usr/bin/env python3
"""
Regression harness for pooled tmux compatibility calls.

Agent-team launchers can fan out through a tmux shim. This drives parallel
`cmux __hot-path tmux ...` calls through a fake app socket and asserts the app
side sees bounded connection concurrency while still executing real JSON-RPC
request/response paths.
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli


WORKSPACE_ID = "11111111-1111-1111-1111-111111111111"
PANE_ID = "22222222-2222-2222-2222-222222222222"
SURFACE_ID = "33333333-3333-3333-3333-333333333333"


class FakeCmuxSocketServer:
    def __init__(self, socket_path: str, response_delay: float) -> None:
        self.socket_path = socket_path
        self.response_delay = response_delay
        self._ready = threading.Event()
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._lock = threading.Lock()
        self.total_connections = 0
        self.active_connections = 0
        self.max_active_connections = 0
        self.methods: list[str] = []
        self._listener: socket.socket | None = None

    def start(self) -> None:
        self._thread.start()
        if not self._ready.wait(timeout=5.0):
            raise RuntimeError("fake socket server did not start in time")

    def stop(self) -> None:
        self._stop.set()
        if self._listener is not None:
            try:
                self._listener.close()
            except OSError:
                pass
        self._thread.join(timeout=5.0)

    def _serve(self) -> None:
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._listener = listener
        listener.bind(self.socket_path)
        listener.listen(128)
        listener.settimeout(0.1)
        self._ready.set()

        while not self._stop.is_set():
            try:
                conn, _ = listener.accept()
            except TimeoutError:
                continue
            except OSError:
                if self._stop.is_set():
                    break
                continue

            with self._lock:
                self.total_connections += 1
                self.active_connections += 1
                self.max_active_connections = max(self.max_active_connections, self.active_connections)

            threading.Thread(target=self._handle_conn, args=(conn,), daemon=True).start()

    def _result_for_method(self, method: str) -> dict[str, object]:
        if method == "workspace.create":
            return {"workspace_id": WORKSPACE_ID, "workspace_ref": "workspace:1"}
        if method == "workspace.rename":
            return {"workspace_id": WORKSPACE_ID, "ok": True}
        if method == "workspace.list":
            return {"workspaces": [{"id": WORKSPACE_ID, "ref": "workspace:1", "index": 1, "title": "burst"}]}
        if method == "surface.current":
            return {"workspace_id": WORKSPACE_ID, "pane_id": PANE_ID, "surface_id": SURFACE_ID}
        if method == "pane.surfaces":
            return {"surfaces": [{"id": SURFACE_ID, "ref": "surface:1", "selected": True}]}
        if method == "pane.list":
            return {"panes": [{"id": PANE_ID, "ref": "pane:1", "index": 1, "surface_ids": [SURFACE_ID]}]}
        raise AssertionError(f"unexpected method: {method}")

    def _handle_conn(self, conn: socket.socket) -> None:
        buffer = b""
        try:
            while not self._stop.is_set():
                chunk = conn.recv(4096)
                if not chunk:
                    break
                buffer += chunk
                while b"\n" in buffer:
                    raw_line, buffer = buffer.split(b"\n", 1)
                    line = raw_line.strip()
                    if not line:
                        continue
                    request = json.loads(line.decode("utf-8"))
                    method = str(request.get("method", ""))
                    with self._lock:
                        self.methods.append(method)
                    if self.response_delay > 0:
                        time.sleep(self.response_delay)
                    response = {"id": request.get("id"), "ok": True, "result": self._result_for_method(method)}
                    conn.sendall((json.dumps(response) + "\n").encode("utf-8"))
        finally:
            try:
                conn.close()
            except OSError:
                pass
            with self._lock:
                self.active_connections = max(0, self.active_connections - 1)


def main() -> int:
    failures: list[str] = []
    cli_path = resolve_cmux_cli()

    with tempfile.TemporaryDirectory(prefix="cmux-hot-path-tmux-") as td:
        root = Path(td)
        app_socket = str(root / "cmux.sock")
        broker_socket = str(root / "hot-path-broker.sock")
        server = FakeCmuxSocketServer(socket_path=app_socket, response_delay=0.02)
        server.start()
        try:
            procs: list[subprocess.Popen[str]] = []
            env = {
                **os.environ,
                "CMUX_WORKSPACE_ID": WORKSPACE_ID,
                "CMUX_SURFACE_ID": SURFACE_ID,
                "CMUX_HOT_PATH_BROKER_IDLE_TIMEOUT_SECONDS": "1",
                "TMUX_PANE": f"%{PANE_ID}",
            }
            for _ in range(60):
                procs.append(
                    subprocess.Popen(
                        [
                            cli_path,
                            "--socket",
                            app_socket,
                            "__hot-path",
                            "--broker-socket",
                            broker_socket,
                            "tmux",
                            "new-session",
                            "-d",
                            "-P",
                            "-F",
                            "#{window_id}",
                            "-s",
                            "burst",
                        ],
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                        env=env,
                    )
                )

            for index, proc in enumerate(procs):
                try:
                    stdout, stderr = proc.communicate(timeout=20.0)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    stdout, stderr = proc.communicate()
                    failures.append(f"request {index} timed out: stdout={stdout!r} stderr={stderr!r}")
                    continue
                if proc.returncode != 0:
                    failures.append(
                        f"request {index} exited {proc.returncode}: stdout={stdout!r} stderr={stderr!r}"
                    )
                elif "@11111111-1111-1111-1111-111111111111" not in stdout:
                    failures.append(f"request {index} returned unexpected stdout: {stdout!r}")

            if server.max_active_connections > 4:
                failures.append(
                    "expected <=4 concurrent app socket connections during pooled tmux burst, "
                    f"saw {server.max_active_connections}"
                )
            if server.total_connections > 4:
                failures.append(
                    "expected <=4 total app socket connections during pooled tmux burst, "
                    f"saw {server.total_connections}"
                )

            required = {"workspace.create", "workspace.rename", "workspace.list", "surface.current", "pane.surfaces"}
            seen = set(server.methods)
            missing = required - seen
            if missing:
                failures.append(f"fake app socket did not receive required methods: {sorted(missing)!r}")
        finally:
            server.stop()

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1

    reduction = 60 / max(server.total_connections, 1)
    print(
        "PASS: hot-path tmux broker bounds app socket fan-out under parallel agent-team calls "
        f"(app_socket_connections={server.total_connections}, "
        f"max_concurrent={server.max_active_connections}, "
        f"fanout_reduction_vs_one_socket_per_call={reduction:.1f}x)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
