#!/usr/bin/env python3
"""Regression: a Claude session's cwd becomes its pane's directory until the session ends.

`claude --worktree wt2` runs in `<repo>/.claude/worktrees/wt2`, but the shell
that launched it stays in `<repo>` and cannot report the change while Claude is
the foreground process. The Claude hooks carry the session's cwd, so they report
the checkout root through the same `report_pwd` path shell integration uses.
A `cd` inside the launch checkout keeps the launch directory, and SessionEnd
reports the launch directory again because the shell only re-reports a
directory it has not already sent. Discussions #1872 and #6371.
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
import uuid
from pathlib import Path

from fake_socket_env import cli_environment, unwrap_capability


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit:
        if os.path.exists(explicit) and os.access(explicit, os.X_OK):
            return explicit
        raise RuntimeError(f"Configured cmux CLI is not executable: {explicit}")
    in_path = shutil.which("cmux")
    if in_path:
        return in_path
    raise RuntimeError("Unable to find cmux CLI binary. Set CMUX_CLI_BIN.")


class HookSocketServer:
    def __init__(self, root: str, workspace_id: str, surface_id: str) -> None:
        self.workspace_id = workspace_id
        self.surface_id = surface_id
        self.commands: list[str] = []
        self.ready = threading.Event()
        self.stop = threading.Event()
        self.error: Exception | None = None
        self.socket_path = os.path.join(root, "cmux.sock")
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

    def _run(self) -> None:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                self.server = server
                server.bind(self.socket_path)
                server.listen(8)
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
                    line = unwrap_capability(raw_line.decode("utf-8", errors="replace"))
                    self.commands.append(line)
                    try:
                        conn.sendall((self._response_for(line) + "\n").encode("utf-8"))
                    except (BrokenPipeError, ConnectionResetError):
                        return

    def _response_for(self, line: str) -> str:
        if not line.startswith("{"):
            return "OK"
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            return "OK"
        method = request.get("method")
        result: dict[str, object] = {}
        if method == "agent.resolve_delivery_target":
            params = request.get("params")
            result = {
                "source": "pid" if isinstance(params, dict) and "pid" in params else "surface",
                "workspace_id": self.workspace_id,
                "surface_id": self.surface_id,
            }
        elif method == "surface.list":
            result = {"surfaces": [{"index": 0, "id": self.surface_id, "ref": "surface:1", "focused": True}]}
        elif method == "workspace.current":
            result = {"workspace_id": self.workspace_id}
        elif method == "workspace.list":
            result = {"workspaces": [{"index": 0, "id": self.workspace_id, "ref": "workspace:1"}]}
        elif method == "window.list":
            result = {"windows": [{"id": str(uuid.uuid4()).upper()}]}
        elif method == "debug.terminals":
            result = {"terminals": []}
        return json.dumps({"id": request.get("id"), "ok": True, "result": result})


def run_claude_hook(cli_path: str, socket_path: str, subcommand: str, payload: dict[str, object], env: dict[str, str]) -> None:
    proc = subprocess.run(
        [cli_path, "--socket", socket_path, "claude-hook", subcommand],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        env=env,
        timeout=8,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"cmux claude-hook {subcommand} failed:\n"
            f"exit={proc.returncode}\nstdout={proc.stdout}\nstderr={proc.stderr}"
        )


def pwd_reports(commands: list[str]) -> list[str]:
    return [command for command in commands if command.startswith("report_pwd ")]


def expected_report(path: str, workspace_id: str, surface_id: str) -> str:
    quoted = path.replace("\\", "\\\\").replace('"', '\\"')
    return f'report_pwd "{quoted}" --tab={workspace_id} --panel={surface_id}'


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    workspace_id = str(uuid.uuid4()).upper()
    surface_id = str(uuid.uuid4()).upper()
    session_id = f"wt-{uuid.uuid4().hex}"

    with tempfile.TemporaryDirectory(prefix="cmux-claude-cwd-") as root_name:
        root = Path(root_name).resolve()
        repo = root / "wt-test-repo"
        worktree = repo / ".claude" / "worktrees" / "wt2"
        worktree_subdir = worktree / "src"
        worktree_subdir.mkdir(parents=True)
        (repo / ".git").mkdir()
        (worktree / ".git").write_text(f"gitdir: {repo}/.git/worktrees/wt2\n")
        repo_subdir = repo / "packages" / "foo"
        repo_subdir.mkdir(parents=True)
        # The shell reports its logical $PWD, which the wrapper also exports as
        # the launch directory; Claude reports the physical path.
        repo_link = root / "repo-link"
        repo_link.symlink_to(repo, target_is_directory=True)
        launch_cwd = str(repo_link)

        with HookSocketServer(root_name, workspace_id, surface_id) as server:
            env = cli_environment(server.socket_path)
            # Hermetic: a cmux or Claude session running this test exports its
            # own launch capture, which would mark the hooks as a fork.
            for key in list(env):
                if key.startswith(("CMUX_AGENT_", "CMUX_CLAUDE_", "CLAUDE")):
                    del env[key]
            env["CMUX_WORKSPACE_ID"] = workspace_id
            env["CMUX_SURFACE_ID"] = surface_id
            env["CMUX_CLAUDE_HOOK_STATE_PATH"] = str(root / "claude-hook-state.json")
            env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
            env["CMUX_CLAUDE_PID"] = "33333"
            env["CMUX_AGENT_LAUNCH_KIND"] = "claude"
            env["CMUX_AGENT_LAUNCH_CWD"] = launch_cwd

            def run_phase(subcommand: str, payload: dict[str, object], applied: str) -> list[str]:
                start = len(server.commands)
                run_claude_hook(cli_path, server.socket_path, subcommand, payload, env)
                commands = server.commands[start:]
                # Each phase must pass the hook's own stale-turn guards, or an
                # absent report proves nothing.
                if not any(command.startswith(applied) for command in commands):
                    raise AssertionError(
                        f"{subcommand} was not applied (no {applied!r}): {commands!r}"
                    )
                return commands

            def expect_reports(label: str, commands: list[str], wanted: list[str]) -> bool:
                if pwd_reports(commands) == wanted:
                    return True
                print(f"FAIL: {label}")
                print(f"want={wanted!r}")
                print(f"commands={commands!r}")
                return False

            running = "set_status claude_code Running"
            idle = "set_status claude_code Idle"
            want = expected_report(str(worktree), workspace_id, surface_id)
            want_launch = expected_report(launch_cwd, workspace_id, surface_id)

            if not expect_reports(
                "SessionStart in a worktree subdirectory must report the worktree root",
                run_phase(
                    "session-start",
                    {"session_id": session_id, "source": "startup", "cwd": str(worktree_subdir)},
                    idle,
                ),
                [want],
            ):
                return 1

            if not expect_reports(
                "UserPromptSubmit must keep the worktree as the pane directory",
                run_phase(
                    "prompt-submit",
                    {"session_id": session_id, "turn_id": "turn-1", "cwd": str(worktree)},
                    running,
                ),
                [want],
            ):
                return 1

            for bad_cwd in ("relative/worktree", "", "   "):
                if not expect_reports(
                    f"a non-absolute hook cwd {bad_cwd!r} must not move the pane directory",
                    run_phase(
                        "stop",
                        {"session_id": session_id, "turn_id": "turn-1", "cwd": bad_cwd},
                        idle,
                    ),
                    [],
                ):
                    return 1

            # A Bash `cd` inside the launch checkout is not a move: the pane
            # keeps the launch directory instead of following the subdirectory.
            if not expect_reports(
                "a cwd inside the launch checkout must report the launch directory",
                run_phase(
                    "prompt-submit",
                    {"session_id": session_id, "turn_id": "turn-2", "cwd": str(repo_subdir)},
                    running,
                ),
                [want_launch],
            ):
                return 1

            # Claude back in the launch checkout (ExitWorktree) reports the
            # shell's spelling of that directory, not the physical path.
            if not expect_reports(
                "a hook cwd that is the launch directory must report the launch spelling",
                run_phase(
                    "stop",
                    {"session_id": session_id, "turn_id": "turn-2", "cwd": str(repo)},
                    idle,
                ),
                [want_launch],
            ):
                return 1

            if not expect_reports(
                "re-entering the worktree must report the worktree root",
                run_phase(
                    "prompt-submit",
                    {"session_id": session_id, "turn_id": "turn-3", "cwd": str(worktree)},
                    running,
                ),
                [want],
            ):
                return 1

            end_commands = run_phase(
                "session-end",
                {"session_id": session_id, "reason": "prompt_input_exit", "cwd": str(worktree)},
                "clear_agent_pid claude_code",
            )
            end_reports = pwd_reports(end_commands)
            if not end_reports or end_reports[-1] != want_launch:
                print("FAIL: SessionEnd must hand the pane directory back to the launch directory")
                print(f"want={want_launch!r}")
                print(f"commands={end_commands!r}")
                return 1

    print("PASS: Claude hook cwd follows the session and SessionEnd restores the launch directory")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
