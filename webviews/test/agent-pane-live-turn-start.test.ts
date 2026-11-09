// The live turn's clock ("Thinking", "Working for") counts from the turn's own start, never from an
// older prompt a resumed turn still opens with (Leo's Session status read "Thinking 118h 21m 48s",
// #26214). The snapshot's `turnStartedAtMs` is that start: the turn's `turn_started`, or the
// summary's `turn.startedAt` when that record is outside the attached page (direct.ts).
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
function fakeDaemon(history: Recorded[], details: Record<string, unknown> = {}, hooks: { onAttach?: () => void } = {}) {
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
      case "_acpmux/attach": {
        // The summary as the attach read it; `onAttach` may change the chat before it answers.
        const asked = { ...session };
        hooks.onAttach?.();
        return { session: asked, lastSeq: lastSeq(), events: history, hasMore: false };
      }
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
const endpoint = {
  protocolVersion: 1,
  transport: "acpmux-websocket",
  endpoint: "ws://127.0.0.1:1/",
  token: "t",
  sessionId: CHAT,
} as const;

async function connect(daemon: ReturnType<typeof fakeDaemon>) {
  const seen: { snapshot?: any } = {};
  const client = await AcpmuxDirectClient.connect(
    endpoint as any,
    (next: any) => (seen.snapshot = next),
    undefined,
    daemon.open,
  );
  await until(() => seen.snapshot?.chatRead === true, "the attach");
  return { client, seen };
}

test("a resumed turn counts from its own start, not the older prompt it opens with", async () => {
  const daemon = fakeDaemon(record([["mux", "user_message", { text: "old prompt", turnId: "t1" }], started]));
  const { client, seen } = await connect(daemon);
  try {
    expect(seen.snapshot.turnStartedAtMs).toBe(START + 2_000);
    daemon.push(record([["mux", "turn_end", { turnId: "t1" }]], 3));
    daemon.change({ status: "idle", turn: null });
    await until(() => seen.snapshot.isWorking === false, "the turn's end");
    expect(seen.snapshot.turnStartedAtMs).toBeUndefined();
    // acpmux resumes the cut turn days later with no new prompt: its own start dates it.
    daemon.push(record([["mux", "turn_started", { turnId: "t2" }]], 400_000));
    daemon.change({ status: "running", turn: { turnId: "t2", startedAt: START + 400_000_000 } });
    await until(() => seen.snapshot.isWorking === true, "the resumed turn");
    expect(seen.snapshot.turnStartedAtMs).toBe(START + 400_000_000);
  } finally {
    client.close();
  }
});

test("an attach in the middle of a turn uses the summary start when its event is paged out", async () => {
  const daemon = fakeDaemon(record([["mux", "user_message", { text: "old prompt" }]]), {
    turn: { turnId: "t2", startedAt: START + 30_000 },
  });
  const { client, seen } = await connect(daemon);
  try {
    expect(seen.snapshot.isWorking).toBe(true);
    expect(seen.snapshot.turnStartedAtMs).toBe(START + 30_000);
    // A lag resync rebuilds from the held page, which still lacks the start: the summary dates it again.
    (client as any).rebuildKeepingLiveState();
    expect((client as any).turnStartedAtMs).toBe(START + 30_000);
    daemon.push(record([["mux", "turn_end", { turnId: "t2" }]], 2));
    daemon.change({ status: "idle", turn: null });
    await until(() => seen.snapshot.isWorking === false, "the turn's end");
    expect(seen.snapshot.turnStartedAtMs).toBeUndefined();
  } finally {
    client.close();
  }
});

test("a summary dates a turn only once, and the turn's own start replaces it", async () => {
  const daemon = fakeDaemon(record([["mux", "user_message", { text: "old prompt" }]]));
  const { client, seen } = await connect(daemon);
  try {
    expect(seen.snapshot.turnStartedAtMs).toBeUndefined();
    daemon.change({ title: "next", turn: { turnId: "t2", startedAt: START + 30_000 } });
    await until(() => seen.snapshot.summary?.title === "next", "the newer summary");
    expect(seen.snapshot.turnStartedAtMs).toBe(START + 30_000);
    // A late summary of an earlier turn never moves the clock back.
    daemon.change({ title: "earlier", turn: { turnId: "t1", startedAt: START + 1_000 } });
    await until(() => seen.snapshot.summary?.title === "earlier", "the older summary");
    expect(seen.snapshot.turnStartedAtMs).toBe(START + 30_000);
    daemon.push(record([["mux", "turn_started", { turnId: "t2" }]], 31));
    expect(seen.snapshot.turnStartedAtMs).toBe(START + 31_000);
    daemon.push(record([["mux", "turn_result", { turnId: "t2", status: "completed" }]], 32));
    daemon.change({ status: "idle", turn: null });
    await until(() => seen.snapshot.isWorking === false, "the turn result");
    expect(seen.snapshot.turnStartedAtMs).toBeUndefined();
  } finally {
    client.close();
  }
});

test("a summary still naming a turn from before the open prompt does not date it", async () => {
  const daemon = fakeDaemon(record([["mux", "user_message", { text: "new prompt" }]], 5), {
    turn: { turnId: "t0", startedAt: START + 1_000 },
  });
  const { client, seen } = await connect(daemon);
  try {
    expect(seen.snapshot.isWorking).toBe(true);
    expect(seen.snapshot.turnStartedAtMs).toBeUndefined();
  } finally {
    client.close();
  }
});

test("a kept tail keeps its replayed turn start over an older summary stamp", async () => {
  const history = record([["mux", "user_message", { text: "fix", turnId: "t1" }], started]);
  const daemon = fakeDaemon([...history], { turn: { turnId: "t1", startedAt: START + 500 } });
  const { client, seen } = await connect(daemon);
  try {
    expect(seen.snapshot.turnStartedAtMs).toBe(START + 2_000);
    (client as any).drawKeptTail(CHAT, {
      summary: { sessionId: CHAT, status: "running", turn: { turnId: "t1", startedAt: START + 500 } },
      events: history,
      turnOpener: undefined,
      historyExhausted: true,
      configSeq: 0,
      usageFromSeq: Infinity,
      queue: [],
    });
    expect((client as any).turnOpen).toBe(true);
    expect((client as any).turnStartedAtMs).toBe(START + 2_000);
  } finally {
    client.close();
  }
});
