// Session Info's running limit (session-info/SubagentLimitStepper.tsx) reads the chat's
// `subsessionLimits` from the attach reply's session detail, and acpmux logs a `subsession` record
// with `event: "limits"` whenever the limit changes (the person, an ancestor, another client). The
// attach asks for that kind, and the snapshot takes a record newer than the attach; one the page
// replays (at or below the attach's lastSeq) never takes the limit back, so − and + always step
// from the number acpmux holds.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";

const CHAT = "0190a000-0000-7000-8000-0000000000f7";
const START = Date.UTC(2026, 9, 21, 9, 0, 0);
type Step = [dir: string, kind: string, msg: Record<string, unknown>];
const record = (steps: Step[], from = 1, sessionId = CHAT) =>
  steps.map(([dir, kind, msg], index) => ({
    sessionId,
    seq: from + index,
    at: START + (from + index) * 1000,
    dir,
    kind,
    msg,
  }));
type Recorded = ReturnType<typeof record>[number];
const limits = (maxRunning: number, maxRunningSource = "session") => ({ maxRunning, maxRunningSource });
const changed = (maxRunning: number): Step => ["mux", "subsession", { event: "limits", limits: limits(maxRunning) }];

/// A daemon over a fake socket: attach answers with `history` and the detail's limit of 8 (the
/// chat's own unless `inherited`); `push` sends live events; `asked` keeps each request's params by
/// method, `limitAsks` each `_acpmux/subsession/limits` request's; `held` is the limit acpmux holds,
/// and `beforeReply` runs between a limits answer and its reply. A change acpmux takes is logged as
/// a `limits` record, streamed before its reply, as acpmux does.
function fakeDaemon(history: Recorded[], inherited = false, chat = CHAT) {
  let socket: any;
  const asked = new Map<string, any>();
  const limitAsks: any[] = [];
  const state: { held: number; source: string; beforeReply?: () => void } = {
    held: 8,
    source: inherited ? "inherited" : "session",
  };
  const session = { sessionId: chat, cwd: "/Users/dev/app", title: "x", harness: "claude", status: "idle" };
  const lastSeq = () => history.at(-1)?.seq ?? 0;
  const answer = (method: string) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return {
          session: { ...session, subsessionLimits: limits(state.held, state.source) },
          lastSeq: lastSeq(),
          events: history,
          hasMore: false,
        };
      case "_acpmux/events": {
        // The records after the cursor the pane asked from: those a lag dropped.
        const after = asked.get(method)?.afterSeq ?? 0;
        const events = history.filter((event) => event.seq > after);
        return { events, hasMore: false, more: false, lastSeq: lastSeq() };
      }
      case "_acpmux/subsession/limits": {
        const params = asked.get(method) ?? {};
        // Naming no field only reads the limit.
        if ("maxRunning" in params) {
          state.held = params.maxRunning;
          state.source = "session";
        }
        return { sessionId: chat, subsessionLimits: limits(state.held, state.source) };
      }
      default:
        return null;
    }
  };
  const open = () => {
    socket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.method) asked.set(message.method, message.params);
        if (message.method === "_acpmux/subsession/limits") limitAsks.push(message.params);
        if (message.id !== undefined)
          queueMicrotask(() => {
            const result = answer(message.method);
            if (message.method === "_acpmux/subsession/limits") {
              if ("maxRunning" in (message.params ?? {})) push(record([changed(state.held)], lastSeq() + 1, chat));
              // What the daemon streams after it answered and before the reply reaches the pane.
              state.beforeReply?.();
            }
            socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) });
          });
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
  /// Records the daemon logs but drops for this client, then the lag notice that names them.
  const drop = (events: Recorded[]) => {
    history.push(...events);
    socket.onmessage?.({
      data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/lagged", params: { dropped: events.length } }),
    });
  };
  /// The seq acpmux gives its next record.
  const next = () => lastSeq() + 1;
  return { open, push, drop, asked, limitAsks, state, next };
}

