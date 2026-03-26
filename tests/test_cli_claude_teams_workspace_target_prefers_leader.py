#!/usr/bin/env python3
"""
Regression test: `cmux claude-teams` keeps workspace-targeted splits on the leader pane.
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
LEADER_PANE_ID = "33333333-3333-4333-8333-333333333333"
LEADER_SURFACE_ID = "44444444-4444-4444-8444-444444444444"
DISTRACTOR_PANE_ID = "55555555-5555-4555-8555-555555555555"
DISTRACTOR_SURFACE_ID = "66666666-6666-4666-8666-666666666666"
TEAM_PANE_ID = "77777777-7777-4777-8777-777777777777"
TEAM_SURFACE_ID = "88888888-8888-4888-8888-888888888888"


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
        self.identify_params: list[dict[str, object]] = []
        self.split_requests: list[dict[str, str]] = []
        self.workspace = {
            "id": WORKSPACE_ID,
            "ref": "workspace:1",
            "index": 1,
            "title": "demo-team",
        }
        self.window = {
            "id": WINDOW_ID,
            "ref": "window:1",
        }
        self.current_pane_id = DISTRACTOR_PANE_ID
        self.current_surface_id = DISTRACTOR_SURFACE_ID
        self.panes = [
            {
                "id": LEADER_PANE_ID,
                "ref": "pane:1",
                "index": 1,
                "surface_ids": [LEADER_SURFACE_ID],
            },
            {
                "id": DISTRACTOR_PANE_ID,
                "ref": "pane:2",
                "index": 2,
                "surface_ids": [DISTRACTOR_SURFACE_ID],
            },
        ]
        self.surfaces = [
            {
                "id": LEADER_SURFACE_ID,
                "ref": "surface:1",
                "pane_id": LEADER_PANE_ID,
                "title": "leader",
            },
            {
                "id": DISTRACTOR_SURFACE_ID,
                "ref": "surface:2",
                "pane_id": DISTRACTOR_PANE_ID,
                "title": "distractor",
            },
        ]

    def handle(self, method: str, params: dict[str, object]) -> dict[str, object]:
        with self.lock:
            if method == "system.identify":
                self.identify_params.append(params)
                caller = params.get("caller") if isinstance(params.get("caller"), dict) else {}
                resolved_caller: dict[str, object] | None = None
                if caller and caller.get("workspace_id") == WORKSPACE_ID and caller.get("surface_id") == LEADER_SURFACE_ID:
                    resolved_caller = {
                        "window_id": WINDOW_ID,
                        "window_ref": "window:1",
                        "workspace_id": WORKSPACE_ID,
                        "workspace_ref": "workspace:1",
                        "pane_id": LEADER_PANE_ID,
                        "pane_ref": "pane:1",
                        "surface_id": LEADER_SURFACE_ID,
                        "surface_ref": "surface:1",
                        "tab_id": LEADER_SURFACE_ID,
                        "tab_ref": "surface:1",
                        "surface_type": "terminal",
                        "is_browser_surface": False,
                    }
                return {
                    "focused": {
                        "window_id": WINDOW_ID,
                        "window_ref": "window:1",
                        "workspace_id": WORKSPACE_ID,
                        "workspace_ref": "workspace:1",
                        "pane_id": DISTRACTOR_PANE_ID,
                        "pane_ref": "pane:2",
                        "surface_id": DISTRACTOR_SURFACE_ID,
                        "surface_ref": "surface:2",
                        "tab_id": DISTRACTOR_SURFACE_ID,
                        "tab_ref": "surface:2",
                        "surface_type": "terminal",
                        "is_browser_surface": False,
                    },
                    "caller": resolved_caller,
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
                            "focused": surface["id"] == self.current_surface_id,
                        }
                        for surface in self.surfaces
                    ]
                }
            if method == "surface.split":
                self.split_requests.append(
                    {
                        "workspace_id": str(params.get("workspace_id") or ""),
                        "surface_id": str(params.get("surface_id") or ""),
                        "direction": str(params.get("direction") or ""),
                    }
                )
                self.panes.append(
                    {
                        "id": TEAM_PANE_ID,
                        "ref": "pane:3",
                        "index": len(self.panes) + 1,
                        "surface_ids": [TEAM_SURFACE_ID],
                    }
                )
                self.surfaces.append(
                    {
                        "id": TEAM_SURFACE_ID,
                        "ref": "surface:3",
                        "pane_id": TEAM_PANE_ID,
                        "title": "teammate",
                    }
                )
                return {
                    "surface_id": TEAM_SURFACE_ID,
                    "pane_id": TEAM_PANE_ID,
                }
            if method == "pane.focus":
                pane_id = str(params.get("pane_id") or "")
                pane = self._pane_by_id(pane_id)
                self.current_pane_id = pane["id"]
                self.current_surface_id = pane["surface_ids"][0]
                return {"ok": True}
            if method == "surface.send_text":
                return {"ok": True}
            raise RuntimeError(f"Unsupported fake cmux method: {method}")

    def _pane_by_id(self, pane_id: str) -> dict[str, object]:
        for pane in self.panes:
            if pane["id"] == pane_id or pane["ref"] == pane_id:
                return pane
        raise RuntimeError(f"Unknown pane id: {pane_id}")

    def _pane_ref(self, pane_id: str) -> str:
        return self._pane_by_id(pane_id)["ref"]  # type: ignore[return-value]

    def _surface_by_id(self, surface_id: str) -> dict[str, object]:
        for surface in self.surfaces:
            if surface["id"] == surface_id or surface["ref"] == surface_id:
                return surface
        raise RuntimeError(f"Unknown surface id: {surface_id}")

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

    with tempfile.TemporaryDirectory(prefix="ct-workspace-target-", dir="/tmp") as td:
        tmp = Path(td)
        home = tmp / "home"
        home.mkdir(parents=True, exist_ok=True)

        socket_path = tmp / "s.sock"
        state = FakeCmuxState()
        server = FakeCmuxUnixServer(str(socket_path), state)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()

        real_bin = tmp / "real-bin"
        real_bin.mkdir(parents=True, exist_ok=True)

        tmux_pane_log = tmp / "tmux-pane.log"

        make_executable(
            real_bin / "claude",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "${TMUX_PANE-__UNSET__}" > "$FAKE_TMUX_PANE_LOG"
window_target="$(tmux display-message -t "${TMUX_PANE}" -p '#{session_name}:#{window_index}')"
tmux split-window -t "$window_target" -h -P -F '#{pane_id}' >/dev/null
""",
        )

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["PATH"] = f"{real_bin}:/usr/bin:/bin"
        env["CMUX_SOCKET_PATH"] = str(socket_path)
        env["CMUX_WORKSPACE_ID"] = WORKSPACE_ID
        env["CMUX_SURFACE_ID"] = LEADER_SURFACE_ID
        env["FAKE_TMUX_PANE_LOG"] = str(tmux_pane_log)

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

        identify_params = state.identify_params[0] if state.identify_params else {}
        caller = identify_params.get("caller")
        expected_caller = {"workspace_id": WORKSPACE_ID, "surface_id": LEADER_SURFACE_ID}
        if caller != expected_caller:
            print(f"FAIL: expected system.identify caller {expected_caller!r}, got {caller!r}")
            return 1

        tmux_pane = read_text(tmux_pane_log)
        if tmux_pane != f"%{LEADER_PANE_ID}":
            print(f"FAIL: expected TMUX_PANE=%{LEADER_PANE_ID}, got {tmux_pane!r}")
            return 1

        expected_split = [{
            "workspace_id": WORKSPACE_ID,
            "surface_id": LEADER_SURFACE_ID,
            "direction": "right",
        }]
        if state.split_requests != expected_split:
            print(f"FAIL: expected split requests {expected_split!r}, got {state.split_requests!r}")
            return 1

    print("PASS: cmux claude-teams keeps workspace-targeted splits on the leader pane")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
