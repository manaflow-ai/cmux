// l10n-allow-file: test fixture prompts and replies, not shipped UI.
//
// A reconnect reads only what it missed (cmuxterm-hq#14027). The client that lost its socket still
// holds the chat's records, so its attach asks the records after the newest one it holds
// (`afterSeq`, a forward page) instead of the chat's newest page again: on a long Cloud chat that
// page was up to 128 KiB on every reconnect, for records already on screen. These tests run the
// client's own reconnect (the socket closes, the same client opens a new one and attaches again)
// against a daemon that pages as acpmux's `_acpmux/attach` does (server/requests.rs: `afterSeq`
// alone pages forward, oldest first).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";

const CHAT = "0190a000-0000-7000-8000-00000000f0f0";
const START = Date.UTC(2026, 10, 19, 9, 0, 0);
const CREATED = START - 60_000;
const PAGE = 400;
const PAGE_BYTES = 128 * 1024;

const scope = globalThis as { window?: unknown };
const hadWindow = "window" in scope;
// The client schedules its reconnect on `window`; this test has no DOM.
beforeAll(() => {
  if (!hadWindow) scope.window = globalThis;
});
afterAll(() => {
  if (!hadWindow) delete scope.window;
});

type Recorded = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: unknown };

/// Turn `n`'s two records from `seq` on: its prompt and a reply about `size` bytes long.
function turn(seq: number, n: number, size = 40): Recorded[] {
  return [
    { sessionId: CHAT, seq, at: START + seq * 1000, dir: "mux", kind: "user_message", msg: { text: `Ask ${n}` } },
    {
      sessionId: CHAT,
      seq: seq + 1,
      at: START + (seq + 1) * 1000,
      dir: "in",
      kind: "agent_message_chunk",
      msg: {
        method: "session/update",
        params: {
          sessionId: CHAT,
          update: {
            sessionUpdate: "agent_message_chunk",
            content: { type: "text", text: `Reply ${n}. ${"x".repeat(Math.max(0, size - 10))}` },
          },
        },
      },
    },
  ];
}

/// A chat of `turns` turns.
function chat(turns: number, size?: number): Recorded[] {
  const out: Recorded[] = [];
  for (let n = 1; n <= turns; n += 1) out.push(...turn(out.length + 1, n, size));
  return out;
}

/// What the daemon was asked and answered: every attach's params and its reply's bytes, and the
/// gap reads (`_acpmux/events` after a seq, every kind).
type Wire = { attaches: { params: any; bytes: number }[]; gapReads: any[] };

