#!/usr/bin/env python3
"""Exercise the canonical OpenCode plugin against an isolated Unix socket."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    bun = shutil.which("bun")
    if not bun:
        raise SystemExit("Bun is required for the native OpenCode plugin behavior harness")
    with tempfile.TemporaryDirectory(prefix="cmux-opencode-runtime-") as temporary:
        directory = Path(temporary)
        socket_path = directory / "runtime.sock"
        harness = directory / "runtime.mjs"
        harness.write_text(r'''
import assert from "node:assert/strict";
import net from "node:net";
import { CMUXFeed } from "PLUGIN_URL";

const queue = [], waiters = [], connections = new Set();
const frames = [];
const deadline = setTimeout(() => { console.error("Plugin socket behavior deadline exceeded"); process.exit(1); }, 10000);
const server = net.createServer(connection => {
  connections.add(connection);
  let buffer = "";
  connection.setEncoding("utf8");
  connection.on("data", chunk => {
    buffer += chunk;
    let index;
    while ((index = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, index); buffer = buffer.slice(index + 1);
      if (!line) continue;
      const frame = JSON.parse(line); frames.push(frame);
      if (waiters.length) waiters.shift()(frame); else queue.push(frame);
    }
  });
});
await new Promise((resolve, reject) => { server.once("error", reject); server.listen(process.env.CMUX_SOCKET_PATH, resolve); });
const next = () => queue.length ? Promise.resolve(queue.shift()) : new Promise(resolve => waiters.push(resolve));
let sdkCalls = 0;
const plugin = await CMUXFeed({ directory: "/isolated-project", client: { question: { reply: async () => { sdkCalls++; } } } });
const emit = (type, properties) => plugin.event({ event: { type, properties } });
const take = async () => {
  const frame = await next();
  assert.equal(frame.method, "feed.push");
  assert.equal(frame.params.event.session_id, "opencode-exact-session");
  assert.equal(frame.params.event._source, "opencode");
  assert.equal(frame.params.event._ppid, process.pid);
  assert.equal(frame.params.event.workspace_id, undefined);
  assert.equal(frame.params.event.surface_id, undefined);
  assert.equal(typeof frame.params.event.event_id, "string");
  assert.equal(typeof frame.params.event.occurred_at_ms, "number");
  return frame.params.event;
};

await emit("session.updated", { sessionID: "exact-session", agent: "plan" });
let event = await take();
assert.equal(event.declared_mode, "plan");
assert.equal(event.declared_activity, undefined);
assert.equal(event.hook_event_name, "Notification");
await emit("session.updated", { sessionID: "exact-session", agent: "plan" });
await emit("session.status", { sessionID: "exact-session", status: { type: "busy" } });
event = await take();
assert.equal(event.declared_activity, "working");
assert.equal(event.declared_mode, undefined);
await emit("session.status", { sessionID: "exact-session", status: { type: "retry" } });
event = await take();
assert.equal(event.declared_activity, "waiting");
assert.equal(event.declared_reason, "networkRetry");
await emit("session.status", { sessionID: "exact-session", status: { type: "idle" } });
assert.equal((await take()).hook_event_name, "Stop");
await emit("session.updated", { sessionID: "exact-session", agent: "build" });
event = await take();
assert.equal(event.declared_mode, "execution");
assert.equal(event.declared_activity, undefined);

const pending = emit("question.asked", { sessionID: "exact-session", id: "exact-question", questions: [{ question: "Choose an option", options: [{ label: "A" }, { label: "B" }] }] });
event = await take();
assert.equal(event.hook_event_name, "AskUserQuestion");
assert.equal(event._opencode_request_id, "exact-question");
await emit("question.rejected", { sessionID: "exact-session", requestID: "exact-question" });
event = await take();
assert.equal(event.hook_event_name, "PostToolUse");
assert.equal(event._opencode_request_id, "exact-question");
assert.equal(event.pending_work, false);
await pending;
assert.equal(sdkCalls, 0);
const pendingReply = emit("question.asked", { sessionID: "exact-session", id: "second-question", questions: [{ question: "Choose", options: [{ label: "A" }] }] });
assert.equal((await take())._opencode_request_id, "second-question");
await emit("question.replied", { sessionID: "exact-session", requestID: "second-question" });
assert.equal((await take())._opencode_request_id, "second-question");
await pendingReply;
await emit("session.error", { sessionID: "exact-session" });
event = await take();
assert.equal(event.hook_event_name, "PostToolUseFailure");
assert.equal(event.declared_activity, "failed");
await emit("session.deleted", { sessionID: "exact-session" });
assert.equal((await take()).hook_event_name, "SessionEnd");
assert.equal(new Set(frames.map(frame => frame.params.event.event_id)).size, frames.length);
assert.equal(new Set(frames.map(frame => frame.id)).size, frames.length);
clearTimeout(deadline);
for (const connection of connections) connection.destroy();
server.close();
console.log(JSON.stringify({ passed: true, frames: frames.length, sdkCalls }));
process.exit(0);
'''.replace("PLUGIN_URL", (root / "Resources/opencode-plugin.js").as_uri()))
        environment = dict(os.environ, CMUX_SOCKET_PATH=str(socket_path), CMUX_WORKSPACE_ID="stale-daemon-workspace", CMUX_SURFACE_ID="stale-daemon-surface")
        completed = subprocess.run([bun, str(harness)], env=environment, text=True, capture_output=True, timeout=15)
        if completed.returncode:
            raise SystemExit(completed.stderr or completed.stdout)
        result = json.loads(completed.stdout.strip())
        assert result["passed"] and result["frames"] == 11 and result["sdkCalls"] == 0
        print(f"OpenCode native socket semantics passed ({result['frames']} frames)")


if __name__ == "__main__":
    main()
