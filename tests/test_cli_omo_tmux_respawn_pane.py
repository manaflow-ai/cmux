#!/usr/bin/env python3
"""
Regression tests for OMO subagent panes through cmux's tmux compatibility shim.
"""

from __future__ import annotations

import json
import os
import socketserver
import subprocess
import tempfile
import threading
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli

WORKSPACE_ID = "11111111-1111-4111-8111-111111111111"
WINDOW_ID = "22222222-2222-4222-8222-222222222222"
PANE_ID = "33333333-3333-4333-8333-333333333333"
SURFACE_ID = "44444444-4444-4444-8444-444444444444"
SELECTED_SOURCE_SURFACE_ID = "55555555-5555-4555-8555-555555555555"
SUBAGENT_PANE_ID = "66666666-6666-4666-8666-666666666666"
SUBAGENT_SURFACE_ID = "77777777-7777-4777-8777-777777777777"

PLACEHOLDER_COMMAND = (
    '/bin/sh -c "printf \\"OMO subagent pane ready: test\\\\n'
    'Focus this pane to attach.\\"; while :; do sleep 86400; done"'
)
ATTACH_COMMAND = (
    '/bin/sh -c "opencode attach http://127.0.0.1:4096 '
    '--session subagent-session --dir /tmp/omo-workspace"'
)


def shell_wrapped(command: str) -> str:
    """Mirror CMUXCLI.tmuxShellInvokedStartCommand: respawn shell-commands are run
    through a POSIX shell (`/bin/sh -c`) so Ghostty's macOS `exec -l <command>`
    execs a shell rather than the raw expression (issue #6447). Quoting mirrors
    tmuxShellQuote (single-quote, with embedded single quotes escaped)."""
    quoted = "'" + command.replace("'", "'\"'\"'") + "'"
    return "/bin/sh -c " + quoted


class FakeCmuxState:
    def __init__(self) -> None:
        self.split_created = False
        self.placeholder_command: str | None = None
        self.respawn_params: list[dict[str, object]] = []
        self.sent_text: list[dict[str, object]] = []

    def handle(self, method: str, params: dict[str, object]) -> dict[str, object]:
        if method == "workspace.list":
            return {
                "workspaces": [
                    {
                        "id": WORKSPACE_ID,
                        "ref": "workspace:1",
                        "index": 1,
                        "title": "omo",
                    }
                ]
            }
        if method == "window.list":
            return {
                "windows": [
                    {
                        "id": WINDOW_ID,
                        "ref": "window:1",
                        "workspace_id": WORKSPACE_ID,
                        "workspace_ref": "workspace:1",
                    }
                ]
            }
        if method == "surface.list":
            surfaces = [
                {
                    "id": SURFACE_ID,
                    "ref": "surface:1",
                    "focused": not self.split_created,
                    "pane_id": PANE_ID,
                    "pane_ref": "pane:1",
                    "title": "leader",
                    "type": "terminal",
                    "tmux_start_command": "echo CALLER_STORED",
                },
                {
                    "id": SELECTED_SOURCE_SURFACE_ID,
                    "ref": "surface:3",
                    "focused": False,
                    "pane_id": PANE_ID,
                    "pane_ref": "pane:1",
                    "title": "selected source tab",
                    "type": "terminal",
                    "tmux_start_command": "echo SELECTED_STORED",
                }
            ]
            if self.split_created:
                surfaces.append(
                    {
                        "id": SUBAGENT_SURFACE_ID,
                        "ref": "surface:2",
                        "focused": True,
                        "pane_id": SUBAGENT_PANE_ID,
                        "pane_ref": "pane:2",
                        "title": "OMO subagent pane ready",
                        "type": "terminal",
                        "tmux_start_command": self.placeholder_command,
                    }
                )
            return {"surfaces": surfaces}
        if method == "surface.current":
            if self.split_created:
                return {
                    "workspace_id": WORKSPACE_ID,
                    "workspace_ref": "workspace:1",
                    "pane_id": SUBAGENT_PANE_ID,
                    "pane_ref": "pane:2",
                    "surface_id": SUBAGENT_SURFACE_ID,
                    "surface_ref": "surface:2",
                    "surface_type": "terminal",
                }
            return {
                "workspace_id": WORKSPACE_ID,
                "workspace_ref": "workspace:1",
                "pane_id": PANE_ID,
                "pane_ref": "pane:1",
                "surface_id": SURFACE_ID,
                "surface_ref": "surface:1",
                "surface_type": "terminal",
            }
        if method == "pane.list":
            panes = [
                {
                    "id": PANE_ID,
                    "ref": "pane:1",
                    "index": 1,
                    "focused": not self.split_created,
                }
            ]
            if self.split_created:
                panes.append(
                    {
                        "id": SUBAGENT_PANE_ID,
                        "ref": "pane:2",
                        "index": 2,
                        "focused": True,
                    }
                )
            return {"panes": panes}
        if method == "pane.surfaces":
            pane_id = str(params.get("pane_id") or "")
            if pane_id == PANE_ID:
                return {
                    "surfaces": [
                        {"id": SELECTED_SOURCE_SURFACE_ID, "selected": True},
                        {"id": SURFACE_ID, "selected": False},
                    ]
                }
            if pane_id == SUBAGENT_PANE_ID:
                return {"surfaces": [{"id": SUBAGENT_SURFACE_ID, "selected": True}]}
            raise RuntimeError(f"unknown pane: {pane_id}")
        if method == "surface.split":
            if params.get("surface_id") != SURFACE_ID:
                raise RuntimeError(f"expected split anchor {SURFACE_ID}, got {params!r}")
            self.split_created = True
            start_command = params.get("tmux_start_command")
            self.placeholder_command = start_command if isinstance(start_command, str) else None
            return {
                "workspace_id": WORKSPACE_ID,
                "surface_id": SUBAGENT_SURFACE_ID,
                "pane_id": SUBAGENT_PANE_ID,
            }
        if method == "surface.respawn":
            self.respawn_params.append(dict(params))
            return {
                "workspace_id": WORKSPACE_ID,
                "surface_id": params.get("surface_id"),
                "type": "terminal",
            }
        if method == "surface.send_text":
            self.sent_text.append(dict(params))
            return {"ok": True}
        if method == "workspace.equalize_splits":
            return {"ok": True}
        raise RuntimeError(f"Unsupported fake cmux method: {method}")


class FakeCmuxHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        while True:
            line = self.rfile.readline()
            if not line:
                return

            request = json.loads(line.decode("utf-8"))
            try:
                result = self.server.state.handle(  # type: ignore[attr-defined]
                    request["method"],
                    request.get("params", {}),
                )
                response = {"ok": True, "result": result, "id": request.get("id")}
            except Exception as exc:
                response = {
                    "ok": False,
                    "error": {"code": "not_found", "message": str(exc)},
                    "id": request.get("id"),
                }

            self.wfile.write((json.dumps(response) + "\n").encode("utf-8"))
            self.wfile.flush()


class FakeCmuxUnixServer(socketserver.ThreadingUnixStreamServer):
    allow_reuse_address = True

    def __init__(self, socket_path: str, state: FakeCmuxState) -> None:
        self.state = state
        super().__init__(socket_path, FakeCmuxHandler)


def run_cli(
    cli_path: str,
    socket_path: Path,
    fake_home: Path,
    args: list[str],
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["CMUX_SOCKET_PATH"] = str(socket_path)
    env["CMUX_WORKSPACE_ID"] = "workspace:1"
    env["CMUX_SURFACE_ID"] = "surface:1"
    env["TMUX_PANE"] = f"%{PANE_ID}"
    env["HOME"] = str(fake_home)
    env["CMUX_OMO_CMUX_BIN"] = cli_path
    return subprocess.run(
        [cli_path, "--socket", str(socket_path), *args],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=30,
    )


def assert_success(proc: subprocess.CompletedProcess[str], label: str) -> None:
    if proc.returncode != 0:
        raise AssertionError(
            f"{label} returned non-zero\n"
            f"stdout={proc.stdout.strip()}\n"
            f"stderr={proc.stderr.strip()}"
        )


def assert_failure(proc: subprocess.CompletedProcess[str], label: str, expected: str) -> None:
    if proc.returncode == 0:
        raise AssertionError(f"{label} unexpectedly succeeded\nstdout={proc.stdout.strip()}")
    combined = f"{proc.stdout}\n{proc.stderr}"
    if expected not in combined:
        raise AssertionError(
            f"{label} did not include {expected!r}\n"
            f"stdout={proc.stdout.strip()}\n"
            f"stderr={proc.stderr.strip()}"
        )


def assert_omo_split_is_listed_and_respawned(
    cli_path: str,
    socket_path: Path,
    fake_home: Path,
    state: FakeCmuxState,
) -> None:
    split = run_cli(
        cli_path,
        socket_path,
        fake_home,
        [
            "__tmux-compat",
            "split-window",
            "-h",
            "-P",
            "-F",
            "#{pane_id}",
            PLACEHOLDER_COMMAND,
        ],
    )
    assert_success(split, "OMO placeholder split")
    subagent_pane_token = split.stdout.strip()
    if not subagent_pane_token.startswith("%"):
        raise AssertionError(f"expected tmux pane token, got {subagent_pane_token!r}")

    listed = run_cli(
        cli_path,
        socket_path,
        fake_home,
        [
            "__tmux-compat",
            "list-panes",
            "-F",
            "#{pane_id},#{pane_active},#{window_active}",
        ],
    )
    assert_success(listed, "OMO list-panes")
    lines = [line.strip() for line in listed.stdout.splitlines() if line.strip()]
    if len(lines) != 2:
        raise AssertionError(f"expected leader and subagent panes, got {lines!r}")
    if f"{subagent_pane_token},1,1" not in lines:
        raise AssertionError(f"expected active subagent pane in list-panes, got {lines!r}")

    state.sent_text.clear()

    non_forced_respawn = run_cli(
        cli_path,
        socket_path,
        fake_home,
        [
            "__tmux-compat",
            "respawn-pane",
            "-t",
            subagent_pane_token,
            ATTACH_COMMAND,
        ],
    )
    assert_failure(non_forced_respawn, "OMO non-forced respawn-pane", "requires -k")
    if state.respawn_params:
        raise AssertionError(f"non-forced respawn must not call surface.respawn: {state.respawn_params!r}")
    if state.sent_text:
        raise AssertionError(f"non-forced respawn must not send text: {state.sent_text!r}")
    state.sent_text.clear()

    empty_respawn = run_cli(
        cli_path,
        socket_path,
        fake_home,
        [
            "__tmux-compat",
            "respawn-pane",
            "-k",
            "-t",
            subagent_pane_token,
        ],
    )
    assert_success(empty_respawn, "OMO empty respawn-pane")
    if len(state.respawn_params) != 1:
        raise AssertionError(f"expected empty respawn to call surface.respawn: {state.respawn_params!r}")
    empty_respawn_params = state.respawn_params[0]
    if empty_respawn_params.get("surface_id") != SUBAGENT_SURFACE_ID:
        raise AssertionError(f"empty respawn targeted wrong surface: {empty_respawn_params!r}")
    if empty_respawn_params.get("command") != shell_wrapped(PLACEHOLDER_COMMAND):
        raise AssertionError(f"empty respawn did not reuse stored command (login-shell-wrapped): {empty_respawn_params!r}")
    if empty_respawn_params.get("tmux_start_command") != PLACEHOLDER_COMMAND:
        raise AssertionError(f"empty respawn did not preserve tmux start metadata: {empty_respawn_params!r}")
    if state.sent_text:
        raise AssertionError(f"empty respawn must replace the pane, not send text: {state.sent_text!r}")
    state.respawn_params.clear()
    state.sent_text.clear()

    respawn = run_cli(
        cli_path,
        socket_path,
        fake_home,
        [
            "__tmux-compat",
            "respawn-pane",
            "-k",
            "-t",
            subagent_pane_token,
            ATTACH_COMMAND,
        ],
    )
    assert_success(respawn, "OMO respawn-pane")
    if len(state.respawn_params) != 1:
        raise AssertionError(f"expected one surface.respawn call, got {state.respawn_params!r}")
    respawn_params = state.respawn_params[0]
    if respawn_params.get("workspace_id") != WORKSPACE_ID:
        raise AssertionError(f"respawn targeted wrong workspace: {respawn_params!r}")
    if respawn_params.get("surface_id") != SUBAGENT_SURFACE_ID:
        raise AssertionError(f"respawn targeted wrong surface: {respawn_params!r}")
    if respawn_params.get("command") != shell_wrapped(ATTACH_COMMAND):
        raise AssertionError(f"respawn carried wrong command (login-shell-wrapped): {respawn_params!r}")
    if respawn_params.get("tmux_start_command") != ATTACH_COMMAND:
        raise AssertionError(f"respawn did not update tmux start metadata: {respawn_params!r}")
    if state.sent_text:
        raise AssertionError(f"respawn must replace the pane, not send text: {state.sent_text!r}")


def assert_caller_pane_respawn_uses_caller_surface(
    cli_path: str,
    socket_path: Path,
    fake_home: Path,
    state: FakeCmuxState,
) -> None:
    respawn = run_cli(
        cli_path,
        socket_path,
        fake_home,
        [
            "__tmux-compat",
            "respawn-pane",
            "-k",
            "-t",
            f"%{PANE_ID}",
            ATTACH_COMMAND,
        ],
    )
    assert_success(respawn, "caller pane respawn-pane")
    if len(state.respawn_params) != 1:
        raise AssertionError(f"expected caller pane respawn to call surface.respawn: {state.respawn_params!r}")
    respawn_params = state.respawn_params[0]
    if respawn_params.get("surface_id") != SURFACE_ID:
        raise AssertionError(
            "caller pane respawn should prefer CMUX_SURFACE_ID over the pane's selected tab: "
            f"{respawn_params!r}"
        )
    state.respawn_params.clear()


def assert_public_respawn_uses_same_surface_lifecycle(
    cli_path: str,
    socket_path: Path,
    fake_home: Path,
    state: FakeCmuxState,
) -> None:
    state.respawn_params.clear()
    state.sent_text.clear()

    public = run_cli(
        cli_path,
        socket_path,
        fake_home,
        [
            "respawn-pane",
            "--workspace",
            "workspace:1",
            "--surface",
            "surface:2",
            "--command",
            "echo TEST_PUBLIC",
        ],
    )
    assert_success(public, "public respawn-pane")
    if len(state.respawn_params) != 1:
        raise AssertionError(f"expected public respawn to call surface.respawn: {state.respawn_params!r}")
    respawn_params = state.respawn_params[0]
    if respawn_params.get("surface_id") != SUBAGENT_SURFACE_ID:
        raise AssertionError(f"public respawn targeted wrong surface: {respawn_params!r}")
    # The public `respawn-pane` CLI reaches the same surface.respawn / Ghostty
    # `exec -l` path, so it shell-wraps its command just like the
    # `__tmux-compat respawn-pane` path.
    if respawn_params.get("command") != shell_wrapped("echo TEST_PUBLIC"):
        raise AssertionError(f"public respawn carried wrong command (login-shell-wrapped): {respawn_params!r}")
    if state.sent_text:
        raise AssertionError(f"public respawn must not send text: {state.sent_text!r}")


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    try:
        with tempfile.TemporaryDirectory(prefix="cmux-omo-respawn-") as td:
            tmp = Path(td)
            socket_path = tmp / "fake-cmux.sock"
            state = FakeCmuxState()
            server = FakeCmuxUnixServer(str(socket_path), state)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            fake_home = tmp / "home"
            fake_home.mkdir(parents=True, exist_ok=True)

            try:
                assert_caller_pane_respawn_uses_caller_surface(
                    cli_path,
                    socket_path,
                    fake_home,
                    state,
                )
                assert_omo_split_is_listed_and_respawned(
                    cli_path,
                    socket_path,
                    fake_home,
                    state,
                )
                assert_public_respawn_uses_same_surface_lifecycle(
                    cli_path,
                    socket_path,
                    fake_home,
                    state,
                )
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)
    except AssertionError as exc:
        print(f"FAIL: {exc}")
        return 1

    print("PASS: OMO tmux shim lists and respawns subagent panes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
