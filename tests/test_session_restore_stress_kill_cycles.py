#!/usr/bin/env python3
"""
Stress: tracked agent sessions must survive repeated kill/reopen cycles.

Phases:
1) Seed six workspaces with tracked Claude/Codex/OpenCode sessions. The fake
   agents keep running (exec sleep) so the shell stays in command-running
   state and every later snapshot records wasAgentRunning=true.
2) Clean quit -> relaunch: all six sessions auto-resume from the persisted
   snapshot (hook state files are deleted before relaunch to prove it).
3) Second clean quit -> relaunch: the re-saved snapshot still resumes all six.
4) SIGKILL the app after the autosave window -> relaunch: the autosaved
   snapshot still resumes all six.
5) Clean quit, then corrupt the primary session snapshot -> relaunch: cmux
   must recover the session from the -previous backup snapshot instead of
   silently starting fresh, and the backup file must survive the relaunch so
   `cmux restore-session` keeps working.
"""

from __future__ import annotations

import json
import os
import plistlib
import re
import signal
import socket
import subprocess
import tempfile
import time
from pathlib import Path

from cmux import cmux

# (launcher, session id, marker tokens). A session counts as resumed when one
# scrollback line contains every token: the fake-agent prefix proves the fake
# binary ran (the typed resume command alone does not contain it), and the
# session token proves which session it was. Claude tokens stay order-agnostic
# because the cmux claude wrapper inserts its own arguments around --resume.
SESSION_SPECS = [
    ("claude", "claude-stress-0", ("CMUX_FAKE_CLAUDE_RESUME:", "--resume claude-stress-0")),
    ("claude", "claude-stress-1", ("CMUX_FAKE_CLAUDE_RESUME:", "--resume claude-stress-1")),
    ("codex", "codex-stress-0", ("CMUX_FAKE_CODEX_RESUME:", "resume codex-stress-0")),
    ("codex", "codex-stress-1", ("CMUX_FAKE_CODEX_RESUME:", "resume codex-stress-1")),
    ("opencode", "opencode-stress-0", ("CMUX_FAKE_OPENCODE_RESUME:", "--session opencode-stress-0")),
    ("opencode", "opencode-stress-1", ("CMUX_FAKE_OPENCODE_RESUME:", "--session opencode-stress-1")),
]


def _marker_found(combined: str, tokens: tuple[str, ...]) -> bool:
    return any(all(token in line for token in tokens) for line in combined.splitlines())


def _bundle_id(app_path: Path) -> str:
    info_path = app_path / "Contents" / "Info.plist"
    if not info_path.exists():
        raise RuntimeError(f"Missing Info.plist at {info_path}")
    with info_path.open("rb") as f:
        info = plistlib.load(f)
    bundle_id = str(info.get("CFBundleIdentifier", "")).strip()
    if not bundle_id:
        raise RuntimeError("Missing CFBundleIdentifier")
    return bundle_id


def _snapshot_path(bundle_id: str, suffix: str = "") -> Path:
    safe_bundle = re.sub(r"[^A-Za-z0-9._-]", "_", bundle_id)
    return Path.home() / "Library/Application Support/cmux" / f"session-{safe_bundle}{suffix}.json"


def _socket_reachable(socket_path: Path) -> bool:
    if not socket_path.exists():
        return False
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(0.3)
        sock.connect(str(socket_path))
        sock.sendall(b"ping\n")
        data = sock.recv(1024)
        return b"PONG" in data
    except OSError:
        return False
    finally:
        sock.close()


