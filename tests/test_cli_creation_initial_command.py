#!/usr/bin/env python3
"""Regression: terminal creation commands pass --command at spawn time."""

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
PANE_ID = "22222222-2222-4222-8222-222222222222"
PANE_REF = "pane:2"
SURFACE_ID = "33333333-3333-4333-8333-333333333333"
SURFACE_REF = "surface:3"
COMMAND_TEXT = r'''printf '%s\n' "spaces 'single' \"double\" $CMUX_VALUE $(printf nested) \\tail 日本語'''


class FakeCmuxState:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.requests: list[tuple[str, dict[str, object]]] = []

    def handle(self, method: str, params: dict[str, object]) -> dict[str, object]:
        with self.lock:
            self.requests.append((method, dict(params)))

        if method == "workspace.create":
            return {
                "workspace_id": WORKSPACE_ID,
                "workspace_ref": WORKSPACE_REF,
            }
        if method in {"surface.split", "pane.create", "surface.create"}:
            return {
                "workspace_id": WORKSPACE_ID,
                "workspace_ref": WORKSPACE_REF,
                "pane_id": PANE_ID,
                "pane_ref": PANE_REF,
                "surface_id": SURFACE_ID,
                "surface_ref": SURFACE_REF,
            }
        if method == "surface.send_text":
            return {"ok": True}
        raise RuntimeError(f"Unsupported fake cmux method: {method}")

    def request_count(self) -> int:
        with self.lock:
            return len(self.requests)

    def requests_since(self, index: int) -> list[tuple[str, dict[str, object]]]:
        with self.lock:
            return [(method, dict(params)) for method, params in self.requests[index:]]


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
            try:
                result = self.server.state.handle(  # type: ignore[attr-defined]
                    request["method"],
                    request.get("params", {}),
                )
                response = {
                    "ok": True,
                    "result": result,
                    "id": request.get("id"),
                }
            except Exception as exc:  # noqa: BLE001
                response = {
                    "ok": False,
                    "error": {
                        "code": "fake_error",
                        "message": str(exc),
                    },
                    "id": request.get("id"),
                }
            self.wfile.write((json.dumps(response) + "\n").encode("utf-8"))
            self.wfile.flush()


def creation_cases(command: str | None) -> list[tuple[str, list[str], str]]:
    cases = [
        (
            "new-split",
            [
                "new-split",
                "right",
                "--workspace",
                WORKSPACE_ID,
                "--surface",
                SURFACE_ID,
            ],
            "surface.split",
        ),
        (
            "new-pane",
            [
                "new-pane",
                "--workspace",
                WORKSPACE_ID,
                "--direction",
                "down",
            ],
            "pane.create",
        ),
        (
            "new-surface",
            [
                "new-surface",
                "--workspace",
                WORKSPACE_ID,
                "--pane",
                PANE_ID,
            ],
            "surface.create",
        ),
        (
            "new-workspace",
            ["new-workspace"],
            "workspace.create",
        ),
    ]
    if command is None:
        return cases
    return [
        (label, [*args, "--command", command], method)
        for label, args, method in cases
    ]


def invoke_creation(
    cli_path: str,
    socket_path: str,
    state: FakeCmuxState,
    label: str,
    args: list[str],
) -> list[tuple[str, dict[str, object]]]:
    env = os.environ.copy()
    for key in [
        "CMUX_SOCKET_PASSWORD",
        "CMUX_WORKSPACE_ID",
        "CMUX_SURFACE_ID",
        "CMUX_TAB_ID",
    ]:
        env.pop(key, None)
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"

    request_start = state.request_count()
    proc = subprocess.run(
        [cli_path, "--socket", socket_path, *args],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=10,
    )
    if proc.returncode != 0:
        raise AssertionError(
            f"{label} exited non-zero: exit={proc.returncode} "
            f"stdout={proc.stdout.strip()!r} stderr={proc.stderr.strip()!r}"
        )
    return state.requests_since(request_start)


def assert_creation_request(
    label: str,
    requests: list[tuple[str, dict[str, object]]],
    expected_method: str,
    expected_command: str | None,
) -> None:
    if len(requests) != 1:
        raise AssertionError(
            f"{label} should make exactly one spawn-time request; observed={requests!r}"
        )
    method, params = requests[0]
    if method != expected_method:
        raise AssertionError(
            f"{label} expected method={expected_method!r}, got {method!r}"
        )
    if expected_command is None:
        if "initial_command" in params:
            raise AssertionError(
                f"{label} without --command should omit initial_command; params={params!r}"
            )
    elif params.get("initial_command") != expected_command:
        raise AssertionError(
            f"{label} did not preserve --command bytes: "
            f"expected={expected_command!r} actual={params.get('initial_command')!r} "
            f"params={params!r}"
        )


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:  # noqa: BLE001
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(prefix="cmux-creation-command-") as tmp:
        socket_path = str(Path(tmp) / "fake.sock")
        state = FakeCmuxState()
        server = FakeCmuxUnixServer(socket_path, state)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()

        try:
            for label, args, method in creation_cases(COMMAND_TEXT):
                requests = invoke_creation(
                    cli_path,
                    socket_path,
                    state,
                    label,
                    args,
                )
                assert_creation_request(
                    label,
                    requests,
                    expected_method=method,
                    expected_command=COMMAND_TEXT,
                )

            for label, args, method in creation_cases(None):
                requests = invoke_creation(
                    cli_path,
                    socket_path,
                    state,
                    label,
                    args,
                )
                assert_creation_request(
                    label,
                    requests,
                    expected_method=method,
                    expected_command=None,
                )

            for label, args, method in creation_cases(" \n\t "):
                requests = invoke_creation(
                    cli_path,
                    socket_path,
                    state,
                    label,
                    args,
                )
                assert_creation_request(
                    label,
                    requests,
                    expected_method=method,
                    expected_command=None,
                )
        except (AssertionError, subprocess.TimeoutExpired) as exc:
            print(f"FAIL: {exc}")
            return 1
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    print(
        "PASS: terminal creation --command uses one spawn-time initial_command request"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
