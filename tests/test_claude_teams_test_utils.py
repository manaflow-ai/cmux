#!/usr/bin/env python3
"""Behavior coverage for the Claude Teams focused-socket test server."""

from __future__ import annotations

import json
import os
import socket
import tempfile
from pathlib import Path

from claude_teams_test_utils import FOCUSED_WORKSPACE_ID, focused_cmux_server


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="cmux-overlong-socket-hint-") as temp_dir:
        socket_path_hint = Path(temp_dir) / ("nested-segment-" * 12) / "focused-cmux.sock"
        if len(os.fsencode(socket_path_hint)) < 200:
            print(f"FAIL: test socket hint was not deliberately overlong: {socket_path_hint}")
            return 1

        with focused_cmux_server(socket_path_hint) as (live_socket_path, requests):
            if Path(live_socket_path) == socket_path_hint:
                print("FAIL: focused server tried to bind the overlong caller path")
                return 1

            request = {
                "method": "surface.list",
                "params": {"workspace_id": FOCUSED_WORKSPACE_ID},
                "id": "overlong-path-probe",
            }
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.connect(live_socket_path)
                with client.makefile("rwb") as stream:
                    stream.write((json.dumps(request) + "\n").encode("utf-8"))
                    stream.flush()
                    response = json.loads(stream.readline())

            if not response.get("ok") or response.get("id") != request["id"]:
                print(f"FAIL: short focused socket returned an invalid response: {response!r}")
                return 1
            if requests != ["surface.list"]:
                print(f"FAIL: short focused socket recorded unexpected requests: {requests!r}")
                return 1

        if Path(live_socket_path).exists():
            print(f"FAIL: focused socket was not cleaned up: {live_socket_path}")
            return 1

    print("PASS: focused cmux test server owns a short socket for overlong caller paths")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
