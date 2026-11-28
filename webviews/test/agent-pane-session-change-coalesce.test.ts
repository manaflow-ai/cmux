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
import { settleReact } from "./support/domTeardown";
import { keptTail, rememberTail, resetKeptTailsForTests } from "../src/agent-session/acpmux/tailCache";

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

afterAll(async () => {
  AcpmuxDirectClient.scheduleFrame = savedSchedule;
  await settleReact();
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

beforeEach(() => {
  // Each test is a fresh page: its chat starts at seq 1, so a tail an earlier test's client kept of
  // the same chat id would stand in front of it (session ids are never reused in the app).
  resetKeptTailsForTests();
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
  sessions = Array.from({ length: SESSIONS }, (_, n) => summary(n + 1));
  watches = 0;
  /// `_acpmux/watch {enabled: false}`: a hidden pane's pause, answered `{}` as acpmux does.
  pauses = 0;
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
    const pause = message.method === "_acpmux/watch" && message.params?.enabled === false;
    if (pause) this.pauses += 1;
    else if (message.method === "_acpmux/watch") this.watches += 1;
    const result = pause
      ? {}
      : message.method === "initialize"
        ? { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [] } } }
        : message.method === "_acpmux/watch"
          ? { sessions: this.sessions }
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

async function openPane(hiddenTurnListener?: Parameters<typeof AcpmuxDirectClient.connect>[7]): Promise<{
  socket: FakeAcpmux;
  client: AcpmuxDirectClient;
  snapshots: () => number;
  latest: () => any;
}> {
  const socket = new FakeAcpmux();
  let count = 0;
  let latest: any;
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://coalesce.invalid/",
      token: "t",
      sessionId: SELECTED,
    },
    (message: any) => {
      if (message?.type === "snapshot") {
        count += 1;
        latest = message;
      }
    },
    undefined,
    () => socket as unknown as WebSocket,
    undefined,
    undefined,
    undefined,
    hiddenTurnListener,
  );
  await client.select(SELECTED);
  for (let i = 0; i < 5; i++) {
    await new Promise((resolve) => setTimeout(resolve, 0));
    flushFrames();
  }
  return { socket, client, snapshots: () => count, latest: () => latest };
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

test("hidden purges discard cached history and read-ahead state without a snapshot", async () => {
  const { socket, client, snapshots } = await openPane();
  const internal = client as any;
  const child = id(2);
  try {
    rememberTail(
      child,
      {
        events: [],
        summary: summary(2),
        turnOpener: undefined,
        historyExhausted: true,
        queue: [],
        configSeq: 0,
        usageFromSeq: 0,
      },
      true,
      false,
    );
    internal.readAheadAt.set(child, 1);
    internal.readAheadSeq.set(child, 1);
    internal.readAheadQueue.push(child);
    setVisibility("hidden");
    flushFrames();
    const before = snapshots();
    socket.notify("_acpmux/session_changed", { kind: "purged", session: { sessionId: child } });
    flushFrames();
    expect(keptTail(child)).toBeUndefined();
    expect(internal.readAheadAt.has(child)).toBe(false);
    expect(internal.readAheadSeq.has(child)).toBe(false);
    expect(internal.readAheadQueue).not.toContain(child);
    expect(snapshots()).toBe(before);
  } finally {
    client.close();
    setVisibility("visible");
  }
});

test("an offered child changes state while hidden without publishing a snapshot", async () => {
  const { socket, client, snapshots } = await openPane();
  const internal = client as any;
  try {
    internal.addOffer(
      { offerId: "hidden-child", title: "Child task", outcome: "accepted", childSessionId: id(2), childStatus: "idle" },
      1,
    );
    setVisibility("hidden");
    flushFrames();
    const before = snapshots();
    socket.notify("_acpmux/session_changed", { kind: "updated", session: summary(2, "running") });
    flushFrames();
    expect(internal.rows.get("offer-hidden-child").offers[0].childStatus).toBe("running");
    expect(internal.offerChildren.attached.has(id(2))).toBe(true);
    socket.notify("_acpmux/session_changed", { kind: "updated", session: summary(2, "idle") });
    flushFrames();
    expect(internal.rows.get("offer-hidden-child").offers[0].childStatus).toBe("idle");
    expect(internal.offerChildren.attached.has(id(2))).toBe(false);
    expect(snapshots()).toBe(before);
    setVisibility("visible");
    flushFrames();
    expect(snapshots()).toBeGreaterThan(before);
  } finally {
    client.close();
    setVisibility("visible");
  }
});

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

// A busy acpmux sends chats' summaries again with nothing changed (Leo, 2026-11-03: "im at 100% cpu
// rn"): each one drew a full snapshot, so an idle pane rebuilt its transcript and list many times a
// second. A summary equal to the one the pane holds changes nothing and draws nothing.
test("another chat's summary sent again unchanged draws nothing", async () => {
  const { socket, client, snapshots } = await openPane();
  jest.useFakeTimers();
  try {
    const before = snapshots();
    for (let round = 0; round < 20; round++) {
      for (let chat = 2; chat < 32; chat++)
        socket.notify("_acpmux/session_changed", {
          sessionId: id(chat),
          // The same fields in another order: still the same summary.
          session: Object.fromEntries(Object.entries(summary(chat)).reverse()),
          kind: "updated",
          seq: 10 + round,
        });
      flushFrames();
      jest.advanceTimersByTime(1000);
      flushFrames();
    }
    expect(snapshots() - before).toBe(0);
    // A real change still draws, once, in the next frame.
    socket.notify("_acpmux/session_changed", {
      sessionId: id(2),
      session: { ...summary(2), title: "Renamed" },
      kind: "renamed",
      seq: 40,
    });
    flushFrames();
    expect(snapshots() - before).toBe(1);
  } finally {
    jest.useRealTimers();
    client.close();
  }
});

// Running chats change their times and latest words on each event, and each change drew every shown
// pane at most twice a second (Leo, 2026-11-25: "the app speed on idle and on load we need to be
// better"). With the pane's live readers listening (App.tsx `otherChatsLive`), a change of only those
// fields of a chat outside the shown chat's tree goes to them and draws nothing; anything else draws.
test("other chats that only ran on reach the pane's live readers and draw nothing", async () => {
  const { socket, client, snapshots, latest } = await openPane();
  jest.useFakeTimers();
  try {
    let draw = false;
    const heard: number[] = [];
    client.onOtherChatsLive((sessions) => {
      heard.push(sessions.find((entry) => entry.sessionId === id(5))?.updatedAt ?? 0);
      return draw;
    });
    const tick = (chat: number, at: number, extra: Record<string, unknown> = {}) => {
      socket.notify("_acpmux/session_changed", {
        sessionId: id(chat),
        session: { ...summary(chat), updatedAt: at, ...extra },
        kind: "updated",
        seq: 10,
      });
      flushFrames();
      jest.advanceTimersByTime(1000);
      flushFrames();
    };
    const before = snapshots();
    for (let round = 0; round < 10; round++) tick(5, 3_000_000 + round);
    expect(snapshots() - before).toBe(0);
    expect(heard.at(-1)).toBe(3_000_009);
    // The next snapshot carries the newest list.
    tick(6, 3_100_000, { title: "Renamed" });
    expect(snapshots() - before).toBe(1);
    expect(latest().sessions.find((entry: any) => entry.sessionId === id(5)).updatedAt).toBe(3_000_009);
    // A status change draws, as does a tick the pane's readers show.
    tick(7, 3_200_000, { status: "running" });
    expect(snapshots() - before).toBe(2);
    draw = true;
    tick(5, 3_300_000);
    expect(snapshots() - before).toBe(3);
    draw = false;
    // A chat the shown one started, at any depth, draws: its sub-session cards read its words.
    tick(8, 3_400_000, { spawnedBy: SELECTED, status: "running" });
    tick(9, 3_400_000, { spawnedBy: id(8) });
    const drawn = snapshots();
    tick(9, 3_500_000, { spawnedBy: id(8) });
    expect(snapshots()).toBe(drawn + 1);
  } finally {
    jest.useRealTimers();
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

test("showing a hidden pane refreshes discarded summaries on its existing connection", async () => {
  const { socket, client, snapshots, latest } = await openPane();
  try {
    const watches = socket.watches;
    const before = snapshots();
    setVisibility("hidden");
    socket.sessions[1] = { ...summary(2, "running"), title: "Renamed while hidden" };
    socket.notify("_acpmux/session_changed", {
      sessionId: id(2),
      session: socket.sessions[1],
      kind: "renamed",
      seq: 401,
    });
    flushFrames();
    expect(snapshots()).toBe(before);
    expect(socket.watches).toBe(watches);
    // Hidden, it turned its list watch off: acpmux sends it no other chat's change until it shows.
    expect(socket.pauses).toBe(1);
    setVisibility("visible");
    for (let i = 0; i < 5; i++) {
      await new Promise((resolve) => setTimeout(resolve, 0));
      flushFrames();
    }
    expect(socket.watches).toBe(watches + 1);
    expect(latest().sessions.find((session: { sessionId: string }) => session.sessionId === id(2))?.title).toBe(
      "Renamed while hidden",
    );
    setVisibility("visible");
    expect(socket.watches).toBe(watches + 1);
  } finally {
    client.close();
    setVisibility("visible");
  }
});

// Every page of the app hears every chat's change: with 100 chats open each busy chat cost every
// hidden page a frame decoded, logged and dropped (Leo, 2026-11-25: "the goal is infinity chats").
// Hidden, the page pauses its watch once, and the many changes that still come (from an acpmux
// that ignores the pause) neither send another request nor draw; shown, it reads the list once.
test("a hidden pane pauses its list watch once and reads the list once when shown", async () => {
  const { socket, client, snapshots } = await openPane();
  try {
    const watches = socket.watches;
    setVisibility("hidden");
    expect(socket.pauses).toBe(1);
    expect((client as any).sessionPages.paused).toBe(true);
    const before = snapshots();
    for (let round = 0; round < 10; round++) {
      burst(socket, 30, round);
      flushFrames();
    }
    expect(socket.pauses).toBe(1);
    expect(socket.watches).toBe(watches);
    expect(snapshots()).toBe(before);
    setVisibility("visible");
    for (let i = 0; i < 5; i++) {
      await new Promise((resolve) => setTimeout(resolve, 0));
      flushFrames();
    }
    expect(socket.watches).toBe(watches + 1);
    expect((client as any).sessionPages.paused).toBe(false);
    // Hidden again: paused again.
    setVisibility("hidden");
    expect(socket.pauses).toBe(2);
  } finally {
    client.close();
    setVisibility("visible");
  }
});

test("a hidden pane with an offered child keeps its list watch on", async () => {
  const { socket, client } = await openPane();
  try {
    (client as any).addOffer(
      { offerId: "kept-child", title: "Child task", outcome: "accepted", childSessionId: id(2), childStatus: "idle" },
      1,
    );
    setVisibility("hidden");
    burst(socket, 5, 0);
    expect(socket.pauses).toBe(0);
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
    // Hidden pages do no snapshot work while another chat is shown.
    flushFrames();
    jest.advanceTimersByTime(50);
    expect(snapshots() - before).toBe(0);
    setVisibility("visible");
    flushFrames();
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

// A hidden page leaves its reply and turn state for when it shows. It does no snapshot work while
// hidden, so the renderer stays available to the page the reader is scrolling.
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
    expect(snapshots() - before).toBe(0);
    record(socket, 402, "turn_started");
    jest.advanceTimersByTime(50);
    expect(snapshots() - before).toBe(0);
    // The reply's first text and the 59 chunks wait for the page to show.
    chunk(socket, 403);
    jest.advanceTimersByTime(50);
    expect(snapshots() - before).toBe(0);
    for (let seq = 404; seq < 462; seq++) chunk(socket, seq);
    jest.advanceTimersByTime(10_000);
    expect(snapshots() - before).toBe(0);
    // A tool call (a subagent's start among them, which opens its own pane) waits too.
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
    expect(snapshots() - before).toBe(0);
    // Its progress waits for the show, as the text does: they draw a hidden tab nothing.
    for (const [index, status] of ["in_progress", "in_progress", "completed"].entries())
      socket.notify("_acpmux/event", {
        sessionId: SELECTED,
        seq: 470 + index,
        at: 470 + index,
        dir: "in",
        kind: "tool_call_update",
        msg: {
          method: "session/update",
          params: { sessionId: SELECTED, update: { sessionUpdate: "tool_call_update", toolCallId: "read-1", status } },
        },
      });
    jest.advanceTimersByTime(10_000);
    expect(snapshots() - before).toBe(0);
    record(socket, 473, "turn_end");
    jest.advanceTimersByTime(50);
    expect(snapshots() - before).toBe(0);
    // A turn that starts and ends at once is coalesced into the wake snapshot.
    record(socket, 474, "turn_started");
    record(socket, 475, "turn_end");
    expect(snapshots() - before).toBe(0);
    setVisibility("visible");
    flushFrames();
    expect(snapshots() - before).toBe(1);
    chunk(socket, 476);
    flushFrames();
    expect(snapshots() - before).toBe(2);
  } finally {
    jest.useRealTimers();
    client.close();
    setVisibility("visible");
  }
});

test("hidden checkpoints see a delayed idle summary and ignore a late result", async () => {
  const states: { isWorking: boolean; completedSeq?: number }[] = [];
  const { socket, client, snapshots } = await openPane((state) => states.push(state));
  try {
    setVisibility("hidden");
    const before = snapshots();
    socket.notify("_acpmux/session_changed", {
      sessionId: SELECTED,
      session: summary(1, "running"),
      kind: "updated",
      seq: 401,
    });
    record(socket, 402, "turn_result");
    expect(states.at(-1)?.isWorking).toBe(false);
    socket.notify("_acpmux/session_changed", {
      sessionId: SELECTED,
      session: summary(1, "idle"),
      kind: "updated",
      seq: 403,
    });
    expect(states.at(-1)?.isWorking).toBe(false);
    const event = (seq: number, kind: string, turnId: string) =>
      socket.notify("_acpmux/event", {
        sessionId: SELECTED,
        seq,
        at: seq,
        dir: "mux",
        kind,
        msg: { turnId },
      });
    event(404, "turn_started", "new-turn");
    const count = states.length;
    event(405, "turn_result", "old-turn");
    expect(states).toHaveLength(count);
    expect(snapshots()).toBe(before);
  } finally {
    client.close();
    setVisibility("visible");
  }
});

test("an entirely hidden turn preserves completion when both visible snapshots are idle", async () => {
  const states: { isWorking: boolean; completedSeq?: number }[] = [];
  const { socket, client, snapshots, latest } = await openPane((state) => states.push(state));
  try {
    record(socket, 401, "turn_end");
    flushFrames();
    const ended = latest().turnsEnded;
    const before = snapshots();
    expect(latest().isWorking).toBe(false);
    setVisibility("hidden");
    record(socket, 402, "turn_started");
    record(socket, 403, "turn_end");
    record(socket, 404, "turn_result");
    flushFrames();
    expect(snapshots()).toBe(before);
    expect(states.map((state) => state.isWorking)).toEqual([true, false, false]);
    expect(states.at(-1)?.completedSeq).toBe(404);
    setVisibility("visible");
    flushFrames();
    expect(latest().isWorking).toBe(false);
    expect(latest().turnsEnded).toBe(ended + 1);
  } finally {
    client.close();
    setVisibility("visible");
  }
});

// Hidden updates schedule no frames; a visible return schedules one, and closing a hidden client
// leaves no pending callback behind.
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
    // A hidden page does no frame scheduling. All ten turns publish in one frame on return.
    for (let turn = 0; turn < 10; turn++) {
      const seq = 401 + turn * 4;
      record(socket, seq, "turn_end");
      record(socket, seq + 1, "turn_started");
      chunk(socket, seq + 2);
      jest.advanceTimersByTime(50);
      chunk(socket, seq + 3);
    }
    expect(asked).toBe(0);
    setVisibility("visible");
    expect(asked).toBe(1);
    flushFrames();
    // All completion boundaries survive without publishing intermediate snapshots.
    expect(latest.turnsEnded - ended).toBe(10);
    client.close();
    expect(cancelled).toBe(0);
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

// Each frame from acpmux is parsed once (HOT PATH AUDIT area F, row W2,
// handoff/hot-path-audit/stream/AUDIT.md): the wire log and the client read one parse. Before, a
// streamed chunk's frame was parsed twice, once for the log and once for the client.
test("a streamed chunk's frame is parsed once", async () => {
  const { socket, client } = await openPane();
  const parse = JSON.parse;
  let parses = 0;
  const frames = 50;
  try {
    const lines = Array.from({ length: frames }, (_, n) =>
      JSON.stringify({
        jsonrpc: "2.0",
        method: "_acpmux/event",
        params: {
          sessionId: SELECTED,
          seq: 1000 + n,
          at: 1000 + n,
          dir: "in",
          kind: "agent_message_chunk",
          msg: {
            method: "session/update",
            params: {
              sessionId: SELECTED,
              update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `word${n} ` } },
            },
          },
        },
      }),
    );
    JSON.parse = ((text: string, reviver?: (this: unknown, key: string, value: unknown) => unknown) => {
      parses += 1;
      return parse(text, reviver);
    }) as typeof JSON.parse;
    for (const data of lines) socket.onmessage?.({ data });
    JSON.parse = parse;
    flushFrames();
    expect(parses).toBe(frames);
  } finally {
    JSON.parse = parse;
    client.close();
  }
});

// A shown chat redrew its whole pane for every frame in which any other chat changed, though the pane
// draws nothing of them while the person reads its transcript (Lawrence, 2026-11-18: scrolling a short
// chat dropped frames in an app with many workspaces and much history; Leo: "it's just redrawing the
// same thing a lot, even when there's very little stuff visible"). Each of those snapshots walks the
// whole session list in App.tsx, so its cost grows with history: 12,000 chats on Leo's Mac, about 5
// changes a second. Other chats' changes now draw at most once every OTHER_CHATS_DRAW_MS, and none
// while the person scrolls; the pane's own chat still draws in the next frame.
test("other chats' changes draw a shown chat at most twice a second", async () => {
  const { socket, client, snapshots } = await openPane();
  jest.useFakeTimers();
  try {
    jest.advanceTimersByTime(1000);
    flushFrames();
    const before = snapshots();
    // A change every 50 ms for 2 s, each in its own frame: 40 frames with a change.
    for (let round = 0; round < 40; round++) {
      burst(socket, 1, round);
      flushFrames();
      jest.advanceTimersByTime(50);
      flushFrames();
    }
    jest.advanceTimersByTime(500);
    flushFrames();
    const drawn = snapshots() - before;
    expect(drawn).toBeGreaterThanOrEqual(4);
    expect(drawn).toBeLessThanOrEqual(5);
  } finally {
    jest.useRealTimers();
    client.close();
  }
});

test("other chats' changes wait while the person scrolls; the pane's own chat does not", async () => {
  const { socket, client, snapshots } = await openPane();
  jest.useFakeTimers();
  try {
    jest.advanceTimersByTime(1000);
    flushFrames();
    const before = snapshots();
    // 1.5 s of scrolling, a wheel tick every 16 ms, while other chats change.
    for (let tick = 0; tick < 94; tick++) {
      window.dispatchEvent(new dom.window.WheelEvent("wheel", { deltaY: 4 }));
      if (tick % 5 === 0) burst(socket, 3, tick);
      jest.advanceTimersByTime(16);
      flushFrames();
    }
    expect(snapshots() - before).toBe(0);
    // The pane's own chat draws in the next frame, scroll or not.
    window.dispatchEvent(new dom.window.WheelEvent("wheel", { deltaY: 4 }));
    socket.notify("_acpmux/session_changed", {
      sessionId: SELECTED,
      session: { ...summary(1), title: "Renamed" },
      kind: "renamed",
      seq: 40,
    });
    flushFrames();
    expect(snapshots() - before).toBe(1);
    // That snapshot carried the list: the wait has nothing left, and the scroll's end draws nothing more.
    jest.advanceTimersByTime(1000);
    flushFrames();
    expect(snapshots() - before).toBe(1);
    // A change after the scroll ends draws.
    burst(socket, 1, 99);
    jest.advanceTimersByTime(1000);
    flushFrames();
    expect(snapshots() - before).toBe(2);
  } finally {
    jest.useRealTimers();
    client.close();
  }
});

// A page that keeps scrolling itself (a smooth scroll elsewhere in it) never rests: other chats'
// changes wait at most 2 s for it, not for ever.
test("a scroll that never rests holds other chats' changes at most 2 s", async () => {
  const { socket, client, snapshots } = await openPane();
  jest.useFakeTimers();
  try {
    jest.advanceTimersByTime(1000);
    flushFrames();
    const before = snapshots();
    burst(socket, 1, 0);
    let drawnAt: number | undefined;
    for (let tick = 0; tick < 250 && drawnAt === undefined; tick++) {
      window.dispatchEvent(new dom.window.WheelEvent("wheel", { deltaY: 4 }));
      jest.advanceTimersByTime(16);
      flushFrames();
      if (snapshots() > before) drawnAt = (tick + 1) * 16;
    }
    expect(drawnAt).toBeGreaterThanOrEqual(1900);
    expect(drawnAt).toBeLessThanOrEqual(2100);
  } finally {
    jest.useRealTimers();
    client.close();
  }
});
