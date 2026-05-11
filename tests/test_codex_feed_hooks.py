#!/usr/bin/env python3
"""
Regression tests for Codex Feed hook wiring and decision output.
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli


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
        self.surfaces = surfaces if surfaces is not None else [{"id": "surface-codex-feed-test"}]
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
    env["CMUX_SURFACE_ID"] = "surface-codex-feed-test"
    env["CMUX_WORKSPACE_ID"] = "workspace-codex-feed-test"
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
    env["CMUX_SURFACE_ID"] = "surface-codex-feed-test"
    env["CMUX_WORKSPACE_ID"] = "workspace-codex-feed-test"
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
    env["CMUX_SURFACE_ID"] = "surface-codex-feed-test"
    env["CMUX_WORKSPACE_ID"] = "workspace-codex-feed-test"
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
    env["CMUX_WORKSPACE_ID"] = "workspace-codex-feed-test"
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
                    "workspace-codex-feed-test",
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
    env["CMUX_WORKSPACE_ID"] = "workspace-codex-feed-test"

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
                "workspace-codex-feed-test",
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
            test_codex_stop_reaps_transcript_monitor(cli_path, root)
            test_codex_stop_without_turn_keeps_session_wide_monitor(cli_path, root)
            test_codex_prompt_submit_starts_monitor_when_lease_write_fails(cli_path, root)
            test_codex_monitor_exits_when_workspace_has_no_surfaces(cli_path, root)
            test_codex_monitor_survives_transient_owner_rpc_timeout(cli_path, root)
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
