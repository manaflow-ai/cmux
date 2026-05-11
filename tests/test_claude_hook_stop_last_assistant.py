#!/usr/bin/env python3
"""Regression: Claude Stop feed events should use the final assistant text."""

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


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit:
        if os.path.exists(explicit) and os.access(explicit, os.X_OK):
            return explicit
        raise RuntimeError(f"Configured cmux CLI is not executable: {explicit}")

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


class CapturingSocketServer:
    def __init__(self) -> None:
        self.commands: list[str] = []
        self.ready = threading.Event()
        self.stop = threading.Event()
        self.error: Exception | None = None
        self.root = tempfile.TemporaryDirectory(prefix="cmux-claude-stop-")
        self.socket_path = os.path.join(self.root.name, "cmux.sock")
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.server: socket.socket | None = None

    def __enter__(self) -> "CapturingSocketServer":
        self.thread.start()
        if not self.ready.wait(timeout=2.0):
            raise RuntimeError("socket server did not become ready")
        if self.error is not None:
            raise self.error
        return self

    def __exit__(self, _exc_type: object, _exc: object, _tb: object) -> None:
        self.stop.set()
        if self.server is not None:
            self.server.close()
        self.thread.join(timeout=2.0)
        self.root.cleanup()

    def _run(self) -> None:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                self.server = server
                server.bind(self.socket_path)
                server.listen(4)
                server.settimeout(0.1)
                self.ready.set()
                while not self.stop.is_set():
                    try:
                        conn, _ = server.accept()
                    except socket.timeout:
                        continue
                    except OSError:
                        return
                    threading.Thread(target=self._handle, args=(conn,), daemon=True).start()
        except Exception as exc:
            self.error = exc
            self.ready.set()

    def _handle(self, conn: socket.socket) -> None:
        with conn:
            conn.settimeout(0.1)
            buffer = b""
            idle_deadline = time.time() + 6.0
            while not self.stop.is_set() and time.time() < idle_deadline:
                try:
                    chunk = conn.recv(4096)
                except socket.timeout:
                    continue
                if not chunk:
                    break
                idle_deadline = time.time() + 2.0
                buffer += chunk
                while b"\n" in buffer:
                    raw_line, buffer = buffer.split(b"\n", 1)
                    if not raw_line:
                        continue
                    line = raw_line.decode("utf-8", errors="replace")
                    self.commands.append(line)
                    conn.sendall((self._response_for(line) + "\n").encode("utf-8"))

    def _response_for(self, line: str) -> str:
        if line.startswith("{"):
            try:
                request = json.loads(line)
                return json.dumps({"id": request.get("id"), "ok": True, "result": {}})
            except json.JSONDecodeError:
                pass
        return "OK"


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    payload = {
        "session_id": f"sess-{uuid.uuid4().hex}",
        "hook_event_name": "Stop",
        "cwd": "/Users/lawrence/fun",
        "last_assistant_message": "2",
    }

    with CapturingSocketServer() as server:
        env = os.environ.copy()
        env["CMUX_SOCKET_PATH"] = server.socket_path
        env["CMUX_WORKSPACE_ID"] = workspace_id
        env["CMUX_SURFACE_ID"] = surface_id
        env["CMUX_CLAUDE_HOOK_STATE_PATH"] = os.path.join(server.root.name, "state.json")
        env["CMUX_CLI_SENTRY_DISABLED"] = "1"
        env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        proc = subprocess.run(
            [cli_path, "--socket", server.socket_path, "claude-hook", "stop"],
            input=json.dumps(payload),
            text=True,
            capture_output=True,
            env=env,
            timeout=8,
            check=False,
        )

        if proc.returncode != 0:
            print("FAIL: claude-hook stop failed")
            print(f"stdout={proc.stdout!r}")
            print(f"stderr={proc.stderr!r}")
            print(f"commands={server.commands!r}")
            return 1

        feed_pushes: list[dict[str, object]] = []
        for line in server.commands:
            if not line.startswith("{"):
                continue
            try:
                request = json.loads(line)
            except json.JSONDecodeError:
                continue
            if request.get("method") == "feed.push":
                feed_pushes.append(request)

        stop_events = []
        for request in feed_pushes:
            params = request.get("params")
            if not isinstance(params, dict):
                continue
            event = params.get("event")
            if isinstance(event, dict) and event.get("hook_event_name") == "Stop":
                stop_events.append(event)

        if not stop_events:
            print("FAIL: expected Stop feed.push command")
            print(f"commands={server.commands!r}")
            return 1

        event = stop_events[-1]
        context = event.get("context")
        if not isinstance(context, dict):
            print("FAIL: expected Stop feed event context")
            print(f"event={event!r}")
            print(f"commands={server.commands!r}")
            return 1

        expected_workspace_id = workspace_id
        actual_workspace_id = event.get("workspace_id")
        actual_assistant_message = context.get("assistantPreamble")
        if actual_workspace_id != expected_workspace_id or actual_assistant_message != "2":
            print("FAIL: expected Stop feed event to use final assistant text")
            print(f"expected_workspace_id={expected_workspace_id!r}")
            print(f"actual_workspace_id={actual_workspace_id!r}")
            print("expected_assistantPreamble='2'")
            print(f"actual_assistantPreamble={actual_assistant_message!r}")
            print(f"commands={server.commands!r}")
            return 1

    print("PASS: Claude Stop feed event uses final assistant text")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
