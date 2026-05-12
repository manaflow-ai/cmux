#!/usr/bin/env python3
"""
Regression harness for hot-path CLI pooling.

The many-agent crash reports point at helper-process/socket fan-out under bursty
cmux CLI traffic. This test drives 100 parallel hot-path RPC calls through a
fake app socket and asserts the app side sees bounded concurrency.
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


def write_github_step_summary(title: str, rows: list[tuple[str, str]]) -> None:
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary_path:
        return
    with open(summary_path, "a", encoding="utf-8") as summary:
        summary.write(f"\n### {title}\n\n")
        summary.write("| Metric | Value |\n")
        summary.write("| --- | ---: |\n")
        for label, value in rows:
            summary.write(f"| {label} | {value} |\n")


def run_hot_path_rpc(
    cli_path: str,
    app_socket: str,
    broker_socket: str,
    params: str,
    env: dict[str, str],
    timeout: float = 5.0,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            cli_path,
            "--socket",
            app_socket,
            "__hot-path",
            "--broker-socket",
            broker_socket,
            "rpc",
            "surface.telemetry",
            params,
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
        timeout=timeout,
        check=False,
    )


class FakeJSONRPCSocketServer:
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
                    with self._lock:
                        self.methods.append(str(request.get("method", "")))
                    if self.response_delay > 0:
                        time.sleep(self.response_delay)
                    response = {"id": request.get("id"), "ok": True, "result": {"queued": True}}
                    conn.sendall((json.dumps(response) + "\n").encode("utf-8"))
        finally:
            try:
                conn.close()
            except OSError:
                pass
            with self._lock:
                self.active_connections = max(0, self.active_connections - 1)

    def method_count(self) -> int:
        with self._lock:
            return len(self.methods)

    def methods_snapshot(self) -> list[str]:
        with self._lock:
            return list(self.methods)

    def wait_for_method_count(self, expected: int, timeout: float) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.method_count() >= expected:
                return True
            time.sleep(0.02)
        return self.method_count() >= expected


def main() -> int:
    failures: list[str] = []
    cli_path = resolve_cmux_cli()

    with tempfile.TemporaryDirectory(prefix="cmux-hot-path-pool-") as td:
        root = Path(td)
        app_socket = str(root / "cmux.sock")
        broker_socket = str(root / "hot-path-broker.sock")
        server = FakeJSONRPCSocketServer(socket_path=app_socket, response_delay=0.02)
        server.start()
        burst_total_connections = 0
        burst_max_active_connections = 0
        try:
            params = json.dumps(
                {
                    "workspace_id": "11111111-1111-1111-1111-111111111111",
                    "surface_id": "22222222-2222-2222-2222-222222222222",
                    "tty_name": "ttys777",
                    "reason": "command",
                }
            )

            procs: list[subprocess.Popen[str]] = []
            env = {
                **os.environ,
                "CMUX_HOT_PATH_BROKER_IDLE_TIMEOUT_SECONDS": "1",
            }
            for _ in range(100):
                procs.append(
                    subprocess.Popen(
                        [
                            cli_path,
                            "--socket",
                            app_socket,
                            "__hot-path",
                            "--broker-socket",
                            broker_socket,
                            "rpc",
                            "surface.telemetry",
                            params,
                        ],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.PIPE,
                        text=True,
                        env=env,
                    )
                )

            for index, proc in enumerate(procs):
                try:
                    _, stderr = proc.communicate(timeout=15.0)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    _, stderr = proc.communicate()
                    failures.append(f"request {index} timed out: stderr={stderr!r}")
                    continue
                if proc.returncode != 0:
                    failures.append(f"request {index} exited {proc.returncode}: stderr={stderr!r}")

            if server.max_active_connections > 4:
                failures.append(
                    "expected <=4 concurrent app socket connections during pooled burst, "
                    f"saw {server.max_active_connections}"
                )
            if server.total_connections > 4:
                failures.append(
                    "expected <=4 total app socket connections during pooled burst, "
                    f"saw {server.total_connections}"
                )

            if not server.wait_for_method_count(100, timeout=30.0):
                failures.append(f"expected 100 telemetry methods, got {server.method_count()}")
            else:
                methods = server.methods_snapshot()
                if set(methods) != {"surface.telemetry"}:
                    failures.append(f"expected only surface.telemetry, got {methods!r}")
            burst_total_connections = server.total_connections
            burst_max_active_connections = server.max_active_connections

            stall_env = {
                **env,
                "CMUX_HOT_PATH_BROKER_CLIENT_READ_TIMEOUT_SECONDS": "0.2",
                "CMUX_HOT_PATH_BROKER_IDLE_TIMEOUT_SECONDS": "3",
            }
            stall_broker_socket = str(root / "hot-path-broker-stall.sock")
            warmup = run_hot_path_rpc(cli_path, app_socket, stall_broker_socket, params, stall_env)
            if warmup.returncode != 0:
                failures.append(f"warmup hot-path request failed: stderr={warmup.stderr!r}")
            else:
                stalled_client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                try:
                    stalled_client.connect(stall_broker_socket)
                    stalled_client.sendall(b'{"mode":"rpc"')
                    time.sleep(0.4)
                    after_stall = run_hot_path_rpc(cli_path, app_socket, stall_broker_socket, params, stall_env)
                    if after_stall.returncode != 0:
                        failures.append(
                            "valid hot-path request failed after stalled broker client: "
                            f"stderr={after_stall.stderr!r}"
                        )
                finally:
                    stalled_client.close()
        finally:
            server.stop()

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1

    reduction = 100 / max(burst_total_connections, 1)
    write_github_step_summary(
        "Hot-path telemetry fan-out",
        [
            ("Parallel calls", "100"),
            ("App socket connections", str(burst_total_connections)),
            ("Max concurrent app socket connections", str(burst_max_active_connections)),
            ("Fan-out reduction vs one socket per call", f"{reduction:.1f}x"),
        ],
    )
    print(
        "PASS: hot-path broker bounds app socket fan-out under 100 parallel calls "
        f"(app_socket_connections={burst_total_connections}, "
        f"max_concurrent={burst_max_active_connections}, "
        f"fanout_reduction_vs_one_socket_per_call={reduction:.1f}x)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
