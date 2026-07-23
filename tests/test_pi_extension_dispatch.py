#!/usr/bin/env python3
"""Regression coverage for Pi extension dispatch responsiveness and stale surfaces."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from claude_teams_test_utils import install_pi_extension, resolve_cmux_cli


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def run_extension(
    *,
    bun: str,
    root: Path,
    extension_path: Path,
    fake_cmux: Path,
    source: str,
    extra_env: dict[str, str],
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.update(extra_env)
    env["CMUX_TEST_PI_EXTENSION_PATH"] = str(extension_path)
    env["CMUX_PI_CMUX_BIN"] = str(fake_cmux)
    env["CMUX_SURFACE_ID"] = "00000000-0000-0000-0000-000000008672"
    env["CMUX_WORKSPACE_ID"] = "00000000-0000-0000-0000-000000008673"
    return subprocess.run(
        [bun, "--eval", source],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=20,
    )


def main() -> int:
    bun = shutil.which("bun")
    if bun is None:
        print("SKIP: bun not found")
        return 0

    try:
        cli_path = resolve_cmux_cli()
    except RuntimeError as exc:
        print(f"FAIL: {exc}")
        return 1

    del cli_path
    with tempfile.TemporaryDirectory(prefix="cmux-pi-dispatch-") as td:
        root = Path(td)
        try:
            extension_path = install_pi_extension(root / "pi-agent")
        except RuntimeError as exc:
            print(f"FAIL: {exc}")
            return 1

        return run_checks(bun, root, extension_path)


def check_responsiveness(bun: str, root: Path, extension_path: Path) -> int:
    slow_log = root / "slow-cmux.log"
    release_marker = root / "release-cmux"
    slow_cmux = root / "slow-cmux"
    make_executable(
        slow_cmux,
        """#!/usr/bin/env bash
set -euo pipefail
printf 'start %s\n' "$*" >> "$CMUX_TEST_PI_DISPATCH_LOG"
cat >/dev/null
for _ in {1..100}; do
  if [ -f "$CMUX_TEST_PI_RELEASE_MARKER" ]; then
    printf 'end %s\n' "$*" >> "$CMUX_TEST_PI_DISPATCH_LOG"
    printf 'temporary cmux failure\n' >&2
    exit 42
  fi
  sleep 0.02
done
printf 'blocked %s\n' "$*" >> "$CMUX_TEST_PI_DISPATCH_LOG"
exit 88
""",
    )
    responsiveness_source = """
import { writeFileSync } from "node:fs";
const extensionPath = process.env.CMUX_TEST_PI_EXTENSION_PATH;
const mod = await import(extensionPath);
const handlers = new Map();
mod.default({
  on(name, handler) {
    handlers.set(name, handler);
  }
});
const beforeAgentStart = handlers.get("before_agent_start");
if (typeof beforeAgentStart !== "function") throw new Error("missing before_agent_start");
let contextStale = false;
const ctx = {
  get cwd() {
    if (contextStale) throw new Error("stale context cwd access");
    return "/tmp/pi-dispatch-project";
  },
  get ui() {
    if (contextStale) throw new Error("stale context UI access");
    return {
      notify() {
        if (contextStale) throw new Error("stale context notification");
      }
    };
  },
  get sessionManager() {
    if (contextStale) throw new Error("stale context session access");
    return {
      getSessionId() { return "pi-dispatch-session"; }
    };
  }
};
setTimeout(() => {
  contextStale = true;
  writeFileSync(process.env.CMUX_TEST_PI_RELEASE_MARKER, "ready");
}, 0);
const first = beforeAgentStart({ prompt: "first" }, ctx);
const second = beforeAgentStart({ prompt: "second" }, ctx);
await Promise.all([first, second]);
"""
    responsive = run_extension(
        bun=bun,
        root=root,
        extension_path=extension_path,
        fake_cmux=slow_cmux,
        source=responsiveness_source,
        extra_env={
            "CMUX_TEST_PI_DISPATCH_LOG": str(slow_log),
            "CMUX_TEST_PI_RELEASE_MARKER": str(release_marker),
        },
    )
    if responsive.returncode != 0:
        print("FAIL: Pi hook dispatch blocked the extension event loop")
        print(f"exit={responsive.returncode}")
        print(f"stdout={responsive.stdout.strip()}")
        print(f"stderr={responsive.stderr.strip()}")
        return 1

    slow_lines = [line for line in slow_log.read_text(encoding="utf-8").splitlines() if line]
    phases = [line.split(" ", 1)[0] for line in slow_lines]
    if phases != ["start", "end", "start", "end"]:
        print(f"FAIL: Pi hook dispatch was blocking or concurrent: {slow_lines!r}")
        return 1
    if not all("hooks pi prompt-submit" in line for line in slow_lines):
        print(f"FAIL: responsiveness harness captured unexpected commands: {slow_lines!r}")
        return 1

    return 0


def check_feed_backlog(bun: str, root: Path, extension_path: Path) -> int:
    backlog_log = root / "backlog-cmux.log"
    backlog_release = root / "backlog-release"
    backlog_cmux = root / "backlog-cmux"
    make_executable(
        backlog_cmux,
        """#!/usr/bin/env bash
