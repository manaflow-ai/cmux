#!/usr/bin/env python3
"""A restored OpenCode session keeps the config, data and state roots it launched with (#15657).

OpenCode reads its config from `OPENCODE_CONFIG_DIR`, then `XDG_CONFIG_HOME`,
and its sessions database from `OPENCODE_DB`, then `XDG_DATA_HOME`, with
`OPENCODE_CONFIG` naming one more config file and `XDG_STATE_HOME` its state.
When cmux records an OpenCode launch for restore, it kept only
`OPENCODE_CONFIG_DIR`, so a session started under any of the others resumed
against the default roots, where its session does not exist.

This drives the real `cmux hooks opencode session-start` against a fake socket
and checks the launch record the hook saves and the resume binding it sends:
- an OpenCode launch, and an `omo` launch of OpenCode, keep all six roots;
- a relative XDG root is dropped, since it would resolve against whatever cwd
  the restored pane starts in;
- secrets in the same environment are never recorded.
"""

from __future__ import annotations

import base64
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
SURFACE_ID = "22222222-2222-4222-8222-222222222222"


class RecordingSocket:
    def __init__(self, path: Path) -> None:
        self.path = path
        self._messages: list[str] = []
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._ready = threading.Event()
        self._thread = threading.Thread(target=self._serve, daemon=True)

    def __enter__(self) -> "RecordingSocket":
        self.path.unlink(missing_ok=True)
        self._thread.start()
        if not self._ready.wait(timeout=3):
            raise RuntimeError("fake socket did not start")
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

    def requests(self, method: str) -> list[dict[str, object]]:
        with self._lock:
            lines = list(self._messages)
        found = []
        for line in lines:
            try:
                payload = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(payload, dict) and payload.get("method") == method:
                found.append(payload)
        return found

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
                    self._messages.append(line)
                try:
                    request = json.loads(line)
                except json.JSONDecodeError:
                    stream.write(b"OK\n")
                    stream.flush()
                    continue
                method = request.get("method") if isinstance(request, dict) else None
                if method == "surface.list":
                    result: dict[str, object] = {"surfaces": [{"id": SURFACE_ID, "ref": "surface:1", "focused": True}]}
                elif method == "agent.resolve_delivery_target":
                    params = request.get("params")
                    result = {"workspace_id": WORKSPACE_ID, "surface_id": SURFACE_ID, "source": "pid",
                              "pid_resolution": params.get("pid_resolution") if isinstance(params, dict) else None}
                else:
                    result = {}
                response = {"id": request.get("id") or "unknown", "ok": True, "result": result}
                stream.write((json.dumps(response) + "\n").encode("utf-8"))
                stream.flush()


def launch_argv_b64(argv: list[str]) -> str:
    return base64.b64encode(b"".join(value.encode("utf-8") + b"\0" for value in argv)).decode("ascii")


def run_session_start(cli_path: str, root: Path, name: str, launcher: str, extra_env: dict[str, str]
                      ) -> tuple[dict[str, object], dict[str, object] | None, list[str]]:
    """Runs the hook once; returns the stored launch command, the resume binding params and failures."""
    failures: list[str] = []
    state_dir = root / f"{name}-state"
    workspace = root / f"{name}-workspace"
    state_dir.mkdir()
    workspace.mkdir()
    session_id = f"ses_{name}"
    # Unix socket paths are short, so the socket lives under /tmp.
    socket_dir = Path(tempfile.mkdtemp(prefix="cmux-oc-", dir="/tmp"))
    socket_path = socket_dir / "s.sock"
    executable = "/Users/example/.opencode/bin/opencode" if launcher == "opencode" else "/Users/example/.bun/bin/omo"
    argv = [executable, "--model", "anthropic/claude-sonnet-4-5"]
    env = cli_environment(
        socket_path,
        home=root / f"{name}-home",
        PWD=str(workspace),
        CMUX_WORKSPACE_ID=WORKSPACE_ID,
        CMUX_SURFACE_ID=SURFACE_ID,
        CMUX_AGENT_HOOK_STATE_DIR=str(state_dir),
        CMUX_AGENT_LAUNCH_KIND=launcher,
        CMUX_AGENT_LAUNCH_EXECUTABLE=executable,
        CMUX_AGENT_LAUNCH_ARGV_B64=launch_argv_b64(argv),
        CMUX_AGENT_LAUNCH_CWD=str(workspace),
        **extra_env,
    )
    for key in ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "OPENCODE_DB", "OPENCODE_CONFIG",
                "OPENCODE_CONFIG_DIR"):
        if key not in extra_env:
            env.pop(key, None)
    (root / f"{name}-home").mkdir()
    hook_input = json.dumps({"session_id": session_id, "cwd": str(workspace), "hook_event_name": "SessionStart"})

    try:
        with RecordingSocket(socket_path) as server:
            result = subprocess.run(
                [cli_path, "hooks", "opencode", "session-start"],
                input=hook_input, capture_output=True, text=True, check=False, env=env, timeout=30,
            )
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and not server.requests("surface.resume.set"):
                time.sleep(0.05)
            resume_sets = server.requests("surface.resume.set")
    finally:
        shutil.rmtree(socket_dir, ignore_errors=True)

    if result.returncode != 0:
        failures.append(f"{name}: hook exited {result.returncode}\nstdout={result.stdout}\nstderr={result.stderr}")
        return {}, None, failures
    store_path = state_dir / "opencode-hook-sessions.json"
    try:
        session = json.loads(store_path.read_text(encoding="utf-8"))["sessions"][session_id]
    except Exception as exc:  # noqa: BLE001 - report what the hook left behind
        failures.append(f"{name}: no stored session in {store_path}: {exc}")
        return {}, None, failures
    if "secret-should-not-persist" in json.dumps(session):
        failures.append(f"{name}: a secret reached the stored session: {session!r}")
    launch_command = session.get("launchCommand")
    if not isinstance(launch_command, dict):
        failures.append(f"{name}: no launch command stored: {session!r}")
        return {}, None, failures
    params = resume_sets[-1].get("params") if resume_sets else None
    return launch_command, params if isinstance(params, dict) else None, failures


