#!/usr/bin/env python3
"""`cmux browser open|open-split|new --engine` forwards a canonical engine to the socket."""

from __future__ import annotations

import json
import socketserver
import subprocess
import tempfile
import threading
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli
from fake_socket_env import cli_environment, unwrap_capability


SURFACE_ID = "22222222-2222-4222-8222-222222222222"


class FakeCmuxState:
    def __init__(self) -> None:
        self.calls: list[tuple[str, dict[str, object]]] = []

    def handle(self, method: str, params: dict[str, object]) -> dict[str, object]:
        self.calls.append((method, params))
        if method == "browser.open_split":
            return {
                "surface_id": SURFACE_ID,
                "surface_ref": "surface:2",
                "pane_id": "33333333-3333-4333-8333-333333333333",
                "pane_ref": "pane:2",
                "created_split": True,
                "engine": params.get("engine", "webkit"),
            }
        if method == "browser.navigate":
            return {"surface_id": SURFACE_ID, "surface_ref": "surface:2"}
        if method == "surface.list" or method == "surface.resolve":
            return {"surfaces": []}
        raise RuntimeError(f"unexpected method: {method}")


class FakeCmuxHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        while line := self.rfile.readline():
            request = json.loads(unwrap_capability(line.decode("utf-8")))
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


def run_cli(cli: str, socket_path: str, arguments: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [cli, "--socket", socket_path, *arguments],
        capture_output=True,
        text=True,
        check=False,
        env=cli_environment(),
        timeout=5,
    )


def expect_ok(cli: str, socket_path: str, arguments: list[str]) -> None:
    result = run_cli(cli, socket_path, arguments)
    if result.returncode != 0:
        raise AssertionError(f"CLI failed ({' '.join(arguments)}): {result.stdout}\n{result.stderr}")


def expect_failure(cli: str, socket_path: str, arguments: list[str], message: str) -> None:
    result = run_cli(cli, socket_path, arguments)
    if result.returncode == 0:
        raise AssertionError(f"CLI unexpectedly succeeded ({' '.join(arguments)})")
    output = f"{result.stdout}\n{result.stderr}"
    if message not in output:
        raise AssertionError(f"expected failure containing {message!r}, got {output!r}")


def last_open(state: FakeCmuxState) -> dict[str, object]:
    method, params = state.calls[-1]
    if method != "browser.open_split":
        raise AssertionError(f"expected browser.open_split, got {method} {params!r}")
    return params


def main() -> int:
    cli = resolve_cmux_cli()
    with tempfile.TemporaryDirectory(prefix="cmux-browser-engine-") as temporary:
        socket_path = str(Path(temporary) / "cmux.sock")
        state = FakeCmuxState()
        server = ThreadedUnixServer(socket_path, FakeCmuxHandler)
        server.state = state
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            cases = [
                (["browser", "open", "https://example.com", "--engine", "chromium"], "chromium"),
                (["browser", "open-split", "--engine", "webkit", "https://example.com"], "webkit"),
                (["browser", "new", "https://example.com", "--engine=CEF"], "chromium"),
                (["browser", "open", "https://example.com", "--engine", "chrome"], "chromium"),
                (["browser", "open", "https://example.com", "--engine", "Safari"], "webkit"),
            ]
            for arguments, expected in cases:
                expect_ok(cli, socket_path, arguments)
                params = last_open(state)
                if params.get("engine") != expected:
                    raise AssertionError(f"{arguments}: expected engine={expected!r}, got {params!r}")
                if params.get("url") != "https://example.com":
                    raise AssertionError(f"{arguments}: the engine flag leaked into the URL: {params!r}")

            expect_ok(cli, socket_path, ["browser", "open", "https://example.com"])
            if "engine" in last_open(state):
                raise AssertionError("browser open without --engine must not send an engine")

            calls_before = len(state.calls)
            expect_failure(
                cli,
                socket_path,
                ["browser", "open", "https://example.com", "--engine", "gecko"],
                "Choose WebKit or Chromium",
            )
            expect_failure(
                cli,
                socket_path,
                ["browser", "open", "https://example.com", "--engine"],
                "Choose WebKit or Chromium",
            )
            if len(state.calls) != calls_before:
                raise AssertionError("an invalid --engine must fail before contacting the socket")

            expect_failure(
                cli,
                socket_path,
                ["browser", "--surface", SURFACE_ID, "open", "https://example.com", "--engine", "chromium"],
                "--engine is only supported when browser open creates a new pane",
            )
        finally:
            server.shutdown()
            server.server_close()

    print("PASS: browser open --engine forwards a canonical engine and rejects invalid values")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
