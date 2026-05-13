#!/usr/bin/env python3
"""
Regression tests for Codex Feed hook wiring and decision output.
"""

from __future__ import annotations

import json
import hashlib
import os
import shutil
import socket
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli


CODEX_HOOK_EVENT_LABELS = {
    "PreToolUse": "pre_tool_use",
    "PermissionRequest": "permission_request",
    "PostToolUse": "post_tool_use",
    "PreCompact": "pre_compact",
    "PostCompact": "post_compact",
    "SessionStart": "session_start",
    "UserPromptSubmit": "user_prompt_submit",
    "Stop": "stop",
}

CODEX_HOOK_EVENTS_WITH_MATCHERS = {
    "PreToolUse",
    "PermissionRequest",
    "PostToolUse",
    "PreCompact",
    "PostCompact",
    "SessionStart",
}

CMUX_CODEX_HOOK_SUBCOMMANDS = (
    "session-start",
    "prompt-submit",
    "stop",
)

CMUX_CODEX_FEED_EVENTS = (
    "PreToolUse",
    "PermissionRequest",
)

FAKE_WORKSPACE_ID = "11111111-1111-1111-1111-111111111111"
FAKE_SURFACE_ID = "22222222-2222-2222-2222-222222222222"


class FakeCmuxSocket:
    def __init__(
        self,
        path: Path,
        decision: dict | None,
        surfaces: list[dict] | None = None,
        drop_first_surface_list: bool = False,
    ):
        self.path = path
        self.decision = decision
        self.surfaces = surfaces if surfaces is not None else [{"id": FAKE_SURFACE_ID}]
        self.drop_first_surface_list = drop_first_surface_list
        self._dropped_surface_list = False
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
                threading.Thread(target=self._handle_conn, args=(conn,), daemon=True).start()

    def _handle_conn(self, conn: socket.socket) -> None:
        with conn:
            data = b""
            while not self._stop.is_set():
                chunk = conn.recv(65536)
                if not chunk:
                    break
                data += chunk
                while b"\n" in data:
                    line, data = data.split(b"\n", 1)
                    if not line:
                        continue
                    raw_line = line.decode("utf-8")
                    try:
                        frame = json.loads(raw_line)
                    except json.JSONDecodeError:
                        self.frames.append({"raw": raw_line})
                        conn.sendall(b"OK\n")
                        continue
                    self.frames.append(frame)
                    result: dict = {"status": "acknowledged"}
                    if frame.get("method") == "surface.list":
                        if self.drop_first_surface_list and not self._dropped_surface_list:
                            self._dropped_surface_list = True
                            continue
                        result = {"surfaces": self.surfaces}
                    elif self.decision is not None:
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


def monitor_pids_for_session(session_id: str) -> list[int]:
    ps_path = shutil.which("ps")
    if ps_path is None:
        raise AssertionError("ps executable not found")
    result = subprocess.run(
        [ps_path, "-axo", "pid=,command="],
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )
    if result.returncode != 0:
        raise AssertionError(f"ps failed: {result.stderr}")
    pids: list[int] = []
    for line in result.stdout.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        pid_text, _, command = stripped.partition(" ")
        if (
            " hooks codex monitor " in f" {command} "
            and f"--session {session_id}" in command
        ):
            pids.append(int(pid_text))
    return pids


def wait_for_monitor_pids(session_id: str, *, present: bool, timeout: float) -> list[int]:
    deadline = time.monotonic() + timeout
    last: list[int] = []
    while time.monotonic() < deadline:
        last = monitor_pids_for_session(session_id)
        if bool(last) is present:
            return last
        time.sleep(0.1)
    state = "start" if present else "exit"
    raise AssertionError(f"monitor for {session_id} did not {state}; last pids={last}")


def assert_monitor_remains_present(session_id: str, *, duration: float) -> None:
    deadline = time.monotonic() + duration
    while time.monotonic() < deadline:
        if not monitor_pids_for_session(session_id):
            raise AssertionError("turn-less Stop reaped a session-wide monitor")
        time.sleep(0.1)


def test_codex_stop_reaps_transcript_monitor(cli_path: str, root: Path) -> None:
    socket_path = root / "cmux-monitor.sock"
    state_dir = root / "hook-state"
    transcript_path = root / "codex-session.jsonl"
    state_dir.mkdir()
    transcript_path.write_text("", encoding="utf-8")

    session_id = f"codex-monitor-reap-session-{os.getpid()}"
    turn_id = f"codex-monitor-reap-turn-{os.getpid()}"
    env = os.environ.copy()
    env["CMUX_SOCKET_PATH"] = str(socket_path)
    env["CMUX_SURFACE_ID"] = FAKE_SURFACE_ID
    env["CMUX_WORKSPACE_ID"] = FAKE_WORKSPACE_ID
    env["CMUX_AGENT_HOOK_STATE_DIR"] = str(state_dir)

    with FakeCmuxSocket(socket_path, None):
        prompt = {
            "session_id": session_id,
            "turn_id": turn_id,
            "cwd": str(root),
            "transcript_path": str(transcript_path),
        }
        result = subprocess.run(
            [cli_path, "--socket", str(socket_path), "hooks", "codex", "prompt-submit"],
            input=json.dumps(prompt),
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=10,
        )
        if result.returncode != 0:
            raise AssertionError(
                f"hooks codex prompt-submit failed exit={result.returncode}\n"
                f"stdout={result.stdout}\nstderr={result.stderr}"
            )

        pids = wait_for_monitor_pids(session_id, present=True, timeout=5)
        stop = {
            "session_id": session_id,
            "turn_id": turn_id,
            "cwd": str(root),
            "transcript_path": str(transcript_path),
        }
        try:
            result = subprocess.run(
                [cli_path, "--socket", str(socket_path), "hooks", "codex", "stop"],
                input=json.dumps(stop),
                capture_output=True,
                text=True,
                check=False,
                env=env,
                timeout=10,
            )
            if result.returncode != 0:
                raise AssertionError(
                    f"hooks codex stop failed exit={result.returncode}\n"
                    f"stdout={result.stdout}\nstderr={result.stderr}"
                )
            wait_for_monitor_pids(session_id, present=False, timeout=5)
        finally:
            for pid in monitor_pids_for_session(session_id):
                subprocess.run(["/bin/kill", str(pid)], check=False)


