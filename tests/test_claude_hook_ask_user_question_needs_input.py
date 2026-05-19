#!/usr/bin/env python3
"""Regression: Claude AskUserQuestion should publish needs-input immediately."""

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


class HookSocketServer:
    def __init__(self, workspace_id: str, surface_id: str) -> None:
        self.workspace_id = workspace_id
        self.surface_id = surface_id
        self.commands: list[str] = []
        self.ready = threading.Event()
        self.stop = threading.Event()
        self.error: Exception | None = None
        self.root = tempfile.TemporaryDirectory(prefix="cmux-claude-ask-user-question-")
        self.socket_path = os.path.join(self.root.name, "cmux.sock")
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.server: socket.socket | None = None

    def __enter__(self) -> "HookSocketServer":
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
                server.listen(16)
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
        if not line.startswith("{"):
            return "OK"
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            return "OK"

        method = request.get("method")
        result: dict[str, object] = {}
        if method == "surface.list":
            result = {
                "surfaces": [
                    {
                        "index": 0,
                        "id": self.surface_id,
                        "ref": "surface:1",
                        "workspace_id": self.workspace_id,
                        "focused": True,
                    }
                ]
            }
        elif method == "workspace.current":
            result = {"workspace_id": self.workspace_id}
        elif method == "workspace.list":
            result = {
                "workspaces": [
                    {
                        "index": 0,
                        "id": self.workspace_id,
                        "ref": "workspace:1",
                    }
                ]
            }
        elif method == "window.list":
            result = {"windows": [{"id": str(uuid.uuid4()).upper()}]}
        elif method == "debug.terminals":
            result = {"terminals": []}

        return json.dumps({"id": request.get("id"), "ok": True, "result": result})


def run_claude_hook(
    cli_path: str,
    socket_path: str,
    subcommand: str,
    payload: dict[str, object],
    env: dict[str, str],
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [cli_path, "--socket", socket_path, "claude-hook", subcommand],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        env=env,
        timeout=8,
        check=False,
    )


def ask_user_question_payload(session_id: str, index: int) -> dict[str, object]:
    return {
        "session_id": session_id,
        "turn_id": f"turn-{index}",
        "hook_event_name": "PreToolUse",
        "cwd": "/Users/example/project",
        "tool_name": "AskUserQuestion",
        "tool_input": {
            "questions": [
                {
                    "header": "Need input",
                    "question": f"Should cmux continue with option {index}?",
                    "options": [
                        {"label": "Yes", "description": "Continue"},
                        {"label": "No", "description": "Stop"},
                    ],
                }
            ]
        },
    }


