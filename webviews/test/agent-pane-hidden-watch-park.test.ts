// l10n-allow-file: test fixture titles, not shipped UI.
// A hidden agent pane costs nothing per change of another chat (Leo, 2026-11-20, about 600 chats:
// "My Mac is at load 272 on 15 cores"; the shared renderer at 168% of a core). acpmux tells every
// watching connection every chat's change, one whole row each, so every hidden pane parsed and laid
// each one over its list: the renderer's work grew with chats times panes. A pane hidden for
// `WATCH_PARK_AFTER_MS` now parks its watch (`_acpmux/watch {enabled: false, attachedRows: true}`,
// acpmux `watch-attached-rows-v1`): its own chat's row still comes, no other chat's does, and
// shown again it follows the list from its cursor: the rows changed meanwhile, never the list.
import { afterAll, beforeAll, beforeEach, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { forgetHeldLists } from "../src/agent-session/acpmux/sessionPages";
import { settleReact } from "./support/domTeardown";
import { resetKeptTailsForTests } from "../src/agent-session/acpmux/tailCache";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: "window" in scope,
  document: "document" in scope,
  values: { window: scope.window, document: scope.document },
};
let visibility: "visible" | "hidden" = "visible";
const savedSchedule = AcpmuxDirectClient.scheduleFrame;

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
  resetKeptTailsForTests();
  forgetHeldLists();
  AcpmuxDirectClient.scheduleFrame = (run) => {
    run();
  };
});

function setVisibility(next: "visible" | "hidden"): void {
  visibility = next;
  dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
}

const SESSIONS = 600;
const id = (n: number) => `0190a000-0000-7000-8000-${n.toString(16).padStart(12, "0")}`;
const SELECTED = id(1);
const summary = (n: number, fields: Record<string, unknown> = {}) => ({
  sessionId: id(n),
  cwd: `/home/dev/project-${n % 40}`,
  title: `Chat ${n}`,
  harness: "claude",
  family: "claude",
  status: "idle",
  turnCount: 12,
  updatedAt: 1_000_000 + n,
  ...fields,
});

/// acpmux's list as a row log (hub/row_log.rs): each change takes the next `listSeq`; a watch with
/// `afterSeq` answers the rows changed since; `enabled: false` stops the notices.
class FakeAcpmux {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  rows = Array.from({ length: SESSIONS }, (_, n) => summary(n + 1));
  rowSeq = new Map<string, number>();
  seq = 1;
  watching = false;
  /// Off with `attachedRows`: the attached chat's row (SELECTED) still comes.
  watchingAttached = false;
  watches: Record<string, unknown>[] = [];
  /// `session_changed` notices that reached the page.
  told = 0;
  constructor(readonly follows = true) {
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.();
    });
  }
  send(raw: string): void {
    const message = JSON.parse(raw) as { id?: number; method: string; params?: Record<string, any> };
    if (message.id === undefined) return;
    const params = message.params ?? {};
    let result: unknown = {};
    if (message.method === "initialize")
      result = {
        protocolVersion: 1,
        _meta: {
          acpmux: {
            origin: "local",
            extensions: [],
            capabilities: this.follows ? ["session-list-follow-v1", "watch-attached-rows-v1"] : [],
          },
        },
      };
    else if (message.method === "_acpmux/watch") {
      this.watches.push(params);
      this.watching = params.enabled !== false;
      this.watchingAttached = !this.watching && params.attachedRows === true;
      const at = { listSeq: this.seq, listEpoch: "e1" };
      if (!this.watching) result = this.watchingAttached ? {} : { ...at, sessions: this.rows };
      else if (this.follows && params.listEpoch === "e1" && typeof params.afterSeq === "number")
        result = {
          ...at,
          follow: true,
          sessions: this.rows.filter((row) => (this.rowSeq.get(row.sessionId) ?? 0) > params.afterSeq),
        };
      else result = { ...at, sessions: this.rows };
    } else if (message.method === "_acpmux/attach")
      result = { session: this.rows[0], lastSeq: 0, events: [], hasMore: false };
    else if (message.method === "_acpmux/events") result = { events: [], hasMore: false, lastSeq: 0 };
    queueMicrotask(() => this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) }));
  }
  /// Chat `n` changed, as acpmux tells a watching connection.
  change(n: number, fields: Record<string, unknown>): void {
    const row = summary(n, fields);
    this.rows[n - 1] = row;
    this.seq += 1;
    this.rowSeq.set(row.sessionId, this.seq);
    if (!this.watching && !(this.watchingAttached && row.sessionId === SELECTED)) return;
    this.told += 1;
    this.onmessage?.({
      data: JSON.stringify({
        jsonrpc: "2.0",
        method: "_acpmux/session_changed",
        params: { sessionId: row.sessionId, session: row, kind: "updated", listSeq: this.seq },
      }),
    });
  }
  close(): void {
    this.readyState = 3;
  }
}

