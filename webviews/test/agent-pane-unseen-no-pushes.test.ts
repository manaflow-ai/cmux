// l10n-allow-file: test fixture titles, not shipped UI.
// Leo, 2026-11-18: "Why should non visible thing even affect the renderer thread anyways?"
//
// Every agent page shares one renderer, and acpmux told each one every chat's `session_changed`,
// about 4 a second at a fleet's scale: the pages nobody saw (a tab behind another, the New Tab
// spare waiting off screen) woke the renderer for each one. A page nobody sees now turns its list
// watch off, so acpmux sends it none, and when it shows it reads the rows changed meanwhile in one
// follow and draws them once. The host tells a page nobody sees though its document says visible
// (the spare) with `window.cmuxPageSeen(false)` (shared/pageSeen.ts).
import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { installPageSeen, hostSeesPage } from "../src/agent-session/shared/pageSeen";
import {
  createScrollQuiet,
  pageScrollQuiet,
  resetPageScrollQuietForTests,
  SCROLL_QUIET_MS,
} from "../src/agent-session/acpmux/scrollQuiet";
import { settleReact } from "./support/domTeardown";
import { resetKeptTailsForTests } from "../src/agent-session/acpmux/tailCache";

// `pretendToBeVisual`: the document reads "visible", as a shown page does (JSDOM says "prerender" otherwise).
const dom = new JSDOM("<!doctype html>", { url: "http://localhost/", pretendToBeVisual: true });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: "window" in scope,
  document: "document" in scope,
  values: { window: scope.window, document: scope.document },
};
const savedSchedule = AcpmuxDirectClient.scheduleFrame;
let frames: (() => void)[] = [];
let setSeen: (seen: boolean) => void = () => {};

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
  setSeen = installPageSeen(dom.window as unknown as Window)!;
});

afterAll(async () => {
  AcpmuxDirectClient.scheduleFrame = savedSchedule;
  await settleReact();
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

beforeEach(() => {
  resetKeptTailsForTests();
  frames = [];
  AcpmuxDirectClient.scheduleFrame = (run) => void frames.push(run);
  setSeen(true);
});

function flushFrames(): void {
  const due = frames;
  frames = [];
  for (const run of due) run();
}

const SESSIONS = 1000;
const id = (n: number) => `0190a000-0000-7000-8000-${n.toString(16).padStart(12, "0")}`;
const SELECTED = id(1);
const summary = (n: number, status = "idle", updatedAt = 1_000_000 + n) => ({
  sessionId: id(n),
  cwd: `/home/dev/project-${n % 40}`,
  title: `Chat ${n}`,
  harness: "claude",
  family: "claude",
  status,
  turnCount: 12,
  updatedAt,
});
const transcript = Array.from({ length: 40 }, (_, i) => ({
  sessionId: SELECTED,
  seq: i + 1,
  at: i + 1,
  dir: "mux",
  kind: "user_message",
  msg: { prompt: [{ type: "text", text: `Question ${i + 1}` }] },
}));

/// acpmux with the list's row log (`session-list-follow-v1`): it sends `session_changed` only while
/// the connection watches, and a watch from a position answers the rows changed since.
class FollowingAcpmux {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  watching = false;
  watches: Record<string, unknown>[] = [];
  /// `session_changed` notices this connection was sent.
  sent = 0;
  private seq = 0;
  private rows = new Map<string, { row: ReturnType<typeof summary>; seq: number }>();
  constructor() {
    for (let n = 1; n <= SESSIONS; n++) this.rows.set(id(n), { row: summary(n), seq: 0 });
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.();
    });
  }
  send(raw: string): void {
    const message = JSON.parse(raw) as { id?: number; method: string; params?: Record<string, any> };
    if (message.id === undefined) return;
    let result: unknown = {};
    if (message.method === "initialize")
      result = {
        protocolVersion: 1,
        _meta: { acpmux: { origin: "local", extensions: [], capabilities: ["session-list-follow-v1"] } },
      };
    else if (message.method === "_acpmux/watch") result = this.watch(message.params ?? {});
    else if (message.method === "_acpmux/attach")
      result = { session: summary(1), lastSeq: transcript.length, events: transcript, hasMore: false };
    else if (message.method === "_acpmux/events") result = { events: [], hasMore: false, lastSeq: transcript.length };
    queueMicrotask(() => this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) }));
  }
  private watch(params: Record<string, any>): unknown {
    this.watches.push(params);
    if (params.enabled === false) {
      this.watching = false;
      return {};
    }
    this.watching = true;
    const at = { listSeq: this.seq, listEpoch: "run-1" };
    if (params.listEpoch === "run-1" && typeof params.afterSeq === "number")
      return {
        follow: true,
        sessions: [...this.rows.values()].filter((entry) => entry.seq > params.afterSeq).map((entry) => entry.row),
        gone: [],
        more: false,
        ...at,
      };
    return { sessions: [...this.rows.values()].map((entry) => entry.row), ...at };
  }
  /// Another chat changes, as acpmux tells a watching connection.
  change(n: number, status: string): void {
    this.seq += 1;
    const row = summary(n, status, 2_000_000 + this.seq);
    this.rows.set(id(n), { row, seq: this.seq });
    if (!this.watching) return;
    this.sent += 1;
    this.onmessage?.({
      data: JSON.stringify({
        jsonrpc: "2.0",
        method: "_acpmux/session_changed",
        params: { sessionId: id(n), session: row, kind: "updated", listSeq: this.seq },
      }),
    });
  }
  close(): void {
    this.readyState = 3;
  }
}

