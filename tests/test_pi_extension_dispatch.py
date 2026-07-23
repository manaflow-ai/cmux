#!/usr/bin/env python3
"""Regression coverage for Pi extension dispatch responsiveness and stale surfaces."""

from __future__ import annotations

import json
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
    env["CMUX_TEST_PI_EXTENSION_PATH"] = str(extension_path)
    env["CMUX_PI_CMUX_BIN"] = str(fake_cmux)
    env["CMUX_SURFACE_ID"] = "00000000-0000-0000-0000-000000008672"
    env["CMUX_WORKSPACE_ID"] = "00000000-0000-0000-0000-000000008673"
    env.update(extra_env)
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
        print("FAIL: bun not found; Pi extension dispatch coverage requires Bun")
        return 1

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


def check_panel_only_target_fails_closed(bun: str, root: Path, extension_path: Path) -> int:
    marker = root / "panel-only-cmux-called"
    fake_cmux = root / "panel-only-cmux"
    make_executable(
        fake_cmux,
        """#!/usr/bin/env bash
set -euo pipefail
touch "$CMUX_TEST_PI_PANEL_ONLY_MARKER"
exit 91
""",
    )
    inspectable_extension = root / "panel-only-cmux-session.ts"
    inspectable_extension.write_text(
        extension_path.read_text(encoding="utf-8")
        + "\nexport { sendHook };\n",
        encoding="utf-8",
    )
    source = """
const extensionPath = process.env.CMUX_TEST_PI_EXTENSION_PATH;
const mod = await import(extensionPath);
const delivered = await mod.sendHook(
  {},
  "session-start",
  {
    sessionId: "pi-panel-only-session",
    cwd: "/tmp/pi-panel-only-project",
  },
);
if (delivered) throw new Error("panel-only hook was reported as delivered");
"""
    result = run_extension(
        bun=bun,
        root=root,
        extension_path=inspectable_extension,
        fake_cmux=fake_cmux,
        source=source,
        extra_env={
            "CMUX_SURFACE_ID": "",
            "CMUX_WORKSPACE_ID": "",
            "CMUX_PANEL_ID": "00000000-0000-0000-0000-000000008674",
            "CMUX_TEST_PI_PANEL_ONLY_MARKER": str(marker),
        },
    )
    if result.returncode != 0:
        print(f"FAIL: panel-only target was treated as delivered: {result.stderr!r}")
        return 1
    if marker.exists():
        print("FAIL: panel-only target invoked the cmux CLI fallback")
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


def check_terminal_feed_compaction(bun: str, root: Path, extension_path: Path) -> int:
    compaction_log = root / "terminal-compaction-cmux.log"
    compaction_release = root / "terminal-compaction-release"
    compaction_cmux = root / "terminal-compaction-cmux"
    make_executable(
        compaction_cmux,
        """#!/usr/bin/env bash
set -euo pipefail
payload="$(cat)"
printf '%s|%s\n' "$*" "$payload" >> "$CMUX_TEST_PI_COMPACTION_LOG"
if [[ "$payload" == *'"tool_call_id":"overflow-tool-0"'* ]]; then
  while [ ! -f "$CMUX_TEST_PI_COMPACTION_RELEASE" ]; do sleep 0.02; done
fi
printf '{}\n'
""",
    )
    compaction_source = """
import { writeFileSync } from "node:fs";
const extensionPath = process.env.CMUX_TEST_PI_EXTENSION_PATH;
const mod = await import(extensionPath);
const handlers = new Map();
mod.default({ on(name, handler) { handlers.set(name, handler); } });
const context = (index) => ({
  cwd: `/tmp/pi-terminal-compaction-project-${index}`,
  sessionManager: { getSessionId() { return "pi-terminal-compaction-session"; } }
});
for (let index = 0; index < 10; index += 1) {
  handlers.get("tool_execution_end")({
    toolCallId: `overflow-tool-${index}`,
    toolName: "bash",
    result: { content: [{ type: "text", text: `terminal result ${index}` }] },
    isError: false
  }, context(index));
}
const logPath = process.env.CMUX_TEST_PI_COMPACTION_LOG;
while (!Bun.file(logPath).size) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
writeFileSync(process.env.CMUX_TEST_PI_COMPACTION_RELEASE, "ready");
await handlers.get("agent_end")({
  messages: [{ role: "assistant", content: "done" }],
  stopReason: "completed"
}, context(9));
"""
    compacted = run_extension(
        bun=bun,
        root=root,
        extension_path=extension_path,
        fake_cmux=compaction_cmux,
        source=compaction_source,
        extra_env={
            "CMUX_TEST_PI_COMPACTION_LOG": str(compaction_log),
            "CMUX_TEST_PI_COMPACTION_RELEASE": str(compaction_release),
        },
    )
    if compacted.returncode != 0:
        print(f"FAIL: terminal-feed compaction harness failed: {compacted.stderr!r}")
        return 1
    compaction_calls = compaction_log.read_text(encoding="utf-8").splitlines()
    feed_calls = [line for line in compaction_calls if "hooks feed" in line]
    feed_payloads = "\n".join(feed_calls)
    missing = [tool_id for index in range(10) if (tool_id := f"overflow-tool-{index}") not in feed_payloads]
    if missing:
        print(f"FAIL: saturated feed queue discarded terminal outcomes {missing!r}: {compaction_calls!r}")
        return 1
    compacted_summaries = [
        summary
        for line in feed_calls
        for summary in json.loads(line.split("|", 1)[1]).get("cmux_compacted_terminal_events", [])
    ]
    for summary in compacted_summaries:
        tool_id = summary.get("tool_call_id", "")
        index = int(tool_id.rsplit("-", 1)[-1])
        expected_cwd = f"/tmp/pi-terminal-compaction-project-{index}"
        if summary.get("cwd") != expected_cwd:
            print(f"FAIL: compacted terminal event lost cwd ownership: {compacted_summaries!r}")
            return 1

    return 0


