// l10n-allow-file: test fixture prompts and replies, not shipped UI.
//
// A daemon restart (a hot-apply, `acpmux --take-over` at a NIGHTLY install) is a reconnect the
// reader should not see (Leo, 2026-11-22, ask-293a8f57e0: "no shift, no anything, just... ok now it
// changed"; ask-ea62b204f6: "a graceful if not imperceptible state transition all around ...
// likewise with daemon stuff"). A permission ask still waiting on the chat is part of what the
// reader sees: its card must not blink out while the pane reconnects and come back when the attach
// lists it again (`session.pending`).
//
// The test runs the pane's own lost path (as agent-pane-reconnect-no-flip.test.ts does): the socket
// closes, `onLost` connects a new client on the same page, and every frame of every client is read.
// It fails if any frame of the chat, after the card first showed, shows no permission ask.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { settleReact } from "./support/domTeardown";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient, type CarriedChat } from "../src/agent-session/acpmux/direct";
import { resetKeptTailsForTests } from "../src/agent-session/acpmux/tailCache";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

const START = Date.UTC(2026, 10, 22, 15, 0, 0);
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

type Message = { id?: number; method: string; params?: Record<string, unknown> };

const CHAT = "0190a000-0000-7000-8000-0000000000f1";

const ASK = {
  permissionId: "p1",
  request: {
    toolCall: { toolCallId: "t1", title: "Run npm test", kind: "execute", rawInput: { command: "npm test" } },
    options: [
      { optionId: "allow", name: "Allow", kind: "allow_once" },
      { optionId: "deny", name: "Deny", kind: "reject_once" },
    ],
  },
};

const STEPS: [string, string, Record<string, unknown>][] = [
  ["mux", "user_message", { text: "Run the tests" }],
  ["mux", "turn_started", {}],
  ["mux", "permission_request", ASK],
];

const records = () =>
  STEPS.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: index + 1,
    at: START + (index + 1) * 1000,
    dir,
    kind,
    msg,
  }));

const summary = (pending: boolean) => ({
  sessionId: CHAT,
  cwd: "/home/dev/project",
  title: "Run the tests",
  harness: "claude",
  family: "claude",
  status: "running",
  turnCount: 1,
  updatedAt: START,
  createdAt: START,
  ...(pending ? { pending: [ASK] } : {}),
});

/// acpmux for one connection of the pane: the ask is still waiting on every attach. `slowAttach`
/// answers the attach only once released, as a daemon that is still starting does.
class Daemon {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  private held: Message[] = [];
  holding = false;

  constructor() {
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.();
    });
  }

  send(raw: string): void {
    const message = JSON.parse(raw) as Message;
    if (message.id === undefined) return;
    if (this.holding && message.method === "_acpmux/attach") this.held.push(message);
    else queueMicrotask(() => this.answer(message));
  }

  release(): void {
    this.holding = false;
    for (const message of this.held.splice(0)) this.answer(message);
  }

  close(): void {
    this.readyState = 3;
  }

  drop(): void {
    this.readyState = 3;
    this.onclose?.();
  }

  private answer(message: Message): void {
    let result: unknown = {};
    if (message.method === "initialize")
      result = { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    else if (message.method === "_acpmux/watch") result = { sessions: [summary(false)] };
    else if (message.method === "_acpmux/attach")
      result = { session: summary(true), lastSeq: STEPS.length, events: records(), hasMore: false };
    else if (message.method === "_acpmux/events") result = { events: [], hasMore: false, lastSeq: STEPS.length };
    else result = null;
    this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) });
  }
}

function installHost(): void {
  const tails = new Map<string, unknown>();
  (
    dom.window as unknown as { cmuxAcpmuxActions: Record<string, (params: any) => Promise<unknown>> }
  ).cmuxAcpmuxActions = {
    "chat.tail.get": async (params: any) => tails.get(String(params.sessionId)) ?? null,
    "chat.tail": async (params: any) => {
      if (params.tail) tails.set(String(params.sessionId), params.tail);
      else tails.delete(String(params.sessionId));
      return null;
    },
  };
}

