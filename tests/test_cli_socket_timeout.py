#!/usr/bin/env python3
"""Regression test: socket reads must honor the configured command timeout."""

from __future__ import annotations

import glob
import os
import shutil
import socket
import subprocess
import tempfile
import threading
import time


class NoResponseSocketServer:
    def __init__(self, path: str) -> None:
        self.path = path
        self.ready = threading.Event()
        self.stop_requested = threading.Event()
        self.payloads: list[str] = []
        self.error: Exception | None = None
        self.thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self.thread.start()
        if not self.ready.wait(timeout=2.0):
            raise RuntimeError("fake socket server did not start")
        if self.error is not None:
            raise RuntimeError(f"fake socket server failed: {self.error}")

    def stop(self) -> None:
        self.stop_requested.set()
        try:
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.settimeout(0.1)
            client.connect(self.path)
            client.close()
        except OSError:
            pass
        self.thread.join(timeout=1.0)
        try:
            os.remove(self.path)
        except OSError:
            pass

    def _run(self) -> None:
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            if os.path.exists(self.path):
                os.remove(self.path)
            server.bind(self.path)
            server.listen(4)
            server.settimeout(0.1)
            self.ready.set()

            while not self.stop_requested.is_set():
                try:
                    conn, _ = server.accept()
                except socket.timeout:
                    continue
                with conn:
                    conn.settimeout(0.1)
                    data = b""
                    while b"\n" not in data and not self.stop_requested.is_set():
                        try:
                            chunk = conn.recv(4096)
                        except socket.timeout:
                            continue
                        if not chunk:
                            break
                        data += chunk
                    if data:
                        self.payloads.append(data.decode("utf-8", errors="replace").strip())
                    self.stop_requested.wait(timeout=5.0)
        except Exception as exc:
            self.error = exc
            self.ready.set()
        finally:
            server.close()


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit and os.path.exists(explicit) and os.access(explicit, os.X_OK):
        return explicit

    candidates: list[str] = []
    candidates.extend(glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux")))
    candidates.extend(glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux"))
    candidates = [p for p in candidates if os.path.exists(p) and os.access(p, os.X_OK)]
    if candidates:
        candidates.sort(key=os.path.getmtime, reverse=True)
        return candidates[0]

    in_path = shutil.which("cmux")
    if in_path:
        return in_path

    raise RuntimeError("Unable to find cmux CLI binary. Set CMUX_CLI_BIN.")


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(prefix="cmux-cli-timeout-", dir="/tmp") as tmpdir:
        socket_path = os.path.join(tmpdir, "cmux.sock")
        server = NoResponseSocketServer(socket_path)
        server.start()
        try:
            env = os.environ.copy()
            env["HOME"] = tmpdir
            env["CMUX_CLI_SENTRY_DISABLED"] = "1"
            env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
            env["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "0.2"
            env.pop("CMUX_SOCKET", None)
            env.pop("CMUX_SOCKET_PATH", None)

            started = time.monotonic()
            proc = subprocess.run(  # noqa: S603
                [cli_path, "--socket", socket_path, "ping"],
                text=True,
                capture_output=True,
                env=env,
                timeout=5.0,
                check=False,
            )
            elapsed = time.monotonic() - started
        finally:
            server.stop()

    if proc.returncode == 0:
        print("FAIL: ping unexpectedly succeeded against a no-response socket")
        print(f"stdout={proc.stdout!r}")
        print(f"stderr={proc.stderr!r}")
        return 1

    merged = f"{proc.stdout}\n{proc.stderr}"
    if "Command timed out" not in merged:
        print("FAIL: timeout error did not mention command timeout")
        print(f"stdout={proc.stdout!r}")
        print(f"stderr={proc.stderr!r}")
        return 1

    if elapsed > 2.0:
        print(f"FAIL: command exceeded bounded timeout budget ({elapsed:.2f}s)")
        print(f"stdout={proc.stdout!r}")
        print(f"stderr={proc.stderr!r}")
        return 1

    if server.payloads != ["ping"]:
        print(f"FAIL: expected one ping payload, got {server.payloads!r}")
        return 1

    print(f"PASS: socket read timeout is bounded (elapsed={elapsed:.2f}s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
