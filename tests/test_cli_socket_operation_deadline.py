#!/usr/bin/env python3
"""Regression tests for CLI Unix socket waits against fake servers."""

from __future__ import annotations

import glob
import os
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import uuid
from collections.abc import Callable
from dataclasses import dataclass


@dataclass(frozen=True)
class RunResult:
    returncode: int
    stdout: str
    stderr: str
    elapsed: float


def output_text(value: str | bytes | None) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode(errors="replace")
    return value


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit and os.path.exists(explicit) and os.access(explicit, os.X_OK):
        return explicit

    candidates: list[str] = []
    candidates.extend(glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux")))
    candidates.extend(glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux"))
    candidates = [path for path in candidates if os.path.exists(path) and os.access(path, os.X_OK)]
    if candidates:
        candidates.sort(key=os.path.getmtime, reverse=True)
        return candidates[0]

    in_path = shutil.which("cmux")
    if in_path:
        return in_path

    raise RuntimeError("Unable to find cmux CLI binary. Set CMUX_CLI_BIN.")


class FakeUnixServer:
    def __init__(self, handler: Callable[[socket.socket, threading.Event], None]) -> None:
        self.handler = handler
        self.stop_event = threading.Event()
        self.ready_event = threading.Event()
        self.root = tempfile.TemporaryDirectory(prefix="cmuxsock-", dir="/tmp")
        self.path = os.path.join(self.root.name, f"s-{uuid.uuid4().hex[:8]}.sock")
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.server: socket.socket | None = None

    def __enter__(self) -> "FakeUnixServer":
        self.thread.start()
        if not self.ready_event.wait(timeout=2.0):
            raise RuntimeError("fake Unix server did not become ready")
        return self

    def __exit__(self, _exc_type: object, _exc: object, _tb: object) -> None:
        self.stop_event.set()
        if self.server is not None:
            self.server.close()
        self.thread.join(timeout=2.0)
        self.root.cleanup()

    def _serve(self) -> None:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
            self.server = server
            server.bind(self.path)
            server.listen(8)
            server.settimeout(0.1)
            self.ready_event.set()
            while not self.stop_event.is_set():
                try:
                    conn, _ = server.accept()
                except socket.timeout:
                    continue
                except OSError:
                    return
                threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn: socket.socket) -> None:
        with conn:
            self.handler(conn, self.stop_event)


def read_one_command(conn: socket.socket, stop_event: threading.Event) -> bytes:
    conn.settimeout(0.1)
    chunks: list[bytes] = []
    while not stop_event.is_set():
        try:
            chunk = conn.recv(4096)
        except socket.timeout:
            continue
        if not chunk:
            break
        chunks.append(chunk)
        if b"\n" in chunk:
            break
    return b"".join(chunks)


def no_reply_handler(conn: socket.socket, stop_event: threading.Event) -> None:
    read_one_command(conn, stop_event)
    stop_event.wait(timeout=1.0)


def pong_handler(conn: socket.socket, stop_event: threading.Event) -> None:
    command = read_one_command(conn, stop_event)
    if command.startswith(b"ping\n"):
        conn.sendall(b"PONG\n")
        stop_event.wait(timeout=1.0)


def close_after_accept_handler(conn: socket.socket, _stop_event: threading.Event) -> None:
    conn.close()


def close_after_command_handler(conn: socket.socket, stop_event: threading.Event) -> None:
    read_one_command(conn, stop_event)
    conn.close()


def run_cli(cli_path: str, socket_path: str, timeout: float = 3.0, args: tuple[str, ...] = ("ping",)) -> RunResult:
    env = dict(os.environ)
    env["CMUX_SOCKET_PATH"] = socket_path
    env["CMUX_SOCKET"] = socket_path
    env["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "0.2"
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
    started = time.monotonic()
    try:
        proc = subprocess.run(
            [cli_path, "--socket", socket_path, *args],
            text=True,
            capture_output=True,
            check=False,
            timeout=timeout,
            env=env,
        )
    except subprocess.TimeoutExpired as exc:
        stderr = output_text(exc.stderr)
        stderr = f"{stderr}\nHarness timeout expired after {timeout:.1f}s".lstrip()
        return RunResult(
            returncode=124,
            stdout=output_text(exc.stdout),
            stderr=stderr,
            elapsed=time.monotonic() - started,
        )
    return RunResult(
        returncode=proc.returncode,
        stdout=proc.stdout,
        stderr=proc.stderr,
        elapsed=time.monotonic() - started,
    )


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    failures: list[str] = []

    try:
        with FakeUnixServer(pong_handler) as server:
            result = run_cli(cli_path, server.path)
            if result.returncode != 0 or result.stdout != "PONG\n":
                failures.append(
                    f"ping fixture failed: rc={result.returncode} stdout={result.stdout!r} stderr={result.stderr!r}"
                )

        with FakeUnixServer(no_reply_handler) as server:
            result = run_cli(cli_path, server.path)
            merged = f"{result.stdout}\n{result.stderr}"
            if result.returncode == 0:
                failures.append("no-reply socket unexpectedly succeeded")
            if "Command timed out" not in merged:
                failures.append(f"no-reply socket did not surface timeout: {merged!r}")
            if result.elapsed > 1.5:
                failures.append(f"no-reply socket took too long: {result.elapsed:.3f}s")

        with FakeUnixServer(close_after_command_handler) as server:
            result = run_cli(cli_path, server.path, args=("capabilities",))
            merged = f"{result.stdout}\n{result.stderr}"
            if result.returncode == 0:
                failures.append("EOF-before-v2-reply socket unexpectedly succeeded")
            if "Socket closed before reply" not in merged:
                failures.append(f"EOF-before-v2-reply socket did not surface socket closure: {merged!r}")

        expected_closed_peer_errors = (
            "Failed to write to socket",
            "Socket read error",
            "Socket closed before reply",
            "Socket closed before complete reply",
            "Command timed out",
            "Failed to connect",
        )
        with FakeUnixServer(close_after_accept_handler) as server:
            for index in range(20):
                result = run_cli(cli_path, server.path)
                merged = f"{result.stdout}\n{result.stderr}"
                if result.returncode < 0:
                    failures.append(f"closed peer run {index} terminated by signal: rc={result.returncode}")
                    break
                if result.returncode == 0:
                    failures.append(f"closed peer run {index} unexpectedly succeeded: stdout={result.stdout!r}")
                    break
                if not any(token in merged for token in expected_closed_peer_errors):
                    failures.append(
                        f"closed peer run {index} returned an unexpected error: "
                        f"rc={result.returncode} stdout={result.stdout!r} stderr={result.stderr!r}"
                    )
                    break
    except Exception as exc:
        failures.append(f"test harness raised {type(exc).__name__}: {exc}")

    if failures:
        print("FAIL: CLI socket operation deadline regressions failed")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: CLI socket operations are bounded and survive closed peers")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
