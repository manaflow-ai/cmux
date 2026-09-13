#!/usr/bin/env python3
"""
Regression tests for the read-plane budget of targeted `cmux __tmux-compat`
commands.

`ControlClientRateLimiter` gives every control-socket connection a burst of
read-plane ("polling") tokens. A single tmux compatibility command runs on one
connection, so its whole fan-out has to fit in that burst.

`display-message` without `-t` already fits. Adding `-t <pane>` makes the CLI
resolve the target first, and that resolution re-reads the same workspace's
pane list several times, which pushed the command past the burst.

These tests drive the real CLI against a fake control socket that applies the
same token bucket, so they fail when the fan-out grows again rather than when a
hand-maintained list of method names falls out of date. They also cover the
other side of reusing a pane list: a command that mutates pane topology has to
see the result of its own mutation.
"""

from __future__ import annotations

import json
import os
import re
import socketserver
import subprocess
import tempfile
import threading
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli

WORKSPACE_ID = "11111111-1111-4111-8111-111111111111"
PANE_ID = "33333333-3333-4333-8333-333333333333"
SURFACE_ID = "44444444-4444-4444-8444-444444444444"
NEW_PANE_ID = "66666666-6666-4666-8666-666666666666"
NEW_SURFACE_ID = "77777777-7777-4777-8777-777777777777"

REPO_ROOT = Path(__file__).resolve().parent.parent
CONTROL_SOCKET_SOURCES = (
    REPO_ROOT / "Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket"
)
RATE_LIMITER_SWIFT = CONTROL_SOCKET_SOURCES / "Server/ControlClientRateLimiter.swift"
READ_PLANE_SWIFT = (
    CONTROL_SOCKET_SOURCES / "Wire/ControlCommandExecutionPolicy+ReadPlane.swift"
)

# These assertions are about how many reads a command issues, never about how
# fast it runs, so the timeout only has to stop a hung process. Keep it far
# above any plausible CLI latency on a loaded shared runner, and allow an
# override for slower environments.
CLI_TIMEOUT_SECONDS = float(os.environ.get("CMUX_CLI_TEST_TIMEOUT_SECONDS", "300"))


def read_polling_burst() -> int:
    """The default burst from `ControlClientRateLimiter.Configuration`."""
    source = RATE_LIMITER_SWIFT.read_text(encoding="utf-8")
    match = re.search(r"\bburst:\s*Int\s*=\s*(\d+)", source)
    if match is None:
        raise RuntimeError(f"could not read the default burst from {RATE_LIMITER_SWIFT}")
    return int(match.group(1))


def read_polling_methods() -> frozenset[str]:
    """The method names `ControlCommandExecutionPolicy` charges tokens for."""
    source = READ_PLANE_SWIFT.read_text(encoding="utf-8")
    match = re.search(
        r"pollingMethods\s*:\s*Set<String>\s*=\s*\[(.*?)\]", source, re.DOTALL
    )
    if match is None:
        raise RuntimeError(f"could not read pollingMethods from {READ_PLANE_SWIFT}")
    methods = frozenset(re.findall(r'"([^"]+)"', match.group(1)))
    if not methods:
        raise RuntimeError(f"pollingMethods in {READ_PLANE_SWIFT} parsed as empty")
    return methods


