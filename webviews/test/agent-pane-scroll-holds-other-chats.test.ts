// l10n-allow-file: test fixture titles, not shipped UI.
// Scrolling one chat draws only that chat (Leo, 2026-11-18: "Lawrence, on a relatively small chat, of
// course, like this is in his app with a lot of workspaces, a lot of history, and he was just scrolling
// up and down through that one particular chat, and you know, he was feeling some dropped frames, like it
// wasn't smooth. ... it gets sort of hijacked by the other parts of the app, which are actually
// non-visible."). Every agent page of the renderer hears every chat's `session_changed`, and each drew its
// whole pane for it between the scrolled chat's frames (bench/session-scale-scroll.bench.ts). While a
// chat scrolls on any page (scrollQuiet.ts), another chat's change draws no page: each page draws all it
// held once, after the scroll rests. A pane draws only from a snapshot, so counted snapshots are its
// renders: this fails if a page, hidden or not, draws for another chat while a wheel moves.
import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { settleReact } from "./support/domTeardown";
import { resetKeptTailsForTests } from "../src/agent-session/acpmux/tailCache";
import {
  createScrollQuiet,
  pageScrollQuiet,
  resetPageScrollQuietForTests,
  SCROLL_HOLD_MAX_MS,
  SCROLL_QUIET_MS,
} from "../src/agent-session/acpmux/scrollQuiet";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: "window" in scope,
  document: "document" in scope,
  values: { window: scope.window, document: scope.document },
};
const visibility: "visible" | "hidden" = "visible";
const savedSchedule = AcpmuxDirectClient.scheduleFrame;
let frames: (() => void)[] = [];

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
  Object.defineProperty(dom.window.document, "visibilityState", { configurable: true, get: () => visibility });
});

afterAll(async () => {
  resetPageScrollQuietForTests();
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
  resetPageScrollQuietForTests();
  frames = [];
  AcpmuxDirectClient.scheduleFrame = (run) => void frames.push(run);
});

function flushFrames(): void {
  const due = frames;
  frames = [];
  for (const run of due) run();
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
      endpoint: "ws://scroll-hold.invalid/",
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

test("while a chat scrolls, other chats' changes draw no page; they draw once when it rests", async () => {
  const clock = manualClock();
  resetPageScrollQuietForTests(clock);
  const { socket, client, snapshots } = await openPane();
  try {
    const before = snapshots();
    // A wheel every 50 ms for 600 ms, as a reader scrolls, with other chats changing all along.
    for (let step = 0; step < 12; step++) {
      pageScrollQuiet()!.scrolled();
      burst(socket, 3, step);
      flushFrames();
      clock.advance(50);
      flushFrames();
    }
    expect(snapshots() - before).toBe(0);
    clock.advance(SCROLL_QUIET_MS + 100);
    flushFrames();
    expect(snapshots() - before).toBe(1);
  } finally {
    client.close();
  }
});

test("the scrolled page's own chat still draws while it scrolls", async () => {
  const clock = manualClock();
  resetPageScrollQuietForTests(clock);
  const { socket, client, snapshots } = await openPane();
  try {
    const before = snapshots();
    pageScrollQuiet()!.scrolled();
    socket.notify("_acpmux/session_changed", {
      sessionId: SELECTED,
      session: { ...summary(1, "running"), title: "Renamed" },
      kind: "renamed",
      recordKind: "renamed",
      seq: 401,
    });
    flushFrames();
    expect(snapshots() - before).toBe(1);
    clock.advance(SCROLL_QUIET_MS + 100);
  } finally {
    client.close();
  }
});

/// A clock a test moves by hand.
function manualClock() {
  let now = 0;
  const timers = new Map<number, { at: number; run: () => void }>();
  let next = 0;
  return {
    now: () => now,
    set: (run: () => void, ms: number) => {
      timers.set(++next, { at: now + ms, run });
      return next;
    },
    clear: (id: unknown) => void timers.delete(id as number),
    advance(ms: number) {
      now += ms;
      for (const [id, timer] of [...timers].sort((a, b) => a[1].at - b[1].at))
        if (timer.at <= now && timers.delete(id)) timer.run();
    },
  };
}

/// Two pages' channels, as BroadcastChannel joins pages of one origin (a page never hears its own).
function pairedChannels() {
  type End = {
    onmessage: ((event: MessageEvent) => void) | null;
    postMessage(data: unknown): void;
    close(): void;
  };
  const a: End = { onmessage: null, postMessage: () => b.onmessage?.({} as MessageEvent), close() {} };
  const b: End = { onmessage: null, postMessage: () => a.onmessage?.({} as MessageEvent), close() {} };
  return [a, b] as const;
}

test("another page's scroll holds this page's waits until it rests", () => {
  const clock = manualClock();
  const [one, two] = pairedChannels();
  const scrolled = createScrollQuiet(clock, one);
  const other = createScrollQuiet(clock, two);
  let ran = 0;
  scrolled.scrolled();
  expect(other.scrolling()).toBe(true);
  other.afterScroll(() => (ran += 1));
  clock.advance(SCROLL_QUIET_MS - 1);
  expect(ran).toBe(0);
  clock.advance(1);
  expect(ran).toBe(1);
  expect(other.scrolling()).toBe(false);
});

test("a scroll that goes on holds a change at most the hold limit", () => {
  const clock = manualClock();
  const quiet = createScrollQuiet(clock, undefined);
  let ran = 0;
  quiet.scrolled();
  quiet.afterScroll(() => (ran += 1));
  for (let at = 0; at < SCROLL_HOLD_MAX_MS - 100; at += 100) {
    quiet.scrolled();
    clock.advance(100);
  }
  expect(ran).toBe(0);
  quiet.scrolled();
  clock.advance(200);
  expect(ran).toBe(1);
});

test("a cancelled wait never runs", () => {
  const clock = manualClock();
  const quiet = createScrollQuiet(clock, undefined);
  let ran = 0;
  quiet.scrolled();
  const cancel = quiet.afterScroll(() => (ran += 1));
  cancel();
  clock.advance(SCROLL_HOLD_MAX_MS);
  expect(ran).toBe(0);
});
