// l10n-allow-file: test fixture prompts, replies and titles, not shipped UI.
//
// Leo, 2026-10-29: "I clicked into your subagent and it's just like, okay, there's nothing there.
// It's just a blank. Well, it loaded after a while." A sub-session's chat (or a message's sender)
// opens in a tab of its own (`chat.offer.open`), which is a new page holding no tails. It drew from
// the app host's tail only when some tab had read that chat already, which a sub-session nobody
// opened never was, so the new tab stayed blank until its own attach of the whole chat answered.
//
// The pane that opens it now warms the host first (direct.ts `handOverForOpen`): the chat's tail
// when this page has one, else its newest page read now and handed over when it lands. These hold
// that:
//
//   - a sub-session no tab ever read draws in its new tab before that tab's attach answers;
//   - without the hand-over the same tab is blank until the attach (the bug, measured against);
//   - a chat this page read ahead is handed over at once, with no second read;
//   - the open actions in App.tsx hand over before `chat.offer.open` / `chat.subagentPane`.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { resetKeptTailsForTests } from "../src/agent-session/acpmux/tailCache";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

const START = Date.UTC(2026, 9, 29, 9, 0, 0);
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
type Step = [dir: string, kind: string, msg: Record<string, unknown>];

const PARENT = "0190a000-0000-7000-8000-00000000aaaa";
const CHILD = "0190a000-0000-7000-8000-00000000bbbb";

const records = (sessionId: string, steps: Step[]) =>
  steps.map(([dir, kind, msg], at) => ({ sessionId, seq: at + 1, at: START + (at + 1) * 1000, dir, kind, msg }));
const prompt = (text: string): Step => ["mux", "user_message", { text }];
const reply = (sessionId: string, text: string): Step => [
  "in",
  "agent_message_chunk",
  {
    method: "session/update",
    params: { sessionId, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  },
];

const transcripts = new Map<string, Step[]>([
  [PARENT, [prompt("Review the PR"), reply(PARENT, "Started codex-review.")]],
  [CHILD, [prompt("Review #27500 at its head"), reply(CHILD, "Codex review: SHIP.")]],
]);

/// acpmux listing the parent chat and the sub-session it started. `hold` keeps that chat's attach
/// unanswered, which is the window a new tab is blank in; `reads` counts `_acpmux/events` pages.
class Daemon {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  hold?: string;
  reads = 0;
  private held?: Message;
  private holding?: () => void;
  asked = new Promise<void>((resolve) => (this.holding = resolve));

  constructor() {
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.();
    });
  }

  send(raw: string): void {
    const message = JSON.parse(raw) as Message;
    if (message.id === undefined) return;
    if (message.method === "_acpmux/attach" && message.params?.sessionId === this.hold) {
      this.held = message;
      this.hold = undefined;
      this.holding?.();
      return;
    }
    queueMicrotask(() => this.answer(message));
  }

  close(): void {
    this.readyState = 3;
  }

  release(): void {
    const message = this.held;
    this.held = undefined;
    if (message) this.answer(message);
  }

  private summary(sessionId: string) {
    return {
      sessionId,
      cwd: "/home/dev/project",
      title: sessionId === CHILD ? "codex-review" : "Main chat",
      harness: "claude",
      status: "idle",
      turnCount: 1,
      updatedAt: START,
      createdAt: START,
      ...(sessionId === CHILD ? { startedBy: PARENT } : {}),
    };
  }

  private answer(message: Message): void {
    const sessionId = String(message.params?.sessionId ?? "");
    const events = records(sessionId, transcripts.get(sessionId) ?? []);
    let result: unknown = {};
    if (message.method === "initialize")
      result = { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    else if (message.method === "_acpmux/watch") result = { sessions: [this.summary(PARENT), this.summary(CHILD)] };
    else if (message.method === "_acpmux/attach")
      result = { session: this.summary(sessionId), lastSeq: events.at(-1)?.seq ?? 0, events, hasMore: false };
    else if (message.method === "_acpmux/events") {
      this.reads += 1;
      result = { events, hasMore: false, lastSeq: events.at(-1)?.seq ?? 0 };
    }
    this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) });
  }
}

/// The app host's in-memory tail store (AgentPaneTailCache.swift), which outlives every page.
class Host {
  readonly tails = new Map<string, any>();
  install(): void {
    (
      dom.window as unknown as { cmuxAcpmuxActions: Record<string, (params: any) => Promise<unknown>> }
    ).cmuxAcpmuxActions = {
      "chat.tail.get": async (params: any) => this.tails.get(String(params.sessionId)) ?? null,
      "chat.tail": async (params: any) => {
        const sessionId = String(params.sessionId);
        if (Array.isArray(params.tail?.events) && params.tail.events.length > 0) this.tails.set(sessionId, params.tail);
        else this.tails.delete(sessionId);
        return null;
      },
    };
  }
}

const flush = async () => {
  for (let pass = 0; pass < 8; pass += 1) await new Promise((resolve) => setTimeout(resolve, 0));
};

