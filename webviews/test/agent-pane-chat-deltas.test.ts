// l10n-allow-file: test fixture replies, not shipped UI.
//
// The chat pane asks acpmux for compact chunks and row patches (direct.ts `initializeParams`,
// chatDeltas.ts) and draws from them what it drew from the whole frames: a streamed reply in
// order, nothing lost or doubled. A compact frame it cannot rebuild reads again what it stood for:
// a chunk of a ref it never had reads the chat's records after its newest, a patch of a row it
// does not hold reads the list again (after either, acpmux sends the next one whole).
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient, initializeParams } from "../src/agent-session/acpmux/direct";
import { resetKeptTailsForTests } from "../src/agent-session/acpmux/tailCache";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { settleReact } from "./support/domTeardown";

const START = Date.UTC(2026, 10, 22, 14, 0, 0);
const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = { window: scope.window, document: scope.document, had: "window" in scope };

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});

afterAll(async () => {
  await settleReact();
  if (saved.had) Object.assign(scope, { window: saved.window, document: saved.document });
  else {
    delete scope.window;
    delete scope.document;
  }
});

const SESSION = "local-chat";

type Message = { id?: number; method: string; params?: Record<string, unknown> };

const reply = (seq: number, text: string) => ({
  sessionId: SESSION,
  seq,
  at: START + seq * 1000,
  dir: "in",
  kind: "agent_message_chunk",
  msg: {
    method: "session/update",
    params: { sessionId: SESSION, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  },
});
const prompt = (seq: number) => ({
  sessionId: SESSION,
  seq,
  at: START + seq * 1000,
  dir: "mux",
  kind: "user_message",
  msg: { method: "_acpmux/user_message", params: { sessionId: SESSION, text: `question ${seq}` } },
});
const LOG = [prompt(1), reply(2, "first answer. ")];

const summary = () => ({
  sessionId: SESSION,
  name: "lane",
  cwd: "/home/dev/project",
  title: "Lane",
  harness: "claude",
  status: "running",
  turnCount: 1,
  updatedAt: START,
  createdAt: 100,
});

/// This machine's acpmux, as it answers a page that asked for both compact forms.
class Daemon {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: ((event?: { code: number }) => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  log = LOG.slice();
  readonly asked: Message[] = [];

  constructor() {
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.();
    });
  }

  notify(method: string, params: Record<string, unknown>): void {
    this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method, params }) });
  }

  send(raw: string): void {
    const message = JSON.parse(raw) as Message;
    if (message.id === undefined) return;
    this.asked.push(message);
    queueMicrotask(() => this.answer(message));
  }

  close(): void {
    this.readyState = 3;
  }

  private answer(message: Message): void {
    const p = message.params ?? {};
    const result = (body: unknown) =>
      this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result: body }) });
    const last = this.log.at(-1)?.seq ?? 0;
    if (message.method === "initialize")
      return result({ protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } });
    if (message.method === "_acpmux/watch") return result({ sessions: [summary()] });
    if (message.method === "_acpmux/attach")
      return result({ session: summary(), events: this.log, hasMore: false, lastSeq: last });
    if (message.method === "_acpmux/events" && p.beforeSeq === undefined) {
      const events = this.log.filter((event) => event.seq > Number(p.afterSeq ?? 0));
      return result({ events, hasMore: false, lastSeq: last });
    }
    result({});
  }
}

const flush = async (passes = 30) => {
  for (let pass = 0; pass < passes; pass += 1) await new Promise((resolve) => setTimeout(resolve, 0));
};

let live: AcpmuxDirectClient[] = [];
afterEach(() => {
  for (const client of live) client.close();
  live = [];
  resetKeptTailsForTests();
});