def check_feed_payload_byte_bound(bun: str, root: Path, extension_path: Path) -> int:
    payload_log = root / "bounded-payload-cmux.log"
    payload_release = root / "bounded-payload-release"
    payload_cmux = root / "bounded-payload-cmux"
    make_executable(
        payload_cmux,
        """#!/usr/bin/env python3
import fcntl
import os
import pathlib
import sys
import time

args = " ".join(sys.argv[1:])
payload = sys.stdin.read()
with open(os.environ["CMUX_TEST_PI_PAYLOAD_LOG"], "a", encoding="utf-8") as stream:
    fcntl.flock(stream, fcntl.LOCK_EX)
    stream.write(f"{args}|{payload}\\n")
    stream.flush()

if '"tool_call_id":"large-tool-0"' in payload:
    release = pathlib.Path(os.environ["CMUX_TEST_PI_PAYLOAD_RELEASE"])
    while not release.exists():
        time.sleep(0.02)
print("{}")
""",
    )
    payload_source = """
import { writeFileSync } from "node:fs";
const extensionPath = process.env.CMUX_TEST_PI_EXTENSION_PATH;
const mod = await import(extensionPath);
const handlers = new Map();
mod.default({ on(name, handler) { handlers.set(name, handler); } });
const ctx = {
  cwd: "/tmp/pi-bounded-payload-project",
  sessionManager: { getSessionId() { return "pi-bounded-payload-session"; } }
};
handlers.get("tool_execution_end")({
  toolCallId: "relay-sized-tool",
  toolName: "bash",
  result: `PRIVATE-RELAY-TOOL-OUTPUT-${"x".repeat(20 * 1024)}`,
  isError: false
}, ctx);
const multibyteIdentifier = "界".repeat(2048);
const multibyteCtx = {
  cwd: multibyteIdentifier,
  sessionManager: { getSessionId() { return multibyteIdentifier; } }
};
handlers.get("tool_execution_end")({
  toolCallId: multibyteIdentifier,
  toolName: multibyteIdentifier,
  result: `PRIVATE-MULTIBYTE-TOOL-OUTPUT-${"界".repeat(20 * 1024)}`,
  isError: false
}, multibyteCtx);
const largeResult = `PRIVATE-TOOL-OUTPUT-${"x".repeat(512 * 1024)}`;
for (let index = 0; index < 10; index += 1) {
  handlers.get("tool_execution_end")({
    toolCallId: `large-tool-${index}`,
    toolName: "bash",
    result: largeResult,
    isError: false
  }, ctx);
}
const logPath = process.env.CMUX_TEST_PI_PAYLOAD_LOG;
while (!Bun.file(logPath).size) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
writeFileSync(process.env.CMUX_TEST_PI_PAYLOAD_RELEASE, "ready");
await handlers.get("agent_end")({
  messages: [{ role: "assistant", content: "done" }],
  stopReason: "completed"
}, ctx);
"""
    bounded = run_extension(
        bun=bun,
        root=root,
        extension_path=extension_path,
        fake_cmux=payload_cmux,
        source=payload_source,
        extra_env={
            "CMUX_TEST_PI_PAYLOAD_LOG": str(payload_log),
            "CMUX_TEST_PI_PAYLOAD_RELEASE": str(payload_release),
        },
    )
    if bounded.returncode != 0:
        print(f"FAIL: bounded-payload harness failed: {bounded.stderr!r}")
        return 1
    feed_payloads = [
        line.split("|", 1)[1]
        for line in payload_log.read_text(encoding="utf-8").splitlines()
        if "hooks feed" in line
    ]
    if not feed_payloads:
        print("FAIL: bounded-payload harness captured no feed commands")
        return 1
    oversized = [
        len(encoded)
        for payload in feed_payloads
        if len(encoded := payload.encode("utf-8")) > 12 * 1024
    ]
    if oversized:
        print(f"FAIL: Pi feed queue exceeded the relay-safe input budget: {oversized!r}")
        return 1
    if any("PRIVATE-" in payload for payload in feed_payloads):
        print("FAIL: bounded Pi feed payload retained raw tool output")
        return 1

    return 0


