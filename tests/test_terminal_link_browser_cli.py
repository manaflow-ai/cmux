#!/usr/bin/env python3
"""Terminal open interception carries placement intent; explicit routes do not."""
import json
import os
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading

from claude_teams_test_utils import resolve_cmux_cli

SOURCE = "11111111-1111-4111-8111-111111111111"
WORKSPACE = "22222222-2222-4222-8222-222222222222"
TARGET = "33333333-3333-4333-8333-333333333333"


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        while line := self.rfile.readline():
            request = json.loads(line)
            self.server.calls.append(request)
            result = {"surface_id": TARGET, "surface_ref": "surface:2", "pane_ref": "pane:1",
                      "created_split": False, "placement_strategy": "same_pane"}
            self.wfile.write((json.dumps({"id": request.get("id"), "ok": True, "result": result}) + "\n").encode())
            self.wfile.flush()


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def main():
    cli = resolve_cmux_cli()
    cases = [
        (["open", "https://example.invalid"], True, True),
        (["open", "https://example.invalid"], False, False),
        (["open-split", "https://example.invalid"], True, False),
        (["new", "https://example.invalid"], True, False),
        (["open", "https://example.invalid", "--workspace", WORKSPACE], True, False),
        (["open", "https://example.invalid", "--window", TARGET], True, False),
        (["open", "https://example.invalid", "--profile", "work"], True, False),
        ([SOURCE, "open", "https://example.invalid"], True, False),
    ]
    with tempfile.TemporaryDirectory(prefix="cmux-link-cli-", dir="/tmp") as root:
        socket_path = str(Path(root) / "socket")
        with Server(socket_path, Handler) as server:
            server.calls = []
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                for args, intercept, opt_in in cases:
                    env = {key: value for key, value in os.environ.items() if not key.startswith("CMUX_")}
                    env.update(CMUX_SURFACE_ID=SOURCE, CMUX_WORKSPACE_ID=WORKSPACE,
                               CMUX_RESPECT_EXTERNAL_OPEN_RULES="1" if intercept else "0")
                    result = subprocess.run([cli, "--socket", socket_path, "browser", *args],
                                            env=env, capture_output=True, text=True, timeout=10)
                    assert result.returncode == 0, (args, result.stderr)
                    call = server.calls[-1]
                    params = call.get("params", {})
                    assert params.get("use_terminal_link_browser_placement", False) == opt_in, (args, call)
                    if args[0] == SOURCE:
                        assert call["method"] == "browser.navigate", call
                    else:
                        assert call["method"] == "browser.open_split", call
                    if opt_in:
                        assert params["surface_id"] == SOURCE, call
                        assert params["respect_external_open_rules"] is True, call
                        assert "placement=samePane" in result.stdout, result.stdout
            finally:
                server.shutdown()
                thread.join(timeout=5)
    print(f"PASS: {len(cases)} terminal-link and explicit browser CLI routes")


if __name__ == "__main__":
    main()
