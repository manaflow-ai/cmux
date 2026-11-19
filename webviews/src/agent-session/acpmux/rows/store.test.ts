// The page's thin store for a chat's rows, fed hand-written change strings of the shapes the
// client core gives (acpmux-client chat.rs `ChatChange`, its shape tests in chat/tests.rs) through
// the document's receiver, as the host's event carries them.
import { describe, expect, test } from "bun:test";
import { chatRowsFeed } from "../../../../test/support/chatRowsFeed";
import {
  ChatRowsHost,
  CHAT_ROWS_LOST,
  CHAT_ROWS_OFF,
  CHAT_ROWS_OTHER_SID,
  type ChatRowsPost,
  chatRowsNamer,
} from "./host";
import { STORE_MAX_BYTES, STORE_MAX_ROWS, type ChatFall, ChatRowStore, type ChatRowsSnapshot } from "./store";
import type { ChatRow } from "./wire";

type Call = { method: string; params: Record<string, unknown> };

/// The host as decision 228 has it: `open` and `blob` answer with the name the page gave.
const echo = (call: Call): unknown =>
  call.method === "chat.rows.open"
    ? { sid: call.params.sid }
    : call.method === "chat.rows.blob"
      ? { id: call.params.id }
      : {};

/// Names in a test: the first sid is "c", then n1, n2, ... for the blob reads.
function testNamer(): () => string {
  let next = 0;
  return () => (next++ === 0 ? "c" : `n${next - 1}`);
}

function harness(answer: (call: Call) => unknown = echo) {
  const calls: Call[] = [];
  const falls: ChatFall[] = [];
  const store = new ChatRowStore({ onFall: (fall) => falls.push(fall) });
  const post: ChatRowsPost = async (method, params) => {
    const call = { method, params };
    calls.push(call);
    const value = await answer(call);
    if (value instanceof Error) throw value;
    return value;
  };
  const host = new ChatRowsHost(post, store, testNamer());
  const feed = chatRowsFeed(host, post);
  const send = (...changes: unknown[]) =>
    feed(changes.map((change) => (typeof change === "string" ? change : JSON.stringify(change))));
  return { calls, falls, store, host, send };
}

const row = (id: number, extra: Partial<ChatRow> = {}): ChatRow => ({
  id,
  rev: 1,
  kind: "text",
  at: 1794480726,
  open: false,
  body: { text: `r${id}` },
  est: 1,
  ...extra,
});

const window = (rows: ChatRow[], extra: Record<string, unknown> = {}, replaces = true) => ({
  kind: "chatWindow",
  replaces,
  window: {
    sid: "c",
    cursor: 10,
    edition: 1,
    rows,
    hasBefore: false,
    hasAfter: false,
    queue: { entries: [], count: 0 },
    ...extra,
  },
});
const op = (body: Record<string, unknown>, replay = false) => ({
  kind: "chatOp",
  sid: "c",
  replay,
  op: { seq: 11, ...body },
});
const ids = (snapshot: ChatRowsSnapshot | undefined) => snapshot?.rows.map((entry) => entry.id);
const range = (n: number, from = 1) => Array.from({ length: n }, (_, index) => row(from + index));

async function opened(answer?: (call: Call) => unknown) {
  const h = harness(answer);
  expect(await h.host.open("chat-1")).toEqual({ sid: "c" });
  const drawn: ChatRowsSnapshot[] = [];
  h.store.subscribe("c", (snapshot) => drawn.push(snapshot));
  return { ...h, drawn };
}