def check_cross_session_feed_ownership(bun: str, root: Path, extension_path: Path) -> int:
    ownership_log = root / "cross-session-cmux.log"
    ownership_release = root / "cross-session-release"
    ownership_cmux = root / "cross-session-cmux"
    make_executable(
        ownership_cmux,
        """#!/usr/bin/env bash
set -euo pipefail
payload="$(cat)"
printf '%s|%s\n' "$*" "$payload" >> "$CMUX_TEST_PI_OWNERSHIP_LOG"
if [[ "$payload" == *'"tool_call_id":"session-a-tool-0"'* ]]; then
  while [ ! -f "$CMUX_TEST_PI_OWNERSHIP_RELEASE" ]; do sleep 0.02; done
fi
printf '{}\n'
""",
    )
    ownership_source = """
import { writeFileSync } from "node:fs";
const extensionPath = process.env.CMUX_TEST_PI_EXTENSION_PATH;
const mod = await import(extensionPath);
const handlers = new Map();
mod.default({ on(name, handler) { handlers.set(name, handler); } });
const context = (sessionId, cwd) => ({
  cwd,
  sessionManager: { getSessionId() { return sessionId; } }
});
const sessionA = context("pi-overflow-session-a", "/tmp/pi-overflow-a");
const sessionB = context("pi-overflow-session-b", "/tmp/pi-overflow-b");
for (let index = 0; index < 9; index += 1) {
  handlers.get("tool_execution_end")({
    toolCallId: `session-a-tool-${index}`,
    toolName: "bash",
    result: { status: "ok", index },
    isError: false
  }, sessionA);
}
handlers.get("tool_execution_end")({
  toolCallId: "session-b-tool",
  toolName: "bash",
  result: { status: "failed" },
  isError: true
}, sessionB);
const logPath = process.env.CMUX_TEST_PI_OWNERSHIP_LOG;
while (!Bun.file(logPath).size) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
writeFileSync(process.env.CMUX_TEST_PI_OWNERSHIP_RELEASE, "ready");
await handlers.get("agent_end")({
  messages: [{ role: "assistant", content: "session b done" }],
  stopReason: "completed"
}, sessionB);
await handlers.get("agent_end")({
  messages: [{ role: "assistant", content: "session a done" }],
  stopReason: "completed"
}, sessionA);
"""
    ownership = run_extension(
        bun=bun,
        root=root,
        extension_path=extension_path,
        fake_cmux=ownership_cmux,
        source=ownership_source,
        extra_env={
            "CMUX_TEST_PI_OWNERSHIP_LOG": str(ownership_log),
            "CMUX_TEST_PI_OWNERSHIP_RELEASE": str(ownership_release),
        },
    )
    if ownership.returncode != 0:
        print(f"FAIL: cross-session ownership harness failed: {ownership.stderr!r}")
        return 1
    calls = ownership_log.read_text(encoding="utf-8").splitlines()
    feed_payloads = [
        json.loads(line.split("|", 1)[1])
        for line in calls
        if "hooks feed" in line
    ]
    session_b_payloads = [payload for payload in feed_payloads if payload.get("session_id") == "pi-overflow-session-b"]
    if len(session_b_payloads) != 1 or session_b_payloads[0].get("cwd") != "/tmp/pi-overflow-b":
        print(f"FAIL: terminal overflow lost session B routing ownership: {feed_payloads!r}")
        return 1
    for payload in feed_payloads:
        summaries = payload.get("cmux_compacted_terminal_events", [])
        if any(summary.get("session_id") != payload.get("session_id") for summary in summaries):
            print(f"FAIL: terminal overflow compacted events across sessions: {payload!r}")
            return 1
    session_b_feed_index = next(
        index
        for index, line in enumerate(calls)
        if "hooks feed" in line and '"session_id":"pi-overflow-session-b"' in line
    )
    session_b_notification_index = next(
        index
        for index, line in enumerate(calls)
        if "hooks pi notification" in line and '"session_id":"pi-overflow-session-b"' in line
    )
    if session_b_feed_index > session_b_notification_index:
        print(f"FAIL: session B lifecycle ran before its terminal feed: {calls!r}")
        return 1

    return 0


def check_cross_session_feed_isolation(bun: str, root: Path, extension_path: Path) -> int:
    isolation_log = root / "cross-session-isolation-cmux.log"
    isolation_release = root / "cross-session-isolation-release"
    isolation_cmux = root / "cross-session-isolation-cmux"
    make_executable(
        isolation_cmux,
        """#!/usr/bin/env bash
set -euo pipefail
payload="$(cat)"
printf '%s|%s\n' "$*" "$payload" >> "$CMUX_TEST_PI_ISOLATION_LOG"
if [[ "$payload" == *'"session_id":"pi-stalled-session-a"'* ]] && [[ "$*" == *"hooks feed"* ]]; then
  while [ ! -f "$CMUX_TEST_PI_ISOLATION_RELEASE" ]; do sleep 0.02; done
fi
printf '{}\n'
""",
    )
    isolation_source = """
import { writeFileSync } from "node:fs";
const extensionPath = process.env.CMUX_TEST_PI_EXTENSION_PATH;
const mod = await import(extensionPath);
const handlers = new Map();
mod.default({ on(name, handler) { handlers.set(name, handler); } });
const context = (sessionId, cwd) => ({
  cwd,
  sessionManager: { getSessionId() { return sessionId; } }
});
const sessionA = context("pi-stalled-session-a", "/tmp/pi-stalled-a");
const sessionB = context("pi-healthy-session-b", "/tmp/pi-healthy-b");
handlers.get("tool_execution_end")({
  toolCallId: "stalled-tool-a",
  toolName: "bash",
  result: { status: "stalled" },
  isError: false
}, sessionA);
const logPath = process.env.CMUX_TEST_PI_ISOLATION_LOG;
while (!Bun.file(logPath).size) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
handlers.get("tool_execution_end")({
  toolCallId: "healthy-tool-b",
  toolName: "bash",
  result: { status: "ok" },
  isError: false
}, sessionB);
await handlers.get("agent_end")({
  messages: [{ role: "assistant", content: "session b done" }],
  stopReason: "completed"
}, sessionB);
writeFileSync(process.env.CMUX_TEST_PI_ISOLATION_RELEASE, "ready");
await handlers.get("agent_end")({
  messages: [{ role: "assistant", content: "session a done" }],
  stopReason: "completed"
}, sessionA);
"""
    isolation = run_extension(
        bun=bun,
        root=root,
        extension_path=extension_path,
        fake_cmux=isolation_cmux,
        source=isolation_source,
        extra_env={
            "CMUX_TEST_PI_ISOLATION_LOG": str(isolation_log),
            "CMUX_TEST_PI_ISOLATION_RELEASE": str(isolation_release),
        },
    )
    if isolation.returncode != 0:
        print(f"FAIL: cross-session isolation harness failed: {isolation.stderr!r}")
        return 1
    calls = isolation_log.read_text(encoding="utf-8").splitlines()
    session_b_feed_indexes = [
        index
        for index, line in enumerate(calls)
        if "hooks feed" in line and '"session_id":"pi-healthy-session-b"' in line
    ]
    session_b_notification_indexes = [
        index
        for index, line in enumerate(calls)
        if "hooks pi notification" in line and '"session_id":"pi-healthy-session-b"' in line
    ]
    if not session_b_feed_indexes:
        print(f"FAIL: stalled session A discarded session B feed work: {calls!r}")
        return 1
    if not session_b_notification_indexes or session_b_feed_indexes[0] > session_b_notification_indexes[0]:
        print(f"FAIL: session B lifecycle ran before its isolated feed work: {calls!r}")
        return 1

    return 0


