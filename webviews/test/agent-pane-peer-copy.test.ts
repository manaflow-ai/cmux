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
//   - a chat on this Mac never asks for a copy;
//   - an attach reply of the session before a recreation is dropped for the session listed now, an
//     attach a reconnect took over leaves the copy to it, and a redraw's attach refused as down
//     draws the Mac's copy;
//   - a late record of an attach that failed stays off the offline copy, and every attach reply
//     is held to the row as it answers (a retry's too, and a createdAt earlier than the reply's);
//   - a recovery attach a reconnect took over changes nothing when it answers, a row that named
//     another session while the attach was out keeps none of its records, and an open that fails
//     before its attach leaves the copy offline;
//   - a copy that covers past its newest record keeps it under a page that starts right after it,
//     and a row that names another session while the attach or the reads after it are out has
//     the chat read again, with none of the session before's live records.
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
  /// The slash commands the session's newest command list names, when it has one (or, as a
  /// function, the list a read back from `beforeSeq` finds).
  commandNames: string[] | ((beforeSeq: number) => string[]) | undefined;
  /// The row's status while the machine is up, when not idle.
  status: string | undefined;
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
  /// Runs once when the next attach is asked, before it is answered.
  onAttach: (() => void) | undefined;
  /// The next attach answered as the session before a recreation (its `createdAt` and records).
  staleReply: { createdAt: number; events: ReturnType<typeof record>[] } | undefined;
  /// Runs once at the first request after an attach was answered (the reads that follow it).
  afterAttach: (() => void) | undefined;
  private attachAnswered = false;
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
    const commandRead =
      message.method === "_acpmux/events" &&
      Array.isArray(message.params?.kinds) &&
      (message.params.kinds as unknown[]).includes("available_commands_update");
    if (this.hold.has(message.method) || (this.holdCommandReads && commandRead)) this.held.push(message);
    else queueMicrotask(() => this.answer(message));
  }

  /// The reads back for the command list wait, unanswered, until `release` answers them.
  holdCommandReads = false;
  /// Requests of these methods wait, unanswered, until `release` answers them.
  readonly hold = new Set<string>();
  private held: Message[] = [];

  /// Answers only the oldest request of `method` held so far.
  releaseFirst(method: string): void {
    const at = this.held.findIndex((message) => message.method === method);
    if (at < 0) return;
    const [message] = this.held.splice(at, 1);
    this.answer(message!);
  }

  /// Answers only the newest request of `method` held so far.
  releaseLast(method: string): void {
    let at = this.held.length - 1;
    while (at >= 0 && this.held[at]!.method !== method) at -= 1;
    if (at < 0) return;
    const [message] = this.held.splice(at, 1);
    this.answer(message!);
  }

  /// Answers the requests of `method` held so far, in the order they were asked.
  release(method: string): void {
    const now = this.held.filter((message) => message.method === method);
    this.held = this.held.filter((message) => message.method !== method);
    for (const message of now) this.answer(message);
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
      status: this.down ? "unreachable" : (this.status ?? "idle"),
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
    if (message.method === "_acpmux/attach") this.attachAnswered = true;
    else if (this.attachAnswered && this.afterAttach) {
      const hook = this.afterAttach;
      this.afterAttach = undefined;
      hook();
    }
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
      const hook = this.onAttach;
      this.onAttach = undefined;
      hook?.();
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
    if (message.method === "_acpmux/attach" && this.staleReply) {
      const { createdAt, events } = this.staleReply;
      this.staleReply = undefined;
      return this.reply(message.id, {
        result: { session: { ...this.summary(), createdAt }, events, hasMore: false, lastSeq: events.at(-1)?.seq ?? 0 },
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
    if (
      message.method === "_acpmux/events" &&
      Array.isArray(p.kinds) &&
      p.kinds.includes("available_commands_update")
    ) {
      // The read back for the session's newest command list: one record naming `commandNames`.
      const seq = this.log.at(-1)?.seq ?? 0;
      const names =
        typeof this.commandNames === "function" ? this.commandNames(Number(p.beforeSeq)) : this.commandNames;
      const events = names
        ? [
            {
              sessionId: SESSION,
              seq,
              at: START,
              dir: "in",
              kind: "available_commands_update",
              msg: {
                method: "session/update",
                params: {
                  sessionId: SESSION,
                  update: {
                    sessionUpdate: "available_commands_update",
                    availableCommands: names.map((name) => ({ name, description: name })),
                  },
                },
              },
            },
          ]
        : [];
      return this.reply(message.id, { result: { events, hasMore: false, lastSeq: seq } });
    }
    if (message.method === "_acpmux/events" && p.beforeSeq !== undefined) {
      // An older page: the newest records before `beforeSeq`, as many as the limit takes.
      const before = Number(p.beforeSeq);
      const older = this.log.filter((r) => r.seq < before);
      const events = older.slice(-Number(p.limit ?? 400));
      return this.reply(message.id, {
        result: { events, hasMore: events.length < older.length, lastSeq: this.log.at(-1)?.seq ?? 0 },
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

test("an attach reply of the session before a recreation is dropped and the session listed now read", async () => {
  const daemon = new Daemon();
  daemon.down = false;
  daemon.log = turn(1, 3, "new");
  // The row names session 200 before the attach is answered, and the answer is of session 100.
  daemon.recreatedDuringAttach = 200;
  daemon.staleReply = { createdAt: 100, events: turn(1, 5, "old") };
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  const shown = text(tab.last());
  expect(shown).toContain("new 3.");
  expect(shown).not.toContain("old ");
  expect(daemon.asked.filter((m) => m.method === "_acpmux/attach").length).toBe(2);
});

test("a select's attach that a reconnect took over leaves the copy on screen when it fails", async () => {
  const daemon = new Daemon();
  daemon.other = true;
  daemon.copy = { events: turn(1, 4, "kept"), generation: 100, lastSeq: 4 };
  const tab = open(daemon, undefined, OTHER);
  const client = await tab.client;
  live.push(client);
  await flush();
  // A reconnect starts its own attach of the copy while the select's is out (`open` moves the
  // token on), and the select's then fails for another reason than the machine being down.
  daemon.onAttach = () => {
    (client as unknown as { copyAttaches: number }).copyAttaches += 1;
  };
  daemon.failAttach = 1;
  await client.select(SESSION).catch(() => undefined);
  await flush();
  expect(text(tab.last())).toContain("kept 4.");
  expect(tab.last()!.peerCopy).toBeDefined();
});

test("a redraw's attach refused as down draws the new machine's copy, offline", async () => {
  const daemon = new Daemon();
  daemon.copy = { events: turn(1, 4, "old"), generation: 100, lastSeq: 4 };
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  expect(tab.last()!.peerCopy?.offline).toBe(true);
  // The session moves to cloud-vm, back: the Mac has no copy of it when the redraw reads, then
  // the attach that follows is refused as down, by which time the Mac has one.
  daemon.peer = "cloud-vm";
  daemon.copy = undefined;
  daemon.down = false;
  daemon.refuseAttach = 1;
  daemon.onAttach = () => {
    daemon.copy = { events: turn(1, 3, "vm"), generation: 100, lastSeq: 3 };
  };
  daemon.announce();
  await flush();
  const shown = text(tab.last());
  expect(shown).toContain("vm 3.");
  expect(shown).not.toContain("old ");
  expect(tab.last()!.peerCopy?.offline).toBe(true);
});

test("an attach reply that comes after the session moved to another machine is read again from that one", async () => {
  const daemon = new Daemon();
  daemon.down = false;
  daemon.log = turn(1, 3, "vm");
  // The row names cloud-vm before the attach is answered; the answer is huge-blue's journal.
  daemon.onAttach = () => {
    daemon.peer = "cloud-vm";
    daemon.announce();
  };
  daemon.staleReply = { createdAt: 100, events: turn(1, 5, "old") };
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  const shown = text(tab.last());
  expect(shown).toContain("vm 3.");
  expect(shown).not.toContain("old ");
  expect(daemon.asked.filter((m) => m.method === "_acpmux/attach").length).toBe(2);
});

test("a session recreated and back at once takes the old copy off screen before it is read", async () => {
  const daemon = new Daemon();
  daemon.copy = { events: turn(1, 4, "old"), generation: 100, lastSeq: 4 };
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  expect(tab.last()!.peerCopy?.offline).toBe(true);
  // While the attach after the row is out, the old session's rows are no longer drawn.
  let shownDuringAttach = "";
  daemon.onAttach = () => {
    shownDuringAttach = text(tab.last());
  };
  daemon.createdAt = 200;
  daemon.copy = undefined;
  daemon.log = turn(1, 3, "new");
  daemon.comeBack();
  await flush();
  expect(shownDuringAttach).not.toContain("old ");
  const shown = text(tab.last());
  expect(shown).toContain("new 3.");
  expect(shown).not.toContain("old ");
});

test("a record that comes after the attach failed is not shown past the offline copy", async () => {
  const daemon = new Daemon();
  daemon.copy = { events: turn(1, 4, "kept"), generation: 100, lastSeq: 4 };
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  expect(tab.last()!.peerCopy?.offline).toBe(true);
  // A live record of the refused attach, late: the copy shows what the Mac confirmed, no more.
  const late = record(5, "late 5. ");
  daemon.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: late }) });
  await flush();
  const shown = text(tab.last());
  expect(shown).toContain("kept 4.");
  expect(shown).not.toContain("late 5.");
});

test("an attach retried for a recreated session is held to the row again when it answers", async () => {
  const daemon = new Daemon();
  daemon.down = false;
  daemon.log = turn(1, 3, "new");
  // The row changes twice while the attaches are out (100, then 200, then 300), and each reply is
  // of the session before: the retry's reply of 200 is not taken for the 300 listed by then.
  daemon.staleReply = { createdAt: 100, events: turn(1, 5, "old") };
  daemon.onAttach = () => {
    daemon.createdAt = 200;
    daemon.announce();
    daemon.onAttach = () => {
      daemon.createdAt = 300;
      daemon.announce();
      daemon.staleReply = { createdAt: 200, events: turn(1, 4, "mid") };
    };
  };
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  const shown = text(tab.last());
  expect(shown).toContain("new 3.");
  expect(shown).not.toContain("mid ");
  expect(shown).not.toContain("old ");
});

test("a session recreated with an earlier createdAt is not taken for the one before", async () => {
  const daemon = new Daemon();
  daemon.down = false;
  daemon.createdAt = 200;
  daemon.log = turn(1, 3, "new");
  // A machine back on an earlier clock recreates the session as 150 while the attach is out.
  daemon.recreatedDuringAttach = 150;
  daemon.staleReply = { createdAt: 200, events: turn(1, 5, "old") };
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  const shown = text(tab.last());
  expect(shown).toContain("new 3.");
  expect(shown).not.toContain("old ");
});

test("a recovery attach that a reconnect took over changes nothing when it answers", async () => {
  const daemon = new Daemon();
  daemon.copy = { events: turn(1, 4, "kept"), generation: 100, lastSeq: 4 };
  const tab = open(daemon);
  const client = await tab.client;
  live.push(client);
  await flush();
  expect(tab.last()!.peerCopy?.offline).toBe(true);
  // The machine is back and the copy's attach goes out; a reconnect's attach starts meanwhile
  // (`open` moves the token on), so the first one's reply is not the chat's to draw.
  daemon.log = turn(1, 6, "stale");
  daemon.onAttach = () => {
    (client as unknown as { copyAttaches: number }).copyAttaches += 1;
  };
  daemon.comeBack();
  await flush();
  const shown = text(tab.last());
  expect(shown).toContain("kept 4.");
  expect(shown).not.toContain("stale 6.");
  expect(tab.last()!.peerCopy).toBeDefined();
});

test("a row that named another session while the attach was out, then this one again, keeps none of the other's records", async () => {
  const daemon = new Daemon();
  daemon.down = false;
  daemon.copy = { events: turn(1, 4, "old"), generation: 100, lastSeq: 4 };
  daemon.log = turn(1, 3, "a");
  // While the attach is out the row names session 200, which streams a record, then 100 again.
  daemon.onAttach = () => {
    daemon.createdAt = 200;
    daemon.announce();
    daemon.onmessage?.({
      data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: record(5, "bee 5. ") }),
    });
    daemon.createdAt = 100;
    daemon.announce();
  };
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  const shown = text(tab.last());
  expect(shown).toContain("a 3.");
  expect(shown).not.toContain("bee 5.");
});

test("an open that fails before its attach leaves the copy offline with no attach out", async () => {
  const daemon = new Daemon();
  daemon.copy = { events: turn(1, 4, "kept"), generation: 100, lastSeq: 4 };
  const tab = open(daemon);
  const client = await tab.client;
  live.push(client);
  await flush();
  // A reconnect whose socket never opens.
  const internals = client as unknown as {
    openSocket: () => unknown;
    open: () => Promise<void>;
    peerCopy?: { offline: boolean; attaching: boolean };
  };
  internals.openSocket = () => {
    const failing = {
      readyState: 0,
      onopen: null as (() => void) | null,
      onerror: null as (() => void) | null,
      onclose: null as (() => void) | null,
      onmessage: null,
      send() {},
      close() {
        failing.readyState = 3;
      },
    };
    queueMicrotask(() => failing.onerror?.());
    return failing;
  };
  await internals.open().catch(() => undefined);
  await flush();
  expect(internals.peerCopy?.attaching).toBe(false);
  expect(internals.peerCopy?.offline).toBe(true);
});

test("a copy that covers past its newest record keeps it under a page that starts right after it", async () => {
  const daemon = new Daemon();
  daemon.down = false;
  // The copy covers 1..6; 5 and 6 are of kinds a page does not ask for, so it holds 1..4.
  daemon.copy = { events: turn(1, 4, "kept"), generation: 100, lastSeq: 6 };
  daemon.log = turn(1, 9, "new");
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  // The attach page holds 7..9: it continues the copy, which stays above it.
  const shown = text(tab.last());
  expect(shown).toContain("kept 1.");
  expect(shown).toContain("new 9.");
});

test("a row recreated while the attach is out keeps none of the session before's live records", async () => {
  const daemon = new Daemon();
  daemon.down = false;
  daemon.log = turn(1, 3, "b");
  // The session before streams a record, then the row names session 200, which the reply is of.
  daemon.onAttach = () => {
    daemon.onmessage?.({
      data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: record(4, "olda 4. ") }),
    });
    daemon.createdAt = 200;
    daemon.announce();
  };
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  const shown = text(tab.last());
  expect(shown).toContain("b 3.");
  expect(shown).not.toContain("olda 4.");
});

