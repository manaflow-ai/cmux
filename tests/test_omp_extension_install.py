#!/usr/bin/env python3
"""
Regression test: the generated OMP extension is importable and emits cmux hook calls with complete payloads.
"""

from __future__ import annotations

import base64
import json
import os
import shutil
import subprocess
import socket
import tempfile
import time
import threading
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def wait_for_text(path: Path, expected_count: int, timeout: float = 5.0) -> str:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            text = path.read_text(encoding="utf-8")
            if len([line for line in text.splitlines() if line.strip()]) >= expected_count:
                return text
        time.sleep(0.05)
    return path.read_text(encoding="utf-8") if path.exists() else ""


class MockCmuxSocket:
    def __init__(self, path: Path, workspace_id: str, surface_id: str) -> None:
        self.path = path
        self.workspace_id = workspace_id
        self.surface_id = surface_id
        self._messages: list[str] = []
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._server: socket.socket | None = None
        self._thread: threading.Thread | None = None

    def __enter__(self) -> "MockCmuxSocket":
        try:
            self.path.unlink()
        except FileNotFoundError:
            pass
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(self.path))
        server.listen(16)
        server.settimeout(0.1)
        self._server = server
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, *_exc: object) -> None:
        self._stop.set()
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.connect(str(self.path))
        except OSError:
            pass
        if self._thread is not None:
            self._thread.join(timeout=2)
        if self._server is not None:
            self._server.close()
        try:
            self.path.unlink()
        except FileNotFoundError:
            pass

    def messages(self) -> list[str]:
        with self._lock:
            return list(self._messages)

    def _serve(self) -> None:
        assert self._server is not None
        while not self._stop.is_set():
            try:
                conn, _addr = self._server.accept()
            except TimeoutError:
                continue
            except OSError:
                return
            self._handle(conn)

    def _handle(self, conn: socket.socket) -> None:
        with conn:
            reader = conn.makefile("rb")
            while True:
                line_bytes = reader.readline()
                if not line_bytes:
                    return
                line = line_bytes.decode("utf-8", errors="replace").rstrip("\n")
                if line:
                    with self._lock:
                        self._messages.append(line)
                response = self._response(line)
                try:
                    conn.sendall(response.encode("utf-8") + b"\n")
                except BrokenPipeError:
                    return

    def _response(self, line: str) -> str:
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            return "OK"
        request_id = payload.get("id") or "unknown"
        method = payload.get("method")
        if method == "surface.list":
            result = {
                "surfaces": [
                    {
                        "id": self.surface_id,
                        "ref": "surface:1",
                        "focused": True,
                    }
                ]
            }
        elif method == "surface.resume.set":
            result = {"ok": True}
        elif method == "feed.push":
            result = {}
        else:
            result = {}
        return json.dumps({"id": request_id, "ok": True, "result": result}, separators=(",", ":"))


def json_rpc_messages(messages: list[str], method: str) -> list[dict[str, object]]:
    matches: list[dict[str, object]] = []
    for line in messages:
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue
        if payload.get("method") == method:
            matches.append(payload)
    return matches


