#!/usr/bin/env python3
"""
Regression test: the generated Amp plugin is importable and emits cmux hook calls.
"""

from __future__ import annotations

import base64
import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def main() -> int:
    # Amp loads `.ts` plugins itself via Node, so use Node for the import
    # check too. Requires Node 22.6+ for `--experimental-strip-types`
    # (default in Node 24).
    node = shutil.which("node")
    if node is None:
        print("SKIP: node not found")
        return 0
    try:
        raw_version = subprocess.check_output([node, "--version"], text=True).strip()
        version_parts = tuple(int(part) for part in raw_version.lstrip("v").split(".")[:3])
    except Exception:
        version_parts = (0, 0, 0)
    if version_parts < (22, 6, 0):
        print("SKIP: node >= 22.6.0 required")
        return 0

    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(prefix="cmux-amp-extension-") as td:
        root = Path(td)
        # `amp` has no documented config-dir override, so install resolves
        # the plugin path against $HOME. Point HOME at the temp dir for the
        # install step so we don't touch the user's real ~/.config/amp.
        env = os.environ.copy()
        env["HOME"] = str(root)

        install = subprocess.run(
            [cli_path, "hooks", "amp", "install", "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=20,
        )
        if install.returncode != 0:
            print("FAIL: amp plugin install failed")
            print(f"exit={install.returncode}")
            print(f"stdout={install.stdout.strip()}")
            print(f"stderr={install.stderr.strip()}")
            return 1

        extension_path = root / ".config" / "amp" / "plugins" / "cmux-session.ts"
        if not extension_path.exists():
            print(f"FAIL: expected plugin at {extension_path}")
            return 1
        extension_text = extension_path.read_text(encoding="utf-8")
        if "cmux-amp-session-extension-marker" not in extension_text:
            print(f"FAIL: expected cmux marker in {extension_path}")
            return 1

        fake_cmux = root / "fake-cmux"
        fake_args_log = root / "fake-cmux-args.log"
        fake_stdin_log = root / "fake-cmux-stdin.log"
        fake_env_log = root / "fake-cmux-env.log"
        fake_bin = root / "bin"
        fake_bin.mkdir()
        fake_amp = fake_bin / "amp"
        make_executable(fake_amp, "#!/usr/bin/env bash\nexit 0\n")
        make_executable(
            fake_cmux,
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_CMUX_ARGS_LOG"
if [[ "$*" == hooks\\ amp\\ __native-attention\\ identify\\ --pid\\ * ]]; then
  requested_pid="${*##* --pid }"
  requested_pid="${requested_pid%% *}"
  printf '{"pid":%s,"pid_start_seconds":1234,"pid_start_microseconds":5678}\n' "$requested_pid"
  exit 0
fi
cat >> "$FAKE_CMUX_STDIN_LOG"
printf '\n---\n' >> "$FAKE_CMUX_STDIN_LOG"
{
  printf 'kind=%s\n' "${CMUX_AGENT_LAUNCH_KIND-}"
  printf 'cwd=%s\n' "${CMUX_AGENT_LAUNCH_CWD-}"
  printf 'argv=%s\n' "${CMUX_AGENT_LAUNCH_ARGV_B64-}"
  printf 'amp_api_key=%s\n' "${AMP_API_KEY-}"
} >> "$FAKE_CMUX_ENV_LOG"
""",
        )

        check_env = env.copy()
        check_env.pop("CMUX_AMP_HOOKS_DISABLED", None)
        for key in tuple(check_env):
            if key.startswith("CMUX_AGENT_LAUNCH_"):
                check_env.pop(key)
        check_env["CMUX_TEST_AMP_EXTENSION_PATH"] = str(extension_path)
        check_env["CMUX_SURFACE_ID"] = "surface-amp-test"
        check_env["CMUX_WORKSPACE_ID"] = (
            "55555555-5555-5555-5555-555555555555"
        )
        check_env["CMUX_AMP_CMUX_BIN"] = str(fake_cmux)
        check_env["AMP_API_KEY"] = "secret-should-not-propagate"
        check_env["FAKE_CMUX_ARGS_LOG"] = str(fake_args_log)
        check_env["FAKE_CMUX_STDIN_LOG"] = str(fake_stdin_log)
        check_env["FAKE_CMUX_ENV_LOG"] = str(fake_env_log)
        check_env["PWD"] = "/tmp/amp-project"
        check_env["PATH"] = f"{fake_bin}{os.pathsep}{env.get('PATH', '')}"
        check_source = """
const extensionPath = process.env.CMUX_TEST_AMP_EXTENSION_PATH;
const mod = await import(extensionPath);
if (typeof mod.default !== "function") throw new Error("missing default export");
const handlers = new Map();
mod.default({
  on(name, handler) {
    handlers.set(name, handler);
  }
});
for (const name of ["session.start", "agent.start", "agent.end"]) {
  if (typeof handlers.get(name) !== "function") throw new Error(`missing ${name}`);
}
process.argv.splice(
  0,
  process.argv.length,
  "/usr/local/bin/node",
  "/Users/example/node_modules/@ampcode/amp/dist/cli.js",
  "--mode",
  "geppetto"
);
const thread = { id: "T-amp-session-test" };
const ctx = { thread };
await handlers.get("session.start")({ thread }, ctx);
await handlers.get("agent.start")({ thread, message: "hello amp", id: "msg-user-1" }, ctx);
await handlers.get("agent.end")({ thread, message: "hello amp", id: "msg-user-1", status: "done", messages: [] }, ctx);
"""
        check_script = root / "check.mjs"
        check_script.write_text(check_source, encoding="utf-8")
        check = subprocess.run(
            [node, "--experimental-strip-types", "--no-warnings", str(check_script)],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
            env=check_env,
            timeout=20,
        )
        if check.returncode != 0:
            print("FAIL: generated Amp plugin is not importable")
            print(f"exit={check.returncode}")
            print(f"stdout={check.stdout.strip()}")
            print(f"stderr={check.stderr.strip()}")
            return 1

        # Exercise turn settlement through an observable spawn seam. The real
        # plugin deliberately unrefs its cmux subprocesses, so observing the
        # spawn calls directly avoids timing assertions on detached children.
        fake_spawn_path = extension_path.parent / "cmux-test-spawn.mjs"
        fake_spawn_path.write_text(
            """
const nativeAttentionEndAttempts = new Map();

export function spawn(command, args, options) {
  const call = { command, args: Array.from(args || []), options, stdin: "" };
  globalThis.__cmuxAmpSpawnCalls.push(call);
  let closeStatus = 0;
  if (
    call.args.slice(0, 4).join(" ")
      === "hooks amp __native-attention end"
  ) {
    const observationIndex = call.args.indexOf("--observation-id");
    const observationId = call.args[observationIndex + 1] || "missing";
    const attempt = nativeAttentionEndAttempts.get(observationId) || 0;
    nativeAttentionEndAttempts.set(observationId, attempt + 1);
    if (attempt === 0) closeStatus = 1;
  }
  return {
    on(name, callback) {
      if (name === "close") queueMicrotask(() => callback(closeStatus));
    },
    unref() {},
    stdin: {
      on() {},
      end(value) { call.stdin = String(value || ""); },
    },
  };
}

export function spawnSync(command, args, options) {
  const call = { command, args: Array.from(args || []), options, stdin: "" };
  globalThis.__cmuxAmpSpawnCalls.push(call);
  const pidIndex = call.args.indexOf("--pid");
  if (pidIndex < 0 || !call.args[pidIndex + 1]) {
    throw new Error("missing --pid in identify call");
  }
  const requestedPid = Number(call.args[pidIndex + 1]);
  if (!Number.isSafeInteger(requestedPid) || requestedPid <= 0) {
    throw new Error(`invalid --pid in identify call: ${call.args[pidIndex + 1]}`);
  }
  return {
    status: 0,
    stdout: JSON.stringify({
      pid: requestedPid,
      pid_start_seconds: 1234,
      pid_start_microseconds: 5678,
    }),
    stderr: "",
  };
}
""",
            encoding="utf-8",
        )
        instrumented_path = extension_path.parent / "cmux-session-instrumented.ts"
        instrumented_text = extension_text.replace(
            'import { spawn, spawnSync } from "node:child_process";',
            'import { spawn, spawnSync } from "./cmux-test-spawn.mjs";',
            1,
        )
        if instrumented_text == extension_text:
            print("FAIL: could not install Amp spawn seam")
            return 1
        instrumented_path.write_text(instrumented_text, encoding="utf-8")

        settlement_source = """
globalThis.__cmuxAmpSpawnCalls = [];
const extensionPath = process.env.CMUX_TEST_AMP_INSTRUMENTED_PATH;
const mod = await import(extensionPath);
const handlers = new Map();
mod.default({
  on(name, handler) {
    handlers.set(name, handler);
  }
});
for (const name of ["agent.start", "tool.call", "tool.result", "agent.end"]) {
  if (typeof handlers.get(name) !== "function") throw new Error(`missing ${name}`);
}
const stopCalls = () => globalThis.__cmuxAmpSpawnCalls.filter(
  (call) => call.args.join(" ") === "hooks amp stop"
);
const attentionCalls = (action) => globalThis.__cmuxAmpSpawnCalls.filter(
  (call) =>
    call.args.slice(0, 4).join(" ")
      === `hooks amp __native-attention ${action}`
);
if (attentionCalls("identify").length !== 1) {
  throw new Error("Amp did not capture its exact process generation once");
}
const makeThread = (id, initialState = "running", deferInitialGet = false) => {
  let currentState = initialState;
  const observers = new Set();
  let resolveInitialGet = null;
  const initialGet = deferInitialGet
    ? new Promise((resolve) => {
        resolveInitialGet = resolve;
      })
    : null;
  return {
    id,
    state: {
      async get() {
        return initialGet ?? currentState;
      },
      subscribe(observer) {
        observers.add(observer);
        return {
          unsubscribe() {
            observers.delete(observer);
          }
        };
      }
    },
    setState(nextState) {
      currentState = nextState;
      for (const observer of observers) observer(nextState);
    },
    resolveInitialGet(value) {
      if (!resolveInitialGet) {
        throw new Error("thread has no deferred native-state snapshot");
      }
      resolveInitialGet(value);
      resolveInitialGet = null;
    }
  };
};
const thread = makeThread("T-amp-settlement-test");
const ctx = { thread };
const otherThread = { id: "T-amp-other-thread" };
const otherCtx = { thread: otherThread };
await handlers.get("agent.start")({ thread, message: "delegate", id: "msg-1" }, ctx);
thread.setState("awaiting-approval");
thread.setState("awaiting-approval");
await Promise.resolve();
if (attentionCalls("begin").length !== 1) {
  throw new Error(
    `Amp awaiting-approval emitted duplicate attention: ${
      JSON.stringify(globalThis.__cmuxAmpSpawnCalls)
    }`
  );
}
thread.setState("running");
thread.setState("running");
await Promise.resolve();
if (attentionCalls("end").length !== 2) {
  throw new Error(
    `Amp did not retry one failed approval conclusion exactly once: ${
      JSON.stringify(globalThis.__cmuxAmpSpawnCalls)
    }`
  );
}
const beginAttention = attentionCalls("begin")[0].args;
const endAttentionAttempts = attentionCalls("end").map((call) => call.args);
const endAttention = endAttentionAttempts.at(-1);
const identifyAttention = attentionCalls("identify")[0].args;
const option = (args, name) => args[args.indexOf(name) + 1];
if (
  option(identifyAttention, "--pid") !== option(beginAttention, "--pid")
  || option(beginAttention, "--pid") !== option(endAttention, "--pid")
  || option(beginAttention, "--scope-id") !== option(endAttention, "--scope-id")
  || option(beginAttention, "--observation-id")
    !== option(endAttention, "--observation-id")
  || option(beginAttention, "--pid-start-seconds")
    !== option(endAttention, "--pid-start-seconds")
  || option(beginAttention, "--pid-start-microseconds")
    !== option(endAttention, "--pid-start-microseconds")
  || option(beginAttention, "--session-id")
    !== option(endAttention, "--session-id")
) {
  throw new Error(
    `Amp approval conclusion did not match its begin: begin=${
      JSON.stringify(beginAttention)
    } end=${JSON.stringify(endAttention)}`
  );
}
for (const attemptedEnd of endAttentionAttempts) {
  if (
    option(attemptedEnd, "--pid") !== option(beginAttention, "--pid")
    || option(attemptedEnd, "--pid-start-seconds")
      !== option(beginAttention, "--pid-start-seconds")
    || option(attemptedEnd, "--pid-start-microseconds")
      !== option(beginAttention, "--pid-start-microseconds")
    || option(attemptedEnd, "--scope-id")
      !== option(beginAttention, "--scope-id")
    || option(attemptedEnd, "--observation-id")
      !== option(beginAttention, "--observation-id")
    || option(attemptedEnd, "--session-id")
      !== option(beginAttention, "--session-id")
  ) {
    throw new Error(
      `Amp retry changed native-attention identity: begin=${
        JSON.stringify(beginAttention)
      } end=${JSON.stringify(attemptedEnd)}`
    );
  }
}
await handlers.get("tool.call")({
  toolUseID: "tool-main",
  tool: "Task",
  input: { prompt: "keep working in the background" }
}, ctx);
await handlers.get("agent.start")({
  thread: otherThread,
  message: "other work",
  id: "msg-other"
}, otherCtx);
await handlers.get("tool.call")({
  thread: otherThread,
  toolUseID: "tool-other",
  tool: "Task",
  input: { prompt: "unrelated concurrent work" }
}, otherCtx);
const completionCount = stopCalls().length;
await handlers.get("agent.end")({
  thread,
  message: "delegate",
  id: "msg-1",
  status: "done",
  messages: []
}, ctx);
if (stopCalls().length !== completionCount + 1) {
  throw new Error("agent.end did not publish exactly one provisional boundary");
}
const provisional = JSON.parse(stopCalls().at(-1).stdin);
if (
  provisional.cmux_turn_boundary !== "turn_end" ||
  provisional.cmux_active_background_work_count !== 1 ||
  typeof provisional.turn_id !== "string" ||
  provisional.turn_id.length === 0
) {
  throw new Error(
    `agent.end emitted a final completion instead of provisional evidence: ${JSON.stringify(provisional)}`
  );
}
await handlers.get("tool.result")({
  thread: otherThread,
  toolUseID: "tool-other",
  tool: "Task",
  status: "done",
  output: "unrelated work finished"
}, otherCtx);
if (stopCalls().length !== completionCount + 1) {
  throw new Error("another thread's tool result settled the pending turn");
}
await handlers.get("tool.result")({
  toolUseID: "tool-main",
  tool: "Task",
  status: "done",
  output: "background work finished"
}, ctx);
if (stopCalls().length !== completionCount + 1) {
  throw new Error(
    "draining structured tools settled before Amp's native thread became idle"
  );
}
thread.setState("idle");
if (stopCalls().length !== completionCount + 2) {
  throw new Error(
    `Amp did not emit one settled completion: ${
      JSON.stringify(globalThis.__cmuxAmpSpawnCalls)
    }`
  );
}
const settled = JSON.parse(stopCalls().at(-1).stdin);
if (
  settled.cmux_turn_boundary !== "settled" ||
  settled.cmux_active_background_work_count !== 0 ||
  settled.turn_id !== provisional.turn_id
) {
  throw new Error(
    `Amp did not publish explicit settlement after background work drained: ${JSON.stringify(settled)}`
  );
}
const racedThread = makeThread(
  "T-amp-native-state-race",
  "running",
  true
);
const racedCtx = { thread: racedThread };
const racedStart = handlers.get("agent.start")({
  thread: racedThread,
  message: "race native snapshot",
  id: "msg-race"
}, racedCtx);
racedThread.setState("idle");
racedThread.resolveInitialGet("running");
await racedStart;
const racedCompletionCount = stopCalls().length;
await handlers.get("agent.end")({
  thread: racedThread,
  message: "race native snapshot",
  id: "msg-race",
  status: "done",
  messages: []
}, racedCtx);
if (stopCalls().length !== racedCompletionCount + 2) {
  throw new Error(
    "a stale native get() snapshot overwrote the newer idle subscription"
  );
}
const raceSettled = JSON.parse(stopCalls().at(-1).stdin);
if (raceSettled.cmux_turn_boundary !== "settled") {
  throw new Error(
    `Amp native-state race did not settle: ${JSON.stringify(raceSettled)}`
  );
}
"""
        settlement_script = root / "settlement-check.mjs"
        settlement_script.write_text(settlement_source, encoding="utf-8")
        settlement_env = check_env.copy()
        settlement_env["CMUX_TEST_AMP_INSTRUMENTED_PATH"] = str(instrumented_path)
        settlement = subprocess.run(
            [node, "--experimental-strip-types", "--no-warnings", str(settlement_script)],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
            env=settlement_env,
            timeout=20,
        )
        if settlement.returncode != 0:
            print("FAIL: generated Amp plugin finalized before shared settlement")
            print(f"exit={settlement.returncode}")
            print(f"stdout={settlement.stdout.strip()}")
            print(f"stderr={settlement.stderr.strip()}")
            return 1

        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            args_log = read_text(fake_args_log)
            stdin_log = read_text(fake_stdin_log)
            env_log = read_text(fake_env_log)
            if (
                "hooks amp session-start" in args_log
                and "hooks amp prompt-submit" in args_log
                and "hooks amp stop" in args_log
                and '"session_id":"T-amp-session-test"' in stdin_log
                and "argv=" in env_log
            ):
                break
            time.sleep(0.05)
        args_log = read_text(fake_args_log)
        stdin_log = read_text(fake_stdin_log)
        env_log = read_text(fake_env_log)
        for expected in [
            "hooks amp session-start",
            "hooks amp prompt-submit",
            "hooks amp stop",
        ]:
            if expected not in args_log:
                print(f"FAIL: plugin did not invoke {expected}, got {args_log!r}")
                return 1
        if '"session_id":"T-amp-session-test"' not in stdin_log:
            print(f"FAIL: plugin did not pass session id, got {stdin_log!r}")
            return 1
        if "kind=amp" not in env_log or "cwd=/tmp/amp-project" not in env_log or "argv=" not in env_log:
            print(f"FAIL: plugin did not pass launch metadata environment, got {env_log!r}")
            return 1
        if "amp_api_key=secret-should-not-propagate" in env_log:
            print(f"FAIL: plugin propagated AMP_API_KEY into hook subprocess, got {env_log!r}")
            return 1
        argv_line = next(
            (
                line
                for line in env_log.splitlines()
                if line.startswith("argv=") and line != "argv="
            ),
            "",
        )
        try:
            argv_value = argv_line[len("argv="):] if argv_line.startswith("argv=") else argv_line
            decoded_argv = [
                value
                for value in base64.b64decode(argv_value).decode("utf-8").split("\0")
                if value
            ]
        except Exception as exc:
            print(f"FAIL: plugin launch argv was not valid base64 NUL data: {exc}; env={env_log!r}")
            return 1
        expected_argv = [
            str(fake_amp),
            "--mode",
            "geppetto",
        ]
        if decoded_argv != expected_argv:
            print(f"FAIL: plugin captured wrong Amp launch argv; expected {expected_argv!r}, got {decoded_argv!r}")
            return 1

    print("PASS: generated Amp plugin installs and emits cmux hooks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
