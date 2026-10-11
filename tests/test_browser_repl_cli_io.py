#!/usr/bin/env python3
"""`cmux browser repl` bounds what it reads from stdin and never writes raw control characters."""

from __future__ import annotations

import subprocess
import tempfile
import threading
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli
from fake_socket_env import cli_environment
from test_browser_profile_cli import FakeCmuxHandler, ThreadedUnixServer

LIMIT = 15 * 1024 * 1024


class ReplState:
    def __init__(self, output: list[str]) -> None:
        self.calls: list[tuple[str, dict[str, object]]] = []
        self.output = output

    def handle(self, method: str, params: dict[str, object]) -> dict[str, object]:
        self.calls.append((method, params))
        if method != "browser.repl.eval":
            raise RuntimeError(f"unexpected method: {method}")
        return {
            "session": None,
            "ok": True,
            "output": [{"level": "log", "text": text} for text in self.output],
            "duration_ms": 5,
        }


def serve(temporary: str, state: ReplState) -> tuple[ThreadedUnixServer, str]:
    socket_path = str(Path(temporary) / "cmux.sock")
    server = ThreadedUnixServer(socket_path, FakeCmuxHandler)
    server.state = state  # type: ignore[assignment]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, socket_path


def stdin_is_read_only_up_to_the_limit(cli: str) -> None:
    """An endless stdin stops at the 15 MiB limit instead of being read whole first."""
    with tempfile.TemporaryDirectory(prefix="cmux-repl-io-", dir="/tmp") as temporary:
        state = ReplState([])
        server, socket_path = serve(temporary, state)
        try:
            process = subprocess.Popen(
                [cli, "--socket", socket_path, "browser", "repl", "--eval", "-"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                cwd=temporary,
                env=cli_environment(),
            )
            assert process.stdin is not None
            chunk = b"x" * (1024 * 1024)
            written = 0
            # 256 MiB stands in for a stream that never ends.
            try:
                while written < 256 * 1024 * 1024:
                    process.stdin.write(chunk)
                    written += len(chunk)
                process.stdin.close()
            except BrokenPipeError:
                pass
            _, stderr = process.communicate(timeout=60)
            assert process.returncode != 0, process.returncode
            assert b"too large" in stderr, stderr
            assert written <= LIMIT + 16 * 1024 * 1024, f"the CLI read {written} bytes before refusing"
            assert not state.calls, state.calls
        finally:
            server.shutdown()
            server.server_close()


def output_has_no_control_characters(cli: str) -> None:
    """Page text with escape sequences prints as visible characters, never as controls."""
    hostile = "title: Inbox\x1b]52;c;cHduZWQ=\x07\x1b[2J\x9b31mRed\rover\ttab"
    with tempfile.TemporaryDirectory(prefix="cmux-repl-io-", dir="/tmp") as temporary:
        state = ReplState([hostile, "plain line"])
        server, socket_path = serve(temporary, state)
        try:
            result = subprocess.run(
                [cli, "--socket", socket_path, "browser", "repl", "--eval", "1"],
                capture_output=True,
                check=False,
                cwd=temporary,
                env=cli_environment(),
                timeout=60,
            )
            assert result.returncode == 0, result.stderr
            text = result.stdout.decode("utf-8")
            controls = [hex(ord(c)) for c in text if (ord(c) < 0x20 and c not in "\n\t") or 0x7F <= ord(c) <= 0x9F]
            assert not controls, (controls, text)
            lines = text.split("\n")
            assert lines[0].startswith("title: Inbox"), lines
            assert "Red" in lines[0] and "over\ttab" in lines[0], lines
            assert lines[1] == "plain line", lines
            assert lines[2] == "[ok | 5ms]", lines
        finally:
            server.shutdown()
            server.server_close()


def main() -> None:
    cli = resolve_cmux_cli()
    stdin_is_read_only_up_to_the_limit(cli)
    output_has_no_control_characters(cli)
    print("PASS: browser repl stdin limit and control-character output")


if __name__ == "__main__":
    main()
