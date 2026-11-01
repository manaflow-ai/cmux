// l10n-allow-file: test fixture titles, not shipped UI.
// Many running chats must not stall a chat pane that shows one of them (Lawrence and Leo,
// 2026-10-21: "web content performance must be sandboxed"). Every pane watches acpmux's whole
// session list, so each `session_changed` of any chat (a turn starting, a tool call auto-approved,
// a queue change) reached every open pane, and each one built a full snapshot at once: the
// transcript's rows, the session list, then a React render of the whole pane. With 30 chats
// running that is a render per change in every pane, also in panes nobody looks at.
//
// A burst of changes now draws once, in the next frame, like the transcript's own events
// (`emitInFrame`), and a hidden pane leaves other chats' changes for when it shows again. The
// change to the pane's own chat still reaches a hidden pane, so its tab row stays right.
import { afterAll, beforeAll, beforeEach, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: "window" in scope,
  document: "document" in scope,
  values: { window: scope.window, document: scope.document },
};
let visibility: "visible" | "hidden" = "visible";
const savedSchedule = AcpmuxDirectClient.scheduleFrame;
let frames: (() => void)[] = [];

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
  Object.defineProperty(dom.window.document, "visibilityState", { configurable: true, get: () => visibility });
});

afterAll(() => {
  AcpmuxDirectClient.scheduleFrame = savedSchedule;
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

beforeEach(() => {
  frames = [];
  AcpmuxDirectClient.scheduleFrame = (run) => void frames.push(run);
});

function flushFrames(): void {
  const due = frames;
  frames = [];
  for (const run of due) run();
}

function setVisibility(next: "visible" | "hidden"): void {
  visibility = next;
  dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
}

const SESSIONS = 1000;
const id = (n: number) => `0190a000-0000-7000-8000-${n.toString(16).padStart(12, "0")}`;
const SELECTED = id(1);
const summary = (n: number, status = "idle") => ({
  sessionId: id(n),
  cwd: `/home/dev/project-${n % 40}`,
  title: `Chat ${n}`,
  harness: "claude",
  family: "claude",
  status,
  turnCount: 12,
  updatedAt: 1_000_000 + n,
});

/// A long transcript: 400 records of user prompts and agent replies.
const transcript = Array.from({ length: 400 }, (_, i) => {
  const seq = i + 1;
  return i % 2 === 0
    ? {
        sessionId: SELECTED,
        seq,
        at: seq,
        dir: "mux",
        kind: "user_message",
        msg: { prompt: [{ type: "text", text: `Question ${seq}` }] },
      }
    : {
        sessionId: SELECTED,
        seq,
        at: seq,
        dir: "in",
        kind: "transcript",
        msg: {
          method: "session/update",
          params: {
            sessionId: SELECTED,
            update: {
              sessionUpdate: "agent_message_chunk",
              content: { type: "text", text: `Answer ${seq} `.repeat(20) },
            },
          },
        },
      };
});

class FakeAcpmux {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  constructor() {
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.();
    });
  }
  send(raw: string): void {
    const message = JSON.parse(raw) as { id?: number; method: string; params?: Record<string, unknown> };
    if (message.id === undefined) return;
    const result =
      message.method === "initialize"
        ? { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [] } } }
        : message.method === "_acpmux/watch"
          ? { sessions: Array.from({ length: SESSIONS }, (_, n) => summary(n + 1)) }
          : message.method === "_acpmux/attach"
            ? { session: summary(1), lastSeq: transcript.length, events: transcript, hasMore: false }
            : message.method === "_acpmux/events"
              ? { events: [], hasMore: false, lastSeq: transcript.length }
              : {};
    queueMicrotask(() => this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) }));
  }
  notify(method: string, params: unknown): void {
    this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method, params }) });
  }
  close(): void {
    this.readyState = 3;
  }
}

