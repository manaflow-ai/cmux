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
const { pluginDir, logPath, socketPath } = JSON.parse(process.env.CMUX_OPENCODE_SERVER_HARNESS);
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

const hooks = [];
for (const file of ["cmux-feed.js", "cmux-session.js", path.join("cmux", "index.js")]) {
  const mod = await import(path.join(pluginDir, file));
  if (typeof mod.default?.server !== "function") throw new Error(`${file} lacks a server entry`);
  hooks.push(await mod.default.server(ctx, {}));
}
const active = hooks.filter((hook) => hook && typeof hook.event === "function");
if (active.length === 0) throw new Error("no OpenCode server entry subscribed to events");

const emit = async (event) => {
  for (const hook of active) await hook.event({ event });
};
const sid = "ses_server_entry";
await emit({ type: "session.created", properties: { info: { id: sid, directory: "/tmp" } } });
await emit({ type: "session.status", properties: { sessionID: sid, status: { type: "busy" } } });
await emit({ type: "session.status", properties: { sessionID: sid, status: { type: "idle" } } });
await emit({ type: "session.idle", properties: { sessionID: sid } });

const deadline = Date.now() + 5000;
const stopFrames = () => frames.filter((frame) => frame.params?.event?.hook_event_name === "Stop");
const hookLog = () => (fs.existsSync(logPath) ? fs.readFileSync(logPath, "utf8") : "");
while (Date.now() < deadline && (stopFrames().length === 0 || !hookLog().includes("hooks enqueue opencode stop"))) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
// Give duplicate deliveries a chance to arrive before counting.
await new Promise((resolve) => setTimeout(resolve, 200));
const stops = stopFrames();
if (stops.length !== 1) throw new Error(`expected one feed Stop, got ${stops.length}: ${JSON.stringify(frames)}`);
if (stops[0].params.event.surface_id !== "surface-server-entry") throw new Error("feed Stop lost the surface id");
const hookStops = hookLog().split("\n").filter((line) => line.includes("hooks enqueue opencode stop"));
if (hookStops.length !== 1) throw new Error(`expected one stop hook, got ${hookStops.length}: ${hookLog()}`);
for (const hook of active) hook.dispose?.();
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
        socket_path = f"/tmp/cmux-oc-server-{os.getpid()}.sock"
        env = os.environ.copy()
        env.update(
            CMUX_SURFACE_ID="surface-server-entry",
            CMUX_WORKSPACE_ID="workspace-server-entry",
            CMUX_SOCKET_PATH=socket_path,
            CMUX_OPENCODE_CMUX_BIN=str(fake_cmux),
            CMUX_OPENCODE_HOOKS_DISABLED="",
            CMUX_OPENCODE_SERVER_HARNESS=json.dumps(
                {"pluginDir": str(plugin_dir), "logPath": str(log_path), "socketPath": socket_path}
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