test("a row recreated while the reads after the attach are out has the chat read again", async () => {
  const daemon = new Daemon();
  daemon.down = false;
  // More than the page holds: the attach then reads back the turn's opener (a read after it), and
  // the row changes while that read is out.
  daemon.log = turn(1, 4, "old");
  daemon.afterAttach = () => {
    daemon.createdAt = 200;
    daemon.log = turn(1, 2, "fresh");
    daemon.announce();
  };
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  const shown = text(tab.last());
  expect(shown).toContain("fresh 2.");
  expect(shown).not.toContain("old ");
});

test("a record a refused attach sent past the copy holds back no record once the machine is read", async () => {
  const daemon = new Daemon();
  daemon.copy = { events: turn(1, 4, "kept"), generation: 100, lastSeq: 4 };
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  daemon.log = turn(1, 4, "kept");
  // Seq 6 comes live, then the attach is refused: the copy (through 4) stays, offline.
  daemon.beforeAttach = [record(6, "stray 6. ")];
  daemon.refuseAttach = 1;
  daemon.comeBack();
  await flush();
  expect(tab.last()!.peerCopy?.offline).toBe(true);
  // Back for good: its page (2..4) joins the copy, and the chat reads on from 4, not from 6.
  daemon.comeBack();
  await flush();
  expect(tab.last()!.peerCopy).toBeUndefined();
  for (const seq of [5, 6])
    daemon.onmessage?.({
      data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: record(seq, `after ${seq}. `) }),
    });
  await flush();
  const shown = text(tab.last());
  expect(shown).toContain("after 5.");
  expect(shown).toContain("after 6.");
  expect(shown).not.toContain("stray");
});