describe("open", () => {
  test("the page names the sid, and a window that comes before the answer is kept", async () => {
    let answer: (() => void) | undefined;
    const { host, store, send, calls } = harness((call) =>
      call.method === "chat.rows.open"
        ? new Promise((resolve) => (answer = () => resolve({ sid: call.params.sid })))
        : {},
    );
    const opening = host.open("chat-1", { rowId: 40, side: "around" }, 100);
    expect(calls[0]).toEqual({
      method: "chat.rows.open",
      params: { sid: "c", chat: "chat-1", anchor: { rowId: 40, side: "around" }, window: 100 },
    });
    // The answer is still out.
    send(window(range(3, 39)));
    expect(ids(store.snapshot("c"))).toEqual([39, 40, 41]);
    answer!();
    expect(await opening).toEqual({ sid: "c" });
    expect(ids(store.snapshot("c"))).toEqual([39, 40, 41]);
  });

  test("a refused open lets go of the sid, so a window that came first is dropped", async () => {
    let refuse: (() => void) | undefined;
    const { host, store, send, falls } = harness((call) =>
      call.method === "chat.rows.open"
        ? new Promise(
            (_, reject) => (refuse = () => reject(Object.assign(new Error("x"), { code: "chat.rows.limit" }))),
          )
        : {},
    );
    const opening = host.open("chat-1");
    send(window(range(2)));
    refuse!();
    expect(await opening).toEqual({ fallen: "chat.rows.limit" });
    expect(store.has("c")).toBe(false);
    // The open's own refusal is the caller's to act on; the store tells no one.
    expect(falls).toEqual([]);
  });

  test("names are a per-document random prefix and a counter, in the host's character set", async () => {
    const first = chatRowsNamer();
    const second = chatRowsNamer();
    const a = first();
    const b = first();
    expect(a).toMatch(/^[0-9a-f]{16}\.1$/);
    expect(b).toBe(`${a.slice(0, 16)}.2`);
    expect(second().slice(0, 16)).not.toBe(a.slice(0, 16));
    expect(a.length).toBeLessThanOrEqual(64);
  });
});

describe("chatWindow", () => {
  test("a window that replaces swaps the rows in one step, never empty between", async () => {
    const { send, drawn, store, calls } = await opened();
    send(window(range(3)));
    send(window([row(7), row(8)], { edition: 2 }));
    expect(drawn.map(ids)).toEqual([
      [1, 2, 3],
      [7, 8],
    ]);
    expect(drawn.every((snapshot) => snapshot.rows.length > 0)).toBe(true);
    expect(store.snapshot("c")?.ready).toBe(true);
    // Each batch is taken once it is applied.
    expect(calls.filter((call) => call.method === "chat.rows.taken").map((call) => call.params.batch)).toEqual([1, 2]);
  });

  test("a window that adds replaces by id and keeps rows outside its range, unconfirmed", async () => {
    const { send, store } = await opened();
    send(window(range(5), { hasBefore: true }));
    send(window([row(4, { rev: 2, body: { text: "new" } }), row(5), row(6)], {}, false));
    const rows = store.snapshot("c")!.rows;
    expect(rows.map((entry) => entry.id)).toEqual([1, 2, 3, 4, 5, 6]);
    expect(rows.filter((entry) => entry.unconfirmed).map((entry) => entry.id)).toEqual([1, 2, 3]);
    expect(rows[3]!.rev).toBe(2);
    // The edge before is still the old window's.
    expect(store.snapshot("c")!.hasBefore).toBe(true);
  });

  test("open rows, queue, seen and folds come from the window", async () => {
    const { send, store } = await opened();
    send(
      window([row(1)], {
        open: [
          { row: row(2, { open: true, body: { text: "he" } }) },
          { row: row(3, { open: true, body: {} }), bodyLen: 90_000 },
        ],
        queue: { entries: [{ id: "q1", text: "next", len: 4, at: 5 }], count: 3 },
        seen: 1,
        folds: [1],
      }),
    );
    const snapshot = store.snapshot("c")!;
    expect(ids(snapshot)).toEqual([1, 2, 3]);
    expect(snapshot.rows[2]!.bodyLen).toBe(90_000);
    expect(snapshot.queue.count).toBe(3);
    expect(snapshot.seen).toBe(1);
    expect(snapshot.folds).toEqual([1]);
  });

  test("refused rows in a window are holes with their size", async () => {
    const { send, store } = await opened();
    send(window([row(1, { est: 4 }), row(3)]));
    send(window([row(3)], { refused: [1, 2] }, false));
    const rows = store.snapshot("c")!.rows;
    expect(rows.map((entry) => [entry.id, entry.row === null, entry.est])).toEqual([
      [1, true, 4],
      [2, true, 1],
      [3, false, 1],
    ]);
  });
});