def check_feed_ack_rehomes_cached_target(bun: str, root: Path, extension_path: Path) -> int:
    live_workspace = "00000000-0000-0000-0000-000000008679"
    inspectable_extension = root / "feed-rehome-cmux-session.ts"
    inspectable_extension.write_text(
        extension_path.read_text(encoding="utf-8")
        + "\nexport { PiCmuxCommandDispatcher, surfaceTargetsFor };\n",
        encoding="utf-8",
    )
    rehome_cmux = root / "feed-rehome-cmux"
    make_executable(
        rehome_cmux,
        f"""#!/usr/bin/env python3
import json
import sys

sys.stdin.read()
print(json.dumps({{
    "status": "acknowledged",
    "item_id": "00000000-0000-0000-0000-000000008680",
    "workspace_id": "{live_workspace}",
    "surface_id": "00000000-0000-0000-0000-000000008672",
}}))
""",
    )
    rehome_source = f"""
const extensionPath = process.env.CMUX_TEST_PI_EXTENSION_PATH;
const mod = await import(extensionPath);
const dispatcher = new mod.PiCmuxCommandDispatcher();
const sessionId = "pi-feed-rehome-session";
const context = {{
  sessionId,
  cwd: "/tmp/pi-feed-rehome-project",
}};
dispatcher.enqueueFeed("first", {{
  args: [
    "hooks", "feed", "--workspace", "00000000-0000-0000-0000-000000008673",
    "--surface", "00000000-0000-0000-0000-000000008672",
  ],
  cwd: context.cwd,
  payload: {{
    session_id: sessionId,
    hook_event_name: "PostToolUse",
  }},
  context,
  terminal: true,
}});
await dispatcher.finishFeedForSession(sessionId);
const target = mod.surfaceTargetsFor(dispatcher).get(sessionId);
const expected = [
  "--workspace", "{live_workspace}",
  "--surface", "00000000-0000-0000-0000-000000008672",
];
if (JSON.stringify(target) !== JSON.stringify(expected)) {{
  throw new Error(`feed acknowledgment did not repair cached target: ${{JSON.stringify(target)}}`);
}}
"""
    result = run_extension(
        bun=bun,
        root=root,
        extension_path=inspectable_extension,
        fake_cmux=rehome_cmux,
        source=rehome_source,
        extra_env={},
    )
    if result.returncode != 0:
        print(f"FAIL: Feed acknowledgment did not rehome the Pi target: {result.stderr!r}")
        return 1
    return 0


def check_aggregate_feed_bound(bun: str, root: Path, extension_path: Path) -> int:
    state_path = root / "aggregate-feed-state.json"
    lock_path = root / "aggregate-feed.lock"
    release_path = root / "aggregate-feed-release"
    aggregate_cmux = root / "aggregate-feed-cmux"
    make_executable(
        aggregate_cmux,
        """#!/usr/bin/env python3
import fcntl
import json
import os
import pathlib
import sys
import time

sys.stdin.read()
state_path = pathlib.Path(os.environ["CMUX_TEST_PI_AGGREGATE_STATE"])
lock_path = pathlib.Path(os.environ["CMUX_TEST_PI_AGGREGATE_LOCK"])
release_path = pathlib.Path(os.environ["CMUX_TEST_PI_AGGREGATE_RELEASE"])

def update(delta):
    with lock_path.open("a+", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = json.loads(state_path.read_text(encoding="utf-8")) if state_path.exists() else {
            "active": 0,
            "maximum": 0,
            "starts": 0,
        }
        state["active"] += delta
        if delta > 0:
            state["starts"] += 1
            state["maximum"] = max(state["maximum"], state["active"])
        state_path.write_text(json.dumps(state), encoding="utf-8")

update(1)
while not release_path.exists():
    time.sleep(0.01)
update(-1)
print("{}")
""",
    )
    aggregate_source = """
import { writeFileSync } from "node:fs";
const extensionPath = process.env.CMUX_TEST_PI_EXTENSION_PATH;
const mod = await import(extensionPath);
const handlers = new Map();
mod.default({ on(name, handler) { handlers.set(name, handler); } });
const sessions = [];
for (let index = 0; index < 40; index += 1) {
  const sessionId = `pi-aggregate-session-${index}`;
  sessions.push(sessionId);
  handlers.get("tool_execution_end")({
    toolCallId: `aggregate-tool-${index}`,
    toolName: "bash",
    result: { status: "ok" },
    isError: false,
  }, {
    cwd: `/tmp/pi-aggregate-${index}`,
    sessionManager: { getSessionId() { return sessionId; } },
  });
}
setTimeout(() => writeFileSync(process.env.CMUX_TEST_PI_AGGREGATE_RELEASE, "ready"), 200);
await new Promise((resolve) => setTimeout(resolve, 2000));
"""
    result = run_extension(
        bun=bun,
        root=root,
        extension_path=extension_path,
        fake_cmux=aggregate_cmux,
        source=aggregate_source,
        extra_env={
            "CMUX_TEST_PI_AGGREGATE_STATE": str(state_path),
            "CMUX_TEST_PI_AGGREGATE_LOCK": str(lock_path),
            "CMUX_TEST_PI_AGGREGATE_RELEASE": str(release_path),
        },
    )
    if result.returncode != 0:
        print(f"FAIL: aggregate Feed bound harness failed: {result.stderr!r}")
        return 1
    state = json.loads(state_path.read_text(encoding="utf-8"))
    if state["maximum"] > 2:
        print(f"FAIL: Pi spawned {state['maximum']} concurrent Feed subprocesses: {state!r}")
        return 1
    if state["starts"] > 34:
        print(f"FAIL: Pi retained more than 2 active + 32 queued Feed commands: {state!r}")
        return 1
    return 0