set -euo pipefail
payload="$(cat)"
printf '%s|%s\n' "$*" "$payload" >> "$CMUX_TEST_PI_BACKLOG_LOG"
while [ ! -f "$CMUX_TEST_PI_BACKLOG_RELEASE" ]; do sleep 0.02; done
printf '{}\n'
""",
    )
    backlog_source = """
import { writeFileSync } from "node:fs";
const extensionPath = process.env.CMUX_TEST_PI_EXTENSION_PATH;
const mod = await import(extensionPath);
const handlers = new Map();
mod.default({ on(name, handler) { handlers.set(name, handler); } });
const ctx = {
  cwd: "/tmp/pi-feed-backlog-project",
  sessionManager: { getSessionId() { return "pi-feed-backlog-session"; } }
};
for (let index = 0; index < 10; index += 1) {
  handlers.get("tool_execution_start")({
    toolCallId: `tool-${index}`,
    toolName: "bash",
    args: { command: `echo ${index}` }
  }, ctx);
}
handlers.get("tool_execution_end")({
  toolCallId: "tool-final",
  toolName: "bash",
  result: { content: [{ type: "text", text: "terminal result" }] },
  isError: false
}, ctx);
setTimeout(() => writeFileSync(process.env.CMUX_TEST_PI_BACKLOG_RELEASE, "ready"), 100);
await handlers.get("before_agent_start")({ prompt: "after feed backlog" }, ctx);
"""
    backlog = run_extension(
        bun=bun,
        root=root,
        extension_path=extension_path,
        fake_cmux=backlog_cmux,
        source=backlog_source,
        extra_env={
            "CMUX_TEST_PI_BACKLOG_LOG": str(backlog_log),
            "CMUX_TEST_PI_BACKLOG_RELEASE": str(backlog_release),
        },
    )
    if backlog.returncode != 0:
        print(f"FAIL: bounded feed-backlog harness failed: {backlog.stderr!r}")
        return 1
    backlog_calls = backlog_log.read_text(encoding="utf-8").splitlines()
    feed_calls = [line for line in backlog_calls if "hooks feed" in line]
    if len(feed_calls) != 9:
        print(f"FAIL: Pi feed lane exceeded its 1-running + 8-pending bound: {backlog_calls!r}")
        return 1
    lifecycle_indexes = [index for index, line in enumerate(backlog_calls) if "hooks pi prompt-submit" in line]
    if lifecycle_indexes != [0] and lifecycle_indexes != [1]:
        print(f"FAIL: lifecycle command was lost behind feed backlog: {backlog_calls!r}")
        return 1
    if not any("PostToolUse" in line and '"tool_call_id":"tool-final"' in line for line in feed_calls):
        print(f"FAIL: feed shedding discarded the terminal tool event: {backlog_calls!r}")
        return 1

    return 0


def make_feed_lifecycle_cmux(root: Path, name: str) -> Path:
    cmux = root / name
    make_executable(
        cmux,
        """#!/usr/bin/env python3