def verify_hook_persistence(cli_path: str, root: Path, base_env: dict[str, str]) -> bool:
    hook_state_dir = root / "hook-state"
    workspace = root / "hook-workspace"
    hook_state_dir.mkdir()
    workspace.mkdir()
    workspace_id = "11111111-1111-1111-1111-111111111111"
    surface_id = "22222222-2222-2222-2222-222222222222"
    session_id = "omp-hook-session-123"
    socket_path = Path("/tmp") / f"cmux-omp-hook-{os.getpid()}-{time.monotonic_ns()}.sock"
    launch_argv = [
        "/Users/example/.bun/bin/omp",
        "--resume",
        "old-session",
        "--model",
        "anthropic/claude-sonnet-4-5",
        "initial prompt should not persist",
    ]
    hook_env = base_env.copy()
    hook_env.pop("PI_CODING_AGENT_DIR", None)
    hook_env.update(
        {
            "PWD": str(workspace),
            "CMUX_SOCKET_PATH": str(socket_path),
            "CMUX_WORKSPACE_ID": workspace_id,
            "CMUX_SURFACE_ID": surface_id,
            "CMUX_AGENT_HOOK_STATE_DIR": str(hook_state_dir),
            "CMUX_AGENT_LAUNCH_KIND": "omp",
            "CMUX_AGENT_LAUNCH_EXECUTABLE": launch_argv[0],
            "CMUX_AGENT_LAUNCH_ARGV_B64": base64.b64encode(
                b"".join(value.encode("utf-8") + b"\0" for value in launch_argv)
            ).decode("ascii"),
            "CMUX_AGENT_LAUNCH_CWD": str(workspace),
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "PI_CONFIG_DIR": ".custom-omp",
            "OPENAI_API_KEY": "secret-should-not-persist",
        }
    )
    hook_input = json.dumps(
        {
            "session_id": session_id,
            "cwd": str(workspace),
            "hook_event_name": "SessionStart",
        },
        separators=(",", ":"),
    )

    with MockCmuxSocket(socket_path, workspace_id=workspace_id, surface_id=surface_id) as server:
        result = subprocess.run(
            [cli_path, "hooks", "omp", "session-start"],
            input=hook_input,
            capture_output=True,
            text=True,
            check=False,
            env=hook_env,
            timeout=20,
        )
        if result.returncode != 0 or result.stdout != "{}\n":
            print("FAIL: omp session-start hook persistence command failed")
            print(f"exit={result.returncode}")
            print(f"stdout={result.stdout.strip()}")
            print(f"stderr={result.stderr.strip()}")
            return False
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if json_rpc_messages(server.messages(), "surface.resume.set"):
                break
            time.sleep(0.05)
        messages = server.messages()

    store_path = hook_state_dir / "omp-hook-sessions.json"
    if not store_path.exists():
        print(f"FAIL: omp hook did not write {store_path}")
        return False
    try:
        store = json.loads(store_path.read_text(encoding="utf-8"))
        session = store["sessions"][session_id]
    except Exception as exc:
        print(f"FAIL: omp hook session store did not contain {session_id}: {exc}")
        print(store_path.read_text(encoding="utf-8"))
        return False

    expected_fields = {
        "sessionId": session_id,
        "workspaceId": workspace_id,
        "surfaceId": surface_id,
        "cwd": str(workspace),
    }
    for key, expected in expected_fields.items():
        if session.get(key) != expected:
            print(f"FAIL: omp hook session {key} expected {expected!r}, got {session.get(key)!r}")
            return False

    launch_command = session.get("launchCommand")
    if not isinstance(launch_command, dict):
        print(f"FAIL: omp hook did not persist launch metadata: {session!r}")
        return False
    expected_arguments = [
        "/Users/example/.bun/bin/omp",
        "--model",
        "anthropic/claude-sonnet-4-5",
    ]
    if launch_command.get("launcher") != "omp" or launch_command.get("executablePath") != launch_argv[0]:
        print(f"FAIL: omp hook persisted wrong launcher metadata: {launch_command!r}")
        return False
    if launch_command.get("arguments") != expected_arguments:
        print(f"FAIL: omp hook persisted unsanitized launch arguments: {launch_command!r}")
        return False
    if launch_command.get("workingDirectory") != str(workspace):
        print(f"FAIL: omp hook persisted wrong working directory: {launch_command!r}")
        return False
    if launch_command.get("environment") != {"PI_CONFIG_DIR": ".custom-omp"}:
        print(f"FAIL: omp hook did not persist PI_CONFIG_DIR for resume: {launch_command!r}")
        return False
    if "secret-should-not-persist" in json.dumps(session, sort_keys=True):
        print(f"FAIL: omp hook persisted secret environment data: {session!r}")
        return False

    resume_sets = json_rpc_messages(messages, "surface.resume.set")
    if len(resume_sets) != 1:
        print(f"FAIL: expected one surface.resume.set, saw {messages!r}")
        return False
    params = resume_sets[0].get("params")
    if not isinstance(params, dict):
        print(f"FAIL: surface.resume.set missing params: {resume_sets[0]!r}")
        return False
    if params.get("kind") != "omp" or params.get("checkpoint_id") != session_id or params.get("auto_resume") is not True:
        print(f"FAIL: surface.resume.set had wrong OMP binding params: {params!r}")
        return False
    command = params.get("command")
    if not isinstance(command, str) or "--session" not in command or session_id not in command:
        print(f"FAIL: surface.resume.set command cannot resume OMP session: {params!r}")
        return False
    return True