describe("chatOp", () => {
  test("a settled row appends at the tail and an op re-renders one row", async () => {
    const { send, drawn } = await opened();
    send(window(range(3)));
    send(op({ op: "row", row: row(4) }));
    const [before, after] = drawn.slice(-2);
    expect(ids(after)).toEqual([1, 2, 3, 4]);
    // The rows that did not change keep their identity.
    for (let index = 0; index < 3; index += 1) expect(after!.rows[index]).toBe(before!.rows[index]!);
    expect(after!.queue).toBe(before!.queue);
  });

  test("a row op replaces by id; an older rev is dropped", async () => {
    const { send, store } = await opened();
    send(window([row(1, { rev: 2 }), row(2)]));
    send(op({ op: "row", row: row(1, { rev: 1, body: { text: "old" } }) }));
    expect((store.snapshot("c")!.rows[0]!.row!.body as { text: string }).text).toBe("r1");
    send(op({ op: "row", row: row(2, { body: { text: "settled" } }) }));
    expect((store.snapshot("c")!.rows[1]!.row!.body as { text: string }).text).toBe("settled");
  });

  test("an op for a row not held that is not an append is dropped", async () => {
    const { send, store, drawn } = await opened();
    send(window([row(5), row(6)], { hasAfter: true }));
    const count = drawn.length;
    send(op({ op: "row", row: row(3) }));
    send(op({ op: "row", row: row(9) }));
    send(op({ op: "patch", row: row(4, { rev: 2 }) }));
    send(op({ op: "text", rowId: 8, text: "x" }));
    expect(ids(store.snapshot("c"))).toEqual([5, 6]);
    expect(drawn.length).toBe(count);
  });

  test("a patch replaces a held row only with a newer rev", async () => {
    const { send, store } = await opened();
    send(window([row(1)]));
    send(op({ op: "patch", row: row(1, { rev: 1, body: { text: "same" } }) }));
    expect(store.snapshot("c")!.rows[0]!.rev).toBe(1);
    expect((store.snapshot("c")!.rows[0]!.row!.body as { text: string }).text).toBe("r1");
    send(op({ op: "patch", row: row(1, { rev: 2, body: { text: "answered" } }) }));
    expect(store.snapshot("c")!.rows[0]!.rev).toBe(2);
  });

  test("text appends to an open row's text", async () => {
    const { send, store } = await opened();
    send(window([row(1)], { open: [{ row: row(2, { open: true, body: { text: "He" } }) }] }));
    send(op({ op: "text", rowId: 2, text: "llo" }), op({ op: "text", rowId: 2, text: " ✓" }));
    expect((store.snapshot("c")!.rows[1]!.row!.body as { text: string }).text).toBe("Hello ✓");
    // Not on a settled row.
    send(op({ op: "text", rowId: 1, text: "!" }));
    expect((store.snapshot("c")!.rows[0]!.row!.body as { text: string }).text).toBe("r1");
  });

  test("queue ops: an entry, a removal, a head", async () => {
    const { send, store } = await opened();
    send(window([row(1)], { queue: { entries: [{ id: "a", text: "one", len: 3, at: 1 }], count: 1 } }));
    send(op({ op: "queue", entry: { id: "b", text: "two", len: 3, at: 2 }, count: 2 }));
    expect(store.snapshot("c")!.queue.entries.map((item) => item.id)).toEqual(["a", "b"]);
    send(op({ op: "queue", entry: { id: "a", text: "one!", len: 4, at: 1, held: true }, count: 2 }));
    expect(store.snapshot("c")!.queue.entries[0]!.held).toBe(true);
    // A key this page does not know yet (decision 232's flags) is kept as it came.
    send(op({ op: "queue", entry: { id: "b", text: "two", len: 3, at: 2, next: true }, count: 2 }));
    expect(store.snapshot("c")!.queue.entries[1]!.next).toBe(true);
    send(op({ op: "queue", removed: "a", why: "withdrawn", count: 1 }));
    expect(store.snapshot("c")!.queue).toEqual({
      entries: [{ id: "b", text: "two", len: 3, at: 2, next: true }],
      count: 1,
    });
    send(op({ op: "queue", head: { entries: [], count: 0 }, count: 0 }));
    expect(store.snapshot("c")!.queue).toEqual({ entries: [], count: 0 });
  });
});