import fcntl
import os
import signal
import sys
import time

args = " ".join(sys.argv[1:])
payload = sys.stdin.read()
log_path = os.environ["CMUX_TEST_PI_CANCELLATION_LOG"]

def log(message):
    with open(log_path, "a", encoding="utf-8") as stream:
        stream.write(f"{message}\\n")
        stream.flush()

log(f"{args}|{payload}")

lock_path = os.environ.get("CMUX_TEST_PI_COMPLETION_LOCK")
if "hooks feed" in args and "PostToolUse" in args and lock_path:
    with open(lock_path, "a", encoding="utf-8") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log("overlap PostToolUse")
            raise SystemExit(91)
        time.sleep(0.1)

if "hooks feed" in args and "PreToolUse" in args:
    def handle_term(_signum, _frame):
        time.sleep(1.0)
        raise SystemExit(88)

    signal.signal(signal.SIGTERM, handle_term)
    while True:
        time.sleep(0.1)

print("{}")
""",
    )
    return cmux


def check_feed_cancellation(bun: str, root: Path, extension_path: Path) -> int:
    cancellation_log = root / "cancellation-cmux.log"
    cancellation_cmux = make_feed_lifecycle_cmux(root, "cancellation-cmux")
    cancellation_source = """
const extensionPath = process.env.CMUX_TEST_PI_EXTENSION_PATH;
const mod = await import(extensionPath);
const handlers = new Map();
mod.default({ on(name, handler) { handlers.set(name, handler); } });
const ctx = {
  cwd: "/tmp/pi-cancellation-project",
  sessionManager: { getSessionId() { return "pi-cancellation-session"; } }
};
for (let index = 0; index < 10; index += 1) {
  handlers.get("tool_execution_start")({
    toolCallId: `cancel-tool-${index}`,
    toolName: "bash",
    args: { command: `echo ${index}` }
  }, ctx);
}
const logPath = process.env.CMUX_TEST_PI_CANCELLATION_LOG;
while (!Bun.file(logPath).size) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
await handlers.get("session_shutdown")({ reason: "reload" }, ctx);
await new Promise((resolve) => setTimeout(resolve, 750));
"""
    cancellation = run_extension(
        bun=bun,
        root=root,
        extension_path=extension_path,
        fake_cmux=cancellation_cmux,
        source=cancellation_source,
        extra_env={"CMUX_TEST_PI_CANCELLATION_LOG": str(cancellation_log)},
    )
    if cancellation.returncode != 0:
        print(f"FAIL: feed-cancellation harness failed: {cancellation.stderr!r}")
        return 1
    cancellation_calls = cancellation_log.read_text(encoding="utf-8").splitlines()
    cancelled_feed_calls = [line for line in cancellation_calls if "hooks feed" in line]
    if len(cancelled_feed_calls) != 1:
        print(f"FAIL: queued feed work survived session shutdown: {cancellation_calls!r}")
        return 1

    return 0


def check_completion_order(bun: str, root: Path, extension_path: Path) -> int:
    completion_cmux = make_feed_lifecycle_cmux(root, "completion-order-cmux")
    completion_log = root / "completion-order-cmux.log"
    completion_lock = root / "completion-order-cmux.lock"
    completion_source = """