/// acpmux over a fake socket. `history` grows with `add` (records logged while no socket is open)
/// or `push` (records sent live). `ignoresAfterSeq`: a daemon or peer that answers every attach
/// with its newest page. `pageFrom`: where the first open's newest page starts (older records stay
/// for history reads).
function daemon(
  history: Recorded[],
  options: { ignoresAfterSeq?: boolean; pageFrom?: number; forwardLimit?: number } = {},
) {
  let socket: any;
  let createdAt = CREATED;
  let lastSeqOverride: number | undefined;
  const wire: Wire = { attaches: [], gapReads: [] };
  const session = () => ({
    sessionId: CHAT,
    cwd: "/home/dev/app",
    title: "Long chat",
    harness: "claude",
    family: "claude",
    status: "idle",
    createdAt,
  });
  const lastSeq = () => lastSeqOverride ?? history.at(-1)?.seq ?? 0;
  /// The newest `PAGE` records before `before`, cut to `PAGE_BYTES` from the newest, as acpmux's
  /// `events_page` with the pane's byte bound.
  const newestPage = (from: number) => {
    const page: Recorded[] = [];
    let bytes = 0;
    for (let index = history.length - 1; index >= 0 && page.length < PAGE; index -= 1) {
      const record = history[index]!;
      if (record.seq < from) break;
      bytes += JSON.stringify(record).length;
      if (bytes > PAGE_BYTES && page.length > 0) break;
      page.unshift(record);
    }
    return page;
  };
  const answer = (method: string, params: any) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session()] };
      case "_acpmux/attach": {
        if (typeof params?.afterSeq === "number" && !options.ignoresAfterSeq) {
          const after = history.filter((event) => event.seq > params.afterSeq);
          const limit = options.forwardLimit ?? PAGE;
          return {
            session: session(),
            lastSeq: lastSeq(),
            events: after.slice(0, limit),
            hasMore: after.length > limit,
          };
        }
        const events = newestPage(wire.attaches.length === 1 ? (options.pageFrom ?? 0) : 0);
        return {
          session: session(),
          lastSeq: lastSeq(),
          events,
          hasMore: (events[0]?.seq ?? lastSeq() + 1) > (history[0]?.seq ?? 1),
        };
      }
      case "_acpmux/events": {
        if (params?.afterSeq !== undefined && params?.kinds === undefined) wire.gapReads.push(params);
        const after = params?.afterSeq ?? 0;
        const before = params?.beforeSeq ?? Infinity;
        const all = history.filter((event) => event.seq > after && event.seq < before);
        const limit = params?.limit ?? 5_000;
        const events = params?.beforeSeq !== undefined ? all.slice(-limit) : all.slice(0, limit);
        return { events, hasMore: all.length > limit, lastSeq: lastSeq() };
      }
      default:
        return null;
    }
  };
  const open = () => {
    socket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id === undefined) return;
        if (message.method === "_acpmux/attach") wire.attaches.push({ params: message.params, bytes: 0 });
        const asked = wire.attaches.at(-1);
        queueMicrotask(() => {
          const data = JSON.stringify({
            jsonrpc: "2.0",
            id: message.id,
            result: answer(message.method, message.params),
          });
          if (message.method === "_acpmux/attach" && asked) asked.bytes = data.length;
          socket.onmessage?.({ data });
        });
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  return {
    open,
    wire,
    /// Records logged while the socket is down.
    add: (records: Recorded[]) => history.push(...records),
    /// The connection drops; the client opens a new one and attaches again.
    drop: () => socket.onclose?.({ code: 1006, reason: "", wasClean: false }),
    /// The session is deleted and made again under the same id (another `createdAt`).
    recreate: (records: Recorded[]) => {
      createdAt += 1;
      history.length = 0;
      history.push(...records);
    },
    /// The machine's log ends before what the pane holds (a restore from an older copy).
    lostTo: (seq: number) => {
      history.splice(history.findIndex((event) => event.seq > seq));
      lastSeqOverride = seq;
    },
  };
}

async function connect(fake: ReturnType<typeof daemon>) {
  let snapshot: any;
  let attached = false;
  let connects = 0;
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (next: any) => {
      snapshot = next;
      if (next.connection === "connected") {
        if (!attached) connects += 1;
        attached = true;
      } else if (next.connection === "disconnected" || next.connection === "failed") attached = false;
    },
    undefined,
    fake.open,
  );
  await until(() => attached, "the attach");
  return { client, snapshot: () => snapshot, connects: () => connects };
}