def main() -> int:
    bun = shutil.which("bun")
    if bun is None:
        print("SKIP: bun not found")
        return 0

    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(prefix="cmux-omp-extension-") as td:
        root = Path(td)
        home = root / "home"
        home.mkdir()
        shared_agent_dir = root / "shared-agent-dir"
        shared_pi_extension = shared_agent_dir / "extensions" / "cmux-session.ts"
        shared_pi_extension.parent.mkdir(parents=True)
        shared_pi_extension.write_text("// cmux-pi-session-extension-marker v1\n", encoding="utf-8")

        env = os.environ.copy()
        env["HOME"] = str(home)
        # OMP treats PI_CODING_AGENT_DIR as the full agent directory override.
        # Install the OMP extension there while proving it does not collide with
        # Pi's different cmux-session.ts filename in the same extensions folder.
        env["PI_CODING_AGENT_DIR"] = str(shared_agent_dir)

        install = subprocess.run(
            [cli_path, "hooks", "omp", "install", "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=20,
        )
        if install.returncode != 0:
            print("FAIL: omp extension install failed")
            print(f"exit={install.returncode}")
            print(f"stdout={install.stdout.strip()}")
            print(f"stderr={install.stderr.strip()}")
            return 1

        extension_path = shared_agent_dir / "extensions" / "cmux-omp-session.ts"
        if not extension_path.exists():
            print(f"FAIL: expected extension at {extension_path}")
            return 1
        extension_text = extension_path.read_text(encoding="utf-8")
        if "cmux-omp-session-extension-marker" not in extension_text:
            print(f"FAIL: expected cmux marker in {extension_path}")
            return 1
        if shared_pi_extension.read_text(encoding="utf-8") != "// cmux-pi-session-extension-marker v1\n":
            print("FAIL: OMP install modified the Pi extension in PI_CODING_AGENT_DIR")
            return 1

        reinstall = subprocess.run(
            [cli_path, "hooks", "omp", "install", "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=20,
        )
        if reinstall.returncode != 0 or "already up to date" not in reinstall.stdout:
            print("FAIL: omp extension reinstall was not idempotent")
            print(f"exit={reinstall.returncode}")
            print(f"stdout={reinstall.stdout.strip()}")
            print(f"stderr={reinstall.stderr.strip()}")
            return 1

        fake_cmux = root / "fake-cmux"
        fake_args_log = root / "fake-cmux-args.log"
        fake_stdin_log = root / "fake-cmux-stdin.log"
        fake_env_log = root / "fake-cmux-env.log"
        make_executable(
            fake_cmux,
            """#!/usr/bin/env bash
set -euo pipefail
sleep 3
printf '%s\n' "$*" >> "$FAKE_CMUX_ARGS_LOG"
cat >> "$FAKE_CMUX_STDIN_LOG"
printf '\n---\n' >> "$FAKE_CMUX_STDIN_LOG"
{
  printf 'kind=%s\n' "${CMUX_AGENT_LAUNCH_KIND-}"
  printf 'cwd=%s\n' "${CMUX_AGENT_LAUNCH_CWD-}"
  printf 'argv=%s\n' "${CMUX_AGENT_LAUNCH_ARGV_B64-}"
  if [ "${AMP_API_KEY-}" = "amp-secret" ]; then
    printf 'amp=present\n'
  else
    printf 'amp=missing\n'
  fi
} >> "$FAKE_CMUX_ENV_LOG"
""",
        )

        check_env = env.copy()
        check_env["CMUX_TEST_OMP_EXTENSION_PATH"] = str(extension_path)
        check_env["CMUX_SURFACE_ID"] = "surface-omp-test"
        check_env["CMUX_OMP_CMUX_BIN"] = str(fake_cmux)
        check_env["FAKE_CMUX_ARGS_LOG"] = str(fake_args_log)
        check_env["FAKE_CMUX_STDIN_LOG"] = str(fake_stdin_log)
        check_env["FAKE_CMUX_ENV_LOG"] = str(fake_env_log)
        check_env["AMP_API_KEY"] = "amp-secret"
        check_source = """
const extensionPath = process.env.CMUX_TEST_OMP_EXTENSION_PATH;
const mod = await import(extensionPath);
if (typeof mod.default !== "function") throw new Error("missing default export");
const handlers = new Map();
mod.default({
  on(name, handler) {
    handlers.set(name, handler);
  }
});
for (const name of ["session_start", "before_agent_start", "agent_end"]) {
  if (typeof handlers.get(name) !== "function") throw new Error(`missing ${name}`);
}
process.argv.splice(
  0,
  process.argv.length,
  "/Users/example/.bun/bin/omp",
  "--model",
  "anthropic/claude-sonnet-4-5"
);
const ctx = {
  cwd: "/tmp/omp-project",
  sessionManager: {
    getSessionId() { return "omp-session-test"; }
  }
};
const start = Date.now();
await handlers.get("session_start")({}, ctx);
await handlers.get("before_agent_start")({ prompt: "hello omp" }, ctx);
await handlers.get("agent_end")({
  messages: [
    { role: "user", content: "hello omp" },
    { role: "assistant", content: [{ type: "text", text: "done" }] }
  ],
  stopReason: "completed"
}, ctx);
const elapsed = Date.now() - start;
if (elapsed > 2000) throw new Error(`handlers blocked for ${elapsed}ms`);
"""
        check = subprocess.run(
            [bun, "--eval", check_source],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
            env=check_env,
            timeout=20,
        )
        if check.returncode != 0:
            print("FAIL: generated OMP extension is not importable or blocks handlers")
            print(f"exit={check.returncode}")
            print(f"stdout={check.stdout.strip()}")
            print(f"stderr={check.stderr.strip()}")
            return 1

        expected_invocations = 3
        args_log = wait_for_text(fake_args_log, expected_invocations)
        stdin_log = wait_for_text(fake_stdin_log, expected_invocations * 2)
        env_log = wait_for_text(fake_env_log, expected_invocations * 4)
        for expected in [
            "hooks omp session-start",
            "hooks omp prompt-submit",
            "hooks omp stop",
        ]:
            if expected not in args_log:
                print(f"FAIL: extension did not invoke {expected}, got {args_log!r}")
                return 1
        if '"session_id":"omp-session-test"' not in stdin_log:
            print(f"FAIL: extension did not pass session id, got {stdin_log!r}")
            return 1
        if stdin_log.count('"session_id":"omp-session-test"') != 3:
            print(f"FAIL: expected 3 hook payloads carrying the session id, got {stdin_log!r}")
            return 1
        if '"hook_event_name":"Stop"' not in stdin_log:
            print(f"FAIL: stop hook payload was missing: {stdin_log!r}")
            return 1
        if '"prompt":"hello omp"' not in stdin_log or '"last_assistant_message":"done"' not in stdin_log:
            print(f"FAIL: extension did not pass prompt/assistant payload, got {stdin_log!r}")
            return 1
        if "kind=omp" not in env_log or "cwd=/tmp/omp-project" not in env_log or "argv=" not in env_log:
            print(f"FAIL: extension did not pass launch metadata environment, got {env_log!r}")
            return 1
        if "amp=present" not in env_log:
            print(f"FAIL: extension stripped unrelated AMP_API_KEY from hook environment, got {env_log!r}")
            return 1
        argv_line = next((line for line in env_log.splitlines() if line.startswith("argv=")), "")
        try:
            decoded_argv = [
                value
                for value in base64.b64decode(argv_line.removeprefix("argv=")).decode("utf-8").split("\0")
                if value
            ]
        except Exception as exc:
            print(f"FAIL: extension launch argv was not valid base64 NUL data: {exc}; env={env_log!r}")
            return 1
        expected_argv = [
            "/Users/example/.bun/bin/omp",
            "--model",
            "anthropic/claude-sonnet-4-5",
        ]
        if decoded_argv != expected_argv:
            print(f"FAIL: extension captured wrong OMP launch argv; expected {expected_argv!r}, got {decoded_argv!r}")
            return 1

        if not verify_hook_persistence(cli_path, root, env):
            return 1

        uninstall = subprocess.run(
            [cli_path, "hooks", "omp", "uninstall", "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=20,
        )
        if uninstall.returncode != 0 or extension_path.exists():
            print("FAIL: omp extension uninstall failed")
            print(f"exit={uninstall.returncode}")
            print(f"stdout={uninstall.stdout.strip()}")
            print(f"stderr={uninstall.stderr.strip()}")
            return 1
        foreign_path = extension_path
        foreign_path.parent.mkdir(parents=True, exist_ok=True)
        foreign_path.write_text("// user extension\n", encoding="utf-8")
        uninstall_foreign = subprocess.run(
            [cli_path, "hooks", "omp", "uninstall", "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=20,
        )
        if uninstall_foreign.returncode != 0 or not foreign_path.exists() or "Refusing to remove" not in uninstall_foreign.stdout:
            print("FAIL: omp extension uninstall did not preserve non-cmux file")
            print(f"exit={uninstall_foreign.returncode}")
            print(f"stdout={uninstall_foreign.stdout.strip()}")
            print(f"stderr={uninstall_foreign.stderr.strip()}")
            return 1

        invalid_extension_bytes = b"\xff\xfe\x00cmux-not-utf8"
        foreign_path.write_bytes(invalid_extension_bytes)
        install_invalid = subprocess.run(
            [cli_path, "hooks", "omp", "install", "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=20,
        )
        if install_invalid.returncode == 0 or foreign_path.read_bytes() != invalid_extension_bytes:
            print("FAIL: omp extension install overwrote unreadable existing file")
            print(f"exit={install_invalid.returncode}")
            print(f"stdout={install_invalid.stdout.strip()}")
            print(f"stderr={install_invalid.stderr.strip()}")
            return 1
        install_invalid_output = install_invalid.stdout + install_invalid.stderr
        if "Failed to read" not in install_invalid_output or "not a cmux extension" in install_invalid_output:
            print("FAIL: omp extension install did not report unreadable file distinctly")
            print(f"stdout={install_invalid.stdout.strip()}")
            print(f"stderr={install_invalid.stderr.strip()}")
            return 1
        uninstall_invalid = subprocess.run(
            [cli_path, "hooks", "omp", "uninstall", "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=20,
        )
        if uninstall_invalid.returncode == 0 or foreign_path.read_bytes() != invalid_extension_bytes:
            print("FAIL: omp extension uninstall removed unreadable existing file")
            print(f"exit={uninstall_invalid.returncode}")
            print(f"stdout={uninstall_invalid.stdout.strip()}")
            print(f"stderr={uninstall_invalid.stderr.strip()}")
            return 1
        uninstall_invalid_output = uninstall_invalid.stdout + uninstall_invalid.stderr
        if "Failed to read" not in uninstall_invalid_output or "not a cmux extension" in uninstall_invalid_output:
            print("FAIL: omp extension uninstall did not report unreadable file distinctly")
            print(f"stdout={uninstall_invalid.stdout.strip()}")
            print(f"stderr={uninstall_invalid.stderr.strip()}")
            return 1
        foreign_path.unlink()


        config_override = root / "absolute-omp-config"
        config_env = env.copy()
        config_env.pop("PI_CODING_AGENT_DIR", None)
        config_env["PI_CONFIG_DIR"] = str(config_override)
        config_install = subprocess.run(
            [cli_path, "hooks", "omp", "install", "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=config_env,
            timeout=20,
        )
        config_extension_path = config_override / "agent" / "extensions" / "cmux-omp-session.ts"
        if config_install.returncode != 0 or not config_extension_path.exists():
            print("FAIL: omp extension install did not respect absolute PI_CONFIG_DIR")
            print(f"exit={config_install.returncode}")
            print(f"stdout={config_install.stdout.strip()}")
            print(f"stderr={config_install.stderr.strip()}")
            return 1
        config_uninstall = subprocess.run(
            [cli_path, "hooks", "omp", "uninstall", "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=config_env,
            timeout=20,
        )
        if config_uninstall.returncode != 0 or config_extension_path.exists():
            print("FAIL: omp extension uninstall did not respect absolute PI_CONFIG_DIR")
            print(f"exit={config_uninstall.returncode}")
            print(f"stdout={config_uninstall.stdout.strip()}")
            print(f"stderr={config_uninstall.stderr.strip()}")
            return 1
    print("PASS: generated OMP extension installs, emits complete cmux hook payloads, and persists hook sessions")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