def test_codex_stop_without_turn_keeps_session_wide_monitor(cli_path: str, root: Path) -> None:
    socket_path = root / "cmux-monitor-session-wide.sock"
    state_dir = root / "hook-state-session-wide"
    transcript_path = root / "codex-session-wide.jsonl"
    state_dir.mkdir()
    transcript_path.write_text("", encoding="utf-8")

    session_id = f"codex-monitor-session-wide-session-{os.getpid()}"
    env = os.environ.copy()
    env["CMUX_SOCKET_PATH"] = str(socket_path)
    env["CMUX_SURFACE_ID"] = FAKE_SURFACE_ID
    env["CMUX_WORKSPACE_ID"] = FAKE_WORKSPACE_ID
    env["CMUX_AGENT_HOOK_STATE_DIR"] = str(state_dir)

    with FakeCmuxSocket(socket_path, None):
        try:
            prompt = {
                "session_id": session_id,
                "cwd": str(root),
                "transcript_path": str(transcript_path),
            }
            result = subprocess.run(
                [cli_path, "--socket", str(socket_path), "hooks", "codex", "prompt-submit"],
                input=json.dumps(prompt),
                capture_output=True,
                text=True,
                check=False,
                env=env,
                timeout=10,
            )
            if result.returncode != 0:
                raise AssertionError(
                    f"hooks codex prompt-submit failed exit={result.returncode}\n"
                    f"stdout={result.stdout}\nstderr={result.stderr}"
                )

            wait_for_monitor_pids(session_id, present=True, timeout=5)
            stop = {
                "session_id": session_id,
                "cwd": str(root),
                "transcript_path": str(transcript_path),
            }
            result = subprocess.run(
                [cli_path, "--socket", str(socket_path), "hooks", "codex", "stop"],
                input=json.dumps(stop),
                capture_output=True,
                text=True,
                check=False,
                env=env,
                timeout=10,
            )
            if result.returncode != 0:
                raise AssertionError(
                    f"hooks codex stop failed exit={result.returncode}\n"
                    f"stdout={result.stdout}\nstderr={result.stderr}"
                )
            assert_monitor_remains_present(session_id, duration=1.0)

            result = subprocess.run(
                [cli_path, "--socket", str(socket_path), "hooks", "codex", "session-end"],
                input=json.dumps(stop),
                capture_output=True,
                text=True,
                check=False,
                env=env,
                timeout=10,
            )
            if result.returncode != 0:
                raise AssertionError(
                    f"hooks codex session-end failed exit={result.returncode}\n"
                    f"stdout={result.stdout}\nstderr={result.stderr}"
                )
            wait_for_monitor_pids(session_id, present=False, timeout=5)
        finally:
            for pid in monitor_pids_for_session(session_id):
                subprocess.run(["/bin/kill", str(pid)], check=False)


def test_codex_prompt_submit_starts_monitor_when_lease_write_fails(cli_path: str, root: Path) -> None:
    socket_path = root / "cmux-monitor-lease-failure.sock"
    transcript_path = root / "codex-session-lease-failure.jsonl"
    bad_state_dir = root / "hook-state-file"
    bad_state_dir.write_text("not a directory", encoding="utf-8")
    transcript_path.write_text("", encoding="utf-8")

    session_id = f"codex-monitor-lease-failure-session-{os.getpid()}"
    turn_id = f"codex-monitor-lease-failure-turn-{os.getpid()}"
    env = os.environ.copy()
    env["CMUX_SOCKET_PATH"] = str(socket_path)
    env["CMUX_SURFACE_ID"] = FAKE_SURFACE_ID
    env["CMUX_WORKSPACE_ID"] = FAKE_WORKSPACE_ID
    env["CMUX_AGENT_HOOK_STATE_DIR"] = str(bad_state_dir)

    with FakeCmuxSocket(socket_path, None):
        try:
            prompt = {
                "session_id": session_id,
                "turn_id": turn_id,
                "cwd": str(root),
                "transcript_path": str(transcript_path),
            }
            result = subprocess.run(
                [cli_path, "--socket", str(socket_path), "hooks", "codex", "prompt-submit"],
                input=json.dumps(prompt),
                capture_output=True,
                text=True,
                check=False,
                env=env,
                timeout=10,
            )
            if result.returncode != 0:
                raise AssertionError(
                    f"hooks codex prompt-submit failed exit={result.returncode}\n"
                    f"stdout={result.stdout}\nstderr={result.stderr}"
                )
            wait_for_monitor_pids(session_id, present=True, timeout=5)
        finally:
            for pid in monitor_pids_for_session(session_id):
                subprocess.run(["/bin/kill", str(pid)], check=False)


def test_codex_monitor_exits_when_workspace_has_no_surfaces(cli_path: str, root: Path) -> None:
    socket_path = root / "cmux-monitor-empty-surfaces.sock"
    state_dir = root / "hook-state-empty-surfaces"
    transcript_path = root / "codex-session-empty-surfaces.jsonl"
    state_dir.mkdir()
    transcript_path.write_text("", encoding="utf-8")

    session_id = f"codex-monitor-empty-surfaces-session-{os.getpid()}"
    env = os.environ.copy()
    env["CMUX_SOCKET_PATH"] = str(socket_path)
    env["CMUX_WORKSPACE_ID"] = FAKE_WORKSPACE_ID
    env["CMUX_AGENT_HOOK_STATE_DIR"] = str(state_dir)

    with FakeCmuxSocket(socket_path, None, surfaces=[]) as fake:
        try:
            result = subprocess.run(
                [
                    cli_path,
                    "--socket",
                    str(socket_path),
                    "hooks",
                    "codex",
                    "monitor",
                    "--workspace",
                    FAKE_WORKSPACE_ID,
                    "--session",
                    session_id,
                    "--transcript",
                    str(transcript_path),
                ],
                capture_output=True,
                text=True,
                check=False,
                env=env,
                timeout=3,
            )
        except subprocess.TimeoutExpired as exc:
            raise AssertionError("monitor stayed alive after surface.list returned no owners") from exc
        if result.returncode != 0:
            raise AssertionError(
                f"hooks codex monitor failed exit={result.returncode}\n"
                f"stdout={result.stdout}\nstderr={result.stderr}"
            )
        if not any(frame.get("method") == "surface.list" for frame in fake.frames):
            raise AssertionError(f"monitor did not query owner surfaces: {fake.frames!r}")


