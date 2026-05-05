#!/usr/bin/env python3
"""Regression reproduction: early socket close currently leaks Broken pipe."""

from __future__ import annotations

import os
import socket
import subprocess
import tempfile
import threading


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit and os.path.exists(explicit) and os.access(explicit, os.X_OK):
        return explicit

    raise RuntimeError(
        "Unable to find cmux CLI binary. Set CMUX_CLI_BIN. "
        "Socket tests must use an explicit, tagged binary."
    )


class EarlyCloseServer:
    def __init__(self, socket_path: str, response: str):
        self.socket_path = socket_path
        self.response = response
        self.ready = threading.Event()
        self.error: Exception | None = None
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self._thread.start()

    def wait_ready(self, timeout: float) -> bool:
        return self.ready.wait(timeout)

    def join(self, timeout: float) -> None:
        self._thread.join(timeout=timeout)

    def _run(self) -> None:
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            if os.path.exists(self.socket_path):
                os.remove(self.socket_path)
            server.bind(self.socket_path)
            server.listen(1)
            server.settimeout(6.0)
            self.ready.set()

            conn, _ = server.accept()
            with conn:
                conn.sendall((self.response + "\n").encode("utf-8"))
        except Exception as exc:  # pragma: no cover - explicit failure surfacing
            self.error = exc
            self.ready.set()
        finally:
            server.close()


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(prefix="cmux-cli-broken-pipe-") as root:
        socket_path = os.path.join(root, "early-close.sock")
        server = EarlyCloseServer(
            socket_path,
            "ERROR: Access denied -- early-close reproduction",
        )
        server.start()

        if not server.wait_ready(2.0):
            print("FAIL: early-close server did not become ready")
            return 1
        if server.error is not None:
            print(f"FAIL: early-close server failed to start: {server.error}")
            return 1

        env = os.environ.copy()
        env["CMUX_CLI_SENTRY_DISABLED"] = "1"
        env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        proc = subprocess.run(
            [cli_path, "--socket", socket_path, "ping"],
            text=True,
            capture_output=True,
            env=env,
            timeout=8,
            check=False,
        )

        server.join(timeout=6.5)
        if server.error is not None:
            print(f"FAIL: early-close server error: {server.error}")
            return 1

        if proc.returncode == 0:
            print("FAIL: expected cmux ping to fail when peer closes early")
            print(f"stdout={proc.stdout!r}")
            print(f"stderr={proc.stderr!r}")
            return 1

        expected = "Error: ERROR: Access denied -- early-close reproduction"
        if expected not in proc.stderr:
            print("FAIL: expected cmux to preserve the server error instead of leaking Broken pipe")
            print(f"expected substring: {expected!r}")
            print(f"stderr={proc.stderr!r}")
            return 1
        if "Broken pipe" in proc.stderr:
            print("FAIL: cmux still leaked Broken pipe for an early-close socket failure")
            print(f"stderr={proc.stderr!r}")
            return 1

    print("PASS: cmux preserves early-close socket errors")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