test("a tail kept of rows not proven of a session names none, so it never joins the session the row moved to", async () => {
  const daemon = new Daemon();
  daemon.down = false;
  daemon.other = true;
  daemon.peer = undefined;
  // An acpmux whose row names no generation: the rows on screen are proven of no session.
  daemon.createdAt = undefined as unknown as number;
  daemon.log = turn(1, 5, "here");
  const tab = open(daemon);
  const client = await tab.client;
  live.push(client);
  await flush();
  expect(text(tab.last())).toContain("here 5.");
  // A later row names a machine and a session; the chat's summary takes it, its rows do not.
  daemon.peer = "huge-blue";
  daemon.createdAt = 300;
  daemon.down = true;
  daemon.announce();
  await flush();
  await client.select(OTHER);
  await flush();
  const kept = keptTail(SESSION);
  expect(kept).toBeDefined();
  expect(kept!.summary?.peer).toBeUndefined();
  expect(kept!.summary?.createdAt).toBeUndefined();
  // That machine's chat, read again, does not continue this Mac's rows.
  daemon.down = false;
  daemon.log = turn(1, 7, "vm");
  await client.select(SESSION);
  await flush();
  const shown = text(tab.last());
  expect(shown).toContain("vm 7.");
  expect(shown).not.toContain("here ");
});

