#!/usr/bin/env python3
"""Large v2 requests from the CLI put `method` first, so the app can route them (#21222).

The app reads the first 4 KiB of every request line to tell an ordinary
request from a CodeRouter handoff frame, and it closes the connection without
a reply when a longer line has no `method` key in that prefix. The CLI used to
serialize requests in dictionary hash order, which changes from one process to
the next, so a request with large params sometimes put `method` after them and
failed with "Socket closed before reply".

This drives the real CLI against a socket that records each raw request line.
Every line longer than 4 KiB must start with its `method` key, across several
CLI processes so a lucky hash order cannot pass the check.
"""

from __future__ import annotations

import json
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from claude_teams_test_utils import resolve_cmux_cli  # noqa: E402
from fake_socket_env import cli_environment, unwrap_capability  # noqa: E402

WORKSPACE_ID = "11111111-1111-4111-8111-111111111111"
PANE_ID = "33333333-3333-4333-8333-333333333333"
SURFACE_ID = "44444444-4444-4444-8444-444444444444"

# The app's route classification window (`codeRouterHandshakeMaximumBytes`).
CLASSIFICATION_PREFIX_BYTES = 4_096
RUNS_PER_SCENARIO = 6


class RecordingSocket:
    """Answers every v2 request with a generic success and keeps the raw lines."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.lines: list[str] = []
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._ready = threading.Event()
        self._thread = threading.Thread(target=self._serve, daemon=True)

    def __enter__(self) -> "RecordingSocket":
        self.path.unlink(missing_ok=True)
        self._thread.start()
        if not self._ready.wait(timeout=3):
            raise RuntimeError("recording socket did not start")
        return self

    def __exit__(self, *_exc: object) -> None:
        self._stop.set()
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.connect(str(self.path))
        except OSError:
            pass
        self._thread.join(timeout=3)
        self.path.unlink(missing_ok=True)

    def take(self) -> list[str]:
        """The lines received since the last call.

        A one-way send can land after the CLI exits, so this waits, up to a
        deadline, until a line over the classification window has arrived.
        """
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            with self._lock:
                if count_large(self.lines) > 0:
                    break
            time.sleep(0.05)
        with self._lock:
            lines, self.lines = self.lines, []
        return lines

    def _serve(self) -> None:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
            server.bind(str(self.path))
            server.listen(16)
            server.settimeout(0.1)
            self._ready.set()
            while not self._stop.is_set():
                try:
                    connection, _ = server.accept()
                except socket.timeout:
                    continue
                threading.Thread(target=self._handle, args=(connection,), daemon=True).start()

    def _handle(self, connection: socket.socket) -> None:
        # One-way sends close their end without reading the reply.
        try:
            self._answer(connection)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _answer(self, connection: socket.socket) -> None:
        with connection, connection.makefile("rwb") as stream:
            for raw in stream:
                line = unwrap_capability(raw.decode("utf-8").rstrip("\r\n"))
                with self._lock:
                    self.lines.append(line)
                try:
                    request = json.loads(line)
                except json.JSONDecodeError:
                    stream.write(b"ERROR: not json\n")
                    stream.flush()
                    continue
                if not isinstance(request, dict) or "method" not in request:
                    stream.write(b"OK\n")
                    stream.flush()
                    continue
                response = {"ok": True, "id": request.get("id"), "result": self._result(request["method"])}
                stream.write((json.dumps(response) + "\n").encode("utf-8"))
                stream.flush()

    @staticmethod
    def _result(method: str) -> dict[str, object]:
        if method == "surface.list":
            return {"surfaces": [{"id": SURFACE_ID, "ref": "surface:1", "focused": True, "pane_id": PANE_ID,
                                  "pane_ref": "pane:1", "type": "terminal"}]}
        if method == "workspace.list":
            return {"workspaces": [{"id": WORKSPACE_ID, "ref": "workspace:1", "index": 1}]}
        if method == "surface.current":
            return {"workspace_id": WORKSPACE_ID, "workspace_ref": "workspace:1", "pane_id": PANE_ID,
                    "pane_ref": "pane:1", "surface_id": SURFACE_ID, "surface_ref": "surface:1",
                    "surface_type": "terminal"}
        if method == "feed.push":
            return {"item_id": "item-1", "status": "accepted"}
        return {}


def first_key(line: str) -> str | None:
    pairs = json.loads(line, object_pairs_hook=lambda items: items)
    return pairs[0][0] if pairs else None


def large_lines_with_late_method(lines: list[str]) -> list[str]:
    late = []
    for line in lines:
        if len(line.encode("utf-8")) <= CLASSIFICATION_PREFIX_BYTES or not line.startswith("{"):
            continue
        if first_key(line) != "method":
            late.append(line)
    return late


def count_large(lines: list[str]) -> int:
    return sum(1 for line in lines if len(line.encode("utf-8")) > CLASSIFICATION_PREFIX_BYTES)


def run_cli(cli_path: str, socket_path: Path, home: Path, args: list[str], stdin: str | None = None
            ) -> subprocess.CompletedProcess[str]:
    env = cli_environment(socket_path, home=home, CMUX_WORKSPACE_ID=WORKSPACE_ID, CMUX_SURFACE_ID=SURFACE_ID)
    return subprocess.run(
        [cli_path, "--socket", str(socket_path), *args],
        input=stdin,
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=30,
    )


def scenarios() -> list[tuple[str, list[str], str | None]]:
    long_command = "echo " + ("cmux-large-request " * 160)
    large_input = "x" * 6_000
    claude_event = {
        "hook_event_name": "PostToolUse",
        "session_id": "large-request-session",
        "cwd": "/tmp",
        "tool_name": "Write",
        "tool_input": {"file_path": "/tmp/large.txt", "content": large_input},
        "tool_response": {"success": True},
    }
    # Codex prompt submits take the ordered feed lane, which waits for the reply.
    codex_event = {
        "hook_event_name": "UserPromptSubmit",
        "session_id": "large-request-codex",
        "cwd": "/tmp",
        "prompt": "Summarize this log:\n" + large_input,
    }
    return [
        ("respawn-pane", ["respawn-pane", "--workspace", WORKSPACE_ID, "--surface", SURFACE_ID,
                          "--command", long_command], None),
        ("claude PostToolUse feed hook", ["hooks", "feed", "--source", "claude", "--event", "PostToolUse"],
         json.dumps(claude_event)),
        ("codex UserPromptSubmit feed hook", ["hooks", "feed", "--source", "codex", "--event", "UserPromptSubmit"],
         json.dumps(codex_event)),
    ]


def run_scenarios(cli_path: str, socket_path: Path, home: Path, failures: list[str]) -> None:
    with RecordingSocket(socket_path) as recorder:
        for label, args, stdin in scenarios():
            for run in range(RUNS_PER_SCENARIO):
                proc = run_cli(cli_path, socket_path, home, args, stdin)
                lines = recorder.take()
                if count_large(lines) == 0:
                    failures.append(f"{label} run {run}: sent no request line over "
                                    f"{CLASSIFICATION_PREFIX_BYTES} bytes")
                if proc.returncode != 0:
                    failures.append(f"{label} run {run}: exit {proc.returncode}\n"
                                    f"stdout={proc.stdout}\nstderr={proc.stderr}")
                    continue
                for line in large_lines_with_late_method(lines):
                    failures.append(f"{label} run {run}: first key {first_key(line)!r}, "
                                    f"method at byte {line.find(chr(34) + 'method' + chr(34))} "
                                    f"of {len(line)}")
            print(f"{label}: {RUNS_PER_SCENARIO} runs checked")


def main() -> int:
    cli_path = resolve_cmux_cli()
    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="cmux-large-req-") as tmp:
        root = Path(tmp)
        # Unix socket paths are short, so the socket lives under /tmp.
        socket_dir = Path(tempfile.mkdtemp(prefix="cmux-lr-", dir="/tmp"))
        socket_path = socket_dir / "s.sock"
        home = root / "home"
        home.mkdir()
        try:
            run_scenarios(cli_path, socket_path, home, failures)
        finally:
            shutil.rmtree(socket_dir, ignore_errors=True)

    if failures:
        print("FAIL: large CLI requests must start with their method key")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("PASS: every large CLI request line starts with its method key")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