const extensionPath = process.env.CMUX_TEST_PI_EXTENSION_PATH;
const mod = await import(extensionPath);
const handlers = new Map();
mod.default({ on(name, handler) { handlers.set(name, handler); } });
const ctx = {
  cwd: "/tmp/pi-completion-order-project",
  sessionManager: { getSessionId() { return "pi-completion-order-session"; } }
};
await handlers.get("before_agent_start")({ prompt: "complete after tools" }, ctx);
for (let index = 0; index < 4; index += 1) {
  handlers.get("tool_execution_start")({
    toolCallId: `completion-tool-${index}`,
    toolName: "bash",
    args: { command: `echo ${index}` }
  }, ctx);
}
const logPath = process.env.CMUX_TEST_PI_CANCELLATION_LOG;
while (!(await Bun.file(logPath).text()).includes("hooks feed")) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
for (const index of [3, 1, 2, 0]) {
  handlers.get("tool_execution_end")({
    toolCallId: `completion-tool-${index}`,
    toolName: "bash",
    result: { content: [{ type: "text", text: `terminal result ${index}` }] },
    isError: false
  }, ctx);
}
await handlers.get("agent_end")({
  messages: [{ role: "assistant", content: "done" }],
  stopReason: "completed"
}, ctx);
handlers.get("tool_execution_end")({
  toolCallId: "late-tool",
  toolName: "bash",
  result: { content: [{ type: "text", text: "late" }] }
}, ctx);
await new Promise((resolve) => setTimeout(resolve, 250));
"""
    completion = run_extension(
        bun=bun,
        root=root,
        extension_path=extension_path,
        fake_cmux=completion_cmux,
        source=completion_source,
        extra_env={
            "CMUX_TEST_PI_CANCELLATION_LOG": str(completion_log),
            "CMUX_TEST_PI_COMPLETION_LOCK": str(completion_lock),
        },
    )
    if completion.returncode != 0:
        print(f"FAIL: completion-order harness failed: {completion.stderr!r}")
        return 1
    completion_calls = completion_log.read_text(encoding="utf-8").splitlines()
    completion_feed_indexes = [index for index, line in enumerate(completion_calls) if "hooks feed" in line]
    notification_indexes = [index for index, line in enumerate(completion_calls) if "hooks pi notification" in line]
    stop_indexes = [index for index, line in enumerate(completion_calls) if "hooks pi stop" in line]
    if len(completion_feed_indexes) != 5:
        print(f"FAIL: terminal lifecycle did not cancel feed backlog: {completion_calls!r}")
        return 1
    if sum("PostToolUse" in line for line in completion_calls) != 4:
        print(f"FAIL: terminal lifecycle discarded the retained completion event: {completion_calls!r}")
        return 1
    if any(line.startswith("overlap ") for line in completion_calls):
        print(f"FAIL: terminal lifecycle spawned overlapping feed commands: {completion_calls!r}")
        return 1
    post_calls = [line for line in completion_calls if "PostToolUse" in line]
    completion_order = []
    for line in post_calls:
        completion_order.extend(index for index in (3, 1, 2, 0) if f'"tool_call_id":"completion-tool-{index}"' in line)
    if completion_order != [3, 1, 2, 0]:
        print(f"FAIL: terminal feed completion order changed: {completion_calls!r}")
        return 1
    if not notification_indexes or not stop_indexes or completion_feed_indexes[-1] > notification_indexes[0]:
        print(f"FAIL: feed event arrived after terminal lifecycle began: {completion_calls!r}")
        return 1
    if notification_indexes[0] > stop_indexes[0]:
        print(f"FAIL: notification/stop lifecycle order changed: {completion_calls!r}")
        return 1

    return 0


def check_timeout_serialization(bun: str, root: Path, extension_path: Path) -> int:
    timeout_log = root / "timeout-cmux.log"
    timeout_lock = root / "timeout-cmux.lock"
    timeout_cmux = root / "timeout-cmux"
    make_executable(
        timeout_cmux,
        """#!/usr/bin/env python3
import fcntl
import os
import signal
import sys
import time

payload = sys.stdin.read()
label = "first" if '"prompt":"first"' in payload else "second"
log_path = os.environ["CMUX_TEST_PI_TIMEOUT_LOG"]

def log(message: str) -> None:
    with open(log_path, "a", encoding="utf-8") as stream:
        stream.write(f"{message} {label}\\n")
        stream.flush()

with open(os.environ["CMUX_TEST_PI_TIMEOUT_LOCK"], "a", encoding="utf-8") as lock:
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("overlap")
        raise SystemExit(91)

    log("start")
    if label == "first":
        def handle_term(_signum, _frame):
            log("term")
            time.sleep(1.0)
            log("exit")
            raise SystemExit(88)

        signal.signal(signal.SIGTERM, handle_term)
        while True:
            time.sleep(0.1)

    log("end")
    print("{}")