class FakeCmuxState:
    """A single workspace holding a single pane, plus the shared token bucket."""

    def __init__(self, burst: int, polling_methods: frozenset[str]) -> None:
        self.burst = burst
        self.polling_methods = polling_methods
        self.polling_calls: list[str] = []
        self.tokens = burst
        self.split_created = False

    def reset_budget(self) -> None:
        self.polling_calls = []
        self.tokens = self.burst

    def admit(self, method: str) -> None:
        if method not in self.polling_methods:
            return
        self.polling_calls.append(method)
        if self.tokens <= 0:
            raise RateLimited(method)
        self.tokens -= 1

    def handle(self, method: str, params: dict[str, object]) -> dict[str, object]:
        self.admit(method)

        if method == "workspace.list":
            return {
                "window_id": "window-1",
                "window_ref": "window:1",
                "workspaces": [
                    {
                        "id": WORKSPACE_ID,
                        "ref": "workspace:1",
                        "index": 0,
                        "title": "cmux",
                    }
                ],
            }
        if method == "workspace.current":
            return {"workspace_id": WORKSPACE_ID, "workspace_ref": "workspace:1"}
        if method == "window.list":
            return {"windows": [{"id": "window-1", "ref": "window:1", "index": 0}]}
        if method == "surface.current":
            return {
                "workspace_id": WORKSPACE_ID,
                "workspace_ref": "workspace:1",
                "pane_id": PANE_ID,
                "pane_ref": "pane:1",
                "surface_id": SURFACE_ID,
                "surface_ref": "surface:1",
            }
        if method == "surface.list":
            surfaces = [
                {
                    "id": SURFACE_ID,
                    "ref": "surface:1",
                    "focused": not self.split_created,
                    "pane_id": PANE_ID,
                    "pane_ref": "pane:1",
                    "title": "leader",
                }
            ]
            if self.split_created:
                surfaces.append(
                    {
                        "id": NEW_SURFACE_ID,
                        "ref": "surface:2",
                        "focused": True,
                        "pane_id": NEW_PANE_ID,
                        "pane_ref": "pane:2",
                        "title": "teammate",
                    }
                )
            return {"surfaces": surfaces}
        if method == "pane.list":
            panes = [
                {
                    "id": PANE_ID,
                    "ref": "pane:1",
                    "index": 0,
                    "focused": not self.split_created,
                    "columns": 94,
                    "rows": 37,
                    "selected_surface_id": SURFACE_ID,
                    "selected_surface_ref": "surface:1",
                    "surface_count": 1,
                    "surface_ids": [SURFACE_ID],
                    "surface_refs": ["surface:1"],
                }
            ]
            if self.split_created:
                panes.append(
                    {
                        "id": NEW_PANE_ID,
                        "ref": "pane:2",
                        "index": 1,
                        "focused": True,
                        "columns": 47,
                        "rows": 37,
                        "selected_surface_id": NEW_SURFACE_ID,
                        "selected_surface_ref": "surface:2",
                        "surface_count": 1,
                        "surface_ids": [NEW_SURFACE_ID],
                        "surface_refs": ["surface:2"],
                    }
                )
            return {
                "workspace_id": WORKSPACE_ID,
                "workspace_ref": "workspace:1",
                "container_frame": {"width": 760, "height": 672},
                "panes": panes,
            }
        if method == "surface.split":
            self.split_created = True
            return {"surface_id": NEW_SURFACE_ID, "pane_id": NEW_PANE_ID}
        if method in {"surface.send_text", "surface.select", "workspace.select"}:
            return {"ok": True}
        if method == "pane.surfaces":
            if self.split_created and params.get("pane_id") == NEW_PANE_ID:
                return {
                    "surfaces": [
                        {
                            "id": NEW_SURFACE_ID,
                            "ref": "surface:2",
                            "selected": True,
                            "title": "teammate",
                        }
                    ]
                }
            return {
                "surfaces": [
                    {
                        "id": SURFACE_ID,
                        "ref": "surface:1",
                        "selected": True,
                        "title": "leader",
                    }
                ]
            }
        raise RuntimeError(f"Unsupported fake cmux method: {method}")


class RateLimited(RuntimeError):
    def __init__(self, method: str) -> None:
        super().__init__(f"Polling rate limited for this connection ({method})")


class FakeCmuxHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        while True:
            line = self.rfile.readline()
            if not line:
                return

            decoded_line = line.decode("utf-8").rstrip("\r\n")
            capability_prefix = "_cmux_capability_v1 "
            if decoded_line.startswith(capability_prefix):
                envelope_parts = decoded_line.split(" ", 2)
                if len(envelope_parts) != 3 or not envelope_parts[2]:
                    self.wfile.write(b"ERROR: malformed capability envelope\n")
                    self.wfile.flush()
                    continue
                decoded_line = envelope_parts[2]

            request = json.loads(decoded_line)
            try:
                result = self.server.state.handle(  # type: ignore[attr-defined]
                    request["method"],
                    request.get("params", {}),
                )
                response = {"ok": True, "result": result, "id": request.get("id")}
            except RateLimited as exc:
                response = {
                    "ok": False,
                    "error": {"code": "rate_limited", "message": str(exc)},
                    "id": request.get("id"),
                }
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
    tmux_pane: str | None = None,
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["CMUX_SOCKET_PATH"] = str(socket_path)
    env["CMUX_WORKSPACE_ID"] = WORKSPACE_ID
    env["CMUX_PANE_ID"] = PANE_ID
    env["CMUX_SURFACE_ID"] = SURFACE_ID
    env["HOME"] = str(fake_home)
    if tmux_pane is None:
        env.pop("TMUX_PANE", None)
    else:
        env["TMUX_PANE"] = tmux_pane
    return subprocess.run(
        [cli_path, "--socket", str(socket_path), *args],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=CLI_TIMEOUT_SECONDS,
    )


def resolve_pane_handle(
    cli_path: str,
    socket_path: Path,
    fake_home: Path,
    state: FakeCmuxState,
) -> str:
    """The `%<id>` handle a shell in the pane would see as `$TMUX_PANE`."""
    state.reset_budget()
    proc = run_cli(
        cli_path,
        socket_path,
        fake_home,
        ["__tmux-compat", "list-panes", "-F", "#{pane_id}"],
    )
    handle = proc.stdout.strip()
    if proc.returncode != 0 or not handle.startswith("%"):
        raise AssertionError(
            "could not resolve the pane handle\n"
            f"  stdout={proc.stdout.strip()}\n"
            f"  stderr={proc.stderr.strip()}"
        )
    return handle


