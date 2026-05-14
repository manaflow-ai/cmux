#!/usr/bin/env python3
"""
Regression test: `cmux claude-teams` main-vertical layout stacks teammates
vertically in a right-side column instead of creating nested horizontal splits.

Simulates Claude creating 3 teammates:
  1. split-window -h (right of leader)
  2. select-layout main-vertical
  3. split-window -h (should redirect to vertical split of T1)
  4. select-layout main-vertical
  5. split-window -h (should redirect to vertical split of T2)
  6. select-layout main-vertical

Expected layout:
  [Leader] [T1]
           [T2]
           [T3]
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

# IDs for dynamically created teammate panes
TEAMMATE_PANE_IDS = [
    "aa000001-0001-4001-8001-000000000001",
    "aa000002-0002-4002-8002-000000000002",
    "aa000003-0003-4003-8003-000000000003",
]
TEAMMATE_SURFACE_IDS = [
    "bb000001-0001-4001-8001-000000000001",
    "bb000002-0002-4002-8002-000000000002",
    "bb000003-0003-4003-8003-000000000003",
]


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


class FakeCmuxState:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.requests: list[str] = []
        self.split_calls: list[dict] = []
        self.split_counter = 0
        self.workspace = {
            "id": INITIAL_WORKSPACE_ID,
            "ref": "workspace:1",
            "index": 1,
            "title": "demo-team",
        }
        self.window = {"id": INITIAL_WINDOW_ID, "ref": "window:1"}
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

    def handle(self, method: str, params: dict) -> dict:
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
                        {"id": p["id"], "ref": p["ref"], "index": p["index"]}
                        for p in self.panes
                    ]
                }
            if method == "pane.surfaces":
                pane_id = str(params.get("pane_id") or "")
                pane = self._pane_by_id(pane_id)
                return {
                    "surfaces": [
                        {
                            "id": sid,
                            "selected": sid == self._selected_surface_for_pane(pane),
                        }
                        for sid in pane["surface_ids"]
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
                            "id": s["id"],
                            "ref": s["ref"],
                            "title": s["title"],
                            "pane_id": s["pane_id"],
                            "pane_ref": self._pane_ref(s["pane_id"]),
                        }
                        for s in self.surfaces
                    ]
                }
            if method == "surface.split":
                idx = self.split_counter
                if idx >= len(TEAMMATE_PANE_IDS):
                    raise RuntimeError(f"Too many splits: {idx}")
                new_pane_id = TEAMMATE_PANE_IDS[idx]
                new_surface_id = TEAMMATE_SURFACE_IDS[idx]
                self.split_counter += 1

                self.split_calls.append({
                    "surface_id": str(params.get("surface_id", "")),
                    "direction": str(params.get("direction", "")),
                    "focus": params.get("focus"),
                })

                self.panes.append({
                    "id": new_pane_id,
                    "ref": f"pane:{idx + 2}",
                    "index": 8 + idx,
                    "surface_ids": [new_surface_id],
                })
                self.surfaces.append({
                    "id": new_surface_id,
                    "ref": f"surface:{idx + 2}",
                    "pane_id": new_pane_id,
                    "title": f"teammate-{idx + 1}",
                })
                return {
                    "surface_id": new_surface_id,
                    "pane_id": new_pane_id,
                }
            if method == "surface.focus":
                self.current_surface_id = str(
                    params.get("surface_id") or self.current_surface_id
                )
                surface = self._surface_by_id(self.current_surface_id)
                self.current_pane_id = surface["pane_id"]
                return {"ok": True}
            if method == "pane.resize":
                return {"ok": True}
            if method == "surface.send_text":
                return {"ok": True}
            raise RuntimeError(f"Unsupported fake cmux method: {method}")

    def _pane_by_id(self, pane_id: str) -> dict:
        for p in self.panes:
            if p["id"] == pane_id or p["ref"] == pane_id:
                return p
        raise RuntimeError(f"Unknown pane id: {pane_id}")

    def _surface_by_id(self, surface_id: str) -> dict:
        for s in self.surfaces:
            if s["id"] == surface_id or s["ref"] == surface_id:
                return s
        raise RuntimeError(f"Unknown surface id: {surface_id}")

    def _pane_ref(self, pane_id: str) -> str:
        return self._pane_by_id(pane_id)["ref"]

    def _surface_ref(self, surface_id: str) -> str:
        return self._surface_by_id(surface_id)["ref"]

    def _selected_surface_for_pane(self, pane: dict) -> str:
        sids = pane["surface_ids"]
        return sids[0] if sids else ""


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
                "result": self.server.state.handle(
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

    with tempfile.TemporaryDirectory(prefix="cmux-claude-teams-mv-") as td:
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

        # Fake claude binary that creates 3 teammates using the same flow
        # Claude uses: split-window -h, select-layout main-vertical, repeat.
        make_executable(
            real_bin / "claude",
            """#!/usr/bin/env bash
