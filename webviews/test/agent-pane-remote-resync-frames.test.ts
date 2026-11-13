// l10n-allow-file: test fixture prompts, replies and machine names, not shipped UI.
//
// A chat whose agent runs on another machine, open with rows on screen, resyncs without drawing
// its transcript anew (Leo, 2026-11-07: "sometimes the entire sort of chat viewing area that I'm
// seeing, it just, like, flickers for a brief second ... It shouldn't need to completely
// re-render from scratch."). For each resync (the socket reconnecting, a seq gap, a list reread,
// the machine dropping and coming back, its row listed again, the chat picked again):
//
//   - no full transcript replace is counted (direct.ts `noteReplace`);
//   - no snapshot in between draws an empty transcript, or leaves out a row shown before;
//   - every row shown before that is still shown unchanged is the same object, so the pane keeps
//     its node;
//   - a seq gap reads only the records after the pane's newest, never the whole log.
//
// And the counter itself: a session the machine recreated is another transcript, counted once; a
// chat that leaves the list for good still says so once the hold ends.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { resetKeptTailsForTests } from "../src/agent-session/acpmux/tailCache";
import type { AcpmuxRow, AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { settleReact } from "./support/domTeardown";

const START = Date.UTC(2026, 10, 7, 7, 0, 0);
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

const SESSION = "remote-chat";

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
/// Four turns: a prompt, then three chunks of its reply.
const LOG = Array.from({ length: 4 }, (_, turn) => [
  prompt(turn * 4 + 1),
  ...[2, 3, 4].map((part) => reply(turn * 4 + part, `turn ${turn} part ${part}. `)),
]).flat();

/// The Mac's acpmux, with the chat on peer huge-blue: `down` refuses its attach as acpmux does for
/// a machine that does not answer, and lists the row stale.
class Daemon {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: ((event?: { code: number }) => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  down = false;
  /// The machine answers an attach but not the read of the records after it.
  readsDown = false;
  /// Attaches wait here until let go, while the row changes under them.
  heldAttaches?: (() => void)[];
  /// Reads of the records after a seq wait here, each answered or failed when let go.
  heldReads?: { afterSeq: number; answer: () => void; fail: () => void }[];
  /// The machine's log stays the same across sockets (a reconnect reaches the same log).
  keepLog = false;
  createdAt = 100;
  listed = true;
  log = LOG.slice();
  /// What `_acpmux/peer_snapshot` answers, when not the log's newest page: its records and how far
  /// it covers (past its newest record when the newest seqs are of kinds a page does not ask for).
  copy?: { events: Daemon["log"]; lastSeq: number };
  readonly asked: Message[] = [];

  constructor() {
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.();
    });
  }

  summary() {
    return {
      sessionId: SESSION,
      name: "huge-blue/lane",
      cwd: "/home/dev/project",
      title: "Lane on huge-blue",
      harness: "claude",
      status: this.down ? "unreachable" : "idle",
      turnCount: 4,
      updatedAt: START,
      createdAt: this.createdAt,
      peer: "huge-blue",
      ...(this.down ? { stale: true } : {}),
    };
  }

  notify(method: string, params: Record<string, unknown>): void {
    this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method, params }) });
  }

  /// The row as it is now, as acpmux announces a change.
  announce(): void {
    this.notify("_acpmux/session_changed", { sessionId: SESSION, kind: "status", session: this.summary() });
  }

  /// The row left the list (a peer's list read anew without it).
  purge(): void {
    this.notify("_acpmux/session_changed", { kind: "purged", session: { sessionId: SESSION } });
  }

  /// The socket to acpmux dropped.
  drop(): void {
    this.readyState = 3;
    this.onclose?.({ code: 1006 });
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
    if (message.method === "_acpmux/watch") return result({ sessions: this.listed ? [this.summary()] : [] });
    if (message.method === "_acpmux/attach") {
      if (this.heldAttaches) return void this.heldAttaches.push(() => this.answer(message));
      if (this.down)
        return this.onmessage?.({
          data: JSON.stringify({
            jsonrpc: "2.0",
            id: message.id,
            error: { code: -32603, message: "peer_unreachable: huge-blue", data: { reason: "peer_unreachable" } },
          }),
        });
      // The newest page only, as a remote attach is bounded.
      const page = this.log.slice(-6);
      return result({ session: this.summary(), events: page, hasMore: page.length < this.log.length, lastSeq: last });
    }
    if (message.method === "_acpmux/peer_snapshot")
      return result({
        peer: "huge-blue",
        sessionId: SESSION,
        stale: true,
        hasMore: this.copy ? false : this.log.length > 6,
        capturedAt: START,
        summary: this.summary(),
        events: this.copy?.events ?? this.log.slice(-6),
        generation: this.createdAt,
        lastSeq: this.copy?.lastSeq ?? last,
      });
    if (message.method === "_acpmux/events" && p.beforeSeq !== undefined) {
      const older = this.log.filter((event) => event.seq < Number(p.beforeSeq));
      const events = older.slice(-Number(p.limit ?? 400));
      return result({ events, hasMore: events.length < older.length, lastSeq: last });
    }
    if (message.method === "_acpmux/events") {
      if (this.heldReads) {
        const read = { ...message, params: { ...p } };
        this.heldReads.push({
          afterSeq: Number(p.afterSeq ?? 0),
          answer: () => {
            const events = this.log.filter((event) => event.seq > Number(p.afterSeq ?? 0));
            this.onmessage?.({
              data: JSON.stringify({ jsonrpc: "2.0", id: read.id, result: { events, hasMore: false, lastSeq: last } }),
            });
          },
          fail: () =>
            this.onmessage?.({
              data: JSON.stringify({
                jsonrpc: "2.0",
                id: read.id,
                error: { code: -32603, message: "peer_unreachable: huge-blue", data: { reason: "peer_unreachable" } },
              }),
            }),
        });
        return;
      }
      if (this.readsDown)
        return this.onmessage?.({
          data: JSON.stringify({
            jsonrpc: "2.0",
            id: message.id,
            error: { code: -32603, message: "peer_unreachable: huge-blue", data: { reason: "peer_unreachable" } },
          }),
        });
      const events = this.log.filter((event) => event.seq > Number(p.afterSeq ?? 0));
      return result({ events, hasMore: false, lastSeq: last });
    }
    result({});
  }
}

