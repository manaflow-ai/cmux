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
    if not isinstance(command, str) or "--resume" not in command or session_id not in command:
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
case "$*" in
  "hooks feed "*)
    printf '%s\n' "$*" >> "$FAKE_CMUX_STARTED_ARGS_LOG"
    cat >/dev/null
    printf '{}\n'
    exit 0
    ;;
  "hooks omp session-end")
    cat >/dev/null
    printf '{}\n'
    exit 0
    ;;
esac
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
const mod = await import(extensionPath);
if (typeof mod.default !== "function") throw new Error("missing default export");
const handlers = new Map();
mod.default({
  on(name, handler) {
    handlers.set(name, handler);
  }
});
for (const name of ["session_start", "before_agent_start", "agent_end", "session_shutdown", "tool_execution_start"]) {
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
let currentSessionId = "omp-session-test";
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
await handlers.get("agent_end")({
  messages: [
    { role: "user", content: "hello omp" },
    { role: "assistant", content: [{ type: "text", text: "done" }] }
  ],
  stopReason: "completed"
}, parentCtx);
await handlers.get("session_start")({}, nestedCtx);
await handlers.get("before_agent_start")({ prompt: "review the storage race" }, nestedCtx);
await handlers.get("agent_end")({
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
currentSessionId = "priority-feed-pressure";
await handlers.get("session_start")({}, parentCtx);
for (let index = 0; index < 40; index += 1) {
  await handlers.get("tool_execution_start")({
    type: "tool_execution_start",
    toolCallId: `priority-feed-${index}`,
    toolName: "bash",
    args: { command: `printf feed-${index}` },
  }, parentCtx);
}
await handlers.get("before_agent_start")({ prompt: "priority prompt survives feed pressure" }, parentCtx);
const priorityStartOffset = nonEmptyLines(process.env.FAKE_CMUX_STARTED_ARGS_LOG).length;
await releaseHook(4);
await waitForCompletedHooks(4);
const priorityPromptPid = await stoppedHookPID(5);
const priorityStarts = nonEmptyLines(process.env.FAKE_CMUX_STARTED_ARGS_LOG)
  .slice(priorityStartOffset);
if (priorityStarts[0] !== "hooks omp prompt-submit") {
  throw new Error(`Queued prompt did not run before the Feed backlog: ${priorityStarts}`);
}
process.kill(priorityPromptPid, "SIGCONT");
await waitForCompletedHooks(5);
await handlers.get("session_shutdown")({}, parentCtx);
currentSessionId = "omp-session-test";
await handlers.get("session_start")({}, parentCtx);
for (let index = 0; index < 40; index += 1) {
  await handlers.get("before_agent_start")({ prompt: `hung omp ${index}` }, parentCtx);
}
await handlers.get("agent_end")({ messages: [], stopReason: "completed" }, parentCtx);
await handlers.get("session_shutdown")({}, parentCtx);
const hungPidLines = nonEmptyLines(process.env.FAKE_CMUX_PID_LOG);
const startedArgs = nonEmptyLines(process.env.FAKE_CMUX_STARTED_ARGS_LOG);
if (hungPidLines.length !== 7) {
  throw new Error(`shutdown did not start the queued Stop after cancelling the active hook: ${hungPidLines}`);
}
if (
  startedArgs.at(-2) !== "hooks omp session-start" ||
  startedArgs.at(-1) !== "hooks omp stop"
) {
  throw new Error(`shutdown did not preserve the queued Stop after timeout: ${startedArgs}`);
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
            check = subprocess.run(
                [bun, "--eval", check_source],
                cwd=root,
                capture_output=True,
                text=True,
                check=False,
                env=check_env,
                timeout=20,
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

        # Exercise OMP's full ExtensionAPI event surface in a fresh Bun process.
        # The fake cmux executable records the actual child-process protocol and
        # uses a FIFO to hold one terminal Feed event, making Stop ordering
        # observable without sleeping.
        behavior_cmux = root / "behavior-cmux"
        behavior_log = root / "behavior-cmux.jsonl"
        terminal_feed_gate = root / "terminal-feed-gate"
        terminal_feed_ack = root / "terminal-feed-ack"
        os.mkfifo(terminal_feed_gate)
        make_executable(
            behavior_cmux,
            """#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

argv = sys.argv[1:]
stdin = sys.stdin.read()
try:
    payload = json.loads(stdin) if stdin else {}
except json.JSONDecodeError:
    payload = {}

log_path = os.environ["CMUX_TEST_OMP_BEHAVIOR_LOG"]
gate_path = os.environ["CMUX_TEST_OMP_TERMINAL_FEED_GATE"]
ack_path = os.environ["CMUX_TEST_OMP_TERMINAL_FEED_ACK"]

def record(phase):
    item = {
        "phase": phase,
        "pid": os.getpid(),
        "argv": argv,
        "payload": payload,
    }
    if argv[:3] == ["hooks", "omp", "stop"]:
        item["terminalFeedAcknowledged"] = Path(ack_path).exists()
    encoded = (json.dumps(item, separators=(",", ":")) + "\\n").encode("utf-8")
    fd = os.open(log_path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        os.write(fd, encoded)
    finally:
        os.close(fd)

record("started")
is_gated_terminal_feed = (
    argv[:6] == ["hooks", "feed", "--source", "omp", "--event", "PostToolUse"]
    and payload.get("tool_call_id") == "terminal-feed-call"
)
if is_gated_terminal_feed:
    fd = os.open(gate_path, os.O_RDONLY)
    try:
        os.read(fd, 1)
    finally:
        os.close(fd)
    Path(ack_path).write_text("ack", encoding="utf-8")
record("completed")
print("{}")
""",
        )
        switch_session_file = sessions_dir / "2026-07-28T12-05-00_omp-switched.jsonl"
        switch_session_file.write_text("{}\n", encoding="utf-8")
        branch_session_file = sessions_dir / "2026-07-28T12-10-00_omp-branched.jsonl"
        branch_session_file.write_text("{}\n", encoding="utf-8")
        behavior_env = check_env.copy()
        behavior_env["CMUX_OMP_CMUX_BIN"] = str(behavior_cmux)
        behavior_env["CMUX_TEST_OMP_BEHAVIOR_LOG"] = str(behavior_log)
        behavior_env["CMUX_TEST_OMP_TERMINAL_FEED_GATE"] = str(terminal_feed_gate)
        behavior_env["CMUX_TEST_OMP_TERMINAL_FEED_ACK"] = str(terminal_feed_ack)
        behavior_env["CMUX_TEST_OMP_SWITCH_SESSION_FILE"] = str(switch_session_file)
        behavior_env["CMUX_TEST_OMP_BRANCH_SESSION_FILE"] = str(branch_session_file)
        behavior_source = """
import * as fs from "node:fs";
const extensionPath = process.env.CMUX_TEST_OMP_EXTENSION_PATH;
const mod = await import(extensionPath);
if (typeof mod.default !== "function") throw new Error("missing default export");
const handlers = new Map();
mod.default({
  on(name, handler) {
    handlers.set(name, handler);
  }
});
for (const name of [
  "session_start",
  "session_switch",
  "session_branch",
  "session_before_compact",
  "session_compact",
  "before_agent_start",
  "agent_end",
  "session_shutdown",
  "tool_execution_start",
  "tool_execution_end",
  "tool_approval_requested",
  "tool_approval_resolved",
]) {
  if (typeof handlers.get(name) !== "function") throw new Error(`missing ${name}`);
}

let currentSessionId = "omp-runtime-initial";
let currentSessionFile = process.env.CMUX_TEST_OMP_PARENT_SESSION_FILE;
let currentCwd = "/tmp/omp-runtime-project";
const ctx = {
  get cwd() { return currentCwd; },
  sessionManager: {
    getSessionId() { return currentSessionId; },
    getSessionFile() { return currentSessionFile; },
    getSessionDir() { return currentSessionFile ? currentSessionFile.replace(/\\/[^/]+$/, "") : undefined; },
  },
};

function records() {
  const path = process.env.CMUX_TEST_OMP_BEHAVIOR_LOG;
  if (!path || !fs.existsSync(path)) return [];
  const contents = fs.readFileSync(path, "utf8");
  const lines = contents.split("\\n");
  if (!contents.endsWith("\\n")) lines.pop();
  return lines
    .filter((line) => line.trim().length > 0)
    .map((line) => JSON.parse(line));
}

const behaviorLogPath = process.env.CMUX_TEST_OMP_BEHAVIOR_LOG;
fs.appendFileSync(behaviorLogPath, '{"phase":"partial');
if (records().length !== 0) throw new Error("partial JSONL record was parsed before completion");
fs.appendFileSync(behaviorLogPath, '"}\\n');
if (records()[0]?.phase !== "partial") throw new Error("completed JSONL record was not parsed");

function hasArgvPrefix(record, expected) {
  return expected.every((value, index) => record.argv[index] === value);
}

async function waitForRecord(predicate, label, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const record = records().find(predicate);
    if (record) return record;
    await new Promise((resolve) => setImmediate(resolve));
  }
  throw new Error(`timed out waiting for ${label}; records=${JSON.stringify(records())}`);
}


async function completedCommand(argvPrefix, payloadPredicate, label) {
  return waitForRecord(
    (record) => record.phase === "completed"
      && hasArgvPrefix(record, argvPrefix)
      && payloadPredicate(record.payload),
    label,
  );
}

async function invoke(name, event) {
  const result = await handlers.get(name)(event, ctx);
  if (result !== undefined) {
    throw new Error(`${name} returned an agent decision: ${JSON.stringify(result)}`);
  }
}

function assertTranscript(record, expected) {
  if (record.payload.transcript_path !== expected) {
    throw new Error(`wrong transcript_path: expected ${expected}, got ${JSON.stringify(record.payload)}`);
  }
}

function assertBoundedStructuredPayload(record, key, label) {
  const value = record.payload[key];
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} was not a structured object: ${JSON.stringify(record.payload)}`);
  }
  const byteLength = Buffer.byteLength(JSON.stringify(record.payload), "utf8");
  if (byteLength > 12 * 1024) {
    throw new Error(`${label} payload was not bounded: ${byteLength} bytes`);
  }
}

await invoke("session_start", { type: "session_start" });
const initialStart = await completedCommand(
  ["hooks", "omp", "session-start"],
  (payload) => payload.session_id === "omp-runtime-initial",
  "initial lifecycle binding",
);
assertTranscript(initialStart, process.env.CMUX_TEST_OMP_PARENT_SESSION_FILE);

currentSessionId = "omp-runtime-switched";
currentSessionFile = process.env.CMUX_TEST_OMP_SWITCH_SESSION_FILE;
currentCwd = "/tmp/omp-runtime-switched";
await invoke("session_switch", {
  type: "session_switch",
  sessionId: "stale-event-session-id",
  transcript_path: "/tmp/stale-event-transcript.jsonl",
});
const switchedStart = await completedCommand(
  ["hooks", "omp", "session-start"],
  (payload) => payload.session_id === "omp-runtime-switched",
  "switched lifecycle binding",
);
assertTranscript(switchedStart, process.env.CMUX_TEST_OMP_SWITCH_SESSION_FILE);
if (switchedStart.payload.cwd !== currentCwd) {
  throw new Error(`session_switch did not re-read authoritative context: ${JSON.stringify(switchedStart.payload)}`);
}

currentSessionId = "omp-runtime-branched";
currentSessionFile = process.env.CMUX_TEST_OMP_BRANCH_SESSION_FILE;
currentCwd = "/tmp/omp-runtime-branched";
await invoke("session_branch", {
  type: "session_branch",
  sessionId: "stale-branch-event-session-id",
  transcript_path: "/tmp/stale-branch-transcript.jsonl",
});
const branchedStart = await completedCommand(
  ["hooks", "omp", "session-start"],
  (payload) => payload.session_id === "omp-runtime-branched",
  "branched lifecycle binding",
);
assertTranscript(branchedStart, process.env.CMUX_TEST_OMP_BRANCH_SESSION_FILE);
if (branchedStart.payload.cwd !== currentCwd) {
  throw new Error(`session_branch did not re-read authoritative context: ${JSON.stringify(branchedStart.payload)}`);
}

const privateBranchEntry = "private-branch-entry-" + "x".repeat(20000);
await invoke("session_before_compact", {
  type: "session_before_compact",
  preparation: { tokensBefore: 120000 },
  branchEntries: [
    { type: "message", role: "user", content: privateBranchEntry },
  ],
});
const preCompact = await completedCommand(
  ["hooks", "feed", "--source", "omp", "--event", "PreCompact"],
  (payload) => payload.session_id === currentSessionId,
  "PreCompact Feed telemetry",
);
const preCompactJSON = JSON.stringify(preCompact.payload);
if (
  preCompactJSON.includes("branchEntries")
  || preCompactJSON.includes("branch_entries")
  || preCompactJSON.includes("private-branch-entry-")
) {
  throw new Error(`PreCompact forwarded raw branch entries: ${preCompactJSON}`);
}
assertTranscript(preCompact, currentSessionFile);

await invoke("session_compact", {
  type: "session_compact",
  fromExtension: false,
  compactionEntry: {
    summary: "bounded summary",
    branchEntries: [{ content: privateBranchEntry }],
  },
});
const postCompact = await completedCommand(
  ["hooks", "feed", "--source", "omp", "--event", "PostCompact"],
  (payload) => payload.session_id === currentSessionId,
  "PostCompact Feed telemetry",
);
const postCompactJSON = JSON.stringify(postCompact.payload);
if (
  postCompactJSON.includes("branchEntries")
  || postCompactJSON.includes("branch_entries")
  || postCompactJSON.includes("private-branch-entry-")
) {
  throw new Error(`PostCompact forwarded raw branch entries: ${postCompactJSON}`);
}

const privateToolInput = "private-pre-tool-input-" + "i".repeat(20000);
await invoke("tool_execution_start", {
  type: "tool_execution_start",
  toolCallId: "ordinary-tool-call",
  toolName: "bash",
  args: {
    command: "printf bounded",
    nested: { private: privateToolInput },
  },
});
const preTool = await completedCommand(
  ["hooks", "feed", "--source", "omp", "--event", "PreToolUse"],
  (payload) => payload.tool_call_id === "ordinary-tool-call",
  "ordinary PreToolUse Feed telemetry",
);
assertBoundedStructuredPayload(preTool, "tool_input", "PreToolUse tool_input");
if (JSON.stringify(preTool.payload).includes(privateToolInput)) {
  throw new Error(`PreToolUse forwarded an unbounded raw tool input: ${JSON.stringify(preTool.payload)}`);
}
assertTranscript(preTool, currentSessionFile);

const privateToolResult = "private-post-tool-output-" + "o".repeat(20000);
await invoke("tool_execution_end", {
  type: "tool_execution_end",
  toolCallId: "ordinary-tool-call",
  toolName: "bash",
  result: {
    content: [{ type: "text", text: privateToolResult }],
    metadata: { exitCode: 7 },
  },
  isError: true,
});
const postTool = await completedCommand(
  ["hooks", "feed", "--source", "omp", "--event", "PostToolUse"],
  (payload) => payload.tool_call_id === "ordinary-tool-call",
  "ordinary PostToolUse Feed telemetry",
);
assertBoundedStructuredPayload(postTool, "tool_result", "PostToolUse tool_result");
if (postTool.payload.is_error !== true) {
  throw new Error(`PostToolUse lost the error state: ${JSON.stringify(postTool.payload)}`);
}
if (JSON.stringify(postTool.payload).includes(privateToolResult)) {
  throw new Error(`PostToolUse forwarded unbounded raw output: ${JSON.stringify(postTool.payload)}`);
}

await invoke("tool_execution_start", {
  type: "tool_execution_start",
  toolCallId: "task-call",
  toolName: "task",
  args: { task: "review the storage race" },
});
await completedCommand(
  ["hooks", "feed", "--source", "omp", "--event", "SubagentStart"],
  (payload) => payload.tool_call_id === "task-call" && payload.tool_name === "task",
  "lowercase task SubagentStart",
);
await invoke("tool_execution_end", {
  type: "tool_execution_end",
  toolCallId: "task-call",
  toolName: "task",
  result: { content: [{ type: "text", text: "review complete" }] },
  isError: false,
});
const taskStop = await completedCommand(
  ["hooks", "feed", "--source", "omp", "--event", "SubagentStop"],
  (payload) => payload.tool_call_id === "task-call" && payload.tool_name === "task",
  "lowercase task SubagentStop",
);
if (taskStop.payload.is_error !== false) {
  throw new Error(`SubagentStop lost the success state: ${JSON.stringify(taskStop.payload)}`);
}

await invoke("tool_approval_requested", {
  type: "tool_approval_requested",
  sessionId: currentSessionId,
  toolCallId: "approval-call",
  toolName: "bash",
  reason: "write a generated fixture",
  approvalMode: "once",
});
const approvalRequested = await completedCommand(
  ["hooks", "omp", "notification"],
  (payload) => payload.tool_call_id === "approval-call",
  "observational approval request",
);
if (
  approvalRequested.payload.event !== "permission_request"
  || approvalRequested.payload.notification_type !== "permission_request"
) {
  throw new Error(`approval request had the wrong lifecycle payload: ${JSON.stringify(approvalRequested.payload)}`);
}
if (approvalRequested.payload.message !== "write a generated fixture") {
  throw new Error(`approval request lost its reason message: ${JSON.stringify(approvalRequested.payload)}`);
}

await invoke("tool_approval_resolved", {
  type: "tool_approval_resolved",
  sessionId: currentSessionId,
  toolCallId: "approval-call",
  toolName: "bash",
  approved: false,
  reason: "denied in OMP",
});
const approvalResolved = await completedCommand(
  ["hooks", "omp", "approval-response"],
  (payload) => payload.tool_call_id === "approval-call",
  "observational approval resolution",
);
if (approvalResolved.payload.approved !== false) {
  throw new Error(`approval resolution lost the decision state: ${JSON.stringify(approvalResolved.payload)}`);
}

const stopCommand = ["hooks", "omp", "stop"];
const stopCount = () => records().filter(
  (record) => record.phase === "started"
    && hasArgvPrefix(record, stopCommand)
    && record.payload.session_id === currentSessionId,
).length;
const stopCountBeforeContinuations = stopCount();
if (stopCountBeforeContinuations !== 0) {
  throw new Error(`OMP emitted Stop before a terminal agent_end: ${JSON.stringify(records())}`);
}
for (const assistantText of ["intermediate one", "intermediate two"]) {
  await invoke("agent_end", {
    type: "agent_end",
    messages: [{ role: "assistant", content: assistantText }],
    willContinue: true,
  });
}
await invoke("tool_approval_resolved", {
  type: "tool_approval_resolved",
  sessionId: currentSessionId,
  toolCallId: "continuation-barrier",
  toolName: "bash",
  approved: true,
});
await completedCommand(
  ["hooks", "omp", "approval-response"],
  (payload) => payload.tool_call_id === "continuation-barrier",
  "willContinue ordering barrier",
);
if (stopCount() !== stopCountBeforeContinuations) {
  throw new Error(`agent_end(willContinue: true) emitted Stop: ${JSON.stringify(records())}`);
}

await invoke("tool_execution_end", {
  type: "tool_execution_end",
  toolCallId: "terminal-feed-call",
  toolName: "bash",
  result: { content: [{ type: "text", text: "terminal result" }] },
  isError: false,
});
const terminalFeedStarted = await waitForRecord(
  (record) => record.phase === "started"
    && hasArgvPrefix(record, ["hooks", "feed", "--source", "omp", "--event", "PostToolUse"])
    && record.payload.tool_call_id === "terminal-feed-call",
  "gated terminal Feed event",
);
let finalAgentEndCompleted = false;
let finalAgentEndError;
const finalAgentEnd = handlers.get("agent_end")({
  type: "agent_end",
  messages: [{ role: "assistant", content: "final answer" }],
  willContinue: false,
}, ctx).then((result) => {
  if (result !== undefined) throw new Error(`agent_end returned a decision: ${JSON.stringify(result)}`);
  finalAgentEndCompleted = true;
}).catch((error) => {
  finalAgentEndError = error;
  finalAgentEndCompleted = true;
});

const gateFD = fs.openSync(process.env.CMUX_TEST_OMP_TERMINAL_FEED_GATE, "w");
fs.writeSync(gateFD, Buffer.from([1]));
fs.closeSync(gateFD);
const terminalFeedCompleted = await waitForRecord(
  (record) => record.phase === "completed"
    && record.pid === terminalFeedStarted.pid,
  "terminal Feed acknowledgment",
);
const finalStop = await completedCommand(
  stopCommand,
  (payload) => payload.session_id === currentSessionId,
  "final Stop after terminal Feed acknowledgment",
);
await waitForRecord(
  () => finalAgentEndCompleted,
  "final agent_end completion",
);
if (finalAgentEndError) throw finalAgentEndError;
const orderedRecords = records();
const terminalCompletionIndex = orderedRecords.findIndex(
  (record) => record.phase === "completed" && record.pid === terminalFeedCompleted.pid,
);
const stopStartIndex = orderedRecords.findIndex(
  (record) => record.phase === "started" && record.pid === finalStop.pid,
);
if (
  terminalCompletionIndex < 0
  || stopStartIndex <= terminalCompletionIndex
  || finalStop.terminalFeedAcknowledged !== true
) {
  throw new Error(`final Stop was not ordered after terminal Feed acknowledgment: ${JSON.stringify(orderedRecords)}`);
}
if (stopCount() !== stopCountBeforeContinuations + 1) {
  throw new Error(`expected exactly one final Stop: ${JSON.stringify(orderedRecords)}`);
}
assertTranscript(finalStop, currentSessionFile);

await invoke("before_agent_start", {
  type: "before_agent_start",
  prompt: "follow-up turn",
});
await invoke("agent_end", {
  type: "agent_end",
  messages: [{ role: "assistant", content: "follow-up answer" }],
  willContinue: false,
});
const followUpStop = await completedCommand(
  stopCommand,
  (payload) => payload.session_id === currentSessionId
    && payload.last_assistant_message === "follow-up answer",
  "follow-up turn Stop",
);
assertTranscript(followUpStop, currentSessionFile);
if (stopCount() !== stopCountBeforeContinuations + 2) {
  throw new Error(`follow-up turn did not re-arm Stop: ${JSON.stringify(records())}`);
}

await invoke("session_shutdown", { type: "session_shutdown" });
const sessionEnd = await completedCommand(
  ["hooks", "omp", "session-end"],
  (payload) => payload.session_id === currentSessionId,
  "SessionEnd on shutdown",
);
if (
  sessionEnd.payload.hook_event_name !== "SessionEnd"
  || "last_assistant_message" in sessionEnd.payload
) {
  throw new Error(`shutdown emitted fake completion instead of SessionEnd: ${JSON.stringify(sessionEnd.payload)}`);
}
if (stopCount() !== stopCountBeforeContinuations + 2) {
  throw new Error(`shutdown emitted a duplicate Stop: ${JSON.stringify(records())}`);
}
assertTranscript(sessionEnd, currentSessionFile);
"""
        try:
            behavior_check = subprocess.run(
                [bun, "--eval", behavior_source],
                cwd=root,
                capture_output=True,
                text=True,
                check=False,
                env=behavior_env,
                timeout=30,
            )
        except subprocess.TimeoutExpired:
            print("FAIL: generated OMP extension behavior harness timed out")
            if behavior_log.exists():
                print(behavior_log.read_text(encoding="utf-8"))
            return 1
        if behavior_check.returncode != 0:
            print("FAIL: generated OMP extension did not satisfy the OMP 17.1.8 event contract")
            print(f"exit={behavior_check.returncode}")
            print(f"stdout={behavior_check.stdout.strip()}")
            print(f"stderr={behavior_check.stderr.strip()}")
            if behavior_log.exists():
                print(f"behavior log={behavior_log.read_text(encoding='utf-8').strip()}")
            return 1

        expected_invocations = 5
        args_log = wait_for_stable_text(fake_args_log, expected_invocations, timeout=20.0)
        stdin_log = wait_for_stable_text(fake_stdin_log, expected_invocations * 2, timeout=20.0)
        env_log = wait_for_stable_text(fake_env_log, expected_invocations * 4, timeout=20.0)
        args_lines = [line for line in args_log.splitlines() if line.strip()]
        if len(args_lines) != expected_invocations:
            print(f"FAIL: expected exactly {expected_invocations} hook invocations, got {args_lines!r}")
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
        if stdin_log.count('"session_id":"omp-session-test"') != 3:
            print(f"FAIL: expected 3 completed hook payloads carrying the session id, got {stdin_log!r}")
            return 1
        if '"session_id":"omp-nested-task-session"' in stdin_log:
            print(f"FAIL: extension emitted a nested OMP task session id, got {stdin_log!r}")
            return 1
        if '"hook_event_name":"Stop"' not in stdin_log:
            print(f"FAIL: stop hook payload was missing: {stdin_log!r}")
            return 1
        if '"session_id":"priority-feed-pressure","cwd":"/tmp/omp-project","hook_event_name":"UserPromptSubmit"' not in stdin_log:
            print(f"FAIL: queued prompt was evicted under Feed pressure: {stdin_log!r}")
            return 1
        if '"prompt":"priority prompt survives feed pressure"' not in stdin_log:
            print(f"FAIL: surviving priority prompt lost its payload: {stdin_log!r}")
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
        config_extension_path = home / str(config_override).lstrip(os.sep) / "agent" / "extensions" / "cmux-omp-session.ts"
        if config_install.returncode != 0 or not config_extension_path.exists():
            print("FAIL: omp extension install did not match OMP PI_CONFIG_DIR path joining")
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
            print("FAIL: omp extension uninstall did not match OMP PI_CONFIG_DIR path joining")
            print(f"exit={config_uninstall.returncode}")
            print(f"stdout={config_uninstall.stdout.strip()}")
            print(f"stderr={config_uninstall.stderr.strip()}")
            return 1
    print("PASS: generated OMP extension installs, executes the OMP event contract, and persists hook sessions")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
