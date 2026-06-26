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
    "SubagentStart": "subagent_start",
    "SubagentStop": "subagent_stop",
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
    "SubagentStart",
    "SubagentStop",
}

CMUX_CODEX_HOOK_SUBCOMMANDS = (
    "session-start",
    "prompt-submit",
    "stop",
)

CMUX_CODEX_FEED_EVENTS = (
    "PreToolUse",
    "PermissionRequest",
    "PostToolUse",
    "PreCompact",
    "PostCompact",
    "SubagentStart",
    "SubagentStop",
)

FAKE_WORKSPACE_ID = "11111111-1111-1111-1111-111111111111"
FAKE_SURFACE_ID = "22222222-2222-2222-2222-222222222222"


def _toml_has_line(content: str, line: str) -> bool:
    return any(raw.strip() == line for raw in content.splitlines())


def _toml_line_count(content: str, line: str) -> int:
    return sum(1 for raw in content.splitlines() if raw.strip() == line)


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
            wait_for_monitor_pids(session_id, present=False, timeout=30)
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
    state_dir = root / "hook-state-lease-failure"
    state_dir.mkdir()
    (state_dir / "codex-monitor-leases").write_text("not a directory", encoding="utf-8")
    transcript_path.write_text("", encoding="utf-8")

    session_id = f"codex-monitor-lease-failure-session-{os.getpid()}"
    turn_id = f"codex-monitor-lease-failure-turn-{os.getpid()}"
    env = os.environ.copy()
    env["CMUX_SOCKET_PATH"] = str(socket_path)
    env["CMUX_SURFACE_ID"] = FAKE_SURFACE_ID
    env["CMUX_WORKSPACE_ID"] = FAKE_WORKSPACE_ID
    env["CMUX_AGENT_HOOK_STATE_DIR"] = str(state_dir)

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


def run_feed_hook_optional_frame(
    cli_path: str,
    socket_path: Path,
    payload: dict,
    decision: dict | None,
    source: str = "codex",
) -> tuple[dict, dict | None]:
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
                source,
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
        stdout = json.loads(result.stdout.strip() or "{}")
        return stdout, fake.frames[0] if fake.frames else None


def run_feed_hook(
    cli_path: str,
    socket_path: Path,
    payload: dict,
    decision: dict | None,
    source: str = "codex",
) -> tuple[dict, dict]:
    stdout, frame = run_feed_hook_optional_frame(cli_path, socket_path, payload, decision, source)
    if frame is None:
        raise AssertionError("hooks feed did not send feed.push")
    return stdout, frame


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
    routed_arguments = f"hooks codex {subcommand}"
    return (
        'cmux_cli="${CMUX_BUNDLED_CLI_PATH:-}"; if [ -z "$cmux_cli" ] || [ ! -x "$cmux_cli" ]; '
        'then cmux_cli="$(command -v cmux 2>/dev/null || true)"; fi; if [ -n "$CMUX_SURFACE_ID" ] '
        '&& [ "$CMUX_CODEX_HOOKS_DISABLED" != "1" ] && [ -n "$cmux_cli" ]; then { '
        f'if [ -n "${{CMUX_SOCKET_PATH:-}}" ]; then "$cmux_cli" --socket "$CMUX_SOCKET_PATH" {routed_arguments}; '
        f'else "$cmux_cli" {routed_arguments}; fi; '
        "} || echo '{}'; else echo '{}'; fi"
    )


