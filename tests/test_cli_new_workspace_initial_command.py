#!/usr/bin/env python3
"""Regression: `new-workspace --command` should use `workspace.create.initial_command`."""

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
WORKSPACE_REF = "workspace:1"


class FakeCmuxState:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.requests: list[tuple[str, dict[str, object]]] = []
        self.workspace_create_params: dict[str, object] | None = None
        self.surface_send_text_params: dict[str, object] | None = None

    def handle(self, method: str, params: dict[str, object]) -> dict[str, object]:
        with self.lock:
            self.requests.append((method, dict(params)))
            if method == "workspace.create":
                self.workspace_create_params = dict(params)
                return {
                    "workspace_id": WORKSPACE_ID,
                    "workspace_ref": WORKSPACE_REF,
                }
            if method == "surface.send_text":
                self.surface_send_text_params = dict(params)
                return {"ok": True}
            raise RuntimeError(f"Unsupported fake cmux method: {method}")


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

    with tempfile.TemporaryDirectory(prefix="cmux-newws-cmd-") as td:
        tmp = Path(td)
        socket_path = tmp / "fake.sock"
        cwd = tmp / "workspace"
        cwd.mkdir(parents=True, exist_ok=True)

        state = FakeCmuxState()
        server = FakeCmuxUnixServer(str(socket_path), state)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()

        command_text = "echo hello > /tmp/cmux-1900-check.txt"
        env = os.environ.copy()
        env.pop("CMUX_WORKSPACE_ID", None)
        env.pop("CMUX_SURFACE_ID", None)
        env.pop("CMUX_TAB_ID", None)

        try:
            proc = subprocess.run(
                [
                    cli_path,
                    "--socket",
                    str(socket_path),
                    "new-workspace",
                    "--cwd",
                    str(cwd),
                    "--command",
                    command_text,
                ],
                capture_output=True,
                text=True,
                check=False,
                env=env,
                timeout=30,
            )
        except subprocess.TimeoutExpired:
            print("FAIL: `cmux new-workspace --command` timed out")
            return 1
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

        if proc.returncode != 0:
            print("FAIL: `cmux new-workspace --command` exited non-zero")
            print(f"exit={proc.returncode}")
            print(f"stdout={proc.stdout.strip()}")
            print(f"stderr={proc.stderr.strip()}")
            return 1

        output = (proc.stdout or "").strip()
        if output != f"OK {WORKSPACE_REF}":
            print(f"FAIL: expected workspace ref output, got {output!r}")
            return 1

        if state.workspace_create_params is None:
            print("FAIL: CLI never called workspace.create")
            return 1

        expected_params = {
            "cwd": str(cwd),
            "initial_command": command_text,
        }
        observed_params = state.workspace_create_params
        missing_or_mismatched = {
            key: (expected_params[key], observed_params.get(key))
            for key in expected_params
            if observed_params.get(key) != expected_params[key]
        }
        if missing_or_mismatched:
            print(
                "FAIL: workspace.create params mismatch "
                f"expected_subset={expected_params!r} observed={observed_params!r} "
                f"diff={missing_or_mismatched!r}"
            )
            return 1

        if state.surface_send_text_params is not None:
            print(
                "FAIL: new-workspace --command should not call surface.send_text "
                f"observed={state.surface_send_text_params!r}"
            )
            return 1

    print("PASS: new-workspace --command uses workspace.create initial_command")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
