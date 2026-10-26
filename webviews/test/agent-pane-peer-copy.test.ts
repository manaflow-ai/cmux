// l10n-allow-file: test fixture prompts, replies and machine names, not shipped UI.
//
// A chat on another machine (huge-blue, a Cloud VM) opens on its history while that machine is
// paused or offline: the Mac's acpmux keeps a copy of what it saw (`_acpmux/peer_snapshot`,
// acpmux hub/peer_snapshot.rs), the pane draws it at once, marked possibly stale, and catches up
// from the machine with `afterSeq` once it is back (peerCopy.ts). Lawrence: "decouple persistence
// of acp trajectories from the VM itself, in case the VM is resuming". These hold the page to that:
//
//   - a peer chat whose machine is down opens on the copy and stays on it, marked offline;
//   - the machine coming back catches the chat up with `afterSeq`, each record once;
//   - a session the machine recreated (another `createdAt`) replaces the copy instead of merging,
//     a tail this page kept of it too, and the new session's live records are kept meanwhile;
//   - a machine that goes down again before the catch-up read keeps the copy's cursor;
//   - a chat on this Mac never asks for a copy.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { rememberTail, resetKeptTailsForTests } from "../src/agent-session/acpmux/tailCache";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

const START = Date.UTC(2026, 9, 25, 9, 0, 0);
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

const SESSION = "peer-chat";
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

/// The Mac's acpmux with one chat on peer huge-blue (or on this Mac, `peer: undefined`): `down`
/// refuses its attach as acpmux does for a machine that does not answer, `copy` is what
/// `_acpmux/peer_snapshot` answers, `log` the machine's own records, `createdAt` its session.
class Daemon {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  down = true;
  peer: string | undefined = "huge-blue";
  createdAt = 100;
  copy: { events: unknown[]; generation: number; lastSeq: number } | undefined;
  log: ReturnType<typeof record>[] = [];
  /// The machine goes down again before it answers the catch-up read (`_acpmux/events` after a seq).
  catchUpDown = false;
  /// Live records the machine sends while the attach's own reads (an older page) are out.
  afterAttach: ReturnType<typeof record>[] = [];
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

  summary() {
    return {
      sessionId: SESSION,
      name: "huge-blue/lane",
      cwd: "/home/dev/project",
      title: "Lane on huge-blue",
      harness: "claude",
      status: this.down ? "unreachable" : "idle",
      turnCount: 1,
      updatedAt: START,
      createdAt: this.createdAt,
      ...(this.peer ? { peer: this.peer } : {}),
      ...(this.down ? { stale: true } : {}),
    };
  }

  /// The machine answers again: its row comes back fresh, as acpmux announces it.
  comeBack(): void {
    this.down = false;
    this.onmessage?.({
      data: JSON.stringify({
        jsonrpc: "2.0",
        method: "_acpmux/session_changed",
        params: { sessionId: SESSION, kind: "status", session: this.summary(), peer: this.peer },
      }),
    });
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
    if (message.method === "_acpmux/peer_snapshot") {
      const copy = this.copy;
      return this.reply(message.id, {
        result: copy
          ? { peer: this.peer, sessionId: SESSION, stale: true, hasMore: false, capturedAt: START, summary: this.summary(), ...copy }
          : { peer: this.peer, sessionId: SESSION, stale: true, events: [], lastSeq: 0 },
      });
    }
    if (message.method === "_acpmux/attach" && this.down)
      return this.reply(message.id, {
        error: {
          code: -32603,
          message: "peer_unreachable: huge-blue (reconnecting, last seen 40s ago: connect timed out)",
          data: { reason: "peer_unreachable" },
        },
      });
    if (message.method === "_acpmux/attach") {
      // The newest page only, as a remote attach is bounded.
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
    if (message.method === "_acpmux/events" && p.afterSeq !== undefined && this.catchUpDown) {
      this.catchUpDown = false;
      return this.reply(message.id, {
        error: { code: -32603, message: "peer_unreachable: huge-blue (reconnecting)", data: { reason: "peer_unreachable" } },
      });
    }
    if (message.method === "_acpmux/events" && p.beforeSeq !== undefined) {
      for (const params of this.afterAttach.splice(0))
        this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params }) });
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

function open(daemon: Daemon, seed?: () => void) {
  resetKeptTailsForTests();
  seed?.();
  const drawn: AcpmuxSnapshot[] = [];
  const client = AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://peer.invalid/", token: "t", sessionId: SESSION },
    (snapshot) => {
      if (snapshot.type === "snapshot") drawn.push(snapshot);
    },
    undefined,
    () => daemon as unknown as WebSocket,
  );
  return { drawn, client, last: () => drawn.at(-1) };
}

