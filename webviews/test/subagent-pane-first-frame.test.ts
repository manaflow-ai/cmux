// l10n-allow-file: test fixture prompts, replies and titles, not shipped UI.
//
// Leo, 2026-11-05: "it takes EGREGIOUSLY long for me to open up a link/the pane on the right
// opens... there's probably some stupid flow that bottlenecks itself" and "things just don't
// f***ing open up fast enough on the right. / links. subagents. all". A subagent's pane opened
// cold: a new page loaded, mounted, shook hands, connected, then asked the host for the chat's tail
// in a round trip raced against 250 ms, and drew nothing until then (2-3 s under load). Now it
// adopts the prewarmed page, and the adopt event carries the tail the chat handed the host as it
// asked for the pane (AgentPaneView+SessionAdopt.swift). These hold the page's half:
//
//   - the adopt event's tail is read (newtab/adoption.ts `sessionAdoption`);
//   - the page keeps it and draws the chat from it in the event's own turn, before any host or
//     acpmux round trip (`keepAdoptedTail`, then `adoptSession`);
//   - a subagent's pane shows the subagent from its first frame and waits on no reading place of
//     the chat, which it does not show (`adoptionPlan`).
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { adoptionPlan, keepAdoptedTail, sessionAdoption } from "../src/agent-session/acpmux/newtab/adoption";
import { keptTail, resetKeptTailsForTests } from "../src/agent-session/acpmux/tailCache";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

const START = Date.UTC(2026, 10, 5, 9, 0, 0);
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

const summary = (sessionId: string) => ({
  sessionId,
  cwd: "/home/dev/project",
  title: `Chat ${sessionId}`,
  harness: "claude",
  status: "idle",
  turnCount: 1,
  updatedAt: START,
});

const chatEvents = (sessionId: string, text: string) => [
  { sessionId, seq: 1, at: START + 1000, dir: "mux", kind: "user_message", msg: { text: "Audit the retry path." } },
  {
    sessionId,
    seq: 2,
    at: START + 2000,
    dir: "in",
    kind: "agent_message_chunk",
    msg: {
      method: "session/update",
      params: { sessionId, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
    },
  },
];

/// acpmux listing `listed`; an attach of `hold` is never answered (a busy daemon).
class Daemon {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  hold?: string;
  attaches: string[] = [];

  constructor(public listed: string[]) {
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.();
    });
  }

  send(raw: string): void {
    const message = JSON.parse(raw) as Message;
    if (message.id === undefined) return;
    const sessionId = String(message.params?.sessionId ?? "");
    if (message.method === "_acpmux/attach") this.attaches.push(sessionId);
    if (message.method === "_acpmux/attach" && sessionId === this.hold) return;
    queueMicrotask(() => this.answer(message));
  }

  close(): void {
    this.readyState = 3;
  }

  private answer(message: Message): void {
    const sessionId = String(message.params?.sessionId ?? "");
    let result: unknown = {};
    if (message.method === "initialize")
      result = { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    else if (message.method === "_acpmux/watch") result = { sessions: this.listed.map(summary) };
    else if (message.method === "_acpmux/attach") {
      const events = chatEvents(sessionId, `Reply of ${sessionId}.`);
      result = { session: summary(sessionId), lastSeq: events.length, events, hasMore: false };
    } else if (message.method === "_acpmux/events") result = { events: [], hasMore: false, lastSeq: 0 };
    this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) });
  }
}

const text = (snapshot: AcpmuxSnapshot | undefined) =>
  (snapshot?.rows ?? [])
    .map((row) => JSON.stringify(row))
    .join(" ")
    .replace(/\s+/g, " ");

let live: AcpmuxDirectClient[] = [];
afterEach(() => {
  for (const client of live) client.close();
  live = [];
  delete (dom.window as unknown as { cmuxAcpmuxActions?: unknown }).cmuxAcpmuxActions;
  resetKeptTailsForTests();
});

