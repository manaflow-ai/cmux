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
import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient, nextFrame } from "../src/agent-session/acpmux/direct";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { noChat } from "../src/gallery/fixtures/acpmux";
import { snapshotFrames } from "../src/agent-session/acpmux/snapshotFrames";

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

async function openPane(
  receive?: (snapshot: AcpmuxSnapshot, timing?: "frame") => void,
): Promise<{ socket: FakeAcpmux; client: AcpmuxDirectClient; snapshots: () => number }> {
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
    (message: AcpmuxSnapshot, timing?: "frame") => {
      if (message?.type === "snapshot") count += 1;
      receive?.(message, timing);
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
    flushFrames();
    expect(snapshots() - before).toBe(1);
  } finally {
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

for (const mode of ["visible", "hidden"] as const) {
  test(`${mode}: a live delta presents in the client's frame without a second frame`, async () => {
    let schedule: (run: () => void) => void = (run) => void frames.push(run);
    let current = noChat();
    let presentations = 0;
    const presentation = snapshotFrames(
      (run) => schedule(run),
      (update) => {
        current = update(current);
        presentations += 1;
      },
    );
    const { socket, client } = await openPane((next, timing) => presentation.push(next, timing));
    const originals = { requestAnimationFrame: scope.requestAnimationFrame, setTimeout: scope.setTimeout };
    const animationFrames: (() => void)[] = [];
    const timers: { at: number; run: () => void }[] = [];
    let now = 0;
    try {
      setVisibility(mode);
      flushFrames();
      scope.requestAnimationFrame = (run: FrameRequestCallback) => {
        animationFrames.push(() => run(now));
        return animationFrames.length;
      };
      scope.setTimeout = (run: () => void, delay: number) => {
        timers.push({ at: now + delay, run });
        return timers.length;
      };
      AcpmuxDirectClient.scheduleFrame = schedule = nextFrame;
      const before = presentations;
      socket.notify("session/update", {
        sessionId: SELECTED,
        _meta: { acpmux: { seq: transcript.length + 1, at: 2_000_000 } },
        update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "First streamed chunk" } },
      });
      expect(presentations).toBe(before);
      expect(animationFrames).toHaveLength(1);
      expect(timers.map(({ at }) => at)).toEqual([50]);
      if (mode === "visible") {
        now = 16;
        animationFrames.shift()!();
      } else {
        now = 49;
        expect(presentations).toBe(before);
        now = 50;
        timers.shift()!.run();
      }
      expect(presentations).toBe(before + 1);
      expect(current.rows.some((row) => row.text?.includes("First streamed chunk"))).toBe(true);
      // The other branch of nextFrame may still fire, but it cannot schedule or publish again.
      for (const callback of animationFrames) callback();
      for (const timer of timers) timer.run();
      expect(presentations).toBe(before + 1);
      expect(timers.every(({ at }) => at === 50)).toBe(true);
    } finally {
      for (const [key, value] of Object.entries(originals)) {
        if (value === undefined) delete scope[key];
        else scope[key] = value;
      }
      presentation.stop();
      client.close();
      setVisibility("visible");
    }
  });
}