const text = (snapshot: AcpmuxSnapshot | undefined) =>
  (snapshot?.rows ?? []).map((row) => JSON.stringify(row)).join(" ");

let live: AcpmuxDirectClient[] = [];
afterEach(() => {
  for (const client of live) client.close();
  live = [];
  delete (dom.window as unknown as { cmuxAcpmuxActions?: unknown }).cmuxAcpmuxActions;
  resetKeptTailsForTests();
});

/// A page of the pane on `sessionId`: its own daemon (one client per socket) and its snapshots.
/// A new tab is a new page, so it starts with no tails of its own.
function tab(sessionId: string, options: { hold?: boolean; newPage?: boolean } = {}) {
  if (options.newPage) resetKeptTailsForTests();
  const daemon = new Daemon();
  if (options.hold) daemon.hold = sessionId;
  const drawn: AcpmuxSnapshot[] = [];
  const client = AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://sub.invalid/", token: "t", sessionId },
    (snapshot) => {
      if (snapshot.type === "snapshot") drawn.push(snapshot);
    },
    undefined,
    () => daemon as unknown as WebSocket,
  );
  return { daemon, drawn, client, last: () => drawn.at(-1) };
}

test("a sub-session no tab read draws in its new tab before that tab's attach answers", async () => {
  const host = new Host();
  host.install();
  const parent = tab(PARENT);
  const client = await parent.client;
  live.push(client);
  await flush();
  // Nobody read the sub-session: the host holds nothing for it.
  expect(host.tails.has(CHILD)).toBe(false);

  // The press on its card or strip row (App.tsx `openOfferChat`).
  client.handOverForOpen(CHILD);
  await flush();
  expect(host.tails.has(CHILD)).toBe(true);
  expect(parent.daemon.reads).toBe(1);

  // Its new tab, with acpmux slow to answer the attach of a long chat.
  const opened = tab(CHILD, { hold: true, newPage: true });
  await opened.daemon.asked;
  expect(text(opened.last())).toContain("Codex review: SHIP.");
  expect(opened.last()!.sessionId).toBe(CHILD);
  expect(opened.last()!.drewKeptTail).toBe(true);
  opened.daemon.release();
  live.push(await opened.client);
  expect(text(opened.last())).toContain("Codex review: SHIP.");
});

test("without the hand-over the sub-session's new tab is blank until its attach answers", async () => {
  const host = new Host();
  host.install();
  const parent = tab(PARENT);
  live.push(await parent.client);
  await flush();

  const opened = tab(CHILD, { hold: true, newPage: true });
  await opened.daemon.asked;
  // The blank pane Leo saw: nothing to draw while the attach is out.
  expect(text(opened.last())).not.toContain("Codex review: SHIP.");
  opened.daemon.release();
  live.push(await opened.client);
  expect(text(opened.last())).toContain("Codex review: SHIP.");
});

test("a chat this page already read ahead is handed over at once, with no second read", async () => {
  const host = new Host();
  host.install();
  const parent = tab(PARENT);
  const client = await parent.client;
  live.push(client);
  await flush();
  client.prefetch(CHILD);
  await flush();
  const reads = parent.daemon.reads;
  expect(reads).toBe(1);
  // Read ahead is the page's own: the host keeps what a page opens, not what it guessed at.
  expect(host.tails.has(CHILD)).toBe(false);

  client.handOverForOpen(CHILD);
  await flush();
  expect(host.tails.has(CHILD)).toBe(true);
  expect(parent.daemon.reads).toBe(reads);
});

test("handing over the chat on screen is its own tail, with no read", async () => {
  const host = new Host();
  host.install();
  const parent = tab(PARENT);
  const client = await parent.client;
  live.push(client);
  await flush();
  client.handOverForOpen(PARENT);
  await flush();
  expect(host.tails.has(PARENT)).toBe(true);
  expect(parent.daemon.reads).toBe(0);
});

/// The calls live in App.tsx's React code, which no test here drives: take one away and every test
/// above stays green while the new tab goes blank again. So the call sites are read from the source.
test("the actions that open a sub-session or subagent in another tab hand it over first", async () => {
  const app = await readFile(new URL("../src/agent-session/acpmux/App.tsx", import.meta.url), "utf8");
  const offers = [...app.matchAll(/callNative\("chat\.offer\.open"/g)];
  expect(offers.length).toBe(2);
  for (const site of offers) {
    const before = app.slice(Math.max(0, site.index - 200), site.index);
    expect(before.includes("handOverForOpen(sessionId)"), `chat.offer.open at ${site.index} opens cold`).toBe(true);
  }
  const panes = [...app.matchAll(/openSubagentPane\(callNative/g)];
  expect(panes.length).toBe(1);
  for (const site of panes) {
    const before = app.slice(Math.max(0, site.index - 300), site.index);
    expect(before.includes("handOverCurrentTail()"), "chat.subagentPane opens cold").toBe(true);
  }
});