""",
    )
    timeout_source = """
const extensionPath = process.env.CMUX_TEST_PI_EXTENSION_PATH;
const mod = await import(extensionPath);
const handlers = new Map();
mod.default({ on(name, handler) { handlers.set(name, handler); } });
const ctx = {
  cwd: "/tmp/pi-timeout-project",
  sessionManager: { getSessionId() { return "pi-timeout-session"; } }
};
const first = handlers.get("before_agent_start")({ prompt: "first" }, ctx);
const second = handlers.get("before_agent_start")({ prompt: "second" }, ctx);
await Promise.all([first, second]);
"""
    timed_out = run_extension(
        bun=bun,
        root=root,
        extension_path=extension_path,
        fake_cmux=timeout_cmux,
        source=timeout_source,
        extra_env={
            "CMUX_TEST_PI_TIMEOUT_LOG": str(timeout_log),
            "CMUX_TEST_PI_TIMEOUT_LOCK": str(timeout_lock),
        },
    )
    if timed_out.returncode != 0:
        print(f"FAIL: timeout serialization harness failed: {timed_out.stderr!r}")
        return 1
    timeout_lines = timeout_log.read_text(encoding="utf-8").splitlines()
    if "overlap second" in timeout_lines:
        print(f"FAIL: queue advanced before timed-out child exited: {timeout_lines!r}")
        return 1
    if "start first" not in timeout_lines or "start second" not in timeout_lines:
        print(f"FAIL: timeout harness missed a serialized command: {timeout_lines!r}")
        return 1

    return 0


def check_error_classification(bun: str, root: Path, extension_path: Path) -> int:
    ambiguous_log = root / "ambiguous-cmux.log"
    ambiguous_marker = root / "ambiguous-cmux-first-call"
    ambiguous_cmux = root / "ambiguous-cmux"
    make_executable(
        ambiguous_cmux,
        """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CMUX_TEST_PI_AMBIGUOUS_LOG"
cat >/dev/null
if [ ! -f "$CMUX_TEST_PI_AMBIGUOUS_MARKER" ]; then
  touch "$CMUX_TEST_PI_AMBIGUOUS_MARKER"
  printf 'not_found: hook metadata references surface settings\n' >&2
  exit 1
fi
printf '{}\n'
""",
    )
    ambiguous_source = """
const extensionPath = process.env.CMUX_TEST_PI_EXTENSION_PATH;
const mod = await import(extensionPath);
const handlers = new Map();
mod.default({ on(name, handler) { handlers.set(name, handler); } });
const ctx = {
  cwd: "/tmp/pi-ambiguous-error-project",
  sessionManager: { getSessionId() { return "pi-ambiguous-error-session"; } }
};
await handlers.get("before_agent_start")({ prompt: "first" }, ctx);
await handlers.get("before_agent_start")({ prompt: "second" }, ctx);
"""
    ambiguous = run_extension(
        bun=bun,
        root=root,
        extension_path=extension_path,
        fake_cmux=ambiguous_cmux,
        source=ambiguous_source,
        extra_env={
            "CMUX_TEST_PI_AMBIGUOUS_LOG": str(ambiguous_log),
            "CMUX_TEST_PI_AMBIGUOUS_MARKER": str(ambiguous_marker),
        },
    )
    if ambiguous.returncode != 0:
        print(f"FAIL: ambiguous-error harness failed: {ambiguous.stderr!r}")
        return 1
    ambiguous_calls = ambiguous_log.read_text(encoding="utf-8").splitlines()
    if len(ambiguous_calls) != 2:
        print(f"FAIL: non-surface not_found error disabled dispatch: {ambiguous_calls!r}")
        return 1

    return 0


def check_unserializable_feed(bun: str, root: Path, extension_path: Path) -> int:
    feed_log = root / "unserializable-feed-cmux.log"
    feed_cmux = root / "unserializable-feed-cmux"
    make_executable(
        feed_cmux,
        """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CMUX_TEST_PI_UNSERIALIZABLE_LOG"
cat >/dev/null
printf '{}\n'
""",
    )
    feed_source = """