def test_codex_monitor_survives_transient_owner_rpc_timeout(cli_path: str, root: Path) -> None:
    socket_path = root / "cmux-monitor-timeout.sock"
    transcript_path = root / "codex-session-timeout.jsonl"
    turn_id = f"codex-monitor-timeout-turn-{os.getpid()}"
    transcript_lines = [
        {"type": "event_msg", "payload": {"type": "task_started", "turn_id": turn_id}},
        {"type": "event_msg", "payload": {"type": "error", "turn_id": turn_id, "message": "stream disconnected"}},
        {"type": "event_msg", "payload": {"type": "turn_complete", "turn_id": turn_id}},
    ]
    transcript_path.write_text(
        "\n".join(json.dumps(line) for line in transcript_lines) + "\n",
        encoding="utf-8",
    )

    session_id = f"codex-monitor-timeout-session-{os.getpid()}"
    env = os.environ.copy()
    env["CMUX_SOCKET_PATH"] = str(socket_path)
    env["CMUX_WORKSPACE_ID"] = FAKE_WORKSPACE_ID

    with FakeCmuxSocket(socket_path, None, drop_first_surface_list=True) as fake:
        result = subprocess.run(
            [
                cli_path,
                "--socket",
                str(socket_path),
                "hooks",
                "codex",
                "monitor",
                "--workspace",
                FAKE_WORKSPACE_ID,
                "--session",
                session_id,
                "--turn",
                turn_id,
                "--transcript",
                str(transcript_path),
            ],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=5,
        )
        if result.returncode != 0:
            raise AssertionError(
                f"hooks codex monitor failed exit={result.returncode}\n"
                f"stdout={result.stdout}\nstderr={result.stderr}"
            )
        if not fake._dropped_surface_list:
            raise AssertionError(f"monitor did not exercise transient owner timeout: {fake.frames!r}")
        raw_commands = [frame.get("raw", "") for frame in fake.frames]
        if not any(command.startswith("set_status codex ") for command in raw_commands):
            raise AssertionError(f"monitor exited before publishing transcript failure: {fake.frames!r}")


def run_feed_hook(cli_path: str, socket_path: Path, payload: dict, decision: dict | None) -> tuple[dict, dict]:
    env = os.environ.copy()
    env["CMUX_SURFACE_ID"] = FAKE_SURFACE_ID
    env["CMUX_WORKSPACE_ID"] = FAKE_WORKSPACE_ID
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


