#!/usr/bin/env python3
"""
Regression test: the generated Campfire extension installs cleanly, emits cmux
hook calls with complete payloads for the HOST role only, normalizes the
bun-compiled launch argv, bridges campfire observer events to notifications,
and persists restorable hook sessions without secrets or invite URLs.
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
        request_id = payload["id"] if "id" in payload else "unknown"
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
    session_id = "campfire-hook-session-123"
    socket_path = Path("/tmp") / f"cmux-campfire-hook-{os.getpid()}-{time.monotonic_ns()}.sock"
    launch_argv = [
        "/Users/example/.local/bin/campfire",
        "--session",
        "old-session",
        "--relay",
        "wss://relay.example/ws",
        "--model",
        "anthropic/claude-sonnet-4-5",
        "initial prompt should not persist",
    ]
    hook_env = base_env.copy()
    hook_env.pop("CAMPFIRE_CODING_AGENT_DIR", None)
    hook_env.update(
        {
            "PWD": str(workspace),
            "CMUX_SOCKET_PATH": str(socket_path),
            "CMUX_WORKSPACE_ID": workspace_id,
            "CMUX_SURFACE_ID": surface_id,
            "CMUX_AGENT_HOOK_STATE_DIR": str(hook_state_dir),
            "CMUX_AGENT_LAUNCH_KIND": "campfire",
            "CMUX_AGENT_LAUNCH_EXECUTABLE": launch_argv[0],
            "CMUX_AGENT_LAUNCH_ARGV_B64": base64.b64encode(
                b"".join(value.encode("utf-8") + b"\0" for value in launch_argv)
            ).decode("ascii"),
            "CMUX_AGENT_LAUNCH_CWD": str(workspace),
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CAMPFIRE_RELAY_URL": "wss://relay.example/ws",
            "PI_PACKAGE_DIR": "/tmp/stale-pi-cache-should-not-persist",
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
            [cli_path, "hooks", "campfire", "session-start"],
            input=hook_input,
            capture_output=True,
            text=True,
            check=False,
            env=hook_env,
            timeout=20,
        )
        if result.returncode != 0 or result.stdout != "{}\n":
            print("FAIL: campfire session-start hook persistence command failed")
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

    store_path = hook_state_dir / "campfire-hook-sessions.json"
    if not store_path.exists():
        print(f"FAIL: campfire hook did not write {store_path}")
        return False
    try:
        store = json.loads(store_path.read_text(encoding="utf-8"))
        session = store["sessions"][session_id]
    except Exception as exc:
        print(f"FAIL: campfire hook session store did not contain {session_id}: {exc}")
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
            print(f"FAIL: campfire hook session {key} expected {expected!r}, got {session.get(key)!r}")
            return False

    launch_command = session.get("launchCommand")
    if not isinstance(launch_command, dict):
        print(f"FAIL: campfire hook did not persist launch metadata: {session!r}")
        return False
    expected_arguments = [
        "/Users/example/.local/bin/campfire",
        "--relay",
        "wss://relay.example/ws",
        "--model",
        "anthropic/claude-sonnet-4-5",
    ]
    if launch_command.get("launcher") != "campfire" or launch_command.get("executablePath") != launch_argv[0]:
        print(f"FAIL: campfire hook persisted wrong launcher metadata: {launch_command!r}")
        return False
    if launch_command.get("arguments") != expected_arguments:
        print(f"FAIL: campfire hook persisted unsanitized launch arguments: {launch_command!r}")
        return False
    if launch_command.get("workingDirectory") != str(workspace):
        print(f"FAIL: campfire hook persisted wrong working directory: {launch_command!r}")
        return False
    if launch_command.get("environment") != {"CAMPFIRE_RELAY_URL": "wss://relay.example/ws"}:
        print(f"FAIL: campfire hook persisted wrong resume environment: {launch_command!r}")
        return False
    persisted = json.dumps(session, sort_keys=True)
    if "secret-should-not-persist" in persisted:
        print(f"FAIL: campfire hook persisted secret environment data: {session!r}")
        return False
    if "stale-pi-cache-should-not-persist" in persisted:
        print(f"FAIL: campfire hook persisted self-managed PI_PACKAGE_DIR: {session!r}")
        return False

    resume_sets = json_rpc_messages(messages, "surface.resume.set")
    if len(resume_sets) != 1:
        print(f"FAIL: expected one surface.resume.set, saw {messages!r}")
        return False
    params = resume_sets[0].get("params")
    if not isinstance(params, dict):
        print(f"FAIL: surface.resume.set missing params: {resume_sets[0]!r}")
        return False
    if params.get("kind") != "campfire" or params.get("checkpoint_id") != session_id or params.get("auto_resume") is not True:
        print(f"FAIL: surface.resume.set had wrong Campfire binding params: {params!r}")
        return False
    command = params.get("command")
    if not isinstance(command, str) or "--session" not in command or session_id not in command:
        print(f"FAIL: surface.resume.set command cannot resume Campfire session: {params!r}")
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

    with tempfile.TemporaryDirectory(prefix="cmux-campfire-extension-") as td:
        root = Path(td)
        home = root / "home"
        home.mkdir()

        env = os.environ.copy()
        env["HOME"] = str(home)
        env.pop("CAMPFIRE_CODING_AGENT_DIR", None)

        install = subprocess.run(
            [cli_path, "hooks", "campfire", "install", "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=20,
        )
        if install.returncode != 0:
            print("FAIL: campfire extension install failed")
            print(f"exit={install.returncode}")
            print(f"stdout={install.stdout.strip()}")
            print(f"stderr={install.stderr.strip()}")
            return 1

        extension_path = home / ".campfire" / "agent" / "extensions" / "cmux-campfire-session.ts"
        if not extension_path.exists():
            print(f"FAIL: expected extension at {extension_path}")
            return 1
        extension_text = extension_path.read_text(encoding="utf-8")
        if "cmux-campfire-session-extension-marker" not in extension_text:
            print(f"FAIL: expected cmux marker in {extension_path}")
            return 1

        reinstall = subprocess.run(
            [cli_path, "hooks", "campfire", "install", "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=20,
        )
        if reinstall.returncode != 0 or "already up to date" not in reinstall.stdout:
            print("FAIL: campfire extension reinstall was not idempotent")
            print(f"exit={reinstall.returncode}")
            print(f"stdout={reinstall.stdout.strip()}")
            print(f"stderr={reinstall.stderr.strip()}")
            return 1

        fake_cmux = root / "fake-cmux"
        fake_args_log = root / "fake-cmux-args.log"
        fake_stdin_log = root / "fake-cmux-stdin.log"
        fake_env_log = root / "fake-cmux-env.log"
        fake_order_log = root / "fake-cmux-order.log"
        make_executable(
            fake_cmux,
            """#!/usr/bin/env bash