/// Yields until `ready()` holds; fails after 2 s with what it waited for.
async function until(ready: () => boolean, what: string) {
  const deadline = performance.now() + 2_000;
  while (!ready()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}

test("the attach asks for the limit's records, and only one newer than the attach moves it", async () => {
  // The page replays two older changes (to 3, then 5); the detail's 8 is what acpmux holds now.
  const daemon = fakeDaemon(record([["mux", "user_message", { text: "start the agents" }], changed(3), changed(5)]));
  let snapshot: any;
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (next: any) => (snapshot = next),
    undefined,
    daemon.open,
  );
  try {
    await until(() => snapshot?.connection === "connected", "the attach");
    const kinds: string[] = daemon.asked.get("_acpmux/attach")?.kinds ?? [];
    expect(kinds).toContain("subsession");
    // A remote cmux-tui refuses more than 8 kinds; the queue's go only to a local acpmux.
    expect(kinds.filter((kind) => !["queue_order", "queue_updated", "prompt_refused"].includes(kind)).length).toBe(8);
    expect(snapshot.summary.subsessionLimits).toEqual({ maxRunning: 8, maxRunningSource: "session" });
    // A record at or below the attach's lastSeq (3) is history.
    daemon.push(record([changed(2)], 3));
    daemon.push(record([["mux", "turn_started", {}]], 4));
    await until(() => snapshot.isWorking === true, "the turn");
    expect(snapshot.summary.subsessionLimits.maxRunning).toBe(8);
    // A newer one is the limit now.
    daemon.push(record([changed(12)], 5));
    await until(() => snapshot.summary.subsessionLimits?.maxRunning === 12, "the live limit");
    // The reply to the pane's own change moves it at once.
    await client.setRunningLimit(CHAT, 13);
    expect(daemon.asked.get("_acpmux/subsession/limits")).toEqual({ sessionId: CHAT, maxRunning: 13 });
    await until(() => snapshot.summary.subsessionLimits?.maxRunning === 13, "the reply's limit");
  } finally {
    client.close();
  }
});

test("a step on an inherited limit steps from the limit acpmux holds now, and quick steps build on each other", async () => {
  // The chat inherits 8; then its parent's limit moves to 20, which reaches this chat as no record.
  const daemon = fakeDaemon(record([["mux", "user_message", { text: "start the agents" }]]), true);
  let snapshot: any;
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (next: any) => (snapshot = next),
    undefined,
    daemon.open,
  );
  try {
    await until(() => snapshot?.connection === "connected", "the attach");
    expect(snapshot.summary.subsessionLimits).toEqual({ maxRunning: 8, maxRunningSource: "inherited" });
    daemon.state.held = 20;
    // Two quick + clicks on the stale 8: 8 → 9, then 9 → 10.
    await Promise.all([client.setRunningLimit(CHAT, 9, 8), client.setRunningLimit(CHAT, 10, 9)]);
    // The first read acpmux's 20 and set 21; the second stepped from that answer, the chat's own now.
    expect(daemon.limitAsks).toEqual([
      { sessionId: CHAT },
      { sessionId: CHAT, maxRunning: 21 },
      { sessionId: CHAT, maxRunning: 22 },
    ]);
    expect(snapshot.summary.subsessionLimits).toEqual({ maxRunning: 22, maxRunningSource: "session" });
    // Reset names no step: it is sent as is.
    await client.setRunningLimit(CHAT, null);
    expect(daemon.limitAsks.at(-1)).toEqual({ sessionId: CHAT, maxRunning: null });
  } finally {
    client.close();
  }
});

test("a limit change a lag dropped reaches the summary when the pane catches up", async () => {
  const daemon = fakeDaemon(record([["mux", "user_message", { text: "start the agents" }]]));
  let snapshot: any;
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (next: any) => (snapshot = next),
    undefined,
    daemon.open,
  );
  try {
    await until(() => snapshot?.connection === "connected", "the attach");
    expect(snapshot.summary.subsessionLimits.maxRunning).toBe(8);
    // 8 → 12 while the client lagged: it reads the missed record, and keeps it.
    daemon.drop(record([changed(12)], 2));
    await until(() => snapshot.summary.subsessionLimits?.maxRunning === 12, "the missed limit");
    // fixed-wait: nothing more may arrive; no event marks that a late reply did not.
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect(snapshot.summary.subsessionLimits.maxRunning).toBe(12);
  } finally {
    client.close();
  }
});

test("a reply older than a limit streamed while it was in flight never takes the limit back", async () => {
  const daemon = fakeDaemon(record([["mux", "user_message", { text: "start the agents" }]]));
  let snapshot: any;
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (next: any) => (snapshot = next),
    undefined,
    daemon.open,
  );
  try {
    await until(() => snapshot?.connection === "connected", "the attach");
    expect(snapshot.summary.subsessionLimits.maxRunning).toBe(8);
    // The pane sets 9; acpmux answers 9, then another client sets 20, whose record reaches the pane
    // before the reply does.
    daemon.state.beforeReply = () => {
      daemon.state.beforeReply = undefined;
      daemon.state.held = 20;
      daemon.push(record([changed(20)], daemon.next()));
    };
    await client.setRunningLimit(CHAT, 9, 8);
    expect(daemon.limitAsks).toEqual([{ sessionId: CHAT, maxRunning: 9 }]);
    expect(snapshot.summary.subsessionLimits.maxRunning).toBe(20);
    // So the next + steps from 20.
    await client.setRunningLimit(CHAT, 21, 20);
    expect(daemon.limitAsks.at(-1)).toEqual({ sessionId: CHAT, maxRunning: 21 });
    expect(snapshot.summary.subsessionLimits.maxRunning).toBe(21);
  } finally {
    client.close();
  }
});