const flush = async (passes = 30) => {
  for (let pass = 0; pass < passes; pass += 1) await new Promise((resolve) => setTimeout(resolve, 0));
};
/// Yields until `ready()` holds; fails after `ms` with what it waited for.
async function until(ready: () => boolean, what: string, ms = 2_000) {
  const deadline = performance.now() + ms;
  while (!ready()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}

let live: AcpmuxDirectClient[] = [];
afterEach(() => {
  for (const client of live) client.close();
  live = [];
  resetKeptTailsForTests();
});

/// The tab's chat open with its rows on screen; each new socket is a new `Daemon` on the same log.
/// `down`: its machine is down from the first socket, so the rows are the Mac's copy of it.
async function openChat(log?: Daemon["log"], down = false, copy?: Daemon["copy"]) {
  resetKeptTailsForTests();
  const daemons: Daemon[] = [];
  let state:
    | Pick<Daemon, "down" | "createdAt" | "listed" | "heldAttaches" | "heldReads" | "keepLog" | "log" | "copy">
    | undefined;
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
      // A reconnect reaches the same machine, as it is now.
      if (state)
        Object.assign(daemon, {
          down: state.down,
          createdAt: state.createdAt,
          listed: state.listed,
          heldAttaches: state.heldAttaches,
          heldReads: state.heldReads,
          keepLog: state.keepLog,
          copy: state.copy,
          ...(state.keepLog ? { log: state.log } : {}),
        });
      // The machine's log, when the test names one: every socket reaches the same machine.
      else {
        if (log) daemon.log = log.slice();
        daemon.down = down;
        daemon.copy = copy;
      }
      daemons.push(daemon);
      state = daemon;
      return daemon as unknown as WebSocket;
    },
  );
  live.push(client);
  await flush();
  const shown = drawn.at(-1)!;
  expect(shown.sessionId).toBe(SESSION);
  expect(shown.rows.length).toBeGreaterThan(0);
  const daemon = () => daemons.at(-1)!;
  /// The socket drops; answers once the new one asked for the chat again.
  const reconnect = async () => {
    const sockets = daemons.length;
    daemon().drop();
    await until(
      () => daemons.length > sockets && daemon().asked.some((message) => message.method === "_acpmux/attach"),
      "the reconnect's attach",
    );
    await flush();
  };
  return { client, drawn, daemon, reconnect, shown, from: drawn.length };
}