def _wait_for_socket(socket_path: Path, timeout: float = 20.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if _socket_reachable(socket_path):
            return
        time.sleep(0.2)
    raise RuntimeError(f"Socket did not become reachable: {socket_path}")


def _wait_for_socket_closed(socket_path: Path, timeout: float = 20.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not _socket_reachable(socket_path):
            return
        time.sleep(0.2)
    raise RuntimeError(f"Socket still reachable after quit: {socket_path}")


def _app_pids(app_path: Path) -> list[int]:
    exe = app_path / "Contents" / "MacOS" / "cmux DEV"
    result = subprocess.run(["pgrep", "-f", str(exe)], capture_output=True, text=True)
    return [int(line) for line in result.stdout.split() if line.strip().isdigit()]


def _kill_existing(app_path: Path) -> None:
    exe = app_path / "Contents" / "MacOS" / "cmux DEV"
    subprocess.run(["pkill", "-f", str(exe)], capture_output=True, text=True)
    time.sleep(1.0)


def _launch(app_path: Path, socket_path: Path, env_overrides: dict[str, str] | None = None) -> None:
    try:
        socket_path.unlink()
    except FileNotFoundError:
        pass

    command = ["open", "-na", str(app_path)]
    full_env = dict(env_overrides or {})
    full_env["CMUX_SOCKET_PATH"] = str(socket_path)
    full_env["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
    for key, value in full_env.items():
        command.extend(["--env", f"{key}={value}"])
    subprocess.run(command, check=True)
    _wait_for_socket(socket_path)
    time.sleep(1.5)


def _quit(bundle_id: str, socket_path: Path) -> None:
    subprocess.run(
        ["osascript", "-e", f'tell application id "{bundle_id}" to quit'],
        capture_output=True,
        text=True,
        check=True,
    )
    _wait_for_socket_closed(socket_path)
    try:
        socket_path.unlink()
    except FileNotFoundError:
        pass
    time.sleep(0.8)


def _force_kill(app_path: Path, socket_path: Path) -> None:
    pids = _app_pids(app_path)
    if not pids:
        raise RuntimeError("expected a running app to SIGKILL")
    for pid in pids:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    _wait_for_socket_closed(socket_path)
    try:
        socket_path.unlink()
    except FileNotFoundError:
        pass
    time.sleep(0.8)


def _connect(socket_path: Path) -> cmux:
    client = cmux(socket_path=str(socket_path))
    client.connect()
    if not client.ping():
        raise RuntimeError("ping failed")
    return client


def _read_scrollback(client: cmux) -> str:
    return client._send_command("read_screen --scrollback")


def _wait_for_condition(timeout: float, predicate) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.3)
    return False


def _write_fake_agent(fake_bin_dir: Path, binary_name: str, prefix: str) -> None:
    fake_bin_dir.mkdir(parents=True, exist_ok=True)
    fake_binary = fake_bin_dir / binary_name
    # Keep running so snapshots record the agent as live (wasAgentRunning=true)
    # and later relaunches keep auto-resuming.
    fake_binary.write_text(
        "#!/bin/sh\n"
        f"printf '{prefix}:%s\\n' \"$*\"\n"
        "exec sleep 86400\n",
        encoding="utf-8",
    )
    fake_binary.chmod(0o755)


def _write_hook_state(
    path: Path,
    sessions: list[dict],
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {"version": 1, "sessions": {entry["sessionId"]: entry for entry in sessions}}
    path.write_text(json.dumps(payload), encoding="utf-8")


def _hook_session_entry(
    session_id: str,
    workspace_id: str,
    surface_id: str,
    cwd: str,
    launcher: str,
    executable_path: Path,
    environment: dict[str, str],
    transcript_path: Path | None = None,
) -> dict:
    # Claude hook records are only restorable when their transcript exists on
    # disk (hookRecordIsRestorable), so claude entries carry a transcriptPath.
    entry = {
        "sessionId": session_id,
        "workspaceId": workspace_id,
        "surfaceId": surface_id,
        "cwd": cwd,
        "launchCommand": {
            "launcher": launcher,
            "executablePath": str(executable_path),
            "arguments": [str(executable_path)],
            "workingDirectory": cwd,
            "environment": environment,
            "capturedAt": time.time(),
            "source": "test",
        },
        "updatedAt": time.time(),
    }
    if transcript_path is not None:
        entry["transcriptPath"] = str(transcript_path)
    return entry


def _collect_all_scrollbacks(client: cmux) -> str:
    chunks: list[str] = []
    workspaces = client.list_workspaces()
    for index in range(len(workspaces)):
        client.select_workspace(index)
        chunks.append(_read_scrollback(client))
    return "\n".join(chunks)


def _assert_all_sessions_resumed(
    client: cmux,
    phase: str,
    failures: list[str],
    timeout: float = 30.0,
) -> None:
    expected_markers = [marker for (_, _, marker) in SESSION_SPECS]

    def all_present() -> bool:
        if len(client.list_workspaces()) < len(SESSION_SPECS):
            return False
        combined = _collect_all_scrollbacks(client)
        return all(_marker_found(combined, marker) for marker in expected_markers)

    if _wait_for_condition(timeout, all_present):
        return
    combined = _collect_all_scrollbacks(client)
    missing = [marker for marker in expected_markers if not _marker_found(combined, marker)]
    workspace_count = len(client.list_workspaces())
    failures.append(
        f"{phase}: {len(missing)}/{len(expected_markers)} sessions did not resume "
        f"(workspaces={workspace_count}); missing markers: {missing}"
    )


def main() -> int:
    app_path_str = os.environ.get("CMUX_APP_PATH", "").strip()
    if not app_path_str:
        print("SKIP: set CMUX_APP_PATH to a built cmux DEV .app path")
        return 0
    app_path = Path(app_path_str)
    if not app_path.exists():
        print(f"SKIP: CMUX_APP_PATH does not exist: {app_path}")
        return 0

    bundle_id = _bundle_id(app_path)
    socket_path = Path(f"/tmp/cmux-restore-stress-{bundle_id.replace('.', '-')}.sock")
    snapshot = _snapshot_path(bundle_id)
    previous_snapshot = _snapshot_path(bundle_id, suffix="-previous")

    failures: list[str] = []

    with tempfile.TemporaryDirectory(prefix="cmux-restore-stress-") as td:
        fake_bin_dir = Path(td) / "bin"
        hook_state_dir = Path(td) / "hook-state"
        hook_state_files = {
            launcher: hook_state_dir / f"{launcher}-hook-sessions.json"
            for launcher in {launcher for (launcher, _, _) in SESSION_SPECS}
        }
        _write_fake_agent(fake_bin_dir, "claude", "CMUX_FAKE_CLAUDE_RESUME")
        _write_fake_agent(fake_bin_dir, "codex", "CMUX_FAKE_CODEX_RESUME")
        _write_fake_agent(fake_bin_dir, "opencode", "CMUX_FAKE_OPENCODE_RESUME")
        launch_path = f"{fake_bin_dir}:{os.environ.get('PATH', '')}"
        app_env = {
            "PATH": launch_path,
            "CMUX_AGENT_HOOK_STATE_DIR": str(hook_state_dir),
            # Claude resume routes through the cmux claude wrapper, which
            # resolves the real binary; point it at the fake one instead.
            "CMUX_CUSTOM_CLAUDE_PATH": str(fake_bin_dir / "claude"),
        }

        def remove_hook_state() -> None:
            for hook_state in hook_state_files.values():
                hook_state.unlink(missing_ok=True)

        _kill_existing(app_path)
        snapshot.unlink(missing_ok=True)
        previous_snapshot.unlink(missing_ok=True)
        remove_hook_state()

        try:
            # Phase 1: seed one workspace per session.
            _launch(app_path, socket_path, env_overrides=app_env)
            client = _connect(socket_path)
            try:
                workspace_ids = [client.current_workspace()]
                while len(workspace_ids) < len(SESSION_SPECS):
                    workspace_ids.append(client.new_workspace())
                    time.sleep(0.3)

                entries_by_launcher: dict[str, list[dict]] = {}
                for index, (launcher, session_id, _) in enumerate(SESSION_SPECS):
                    client.select_workspace(workspace_ids[index])
                    time.sleep(0.3)
                    surfaces = client.list_surfaces()
                    if not surfaces:
                        failures.append(f"setup: expected a surface in workspace {index}")
                        continue
                    transcript_path: Path | None = None
                    if launcher == "claude":
                        transcript_path = Path(td) / f"transcript-{session_id}.jsonl"
                        transcript_path.write_text('{"type":"user"}\n', encoding="utf-8")
                    entries_by_launcher.setdefault(launcher, []).append(
                        _hook_session_entry(
                            session_id=session_id,
                            workspace_id=workspace_ids[index],
                            surface_id=surfaces[0][1],
                            cwd=os.getcwd(),
                            launcher=launcher,
                            executable_path=fake_bin_dir / launcher,
                            environment={"PATH": launch_path, "SHELL": "/bin/zsh"},
                            transcript_path=transcript_path,
                        )
                    )
                for launcher, entries in entries_by_launcher.items():
                    _write_hook_state(hook_state_files[launcher], entries)
                client.select_workspace(0)
                time.sleep(0.4)
            finally:
                client.close()
            if failures:
                return _report(failures)
            _quit(bundle_id, socket_path)

            # Prove relaunches use the persisted snapshot, not live hook files.
            remove_hook_state()

            # Phase 2: clean relaunch resumes everything.
            _launch(app_path, socket_path, env_overrides=app_env)
            client = _connect(socket_path)
            try:
                _assert_all_sessions_resumed(client, "clean relaunch #1", failures)
            finally:
                client.close()
            _quit(bundle_id, socket_path)

            # Phase 3: second clean relaunch (re-saved snapshot) resumes everything.
            _launch(app_path, socket_path, env_overrides=app_env)
            client = _connect(socket_path)
            try:
                _assert_all_sessions_resumed(client, "clean relaunch #2", failures)
            finally:
                client.close()

            # Phase 4: force-kill after the autosave window, relaunch, resume.
            time.sleep(12.0)  # > SessionPersistencePolicy.autosaveInterval
            _force_kill(app_path, socket_path)
            _launch(app_path, socket_path, env_overrides=app_env)
            client = _connect(socket_path)
            try:
                _assert_all_sessions_resumed(client, "relaunch after SIGKILL", failures)
            finally:
                client.close()
            _quit(bundle_id, socket_path)

            # Phase 5: corrupt the primary snapshot; relaunch must recover from
            # the -previous backup instead of silently starting fresh.
            if not snapshot.exists():
                failures.append("corrupt-snapshot phase: expected a primary snapshot after quit")
                return _report(failures)
            snapshot.write_text('{"version": 9999, "windows": [truncated-mid-w', encoding="utf-8")

            _launch(app_path, socket_path, env_overrides=app_env)
            client = _connect(socket_path)
            try:
                _assert_all_sessions_resumed(client, "relaunch with corrupt primary snapshot", failures)

                if not previous_snapshot.exists():
                    failures.append(
                        "corrupt-snapshot phase: -previous backup snapshot was deleted; "
                        "restore-session recovery is impossible after a corrupt primary snapshot"
                    )
                else:
                    # The manual `cmux restore-session` recovery entrypoint must
                    # also still work from the preserved backup. It reopens the
                    # backed-up workspaces in a new window (with the same
                    # workspace ids as the startup fallback restore, since both
                    # read the same backup), so assert on the window count.
                    cli_path = app_path / "Contents" / "Resources" / "bin" / "cmux"
                    restore_env = dict(os.environ)
                    restore_env["CMUX_SOCKET_PATH"] = str(socket_path)

                    def window_count() -> int:
                        result = subprocess.run(
                            [str(cli_path), "list-windows", "--json"],
                            capture_output=True,
                            text=True,
                            env=restore_env,
                        )
                        try:
                            return len(json.loads(result.stdout))
                        except (json.JSONDecodeError, TypeError):
                            return -1

                    windows_before = window_count()
                    restore_proc = subprocess.run(
                        [str(cli_path), "restore-session"],
                        capture_output=True,
                        text=True,
                        env=restore_env,
                    )
                    if restore_proc.returncode != 0 or restore_proc.stdout.strip() != "OK":
                        failures.append(
                            "corrupt-snapshot phase: restore-session failed after backup-preserving "
                            f"relaunch; rc={restore_proc.returncode} stdout={restore_proc.stdout!r} "
                            f"stderr={restore_proc.stderr!r}"
                        )
                    elif windows_before < 1 or not _wait_for_condition(
                        20.0, lambda: window_count() > windows_before
                    ):
                        failures.append(
                            "corrupt-snapshot phase: restore-session did not reopen the backed-up "
                            f"session in a new window (windows before={windows_before}, "
                            f"after={window_count()})"
                        )
            finally:
                client.close()
            _quit(bundle_id, socket_path)
        finally:
            _kill_existing(app_path)
            socket_path.unlink(missing_ok=True)
            snapshot.unlink(missing_ok=True)
            previous_snapshot.unlink(missing_ok=True)
            remove_hook_state()

    return _report(failures)


def _report(failures: list[str]) -> int:
    if failures:
        print("FAIL:")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("PASS: agent sessions survive clean relaunch, repeat relaunch, SIGKILL, and corrupt-snapshot recovery")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
