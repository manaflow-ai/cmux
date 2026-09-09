#!/usr/bin/env python3
"""Behavioral contract tests for ``cmux workspace-font-size``."""

from __future__ import annotations

import json
import os
import shutil
import socketserver
import subprocess
import tempfile
import threading
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator

import pytest


WORKSPACE_ID = "11111111-1111-4111-8111-111111111111"
WINDOW_ID = "22222222-2222-4222-8222-222222222222"


class _FontSizeState:
    def __init__(self) -> None:
        self.requests: list[dict[str, object]] = []
        self.lock = threading.Lock()


class _FontSizeHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        while line := self.rfile.readline():
            request = json.loads(line.decode("utf-8"))
            with self.server.state.lock:  # type: ignore[attr-defined]
                self.server.state.requests.append(request)  # type: ignore[attr-defined]
            method = request.get("method")
            params = request.get("params") or {}
            if method == "window.list":
                result = {"windows": [{"id": WINDOW_ID, "ref": "window:2", "index": 2}]}
            elif method == "workspace.list":
                result = {
                    "workspaces": [
                        {"id": WORKSPACE_ID, "ref": "workspace:2", "index": 2}
                    ]
                }
            else:
                result = {
                    "workspace_id": WORKSPACE_ID,
                    "workspace_ref": "workspace:2",
                    "accepted": True,
                    "action": params.get("action"),
                }
            response = {"ok": True, "result": result, "id": request.get("id")}
            self.wfile.write((json.dumps(response) + "\n").encode("utf-8"))
            self.wfile.flush()


class _FontSizeServer(socketserver.ThreadingUnixStreamServer):
    allow_reuse_address = True

    def __init__(self, socket_path: str, state: _FontSizeState) -> None:
        self.state = state
        super().__init__(socket_path, _FontSizeHandler)


@contextmanager
def _fake_socket() -> Iterator[tuple[Path, _FontSizeState]]:
    temp_dir = tempfile.mkdtemp(prefix="cmux-", dir="/tmp")
    socket_path = Path(temp_dir) / "s"
    state = _FontSizeState()
    server = _FontSizeServer(str(socket_path), state)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield socket_path, state
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        shutil.rmtree(temp_dir, ignore_errors=True)


def _cli_path() -> str:
    value = os.environ.get("CMUX_CLI_BIN")
    if not value:
        pytest.skip("set CMUX_CLI_BIN to the isolated CLI binary")
    return value