def assert_fits_in_one_burst(
    cli_path: str,
    socket_path: Path,
    fake_home: Path,
    state: FakeCmuxState,
    label: str,
    args: list[str],
    tmux_pane: str | None = None,
) -> None:
    state.reset_budget()
    proc = run_cli(cli_path, socket_path, fake_home, args, tmux_pane=tmux_pane)
    spent = len(state.polling_calls)
    detail = (
        f"{label}\n"
        f"  polling calls={spent} (burst={state.burst})\n"
        f"  order={' -> '.join(state.polling_calls)}\n"
        f"  stdout={proc.stdout.strip()}\n"
        f"  stderr={proc.stderr.strip()}"
    )
    if spent > state.burst:
        raise AssertionError(
            f"{label} exceeded the per-connection read-plane burst\n{detail}"
        )
    if proc.returncode != 0 or "rate_limited" in proc.stdout + proc.stderr:
        raise AssertionError(f"{label} did not succeed\n{detail}")
    if proc.stdout.strip() != "cmux:0":
        raise AssertionError(f"{label} produced unexpected output\n{detail}")


def assert_split_reports_the_new_pane(
    cli_path: str,
    socket_path: Path,
    fake_home: Path,
    state: FakeCmuxState,
    handle: str,
) -> None:
    """`split-window -P` must describe the pane the split just created.

    Target resolution reads the pane list before `surface.split` runs, and the
    `-P` format context reads it again afterwards. The second read has to see
    the new pane.
    """
    state.reset_budget()
    state.split_created = False
    proc = run_cli(
        cli_path,
        socket_path,
        fake_home,
        [
            "__tmux-compat",
            "split-window",
            "-h",
            "-t",
            handle,
            "-P",
            "-F",
            "#{pane_id} #{pane_index} #{pane_active}",
        ],
        tmux_pane=handle,
    )
    detail = (
        f"  stdout={proc.stdout.strip()}\n"
        f"  stderr={proc.stderr.strip()}\n"
        f"  order={' -> '.join(state.polling_calls)}"
    )
    if proc.returncode != 0:
        raise AssertionError(f"split-window -P returned non-zero\n{detail}")
    fields = proc.stdout.strip().split(" ")
    if len(fields) != 3:
        raise AssertionError(
            "split-window -P reported a stale pane list: the format context "
            "resolved the new pane's id but not its position, so "
            f"`#{{pane_index}}`/`#{{pane_active}}` came back empty\n{detail}"
        )
    pane_id, pane_index, pane_active = fields
    if pane_id == handle:
        raise AssertionError(f"split-window -P named the target pane\n{detail}")
    if (pane_index, pane_active) != ("1", "1"):
        raise AssertionError(
            "split-window -P described the new pane with the pre-split layout: "
            f"expected index 1 and active 1, got {pane_index!r}/{pane_active!r}"
            f"\n{detail}"
        )


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
        burst = read_polling_burst()
        polling_methods = read_polling_methods()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    fmt = "#{session_name}:#{window_index}"
    try:
        with tempfile.TemporaryDirectory(prefix="cmux-tmux-read-budget-") as td:
            tmp = Path(td)
            socket_path = tmp / "fake-cmux.sock"
            state = FakeCmuxState(burst, polling_methods)
            server = FakeCmuxUnixServer(str(socket_path), state)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            fake_home = tmp / "home"
            fake_home.mkdir(parents=True, exist_ok=True)

            try:
                handle = resolve_pane_handle(
                    cli_path, socket_path, fake_home, state
                )
                assert_fits_in_one_burst(
                    cli_path,
                    socket_path,
                    fake_home,
                    state,
                    "display-message without -t",
                    ["__tmux-compat", "display-message", "-p", fmt],
                    tmux_pane=handle,
                )
                # The reported failure: `tmux display-message -t "$TMUX_PANE"`.
                assert_fits_in_one_burst(
                    cli_path,
                    socket_path,
                    fake_home,
                    state,
                    'display-message -t "$TMUX_PANE"',
                    ["__tmux-compat", "display-message", "-t", handle, "-p", fmt],
                    tmux_pane=handle,
                )
                assert_split_reports_the_new_pane(
                    cli_path, socket_path, fake_home, state, handle
                )
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)
    except AssertionError as exc:
        print(f"FAIL: {exc}")
        return 1

    print(
        "PASS: targeted tmux-compat reads fit in one read-plane burst "
        "and stay fresh across a split"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