describe("a resume", () => {
  test("dropped, replay ops, end: draws once, at the end", async () => {
    const { send, drawn } = await opened();
    send(window(range(2)));
    const count = drawn.length;
    send({ kind: "chatDropped", sid: "c", cursor: 10 });
    expect(drawn.length).toBe(count);
    send(op({ op: "row", row: row(3) }, true));
    send(op({ op: "row", row: row(4) }, true), op({ op: "patch", row: row(1, { rev: 2 }) }, true));
    expect(drawn.length).toBe(count);
    send({ kind: "chatResumeEnd", sid: "c", cursor: 13 });
    expect(drawn.length).toBe(count + 1);
    expect(ids(drawn.at(-1))).toEqual([1, 2, 3, 4]);
    expect(drawn.at(-1)!.rows[0]!.rev).toBe(2);
  });

  test("a dropped sub shows nothing and clears nothing", async () => {
    const { send, drawn, store } = await opened();
    send(window(range(2)));
    const before = store.snapshot("c");
    send({ kind: "chatDropped", sid: "c", cursor: null });
    expect(store.snapshot("c")).toBe(before);
    expect(drawn.length).toBe(1);
  });

  test("a window in place of the resume: the held ops go, the window's rows are drawn", async () => {
    const { send, drawn, store } = await opened();
    send(window(range(2)));
    send({ kind: "chatDropped", sid: "c", cursor: 10 });
    send(op({ op: "row", row: row(3) }, true));
    // The core ends the resume, then gives the window that came in its place; one batch.
    send({ kind: "chatResumeEnd", sid: "c", cursor: 10 }, window([row(5), row(6)], { edition: 2 }));
    expect(ids(store.snapshot("c"))).toEqual([5, 6]);
    expect(drawn.length).toBe(2);
    // A window with ops still held throws them away.
    send(op({ op: "row", row: row(7) }, true));
    send(window([row(5), row(6)], {}, false));
    send({ kind: "chatResumeEnd", sid: "c", cursor: 11 });
    expect(ids(store.snapshot("c"))).toEqual([5, 6]);
  });
});