/// What the snapshots after `from` did to the rows `shown` drew.
function frames(drawn: AcpmuxSnapshot[], from: number, shown: AcpmuxSnapshot) {
  const after = drawn.slice(from);
  const empty = after.filter((snapshot) => snapshot.rows.length === 0).length;
  const before = new Map<string, AcpmuxRow>(shown.rows.map((row) => [row.id, row]));
  const last = drawn.at(-1)!;
  // Rows drawn again unchanged but as new objects: a row whose content moved (a reply that grew) is
  // a new object by design.
  const rebuilt = last.rows
    .filter((row) => {
      const old = before.get(row.id);
      return old !== undefined && old !== row && JSON.stringify(old) === JSON.stringify(row);
    })
    .map((row) => row.id);
  // Rows shown before that some snapshot in between left out (a row that went and came back).
  const left = new Set<string>();
  for (const snapshot of after) {
    const ids = new Set(snapshot.rows.map((row) => row.id));
    for (const id of before.keys()) if (!ids.has(id)) left.add(id);
  }
  return { empty, rebuilt, left: [...left], ids: last.rows.map((row) => row.id) };
}

const resyncs: [string, (chat: Awaited<ReturnType<typeof openChat>>) => Promise<void>][] = [
  ["the socket to acpmux reconnects", async ({ reconnect }) => reconnect()],
  [
    "a seq gap (the peer's link dropped records)",
    async ({ daemon }) => {
      daemon().notify("_acpmux/lagged", { sessionIds: [SESSION], dropped: 3 });
      await flush();
    },
  ],
  [
    "the chat list is read again after a watch lag",
    async ({ daemon }) => {
      daemon().notify("_acpmux/lagged", { watch: true, dropped: 2 });
      await flush();
    },
  ],
  [
    "the machine drops and comes back",
    async ({ daemon, reconnect }) => {
      daemon().down = true;
      daemon().announce();
      await flush();
      await reconnect();
      daemon().down = false;
      daemon().announce();
      await flush();
    },
  ],
  [
    "the chat's row leaves the list and is listed again",
    async ({ daemon }) => {
      daemon().purge();
      await flush(4);
      daemon().announce();
      await flush();
    },
  ],
  [
    "the chat is picked again",
    async ({ client }) => {
      await client.select(SESSION);
      await flush();
    },
  ],
];

for (const [name, resync] of resyncs)
  test(`${name}: no full transcript replace, no empty frame, the same row objects`, async () => {
    const chat = await openChat();
    await resync(chat);
    const { empty, rebuilt, left, ids } = frames(chat.drawn, chat.from, chat.shown);
    if (process.env.RESYNC_TABLE)
      console.log(
        `| ${name} | ${chat.client.transcriptReplaces?.(SESSION) ?? "-"} | ${empty} | ${left.length} | ${rebuilt.length} |`,
      );
    expect(chat.drawn.at(-1)!.sessionId).toBe(SESSION);
    expect(empty).toBe(0);
    expect(left).toEqual([]);
    expect(rebuilt).toEqual([]);
    for (const row of chat.shown.rows) expect(ids).toContain(row.id);
    expect(chat.client.transcriptReplaces(SESSION)).toBe(0);
  });

test("a seq gap reads the records after the pane's newest, not the whole log", async () => {
  const chat = await openChat();
  const asked = chat.daemon().asked.length;
  chat.daemon().log.push(reply(17, "late "), reply(18, "later "));
  chat.daemon().notify("_acpmux/lagged", { sessionIds: [SESSION], dropped: 2 });
  await flush();
  const reads = chat
    .daemon()
    .asked.slice(asked)
    .filter((message) => message.method === "_acpmux/events" && message.params?.beforeSeq === undefined);
  expect(reads.map((message) => message.params?.afterSeq)).toEqual([16]);
  expect(JSON.stringify(chat.drawn.at(-1)!.rows)).toContain("later ");
  expect(frames(chat.drawn, chat.from, chat.shown).rebuilt).toEqual([]);
});