set -euo pipefail
printf 'start %s\n' "$*" >> "$FAKE_CMUX_ORDER_LOG"
case "$*" in
  *notification*) sleep 1 ;;
  *) sleep 0.15 ;;
esac
printf '%s\n' "$*" >> "$FAKE_CMUX_ARGS_LOG"
cat >> "$FAKE_CMUX_STDIN_LOG"
printf '\n---\n' >> "$FAKE_CMUX_STDIN_LOG"
{
  printf 'kind=%s\n' "${CMUX_AGENT_LAUNCH_KIND-}"
  printf 'cwd=%s\n' "${CMUX_AGENT_LAUNCH_CWD-}"
  printf 'argv=%s\n' "${CMUX_AGENT_LAUNCH_ARGV_B64-}"
} >> "$FAKE_CMUX_ENV_LOG"
printf 'end %s\n' "$*" >> "$FAKE_CMUX_ORDER_LOG"
""",
        )

        check_env = env.copy()
        check_env["CMUX_TEST_CAMPFIRE_EXTENSION_PATH"] = str(extension_path)
        check_env["CMUX_SURFACE_ID"] = "surface-campfire-test"
        check_env["CMUX_CAMPFIRE_CMUX_BIN"] = str(fake_cmux)
        check_env["FAKE_CMUX_ARGS_LOG"] = str(fake_args_log)
        check_env["FAKE_CMUX_STDIN_LOG"] = str(fake_stdin_log)
        check_env["FAKE_CMUX_ENV_LOG"] = str(fake_env_log)
        check_env["FAKE_CMUX_ORDER_LOG"] = str(fake_order_log)
        check_env["CAMPFIRE_SESSION_ROLE"] = "host"
        check_env["CMUX_AGENT_LAUNCH_KIND"] = "claude"
        check_env["CMUX_AGENT_LAUNCH_EXECUTABLE"] = "/usr/local/bin/claude"
        check_env["CMUX_AGENT_LAUNCH_ARGV_B64"] = base64.b64encode(
            b"/usr/local/bin/claude\0--resume\0stale-parent-session\0"
        ).decode("ascii")
        check_env["CMUX_AGENT_LAUNCH_CWD"] = "/tmp/stale-parent-project"
        check_source = """
