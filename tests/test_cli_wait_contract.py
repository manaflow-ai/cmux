#!/usr/bin/env python3
"""Executable contract tests for ``cmux wait`` against a fake v2 socket."""

from __future__ import annotations

import json
import os
import socketserver
import subprocess
import tempfile
import threading
from dataclasses import dataclass
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli


WORKSPACE_ID = "11111111-1111-4111-8111-111111111111"
SURFACE_ID = "22222222-2222-4222-8222-222222222222"
PANE_ID = "33333333-3333-4333-8333-333333333333"


@dataclass(frozen=True)
class RunResult:
    returncode: int
    stdout: str
    stderr: str


class FakeCmuxState:
    def __init__(self) -> None:
        self.calls: list[tuple[str, dict[str, object]]] = []
        self.status = "satisfied"
        self.state = "idle"

    def handle(self, method: str, params: dict[str, object]) -> dict[str, object]:
        self.calls.append((method, params))
        if method != "agent.wait":
            raise RuntimeError(f"unsupported fake cmux method: {method}")
        return {
            "status": self.status,
            "until": params["until"],
            "state": self.state,
            "agent": "codex",
            "session_id": "session-8950",
            "workspace_id": WORKSPACE_ID,
            "surface_id": SURFACE_ID,
            "pane_id": PANE_ID,
        }


class FakeCmuxHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        line = self.rfile.readline()
        if line.startswith(b"auth "):
            self.wfile.write(b"ERROR: Unknown command 'auth'\n")
            self.wfile.flush()
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
        except Exception as exc:  # noqa: BLE001
            response = {
                "ok": False,
                "error": {"code": "fake_error", "message": str(exc)},
                "id": request.get("id"),
            }
        self.wfile.write((json.dumps(response) + "\n").encode("utf-8"))
        self.wfile.flush()


class ThreadedUnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    state: FakeCmuxState


def run_cli(
    cli: str,
    socket_path: str,
    args: list[str],
    *,
    cwd: str | None = None,
) -> RunResult:
    env = dict(os.environ)
    for key in [
        "CMUX_SOCKET",
        "CMUX_SOCKET_CAPABILITY",
        "CMUX_SOCKET_PASSWORD",
        "CMUX_WORKSPACE_ID",
        "CMUX_SURFACE_ID",
        "CMUX_TAB_ID",
        "CMUX_PANEL_ID",
    ]:
        env.pop(key, None)
    env["CMUX_SOCKET_PATH"] = socket_path
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
    proc = subprocess.run(
        [cli, "--socket", socket_path, *args],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=5,
        cwd=cwd,
    )
    return RunResult(proc.returncode, proc.stdout, proc.stderr)


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> int:
    cli = resolve_cmux_cli()
    with tempfile.TemporaryDirectory(prefix="cmux-wait-contract-") as tmp:
        socket_path = str(Path(tmp) / "cmux.sock")
        state = FakeCmuxState()
        server = ThreadedUnixServer(socket_path, FakeCmuxHandler)
        server.state = state
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            (Path(tmp) / "wait").mkdir()
            result = run_cli(
                cli,
                socket_path,
                [
                    "wait",
                    "--surface",
                    SURFACE_ID,
                    "--until",
                    "needs-input",
                    "--timeout",
                    "2500",
                ],
                cwd=tmp,
            )
            expect(result.returncode == 0, f"satisfied wait failed: {result}")
            expect(result.stdout == "", f"plain success should be silent: {result.stdout!r}")
            expect(result.stderr == "", f"plain success wrote stderr: {result.stderr!r}")
            expect(
                state.calls[-1]
                == (
                    "agent.wait",
                    {
                        "surface_id": SURFACE_ID,
                        "until": "needs-input",
                        "timeout_ms": 2500,
                    },
                ),
                f"unexpected agent.wait request: {state.calls[-1]!r}",
            )

            result = run_cli(
                cli,
                socket_path,
                [
                    "--json",
                    "wait",
                    "--surface",
                    SURFACE_ID,
                    "--until",
                    "idle",
                ],
            )
            expect(result.returncode == 0, f"JSON success failed: {result}")
            payload = json.loads(result.stdout)
            expect(
                payload
                == {
                    "agent": "codex",
                    "pane_id": PANE_ID,
                    "session_id": "session-8950",
                    "state": "idle",
                    "status": "satisfied",
                    "surface_id": SURFACE_ID,
                    "until": "idle",
                    "workspace_id": WORKSPACE_ID,
                },
                f"unexpected JSON success payload: {payload!r}",
            )
            expect(result.stderr == "", f"JSON success wrote stderr: {result.stderr!r}")

            state.status = "timed_out"
            state.state = "running"
            result = run_cli(
                cli,
                socket_path,
                [
                    "wait",
                    "--surface",
                    SURFACE_ID,
                    "--until",
                    "idle",
                    "--timeout",
                    "0",
                    "--json",
                ],
            )
            expect(result.returncode == 124, f"timeout exit code was not 124: {result}")
            expect(json.loads(result.stdout)["status"] == "timed_out", f"missing timeout JSON: {result}")
            expect(result.stderr == "", f"JSON timeout duplicated an error on stderr: {result.stderr!r}")

            state.status = "surface_closed"
            result = run_cli(
                cli,
                socket_path,
                [
                    "wait",
                    "--surface",
                    SURFACE_ID,
                    "--until",
                    "exit",
                    "--json",
                ],
            )
            expect(result.returncode == 3, f"surface closure exit code was not 3: {result}")
            expect(
                json.loads(result.stdout)["status"] == "surface_closed",
                f"missing surface-closed JSON: {result}",
            )
            expect(result.stderr == "", f"JSON surface closure duplicated stderr: {result.stderr!r}")
        finally:
            server.shutdown()
            server.server_close()

    print("PASS: cmux wait request, JSON, and exit-code contracts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
