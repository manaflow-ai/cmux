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


def read_json_records(path: Path) -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    for chunk in read_text(path).split("\n---\n"):
        chunk = chunk.strip()
        if not chunk:
            continue
        try:
            value = json.loads(chunk)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            records.append(value)
    return records


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

    with tempfile.TemporaryDirectory(
        prefix="cmux-amp-extension-",
        ignore_cleanup_errors=True,
    ) as td:
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
            timeout=35,
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
        installed_stat = extension_path.stat()
        refresh = subprocess.run(
            [cli_path, "hooks", "amp", "install", "--yes"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=20,
        )
        refreshed_stat = extension_path.stat()
        if refresh.returncode != 0:
            print("FAIL: idempotent Amp plugin refresh failed")
            print(f"exit={refresh.returncode}")
            print(f"stdout={refresh.stdout.strip()}")
            print(f"stderr={refresh.stderr.strip()}")
            return 1
        if (
            refreshed_stat.st_ino != installed_stat.st_ino
            or refreshed_stat.st_mtime_ns != installed_stat.st_mtime_ns
            or extension_path.read_text(encoding="utf-8") != extension_text
        ):
            print("FAIL: idempotent Amp plugin refresh rewrote the managed extension")
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
            """#!/usr/bin/perl
use Fcntl qw(:flock);

sub append {
    my ($path, $value) = @_;
    open my $handle, ">>", $path or die $!;
    flock($handle, LOCK_EX) or die $!;
    print {$handle} $value;
    close $handle;
}

my $stdin = do { local $/; <STDIN> // "" };
append($ENV{"FAKE_CMUX_ARGS_LOG"}, join(" ", @ARGV) . "\\n");
append($ENV{"FAKE_CMUX_STDIN_LOG"}, $stdin . "\\n---\\n");
append($ENV{"FAKE_CMUX_ENV_LOG"}, sprintf(
    "kind=%s\\ncwd=%s\\nargv=%s\\namp_api_key=%s\\n",
    $ENV{"CMUX_AGENT_LAUNCH_KIND"} // "",
    $ENV{"CMUX_AGENT_LAUNCH_CWD"} // "",
    $ENV{"CMUX_AGENT_LAUNCH_ARGV_B64"} // "",
    $ENV{"AMP_API_KEY"} // "",
));
""",
        )

        check_env = env.copy()
        check_env["CMUX_TEST_AMP_EXTENSION_PATH"] = str(extension_path)
        check_env["CMUX_SURFACE_ID"] = "surface-amp-test"
        check_env["CMUX_WORKSPACE_ID"] = "workspace-amp-test"
        invalid_cmux_override = root / "cmux-directory"
        invalid_cmux_override.mkdir()
        check_env["CMUX_AMP_CMUX_BIN"] = str(invalid_cmux_override)
        check_env["CMUX_BUNDLED_CLI_PATH"] = str(fake_cmux)
        check_env["AMP_API_KEY"] = "secret-should-not-propagate"
        check_env["FAKE_CMUX_ARGS_LOG"] = str(fake_args_log)
        check_env["FAKE_CMUX_STDIN_LOG"] = str(fake_stdin_log)
        check_env["FAKE_CMUX_ENV_LOG"] = str(fake_env_log)
        check_env["PWD"] = "/tmp/amp-project"
        check_env["PATH"] = f"{fake_bin}{os.pathsep}{env.get('PATH', '')}"
        for key in (
            "CMUX_AMP_HOOKS_DISABLED",
            "CMUX_AGENT_LAUNCH_KIND",
            "CMUX_AGENT_LAUNCH_EXECUTABLE",
            "CMUX_AGENT_LAUNCH_ARGV_B64",
            "CMUX_AGENT_LAUNCH_CWD",
        ):
            check_env.pop(key, None)
        check_source = """
import * as fs from "node:fs";
const extensionPath = process.env.CMUX_TEST_AMP_EXTENSION_PATH;
const mod = await import(extensionPath);
if (typeof mod.default !== "function") throw new Error("missing default export");
const handlers = new Map();
const POLL_ATTEMPTS = 500;
let stateSubscriber = null;
let titleSubscriber = null;
let unsubscribeCount = 0;
let currentState = "idle";
let titleGetter = async () => "Initial Amp title";
const thread = {
  id: "T-amp-session-test",
  state: {
    get: async () => currentState,
    subscribe(cb) {
      stateSubscriber = cb;
      return { unsubscribe() { unsubscribeCount += 1; } };
    }
  },
  title: {
    get: () => titleGetter(),
    subscribe(cb) {
      titleSubscriber = cb;
      return { unsubscribe() { unsubscribeCount += 1; } };
    }
  }
};
let secondStateSubscriber = null;
let secondState = "idle";
const secondThread = {
  id: "T-amp-session-second",
  state: {
    get: async () => secondState,
    subscribe(cb) {
      secondStateSubscriber = cb;
      return { unsubscribe() { unsubscribeCount += 1; } };
    }
  },
  title: {
    get: async () => "Second Amp title",
    subscribe() { return { unsubscribe() { unsubscribeCount += 1; } }; }
  }
};
let thirdStateSubscriber = null;
let thirdState = "idle";
const thirdThread = {
  id: "T-amp-session-third",
  state: {
    get: async () => thirdState,
    subscribe(cb) {
      thirdStateSubscriber = cb;
      return { unsubscribe() { unsubscribeCount += 1; } };
    }
  },
  title: {
    get: async () => "Third Amp title",
    subscribe() { return { unsubscribe() { unsubscribeCount += 1; } }; }
  }
};
const legacyThread = {
  id: "T-amp-session-legacy",
  title: {
    get: async () => "Legacy Amp title",
    subscribe() { return { unsubscribe() { unsubscribeCount += 1; } }; }
  }
};
let activeThreadSubscriber = null;
const activeThread = {
  current: thread,
  subscribe(cb) {
    activeThreadSubscriber = cb;
    return { unsubscribe() { unsubscribeCount += 1; } };
  }
};
mod.default({
  on(name, handler) {
    handlers.set(name, handler);
  },
  thread,
  activeThread
});
if (typeof stateSubscriber !== "function" || typeof titleSubscriber !== "function") {
  throw new Error("initial active thread was not reconciled at plugin startup");
}
for (const name of ["session.start", "agent.start", "tool.call", "agent.end"]) {
  if (typeof handlers.get(name) !== "function") throw new Error(`missing ${name}`);
}
function selectThread(nextThread) {
  activeThread.current = nextThread;
  activeThreadSubscriber(nextThread);
}
function statusCount(fragment) {
  const text = fs.existsSync(process.env.FAKE_CMUX_ARGS_LOG)
    ? fs.readFileSync(process.env.FAKE_CMUX_ARGS_LOG, "utf8")
    : "";
  return text.split("\\n").filter((line) => line.startsWith("set-status amp ") && line.includes(fragment)).length;
}
async function waitForProjectedStatus(fragment, minimumCount) {
  for (let attempt = 0; attempt < POLL_ATTEMPTS; attempt += 1) {
    if (statusCount(fragment) >= minimumCount) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`Amp status count did not reach ${minimumCount} for ${fragment}`);
}
function commandCount(fragment) {
  const text = fs.existsSync(process.env.FAKE_CMUX_ARGS_LOG)
    ? fs.readFileSync(process.env.FAKE_CMUX_ARGS_LOG, "utf8")
    : "";
  return text.split("\\n").filter((line) => line.includes(fragment)).length;
}
async function waitForCommandCount(fragment, minimumCount) {
  for (let attempt = 0; attempt < POLL_ATTEMPTS; attempt += 1) {
    if (commandCount(fragment) >= minimumCount) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`cmux command count did not reach ${minimumCount} for ${fragment}`);
}
async function waitForInputFragment(fragment) {
  for (let attempt = 0; attempt < POLL_ATTEMPTS; attempt += 1) {
    const text = fs.existsSync(process.env.FAKE_CMUX_STDIN_LOG)
      ? fs.readFileSync(process.env.FAKE_CMUX_STDIN_LOG, "utf8")
      : "";
    if (text.includes(fragment)) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`cmux hook input did not contain ${fragment}`);
}
async function waitForLifecycle(sessionId) {
  for (let attempt = 0; attempt < POLL_ATTEMPTS; attempt += 1) {
    const text = fs.existsSync(process.env.FAKE_CMUX_STDIN_LOG)
      ? fs.readFileSync(process.env.FAKE_CMUX_STDIN_LOG, "utf8")
      : "";
    const found = text.split("\\n---\\n").some((chunk) => {
      try {
        const payload = JSON.parse(chunk);
        return payload.session_id === sessionId && payload.hook_event_name === "Lifecycle";
      } catch (_) {
        return false;
      }
    });
    if (found) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`cmux lifecycle input did not contain ${sessionId}`);
}
function readJsonRecords() {
  const text = fs.existsSync(process.env.FAKE_CMUX_STDIN_LOG)
    ? fs.readFileSync(process.env.FAKE_CMUX_STDIN_LOG, "utf8")
    : "";
  return text.split("\\n---\\n").flatMap((chunk) => {
    try {
      const payload = JSON.parse(chunk);
      return payload && typeof payload === "object" ? [payload] : [];
    } catch (_) {
      return [];
    }
  });
}
function lifecycleStateCount(sessionId, state) {
  return readJsonRecords().filter((payload) =>
    payload.session_id === sessionId
      && payload.hook_event_name === "Lifecycle"
      && payload.agent_state === state
  ).length;
}
async function waitForLifecycleState(sessionId, state, minimumCount) {
  for (let attempt = 0; attempt < POLL_ATTEMPTS; attempt += 1) {
    if (lifecycleStateCount(sessionId, state) >= minimumCount) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`cmux lifecycle state count did not reach ${minimumCount} for ${sessionId}/${state}`);
}
function projectedStatusCount() {
  const text = fs.existsSync(process.env.FAKE_CMUX_ARGS_LOG)
    ? fs.readFileSync(process.env.FAKE_CMUX_ARGS_LOG, "utf8")
    : "";
  return text.split("\\n").filter((line) => line.startsWith("set-status amp ")).length;
}
process.argv.splice(
  0,
  process.argv.length,
  "/usr/local/bin/node",
  "/Users/example/node_modules/@ampcode/amp/dist/cli.js",
  "--mode",
  "geppetto"
);
const ctx = { thread };
await handlers.get("session.start")({ thread }, ctx);
if (typeof stateSubscriber !== "function") throw new Error("missing thread.state subscription");
if (typeof activeThreadSubscriber !== "function") throw new Error("missing activeThread subscription");
let resolveStaleTitle = null;
titleGetter = () => new Promise((resolve) => { resolveStaleTitle = resolve; });
await handlers.get("agent.start")({ thread, message: "hello amp", id: "msg-user-1" }, ctx);
currentState = "running";
await stateSubscriber(currentState);
if (typeof titleSubscriber === "function") titleSubscriber("Updated Amp title");
if (typeof resolveStaleTitle !== "function") throw new Error("missing deferred title lookup");
resolveStaleTitle("Stale Amp title");
await handlers.get("agent.end")({ thread, message: "hello amp", id: "msg-user-1", status: "done", messages: [] }, ctx);
currentState = "awaiting-approval";
await stateSubscriber(currentState);
currentState = "idle";
await stateSubscriber(currentState);

titleGetter = async () => "Updated Amp title";
await handlers.get("agent.start")({ thread, message: "settle first", id: "msg-user-2" }, ctx);
currentState = "running";
await stateSubscriber(currentState);
currentState = "idle";
await stateSubscriber(currentState);
await handlers.get("agent.end")({ thread, message: "settle first", id: "msg-user-2", status: "done", messages: [] }, ctx);

await handlers.get("agent.start")({ thread, message: "fail now", id: "msg-user-3" }, ctx);
currentState = "running";
await stateSubscriber(currentState);
await handlers.get("agent.end")({ thread, message: "fail now", id: "msg-user-3", status: "error", messages: [] }, ctx);
currentState = "error";
await stateSubscriber(currentState);

await handlers.get("agent.start")({ thread, message: "idle error", id: "msg-user-4" }, ctx);
currentState = "running";
await stateSubscriber(currentState);
await handlers.get("agent.end")({ thread, message: "idle error", id: "msg-user-4", status: "error", messages: [] }, ctx);
currentState = "idle";
await stateSubscriber(currentState);

await handlers.get("session.start")({ thread: secondThread }, { thread: secondThread });
await handlers.get("session.start")({ thread: thirdThread }, { thread: thirdThread });
if (typeof secondStateSubscriber !== "function" || typeof thirdStateSubscriber !== "function") {
  throw new Error("missing per-thread state subscriptions");
}
await handlers.get("agent.start")(
  { thread: secondThread, message: "finish second", id: "turn-second" },
  { thread: secondThread }
);
secondState = "running";
await secondStateSubscriber(secondState);
await handlers.get("tool.call")({
  thread: secondThread,
  tool: "Bash",
  input: { command: "echo second" }
});
const runningStatusFragment = "running --icon terminal --color #ffd700";
const runningStatusCount = statusCount(runningStatusFragment);
selectThread(secondThread);
await waitForProjectedStatus(runningStatusFragment, runningStatusCount + 1);
selectThread(thread);
secondState = "awaiting-approval";
await secondStateSubscriber(secondState);
const needsInputStatusFragment = "needs input --icon bell.fill --color #4C8DFF";
const needsInputStatusCount = statusCount(needsInputStatusFragment);
selectThread(secondThread);
await waitForProjectedStatus(needsInputStatusFragment, needsInputStatusCount + 1);
secondState = "running";
await secondStateSubscriber(secondState);
await handlers.get("agent.start")(
  { thread: thirdThread, message: "fail third", id: "turn-third" },
  { thread: thirdThread }
);
thirdState = "running";
await thirdStateSubscriber(thirdState);
await handlers.get("agent.end")({
  thread: secondThread,
  id: "turn-second",
  status: "done",
  messages: [{
    role: "assistant",
    content: [{ type: "text", text: "Second thread completed" }]
  }]
}, { thread: secondThread });
secondState = "idle";
await secondStateSubscriber(secondState);
selectThread(thread);

// Amp can begin another turn through a thread-state transition without
// emitting a second agent.start event. That transition must re-arm terminal
// delivery so the follow-up completion is not swallowed by the prior turn.
secondState = "running";
await secondStateSubscriber(secondState);
await handlers.get("agent.end")({
  thread: secondThread,
  id: "turn-second-follow-up",
  status: "done",
  messages: [{
    role: "assistant",
    content: [{ type: "text", text: "Second thread follow-up completed" }]
  }]
}, { thread: secondThread });
secondState = "idle";
await secondStateSubscriber(secondState);

await handlers.get("agent.end")({
  thread: thirdThread,
  id: "turn-third",
  status: "error",
  messages: [{
    role: "assistant",
    content: [{ type: "text", text: "Third thread failed" }]
  }]
}, { thread: thirdThread });
thirdState = "error";
await thirdStateSubscriber(thirdState);
const errorStatusFragment = "error --icon xmark.circle --color #ff5555";
const errorStatusCount = statusCount(errorStatusFragment);
selectThread(thirdThread);
await waitForProjectedStatus(errorStatusFragment, errorStatusCount + 1);
const clearCountBeforeNoActiveThread = commandCount("clear-status amp");
selectThread(null);
await waitForCommandCount("clear-status amp", clearCountBeforeNoActiveThread + 1);
secondState = "running";
await secondStateSubscriber(secondState);
const activeStatusMarker = "set-status amp error --icon xmark.circle --color #ff5555";
const activeStatusCount = commandCount(activeStatusMarker);
selectThread(thirdThread);
await waitForCommandCount(activeStatusMarker, activeStatusCount + 1);
if (statusCount(activeStatusMarker) !== activeStatusCount + 1) {
  throw new Error("a background Amp thread repainted status with no active thread");
}

// A get-only state observable can answer out of order. Only the newest read
// may reconcile the thread, otherwise a stale idle result can erase a live turn.
let readOnlyResolvers = [];
const readOnlyThread = {
  id: "T-amp-read-only",
  state: {
    get: () => new Promise((resolve) => readOnlyResolvers.push(resolve)),
  },
  title: {
    get: async () => "Read-only Amp title",
    subscribe() { return { unsubscribe() {} }; },
  },
};
await handlers.get("session.start")({ thread: readOnlyThread }, { thread: readOnlyThread });
await handlers.get("agent.start")(
  { thread: readOnlyThread, message: "read-only turn", id: "turn-read-only" },
  { thread: readOnlyThread }
);
if (readOnlyResolvers.length !== 2) {
  throw new Error(`expected two overlapping get-only state reads, got ${readOnlyResolvers.length}`);
}
const staleRead = readOnlyResolvers.shift();
const newestRead = readOnlyResolvers.shift();
newestRead("running");
await waitForLifecycleState("T-amp-read-only", "running", 1);
staleRead("idle");
await handlers.get("agent.start")(
  { thread: readOnlyThread, message: "read-only follow-up", id: "turn-read-only-follow-up" },
  { thread: readOnlyThread }
);
if (readOnlyResolvers.length !== 1) {
  throw new Error(`expected one follow-up get-only state read, got ${readOnlyResolvers.length}`);
}
readOnlyResolvers.shift()("running");
await waitForLifecycleState("T-amp-read-only", "running", 2);
if (lifecycleStateCount("T-amp-read-only", "idle") !== 0) {
  throw new Error("an out-of-order get-only state read reconciled stale idle state");
}

// A long-lived Amp process must not retain every completed thread forever.
const previousHooksDisabled = process.env.CMUX_AMP_HOOKS_DISABLED;
process.env.CMUX_AMP_HOOKS_DISABLED = "1";
let resumableStateSubscriber = null;
let resumableStateUnsubscribed = false;
const resumableThread = {
  id: "T-amp-resumable",
  state: {
    get: async () => "idle",
    subscribe(cb) {
      resumableStateSubscriber = cb;
      return { unsubscribe() { resumableStateUnsubscribed = true; } };
    },
  },
  title: {
    get: async () => "Resumable Amp title",
    subscribe() { return { unsubscribe() {} }; },
  },
};
await handlers.get("session.start")({ thread: resumableThread }, { thread: resumableThread });
for (let index = 0; index < 132; index += 1) {
  const boundedThread = {
    id: `T-amp-bounded-${index}`,
    state: {
      get: async () => "idle",
      subscribe() {
        return { unsubscribe() { unsubscribeCount += 1; } };
      },
    },
    title: {
      get: async () => `Bounded Amp title ${index}`,
      subscribe() {
        return { unsubscribe() { unsubscribeCount += 1; } };
      },
    },
  };
  await handlers.get("session.start")({ thread: boundedThread }, { thread: boundedThread });
}
if (previousHooksDisabled === undefined) delete process.env.CMUX_AMP_HOOKS_DISABLED;
else process.env.CMUX_AMP_HOOKS_DISABLED = previousHooksDisabled;
if (unsubscribeCount === 0) throw new Error("Amp thread subscriptions were never evicted");
if (typeof resumableStateSubscriber !== "function" || resumableStateUnsubscribed) {
  throw new Error("Amp evicted the state observer needed for a follow-up turn");
}
await resumableStateSubscriber("running");

process.argv.splice(
  0,
  process.argv.length,
  "/Users/example/custom-amp-launcher",
  "--mode",
  "fallback"
);
await handlers.get("session.start")({ thread: legacyThread }, { thread: legacyThread });
await handlers.get("agent.start")(
  { thread: legacyThread, message: "legacy finish", id: "turn-legacy" },
  { thread: legacyThread }
);
const legacyEnd = {
  thread: legacyThread,
  id: "turn-legacy",
  status: "done",
  messages: [{
    role: "assistant",
    content: [{ type: "text", text: "Legacy thread completed" }]
  }]
};
await handlers.get("agent.end")(legacyEnd, { thread: legacyThread });
await handlers.get("agent.end")(legacyEnd, { thread: legacyThread });
await waitForInputFragment('"session_id":"T-amp-session-legacy"');
for (const fragment of [
  '"session_id":"T-amp-session-test"',
  '"agent_state":"awaiting-approval"',
  '"agent_state":"error"',
  '"turn_id":"turn-second-follow-up"',
  '"turn_id":"turn-third"',
]) {
  await waitForInputFragment(fragment);
}
for (const sessionId of [
  "T-amp-session-test",
  "T-amp-session-second",
  "T-amp-session-third",
  "T-amp-session-legacy",
]) {
  await waitForLifecycle(sessionId);
}
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
            timeout=35,
        )
        if check.returncode != 0:
            print("FAIL: generated Amp plugin is not importable")
            print(f"exit={check.returncode}")
            print(f"stdout={check.stdout.strip()}")
            print(f"stderr={check.stderr.strip()}")
            return 1

        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            args_log = read_text(fake_args_log)
            stdin_log = read_text(fake_stdin_log)
            env_log = read_text(fake_env_log)
            records = read_json_records(fake_stdin_log)
            lifecycle_records = [
                record for record in records
                if record.get("hook_event_name") == "Lifecycle"
            ]
            primary_states = {
                record.get("agent_state")
                for record in lifecycle_records
                if record.get("session_id") == "T-amp-session-test"
            }
            if (
                "hooks amp session-start" in args_log
                and "hooks amp prompt-submit" in args_log
                and "hooks amp title-update" in args_log
                and "hooks amp lifecycle" in args_log
                and {"running", "awaiting-approval", "idle", "error"}.issubset(primary_states)
                and any(record.get("session_id") == "T-amp-session-second" for record in lifecycle_records)
                and any(record.get("session_id") == "T-amp-session-third" for record in lifecycle_records)
                and any(record.get("session_id") == "T-amp-session-legacy" for record in lifecycle_records)
                and any(record.get("turn_id") == "turn-second-follow-up" for record in lifecycle_records)
                and any(record.get("turn_id") == "turn-third" for record in lifecycle_records)
                and any(record.get("turn_id") == "turn-legacy" for record in lifecycle_records)
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
            "hooks amp title-update",
            "hooks amp lifecycle",
        ]:
            if expected not in args_log:
                print(f"FAIL: plugin did not invoke {expected}, got {args_log!r}")
                return 1
        if '"session_id":"T-amp-session-test"' not in stdin_log:
            print(f"FAIL: plugin did not pass session id, got {stdin_log!r}")
            return 1
        payloads = read_json_records(fake_stdin_log)
        lifecycle = [
            payload for payload in payloads
            if payload.get("hook_event_name") == "Lifecycle"
        ]
        primary_lifecycle = [
            payload for payload in lifecycle
            if payload.get("session_id") == "T-amp-session-test"
        ]
        states = [payload.get("agent_state") for payload in primary_lifecycle]
        for expected_state in ["running", "awaiting-approval", "idle", "error"]:
            if expected_state not in states:
                print(f"FAIL: plugin did not publish authoritative state {expected_state!r}, got {lifecycle!r}")
                return 1
        idle_outcomes = [
            payload.get("turn_outcome") for payload in primary_lifecycle
            if payload.get("agent_state") == "idle" and payload.get("turn_outcome")
        ]
        if sorted(idle_outcomes) != ["done", "done", "error"]:
            print(f"FAIL: idle reconciliation lost the completed turn outcome, got {idle_outcomes!r}")
            return 1
        idle_errors = [
            payload for payload in primary_lifecycle
            if payload.get("agent_state") == "idle" and payload.get("turn_outcome") == "error"
        ]
        if len(idle_errors) != 1 or idle_errors[0].get("notification_type") != "error":
            print(f"FAIL: idle-after-error was not classified as an error, got {idle_errors!r}")
            return 1
        error_outcomes = [
            payload.get("turn_outcome") for payload in primary_lifecycle
            if payload.get("agent_state") == "error"
        ]
        if len(error_outcomes) != 1 or error_outcomes[0] != "error":
            print(f"FAIL: error reconciliation lost the failed turn outcome, got {error_outcomes!r}")
            return 1
        second_completions = [
            payload for payload in lifecycle
            if payload.get("session_id") == "T-amp-session-second"
            and payload.get("agent_state") == "idle"
            and payload.get("turn_outcome") == "done"
        ]
        if len(second_completions) != 2:
            print(f"FAIL: second Amp thread did not re-arm terminal delivery, got {second_completions!r}")
            return 1
        second_by_turn = {payload.get("turn_id"): payload for payload in second_completions}
        if set(second_by_turn) != {"turn-second", "turn-second-follow-up"}:
            print(f"FAIL: second Amp thread lost a turn identity, got {second_completions!r}")
            return 1
        if {
            turn_id: payload.get("last_assistant_message")
            for turn_id, payload in second_by_turn.items()
        } != {
            "turn-second": "Second thread completed",
            "turn-second-follow-up": "Second thread follow-up completed",
        }:
            print(f"FAIL: second Amp thread lost its turn payload, got {second_completions!r}")
            return 1
        third_errors = [
            payload for payload in lifecycle
            if payload.get("session_id") == "T-amp-session-third"
            and payload.get("agent_state") == "error"
            and payload.get("turn_outcome") == "error"
        ]
        if len(third_errors) != 1 or third_errors[0].get("turn_id") != "turn-third":
            print(f"FAIL: third Amp thread did not retain independent error state, got {third_errors!r}")
            return 1
        legacy_completions = [
            payload for payload in lifecycle
            if payload.get("session_id") == "T-amp-session-legacy"
            and payload.get("agent_state") == "idle"
            and payload.get("turn_outcome") == "done"
        ]
        if len(legacy_completions) != 1:
            print(f"FAIL: legacy Amp thread did not emit exactly one completion, got {legacy_completions!r}; lifecycle={lifecycle!r}")
            return 1
        if legacy_completions[0].get("last_assistant_message") != "Legacy thread completed":
            print(f"FAIL: legacy Amp completion lost its assistant message, got {legacy_completions!r}")
            return 1
        title_updates = [
            payload.get("title") for payload in payloads
            if payload.get("hook_event_name") == "TitleUpdate"
            and payload.get("session_id") == "T-amp-session-test"
        ]
        if "Updated Amp title" not in title_updates:
            print(f"FAIL: plugin did not persist the latest Amp title, got {title_updates!r}")
            return 1
        if "Stale Amp title" in title_updates:
            print(f"FAIL: a stale async title lookup overwrote the observed Amp title, got {title_updates!r}")
            return 1
        if "hooks amp stop" in args_log:
            print(f"FAIL: extension bypassed lifecycle reconciliation with a direct stop, got {args_log!r}")
            return 1
        if "kind=amp" not in env_log or f"cwd={root.resolve()}" not in env_log or "argv=" not in env_log:
            print(f"FAIL: plugin did not pass launch metadata environment, got {env_log!r}")
            return 1
        if "amp_api_key=secret-should-not-propagate" in env_log:
            print(f"FAIL: plugin propagated AMP_API_KEY into hook subprocess, got {env_log!r}")
            return 1
        decoded_argv_values = []
        for line in env_log.splitlines():
            if not line.startswith("argv=") or not line[len("argv="):]:
                continue
            try:
                decoded_argv_values.append([
                    value
                    for value in base64.b64decode(line[len("argv="):]).decode("utf-8").split("\0")
                    if value
                ])
            except Exception as exc:
                print(f"FAIL: plugin launch argv was not valid base64 NUL data: {exc}; env={env_log!r}")
                return 1
        expected_argv = [
            str(fake_amp),
            "--mode",
            "geppetto",
        ]
        if expected_argv not in decoded_argv_values:
            print(f"FAIL: plugin captured wrong Amp launch argv; expected {expected_argv!r}, got {decoded_argv_values!r}")
            return 1
        expected_fallback_argv = ["/Users/example/custom-amp-launcher", "--mode", "fallback"]
        if expected_fallback_argv not in decoded_argv_values:
            print(
                "FAIL: plugin dropped unrecognized launch arguments; "
                f"expected {expected_fallback_argv!r}, got {decoded_argv_values!r}"
            )
            return 1

    print("PASS: generated Amp plugin installs and emits cmux hooks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