/// A + on the inherited 8 whose read acpmux answers with 8 just before the chat's inherited limit
/// moves to 20 and the pane attaches the chat again (`beforeReply`); `history` is the chat's log.
async function stepOverReattach(chat: string, history: Recorded[]) {
  const daemon = fakeDaemon(history, true, chat);
  let snapshot: any;
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: chat },
    (next: any) => (snapshot = next),
    undefined,
    daemon.open,
  );
  try {
    await until(() => snapshot?.connection === "connected", "the attach");
    expect(snapshot.summary.subsessionLimits).toEqual({ maxRunning: 8, maxRunningSource: "inherited" });
    daemon.state.beforeReply = () => {
      daemon.state.beforeReply = undefined;
      daemon.state.held = 20;
      void client.select(chat);
    };
    await client.setRunningLimit(chat, 9, 8);
    // The read the attach overtook is read again: the step builds on 20, never the stale 8.
    expect(daemon.limitAsks.filter((ask) => "maxRunning" in ask)).toEqual([{ sessionId: chat, maxRunning: 21 }]);
    expect(daemon.limitAsks.length).toBeGreaterThanOrEqual(3);
    await until(() => snapshot.summary?.subsessionLimits?.maxRunning === 21, "the limit after the re-attach");
    // fixed-wait: nothing more may arrive; no event marks that a late reply did not.
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect(snapshot.summary.subsessionLimits.maxRunning).toBe(21);
  } finally {
    client.close();
  }
}

test("a read a re-attach overtook is read again, so the step builds on the limit acpmux holds", async () => {
  const chat = "0190a000-0000-7000-8000-0000000000f8";
  // fixed-wait: the helper checks, after a short settle, that no late reply takes the limit back.
  await stepOverReattach(chat, record([["mux", "user_message", { text: "start the agents" }]], 1, chat));
});

test("a kept tail's old limit, replayed as the chat is opened again, is never stepped from", async () => {
  // The log holds an old change to 5; opening the chat again draws its kept tail, whose replay
  // passes that record before the attach answers.
  const chat = "0190a000-0000-7000-8000-0000000000f9";
  // fixed-wait: the helper checks, after a short settle, that no late reply takes the limit back.
  await stepOverReattach(chat, record([["mux", "user_message", { text: "start the agents" }], changed(5)], 1, chat));
});

test("a + while a reopened chat's kept tail shows its own old limit steps from acpmux's limit", async () => {
  // The chat's own limit was 8 on the last visit; another client set 20 since. Opening it again
  // draws the kept tail (own 8) before the attach answers, and a + then must not trust it.
  const daemon = fakeDaemon(record([["mux", "user_message", { text: "start the agents" }]]));
  let snapshot: any;
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (next: any) => (snapshot = next),
    undefined,
    daemon.open,
  );
  try {
    await until(() => snapshot?.connection === "connected", "the attach");
    expect(snapshot.summary.subsessionLimits).toEqual({ maxRunning: 8, maxRunningSource: "session" });
    daemon.state.held = 20;
    const opened = client.select(CHAT);
    await client.setRunningLimit(CHAT, 9, 8);
    await opened;
    expect(daemon.limitAsks).toEqual([{ sessionId: CHAT }, { sessionId: CHAT, maxRunning: 21 }]);
    await until(() => snapshot.summary?.subsessionLimits?.maxRunning === 21, "the stepped limit");
  } finally {
    client.close();
  }
});

test("a step whose every read is overtaken is refused, and writes nothing", async () => {
  const daemon = fakeDaemon(record([["mux", "user_message", { text: "start the agents" }]]), true);
  let snapshot: any;
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (next: any) => (snapshot = next),
    undefined,
    daemon.open,
  );
  try {
    await until(() => snapshot?.connection === "connected", "the attach");
    // Each read's reply is overtaken by a newer change: 20, 30, then 40.
    daemon.state.beforeReply = () => {
      daemon.state.held += daemon.state.held < 20 ? 12 : 10;
      daemon.push(record([changed(daemon.state.held)], daemon.next()));
    };
    await expect(client.setRunningLimit(CHAT, 9, 8)).rejects.toThrow();
    expect(daemon.limitAsks).toEqual([{ sessionId: CHAT }, { sessionId: CHAT }, { sessionId: CHAT }]);
    expect(snapshot.summary.subsessionLimits.maxRunning).toBe(40);
    // Once the limit holds still, the next + steps from it.
    daemon.state.beforeReply = undefined;
    await client.setRunningLimit(CHAT, 41, 40);
    expect(daemon.limitAsks.at(-1)).toEqual({ sessionId: CHAT, maxRunning: 41 });
  } finally {
    client.close();
  }
});
