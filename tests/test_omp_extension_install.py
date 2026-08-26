#!/usr/bin/env python3
"""
Regression test: the generated OMP extension is importable and emits cmux hook calls with complete payloads.
"""

from __future__ import annotations

import base64
import json
import os
import signal
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


def wait_for_stable_text(
    path: Path,
    expected_count: int,
    timeout: float = 5.0,
    stable_for: float = 0.5,
) -> str:
    deadline = time.monotonic() + timeout
    last_text = ""
    stable_since: float | None = None
    while time.monotonic() < deadline:
        text = path.read_text(encoding="utf-8") if path.exists() else ""
        count = len([line for line in text.splitlines() if line.strip()])
        if count >= expected_count:
            if text != last_text:
                last_text = text
                stable_since = time.monotonic()
            elif stable_since is not None and time.monotonic() - stable_since >= stable_for:
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
        elif method == "agent.resolve_delivery_target":
            params = payload.get("params")
            pid_resolution = params.get("pid_resolution") if isinstance(params, dict) else None
            result = {
                "workspace_id": self.workspace_id,
                "surface_id": self.surface_id,
                "source": "pid",
                "pid_resolution": pid_resolution,
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
    hook_env.pop("CMUX_SOCKET_CAPABILITY", None)
    hook_env.pop("CMUX_SOCKET_PASSWORD", None)
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
        print(f"socket messages: {messages!r}")
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
    expected_environment = {"PI_CONFIG_DIR": ".custom-omp"}
    captured_path = hook_env.get("PATH", "").strip()
    if captured_path:
        expected_environment["PATH"] = captured_path
    if launch_command.get("environment") != expected_environment:
        print(f"FAIL: omp hook persisted wrong replay-safe environment: {launch_command!r}")
        print(f"expected environment: {expected_environment!r}")
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
        extension_override = os.environ.get("CMUX_TEST_OMP_EXTENSION_OVERRIDE")
        if extension_override:
            shutil.copyfile(extension_override, extension_path)

        fake_cmux = root / "fake-cmux"
        fake_args_log = root / "fake-cmux-args.log"
        fake_stdin_log = root / "fake-cmux-stdin.log"
        fake_env_log = root / "fake-cmux-env.log"
        fake_concurrency_log = root / "fake-cmux-concurrency.log"
        fake_pid_log = root / "fake-cmux-pids.log"
        fake_started_args_log = root / "fake-cmux-started-args.log"
        fake_args_log.touch()
        fake_pid_log.touch()
        fake_started_args_log.touch()
        fake_lock_dir = root / "fake-cmux.lock"
        make_executable(
            fake_cmux,
            """#!/usr/bin/env bash
set -euo pipefail
# Fire-and-forget sidebar/feed calls must not participate in the hook
# serialization test (SIGSTOP + lock), otherwise they hang the test forever.
if [[ "$1" == "hooks" && "$2" == "feed" ]] || [[ "$1" == "set-status" ]] || [[ "$1" == "clear-status" ]]; then
  printf '%s\n' "$*" >> "$FAKE_CMUX_STARTED_ARGS_LOG"
  printf '%s\n' "$*" >> "$FAKE_CMUX_ARGS_LOG"
  cat >> "$FAKE_CMUX_STDIN_LOG"
  printf '\n---\n' >> "$FAKE_CMUX_STDIN_LOG"
  exit 0
fi
if ! mkdir "$FAKE_CMUX_LOCK_DIR" 2>/dev/null; then
  active_pid="$(cat "$FAKE_CMUX_LOCK_DIR/pid" 2>/dev/null || true)"
  if [ -n "$active_pid" ] && kill -0 "$active_pid" 2>/dev/null; then
    printf 'overlap\n' >> "$FAKE_CMUX_CONCURRENCY_LOG"
  fi
fi
printf '%s\n' "$$" > "$FAKE_CMUX_LOCK_DIR/pid"
printf '%s\n' "$$" >> "$FAKE_CMUX_PID_LOG"
printf '%s\n' "$*" >> "$FAKE_CMUX_STARTED_ARGS_LOG"
kill -STOP "$$"
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
rm -f "$FAKE_CMUX_LOCK_DIR/pid"
rmdir "$FAKE_CMUX_LOCK_DIR" 2>/dev/null || true
""",
        )

        sessions_dir = root / "omp-sessions"
        sessions_dir.mkdir()
        parent_session_file = sessions_dir / "2026-07-28T12-00-00_omp-session-test.jsonl"
        parent_session_file.write_text("{}\n", encoding="utf-8")
        parent_artifacts_dir = parent_session_file.with_suffix("")
        parent_artifacts_dir.mkdir()
        nested_session_file = parent_artifacts_dir / "StorageRaceReview.jsonl"
        nested_session_file.write_text("{}\n", encoding="utf-8")

        check_env = env.copy()
        for key in [
            "CMUX_AGENT_LAUNCH_KIND",
            "CMUX_AGENT_LAUNCH_EXECUTABLE",
            "CMUX_AGENT_LAUNCH_ARGV_B64",
            "CMUX_AGENT_LAUNCH_CWD",
        ]:
            check_env.pop(key, None)
        check_env["CMUX_TEST_OMP_EXTENSION_PATH"] = str(extension_path)
        check_env["CMUX_TEST_OMP_PARENT_SESSION_FILE"] = str(parent_session_file)
        check_env["CMUX_TEST_OMP_NESTED_SESSION_FILE"] = str(nested_session_file)
        check_env["CMUX_SURFACE_ID"] = "surface-omp-test"
        check_env["CMUX_OMP_CMUX_BIN"] = str(fake_cmux)
        check_env["FAKE_CMUX_ARGS_LOG"] = str(fake_args_log)
        check_env["FAKE_CMUX_STDIN_LOG"] = str(fake_stdin_log)
        check_env["FAKE_CMUX_ENV_LOG"] = str(fake_env_log)
        check_env["FAKE_CMUX_CONCURRENCY_LOG"] = str(fake_concurrency_log)
        check_env["FAKE_CMUX_PID_LOG"] = str(fake_pid_log)
        check_env["FAKE_CMUX_STARTED_ARGS_LOG"] = str(fake_started_args_log)
        check_env["FAKE_CMUX_LOCK_DIR"] = str(fake_lock_dir)
        check_env["AMP_API_KEY"] = "amp-secret"
        check_source = """
import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
const extensionPath = process.env.CMUX_TEST_OMP_EXTENSION_PATH;
// OMP loads a fresh copy of the extension module for every session in the
// process (unique ?mtime= cache-busting import URLs), so module scope is
// per-session. Give each simulated session its own module instance.
async function loadExtensionInstance(cacheBust) {
  const mod = await import(`${extensionPath}?mtime=${cacheBust}`);
  if (typeof mod.default !== "function") throw new Error("missing default export");
  const instanceHandlers = new Map();
  mod.default({
    on(name, handler) {
      instanceHandlers.set(name, handler);
    }
  });
  return instanceHandlers;
}
const handlers = await loadExtensionInstance("2001");
const nestedHandlers = await loadExtensionInstance("2002");
const workerHandlers = await loadExtensionInstance("2003");
for (const name of ["session_start", "before_agent_start", "agent_end", "session_shutdown", "tool_execution_start", "tool_execution_end"]) {
  if (typeof handlers.get(name) !== "function") throw new Error(`missing ${name}`);
}
process.argv.splice(
  0,
  process.argv.length,
  "/Users/example/.bun/bin/omp",
  "--model",
  "anthropic/claude-sonnet-4-5"
);
const parentCtx = {
  cwd: "/tmp/omp-project",
  sessionManager: {
    getSessionId() { return currentSessionId; },
    getSessionFile() { return process.env.CMUX_TEST_OMP_PARENT_SESSION_FILE; }
  }
};
const nestedCtx = {
  cwd: "/tmp/omp-project",
  sessionManager: {
    getSessionId() { return "omp-nested-task-session"; },
    getSessionFile() { return process.env.CMUX_TEST_OMP_NESTED_SESSION_FILE; }
  }
};
const workerCtx = {
  cwd: "/tmp/omp-project",
  sessionManager: {
    getSessionId() { return "omp-worker-task-session"; },
    getSessionFile() { return process.env.CMUX_TEST_OMP_PARENT_SESSION_FILE; }
  }
};
let currentSessionId = "omp-session-test";
async function switchSession(sessionId, reason) {
  currentSessionId = sessionId;
  await handlers.get("session_switch")({ reason, previousSessionFile: undefined }, parentCtx);
}
async function expectHandlerCompletion(promise, label) {
  let completed = false;
  promise.then(() => { completed = true; });
  await new Promise((resolve) => setImmediate(resolve));
  if (!completed) throw new Error(`${label} waited for hook child completion`);
}
function nonEmptyLines(path) {
  return fs.readFileSync(path, "utf8")
    .split("\\n")
    .filter((line) => line.trim().length > 0);
}
async function waitForLineCount(path, expected) {
  while (nonEmptyLines(path).length < expected) {
    await new Promise((resolve) => setImmediate(resolve));
  }
}
async function stoppedHookPID(expectedStartedCount) {
  await waitForLineCount(process.env.FAKE_CMUX_PID_LOG, expectedStartedCount);
  const pid = Number(nonEmptyLines(process.env.FAKE_CMUX_PID_LOG)[expectedStartedCount - 1]);
  if (!Number.isInteger(pid) || pid <= 0) throw new Error(`invalid hook pid: ${pid}`);
  while (true) {
    const state = spawnSync("/bin/ps", ["-o", "state=", "-p", String(pid)], { encoding: "utf8" });
    if (state.stdout.trim().startsWith("T")) break;
    await new Promise((resolve) => setImmediate(resolve));
  }
  return pid;
}
async function releaseHook(expectedStartedCount) {
  const pid = await stoppedHookPID(expectedStartedCount);
  process.kill(pid, "SIGCONT");
}
async function waitForCompletedHooks(expected) {
  await waitForLineCount(process.env.FAKE_CMUX_ARGS_LOG, expected);
}
const start = Date.now();
await expectHandlerCompletion(handlers.get("session_start")({}, parentCtx), "session_start");
for (let index = 0; index < 40; index += 1) {
  await handlers.get("before_agent_start")({ prompt: `hello omp ${index}` }, parentCtx);
}
// Fire tool execution handlers to verify feed telemetry + sidebar status.
for (let index = 0; index < 3; index += 1) {
  handlers.get("tool_execution_start")({ toolName: `read`, input: { path: `/tmp/file${index}` }, toolCallId: `tc-${index}` }, parentCtx);
  handlers.get("tool_execution_end")({ toolName: `read`, is_error: false, toolCallId: `tc-${index}` }, parentCtx);
}
await handlers.get("agent_end")({
  messages: [
    { role: "user", content: "hello omp" },
    { role: "assistant", content: [{ type: "text", text: "done" }] }
  ],
  stopReason: "completed"
}, parentCtx);
await nestedHandlers.get("session_start")({}, nestedCtx);
await nestedHandlers.get("before_agent_start")({ prompt: "review the storage race" }, nestedCtx);
await nestedHandlers.get("agent_end")({
  messages: [
    { role: "user", content: "review the storage race" },
    { role: "assistant", content: [{ type: "text", text: "nested done" }] }
  ],
  stopReason: "completed"
}, nestedCtx);
const elapsed = Date.now() - start;
if (elapsed > 2000) throw new Error(`handlers blocked for ${elapsed}ms`);
await releaseHook(1);
await waitForCompletedHooks(1);
await releaseHook(2);
await waitForCompletedHooks(2);
await releaseHook(3);
await waitForCompletedHooks(3);
await handlers.get("session_shutdown")({}, parentCtx);
const firstPhasePids = nonEmptyLines(process.env.FAKE_CMUX_PID_LOG);
if (firstPhasePids.length !== 3) {
  throw new Error(`nested OMP task session spawned a hook child: ${firstPhasePids}`);
}
// Top-level session transitions go through session_switch; the queued Stop
// must survive session-start/prompt pressure that overflows the hook queue.
await switchSession("priority-stop-session", "new");
const switchHookPid = await stoppedHookPID(4);
await handlers.get("agent_end")({ messages: [], stopReason: "completed" }, parentCtx);
for (let index = 0; index < 10; index += 1) {
  await switchSession(`priority-prompt-${index}`, "new");
  await handlers.get("before_agent_start")({ prompt: `priority prompt ${index}` }, parentCtx);
}
// A finished task-tool subagent's session teardown (arriving through its own
// module instance) must not drain or evict the owner session's queued hooks.
await workerHandlers.get("session_shutdown")({}, workerCtx);
process.kill(switchHookPid, "SIGCONT");
await waitForCompletedHooks(4);
// active switch hook + 16-entry queue: the stop, 10 session-starts, and the
// 5 prompts that survive eviction (2 evicted by session-starts, 3 dropped at
// the full queue).
for (let hook = 5; hook <= 20; hook += 1) {
  await releaseHook(hook);
  await waitForCompletedHooks(hook);
}
await switchSession("omp-session-test", "resume");
for (let index = 0; index < 40; index += 1) {
  await handlers.get("before_agent_start")({ prompt: `hung omp ${index}` }, parentCtx);
}
await handlers.get("agent_end")({ messages: [], stopReason: "completed" }, parentCtx);
await handlers.get("session_shutdown")({}, parentCtx);
const hungPidLines = nonEmptyLines(process.env.FAKE_CMUX_PID_LOG);
const startedArgs = nonEmptyLines(process.env.FAKE_CMUX_STARTED_ARGS_LOG);
const ompStartedArgs = startedArgs.filter((line) => line.startsWith("hooks omp "));
if (hungPidLines.length !== 22) {
  throw new Error(`shutdown did not start the queued Stop after cancelling the active hook: ${hungPidLines}`);
}
if (
  ompStartedArgs.at(-2) !== "hooks omp session-start" ||
  ompStartedArgs.at(-1) !== "hooks omp stop"
) {
  throw new Error(`shutdown did not preserve the queued Stop after timeout: ${ompStartedArgs}`);
}
for (const rawPid of hungPidLines.slice(-2)) {
  const hungPid = Number(rawPid);
  if (!Number.isInteger(hungPid) || hungPid <= 0) throw new Error(`missing hung hook pid: ${hungPidLines}`);
  try {
    process.kill(hungPid, 0);
    throw new Error(`shutdown completed before hook child ${hungPid} closed`);
  } catch (error) {
    if (!error || error.code !== "ESRCH") throw error;
  }
}
"""
        try:
            # The choreography starts ~22 hook children sequentially (SIGSTOP,
            # release, await completion each), so give it generous headroom on
            # loaded machines and CI runners.
            check = subprocess.run(
                [bun, "--eval", check_source],
                cwd=root,
                capture_output=True,
                text=True,
                check=False,
                env=check_env,
                timeout=120,
            )
        except subprocess.TimeoutExpired:
            pid_lines = [
                line
                for line in fake_pid_log.read_text(encoding="utf-8").splitlines()
                if line.strip()
            ]
            args_lines = [
                line
                for line in fake_args_log.read_text(encoding="utf-8").splitlines()
                if line.strip()
            ]
            started_args_lines = [
                line
                for line in fake_started_args_log.read_text(encoding="utf-8").splitlines()
                if line.strip()
            ]
            for raw_pid in pid_lines:
                try:
                    os.kill(int(raw_pid), signal.SIGKILL)
                except (ProcessLookupError, ValueError):
                    pass
            print(
                "FAIL: generated OMP extension timed out; "
                f"pids={pid_lines!r} started_args={started_args_lines!r} args={args_lines!r}"
            )
            return 1
        if check.returncode != 0:
            print("FAIL: generated OMP extension is not importable or blocks handlers")
            print(f"exit={check.returncode}")
            print(f"stdout={check.stdout.strip()}")
            print(f"stderr={check.stderr.strip()}")
            return 1
        expected_invocations = 20
        # Wait for all entries (lifecycle SIGSTOP + feed/status fast-path) to settle.
        args_log = wait_for_stable_text(fake_args_log, expected_invocations, timeout=20.0)
        stdin_log = wait_for_stable_text(fake_stdin_log, expected_invocations * 2, timeout=20.0)
        env_log = wait_for_stable_text(fake_env_log, expected_invocations * 4, timeout=20.0)
        args_lines = [line for line in args_log.splitlines() if line.strip()]
        # Lifecycle hooks go through the SIGSTOP path; feed/status calls go through
        # the fast path. Count only lifecycle hooks for the exact count check.
        omp_hook_lines = [line for line in args_lines if line.startswith("hooks omp ")]
        feed_status_lines = [line for line in args_lines if not line.startswith("hooks omp ")]
        if len(omp_hook_lines) != expected_invocations:
            print(f"FAIL: expected exactly {expected_invocations} hooks omp invocations, got {omp_hook_lines!r}")
            return 1
        if len(feed_status_lines) == 0:
            print(f"FAIL: expected feed/status invocations from tool_execution handlers, got {feed_status_lines!r}")
            return 1
        # Verify tool execution telemetry appears in the feed/status args.
        if "hooks feed --source omp --event PreToolUse" not in args_log:
            print(f"FAIL: extension did not emit PreToolUse feed telemetry, got {args_log!r}")
            return 1
        if "hooks feed --source omp --event PostToolUse" not in args_log:
            print(f"FAIL: extension did not emit PostToolUse feed telemetry, got {args_log!r}")
            return 1
        if "set-status omp_agent Read --icon hammer" not in args_log:
            print(f"FAIL: extension did not set sidebar status during tool execution, got {args_log!r}")
            return 1
        if "clear-status omp_agent" not in args_log:
            print(f"FAIL: extension did not clear sidebar status on agent_end, got {args_log!r}")
            return 1
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
        # Lifecycle hooks (session-start, prompt-submit, stop) carry the session id.
        # Feed telemetry from tool_execution also includes it, so check >= 3.
        if stdin_log.count('"session_id":"omp-session-test"') < 3:
            print(f"FAIL: expected at least 3 completed hook payloads carrying the session id, got {stdin_log!r}")
            return 1
        if '"session_id":"omp-nested-task-session"' in stdin_log:
            print(f"FAIL: extension emitted a nested OMP task session id, got {stdin_log!r}")
            return 1
        if '"hook_event_name":"Stop"' not in stdin_log:
            print(f"FAIL: stop hook payload was missing: {stdin_log!r}")
            return 1
        if '"session_id":"priority-stop-session","cwd":"/tmp/omp-project","hook_event_name":"Stop"' not in stdin_log:
            print(f"FAIL: queued stop hook was evicted under session-start/prompt pressure: {stdin_log!r}")
            return 1
        if '"session_id":"omp-worker-task-session"' in stdin_log:
            print(f"FAIL: a non-owner session id reached cmux hooks: {stdin_log!r}")
            return 1
        if '"session_id":"priority-prompt-9","cwd":"/tmp/omp-project","hook_event_name":"SessionStart"' not in stdin_log:
            print(f"FAIL: session_switch did not rebind the switched session: {stdin_log!r}")
            return 1
        if '"prompt":"priority prompt 2"' not in stdin_log:
            print(f"FAIL: surviving queued prompt was not delivered: {stdin_log!r}")
            return 1
        if '"prompt":"priority prompt 0"' in stdin_log or '"prompt":"priority prompt 7"' in stdin_log:
            print(f"FAIL: evicted/dropped prompt hooks were still delivered: {stdin_log!r}")
            return 1
        if '"prompt":"hello omp 39"' not in stdin_log or '"last_assistant_message":"done"' not in stdin_log:
            print(f"FAIL: extension did not pass prompt/assistant payload, got {stdin_log!r}")
            return 1
        if "kind=omp" not in env_log or "cwd=/tmp/omp-project" not in env_log or "argv=" not in env_log:
            print(f"FAIL: extension did not pass launch metadata environment, got {env_log!r}")
            return 1
        if "amp=present" not in env_log:
            print(f"FAIL: extension stripped unrelated AMP_API_KEY from hook environment, got {env_log!r}")
            return 1
        if fake_concurrency_log.exists():
            print(f"FAIL: extension ran hook children concurrently: {fake_concurrency_log.read_text()!r}")
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
