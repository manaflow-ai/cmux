#!/usr/bin/env python3
"""Regression coverage for the managed Prime Agent extension and resume path."""

from __future__ import annotations

import base64
import json
import os
import shutil
import socket
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def non_empty_lines(text: str) -> list[str]:
    return [line for line in text.splitlines() if line.strip()]


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
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(self.path))
        server.listen(8)
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
                conn, _ = self._server.accept()
            except TimeoutError:
                continue
            except OSError:
                return
            with conn:
                reader = conn.makefile("rb")
                for line_bytes in reader:
                    line = line_bytes.decode("utf-8", errors="replace").rstrip("\n")
                    if not line:
                        continue
                    with self._lock:
                        self._messages.append(line)
                    try:
                        request = json.loads(line)
                        request_id = request.get("id", "unknown")
                        method = request.get("method")
                    except json.JSONDecodeError:
                        request_id, method = "unknown", ""
                    if method == "surface.list":
                        result = {"surfaces": [{"id": self.surface_id, "focused": True}]}
                    else:
                        result = {"ok": True}
                    response = {"id": request_id, "ok": True, "result": result}
                    try:
                        conn.sendall(json.dumps(response, separators=(",", ":")).encode() + b"\n")
                    except BrokenPipeError:
                        return


def rpc_messages(messages: list[str], method: str) -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    for line in messages:
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue
        if payload.get("method") == method:
            result.append(payload)
    return result


