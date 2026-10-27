// l10n-allow-file: test fixture replies and machine names, not shipped UI.
//
// A chat attached and idle whose session acpmux recreated (another `createdAt`), or moved to
// another machine (a Cloud move, Bring Back Local, another peer), is read again from the session
// its row names now: the old rows, cursors and stream go, so the pane never shows the session
// before as this chat, and the new session's records (which start their seqs over) are not taken
// for ones already held. These hold the page to that:
//
//   - a recreated session's rows replace the old ones, and its live records show;
//   - a chat moved from this Mac to a Cloud machine, or from one machine to another, is read there;
//   - a chat moved to a machine that does not answer shows that machine's copy, offline;
//   - a row that names the same session on the same machine reads nothing again;
//   - the follow claims no attach token, so a reconnect's attach that starts meanwhile decides.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { resetKeptTailsForTests } from "../src/agent-session/acpmux/tailCache";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

const START = Date.UTC(2026, 9, 27, 9, 0, 0);
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

const SESSION = "lane-chat";
const record = (seq: number, text: string) => ({
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
const turn = (from: number, to: number, label: string) =>
  Array.from({ length: to - from + 1 }, (_, at) => record(from + at, `${label} ${from + at}. `));

/// The Mac's acpmux with one chat: `peer` the machine it runs on (undefined: this Mac), `createdAt`
/// its session, `log` that session's records, `down` a machine that does not answer, `copy` what
/// `_acpmux/peer_snapshot` answers of it.
class Daemon {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  peer: string | undefined = "huge-blue";
  createdAt = 100;
  down = false;
  log: ReturnType<typeof record>[] = [];
  copy: { events: unknown[]; generation: number; lastSeq: number } | undefined;
  /// Runs once when the next attach is asked, before it is answered.
  onAttach: (() => void) | undefined;
  readonly asked: Message[] = [];

  constructor() {
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.();
    });
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

  attaches(): number {
    return this.asked.filter((message) => message.method === "_acpmux/attach").length;
  }

  summary() {
    return {
      sessionId: SESSION,
      name: "lane",
      cwd: "/home/dev/project",
      title: "Lane",
      harness: "claude",
      status: this.down ? "unreachable" : "idle",
      turnCount: 1,
      updatedAt: START,
      createdAt: this.createdAt,
      ...(this.peer ? { peer: this.peer } : {}),
      ...(this.down ? { stale: true } : {}),
    };
  }

  /// The session's row as it is now, as acpmux announces a change.
  announce(): void {
    this.onmessage?.({
      data: JSON.stringify({
        jsonrpc: "2.0",
        method: "_acpmux/session_changed",
        params: { sessionId: SESSION, kind: "status", session: this.summary(), peer: this.peer },
      }),
    });
  }

  /// A record the session streams live to the attached page.
  stream(event: ReturnType<typeof record>): void {
    this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }) });
  }

  private reply(id: number | undefined, body: Record<string, unknown>) {
    this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id, ...body }) });
  }

  private answer(message: Message): void {
    const p = message.params ?? {};
    if (message.method === "initialize")
      return this.reply(message.id, {
        result: { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } },
      });
    if (message.method === "_acpmux/watch") return this.reply(message.id, { result: { sessions: [this.summary()] } });
    if (message.method === "_acpmux/peer_snapshot")
      return this.reply(message.id, {
        result: this.copy
          ? { peer: this.peer, sessionId: SESSION, stale: true, hasMore: false, capturedAt: START, ...this.copy }
          : { peer: this.peer, sessionId: SESSION, stale: true, events: [], lastSeq: 0 },
      });
    if (message.method === "_acpmux/attach") {
      const hook = this.onAttach;
      this.onAttach = undefined;
      hook?.();
      if (this.down)
        return this.reply(message.id, {
          error: {
            code: -32603,
            message: `peer_unreachable: ${this.peer} (reconnecting, last seen 40s ago: connect timed out)`,
            data: { reason: "peer_unreachable" },
          },
        });
      const page = this.log.slice(-3);
      return this.reply(message.id, {
        result: {
          session: this.summary(),
          events: page,
          hasMore: page.length < this.log.length,
          lastSeq: this.log.at(-1)?.seq ?? 0,
        },
      });
    }
    if (message.method === "_acpmux/events") {
      const after = Number(p.afterSeq ?? 0);
      const events = this.log.filter((r) => r.seq > after);
      return this.reply(message.id, { result: { events, hasMore: false, lastSeq: this.log.at(-1)?.seq ?? 0 } });
    }
    this.reply(message.id, { result: {} });
  }
}

const flush = async () => {
  for (let pass = 0; pass < 12; pass += 1) await new Promise((resolve) => setTimeout(resolve, 0));
};

