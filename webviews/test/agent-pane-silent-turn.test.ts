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
function fakeDaemon(history: Recorded[], details: Record<string, unknown> = {}) {
  let socket: any;
  const calls: string[] = [];
  const session = {
    sessionId: CHAT,
    cwd: "/Users/dev/app",
    title: "x",
    harness: "opencode",
    family: "opencode",
    status: "running",
    ...details,
  };
  const lastSeq = () => history.at(-1)?.seq ?? 0;
  const answer = (method: string) => {
    switch (method) {
      case "initialize":
        return {
          protocolVersion: 1,
          _meta: {
            acpmux: {
              origin: "local",
              extensions: [],
              operations: [
                "_acpmux/handoff_prepare",
                "_acpmux/handoff_get",
                "_acpmux/handoff_draft",
                "_acpmux/handoff_start",
                "_acpmux/handoff_discard",
              ],
            },
          },
        };
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
        calls.push(message.method);
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
  const change = (fields: Record<string, unknown>) => {
    Object.assign(session, fields);
    socket.onmessage?.({
      data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/session_changed", params: { session } }),
    });
  };
  return { open, push, change, calls };
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
    // A resumed session can expose an old prompt before its new turn_started event. The live clock
    // must use that event's timestamp, rather than the prompt's history timestamp.
    expect(snapshot.turnStartedAtMs).toBe(START + 2_000);
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
    expect(snapshot.isWorking).toBe(false);
    expect(snapshot.turnStartedAtMs).toBeUndefined();
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

test("an attach in the middle of a turn uses the summary start when its event is paged out", async () => {
  const daemon = fakeDaemon(record([["mux", "user_message", { text: "old prompt" }]]), {
    turn: { turnId: "t2", startedAt: START + 30_000 },
  });
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
    expect(snapshot.turnStartedAtMs).toBe(START + 30_000);
    daemon.push(record([["mux", "turn_end", { turnId: "t2" }]], 2));
    await until(() => snapshot.isWorking === false, "the turn's end");
  } finally {
    client.close();
  }
});

test("a newer summary start replaces a previous live turn before its start event arrives", async () => {
  const daemon = fakeDaemon(record([["mux", "user_message", { text: "old prompt" }]]));
  let snapshot: any;
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (next: any) => (snapshot = next),
    undefined,
    daemon.open,
  );
  try {
    await until(() => snapshot?.connection === "connected", "the attach");
    expect(snapshot.turnStartedAtMs).toBeUndefined();
    daemon.change({ title: "next", turn: { turnId: "t2", startedAt: START + 30_000 } });
    await until(() => snapshot.summary?.title === "next", "the newer summary");
    expect(snapshot.turnStartedAtMs).toBe(START + 30_000);
    expect(client.turnRunning()).toBe(true);
    // A late summary of the earlier turn must not move the clock backwards either.
    daemon.change({ title: "earlier", turn: { turnId: "t1", startedAt: START + 1_000 } });
    await until(() => snapshot.summary?.title === "earlier", "the older summary");
    expect(snapshot.turnStartedAtMs).toBe(START + 30_000);
    expect(await client.continueIn("claude")).toBeUndefined();
    expect(daemon.calls.filter((method) => method === "_acpmux/handoff_prepare")).toHaveLength(0);
    daemon.push(record([["mux", "turn_started", { turnId: "t2" }]], 31));
    expect(snapshot.turnStartedAtMs).toBe(START + 31_000);
    await client.cancel();
    expect((client as any).stopAfterSeq).toBe(31);
    // Replaying a terminal event for the old turn must not stop the newer live turn.
    daemon.push(record([["mux", "turn_result", { turnId: "t1", status: "completed" }]], 32));
    expect(snapshot.turnStartedAtMs).toBe(START + 31_000);
    expect(client.turnRunning()).toBe(true);
    expect((client as any).stopAfterSeq).toBe(31);
    daemon.push(record([["mux", "turn_result", { turnId: "t2", status: "completed" }]], 33));
    await until(() => snapshot.isWorking === false, "the turn result");
    expect(snapshot.turnStartedAtMs).toBeUndefined();
    expect(client.turnRunning()).toBe(false);
    let prepareFailed = false;
    try {
      await client.continueIn("claude");
    } catch {
      prepareFailed = true;
    }
    expect(prepareFailed).toBe(true);
    expect(daemon.calls.filter((method) => method === "_acpmux/handoff_prepare")).toHaveLength(1);
  } finally {
    client.close();
  }
});