test("a machine back while an attach with no copy to fall back on is out is read once that attach fails", async () => {
  const daemon = new Daemon();
  daemon.other = true;
  daemon.log = turn(1, 3, "back");
  const tab = open(daemon, undefined, OTHER);
  const client = await tab.client;
  live.push(client);
  await flush();
  // The Mac has no copy; the row says the machine is back while the attach is out, which it refuses.
  daemon.refuseAttach = 1;
  daemon.onAttach = () => daemon.comeBack();
  await client.select(SESSION).catch(() => undefined);
  await flush();
  expect(text(tab.last())).toContain("back 3.");
});

test("an attach that fails after the row named another session keeps none of that one's records", async () => {
  const daemon = new Daemon();
  // The copy covers through 6 but holds 1..4 (5 and 6 are of kinds a page does not ask for).
  daemon.copy = { events: turn(1, 4, "kept"), generation: 100, lastSeq: 6 };
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  expect(tab.last()!.peerCopy?.offline).toBe(true);
  // While the copy's attach is out the row names session B, B streams seq 5, the row names A
  // again, and the machine is down when the attach is answered.
  daemon.onAttach = () => {
    daemon.down = true;
    daemon.createdAt = 200;
    daemon.announce();
    daemon.onmessage?.({
      data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: record(5, "bee 5. ") }),
    });
    daemon.createdAt = 100;
    daemon.announce();
  };
  daemon.comeBack();
  await flush();
  const shown = text(tab.last());
  expect(tab.last()!.peerCopy?.offline).toBe(true);
  expect(shown).toContain("kept 4.");
  expect(shown).not.toContain("bee 5.");
});

