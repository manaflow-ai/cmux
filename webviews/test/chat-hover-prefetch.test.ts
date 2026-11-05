// l10n-allow-file: test fixture prompts, replies and titles, not shipped UI.
//
// A chat the pointer rests on in the sidebar is read before the click (HQ#5914, finding 2; Leo
// 2026-11-01: "it's not cached well enough nor prerendered/prefetched well enough"). The native
// sidebar forwards each row the pointer is on as `chat.prefetch {hover: true}` to the agent page on
// screen; that page waits for the hover to rest (hoverPrefetch.ts), reads the chat ahead and hands
// its tail to the app host, so the tab the click opens (a new page) draws it before its attach.
//
//   - a rested hover reads the chat once and the host holds it; a new tab on it draws before its
//     attach answers;
//   - a pointer passing over rows reads none of them (dwell), and only the row it stops on is read;
//   - a hover back on a chat read moments ago reads nothing again (dedupe), and a hover never puts
//     an older copy over a newer one the host holds;
//   - Low Power Mode, a hover that left and the client's close each cancel a waiting hover;
//   - the policy's own bounds: one timer, the HOVER_RECENT chats remembered (eviction).
import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import {
  HOVER_DWELL_MS,
  HOVER_RECENT,
  HOVER_REFIRE_MS,
  HoverPrefetch,
  type HoverClock,
} from "../src/agent-session/acpmux/hoverPrefetch";
import { resetKeptTailsForTests } from "../src/agent-session/acpmux/tailCache";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

const START = Date.UTC(2026, 10, 1, 9, 0, 0);
const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = { window: scope.window, document: scope.document, had: "window" in scope };

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});

afterAll(() => {
  if (saved.had) Object.assign(scope, { window: saved.window, document: saved.document });
  else {
    delete scope.window;
    delete scope.document;
  }
});

type Message = { id?: number; method: string; params?: Record<string, unknown> };

const CHATS = ["hover-a", "hover-b", "hover-c"];
const records = (sessionId: string) =>
  [
    ["mux", "user_message", { text: `Question for ${sessionId}` }],
    [
      "in",
      "agent_message_chunk",
      {
        method: "session/update",
        params: {
          sessionId,
          update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `Reply in ${sessionId}.` } },
        },
      },
    ],
  ].map(([dir, kind, msg], at) => ({ sessionId, seq: at + 1, at: START + at * 1000, dir, kind, msg }));

/// acpmux for three chats. Counts every `_acpmux/events` read of a chat the page does not show (the
/// page reads its own chat's pages too, its usage and older history): a hover's read is one.
/// `hold` keeps that chat's attach unanswered, so a test sees what a page draws before it.
class Daemon {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  hold?: string;
  readonly reads = new Map<string, number>();

  constructor() {
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.();
    });
  }

  send(raw: string): void {
    const message = JSON.parse(raw) as Message;
    if (message.id === undefined) return;
    const sessionId = String(message.params?.sessionId ?? "");
    if (message.method === "_acpmux/attach" && sessionId === this.hold) return;
    queueMicrotask(() => this.answer(message, sessionId));
  }

  close(): void {
    this.readyState = 3;
  }

  private summary(sessionId: string, at: number) {
    return {
      sessionId,
      cwd: "/home/dev/project",
      title: `Chat ${sessionId}`,
      harness: "claude",
      status: "idle",
      turnCount: 1,
      updatedAt: START - at * 60_000,
    };
  }

  private answer(message: Message, sessionId: string): void {
    let result: unknown = {};
    if (message.method === "initialize")
      result = { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    else if (message.method === "_acpmux/watch") result = { sessions: CHATS.map((id, at) => this.summary(id, at)) };
    else if (message.method === "_acpmux/attach") {
      const events = records(sessionId);
      result = { session: this.summary(sessionId, CHATS.indexOf(sessionId)), lastSeq: 2, events, hasMore: false };
    } else if (message.method === "_acpmux/events") {
      if (sessionId !== CHATS[0]) this.reads.set(sessionId, (this.reads.get(sessionId) ?? 0) + 1);
      result = { events: records(sessionId), hasMore: false, lastSeq: 2 };
    }
    this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) });
  }
}

const newestSeq = (tail: any): number => Math.max(0, ...(tail?.events ?? []).map((event: any) => Number(event.seq)));

