#!/usr/bin/env python3
"""Browser creation CLI commands forward profile selectors to the socket API."""

from __future__ import annotations

import json
import os
import socketserver
import subprocess
import tempfile
import threading
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli


PROFILE_ID = "11111111-1111-4111-8111-111111111111"


class FakeCmuxState:
    def __init__(self) -> None:
        self.calls: list[tuple[str, dict[str, object]]] = []

    def handle(self, method: str, params: dict[str, object]) -> dict[str, object]:
        self.calls.append((method, params))
        if method == "browser.open_split":
            return {
                "surface_id": "22222222-2222-4222-8222-222222222222",
                "surface_ref": "surface:2",
                "pane_id": "33333333-3333-4333-8333-333333333333",
                "pane_ref": "pane:2",
                "created_split": True,
            }
        if method == "pane.create":
            return {
                "surface_id": "22222222-2222-4222-8222-222222222222",
                "surface_ref": "surface:2",
                "pane_id": "33333333-3333-4333-8333-333333333333",
                "pane_ref": "pane:2",
            }
        if method == "browser.profiles.list":
            return {
                "current_profile_id": PROFILE_ID,
                "profiles": [
                    {
                        "id": PROFILE_ID,
                        "name": "Work Profile",
                        "slug": "work-profile",
                        "built_in_default": False,
                        "current": True,
                    }
                ],
            }
        raise RuntimeError(f"unexpected method: {method}")


class FakeCmuxHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        while line := self.rfile.readline():
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


def run_cli(cli: str, socket_path: str, arguments: list[str]) -> str:
    environment = dict(os.environ)
    for key in ["CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_TAB_ID"]:
        environment.pop(key, None)
    result = subprocess.run(
        [cli, "--socket", socket_path, *arguments],
        capture_output=True,
        text=True,
        check=False,
        env=environment,
        timeout=5,
    )
    if result.returncode != 0:
        raise AssertionError(
            f"CLI failed ({' '.join(arguments)}): {result.stdout}\n{result.stderr}"
        )
    return result.stdout.strip()


def assert_cli_fails(
    cli: str,
    socket_path: str,
    arguments: list[str],
    expected_message: str,
) -> None:
    environment = dict(os.environ)
    for key in ["CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_TAB_ID"]:
        environment.pop(key, None)
    result = subprocess.run(
        [cli, "--socket", socket_path, *arguments],
        capture_output=True,
        text=True,
        check=False,
        env=environment,
        timeout=5,
    )
    if result.returncode == 0:
        raise AssertionError(f"CLI unexpectedly succeeded ({' '.join(arguments)})")
    output = f"{result.stdout}\n{result.stderr}"
    if expected_message not in output:
        raise AssertionError(
            f"expected failure containing {expected_message!r}, got {output!r}"
        )


def assert_last_call(
    state: FakeCmuxState,
    expected_method: str,
    expected_profile: str | None,
) -> None:
    method, params = state.calls[-1]
    if method != expected_method:
        raise AssertionError(f"expected {expected_method}, got {method}")
    if params.get("profile") != expected_profile:
        raise AssertionError(
            f"{expected_method} expected profile={expected_profile!r}, got {params!r}"
        )


def main() -> int:
    cli = resolve_cmux_cli()
    with tempfile.TemporaryDirectory(prefix="cmux-browser-profile-") as temporary:
        socket_path = str(Path(temporary) / "cmux.sock")
        state = FakeCmuxState()
        server = ThreadedUnixServer(socket_path, FakeCmuxHandler)
        server.state = state
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            run_cli(
                cli,
                socket_path,
                ["browser", "open", "https://example.com", "--profile", "Work Profile"],
            )
            assert_last_call(state, "browser.open_split", "Work Profile")

            run_cli(
                cli,
                socket_path,
                ["browser", "open-split", "https://example.com", "--profile", PROFILE_ID],
            )
            assert_last_call(state, "browser.open_split", PROFILE_ID)

            run_cli(
                cli,
                socket_path,
                [
                    "new-pane",
                    "--type",
                    "browser",
                    "--url",
                    "https://example.com",
                    "--profile",
                    "Work Profile",
                ],
            )
            assert_last_call(state, "pane.create", "Work Profile")

            calls_before_terminal_profile = len(state.calls)
            assert_cli_fails(
                cli,
                socket_path,
                ["new-pane", "--profile", "Work Profile"],
                "Browser profiles can only be used when creating a browser pane",
            )
            if len(state.calls) != calls_before_terminal_profile:
                raise AssertionError("new-pane sent a browser profile for a terminal pane")

            calls_before_missing_profile = len(state.calls)
            assert_cli_fails(
                cli,
                socket_path,
                ["new-pane", "--type", "browser", "--profile"],
                "--profile requires a non-empty profile name or UUID",
            )
            if len(state.calls) != calls_before_missing_profile:
                raise AssertionError("new-pane sent a profile request without a selector")

            run_cli(cli, socket_path, ["browser", "open", "https://example.com"])
            assert_last_call(state, "browser.open_split", None)

            calls_before_rejected_open = len(state.calls)
            assert_cli_fails(
                cli,
                socket_path,
                [
                    "browser",
                    "surface:1",
                    "open",
                    "https://example.com",
                    "--profile",
                    "Work Profile",
                ],
                "--profile is only supported when browser open creates a new pane",
            )
            if len(state.calls) != calls_before_rejected_open:
                raise AssertionError("surface-qualified browser open sent an ignored profile")

            profiles = run_cli(cli, socket_path, ["browser", "profiles"])
            if "Work Profile" not in profiles or PROFILE_ID not in profiles:
                raise AssertionError(f"profile list omitted name or UUID: {profiles!r}")
            if "last used" not in profiles:
                raise AssertionError(f"profile list did not mark last-used profile: {profiles!r}")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
    print("PASS: browser profile CLI plumbing")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
