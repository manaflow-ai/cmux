#!/usr/bin/env python3
"""
Regression test: the generated Amp plugin is importable and emits cmux hook calls.
"""

from __future__ import annotations

import base64
import json
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

        extension_path.write_text(
            "// cmux-amp-session-extension-marker v2\n"
            "// stale managed fixture without settled turn boundaries\n",
            encoding="utf-8",
        )
        workspace_id = "55555555-5555-5555-5555-555555555555"
        surface_id = "66666666-6666-6666-6666-666666666666"
        refresh_env = env.copy()
        refresh_env["CMUX_WORKSPACE_ID"] = workspace_id
        refresh_env["CMUX_SURFACE_ID"] = surface_id
        refresh_result = subprocess.run(
            [
                cli_path,
                "--socket",
                str(root / "missing-amp-refresh.sock"),
                "hooks",
                "amp",
                "session-start",
                "--workspace",
                workspace_id,
                "--surface",
                surface_id,
            ],
            input=json.dumps(
                {
                    "session_id": "amp-managed-plugin-refresh",
                    "cwd": str(root),
                    "hook_event_name": "SessionStart",
                }
            ),
            capture_output=True,
            text=True,
            check=False,
            env=refresh_env,
            timeout=20,
        )
        if refresh_result.returncode == 0:
            print("FAIL: Amp refresh fixture unexpectedly connected to its missing socket")
            return 1
        refreshed_text = extension_path.read_text(encoding="utf-8")
        if refreshed_text != extension_text:
            print("FAIL: Amp session-start did not refresh the stale cmux-managed plugin")
            return 1
        if "cmux-amp-session-extension-marker" not in refreshed_text:
            print("FAIL: Amp session-start rewrote the plugin without the cmux marker")
            return 1

        # The event-time refresh path is only allowed to replace a file that
        # cmux previously marked as its own. An unmarked empty file can be a
        # user placeholder, so preserve it just like any other custom file.
        extension_path.write_text("", encoding="utf-8")
        empty_refresh = subprocess.run(
            [
                cli_path,
                "--socket",
                str(root / "missing-amp-refresh-empty.sock"),
                "hooks",
                "amp",
                "session-start",
                "--workspace",
                workspace_id,
                "--surface",
                surface_id,
            ],
            input=json.dumps(
                {
                    "session_id": "amp-unmarked-empty-plugin",
                    "cwd": str(root),
                    "hook_event_name": "SessionStart",
                }
            ),
            capture_output=True,
            text=True,
            check=False,
            env=refresh_env,
            timeout=20,
        )
        if empty_refresh.returncode == 0:
            print("FAIL: empty Amp refresh fixture unexpectedly connected to its missing socket")
            return 1
        if extension_path.read_text(encoding="utf-8") != "":
            print("FAIL: Amp refresh overwrote an unmarked empty plugin")
            return 1

        custom_plugin = "// user-owned Amp plugin\nexport default () => {};\n"
        extension_path.write_text(custom_plugin, encoding="utf-8")
        custom_refresh = subprocess.run(
            [
                cli_path,
                "--socket",
                str(root / "missing-amp-refresh-custom.sock"),
                "hooks",
                "amp",
                "session-start",
                "--workspace",
                workspace_id,
                "--surface",
                surface_id,
            ],
            input=json.dumps(
                {
                    "session_id": "amp-unmarked-custom-plugin",
                    "cwd": str(root),
                    "hook_event_name": "SessionStart",
                }
            ),
            capture_output=True,
            text=True,
            check=False,
            env=refresh_env,
            timeout=20,
        )
        if custom_refresh.returncode == 0:
            print("FAIL: custom Amp refresh fixture unexpectedly connected to its missing socket")
            return 1
        if extension_path.read_text(encoding="utf-8") != custom_plugin:
            print("FAIL: Amp refresh overwrote an unmarked custom plugin")
            return 1

        # Restore the managed fixture for the import and lifecycle checks
        # below; those checks intentionally exercise cmux's generated source.
        extension_path.write_text(extension_text, encoding="utf-8")

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
  printf 'workspace_id=%s\n' "${CMUX_WORKSPACE_ID-}"
  printf 'amp_api_key=%s\n' "${AMP_API_KEY-}"
  printf 'socket_password=%s\n' "${CMUX_SOCKET_PASSWORD-}"
  printf 'socket_capability=%s\n' "${CMUX_SOCKET_CAPABILITY-}"
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
        check_env["CMUX_SOCKET_PASSWORD"] = "socket-password-should-not-propagate"
        check_env["CMUX_SOCKET_CAPABILITY"] = "socket-capability-should-not-propagate"
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
let nativeAttentionIdentifyAttempts = 0;
const nativeAttentionEndAttempts = new Map();

