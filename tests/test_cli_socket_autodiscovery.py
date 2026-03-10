#!/usr/bin/env python3
"""Regression test: CLI should auto-discover tagged debug sockets from CMUX_TAG."""

from __future__ import annotations

import glob
import os
import shutil
import socket
import subprocess
import threading


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


class PingServer:
    def __init__(self, socket_path: str):
        self.socket_path = socket_path
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

            # The CLI may probe candidate sockets with a connect-only check before
            # issuing the actual command, so handle more than one connection.
            for _ in range(4):
                conn, _ = server.accept()
                with conn:
                    conn.settimeout(2.0)
                    data = b""
                    while b"\n" not in data:
                        chunk = conn.recv(4096)
                        if not chunk:
                            break
                        data += chunk

                    if b"ping" in data:
                        conn.sendall(b"PONG\n")
                        return
            raise RuntimeError("Did not receive ping command on test socket")
        except Exception as exc:  # pragma: no cover - explicit surface on failure
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

    tag = f"cli-autodiscover-{os.getpid()}"
    socket_path = f"/tmp/cmux-debug-{tag}.sock"
    server = PingServer(socket_path)
    server.start()

    if not server.wait_ready(2.0):
        print("FAIL: socket server did not become ready")
        return 1

    if server.error is not None:
        print(f"FAIL: socket server failed to start: {server.error}")
        return 1

    env = os.environ.copy()
    env["CMUX_SOCKET_PATH"] = "/tmp/cmux.sock"
    env["CMUX_TAG"] = tag
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

    try:
        proc = subprocess.run(
            [cli_path, "ping"],
            text=True,
            capture_output=True,
            env=env,
            timeout=8,
            check=False,
        )
    except Exception as exc:
        print(f"FAIL: invoking cmux ping failed: {exc}")
        return 1
    finally:
        server.join(timeout=2.0)
        try:
            os.remove(socket_path)
        except OSError:
            pass

    if server.error is not None:
        print(f"FAIL: socket server error: {server.error}")
        return 1

    if proc.returncode != 0:
        print("FAIL: cmux ping returned non-zero status")
        print(f"stdout={proc.stdout!r}")
        print(f"stderr={proc.stderr!r}")
        return 1

    if proc.stdout.strip() != "PONG":
        print("FAIL: cmux ping did not use auto-discovered socket")
        print(f"stdout={proc.stdout!r}")
        print(f"stderr={proc.stderr!r}")
        return 1

    print("PASS: cmux ping auto-discovers tagged socket from CMUX_TAG")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