async function openPane(): Promise<{ socket: FakeAcpmux; client: AcpmuxDirectClient; snapshots: () => number }> {
  const socket = new FakeAcpmux();
  let count = 0;
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://coalesce.invalid/",
      token: "t",
      sessionId: SELECTED,
    },
    (message: any) => {
      if (message?.type === "snapshot") count += 1;
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  await client.select(SELECTED);
  for (let i = 0; i < 5; i++) {
    await new Promise((resolve) => setTimeout(resolve, 0));
    flushFrames();
  }
  return { socket, client, snapshots: () => count };
}

/// One change of each of `chats` other running chats, as acpmux sends them.
function burst(socket: FakeAcpmux, chats: number, round: number): void {
  for (let n = 0; n < chats; n++) {
    const chat = 2 + ((n + round * chats) % (SESSIONS - 1));
    socket.notify("_acpmux/session_changed", {
      sessionId: id(chat),
      session: { ...summary(chat, "running"), updatedAt: 2_000_000 + round * chats + n },
      kind: "permission_resolved",
      recordKind: "permission_auto",
      seq: 10 + round,
    });
  }
}

test("a burst of other chats' changes draws the pane once, in the next frame", async () => {
  const { socket, client, snapshots } = await openPane();
  try {
    const before = snapshots();
    burst(socket, 30, 0);
    expect(snapshots() - before).toBe(0);
    flushFrames();
    expect(snapshots() - before).toBe(1);
  } finally {
    client.close();
  }
});

test("a hidden pane draws other chats' changes only when it shows again", async () => {
  const { socket, client, snapshots } = await openPane();
  try {
    setVisibility("hidden");
    flushFrames();
    const before = snapshots();
    for (let round = 0; round < 10; round++) {
      burst(socket, 30, round);
      flushFrames();
    }
    expect(snapshots() - before).toBe(0);
    setVisibility("visible");
    flushFrames();
    expect(snapshots() - before).toBe(1);
  } finally {
    client.close();
    setVisibility("visible");
  }
});

test("a hidden pane still draws a change to its own chat", async () => {
  const { socket, client, snapshots } = await openPane();
  jest.useFakeTimers();
  try {
    setVisibility("hidden");
    flushFrames();
    const before = snapshots();
    socket.notify("_acpmux/session_changed", {
      sessionId: SELECTED,
      session: { ...summary(1, "running"), title: "Renamed" },
      kind: "renamed",
      recordKind: "renamed",
      seq: 401,
    });
    // Not in a frame (a hidden page draws none) but within 50 ms.
    flushFrames();
    jest.advanceTimersByTime(50);
    expect(snapshots() - before).toBe(1);
  } finally {
    jest.useRealTimers();
    client.close();
    setVisibility("visible");
  }
});

/// A live record of the shown chat, as acpmux sends it.
function record(socket: FakeAcpmux, seq: number, kind: string, msg: Record<string, unknown> = {}): void {
  socket.notify("_acpmux/event", { sessionId: SELECTED, seq, at: seq, dir: "mux", kind, msg });
}

/// A chunk of the shown chat's reply, as acpmux records it (its kind is the update's).
function chunk(socket: FakeAcpmux, seq: number): void {
  socket.notify("_acpmux/event", {
    sessionId: SELECTED,
    seq,
    at: seq,
    dir: "in",
    kind: "agent_message_chunk",
    msg: {
      method: "session/update",
      params: {
        sessionId: SELECTED,
        update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `word ${seq} ` } },
      },
    },
  });
}