const extensionPath = process.env.CMUX_TEST_CAMPFIRE_EXTENSION_PATH;
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
// Simulate the bun-compiled campfire binary: real binary at argv[0], the bunfs
// virtual entry at argv[1]. The captured launch argv must drop the bunfs entry.
process.argv.splice(
  0,
  process.argv.length,
  "/Users/example/.local/bin/campfire",
  "/$bunfs/root/campfire",
  "--relay",
  "wss://relay.example/ws"
);
const ctx = {
  cwd: "/tmp/campfire-project",
  sessionManager: {
    getSessionId() { return "campfire-session-test"; }
  }
};
const start = Date.now();
await handlers.get("session_start")({}, ctx);
await handlers.get("before_agent_start")({ prompt: "hello campfire" }, ctx);
await handlers.get("agent_end")({
  messages: [
    { role: "user", content: "hello campfire" },
    { role: "assistant", content: [{ type: "text", text: "done" }] }
  ],
  stopReason: "completed"
}, ctx);
// Campfire publishes observer events on a versioned global bridge; the
// extension subscribed at load. Emitting a join request must produce a
// notification hook call.
const bridge = globalThis[Symbol.for("campfire.observer.v1")];
if (!bridge || bridge.listeners.size === 0) throw new Error("extension did not subscribe to the observer bridge");
for (const listener of bridge.listeners) {
  listener({ type: "join.requested", displayName: "alice" });
  listener({ type: "presence.changed", count: 1 });
}
const elapsed = Date.now() - start;
if (elapsed > 2000) throw new Error(`handlers blocked for ${elapsed}ms`);
await new Promise((resolve) => setTimeout(resolve, 300));
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
            print("FAIL: generated Campfire extension is not importable or blocks handlers")
            print(f"exit={check.returncode}")
            print(f"stdout={check.stdout.strip()}")
            print(f"stderr={check.stderr.strip()}")
            return 1

        expected_invocations = 4
        args_log = wait_for_text(fake_args_log, expected_invocations)
        stdin_log = wait_for_text(fake_stdin_log, expected_invocations * 2)
        env_log = wait_for_text(fake_env_log, expected_invocations * 3)
        order_log = wait_for_text(fake_order_log, expected_invocations * 2)
        order_lines = [line for line in order_log.splitlines() if line.strip()]
        expected_lifecycle_order = [
            "start hooks campfire session-start",
            "end hooks campfire session-start",
            "start hooks campfire prompt-submit",
            "end hooks campfire prompt-submit",
            "start hooks campfire stop",
            "end hooks campfire stop",
        ]
        if order_lines[: len(expected_lifecycle_order)] != expected_lifecycle_order:
            print(f"FAIL: lifecycle hooks did not run serially, got {order_log!r}")
            return 1
        for expected in [
            "hooks campfire session-start",
            "hooks campfire prompt-submit",
            "hooks campfire stop",
            "hooks campfire notification",
        ]:
            if expected not in args_log:
                print(f"FAIL: extension did not invoke {expected}, got {args_log!r}")
                return 1
        if stdin_log.count('"session_id":"campfire-session-test"') != 4:
            print(f"FAIL: expected 4 hook payloads carrying the session id, got {stdin_log!r}")
            return 1
        if '"prompt":"hello campfire"' not in stdin_log or '"last_assistant_message":"done"' not in stdin_log:
            print(f"FAIL: extension did not pass prompt/assistant payload, got {stdin_log!r}")
            return 1
        if (
            '"campfire_event_type":"join.requested"' not in stdin_log
            or '"display_name":"alice"' not in stdin_log
        ):
            print(f"FAIL: extension did not bridge the structured join request notification, got {stdin_log!r}")
            return 1
        if '"presence.changed"' in stdin_log:
            print(f"FAIL: extension forwarded a non-actionable observer event, got {stdin_log!r}")
            return 1
        if "kind=campfire" not in env_log or "cwd=/tmp/campfire-project" not in env_log:
            print(f"FAIL: extension did not pass launch metadata environment, got {env_log!r}")
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
            "/Users/example/.local/bin/campfire",
            "--relay",
            "wss://relay.example/ws",
        ]
        if decoded_argv != expected_argv:
            print(f"FAIL: extension captured wrong Campfire launch argv; expected {expected_argv!r}, got {decoded_argv!r}")
            return 1

        # The JOINER role must record nothing: its argv carries the invite URL,
        # a capability token that must never be persisted or replayed.
        joiner_args_log = root / "fake-cmux-joiner-args.log"
        joiner_env = check_env.copy()
        joiner_env["CAMPFIRE_SESSION_ROLE"] = "joiner"
        joiner_env["FAKE_CMUX_ARGS_LOG"] = str(joiner_args_log)
        joiner_check = subprocess.run(
            [bun, "--eval", """
const mod = await import(process.env.CMUX_TEST_CAMPFIRE_EXTENSION_PATH);
const handlers = new Map();
mod.default({ on(name, handler) { handlers.set(name, handler); } });
const ctx = {
  cwd: "/tmp/campfire-project",
  sessionManager: { getSessionId() { return "joiner-session"; } }
};
await handlers.get("session_start")({}, ctx);
await handlers.get("agent_end")({ messages: [] }, ctx);
await new Promise((resolve) => setTimeout(resolve, 300));
"""],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
            env=joiner_env,
            timeout=20,
        )
        if joiner_check.returncode != 0:
            print("FAIL: campfire extension errored under the joiner role")
            print(f"stderr={joiner_check.stderr.strip()}")
            return 1
        if joiner_args_log.exists() and joiner_args_log.read_text(encoding="utf-8").strip():
            print(f"FAIL: joiner role produced hook invocations: {joiner_args_log.read_text(encoding='utf-8')!r}")
            return 1

        # When campfire's NATIVE bridge owns the process (it publishes a flag on
        # globalThis), this installed extension must go silent — otherwise every
        # hook fires twice on machines that ran the installer against an older
        # campfire and then upgraded.
        native_args_log = root / "fake-cmux-native-args.log"
        native_env = check_env.copy()
        native_env["FAKE_CMUX_ARGS_LOG"] = str(native_args_log)
        native_check = subprocess.run(
            [bun, "--eval", """
globalThis[Symbol.for("campfire.cmux.bridge.v1")] = true;
const mod = await import(process.env.CMUX_TEST_CAMPFIRE_EXTENSION_PATH);
const handlers = new Map();
mod.default({ on(name, handler) { handlers.set(name, handler); } });
const ctx = {
  cwd: "/tmp/campfire-project",
  sessionManager: { getSessionId() { return "native-owned-session"; } }
};
await handlers.get("session_start")({}, ctx);
await new Promise((resolve) => setTimeout(resolve, 300));
"""],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
            env=native_env,
            timeout=20,
        )
        if native_check.returncode != 0:
            print("FAIL: campfire extension errored under native-bridge deferral")
            print(f"stderr={native_check.stderr.strip()}")
            return 1
        if native_args_log.exists() and native_args_log.read_text(encoding="utf-8").strip():
            print(f"FAIL: installed extension did not defer to the native bridge: {native_args_log.read_text(encoding='utf-8')!r}")
            return 1

        if not verify_hook_persistence(cli_path, root, env):
            return 1

        uninstall = subprocess.run(
            [cli_path, "hooks", "campfire", "uninstall", "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=20,
        )
        if uninstall.returncode != 0 or extension_path.exists():
            print("FAIL: campfire extension uninstall failed")
            print(f"exit={uninstall.returncode}")
            print(f"stdout={uninstall.stdout.strip()}")
            print(f"stderr={uninstall.stderr.strip()}")
            return 1
        foreign_path = extension_path
        foreign_path.parent.mkdir(parents=True, exist_ok=True)
        foreign_path.write_text("// user extension\n", encoding="utf-8")
        uninstall_foreign = subprocess.run(
            [cli_path, "hooks", "campfire", "uninstall", "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=20,
        )
        if uninstall_foreign.returncode != 0 or not foreign_path.exists() or "Refusing to remove" not in uninstall_foreign.stdout:
            print("FAIL: campfire extension uninstall did not preserve non-cmux file")
            print(f"exit={uninstall_foreign.returncode}")
            print(f"stdout={uninstall_foreign.stdout.strip()}")
            print(f"stderr={uninstall_foreign.stderr.strip()}")
            return 1
        foreign_path.unlink()

        # CAMPFIRE_CODING_AGENT_DIR overrides the agent dir for install/uninstall.
        agent_override = root / "campfire-agent-override"
        override_env = env.copy()
        override_env["CAMPFIRE_CODING_AGENT_DIR"] = str(agent_override)
        override_install = subprocess.run(
            [cli_path, "hooks", "campfire", "install", "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=override_env,
            timeout=20,
        )
        override_extension_path = agent_override / "extensions" / "cmux-campfire-session.ts"
        if override_install.returncode != 0 or not override_extension_path.exists():
            print("FAIL: campfire extension install did not respect CAMPFIRE_CODING_AGENT_DIR")
            print(f"exit={override_install.returncode}")
            print(f"stdout={override_install.stdout.strip()}")
            print(f"stderr={override_install.stderr.strip()}")
            return 1
        override_uninstall = subprocess.run(
            [cli_path, "hooks", "campfire", "uninstall", "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=override_env,
            timeout=20,
        )
        if override_uninstall.returncode != 0 or override_extension_path.exists():
            print("FAIL: campfire extension uninstall did not respect CAMPFIRE_CODING_AGENT_DIR")
            print(f"exit={override_uninstall.returncode}")
            print(f"stdout={override_uninstall.stdout.strip()}")
            print(f"stderr={override_uninstall.stderr.strip()}")
            return 1
    print("PASS: generated Campfire extension installs, gates on the host role, emits complete cmux hook payloads, and persists hook sessions")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