def check_feed_failure_overflow_fails_closed(bun: str, root: Path, extension_path: Path) -> int:
    release_path = root / "feed-failure-overflow-release"
    overflow_cmux = root / "feed-failure-overflow-cmux"
    make_executable(
        overflow_cmux,
        """#!/usr/bin/env python3
import os
import pathlib
import sys
import time

sys.stdin.read()
release_path = pathlib.Path(os.environ["CMUX_TEST_PI_FAILURE_OVERFLOW_RELEASE"])
while not release_path.exists():
    time.sleep(0.01)
print("{}")
""",
    )
    inspectable_extension = root / "feed-failure-overflow-cmux-session.ts"
    inspectable_extension.write_text(
        extension_path.read_text(encoding="utf-8")
        + "\nexport { PiCmuxCommandDispatcher };\n",
        encoding="utf-8",
    )
    overflow_source = """
import { writeFileSync } from "node:fs";
const extensionPath = process.env.CMUX_TEST_PI_EXTENSION_PATH;
const mod = await import(extensionPath);
const dispatcher = new mod.PiCmuxCommandDispatcher();
let overflowFailureReported = false;
for (let index = 0; index < 70; index += 1) {
  const sessionId = `pi-feed-failure-overflow-${index}`;
  dispatcher.enqueueFeed(`overflow-${index}`, {
    args: ["hooks", "feed", "--surface", "00000000-0000-0000-0000-000000008672"],
    cwd: "/tmp/pi-feed-failure-overflow",
    payload: {
      session_id: sessionId,
      hook_event_name: "PostToolUse",
    },
    context: {
      sessionId,
      cwd: "/tmp/pi-feed-failure-overflow",
    },
    terminal: true,
    onFailure: () => {
      if (index === 69) overflowFailureReported = true;
    },
  });
}
await dispatcher.finishFeedForSession("pi-feed-failure-overflow-69");
writeFileSync(process.env.CMUX_TEST_PI_FAILURE_OVERFLOW_RELEASE, "ready");
if (!overflowFailureReported) throw new Error("dropped terminal Feed event was reported as delivered");
await Promise.all(Array.from(
  { length: 34 },
  (_, index) => dispatcher.finishFeedForSession(`pi-feed-failure-overflow-${index}`),
));
let recoveredFailureReported = false;
const recoveredSessionId = "pi-feed-failure-overflow-recovered";
dispatcher.enqueueFeed("overflow-recovered", {
  args: ["hooks", "feed", "--surface", "00000000-0000-0000-0000-000000008672"],
  cwd: "/tmp/pi-feed-failure-overflow",
  payload: {
    session_id: recoveredSessionId,
    hook_event_name: "PostToolUse",
  },
  context: {
    sessionId: recoveredSessionId,
    cwd: "/tmp/pi-feed-failure-overflow",
  },
  terminal: true,
  onFailure: () => { recoveredFailureReported = true; },
});
await dispatcher.finishFeedForSession(recoveredSessionId);
if (recoveredFailureReported) throw new Error("Feed failure overflow did not recover after draining");
"""
    result = run_extension(
        bun=bun,
        root=root,
        extension_path=inspectable_extension,
        fake_cmux=overflow_cmux,
        source=overflow_source,
        extra_env={"CMUX_TEST_PI_FAILURE_OVERFLOW_RELEASE": str(release_path)},
    )
    if result.returncode != 0:
        print(f"FAIL: Feed failure overflow did not fail closed: {result.stderr!r}")
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


def check_terminal_feed_failure_emits_one_stop(bun: str, root: Path, extension_path: Path) -> int:
    failure_cmux = root / "terminal-feed-failure-cmux"
    make_executable(
        failure_cmux,
        """#!/usr/bin/env python3
import os
import pathlib
import sys

args = " ".join(sys.argv[1:])
payload = sys.stdin.read()
log_path = pathlib.Path(os.environ["CMUX_TEST_PI_FAILURE_LOG"])
with log_path.open("a", encoding="utf-8") as stream:
    stream.write(f"{args}|{payload}\\n")

if "hooks feed" in args and "PostToolUse" in args:
    print("ambiguous feed acknowledgment failure", file=sys.stderr)
    raise SystemExit(42)

print("{}")
""",
    )
    lifecycle_source = """
const extensionPath = process.env.CMUX_TEST_PI_EXTENSION_PATH;
const mod = await import(extensionPath);
const handlers = new Map();
mod.default({ on(name, handler) { handlers.set(name, handler); } });
const ctx = {
  cwd: "/tmp/pi-terminal-feed-failure-project",
  sessionManager: { getSessionId() { return "pi-terminal-feed-failure-session"; } }
};
handlers.get("tool_execution_end")({
  toolCallId: "failure-tool",
  toolName: "bash",
  result: { status: "done" },
  isError: false
}, ctx);
await handlers.get("agent_end")({
  messages: [{ role: "assistant", content: "done" }],
  stopReason: "completed"
}, ctx);
await handlers.get("session_shutdown")({ reason: "quit" }, ctx);
"""

    shutdown_source = """
const extensionPath = process.env.CMUX_TEST_PI_EXTENSION_PATH;
const mod = await import(extensionPath);
const handlers = new Map();
mod.default({ on(name, handler) { handlers.set(name, handler); } });
const ctx = {
  cwd: "/tmp/pi-terminal-feed-shutdown-failure-project",
  sessionManager: { getSessionId() { return "pi-terminal-feed-shutdown-failure-session"; } }
};
handlers.get("tool_execution_end")({
  toolCallId: "shutdown-failure-tool",
  toolName: "bash",
  result: { status: "done" },
  isError: false
}, ctx);
await handlers.get("session_shutdown")({ reason: "quit" }, ctx);
"""

    for label, source in (
        ("settled", lifecycle_source),
        ("shutdown", shutdown_source),
    ):
        log_path = root / f"terminal-feed-{label}-failure.log"
        result = run_extension(
            bun=bun,
            root=root,
            extension_path=extension_path,
            fake_cmux=failure_cmux,
            source=source,
            extra_env={"CMUX_TEST_PI_FAILURE_LOG": str(log_path)},
        )
        if result.returncode != 0:
            print(f"FAIL: terminal-feed {label} failure harness failed: {result.stderr!r}")
            return 1
        calls = log_path.read_text(encoding="utf-8").splitlines()
        feed_calls = [line for line in calls if "hooks feed" in line and "PostToolUse" in line]
        if len(feed_calls) != 1:
            print(f"FAIL: ambiguous terminal-feed {label} delivery was replayed: {calls!r}")
            return 1
        stop_calls = [line for line in calls if "hooks pi stop" in line]
        if len(stop_calls) != 1:
            print(f"FAIL: terminal-feed {label} failure emitted {len(stop_calls)} Stop hooks: {calls!r}")
            return 1
        if any("hooks pi notification" in line for line in calls):
            print(f"FAIL: terminal-feed {label} failure emitted a completion notification: {calls!r}")
            return 1
        if '"message":"cmux terminal feed delivery failed"' not in result.stderr:
            print(f"FAIL: failed terminal-feed {label} delivery was not surfaced: {result.stderr!r}")
            return 1

    return 0