async function settle(): Promise<void> {
  for (let i = 0; i < 6; i++) {
    await new Promise((resolve) => setTimeout(resolve, 0));
    flushFrames();
  }
}

async function openPane() {
  const socket = new FollowingAcpmux();
  let count = 0;
  let last: any;
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://unseen.invalid/", token: "t", sessionId: SELECTED },
    (message: any) => {
      if (message?.type !== "snapshot") return;
      count += 1;
      last = message.snapshot ?? message;
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  await client.select(SELECTED);
  await settle();
  return { socket, client, snapshots: () => count, last: () => last };
}

test("the host's seen switch makes the document read hidden and back, with one visibilitychange each", () => {
  const doc = dom.window.document;
  let changes = 0;
  const heard = () => (changes += 1);
  doc.addEventListener("visibilitychange", heard);
  try {
    expect(doc.visibilityState).toBe("visible");
    setSeen(false);
    expect(doc.visibilityState).toBe("hidden");
    expect(doc.hidden).toBe(true);
    expect(hostSeesPage(doc)).toBe(false);
    setSeen(false);
    expect(changes).toBe(1);
    setSeen(true);
    expect(doc.visibilityState).toBe("visible");
    expect(doc.hidden).toBe(false);
    expect(changes).toBe(2);
  } finally {
    doc.removeEventListener("visibilitychange", heard);
  }
});

test("a page nobody sees gets no other chat's change, and shows them in one follow and one draw", async () => {
  const { socket, client, snapshots } = await openPane();
  try {
    expect(socket.watching).toBe(true);
    setSeen(false);
    await Promise.resolve();
    await settle();
    expect(socket.watches.at(-1)).toEqual({ enabled: false });
    expect(socket.watching).toBe(false);
    const sentBefore = socket.sent;
    const drawnBefore = snapshots();
    // A minute of a fleet's changes: 4 a second.
    for (let n = 0; n < 240; n++) {
      socket.change(2 + (n % 50), n % 2 ? "running" : "idle");
      flushFrames();
    }
    expect(socket.sent - sentBefore).toBe(0);
    expect(snapshots() - drawnBefore).toBe(0);
    const watchesBefore = socket.watches.length;
    setSeen(true);
    await settle();
    await settle();
    // One follow from the list's position: the 50 rows that changed, not the 1,000.
    const reads = socket.watches.slice(watchesBefore);
    expect(reads.length).toBe(1);
    expect(reads[0]).toMatchObject({ enabled: true, listEpoch: "run-1" });
    expect(typeof reads[0]!.afterSeq).toBe("number");
    expect(socket.watching).toBe(true);
    expect(snapshots() - drawnBefore).toBe(1);
    // Seen again, it hears changes as before.
    socket.change(3, "running");
    expect(socket.sent - sentBefore).toBe(1);
  } finally {
    client.close();
  }
});

test("a page hidden during a scroll hold leaves the held changes for the show", async () => {
  const { socket, client, snapshots } = await openPane();
  const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
  try {
    const before = snapshots();
    // Another chat changes while a chat scrolls: held for the rest.
    pageScrollQuiet()!.scrolled();
    socket.change(5, "running");
    flushFrames();
    expect(snapshots() - before).toBe(0);
    // Hidden before the scroll rests: the hold's expiry must not draw (it drew after 50 ms).
    setSeen(false);
    await wait(SCROLL_QUIET_MS + 150);
    flushFrames();
    expect(snapshots() - before).toBe(0);
  } finally {
    resetPageScrollQuietForTests();
    client.close();
  }
});

test("a scroll quiet with no channel opens none", () => {
  const Real = (globalThis as { BroadcastChannel?: unknown }).BroadcastChannel;
  let opened = 0;
  (globalThis as { BroadcastChannel?: unknown }).BroadcastChannel = class {
    constructor() {
      opened += 1;
    }
    postMessage() {}
    close() {}
  };
  try {
    const clock = { now: () => 0, set: () => 0, clear: () => {} };
    createScrollQuiet(clock as never, null).dispose();
    expect(opened).toBe(0);
  } finally {
    (globalThis as { BroadcastChannel?: unknown }).BroadcastChannel = Real;
  }
});