test("an attach of a chat already left never takes the watch of the attach out", async () => {
  const daemon = new Daemon();
  daemon.down = false;
  daemon.other = true;
  daemon.log = turn(1, 3, "a");
  const tab = open(daemon);
  const client = await tab.client;
  live.push(client);
  await flush();
  expect(text(tab.last())).toContain("a 3.");
  // Leaving for the other chat waits on its detach of this one; back here before it answers.
  daemon.hold.add("_acpmux/detach");
  const toOther = client.select(OTHER).catch(() => undefined);
  await flush();
  daemon.hold.delete("_acpmux/detach");
  daemon.hold.add("_acpmux/attach");
  const back = client.select(SESSION).catch(() => undefined);
  await flush();
  // The select left goes on now: its attach is of a chat no longer selected.
  daemon.release("_acpmux/detach");
  await flush();
  // While this chat's attach is out its row names session 200, which streams seq 4, then 100 again.
  daemon.createdAt = 200;
  daemon.announce();
  daemon.onmessage?.({
    data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: record(4, "bee 4. ") }),
  });
  daemon.createdAt = 100;
  daemon.announce();
  daemon.hold.delete("_acpmux/attach");
  daemon.release("_acpmux/attach");
  await flush();
  await toOther;
  await back;
  const shown = text(tab.last());
  expect(shown).toContain("a 3.");
  expect(shown).not.toContain("bee 4.");
});

