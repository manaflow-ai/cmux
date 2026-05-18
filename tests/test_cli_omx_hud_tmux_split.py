#!/usr/bin/env python3
"""
Regression tests for OMX HUD panes through cmux's tmux compatibility shim.
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
HUD_PANE_ID = "66666666-6666-4666-8666-666666666666"
HUD_SURFACE_ID = "77777777-7777-4777-8777-777777777777"


class FakeCmuxState:
    def __init__(self) -> None:
        self.split_created = False
        self.hud_rows = 12
        self.split_params: list[dict[str, object]] = []
        self.resize_params: list[dict[str, object]] = []
        self.equalize_params: list[dict[str, object]] = []
        self.sent_text: list[str] = []
        self.hud_tmux_start_command: str | None = None

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
                        "id": HUD_SURFACE_ID,
                        "ref": "surface:2",
                        "focused": False,
                        "pane_id": HUD_PANE_ID,
                        "pane_ref": "pane:2",
                        "title": "omx hud",
                        "tmux_start_command": self.hud_tmux_start_command,
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
                    "rows": 32,
                    "columns": 120,
                    "cell_height_px": 18,
                    "cell_width_px": 9,
                }
            ]
            if self.split_created:
                panes.append(
                    {
                        "id": HUD_PANE_ID,
                        "ref": "pane:2",
                        "index": 2,
                        "rows": self.hud_rows,
                        "columns": 120,
                        "cell_height_px": 18,
                        "cell_width_px": 9,
                    }
                )
            return {"panes": panes}
        if method == "pane.surfaces":
            pane_id = str(params.get("pane_id") or "")
            if pane_id == PANE_ID:
                return {"surfaces": [{"id": SURFACE_ID, "selected": True}]}
            if pane_id == HUD_PANE_ID:
                return {"surfaces": [{"id": HUD_SURFACE_ID, "selected": True}]}
            raise RuntimeError(f"unknown pane: {pane_id}")
        if method == "surface.split":
            self.split_params.append(dict(params))
            self.split_created = True
            start_command = params.get("tmux_start_command")
            self.hud_tmux_start_command = start_command if isinstance(start_command, str) else None
            return {
                "surface_id": HUD_SURFACE_ID,
                "pane_id": HUD_PANE_ID,
            }
        if method == "pane.resize":
            self.resize_params.append(dict(params))
            if params.get("pane_id") == HUD_PANE_ID:
                if params.get("absolute_axis") == "vertical":
                    self.hud_rows = int(params.get("target_pixels") or 0) // 18
                else:
                    direction = str(params.get("direction") or "")
                    amount = int(params.get("amount") or 0)
                    if direction == "up":
                        self.hud_rows -= amount // 18
                    elif direction == "down":
                        self.hud_rows += amount // 18
            return {"ok": True}
        if method == "workspace.equalize_splits":
            self.equalize_params.append(dict(params))
            return {"ok": True}
        if method == "surface.send_text":
            self.sent_text.append(str(params.get("text") or ""))
            return {"ok": True}
        if method == "surface.read_text":
            if params.get("surface_id") == HUD_SURFACE_ID:
                return {"text": "[OMX#0.15.3] turns:1 | session:23s | last:12s ago\n"}
            return {"text": ""}
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
    env["CMUX_OMX_CMUX_BIN"] = cli_path
    return subprocess.run(
        [cli_path, "--socket", str(socket_path), *args],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=30,
    )


def omx_hud_split_args(cwd: Path) -> list[str]:
    return [
        "__tmux-compat",
        "split-window",
        "-v",
        "-l",
        "4",
        "-d",
        "-c",
        str(cwd),
        "-P",
        "-F",
        "#{pane_id}",
        "node '/opt/oh-my-codex/dist/omx.js' hud --watch",
    ]


def assert_omx_hud_splits_down_with_compact_size(
    cli_path: str,
    socket_path: Path,
    fake_home: Path,
    cwd: Path,
    state: FakeCmuxState,
) -> None:
    proc = run_cli(cli_path, socket_path, fake_home, omx_hud_split_args(cwd))
    if proc.returncode != 0:
        raise AssertionError(
            "HUD split returned non-zero\n"
            f"stdout={proc.stdout.strip()}\n"
            f"stderr={proc.stderr.strip()}"
        )
    if proc.stdout.strip() != f"%{HUD_PANE_ID}":
        raise AssertionError(
            f"expected split-window to print %{HUD_PANE_ID}, got {proc.stdout.strip()!r}"
        )
    if len(state.split_params) != 1:
        raise AssertionError(f"expected one surface.split call, got {state.split_params!r}")
    split = state.split_params[0]
    if split.get("direction") != "down":
        raise AssertionError(f"expected HUD direction down, got {split!r}")
    if split.get("focus") is not False:
        raise AssertionError(f"expected detached HUD split, got {split!r}")
    if split.get("surface_id") != SURFACE_ID:
        raise AssertionError(f"expected HUD split to anchor to the caller surface, got {split!r}")
    if split.get("working_directory") != str(cwd):
        raise AssertionError(f"expected HUD split to carry the requested cwd, got {split!r}")
    divider = split.get("initial_divider_position")
    if not isinstance(divider, (float, int)) or abs(float(divider) - 0.875) > 0.001:
        raise AssertionError(f"expected HUD split to request a compact bottom divider, got {split!r}")
    if state.equalize_params:
        raise AssertionError(f"HUD split should not equalize teammate columns: {state.equalize_params!r}")
    startup_script = split.get("initial_command")
    if not isinstance(startup_script, str) or not startup_script:
        raise AssertionError(f"expected HUD command to launch as an initial pane command, got {split!r}")
    startup_path = Path(startup_script)
    if not startup_path.exists():
        raise AssertionError(f"expected generated HUD startup script to exist: {startup_script}")
    startup_text = startup_path.read_text(encoding="utf-8")
    if f"cd -- '{cwd}'" not in startup_text:
        raise AssertionError(f"expected HUD startup script to cd to project cwd, got {startup_text!r}")
    if "hud --watch" not in startup_text:
        raise AssertionError(f"expected HUD startup script to run the watch command, got {startup_text!r}")
    tmux_start_command = split.get("tmux_start_command")
    if not isinstance(tmux_start_command, str) or "hud --watch" not in tmux_start_command:
        raise AssertionError(f"expected HUD tmux start command metadata, got {split!r}")
    if state.sent_text:
        raise AssertionError(f"HUD command should not be typed into a shell: {state.sent_text!r}")


def assert_omx_hud_is_visible_to_tmux_pane_formats(
    cli_path: str,
    socket_path: Path,
    fake_home: Path,
) -> None:
    proc = run_cli(
        cli_path,
        socket_path,
        fake_home,
        [
            "__tmux-compat",
            "list-panes",
            "-t",
            f"%{PANE_ID}",
            "-F",
            "#{pane_id}\t#{pane_current_command}\t#{pane_start_command}",
        ],
    )
    if proc.returncode != 0:
        raise AssertionError(
            "HUD pane format query returned non-zero\n"
            f"stdout={proc.stdout.strip()}\n"
            f"stderr={proc.stderr.strip()}"
        )

    lines = [line for line in proc.stdout.splitlines() if line.strip()]
    hud_lines = [line for line in lines if line.startswith(f"%{HUD_PANE_ID}\t")]
    if len(hud_lines) != 1:
        raise AssertionError(f"expected one formatted HUD pane line, got {lines!r}")
    fields = hud_lines[0].split("\t")
    if len(fields) != 3:
        raise AssertionError(f"expected three tmux format fields, got {hud_lines[0]!r}")
    if fields[1] != "node":
        raise AssertionError(f"expected pane_current_command=node, got {hud_lines[0]!r}")
    if "hud --watch" not in fields[2]:
        raise AssertionError(f"expected pane_start_command to expose HUD watch command, got {hud_lines[0]!r}")


def assert_omx_hud_start_command_visible_to_legacy_tmux_pane_format(
    cli_path: str,
    socket_path: Path,
    fake_home: Path,
) -> None:
    proc = run_cli(
        cli_path,
        socket_path,
        fake_home,
        [
            "__tmux-compat",
            "list-panes",
            "-t",
            f"%{PANE_ID}",
            "-F",
            "#{pane_id}\t#{pane_start_command}",
        ],
    )
    if proc.returncode != 0:
        raise AssertionError(
            "Legacy HUD pane format query returned non-zero\n"
            f"stdout={proc.stdout.strip()}\n"
            f"stderr={proc.stderr.strip()}"
        )

    lines = [line for line in proc.stdout.splitlines() if line.strip()]
    hud_lines = [line for line in lines if line.startswith(f"%{HUD_PANE_ID}\t")]
    if len(hud_lines) != 1:
        raise AssertionError(f"expected one formatted HUD pane line, got {lines!r}")
    fields = hud_lines[0].split("\t")
    if len(fields) != 2:
        raise AssertionError(f"expected two tmux format fields, got {hud_lines[0]!r}")
    if "hud --watch" not in fields[1]:
        raise AssertionError(f"expected legacy pane_start_command to expose HUD watch command, got {hud_lines[0]!r}")


def assert_absolute_height_resize_uses_row_cell_size(
    cli_path: str,
    socket_path: Path,
    fake_home: Path,
    state: FakeCmuxState,
) -> None:
    baseline = len(state.resize_params)
    proc = run_cli(
        cli_path,
        socket_path,
        fake_home,
        ["__tmux-compat", "resize-pane", "-t", f"%{PANE_ID}", "-y", "20"],
    )
    if proc.returncode != 0:
        raise AssertionError(
            "absolute height resize returned non-zero\n"
            f"stdout={proc.stdout.strip()}\n"
            f"stderr={proc.stderr.strip()}"
        )

    new_resize_params = state.resize_params[baseline:]
    if len(new_resize_params) != 1:
        raise AssertionError(f"expected one absolute height resize, got {new_resize_params!r}")
    params = new_resize_params[0]
    if params.get("pane_id") != PANE_ID:
        raise AssertionError(f"absolute height resize targeted wrong pane: {params!r}")
    if params.get("absolute_axis") != "vertical" or params.get("target_pixels") != 20 * 18:
        raise AssertionError(f"absolute height resize did not use row cell size: {params!r}")


def assert_omx_hud_absolute_width_resize_still_applies(
    cli_path: str,
    socket_path: Path,
    fake_home: Path,
    state: FakeCmuxState,
) -> None:
    baseline = len(state.resize_params)
    proc = run_cli(
        cli_path,
        socket_path,
        fake_home,
        ["__tmux-compat", "resize-pane", "-t", f"%{HUD_PANE_ID}", "-x", "80"],
    )
    if proc.returncode != 0:
        raise AssertionError(
            "HUD absolute width resize returned non-zero\n"
            f"stdout={proc.stdout.strip()}\n"
            f"stderr={proc.stderr.strip()}"
        )

    new_resize_params = state.resize_params[baseline:]
    if len(new_resize_params) != 1:
        raise AssertionError(f"expected one HUD absolute width resize, got {new_resize_params!r}")
    params = new_resize_params[0]
    if params.get("pane_id") != HUD_PANE_ID:
        raise AssertionError(f"HUD absolute width resize targeted wrong pane: {params!r}")
    if params.get("absolute_axis") != "horizontal" or params.get("target_pixels") != 80 * 9:
        raise AssertionError(f"HUD absolute width resize did not use column cell size: {params!r}")


def assert_omx_hud_absolute_height_resize_does_not_override_user_layout(
    cli_path: str,
    socket_path: Path,
    fake_home: Path,
    state: FakeCmuxState,
) -> None:
    baseline = len(state.resize_params)
    proc = run_cli(
        cli_path,
        socket_path,
        fake_home,
        ["__tmux-compat", "resize-pane", "-t", f"%{HUD_PANE_ID}", "-y", "4"],
    )
    if proc.returncode != 0:
        raise AssertionError(
            "HUD absolute resize returned non-zero\n"
            f"stdout={proc.stdout.strip()}\n"
            f"stderr={proc.stderr.strip()}"
        )
    new_resize_params = state.resize_params[baseline:]
    if new_resize_params:
        raise AssertionError(f"HUD absolute resize should not override an existing layout: {new_resize_params!r}")
    if state.hud_rows != 12:
        raise AssertionError(f"expected fake HUD rows to remain user-controlled, got {state.hud_rows}")


def assert_omx_hud_feature_probe_is_supported(
    cli_path: str,
    socket_path: Path,
    fake_home: Path,
) -> None:
    proc = run_cli(
        cli_path,
        socket_path,
        fake_home,
        ["__tmux-compat", "show-options", "-sv", "extended-keys"],
    )
    if proc.returncode != 0:
        raise AssertionError(
            "HUD feature probe returned non-zero\n"
            f"stdout={proc.stdout.strip()}\n"
            f"stderr={proc.stderr.strip()}"
        )
    if proc.stdout.strip() != "on":
        raise AssertionError(f"expected extended-keys probe to print on, got {proc.stdout!r}")


def assert_omx_hud_unsupported_feature_probe_fails(
    cli_path: str,
    socket_path: Path,
    fake_home: Path,
) -> None:
    proc = run_cli(
        cli_path,
        socket_path,
        fake_home,
        ["__tmux-compat", "show-options", "-sv", "display-time"],
    )
    if proc.returncode == 0:
        raise AssertionError(f"unsupported show-options probe should fail, stdout={proc.stdout!r}")


def assert_disabled_omx_hud_does_not_split(
    cli_path: str,
    socket_path: Path,
    fake_home: Path,
    cwd: Path,
    state: FakeCmuxState,
) -> None:
    config_dir = cwd / ".omx"
    config_dir.mkdir(parents=True, exist_ok=True)
    (config_dir / "hud-config.json").write_text('{"enabled": false}\n', encoding="utf-8")

    proc = run_cli(cli_path, socket_path, fake_home, omx_hud_split_args(cwd))
    if proc.returncode != 0:
        raise AssertionError(
            "disabled HUD split returned non-zero\n"
            f"stdout={proc.stdout.strip()}\n"
            f"stderr={proc.stderr.strip()}"
        )
    if proc.stdout.strip():
        raise AssertionError(f"disabled HUD split should not print a pane id: {proc.stdout!r}")
    if state.split_params:
        raise AssertionError(f"disabled HUD should not create a split: {state.split_params!r}")
    if state.resize_params or state.sent_text or state.equalize_params:
        raise AssertionError("disabled HUD should not resize, equalize, or launch a command")


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    try:
        with tempfile.TemporaryDirectory(prefix="cmux-omx-hud-split-") as td:
            tmp = Path(td)
            socket_path = tmp / "fake-cmux.sock"
            fake_home = tmp / "home"
            fake_home.mkdir(parents=True, exist_ok=True)
            cwd = tmp / "project"
            cwd.mkdir(parents=True, exist_ok=True)

            state = FakeCmuxState()
            server = FakeCmuxUnixServer(str(socket_path), state)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                assert_omx_hud_feature_probe_is_supported(cli_path, socket_path, fake_home)
                assert_omx_hud_unsupported_feature_probe_fails(cli_path, socket_path, fake_home)
                assert_omx_hud_splits_down_with_compact_size(
                    cli_path,
                    socket_path,
                    fake_home,
                    cwd,
                    state,
                )
                assert_absolute_height_resize_uses_row_cell_size(
                    cli_path,
                    socket_path,
                    fake_home,
                    state,
                )
                assert_omx_hud_is_visible_to_tmux_pane_formats(
                    cli_path,
                    socket_path,
                    fake_home,
                )

                state.hud_tmux_start_command = None
                assert_omx_hud_start_command_visible_to_legacy_tmux_pane_format(
                    cli_path,
                    socket_path,
                    fake_home,
                )
                assert_omx_hud_absolute_width_resize_still_applies(
                    cli_path,
                    socket_path,
                    fake_home,
                    state,
                )
                assert_omx_hud_absolute_height_resize_does_not_override_user_layout(
                    cli_path,
                    socket_path,
                    fake_home,
                    state,
                )
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)

        with tempfile.TemporaryDirectory(prefix="cmux-omx-hud-disabled-") as td:
            tmp = Path(td)
            socket_path = tmp / "fake-cmux.sock"
            fake_home = tmp / "home"
            fake_home.mkdir(parents=True, exist_ok=True)
            cwd = tmp / "project"
            cwd.mkdir(parents=True, exist_ok=True)

            state = FakeCmuxState()
            server = FakeCmuxUnixServer(str(socket_path), state)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                assert_disabled_omx_hud_does_not_split(
                    cli_path,
                    socket_path,
                    fake_home,
                    cwd,
                    state,
                )
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)
    except AssertionError as exc:
        print(f"FAIL: {exc}")
        return 1

    print("PASS: OMX HUD tmux splits attach to the bottom and respect disabled config")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