def cmux_codex_feed_command(agent_event: str) -> str:
    routed_arguments = f"hooks feed --source codex --event {agent_event}"
    noop_command = "{ cat >/dev/null 2>/dev/null || true; echo '{}'; }"
    return (
        'cmux_cli="${CMUX_BUNDLED_CLI_PATH:-}"; if [ -z "$cmux_cli" ] || [ ! -x "$cmux_cli" ]; '
        'then cmux_cli="$(command -v cmux 2>/dev/null || true)"; fi; if [ -n "$CMUX_SURFACE_ID" ] '
        '&& [ "$CMUX_CODEX_HOOKS_DISABLED" != "1" ] && [ -n "$cmux_cli" ]; then { '
        f'if [ -n "${{CMUX_SOCKET_PATH:-}}" ]; then "$cmux_cli" --socket "$CMUX_SOCKET_PATH" {routed_arguments}; '
        f'else "$cmux_cli" {routed_arguments}; fi; '
        f"}} || {noop_command}; else {noop_command}; fi"
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
    for event_name in ["SessionStart", "UserPromptSubmit", "Stop"]:
        groups = hook_groups.get(event_name)
        if not groups:
            raise AssertionError(f"missing {event_name} hook group: {hooks!r}")
        if groups[-1]["hooks"][0].get("timeout") != 5:
            raise AssertionError(f"wrong {event_name} timeout: {groups[-1]!r}")
    for event_name in CMUX_CODEX_FEED_EVENTS:
        groups = hook_groups.get(event_name)
        if not groups:
            raise AssertionError(f"missing {event_name} hook group: {hooks!r}")
        command = groups[-1]["hooks"][0]["command"]
        if command != cmux_codex_feed_command(event_name):
            raise AssertionError(f"wrong {event_name} feed command: {command!r}")
        if groups[-1]["hooks"][0].get("timeout") != 5:
            raise AssertionError(f"wrong {event_name} timeout: {groups[-1]!r}")

    config_toml = (codex_home / "config.toml").read_text(encoding="utf-8")
    if not _toml_has_line(config_toml, "hooks = true"):
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
    cmux_pre_tool = cmux_codex_feed_command("PreToolUse")
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
    if first_command != cmux_pre_tool:
        raise AssertionError(f"cmux hook did not keep its existing position: {groups!r}")
    if second_command != orca_hook:
        raise AssertionError(f"third-party hook was not preserved after cmux hook: {groups!r}")


def test_install_deduplicates_interleaved_codex_hook_positions(
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
        user_hook_after,
    ]
    if commands != expected:
        raise AssertionError(f"interleaved cmux hook dedupe changed: {commands!r}")


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
    if not _toml_has_line(config_toml, "hooks = true"):
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
    if not _toml_has_line(config_toml, "features.hooks = true"):
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
    if not _toml_has_line(config_toml, "hooks = true"):
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
    if _toml_line_count(config_toml, "hooks = true") != 1:
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
    if "[features]" not in installed_config or not _toml_has_line(installed_config, "hooks = true"):
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
    if not _toml_has_line(config_toml, "hooks = false"):
        raise AssertionError(f"pre-existing disabled hooks feature was not restored: {config_toml!r}")
    if _toml_has_line(config_toml, "hooks = true"):
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
    if not _toml_has_line(config_toml, "features.hooks = false"):
        raise AssertionError(f"pre-existing disabled dotted hooks feature was not restored: {config_toml!r}")
    if _toml_has_line(config_toml, "features.hooks = true"):
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
        if action == "install" and _toml_line_count(config_toml, "hooks = true") != 1:
            raise AssertionError(f"install wrote duplicate hooks settings: {config_toml!r}")

    config_toml = (codex_home / "config.toml").read_text(encoding="utf-8")
    if not _toml_has_line(config_toml, "hooks = false") or _toml_has_line(config_toml, "hooks = true"):
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


def test_install_preserves_plugin_tables_inside_stale_cmux_hook_trust_marker(
    cli_path: str, root: Path
) -> None:
    codex_home = root / "codex-home-stale-trust-with-plugins"
    codex_home.mkdir()
    hooks_path = codex_home / "hooks.json"
    stale_key = f"{hooks_path.resolve()}:pre_tool_use:0:0"
    stale_old_cmux_key = f"{hooks_path.resolve()}:pre_tool_use:9:0"
    stale_old_cmux_hash = codex_command_hook_hash(
        event_label="pre_tool_use",
        matcher=None,
        command=cmux_codex_feed_command("PreToolUse"),
        timeout=120_000,
        status_message=None,
    )
    stale_legacy_key = f"{hooks_path.resolve()}:pre_tool_use:10:0"
    stale_legacy_hash = codex_command_hook_hash(
        event_label="pre_tool_use",
        matcher=None,
        command="cmux feed-hook --source codex --event PreToolUse",
        timeout=120_000,
        status_message=None,
    )
    same_file_user_key = f"{hooks_path.resolve()}:pre_tool_use:8:0"
    escaped_user_key = "/tmp/third-party\\t/hooks.json:pre_tool_use:0:0"
    third_party_key = "/tmp/third-party/hooks.json:pre_tool_use:0:0"
    config_path = codex_home / "config.toml"
    config_path.write_text(
        "[features]\n"
        "hooks = true\n"
        "# cmux-codex-hook-trust-f5cc24da-7a09-4b20-a756-89e7786f6738 begin\n"
        "preserve_loose_config = true\n"
        f'[ hooks . state . "{stale_key}" ] # stale cmux trust\n'
        'trusted_hash = "sha256:stale"\n'
        "\n"
        f'[hooks.state."{escaped_user_key}"]\n'
        'trusted_hash = "sha256:escaped-user"\n'
        "\n"
        f'[hooks.state."{stale_old_cmux_key}"]\n'
        f'trusted_hash = "{stale_old_cmux_hash}"\n'
        "\n"
        f'[hooks.state."{stale_legacy_key}"]\n'
        f'trusted_hash = "{stale_legacy_hash}"\n'
        "\n"
        f'[hooks.state."{same_file_user_key}"]\n'
        'trusted_hash = "sha256:same-file-user"\n'
        "\n"
        f'[hooks.state."{third_party_key}"]\n'
        'trusted_hash = "sha256:third-party"\n'
        "\n"
        '[plugins."documents@openai-primary-runtime"]\n'
        "enabled = true\n"
        "\n"
        '[plugins."browser@openai-bundled"]\n'
        "enabled = true\n"
        "# cmux-codex-hook-trust-f5cc24da-7a09-4b20-a756-89e7786f6738 end\n",
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
    if '[plugins."documents@openai-primary-runtime"]' not in config_toml:
        raise AssertionError(f"documents plugin table was removed: {config_toml!r}")
    if '[plugins."browser@openai-bundled"]' not in config_toml:
        raise AssertionError(f"browser plugin table was removed: {config_toml!r}")
    if "preserve_loose_config = true" not in config_toml:
        raise AssertionError(f"loose config line was removed: {config_toml!r}")
    if 'trusted_hash = "sha256:third-party"' not in config_toml:
        raise AssertionError(f"third-party hook trust was removed: {config_toml!r}")
    if 'trusted_hash = "sha256:same-file-user"' not in config_toml:
        raise AssertionError(f"same-file user hook trust was removed: {config_toml!r}")
    if 'trusted_hash = "sha256:escaped-user"' not in config_toml:
        raise AssertionError(f"escaped-key user hook trust was removed: {config_toml!r}")
    if 'trusted_hash = "sha256:stale"' in config_toml:
        raise AssertionError(f"stale cmux hook trust was preserved: {config_toml!r}")
    if stale_old_cmux_key in config_toml:
        raise AssertionError(f"old cmux hook trust was preserved: {config_toml!r}")
    if stale_legacy_key in config_toml or stale_legacy_hash in config_toml:
        raise AssertionError(f"legacy cmux hook trust was preserved: {config_toml!r}")
    trust_begin = "# cmux-codex-hook-trust-f5cc24da-7a09-4b20-a756-89e7786f6738 begin"
    trust_end = "# cmux-codex-hook-trust-f5cc24da-7a09-4b20-a756-89e7786f6738 end"
    if config_toml.count(trust_begin) != 1:
        raise AssertionError(f"install did not write one fresh cmux hook trust marker: {config_toml!r}")
    if config_toml.count(trust_end) != 1:
        raise AssertionError(f"install did not close the fresh cmux trust block: {config_toml!r}")
    trust_begin_index = config_toml.index(trust_begin)
    trust_end_index = config_toml.index(trust_end)
    for plugin_header in (
        '[plugins."documents@openai-primary-runtime"]',
        '[plugins."browser@openai-bundled"]',
    ):
        plugin_index = config_toml.index(plugin_header)
        if trust_begin_index < plugin_index < trust_end_index:
            raise AssertionError(f"plugin table remained inside fresh cmux trust block: {config_toml!r}")

    hooks = json.loads(hooks_path.read_text(encoding="utf-8"))
    state = codex_hook_trust_state(config_toml)
    expected_trust = expected_cmux_codex_hook_trust(hooks, hooks_path)
    for key, trusted_hash in expected_trust.items():
        if state.get(key, {}).get("trusted_hash") != trusted_hash:
            raise AssertionError(
                f"missing fresh trusted hash for {key}: expected {trusted_hash!r}, got state {state!r}"
            )


def test_install_enables_hooks_when_stale_trust_marker_captures_dotted_feature(
    cli_path: str, root: Path
) -> None:
    codex_home = root / "codex-home-stale-trust-with-dotted-feature"
    codex_home.mkdir()
    hooks_path = codex_home / "hooks.json"
    stale_key = f"{hooks_path.resolve()}:pre_tool_use:0:0"
    config_path = codex_home / "config.toml"
    config_path.write_text(
        "# cmux-codex-hook-trust-f5cc24da-7a09-4b20-a756-89e7786f6738 begin\n"
        f'[hooks.state."{stale_key}"]\n'
        'trusted_hash = "sha256:stale"\n'
        "features.experimental = true\n"
        "# cmux-codex-hook-trust-f5cc24da-7a09-4b20-a756-89e7786f6738 end\n",
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
    if not _toml_has_line(config_toml, "hooks = true") and not _toml_has_line(config_toml, "features.hooks = true"):
        raise AssertionError(f"install did not enable Codex hooks: {config_toml!r}")
    if 'trusted_hash = "sha256:stale"' in config_toml:
        raise AssertionError(f"stale cmux hook trust was preserved: {config_toml!r}")


def test_uninstall_preserves_third_party_hook_trust_inside_cmux_marker(
    cli_path: str, root: Path
) -> None:
    codex_home = root / "codex-home-uninstall-stale-third-party-trust"
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

    config_path = codex_home / "config.toml"
    trust_end = "# cmux-codex-hook-trust-f5cc24da-7a09-4b20-a756-89e7786f6738 end"
    same_file_user_key = f"{(codex_home / 'hooks.json').resolve()}:pre_tool_use:8:0"
    third_party_key = "/tmp/third-party/hooks.json:pre_tool_use:0:0"
    config_toml = config_path.read_text(encoding="utf-8")
    config_path.write_text(
        config_toml.replace(
            trust_end,
            f'[hooks.state."{same_file_user_key}"]\n'
            'trusted_hash = "sha256:same-file-user"\n'
            f'[hooks.state."{third_party_key}"]\n'
            'trusted_hash = "sha256:third-party"\n'
            f"{trust_end}",
        ),
        encoding="utf-8",
    )

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
    if "cmux-codex-hook-trust-f5cc24da-7a09-4b20-a756-89e7786f6738" in config_toml:
        raise AssertionError(f"cmux hook trust marker was preserved: {config_toml!r}")
    state = codex_hook_trust_state(config_toml)
    for key in state:
        if key.startswith(f"{(codex_home / 'hooks.json').resolve()}:") and key != same_file_user_key:
            raise AssertionError(f"cmux hook trust was preserved: {config_toml!r}")
    if 'trusted_hash = "sha256:same-file-user"' not in config_toml:
        raise AssertionError(f"same-file user hook trust was removed: {config_toml!r}")
    if 'trusted_hash = "sha256:third-party"' not in config_toml:
        raise AssertionError(f"third-party hook trust was removed: {config_toml!r}")


def test_uninstall_retry_removes_stale_cmux_hook_trust_after_hooks_are_cleaned(
    cli_path: str, root: Path
) -> None:
    codex_home = root / "codex-home-uninstall-retry-stale-trust"
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

    hooks_path = codex_home / "hooks.json"
    hooks = json.loads(hooks_path.read_text(encoding="utf-8"))
    expected_trust = expected_cmux_codex_hook_trust(hooks, hooks_path)
    if not expected_trust:
        raise AssertionError(f"expected cmux Codex trust entries, got {expected_trust!r}")

    config_path = codex_home / "config.toml"
    trust_end = "# cmux-codex-hook-trust-f5cc24da-7a09-4b20-a756-89e7786f6738 end"
    same_file_user_key = f"{hooks_path.resolve()}:pre_tool_use:8:0"
    legacy_key = f"{hooks_path.resolve()}:pre_tool_use:9:0"
    legacy_hash = codex_command_hook_hash(
        event_label="pre_tool_use",
        matcher=None,
        command="cmux feed-hook --source codex --event PreToolUse",
        timeout=120_000,
        status_message=None,
    )
    third_party_key = "/tmp/third-party/hooks.json:pre_tool_use:0:0"
    config_toml = config_path.read_text(encoding="utf-8")
    config_path.write_text(
        config_toml.replace(
            trust_end,
            f'[hooks.state."{same_file_user_key}"]\n'
            'trusted_hash = "sha256:same-file-user"\n'
            f'[hooks.state."{legacy_key}"]\n'
            f'trusted_hash = "{legacy_hash}"\n'
            f'[hooks.state."{third_party_key}"]\n'
            'trusted_hash = "sha256:third-party"\n'
            f"{trust_end}",
        ),
        encoding="utf-8",
    )
    hooks_path.write_text('{"hooks": {}}\n', encoding="utf-8")

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
            f"hooks codex uninstall retry failed exit={result.returncode}\n"
            f"stdout={result.stdout}\nstderr={result.stderr}"
        )

    config_toml = config_path.read_text(encoding="utf-8")
    if "cmux-codex-hook-trust-f5cc24da-7a09-4b20-a756-89e7786f6738" in config_toml:
        raise AssertionError(f"cmux hook trust marker was preserved: {config_toml!r}")
    for key, trusted_hash in expected_trust.items():
        if key in config_toml or trusted_hash in config_toml:
            raise AssertionError(f"stale cmux hook trust was preserved: {config_toml!r}")
    if legacy_key in config_toml or legacy_hash in config_toml:
        raise AssertionError(f"legacy cmux hook trust was preserved: {config_toml!r}")
    if 'trusted_hash = "sha256:same-file-user"' not in config_toml:
        raise AssertionError(f"same-file user hook trust was removed: {config_toml!r}")
    if 'trusted_hash = "sha256:third-party"' not in config_toml:
        raise AssertionError(f"third-party hook trust was removed: {config_toml!r}")


def test_uninstall_retry_preserves_user_hook_trust_at_default_cmux_key(
    cli_path: str, root: Path
) -> None:
    codex_home = root / "codex-home-uninstall-retry-user-default-key"
    codex_home.mkdir()
    hooks_path = codex_home / "hooks.json"
    config_path = codex_home / "config.toml"
    user_key = f"{hooks_path.resolve()}:pre_tool_use:0:0"
    user_hooks = {
        "hooks": {
            "PreToolUse": [
                {
                    "hooks": [
                        {"type": "command", "command": "printf user", "timeout": 1000}
                    ]
                }
            ]
        }
    }
    hooks_path.write_text(json.dumps(user_hooks, indent=2) + "\n", encoding="utf-8")
    config_path.write_text(
        f'[hooks.state."{user_key}"]\n'
        'trusted_hash = "sha256:user-default-index"\n',
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

    installed_hooks = json.loads(hooks_path.read_text(encoding="utf-8"))
    expected_trust = expected_cmux_codex_hook_trust(installed_hooks, hooks_path)
    if not expected_trust:
        raise AssertionError(f"expected cmux Codex trust entries, got {expected_trust!r}")
    hooks_path.write_text(json.dumps(user_hooks, indent=2) + "\n", encoding="utf-8")

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
            f"hooks codex uninstall retry failed exit={result.returncode}\n"
            f"stdout={result.stdout}\nstderr={result.stderr}"
        )

    config_toml = config_path.read_text(encoding="utf-8")
    if 'trusted_hash = "sha256:user-default-index"' not in config_toml:
        raise AssertionError(f"user hook trust at default cmux key was removed: {config_toml!r}")
    for key, trusted_hash in expected_trust.items():
        if trusted_hash in config_toml:
            raise AssertionError(f"stale cmux hook trust was preserved: {config_toml!r}")
        if key != user_key and key in config_toml:
            raise AssertionError(f"stale cmux hook trust was preserved: {config_toml!r}")


def test_uninstall_removes_legacy_codex_hook_trust(cli_path: str, root: Path) -> None:
    codex_home = root / "codex-home-uninstall-legacy-trust"
    codex_home.mkdir()
    hooks_path = codex_home / "hooks.json"
    config_path = codex_home / "config.toml"
    legacy_command = "cmux feed-hook --source codex --event PreToolUse"
    legacy_key = f"{hooks_path.resolve()}:pre_tool_use:0:0"
    legacy_hash = codex_command_hook_hash(
        event_label="pre_tool_use",
        matcher=None,
        command=legacy_command,
        timeout=120_000,
        status_message=None,
    )
    hooks_path.write_text(
        json.dumps(
            {
                "hooks": {
                    "PreToolUse": [
                        {
                            "hooks": [
                                {
                                    "type": "command",
                                    "command": legacy_command,
                                    "timeout": 120_000,
                                }
                            ]
                        }
                    ]
                }
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    config_path.write_text(
        f'[hooks.state."{legacy_key}"]\n'
        f'trusted_hash = "{legacy_hash}"\n',
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

    hooks = json.loads(hooks_path.read_text(encoding="utf-8"))
    if legacy_command in json.dumps(hooks):
        raise AssertionError(f"legacy cmux hook command was preserved: {hooks!r}")
    config_toml = config_path.read_text(encoding="utf-8")
    if legacy_key in config_toml or legacy_hash in config_toml:
        raise AssertionError(f"legacy cmux hook trust was preserved: {config_toml!r}")


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


def test_codex_permission_request_is_nonblocking_telemetry(cli_path: str, root: Path) -> None:
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
    if stdout != {}:
        raise AssertionError(f"Codex PermissionRequest telemetry should not emit a decision: {stdout!r}")
    params = frame["params"]
    if params.get("wait_timeout_seconds") != 0:
        raise AssertionError(f"Codex PermissionRequest should not wait for Feed reply: {frame!r}")
    event = params["event"]
    if event.get("hook_event_name") != "PermissionRequest" or event.get("_source") != "codex":
        raise AssertionError(f"wrong feed event: {event!r}")


def test_codex_permission_decisions_do_not_block_approval_reviewer(cli_path: str, root: Path) -> None:
    payload = {
        "session_id": "codex-session",
        "turn_id": "turn-persistent",
        "cwd": "/tmp/project",
        "hook_event_name": "PermissionRequest",
        "tool_name": "Bash",
        "tool_input": {"command": "printf hi"},
    }

    for mode in ["once", "always", "all", "bypass", "deny"]:
        stdout, _ = run_feed_hook(
            cli_path,
            root / f"cmux-{mode}.sock",
            payload,
            {"kind": "permission", "mode": mode},
        )
        if stdout != {}:
            raise AssertionError(f"Codex PermissionRequest must not answer {mode}: {stdout!r}")


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


def test_codex_lifecycle_feed_events_stay_telemetry_and_distinct(cli_path: str, root: Path) -> None:
    event_payloads = {
        "PostToolUse": {
            "session_id": "codex-session",
            "turn_id": "turn-post-tool",
            "cwd": "/tmp/project",
            "hook_event_name": "PostToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": "printf hi"},
            "tool_response": {"exit_code": 0, "stdout": "hi", "stderr": ""},
        },
        "PreCompact": {
            "session_id": "codex-session",
            "turn_id": "turn-pre-compact",
            "cwd": "/tmp/project",
            "hook_event_name": "PreCompact",
            "trigger": "manual",
        },
        "PostCompact": {
            "session_id": "codex-session",
            "turn_id": "turn-post-compact",
            "cwd": "/tmp/project",
            "hook_event_name": "PostCompact",
            "trigger": "manual",
        },
        "SubagentStart": {
            "session_id": "codex-session",
            "turn_id": "turn-subagent-start",
            "cwd": "/tmp/project",
            "hook_event_name": "SubagentStart",
            "agent_id": "agent-1",
            "agent_type": "general",
        },
        "SubagentStop": {
            "session_id": "codex-session",
            "turn_id": "turn-subagent-stop",
            "cwd": "/tmp/project",
            "hook_event_name": "SubagentStop",
            "agent_id": "agent-1",
            "agent_type": "general",
        },
    }

    for event_name, payload in event_payloads.items():
        stdout, frame = run_feed_hook(
            cli_path,
            root / f"cmux-codex-{event_name}.sock",
            payload,
            None,
        )
        if stdout != {}:
            raise AssertionError(f"Codex {event_name} telemetry should not emit a decision: {stdout!r}")
        params = frame["params"]
        if params.get("wait_timeout_seconds") != 0:
            raise AssertionError(f"Codex {event_name} should not wait for Feed reply: {frame!r}")
        event = params["event"]
        if event.get("hook_event_name") != event_name or event.get("_source") != "codex":
            raise AssertionError(f"Codex {event_name} should stay distinct in Feed, got {event!r}")
        if event_name == "PostToolUse":
            tool_input = event.get("tool_input")
            if not isinstance(tool_input, dict):
                raise AssertionError(f"Codex PostToolUse should forward tool metadata, got {event!r}")
            if tool_input.get("exit_code") != payload["tool_response"]["exit_code"]:
                raise AssertionError(f"Codex PostToolUse should preserve result metadata, got {event!r}")
            if "stdout" in tool_input or "stderr" in tool_input:
                raise AssertionError(f"Codex PostToolUse should omit command output, got {event!r}")


def test_codex_post_tool_use_redacts_tool_output(cli_path: str, root: Path) -> None:
    large_stdout = "x" * (80 * 1024)
    payload = {
        "session_id": "codex-session",
        "turn_id": "turn-large-post-tool",
        "cwd": "/tmp/project",
        "hook_event_name": "PostToolUse",
        "tool_name": "Bash",
        "tool_input": {"command": "python3 noisy.py"},
        "tool_response": {
            "exit_code": 42,
            "status": "failed",
            "stdout": large_stdout,
            "stderr": "short stderr",
            "private_blob": "y" * (80 * 1024),
        },
    }

    stdout, frame = run_feed_hook(
        cli_path,
        root / "cmux-codex-large-posttool.sock",
        payload,
        None,
    )
    if stdout != {}:
        raise AssertionError(f"Codex PostToolUse telemetry should not emit a decision: {stdout!r}")
    params = frame["params"]
    if params.get("wait_timeout_seconds") != 0:
        raise AssertionError(f"Codex PostToolUse should not wait for Feed reply: {frame!r}")
    event = params["event"]
    tool_input = event.get("tool_input")
    if not isinstance(tool_input, dict):
        raise AssertionError(f"Codex PostToolUse should forward summarized tool_input: {event!r}")
    if tool_input.get("_cmux_sanitized") is not True:
        raise AssertionError(f"PostToolUse response was not marked sanitized: {tool_input!r}")
    if tool_input.get("exit_code") != 42 or tool_input.get("status") != "failed":
        raise AssertionError(f"large PostToolUse response did not preserve metadata: {tool_input!r}")
    if "stdout" in tool_input or "stderr" in tool_input or "private_blob" in tool_input:
        raise AssertionError(f"unrecognized large PostToolUse fields should be omitted: {tool_input!r}")
    if tool_input.get("stdout_text_omitted") is not True:
        raise AssertionError(f"stdout omission marker was not recorded: {tool_input!r}")
    if tool_input.get("stderr_text_omitted") is not True:
        raise AssertionError(f"stderr omission marker was not recorded: {tool_input!r}")


def test_codex_post_tool_use_accepts_native_event_label(cli_path: str, root: Path) -> None:
    payload = {
        "session_id": "codex-session",
        "turn_id": "turn-native-post-tool",
        "cwd": "/tmp/project",
        "event": "post_tool_use",
        "tool_name": "Bash",
        "tool_input": {"command": "printf hi"},
        "tool_response": {
            "exit_code": 7,
            "stdout": "hi",
        },
    }

    stdout, frame = run_feed_hook(
        cli_path,
        root / "cmux-codex-native-posttool.sock",
        payload,
        None,
    )
    if stdout != {}:
        raise AssertionError(f"native Codex post_tool_use telemetry should not emit a decision: {stdout!r}")
    event = frame["params"]["event"]
    if event.get("hook_event_name") != "PostToolUse":
        raise AssertionError(f"native Codex post_tool_use should classify as PostToolUse: {event!r}")
    tool_input = event.get("tool_input")
    if not isinstance(tool_input, dict):
        raise AssertionError(f"native Codex post_tool_use should forward sanitized metadata: {event!r}")
    if tool_input.get("exit_code") != 7 or "stdout" in tool_input:
        raise AssertionError(f"native Codex post_tool_use should omit command output: {event!r}")


def test_codex_post_tool_use_oversize_payload_is_dropped_before_decode(cli_path: str, root: Path) -> None:
    payload = {
        "session_id": "codex-session",
        "turn_id": "turn-oversize-post-tool",
        "cwd": "/tmp/project",
        "hook_event_name": "PostToolUse",
        "tool_name": "Bash",
        "tool_input": {"command": "python3 very_noisy.py"},
        "tool_response": {
            "exit_code": 0,
            "stdout": "x" * (1024 * 1024 + 128),
        },
    }

    stdout, frame = run_feed_hook_optional_frame(
        cli_path,
        root / "cmux-codex-oversize-posttool.sock",
        payload,
        None,
    )
    if stdout != {}:
        raise AssertionError(f"oversize Codex PostToolUse should fall back to empty output: {stdout!r}")
    if frame is not None:
        raise AssertionError(f"oversize Codex PostToolUse should not send feed.push: {frame!r}")


def test_codex_lifecycle_oversize_payload_is_dropped_before_decode(cli_path: str, root: Path) -> None:
    payload = {
        "session_id": "codex-session",
        "turn_id": "turn-oversize-pre-compact",
        "cwd": "/tmp/project",
        "hook_event_name": "PreCompact",
        "transcript": "x" * (1024 * 1024 + 128),
    }

    stdout, frame = run_feed_hook_optional_frame(
        cli_path,
        root / "cmux-codex-oversize-precompact.sock",
        payload,
        None,
    )
    if stdout != {}:
        raise AssertionError(f"oversize Codex PreCompact should fall back to empty output: {stdout!r}")
    if frame is not None:
        raise AssertionError(f"oversize Codex PreCompact should not send feed.push: {frame!r}")


def test_codex_post_tool_use_keeps_cwd_from_tool_input(cli_path: str, root: Path) -> None:
    payload = {
        "session_id": "codex-session",
        "turn_id": "turn-post-tool-cwd",
        "hook_event_name": "PostToolUse",
        "tool_name": "Bash",
        "tool_input": {
            "command": "printf hi",
            "cwd": "/tmp/request-cwd",
        },
        "tool_response": {
            "exit_code": 0,
            "stdout": "hi",
        },
    }

    stdout, frame = run_feed_hook(
        cli_path,
        root / "cmux-codex-posttool-cwd.sock",
        payload,
        None,
    )
    if stdout != {}:
        raise AssertionError(f"Codex PostToolUse telemetry should not emit a decision: {stdout!r}")
    event = frame["params"]["event"]
    if event.get("cwd") != "/tmp/request-cwd":
        raise AssertionError(f"Codex PostToolUse should keep cwd from tool_input: {event!r}")
    tool_input = event.get("tool_input")
    if not isinstance(tool_input, dict):
        raise AssertionError(f"Codex PostToolUse should forward sanitized tool_response metadata: {event!r}")
    if tool_input.get("exit_code") != 0 or "stdout" in tool_input:
        raise AssertionError(f"Codex PostToolUse should forward metadata without stdout: {event!r}")


def test_codex_post_tool_use_without_response_keeps_request_input(cli_path: str, root: Path) -> None:
    payload = {
        "session_id": "codex-session",
        "turn_id": "turn-post-tool-request-only",
        "hook_event_name": "PostToolUse",
        "tool_name": "Bash",
        "tool_input": {
            "command": "printf hi",
            "cwd": "/tmp/request-cwd",
        },
    }

    stdout, frame = run_feed_hook(
        cli_path,
        root / "cmux-codex-posttool-request-only.sock",
        payload,
        None,
    )
    if stdout != {}:
        raise AssertionError(f"Codex PostToolUse telemetry should not emit a decision: {stdout!r}")
    event = frame["params"]["event"]
    tool_input = event.get("tool_input")
    if tool_input != payload["tool_input"]:
        raise AssertionError(f"Codex PostToolUse without response should preserve request input: {event!r}")
    if isinstance(tool_input, dict) and tool_input.get("_cmux_sanitized") is True:
        raise AssertionError(f"request input fallback should not be sanitized: {event!r}")


def test_non_codex_post_tool_use_keeps_request_input(cli_path: str, root: Path) -> None:
    payload = {
        "session_id": "antigravity-session",
        "hook_event_name": "PostToolUse",
        "tool_name": "run_command",
        "tool_input": {
            "command": "cat important.txt",
            "cwd": "/tmp/antigravity-cwd",
            "path": "important.txt",
        },
        "tool_response": {
            "stdout": "secret output that must not replace the request input",
            "exit_code": 0,
        },
    }

    stdout, frame = run_feed_hook(
        cli_path,
        root / "cmux-antigravity-posttool.sock",
        payload,
        None,
        source="antigravity",
    )
    if stdout != {}:
        raise AssertionError(f"Antigravity PostToolUse telemetry should not emit a decision: {stdout!r}")
    event = frame["params"]["event"]
    tool_input = event.get("tool_input")
    if tool_input != payload["tool_input"]:
        raise AssertionError(f"non-Codex PostToolUse should preserve request input: {event!r}")
    if isinstance(tool_input, dict) and tool_input.get("_cmux_sanitized") is True:
        raise AssertionError(f"non-Codex request input should not be sanitized: {event!r}")


def test_claude_subagent_stop_stays_distinct_feed_telemetry(cli_path: str, root: Path) -> None:
    stdout, frame = run_feed_hook(
        cli_path,
        root / "cmux-claude-subagent-stop.sock",
        {
            "session_id": "claude-session",
            "cwd": "/tmp/project",
            "hook_event_name": "SubagentStop",
        },
        None,
        source="claude",
    )
    if stdout != {}:
        raise AssertionError(f"SubagentStop telemetry should not emit a decision: {stdout!r}")
    params = frame["params"]
    if params.get("wait_timeout_seconds") != 0:
        raise AssertionError(f"SubagentStop should not wait for Feed reply: {frame!r}")
    event = params["event"]
    if event.get("hook_event_name") != "SubagentStop" or event.get("_source") != "claude":
        raise AssertionError(f"SubagentStop should stay distinct in Feed, got {event!r}")


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(prefix="cmux-codex-feed-hooks-", dir="/tmp") as td:
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
            test_install_deduplicates_interleaved_codex_hook_positions(cli_path, root)
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
            test_install_preserves_plugin_tables_inside_stale_cmux_hook_trust_marker(cli_path, root)
            test_install_enables_hooks_when_stale_trust_marker_captures_dotted_feature(cli_path, root)
            test_uninstall_preserves_third_party_hook_trust_inside_cmux_marker(cli_path, root)
            test_uninstall_retry_removes_stale_cmux_hook_trust_after_hooks_are_cleaned(cli_path, root)
            test_uninstall_retry_preserves_user_hook_trust_at_default_cmux_key(cli_path, root)
            test_uninstall_removes_legacy_codex_hook_trust(cli_path, root)
            test_uninstall_codex_hooks_removes_legacy_managed_block(cli_path, root)
            test_install_surfaces_invalid_codex_config_encoding(cli_path, root)
            test_uninstall_surfaces_invalid_codex_config_encoding(cli_path, root)
            test_install_codex_hooks_preserves_config_when_toml_read_fails(cli_path, root)
            test_codex_permission_request_is_nonblocking_telemetry(cli_path, root)
            test_codex_permission_decisions_do_not_block_approval_reviewer(cli_path, root)
            test_codex_pre_tool_use_is_telemetry_not_actionable(cli_path, root)
            test_codex_lifecycle_feed_events_stay_telemetry_and_distinct(cli_path, root)
            test_codex_post_tool_use_redacts_tool_output(cli_path, root)
            test_codex_post_tool_use_accepts_native_event_label(cli_path, root)
            test_codex_post_tool_use_oversize_payload_is_dropped_before_decode(cli_path, root)
            test_codex_lifecycle_oversize_payload_is_dropped_before_decode(cli_path, root)
            test_codex_post_tool_use_keeps_cwd_from_tool_input(cli_path, root)
            test_codex_post_tool_use_without_response_keeps_request_input(cli_path, root)
            test_non_codex_post_tool_use_keeps_request_input(cli_path, root)
            test_claude_subagent_stop_stays_distinct_feed_telemetry(cli_path, root)
        except Exception as exc:
            print(f"FAIL: {exc}")
            return 1

    print("PASS: Codex Feed hooks leave Codex approvals non-blocking")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