def codex_command_hook_hash(
    *,
    event_label: str,
    matcher: str | None,
    command: str,
    timeout: int,
    status_message: str | None,
) -> str:
    handler: dict = {
        "async": False,
        "command": command,
        "timeout": max(timeout, 1),
        "type": "command",
    }
    if status_message is not None:
        handler["statusMessage"] = status_message
    identity: dict = {
        "event_name": event_label,
        "hooks": [handler],
    }
    if matcher is not None:
        identity["matcher"] = matcher
    canonical = json.dumps(identity, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    return f"sha256:{hashlib.sha256(canonical).hexdigest()}"


def cmux_codex_hook_command(subcommand: str) -> str:
    return (
        '[ -n "$CMUX_SURFACE_ID" ] && [ "$CMUX_CODEX_HOOKS_DISABLED" != "1" ] '
        f"&& command -v cmux >/dev/null 2>&1 && cmux hooks codex {subcommand} || echo '{{}}'"
    )


def cmux_codex_feed_command(agent_event: str) -> str:
    return (
        '[ -n "$CMUX_SURFACE_ID" ] && [ "$CMUX_CODEX_HOOKS_DISABLED" != "1" ] '
        f"&& command -v cmux >/dev/null 2>&1 && cmux hooks feed --source codex --event {agent_event} "
        "|| echo '{}'"
    )


def is_cmux_codex_hook_command(command: str) -> bool:
    hook_commands = {cmux_codex_hook_command(subcommand) for subcommand in CMUX_CODEX_HOOK_SUBCOMMANDS}
    feed_commands = {cmux_codex_feed_command(agent_event) for agent_event in CMUX_CODEX_FEED_EVENTS}
    return command in hook_commands or command in feed_commands


def toml_basic_string_unescape(value: str) -> str:
    escaped = {
        "b": "\b",
        "t": "\t",
        "n": "\n",
        "f": "\f",
        "r": "\r",
        '"': '"',
        "\\": "\\",
    }
    result: list[str] = []
    index = 0
    while index < len(value):
        char = value[index]
        if char != "\\":
            result.append(char)
            index += 1
            continue

        index += 1
        if index >= len(value):
            raise AssertionError(f"trailing TOML escape in {value!r}")
        escape = value[index]
        if escape in escaped:
            result.append(escaped[escape])
            index += 1
        elif escape in {"u", "U"}:
            width = 4 if escape == "u" else 8
            start = index + 1
            end = start + width
            hex_value = value[start:end]
            if len(hex_value) != width:
                raise AssertionError(f"short TOML unicode escape in {value!r}")
            result.append(chr(int(hex_value, 16)))
            index = end
        else:
            raise AssertionError(f"unsupported TOML escape \\{escape} in {value!r}")
    return "".join(result)


def codex_hook_trust_state(config_toml: str) -> dict[str, dict[str, str]]:
    state: dict[str, dict[str, str]] = {}
    current_key: str | None = None
    prefix = '[hooks.state."'
    suffix = '"]'

    for line in config_toml.splitlines():
        stripped = line.strip()
        if stripped.startswith(prefix) and stripped.endswith(suffix):
            current_key = toml_basic_string_unescape(stripped[len(prefix) : -len(suffix)])
            state[current_key] = {}
            continue
        if stripped.startswith("["):
            current_key = None
            continue
        if current_key is None:
            continue
        key, separator, raw_value = stripped.partition("=")
        if separator != "=" or key.strip() != "trusted_hash":
            continue
        value = raw_value.strip()
        if not value.startswith('"') or not value.endswith('"'):
            raise AssertionError(f"trusted_hash is not a TOML basic string: {line!r}")
        state[current_key]["trusted_hash"] = toml_basic_string_unescape(value[1:-1])

    return state


def expected_cmux_codex_hook_trust(hooks: dict, hooks_path: Path) -> dict[str, str]:
    expected: dict[str, str] = {}
    hooks_path = hooks_path.resolve()
    for event_name, groups in hooks.get("hooks", {}).items():
        event_label = CODEX_HOOK_EVENT_LABELS.get(event_name)
        if event_label is None:
            continue
        for group_index, group in enumerate(groups):
            matcher = group.get("matcher") if event_name in CODEX_HOOK_EVENTS_WITH_MATCHERS else None
            for handler_index, hook in enumerate(group.get("hooks", [])):
                command = hook.get("command", "")
                if not is_cmux_codex_hook_command(command):
                    continue
                key = f"{hooks_path}:{event_label}:{group_index}:{handler_index}"
                expected[key] = codex_command_hook_hash(
                    event_label=event_label,
                    matcher=matcher,
                    command=command,
                    timeout=int(hook.get("timeout", 600)),
                    status_message=hook.get("statusMessage"),
                )
    return expected


def codex_hook_commands(hooks: dict) -> list[str]:
    commands: list[str] = []
    for groups in hooks.get("hooks", {}).values():
        for group in groups:
            for hook in group.get("hooks", []):
                command = hook.get("command")
                if isinstance(command, str):
                    commands.append(command)
    return commands


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
    if "hooks = true" not in config_toml:
        raise AssertionError(f"hooks feature was not enabled: {config_toml!r}")
    if "codex_hooks" in config_toml:
        raise AssertionError(f"deprecated codex_hooks feature was written: {config_toml!r}")
    state = codex_hook_trust_state(config_toml)
    expected_trust = expected_cmux_codex_hook_trust(hooks, codex_home / "hooks.json")
    if not expected_trust:
        raise AssertionError(f"expected cmux Codex trust entries, got {expected_trust!r}")
    for key, trusted_hash in expected_trust.items():
        if state.get(key, {}).get("trusted_hash") != trusted_hash:
            raise AssertionError(
                f"missing trusted hash for {key}: expected {trusted_hash!r}, got state {state!r}"
            )


def test_install_escapes_codex_hook_trust_state_keys(cli_path: str, root: Path) -> None:
    codex_home = root / "codex-home\twith\ncontrols"
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
    config_toml = (codex_home / "config.toml").read_text(encoding="utf-8")
    state = codex_hook_trust_state(config_toml)
    expected_trust = expected_cmux_codex_hook_trust(hooks, codex_home / "hooks.json")
    if not expected_trust:
        raise AssertionError(f"expected cmux Codex trust entries, got {expected_trust!r}")
    for key, trusted_hash in expected_trust.items():
        if state.get(key, {}).get("trusted_hash") != trusted_hash:
            raise AssertionError(
                f"missing escaped-key trusted hash for {key}: expected {trusted_hash!r}, got state {state!r}"
            )


def test_install_preserves_codex_hook_position_with_third_party_hooks(cli_path: str, root: Path) -> None:
    codex_home = root / "codex-home-third-party"
    codex_home.mkdir()
    cmux_pre_tool = (
        '[ -n "$CMUX_SURFACE_ID" ] && [ "$CMUX_CODEX_HOOKS_DISABLED" != "1" ] '
        "&& command -v cmux >/dev/null 2>&1 && cmux hooks feed --source codex --event PreToolUse || echo '{}'"
    )
    orca_hook = (
        "if [ -x '/Users/lawrence/Library/Application Support/orca/agent-hooks/codex-hook.sh' ]; "
        "then /bin/sh '/Users/lawrence/Library/Application Support/orca/agent-hooks/codex-hook.sh'; fi"
    )
    (codex_home / "hooks.json").write_text(
        json.dumps(
            {
                "hooks": {
                    "PreToolUse": [
                        {"hooks": [{"type": "command", "command": cmux_pre_tool, "timeout": 120000}]},
                        {"hooks": [{"type": "command", "command": orca_hook}]},
                    ]
                }
            },
            indent=2,
        ),
        encoding="utf-8",
    )
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
    groups = hooks["hooks"]["PreToolUse"]
    first_command = groups[0]["hooks"][0]["command"]
    second_command = groups[1]["hooks"][0]["command"]
    if "cmux hooks feed --source codex --event PreToolUse" not in first_command:
        raise AssertionError(f"cmux hook did not keep its existing position: {groups!r}")
    if second_command != orca_hook:
        raise AssertionError(f"third-party hook was not preserved after cmux hook: {groups!r}")


def test_install_preserves_each_codex_hook_position_with_interleaved_third_party_hooks(
    cli_path: str, root: Path
) -> None:
    codex_home = root / "codex-home-interleaved"
    codex_home.mkdir()
    cmux_pre_tool = cmux_codex_feed_command("PreToolUse")
    user_hook_before = "printf before"
    user_hook_middle = "printf middle"
    user_hook_after = "printf after"
    (codex_home / "hooks.json").write_text(
        json.dumps(
            {
                "hooks": {
                    "PreToolUse": [
                        {"hooks": [{"type": "command", "command": user_hook_before}]},
                        {"hooks": [{"type": "command", "command": cmux_pre_tool, "timeout": 120000}]},
                        {"hooks": [{"type": "command", "command": user_hook_middle}]},
                        {"hooks": [{"type": "command", "command": cmux_pre_tool, "timeout": 120000}]},
                        {"hooks": [{"type": "command", "command": user_hook_after}]},
                    ]
                }
            },
            indent=2,
        ),
        encoding="utf-8",
    )
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
    commands = [group["hooks"][0]["command"] for group in hooks["hooks"]["PreToolUse"]]
    expected = [
        user_hook_before,
        cmux_pre_tool,
        user_hook_middle,
        cmux_pre_tool,
        user_hook_after,
    ]
    if commands != expected:
        raise AssertionError(f"interleaved cmux hook positions changed: {commands!r}")


def test_install_collapses_consecutive_codex_hook_positions(cli_path: str, root: Path) -> None:
    codex_home = root / "codex-home-consecutive"
    codex_home.mkdir()
    cmux_pre_tool = cmux_codex_feed_command("PreToolUse")
    user_hook_before = "printf before"
    user_hook_after = "printf after"
    (codex_home / "hooks.json").write_text(
        json.dumps(
            {
                "hooks": {
                    "PreToolUse": [
                        {"hooks": [{"type": "command", "command": user_hook_before}]},
                        {"hooks": [{"type": "command", "command": cmux_pre_tool, "timeout": 120000}]},
                        {"hooks": [{"type": "command", "command": cmux_pre_tool, "timeout": 120000}]},
                        {"hooks": [{"type": "command", "command": user_hook_after}]},
                    ]
                }
            },
            indent=2,
        ),
        encoding="utf-8",
    )
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
    commands = [group["hooks"][0]["command"] for group in hooks["hooks"]["PreToolUse"]]
    expected = [
        user_hook_before,
        cmux_pre_tool,
        user_hook_after,
    ]
    if commands != expected:
        raise AssertionError(f"consecutive cmux hooks were not collapsed: {commands!r}")


def test_install_replaces_legacy_codex_hook_commands(cli_path: str, root: Path) -> None:
    codex_home = root / "codex-home-legacy-hooks"
    codex_home.mkdir()
    (codex_home / "hooks.json").write_text(
        json.dumps(
            {
                "hooks": {
                    "Stop": [
                        {"hooks": [{"type": "command", "command": "cmux codex-hook stop"}]},
                    ],
                    "PreToolUse": [
                        {
                            "hooks": [
                                {
                                    "type": "command",
                                    "command": "cmux feed-hook --source codex --event PreToolUse",
                                }
                            ]
                        },
                    ],
                }
            },
            indent=2,
        ),
        encoding="utf-8",
    )
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
    commands = codex_hook_commands(hooks)
    if any("cmux codex-hook" in command or "cmux feed-hook --source" in command for command in commands):
        raise AssertionError(f"legacy cmux hook commands were not removed: {commands!r}")
    if cmux_codex_hook_command("stop") not in commands:
        raise AssertionError(f"current Stop hook was not installed: {commands!r}")
    if cmux_codex_feed_command("PreToolUse") not in commands:
        raise AssertionError(f"current PreToolUse feed hook was not installed: {commands!r}")


def test_install_migrates_legacy_codex_hooks_feature(cli_path: str, root: Path) -> None:
    codex_home = root / "codex-home-legacy"
    codex_home.mkdir()
    # Real configs can contain both names after users tried the old and new flags.
    (codex_home / "config.toml").write_text(
        "[features]\napps = true\ncodex_hooks = false\nhooks = false\n",
        encoding="utf-8",
    )
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

    config_toml = (codex_home / "config.toml").read_text(encoding="utf-8")
    if "codex_hooks" in config_toml:
        raise AssertionError(f"deprecated codex_hooks feature was preserved: {config_toml!r}")
    if "hooks = true" not in config_toml:
        raise AssertionError(f"hooks feature was not enabled: {config_toml!r}")
    if "apps = true" not in config_toml:
        raise AssertionError(f"existing feature setting was not preserved: {config_toml!r}")


def test_install_migrates_dotted_codex_hooks_feature(cli_path: str, root: Path) -> None:
    codex_home = root / "codex-home-dotted-legacy"
    codex_home.mkdir()
    (codex_home / "config.toml").write_text(
        "features.apps = true\nfeatures.codex_hooks = false\nfeatures.hooks = false\n",
        encoding="utf-8",
    )
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

    config_toml = (codex_home / "config.toml").read_text(encoding="utf-8")
    if "features.codex_hooks" in config_toml or "[features]" in config_toml:
        raise AssertionError(f"dotted legacy config was rewritten incorrectly: {config_toml!r}")
    if "features.hooks = true" not in config_toml:
        raise AssertionError(f"dotted hooks feature was not enabled: {config_toml!r}")
    if "features.apps = true" not in config_toml:
        raise AssertionError(f"existing dotted feature setting was not preserved: {config_toml!r}")


def test_uninstall_preserves_existing_codex_hooks_feature(cli_path: str, root: Path) -> None:
    codex_home = root / "codex-home-uninstall-existing"
    codex_home.mkdir()
    (codex_home / "config.toml").write_text(
        "[features]\napps = true\nhooks = true\n",
        encoding="utf-8",
    )
    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)

    for action in ["install", "uninstall"]:
        result = subprocess.run(
            [cli_path, "hooks", "codex", action, "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=20,
        )
        if result.returncode != 0:
            raise AssertionError(
                f"hooks codex {action} failed exit={result.returncode}\nstdout={result.stdout}\nstderr={result.stderr}"
            )

    config_toml = (codex_home / "config.toml").read_text(encoding="utf-8")
    if "hooks = true" not in config_toml:
        raise AssertionError(f"pre-existing hooks feature was removed: {config_toml!r}")
    if "apps = true" not in config_toml:
        raise AssertionError(f"existing feature setting was not preserved: {config_toml!r}")


def test_install_codex_hooks_only_edits_real_features_table(cli_path: str, root: Path) -> None:
    codex_home = root / "codex-home-real-features"
    codex_home.mkdir()
    config_path = codex_home / "config.toml"
    config_path.write_text(
        "\n".join(
            [
                "# See [features] in the documentation.",
                'note = "literal [features] mention"',
                "",
                "[features]",
                "existing = true",
                "",
            ]
        ),
        encoding="utf-8",
    )
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

    config_toml = config_path.read_text(encoding="utf-8")
    if config_toml.count("hooks = true") != 1:
        raise AssertionError(f"hooks should be inserted exactly once: {config_toml!r}")
    if "codex_hooks" in config_toml:
        raise AssertionError(f"deprecated codex_hooks feature was written: {config_toml!r}")
    if "# See [features] in the documentation." not in config_toml:
        raise AssertionError(f"comment with [features] was corrupted: {config_toml!r}")
    if 'note = "literal [features] mention"' not in config_toml:
        raise AssertionError(f"string literal with [features] was corrupted: {config_toml!r}")

    lines = config_toml.splitlines()
    features_index = lines.index("[features]")
    if lines[features_index + 1] != "# cmux-codex-hooks-feature-78f1e4ba-66df-4d35-93c1-67fdf1cbb7df begin":
        raise AssertionError(f"cmux marker should be inserted into [features]: {config_toml!r}")
    if lines[features_index + 2] != "hooks = true":
        raise AssertionError(f"hooks should be inserted into [features]: {config_toml!r}")


def test_uninstall_codex_hooks_removes_empty_features_table_from_install(cli_path: str, root: Path) -> None:
    codex_home = root / "codex-home-empty-features-uninstall"
    codex_home.mkdir()
    config_path = codex_home / "config.toml"
    original_config = 'model = "gpt-5.1-codex"\n'
    config_path.write_text(original_config, encoding="utf-8")
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

    installed_config = config_path.read_text(encoding="utf-8")
    if "[features]" not in installed_config or "hooks = true" not in installed_config:
        raise AssertionError(f"install should add the hooks feature table: {installed_config!r}")
    if "codex_hooks" in installed_config:
        raise AssertionError(f"install should not add deprecated codex_hooks: {installed_config!r}")

    result = subprocess.run(
        [cli_path, "hooks", "codex", "uninstall", "--yes"],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=20,
    )
    if result.returncode != 0:
        raise AssertionError(
            f"hooks codex uninstall failed exit={result.returncode}\nstdout={result.stdout}\nstderr={result.stderr}"
        )

    config_toml = config_path.read_text(encoding="utf-8")
    if config_toml != original_config:
        raise AssertionError(f"uninstall should remove the empty [features] table: {config_toml!r}")

def test_uninstall_restores_disabled_codex_hooks_feature(cli_path: str, root: Path) -> None:
    codex_home = root / "codex-home-uninstall-disabled"
    codex_home.mkdir()
    (codex_home / "config.toml").write_text(
        "[features]\napps = true\nhooks = false\n",
        encoding="utf-8",
    )
    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)

    for action in ["install", "uninstall"]:
        result = subprocess.run(
            [cli_path, "hooks", "codex", action, "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=20,
        )
        if result.returncode != 0:
            raise AssertionError(
                f"hooks codex {action} failed exit={result.returncode}\nstdout={result.stdout}\nstderr={result.stderr}"
            )

    config_toml = (codex_home / "config.toml").read_text(encoding="utf-8")
    if "hooks = false" not in config_toml:
        raise AssertionError(f"pre-existing disabled hooks feature was not restored: {config_toml!r}")
    if "hooks = true" in config_toml:
        raise AssertionError(f"cmux-owned hooks feature was not removed: {config_toml!r}")
    if "apps = true" not in config_toml:
        raise AssertionError(f"existing feature setting was not preserved: {config_toml!r}")


def test_uninstall_restores_disabled_dotted_codex_hooks_feature(cli_path: str, root: Path) -> None:
    codex_home = root / "codex-home-uninstall-dotted-disabled"
    codex_home.mkdir()
    (codex_home / "config.toml").write_text(
        "features.apps = true\nfeatures.hooks = false\n",
        encoding="utf-8",
    )
    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)

    for action in ["install", "uninstall"]:
        result = subprocess.run(
            [cli_path, "hooks", "codex", action, "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=20,
        )
        if result.returncode != 0:
            raise AssertionError(
                f"hooks codex {action} failed exit={result.returncode}\nstdout={result.stdout}\nstderr={result.stderr}"
            )

    config_toml = (codex_home / "config.toml").read_text(encoding="utf-8")
    if "features.hooks = false" not in config_toml:
        raise AssertionError(f"pre-existing disabled dotted hooks feature was not restored: {config_toml!r}")
    if "features.hooks = true" in config_toml:
        raise AssertionError(f"cmux-owned dotted hooks feature was not removed: {config_toml!r}")
    if "features.apps = true" not in config_toml:
        raise AssertionError(f"existing dotted feature setting was not preserved: {config_toml!r}")


def test_install_scans_features_past_bracketed_array(cli_path: str, root: Path) -> None:
    codex_home = root / "codex-home-bracketed-array"
    codex_home.mkdir()
    (codex_home / "config.toml").write_text(
        "[features]\napps = [\n  [1, 2],\n]\nhooks = false\n",
        encoding="utf-8",
    )
    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)

    for action in ["install", "uninstall"]:
        result = subprocess.run(
            [cli_path, "hooks", "codex", action, "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=20,
        )
        if result.returncode != 0:
            raise AssertionError(
                f"hooks codex {action} failed exit={result.returncode}\nstdout={result.stdout}\nstderr={result.stderr}"
            )
        config_toml = (codex_home / "config.toml").read_text(encoding="utf-8")
        if action == "install" and config_toml.count("hooks = true") != 1:
            raise AssertionError(f"install wrote duplicate hooks settings: {config_toml!r}")

    config_toml = (codex_home / "config.toml").read_text(encoding="utf-8")
    if "hooks = false" not in config_toml or "hooks = true" in config_toml:
        raise AssertionError(f"uninstall did not restore hooks after bracketed array: {config_toml!r}")
    if "[1, 2]" not in config_toml:
        raise AssertionError(f"bracketed array content was not preserved: {config_toml!r}")


def test_uninstall_removes_cmux_owned_codex_hooks_feature(cli_path: str, root: Path) -> None:
    codex_home = root / "codex-home-uninstall-owned"
    codex_home.mkdir()
    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)

    for action in ["install", "uninstall"]:
        result = subprocess.run(
            [cli_path, "hooks", "codex", action, "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=20,
        )
        if result.returncode != 0:
            raise AssertionError(
                f"hooks codex {action} failed exit={result.returncode}\nstdout={result.stdout}\nstderr={result.stderr}"
            )

    config_toml = (codex_home / "config.toml").read_text(encoding="utf-8")
    if "hooks = true" in config_toml or "codex_hooks" in config_toml:
        raise AssertionError(f"cmux-owned hooks feature was not removed: {config_toml!r}")
    if "hooks.state" in config_toml or "trusted_hash" in config_toml:
        raise AssertionError(f"cmux-owned hook trust was not removed: {config_toml!r}")
    if "[features]" in config_toml:
        raise AssertionError(f"empty features table was preserved: {config_toml!r}")


def test_uninstall_preserves_unowned_hook_trust_when_cmux_marker_is_unclosed(
    cli_path: str, root: Path
) -> None:
    codex_home = root / "codex-home-unclosed-trust"
    codex_home.mkdir()
    (codex_home / "hooks.json").write_text('{"hooks": {}}\n', encoding="utf-8")
    (codex_home / "config.toml").write_text(
        "[features]\n"
        "hooks = true\n"
        "# cmux-codex-hook-trust-f5cc24da-7a09-4b20-a756-89e7786f6738 begin\n"
        "[hooks.state.\"/tmp/cmux/hooks.json:pre_tool_use:0:0\"]\n"
        'trusted_hash = "sha256:cmux"\n'
        "[hooks.state.\"/tmp/third-party/hooks.json:pre_tool_use:0:0\"]\n"
        'trusted_hash = "sha256:third-party"\n',
        encoding="utf-8",
    )
    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)

    result = subprocess.run(
        [cli_path, "hooks", "codex", "uninstall", "--yes"],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=20,
    )
    if result.returncode != 0:
        raise AssertionError(
            f"hooks codex uninstall failed exit={result.returncode}\nstdout={result.stdout}\nstderr={result.stderr}"
        )

    config_toml = (codex_home / "config.toml").read_text(encoding="utf-8")
    if "# cmux-codex-hook-trust-f5cc24da-7a09-4b20-a756-89e7786f6738 begin" in config_toml:
        raise AssertionError(f"orphaned cmux hook trust marker was preserved: {config_toml!r}")
    if 'trusted_hash = "sha256:third-party"' not in config_toml:
        raise AssertionError(f"unowned hook trust was removed: {config_toml!r}")