test("a peer chat whose machine is offline opens on the Mac's copy, marked offline, and stays open", async () => {
  const daemon = new Daemon();
  daemon.copy = { events: turn(1, 4, "kept"), generation: 100, lastSeq: 4 };
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  expect(text(tab.last())).toContain("kept 4.");
  expect(tab.last()!.peerCopy).toEqual({ peer: "huge-blue", capturedAt: START, offline: true });
  expect(tab.last()!.sessionId).toBe(SESSION);
  expect(daemon.asked.some((m) => m.method === "_acpmux/peer_snapshot")).toBe(true);
});

test("the machine coming back catches the chat up after the copy, each record once", async () => {
  const daemon = new Daemon();
  daemon.copy = { events: turn(1, 4, "kept"), generation: 100, lastSeq: 4 };
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  // The machine ran on while it was away: 1..10, of which the attach page holds 8..10.
  daemon.log = [...turn(1, 4, "kept"), ...turn(5, 10, "new")];
  daemon.comeBack();
  await flush();
  const shown = text(tab.last());
  for (let seq = 1; seq <= 10; seq += 1) expect(count(shown, ` ${seq}. `)).toBe(1);
  expect(tab.last()!.peerCopy).toBeUndefined();
  // Not the commands lookup (`beforeSeq`): the read of what the machine holds after the copy.
  const catchUp = daemon.asked.find((m) => m.method === "_acpmux/events" && m.params?.afterSeq !== undefined);
  expect(catchUp?.params?.afterSeq).toBe(4);
});

test("a session the machine recreated replaces the copy instead of merging with it", async () => {
  const daemon = new Daemon();
  daemon.copy = { events: turn(1, 4, "old"), generation: 100, lastSeq: 4 };
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  expect(text(tab.last())).toContain("old 4.");
  daemon.createdAt = 200;
  daemon.log = turn(1, 2, "fresh");
  daemon.comeBack();
  await flush();
  const shown = text(tab.last());
  expect(shown).toContain("fresh 2.");
  expect(shown).not.toContain("old ");
  expect(daemon.asked.some((m) => m.method === "_acpmux/events" && m.params?.afterSeq !== undefined)).toBe(false);
});

test("a session recreated while away replaces a tail this page kept of it, and its live records stay", async () => {
  const daemon = new Daemon();
  daemon.down = false;
  daemon.createdAt = 200;
  // The page (3..5) does not start the chat, so the attach reads older records while it lands.
  daemon.log = turn(1, 5, "fresh");
  daemon.afterAttach = [record(6, "live")];
  const old = { events: turn(1, 8, "old"), summary: { sessionId: SESSION, createdAt: 100 } };
  const tab = open(daemon, () =>
    rememberTail(SESSION, { ...old, turnOpener: undefined, historyExhausted: true, queue: [], configSeq: 0, usageFromSeq: 0 }),
  );
  live.push(await tab.client);
  await flush();
  const shown = text(tab.last());
  // The live record follows the page in the same reply row (its reveal may still be streaming).
  expect(shown).toContain("fresh 5. live");
  expect(shown).not.toContain("old ");
});

test("a machine that goes down again before the catch-up read keeps the copy's cursor", async () => {
  const daemon = new Daemon();
  daemon.copy = { events: turn(1, 4, "kept"), generation: 100, lastSeq: 4 };
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  daemon.log = [...turn(1, 4, "kept"), ...turn(5, 10, "new")];
  daemon.catchUpDown = true;
  daemon.comeBack();
  await flush();
  expect(tab.last()!.peerCopy?.offline).toBe(true);
  daemon.comeBack();
  await flush();
  const shown = text(tab.last());
  for (let seq = 1; seq <= 10; seq += 1) expect(count(shown, ` ${seq}. `)).toBe(1);
  const reads = daemon.asked.filter((m) => m.method === "_acpmux/events" && m.params?.afterSeq !== undefined);
  expect(reads.map((m) => m.params?.afterSeq)).toEqual([4, 4]);
  expect(tab.last()!.peerCopy).toBeUndefined();
});

test("a chat on this Mac never asks for a peer copy", async () => {
  const daemon = new Daemon();
  daemon.peer = undefined;
  daemon.down = false;
  daemon.log = turn(1, 2, "local");
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  expect(text(tab.last())).toContain("local 2.");
  expect(daemon.asked.some((m) => m.method === "_acpmux/peer_snapshot")).toBe(false);
  expect(tab.last()!.peerCopy).toBeUndefined();
});
