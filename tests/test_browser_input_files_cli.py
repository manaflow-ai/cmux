#!/usr/bin/env python3
"""File input CLI parsing forwards explicit selections without touching a real app."""

import json
import tempfile
import threading
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli
from test_browser_profile_cli import (
    FakeCmuxHandler,
    SURFACE_ID,
    ThreadedUnixServer,
    assert_cli_fails,
    run_cli,
)


class FileInputState:
    def __init__(self):
        self.calls = []

    def handle(self, method, params):
        self.calls.append((method, params))
        if method != "browser.set_input_files":
            raise AssertionError(f"Unexpected request: {method}")
        return {"surface_id": SURFACE_ID, "action": "set_input_files"}


def main():
    cli = resolve_cmux_cli()
    with tempfile.TemporaryDirectory(prefix="cmux-input-files-", dir="/tmp") as temporary:
        socket_path = str(Path(temporary) / "cmux.sock")
        state = FileInputState()
        server = ThreadedUnixServer(socket_path, FakeCmuxHandler)
        server.state = state
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            paths = ["statement 日本語.csv", "/tmp/attachment with spaces.bin"]
            response = run_cli(cli, socket_path, [
                "browser", SURFACE_ID, "set-input-files", "--selector", "#upload",
                "--file", paths[0], "--file", paths[1], "--snapshot-after", "--json",
            ])
            assert json.loads(response)["action"] == "set_input_files"
            assert state.calls[-1] == ("browser.set_input_files", {
                "surface_id": SURFACE_ID,
                "selector": "#upload",
                "files": [str(Path(paths[0]).absolute()), paths[1]],
                "snapshot_after": True,
            }), state.calls

            run_cli(cli, socket_path, [
                "browser", "--surface", SURFACE_ID, "set-input-files",
                "--selector", "#upload", "--clear",
            ])
            assert state.calls[-1][1]["files"] == []

            for arguments in [
                ["--selector", "#upload"],
                ["--selector", "#upload", "--file"],
                ["--selector", "#upload", "--clear", "--file", paths[0]],
                ["--file", paths[0]],
                ["--selector", "#upload", "--clear", "--unknown"],
            ]:
                count = len(state.calls)
                assert_cli_fails(cli, socket_path,
                                 ["browser", SURFACE_ID, "set-input-files", *arguments],
                                 "set-input-files")
                assert len(state.calls) == count, "Invalid arguments reached the socket"
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
    print("PASS: browser file input CLI selections and validation")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