describe("chatPage", () => {
  test("a page merges at the edge it was asked from, refused rows stay holes", async () => {
    const { send, store, host, calls } = await opened();
    send(window(range(3, 10), { hasBefore: true }));
    expect(host.page("c", "before")).toBe(true);
    expect(calls.at(-1)).toEqual({ method: "chat.rows.page", params: { sid: "c", before: 10 } });
    // One page a sub at a time.
    expect(host.page("c", "before")).toBe(false);
    send({
      kind: "chatPage",
      page: { sid: "c", edition: 1, rows: [row(7), row(9)], hasBefore: false, hasAfter: true, refused: [8] },
    });
    const snapshot = store.snapshot("c")!;
    expect(ids(snapshot)).toEqual([7, 8, 9, 10, 11, 12]);
    expect(snapshot.rows[1]!.refused).toBe(true);
    expect(snapshot.hasBefore).toBe(false);
    expect(snapshot.hasAfter).toBe(false);
    expect(host.page("c", "before")).toBe(true);
  });

  test("a page replaces a row whose rev changed and confirms what it covers", async () => {
    const { send, store, host } = await opened();
    send(window(range(4, 5), { hasBefore: true }));
    send(window([row(7), row(8)], {}, false));
    host.page("c", "before");
    const kept = store.snapshot("c")!.rows[1]!;
    send({
      kind: "chatPage",
      page: { sid: "c", edition: 1, rows: [row(4), row(5, { rev: 2 }), row(6)], hasBefore: true, hasAfter: true },
    });
    const rows = store.snapshot("c")!.rows;
    expect(rows.map((entry) => entry.id)).toEqual([4, 5, 6, 7, 8]);
    expect(rows[1]!.rev).toBe(2);
    expect(rows.some((entry) => entry.unconfirmed)).toBe(false);
    expect(kept.unconfirmed).toBe(true);
  });

  test("a page lets go of an unconfirmed row it neither gives nor refuses; a confirmed one stays", async () => {
    const { send, store, host } = await opened();
    send(window(range(6)));
    // A window in place of a resume that does not reach the rows held: they are unconfirmed.
    send(window(range(3, 10), { hasBefore: true }, false));
    // An op since confirms row 4.
    send(op({ op: "row", row: row(4, { rev: 2 }) }));
    expect(host.page("c", "before")).toBe(true);
    send({
      kind: "chatPage",
      page: { sid: "c", edition: 1, rows: [row(3), row(5), row(7), row(8), row(9)], hasBefore: true, hasAfter: true },
    });
    const rows = store.snapshot("c")!.rows;
    // 6 is gone; 1 and 2 are outside the page and stay unconfirmed; the page reached 3 and 5.
    expect(rows.map((entry) => entry.id)).toEqual([1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 12]);
    expect(rows.filter((entry) => entry.unconfirmed).map((entry) => entry.id)).toEqual([1, 2]);
    expect(rows.some((entry) => entry.gapBefore)).toBe(false);
  });

  test("a window that does not reach the rows held leaves a gap; pages from its row fill it", async () => {
    const { send, store, host, calls } = await opened();
    send(window(range(3)));
    send(window(range(3, 20), { hasBefore: true }, false));
    let rows = store.snapshot("c")!.rows;
    expect(rows.filter((entry) => entry.gapBefore).map((entry) => entry.id)).toEqual([20]);
    // The stretch that holds the anchor (the end) pages from its own first row.
    expect(store.edge("c", "before")).toBe(20);
    expect(host.page("c", "before")).toBe(true);
    expect(calls.at(-1)!.params).toEqual({ sid: "c", before: 20 });
    send({ kind: "chatPage", page: { sid: "c", edition: 1, rows: range(5, 15), hasBefore: true, hasAfter: true } });
    rows = store.snapshot("c")!.rows;
    expect(rows.filter((entry) => entry.gapBefore).map((entry) => entry.id)).toEqual([15]);
    expect(store.snapshot("c")!.hasBefore).toBe(false);
    expect(host.page("c", "before")).toBe(true);
    expect(calls.at(-1)!.params).toEqual({ sid: "c", before: 15 });
    // This page reaches the rows the store held: the gap is closed.
    send({ kind: "chatPage", page: { sid: "c", edition: 1, rows: range(14), hasBefore: false, hasAfter: true } });
    rows = store.snapshot("c")!.rows;
    expect(rows.map((entry) => entry.id)).toEqual(range(22).map((r) => r.id));
    expect(rows.some((entry) => entry.gapBefore || entry.unconfirmed)).toBe(false);
  });

  test("a page asks from the row it is given", async () => {
    const { send, host, calls } = await opened();
    send(window(range(10), { hasAfter: true }));
    expect(host.page("c", "after", { from: 4, maxBytes: 4096 })).toBe(true);
    expect(calls.at(-1)!.params).toEqual({ sid: "c", after: 4, maxBytes: 4096 });
  });

  test("a page error drops that ask and nothing else", async () => {
    const { send, store, host } = await opened();
    send(window(range(3), { hasBefore: true }));
    host.page("c", "before");
    const before = store.snapshot("c");
    send({ kind: "chatError", sid: "c", method: "page", id: null, code: "stale_edition" });
    expect(store.snapshot("c")).toBe(before);
    expect(store.has("c")).toBe(true);
    expect(host.page("c", "before")).toBe(true);
  });
});