/// Yields until `ready()` holds; fails after 2 s with what it waited for.
async function until(ready: () => boolean, what: string) {
  const deadline = performance.now() + 2_000;
  while (!ready()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}

/// The reconnect: the socket drops and the same client attaches again.
async function reconnect(fake: ReturnType<typeof daemon>, session: Awaited<ReturnType<typeof connect>>) {
  const before = fake.wire.attaches.length;
  fake.drop();
  // The client reconnects on a timer: its new attach, answered.
  await until(
    () => fake.wire.attaches.length > before && fake.wire.attaches.every((attach) => attach.bytes > 0),
    "the reconnect's attach",
  );
  // Let the open's reads after the attach (a fallback attach, a gap read) land.
  for (let pass = 0; pass < 50; pass += 1) await new Promise((resolve) => setTimeout(resolve, 0));
  expect(session.snapshot().connection).not.toBe("disconnected");
}

const replies = (snapshot: any): number[] =>
  [...JSON.stringify(snapshot.rows ?? []).matchAll(/Reply (\d+)\./g)].map((match) => Number(match[1]));

test("a reconnect with nothing new asks only past its records, reads no gap and keeps its history state", async () => {
  // A chat longer than its first page: older history is left to read.
  const history = chat(300);
  const fake = daemon(history, { pageFrom: 401 });
  const session = await connect(fake);
  try {
    expect(session.snapshot().canLoadOlder).toBe(true);
    const shown = replies(session.snapshot());
    await reconnect(fake, session);
    const asked = fake.wire.attaches.at(-1)!.params;
    expect(asked.afterSeq).toBe(600);
    expect(asked.settled).toBeUndefined();
    expect(fake.wire.attaches).toHaveLength(2);
    expect(fake.wire.gapReads).toHaveLength(0);
    // The forward page's `hasMore: false` is of the records after it, not the older history.
    expect(session.snapshot().canLoadOlder).toBe(true);
    expect(replies(session.snapshot())).toEqual(shown);
  } finally {
    session.client.close();
  }
});

test("a reconnect that missed more than a page reads the page forward, then the rest once, with no hole", async () => {
  const history = chat(10);
  const fake = daemon(history);
  const session = await connect(fake);
  try {
    // 250 turns (500 records) while the socket was down: more than one forward page.
    const missed: Recorded[] = [];
    for (let n = 11; n <= 260; n += 1) missed.push(...turn(21 + (n - 11) * 2, n));
    fake.add(missed);
    await reconnect(fake, session);
    expect(fake.wire.attaches.at(-1)!.params.afterSeq).toBe(20);
    expect(fake.wire.attaches).toHaveLength(2);
    // One read, from the forward page's end.
    expect(fake.wire.gapReads.map((read) => read.afterSeq)).toEqual([20 + PAGE]);
    await until(() => replies(session.snapshot()).includes(260), "the missed records");
    const shown = replies(session.snapshot());
    expect(shown).toEqual(Array.from({ length: 260 }, (_, index) => index + 1));
  } finally {
    session.client.close();
  }
});

test("a session recreated while the socket was down is attached again for its newest page", async () => {
  const fake = daemon(chat(5));
  const session = await connect(fake);
  try {
    fake.recreate(chat(2));
    await reconnect(fake, session);
    const attaches = fake.wire.attaches.map((attach) => attach.params.afterSeq);
    expect(attaches).toEqual([undefined, 10, undefined]);
    await until(() => replies(session.snapshot()).length > 0, "the new session's rows");
  } finally {
    session.client.close();
  }
});

test("a log that ends before the records held is attached again for its newest page", async () => {
  const fake = daemon(chat(5));
  const session = await connect(fake);
  try {
    fake.lostTo(6);
    await reconnect(fake, session);
    const attaches = fake.wire.attaches.map((attach) => attach.params.afterSeq);
    expect(attaches).toEqual([undefined, 10, undefined]);
  } finally {
    session.client.close();
  }
});

test("a daemon that ignores afterSeq answers its newest page, laid as before with no second attach", async () => {
  const fake = daemon(chat(5), { ignoresAfterSeq: true });
  const session = await connect(fake);
  try {
    fake.add(turn(11, 6));
    await reconnect(fake, session);
    expect(fake.wire.attaches.map((attach) => attach.params.afterSeq)).toEqual([undefined, 10]);
    await until(() => replies(session.snapshot()).includes(6), "the missed turn");
    expect(replies(session.snapshot())).toEqual([1, 2, 3, 4, 5, 6]);
  } finally {
    session.client.close();
  }
});

test("a cold open asks the newest page, never a forward one", async () => {
  const fake = daemon(chat(5));
  const session = await connect(fake);
  try {
    expect(fake.wire.attaches[0]!.params.afterSeq).toBeUndefined();
  } finally {
    session.client.close();
  }
});

test("reconnect attach reply bytes: newest page before, forward page after (1x and 10x history)", async () => {
  // Each reply about 400 bytes, as an agent's paragraphs: the newest page reaches the 128 KiB byte
  // bound, so it costs the same on every reconnect however long the chat; a forward page costs
  // what was missed (here nothing).
  const rows: string[] = [];
  for (const scale of [1, 10]) {
    const turns = 200 * scale;
    const before = daemon(chat(turns, 400), { ignoresAfterSeq: true });
    const old = await connect(before);
    await reconnect(before, old);
    old.client.close();
    const after = daemon(chat(turns, 400));
    const now = await connect(after);
    await reconnect(after, now);
    now.client.close();
    const oldBytes = before.wire.attaches.at(-1)!.bytes;
    const newBytes = after.wire.attaches.at(-1)!.bytes;
    expect(newBytes).toBeLessThan(oldBytes / 50);
    rows.push(`${scale}x (${turns * 2} records): newest page ${oldBytes} B, forward page ${newBytes} B`);
  }
  console.log(`reconnect attach reply bytes\n${rows.join("\n")}`);
});
