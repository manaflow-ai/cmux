#!/usr/bin/env python3
"""
Regression tests for Codex Feed hook wiring and decision output.
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import tempfile
import threading
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli


class FakeCmuxSocket:
    def __init__(self, path: Path, decision: dict | None):
        self.path = path
        self.decision = decision
        self.frames: list[dict] = []
        self._ready = threading.Event()
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def __enter__(self) -> "FakeCmuxSocket":
        self.path.unlink(missing_ok=True)
        self._thread.start()
        if not self._ready.wait(timeout=3):
            raise RuntimeError("fake socket did not start")
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self._stop.set()
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.connect(str(self.path))
        except OSError:
            pass
        self._thread.join(timeout=3)
        self.path.unlink(missing_ok=True)

    def _run(self) -> None:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
            server.bind(str(self.path))
            server.listen(4)
            self._ready.set()
            while not self._stop.is_set():
                try:
                    conn, _ = server.accept()
                except OSError:
                    continue
                with conn:
                    data = b""
                    while b"\n" not in data:
                        chunk = conn.recv(65536)
                        if not chunk:
                            break
                        data += chunk
                    line = data.split(b"\n", 1)[0]
                    if not line:
                        continue
                    frame = json.loads(line.decode("utf-8"))
                    self.frames.append(frame)
                    result: dict = {"status": "acknowledged"}
                    if self.decision is not None:
                        result = {
                            "status": "resolved",
                            "decision": self.decision,
                        }
                    response = {
                        "id": frame.get("id"),
                        "ok": True,
                        "result": result,
                    }
                    conn.sendall(json.dumps(response).encode("utf-8") + b"\n")


def run_feed_hook(cli_path: str, socket_path: Path, payload: dict, decision: dict | None) -> tuple[dict, dict]:
    env = os.environ.copy()
    env["CMUX_SURFACE_ID"] = "surface-codex-feed-test"
    env["CMUX_WORKSPACE_ID"] = "workspace-codex-feed-test"
    with FakeCmuxSocket(socket_path, decision) as fake:
        result = subprocess.run(
            [
                cli_path,
                "--socket",
                str(socket_path),
                "hooks",
                "feed",
                "--source",
                "codex",
                "--event",
                payload.get("hook_event_name", ""),
            ],
            input=json.dumps(payload),
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=10,
        )
        if result.returncode != 0:
            raise AssertionError(
                f"hooks feed failed exit={result.returncode}\nstdout={result.stdout}\nstderr={result.stderr}"
            )
        if not fake.frames:
            raise AssertionError("hooks feed did not send feed.push")
        stdout = json.loads(result.stdout.strip() or "{}")
        return stdout, fake.frames[0]


def assert_permission_output(stdout: dict, behavior: str) -> None:
    hook_output = stdout.get("hookSpecificOutput")
    if not isinstance(hook_output, dict):
        raise AssertionError(f"missing hookSpecificOutput: {stdout!r}")
    if hook_output.get("hookEventName") != "PermissionRequest":
        raise AssertionError(f"wrong hook event output: {stdout!r}")
    decision = hook_output.get("decision")
    if not isinstance(decision, dict) or decision.get("behavior") != behavior:
        raise AssertionError(f"wrong permission behavior: {stdout!r}")


def assert_codex_allow_has_no_persistent_fields(stdout: dict) -> None:
    decision = stdout["hookSpecificOutput"]["decision"]
    forbidden = {"updatedInput", "updatedPermissions", "setMode", "remember"}
    present = forbidden.intersection(decision)
    if present:
        raise AssertionError(f"Codex permission output included unsupported fields {present}: {stdout!r}")


def test_install_adds_codex_permission_request_hook(cli_path: str, root: Path) -> None:
    codex_home = root / "codex-home"
    codex_home.mkdir()
    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)

    result = subprocess.run(
        [cli_path, "hooks", "codex", "install", "--yes"],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=20,
    )
    if result.returncode != 0:
        raise AssertionError(
            f"hooks codex install failed exit={result.returncode}\nstdout={result.stdout}\nstderr={result.stderr}"
        )

    hooks = json.loads((codex_home / "hooks.json").read_text(encoding="utf-8"))
    hook_groups = hooks.get("hooks", {})
    for event_name in ["PreToolUse", "PermissionRequest"]:
        groups = hook_groups.get(event_name)
        if not groups:
            raise AssertionError(f"missing {event_name} hook group: {hooks!r}")
        command = groups[-1]["hooks"][0]["command"]
        if f"cmux hooks feed --source codex --event {event_name}" not in command:
            raise AssertionError(f"wrong {event_name} feed command: {command!r}")
        if groups[-1]["hooks"][0].get("timeout") != 120_000:
            raise AssertionError(f"wrong {event_name} timeout: {groups[-1]!r}")

    config_toml = (codex_home / "config.toml").read_text(encoding="utf-8")
    if "codex_hooks = true" not in config_toml:
        raise AssertionError(f"codex_hooks feature was not enabled: {config_toml!r}")


def test_permission_reply_uses_codex_permission_request_schema(cli_path: str, root: Path) -> None:
    socket_path = root / "cmux.sock"
    payload = {
        "session_id": "codex-session",
        "turn_id": "turn-1",
        "cwd": "/tmp/project",
        "hook_event_name": "PermissionRequest",
        "tool_name": "Bash",
        "tool_input": {"command": "printf hi"},
    }

    stdout, frame = run_feed_hook(
        cli_path,
        socket_path,
        payload,
        {"kind": "permission", "mode": "once"},
    )
    assert_permission_output(stdout, "allow")
    params = frame["params"]
    if params.get("wait_timeout_seconds") != 120:
        raise AssertionError(f"PermissionRequest should block for Feed reply: {frame!r}")
    event = params["event"]
    if event.get("hook_event_name") != "PermissionRequest" or event.get("_source") != "codex":
        raise AssertionError(f"wrong feed event: {event!r}")

    stdout, _ = run_feed_hook(
        cli_path,
        root / "cmux-deny.sock",
        payload,
        {"kind": "permission", "mode": "deny"},
    )
    assert_permission_output(stdout, "deny")
    message = stdout["hookSpecificOutput"]["decision"].get("message", "")
    if "denied" not in message:
        raise AssertionError(f"deny output should include a message: {stdout!r}")


def test_codex_persistent_permission_modes_degrade_to_once(cli_path: str, root: Path) -> None:
    payload = {
        "session_id": "codex-session",
        "turn_id": "turn-persistent",
        "cwd": "/tmp/project",
        "hook_event_name": "PermissionRequest",
        "tool_name": "Bash",
        "tool_input": {"command": "printf hi"},
    }

    for mode in ["always", "all", "bypass"]:
        stdout, _ = run_feed_hook(
            cli_path,
            root / f"cmux-{mode}.sock",
            payload,
            {"kind": "permission", "mode": mode},
        )
        assert_permission_output(stdout, "allow")
        assert_codex_allow_has_no_persistent_fields(stdout)


def test_codex_pre_tool_use_is_telemetry_not_actionable(cli_path: str, root: Path) -> None:
    stdout, frame = run_feed_hook(
        cli_path,
        root / "cmux-pretool.sock",
        {
            "session_id": "codex-session",
            "turn_id": "turn-2",
            "cwd": "/tmp/project",
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": "printf hi"},
        },
        None,
    )
    if stdout != {}:
        raise AssertionError(f"PreToolUse telemetry should not emit a decision: {stdout!r}")
    params = frame["params"]
    if params.get("wait_timeout_seconds") != 0:
        raise AssertionError(f"Codex PreToolUse should not wait for Feed reply: {frame!r}")
    if params["event"].get("hook_event_name") != "PreToolUse":
        raise AssertionError(f"wrong PreToolUse event: {frame!r}")


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(prefix="cmux-codex-feed-hooks-") as td:
        root = Path(td)
        try:
            test_install_adds_codex_permission_request_hook(cli_path, root)
            test_permission_reply_uses_codex_permission_request_schema(cli_path, root)
            test_codex_persistent_permission_modes_degrade_to_once(cli_path, root)
            test_codex_pre_tool_use_is_telemetry_not_actionable(cli_path, root)
        except Exception as exc:
            print(f"FAIL: {exc}")
            return 1

    print("PASS: Codex Feed hooks use native permission approvals")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
