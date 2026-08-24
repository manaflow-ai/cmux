#!/usr/bin/env python3
"""
Regression test for https://github.com/manaflow-ai/cmux/issues/9591.

OMP task-tool subagents run in the same process as the top-level session and
inherit CMUX_SURFACE_ID, but each has its own session id. The generated cmux
extension must only report lifecycle hooks (session-start / prompt-submit /
stop) for the top-level session that owns the pane; a background subagent's
agent_end must never mark the whole pane idle while the main agent is still
mid-turn, because Agent Hibernation SIGHUPs panes that read idle.

Also covered:
- agent_end with willContinue (a scheduled automatic continuation) must not
  emit a stop hook.
- session_switch (/new, fork, resume, handoff on the top-level runtime) must
  re-pin ownership to the new session id and rebind it via a session-start
  hook, so post-switch sessions do not go dark.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def non_empty_lines(text: str) -> list[str]:
    return [line for line in text.splitlines() if line.strip()]


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

    with tempfile.TemporaryDirectory(prefix="cmux-omp-subagent-") as td:
        root = Path(td)
        home = root / "home"
        home.mkdir()
        agent_dir = root / "agent-dir"

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["PI_CODING_AGENT_DIR"] = str(agent_dir)
        env.pop("CMUX_OMP_HOOKS_DISABLED", None)

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
        extension_path = agent_dir / "extensions" / "cmux-omp-session.ts"
        if not extension_path.exists():
            print(f"FAIL: expected extension at {extension_path}")
            return 1
        extension_override = os.environ.get("CMUX_TEST_OMP_EXTENSION_OVERRIDE")
        if extension_override:
            shutil.copyfile(extension_override, extension_path)

        fake_cmux = root / "fake-cmux"
        fake_args_log = root / "fake-cmux-args.log"
        fake_stdin_log = root / "fake-cmux-stdin.log"
        fake_args_log.touch()
        fake_stdin_log.touch()
        make_executable(
            fake_cmux,
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$FAKE_CMUX_ARGS_LOG"
cat >> "$FAKE_CMUX_STDIN_LOG"
printf '\\n---\\n' >> "$FAKE_CMUX_STDIN_LOG"
""",
        )

        # Both session files live flat in the same sessions directory: OMP
        # task-tool subagents are ordinary sessions, not nested artifact
        # sessions, so the nested-artifact guard does not apply to them.
        sessions_dir = root / "omp-sessions"
        sessions_dir.mkdir()
        main_session_file = sessions_dir / "2026-08-04T16-00-00_omp-main-session.jsonl"
        main_session_file.write_text("{}\n", encoding="utf-8")
        subagent_session_file = sessions_dir / "2026-08-04T16-20-36_omp-subagent-1.jsonl"
        subagent_session_file.write_text("{}\n", encoding="utf-8")

        check_env = env.copy()
        for key in [
            "CMUX_AGENT_LAUNCH_KIND",
            "CMUX_AGENT_LAUNCH_EXECUTABLE",
            "CMUX_AGENT_LAUNCH_ARGV_B64",
            "CMUX_AGENT_LAUNCH_CWD",
        ]:
            check_env.pop(key, None)
        check_env["CMUX_TEST_OMP_EXTENSION_PATH"] = str(extension_path)
        check_env["CMUX_TEST_OMP_MAIN_SESSION_FILE"] = str(main_session_file)
        check_env["CMUX_TEST_OMP_SUBAGENT_SESSION_FILE"] = str(subagent_session_file)
        check_env["CMUX_SURFACE_ID"] = "surface-omp-subagent-test"
        check_env["CMUX_OMP_CMUX_BIN"] = str(fake_cmux)
        check_env["FAKE_CMUX_ARGS_LOG"] = str(fake_args_log)
        check_env["FAKE_CMUX_STDIN_LOG"] = str(fake_stdin_log)

        check_source = """
import * as fs from "node:fs";
import * as path from "node:path";
const extensionPath = process.env.CMUX_TEST_OMP_EXTENSION_PATH;
// OMP loads a fresh copy of the extension module for every session in the
// process: each import goes through a unique ?mtime= cache-busting URL, so
// module scope is per-session, never shared between the top-level session and
// task subagents. Model that here - any cross-session state the extension
// relies on must survive separate module instances.
async function loadExtensionInstance(cacheBust) {
  const url = `${path.resolve(extensionPath)}?mtime=${cacheBust}`;
  const mod = await import(url);
  if (typeof mod.default !== "function") throw new Error("missing default export");
  const handlers = new Map();
  mod.default({
    on(name, handler) {
      handlers.set(name, handler);
    }
  });
  for (const name of ["session_start", "before_agent_start", "agent_end", "session_shutdown"]) {
    if (typeof handlers.get(name) !== "function") throw new Error(`missing ${name}`);
  }
  return handlers;
}
const handlers = await loadExtensionInstance("1001");
const subagentHandlers = await loadExtensionInstance("1002");
if (subagentHandlers.get("agent_end") === handlers.get("agent_end")) {
  throw new Error("test harness bug: subagent instance shared the main module instance");
}
process.argv.splice(
  0,
  process.argv.length,
  "/Users/example/.bun/bin/omp",
  "--model",
  "anthropic/claude-sonnet-4-5"
);
let mainSessionId = "omp-main-session";
const mainCtx = {
  cwd: "/tmp/omp-subagent-project",
  sessionManager: {
    getSessionId() { return mainSessionId; },
    getSessionFile() { return process.env.CMUX_TEST_OMP_MAIN_SESSION_FILE; }
  }
};
const subagentCtx = {
  cwd: "/tmp/omp-subagent-project",
  sessionManager: {
    getSessionId() { return "omp-subagent-1"; },
    getSessionFile() { return process.env.CMUX_TEST_OMP_SUBAGENT_SESSION_FILE; }
  }
};
function agentEndEvent(text, extra = {}) {
  return {
    messages: [
      { role: "user", content: "plan the trip" },
      { role: "assistant", content: [{ type: "text", text }] }
    ],
    stopReason: "completed",
    ...extra
  };
}

// Top-level session boots and starts a turn.
await handlers.get("session_start")({}, mainCtx);
await handlers.get("before_agent_start")({ prompt: "plan the trip" }, mainCtx);

// A background task-tool subagent boots, runs, and finishes while the main
// agent is still mid-turn. Its events arrive through its own freshly loaded
// module instance, as in real OMP. None of this may reach cmux.
await subagentHandlers.get("session_start")({}, subagentCtx);
await subagentHandlers.get("before_agent_start")({ prompt: "scout the beaches" }, subagentCtx);
await subagentHandlers.get("agent_end")(agentEndEvent("subagent done"), subagentCtx);

// Main agent_end with a scheduled automatic continuation: still running.
await handlers.get("agent_end")(agentEndEvent("continuing", { willContinue: true }), mainCtx);

// Main agent's terminal settle: this is the pane's real idle transition.
await handlers.get("agent_end")(agentEndEvent("main done"), mainCtx);

// /reload re-emits session_switch for the SAME session file and id. That is
// not an ownership transition: it must emit nothing, or an idle pane's
// record would flip back to running with no agent_end ever coming.
const sameSessionSwitch = handlers.get("session_switch");
if (typeof sameSessionSwitch === "function") {
  await sameSessionSwitch(
    { reason: "resume", previousSessionFile: process.env.CMUX_TEST_OMP_MAIN_SESSION_FILE },
    mainCtx
  );
}

// /new switches the top-level runtime to a fresh session id; ownership must
// follow it and cmux must be rebound via a session-start hook. A missing
// session_switch handler means post-switch sessions go dark; drive the
// remaining flow anyway so the delivered hook sequence exposes every gap.
mainSessionId = "omp-new-session";
const sessionSwitch = handlers.get("session_switch");
if (typeof sessionSwitch === "function") {
  await sessionSwitch(
    { reason: "new", previousSessionFile: process.env.CMUX_TEST_OMP_MAIN_SESSION_FILE },
    mainCtx
  );
}
await handlers.get("agent_end")(agentEndEvent("new done"), mainCtx);

// Wait for the async hook queue to deliver before shutdown: session_shutdown
// intentionally strips still-queued prompt-submit entries, so shutting down
// immediately would race the queue worker and make delivery timing-dependent.
const expectedDeliveredHooks = 5;
const deliveryDeadline = Date.now() + 10000;
while (Date.now() < deliveryDeadline) {
  const delivered = fs.readFileSync(process.env.FAKE_CMUX_ARGS_LOG, "utf8")
    .split("\\n")
    .filter((line) => line.trim().length > 0).length;
  if (delivered >= expectedDeliveredHooks) break;
  await new Promise((resolve) => setTimeout(resolve, 20));
}

await handlers.get("session_shutdown")({}, mainCtx);
"""
        check = subprocess.run(
            [bun, "--eval", check_source],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
            env=check_env,
            timeout=30,
        )
        if check.returncode != 0:
            print("FAIL: generated OMP extension did not satisfy the subagent lifecycle contract")
            print(f"exit={check.returncode}")
            print(f"stdout={check.stdout.strip()}")
            print(f"stderr={check.stderr.strip()}")
            return 1

        args_lines = non_empty_lines(fake_args_log.read_text(encoding="utf-8"))
        expected_args = [
            "hooks omp session-start",
            "hooks omp prompt-submit",
            "hooks omp stop",
            "hooks omp session-start",
            "hooks omp stop",
        ]
        if args_lines != expected_args:
            print("FAIL: hook invocation sequence did not match the top-level-session contract")
            print(f"expected: {expected_args!r}")
            print(f"got:      {args_lines!r}")
            return 1

        stdin_log = fake_stdin_log.read_text(encoding="utf-8")
        payloads = []
        for chunk in stdin_log.split("\n---\n"):
            chunk = chunk.strip()
            if not chunk:
                continue
            try:
                payloads.append(json.loads(chunk))
            except json.JSONDecodeError as exc:
                print(f"FAIL: hook payload was not valid JSON: {exc}; chunk={chunk!r}")
                return 1
        if len(payloads) != len(expected_args):
            print(f"FAIL: expected {len(expected_args)} hook payloads, got {payloads!r}")
            return 1

        if "omp-subagent-1" in stdin_log:
            print(f"FAIL: a subagent session reached cmux lifecycle hooks: {stdin_log!r}")
            return 1
        if "subagent done" in stdin_log or "scout the beaches" in stdin_log:
            print(f"FAIL: subagent turn content leaked into hook payloads: {stdin_log!r}")
            return 1

        session_ids = [payload.get("session_id") for payload in payloads]
        expected_session_ids = [
            "omp-main-session",
            "omp-main-session",
            "omp-main-session",
            "omp-new-session",
            "omp-new-session",
        ]
        if session_ids != expected_session_ids:
            print("FAIL: hook payload session ids did not match the owning session")
            print(f"expected: {expected_session_ids!r}")
            print(f"got:      {session_ids!r}")
            return 1

        stops = [payload for payload in payloads if payload.get("hook_event_name") == "Stop"]
        if len(stops) != 2:
            print(f"FAIL: expected exactly 2 Stop payloads, got {payloads!r}")
            return 1
        if stops[0].get("last_assistant_message") != "main done":
            print(
                "FAIL: the pane's idle transition did not carry the main agent's terminal settle "
                f"(willContinue agent_end must not stop the pane): {stops[0]!r}"
            )
            return 1
        if stops[1].get("last_assistant_message") != "new done":
            print(f"FAIL: post-switch session's stop payload was wrong: {stops[1]!r}")
            return 1
        if payloads[1].get("prompt") != "plan the trip":
            print(f"FAIL: prompt-submit payload was wrong: {payloads[1]!r}")
            return 1

    print(
        "PASS: OMP lifecycle hooks are owned by the top-level session; subagent agent_end "
        "cannot idle the pane, willContinue defers stop, and session_switch re-pins ownership"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