def generic_attention_payload(session_id: str, index: int) -> dict[str, object]:
    return {
        "session_id": session_id,
        "turn_id": f"turn-{index}",
        "hook_event_name": "Notification",
        "cwd": "/Users/example/project",
        "notification_type": "generic",
        "message": "Claude Code needs your attention",
    }


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    session_id = f"sess-{uuid.uuid4().hex}"

    with HookSocketServer(workspace_id=workspace_id, surface_id=surface_id) as server:
        state_path = Path(server.root.name) / "claude-hook-state.json"
        env = os.environ.copy()
        env["CMUX_SOCKET_PATH"] = server.socket_path
        env["CMUX_WORKSPACE_ID"] = workspace_id
        env["CMUX_SURFACE_ID"] = surface_id
        env["CMUX_CLAUDE_HOOK_STATE_PATH"] = str(state_path)
        env["CMUX_CLI_SENTRY_DISABLED"] = "1"
        env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        env["CMUX_CLAUDE_PID"] = "4242"

        start_proc = run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {"session_id": session_id, "source": "startup", "cwd": "/Users/example/project"},
            env,
        )
        if start_proc.returncode != 0:
            print("FAIL: claude-hook session-start failed")
            print(f"stdout={start_proc.stdout!r}")
            print(f"stderr={start_proc.stderr!r}")
            return 1

        first_question = ask_user_question_payload(session_id, 0)
        first_proc = run_claude_hook(cli_path, server.socket_path, "pre-tool-use", first_question, env)
        if first_proc.returncode != 0:
            print("FAIL: claude-hook pre-tool-use failed")
            print(f"stdout={first_proc.stdout!r}")
            print(f"stderr={first_proc.stderr!r}")
            print(f"commands={server.commands!r}")
            return 1

        notify_commands = [line for line in server.commands if line.startswith("notify_target_async ")]
        if len(notify_commands) != 1:
            print("FAIL: AskUserQuestion should immediately publish exactly one notification")
            print(f"notify_commands={notify_commands!r}")
            print(f"commands={server.commands!r}")
            return 1
        expected_body = "Should cmux continue with option 0? [Yes] [No]"
        expected_notify = f"notify_target_async {workspace_id} {surface_id} Claude Code|Waiting|{expected_body}"
        if notify_commands[0] != expected_notify:
            print("FAIL: AskUserQuestion notification should preserve the question text")
            print(f"expected={expected_notify!r}")
            print(f"actual={notify_commands[0]!r}")
            print(f"commands={server.commands!r}")
            return 1

        if not any(
            line.startswith("set_status claude_code Claude Code needs input ")
            and f"--tab={workspace_id}" in line
            and f"--panel={surface_id}" in line
            for line in server.commands
        ):
            print("FAIL: AskUserQuestion should mark Claude as Needs input")
            print(f"commands={server.commands!r}")
            return 1

        duplicate_proc = run_claude_hook(
            cli_path,
            server.socket_path,
            "notification",
            generic_attention_payload(session_id, 0),
            env,
        )
        if duplicate_proc.returncode != 0:
            print("FAIL: claude-hook notification failed")
            print(f"stdout={duplicate_proc.stdout!r}")
            print(f"stderr={duplicate_proc.stderr!r}")
            print(f"commands={server.commands!r}")
            return 1
        notify_after_duplicate = [line for line in server.commands if line.startswith("notify_target_async ")]
        if len(notify_after_duplicate) != 1:
            print("FAIL: generic attention Notification should be deduped after AskUserQuestion")
            print(f"notify_commands={notify_after_duplicate!r}")
            print(f"commands={server.commands!r}")
            return 1

        resume_proc = run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {
                "session_id": session_id,
                "hook_event_name": "UserPromptSubmit",
                "cwd": "/Users/example/project",
                "prompt": "answered the previous question; continue",
            },
            env,
        )
        if resume_proc.returncode != 0:
            print("FAIL: claude-hook prompt-submit failed")
            print(f"stdout={resume_proc.stdout!r}")
            print(f"stderr={resume_proc.stderr!r}")
            print(f"commands={server.commands!r}")
            return 1

        repeated_proc = run_claude_hook(
            cli_path,
            server.socket_path,
            "pre-tool-use",
            ask_user_question_payload(session_id, 0),
            env,
        )
        if repeated_proc.returncode != 0:
            print("FAIL: repeated claude-hook pre-tool-use failed")
            print(f"stdout={repeated_proc.stdout!r}")
            print(f"stderr={repeated_proc.stderr!r}")
            print(f"commands={server.commands!r}")
            return 1
        notify_after_repeat = [line for line in server.commands if line.startswith("notify_target_async ")]
        if len(notify_after_repeat) != 2:
            print("FAIL: prompt-submit should clear the needs-input dedup fingerprint")
            print(f"notify_commands={notify_after_repeat!r}")
            print(f"commands={server.commands!r}")
            return 1

        before_loop_count = len(notify_after_repeat)
        for index in range(1, 101):
            proc = run_claude_hook(
                cli_path,
                server.socket_path,
                "pre-tool-use",
                ask_user_question_payload(session_id, index),
                env,
            )
            if proc.returncode != 0:
                print(f"FAIL: claude-hook pre-tool-use failed at loop {index}")
                print(f"stdout={proc.stdout!r}")
                print(f"stderr={proc.stderr!r}")
                print(f"commands={server.commands!r}")
                return 1
            dup = run_claude_hook(
                cli_path,
                server.socket_path,
                "notification",
                generic_attention_payload(session_id, index),
                env,
            )
            if dup.returncode != 0:
                print(f"FAIL: claude-hook notification failed at loop {index}")
                print(f"stdout={dup.stdout!r}")
                print(f"stderr={dup.stderr!r}")
                print(f"commands={server.commands!r}")
                return 1

        loop_notify_commands = [line for line in server.commands if line.startswith("notify_target_async ")]
        expected_total = before_loop_count + 100
        if len(loop_notify_commands) != expected_total:
            print("FAIL: AskUserQuestion loop should have zero drops and zero duplicate generic notifications")
            print(f"expected_total={expected_total}")
            print(f"actual_total={len(loop_notify_commands)}")
            print(f"notify_commands={loop_notify_commands!r}")
            return 1

    print("PASS: Claude AskUserQuestion publishes needs-input immediately with no duplicate generic notifications")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
