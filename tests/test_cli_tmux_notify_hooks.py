#!/usr/bin/env python3
"""Regression: tmux notify hooks are installed and refresh caller TTY mapping."""

from __future__ import annotations

import json
import os
import socket
import subprocess
import tempfile
import threading
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli


REQUIRED_EVENTS = {
    "client-attached",
    "client-session-changed",
    "session-created",
    "window-linked",
    "window-renamed",
    "pane-focus-in",
    "after-select-pane",
}


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


class JSONRPCServer:
    def __init__(self, socket_path: str) -> None:
        self.socket_path = socket_path
        self.ready = threading.Event()
        self.error: Exception | None = None
        self.request: dict[str, object] | None = None
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self._thread.start()

    def wait_ready(self, timeout: float = 2.0) -> bool:
        return self.ready.wait(timeout)

    def join(self, timeout: float = 2.0) -> None:
        self._thread.join(timeout)

    def _run(self) -> None:
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            if os.path.exists(self.socket_path):
                os.remove(self.socket_path)
            server.bind(self.socket_path)
            server.listen(1)
            server.settimeout(6.0)
            self.ready.set()

            conn, _ = server.accept()
            with conn:
                data = b""
                while b"\n" not in data:
                    chunk = conn.recv(4096)
                    if not chunk:
                        break
                    data += chunk
                self.request = json.loads(data.decode("utf-8").strip())
                response = {
                    "ok": True,
                    "result": {
                        "workspace_id": "11111111-1111-1111-1111-111111111111",
                        "surface_id": "22222222-2222-2222-2222-222222222222",
                        "tty_name": "ttys-pane",
                    },
                }
                conn.sendall((json.dumps(response) + "\n").encode("utf-8"))
        except Exception as exc:  # pragma: no cover - surfaced explicitly by caller
            self.error = exc
            self.ready.set()
        finally:
            server.close()


def read_json_lines(path: Path) -> list[list[str]]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def test_tmux_init(cli_path: str, tmp: Path) -> list[str]:
    fake_bin = tmp / "bin"
    fake_bin.mkdir()
    log_path = tmp / "tmux-args.jsonl"
    make_executable(
        fake_bin / "tmux",
        """#!/usr/bin/env python3
import json
import os
import sys

with open(os.environ["FAKE_TMUX_LOG"], "a", encoding="utf-8") as fh:
    fh.write(json.dumps(sys.argv[1:]) + "\\n")

args = sys.argv[1:]
if args[:3] == ["show-options", "-gqv", "@cmux_hooks_version"]:
    print(os.environ.get("FAKE_TMUX_MARKER", ""))
sys.exit(0)
""",
    )

    env = os.environ.copy()
    env["PATH"] = f"{fake_bin}:{env.get('PATH', '')}"
    env["HOME"] = str(tmp / "home")
    env["FAKE_TMUX_LOG"] = str(log_path)
    env["FAKE_TMUX_MARKER"] = "stale"
    env["CMUX_SOCKET_PATH"] = "/tmp/cmux-test.sock"
    env["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
    env["CMUX_PANEL_ID"] = "22222222-2222-2222-2222-222222222222"
    env["CMUX_BUNDLED_CLI_PATH"] = cli_path
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"

    proc = subprocess.run(
        [cli_path, "tmux", "init"],
        text=True,
        capture_output=True,
        env=env,
        timeout=10,
        check=False,
    )
    failures: list[str] = []
    if proc.returncode != 0:
        failures.append(f"`cmux tmux init` exited {proc.returncode}: stdout={proc.stdout!r} stderr={proc.stderr!r}")
        return failures

    calls = read_json_lines(log_path)
    set_option_calls = [call for call in calls if call[:3] == ["set-option", "-g", "@cmux_hooks_version"]]
    if not set_option_calls or set_option_calls[-1][3:] != ["1"]:
        failures.append(f"expected @cmux_hooks_version marker set to 1, got {set_option_calls!r}")

    hook_calls = [call for call in calls if len(call) >= 4 and call[0] == "set-hook" and call[1] == "-g"]
    events = {call[2] for call in hook_calls}
    missing = REQUIRED_EVENTS - events
    if missing:
        failures.append(f"missing tmux hooks: {sorted(missing)}")

    for event in REQUIRED_EVENTS:
        command = next((call[-1] for call in hook_calls if call[2] == event), "")
        if "tmux refresh" not in command:
            failures.append(f"{event} hook does not call `cmux tmux refresh`: {command!r}")
        if f"--event {event}" not in command:
            failures.append(f"{event} hook does not pass its event name: {command!r}")
        if "#{pane_tty}" not in command:
            failures.append(f"{event} hook does not pass pane tty: {command!r}")
        if "#{client_tty}" not in command:
            failures.append(f"{event} hook does not pass client tty: {command!r}")
        if ">/dev/null 2>&1 || true" not in command:
            failures.append(f"{event} hook is not quiet/failure-tolerant: {command!r}")

    return failures


def test_tmux_refresh(cli_path: str, tmp: Path) -> list[str]:
    socket_path = str(tmp / "cmux.sock")
    server = JSONRPCServer(socket_path)
    server.start()
    failures: list[str] = []

    if not server.wait_ready():
        return ["fake socket did not become ready"]

    env = os.environ.copy()
    env["CMUX_SOCKET_PATH"] = socket_path
    env["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
    env["CMUX_PANEL_ID"] = "22222222-2222-2222-2222-222222222222"
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"

    proc = subprocess.run(
        [
            cli_path,
            "tmux",
            "refresh",
            "--event",
            "client-attached",
            "--pane-tty",
            "/dev/ttys-pane",
            "--client-tty",
            "/dev/ttys-client",
            "--session",
            "work",
            "--window",
            "2",
            "--pane",
            "%7",
        ],
        text=True,
        capture_output=True,
        env=env,
        timeout=10,
        check=False,
    )
    server.join()
    try:
        os.remove(socket_path)
    except OSError:
        pass

    if proc.returncode != 0:
        failures.append(f"`cmux tmux refresh` exited {proc.returncode}: stdout={proc.stdout!r} stderr={proc.stderr!r}")
        return failures
    if server.error is not None:
        failures.append(f"fake socket error: {server.error}")
        return failures

    request = server.request or {}
    if request.get("method") != "surface.report_tty":
        failures.append(f"expected surface.report_tty request, got {request!r}")
        return failures
    params = request.get("params")
    if not isinstance(params, dict):
        failures.append(f"expected JSON params dict, got {request!r}")
        return failures

    expected = {
        "workspace_id": "11111111-1111-1111-1111-111111111111",
        "surface_id": "22222222-2222-2222-2222-222222222222",
        "tty_name": "/dev/ttys-pane",
        "client_tty_name": "/dev/ttys-client",
        "tmux_event": "client-attached",
        "tmux_session": "work",
        "tmux_window": "2",
        "tmux_pane": "%7",
    }
    for key, value in expected.items():
        if params.get(key) != value:
            failures.append(f"expected params[{key!r}]={value!r}, got {params.get(key)!r} in {params!r}")

    return failures


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(prefix="cmux-tmux-notify-hooks-") as td:
        tmp = Path(td)
        failures = test_tmux_init(cli_path, tmp) + test_tmux_refresh(cli_path, tmp)

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1

    print("PASS: tmux notify hooks install and refresh caller TTY mapping")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
