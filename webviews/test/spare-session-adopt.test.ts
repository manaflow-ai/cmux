// l10n-allow-file: test fixture prompts, replies and titles, not shipped UI.
//
// Leo 2026-10-29: "i also like the way it just loads in the subagent stuff instantly :(" / "as in i
// want ours to load fast too :(". A tab opening an existing chat (a sidebar click, Open in Tab, a
// subagent's pane) now adopts the app's prewarmed New Tab page, which is loaded and connected
// already (AgentPaneView+SessionAdopt.swift). The page switches to the chat in place. These hold it:
//
//   - the adopt event's detail is read defensively (newtab/adoption.ts `sessionAdoption`);
//   - the New Tab page's client, bound to the chat, draws the chat the host kept before its attach
//     answers, and reports it read for that chat (the page's first paint, App.tsx `adoptionDrawn`);
//   - bound, it is that tab's page: a chat the daemon drops is called missing, never replaced by
//     another chat, as a page whose handshake named the session (`sessionMustExist`);
//   - a chat the page's list lacks opens on its attach, without waiting for the list to be read
//     again (a busy acpmux paces its whole list for seconds);
//   - a chat the daemon neither attaches nor lists when the page adopts it is the tab's missing chat
//     (the pane says why, chatUnavailable.ts), never an empty chat.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { sessionAdoption } from "../src/agent-session/acpmux/newtab/adoption";
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
  { sessionId, seq: 1, at: START + 1000, dir: "mux", kind: "user_message", msg: { text: "Where is the retry?" } },
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

/// acpmux listing `listed`; an attach is held until `release` when `hold` names it.
class Daemon {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  hold?: string;
  /// Lists asked while set are never answered: a list acpmux is still pacing.
  holdLists = false;
  attaches: string[] = [];
  private held?: Message;
  private holding?: () => void;
  asked = new Promise<void>((resolve) => (this.holding = resolve));

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
    if (message.method === "_acpmux/watch" && this.holdLists) return;
    if (message.method === "_acpmux/attach" && sessionId === this.hold) {
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

  private answer(message: Message): void {
    const sessionId = String(message.params?.sessionId ?? "");
    let result: unknown = {};
    if (message.method === "initialize")
      result = { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    else if (message.method === "_acpmux/watch") result = { sessions: this.listed.map(summary) };
    else if (message.method === "_acpmux/attach" && !this.listed.includes(sessionId)) {
      // acpmux refuses an attach of a chat it lacks.
      this.onmessage?.({
        data: JSON.stringify({ jsonrpc: "2.0", id: message.id, error: { code: -32602, message: "unknown session" } }),
      });
      return;
    } else if (message.method === "_acpmux/attach") {
      const events = chatEvents(sessionId, `Reply of ${sessionId}.`);
      result = { session: summary(sessionId), lastSeq: events.length, events, hasMore: false };
    } else if (message.method === "_acpmux/events") result = { events: [], hasMore: false, lastSeq: 0 };
    this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) });
  }

  /// acpmux's watch: it dropped chat `sessionId` (closed on another device).
  purge(sessionId: string): void {
    this.listed = this.listed.filter((id) => id !== sessionId);
    this.onmessage?.({
      data: JSON.stringify({
        jsonrpc: "2.0",
        method: "_acpmux/session_changed",
        params: { kind: "purged", session: { sessionId } },
      }),
    });
  }
}

const flush = async () => {
  for (let pass = 0; pass < 8; pass += 1) await new Promise((resolve) => setTimeout(resolve, 0));
};

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

test("an adopt event names its chat and its turn, and anything else names none", () => {
  expect(sessionAdoption({ sessionId: "s-1" })).toEqual({ sessionId: "s-1" });
  expect(sessionAdoption({ sessionId: "s-1", revealTurn: "subagent:a" })).toEqual({
    sessionId: "s-1",
    revealTurn: "subagent:a",
  });
  expect(sessionAdoption({ sessionId: "s-1", revealTurn: 4 })).toEqual({ sessionId: "s-1" });
  for (const detail of [undefined, null, "s-1", {}, { sessionId: "" }, { sessionId: 7 }])
    expect(sessionAdoption(detail)).toBeUndefined();
});