def main() -> int:
    if shutil.which("bun") is None:
        print("SKIP: bun not found")
        return 0
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(prefix="cmux-prime-agent-extension-") as temp_dir:
        root = Path(temp_dir)
        home = root / "home"
        state_dir = root / "hook-state"
        workspace = root / "workspace"
        home.mkdir()
        state_dir.mkdir()
        workspace.mkdir()
        config_dir = home / ".prime" / "agent"
        env = os.environ.copy()
        env.update(
            {
                "HOME": str(home),
                "PRIME_AGENT_CODING_AGENT_DIR": str(config_dir),
                "CMUX_CLI_SENTRY_DISABLED": "1",
            }
        )
        install = subprocess.run(
            [cli_path, "hooks", "prime-agent", "install", "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=20,
        )
        if install.returncode != 0:
            print(f"FAIL: Prime Agent install failed: {install.stdout}\n{install.stderr}")
            return 1
        extension_path = config_dir / "extensions" / "cmux-prime-agent-session.ts"
        if not extension_path.exists():
            print(f"FAIL: expected generated extension at {extension_path}")
            return 1
        extension = extension_path.read_text(encoding="utf-8")
        required_fragments = (
            "@earendil-works/pi-coding-agent",
            "ctx.sessionManager.getSessionId()",
            "ctx.sessionManager.getSessionFile()",
            "ctx.hasUI",
            "isHeadlessInvocation",
            "RLM_DEPTH",
            "RLM_SESSION_DIR",
            "prime-agent --resume",
            "__cmuxPrimeAgentState",
        )
        if any(fragment not in extension for fragment in required_fragments):
            print("FAIL: generated extension is missing a required Prime Agent/root-session contract")
            return 1

        # Execute the generated extension itself. This models Prime's separate
        # extension module instances, verifies non-blocking lifecycle delivery,
        # and proves that headless/RLM sessions cannot claim the visible pane.
        fake_cmux = root / "fake-prime-cmux"
        fake_args_log = root / "fake-prime-cmux-args.log"
        fake_stdin_log = root / "fake-prime-cmux-stdin.log"
        fake_env_log = root / "fake-prime-cmux-env.log"
        for log in (fake_args_log, fake_stdin_log, fake_env_log):
            log.touch()
        make_executable(
            fake_cmux,
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$FAKE_PRIME_CMUX_ARGS_LOG"
cat >> "$FAKE_PRIME_CMUX_STDIN_LOG"
printf '\\n---\\n' >> "$FAKE_PRIME_CMUX_STDIN_LOG"
printf 'kind=%s\\n' "${CMUX_AGENT_LAUNCH_KIND-}" >> "$FAKE_PRIME_CMUX_ENV_LOG"
printf 'argv=%s\\n' "${CMUX_AGENT_LAUNCH_ARGV_B64-}" >> "$FAKE_PRIME_CMUX_ENV_LOG"
""",
        )
        lifecycle_env = env.copy()
        lifecycle_env.pop("CMUX_PRIME_AGENT_HOOKS_DISABLED", None)
        lifecycle_env.pop("RLM_DEPTH", None)
        lifecycle_env.pop("RLM_SESSION_DIR", None)
        for key in [
            "CMUX_AGENT_LAUNCH_KIND",
            "CMUX_AGENT_LAUNCH_EXECUTABLE",
            "CMUX_AGENT_LAUNCH_ARGV_B64",
            "CMUX_AGENT_LAUNCH_CWD",
        ]:
            lifecycle_env.pop(key, None)
        lifecycle_env.update(
            {
                "CMUX_TEST_PRIME_EXTENSION_PATH": str(extension_path),
                "CMUX_SURFACE_ID": "prime-lifecycle-surface",
                "CMUX_PRIME_AGENT_CMUX_BIN": str(fake_cmux),
                "FAKE_PRIME_CMUX_ARGS_LOG": str(fake_args_log),
                "FAKE_PRIME_CMUX_STDIN_LOG": str(fake_stdin_log),
                "FAKE_PRIME_CMUX_ENV_LOG": str(fake_env_log),
                # Deliberately stale, even though the inherited kind matches:
                # launchEnvironment must replace a same-kind capture when a
                # root Prime process starts.
                "CMUX_AGENT_LAUNCH_KIND": "prime-agent",
                "CMUX_AGENT_LAUNCH_ARGV_B64": "stale-capture",
            }
        )
        lifecycle_source = r"""
import * as fs from "node:fs";
const extensionPath = process.env.CMUX_TEST_PRIME_EXTENSION_PATH;
async function loadExtension(cacheBust) {
  const mod = await import(`${extensionPath}?mtime=${cacheBust}`);
  if (typeof mod.default !== "function") throw new Error("missing default export");
  const handlers = new Map();
  mod.default({ on(name, handler) { handlers.set(name, handler); } });
  return handlers;
}
function lines(path) {
  return fs.readFileSync(path, "utf8").split("\n").filter((line) => line.trim().length > 0);
}
async function waitForLines(path, count) {
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    if (lines(path).length >= count) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`timed out waiting for ${count} hook deliveries: ${lines(path)}`);
}
const handlers = await loadExtension("3001");
const duplicateHandlers = await loadExtension("3002");
process.argv = ["/usr/local/bin/prime-agent", "--model", "prime-model"];
delete process.env.RLM_DEPTH;
delete process.env.RLM_SESSION_DIR;
const rootCtx = {
  hasUI: true,
  cwd: "/tmp/prime-project",
  sessionManager: {
    getSessionId() { return "prime-root-session"; },
    getSessionFile() { return "/tmp/prime-project/sessions/root.jsonl"; }
  }
};
const childCtx = {
  hasUI: true,
  cwd: "/tmp/prime-project",
  sessionManager: {
    getSessionId() { return "prime-rlm-child"; },
    getSessionFile() { return "/tmp/prime-project/sessions/child.jsonl"; }
  }
};
await handlers.get("session_start")({ reason: "startup" }, rootCtx);
// A duplicate extension copy cannot claim the same visible surface.
await duplicateHandlers.get("session_start")({ reason: "startup" }, rootCtx);
// Reload is a resource event, not a new running transition.
await handlers.get("session_start")({ reason: "reload" }, rootCtx);
await handlers.get("before_agent_start")({ prompt: "root prompt" }, rootCtx);
await handlers.get("agent_end")({ messages: [{ role: "assistant", content: "root answer" }] }, rootCtx);
await waitForLines(process.env.FAKE_PRIME_CMUX_ARGS_LOG, 3);

// Prime tears down the old extension instance before loading a replacement.
// The old instance is already idle, so its reload shutdown must not enqueue a
// second stop; the fresh instance must not invent a running state either.
await handlers.get("session_shutdown")({ reason: "reload" }, rootCtx);
const reloadedHandlers = await loadExtension("3003");
await reloadedHandlers.get("session_start")({ reason: "reload" }, rootCtx);

// RLM children inherit CMUX_SURFACE_ID but carry a positive depth.
process.env.RLM_DEPTH = "1";
for (const name of ["session_start", "before_agent_start", "agent_end", "session_shutdown"]) {
  const event = name === "before_agent_start" ? { prompt: "child prompt" }
    : name === "agent_end" ? { messages: [{ role: "assistant", content: "child answer" }] }
    : { reason: "quit" };
  await handlers.get(name)(event, childCtx);
}

// RPC mode is headless even if a test context accidentally reports UI.
delete process.env.RLM_DEPTH;
process.argv = ["/usr/local/bin/prime-agent", "--mode", "rpc"];
await handlers.get("session_start")({ reason: "startup" }, rootCtx);
await handlers.get("before_agent_start")({ prompt: "rpc prompt" }, rootCtx);
await handlers.get("agent_end")({ messages: [{ role: "assistant", content: "rpc answer" }] }, rootCtx);
process.argv = ["/usr/local/bin/prime-agent", "--model", "prime-model"];

await reloadedHandlers.get("session_shutdown")({ reason: "quit" }, rootCtx);
// The duplicate copy never owned lifecycle state and must not emit a late stop.
await duplicateHandlers.get("session_shutdown")({ reason: "quit" }, rootCtx);
const delivered = lines(process.env.FAKE_PRIME_CMUX_ARGS_LOG);
if (!delivered.every((line) => line === "hooks prime-agent session-start"
  || line === "hooks prime-agent prompt-submit"
  || line === "hooks prime-agent stop")) {
  throw new Error(`unexpected Prime hook commands: ${delivered}`);
}
if (delivered.length !== 3) throw new Error(`child/headless/duplicate lifecycle leaked: ${delivered}`);
const payloads = fs.readFileSync(process.env.FAKE_PRIME_CMUX_STDIN_LOG, "utf8")
  .split("\n---\n").filter((chunk) => chunk.trim()).map((chunk) => JSON.parse(chunk));
if (payloads.some((payload) => payload.session_id !== "prime-root-session")) {
  throw new Error(`non-root session reached cmux: ${JSON.stringify(payloads)}`);
}
if (payloads[1].prompt !== "root prompt" || payloads[2].last_assistant_message !== "root answer") {
  throw new Error(`root lifecycle payloads were incomplete: ${JSON.stringify(payloads)}`);
}
const envLines = lines(process.env.FAKE_PRIME_CMUX_ENV_LOG);
if (envLines.filter((line) => line === "kind=prime-agent").length !== 3
  || envLines.some((line) => line === "argv=stale-capture")) {
  throw new Error(`root launch capture was not normalized: ${lines(process.env.FAKE_PRIME_CMUX_ENV_LOG)}`);
}
"""
        lifecycle = subprocess.run(
            ["bun", "--eval", lifecycle_source],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
            env=lifecycle_env,
            timeout=30,
        )
        if lifecycle.returncode != 0:
            print("FAIL: generated Prime Agent extension lifecycle contract failed")
            print(f"exit={lifecycle.returncode}")
            print(f"stdout={lifecycle.stdout.strip()}")
            print(f"stderr={lifecycle.stderr.strip()}")
            return 1

        session_id = "prime-session-123"
        session_file = str(config_dir / "sessions" / "prime-session-123.jsonl")
        workspace_id = "11111111-1111-1111-1111-111111111111"
        surface_id = "22222222-2222-2222-2222-222222222222"
        socket_path = root / "cmux.sock"
        launch_argv = ["prime-agent"]
        hook_env = env.copy()
        hook_env.update(
            {
                "PWD": str(workspace),
                "CMUX_SOCKET_PATH": str(socket_path),
                "CMUX_WORKSPACE_ID": workspace_id,
                "CMUX_SURFACE_ID": surface_id,
                "CMUX_AGENT_HOOK_STATE_DIR": str(state_dir),
                "CMUX_AGENT_LAUNCH_KIND": "prime-agent",
                "CMUX_AGENT_LAUNCH_EXECUTABLE": "prime-agent",
                "CMUX_AGENT_LAUNCH_ARGV_B64": base64.b64encode(b"prime-agent\0").decode("ascii"),
                "CMUX_AGENT_LAUNCH_CWD": str(workspace),
            }
        )
        payload = json.dumps(
            {
                "session_id": session_id,
                "session_file": session_file,
                "cwd": str(workspace),
                "hook_event_name": "session_start",
            },
            separators=(",", ":"),
        )
        with MockCmuxSocket(socket_path, workspace_id, surface_id) as server:
            hook = subprocess.run(
                [cli_path, "hooks", "prime-agent", "session-start"],
                input=payload,
                capture_output=True,
                text=True,
                check=False,
                env=hook_env,
                timeout=20,
            )
            if hook.returncode != 0 or hook.stdout != "{}\n":
                print(f"FAIL: Prime Agent hook failed: {hook.stdout}\n{hook.stderr}")
                return 1
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and not rpc_messages(server.messages(), "surface.resume.set"):
                time.sleep(0.05)
            resume_sets = rpc_messages(server.messages(), "surface.resume.set")

        store_path = state_dir / "prime-agent-hook-sessions.json"
        if not store_path.exists():
            print(f"FAIL: Prime Agent hook did not write {store_path}")
            return 1
        session = json.loads(store_path.read_text(encoding="utf-8"))["sessions"][session_id]
        if session.get("transcriptPath") != session_file:
            print(f"FAIL: session file was not persisted as the resume artifact: {session!r}")
            return 1
        launch = session.get("launchCommand") or {}
        if launch.get("arguments") != ["prime-agent", "--resume", session_file]:
            print(f"FAIL: Prime Agent launch command was not structured around the absolute session file: {launch!r}")
            return 1
        if len(resume_sets) != 1:
            print(f"FAIL: expected one managed surface.resume.set, got {resume_sets!r}")
            return 1
        params = resume_sets[0].get("params") or {}
        if not isinstance(params, dict):
            print(f"FAIL: malformed Prime Agent resume binding: {params!r}")
            return 1
        command = params.get("command")
        if params.get("kind") != "prime-agent" or params.get("checkpoint_id") != session_id or not isinstance(command, str):
            print(f"FAIL: malformed Prime Agent resume binding: {params!r}")
            return 1
        if "prime-agent" not in command or "--resume" not in command or session_file not in command:
            print(f"FAIL: managed resume command does not target the absolute Prime session file: {command!r}")
            return 1

        reinstall = subprocess.run(
            [cli_path, "hooks", "prime-agent", "install", "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=20,
        )
        if reinstall.returncode != 0 or "already up to date" not in reinstall.stdout:
            print(f"FAIL: Prime Agent install was not idempotent: {reinstall.stdout}\n{reinstall.stderr}")
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
