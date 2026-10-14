#!/usr/bin/env python3
"""Released OpenCode loads cmux through each plugin's default `server` entry.

OpenCode 1.x (including the current dev channel) calls `default.server(ctx)`
inside the TUI process with `{ client, project, worktree, directory,
serverUrl, $ }` and delivers events through the returned `event` hook. It
loads `cmux-feed.js`, `cmux-session.js` and `plugins/cmux/index.js`, so the
server entries must deliver one Stop per turn instead of returning `{}`.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def session_plugin_source() -> str:
    swift = (ROOT / "CLI/cmux.swift").read_text(encoding="utf-8")
    match = re.search(r'openCodeSessionPluginSource = #"""\n(.*?)\n"""#', swift, re.S)
    if match is None:
        raise RuntimeError("openCodeSessionPluginSource not found")
    return match.group(1)


HARNESS = r'''
const { pluginDir, logPath, socketPath, fakeCmux } = JSON.parse(process.env.CMUX_OPENCODE_SERVER_HARNESS);
const fs = await import("node:fs");
const net = await import("node:net");
const path = await import("node:path");

const frames = [];
const server = net.createServer((connection) => {
  connection.setEncoding("utf8");
  connection.on("error", () => {});
  let buffered = "";
  connection.on("data", (chunk) => {
    buffered += chunk;
    let index;
    while ((index = buffered.indexOf("\n")) >= 0) {
      const line = buffered.slice(0, index);
      buffered = buffered.slice(index + 1);
      if (!line) continue;
      const frame = JSON.parse(line);
      frames.push(frame);
      connection.write(JSON.stringify({ id: frame.id, ok: true, result: {} }) + "\n");
    }
  });
});
await new Promise((resolve) => server.listen(socketPath, resolve));

// Shape observed from OpenCode 1.19.0 and the dev channel.
const ctx = {
  client: {},
  project: { id: "project" },
  worktree: "/tmp",
  directory: "/tmp",
  experimental_workspace: {},
  serverUrl: new URL("http://127.0.0.1:4096"),
  $: () => {},
};

// Old V2 snapshots called setup()/server() without the server context; they
// must stay inert because their shared service is not owned by one TUI.
const v2 = await import(path.join(pluginDir, "cmux", "index.js"));
const v2Hooks = await v2.default.server({});
if (v2Hooks && typeof v2Hooks.event === "function") throw new Error("V2 shared server entry subscribed");
const v2Cleanup = await v2.default.setup({});
if (typeof v2Cleanup !== "function") throw new Error("V2 setup did not return cleanup");
v2Cleanup();

const { execFileSync } = await import("node:child_process");
const hookLog = () => (fs.existsSync(logPath) ? fs.readFileSync(logPath, "utf8") : "");
const fakeCmuxRunning = () => {
  try {
    execFileSync("pgrep", ["-f", fakeCmux], { stdio: "ignore" });
    return true;
  } catch (_) {
    return false;
  }
};
const waitFor = async (predicate, message) => {
  const deadline = Date.now() + 5000;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error(message);
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
};

// Load the three cmux entries for one plugin scope and drive one turn. The
// session.deleted sentinel follows the duplicate-prone idle events: socket
// frames are ordered, and every hook process is spawned before the sentinel's.
const runScope = async (scopeCtx, sid) => {
  const hooks = [];
  for (const file of ["cmux-feed.js", "cmux-session.js", path.join("cmux", "index.js")]) {
    const mod = await import(path.join(pluginDir, file));
    if (typeof mod.default?.server !== "function") throw new Error(`${file} lacks a server entry`);
    hooks.push(await mod.default.server(scopeCtx, {}));
  }
  const active = hooks.filter((hook) => hook && typeof hook.event === "function");
  if (active.length === 0) throw new Error("no OpenCode server entry subscribed to events");
  const emit = async (event) => {
    for (const hook of active) await hook.event({ event });
  };
  await emit({ type: "session.created", properties: { info: { id: sid, directory: "/tmp" } } });
  await emit({ type: "session.status", properties: { sessionID: sid, status: { type: "busy" } } });
  await emit({ type: "session.status", properties: { sessionID: sid, status: { type: "idle" } } });
  await emit({ type: "session.idle", properties: { sessionID: sid } });
  await emit({ type: "session.deleted", properties: { info: { id: sid } } });

  const forSession = (frame) => frame.params?.event?.session_id === `opencode-${sid}`;
  await waitFor(
    () => frames.some((frame) => forSession(frame) && frame.params.event.hook_event_name === "SessionEnd"),
    `feed sentinel never arrived for ${sid}: ${JSON.stringify(frames)}`,
  );
  const sessionEnds = () => hookLog().split("\n").filter((line) => line.includes("opencode session-end")).length;
  await waitFor(() => sessionEnds() >= runs + 1, `session-end hook never ran for ${sid}`);
  await waitFor(() => !fakeCmuxRunning(), "hook processes did not exit");
  const stops = frames.filter((frame) => forSession(frame) && frame.params.event.hook_event_name === "Stop");
  if (stops.length !== 1) throw new Error(`expected one feed Stop for ${sid}, got ${stops.length}: ${JSON.stringify(frames)}`);
  if (stops[0].params.event.surface_id !== "surface-server-entry") throw new Error("feed Stop lost the surface id");
  return active;
};

let runs = 0;
const first = await runScope(ctx, "ses_server_entry");
runs++;
// OpenCode can reinitialize a plugin scope in the same process; the new scope
// gets a new ctx and must subscribe again.
await runScope({ ...ctx }, "ses_server_entry_reinit");
runs++;
// The replaced scope's hooks stay registered in OpenCode; they must not emit.
const stale = "ses_server_entry_stale";
for (const event of [
  { type: "session.created", properties: { info: { id: stale, directory: "/tmp" } } },
  { type: "session.status", properties: { sessionID: stale, status: { type: "busy" } } },
  { type: "session.idle", properties: { sessionID: stale } },
]) {
  for (const hook of first) await hook.event({ event });
}
// Hook processes are spawned synchronously inside event(); wait for them.
await waitFor(() => !fakeCmuxRunning(), "hook processes did not exit");
if (frames.some((frame) => frame.params?.event?.session_id === `opencode-${stale}`)) {
  throw new Error("replaced feed scope still emitted events");
}
const hookStops = hookLog().split("\n").filter((line) => line.includes("hooks enqueue opencode stop"));
if (hookStops.length !== 2) throw new Error(`expected one stop hook per turn, got ${hookStops.length}: ${hookLog()}`);
for (const hook of first) hook.dispose?.();
server.close();
console.log("PASS: OpenCode server entry delivers one completion");
process.exit(0);
'''


def main() -> int:
    node = shutil.which("node")
    if node is None:
        print("SKIP: node not found")
        return 0
    with tempfile.TemporaryDirectory(prefix="cmux-opencode-server-") as td:
        root = Path(td)
        plugin_dir = root / "plugins"
        package_dir = plugin_dir / "cmux"
        package_dir.mkdir(parents=True)
        feed_source = (ROOT / "Resources/opencode-plugin.js").read_text(encoding="utf-8")
        (plugin_dir / "cmux-feed.js").write_text(feed_source, encoding="utf-8")
        (plugin_dir / "cmux-session.js").write_text(session_plugin_source(), encoding="utf-8")
        (package_dir / "index.js").write_text(
            "// cmux-opencode-tui-plugin-server-marker v2\n" + feed_source, encoding="utf-8"
        )
        (plugin_dir / "package.json").write_text('{"type":"module"}', encoding="utf-8")
        (package_dir / "package.json").write_text('{"type":"module"}', encoding="utf-8")
        log_path = root / "cmux.log"
        fake_cmux = root / "cmux"
        fake_cmux.write_text(f'#!/bin/sh\necho "$*" >> "{log_path}"\ncat >/dev/null\n', encoding="utf-8")
        fake_cmux.chmod(0o755)
        socket_path = str(root / "cmux.sock")
        env = os.environ.copy()
        env.update(
            CMUX_SURFACE_ID="surface-server-entry",
            CMUX_WORKSPACE_ID="workspace-server-entry",
            CMUX_SOCKET_PATH=socket_path,
            CMUX_OPENCODE_CMUX_BIN=str(fake_cmux),
            CMUX_OPENCODE_HOOKS_DISABLED="",
            CMUX_OPENCODE_SERVER_HARNESS=json.dumps(
                {"pluginDir": str(plugin_dir), "logPath": str(log_path), "socketPath": socket_path, "fakeCmux": str(fake_cmux)}
            ),
        )
        harness = root / "harness.mjs"
        harness.write_text(HARNESS, encoding="utf-8")
        try:
            result = subprocess.run([node, str(harness)], env=env, capture_output=True, text=True, timeout=30)
        finally:
            try:
                os.unlink(socket_path)
            except FileNotFoundError:
                pass
        sys_out = (result.stdout + result.stderr).strip()
        if result.returncode != 0:
            print(f"FAIL: {sys_out[-3000:]}")
            return 1
        print(sys_out)
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
