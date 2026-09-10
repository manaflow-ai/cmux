#!/usr/bin/env python3
"""Regression: terminal creation commands inject --command into a new shell."""

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
COMMAND_TEXT = r"""printf '%s\n' "spaces 'single' \"double\" $CMUX_VALUE $(printf nested) \\tail 日本語"""


def creation_initial_input(command: str) -> str:
    """Preserve command text literally and append one terminal Enter."""
    return command + "\r"


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
        (label, [*args, "--command", command], method) for label, args, method in cases
    ]


def invoke_cli(
    cli_path: str,
    socket_path: str,
    state: FakeCmuxState,
    args: list[str],
) -> tuple[
    subprocess.CompletedProcess[str],
    list[tuple[str, dict[str, object]]],
]:
    env = os.environ.copy()
    for key in [
        "CMUX_SOCKET_PASSWORD",
        "CMUX_SOCKET_CAPABILITY",
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
    return proc, state.requests_since(request_start)


def invoke_creation(
    cli_path: str,
    socket_path: str,
    state: FakeCmuxState,
    label: str,
    args: list[str],
) -> list[tuple[str, dict[str, object]]]:
    proc, requests = invoke_cli(cli_path, socket_path, state, args)
    if proc.returncode != 0:
        raise AssertionError(
            f"{label} exited non-zero: exit={proc.returncode} "
            f"stdout={proc.stdout.strip()!r} stderr={proc.stderr.strip()!r}"
        )
    return requests


def assert_non_terminal_command_rejected(
    cli_path: str,
    socket_path: str,
    state: FakeCmuxState,
    label: str,
    args: list[str],
) -> None:
    proc, requests = invoke_cli(cli_path, socket_path, state, args)
    if proc.returncode == 0:
        raise AssertionError(f"{label} should reject --command for a non-terminal type")
    if requests:
        raise AssertionError(
            f"{label} should fail before sending a request: {requests!r}"
        )
    if "--command" not in proc.stderr or "--type terminal" not in proc.stderr:
        raise AssertionError(
            f"{label} returned an unclear error: stderr={proc.stderr.strip()!r}"
        )


def assert_missing_command_value_rejected(
    cli_path: str,
    socket_path: str,
    state: FakeCmuxState,
    label: str,
    args: list[str],
) -> None:
    proc, requests = invoke_cli(cli_path, socket_path, state, args)
    if proc.returncode == 0:
        raise AssertionError(f"{label} should reject --command without command text")
    if requests:
        raise AssertionError(
            f"{label} should fail before sending a request: {requests!r}"
        )
    if "--command requires <text>" not in proc.stderr:
        raise AssertionError(
            f"{label} returned an unclear error: stderr={proc.stderr.strip()!r}"
        )


def assert_creation_request(
    label: str,
    requests: list[tuple[str, dict[str, object]]],
    expected_method: str,
    expected_input: str | None,
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
    if "initial_command" in params:
        raise AssertionError(
            f"{label} should preserve an interactive shell; params={params!r}"
        )
    if expected_input is None:
        if "initial_input" in params:
            raise AssertionError(
                f"{label} without --command should omit initial_input; params={params!r}"
            )
    elif params.get("initial_input") != expected_input:
        raise AssertionError(
            f"{label} did not preserve the --command input contract: "
            f"expected={expected_input!r} actual={params.get('initial_input')!r} "
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
                    expected_input=creation_initial_input(COMMAND_TEXT),
                )

            for label, args, method in creation_cases(None):
                requests = invoke_creation(
                    cli_path,
                    socket_path,
                    state,
                    f"{label} equals syntax",
                    [*args, f"--command={COMMAND_TEXT}"],
                )
                assert_creation_request(
                    f"{label} equals syntax",
                    requests,
                    expected_method=method,
                    expected_input=creation_initial_input(COMMAND_TEXT),
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
                    expected_input=None,
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
                    expected_input=None,
                )

            non_terminal_cases = [
                (
                    "new-pane browser",
                    [
                        "new-pane",
                        "--workspace",
                        WORKSPACE_ID,
                        "--type",
                        "browser",
                        "--command",
                        "echo ignored",
                    ],
                ),
                (
                    "new-surface agent-session",
                    [
                        "new-surface",
                        "--workspace",
                        WORKSPACE_ID,
                        "--pane",
                        PANE_ID,
                        "--type",
                        "agent-session",
                        "--command",
                        "echo ignored",
                    ],
                ),
            ]
            for label, args in non_terminal_cases:
                assert_non_terminal_command_rejected(
                    cli_path,
                    socket_path,
                    state,
                    label,
                    args,
                )

            for label, args, _ in creation_cases(None):
                invalid_command_args = [
                    (f"{label} trailing command flag", [*args, "--command"]),
                    (
                        f"{label} command followed by flag",
                        [*args, "--command", "--focus", "false"],
                    ),
                    (f"{label} empty equals command", [*args, "--command="]),
                ]
                for invalid_label, invalid_args in invalid_command_args:
                    assert_missing_command_value_rejected(
                        cli_path,
                        socket_path,
                        state,
                        invalid_label,
                        invalid_args,
                    )
        except (AssertionError, subprocess.TimeoutExpired) as exc:
            print(f"FAIL: {exc}")
            return 1
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    print("PASS: terminal creation --command uses one spawn-time initial_input request")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