test("the adopted New Tab page draws the chat the host kept before its attach answers", async () => {
  const chat = "adopt-kept";
  const kept = {
    events: chatEvents(chat, "Retry added in the kept tail."),
    lastSeq: 2,
    historyExhausted: true,
    summary: summary(chat),
  };
  (
    dom.window as unknown as { cmuxAcpmuxActions: Record<string, (params: any) => Promise<unknown>> }
  ).cmuxAcpmuxActions = {
    "chat.tail.get": async (params: any) => (String(params.sessionId) === chat ? kept : null),
    "chat.tail": async () => null,
  };
  const daemon = new Daemon([chat, "other"]);
  const page = await spare(daemon);
  // The spare is a New Tab page: it opened no chat.
  expect(page.last()?.sessionId).toBeUndefined();
  expect(daemon.attaches).toEqual([]);

  daemon.hold = chat;
  page.client.bindToSession(chat);
  const selected = page.client.select(chat);
  await daemon.asked;
  // Drawn from the host's tail, with the attach still out: read for this chat, so the page reports it.
  expect(page.last()?.sessionId).toBe(chat);
  expect(page.last()?.chatRead).toBe(true);
  expect(page.last()?.drewKeptTail).toBe(true);
  expect(text(page.last())).toContain("Retry added in the kept tail.");
  daemon.release();
  expect(await selected).toBe(chat);
  expect(daemon.attaches).toEqual([chat]);
});

test("bound to its chat, the adopted page never falls back to another one", async () => {
  const chat = "adopt-bound";
  const daemon = new Daemon([chat, "newest"]);
  const page = await spare(daemon);
  page.client.bindToSession(chat);
  expect(await page.client.select(chat)).toBe(chat);
  expect(page.last()?.sessionId).toBe(chat);

  // The chat goes away while shown (closed on another device).
  daemon.purge(chat);
  await flush();
  expect(page.last()?.sessionId).toBeUndefined();
  expect(daemon.attaches).not.toContain("newest");
});

test("a chat the daemon does not list is the adopted tab's missing chat, never an empty one", async () => {
  const chat = "adopt-gone";
  const daemon = new Daemon(["newest"]);
  const page = await spare(daemon);
  expect(await page.client.adoptSession(chat)).toBeUndefined();
  await flush();
  expect(page.last()?.sessionId).toBeUndefined();
  expect(page.last()?.missingSession).toBe(chat);
  expect(page.last()?.missingReason).toBe("notListedAtOpen");
  expect(daemon.attaches).toEqual([chat]);
});

test("a chat the page's list lacks opens on its attach, without waiting for the list", async () => {
  const chat = "adopt-later";
  const daemon = new Daemon(["newest"]);
  const page = await spare(daemon);
  // The chat started after the page read its list, and acpmux is slow to list again.
  daemon.listed.push(chat);
  daemon.holdLists = true;
  expect(await page.client.adoptSession(chat)).toBe(chat);
  expect(page.last()?.sessionId).toBe(chat);
  expect(page.last()?.missingSession).toBeUndefined();
  expect(daemon.attaches).toEqual([chat]);
});

test("a listed chat the page adopts opens as a pick opens it", async () => {
  const chat = "adopt-listed";
  const daemon = new Daemon([chat, "newest"]);
  const page = await spare(daemon);
  expect(await page.client.adoptSession(chat)).toBe(chat);
  expect(page.last()?.sessionId).toBe(chat);
  expect(page.last()?.missingSession).toBeUndefined();
  expect(daemon.attaches).toEqual([chat]);
});
