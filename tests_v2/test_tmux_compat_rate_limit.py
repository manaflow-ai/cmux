#!/usr/bin/env python3
"""Issue #12757: replay Claude's targeted tmux calls against a real cmux socket.

Requires CMUX_SOCKET_PATH and CMUXTERM_CLI pointing to the same isolated build.
Creates and removes one workspace, and uses an isolated tmux compatibility store.
"""

import os
import re
import select
import shlex
import subprocess
import tempfile
from pathlib import Path

from cmux import cmux


def tmux_id(raw: str, sigil: str) -> str:
    value = 14695981039346656037
    for byte in raw.encode():
        value = ((value ^ byte) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return sigil + str((value & 0x7FFFFFFFFFFFFFFF) or 1)


def main() -> None:
    socket_path = os.environ["CMUX_SOCKET_PATH"]
    cli = os.environ["CMUXTERM_CLI"]

    def rpc(method: str, params: dict | None = None) -> dict:
        # Setup/assertions use fresh connections; the CLI under test must
        # complete its full resolution fan-out on its own single connection.
        with cmux(socket_path) as client:
            return client._call(method, params) or {}

    created = rpc("workspace.create", {"focus": False})
    workspace = created["workspace_id"]
    try:
        rpc("workspace.select", {"workspace_id": workspace})
        surfaces = rpc("surface.list", {"workspace_id": workspace})["surfaces"]
        surface = surfaces[0]["id"]
        pane = surfaces[0]["pane_id"]
        pane_target = tmux_id(pane, "%")
        window_target = tmux_id(workspace, "@")
        with tempfile.TemporaryDirectory(prefix="cmux-12757-", dir="/tmp") as directory:
            environment = {
                key: value for key, value in os.environ.items()
                if not key.startswith(("CMUX_", "CMUXD_", "TMUX"))
            }
            environment.update(
                HOME=directory,
                CMUX_SOCKET_PATH=socket_path,
                CMUX_WORKSPACE_ID=workspace,
                CMUX_SURFACE_ID=surface,
                CMUX_CLI_SENTRY_DISABLED="1",
                TMUX_PANE=pane_target,
            )

            def tmux(*args: str, success: bool = True) -> str:
                result = subprocess.run(
                    [cli, "--socket", socket_path, "__tmux-compat",
                     "-S", f"/tmp/cmux-claude-teams/{workspace}", *args],
                    env=environment, capture_output=True, text=True, timeout=30,
                )
                assert (result.returncode == 0) == success, (
                    args, result.returncode, result.stdout, result.stderr
                )
                assert "rate_limited" not in result.stderr, (args, result.stderr)
                if success:
                    assert not result.stderr.strip(), (args, result.stderr)
                return result.stdout.strip()

            assert tmux("display-message", "-p", "#{pane_id}") == pane_target
            assert tmux("display-message", "-t", window_target, "-p", "#{window_id}") == window_target
            for _ in range(20):
                assert tmux("display-message", "-t", pane_target, "-p", "#{window_id}") == window_target
            print("PASS: untargeted, @window, and 20 fresh %pane display-message calls")

            expected_panes = {pane_target}

            def assert_panes() -> None:
                for target in (pane_target, window_target):
                    listed = tmux("list-panes", "-t", target, "-F", "#{pane_id}").splitlines()
                    assert len(listed) == len(expected_panes), (target, listed, expected_panes)
                    assert set(listed) == expected_panes, (target, listed, expected_panes)

            assert_panes()
            selected = rpc("surface.current", {"workspace_id": workspace})["surface_id"]
            for _ in range(3):
                new_pane = tmux(
                    "split-window", "-d", "-t", pane_target, "-h", "-l", "70%",
                    "-P", "-F", "#{pane_id}", "--", "sleep 20",
                )
                assert re.fullmatch(r"%[0-9]+", new_pane), new_pane
                assert new_pane not in expected_panes, new_pane
                expected_panes.add(new_pane)
                assert_panes()
                assert rpc("surface.current", {"workspace_id": workspace})["surface_id"] == selected
            print("PASS: three detached splits each create exactly one listed pane and preserve focus")

            # Wait for the split's shell command via a pipe readiness event,
            # independently of terminal rendering or read-text polling.
            fifo = Path(directory) / "started"
            os.mkfifo(fifo)
            reader = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
            try:
                command = f"printf started > {shlex.quote(str(fifo))}; sleep 20"
                new_pane = tmux(
                    "split-window", "-d", "-t", pane_target, "-v", "-P", "-F",
                    "#{pane_id}", "--", command,
                )
                assert new_pane not in expected_panes
                expected_panes.add(new_pane)
                ready, _, _ = select.select([reader], [], [], 20)
                assert ready and os.read(reader, 100) == b"started", "split command did not execute"
            finally:
                os.close(reader)
            assert_panes()

            # Real tmux is quiet without -P; a successful exit must still
            # correspond to a created pane, not a swallowed limiter error.
            assert tmux("split-window", "-d", "-t", pane_target, "-v", "--", "sleep 20") == ""
            actual = rpc("pane.list", {"workspace_id": workspace})["panes"]
            assert len(actual) == len(expected_panes) + 1
            expected_panes = {tmux_id(item["id"], "%") for item in actual}
            assert_panes()
            assert rpc("surface.current", {"workspace_id": workspace})["surface_id"] == selected
            print("PASS: command delivery, silent split without -P, and complete six-pane lists")

            tmux("split-window", "-d", "-t", "%999999999999999999", "-h", success=False)
            assert_panes()
            print("PASS: invalid target reports failure without creating a pane")
    finally:
        rpc("workspace.close", {"workspace_id": workspace})


if __name__ == "__main__":
    main()
