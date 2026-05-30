#!/usr/bin/env python3
"""
Regression test: `cmux claude-teams` supports Claude's tmux teammate flow.
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
INITIAL_WORKSPACE_ID = "11111111-1111-4111-8111-111111111111"
INITIAL_WINDOW_ID = "22222222-2222-4222-8222-222222222222"
INITIAL_PANE_ID = "33333333-3333-4333-8333-333333333333"
INITIAL_SURFACE_ID = "44444444-4444-4444-8444-444444444444"
INITIAL_TAB_ID = "55555555-5555-4555-8555-555555555555"
NEW_PANE_ID = "66666666-6666-4666-8666-666666666666"
NEW_SURFACE_ID = "77777777-7777-4777-8777-777777777777"


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def read_text(path: Path) -> str:
    if not path.exists():
        return ""
    return path.read_text(encoding="utf-8").strip()


class FakeCmuxState:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.requests: list[str] = []
        self.workspace = {
            "id": INITIAL_WORKSPACE_ID,
            "ref": "workspace:1",
            "index": 1,
            "title": "demo-team",
        }
        self.window = {
            "id": INITIAL_WINDOW_ID,
            "ref": "window:1",
        }
        self.current_pane_id = INITIAL_PANE_ID
        self.current_surface_id = INITIAL_SURFACE_ID
        self.panes = [
            {
                "id": INITIAL_PANE_ID,
                "ref": "pane:1",
                "index": 7,
                "surface_ids": [INITIAL_SURFACE_ID],
            }
        ]
        self.surfaces = [
            {
                "id": INITIAL_SURFACE_ID,
                "ref": "surface:1",
                "pane_id": INITIAL_PANE_ID,
                "title": "leader",
            }
        ]

    def handle(self, method: str, params: dict[str, object]) -> dict[str, object]:
        with self.lock:
            self.requests.append(method)
            if method == "system.identify":
                return {
                    "socket_path": str(params.get("socket_path", "")),
                    "focused": {
                        "workspace_id": self.workspace["id"],
                        "workspace_ref": self.workspace["ref"],
                        "window_id": self.window["id"],
                        "window_ref": self.window["ref"],
                        "pane_id": self.current_pane_id,
                        "pane_ref": self._pane_ref(self.current_pane_id),
                        "surface_id": self.current_surface_id,
                        "surface_ref": self._surface_ref(self.current_surface_id),
                        "tab_id": INITIAL_TAB_ID,
                        "tab_ref": "tab:1",
                        "surface_type": "terminal",
                        "is_browser_surface": False,
                    },
                }
            if method == "workspace.current":
                return {
                    "workspace_id": self.workspace["id"],
                    "workspace_ref": self.workspace["ref"],
                }
            if method == "workspace.list":
                return {
                    "workspaces": [
                        {
                            "id": self.workspace["id"],
                            "ref": self.workspace["ref"],
                            "index": self.workspace["index"],
                            "title": self.workspace["title"],
                        }
                    ]
                }
            if method == "window.list":
                return {
                    "windows": [
                        {
                            "id": self.window["id"],
                            "ref": self.window["ref"],
                            "workspace_id": self.workspace["id"],
                            "workspace_ref": self.workspace["ref"],
                        }
                    ]
                }
            if method == "pane.list":
                return {
                    "panes": [
                        {
                            "id": pane["id"],
                            "ref": pane["ref"],
                            "index": pane["index"],
                        }
                        for pane in self.panes
                    ]
                }
            if method == "pane.surfaces":
                pane_id = str(params.get("pane_id") or "")
                pane = self._pane_by_id(pane_id)
                return {
                    "surfaces": [
                        {
                            "id": surface_id,
                            "selected": surface_id == self.current_surface_id,
                        }
                        for surface_id in pane["surface_ids"]
                    ]
                }
            if method == "surface.current":
                return {
                    "workspace_id": self.workspace["id"],
                    "workspace_ref": self.workspace["ref"],
                    "pane_id": self.current_pane_id,
                    "pane_ref": self._pane_ref(self.current_pane_id),
                    "surface_id": self.current_surface_id,
                    "surface_ref": self._surface_ref(self.current_surface_id),
                }
            if method == "surface.list":
                return {
                    "surfaces": [
                        {
                            "id": surface["id"],
                            "ref": surface["ref"],
                            "title": surface["title"],
                            "pane_id": surface["pane_id"],
                            "pane_ref": self._pane_ref(surface["pane_id"]),
                        }
                        for surface in self.surfaces
                    ]
                }
            if method == "surface.split":
                self.panes.append(
                    {
                        "id": NEW_PANE_ID,
                        "ref": "pane:2",
                        "index": 8,
                        "surface_ids": [NEW_SURFACE_ID],
                    }
                )
                self.surfaces.append(
                    {
                        "id": NEW_SURFACE_ID,
                        "ref": "surface:2",
                        "pane_id": NEW_PANE_ID,
                        "title": "teammate",
                    }
                )
                return {
                    "surface_id": NEW_SURFACE_ID,
                    "pane_id": NEW_PANE_ID,
                }
            if method == "surface.focus":
                self.current_surface_id = str(params.get("surface_id") or self.current_surface_id)
                surface = self._surface_by_id(self.current_surface_id)
                self.current_pane_id = surface["pane_id"]
                return {"ok": True}
            if method == "pane.resize":
                return {"ok": True}
            if method == "surface.send_text":
                return {"ok": True}
            raise RuntimeError(f"Unsupported fake cmux method: {method}")

    def _pane_by_id(self, pane_id: str) -> dict[str, object]:
        for pane in self.panes:
            if pane["id"] == pane_id or pane["ref"] == pane_id:
                return pane
        raise RuntimeError(f"Unknown pane id: {pane_id}")

    def _surface_by_id(self, surface_id: str) -> dict[str, object]:
        for surface in self.surfaces:
            if surface["id"] == surface_id or surface["ref"] == surface_id:
                return surface
        raise RuntimeError(f"Unknown surface id: {surface_id}")

    def _pane_ref(self, pane_id: str) -> str:
        return self._pane_by_id(pane_id)["ref"]  # type: ignore[return-value]

    def _surface_ref(self, surface_id: str) -> str:
        return self._surface_by_id(surface_id)["ref"]  # type: ignore[return-value]


class FakeCmuxUnixServer(socketserver.ThreadingUnixStreamServer):
    allow_reuse_address = True

    def __init__(self, socket_path: str, state: FakeCmuxState) -> None:
        self.state = state
        super().__init__(socket_path, FakeCmuxHandler)


class FakeCmuxHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        while True:
            line = self.rfile.readline()
            if not line:
                return
            request = json.loads(line.decode("utf-8"))
            response = {
                "ok": True,
                "result": self.server.state.handle(  # type: ignore[attr-defined]
                    request["method"],
                    request.get("params", {}),
                ),
                "id": request.get("id"),
            }
            self.wfile.write((json.dumps(response) + "\n").encode("utf-8"))
            self.wfile.flush()


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(prefix="cmux-claude-teams-seq-") as td:
        tmp = Path(td)
        home = tmp / "home"
        home.mkdir(parents=True, exist_ok=True)

        socket_path = tmp / "fake-cmux.sock"
        state = FakeCmuxState()
        server = FakeCmuxUnixServer(str(socket_path), state)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()

        real_bin = tmp / "real-bin"
        real_bin.mkdir(parents=True, exist_ok=True)

        tmux_pane_log = tmp / "tmux-pane.log"
        tmux_socket_log = tmp / "tmux-socket.log"
        window_target_log = tmp / "window-target.log"
        split_pane_log = tmp / "split-pane.log"
        pane_list_log = tmp / "pane-list.log"

        make_executable(
            real_bin / "claude",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "${TMUX_PANE-__UNSET__}" > "$FAKE_TMUX_PANE_LOG"
printf '%s\\n' "${CMUX_SOCKET_PATH-__UNSET__}" > "$FAKE_SOCKET_LOG"
window_target="$(tmux display-message -t "${TMUX_PANE}" -p '#{session_name}:#{window_index}')"
printf '%s\\n' "$window_target" > "$FAKE_WINDOW_TARGET_LOG"
split_pane="$(tmux split-window -t "${TMUX_PANE}" -h -l 70% -P -F '#{pane_id}')"
printf '%s\\n' "$split_pane" > "$FAKE_SPLIT_PANE_LOG"
tmux select-layout -t "$window_target" main-vertical
tmux resize-pane -t "${TMUX_PANE}" -x 30%
tmux list-panes -t "$window_target" -F '#{pane_id}' > "$FAKE_PANE_LIST_LOG"
""",
        )

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["PATH"] = f"{real_bin}:/usr/bin:/bin"
        env["CMUX_SOCKET_PATH"] = str(socket_path)
        env["FAKE_TMUX_PANE_LOG"] = str(tmux_pane_log)
        env["FAKE_SOCKET_LOG"] = str(tmux_socket_log)
        env["FAKE_WINDOW_TARGET_LOG"] = str(window_target_log)
        env["FAKE_SPLIT_PANE_LOG"] = str(split_pane_log)
        env["FAKE_PANE_LIST_LOG"] = str(pane_list_log)

        try:
            proc = subprocess.run(
                [cli_path, "claude-teams", "--version"],
                capture_output=True,
                text=True,
                check=False,
                env=env,
                timeout=30,
            )
        except subprocess.TimeoutExpired as exc:
            print("FAIL: `cmux claude-teams --version` timed out")
            print(f"cmd={exc.cmd!r}")
            return 1
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

        if proc.returncode != 0:
            print("FAIL: `cmux claude-teams --version` exited non-zero")
            print(f"exit={proc.returncode}")
            print(f"stdout={proc.stdout.strip()}")
            print(f"stderr={proc.stderr.strip()}")
            return 1

        tmux_pane = read_text(tmux_pane_log)
        if tmux_pane != f"%{INITIAL_PANE_ID}":
            print(f"FAIL: expected TMUX_PANE=%{INITIAL_PANE_ID}, got {tmux_pane!r}")
            return 1

        socket_value = read_text(tmux_socket_log)
        if socket_value != str(socket_path):
            print(f"FAIL: expected CMUX_SOCKET_PATH={socket_path}, got {socket_value!r}")
            return 1

        window_target = read_text(window_target_log)
        if window_target != "cmux:1":
            print(f"FAIL: expected tmux window target 'cmux:1', got {window_target!r}")
            return 1

        split_pane = read_text(split_pane_log)
        if split_pane != f"%{NEW_PANE_ID}":
            print(f"FAIL: expected split-window to print %{NEW_PANE_ID}, got {split_pane!r}")
            return 1

        pane_lines = pane_list_log.read_text(encoding="utf-8").splitlines()
        expected_panes = [f"%{INITIAL_PANE_ID}", f"%{NEW_PANE_ID}"]
        if pane_lines != expected_panes:
            print(f"FAIL: expected list-panes output {expected_panes!r}, got {pane_lines!r}")
            return 1

        if state.current_pane_id != INITIAL_PANE_ID:
            print(
                "FAIL: expected split-window to keep the leader pane focused, "
                f"got current pane {state.current_pane_id!r}"
            )
            return 1

        if "surface.send_text" in state.requests:
            print("FAIL: split-window treated '-l 70%' like shell text and called surface.send_text")
            print(f"requests={state.requests!r}")
            return 1

    print("PASS: cmux claude-teams supports Claude's tmux teammate flow")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