// A hidden page leaves its reply's text growing for when it shows, the bulk of a running chat's
// events. Everything else still draws within 50 ms, and a turn starting or ending at once, since the
// page's effects act on them while hidden (App.tsx `pane.tabState`, a subagent's own pane).
test("a hidden pane draws its chat's turns and new replies, not its reply's text growing", async () => {
  const { socket, client, snapshots } = await openPane();
  jest.useFakeTimers();
  try {
    setVisibility("hidden");
    flushFrames();
    const before = snapshots();
    // The fixture's transcript ends inside a turn: it ends, then the next one starts.
    record(socket, 401, "turn_end");
    jest.advanceTimersByTime(50);
    expect(snapshots() - before).toBe(1);
    record(socket, 402, "turn_started");
    jest.advanceTimersByTime(50);
    expect(snapshots() - before).toBe(2);
    // The reply's first text is a new row: it draws. The 59 chunks that grow it wait.
    chunk(socket, 403);
    jest.advanceTimersByTime(50);
    expect(snapshots() - before).toBe(3);
    for (let seq = 404; seq < 462; seq++) chunk(socket, seq);
    jest.advanceTimersByTime(10_000);
    expect(snapshots() - before).toBe(3);
    // A tool call (a subagent's start among them, which opens its own pane) draws within 50 ms.
    socket.notify("_acpmux/event", {
      sessionId: SELECTED,
      seq: 462,
      at: 462,
      dir: "in",
      kind: "tool_call",
      msg: {
        method: "session/update",
        params: {
          sessionId: SELECTED,
          update: { sessionUpdate: "tool_call", toolCallId: "read-1", title: "Read", kind: "read", status: "pending" },
        },
      },
    });
    jest.advanceTimersByTime(50);
    expect(snapshots() - before).toBe(4);
    record(socket, 463, "turn_end");
    jest.advanceTimersByTime(50);
    expect(snapshots() - before).toBe(5);
    // A turn that starts and ends at once still draws both: the header refreshes on the end.
    record(socket, 464, "turn_started");
    record(socket, 465, "turn_end");
    expect(snapshots() - before).toBe(7);
    // Nothing waits for the show: those snapshots carried the stream too.
    setVisibility("visible");
    flushFrames();
    expect(snapshots() - before).toBe(7);
    chunk(socket, 466);
    flushFrames();
    expect(snapshots() - before).toBe(8);
  } finally {
    jest.useRealTimers();
    client.close();
    setVisibility("visible");
  }
});

// A client waits for one frame at a time, however many snapshots a hidden page draws at once
// meanwhile, and a closed client's wait goes: a hidden page that reconnects keeps no closed client.
test("a hidden pane asks for one frame at a time and cancels it on close", async () => {
  let latest: any;
  const socket = new FakeAcpmux();
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://coalesce.invalid/",
      token: "t",
      sessionId: SELECTED,
    },
    (message: any) => {
      if (message?.type === "snapshot") latest = message;
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  await client.select(SELECTED);
  for (let i = 0; i < 5; i++) {
    await new Promise((resolve) => setTimeout(resolve, 0));
    flushFrames();
  }
  jest.useFakeTimers();
  let asked = 0;
  let cancelled = 0;
  AcpmuxDirectClient.scheduleFrame = (run) => {
    asked += 1;
    frames.push(run);
    return () => (cancelled += 1);
  };
  try {
    setVisibility("hidden");
    const ended = latest.turnsEnded ?? 0;
    // Each turn's start and end draws at once, and its reply's first text within 50 ms; the text
    // growing after it waits for one frame, the same one for every turn.
    for (let turn = 0; turn < 10; turn++) {
      const seq = 401 + turn * 4;
      record(socket, seq, "turn_end");
      record(socket, seq + 1, "turn_started");
      chunk(socket, seq + 2);
      jest.advanceTimersByTime(50);
      chunk(socket, seq + 3);
    }
    expect(asked).toBe(1);
    // Ten ends, counted even where React would draw a start and its end as one render.
    expect(latest.turnsEnded - ended).toBe(10);
    client.close();
    expect(cancelled).toBe(1);
  } finally {
    jest.useRealTimers();
    client.close();
    setVisibility("visible");
  }
});

test("bench: client time for 30 running chats changing 20 times (600 changes)", async () => {
  const { socket, client, snapshots } = await openPane();
  try {
    const before = snapshots();
    const started = performance.now();
    for (let round = 0; round < 20; round++) {
      burst(socket, 30, round);
      flushFrames();
    }
    const elapsed = performance.now() - started;
    const drawn = snapshots() - before;
    console.log(`session-change bench: 600 changes, ${drawn} snapshots, ${elapsed.toFixed(1)} ms in the client`);
    // One snapshot per frame at most: 20 frames.
    expect(drawn).toBeLessThanOrEqual(20);
  } finally {
    client.close();
  }
});