test("a session the machine recreated is another transcript: one full replace is counted", async () => {
  const chat = await openChat();
  chat.daemon().createdAt = 200;
  chat.daemon().announce();
  await flush();
  expect(chat.client.transcriptReplaces(SESSION)).toBe(1);
});

test("a chat that leaves the list for good says so once the hold ends", async () => {
  const chat = await openChat();
  chat.daemon().listed = false;
  chat.daemon().purge();
  await flush(4);
  // Held: the chat stays drawn for the hold, never an empty frame.
  expect(chat.drawn.at(-1)!.rows.length).toBeGreaterThan(0);
  await until(() => chat.drawn.at(-1)?.missingSession === SESSION, "the chat said gone", 3_000);
  const last = chat.drawn.at(-1)!;
  expect(last.sessionId).toBeUndefined();
  expect(last.missingSession).toBe(SESSION);
  expect(last.rows).toEqual([]);
  // Gone, not resynced: that frame is the chat's one replace.
  expect(chat.client.transcriptReplaces(SESSION)).toBe(1);
});

test("a chat with older pages read keeps them when its row leaves the list and is listed again", async () => {
  const chat = await openChat();
  await chat.client.loadOlder();
  await flush();
  const shown = chat.drawn.at(-1)!;
  expect(shown.rows.length).toBeGreaterThan(chat.shown.rows.length);
  const from = chat.drawn.length;
  chat.daemon().purge();
  await flush(4);
  chat.daemon().announce();
  await flush();
  const { empty, rebuilt, left, ids } = frames(chat.drawn, from, shown);
  expect(empty).toBe(0);
  expect(left).toEqual([]);
  expect(rebuilt).toEqual([]);
  for (const row of shown.rows) expect(ids).toContain(row.id);
});

test("the machine back after records it missed draws no transcript with a hole in it", async () => {
  const chat = await openChat();
  chat.daemon().down = true;
  chat.daemon().announce();
  await flush();
  await chat.reconnect();
  // The machine ran on past one page while it was down: 17..24, of which the attach page holds 19..24.
  for (let seq = 17; seq <= 24; seq += 1) chat.daemon().log.push(reply(seq, `missed ${seq}. `));
  const from = chat.drawn.length;
  chat.daemon().down = false;
  chat.daemon().announce();
  await flush();
  for (const snapshot of chat.drawn.slice(from)) {
    const text = JSON.stringify(snapshot.rows);
    if (text.includes("missed 24.")) expect(text).toContain("missed 17.");
  }
  expect(JSON.stringify(chat.drawn.at(-1)!.rows)).toContain("missed 17.");
  expect(frames(chat.drawn, from, chat.shown).left).toEqual([]);
});

test("a gap read that fails keeps the hole to read: the machine's next answer fills it", async () => {
  const chat = await openChat();
  chat.daemon().down = true;
  chat.daemon().announce();
  await flush();
  await chat.reconnect();
  for (let seq = 17; seq <= 24; seq += 1) chat.daemon().log.push(reply(seq, `missed ${seq}. `));
  // Back for the attach (19..24), gone again before the records between it and the pane are read.
  const drawnFrom = chat.drawn.length;
  chat.daemon().readsDown = true;
  chat.daemon().down = false;
  chat.daemon().announce();
  await until(
    () => chat.daemon().asked.some((message) => message.method === "_acpmux/events" && message.params?.afterSeq === 16),
    "the gap read",
  );
  await flush();
  // Gone again with the page in and the hole not: no frame showed the page past the hole.
  for (const snapshot of chat.drawn.slice(drawnFrom)) {
    const text = JSON.stringify(snapshot.rows);
    if (text.includes("missed 24.")) expect(text).toContain("missed 17.");
  }
  chat.daemon().readsDown = false;
  const from = chat.daemon().asked.length;
  chat.daemon().down = true;
  chat.daemon().announce();
  await flush();
  chat.daemon().down = false;
  chat.daemon().announce();
  await until(() => JSON.stringify(chat.drawn.at(-1)?.rows).includes("missed 17."), "the hole read");
  const reads = chat
    .daemon()
    .asked.slice(from)
    .filter((message) => message.method === "_acpmux/events");
  expect(reads.map((message) => message.params?.afterSeq)).toContain(16);
  expect(JSON.stringify(chat.drawn.at(-1)!.rows)).toContain("missed 24.");
});