async function settle(): Promise<void> {
  for (let i = 0; i < 8; i++) await new Promise((resolve) => setTimeout(resolve, 0));
}

async function openPane(follows = true) {
  const socket = new FakeAcpmux(follows);
  let last: any;
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://park.invalid/",
      token: "t",
      sessionId: SELECTED,
    },
    (message: any) => {
      if (message?.type === "snapshot") last = message;
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  await client.select(SELECTED);
  await settle();
  return { socket, client, last: () => last };
}

/// Advances fake time by `ms` and lets the requests it started answer (their replies are microtasks).
async function advance(ms: number): Promise<void> {
  jest.advanceTimersByTime(ms);
  for (let i = 0; i < 8; i++) await Promise.resolve();
}

test("a pane hidden past the park delay turns its watch off, hears nothing, and catches up when shown", async () => {
  const { socket, client, last } = await openPane();
  jest.useFakeTimers();
  try {
    setVisibility("hidden");
    await advance(6000);
    expect(socket.watches.at(-1)).toEqual({ enabled: false, attachedRows: true });
    const toldBefore = socket.told;
    for (let n = 2; n < 300; n++) socket.change(n, { status: "running", updatedAt: 2_000_000 + n });
    // Parked: not one of 298 other chats' changes reached the page.
    expect(socket.told - toldBefore).toBe(0);
    // Its own chat's row still comes, so its tab and header stay right while hidden.
    socket.change(1, { title: "Renamed while hidden" });
    expect(socket.told - toldBefore).toBe(1);
    jest.useRealTimers();
    setVisibility("visible");
    await settle();
    const rewatch = socket.watches.at(-1)!;
    expect(rewatch.enabled).toBe(true);
    // A follow from the cursor: the 299 changed rows, never the list.
    expect(typeof rewatch.afterSeq).toBe("number");
    const sessions = last().sessions as { sessionId: string; status: string; title: string }[];
    expect(sessions).toHaveLength(SESSIONS);
    expect(sessions.find((entry) => entry.sessionId === id(42))?.status).toBe("running");
    expect(sessions.find((entry) => entry.sessionId === SELECTED)?.title).toBe("Renamed while hidden");
    // Shown, it hears changes again.
    const toldShown = socket.told;
    socket.change(500, { status: "running" });
    expect(socket.told - toldShown).toBe(1);
  } finally {
    jest.useRealTimers();
    client.close();
    setVisibility("visible");
  }
});

test("a quick hide (a tab switch) keeps the watch on", async () => {
  const { socket, client } = await openPane();
  jest.useFakeTimers();
  try {
    const watches = socket.watches.length;
    setVisibility("hidden");
    await advance(2000);
    setVisibility("visible");
    await advance(10_000);
    expect(socket.watches.length).toBe(watches);
  } finally {
    jest.useRealTimers();
    client.close();
    setVisibility("visible");
  }
});

test("a daemon without list follow or attached rows keeps every hidden pane watching", async () => {
  const { socket, client } = await openPane(false);
  jest.useFakeTimers();
  try {
    const watches = socket.watches.length;
    setVisibility("hidden");
    await advance(30_000);
    expect(socket.watches.length).toBe(watches);
  } finally {
    jest.useRealTimers();
    client.close();
    setVisibility("visible");
  }
});