def _run_cli(
    cli_path: str,
    socket_path: Path,
    *args: str,
    workspace: str | None = None,
    global_window: str | None = None,
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    for key in list(env):
        if key.startswith("CMUX_"):
            env.pop(key)
    env["CMUX_SOCKET_PATH"] = str(socket_path)
    if workspace is None:
        env.pop("CMUX_WORKSPACE_ID", None)
    else:
        env["CMUX_WORKSPACE_ID"] = workspace
    with tempfile.TemporaryDirectory(prefix="cmux-home-", dir="/tmp") as home:
        env["HOME"] = home
        command = [cli_path, "--socket", str(socket_path)]
        if global_window is not None:
            command.extend(["--window", global_window])
        command.extend(args)
        return subprocess.run(
            command,
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=15,
        )


def test_workspace_font_size_sends_action_and_targets_explicit_handles() -> None:
    cli_path = _cli_path()
    with _fake_socket() as (socket_path, state):
        result = _run_cli(
            cli_path,
            socket_path,
            "workspace-font-size",
            "increase",
            "--workspace",
            WORKSPACE_ID,
            "--window",
            WINDOW_ID,
            "--json",
            "--id-format",
            "both",
        )

    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == {
        "workspace_id": WORKSPACE_ID,
        "workspace_ref": "workspace:2",
        "accepted": True,
        "action": "increase",
    }
    assert len(state.requests) == 1
    assert state.requests[0]["method"] == "workspace.font_size"
    assert state.requests[0]["params"] == {
        "action": "increase",
        "workspace_id": WORKSPACE_ID,
        "window_id": WINDOW_ID,
    }


def test_workspace_font_size_uses_ambient_workspace_only_without_window() -> None:
    cli_path = _cli_path()
    with _fake_socket() as (socket_path, state):
        result = _run_cli(
            cli_path,
            socket_path,
            "workspace-font-size",
            "reset",
            workspace=WORKSPACE_ID,
        )

    assert result.returncode == 0, result.stderr
    assert "request accepted" in result.stdout.lower()
    assert state.requests[0]["params"] == {
        "action": "reset",
        "workspace_id": WORKSPACE_ID,
    }


def test_workspace_font_size_explicit_window_suppresses_ambient_workspace() -> None:
    cli_path = _cli_path()
    with _fake_socket() as (socket_path, state):
        result = _run_cli(
            cli_path,
            socket_path,
            "workspace-font-size",
            "decrease",
            "--window",
            WINDOW_ID,
            workspace=WORKSPACE_ID,
        )

    assert result.returncode == 0, result.stderr
    assert state.requests[0]["params"] == {
        "action": "decrease",
        "window_id": WINDOW_ID,
    }


def test_workspace_font_size_normalizes_ref_and_index_handles() -> None:
    cli_path = _cli_path()
    with _fake_socket() as (socket_path, state):
        result = _run_cli(
            cli_path,
            socket_path,
            "workspace-font-size",
            "increase",
            "--workspace",
            "workspace:2",
            "--window",
            "window:2",
        )
    assert result.returncode == 0, result.stderr
    assert state.requests[-1]["method"] == "workspace.font_size"
    assert state.requests[-1]["params"] == {
        "action": "increase",
        "workspace_id": WORKSPACE_ID,
        "window_id": WINDOW_ID,
    }

    with _fake_socket() as (socket_path, state):
        result = _run_cli(
            cli_path,
            socket_path,
            "workspace-font-size",
            "reset",
            "--workspace",
            "2",
            "--window",
            "2",
        )
    assert result.returncode == 0, result.stderr
    assert state.requests[-1]["method"] == "workspace.font_size"
    assert state.requests[-1]["params"] == {
        "action": "reset",
        "workspace_id": WORKSPACE_ID,
        "window_id": WINDOW_ID,
    }


def test_workspace_font_size_honors_global_window_override() -> None:
    cli_path = _cli_path()
    with _fake_socket() as (socket_path, state):
        result = _run_cli(
            cli_path,
            socket_path,
            "workspace-font-size",
            "decrease",
            global_window=WINDOW_ID,
        )
    assert result.returncode == 0, result.stderr
    assert state.requests[-1]["params"] == {
        "action": "decrease",
        "window_id": WINDOW_ID,
    }


@pytest.mark.parametrize(
    ("args", "expected_error"),
    [
        (("workspace-font-size",), "requires increase, decrease, or reset"),
        (("workspace-font-size", "grow"), "Invalid workspace font-size action"),
        (("workspace-font-size", "increase", "--unknown", "value"), "Unknown workspace-font-size argument"),
        (
            ("workspace-font-size", "increase", "--workspace", WORKSPACE_ID, "--workspace", WORKSPACE_ID),
            "Duplicate workspace-font-size argument",
        ),
        (
            ("workspace-font-size", "increase", "--workspace", "--window", WINDOW_ID),
            "--workspace requires a workspace or window id, ref, or index",
        ),
    ],
)
def test_workspace_font_size_rejects_invalid_arguments_without_mutation(
    args: tuple[str, ...], expected_error: str
) -> None:
    cli_path = _cli_path()
    with _fake_socket() as (socket_path, state):
        result = _run_cli(cli_path, socket_path, *args)

    assert result.returncode == 1
    assert result.stderr.startswith("Error: ")
    assert expected_error in result.stderr
    assert not [request for request in state.requests if request.get("method") == "workspace.font_size"]


def test_workspace_font_size_help_describes_scope_and_queueing() -> None:
    cli_path = _cli_path()
    result = subprocess.run(
        [cli_path, "workspace-font-size", "--help"],
        capture_output=True,
        text=True,
        check=False,
        env=os.environ.copy(),
        timeout=15,
    )

    assert result.returncode == 0, result.stderr
    assert "all terminal panels" in result.stdout
    assert "relative 1pt step" in result.stdout
    assert "does not change focus" in result.stdout
