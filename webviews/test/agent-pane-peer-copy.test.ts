// l10n-allow-file: test fixture prompts, replies and machine names, not shipped UI.
//
// A chat on another machine (huge-blue, a Cloud VM) opens on its history while that machine is
// paused or offline: the Mac's acpmux keeps a copy of what it saw (`_acpmux/peer_snapshot`,
// acpmux hub/peer_snapshot.rs), the pane draws it at once, marked possibly stale, and reads the
// chat from the machine once it is back (peerCopy.ts). Lawrence: "decouple persistence of acp
// trajectories from the VM itself, in case the VM is resuming". These hold the page to that:
//
//   - a peer chat whose machine is down opens on the copy and stays on it, marked offline;
//   - the machine coming back continues the copy where its page joins it, each record once, and
//     replaces it where it does not;
//   - a session the machine recreated (another `createdAt`) replaces the copy instead of merging,
//     and the new session's live records that came before its attach answered are kept;
//   - a copy of another generation than the session listed is not drawn;
//   - a machine back on an older log replaces the copy's newer records;
//   - a machine that is down again when it is read keeps the copy, offline, as it was confirmed;
//   - a chat read before whose machine is now offline shows the copy, and a tail of a session
//     since recreated never joins the new one, nor loses what came live while it was drawn;
//   - a session recreated while the copy's attach was out, or named by a row while its machine
//     stays down, leaves no copy of the old one on screen, and a record that comes live twice
//     shows once when the copy is replaced;
//   - a machine back while the copy's attach is out is read again once that attach fails;
//   - a session moved to another machine, or a reply of another session, is never drawn as it,
//     and the new machine's copy is;
//   - a recreated session drawn from its copy keeps nothing queued of the old one, and one
//     recreated while its copy is read draws the new session's copy;
//   - a chat on this Mac never asks for a copy.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { keptTail, rememberTail, resetKeptTailsForTests } from "../src/agent-session/acpmux/tailCache";
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
const OTHER = "local-chat";
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
  /// Attaches refused although the row says the machine is back (it went down again).
  refuseAttach = 0;
  /// The session the attach names, when the machine recreated it after the row was listed.
  attachCreatedAt: number | undefined;
  /// Live records the machine sends before it answers the attach.
  beforeAttach: ReturnType<typeof record>[] = [];
  /// Attaches that fail for another reason than the machine being down.
  failAttach = 0;
  /// Live records sent while the chat left is detached (before the attach is asked).
  beforeDetach: ReturnType<typeof record>[] = [];
  /// Another chat, on this Mac, listed beside the peer chat (a tab that switches from it).
  other = false;
  /// The session's `createdAt` a row announces while the attach is out (the machine recreated it),
  /// before that attach is answered.
  recreatedDuringAttach: number | undefined;
  /// The attach reply's `pageThrough` and a `lastSeq` read after the page, when set.
  pageThrough: number | undefined;
  lastSeqAfter: number | undefined;
  /// The row is announced (back) once while the next attach is out, before it is answered.
  announceDuringAttach = false;
  /// The session the copy's reply names, when not this one.
  copyNames: string | undefined;
  /// The session a row announces while the copy is read (the machine recreated it, still down),
  /// with the Mac's copy of it: the read that is out answers the copy before.
  recreatedDuringRead:
    | { createdAt: number; copy: { events: unknown[]; generation: number; lastSeq: number } }
    | undefined;
  /// The prompts the session's row lists as queued.
  queue: { promptId: string; prompt: string }[] | undefined;
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
      ...(this.queue ? { queue: this.queue } : {}),
      ...(this.peer ? { peer: this.peer } : {}),
      ...(this.down ? { stale: true } : {}),
    };
  }

  otherSummary() {
    return { ...this.summary(), sessionId: OTHER, name: "here", status: "idle", peer: undefined, stale: undefined };
  }

  /// The machine answers again: its row comes back fresh, as acpmux announces it.
  comeBack(): void {
    this.down = false;
    this.announce();
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

  private reply(id: number | undefined, body: Record<string, unknown>) {
    this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id, ...body }) });
  }

  private answer(message: Message): void {
    const p = message.params ?? {};
    if (message.method === "initialize")
      return this.reply(message.id, {
        result: { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } },
      });
    if (message.method === "_acpmux/watch")
      return this.reply(message.id, {
        result: { sessions: [this.summary(), ...(this.other ? [this.otherSummary()] : [])] },
      });
    if (message.method === "_acpmux/detach") {
      for (const params of this.beforeDetach.splice(0))
        this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params }) });
      return this.reply(message.id, { result: {} });
    }
    if (message.method === "_acpmux/attach" && p.sessionId === OTHER)
      return this.reply(message.id, {
        result: { session: this.otherSummary(), events: [], hasMore: false, lastSeq: 0 },
      });
    if (message.method === "_acpmux/peer_snapshot") {
      const copy = this.copy;
      const summary = this.summary();
      const recreated = this.recreatedDuringRead;
      if (recreated) {
        this.recreatedDuringRead = undefined;
        this.createdAt = recreated.createdAt;
        this.copy = recreated.copy;
        this.announce();
      }
      return this.reply(message.id, {
        result: copy
          ? {
              peer: this.peer,
              sessionId: this.copyNames ?? SESSION,
              stale: true,
              hasMore: false,
              capturedAt: START,
              summary,
              ...copy,
            }
          : { peer: this.peer, sessionId: SESSION, stale: true, events: [], lastSeq: 0 },
      });
    }
    if (message.method === "_acpmux/attach") {
      for (const params of this.beforeAttach.splice(0))
        this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params }) });
      if (this.announceDuringAttach) {
        this.announceDuringAttach = false;
        this.announce();
      }
      if (this.recreatedDuringAttach !== undefined) {
        this.createdAt = this.recreatedDuringAttach;
        this.recreatedDuringAttach = undefined;
        this.announce();
      }
    }
    if (message.method === "_acpmux/attach" && this.failAttach > 0) {
      this.failAttach -= 1;
      return this.reply(message.id, { error: { code: -32603, message: "internal: the log did not read" } });
    }
    if (message.method === "_acpmux/attach" && (this.down || this.refuseAttach > 0)) {
      this.refuseAttach = Math.max(0, this.refuseAttach - 1);
      return this.reply(message.id, {
        error: {
          code: -32603,
          message: "peer_unreachable: huge-blue (reconnecting, last seen 40s ago: connect timed out)",
          data: { reason: "peer_unreachable" },
        },
      });
    }
    if (message.method === "_acpmux/attach") {
      // The newest page only, as a remote attach is bounded.
      const page = this.log.slice(-3);
      return this.reply(message.id, {
        result: {
          session: { ...this.summary(), createdAt: this.attachCreatedAt ?? this.createdAt },
          events: page,
          hasMore: page.length < this.log.length,
          lastSeq: this.lastSeqAfter ?? this.log.at(-1)?.seq ?? 0,
          ...(this.pageThrough !== undefined ? { pageThrough: this.pageThrough } : {}),
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

function open(daemon: Daemon, seed?: () => void, sessionId = SESSION) {
  resetKeptTailsForTests();
  seed?.();
  const drawn: AcpmuxSnapshot[] = [];
  const client = AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://peer.invalid/",
      token: "t",
      sessionId,
    },
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

test("the machine coming back continues the copy where its page joins it, each record once", async () => {
  const daemon = new Daemon();
  daemon.copy = { events: turn(1, 4, "kept"), generation: 100, lastSeq: 4 };
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  // The attach page holds 4..6: it joins the copy.
  daemon.log = [...turn(1, 4, "kept"), ...turn(5, 6, "new")];
  daemon.comeBack();
  await flush();
  const shown = text(tab.last());
  for (let seq = 1; seq <= 6; seq += 1) expect(count(shown, ` ${seq}. `)).toBe(1);
  expect(tab.last()!.peerCopy).toBeUndefined();
});

test("a page that does not join the copy replaces it, and no record shows twice", async () => {
  const daemon = new Daemon();
  daemon.copy = { events: turn(1, 4, "kept"), generation: 100, lastSeq: 4 };
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  // The machine ran on while it was away: the attach page holds 8..10.
  daemon.log = [...turn(1, 4, "kept"), ...turn(5, 10, "new")];
  daemon.comeBack();
  await flush();
  const shown = text(tab.last());
  for (let seq = 8; seq <= 10; seq += 1) expect(count(shown, ` ${seq}. `)).toBe(1);
  for (let seq = 1; seq <= 7; seq += 1) expect(count(shown, ` ${seq}. `)).toBeLessThanOrEqual(1);
  // None of the copy's rows is left beside the machine's page.
  expect(shown).not.toContain("kept ");
  expect(tab.last()!.peerCopy).toBeUndefined();
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
});

test("a session recreated while its copy is drawn keeps the live records that came before its attach answered", async () => {
  const daemon = new Daemon();
  daemon.down = false;
  daemon.copy = { events: turn(1, 4, "old"), generation: 100, lastSeq: 4 };
  daemon.attachCreatedAt = 200;
  daemon.log = turn(1, 2, "fresh");
  // At or below the copy's newest seq, and above it: both the new session's.
  daemon.beforeAttach = [record(3, "low"), record(6, "high")];
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  const shown = text(tab.last());
  expect(shown).toContain("fresh 2.");
  expect(shown).toContain("low");
  expect(shown).toContain("high");
  expect(shown).not.toContain("old ");
});

test("a machine back on an older log replaces the copy's newer records", async () => {
  const daemon = new Daemon();
  daemon.copy = { events: turn(1, 10, "kept"), generation: 100, lastSeq: 10 };
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  // Restored from an older disk, same session: its log ends at 6.
  daemon.log = turn(1, 6, "restored");
  daemon.comeBack();
  await flush();
  const shown = text(tab.last());
  expect(shown).toContain("restored 6.");
  expect(shown).not.toContain("kept ");
  expect(tab.last()!.peerCopy).toBeUndefined();
});

test("a live record from a failed attempt never leaves a hole once the machine is read", async () => {
  const daemon = new Daemon();
  daemon.copy = { events: turn(1, 4, "kept"), generation: 100, lastSeq: 4 };
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  daemon.log = [...turn(1, 4, "kept"), ...turn(5, 10, "new")];
  // The machine sends seq 10 and then refuses the attach: the copy stays as it was confirmed.
  daemon.beforeAttach = [record(10, "stray")];
  daemon.refuseAttach = 1;
  daemon.comeBack();
  await flush();
  expect(tab.last()!.peerCopy?.offline).toBe(true);
  expect(text(tab.last())).not.toContain("stray");
  // Back for good: its page (8..10) does not join the copy (4), so it replaces it.
  daemon.comeBack();
  await flush();
  const shown = text(tab.last());
  for (let seq = 8; seq <= 10; seq += 1) expect(count(shown, ` ${seq}. `)).toBe(1);
  expect(shown).not.toContain("kept ");
  expect(tab.last()!.peerCopy).toBeUndefined();
});

test("a copy of another generation than the session listed is not drawn", async () => {
  const daemon = new Daemon();
  daemon.down = false;
  daemon.createdAt = 200;
  daemon.log = turn(1, 2, "fresh");
  daemon.copy = { events: turn(1, 4, "old"), generation: 100, lastSeq: 4 };
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  expect(text(tab.last())).toContain("fresh 2.");
  expect(tab.drawn.some((snapshot) => text(snapshot).includes("old "))).toBe(false);
  expect(tab.last()!.peerCopy).toBeUndefined();
});

test("a machine that is down again when it is read keeps the copy, offline", async () => {
  const daemon = new Daemon();
  daemon.copy = { events: turn(1, 4, "kept"), generation: 100, lastSeq: 4 };
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  daemon.log = [...turn(1, 4, "kept"), ...turn(5, 6, "new")];
  daemon.refuseAttach = 1;
  daemon.comeBack();
  await flush();
  expect(tab.last()!.peerCopy?.offline).toBe(true);
  expect(text(tab.last())).toContain("kept 4.");
  daemon.comeBack();
  await flush();
  const shown = text(tab.last());
  for (let seq = 1; seq <= 6; seq += 1) expect(count(shown, ` ${seq}. `)).toBe(1);
  expect(tab.last()!.peerCopy).toBeUndefined();
});

/// A tail this page kept of the chat (an earlier visit), of session generation `createdAt`.
const keptTailOf =
  (events: unknown[], createdAt: number, peer = "huge-blue") =>
  () =>
    rememberTail(SESSION, {
      events: events as never,
      summary: { sessionId: SESSION, createdAt, peer },
      turnOpener: undefined,
      historyExhausted: true,
      queue: [],
      configSeq: 0,
      usageFromSeq: 0,
    });

test("a chat read before, whose machine is now offline, shows the Mac's copy instead of closing", async () => {
  const daemon = new Daemon();
  daemon.copy = { events: turn(1, 6, "kept"), generation: 100, lastSeq: 6 };
  const tab = open(daemon, keptTailOf(turn(1, 4, "cached"), 100));
  live.push(await tab.client);
  await flush();
  const shown = text(tab.last());
  expect(shown).toContain("kept 6.");
  expect(shown).not.toContain("cached ");
  expect(tab.last()!.peerCopy?.offline).toBe(true);
});

test("a tail kept of a session since recreated never joins the new one", async () => {
  const daemon = new Daemon();
  daemon.down = false;
  daemon.createdAt = 200;
  daemon.log = turn(1, 5, "fresh");
  const tab = open(daemon, keptTailOf(turn(1, 8, "old"), 100));
  live.push(await tab.client);
  await flush();
  const shown = text(tab.last());
  expect(shown).toContain("fresh 5.");
  expect(shown).not.toContain("old ");
});

test("a tail kept of another machine never joins the chat of the one the row names", async () => {
  const daemon = new Daemon();
  daemon.down = false;
  daemon.peer = "cloud-vm";
  daemon.log = turn(1, 9, "vm");
  const tab = open(daemon, keptTailOf(turn(1, 8, "old"), 100));
  live.push(await tab.client);
  await flush();
  const shown = text(tab.last());
  expect(shown).toContain("vm 9.");
  expect(shown).not.toContain("old ");
});

test("a tail kept of a machine never joins the chat once the session is on this Mac", async () => {
  const daemon = new Daemon();
  daemon.down = false;
  daemon.peer = undefined;
  daemon.log = turn(1, 9, "here");
  const tab = open(daemon, keptTailOf(turn(1, 8, "old"), 100));
  live.push(await tab.client);
  await flush();
  const shown = text(tab.last());
  expect(shown).toContain("here 9.");
  expect(shown).not.toContain("old ");
});

test("a machine back while a tail's attach is out, no copy drawn yet, is read once that attach fails", async () => {
  const daemon = new Daemon();
  daemon.down = false;
  daemon.copy = { events: turn(1, 4, "kept"), generation: 100, lastSeq: 4 };
  daemon.log = turn(1, 6, "kept");
  // Refused as down, while its row says it is back.
  daemon.refuseAttach = 1;
  daemon.announceDuringAttach = true;
  const tab = open(daemon, keptTailOf(turn(1, 3, "kept"), 100));
  live.push(await tab.client);
  await flush();
  const shown = text(tab.last());
  for (let seq = 1; seq <= 6; seq += 1) expect(count(shown, ` ${seq}. `)).toBe(1);
  expect(tab.last()!.peerCopy).toBeUndefined();
});

test("a live record that comes while the chat left detaches is kept when the tail drawn is replaced", async () => {
  const daemon = new Daemon();
  daemon.down = false;
  daemon.other = true;
  daemon.createdAt = 200;
  daemon.log = turn(1, 5, "fresh");
  // The new session's seq 2 comes live before the attach is asked; the attach's page is 3 to 5.
  daemon.beforeDetach = [daemon.log[1]!];
  const tab = open(daemon, keptTailOf(turn(1, 8, "old"), 100), OTHER);
  const client = await tab.client;
  live.push(client);
  await flush();
  await client.select(SESSION);
  await flush();
  const shown = text(tab.last());
  expect(shown).toContain("fresh 2.");
  expect(shown).toContain("fresh 5.");
  expect(shown).not.toContain("old ");
});

test("a copy whose machine comes back but cannot be read leaves no tail to draw again", async () => {
  const daemon = new Daemon();
  daemon.copy = { events: turn(1, 4, "kept"), generation: 100, lastSeq: 4 };
  const tab = open(daemon, keptTailOf(turn(1, 3, "cached"), 100));
  live.push(await tab.client);
  await flush();
  expect(tab.last()!.peerCopy?.offline).toBe(true);
  daemon.failAttach = 1;
  daemon.comeBack();
  await flush();
  expect(tab.last()!.peerCopy).toBeUndefined();
  expect(text(tab.last())).not.toContain("kept ");
  expect(keptTail(SESSION)).toBeUndefined();
});

test("a copy whose session was recreated while its attach was out is not kept when the machine is down", async () => {
  const daemon = new Daemon();
  daemon.copy = { events: turn(1, 4, "old"), generation: 100, lastSeq: 4 };
  // The row names session 200 before the attach is refused; the Mac holds a copy of 100 only.
  daemon.recreatedDuringAttach = 200;
  const tab = open(daemon);
  const client = await tab.client.catch(() => undefined);
  if (client) live.push(client);
  await flush();
  expect(text(tab.last())).not.toContain("old ");
  expect(tab.last()!.peerCopy).toBeUndefined();
});

test("a row naming a recreated session takes the old copy off screen while the machine stays down", async () => {
  const daemon = new Daemon();
  daemon.copy = { events: turn(1, 4, "old"), generation: 100, lastSeq: 4 };
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  expect(tab.last()!.peerCopy?.offline).toBe(true);
  daemon.createdAt = 200;
  daemon.announce();
  await flush();
  expect(text(tab.last())).not.toContain("old ");
  expect(tab.last()!.peerCopy).toBeUndefined();
  expect(keptTail(SESSION)).toBeUndefined();
});

test("a row naming a recreated session the Mac has a copy of draws that copy, offline", async () => {
  const daemon = new Daemon();
  daemon.copy = { events: turn(1, 4, "old"), generation: 100, lastSeq: 4 };
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  daemon.createdAt = 200;
  daemon.copy = { events: turn(1, 2, "fresh"), generation: 200, lastSeq: 2 };
  daemon.announce();
  await flush();
  const shown = text(tab.last());
  expect(shown).toContain("fresh 2.");
  expect(shown).not.toContain("old ");
  expect(tab.last()!.peerCopy?.offline).toBe(true);
  // The machine back: the new session's chat is read from it.
  daemon.log = turn(1, 3, "fresh");
  daemon.comeBack();
  await flush();
  expect(text(tab.last())).toContain("fresh 3.");
  expect(tab.last()!.peerCopy).toBeUndefined();
});

test("a machine whose page was read before its newest records replaces a copy past it", async () => {
  const daemon = new Daemon();
  daemon.copy = { events: turn(1, 10, "kept"), generation: 100, lastSeq: 10 };
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  // Restored to seq 6; its log takes seq 7 between the page and `lastSeq`.
  daemon.log = turn(1, 6, "restored");
  daemon.pageThrough = 6;
  daemon.lastSeqAfter = 11;
  daemon.comeBack();
  await flush();
  const shown = text(tab.last());
  expect(shown).toContain("restored 6.");
  expect(shown).not.toContain("kept ");
});

test("a live record that comes twice shows once when the attach replaces the copy", async () => {
  const daemon = new Daemon();
  daemon.down = false;
  daemon.copy = { events: turn(1, 4, "old"), generation: 100, lastSeq: 4 };
  daemon.attachCreatedAt = 200;
  daemon.log = turn(1, 2, "fresh");
  daemon.beforeAttach = [record(3, "twice3."), record(3, "twice3."), record(6, "once6.")];
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  const shown = text(tab.last());
  expect(count(shown, "twice3.")).toBe(1);
  expect(count(shown, "once6.")).toBe(1);
  expect(shown).not.toContain("old ");
});

test("a machine back while the copy's attach is out is read again once that attach fails", async () => {
  const daemon = new Daemon();
  daemon.copy = { events: turn(1, 4, "kept"), generation: 100, lastSeq: 4 };
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  daemon.log = [...turn(1, 4, "kept"), ...turn(5, 6, "new")];
  const attaches = () => daemon.asked.filter((m) => m.method === "_acpmux/attach").length;
  const before = attaches();
  // The attach is refused, but the row said the machine was back while it was out.
  daemon.refuseAttach = 1;
  daemon.announceDuringAttach = true;
  daemon.comeBack();
  await flush();
  const shown = text(tab.last());
  for (let seq = 1; seq <= 6; seq += 1) expect(count(shown, ` ${seq}. `)).toBe(1);
  expect(tab.last()!.peerCopy).toBeUndefined();
  // The refused attach and one more: never a loop.
  expect(attaches() - before).toBe(2);
  await flush();
  expect(attaches() - before).toBe(2);
});

test("a session moved to another machine takes the old machine's copy off screen", async () => {
  const daemon = new Daemon();
  daemon.copy = { events: turn(1, 4, "old"), generation: 100, lastSeq: 4 };
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  expect(tab.last()!.peerCopy?.offline).toBe(true);
  daemon.peer = "cloud-vm";
  daemon.copy = undefined;
  daemon.announce();
  await flush();
  expect(text(tab.last())).not.toContain("old ");
  expect(tab.last()!.peerCopy).toBeUndefined();
});

test("a session moved to another machine draws that machine's copy, then its chat", async () => {
  const daemon = new Daemon();
  daemon.copy = { events: turn(1, 4, "old"), generation: 100, lastSeq: 4 };
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  daemon.peer = "cloud-vm";
  daemon.copy = { events: turn(1, 3, "vm"), generation: 100, lastSeq: 3 };
  daemon.announce();
  await flush();
  expect(text(tab.last())).toContain("vm 3.");
  expect(text(tab.last())).not.toContain("old ");
  expect(tab.last()!.peerCopy).toEqual({ peer: "cloud-vm", capturedAt: START, offline: true });
  daemon.log = turn(1, 5, "vm");
  daemon.comeBack();
  await flush();
  const shown = text(tab.last());
  for (let seq = 1; seq <= 5; seq += 1) expect(count(shown, ` ${seq}. `)).toBe(1);
  expect(shown).not.toContain("old ");
  expect(tab.last()!.peerCopy).toBeUndefined();
});

test("a recreated session drawn from its copy keeps nothing queued of the old one", async () => {
  const daemon = new Daemon();
  daemon.copy = { events: turn(1, 4, "old"), generation: 100, lastSeq: 4 };
  daemon.queue = [{ promptId: "p1", prompt: "old queued prompt" }];
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  expect(JSON.stringify(tab.last()!.queue)).toContain("old queued prompt");
  daemon.createdAt = 200;
  daemon.queue = undefined;
  daemon.copy = { events: turn(1, 2, "fresh"), generation: 200, lastSeq: 2 };
  daemon.announce();
  await flush();
  expect(text(tab.last())).toContain("fresh 2.");
  expect(JSON.stringify(tab.last()!.queue)).not.toContain("old queued prompt");
});

test("a session recreated while its copy is read draws the new session's copy, offline", async () => {
  const daemon = new Daemon();
  daemon.copy = { events: turn(1, 4, "old"), generation: 100, lastSeq: 4 };
  // The read of the old copy is out when the row names the new session; the Mac has a copy of it.
  daemon.recreatedDuringRead = { createdAt: 200, copy: { events: turn(1, 2, "fresh"), generation: 200, lastSeq: 2 } };
  const tab = open(daemon, keptTailOf(turn(1, 3, "cached"), 100));
  live.push(await tab.client);
  await flush();
  const shown = text(tab.last());
  expect(shown).toContain("fresh 2.");
  expect(shown).not.toContain("old ");
  expect(shown).not.toContain("cached ");
  expect(tab.last()!.peerCopy?.offline).toBe(true);
  expect(daemon.asked.filter((m) => m.method === "_acpmux/peer_snapshot")).toHaveLength(2);
});

test("a copy reply that names another session is never drawn", async () => {
  const daemon = new Daemon();
  daemon.copy = { events: turn(1, 4, "kept"), generation: 100, lastSeq: 4 };
  daemon.copyNames = "another-chat";
  const tab = open(daemon);
  const client = await tab.client.catch(() => undefined);
  if (client) live.push(client);
  await flush();
  expect(tab.drawn.some((snapshot) => text(snapshot).includes("kept "))).toBe(false);
  expect(tab.last()?.peerCopy).toBeUndefined();
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