def test_install_recovers_hook_trust_when_cmux_marker_is_unclosed(
    cli_path: str, root: Path
) -> None:
    codex_home = root / "codex-home-unclosed-trust-install"
    codex_home.mkdir()
    stale_key = f"{(codex_home / 'hooks.json').resolve()}:pre_tool_use:0:0"
    (codex_home / "config.toml").write_text(
        "[features]\n"
        "hooks = true\n"
        "# cmux-codex-hook-trust-f5cc24da-7a09-4b20-a756-89e7786f6738 begin\n"
        f'[hooks.state."{stale_key}"]\n'
        'trusted_hash = "sha256:stale"\n',
        encoding="utf-8",
    )
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

    config_toml = (codex_home / "config.toml").read_text(encoding="utf-8")
    if "approved cmux hooks" not in result.stdout:
        raise AssertionError(f"install did not report recovered hook trust approval: {result.stdout!r}")
    if config_toml.count("# cmux-codex-hook-trust-f5cc24da-7a09-4b20-a756-89e7786f6738 begin") != 1:
        raise AssertionError(f"install did not write one fresh cmux hook trust marker: {config_toml!r}")
    if config_toml.count("# cmux-codex-hook-trust-f5cc24da-7a09-4b20-a756-89e7786f6738 end") != 1:
        raise AssertionError(f"install did not close the recovered hook trust block: {config_toml!r}")
    if 'trusted_hash = "sha256:stale"' in config_toml:
        raise AssertionError(f"install preserved stale cmux hook trust: {config_toml!r}")
    hooks = json.loads((codex_home / "hooks.json").read_text(encoding="utf-8"))
    state = codex_hook_trust_state(config_toml)
    expected_trust = expected_cmux_codex_hook_trust(hooks, codex_home / "hooks.json")
    for key, trusted_hash in expected_trust.items():
        if state.get(key, {}).get("trusted_hash") != trusted_hash:
            raise AssertionError(
                f"missing recovered trusted hash for {key}: expected {trusted_hash!r}, got state {state!r}"
            )