test("a chat read ahead while its row named another session is not kept", async () => {
  const daemon = new Daemon();
  daemon.down = false;
  daemon.other = true;
  daemon.log = turn(1, 5, "before");
  const tab = open(daemon, undefined, OTHER);
  const client = await tab.client;
  live.push(client);
  await flush();
  resetKeptTailsForTests();
  daemon.hold.add("_acpmux/events");
  client.prefetch(SESSION);
  await flush();
  // The machine recreated the session while the read was out.
  daemon.createdAt = 200;
  daemon.announce();
  await flush();
  daemon.hold.delete("_acpmux/events");
  daemon.release("_acpmux/events");
  await flush();
  expect(keptTail(SESSION)).toBeUndefined();
});

test("an attached chat whose machine recreates the session reads the new one instead of keeping the old rows", async () => {
  const daemon = new Daemon();
  daemon.down = false;
  daemon.log = turn(1, 5, "old");
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  expect(text(tab.last())).toContain("old 5.");
  // Nothing is out: the machine recreates the session, and its row says so.
  daemon.createdAt = 200;
  daemon.log = turn(1, 3, "new");
  daemon.announce();
  await flush();
  const shown = text(tab.last());
  expect(shown).toContain("new 3.");
  expect(shown).not.toContain("old ");
});

test("an attached chat whose session moves to another machine reads it from that machine", async () => {
  const daemon = new Daemon();
  daemon.down = false;
  daemon.log = turn(1, 5, "here");
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  expect(text(tab.last())).toContain("here 5.");
  daemon.peer = "cloud-vm";
  daemon.log = turn(1, 2, "vm");
  daemon.announce();
  await flush();
  const shown = text(tab.last());
  expect(shown).toContain("vm 2.");
  expect(shown).not.toContain("here ");
});

test("an attached chat whose row changes only its status keeps its rows and is not read again", async () => {
  const daemon = new Daemon();
  daemon.down = false;
  daemon.log = turn(1, 5, "same");
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  const attaches = daemon.asked.filter((message) => message.method === "_acpmux/attach").length;
  // The chat starts a turn and ends it: the row changes its status and when it was updated.
  daemon.status = "running";
  daemon.announce();
  await flush();
  daemon.status = undefined;
  daemon.announce();
  await flush();
  expect(daemon.asked.filter((message) => message.method === "_acpmux/attach").length).toBe(attaches);
  expect(text(tab.last())).toContain("same 5.");
});

