#!/usr/bin/env python3
"""Regression: Claude ignored notification types should not render notifications."""

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
        self.root = tempfile.TemporaryDirectory(prefix="cmux-claude-ignored-notifications-")
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


def run_notification_hook(
    cli_path: str,
    server: CapturingSocketServer,
    env: dict[str, str],
    payload: object,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [cli_path, "--socket", server.socket_path, "claude-hook", "notification"],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        env=env,
        timeout=8,
        check=False,
    )


def configure_isolated_home(server: CapturingSocketServer, env: dict[str, str]) -> str:
    home = os.path.join(server.root.name, "home")
    os.makedirs(home, exist_ok=True)
    env["HOME"] = home
    env["CFFIXED_USER_HOME"] = home
    return home


def write_cmux_config(home: str, notifications: dict[str, object]) -> None:
    config_dir = os.path.join(home, ".config", "cmux")
    os.makedirs(config_dir, exist_ok=True)
    with open(os.path.join(config_dir, "cmux.json"), "w", encoding="utf-8") as handle:
        json.dump({"notifications": notifications}, handle)


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()

    with CapturingSocketServer() as server:
        env = os.environ.copy()
        env["CMUX_SOCKET_PATH"] = server.socket_path
        env["CMUX_WORKSPACE_ID"] = workspace_id
        env["CMUX_SURFACE_ID"] = surface_id
        env["CMUX_CLAUDE_HOOK_STATE_PATH"] = os.path.join(server.root.name, "state.json")
        env["CMUX_CLAUDE_IGNORED_NOTIFICATION_TYPES"] = "idle_prompt"
        env["CMUX_CLI_SENTRY_DISABLED"] = "1"
        env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        home = configure_isolated_home(server, env)

        idle = run_notification_hook(
            cli_path,
            server,
            env,
            {
                "session_id": f"sess-{uuid.uuid4().hex}",
                "hook_event_name": "Notification",
                "notification_type": "idle_prompt",
                "message": "Claude is waiting for your input",
            },
        )
        if idle.returncode != 0 or idle.stdout.strip() != "OK":
            print("FAIL: ignored idle prompt hook did not complete cleanly")
            print(f"stdout={idle.stdout!r}")
            print(f"stderr={idle.stderr!r}")
            print(f"commands={server.commands!r}")
            return 1

        rendered_commands = [
            line for line in server.commands
            if line.startswith("notify_target_async ") or line.startswith("set_status claude_code Needs input ")
        ]
        if rendered_commands:
            print("FAIL: idle_prompt rendered despite ignored notification type")
            print(f"commands={server.commands!r}")
            return 1

        nested_idle = run_notification_hook(
            cli_path,
            server,
            env,
            {
                "session_id": f"sess-{uuid.uuid4().hex}",
                "hook_event_name": "Notification",
                "notification": {
                    "notification_type": "idle_prompt",
                    "message": "Claude is still waiting for your input",
                },
            },
        )
        if nested_idle.returncode != 0 or nested_idle.stdout.strip() != "OK":
            print("FAIL: nested ignored idle prompt hook did not complete cleanly")
            print(f"stdout={nested_idle.stdout!r}")
            print(f"stderr={nested_idle.stderr!r}")
            print(f"commands={server.commands!r}")
            return 1

        nested_rendered_commands = [
            line for line in server.commands
            if line.startswith("notify_target_async ") or line.startswith("set_status claude_code Needs input ")
        ]
        if nested_rendered_commands:
            print("FAIL: nested idle_prompt rendered despite ignored notification type")
            print(f"commands={server.commands!r}")
            return 1

        nested_type_idle = run_notification_hook(
            cli_path,
            server,
            env,
            {
                "session_id": f"sess-{uuid.uuid4().hex}",
                "hook_event_name": "Notification",
                "notification": {
                    "type": "idle_prompt",
                    "message": "Claude is waiting from a nested type field",
                },
            },
        )
        if nested_type_idle.returncode != 0 or nested_type_idle.stdout.strip() != "OK":
            print("FAIL: nested type-field ignored idle prompt hook did not complete cleanly")
            print(f"stdout={nested_type_idle.stdout!r}")
            print(f"stderr={nested_type_idle.stderr!r}")
            print(f"commands={server.commands!r}")
            return 1

        nested_type_rendered_commands = [
            line for line in server.commands
            if line.startswith("notify_target_async ") or line.startswith("set_status claude_code Needs input ")
        ]
        if nested_type_rendered_commands:
            print("FAIL: nested type-field idle_prompt rendered despite ignored notification type")
            print(f"commands={server.commands!r}")
            return 1

        json_string_idle = run_notification_hook(
            cli_path,
            server,
            env,
            json.dumps(
                {
                    "session_id": f"sess-{uuid.uuid4().hex}",
                    "hook_event_name": "Notification",
                    "notification_type": "idle_prompt",
                    "message": "Claude is waiting from a raw JSON string payload",
                }
            ),
        )
        if json_string_idle.returncode != 0 or json_string_idle.stdout.strip() != "OK":
            print("FAIL: JSON-string ignored idle prompt hook did not complete cleanly")
            print(f"stdout={json_string_idle.stdout!r}")
            print(f"stderr={json_string_idle.stderr!r}")
            print(f"commands={server.commands!r}")
            return 1

        json_string_rendered_commands = [
            line for line in server.commands
            if line.startswith("notify_target_async ") or line.startswith("set_status claude_code Needs input ")
        ]
        if json_string_rendered_commands:
            print("FAIL: JSON-string idle_prompt rendered despite ignored notification type")
            print(f"commands={server.commands!r}")
            return 1

        raw_fallback_idle = run_notification_hook(
            cli_path,
            server,
            env,
            [
                {
                    "session_id": f"sess-{uuid.uuid4().hex}",
                    "hook_event_name": "Notification",
                    "notification_type": "idle_prompt",
                    "message": "Claude is waiting from a fallback JSON array payload",
                }
            ],
        )
        if raw_fallback_idle.returncode != 0 or raw_fallback_idle.stdout.strip() != "OK":
            print("FAIL: fallback JSON ignored idle prompt hook did not complete cleanly")
            print(f"stdout={raw_fallback_idle.stdout!r}")
            print(f"stderr={raw_fallback_idle.stderr!r}")
            print(f"commands={server.commands!r}")
            return 1

        raw_fallback_rendered_commands = [
            line for line in server.commands
            if line.startswith("notify_target_async ") or line.startswith("set_status claude_code Needs input ")
        ]
        if raw_fallback_rendered_commands:
            print("FAIL: fallback JSON idle_prompt rendered despite ignored notification type")
            print(f"commands={server.commands!r}")
            return 1

        before_permission_count = len(server.commands)
        permission = run_notification_hook(
            cli_path,
            server,
            env,
            {
                "session_id": f"sess-{uuid.uuid4().hex}",
                "hook_event_name": "Notification",
                "notification_type": "permission_prompt",
                "message": "Approve shell command?",
            },
        )
        if permission.returncode != 0:
            print("FAIL: non-ignored permission notification hook failed")
            print(f"stdout={permission.stdout!r}")
            print(f"stderr={permission.stderr!r}")
            print(f"commands={server.commands!r}")
            return 1

        new_commands = server.commands[before_permission_count:]
        if not any(line.startswith("set_status claude_code Needs input ") for line in new_commands):
            print("FAIL: non-ignored notification did not set Needs input status")
            print(f"new_commands={new_commands!r}")
            return 1
        if not any(line.startswith("notify_target_async ") for line in new_commands):
            print("FAIL: non-ignored notification did not render notify_target_async")
            print(f"new_commands={new_commands!r}")
            return 1

        before_root_type_count = len(server.commands)
        root_type = run_notification_hook(
            cli_path,
            server,
            env,
            {
                "session_id": f"sess-{uuid.uuid4().hex}",
                "hook_event_name": "Notification",
                "type": "idle_prompt",
                "message": "Generic root type should not be treated as a notification subtype",
            },
        )
        if root_type.returncode != 0:
            print("FAIL: generic root type notification hook failed")
            print(f"stdout={root_type.stdout!r}")
            print(f"stderr={root_type.stderr!r}")
            print(f"commands={server.commands!r}")
            return 1

        root_type_commands = server.commands[before_root_type_count:]
        if not any(line.startswith("notify_target_async ") for line in root_type_commands):
            print("FAIL: generic root type was treated as a notification type")
            print(f"root_type_commands={root_type_commands!r}")
            return 1

        hook_event_env = env.copy()
        hook_event_env["CMUX_CLAUDE_IGNORED_NOTIFICATION_TYPES"] = "notification"
        before_hook_event_count = len(server.commands)
        hook_event = run_notification_hook(
            cli_path,
            server,
            hook_event_env,
            {
                "session_id": f"sess-{uuid.uuid4().hex}",
                "hook_event_name": "Notification",
                "notification_type": "permission_prompt",
                "message": "Approve another command?",
            },
        )
        if hook_event.returncode != 0:
            print("FAIL: hook_event_name-only ignored type case failed")
            print(f"stdout={hook_event.stdout!r}")
            print(f"stderr={hook_event.stderr!r}")
            print(f"commands={server.commands!r}")
            return 1

        hook_event_commands = server.commands[before_hook_event_count:]
        if not any(line.startswith("notify_target_async ") for line in hook_event_commands):
            print("FAIL: hook_event_name Notification was treated as a notification type")
            print(f"hook_event_commands={hook_event_commands!r}")
            return 1

        settings_env = env.copy()
        settings_env["CMUX_CLAUDE_IGNORED_NOTIFICATION_TYPES"] = "permission_prompt"
        write_cmux_config(home, {"ignoredClaudeNotificationTypes": ["idle_prompt"]})
        before_settings_count = len(server.commands)
        settings_idle = run_notification_hook(
            cli_path,
            server,
            settings_env,
            {
                "session_id": f"sess-{uuid.uuid4().hex}",
                "hook_event_name": "Notification",
                "notification_type": "idle_prompt",
                "message": "Current cmux.json should override stale hook env",
            },
        )
        if settings_idle.returncode != 0 or settings_idle.stdout.strip() != "OK":
            print("FAIL: cmux.json ignored type did not override stale hook env")
            print(f"stdout={settings_idle.stdout!r}")
            print(f"stderr={settings_idle.stderr!r}")
            print(f"commands={server.commands!r}")
            return 1

        settings_idle_commands = server.commands[before_settings_count:]
        if any(
            line.startswith("notify_target_async ") or line.startswith("set_status claude_code Needs input ")
            for line in settings_idle_commands
        ):
            print("FAIL: cmux.json ignored type rendered because stale env won")
            print(f"settings_idle_commands={settings_idle_commands!r}")
            return 1

        stale_env = env.copy()
        stale_env["CMUX_CLAUDE_IGNORED_NOTIFICATION_TYPES"] = "idle_prompt"
        write_cmux_config(home, {})
        before_removed_count = len(server.commands)
        removed_idle = run_notification_hook(
            cli_path,
            server,
            stale_env,
            {
                "session_id": f"sess-{uuid.uuid4().hex}",
                "hook_event_name": "Notification",
                "notification_type": "idle_prompt",
                "message": "Removed cmux.json setting should not leave stale suppression active",
            },
        )
        if removed_idle.returncode != 0:
            print("FAIL: removed cmux.json ignored type hook failed")
            print(f"stdout={removed_idle.stdout!r}")
            print(f"stderr={removed_idle.stderr!r}")
            print(f"commands={server.commands!r}")
            return 1

        removed_idle_commands = server.commands[before_removed_count:]
        if not any(line.startswith("notify_target_async ") for line in removed_idle_commands):
            print("FAIL: stale hook env suppressed after cmux.json ignored types were removed")
            print(f"removed_idle_commands={removed_idle_commands!r}")
            return 1

    print("PASS: Claude ignored notification types suppress only matching hook notifications")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
