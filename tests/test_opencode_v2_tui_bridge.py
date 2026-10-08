#!/usr/bin/env python3
"""Focused behavioral coverage for the OpenCode V2 per-TUI bridge."""
from __future__ import annotations
import json
import os
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    node = shutil.which("node")
    if node is None:
        print("SKIP: node not found")
        return 0
    fixture = json.loads((ROOT / "tests/fixtures/opencode-v2-multi-tui.json").read_text())
    source = r'''
const { source, fixture } = JSON.parse(process.env.CMUX_OPENCODE_V2_HARNESS);
const socketPath = "/tmp/cmux-opencode-v2-" + process.pid + ".sock";
process.env.CMUX_SOCKET_PATH = socketPath;
const mod = await import("data:text/javascript;base64," + Buffer.from(source).toString("base64"));
const makeContext = (name) => {
  const spec = fixture.tuis[name];
  return {
    ui: {
      router: { current: () => spec.route },
      tabs: { enabled: () => true, list: () => spec.tabs.map((id) => ({ sessionID: id })) },
    },
    data: { session: { root: (id) => fixture.roots[id] || id } },
  };
};
if (!await mod.sessionBelongsToTUI(makeContext("a"), "child-a")) throw new Error("TUI A lost its own session");
if (await mod.sessionBelongsToTUI(makeContext("a"), "child-b")) throw new Error("TUI A claimed TUI B session");
const closed = { ui: { router: { current: () => fixture.starterClosed.route }, tabs: { enabled: () => true, list: () => [] } }, data: { session: { root: (id) => fixture.roots[id] || id } } };
if (await mod.sessionBelongsToTUI(closed, "child-a")) throw new Error("closed starter surface retained ownership");
let spawnCalls = 0;
const fakeSpawn = () => {
  spawnCalls++;
  return { stdin: { end() {}, on() { return this; } }, on() { return this; }, unref() {} };
};
mod.dispatchSessionHook("stop", { session_id: "opencode-child-a", cwd: "/tmp" }, fakeSpawn);
if (source.includes("spawnSync")) throw new Error("shared bridge still uses synchronous spawn");
if (spawnCalls !== 1) throw new Error("session admission did not use async spawn");
if (!source.includes("data.listen") || !source.includes("client.permission.reply") || !source.includes("session.form.reply")) throw new Error("V2 Feed/reply bridge is incomplete");
const net = await import("node:net");
try { await (await import("node:fs/promises")).unlink(socketPath); } catch (_) {}
const server = net.createServer((connection) => {
  connection.setEncoding("utf8");
  connection.on("data", (chunk) => {
    const frame = JSON.parse(chunk.trim());
    const event = frame.params.event;
    const decision = event.hook_event_name === "PermissionRequest"
      ? { kind: "permission", mode: "once" }
      : { kind: "question", selections: { choice: "yes" } };
    connection.end(JSON.stringify({ result: { request_id: event._opencode_request_id, status: "resolved", decision } }) + "\n");
  });
});
await new Promise((resolve) => server.listen(socketPath, resolve));
const replies = { permission: null, form: null };
let listen;
const live = makeContext("a");
live.location = { directory: "/tmp/project" };
live.data.listen = (callback) => { listen = callback; return () => {}; };
live.client = { permission: { reply: async (value) => { replies.permission = value; } } };
live.data.session.form = { reply: async (value, location) => { replies.form = { value, location }; } };
const cleanup = mod.createCMUXTUIBridge(live);
listen({ details: { type: "permission.asked", data: { sessionID: "child-a", permission: { id: "perm-1", action: "edit" } } } });
for (let i = 0; i < 50 && !replies.permission; i++) await new Promise((resolve) => setTimeout(resolve, 5));
if (replies.permission?.sessionID !== "child-a" || replies.permission?.requestID !== "perm-1") throw new Error("permission reply was not scoped to owning TUI");
listen({ details: { type: "form.created", data: { sessionID: "child-a", form: { id: "form-1", fields: [] } } } });
for (let i = 0; i < 50 && !replies.form; i++) await new Promise((resolve) => setTimeout(resolve, 5));
if (replies.form?.value?.sessionID !== "child-a" || replies.form?.value?.formID !== "form-1") throw new Error("form reply was not scoped to owning TUI");
cleanup();
server.close();
console.log("PASS");
'''
    env = os.environ.copy()
    env["CMUX_OPENCODE_V2_HARNESS"] = json.dumps({"source": (ROOT / "Resources/opencode-tui-plugin.js").read_text(), "fixture": fixture})
    result = subprocess.run([node, "--input-type=module", "-e", source], cwd=ROOT, env=env, text=True, capture_output=True, check=False, timeout=20)
    if result.returncode:
        print("FAIL: OpenCode V2 TUI bridge harness")
        print(result.stdout)
        print(result.stderr)
        return 1
    print(result.stdout.strip() or "PASS: OpenCode V2 TUI bridge")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