/// The prewarmed New Tab page's client: a new chat page, with no session (the spare's handshake).
async function spare(daemon: Daemon) {
  const drawn: AcpmuxSnapshot[] = [];
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://spare.invalid/",
      token: "t",
      newSession: true,
    },
    (snapshot) => {
      if (snapshot.type === "snapshot") drawn.push(snapshot);
    },
    undefined,
    () => daemon as unknown as WebSocket,
  );
  live.push(client);
  return { client, drawn, last: () => drawn.at(-1) };
}

const handed = (chat: string) => ({
  events: chatEvents(chat, "The retry path holds its lock."),
  summary: summary(chat),
  historyExhausted: true,
  queue: [],
  configSeq: 0,
  usageFromSeq: 0,
});

test("an adopt event carries the chat's kept tail, and only an object counts as one", () => {
  const tail = handed("s-1");
  expect(sessionAdoption({ sessionId: "s-1", revealTurn: "subagent:a", tail })).toEqual({
    sessionId: "s-1",
    revealTurn: "subagent:a",
    tail,
  });
  for (const value of [undefined, null, "tail", 4, true])
    expect(sessionAdoption({ sessionId: "s-1", tail: value })).toEqual({ sessionId: "s-1" });
});

test("a subagent's pane reveals the subagent first and reads no reading place of the chat", () => {
  expect(adoptionPlan({ sessionId: "s-1", revealTurn: "subagent:a" })).toEqual({
    readsAnchor: false,
    revealsFirst: true,
  });
  // A chat opened in a tab (any other adoption) reads where its reader left it, then shows its turn.
  expect(adoptionPlan({ sessionId: "s-1" })).toEqual({ readsAnchor: true, revealsFirst: false });
  expect(adoptionPlan({ sessionId: "s-1", revealTurn: "turn-4" })).toEqual({ readsAnchor: true, revealsFirst: false });
});

test("the adopted page draws the tail its adopt event carries in that event's own turn", async () => {
  const chat = "subagent-chat";
  const asked: string[] = [];
  (
    dom.window as unknown as { cmuxAcpmuxActions: Record<string, (params: any) => Promise<unknown>> }
  ).cmuxAcpmuxActions = {
    "chat.tail.get": async (params: any) => {
      asked.push(String(params.sessionId));
      return null;
    },
    "chat.tail": async () => null,
  };
  const daemon = new Daemon([chat, "other"]);
  const page = await spare(daemon);
  expect(page.last()?.sessionId).toBeUndefined();
  daemon.hold = chat;

  // The adopt event's handler, as App.tsx runs it: keep the tail, then switch, with no await between.
  const adoption = sessionAdoption({ sessionId: chat, revealTurn: "subagent:a", tail: handed(chat) })!;
  expect(keepAdoptedTail(adoption)).toBe(true);
  void page.client.adoptSession(chat);
  // Same turn: no microtask has run, so neither the host nor acpmux answered anything.
  expect(page.last()?.sessionId).toBe(chat);
  expect(page.last()?.chatRead).toBe(true);
  expect(page.last()?.drewKeptTail).toBe(true);
  expect(text(page.last())).toContain("The retry path holds its lock.");
  expect(asked).toEqual([]);
});

test("a page that read the chat itself keeps its own, newer tail over the one an adopt event carries", () => {
  const chat = "read-here";
  expect(keepAdoptedTail({ sessionId: chat, tail: handed(chat) })).toBe(true);
  const first = keptTail(chat);
  const older = { ...handed(chat), events: chatEvents(chat, "Older.").slice(0, 1) };
  expect(keepAdoptedTail({ sessionId: chat, tail: older })).toBe(false);
  expect(keptTail(chat)).toBe(first);
  // No tail, or one with no records, keeps nothing.
  expect(keepAdoptedTail({ sessionId: "none" })).toBe(false);
  expect(keepAdoptedTail({ sessionId: "empty", tail: { events: [] } })).toBe(false);
  expect(keptTail("empty")).toBeUndefined();
});