def check_nonterminal_timeout_marks_dropped_completion(
    bun: str,
    root: Path,
    extension_path: Path,
) -> int:
    inspectable_extension = root / "inspectable-cmux-session.ts"
    inspectable_extension.write_text(
        extension_path.read_text(encoding="utf-8")
        + "\nexport { PiCmuxCommandDispatcher };\n",
        encoding="utf-8",
    )
    timeout_source = """
const extensionPath = process.env.CMUX_TEST_PI_EXTENSION_PATH;
const mod = await import(extensionPath);
const dispatcher = new mod.PiCmuxCommandDispatcher();
const context = {
  sessionId: "pi-queued-completion-timeout-session",
  workspaceId: "00000000-0000-0000-0000-000000008673",
  surfaceId: "00000000-0000-0000-0000-000000008672"
};
let resolveActive;
dispatcher.execute = () => new Promise((resolve) => {
  resolveActive = resolve;
});
const startPayload = { session_id: context.sessionId, hook_event_name: "PreToolUse" };
dispatcher.enqueueFeed("timeout-tool", {
  args: ["hooks", "feed", "--source", "pi", "--event", "PreToolUse"],
  cwd: "/tmp/pi-queued-completion-timeout",
  payload: startPayload,
  context,
  terminal: false
});
const completionPayload = { session_id: context.sessionId, hook_event_name: "PostToolUse" };
let completionFailed = false;
dispatcher.enqueueFeed("timeout-tool", {
  args: ["hooks", "feed", "--source", "pi", "--event", "PostToolUse"],
  cwd: "/tmp/pi-queued-completion-timeout",
  payload: completionPayload,
  context,
  terminal: true,
  onFailure: () => { completionFailed = true; }
});
if (!resolveActive) throw new Error("nonterminal feed did not become active");
resolveActive({
  ok: false,
  status: null,
  stdout: "",
  stderr: "",
  error: new Error("cmux command timed out after 5000ms"),
  surfaceUnavailable: false
});
const settleDeadline = Date.now() + 1_000;
while (dispatcher.activeFeeds.size > 0) {
  if (Date.now() >= settleDeadline) throw new Error("timed-out feed did not settle");
  await new Promise((resolve) => setTimeout(resolve, 5));
}
await dispatcher.finishFeedForSession(context.sessionId);
if (!completionFailed) {
  throw new Error("queued terminal completion was discarded as successfully delivered");
}
"""
    result = run_extension(
        bun=bun,
        root=root,
        extension_path=inspectable_extension,
        fake_cmux=Path("/usr/bin/true"),
        source=timeout_source,
        extra_env={},
    )
    if result.returncode != 0:
        print(
            "FAIL: nonterminal timeout accepted a dropped queued completion: "
            f"{result.stderr!r}"
        )
        return 1

    return 0


