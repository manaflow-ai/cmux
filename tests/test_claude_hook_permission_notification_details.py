#!/usr/bin/env python3
"""Regression: generic Claude notifications should use Feed context."""

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
        self.root = tempfile.TemporaryDirectory(prefix="cmux-claude-permission-")
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
            idle_deadline = time.time() + 30.0
            while not self.stop.is_set() and time.time() < idle_deadline:
                try:
                    chunk = conn.recv(4096)
                except socket.timeout:
                    continue
                if not chunk:
                    break
                idle_deadline = time.time() + 30.0
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
                method = request.get("method")
                if method == "surface.list":
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
                if method == "feed.push":
                    event = request.get("params", {}).get("event", {})
                    if event.get("_opencode_request_id") == "resolved-clear-stale":
                        return json.dumps(
                            {
                                "id": request.get("id"),
                                "ok": True,
                                "result": {
                                    "status": "resolved",
                                    "decision": {"kind": "permission", "mode": "allow"},
                                },
                            }
                        )
                    return json.dumps(
                        {
                            "id": request.get("id"),
                            "ok": True,
                            "result": {"status": "acknowledged"},
                        }
                    )
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

    with CapturingSocketServer(workspace_id=workspace_id, surface_id=surface_id) as server:
        env = os.environ.copy()
        state_path = os.path.join(server.root.name, "state.json")
        env["CMUX_SOCKET_PATH"] = server.socket_path
        env["CMUX_WORKSPACE_ID"] = workspace_id
        env["CMUX_SURFACE_ID"] = surface_id
        env["CMUX_CLAUDE_HOOK_STATE_PATH"] = state_path
        env["CMUX_CLI_SENTRY_DISABLED"] = "1"
        env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        def session_record(session_id: str) -> dict[str, object]:
            with open(state_path, "r", encoding="utf-8") as state_file:
                state = json.load(state_file)
            record = state.get("sessions", {}).get(session_id)
            if not isinstance(record, dict):
                raise AssertionError(f"missing session record for {session_id}")
            return record

        cases = [
            {
                "name": "permission",
                "feed_payload": {
                    "hook_event_name": "PermissionRequest",
                    "cwd": os.getcwd(),
                    "tool_name": "Bash",
                    "tool_input": {
                        "command": "rm -rf .build",
                        "description": "Remove stale build artifacts",
                    },
                },
                "notification_message": "Claude needs your permission.",
                "expected": "Claude Code|Permission|Bash: Remove stale build artifacts",
            },
            {
                "name": "detailed permission message",
                "feed_payload": {
                    "hook_event_name": "PermissionRequest",
                    "cwd": os.getcwd(),
                    "tool_name": "Bash",
                    "tool_input": {
                        "command": "rm -rf .build",
                        "description": "Remove stale build artifacts",
                    },
                },
                "notification_message": "Permission needed: Bash: npm publish",
                "expected": "Claude Code|Permission|Permission needed: Bash: npm publish",
            },
            {
                "name": "redacted permission",
                "feed_payload": {
                    "hook_event_name": "PermissionRequest",
                    "cwd": os.getcwd(),
                    "tool_name": "Bash",
                    "tool_input": {
                        "command": "API_KEY=sk-test-secret-token curl -H 'Authorization: Bearer abcdefghijklmnop' https://example.test",
                    },
                },
                "notification_message": "Claude needs your permission!",
                "expected": "Claude Code|Permission|Bash: Sensitive content removed",
            },
            {
                "name": "redacted non-bearer authorization",
                "feed_payload": {
                    "hook_event_name": "PermissionRequest",
                    "cwd": os.getcwd(),
                    "tool_name": "Bash",
                    "tool_input": {
                        "command": "curl -H 'Authorization: token ghp_1234567890abcdef1234567890abcdef123456' https://api.github.test/repos",
                    },
                },
                "notification_message": "Claude needs your permission",
                "expected": "Claude Code|Permission|Bash: Sensitive content removed",
            },
            {
                "name": "nested file permission",
                "feed_payload": {
                    "hook_event_name": "PermissionRequest",
                    "data": {
                        "toolName": "Write",
                        "toolInput": {
                            "file_path": "/tmp/cmux-notification-test.txt",
                        },
                    },
                },
                "notification_message": "Claude needs your permission",
                "expected": "Claude Code|Permission|Write: cmux-notification-test.txt",
            },
            {
                "name": "web permission",
                "feed_payload": {
                    "hook_event_name": "PermissionRequest",
                    "cwd": os.getcwd(),
                    "tool_name": "WebFetch",
                    "tool_input": {
                        "url": "https://docs.example.test/guide",
                    },
                },
                "notification_message": "Claude needs your permission",
                "expected": "Claude Code|Permission|WebFetch: https://docs.example.test/guide",
            },
            {
                "name": "redacted web permission",
                "feed_payload": {
                    "hook_event_name": "PermissionRequest",
                    "cwd": os.getcwd(),
                    "tool_name": "WebFetch",
                    "tool_input": {
                        "url": "https://docs.example.test/guide?apiKey=secret-value&accessToken=secret-token",
                    },
                },
                "notification_message": "Claude needs your permission",
                "expected": "Claude Code|Permission|WebFetch: Sensitive content removed",
            },
            {
                "name": "unknown tool permission",
                "feed_payload": {
                    "hook_event_name": "PermissionRequest",
                    "cwd": os.getcwd(),
                    "tool_name": "mcp__ops__restart",
                    "tool_input": {
                        "action": "restart",
                        "target": "worker",
                    },
                },
                "notification_message": "Claude needs your permission",
                "expected": 'Claude Code|Permission|mcp__ops__restart: {"action":"restart","target":"worker"}',
            },
            {
                "name": "redacted unknown tool permission",
                "feed_payload": {
                    "hook_event_name": "PermissionRequest",
                    "cwd": os.getcwd(),
                    "tool_name": "mcp__ops__restart",
                    "tool_input": {
                        "aws_secret_access_key": "ABCDEFGHIJKLMNOPQRSTUVWX",
                        "target": "worker",
                    },
                },
                "notification_message": "Claude needs your permission",
                "expected": "Claude Code|Permission|mcp__ops__restart: Sensitive content removed",
            },
            {
                "name": "exit plan",
                "feed_payload": {
                    "hook_event_name": "PermissionRequest",
                    "cwd": os.getcwd(),
                    "tool_name": "ExitPlanMode",
                    "tool_input": {
                        "plan": "1. Improve notification summaries\n2. Simulate Claude hook flows",
                    },
                },
                "notification_message": "Claude needs your permission",
                "expected": "Claude Code|Exit plan|Improve notification summaries",
            },
            {
                "name": "redacted exit plan",
                "feed_payload": {
                    "hook_event_name": "PermissionRequest",
                    "cwd": os.getcwd(),
                    "tool_name": "ExitPlanMode",
                    "tool_input": {
                        "plan": "1. Rotate API_KEY=secret-value\n2. Continue notification tests",
                    },
                },
                "notification_message": "Claude needs your permission",
                "expected": "Claude Code|Exit plan|Sensitive content removed",
            },
            {
                "name": "question",
                "feed_payload": {
                    "hook_event_name": "PermissionRequest",
                    "cwd": os.getcwd(),
                    "tool_name": "AskUserQuestion",
                    "tool_input": {
                        "questions": [
                            {
                                "header": "Choose style",
                                "question": "Which notification style should cmux use?",
                                "options": [
                                    {"label": "Detailed"},
                                    {"label": "Compact"},
                                ],
                            }
                        ],
                    },
                },
                "notification_message": "needs your input",
                "expected": "Claude Code|Question|Which notification style should cmux use? [Detailed] [Compact]",
            },
            {
                "name": "redacted question",
                "feed_payload": {
                    "hook_event_name": "PermissionRequest",
                    "cwd": os.getcwd(),
                    "tool_name": "AskUserQuestion",
                    "tool_input": {
                        "questions": [
                            {
                                "question": "Use token sk-testsecret123456 for setup?",
                                "options": [
                                    {"label": "Yes"},
                                    {"label": "No"},
                                ],
                            }
                        ],
                    },
                },
                "notification_message": "Claude needs your input",
                "expected": "Claude Code|Question|Sensitive content removed",
            },
        ]

        for case in cases:
            session_id = f"sess-{uuid.uuid4().hex}"
            feed_payload = dict(case["feed_payload"])
            feed_payload["session_id"] = session_id
            feed_proc = subprocess.run(
                [cli_path, "--socket", server.socket_path, "hooks", "feed", "--source", "claude"],
                input=json.dumps(feed_payload),
                text=True,
                capture_output=True,
                env=env,
                timeout=8,
                check=False,
            )
            if feed_proc.returncode != 0:
                print(f"FAIL: hooks feed failed for {case['name']}")
                print(f"stdout={feed_proc.stdout!r}")
                print(f"stderr={feed_proc.stderr!r}")
                print(f"commands={server.commands!r}")
                return 1

            before_count = len([line for line in server.commands if line.startswith("notify_target_async ")])
            notification_payload = {
                "session_id": session_id,
                "hook_event_name": "Notification",
                "message": case["notification_message"],
            }
            notification_proc = subprocess.run(
                [cli_path, "--socket", server.socket_path, "claude-hook", "notification"],
                input=json.dumps(notification_payload),
                text=True,
                capture_output=True,
                env=env,
                timeout=8,
                check=False,
            )
            if notification_proc.returncode != 0:
                print(f"FAIL: claude-hook notification failed for {case['name']}")
                print(f"stdout={notification_proc.stdout!r}")
                print(f"stderr={notification_proc.stderr!r}")
                print(f"commands={server.commands!r}")
                return 1

            notify_commands = [line for line in server.commands if line.startswith("notify_target_async ")]
            if len(notify_commands) <= before_count:
                print(f"FAIL: expected notify_target_async command for {case['name']}")
                print(f"commands={server.commands!r}")
                return 1

            notify = notify_commands[-1]
            expected_payload = f"notify_target_async {workspace_id} {surface_id} {case['expected']}"
            if notify != expected_payload:
                print(f"FAIL: notification should include {case['name']} detail")
                print(f"expected={expected_payload!r}")
                print(f"actual={notify!r}")
                print(f"commands={server.commands!r}")
                return 1

        question_tool_session_id = f"sess-{uuid.uuid4().hex}"
        question_tool_payload = {
            "session_id": question_tool_session_id,
            "hookEventName": "PreToolUse",
            "toolName": "AskUserQuestion",
            "toolInput": {
                "questions": [
                    {
                        "question": "Which follow-up agent should run next?",
                        "options": [
                            {"label": "Codex"},
                            {"label": "OpenCode"},
                        ],
                    }
                ],
            },
        }
        question_tool_proc = subprocess.run(
            [cli_path, "--socket", server.socket_path, "claude-hook", "pre-tool-use"],
            input=json.dumps(question_tool_payload),
            text=True,
            capture_output=True,
            env=env,
            timeout=8,
            check=False,
        )
        if question_tool_proc.returncode != 0:
            print("FAIL: AskUserQuestion pre-tool-use failed")
            print(f"stdout={question_tool_proc.stdout!r}")
            print(f"stderr={question_tool_proc.stderr!r}")
            print(f"commands={server.commands!r}")
            return 1
        before_count = len([line for line in server.commands if line.startswith("notify_target_async ")])
        question_tool_notification = {
            "session_id": question_tool_session_id,
            "hook_event_name": "Notification",
            "message": "Claude needs your input",
        }
        question_tool_notify_proc = subprocess.run(
            [cli_path, "--socket", server.socket_path, "claude-hook", "notification"],
            input=json.dumps(question_tool_notification),
            text=True,
            capture_output=True,
            env=env,
            timeout=8,
            check=False,
        )
        if question_tool_notify_proc.returncode != 0:
            print("FAIL: AskUserQuestion notification failed")
            print(f"stdout={question_tool_notify_proc.stdout!r}")
            print(f"stderr={question_tool_notify_proc.stderr!r}")
            print(f"commands={server.commands!r}")
            return 1
        notify_commands = [line for line in server.commands if line.startswith("notify_target_async ")]
        if len(notify_commands) <= before_count:
            print("FAIL: expected notify_target_async command for AskUserQuestion")
            print(f"commands={server.commands!r}")
            return 1
        expected_question_tool = (
            f"notify_target_async {workspace_id} {surface_id} "
            "Claude Code|Question|Which follow-up agent should run next? [Codex] [OpenCode]"
        )
        if notify_commands[-1] != expected_question_tool:
            print("FAIL: AskUserQuestion notification should include question detail")
            print(f"expected={expected_question_tool!r}")
            print(f"actual={notify_commands[-1]!r}")
            print(f"commands={server.commands!r}")
            return 1

        direct_cases = [
            {
                "name": "direct snake-case",
                "notification": {
                    "hook_event_name": "Notification",
                    "message": "Claude needs your permission",
                    "tool_name": "Bash",
                    "tool_input": {"description": "Install test dependency"},
                },
                "expected": "Claude Code|Permission|Bash: Install test dependency",
            },
            {
                "name": "direct camelCase",
                "notification": {
                    "hookEventName": "Notification",
                    "message": "Claude needs your permission",
                    "toolName": "WebFetch",
                    "toolInput": {"url": "https://docs.example.test/camel"},
                },
                "expected": "Claude Code|Permission|WebFetch: https://docs.example.test/camel",
            },
            {
                "name": "direct nested data",
                "notification": {
                    "data": {
                        "hookEventName": "Notification",
                        "message": "Claude needs your permission",
                        "toolName": "Write",
                        "toolInput": {"file_path": "/tmp/cmux-nested-direct.txt"},
                    },
                },
                "expected": "Claude Code|Permission|Write: cmux-nested-direct.txt",
            },
        ]
        for case in direct_cases:
            direct_session_id = f"sess-{uuid.uuid4().hex}"
            before_count = len([line for line in server.commands if line.startswith("notify_target_async ")])
            direct_notification = dict(case["notification"])
            direct_notification["session_id"] = direct_session_id
            direct_proc = subprocess.run(
                [cli_path, "--socket", server.socket_path, "claude-hook", "notification"],
                input=json.dumps(direct_notification),
                text=True,
                capture_output=True,
                env=env,
                timeout=8,
                check=False,
            )
            if direct_proc.returncode != 0:
                print(f"FAIL: {case['name']} generic notification failed")
                print(f"stdout={direct_proc.stdout!r}")
                print(f"stderr={direct_proc.stderr!r}")
                print(f"commands={server.commands!r}")
                return 1
            notify_commands = [line for line in server.commands if line.startswith("notify_target_async ")]
            if len(notify_commands) <= before_count:
                print(f"FAIL: expected notify_target_async command for {case['name']} generic notification")
                print(f"commands={server.commands!r}")
                return 1
            expected_direct = f"notify_target_async {workspace_id} {surface_id} {case['expected']}"
            if notify_commands[-1] != expected_direct:
                print(f"FAIL: {case['name']} generic notification should include tool detail")
                print(f"expected={expected_direct!r}")
                print(f"actual={notify_commands[-1]!r}")
                print(f"commands={server.commands!r}")
                return 1

        direct_stale_session_id = f"sess-{uuid.uuid4().hex}"
        before_count = len([line for line in server.commands if line.startswith("notify_target_async ")])
        direct_stale_notification = {
            "session_id": direct_stale_session_id,
            "hook_event_name": "Notification",
            "message": "Claude needs your permission",
            "tool_name": "Bash",
            "tool_input": {"description": "Install direct dependency"},
        }
        direct_stale_proc = subprocess.run(
            [cli_path, "--socket", server.socket_path, "claude-hook", "notification"],
            input=json.dumps(direct_stale_notification),
            text=True,
            capture_output=True,
            env=env,
            timeout=8,
            check=False,
        )
        if direct_stale_proc.returncode != 0:
            print("FAIL: direct stale-seed notification failed")
            print(f"stdout={direct_stale_proc.stdout!r}")
            print(f"stderr={direct_stale_proc.stderr!r}")
            print(f"commands={server.commands!r}")
            return 1
        notify_commands = [line for line in server.commands if line.startswith("notify_target_async ")]
        if len(notify_commands) <= before_count:
            print("FAIL: expected notify_target_async command for direct stale-seed notification")
            print(f"commands={server.commands!r}")
            return 1
        pre_tool_use_payload = {
            "session_id": direct_stale_session_id,
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"description": "Continue after permission"},
        }
        pre_tool_use_proc = subprocess.run(
            [cli_path, "--socket", server.socket_path, "claude-hook", "pre-tool-use"],
            input=json.dumps(pre_tool_use_payload),
            text=True,
            capture_output=True,
            env=env,
            timeout=8,
            check=False,
        )
        if pre_tool_use_proc.returncode != 0:
            print("FAIL: pre-tool-use failed to clear direct pending summary")
            print(f"stdout={pre_tool_use_proc.stdout!r}")
            print(f"stderr={pre_tool_use_proc.stderr!r}")
            print(f"commands={server.commands!r}")
            return 1
        try:
            direct_record = session_record(direct_stale_session_id)
        except Exception as exc:
            print(f"FAIL: direct pending summary state missing after pre-tool-use: {exc}")
            return 1
        if direct_record.get("runtimeStatus") != "running":
            print("FAIL: pre-tool-use should restore pending runtime status to running")
            print(f"record={direct_record!r}")
            return 1
        before_count = len([line for line in server.commands if line.startswith("notify_target_async ")])
        direct_stale_followup = {
            "session_id": direct_stale_session_id,
            "hook_event_name": "Notification",
            "message": "Claude needs your permission",
        }
        direct_stale_followup_proc = subprocess.run(
            [cli_path, "--socket", server.socket_path, "claude-hook", "notification"],
            input=json.dumps(direct_stale_followup),
            text=True,
            capture_output=True,
            env=env,
            timeout=8,
            check=False,
        )
        if direct_stale_followup_proc.returncode != 0:
            print("FAIL: direct stale follow-up notification failed")
            print(f"stdout={direct_stale_followup_proc.stdout!r}")
            print(f"stderr={direct_stale_followup_proc.stderr!r}")
            print(f"commands={server.commands!r}")
            return 1
        notify_commands = [line for line in server.commands if line.startswith("notify_target_async ")]
        if len(notify_commands) <= before_count:
            print("FAIL: expected notify_target_async command for direct stale follow-up")
            print(f"commands={server.commands!r}")
            return 1
        if "Install direct dependency" in notify_commands[-1]:
            print("FAIL: direct permission detail should clear after pre-tool-use")
            print(f"actual={notify_commands[-1]!r}")
            print(f"commands={server.commands!r}")
            return 1

        stale_session_id = f"sess-{uuid.uuid4().hex}"
        stale_feed_payload = {
            "session_id": stale_session_id,
            "request_id": "resolved-clear-stale",
            "hook_event_name": "PermissionRequest",
            "cwd": os.getcwd(),
            "tool_name": "Bash",
            "tool_input": {"description": "Delete temporary credentials"},
        }
        stale_feed_proc = subprocess.run(
            [cli_path, "--socket", server.socket_path, "hooks", "feed", "--source", "claude"],
            input=json.dumps(stale_feed_payload),
            text=True,
            capture_output=True,
            env=env,
            timeout=8,
            check=False,
        )
        if stale_feed_proc.returncode != 0:
            print("FAIL: resolved hooks feed failed for stale-clear case")
            print(f"stdout={stale_feed_proc.stdout!r}")
            print(f"stderr={stale_feed_proc.stderr!r}")
            print(f"commands={server.commands!r}")
            return 1
        try:
            stale_record = session_record(stale_session_id)
        except Exception as exc:
            print(f"FAIL: resolved pending summary state missing: {exc}")
            return 1
        if stale_record.get("runtimeStatus") != "running":
            print("FAIL: resolved pending summary should restore runtime status to running")
            print(f"record={stale_record!r}")
            return 1
        before_count = len([line for line in server.commands if line.startswith("notify_target_async ")])
        stale_notification = {
            "session_id": stale_session_id,
            "hook_event_name": "Notification",
            "message": "Claude needs your permission",
        }
        stale_proc = subprocess.run(
            [cli_path, "--socket", server.socket_path, "claude-hook", "notification"],
            input=json.dumps(stale_notification),
            text=True,
            capture_output=True,
            env=env,
            timeout=8,
            check=False,
        )
        if stale_proc.returncode != 0:
            print("FAIL: stale-clear notification failed")
            print(f"stdout={stale_proc.stdout!r}")
            print(f"stderr={stale_proc.stderr!r}")
            print(f"commands={server.commands!r}")
            return 1
        notify_commands = [line for line in server.commands if line.startswith("notify_target_async ")]
        if len(notify_commands) <= before_count:
            print("FAIL: expected notify_target_async command for stale-clear notification")
            print(f"commands={server.commands!r}")
            return 1
        if "Delete temporary credentials" in notify_commands[-1]:
            print("FAIL: resolved permission detail should not be reused by later generic notification")
            print(f"actual={notify_commands[-1]!r}")
            print(f"commands={server.commands!r}")
            return 1

    print("PASS: Claude notifications include permission, plan, question, and fallback details")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
