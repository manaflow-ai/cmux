#!/usr/bin/env python3
"""Regression: Claude PushNotification tool calls must reach cmux notifications.

Claude Code's PushNotification tool delivers via a raw OSC desktop
notification. cmux suppresses raw OSC notifications for surfaces running a
hook-integrated agent, and the tool never fires the Notification hook, so the
PostToolUse `hooks claude push-notification` bridge is the only path into the
cmux notification store. The bridge mirrors the tool's own delivery decision
(tool_response.localSent) and fails open when the structured response is
missing.
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


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit:
        if os.path.exists(explicit) and os.access(explicit, os.X_OK):
            return explicit
        raise RuntimeError(f"Configured cmux CLI is not executable: {explicit}")

    # No /tmp globbing: /tmp is world-writable, so auto-discovering and
    # executing binaries from it is unsafe. CI always passes CMUX_CLI_BIN.
    candidates: list[str] = []
    candidates.extend(glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux")))
    candidates = [path for path in candidates if os.path.exists(path) and os.access(path, os.X_OK)]
    if candidates:
        candidates.sort(key=os.path.getmtime, reverse=True)
        return candidates[0]

    in_path = shutil.which("cmux")
    if in_path:
        return in_path

    raise RuntimeError("Unable to find cmux CLI binary. Set CMUX_CLI_BIN.")


class CapturingSocketServer:
    def __init__(self, workspace_id: str, surface_id: str) -> None:
        self.commands: list[str] = []
        self.workspace_id = workspace_id
        self.surface_id = surface_id
        self.ready = threading.Event()
        self.stop = threading.Event()
        self.error: Exception | None = None
        self.root = tempfile.TemporaryDirectory(prefix="cmux-claude-push-")
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
                    response = self._response_for(line)
                    if response is None:
                        continue
                    try:
                        conn.sendall((response + "\n").encode("utf-8"))
                    except OSError:
                        return

    def _response_for(self, line: str) -> str | None:
        if line.startswith("{"):
            try:
                request = json.loads(line)
                if "id" not in request:
                    return None
                if request.get("method") == "surface.list":
                    return json.dumps(
                        {
                            "id": request.get("id"),
                            "ok": True,
                            "result": {
                                "surfaces": [
                                    {
                                        "id": self.surface_id,
                                        "ref": self.surface_id,
                                        "workspace_id": self.workspace_id,
                                    }
                                ]
                            },
                        }
                    )
                return json.dumps({"id": request.get("id"), "ok": True, "result": {}})
            except json.JSONDecodeError:
                pass
        return "OK"


def run_push_notification_hook(
    cli_path: str,
    payload: dict,
) -> tuple[subprocess.CompletedProcess, list[str], str, str]:
    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    with CapturingSocketServer(workspace_id=workspace_id, surface_id=surface_id) as server:
        env = os.environ.copy()
        env["CMUX_SOCKET_PATH"] = server.socket_path
        env["CMUX_WORKSPACE_ID"] = workspace_id
        env["CMUX_SURFACE_ID"] = surface_id
        env["CMUX_CLAUDE_HOOK_STATE_PATH"] = os.path.join(server.root.name, "state.json")
        env["CMUX_CLI_SENTRY_DISABLED"] = "1"
        env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        proc = subprocess.run(
            [cli_path, "--socket", server.socket_path, "hooks", "claude", "push-notification"],
            input=json.dumps(payload),
            text=True,
            capture_output=True,
            env=env,
            timeout=8,
            check=False,
        )
        commands = list(server.commands)
    return proc, commands, workspace_id, surface_id


def push_payload(message: str, tool_response: object) -> dict:
    payload = {
        "session_id": f"sess-{uuid.uuid4().hex}",
        "hook_event_name": "PostToolUse",
        "cwd": "/tmp/cmux-test-workspace",
        "tool_name": "PushNotification",
        "tool_input": {"message": message, "status": "proactive"},
    }
    if tool_response is not None:
        payload["tool_response"] = tool_response
    return payload


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    # 1. localSent true -> bridged into a cmux notification, no lifecycle flip.
    message = "build failed: 2 auth tests"
    proc, commands, workspace_id, surface_id = run_push_notification_hook(
        cli_path,
        push_payload(
            message,
            {"message": message, "localSent": True, "sentAt": "2026-07-04T00:00:00Z"},
        ),
    )
    if proc.returncode != 0:
        print("FAIL: push-notification (sent) hook exited nonzero")
        print(f"stdout={proc.stdout!r} stderr={proc.stderr!r} commands={commands!r}")
        return 1
    notify_commands = [line for line in commands if line.startswith("notify_target_async ")]
    expected = f"notify_target_async {workspace_id} {surface_id} Claude Code||{message}"
    if notify_commands != [expected]:
        print("FAIL: expected exactly one bridged notification for localSent=true")
        print(f"expected={expected!r}")
        print(f"notify_commands={notify_commands!r} commands={commands!r}")
        return 1
    lifecycle_commands = [line for line in commands if line.startswith("set_agent_lifecycle")]
    if lifecycle_commands:
        print("FAIL: push-notification must not change agent lifecycle")
        print(f"commands={commands!r}")
        return 1

    # 2. Tool skipped delivery (user present) -> no cmux notification.
    proc, commands, _, _ = run_push_notification_hook(
        cli_path,
        push_payload(
            "should not surface",
            {"message": "should not surface", "localSent": False, "disabledReason": "user_present"},
        ),
    )
    if proc.returncode != 0:
        print("FAIL: push-notification (skipped) hook exited nonzero")
        print(f"stdout={proc.stdout!r} stderr={proc.stderr!r} commands={commands!r}")
        return 1
    if any(line.startswith("notify_target_async ") for line in commands):
        print("FAIL: skipped PushNotification must not create a cmux notification")
        print(f"commands={commands!r}")
        return 1

    # 3. No structured tool_response (older client) -> fail open and bridge.
    proc, commands, workspace_id, surface_id = run_push_notification_hook(
        cli_path,
        push_payload("fallback delivery", None),
    )
    if proc.returncode != 0:
        print("FAIL: push-notification (fail-open) hook exited nonzero")
        print(f"stdout={proc.stdout!r} stderr={proc.stderr!r} commands={commands!r}")
        return 1
    expected = f"notify_target_async {workspace_id} {surface_id} Claude Code||fallback delivery"
    if [line for line in commands if line.startswith("notify_target_async ")] != [expected]:
        print("FAIL: missing tool_response should fail open and bridge the message")
        print(f"expected={expected!r} commands={commands!r}")
        return 1

    # 4. Explicit JSON-null disabledReason with localSent absent -> fail open.
    #    JSONSerialization maps JSON null to NSNull, which is not Swift nil; a
    #    naive `response["disabledReason"] == nil` check would suppress here.
    proc, commands, workspace_id, surface_id = run_push_notification_hook(
        cli_path,
        push_payload(
            "null reason delivery",
            {"message": "null reason delivery", "disabledReason": None},
        ),
    )
    if proc.returncode != 0:
        print("FAIL: push-notification (null disabledReason) hook exited nonzero")
        print(f"stdout={proc.stdout!r} stderr={proc.stderr!r} commands={commands!r}")
        return 1
    expected = f"notify_target_async {workspace_id} {surface_id} Claude Code||null reason delivery"
    if [line for line in commands if line.startswith("notify_target_async ")] != [expected]:
        print("FAIL: JSON-null disabledReason should fail open and bridge the message")
        print(f"expected={expected!r} commands={commands!r}")
        return 1

    # 5. localSent=false with NO disabledReason (e.g. mobile-only delivery, or
    #    a client whose local terminal channel is suppressed) -> bridge. The
    #    cmux notification is the only Mac-visible surface in that state, so
    #    the gate must not key on localSent; only explicit user-facing skip
    #    reasons (user_present, config_off) suppress the bridge.
    proc, commands, workspace_id, surface_id = run_push_notification_hook(
        cli_path,
        push_payload(
            "local channel unavailable",
            {"message": "local channel unavailable", "localSent": False},
        ),
    )
    if proc.returncode != 0:
        print("FAIL: push-notification (localSent=false, no reason) hook exited nonzero")
        print(f"stdout={proc.stdout!r} stderr={proc.stderr!r} commands={commands!r}")
        return 1
    expected = f"notify_target_async {workspace_id} {surface_id} Claude Code||local channel unavailable"
    if [line for line in commands if line.startswith("notify_target_async ")] != [expected]:
        print("FAIL: localSent=false without a skip reason should still bridge")
        print(f"expected={expected!r} commands={commands!r}")
        return 1

    # 6. config_off is a deliberate user setting -> no cmux notification.
    proc, commands, _, _ = run_push_notification_hook(
        cli_path,
        push_payload(
            "config off must not surface",
            {"message": "config off must not surface", "localSent": False, "disabledReason": "config_off"},
        ),
    )
    if proc.returncode != 0:
        print("FAIL: push-notification (config_off) hook exited nonzero")
        print(f"stdout={proc.stdout!r} stderr={proc.stderr!r} commands={commands!r}")
        return 1
    if any(line.startswith("notify_target_async ") for line in commands):
        print("FAIL: config_off PushNotification must not create a cmux notification")
        print(f"commands={commands!r}")
        return 1

    print("PASS: PushNotification tool calls bridge into cmux notifications")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