test("an attach retry that fails keeps the frame until the copy is drawn: no empty frame", async () => {
  const chat = await openChat();
  // The next socket's attach waits while the row names another session and then this one again.
  chat.daemon().heldAttaches = [];
  const sockets = chat.daemon();
  sockets.drop();
  await until(() => (chat.daemon().heldAttaches?.length ?? 0) > 0 && chat.daemon() !== sockets, "the held attach");
  const from = chat.drawn.length;
  const daemon = chat.daemon();
  daemon.createdAt = 200;
  daemon.announce();
  await flush();
  daemon.createdAt = 100;
  daemon.announce();
  await flush();
  // The reply strayed from the row, so the attach is retried; the machine is down for the retry.
  const held = daemon.heldAttaches ?? [];
  daemon.heldAttaches = undefined;
  for (const answer of held) answer();
  daemon.down = true;
  await until(() => daemon.asked.some((message) => message.method === "_acpmux/peer_snapshot"), "the Mac's copy read");
  await flush();
  expect(chat.drawn.slice(from).filter((snapshot) => snapshot.rows.length === 0)).toEqual([]);
  expect(chat.drawn.at(-1)!.rows.length).toBeGreaterThan(0);
});

test("a newer gap read that lands keeps an older one's hole to read when the older fails", async () => {
  const chat = await openChat();
  // The reconnect's attach waits while the machine runs on past one page: 17..24.
  const sockets = chat.daemon();
  sockets.keepLog = true;
  sockets.heldAttaches = [];
  sockets.heldReads = [];
  sockets.drop();
  await until(() => chat.daemon() !== sockets && (chat.daemon().heldAttaches?.length ?? 0) > 0, "the held attach");
  const daemon = chat.daemon();
  for (let seq = 17; seq <= 24; seq += 1) daemon.log.push(reply(seq, `missed ${seq}. `));
  const attaches = daemon.heldAttaches!;
  daemon.heldAttaches = undefined;
  for (const answer of attaches) answer();
  // Its page is 19..24; its read of 17..18 waits.
  await until(() => daemon.heldReads!.some((read) => read.afterSeq === 16), "the reconnect's gap read");
  // A watch lag reads after the page's newest meanwhile, and lands first.
  daemon.notify("_acpmux/lagged", { dropped: 1 });
  await until(() => daemon.heldReads!.some((read) => read.afterSeq === 24), "the lag's read");
  daemon.heldReads!.find((read) => read.afterSeq === 24)!.answer();
  await flush();
  // The older read fails: 17..18 are still to read.
  const older = daemon.heldReads!.find((read) => read.afterSeq === 16)!;
  daemon.heldReads = undefined;
  older.fail();
  await flush();
  // The next reconnect reads the hole: from the newest record the transcript is whole through.
  await chat.reconnect();
  await until(() => JSON.stringify(chat.drawn.at(-1)?.rows).includes("missed 17."), "the hole read", 4_000);
  expect(JSON.stringify(chat.drawn.at(-1)!.rows)).toContain("missed 24.");
});

test("a chat with more older rows read than a kept tail holds keeps them all when listed again", async () => {
  // 120 turns: past the 400 records a kept tail holds.
  const log = Array.from({ length: 120 }, (_, turn) => [
    prompt(turn * 4 + 1),
    ...[2, 3, 4].map((part) => reply(turn * 4 + part, `turn ${turn} part ${part}. `)),
  ]).flat();
  const chat = await openChat(log);
  // Two older pages of up to 400 records reach its first.
  for (let page = 0; page < 2; page += 1) {
    await chat.client.loadOlder();
    await flush();
  }
  await flush();
  const shown = chat.drawn.at(-1)!;
  expect(JSON.stringify(shown.rows)).toContain("turn 0 part 2.");
  const from = chat.drawn.length;
  chat.daemon().purge();
  await flush(4);
  chat.daemon().announce();
  await flush();
  const { empty, left } = frames(chat.drawn, from, shown);
  expect(empty).toBe(0);
  expect(left).toEqual([]);
  expect(JSON.stringify(chat.drawn.at(-1)!.rows)).toContain("turn 0 part 2.");
});