export function spawn(command, args, options) {
  const call = { command, args: Array.from(args || []), options, stdin: "" };
  globalThis.__cmuxAmpSpawnCalls.push(call);
  let closeStatus = 0;
  let hangs = false;
  let stdout = "";
  if (
    call.args.slice(0, 5).join(" ")
      === "hooks amp __native-attention identify --pid"
  ) {
    const attempt = nativeAttentionIdentifyAttempts;
    nativeAttentionIdentifyAttempts += 1;
    const pidIndex = call.args.indexOf("--pid");
    const requestedPid = Number(call.args[pidIndex + 1]);
    if (globalThis.__cmuxAmpFailAllIdentityCaptures === true || attempt === 0) {
      closeStatus = 1;
    } else {
      stdout = JSON.stringify({
        pid: requestedPid,
        pid_start_seconds: 1234,
        pid_start_microseconds: 5678,
      });
    }
  }
  if (
    call.args.slice(0, 4).join(" ")
      === "hooks amp __native-attention end"
  ) {
    const observationIndex = call.args.indexOf("--observation-id");
    const observationId = call.args[observationIndex + 1] || "missing";
    const attempt = nativeAttentionEndAttempts.get(observationId) || 0;
    nativeAttentionEndAttempts.set(observationId, attempt + 1);
    if (globalThis.__cmuxAmpHangNextEndAttempts > 0) {
      globalThis.__cmuxAmpHangNextEndAttempts -= 1;
      hangs = true;
    } else if (globalThis.__cmuxAmpSkipNextEndTimeout === true) {
      globalThis.__cmuxAmpSkipNextEndTimeout = false;
    } else if (attempt === 0) {
      hangs = true;
    }
  }
  if (
    call.args.slice(0, 4).join(" ")
      === "hooks amp __native-attention begin"
    && globalThis.__cmuxAmpHangNextBegin === true
  ) {
    globalThis.__cmuxAmpHangNextBegin = false;
    hangs = true;
  }
  const handlers = new Map();
  const stdoutHandlers = new Map();
  const child = {
    on(name, callback) {
      handlers.set(name, callback);
      return child;
    },
    unref() {},
    kill(signal) {
      call.killedWith = signal;
      return true;
    },
    stdout: {
      on(name, callback) {
        stdoutHandlers.set(name, callback);
        return child.stdout;
      },
    },
    stdin: {
      on() {},
      end(value) { call.stdin = String(value || ""); },
    },
  };
  queueMicrotask(() => {
    if (hangs) return;
    if (stdout) stdoutHandlers.get("data")?.(stdout);
    call.closedWith = closeStatus;
    handlers.get("close")?.(closeStatus);
  });
  return child;
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
        if extension_text.count('from "node:child_process";') != 1:
            print("FAIL: Amp plugin no longer has exactly one child_process import")
            return 1
        instrumented_text = extension_text.replace(
            'from "node:child_process";',
            'from "./cmux-test-spawn.mjs";',
            1,
        )
        if instrumented_text == extension_text:
            print("FAIL: could not install Amp spawn seam")
            return 1
        instrumented_path.write_text(instrumented_text, encoding="utf-8")

        settlement_source = """
globalThis.__cmuxAmpSpawnCalls = [];
const platformSetTimeout = globalThis.setTimeout;
const platformClearTimeout = globalThis.clearTimeout;
const controlledTimers = new Set();
globalThis.setTimeout = (callback, delay = 0, ...args) => {
  const timer = {
    callback,
    delay: Number(delay) || 0,
    args,
    cancelled: false,
    handle: null
  };
  const handle = {
    timer,
    unref() { return handle; }
  };
  timer.handle = handle;
  controlledTimers.add(timer);
  return handle;
};
globalThis.clearTimeout = (handle) => {
  const timer = handle?.timer;
  if (!timer) return;
  timer.cancelled = true;
  controlledTimers.delete(timer);
};
const dispatchControlledTimers = async (delay) => {
  let dispatched = 0;
  for (let pass = 0; pass < 100; pass += 1) {
    await Promise.resolve();
    const due = Array.from(controlledTimers).filter(
      (timer) => !timer.cancelled && timer.delay === delay
    );
    if (due.length === 0) return dispatched;
    for (const timer of due) {
      controlledTimers.delete(timer);
      if (timer.cancelled) continue;
      dispatched += 1;
      timer.callback(...timer.args);
    }
  }
  throw new Error(`Amp controlled timer queue did not quiesce for ${delay}ms`);
};
const dispatchControlledTimersOrFail = async (delay) => {
  const dispatched = await dispatchControlledTimers(delay);
  if (dispatched === 0) {
    throw new Error(
      `Amp scheduled no ${delay}ms timer; pending delays=${
        JSON.stringify(Array.from(controlledTimers, (timer) => timer.delay))
      }`
    );
  }
  return dispatched;
};
const extensionPath = process.env.CMUX_TEST_AMP_INSTRUMENTED_PATH;
const mod = await import(extensionPath);
const handlers = new Map();
mod.default({
  on(name, handler) {
    handlers.set(name, handler);
  }
});
for (const name of [
  "session.start",
  "agent.start",
  "tool.call",
  "tool.result",
  "agent.end"
]) {
  if (typeof handlers.get(name) !== "function") throw new Error(`missing ${name}`);
}
const stopCalls = () => globalThis.__cmuxAmpSpawnCalls.filter(
  (call) => call.args.join(" ") === "hooks amp stop"
);
const statusCalls = () => globalThis.__cmuxAmpSpawnCalls.filter(
  (call) => call.args[0] === "set-status" && call.args[1] === "amp"
);
const attentionCalls = (action) => globalThis.__cmuxAmpSpawnCalls.filter(
  (call) =>
    call.args.slice(0, 4).join(" ")
      === `hooks amp __native-attention ${action}`
);
const waitFor = async (predicate, description, timeout = 4000) => {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => platformSetTimeout(resolve, 5));
  }
  throw new Error(
    `${description}: ${JSON.stringify(globalThis.__cmuxAmpSpawnCalls)}`
  );
};
if (globalThis.__cmuxAmpSpawnCalls.length !== 0) {
  throw new Error("Amp synchronously spawned cmux while loading the plugin");
}
const makeThread = (
  id,
  initialState = "running",
  deferInitialGet = false,
  failures = { get: false, subscribe: false },
) => {
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
        if (failures.get) throw new Error("native thread state get failed");
        return initialGet ?? currentState;
      },
      subscribe(observer) {
        if (failures.subscribe) {
          throw new Error("native thread state subscribe failed");
        }
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
    },
    observerCount() {
      return observers.size;
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
await waitFor(
  () => attentionCalls("identify").length >= 1
    && attentionCalls("identify")[0].closedWith === 1,
  "Amp did not observe the transient process-identity failure"
);
await waitFor(
  () => attentionCalls("identify").length === 2
    && attentionCalls("begin").length === 1
    && attentionCalls("begin")[0].closedWith === 0,
  "Amp did not retry identity capture while approval remained pending"
);
thread.setState("running");
thread.setState("running");
await waitFor(
  () => attentionCalls("end").length === 1,
  "Amp did not start the first approval conclusion"
);
await dispatchControlledTimersOrFail(2_000);
await waitFor(
  () => attentionCalls("end").length === 2
    && attentionCalls("end")[1].closedWith === 0,
  "Amp did not retry one timed-out approval conclusion exactly once"
);
const beginAttention = attentionCalls("begin")[0].args;
const endAttentionAttempts = attentionCalls("end").map((call) => call.args);
const endAttention = endAttentionAttempts.at(-1);
const identifyAttention = attentionCalls("identify").at(-1).args;
if (attentionCalls("end")[0].killedWith !== "SIGKILL") {
  throw new Error("Amp did not kill a timed-out native-attention subprocess");
}
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
thread.setState("awaiting-approval");
await waitFor(
  () => attentionCalls("begin").length === 2
    && attentionCalls("begin")[1].closedWith === 0,
  "Amp did not publish a second approval episode in the same turn"
);
const secondBeginAttention = attentionCalls("begin")[1].args;
if (
  option(secondBeginAttention, "--scope-id")
    === option(beginAttention, "--scope-id")
  || option(secondBeginAttention, "--observation-id")
    === option(beginAttention, "--observation-id")
) {
  throw new Error(
    `Amp reused a concluded approval identity: first=${
      JSON.stringify(beginAttention)
    } second=${JSON.stringify(secondBeginAttention)}`
  );
}
thread.setState("running");
await waitFor(
  () => attentionCalls("end").length === 3,
  "Amp did not start the second approval conclusion"
);
await dispatchControlledTimersOrFail(2_000);
await waitFor(
  () => attentionCalls("end").length === 4
    && attentionCalls("end")[3].closedWith === 0,
  "Amp did not conclude the second approval episode"
);
for (const attemptedEnd of attentionCalls("end").slice(2)) {
  if (
    option(attemptedEnd.args, "--scope-id")
      !== option(secondBeginAttention, "--scope-id")
    || option(attemptedEnd.args, "--observation-id")
      !== option(secondBeginAttention, "--observation-id")
  ) {
    throw new Error(
      `Amp changed the second approval identity during conclusion: begin=${
        JSON.stringify(secondBeginAttention)
      } end=${JSON.stringify(attemptedEnd.args)}`
    );
  }
}
globalThis.__cmuxAmpHangNextBegin = true;
globalThis.__cmuxAmpSkipNextEndTimeout = true;
thread.setState("awaiting-approval");
await waitFor(
  () => attentionCalls("begin").length === 3,
  "Amp did not start the acknowledgement-timeout approval episode"
);
const unacknowledgedBegin = attentionCalls("begin")[2].args;
const unacknowledgedEndCount = attentionCalls("end").length;
thread.setState("running");
await dispatchControlledTimersOrFail(2_000);
await waitFor(
  () => attentionCalls("end")
    .slice(unacknowledgedEndCount)
    .some((call) => call.closedWith === 0),
  "Amp did not conservatively conclude an unacknowledged approval begin"
);
const unacknowledgedConclusion = attentionCalls("end")
  .slice(unacknowledgedEndCount)
  .find((call) => call.closedWith === 0).args;
if (
  option(unacknowledgedConclusion, "--scope-id")
    !== option(unacknowledgedBegin, "--scope-id")
  || option(unacknowledgedConclusion, "--observation-id")
    !== option(unacknowledgedBegin, "--observation-id")
) {
  throw new Error(
    `Amp concluded the wrong unacknowledged approval episode: begin=${
      JSON.stringify(unacknowledgedBegin)
    } end=${JSON.stringify(unacknowledgedConclusion)}`
  );
}
const identityFailureThread = makeThread(
  "T-amp-native-identity-exhausted",
  "running"
);
const identityFailureCtx = { thread: identityFailureThread };
await handlers.get("agent.start")({
  thread: identityFailureThread,
  message: "release status after identity retries",
  id: "msg-identity-exhausted"
}, identityFailureCtx);
globalThis.__cmuxAmpFailAllIdentityCaptures = true;
const identityFailureBeginCount = attentionCalls("identify").length;
identityFailureThread.setState("awaiting-approval");
await waitFor(
  () => attentionCalls("identify").length
    >= identityFailureBeginCount + 3,
  "Amp did not exhaust bounded native identity retries"
);
globalThis.__cmuxAmpFailAllIdentityCaptures = false;
const statusBeforeIdentityRecovery = statusCalls().length;
const identityRecoveryThread = makeThread(
  "T-amp-native-identity-recovery",
  "running"
);
const identityRecoveryCtx = { thread: identityRecoveryThread };
await handlers.get("agent.start")({
  thread: identityRecoveryThread,
  message: "status after identity retry exhaustion",
  id: "msg-identity-recovery"
}, identityRecoveryCtx);
await handlers.get("tool.call")({
  thread: identityRecoveryThread,
  toolUseID: "tool-identity-recovery",
  tool: "Task",
  input: { prompt: "prove status fanout recovered" }
}, identityRecoveryCtx);
if (statusCalls().length <= statusBeforeIdentityRecovery) {
  throw new Error(
    "Amp native identity retry exhaustion permanently suppressed status fanout"
  );
}
identityFailureThread.setState("running");

const approvalStatusThread = makeThread("T-amp-status-approval", "running");
const approvalStatusCtx = { thread: approvalStatusThread };
const siblingStatusThread = makeThread("T-amp-status-sibling", "running");
const siblingStatusCtx = { thread: siblingStatusThread };
await handlers.get("agent.start")({
  thread: approvalStatusThread,
  message: "approval owns aggregate status",
  id: "msg-status-approval"
}, approvalStatusCtx);
await handlers.get("agent.start")({
  thread: siblingStatusThread,
  message: "sibling status work",
  id: "msg-status-sibling"
}, siblingStatusCtx);
await handlers.get("tool.call")({
  thread: siblingStatusThread,
  toolUseID: "tool-status-sibling",
  tool: "Task",
  input: { prompt: "retain shared status" }
}, siblingStatusCtx);
const aggregateApprovalBeginCount = attentionCalls("begin").length;
approvalStatusThread.setState("awaiting-approval");
await waitFor(
  () => attentionCalls("begin").length === aggregateApprovalBeginCount + 1
    && attentionCalls("begin").at(-1).closedWith === 0,
  "Amp did not publish the aggregate-status approval"
);
const statusCountDuringApproval = statusCalls().length;
const transientSessionThread = { id: "T-amp-status-session-start" };
await handlers.get("session.start")(
  { thread: transientSessionThread },
  { thread: transientSessionThread }
);
await handlers.get("tool.result")({
  thread: siblingStatusThread,
  toolUseID: "tool-status-sibling",
  tool: "Task",
  status: "done",
  output: "sibling work finished"
}, siblingStatusCtx);
if (statusCalls().length !== statusCountDuringApproval) {
  throw new Error(
    "another Amp thread overwrote the shared Needs input status"
  );
}
const aggregateApprovalEndCount = attentionCalls("end").length;
approvalStatusThread.setState("running");
await waitFor(
  () => attentionCalls("end").length === aggregateApprovalEndCount + 1,
  "Amp did not start the aggregate-status approval conclusion"
);
await dispatchControlledTimersOrFail(2_000);
await waitFor(
  () => attentionCalls("end").length === aggregateApprovalEndCount + 2
    && attentionCalls("end").at(-1).closedWith === 0,
  "Amp did not conclude the aggregate-status approval"
);
await handlers.get("tool.call")({
  thread: siblingStatusThread,
  toolUseID: "tool-status-sibling-2",
  tool: "Task",
  input: { prompt: "keep active tool visible" }
}, siblingStatusCtx);
const secondTransientSessionThread = { id: "T-amp-status-session-start-2" };
await handlers.get("session.start")(
  { thread: secondTransientSessionThread },
  { thread: secondTransientSessionThread }
);
if (statusCalls().at(-1)?.args[2] !== "subagent") {
  throw new Error(
    `an idle session hid an active sibling tool: ${
      JSON.stringify(statusCalls().at(-1))
    }`
  );
}
await handlers.get("tool.result")({
  thread: siblingStatusThread,
  toolUseID: "tool-status-sibling-2",
  tool: "Task",
  status: "done",
  output: "second sibling work finished"
}, siblingStatusCtx);
const discardedAttentionThread = makeThread(
  "T-amp-discarded-attention",
  "running"
);
const discardedAttentionCtx = { thread: discardedAttentionThread };
await handlers.get("agent.start")({
  thread: discardedAttentionThread,
  message: "discard an in-flight approval",
  id: "msg-discarded-attention"
}, discardedAttentionCtx);
globalThis.__cmuxAmpHangNextBegin = true;
const discardedBeginCount = attentionCalls("begin").length;
discardedAttentionThread.setState("awaiting-approval");
await waitFor(
  () => attentionCalls("begin").length === discardedBeginCount + 1,
  "Amp did not start the approval that will be discarded"
);
const discardedBeginCall = attentionCalls("begin").at(-1);
await handlers.get("session.start")(
  { thread: discardedAttentionThread },
  discardedAttentionCtx
);
await dispatchControlledTimersOrFail(2_000);
await waitFor(
  () => discardedBeginCall.killedWith === "SIGKILL",
  "Amp did not finish the abandoned approval subprocess deadline"
);
const postDiscardThread = makeThread(
  "T-amp-post-discard-status",
  "running"
);
const postDiscardCtx = { thread: postDiscardThread };
await handlers.get("agent.start")({
  thread: postDiscardThread,
  message: "publish after discarded attention",
  id: "msg-post-discard-status"
}, postDiscardCtx);
await handlers.get("tool.call")({
  thread: postDiscardThread,
  toolUseID: "tool-post-discard-status",
  tool: "Task",
  input: { prompt: "prove aggregate status ownership was released" }
}, postDiscardCtx);
if (statusCalls().at(-1)?.args[2] !== "subagent") {
  throw new Error(
    `discarded Amp attention kept shared status ownership: ${
      JSON.stringify(statusCalls().at(-1))
    }`
  );
}
await handlers.get("tool.result")({
  thread: postDiscardThread,
  toolUseID: "tool-post-discard-status",
  tool: "Task",
  status: "done",
  output: "post-discard proof complete"
}, postDiscardCtx);
await handlers.get("agent.end")({
  thread: postDiscardThread,
  message: "post-discard proof complete",
  id: "msg-post-discard-status",
  status: "done",
  messages: []
}, postDiscardCtx);
postDiscardThread.setState("idle");
for (const [statusThread, statusCtx, messageId] of [
  [approvalStatusThread, approvalStatusCtx, "msg-status-approval"],
  [siblingStatusThread, siblingStatusCtx, "msg-status-sibling"]
]) {
  await handlers.get("agent.end")({
    thread: statusThread,
    message: "aggregate status complete",
    id: messageId,
    status: "done",
    messages: []
  }, statusCtx);
  statusThread.setState("idle");
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
  thread: otherThread,
  message: "other work",
  id: "msg-other",
  status: "done",
  messages: []
}, otherCtx);
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
  toolUseID: "tool-main",
  tool: "Task",
  status: "done",
  output: "background work finished"
}, ctx);
if (stopCalls().length !== completionCount + 1) {
  throw new Error("another thread's tool result settled the pending turn");
}
await handlers.get("tool.result")({
  thread: otherThread,
  toolUseID: "tool-other",
  tool: "Task",
  status: "done",
  output: "unrelated work finished"
}, otherCtx);
if (stopCalls().length !== completionCount + 2) {
  throw new Error(
    "a settled Amp sibling was retained behind another active thread"
  );
}
const siblingSettlement = JSON.parse(stopCalls().at(-1).stdin);
if (
  siblingSettlement.cmux_turn_boundary !== "settled" ||
  siblingSettlement.cmux_active_background_work_count !== 0 ||
  siblingSettlement.cmux_active_sibling_turn_count !== 1 ||
  siblingSettlement.turn_id !== provisional.turn_id ||
  siblingSettlement.session_id !== "T-amp-other-thread"
) {
  throw new Error(
    `Amp did not settle the exact sibling while preserving aggregate work: ${
      JSON.stringify(siblingSettlement)
    }`
  );
}
const finalCompletionCount = stopCalls().length;
await handlers.get("agent.end")({
  thread,
  message: "delegate",
  id: "msg-1",
  status: "done",
  messages: []
}, ctx);
if (stopCalls().length !== finalCompletionCount + 1) {
  throw new Error(
    "draining structured tools settled before Amp's native thread became idle"
  );
}
const finalProvisional = JSON.parse(stopCalls().at(-1).stdin);
if (
  finalProvisional.cmux_turn_boundary !== "turn_end" ||
  finalProvisional.cmux_active_background_work_count !== 0 ||
  finalProvisional.turn_id === provisional.turn_id
) {
  throw new Error(
    `the remaining thread did not retain its own provisional identity: ${
      JSON.stringify(finalProvisional)
    }`
  );
}
thread.setState("idle");
await waitFor(
  () => stopCalls().length === finalCompletionCount + 2,
  "Amp did not settle the final thread after every thread drained"
);
const finalSettlement = JSON.parse(stopCalls().at(-1).stdin);
if (
  finalSettlement.cmux_turn_boundary !== "settled" ||
  finalSettlement.cmux_active_background_work_count !== 0 ||
  finalSettlement.cmux_active_sibling_turn_count !== 0 ||
  finalSettlement.turn_id !== finalProvisional.turn_id ||
  finalSettlement.session_id !== "T-amp-settlement-test"
) {
  throw new Error(
    `Amp did not publish the final thread's exact settlement: ${
      JSON.stringify(finalSettlement)
    }`
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
for (const failure of ["get", "subscribe"]) {
  const failedNativeThread = makeThread(
    `T-amp-native-state-failure-${failure}`,
    "running",
    false,
    { get: failure === "get", subscribe: failure === "subscribe" },
  );
  const failedNativeCtx = { thread: failedNativeThread };
  await handlers.get("agent.start")({
    thread: failedNativeThread,
    message: `native state ${failure} failure`,
    id: `msg-failure-${failure}`
  }, failedNativeCtx);
  const beforeFailedNativeEnd = stopCalls().length;
  await handlers.get("agent.end")({
    thread: failedNativeThread,
    message: `native state ${failure} failure`,
    id: `msg-failure-${failure}`,
    status: "done",
    messages: []
  }, failedNativeCtx);
  if (stopCalls().length !== beforeFailedNativeEnd + 1) {
    throw new Error(
      `Amp native-state ${failure} failure wedged the pending turn`
    );
  }
  const failedNativeSettlement = JSON.parse(stopCalls().at(-1).stdin);
  if (failedNativeSettlement.cmux_turn_boundary !== "settled") {
    throw new Error(
      `Amp native-state ${failure} failure did not use structured fallback`
    );
  }
  if (failedNativeThread.observerCount() !== 0) {
    throw new Error(
      `Amp native-state ${failure} failure retained a failed observer`
    );
  }
}
try {
  const hangingThread = makeThread(
    "T-amp-native-state-hang",
    "running",
    true
  );
  const hangingCtx = { thread: hangingThread };
  const hangingStart = handlers.get("agent.start")({
    thread: hangingThread,
    message: "native state never resolves",
    id: "msg-hang"
  }, hangingCtx);
  await dispatchControlledTimersOrFail(1_000);
  await hangingStart;

  const beforeHangingEnd = stopCalls().length;
  const hangingEnd = handlers.get("agent.end")({
    thread: hangingThread,
    message: "native state never resolves",
    id: "msg-hang",
    status: "done",
    messages: []
  }, hangingCtx);
  await hangingEnd;
  if (stopCalls().length !== beforeHangingEnd + 2) {
    throw new Error(
      "the hanging native state did not fall back after its snapshot deadline"
    );
  }
  const hangingSettlement = JSON.parse(stopCalls().at(-1).stdin);
  if (hangingSettlement.cmux_turn_boundary !== "settled") {
    throw new Error(
      `Amp snapshot timeout did not publish settlement: ${
        JSON.stringify(hangingSettlement)
      }`
    );
  }
  if (hangingThread.observerCount() !== 0) {
    throw new Error("a settled native-state observer was not released");
  }

  const approvalLeaseThread = makeThread(
    "T-amp-native-approval-lease",
    "running"
  );
  const approvalLeaseCtx = { thread: approvalLeaseThread };
  await handlers.get("agent.start")({
    thread: approvalLeaseThread,
    message: "wait for durable approval",
    id: "msg-approval-lease"
  }, approvalLeaseCtx);
  const approvalBeginCount = attentionCalls("begin").length;
  approvalLeaseThread.setState("awaiting-approval");
  await waitFor(
    () => attentionCalls("begin").length === approvalBeginCount + 1
      && attentionCalls("begin").at(-1).closedWith === 0,
    "Amp did not publish the lease-retention approval"
  );
  const approvalEndCount = attentionCalls("end").length;
  await dispatchControlledTimers(30 * 60 * 1_000);
  if (approvalLeaseThread.observerCount() !== 1) {
    throw new Error("a confirmed approval expired on the observation lease");
  }
  if (attentionCalls("end").length !== approvalEndCount) {
    throw new Error("the observation lease cleared a confirmed approval");
  }
  approvalLeaseThread.setState("running");
  await waitFor(
    () => attentionCalls("end").length === approvalEndCount + 1,
    "Amp did not start the lease-retention approval conclusion"
  );
  await dispatchControlledTimersOrFail(2_000);
  await waitFor(
    () => attentionCalls("end").length === approvalEndCount + 2
      && attentionCalls("end").at(-1).closedWith === 0,
    "Amp did not conclude the lease-retention approval from native state"
  );
  const beforeApprovalLeaseEnd = stopCalls().length;
  await handlers.get("agent.end")({
    thread: approvalLeaseThread,
    message: "wait for durable approval",
    id: "msg-approval-lease",
    status: "done",
    messages: []
  }, approvalLeaseCtx);
  approvalLeaseThread.setState("idle");
  await waitFor(
    () => stopCalls().length === beforeApprovalLeaseEnd + 2,
    "the approval-retention turn did not settle normally"
  );

  const maximumRetainedTurnStateCount = 128;
  const boundedThreads = [];
  for (let index = 0; index <= maximumRetainedTurnStateCount; index += 1) {
    const boundedThread = makeThread(
      `T-amp-bounded-pending-${index}`,
      "running",
      true
    );
    const boundedCtx = { thread: boundedThread };
    const boundedStart = handlers.get("agent.start")({
      thread: boundedThread,
      message: "bounded pending native state",
      id: `msg-bounded-${index}`
    }, boundedCtx);
    await dispatchControlledTimersOrFail(1_000);
    await boundedStart;
    await handlers.get("agent.end")({
      thread: boundedThread,
      message: "bounded pending native state",
      id: `msg-bounded-${index}`,
      status: "done",
      messages: []
    }, boundedCtx);
    boundedThreads.push(boundedThread);
  }
  const retainedObserverCount = boundedThreads.reduce(
    (count, boundedThread) => count + boundedThread.observerCount(),
    0
  );
  if (retainedObserverCount !== maximumRetainedTurnStateCount) {
    throw new Error(
      `Amp retained ${retainedObserverCount} silent pending observers; `
      + `expected ${maximumRetainedTurnStateCount}`
    );
  }
  if (boundedThreads[0].observerCount() !== 0) {
    throw new Error("Amp did not evict the least-recent silent pending turn");
  }
  if (boundedThreads.at(-1).observerCount() !== 1) {
    throw new Error("Amp evicted the most recent silent pending turn");
  }
  const beforeEvictedIdle = stopCalls().length;
  boundedThreads[0].setState("idle");
  if (stopCalls().length !== beforeEvictedIdle) {
    throw new Error("an evicted Amp turn retained settlement ownership");
  }
  // A late agent.end must not recreate an empty state for the evicted turn.
  // Resolve the old deferred snapshot to idle so an unsafely recreated state
  // would settle immediately and make the regression deterministic.
  boundedThreads[0].resolveInitialGet("idle");
  const beforeEvictedEnd = stopCalls().length;
  await handlers.get("agent.end")({
    thread: boundedThreads[0],
    message: "bounded pending native state",
    id: "msg-bounded-0",
    status: "done",
    messages: []
  }, { thread: boundedThreads[0] });
  const evictedEndSettlements = stopCalls()
    .slice(beforeEvictedEnd)
    .map((call) => JSON.parse(call.stdin))
    .filter((payload) => payload.cmux_turn_boundary === "settled");
  if (evictedEndSettlements.length !== 0) {
    throw new Error(
      `an evicted Amp turn was recreated and settled: ${JSON.stringify(evictedEndSettlements)}`
    );
  }
  const beforeRetainedIdle = stopCalls().length;
  boundedThreads.at(-1).setState("idle");
  await waitFor(
    () => stopCalls().length === beforeRetainedIdle + 1,
    "the most recent bounded Amp turn lost settlement ownership"
  );
  const retainedSettlement = JSON.parse(stopCalls().at(-1).stdin);
  if (
    retainedSettlement.cmux_active_sibling_turn_count
      !== maximumRetainedTurnStateCount
  ) {
    throw new Error(
      `Amp settlement dropped the evicted sibling from its conservative count: ${
        JSON.stringify(retainedSettlement)
      }`
    );
  }

  // Fill the bounded tombstone table and exercise its overflow recovery. A
  // later authoritative session.start must make that one owner eligible
  // again; a process-wide latch that never recovers would drop its turn.
  for (let index = 0; index < 128; index += 1) {
    const latchThread = makeThread(
      `T-amp-overflow-latch-${index}`,
      "running"
    );
    const latchCtx = { thread: latchThread };
    await handlers.get("agent.start")({
      thread: latchThread,
      message: "fill bounded Amp overflow tombstones",
      id: `msg-overflow-latch-${index}`
    }, latchCtx);
    await handlers.get("agent.end")({
      thread: latchThread,
      message: "fill bounded Amp overflow tombstones",
      id: `msg-overflow-latch-${index}`,
      status: "done",
      messages: []
    }, latchCtx);
  }
  const recoveryThread = makeThread(
    "T-amp-overflow-recovery",
    "running"
  );
  const recoveryCtx = { thread: recoveryThread };
  await handlers.get("session.start")(
    { thread: recoveryThread },
    recoveryCtx
  );
  await handlers.get("agent.start")({
    thread: recoveryThread,
    message: "recover after bounded Amp overflow",
    id: "msg-overflow-recovery"
  }, recoveryCtx);
  const beforeRecoveryEnd = stopCalls().length;
  await handlers.get("agent.end")({
    thread: recoveryThread,
    message: "recover after bounded Amp overflow",
    id: "msg-overflow-recovery",
    status: "done",
    messages: []
  }, recoveryCtx);
  recoveryThread.setState("idle");
  await waitFor(
    () => stopCalls().length === beforeRecoveryEnd + 2,
    "authoritative Amp session cleanup did not recover overflowed turn tracking"
  );

  const overflowThread = makeThread(
    "T-amp-active-tool-overflow",
    "running"
  );
  const overflowCtx = { thread: overflowThread };
  await handlers.get("agent.start")({
    thread: overflowThread,
    message: "retain bounded active tools",
    id: "msg-active-tool-overflow"
  }, overflowCtx);
  const maximumRetainedActiveToolsPerTurn = 128;
  for (
    let index = 0;
    index <= maximumRetainedActiveToolsPerTurn;
    index += 1
  ) {
    await handlers.get("tool.call")({
      thread: overflowThread,
      toolUseID: `tool-overflow-${index}`,
      tool: "Task",
      input: { prompt: `bounded tool ${index}` }
    }, overflowCtx);
  }
  const beforeOverflowEnd = stopCalls().length;
  await handlers.get("agent.end")({
    thread: overflowThread,
    message: "retain bounded active tools",
    id: "msg-active-tool-overflow",
    status: "done",
    messages: []
  }, overflowCtx);
  const overflowProvisional = JSON.parse(stopCalls().at(-1).stdin);
  if (
    stopCalls().length !== beforeOverflowEnd + 1
    || overflowProvisional.cmux_active_background_work_count
      !== maximumRetainedActiveToolsPerTurn + 1
  ) {
    throw new Error(
      `Amp did not latch active-tool overflow: ${
        JSON.stringify(overflowProvisional)
      }`
    );
  }
  for (
    let index = 0;
    index <= maximumRetainedActiveToolsPerTurn;
    index += 1
  ) {
    await handlers.get("tool.result")({
      thread: overflowThread,
      toolUseID: `tool-overflow-${index}`,
      tool: "Task",
      status: "done",
      output: "done"
    }, overflowCtx);
  }
  if (stopCalls().length !== beforeOverflowEnd + 1) {
    throw new Error("retained tool results cleared an unproven overflow latch");
  }
  overflowThread.setState("idle");
  await waitFor(
    () => stopCalls().length === beforeOverflowEnd + 2,
    "terminal Amp native state did not clear active-tool overflow"
  );

  const failedConclusionThread = makeThread(
    "T-amp-failed-attention-conclusion",
    "running"
  );
  const failedConclusionCtx = { thread: failedConclusionThread };
  await handlers.get("agent.start")({
    thread: failedConclusionThread,
    message: "release ownership after failed conclusion",
    id: "msg-failed-attention-conclusion"
  }, failedConclusionCtx);
  const failedConclusionBeginCount = attentionCalls("begin").length;
  failedConclusionThread.setState("awaiting-approval");
  await waitFor(
    () => attentionCalls("begin").length === failedConclusionBeginCount + 1
      && attentionCalls("begin").at(-1).closedWith === 0,
    "Amp did not publish the approval used by the failed-conclusion regression"
  );
  globalThis.__cmuxAmpHangNextEndAttempts = 2;
  const failedConclusionEndCount = attentionCalls("end").length;
  failedConclusionThread.setState("running");
  await waitFor(
    () => attentionCalls("end").length === failedConclusionEndCount + 1,
    "Amp did not start the first failed approval conclusion"
  );
  await dispatchControlledTimersOrFail(2_000);
  await waitFor(
    () => attentionCalls("end").length === failedConclusionEndCount + 2
      && attentionCalls("end").slice(-2).every(
        (call) => call.killedWith === "SIGKILL"
      ),
    "Amp did not exhaust both failed approval conclusion attempts"
  );

  const statusCountAfterFailedConclusion = statusCalls().length;
  const statusProbeThread = makeThread(
    "T-amp-failed-attention-status-probe",
    "running"
  );
  const statusProbeCtx = { thread: statusProbeThread };
  await handlers.get("agent.start")({
    thread: statusProbeThread,
    message: "publish after failed conclusion",
    id: "msg-failed-attention-status-probe"
  }, statusProbeCtx);
  await handlers.get("tool.call")({
    thread: statusProbeThread,
    toolUseID: "tool-failed-attention-status-probe",
    tool: "Task",
    input: { prompt: "prove failed attention released aggregate status" }
  }, statusProbeCtx);
  await waitFor(
    () => statusCalls().length > statusCountAfterFailedConclusion
      && statusCalls().at(-1)?.args[2] === "subagent",
    "failed Amp attention conclusion retained aggregate status ownership"
  );
} finally {
  globalThis.setTimeout = platformSetTimeout;
  globalThis.clearTimeout = platformClearTimeout;
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
                and any(
                    line.startswith("argv=") and line != "argv="
                    for line in env_log.splitlines()
                )
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
        if (
            "kind=amp" not in env_log
            or "cwd=/tmp/amp-project" not in env_log
            or "argv=" not in env_log
            or "workspace_id=55555555-5555-5555-5555-555555555555" not in env_log
        ):
            print(f"FAIL: plugin did not pass launch metadata environment, got {env_log!r}")
            return 1
        if "amp_api_key=secret-should-not-propagate" in env_log:
            print(f"FAIL: plugin propagated AMP_API_KEY into hook subprocess, got {env_log!r}")
            return 1
        if "socket_password=socket-password-should-not-propagate" in env_log:
            print(f"FAIL: plugin propagated CMUX_SOCKET_PASSWORD into child, got {env_log!r}")
            return 1
        if "socket_capability=socket-capability-should-not-propagate" in env_log:
            print(f"FAIL: plugin propagated CMUX_SOCKET_CAPABILITY into child, got {env_log!r}")
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