const text = (snapshot: AcpmuxSnapshot | undefined) =>
  (snapshot?.rows ?? [])
    .map((row) => JSON.stringify(row))
    .join(" ")
    .replace(/\s+/g, " ");

const count = (haystack: string, needle: string) => haystack.split(needle).length - 1;

let live: AcpmuxDirectClient[] = [];
afterEach(() => {
  for (const client of live) client.close();
  live = [];
  resetKeptTailsForTests();
});

/// Opens the chat on `daemon` and waits until it is attached, idle, on the session before.
async function attached(daemon: Daemon) {
  resetKeptTailsForTests();
  daemon.log = turn(1, 3, "old");
  const drawn: AcpmuxSnapshot[] = [];
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://peer.invalid/",
      token: "t",
      sessionId: SESSION,
    },
    (snapshot) => {
      if (snapshot.type === "snapshot") drawn.push(snapshot);
    },
    undefined,
    () => daemon as unknown as WebSocket,
  );
  live.push(client);
  await flush();
  expect(text(drawn.at(-1))).toContain("old 3.");
  expect(daemon.attaches()).toBe(1);
  return { client, last: () => drawn.at(-1) };
}

test("an idle chat whose session was recreated shows the new session, and its live records", async () => {
  const daemon = new Daemon();
  const tab = await attached(daemon);
  daemon.createdAt = 200;
  daemon.log = turn(1, 2, "new");
  daemon.announce();
  await flush();
  expect(daemon.attaches()).toBe(2);
  let shown = text(tab.last());
  expect(shown).toContain("new 2.");
  expect(shown).not.toContain("old ");
  // The new session's seqs start over: its next record is not taken for one already held.
  daemon.log.push(record(3, "live 3. "));
  daemon.stream(record(3, "live 3. "));
  await flush();
  shown = text(tab.last());
  expect(shown).toContain("live 3.");
  for (let seq = 1; seq <= 3; seq += 1) expect(count(shown, ` ${seq}. `)).toBe(1);
  expect(tab.last()!.sessionId).toBe(SESSION);
});

test("an idle chat on this Mac moved to a Cloud machine is read there", async () => {
  const daemon = new Daemon();
  daemon.peer = undefined;
  const tab = await attached(daemon);
  daemon.peer = "cloud-vm";
  daemon.log = turn(1, 5, "vm");
  daemon.announce();
  await flush();
  expect(daemon.attaches()).toBe(2);
  const shown = text(tab.last());
  for (let seq = 3; seq <= 5; seq += 1) expect(count(shown, `vm ${seq}.`)).toBe(1);
  expect(shown).not.toContain("old ");
});

test("an idle chat moved from one machine to another is read from the new one", async () => {
  const daemon = new Daemon();
  const tab = await attached(daemon);
  daemon.peer = "cloud-vm";
  daemon.log = turn(1, 4, "vm");
  daemon.announce();
  await flush();
  expect(daemon.attaches()).toBe(2);
  const shown = text(tab.last());
  expect(shown).toContain("vm 4.");
  expect(shown).not.toContain("old ");
});

test("an idle chat moved to a machine that does not answer shows that machine's copy, offline", async () => {
  const daemon = new Daemon();
  const tab = await attached(daemon);
  daemon.peer = "cloud-vm";
  daemon.down = true;
  daemon.copy = { events: turn(1, 2, "vm"), generation: 100, lastSeq: 2 };
  daemon.announce();
  await flush();
  const shown = text(tab.last());
  expect(shown).toContain("vm 2.");
  expect(shown).not.toContain("old ");
  expect(tab.last()!.peerCopy).toEqual({ peer: "cloud-vm", capturedAt: START, offline: true });
});

test("a row that names the same session on the same machine reads nothing again", async () => {
  const daemon = new Daemon();
  const tab = await attached(daemon);
  daemon.announce();
  await flush();
  expect(daemon.attaches()).toBe(1);
  expect(text(tab.last())).toContain("old 3.");
});

test("following a recreated session claims no attach token, so a reconnect's attach meanwhile decides", async () => {
  const daemon = new Daemon();
  const tab = await attached(daemon);
  const tokens = tab.client as unknown as { copyAttaches: number };
  const before = tokens.copyAttaches;
  // A reconnect starts its own attach while the follow's is out (`open` moves the token on): the
  // follow's reply is then not the chat's to draw.
  daemon.onAttach = () => {
    tokens.copyAttaches += 1;
  };
  daemon.createdAt = 200;
  daemon.log = turn(1, 2, "stale");
  daemon.announce();
  await flush();
  expect(daemon.attaches()).toBe(2);
  expect(tokens.copyAttaches).toBe(before + 1);
  expect(text(tab.last())).not.toContain("stale ");
});
