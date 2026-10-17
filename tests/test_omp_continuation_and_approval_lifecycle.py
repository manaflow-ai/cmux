#!/usr/bin/env python3
"""
Regression test for two pane states the generated OMP extension could not reach.

1. Running after a promptless continuation. OMP fires before_agent_start only
   for a user-submitted prompt. A loop that starts from a delivered background
   subagent result, a queued or steering message, or a session_stop
   continuation reaches agent_start with no prompt-submit behind it, so the
   pane kept the Idle status the previous agent_end set while the agent was
   visibly working. agent_start must re-arm Running for exactly that case, and
   a normal turn must still deliver exactly one prompt-submit (the one that
   carries prompt text for auto-naming). An aborted turn that never reaches
   agent_start must not swallow the next continuation's re-arm.

2. Needs-input while a tool waits on approval. The agent is neither running
   nor idle; it is blocked on the user. tool_approval_requested must map onto
   the notification hook ("Approval needed" routes to needsInput plus the bell)
   and tool_approval_resolved onto approval-response (not prompt-submit, whose
   mid-turn form is suppressed as a nested prompt and would leave the bell
   ringing after the answer).
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

    with tempfile.TemporaryDirectory(prefix="cmux-omp-continuation-") as td:
        root = Path(td)
        home = root / "home"
        home.mkdir()
        agent_dir = root / "agent-dir"

        env = os.environ.copy()
        env["HOME"] = str(home)
        # Point both agent-directory overrides at the fixture: the installer
        # honours OMP_AGENT_DIR over PI_CODING_AGENT_DIR, and a developer's own
        # OMP_AGENT_DIR must never receive the test install.
        env["OMP_AGENT_DIR"] = str(agent_dir)
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

        sessions_dir = root / "omp-sessions"
        sessions_dir.mkdir()
        main_session_file = sessions_dir / "2026-08-21T10-00-00_omp-main-session.jsonl"
        main_session_file.write_text("{}\n", encoding="utf-8")

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
        check_env["CMUX_SURFACE_ID"] = "surface-omp-continuation-test"
        check_env["CMUX_OMP_CMUX_BIN"] = str(fake_cmux)
        check_env["FAKE_CMUX_ARGS_LOG"] = str(fake_args_log)
        check_env["FAKE_CMUX_STDIN_LOG"] = str(fake_stdin_log)

        # Every hook the contract expects, in order. The harness drives the
        # whole flow even when a handler is missing from an older extension, so
        # the delivered sequence exposes exactly which transition went dark.
        expected_args = [
            "hooks enqueue omp session-start",
            # Turn 1: a user prompt. before_agent_start and agent_start pair up
            # into exactly one prompt-submit, and the agent_start that follows
            # agent_end(willContinue) adds nothing: the turn is still open and
            # cmux already shows Running.
            "hooks enqueue omp prompt-submit",
            # A tool blocks on the user, then the user answers.
            "hooks enqueue omp notification",
            "hooks enqueue omp approval-response",
            "hooks enqueue omp stop",
            # The pane is Idle. A background-job result starts a new loop with
            # no before_agent_start: agent_start must open a new turn.
            "hooks enqueue omp prompt-submit",
            "hooks enqueue omp stop",
            # Turn 3 is aborted before agent_start ever fires.
            "hooks enqueue omp prompt-submit",
            "hooks enqueue omp stop",
            # The promptless loop after that abort must still open a turn.
            "hooks enqueue omp prompt-submit",
            "hooks enqueue omp stop",
        ]

        check_source = """
