#!/usr/bin/env python3
"""
Regression test: claude-hook stop should not fail when workspace teardown makes
TabManager unavailable before the final status update runs.
"""

from __future__ import annotations

import glob
import json
import os
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import uuid
from pathlib import Path


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


class TeardownUnavailableServer:
    def __init__(self, socket_path: str):
        self.socket_path = socket_path
        self.commands: list[str] = []
        self.ready = threading.Event()
        self.error: Exception | None = None
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self._thread.start()

    def wait_ready(self, timeout: float) -> bool:
        return self.ready.wait(timeout)

    def join(self, timeout: float) -> None:
        self._thread.join(timeout=timeout)

    def _response_for(self, line: str) -> str:
        stripped = line.strip()
        if stripped.startswith("{"):
            request = json.loads(stripped)
            return json.dumps(
                {
                    "id": request.get("id"),
                    "ok": False,
                    "error": {
                        "code": "unavailable",
                        "message": "TabManager not available",
                    },
                }
            )
        return "ERROR: TabManager not available"

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
                conn.settimeout(0.5)
                buffer = b""
                idle_deadline = time.time() + 6.0
                while time.time() < idle_deadline:
                    try:
                        chunk = conn.recv(4096)
                    except socket.timeout:
                        continue

                    if not chunk:
                        break
                    buffer += chunk

                    while b"\n" in buffer:
                        raw_line, buffer = buffer.split(b"\n", 1)
                        line = raw_line.decode("utf-8")
                        if not line:
                            continue
                        self.commands.append(line)
                        response = self._response_for(line)
                        conn.sendall((response + "\n").encode("utf-8"))

                if not self.commands:
                    raise RuntimeError("cmux CLI never sent a command to the teardown test socket")
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

    temp_dir = tempfile.TemporaryDirectory(prefix="cmux-claude-hook-stop-")
    try:
        root = Path(temp_dir.name)
        socket_path = str(root / "cmux.sock")
        state_path = root / "claude-hook-state.json"
        server = TeardownUnavailableServer(socket_path)
        server.start()

        if not server.wait_ready(2.0):
            print("FAIL: teardown socket server did not become ready")
            return 1
        if server.error is not None:
            print(f"FAIL: teardown socket server failed to start: {server.error}")
            return 1

        env = os.environ.copy()
        env["CMUX_SOCKET_PATH"] = socket_path
        env["CMUX_WORKSPACE_ID"] = str(uuid.uuid4())
        env["CMUX_SURFACE_ID"] = str(uuid.uuid4())
        env["CMUX_CLAUDE_HOOK_STATE_PATH"] = str(state_path)
        env["CMUX_CLI_SENTRY_DISABLED"] = "1"
        env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        proc = subprocess.run(
            [cli_path, "--socket", socket_path, "claude-hook", "stop"],
            input=json.dumps({"session_id": f"sess-{uuid.uuid4().hex}"}),
            text=True,
            capture_output=True,
            env=env,
            timeout=8,
            check=False,
        )

        server.join(timeout=2.0)
        if server.error is not None:
            print(f"FAIL: teardown socket server error: {server.error}")
            return 1

        if proc.returncode != 0:
            print("FAIL: expected claude-hook stop to ignore teardown-time unavailable errors")
            print(f"stdout={proc.stdout!r}")
            print(f"stderr={proc.stderr!r}")
            print(f"commands={server.commands!r}")
            return 1

        if proc.stdout.strip() != "OK":
            print("FAIL: expected claude-hook stop to print OK")
            print(f"stdout={proc.stdout!r}")
            print(f"stderr={proc.stderr!r}")
            print(f"commands={server.commands!r}")
            return 1

        if not server.commands:
            print("FAIL: expected the CLI to send at least one command to the teardown socket")
            return 1

        print("PASS: claude-hook stop ignores teardown-time TabManager unavailable responses")
        return 0
    finally:
        temp_dir.cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