def test_uninstall_codex_hooks_removes_legacy_managed_block(cli_path: str, root: Path) -> None:
    codex_home = root / "codex-home-legacy-uninstall"
    codex_home.mkdir()
    (codex_home / "hooks.json").write_text('{"hooks": {}}\n', encoding="utf-8")
    config_path = codex_home / "config.toml"
    config_path.write_text(
        "\n".join(
            [
                "[features]",
                "apps = true",
                "# cmux-codex-hooks-feature-78f1e4ba-66df-4d35-93c1-67fdf1cbb7df begin",
                "# cmux-codex-hooks-feature-78f1e4ba-66df-4d35-93c1-67fdf1cbb7df previous line: hooks = false",
                "hooks = true",
                "# cmux-codex-hooks-feature-78f1e4ba-66df-4d35-93c1-67fdf1cbb7df end",
                "# cmux hooks codex feature begin",
                "# cmux hooks codex feature previous line: features.hooks = false",
                "features.hooks = true",
                "# cmux hooks codex feature end",
                "",
            ]
        ),
        encoding="utf-8",
    )
    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)

    result = subprocess.run(
        [cli_path, "hooks", "codex", "uninstall", "--yes"],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=20,
    )
    if result.returncode != 0:
        raise AssertionError(
            f"hooks codex uninstall failed exit={result.returncode}\nstdout={result.stdout}\nstderr={result.stderr}"
        )

    config_toml = config_path.read_text(encoding="utf-8")
    if "cmux-codex-hooks-feature" in config_toml:
        raise AssertionError(f"legacy managed markers were not removed: {config_toml!r}")
    if "cmux hooks codex feature" in config_toml:
        raise AssertionError(f"old legacy managed markers were not removed: {config_toml!r}")
    if "hooks = true" in config_toml:
        raise AssertionError(f"cmux-owned legacy hooks setting was not removed: {config_toml!r}")
    if "hooks = false" not in config_toml:
        raise AssertionError(f"previous hooks setting was not restored: {config_toml!r}")
    if "features.hooks = false" not in config_toml:
        raise AssertionError(f"previous dotted hooks setting was not restored: {config_toml!r}")
    if "apps = true" not in config_toml:
        raise AssertionError(f"existing feature setting was not preserved: {config_toml!r}")