test("a chat drawn from the Mac's copy keeps its older pages when listed again", async () => {
  const chat = await openChat(undefined, true);
  expect(chat.shown.peerCopy?.offline).toBe(true);
  await chat.client.loadOlder();
  await flush();
  const shown = chat.drawn.at(-1)!;
  expect(shown.rows.length).toBeGreaterThan(chat.shown.rows.length);
  const from = chat.drawn.length;
  chat.daemon().purge();
  await flush(4);
  chat.daemon().announce();
  await flush();
  const { empty, left, ids } = frames(chat.drawn, from, shown);
  expect(empty).toBe(0);
  expect(left).toEqual([]);
  for (const row of shown.rows) expect(ids).toContain(row.id);
  // Still the copy, offline, as before it left the list.
  expect(chat.drawn.at(-1)!.peerCopy?.offline).toBe(true);
});

test("a copy that covers past its newest record is continued from there when listed again", async () => {
  // Seven turns; the Mac's copy holds 1..16 and covers through 20 (17..20 are of kinds a page does
  // not ask for).
  const log = Array.from({ length: 7 }, (_, turn) => [
    prompt(turn * 4 + 1),
    ...[2, 3, 4].map((part) => reply(turn * 4 + part, `turn ${turn} part ${part}. `)),
  ]).flat();
  const chat = await openChat(log, true, { events: log.slice(0, 16), lastSeq: 20 });
  const shown = chat.drawn.at(-1)!;
  expect(JSON.stringify(shown.rows)).toContain("turn 0 part 2.");
  // The machine's page after the relist starts right after the copy (21..26): nothing in between.
  chat.daemon().log = log.filter((event) => event.seq <= 16 || (event.seq > 20 && event.seq <= 26));
  const from = chat.drawn.length;
  chat.daemon().purge();
  await flush(4);
  chat.daemon().down = false;
  chat.daemon().announce();
  await flush();
  const { empty, left } = frames(chat.drawn, from, shown);
  expect(empty).toBe(0);
  expect(left).toEqual([]);
  const rows = JSON.stringify(chat.drawn.at(-1)!.rows);
  expect(rows).toContain("turn 0 part 2.");
  expect(rows).toContain("turn 6 part 2.");
});

test("a chat that stays gone past its hold keeps no tail of it for a relist", async () => {
  const chat = await openChat();
  chat.daemon().listed = false;
  chat.daemon().purge();
  await flush(4);
  const kept = () => (chat.client as unknown as { leftTail?: unknown }).leftTail;
  // Kept for the hold, for a relist during it.
  expect(kept()).toBeDefined();
  await until(() => chat.drawn.at(-1)?.missingSession === SESSION, "the chat said gone", 3_000);
  // The hold is over: the rows it kept (every one the page read) are not held on to.
  expect(kept()).toBeUndefined();
});

test("the machine back with a slow read of the records it missed draws no hole while it waits", async () => {
  const chat = await openChat();
  chat.daemon().down = true;
  chat.daemon().announce();
  await flush();
  await chat.reconnect();
  for (let seq = 17; seq <= 24; seq += 1) chat.daemon().log.push(reply(seq, `missed ${seq}. `));
  const from = chat.drawn.length;
  // The read of 17..18 is slow: longer than a switch's hold.
  chat.daemon().heldReads = [];
  chat.daemon().down = false;
  chat.daemon().announce();
  await until(() => (chat.daemon().heldReads?.length ?? 0) > 0, "the gap read");
  // fixed-wait: the read must stay out past a switch's 1.5 s hold, which runs on real timers.
  await new Promise((resolve) => setTimeout(resolve, 2_000));
  const held = chat.daemon().heldReads ?? [];
  chat.daemon().heldReads = undefined;
  for (const read of held) read.answer();
  await flush();
  for (const snapshot of chat.drawn.slice(from)) {
    const text = JSON.stringify(snapshot.rows);
    if (text.includes("missed 24.")) expect(text).toContain("missed 17.");
  }
  expect(JSON.stringify(chat.drawn.at(-1)!.rows)).toContain("missed 17.");
});