set -euo pipefail

# Get window target (session:window_index)
window_target="$(tmux display-message -t "${TMUX_PANE}" -p '#{session_name}:#{window_index}')"

# Teammate 1: horizontal split right
t1="$(tmux split-window -t "${TMUX_PANE}" -h -l 70% -P -F '#{pane_id}')"
tmux select-layout -t "$window_target" main-vertical
tmux resize-pane -t "${TMUX_PANE}" -x 30%

# Teammate 2: horizontal split right (should redirect to vertical)
t2="$(tmux split-window -t "${TMUX_PANE}" -h -l 70% -P -F '#{pane_id}')"
tmux select-layout -t "$window_target" main-vertical
tmux resize-pane -t "${TMUX_PANE}" -x 30%

# Teammate 3: horizontal split right (should redirect to vertical)
t3="$(tmux split-window -t "${TMUX_PANE}" -h -l 70% -P -F '#{pane_id}')"
tmux select-layout -t "$window_target" main-vertical
tmux resize-pane -t "${TMUX_PANE}" -x 30%

# Write results for verification
printf '%s\\n%s\\n%s\\n' "$t1" "$t2" "$t3" > "$RESULT_LOG"
""",
        )

        result_log = tmp / "result.log"

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["PATH"] = f"{real_bin}:/usr/bin:/bin"
        env["CMUX_SOCKET_PATH"] = str(socket_path)
        env["RESULT_LOG"] = str(result_log)

        try:
            proc = subprocess.run(
                [cli_path, "claude-teams", "--version"],
                capture_output=True,
                text=True,
                check=False,
                env=env,
                timeout=30,
            )
        except subprocess.TimeoutExpired:
            print("FAIL: timed out")
            return 1
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

        if proc.returncode != 0:
            print(f"FAIL: exit={proc.returncode}")
            print(f"stdout={proc.stdout.strip()}")
            print(f"stderr={proc.stderr.strip()}")
            return 1

        # Verify split calls
        if len(state.split_calls) != 3:
            print(f"FAIL: expected 3 splits, got {len(state.split_calls)}")
            for i, call in enumerate(state.split_calls):
                print(f"  split[{i}]: {call}")
            return 1

        # Split 1: should be a normal right split of the leader surface
        s1 = state.split_calls[0]
        if s1["direction"] != "right":
            print(f"FAIL: split[0] expected direction=right, got {s1['direction']}")
            return 1
        if s1["surface_id"] != INITIAL_SURFACE_ID:
            print(
                f"FAIL: split[0] expected surface_id={INITIAL_SURFACE_ID}, "
                f"got {s1['surface_id']}"
            )
            return 1

        # Split 2: should be redirected to a DOWN split of T1's surface
        s2 = state.split_calls[1]
        if s2["direction"] != "down":
            print(
                f"FAIL: split[1] expected direction=down (main-vertical redirect), "
                f"got {s2['direction']}"
            )
            return 1
        if s2["surface_id"] != TEAMMATE_SURFACE_IDS[0]:
            print(
                f"FAIL: split[1] expected surface_id={TEAMMATE_SURFACE_IDS[0]} "
                f"(T1), got {s2['surface_id']}"
            )
            return 1

        # Split 3: should be redirected to a DOWN split of T2's surface
        s3 = state.split_calls[2]
        if s3["direction"] != "down":
            print(
                f"FAIL: split[2] expected direction=down (main-vertical redirect), "
                f"got {s3['direction']}"
            )
            return 1
        if s3["surface_id"] != TEAMMATE_SURFACE_IDS[1]:
            print(
                f"FAIL: split[2] expected surface_id={TEAMMATE_SURFACE_IDS[1]} "
                f"(T2), got {s3['surface_id']}"
            )
            return 1

        # All splits should have focus=false
        for i, call in enumerate(state.split_calls):
            if call["focus"] is not False:
                print(f"FAIL: split[{i}] expected focus=false, got {call['focus']}")
                return 1

        # Focus should remain on leader
        if state.current_pane_id != INITIAL_PANE_ID:
            print(
                f"FAIL: focus moved from leader pane to {state.current_pane_id}"
            )
            return 1

    print("PASS: main-vertical layout stacks teammates vertically")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
