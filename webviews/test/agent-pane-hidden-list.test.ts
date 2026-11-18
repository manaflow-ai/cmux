// l10n-allow-file: test fixture titles, not shipped UI.
// A hidden page hears no other chat's change (Leo, 2026-11-18: "Why should non visible thing even
// affect the renderer thread anyways?"). Every agent page watches the session list, the hidden New
// Tab page and the prewarmed spare page too, and all of them share one renderer: each change of any
// of 10K chats was parsed and folded in every hidden page. A page now tells acpmux it is hidden
// (`_acpmux/watch {shown: false}`, acpmux server/list_shown.rs); acpmux then sends it only the chats
// it is attached to, and on show the page follows the rows that changed meanwhile and draws once.
//
// The fake below gates as acpmux does: a connection whose watch said `shown: false` hears its own
// chat only, and a show's follow holds the rows it was not sent.
import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
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
  resetKeptTailsForTests();
  frames = [];
  AcpmuxDirectClient.scheduleFrame = (run) => void frames.push(run);
});

function flushFrames(): void {
  const due = frames;
  frames = [];
  for (const run of due) run();
}

async function settle(): Promise<void> {
  for (let i = 0; i < 8; i++) {
    await new Promise((resolve) => setTimeout(resolve, 0));
    flushFrames();
  }
}

function setVisibility(next: "visible" | "hidden"): void {
  visibility = next;
  dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
}

const SESSIONS = 500;
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

/// acpmux, as the page's socket sees it, with `session-list-shown-v1`.
class FakeAcpmux {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  rows = new Map<string, ReturnType<typeof summary>>();
  at = new Map<string, number>();
  listSeq = 1;
  shown = true;
  /// The last position sent while shown (acpmux `Conn::list_sent`).
  sent = 1;
  /// `session_changed` notices the page was sent.
  delivered = 0;
  watches: Record<string, unknown>[] = [];
  constructor() {
    for (let n = 1; n <= SESSIONS; n++) this.rows.set(id(n), summary(n));
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.();
    });
  }
  send(raw: string): void {
    const message = JSON.parse(raw) as { id?: number; method: string; params?: Record<string, any> };
    if (message.id === undefined) return;
    const result =
      message.method === "initialize"
        ? {
            protocolVersion: 1,
            _meta: {
              acpmux: {
                origin: "local",
                extensions: [],
                capabilities: ["acpmux-v1", "session-list-follow-v1", "session-list-shown-v1"],
              },
            },
          }
        : message.method === "_acpmux/watch"
          ? this.watch(message.params ?? {})
          : message.method === "_acpmux/attach"
            ? { session: this.rows.get(SELECTED), lastSeq: 0, events: [], hasMore: false }
            : message.method === "_acpmux/events"
              ? { events: [], hasMore: false, lastSeq: 0 }
              : {};
    queueMicrotask(() => this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) }));
  }
  /// acpmux server/list_reply.rs `watch` with list_shown.rs.
  private watch(params: Record<string, any>): Record<string, unknown> {
    this.watches.push(params);
    let after: number | undefined = typeof params.afterSeq === "number" ? params.afterSeq : undefined;
    if (params.shown === false) this.shown = false;
    else if (params.shown === true && !this.shown) {
      this.shown = true;
      if (after !== undefined) after = Math.min(after, this.sent);
    }
    this.sent = Math.max(this.sent, this.listSeq);
    const cursor = { listEpoch: "e1", listSeq: this.listSeq };
    if (after !== undefined) {
      const sessions = [...this.rows.values()].filter((row) => (this.at.get(row.sessionId) ?? 0) > after!);
      return { follow: true, more: false, gone: [], sessions, ...cursor };
    }
    const sessions = [...this.rows.values()].sort((a, b) => b.updatedAt - a.updatedAt);
    return { sessions: params.limit === 1 ? sessions.slice(0, 1) : sessions, ...cursor };
  }
  /// A change of chat `n`, as acpmux deliver()s it to this connection.
  change(n: number, status: string): void {
    this.listSeq += 1;
    const row = summary(n, status, 2_000_000 + this.listSeq);
    this.rows.set(row.sessionId, row);
    this.at.set(row.sessionId, this.listSeq);
    if (!this.shown && row.sessionId !== SELECTED) return;
    if (this.shown) this.sent = this.listSeq;
    this.delivered += 1;
    this.onmessage?.({
      data: JSON.stringify({
        jsonrpc: "2.0",
        method: "_acpmux/session_changed",
        params: { sessionId: row.sessionId, session: row, kind: "status", seq: 10, listSeq: this.listSeq },
      }),
    });
  }
  close(): void {
    this.readyState = 3;
  }
}

async function openPage() {
  const socket = new FakeAcpmux();
  let count = 0;
  let last: any;
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://hidden-list.invalid/",
      token: "t",
      sessionId: SELECTED,
    },
    (message: any) => {
      if (message?.type !== "snapshot") return;
      count += 1;
      last = message;
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  await client.select(SELECTED);
  await settle();
  return { socket, client, snapshots: () => count, last: () => last };
}

const titleOf = (snapshot: any, n: number) =>
  (snapshot?.sessions as any[] | undefined)?.find((entry) => (entry.session ?? entry).sessionId === id(n));

test("a hidden page is sent 0 other chats' changes and draws 0 times; shown, it draws them once", async () => {
  const { socket, client, snapshots, last } = await openPage();
  try {
    setVisibility("hidden");
    await settle();
    const before = { snapshots: snapshots(), delivered: socket.delivered };
    for (let n = 2; n <= 301; n++) socket.change(n, "running");
    await settle();
    expect(socket.delivered - before.delivered).toBe(0);
    expect(snapshots() - before.snapshots).toBe(0);

    // Its own chat still reaches it, and moves no cursor past the rows it was not sent.
    socket.change(1, "running");
    await settle();
    expect(socket.delivered - before.delivered).toBe(1);

    const drawn = snapshots();
    setVisibility("visible");
    await settle();
    const show = socket.watches.at(-1)!;
    expect(show.shown).toBe(true);
    expect(typeof show.afterSeq).toBe("number");
    expect(snapshots() - drawn).toBe(1);
    // Every row changed while hidden is in the page now.
    for (const n of [2, 150, 301]) expect(JSON.stringify(titleOf(last(), n))).toContain("running");
  } finally {
    client.close();
    setVisibility("visible");
  }
});

test("a page born hidden says so on its first watch", async () => {
  setVisibility("hidden");
  const { socket, client } = await openPage();
  try {
    const before = socket.delivered;
    for (let n = 2; n <= 50; n++) socket.change(n, "running");
    await settle();
    expect(socket.delivered - before).toBe(0);
    expect(socket.watches[0]?.shown).toBe(false);
  } finally {
    client.close();
    setVisibility("visible");
  }
});