import * as fs from "node:fs";
import * as path from "node:path";
const extensionPath = process.env.CMUX_TEST_OMP_EXTENSION_PATH;
const url = `${path.resolve(extensionPath)}?mtime=2001`;
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
async function fire(name, event, ctx) {
  const handler = handlers.get(name);
  if (typeof handler === "function") await handler(event, ctx);
}
// The extension's hook queue keeps one queued entry per subcommand and session
// (a newer prompt-submit replaces a still-queued one), so hooks are delivered
// at the pace OMP emits them, never back to back. Let each step land before the
// next one fires. A missing handler delivers nothing, so cap the wait and let
// the final sequence check report the gap instead of hanging here.
function deliveredCount() {
  return fs.readFileSync(process.env.FAKE_CMUX_ARGS_LOG, "utf8")
    .split("\\n")
    .filter((line) => line.trim().length > 0).length;
}
async function settle(expected) {
  const deadline = Date.now() + 3000;
  while (Date.now() < deadline && deliveredCount() < expected) {
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
}
process.argv.splice(
  0,
  process.argv.length,
  "/Users/example/.bun/bin/omp",
  "--model",
  "anthropic/claude-sonnet-4-5"
);
const ctx = {
  cwd: "/tmp/omp-continuation-project",
  sessionManager: {
    getSessionId() { return "omp-main-session"; },
    getSessionFile() { return process.env.CMUX_TEST_OMP_MAIN_SESSION_FILE; }
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

await fire("session_start", {}, ctx);
await settle(1);

// Turn 1: user prompt. before_agent_start and agent_start are one turn start.
await fire("before_agent_start", { prompt: "plan the trip" }, ctx);
await fire("agent_start", {}, ctx);
await settle(2);

// A scheduled continuation inside the same turn: agent_end(willContinue) sends
// no stop, and the loop that follows starts from agent_start with no prompt.
// Nothing may be sent here; give a spurious prompt-submit time to show up so
// the final sequence check catches it.
await fire("agent_end", agentEndEvent("continuing", { willContinue: true }), ctx);
await fire("agent_start", {}, ctx);
await new Promise((resolve) => setTimeout(resolve, 300));

// A tool blocks on the user, then the user answers.
await fire("tool_approval_requested", { toolName: "bash", toolCallId: "call-1" }, ctx);
await settle(3);
await fire("tool_approval_resolved", { toolCallId: "call-1", decision: "allow" }, ctx);
await settle(4);

await fire("agent_end", agentEndEvent("main done"), ctx);
await settle(5);

// Idle. A background-job result starts a new loop with no user prompt.
await fire("agent_start", {}, ctx);
await settle(6);
await fire("agent_end", agentEndEvent("job done"), ctx);
await settle(7);

// Turn 3 is aborted before agent_start fires (e.g. Escape during submit).
await fire("before_agent_start", { prompt: "second task" }, ctx);
await settle(8);
await fire("agent_end", agentEndEvent("aborted", { stopReason: "aborted" }), ctx);
await settle(9);

// The promptless loop after that abort must still open a turn.
await fire("agent_start", {}, ctx);
await settle(10);
await fire("agent_end", agentEndEvent("final"), ctx);
await settle(%(expected_count)d);

await fire("session_shutdown", {}, ctx);
""" % {"expected_count": len(expected_args)}
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
            print("FAIL: generated OMP extension did not run the continuation/approval flow")
            print(f"exit={check.returncode}")
            print(f"stdout={check.stdout.strip()}")
            print(f"stderr={check.stderr.strip()}")
            return 1

        args_lines = non_empty_lines(fake_args_log.read_text(encoding="utf-8"))
        if args_lines != expected_args:
            print("FAIL: hook invocation sequence did not match the continuation/approval contract")
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

        prompt_submits = [p for p in payloads if p.get("hook_event_name") == "UserPromptSubmit"]
        if len(prompt_submits) != 4:
            print(f"FAIL: expected 4 UserPromptSubmit payloads, got {prompt_submits!r}")
            return 1
        if prompt_submits[0].get("prompt") != "plan the trip":
            print(f"FAIL: the user turn's prompt-submit lost its prompt text: {prompt_submits[0]!r}")
            return 1
        if "prompt" in prompt_submits[1]:
            print(
                "FAIL: the post-idle continuation's prompt-submit must not carry prompt text "
                f"(auto-naming would treat it as a new prompt): {prompt_submits[1]!r}"
            )
            return 1
        if prompt_submits[2].get("prompt") != "second task":
            print(f"FAIL: the aborted turn's prompt-submit was wrong: {prompt_submits[2]!r}")
            return 1
        if "prompt" in prompt_submits[3]:
            print(f"FAIL: the post-abort continuation's prompt-submit carried prompt text: {prompt_submits[3]!r}")
            return 1

        notification = payloads[2]
        if notification.get("hook_event_name") != "Notification":
            print(f"FAIL: approval request did not map to the Notification hook: {notification!r}")
            return 1
        if notification.get("message") != "Approval needed: bash":
            print(
                "FAIL: approval request message must say 'Approval needed' so cmux routes it "
                f"to needsInput: {notification!r}"
            )
            return 1
        if (notification.get("notification") or {}).get("type") != "permission":
            print(f"FAIL: approval request payload lacked notification.type=permission: {notification!r}")
            return 1

        stops = [p for p in payloads if p.get("hook_event_name") == "Stop"]
        if [s.get("last_assistant_message") for s in stops] != ["main done", "job done", "aborted", "final"]:
            print(f"FAIL: stop payloads did not follow the turn settles: {stops!r}")
            return 1

    print(
        "PASS: OMP extension opens one turn per prompt-submit/stop pair, re-arms Running "
        "only for promptless loops after Idle, and signals pending approvals via "
        "notification and approval-response"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