/// The app host's tail store (AgentPaneTailCache), shared by every page as the app is.
class Host {
  readonly tails = new Map<string, any>();
  install(): void {
    (
      dom.window as unknown as { cmuxAcpmuxActions: Record<string, (params: any) => Promise<unknown>> }
    ).cmuxAcpmuxActions = {
      "chat.tail.get": async (params: any) => this.tails.get(String(params.sessionId)) ?? null,
      "chat.tail": async (params: any) => {
        const sessionId = String(params.sessionId);
        // A hover's hand-over is compared and kept in one step, as AgentPaneTailCache.rememberIfNewer does.
        const kept = this.tails.get(sessionId);
        if (params.ifNewer === true && kept && newestSeq(kept) >= newestSeq(params.tail)) return null;
        this.tails.delete(sessionId);
        if (Array.isArray(params.tail?.events) && params.tail.events.length > 0) this.tails.set(sessionId, params.tail);
        return null;
      },
    };
  }
}

const flush = async () => {
  for (let pass = 0; pass < 8; pass += 1) await new Promise((resolve) => setTimeout(resolve, 0));
};
// fixed-wait: the hover dwell is the behavior under test (real timers in the client)
const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
/// Past the dwell, with the read it starts answered.
const rest = async () => {
  // fixed-wait: the hover dwell is the behavior under test (real timers in the client)
  await wait(HOVER_DWELL_MS + 40);
  await flush();
};
const text = (snapshot: AcpmuxSnapshot | undefined) => JSON.stringify(snapshot?.rows ?? []);

let live: AcpmuxDirectClient[] = [];
let host = new Host();
afterEach(() => {
  for (const client of live) client.close();
  live = [];
  delete (dom.window as unknown as { cmuxAcpmuxActions?: unknown }).cmuxAcpmuxActions;
  resetKeptTailsForTests();
});

/// A page on `sessionId`; `hold` keeps its attach unanswered and the connect is not awaited.
function page(sessionId: string, options: { hold?: boolean } = {}) {
  const daemon = new Daemon();
  if (options.hold) daemon.hold = sessionId;
  const drawn: AcpmuxSnapshot[] = [];
  const client = AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://hover.invalid/", token: "t", sessionId },
    (snapshot) => {
      if (snapshot.type === "snapshot") drawn.push(snapshot);
    },
    undefined,
    () => daemon as unknown as WebSocket,
  );
  return { daemon, drawn, client, last: () => drawn.at(-1) };
}

/// The page on screen, on chat A, connected. Hovers go to it, as the sidebar sends them.
async function worker() {
  host = new Host();
  host.install();
  const shown = page(CHATS[0]!);
  const client = await shown.client;
  live.push(client);
  await flush();
  return { ...shown, client };
}