describe("chatBlob", () => {
  const blob = (id: string, start: number, total: number, nextStart: number, text: string, extra = {}) =>
    `${JSON.stringify({ kind: "chatBlob", sid: "c", head: { id, start, len: nextStart - start, total, ...extra }, nextStart })}\n${text}`;
  const bytes = (text: string) => new TextEncoder().encode(text).length;

  test("three ranges join in order; a cut inside a multi-byte character starts the next at nextStart", async () => {
    const { send, store, host, calls } = await opened();
    send(window([row(4, { kind: "tool", blob: { bytes: 40, preview: "…" } })]));
    const body = JSON.stringify({ output: "naïve ✓ done" });
    const total = bytes(body);
    // The second range asks for one byte past where "✓" (3 bytes) starts, so it would end inside
    // the character: the core gives the bytes before it, and nextStart names where it starts.
    const first = body.slice(0, 11);
    const second = body.slice(11, body.indexOf("✓"));
    const secondEnd = bytes(body.slice(0, body.indexOf("✓")));
    expect(await host.blob("c", { rowId: 4 }, 11)).toBe("n1");
    // The page names the id in the request (decision 228).
    expect(calls.at(-1)).toEqual({ method: "chat.rows.blob", params: { sid: "c", id: "n1", len: 11, rowId: 4 } });
    send(blob("n1", 0, total, bytes(first), first));
    await host.blob("c", { rowId: 4 }, secondEnd - bytes(first) + 1, { start: bytes(first) });
    send(blob("n2", bytes(first), total, secondEnd, second));
    expect(store.snapshot("c")!.bodies.size).toBe(0);
    await host.blob("c", { rowId: 4 }, 64, { start: secondEnd });
    send(blob("n3", secondEnd, total, total, body.slice(body.indexOf("✓"))));
    expect(store.snapshot("c")!.bodies.get("row:4")).toEqual({ output: "naïve ✓ done" });
  });

  test("a reply that comes before the blob's answer is applied; a prompt's text is kept as text", async () => {
    let answer: (() => void) | undefined;
    const { send, store, host } = await opened((call) =>
      call.method === "chat.rows.blob"
        ? new Promise((resolve) => (answer = () => resolve({ id: call.params.id })))
        : echo(call),
    );
    send(window([row(1)]));
    const asked = host.blob("c", { prompt: "q1" }, 64);
    // The answer is still out.
    send(blob("n1", 0, 5, 5, "hello"));
    expect(store.snapshot("c")!.bodies.get("prompt:q1")).toBe("hello");
    answer!();
    expect(await asked).toBe("n1");
  });

  test("a reply for an id the page did not name, or a read the host refused, is dropped", async () => {
    const { send, store, host } = await opened((call) =>
      call.method === "chat.rows.blob" ? Object.assign(new Error("busy"), { code: "chat.rows.busy" }) : echo(call),
    );
    send(window([row(1)]));
    send(blob("someone-else.1", 0, 5, 5, "hello"));
    expect(await host.blob("c", { prompt: "q1" }, 64)).toBeNull();
    send(blob("n1", 0, 5, 5, "hello"));
    expect(store.snapshot("c")!.bodies.size).toBe(0);
  });

  test("an open row's gen changed between two ranges: the joined part goes and it starts over", async () => {
    const { send, store, host } = await opened();
    send(window([], { open: [{ row: row(2, { open: true, body: {} }), bodyLen: 20 }] }));
    await host.blob("c", { rowId: 2 }, 8);
    send(blob("n1", 0, 20, 8, '{"text":', { open: true, gen: "a" }));
    // The body was set again: the second range is of another body, so neither is kept.
    await host.blob("c", { rowId: 2 }, 12, { start: 8 });
    send(blob("n2", 8, 16, 16, '"fresh"}', { open: true, gen: "b" }));
    expect(store.snapshot("c")!.bodies.size).toBe(0);
    // Started over from 0 in the new gen, the two ranges join.
    await host.blob("c", { rowId: 2 }, 8);
    send(blob("n3", 0, 16, 8, '{"text":', { open: true, gen: "b" }));
    await host.blob("c", { rowId: 2 }, 8, { start: 8 });
    send(blob("n4", 8, 16, 16, '"fresh"}', { open: true, gen: "b" }));
    expect(store.snapshot("c")!.bodies.get("row:2")).toEqual({ text: "fresh" });
  });
});