def check_completion_drain_deadline(bun: str, root: Path, extension_path: Path) -> int:
    deadline_log = root / "completion-deadline-cmux.log"
    deadline_cmux = root / "completion-deadline-cmux"
    make_executable(
        deadline_cmux,
        """#!/usr/bin/env python3
import os
import signal
import sys
import time

args = " ".join(sys.argv[1:])
payload = sys.stdin.read()
with open(os.environ["CMUX_TEST_PI_DEADLINE_LOG"], "a", encoding="utf-8") as stream:
    stream.write(f"{args}|{payload}\\n")
    stream.flush()

if "hooks feed" in args and "PostToolUse" in args:
    def handle_term(_signum, _frame):
        raise SystemExit(88)

    signal.signal(signal.SIGTERM, handle_term)
    while True:
        time.sleep(0.1)

print("{}")
""",
    )
    deadline_source = """
const extensionPath = process.env.CMUX_TEST_PI_EXTENSION_PATH;
const mod = await import(extensionPath);
const handlers = new Map();
mod.default({ on(name, handler) { handlers.set(name, handler); } });
const ctx = {
  cwd: "/tmp/pi-completion-deadline-project",
  sessionManager: { getSessionId() { return "pi-completion-deadline-session"; } }
};
handlers.get("tool_execution_end")({
  toolCallId: "deadline-tool",
  toolName: "bash",
  result: { content: [{ type: "text", text: "done" }] },
  isError: false
}, ctx);
const logPath = process.env.CMUX_TEST_PI_DEADLINE_LOG;
while (!Bun.file(logPath).size) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const startedAt = performance.now();
await handlers.get("agent_end")({
  messages: [{ role: "assistant", content: "done" }],
  stopReason: "completed"
}, ctx);
console.log(`completion_ms=${performance.now() - startedAt}`);
"""
    deadline = run_extension(
        bun=bun,
        root=root,
        extension_path=extension_path,
        fake_cmux=deadline_cmux,
        source=deadline_source,
        extra_env={"CMUX_TEST_PI_DEADLINE_LOG": str(deadline_log)},
    )
    if deadline.returncode != 0:
        print(f"FAIL: completion-drain deadline harness failed: {deadline.stderr!r}")
        return 1
    timing_lines = [line for line in deadline.stdout.splitlines() if line.startswith("completion_ms=")]
    if len(timing_lines) != 1:
        print(f"FAIL: completion-drain harness did not report timing: {deadline.stdout!r}")
        return 1
    elapsed_ms = float(timing_lines[0].split("=", 1)[1])
    if elapsed_ms >= 3_000:
        print(f"FAIL: stalled terminal feed delayed lifecycle completion by {elapsed_ms:.0f}ms")
        return 1
    deadline_calls = deadline_log.read_text(encoding="utf-8").splitlines()
    stop_calls = [line for line in deadline_calls if "hooks pi stop" in line]
    if len(stop_calls) != 1:
        print(f"FAIL: terminal-feed drain deadline emitted {len(stop_calls)} Stop hooks: {deadline_calls!r}")
        return 1
    if any("hooks pi notification" in line for line in deadline_calls):
        print(f"FAIL: terminal-feed drain deadline emitted a completion notification: {deadline_calls!r}")
        return 1
    if '"message":"cmux terminal feed delivery failed"' not in deadline.stderr:
        print(f"FAIL: terminal-feed drain deadline was not surfaced: {deadline.stderr!r}")
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
  printf 'Error: Surface not found\n' >&2
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
payload="$(cat)"
printf '%s|%s\n' "$*" "$payload" >> "$CMUX_TEST_PI_UNSERIALIZABLE_LOG"
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
const circularResult = { value: 1n };
circularResult.self = circularResult;
await handlers.get("tool_execution_end")({
  toolCallId: "bigint-tool",
  toolName: "custom",
  args: { command: "custom", threshold: 2n },
  result: circularResult,
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
    calls = feed_log.read_text(encoding="utf-8").splitlines()
    feed_calls = [line for line in calls if "hooks feed" in line]
    prompt_calls = [line for line in calls if "hooks pi prompt-submit" in line]
    if len(feed_calls) != 1 or len(prompt_calls) != 1:
        print(f"FAIL: unserializable feed was dropped or disrupted lifecycle routing: {calls!r}")
        return 1
    payload = json.loads(feed_calls[0].split("|", 1)[1])
    summary = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    if '"kind":"bigint"' not in summary or '"kind":"circular"' not in summary:
        print(f"FAIL: unserializable Pi values were not safely summarized: {payload!r}")
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
printf 'エラー: 対象を解決できません\n' >&2
exit 69
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
    if len(explicit_calls) != 1 or "hooks pi session-start" not in explicit_calls[0]:
        print(f"FAIL: stale explicit target was retried by Pi lifecycle routing: {explicit_calls!r}")
        return 1
    expected_target = (
        "--workspace 00000000-0000-0000-0000-000000008673 "
        "--surface 00000000-0000-0000-0000-000000008672"
    )
    if expected_target not in explicit_calls[0]:
        print(f"FAIL: Pi lifecycle command omitted its strict surface target: {explicit_calls!r}")
        return 1

    return 0


def check_moved_surface_resume_target(bun: str, root: Path, extension_path: Path) -> int:
    moved_log = root / "moved-surface-resume-cmux.log"
    moved_cmux = root / "moved-surface-resume-cmux"
    make_executable(
        moved_cmux,
        """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CMUX_TEST_PI_MOVED_RESUME_LOG"
cat >/dev/null
if [[ "$*" == *"hooks pi"* ]]; then
  printf '{"workspace_id":"00000000-0000-0000-0000-000000008674","surface_id":"00000000-0000-0000-0000-000000008672"}\n'
else
  printf '{}\n'
fi
""",
    )
    moved_source = """
const extensionPath = process.env.CMUX_TEST_PI_EXTENSION_PATH;
const mod = await import(extensionPath);
const handlers = new Map();
mod.default({ on(name, handler) { handlers.set(name, handler); } });
const ctx = {
  cwd: "/tmp/pi-moved-surface-resume-project",
  sessionManager: { getSessionId() { return "pi-moved-surface-resume-session"; } }
};
await handlers.get("session_start")({}, ctx);
await handlers.get("session_shutdown")({ reason: "quit" }, ctx);
"""
    moved = run_extension(
        bun=bun,
        root=root,
        extension_path=extension_path,
        fake_cmux=moved_cmux,
        source=moved_source,
        extra_env={"CMUX_TEST_PI_MOVED_RESUME_LOG": str(moved_log)},
    )
    if moved.returncode != 0:
        print(f"FAIL: moved-surface resume harness failed: {moved.stderr!r}")
        return 1
    calls = moved_log.read_text(encoding="utf-8").splitlines()
    resume_calls = [line for line in calls if "surface resume" in line]
    if len(resume_calls) != 3:
        print(f"FAIL: moved-surface harness missed resume set/get/clear: {calls!r}")
        return 1
    moved_target = (
        "--workspace 00000000-0000-0000-0000-000000008674 "
        "--surface 00000000-0000-0000-0000-000000008672"
    )
    if any(moved_target not in line for line in resume_calls):
        print(f"FAIL: resume binding reused the surface's stale ambient workspace: {calls!r}")
        return 1

    return 0


def check_failed_resume_clear_releases_session_runtime(
    bun: str,
    root: Path,
    extension_path: Path,
) -> int:
    log_path = root / "failed-resume-clear.log"
    fake_cmux = root / "failed-resume-clear-cmux"
    make_executable(
        fake_cmux,
        """#!/usr/bin/env bash
set -euo pipefail
args="$*"
cat >/dev/null
printf '%s\n' "$args" >> "$CMUX_TEST_PI_FAILED_CLEAR_LOG"
if [[ "$args" == *"hooks pi session-start"* ]]; then
  printf '{"workspace_id":"00000000-0000-0000-0000-000000008673","surface_id":"00000000-0000-0000-0000-000000008672"}\n'
elif [[ "$args" == *"surface resume get"* ]]; then
  printf '{"resume_binding":{"kind":"pi","checkpoint_id":"pi-failed-clear-session"}}\n'
elif [[ "$args" == *"surface resume clear"* ]]; then
  printf 'temporary clear failure\n' >&2
  exit 42
else
  printf '{}\n'
fi
""",
    )
    inspectable_extension = root / "failed-resume-clear-session.ts"
    inspectable_extension.write_text(
        extension_path.read_text(encoding="utf-8")
        + "\nexport { releaseSessionRuntime, surfaceTargetsFor };\n",
        encoding="utf-8",
    )
    source = """
const extensionPath = process.env.CMUX_TEST_PI_EXTENSION_PATH;
const mod = await import(extensionPath);
const handlers = new Map();
mod.default({ on(name, handler) { handlers.set(name, handler); } });
const ctx = {
  cwd: "/tmp/pi-failed-clear-project",
  sessionManager: { getSessionId() { return "pi-failed-clear-session"; } }
};
await handlers.get("session_start")({}, ctx);
await handlers.get("session_shutdown")({ reason: "done" }, ctx);
process.env.CMUX_WORKSPACE_ID = "00000000-0000-0000-0000-000000009673";
process.env.CMUX_SURFACE_ID = "00000000-0000-0000-0000-000000009672";
await handlers.get("before_agent_start")({ prompt: "new target" }, ctx);

const probeDispatcher = { releaseSession() {} };
const probeStates = new Map([["probe-session", { stopped: true }]]);
mod.surfaceTargetsFor(probeDispatcher).set("probe-session", ["--surface", "old"]);
mod.releaseSessionRuntime(probeDispatcher, probeStates, "probe-session");
if (probeStates.has("probe-session")) throw new Error("session state survived runtime release");
if (mod.surfaceTargetsFor(probeDispatcher).has("probe-session")) {
  throw new Error("resolved surface target survived runtime release");
}
"""
    result = run_extension(
        bun=bun,
        root=root,
        extension_path=inspectable_extension,
        fake_cmux=fake_cmux,
        source=source,
        extra_env={"CMUX_TEST_PI_FAILED_CLEAR_LOG": str(log_path)},
    )
    if result.returncode != 0:
        print(f"FAIL: failed resume clear retained Pi runtime state: {result.stderr!r}")
        return 1
    calls = log_path.read_text(encoding="utf-8").splitlines()
    prompt_calls = [line for line in calls if "hooks pi prompt-submit" in line]
    expected_new_target = (
        "--workspace 00000000-0000-0000-0000-000000009673 "
        "--surface 00000000-0000-0000-0000-000000009672"
    )
    if len(prompt_calls) != 1 or expected_new_target not in prompt_calls[0]:
        print(f"FAIL: failed resume clear retained the old resolved target: {calls!r}")
        return 1
    if '"message":"failed to clear Pi resume binding"' not in result.stderr:
        print(f"FAIL: failed resume clear was not reported: {result.stderr!r}")
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
  printf 'エラー: 対象を解決できません\n' >&2
  exit 69
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


def check_session_isolation_within_runtime(bun: str, root: Path, extension_path: Path) -> int:
    session_log = root / "session-isolation-cmux.log"
    session_cmux = root / "session-isolation-cmux"
    make_executable(
        session_cmux,
        """#!/usr/bin/env bash
set -euo pipefail
payload="$(cat)"
printf '%s|%s\n' "$*" "$payload" >> "$CMUX_TEST_PI_SESSION_ISOLATION_LOG"
if [[ "$payload" == *'"session_id":"pi-session-stale"'* ]]; then
  printf 'stale surface\n' >&2
  exit 69
fi
printf '{}\n'
""",
    )
    session_source = """
const extensionPath = process.env.CMUX_TEST_PI_EXTENSION_PATH;
const mod = await import(extensionPath);
const handlers = new Map();
mod.default({ on(name, handler) { handlers.set(name, handler); } });
const context = (sessionId) => ({
  cwd: "/tmp/pi-session-isolation-project",
  sessionManager: { getSessionId() { return sessionId; } },
});
await handlers.get("before_agent_start")(
  { prompt: "stale session" },
  context("pi-session-stale"),
);
await handlers.get("before_agent_start")(
  { prompt: "stale session retry" },
  context("pi-session-stale"),
);
await handlers.get("before_agent_start")(
  { prompt: "healthy session" },
  context("pi-session-healthy"),
);
"""
    result = run_extension(
        bun=bun,
        root=root,
        extension_path=extension_path,
        fake_cmux=session_cmux,
        source=session_source,
        extra_env={"CMUX_TEST_PI_SESSION_ISOLATION_LOG": str(session_log)},
    )
    if result.returncode != 0:
        print(f"FAIL: same-runtime session isolation harness failed: {result.stderr!r}")
        return 1
    calls = session_log.read_text(encoding="utf-8").splitlines()
    if len(calls) != 2 or "pi-session-healthy" not in calls[-1]:
        print(f"FAIL: stale surface disabled another Pi session in the same runtime: {calls!r}")
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
printf 'エラー: 対象を解決できません\n' >&2
exit 69
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
        check_panel_only_target_fails_closed,
        check_feed_backlog,
        check_terminal_feed_compaction,
        check_feed_payload_byte_bound,
        check_cross_session_feed_ownership,
        check_cross_session_feed_isolation,
        check_feed_ack_rehomes_cached_target,
        check_aggregate_feed_bound,
        check_feed_failure_overflow_fails_closed,
        check_feed_cancellation,
        check_completion_order,
        check_terminal_feed_failure_emits_one_stop,
        check_nonterminal_timeout_marks_dropped_completion,
        check_completion_drain_deadline,
        check_timeout_serialization,
        check_error_classification,
        check_unserializable_feed,
        check_explicit_surface_routing,
        check_moved_surface_resume_target,
        check_failed_resume_clear_releases_session_runtime,
        check_runtime_isolation,
        check_session_isolation_within_runtime,
        check_stale_surface,
    )
    for check in checks:
        if check(bun, root, extension_path) != 0:
            return 1
    print("PASS: Pi dispatch stays responsive, serialized, and fails stale surfaces once")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
