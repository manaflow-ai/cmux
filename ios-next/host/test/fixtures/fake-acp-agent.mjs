// Fake ACP agent over stdio (newline-delimited JSON-RPC) for tests.
import { createInterface } from "node:readline";

let nextId = 1000;
const pending = new Map();
const send = (msg) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...msg }) + "\n");
const notify = (sessionId, update) => send({ method: "session/update", params: { sessionId, update } });
const request = (method, params) =>
  new Promise((resolve) => {
    const id = nextId++;
    pending.set(id, resolve);
    send({ id, method, params });
  });

let sessions = 0;
let cancelled = false;

async function prompt(id, params) {
  const sid = params.sessionId;
  const text = params.prompt.map((b) => b.text ?? "").join(" ");
  cancelled = false;
  if (text.includes("spawn")) {
    notify(sid, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "On it.\n\nStarting an agent now.\n/spawn codex fix the flaky test" } });
    send({ id, result: { stopReason: "end_turn" } });
    return;
  }
  notify(sid, { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "Thinking " } });
  notify(sid, { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "hard." } });
  notify(sid, { sessionUpdate: "plan", entries: [{ content: "Edit file", priority: "high", status: "in_progress" }] });
  notify(sid, { sessionUpdate: "tool_call", toolCallId: "t1", title: "Edit a.txt", kind: "edit", status: "pending", locations: [{ path: "/tmp/a.txt", line: 3 }], rawInput: { path: "/tmp/a.txt" } });
  if (text.includes("permission")) {
    const res = await request("session/request_permission", {
      sessionId: sid,
      toolCall: { toolCallId: "t1", title: "Edit a.txt" },
      options: [
        { optionId: "allow", name: "Allow", kind: "allow_once" },
        { optionId: "deny", name: "Deny", kind: "reject_once" },
      ],
    });
    notify(sid, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `permission:${res.outcome.outcome}:${res.outcome.optionId ?? ""} ` } });
  }
  notify(sid, { sessionUpdate: "tool_call_update", toolCallId: "t1", status: "completed", content: [{ type: "diff", path: "/tmp/a.txt", oldText: "a", newText: "b" }, { type: "content", content: { type: "text", text: "done" } }] });
  notify(sid, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Hello " } });
  notify(sid, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "world." } });
  notify(sid, { sessionUpdate: "available_commands_update", availableCommands: [{ name: "review", description: "Review code" }] });
  send({ id, result: { stopReason: cancelled ? "cancelled" : "end_turn" } });
}

createInterface({ input: process.stdin }).on("line", (line) => {
  if (!line.trim()) return;
  const msg = JSON.parse(line);
  if (msg.method === undefined && msg.id !== undefined) {
    pending.get(msg.id)?.(msg.result);
    pending.delete(msg.id);
    return;
  }
  switch (msg.method) {
    case "initialize":
      send({ id: msg.id, result: { protocolVersion: 1, agentCapabilities: { loadSession: false }, authMethods: [] } });
      break;
    case "session/new":
      sessions += 1;
      send({
        id: msg.id,
        result: {
          sessionId: `fake-${sessions}`,
          modes: { currentModeId: "default", availableModes: [{ id: "default", name: "Default" }, { id: "plan", name: "Plan" }] },
        },
      });
      break;
    case "session/prompt":
      void prompt(msg.id, msg.params);
      break;
    case "session/set_mode":
      send({ id: msg.id, result: {} });
      break;
    case "session/cancel":
      cancelled = true;
      break;
    default:
      if (msg.id !== undefined) send({ id: msg.id, error: { code: -32601, message: `no ${msg.method}` } });
  }
});