describe("the fall to v1", () => {
  for (const [name, error, code] of [
    ["off", Object.assign(new Error("off"), { code: "chat.rows.off" }), "chat.rows.off"],
    ["limit", Object.assign(new Error("limit"), { code: "chat.rows.limit" }), "chat.rows.limit"],
    ["the v1 attach's refusal", Object.assign(new Error("no"), { code: "session.not_found" }), "session.not_found"],
    [
      "a host with no such op",
      Object.assign(new Error("unknown"), {
        code: "native.invalid_request",
        details: { protocol: "cmux.protocol.unknown_op" },
      }),
      CHAT_ROWS_OFF,
    ],
    ["the old bridge's unsupported", Object.assign(new Error("no"), { code: "unsupported" }), CHAT_ROWS_OFF],
    ["a lost link, with no code", new Error("lost"), CHAT_ROWS_LOST],
    [
      "invalid params",
      Object.assign(new Error("bad"), {
        code: "native.invalid_request",
        details: { protocol: "cmux.protocol.invalid_params" },
      }),
      "native.invalid_request",
    ],
  ] as const)
    test(`an open refused (${name}) falls with its code and holds no sid`, async () => {
      const { host, store } = harness((call) => (call.method === "chat.rows.open" ? error : {}));
      expect(await host.open("chat-1")).toEqual({ fallen: code });
      expect(store.has("c")).toBe(false);
    });

  test("an open answered with no sid is a host without the operation", async () => {
    const { host, store } = harness(() => ({}));
    expect(await host.open("chat-1")).toEqual({ fallen: CHAT_ROWS_OFF });
    expect(store.has("c")).toBe(false);
  });

  test("an open answered with another sid falls that chat only", async () => {
    const { host, store } = harness((call) => (call.method === "chat.rows.open" ? { sid: "theirs" } : {}));
    expect(await host.open("chat-1")).toEqual({ fallen: CHAT_ROWS_OTHER_SID });
    expect(store.has("c")).toBe(false);
    expect(store.has("theirs")).toBe(false);
  });

  test("a sub error other than not_ready ends the sub: the sid is forgotten and the chat falls", async () => {
    const { send, store, falls } = await opened();
    send(window(range(2)));
    send({ kind: "chatError", sid: "c", method: "sub", id: null, code: "not_ready" });
    expect(store.has("c")).toBe(true);
    expect(falls).toEqual([]);
    send({ kind: "chatError", sid: "c", method: "sub", id: null, code: "surface_off" });
    expect(store.has("c")).toBe(false);
    expect(falls).toEqual([{ sid: "c", code: "surface_off" }]);
    // Changes for a sid the page does not hold are dropped unread.
    send(op({ op: "row", row: row(3) }));
    expect(store.snapshot("c")).toBeUndefined();
  });

  test("not_ready keeps the sid and the window follows", async () => {
    const { send, store } = await opened();
    send({ kind: "chatError", sid: "c", method: "sub", id: null, code: "not_ready" });
    expect(store.snapshot("c")!.ready).toBe(false);
    send(window(range(2)));
    expect(ids(store.snapshot("c"))).toEqual([1, 2]);
  });
});