const extensionPath = process.env.CMUX_TEST_PI_EXTENSION_PATH;
const mod = await import(extensionPath);
const handlers = new Map();
mod.default({ on(name, handler) { handlers.set(name, handler); } });
const ctx = {
  cwd: "/tmp/pi-unserializable-feed-project",
  sessionManager: { getSessionId() { return "pi-unserializable-feed-session"; } }
};
await handlers.get("tool_execution_end")({
  toolCallId: "bigint-tool",
  toolName: "custom",
  result: { value: 1n },
  isError: false
}, ctx);
await handlers.get("before_agent_start")({ prompt: "still routable" }, ctx);
"""
    feed = run_extension(
        bun=bun,
        root=root,
        extension_path=extension_path,
        fake_cmux=feed_cmux,
        source=feed_source,
        extra_env={"CMUX_TEST_PI_UNSERIALIZABLE_LOG": str(feed_log)},
    )
    if feed.returncode != 0:
        print(f"FAIL: unserializable feed escaped its best-effort boundary: {feed.stderr!r}")
        return 1
    feed_calls = feed_log.read_text(encoding="utf-8").splitlines()
    if len(feed_calls) != 1 or "hooks pi prompt-submit" not in feed_calls[0]:
        print(f"FAIL: unserializable feed disrupted later lifecycle routing: {feed_calls!r}")
        return 1

    return 0


def check_explicit_surface_routing(bun: str, root: Path, extension_path: Path) -> int:
    explicit_log = root / "explicit-surface-cmux.log"
    explicit_cmux = root / "explicit-surface-cmux"
    make_executable(
        explicit_cmux,
        """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CMUX_TEST_PI_EXPLICIT_LOG"
cat >/dev/null
case "$*" in
  *"surface resume set"*)
    printf 'Error: not_found: Surface not found\n' >&2
    exit 1
    ;;
  *)
    printf '{}\n'
    ;;
esac
""",
    )
    explicit_source = """
const extensionPath = process.env.CMUX_TEST_PI_EXTENSION_PATH;
const mod = await import(extensionPath);
const handlers = new Map();
mod.default({ on(name, handler) { handlers.set(name, handler); } });
const ctx = {
  cwd: "/tmp/pi-explicit-surface-project",
  sessionManager: { getSessionId() { return "pi-explicit-surface-session"; } }
};
await handlers.get("session_start")({}, ctx);
await handlers.get("before_agent_start")({ prompt: "route after stale resume target" }, ctx);
"""
    explicit = run_extension(
        bun=bun,
        root=root,
        extension_path=extension_path,
        fake_cmux=explicit_cmux,
        source=explicit_source,
        extra_env={"CMUX_TEST_PI_EXPLICIT_LOG": str(explicit_log)},
    )
    if explicit.returncode != 0:
        print(f"FAIL: explicit-surface harness failed: {explicit.stderr!r}")
        return 1
    explicit_calls = explicit_log.read_text(encoding="utf-8").splitlines()
    if len(explicit_calls) != 3 or "hooks pi prompt-submit" not in explicit_calls[-1]:
        print(f"FAIL: stale resume target disabled recoverable lifecycle routing: {explicit_calls!r}")
        return 1

    return 0


def check_runtime_isolation(bun: str, root: Path, extension_path: Path) -> int:
    runtime_log = root / "runtime-isolation-cmux.log"
    runtime_cmux = root / "runtime-isolation-cmux"
    make_executable(
        runtime_cmux,
        """#!/usr/bin/env bash
set -euo pipefail
payload="$(cat)"
printf '%s|%s\n' "$*" "$payload" >> "$CMUX_TEST_PI_RUNTIME_LOG"
if [[ "$payload" == *'"session_id":"pi-runtime-stale"'* ]]; then
  printf 'Error: not_found: Surface not found\n' >&2
  exit 1
fi
printf '{}\n'
""",
    )
    runtime_source = """