const flush = async () => {
  for (let pass = 0; pass < 12; pass += 1) await new Promise((resolve) => setTimeout(resolve, 0));
};

let clients: AcpmuxDirectClient[] = [];
afterEach(() => {
  for (const client of clients) client.close();
  clients = [];
  delete (dom.window as unknown as { cmuxAcpmuxActions?: unknown }).cmuxAcpmuxActions;
  resetKeptTailsForTests();
});

for (const slow of [false, true]) {
  test(`a waiting permission ask stays on screen across reconnects (${slow ? "slow" : "quick"} daemon)`, async () => {
    resetKeptTailsForTests();
    installHost();
    let seen = false;
    const blinks: string[] = [];
    let frame = 0;
    let daemon!: Daemon;
    let reconnected!: Promise<AcpmuxDirectClient>;
    const listener = (snapshot: AcpmuxSnapshot) => {
      if (snapshot.type !== "snapshot" || snapshot.sessionId !== CHAT) return;
      frame += 1;
      if (snapshot.permission) seen = true;
      else if (seen) blinks.push(`frame ${frame}: no permission ask (connection ${snapshot.connection ?? "?"})`);
      // Nor does the transcript go: a frame with fewer rows than the chat holds is a blank or a shift.
      if (seen && (snapshot.rows?.length ?? 0) < 2) blinks.push(`frame ${frame}: ${snapshot.rows?.length ?? 0} rows`);
    };
    // The pane's lost path (App.tsx `onLost`): the lost client hands what it held (`takeCarried`) to
    // the new one, which connects on this page.
    let current: AcpmuxDirectClient | undefined;
    const connect = (carried?: CarriedChat): Promise<AcpmuxDirectClient> => {
      daemon = new Daemon();
      daemon.holding = slow && clients.length > 0;
      const opened = AcpmuxDirectClient.connect(
        {
          protocolVersion: 1,
          transport: "acpmux-websocket",
          endpoint: "ws://perm.invalid/",
          token: "t",
          sessionId: CHAT,
        },
        listener,
        () => {
          reconnected = connect(current?.takeCarried());
        },
        () => daemon as unknown as WebSocket,
        undefined,
        undefined,
        carried,
      );
      void opened.then((client) => {
        clients.push(client);
        current = client;
      });
      return opened;
    };

    await connect();
    await flush();
    expect(seen).toBe(true);

    for (let drop = 1; drop <= 5; drop += 1) {
      daemon.drop();
      const next = reconnected;
      if (slow) {
        // The new daemon takes longer than the open's hold (direct.ts OPEN_HOLD_MS) to answer.
        await new Promise((resolve) => setTimeout(resolve, 1800)); // fixed-wait: a daemon slower than the 1.5 s open hold is the subject.
        daemon.release();
      }
      await next;
      await flush();
    }
    expect(blinks).toEqual([]);
  }, 30_000);
}

test("a waiting permission ask stays on screen when the client reconnects by itself", async () => {
  resetKeptTailsForTests();
  installHost();
  let seen = false;
  const blinks: string[] = [];
  let frame = 0;
  const daemons: Daemon[] = [];
  const listener = (snapshot: AcpmuxSnapshot) => {
    if (snapshot.type !== "snapshot" || snapshot.sessionId !== CHAT) return;
    frame += 1;
    if (snapshot.permission) seen = true;
    else if (seen) blinks.push(`frame ${frame}: no permission ask (connection ${snapshot.connection})`);
  };
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://perm.invalid/", token: "t", sessionId: CHAT },
    listener,
    undefined,
    () => {
      const daemon = new Daemon();
      daemons.push(daemon);
      return daemon as unknown as WebSocket;
    },
  );
  clients.push(client);
  await flush();
  expect(seen).toBe(true);
  for (let drop = 1; drop <= 3; drop += 1) {
    const before = daemons.length;
    daemons.at(-1)!.drop();
    // The client's own backoff picks the moment: wait until it opened its next connection.
    while (daemons.length === before) await new Promise((resolve) => setTimeout(resolve, 0));
    await flush();
  }
  expect(daemons.length).toBeGreaterThan(1);
  expect(blinks).toEqual([]);
}, 30_000);