describe("the cap", () => {
  test("paging past the cap lets go of the end farthest from where the person reads", async () => {
    const { send, store, host } = await opened();
    const last = 20_000;
    send(window(range(400, last - 399), { hasBefore: true }));
    let pages = 0;
    while (store.snapshot("c")!.hasBefore) {
      const edge = store.edge("c", "before")!;
      expect(host.page("c", "before")).toBe(true);
      const from = Math.max(1, edge - 400);
      send({
        kind: "chatPage",
        page: { sid: "c", edition: 1, rows: range(edge - from, from), hasBefore: from > 1, hasAfter: true },
      });
      const held = store.held("c")!;
      expect(held.rows).toBeLessThanOrEqual(STORE_MAX_ROWS);
      expect(held.bytes).toBeLessThanOrEqual(STORE_MAX_BYTES);
      pages += 1;
    }
    const snapshot = store.snapshot("c")!;
    expect(pages).toBe(49);
    expect(snapshot.rows[0]!.id).toBe(1);
    expect(snapshot.rows.length).toBe(STORE_MAX_ROWS);
    // The tail was let go of, so a page after brings it back.
    expect(snapshot.hasAfter).toBe(true);
    expect(store.edge("c", "after")).toBe(STORE_MAX_ROWS);
  });

  test("open rows are never let go of: past the stretch they are held apart until a page reaches them", async () => {
    const { send, store, host } = await opened();
    const tail = 20_001;
    send(
      window(range(400, tail - 400), {
        hasBefore: true,
        open: [{ row: row(tail, { open: true, body: { text: "a" } }) }],
      }),
    );
    for (let pages = 0; pages < 5; pages += 1) {
      const edge = store.edge("c", "before")!;
      expect(host.page("c", "before")).toBe(true);
      send({
        kind: "chatPage",
        page: { sid: "c", edition: 1, rows: range(400, edge - 400), hasBefore: true, hasAfter: true },
      });
    }
    let snapshot = store.snapshot("c")!;
    expect(snapshot.rows.length).toBe(STORE_MAX_ROWS);
    expect(snapshot.rows.some((entry) => entry.row?.open)).toBe(false);
    expect(snapshot.apart.map((entry) => entry.id)).toEqual([tail]);
    expect(snapshot.hasAfter).toBe(true);
    expect(store.held("c")!.rows).toBe(STORE_MAX_ROWS + 1);
    // Ops on a row held apart apply; a row that opens past the stretch is taken; one that
    // settles there is let go of (a page after brings it).
    send(op({ op: "text", rowId: tail, text: "b" }));
    send(op({ op: "row", row: row(tail + 1, { open: true, body: { text: "" } }) }));
    send(op({ op: "row", row: row(tail, { rev: 2, body: { text: "ab" } }) }));
    snapshot = store.snapshot("c")!;
    expect(snapshot.apart.map((entry) => entry.id)).toEqual([tail + 1]);
    // Pages after, until one says nothing follows: the open rows join the rows, and appends follow.
    while (store.snapshot("c")!.hasAfter) {
      const last = store.edge("c", "after")!;
      const count = Math.min(400, tail - last);
      expect(host.page("c", "after")).toBe(true);
      send({
        kind: "chatPage",
        page: { sid: "c", edition: 1, rows: range(count, last + 1), hasBefore: true, hasAfter: last + count < tail },
      });
      if (last + count < tail) expect(store.snapshot("c")!.apart.map((entry) => entry.id)).toEqual([tail + 1]);
    }
    snapshot = store.snapshot("c")!;
    expect(snapshot.apart).toEqual([]);
    expect(snapshot.hasAfter).toBe(false);
    expect(snapshot.rows.at(-1)!.id).toBe(tail + 1);
    expect(snapshot.rows.at(-2)!.id).toBe(tail);
    send(op({ op: "row", row: row(tail + 2) }));
    expect(store.snapshot("c")!.rows.at(-1)!.id).toBe(tail + 2);
  });

  test("a text op adds its piece's bytes: the count matches a row measured whole", async () => {
    const { send, store } = await opened();
    send(window([row(1)], { open: [{ row: row(2, { open: true, body: { text: "He" } }) }] }));
    for (const piece of ["llo", ' "q"\n', "✓\u0001"]) send(op({ op: "text", rowId: 2, text: piece }));
    const whole = await opened();
    whole.send(window([row(1)], { open: [{ row: row(2, { open: true, body: { text: 'Hello "q"\n✓\u0001' } }) }] }));
    expect(store.held("c")!.bytes).toBe(whole.store.held("c")!.bytes);
  });

  test("rows past the cap in bytes go too, from the far end", async () => {
    const { send, store } = await opened();
    const big = (id: number) => row(id, { body: { text: "x".repeat(15_000) } });
    send(window(Array.from({ length: 80 }, (_, index) => big(index + 1))));
    const held = store.held("c")!;
    expect(held.bytes).toBeLessThanOrEqual(STORE_MAX_BYTES);
    expect(store.snapshot("c")!.hasBefore).toBe(true);
    expect(store.snapshot("c")!.rows.at(-1)!.id).toBe(80);
  });
});