def test_install_surfaces_invalid_codex_config_encoding(cli_path: str, root: Path) -> None:
    codex_home = root / "codex-home-invalid-install-config"
    codex_home.mkdir()
    config_path = codex_home / "config.toml"
    invalid_bytes = b"\xff"
    config_path.write_bytes(invalid_bytes)
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
    if result.returncode == 0:
        raise AssertionError("hooks codex install unexpectedly succeeded with invalid config encoding")
    if config_path.read_bytes() != invalid_bytes:
        raise AssertionError("hooks codex install overwrote unreadable config content")


def test_uninstall_surfaces_invalid_codex_config_encoding(cli_path: str, root: Path) -> None:
    codex_home = root / "codex-home-invalid-uninstall-config"
    codex_home.mkdir()
    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)

    install_result = subprocess.run(
        [cli_path, "hooks", "codex", "install", "--yes"],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=20,
    )
    if install_result.returncode != 0:
        raise AssertionError(
            "initial hooks codex install failed "
            f"exit={install_result.returncode}\nstdout={install_result.stdout}\nstderr={install_result.stderr}"
        )

    config_path = codex_home / "config.toml"
    invalid_bytes = b"\xff"
    config_path.write_bytes(invalid_bytes)

    result = subprocess.run(
        [cli_path, "hooks", "codex", "uninstall", "--yes"],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=20,
    )
    if result.returncode == 0:
        raise AssertionError("hooks codex uninstall unexpectedly succeeded with invalid config encoding")
    if config_path.read_bytes() != invalid_bytes:
        raise AssertionError("hooks codex uninstall overwrote unreadable config content")