async function openChat() {
  resetKeptTailsForTests();
  const daemons: Daemon[] = [];
  const drawn: AcpmuxSnapshot[] = [];
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://acpmux.invalid/",
      token: "t",
      sessionId: SESSION,
      sessionMustExist: true,
    },
    (snapshot) => {
      if (snapshot.type === "snapshot") drawn.push(snapshot);
    },
    undefined,
    () => {
      const daemon = new Daemon();
      daemons.push(daemon);
      return daemon as unknown as WebSocket;
    },
  );
  live.push(client);
  await flush();
  expect(JSON.stringify(drawn.at(-1)?.rows)).toContain("first answer. ");
  const daemon = () => daemons.at(-1)!;
  const askedAfter = (from: number, method: string) =>
    daemon()
      .asked.slice(from)
      .filter((message) => message.method === method && message.params?.beforeSeq === undefined);
  return { drawn, daemon, askedAfter };
}

test("the page asks for compact chunks and row patches", () => {
  expect(initializeParams()._meta).toEqual({
    acpmux: { peerRowBatches: true, chunkDeltas: true, sessionChangedDelta: true },
  });
});

test("a reply streamed as compact chunks draws as the whole events drew it, in order", async () => {
  const chat = await openChat();
  const asked = chat.daemon().asked.length;
  const words = ["alpha ", "beta ", "gamma ", "delta "];
  const events = words.map((text, i) => reply(3 + i, text));
  chat.daemon().log.push(...events);
  chat.daemon().notify("_acpmux/event", { ...events[0]!, chunkRef: 1 });
  for (const event of events.slice(1))
    chat
      .daemon()
      .notify("_acpmux/chunk", { ref: 1, seq: event.seq, dt: 1000, text: event.msg.params.update.content.text });
  await flush();
  const shown = JSON.stringify(chat.drawn.at(-1)!.rows);
  expect(shown).toContain("alpha beta gamma delta ");
  expect(shown.split("alpha").length - 1).toBe(1);
  // Nothing was missed: no read of the records again.
  expect(chat.askedAfter(asked, "_acpmux/events")).toEqual([]);
});

test("a chunk of a ref the page never had reads the chat's records after its newest", async () => {
  const chat = await openChat();
  const asked = chat.daemon().asked.length;
  chat.daemon().log.push(reply(3, "missed "), reply(4, "after "));
  chat.daemon().notify("_acpmux/chunk", { ref: 41, seq: 3, dt: 1000, text: "missed " });
  chat.daemon().notify("_acpmux/chunk", { ref: 41, seq: 4, dt: 1000, text: "after " });
  await flush();
  expect(chat.askedAfter(asked, "_acpmux/events").map((message) => message.params?.afterSeq)).toEqual([2]);
  expect(JSON.stringify(chat.drawn.at(-1)!.rows)).toContain("missed after ");
});

test("a patch of a row the page does not hold reads the list again, once", async () => {
  const chat = await openChat();
  const asked = chat.daemon().asked.length;
  const patch = (rowSeq: number) => ({
    sessionId: SESSION,
    kind: "status",
    patch: { status: "idle" },
    rowSeq,
    baseRowSeq: rowSeq - 1,
  });
  chat.daemon().notify("_acpmux/session_patch", patch(5));
  chat.daemon().notify("_acpmux/session_patch", patch(6));
  await flush();
  expect(chat.askedAfter(asked, "_acpmux/watch").length).toBe(1);
});

test("a whole row then its patch reach the pane as the row the patch makes", async () => {
  const chat = await openChat();
  const asked = chat.daemon().asked.length;
  chat
    .daemon()
    .notify("_acpmux/session_changed", { sessionId: SESSION, kind: "status", session: summary(), rowSeq: 1 });
  chat.daemon().notify("_acpmux/session_patch", {
    sessionId: SESSION,
    kind: "status",
    patch: { title: "Renamed lane" },
    rowSeq: 2,
    baseRowSeq: 1,
  });
  await flush();
  expect(chat.askedAfter(asked, "_acpmux/watch")).toEqual([]);
  expect(JSON.stringify(chat.drawn.at(-1))).toContain("Renamed lane");
});