describe("sidebar hover prefetch, through the page on screen", () => {
  test("a rested hover reads the chat once, the host holds it, and a new tab draws it before its attach", async () => {
    const shown = await worker();
    shown.client.hoverPrefetch(CHATS[1]);
    // fixed-wait: the hover dwell is the behavior under test (real timers in the client)
    await rest();
    expect(shown.daemon.reads.get(CHATS[1]!)).toBe(1);
    expect(host.tails.has(CHATS[1]!)).toBe(true);

    // The click opens chat B in its own tab: a new page, holding nothing, with acpmux slow to attach.
    resetKeptTailsForTests();
    const opened = page(CHATS[1]!, { hold: true });
    await flush();
    expect(opened.last()?.sessionId).toBe(CHATS[1]);
    expect(text(opened.last())).toContain(`Reply in ${CHATS[1]}.`);
    void opened.client.then((client) => client.close());
  });

  test("a pointer passing over rows reads none of them, and the row it stops on is the one read", async () => {
    const shown = await worker();
    shown.client.hoverPrefetch(CHATS[1]);
    // fixed-wait: the hover dwell is the behavior under test (real timers in the client)
    await wait(HOVER_DWELL_MS / 4);
    shown.client.hoverPrefetch(CHATS[2]);
    // fixed-wait: the hover dwell is the behavior under test (real timers in the client)
    await wait(HOVER_DWELL_MS / 4);
    shown.client.hoverPrefetch(undefined);
    // fixed-wait: the hover dwell is the behavior under test (real timers in the client)
    await rest();
    expect(shown.daemon.reads.size).toBe(0);
    expect(host.tails.size).toBe(0);

    shown.client.hoverPrefetch(CHATS[1]);
    // fixed-wait: the hover dwell is the behavior under test (real timers in the client)
    await wait(HOVER_DWELL_MS / 4);
    shown.client.hoverPrefetch(CHATS[2]);
    // fixed-wait: the hover dwell is the behavior under test (real timers in the client)
    await rest();
    expect(shown.daemon.reads.get(CHATS[1]!)).toBeUndefined();
    expect(shown.daemon.reads.get(CHATS[2]!)).toBe(1);
    expect([...host.tails.keys()]).toEqual([CHATS[2]]);
  });

  /// The Codex review of ea872ad4: a hover on a chat this page read ahead earlier, while another tab
  /// has since handed the host a newer read of it, must not put the page's older copy over the
  /// host's. The next tab would draw fewer messages until its attach answered.
  test("a hover never replaces a newer host copy with this page's older one", async () => {
    const shown = await worker();
    const chat = CHATS[1]!;
    shown.client.hoverPrefetch(chat);
    await rest();
    expect(shown.daemon.reads.get(chat)).toBe(1);
    // Another tab read the chat on since: the host's copy now ends two records later.
    const newer = structuredClone(host.tails.get(chat));
    const last = newer.events.at(-1);
    newer.events.push(
      { ...last, seq: last.seq + 1, kind: "user_message", dir: "mux", msg: { text: "A newer question." } },
      { ...last, seq: last.seq + 2 },
    );
    host.tails.set(chat, newer);
    // The pointer comes back to the row past the refire window: no read is needed (this page's
    // read is fresh by its own clock), and its older copy must not go over the host's.
    (shown.client as unknown as { hoverReads: { fired: Map<string, number> } }).hoverReads.fired.clear();
    shown.client.hoverPrefetch(undefined);
    shown.client.hoverPrefetch(chat);
    await rest();
    expect(shown.daemon.reads.get(chat)).toBe(1);
    expect(host.tails.get(chat).events.length).toBe(newer.events.length);

    // And a new tab on the chat draws the newer copy.
    resetKeptTailsForTests();
    const opened = page(chat, { hold: true });
    await flush();
    expect(text(opened.last())).toContain("A newer question.");
    void opened.client.then((client) => client.close());
  });

  test("a hover keeps the host's fuller copy when both end on the same record", async () => {
    const shown = await worker();
    const chat = CHATS[2]!;
    shown.client.hoverPrefetch(chat);
    await rest();
    // Another tab's own read: the same newest record, and an older one the read ahead did not carry.
    const fuller = structuredClone(host.tails.get(chat));
    fuller.events.unshift({ ...fuller.events[0], seq: 0, msg: { text: "An older question." } });
    fuller.turnOpener = fuller.events[0];
    host.tails.set(chat, fuller);
    (shown.client as unknown as { hoverReads: { fired: Map<string, number> } }).hoverReads.fired.clear();
    shown.client.hoverPrefetch(undefined);
    shown.client.hoverPrefetch(chat);
    await rest();
    expect(host.tails.get(chat)).toEqual(fuller);
  });

  test("a hover back on a chat read moments ago reads nothing again", async () => {
    const shown = await worker();
    shown.client.hoverPrefetch(CHATS[1]);
    // fixed-wait: the hover dwell is the behavior under test (real timers in the client)
    await rest();
    shown.client.hoverPrefetch(undefined);
    shown.client.hoverPrefetch(CHATS[1]);
    // fixed-wait: the hover dwell is the behavior under test (real timers in the client)
    await rest();
    expect(shown.daemon.reads.get(CHATS[1]!)).toBe(1);
    expect(host.tails.has(CHATS[1]!)).toBe(true);
  });

  test("a hover on the chat the page shows hands nothing to the host", async () => {
    const shown = await worker();
    host.tails.clear();
    shown.client.hoverPrefetch(CHATS[0]);
    // fixed-wait: the hover dwell is the behavior under test (real timers in the client)
    await rest();
    expect(host.tails.size).toBe(0);
  });

  test("Low Power Mode and the client's close cancel a waiting hover", async () => {
    const shown = await worker();
    shown.client.hoverPrefetch(CHATS[1], { lowPower: true });
    // fixed-wait: the hover dwell is the behavior under test (real timers in the client)
    await rest();
    expect(shown.daemon.reads.size).toBe(0);

    shown.client.hoverPrefetch(CHATS[2]);
    shown.client.close();
    // fixed-wait: the hover dwell is the behavior under test (real timers in the client)
    await rest();
    expect(shown.daemon.reads.size).toBe(0);
    // (The close hands over the chat it showed, A, as every close does; nothing of C.)
    expect(host.tails.has(CHATS[2]!)).toBe(false);
  });
});