def test_install_codex_hooks_preserves_config_when_toml_read_fails(cli_path: str, root: Path) -> None:
    codex_home = root / "codex-home-toml-read-fails"
    codex_home.mkdir()
    config_path = codex_home / "config.toml"
    original_bytes = b'model = "safe"\ninvalid_utf8 = "\xff"\n'
    config_path.write_bytes(original_bytes)

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
    if result.returncode == 0:
        raise AssertionError(
            "hooks codex install should fail when existing config.toml cannot be read as UTF-8"
        )
    if config_path.read_bytes() != original_bytes:
        raise AssertionError(
            "hooks codex install should not overwrite config.toml after a read failure"
        )


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
            test_codex_stop_reaps_transcript_monitor(cli_path, root)
            test_codex_stop_without_turn_keeps_session_wide_monitor(cli_path, root)
            test_codex_prompt_submit_starts_monitor_when_lease_write_fails(cli_path, root)
            test_codex_monitor_exits_when_workspace_has_no_surfaces(cli_path, root)
            test_codex_monitor_survives_transient_owner_rpc_timeout(cli_path, root)
            test_install_adds_codex_permission_request_hook(cli_path, root)
            test_install_escapes_codex_hook_trust_state_keys(cli_path, root)
            test_install_preserves_codex_hook_position_with_third_party_hooks(cli_path, root)
            test_install_preserves_each_codex_hook_position_with_interleaved_third_party_hooks(cli_path, root)
            test_install_collapses_consecutive_codex_hook_positions(cli_path, root)
            test_install_replaces_legacy_codex_hook_commands(cli_path, root)
            test_install_migrates_legacy_codex_hooks_feature(cli_path, root)
            test_install_migrates_dotted_codex_hooks_feature(cli_path, root)
            test_uninstall_preserves_existing_codex_hooks_feature(cli_path, root)
            test_install_codex_hooks_only_edits_real_features_table(cli_path, root)
            test_uninstall_codex_hooks_removes_empty_features_table_from_install(cli_path, root)
            test_uninstall_restores_disabled_codex_hooks_feature(cli_path, root)
            test_uninstall_restores_disabled_dotted_codex_hooks_feature(cli_path, root)
            test_install_scans_features_past_bracketed_array(cli_path, root)
            test_uninstall_removes_cmux_owned_codex_hooks_feature(cli_path, root)
            test_uninstall_preserves_unowned_hook_trust_when_cmux_marker_is_unclosed(cli_path, root)
            test_install_recovers_hook_trust_when_cmux_marker_is_unclosed(cli_path, root)
            test_uninstall_codex_hooks_removes_legacy_managed_block(cli_path, root)
            test_install_surfaces_invalid_codex_config_encoding(cli_path, root)
            test_uninstall_surfaces_invalid_codex_config_encoding(cli_path, root)
            test_install_codex_hooks_preserves_config_when_toml_read_fails(cli_path, root)
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
