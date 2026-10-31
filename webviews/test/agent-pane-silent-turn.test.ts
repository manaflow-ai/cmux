// An OpenCode free model that stalled left the chat on "Thinking" with no end and no sign why.
// acpmux logs `turn_silent` when a turn's agent has said nothing since its prompt past
// `silentTurnMs` (hub/silent_turn.rs); the pane's snapshot carries it (direct.ts `silentTurn`), so
// the turn's line says "No response from the model yet" (waitingOn.ts) until acpmux hears the
// model (`turn_heard`) or the turn ends. The agent's own bookkeeping (usage, commands) is no answer.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";

const CHAT = "0190a000-0000-7000-8000-0000000000f1";
const START = Date.UTC(2026, 9, 21, 9, 0, 0);
type Step = [dir: string, kind: string, msg: Record<string, unknown>];
const record = (steps: Step[], from = 1) =>
  steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: from + index,
    at: START + (from + index) * 1000,
    dir,
    kind,
    msg,
  }));
type Recorded = ReturnType<typeof record>[number];

/// A daemon over a fake socket: attach answers with `history`; `push` sends live events.
function fakeDaemon(history: Recorded[]) {
  let socket: any;
  const session = {
    sessionId: CHAT,
    cwd: "/Users/dev/app",
    title: "x",
    harness: "opencode",
    family: "opencode",
    status: "running",
  };
  const lastSeq = () => history.at(-1)?.seq ?? 0;
  const answer = (method: string) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: lastSeq(), events: history, hasMore: false };
      case "_acpmux/events":
        return { events: [], hasMore: false, more: false, lastSeq: lastSeq() };
      default:
        return null;
    }
  };
  const open = () => {
    socket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id !== undefined)
          queueMicrotask(() =>
            socket.onmessage?.({
              data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }),
            }),
          );
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  const push = (events: Recorded[]) => {
    for (const event of events) {
      history.push(event);
      socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }) });
    }
  };
  return { open, push };
}

/// Yields until `ready()` holds; fails after 2 s with what it waited for.
async function until(ready: () => boolean, what: string) {
  const deadline = performance.now() + 2_000;
  while (!ready()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}

const started: Step = ["mux", "turn_started", { turnId: "t1" }];
const silent: Step = ["mux", "turn_silent", { turnId: "t1", silentMs: 90_000 }];
const heard: Step = ["mux", "turn_heard", { turnId: "t1" }];
const usage: Step = [
  "in",
  "usage_update",
  { method: "session/update", params: { update: { sessionUpdate: "usage_update", used: 12, size: 200_000 } } },
];
const word: Step = [
  "in",
  "agent_message_chunk",
  {
    method: "session/update",
    params: { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Here" } } },
  },
];

test("a turn whose model said nothing says so until acpmux hears the model", async () => {
  const daemon = fakeDaemon(record([["mux", "user_message", { text: "fix the build" }], started]));
  let snapshot: any;
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (next: any) => (snapshot = next),
    undefined,
    daemon.open,
  );
  try {
    await until(() => snapshot?.connection === "connected", "the attach");
    expect(snapshot.isWorking).toBe(true);
    expect(snapshot.silentTurn).toBeUndefined();
    daemon.push(record([silent], 3));
    await until(() => snapshot.silentTurn === true, "the silent turn");
    // The agent's bookkeeping is no answer.
    daemon.push(record([usage], 4));
    await until(() => snapshot.summary?.usage?.used === 12, "the usage");
    expect(snapshot.silentTurn).toBe(true);
    // acpmux hearing the model ends it.
    daemon.push(record([heard, word], 5));
    await until(() => snapshot.silentTurn === undefined, "the model's word");
    // So does the turn's end.
    daemon.push(record([silent], 7));
    await until(() => snapshot.silentTurn === true, "the second silence");
    daemon.push(record([["mux", "turn_result", { status: "cancelled" }]], 8));
    await until(() => snapshot.silentTurn === undefined, "the turn's end");
  } finally {
    client.close();
  }
});

test("a silence replayed from a turn that already ended is not drawn", async () => {
  const daemon = fakeDaemon(
    record([started, silent, ["mux", "turn_result", { status: "failed" }], ["mux", "turn_silent", { turnId: "t0" }]]),
  );
  let snapshot: any;
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (next: any) => (snapshot = next),
    undefined,
    daemon.open,
  );
  try {
    await until(() => snapshot?.connection === "connected", "the attach");
    expect(snapshot.silentTurn).toBeUndefined();
  } finally {
    client.close();
  }
});