/// A clock the test moves by hand.
function manualClock() {
  let now = 0;
  const timers = new Map<number, { at: number; run: () => void }>();
  let next = 0;
  const clock: HoverClock = {
    now: () => now,
    setTimeout: (run, ms) => {
      next += 1;
      timers.set(next, { at: now + ms, run });
      return next;
    },
    clearTimeout: (timer) => void timers.delete(timer as number),
  };
  const advance = (ms: number) => {
    now += ms;
    for (const [id, timer] of Array.from(timers)) {
      if (timer.at > now) continue;
      timers.delete(id);
      timer.run();
    }
  };
  return { clock, advance, pending: () => timers.size };
}

describe("the hover policy (hoverPrefetch.ts)", () => {
  test("dwell: only a hover that rests reads, and one timer at a time", () => {
    const { clock, advance, pending } = manualClock();
    const read: string[] = [];
    const policy = new HoverPrefetch((id) => read.push(id), clock);
    policy.hover("a");
    advance(HOVER_DWELL_MS - 1);
    policy.hover("b");
    expect(pending()).toBe(1);
    advance(HOVER_DWELL_MS - 1);
    expect(read).toEqual([]);
    advance(1);
    expect(read).toEqual(["b"]);
    expect(pending()).toBe(0);
  });

  test("the same row again keeps its dwell running instead of starting over", () => {
    const { clock, advance } = manualClock();
    const read: string[] = [];
    const policy = new HoverPrefetch((id) => read.push(id), clock);
    policy.hover("a");
    advance(HOVER_DWELL_MS / 2);
    policy.hover("a");
    advance(HOVER_DWELL_MS / 2);
    expect(read).toEqual(["a"]);
  });

  test("dedupe: a chat read is not read again inside the refire window, and is after it", () => {
    const { clock, advance } = manualClock();
    const read: string[] = [];
    const policy = new HoverPrefetch((id) => read.push(id), clock);
    policy.hover("a");
    advance(HOVER_DWELL_MS);
    policy.hover(undefined);
    policy.hover("a");
    advance(HOVER_DWELL_MS);
    expect(read).toEqual(["a"]);
    advance(HOVER_REFIRE_MS);
    policy.hover(undefined);
    policy.hover("a");
    advance(HOVER_DWELL_MS);
    expect(read).toEqual(["a", "a"]);
  });

  test("eviction: at most HOVER_RECENT chats are remembered, the oldest forgotten first", () => {
    const { clock, advance } = manualClock();
    const read: string[] = [];
    const policy = new HoverPrefetch((id) => read.push(id), clock);
    for (let at = 0; at <= HOVER_RECENT; at += 1) {
      policy.hover(`chat-${at}`);
      advance(HOVER_DWELL_MS);
    }
    expect(policy.remembered).toBe(HOVER_RECENT);
    // chat-0 was forgotten, so it reads again; chat-1 is still remembered.
    const before = read.length;
    policy.hover("chat-1");
    advance(HOVER_DWELL_MS);
    expect(read.length).toBe(before);
    policy.hover("chat-0");
    advance(HOVER_DWELL_MS);
    expect(read.slice(before)).toEqual(["chat-0"]);
    expect(policy.remembered).toBe(HOVER_RECENT);
  });

  test("Low Power Mode on the same row cancels its waiting dwell", () => {
    const { clock, advance, pending } = manualClock();
    const read: string[] = [];
    const policy = new HoverPrefetch((id) => read.push(id), clock);
    policy.hover("b");
    policy.hover("b", { lowPower: true });
    expect(pending()).toBe(0);
    // And the host's cancel when the Mac turns Low Power Mode on (no row).
    policy.hover("c");
    policy.hover(undefined, { lowPower: true });
    advance(HOVER_DWELL_MS * 2);
    expect(read).toEqual([]);
  });

  test("cancel: no session, Low Power Mode and stop leave no timer and read nothing", () => {
    const { clock, advance, pending } = manualClock();
    const read: string[] = [];
    const policy = new HoverPrefetch((id) => read.push(id), clock);
    policy.hover("a");
    policy.hover(undefined);
    expect(pending()).toBe(0);
    policy.hover("b", { lowPower: true });
    expect(pending()).toBe(0);
    policy.hover("c");
    policy.stop();
    expect(pending()).toBe(0);
    policy.hover("d");
    advance(HOVER_DWELL_MS * 2);
    expect(read).toEqual([]);
    expect(policy.remembered).toBe(0);
  });
});