const extensionPath = process.env.CMUX_TEST_PI_EXTENSION_PATH;
const mod = await import(extensionPath);
const staleHandlers = new Map();
const healthyHandlers = new Map();
mod.default({ on(name, handler) { staleHandlers.set(name, handler); } });
mod.default({ on(name, handler) { healthyHandlers.set(name, handler); } });
const context = (sessionId) => ({
  cwd: "/tmp/pi-runtime-isolation-project",
  sessionManager: { getSessionId() { return sessionId; } }
});
await staleHandlers.get("before_agent_start")(
  { prompt: "stale runtime" },
  context("pi-runtime-stale")
);
await healthyHandlers.get("before_agent_start")(
  { prompt: "healthy runtime" },
  context("pi-runtime-healthy")
);
"""
    runtime = run_extension(
        bun=bun,
        root=root,
        extension_path=extension_path,
        fake_cmux=runtime_cmux,
        source=runtime_source,
        extra_env={"CMUX_TEST_PI_RUNTIME_LOG": str(runtime_log)},
    )
    if runtime.returncode != 0:
        print(f"FAIL: runtime-isolation harness failed: {runtime.stderr!r}")
        return 1
    runtime_calls = runtime_log.read_text(encoding="utf-8").splitlines()
    if len(runtime_calls) != 2 or "pi-runtime-healthy" not in runtime_calls[-1]:
        print(f"FAIL: stale surface leaked across Pi extension runtimes: {runtime_calls!r}")
        return 1

    return 0


def check_stale_surface(bun: str, root: Path, extension_path: Path) -> int:
    stale_log = root / "stale-cmux.log"
    stale_cmux = root / "stale-cmux"
    make_executable(
        stale_cmux,
        """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CMUX_TEST_PI_STALE_LOG"
cat >/dev/null
printf 'Error: not_found: Surface not found\n' >&2
exit 1
""",
    )
    stale_source = """
const extensionPath = process.env.CMUX_TEST_PI_EXTENSION_PATH;
const mod = await import(extensionPath);
const handlers = new Map();
mod.default({
  on(name, handler) {
    handlers.set(name, handler);
  }
});
const ctx = {
  cwd: "/tmp/pi-stale-surface-project",
  sessionManager: {
    getSessionId() { return "pi-stale-surface-session"; }
  }
};
await handlers.get("session_start")({}, ctx);
await handlers.get("before_agent_start")({ prompt: "hello" }, ctx);
await handlers.get("agent_end")({
  messages: [{ role: "assistant", content: "done" }],
  stopReason: "completed"
}, ctx);
await handlers.get("session_shutdown")({ reason: "quit" }, ctx);
"""
    stale = run_extension(
        bun=bun,
        root=root,
        extension_path=extension_path,
        fake_cmux=stale_cmux,
        source=stale_source,
        extra_env={"CMUX_TEST_PI_STALE_LOG": str(stale_log)},
    )
    if stale.returncode != 0:
        print("FAIL: stale-surface Pi harness failed to execute")
        print(f"exit={stale.returncode}")
        print(f"stdout={stale.stdout.strip()}")
        print(f"stderr={stale.stderr.strip()}")
        return 1

    stale_calls = [line for line in stale_log.read_text(encoding="utf-8").splitlines() if line]
    if len(stale_calls) != 1:
        print(f"FAIL: stale CMUX_SURFACE_ID was retried after its first permanent failure: {stale_calls!r}")
        return 1
    warning_count = stale.stderr.count('"source":"cmux-pi-extension"')
    if warning_count != 1:
        print(f"FAIL: stale surface emitted {warning_count} warnings instead of one: {stale.stderr!r}")
        return 1

    return 0


def run_checks(bun: str, root: Path, extension_path: Path) -> int:
    checks = (
        check_responsiveness,
        check_feed_backlog,
        check_feed_cancellation,
        check_completion_order,
        check_timeout_serialization,
        check_error_classification,
        check_unserializable_feed,
        check_explicit_surface_routing,
        check_runtime_isolation,
        check_stale_surface,
    )
    for check in checks:
        if check(bun, root, extension_path) != 0:
            return 1
    print("PASS: Pi dispatch stays responsive, serialized, and fails stale surfaces once")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
