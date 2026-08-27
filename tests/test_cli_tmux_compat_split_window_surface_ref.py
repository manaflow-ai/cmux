#!/usr/bin/env python3
"""
Regression tests for `cmux __tmux-compat split-window`.
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
PANE_ID = "33333333-3333-4333-8333-333333333333"
SURFACE_ID = "44444444-4444-4444-8444-444444444444"
NEW_PANE_ID = "66666666-6666-4666-8666-666666666666"
NEW_SURFACE_ID = "77777777-7777-4777-8777-777777777777"


class FakeCmuxState:
    def __init__(self) -> None:
        self.split_created = False

    def handle(self, method: str, params: dict[str, object]) -> dict[str, object]:
        if method == "workspace.list":
            return {
                "workspaces": [
                    {
                        "id": WORKSPACE_ID,
                        "ref": "workspace:1",
                        "index": 1,
                        "title": "demo",
                    }
                ]
            }
        if method == "surface.list":
            surfaces = [
                {
                    "id": SURFACE_ID,
                    "ref": "surface:1",
                    "focused": True,
                    "pane_id": PANE_ID,
                    "pane_ref": "pane:1",
                    "title": "leader",
                }
            ]
            if self.split_created:
                surfaces.append(
                    {
                        "id": NEW_SURFACE_ID,
                        "ref": "surface:2",
                        "focused": False,
                        "pane_id": NEW_PANE_ID,
                        "pane_ref": "pane:2",
                        "title": "teammate",
                    }
                )
            return {"surfaces": surfaces}
        if method == "surface.current":
            return {
                "workspace_id": WORKSPACE_ID,
                "workspace_ref": "workspace:1",
                "pane_id": PANE_ID,
                "pane_ref": "pane:1",
                "surface_id": SURFACE_ID,
                "surface_ref": "surface:1",
            }
        if method == "pane.list":
            panes = [
                {
                    "id": PANE_ID,
                    "ref": "pane:1",
                    "index": 1,
                }
            ]
            if self.split_created:
                panes.append(
                    {
                        "id": NEW_PANE_ID,
                        "ref": "pane:2",
                        "index": 2,
                    }
                )
            return {"panes": panes}
        if method == "surface.split":
            target_surface = str(params.get("surface_id") or "")
            if target_surface != SURFACE_ID:
                raise RuntimeError(
                    f"expected split target {SURFACE_ID}, got {target_surface!r}"
                )
            self.split_created = True
            return {
                "surface_id": NEW_SURFACE_ID,
                "pane_id": NEW_PANE_ID,
            }
        if method == "surface.close":
            target_surface = str(params.get("surface_id") or "")
            if target_surface != NEW_SURFACE_ID:
                raise RuntimeError(
                    f"expected close target {NEW_SURFACE_ID}, got {target_surface!r}"
                )
            self.split_created = False
            return {
                "workspace_id": WORKSPACE_ID,
                "surface_id": NEW_SURFACE_ID,
            }
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
    env["TMUX_PANE"] = "%pane:1"
    env["HOME"] = str(fake_home)
    return subprocess.run(
        [cli_path, "--socket", str(socket_path), *args],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=30,
    )


def assert_successful_split(
    cli_path: str,
    socket_path: Path,
    fake_home: Path,
    label: str,
) -> None:
    proc = run_cli(
        cli_path,
        socket_path,
        fake_home,
        ["__tmux-compat", "split-window", "-h", "-P", "-F", "#{pane_id}"],
    )
    if proc.returncode != 0:
        raise AssertionError(
            f"{label} returned non-zero\n"
            f"stdout={proc.stdout.strip()}\n"
            f"stderr={proc.stderr.strip()}"
        )
    if proc.stdout.strip() != f"%{NEW_PANE_ID}":
        raise AssertionError(
            f"{label} expected %{NEW_PANE_ID}, got {proc.stdout.strip()!r}"
        )


def assert_resplit_after_close(
    cli_path: str,
    socket_path: Path,
    fake_home: Path,
) -> None:
    assert_successful_split(cli_path, socket_path, fake_home, "initial split-window")

    closed = run_cli(
        cli_path,
        socket_path,
        fake_home,
        ["close-surface", "--workspace", "workspace:1", "--surface", "surface:2"],
    )
    if closed.returncode != 0:
        raise AssertionError(
            "close-surface returned non-zero\n"
            f"stdout={closed.stdout.strip()}\n"
            f"stderr={closed.stderr.strip()}"
        )

    assert_successful_split(cli_path, socket_path, fake_home, "second split-window")


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    try:
        with tempfile.TemporaryDirectory(prefix="cmux-tmux-surface-ref-") as td:
            tmp = Path(td)
            socket_path = tmp / "fake-cmux.sock"
            state = FakeCmuxState()
            server = FakeCmuxUnixServer(str(socket_path), state)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            fake_home = tmp / "home"
            fake_home.mkdir(parents=True, exist_ok=True)

            try:
                assert_resplit_after_close(cli_path, socket_path, fake_home)
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)
    except AssertionError as exc:
        print(f"FAIL: {exc}")
        return 1

    print(
        "PASS: tmux-compat split-window handles caller refs and close/re-split flows"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