test("an attached chat whose row names another session and then this one again ends on this one, read a bounded number of times", async () => {
  const daemon = new Daemon();
  daemon.down = false;
  daemon.log = turn(1, 5, "first");
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  const attaches = () => daemon.asked.filter((message) => message.method === "_acpmux/attach").length;
  const before = attaches();
  // A row of another session, then a late one of this session again, back to back.
  daemon.createdAt = 200;
  daemon.announce();
  daemon.createdAt = 100;
  daemon.announce();
  await flush();
  expect(text(tab.last())).toContain("first 5.");
  expect(attaches() - before).toBeLessThanOrEqual(3);
});

test("an older page read of the session before it was recreated is not drawn above the new one", async () => {
  const daemon = new Daemon();
  daemon.down = false;
  daemon.log = turn(1, 8, "old");
  const tab = open(daemon);
  const client = await tab.client;
  live.push(client);
  await flush();
  // The attach drew the newest page (6 to 8); the reader scrolls up and the older page is held.
  expect(text(tab.last())).toContain("old 8.");
  daemon.hold.add("_acpmux/events");
  const older = client.loadOlder().catch(() => undefined);
  await flush();
  // The machine recreates the session while that read is out, and the new one is attached.
  daemon.createdAt = 200;
  daemon.log = turn(1, 2, "new");
  daemon.announce();
  await flush();
  expect(text(tab.last())).toContain("new 2.");
  // The old session's older page lands now.
  daemon.log = turn(1, 8, "old");
  daemon.hold.delete("_acpmux/events");
  daemon.release("_acpmux/events");
  await older;
  await flush();
  const shown = text(tab.last());
  expect(shown).toContain("new 2.");
  expect(shown).not.toContain("old ");
});

test("an attach retried because the row moved on while its reads were out shows the command list of the session it ends on", async () => {
  const daemon = new Daemon();
  daemon.down = false;
  daemon.log = turn(1, 5, "first");
  // Each read back finds the list as of where it starts, so whose list is shown can be told.
  daemon.commandNames = (beforeSeq) => [`through-${beforeSeq - 1}`];
  daemon.holdCommandReads = true;
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  expect(text(tab.last())).toContain("first 5.");
  // The machine recreates the session; while the new one's attach reads what it draws with, it
  // recreates it once more.
  daemon.onAttach = () => {
    daemon.afterAttach = () => {
      daemon.createdAt = 300;
      daemon.log = turn(1, 3, "third");
      daemon.announce();
    };
  };
  daemon.createdAt = 200;
  daemon.log = turn(1, 4, "second");
  daemon.announce();
  await flush();
  expect(text(tab.last())).toContain("third 3.");
  expect(text(tab.last())).not.toContain("second 4.");
  // The list reads back answer newest first: the session it ends on, then any asked before it.
  daemon.holdCommandReads = false;
  daemon.releaseLast("_acpmux/events");
  await flush();
  daemon.releaseLast("_acpmux/events");
  daemon.release("_acpmux/events");
  await flush();
  const names = (tab.last()!.commands ?? []).map((command) => command.name);
  expect(names).toEqual(["through-3"]);
});

test("the command list read of the session before it was recreated is not shown for the new one", async () => {
  const daemon = new Daemon();
  daemon.down = false;
  daemon.log = turn(1, 5, "old");
  daemon.commandNames = ["old-command"];
  // The command list's read back waits, for the session before and for the new one.
  daemon.holdCommandReads = true;
  const tab = open(daemon);
  live.push(await tab.client);
  await flush();
  expect(text(tab.last())).toContain("old 5.");
  daemon.createdAt = 200;
  daemon.log = turn(1, 3, "new");
  daemon.announce();
  await flush();
  expect(text(tab.last())).toContain("new 3.");
  // The old session's list answers first.
  daemon.holdCommandReads = false;
  daemon.releaseFirst("_acpmux/events");
  await flush();
  const names = () => (tab.last()!.commands ?? []).map((command) => command.name);
  expect(names()).not.toContain("old-command");
  daemon.commandNames = ["new-command"];
  daemon.release("_acpmux/events");
  await flush();
  expect(names()).toContain("new-command");
});