ROOTS = {
    "XDG_CONFIG_HOME": "/Users/example/dotfiles/config",
    "XDG_DATA_HOME": "/Volumes/work/share",
    "XDG_STATE_HOME": "/Volumes/work/state",
    "OPENCODE_DB": "/Volumes/work/opencode/sessions.db",
    "OPENCODE_CONFIG": "/Users/example/dotfiles/opencode/extra.jsonc",
    "OPENCODE_CONFIG_DIR": "/Users/example/dotfiles/opencode",
}


def check_keeps_roots(cli_path: str, root: Path, launcher: str) -> list[str]:
    launch_command, params, failures = run_session_start(
        cli_path, root, f"keeps-{launcher}", launcher, {**ROOTS, "OPENAI_API_KEY": "secret-should-not-persist"}
    )
    if failures:
        return failures
    environment = launch_command.get("environment") or {}
    for key, value in ROOTS.items():
        if environment.get(key) != value:
            failures.append(f"{launcher} launch: stored environment has {key}={environment.get(key)!r}, "
                            f"expected {value!r}; stored {environment!r}")
    if "OPENAI_API_KEY" in environment:
        failures.append(f"{launcher} launch: stored a secret key: {environment!r}")
    if params is None:
        failures.append(f"{launcher} launch: no surface.resume.set was sent")
    else:
        # The environment the restored command is started with.
        replay = params.get("environment")
        replay = replay if isinstance(replay, dict) else {}
        for key, value in ROOTS.items():
            if replay.get(key) != value:
                failures.append(f"{launcher} launch: resume binding environment has {key}={replay.get(key)!r}, "
                                f"expected {value!r}; binding {params!r}")
    return failures


def check_drops_relative_roots(cli_path: str, root: Path) -> list[str]:
    relative = {"XDG_CONFIG_HOME": "dotfiles/config", "XDG_DATA_HOME": "~/share", "XDG_STATE_HOME": "./state",
                "OPENCODE_DB": "sessions.db", "OPENCODE_CONFIG": "extra.jsonc"}
    launch_command, _params, failures = run_session_start(cli_path, root, "relative", "opencode", relative)
    if failures:
        return failures
    environment = launch_command.get("environment") or {}
    kept = {key: environment[key] for key in relative if key in environment}
    if kept:
        failures.append(f"relative roots were recorded for replay: {kept!r}")
    return failures


def main() -> int:
    cli_path = resolve_cmux_cli()
    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="cmux-oc-roots-") as tmp:
        root = Path(tmp)
        failures += check_keeps_roots(cli_path, root, "opencode")
        failures += check_keeps_roots(cli_path, root, "omo")
        failures += check_drops_relative_roots(cli_path, root)
    if failures:
        print("FAIL: OpenCode restore environment roots")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("PASS: OpenCode launches keep their absolute config, data and state roots for restore")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
