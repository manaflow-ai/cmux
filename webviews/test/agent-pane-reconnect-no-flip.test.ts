// l10n-allow-file: test fixture prompts and replies, not shipped UI.
//
// A chat never goes back to an older copy of itself when its connection comes back (Leo,
// 2026-11-12, of his recording: the chat flipped between the live chat, "49 stopped", and an old
// saved copy, "32 stopped", every time it reconnected). One source wins: what this page has shown
// of a chat is never replaced by an older copy of it.
//
// The flip came from two copies of one tail. A page keeps the tail of a chat in its own map when
// the reader leaves the chat, and the app host keeps one too. A client whose connection is lost
// closes, and the pane makes a new client (App.tsx `onLost`); the closing client handed its newer
// tail to the host only, so the next client drew the page map's copy, kept when the chat was
// last left, while it connected. Its attach then drew the live chat again: old, new, old, new, once
// per dropped connection.
//
// The test runs the pane's own lost path: the socket closes, `onLost` connects a new client on the
// same page, and the chat goes on growing between drops. Every frame of every client is read; the
// test fails if the newest reply on screen ever goes back, even once.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { settleReact } from "./support/domTeardown";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { resetKeptTailsForTests } from "../src/agent-session/acpmux/tailCache";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

const START = Date.UTC(2026, 10, 12, 2, 0, 0);
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

const CHAT = "flip-chat";
const OTHER = "flip-other";

/// Chat `sessionId` after `turns` turns: a prompt and the reply "Reply N." each.
function transcript(sessionId: string, turns: number) {
  const out: Record<string, unknown>[] = [];
  for (let turn = 1; turn <= turns; turn += 1) {
    const seq = out.length + 1;
    out.push({
      sessionId,
      seq,
      at: START + seq * 1000,
      dir: "mux",
      kind: "user_message",
      msg: { text: `Ask ${turn}` },
    });
    out.push({
      sessionId,
      seq: seq + 1,
      at: START + (seq + 1) * 1000,
      dir: "in",
      kind: "agent_message_chunk",
      msg: {
        method: "session/update",
        params: {
          sessionId,
          update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `Reply ${turn}.` } },
        },
      },
    });
  }
  return out;
}

/// acpmux for one connection of the pane: it answers with the chats as `turns` holds them now.
class Daemon {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;

  constructor(readonly turns: Map<string, number>) {
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.();
    });
  }

  send(raw: string): void {
    const message = JSON.parse(raw) as Message;
    if (message.id !== undefined) queueMicrotask(() => this.answer(message));
  }

  close(): void {
    this.readyState = 3;
  }

  /// The connection drops under the pane, as the bridge's socket does.
  drop(): void {
    this.readyState = 3;
    this.onclose?.();
  }

  private summary(sessionId: string) {
    return {
      sessionId,
      cwd: "/home/dev/project",
      title: `Chat ${sessionId}`,
      harness: "claude",
      status: "idle",
      turnCount: this.turns.get(sessionId) ?? 0,
      updatedAt: START,
      createdAt: START,
    };
  }

  private answer(message: Message): void {
    const sessionId = String(message.params?.sessionId ?? "");
    let result: unknown = {};
    if (message.method === "initialize")
      result = { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    else if (message.method === "_acpmux/watch") result = { sessions: [this.summary(CHAT), this.summary(OTHER)] };
    else if (message.method === "_acpmux/attach") {
      const records = transcript(sessionId, this.turns.get(sessionId) ?? 0);
      result = { session: this.summary(sessionId), lastSeq: records.length, events: records, hasMore: false };
    } else if (message.method === "_acpmux/events") {
      const after = Number(message.params?.afterSeq ?? 0);
      const records = transcript(sessionId, this.turns.get(sessionId) ?? 0).filter(
        (event) => Number(event.seq) > after,
      );
      result = { events: records, hasMore: false, lastSeq: records.length };
    }
    this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) });
  }
}

/// The app host's tail store (AgentPaneTailCache): the newest tail each page handed it.
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

/// The newest "Reply N." a frame of `CHAT` shows, or undefined when it shows none.
function newestReply(snapshot: AcpmuxSnapshot): number | undefined {
  if (snapshot.sessionId !== CHAT) return undefined;
  let newest: number | undefined;
  for (const match of JSON.stringify(snapshot.rows ?? []).matchAll(/Reply (\d+)\./g)) {
    const turn = Number(match[1]);
    if (newest === undefined || turn > newest) newest = turn;
  }
  return newest;
}

let clients: AcpmuxDirectClient[] = [];
afterEach(() => {
  for (const client of clients) client.close();
  clients = [];
  delete (dom.window as unknown as { cmuxAcpmuxActions?: unknown }).cmuxAcpmuxActions;
  resetKeptTailsForTests();
});

test("a chat never flips back to an older copy across repeated reconnects", async () => {
  resetKeptTailsForTests();
  installHost();
  const turns = new Map([
    [CHAT, 32],
    [OTHER, 3],
  ]);
  // Every frame of `CHAT` any client of this page drew, in order: the newest reply each showed.
  const shown: number[] = [];
  const flips: string[] = [];
  let daemon!: Daemon;
  let reconnected!: Promise<AcpmuxDirectClient>;
  const listener = (snapshot: AcpmuxSnapshot) => {
    if (snapshot.type !== "snapshot") return;
    const newest = newestReply(snapshot);
    if (newest === undefined) return;
    const most = Math.max(0, ...shown);
    if (newest < most) flips.push(`showed Reply ${newest} after Reply ${most}`);
    shown.push(newest);
  };
  // The pane's lost path (App.tsx): the lost client is closed and a new one connects on this page.
  const connect = (): Promise<AcpmuxDirectClient> => {
    daemon = new Daemon(turns);
    const opened = AcpmuxDirectClient.connect(
      {
        protocolVersion: 1,
        transport: "acpmux-websocket",
        endpoint: "ws://flip.invalid/",
        token: "t",
        sessionId: CHAT,
      },
      listener,
      () => {
        reconnected = connect();
      },
      () => daemon as unknown as WebSocket,
    );
    void opened.then((client) => clients.push(client));
    return opened;
  };

  // The reader reads the chat at 32 replies, looks at another chat and comes back: the page keeps
  // the chat's tail as it was at 32.
  const first = await connect();
  await flush();
  await first.select(OTHER);
  await flush();
  turns.set(CHAT, 49);
  await first.select(CHAT);
  await flush();
  expect(Math.max(...shown)).toBe(49);

  // The connection drops again and again while the chat goes on.
  for (let drop = 1; drop <= 5; drop += 1) {
    daemon.drop();
    turns.set(CHAT, 49 + drop);
    await reconnected;
    await flush();
    expect(shown.at(-1)).toBe(49 + drop);
  }
  expect(flips).toEqual([]);
});
