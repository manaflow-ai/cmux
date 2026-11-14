// The page's thin store for a chat's rows, fed hand-written change strings of the shapes the
// client core gives (acpmux-client chat.rs `ChatChange`, its shape tests in chat/tests.rs) through
// the host client, as the host's event carries them.
import { describe, expect, test } from "bun:test";
import { ChatRowsHost, CHAT_ROWS_OFF } from "./host";
import { STORE_MAX_BYTES, STORE_MAX_ROWS, type ChatFall, ChatRowStore, type ChatRowsSnapshot } from "./store";
import type { ChatRow } from "./wire";

type Call = { method: string; params: Record<string, unknown> };

function harness(answer: (call: Call) => unknown = () => ({})) {
  const calls: Call[] = [];
  const falls: ChatFall[] = [];
  const store = new ChatRowStore({ onFall: (fall) => falls.push(fall) });
  const host = new ChatRowsHost(async (method, params) => {
    const call = { method, params };
    calls.push(call);
    const value = answer(call);
    if (value instanceof Error) throw value;
    return value;
  }, store);
  let batch = 0;
  const send = (...changes: unknown[]) =>
    host.receive({
      batch: ++batch,
      changes: changes.map((change) => (typeof change === "string" ? change : JSON.stringify(change))),
    });
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
  const h = harness(answer ?? ((call) => (call.method === "chat.rows.open" ? { sid: "c" } : {})));
  expect(await h.host.open("chat-1")).toEqual({ sid: "c" });
  const drawn: ChatRowsSnapshot[] = [];
  h.store.subscribe("c", (snapshot) => drawn.push(snapshot));
  return { ...h, drawn };
}

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
    send(op({ op: "queue", removed: "a", count: 1 }));
    expect(store.snapshot("c")!.queue).toEqual({ entries: [{ id: "b", text: "two", len: 3, at: 2 }], count: 1 });
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
    let next = 0;
    const { send, store, host } = await opened((call) =>
      call.method === "chat.rows.open" ? { sid: "c" } : call.method === "chat.rows.blob" ? { id: `b${++next}` } : {},
    );
    send(window([row(4, { kind: "tool", blob: { bytes: 40, preview: "…" } })]));
    const body = JSON.stringify({ output: "naïve ✓ done" });
    const total = bytes(body);
    // The second range asks for one byte past where "✓" (3 bytes) starts, so it would end inside
    // the character: the core gives the bytes before it, and nextStart names where it starts.
    const first = body.slice(0, 11);
    const second = body.slice(11, body.indexOf("✓"));
    const secondEnd = bytes(body.slice(0, body.indexOf("✓")));
    await host.blob("c", { rowId: 4 }, 11);
    send(blob("b1", 0, total, bytes(first), first));
    await host.blob("c", { rowId: 4 }, secondEnd - bytes(first) + 1, { start: bytes(first) });
    send(blob("b2", bytes(first), total, secondEnd, second));
    expect(store.snapshot("c")!.bodies.size).toBe(0);
    await host.blob("c", { rowId: 4 }, 64, { start: secondEnd });
    send(blob("b3", secondEnd, total, total, body.slice(body.indexOf("✓"))));
    expect(store.snapshot("c")!.bodies.get("row:4")).toEqual({ output: "naïve ✓ done" });
  });

  test("a prompt's text is kept as text, and a reply before the host's answer is kept for it", async () => {
    const { send, store } = await opened();
    send(window([row(1)]));
    send(blob("p1", 0, 5, 5, "hello"));
    expect(store.snapshot("c")!.bodies.size).toBe(0);
    store.blobAsked("c", "p1", { prompt: "q1" });
    expect(store.snapshot("c")!.bodies.get("prompt:q1")).toBe("hello");
  });

  test("an open row's gen changed between two ranges: the joined part goes and it starts over", async () => {
    let next = 0;
    const { send, store, host } = await opened((call) =>
      call.method === "chat.rows.open" ? { sid: "c" } : call.method === "chat.rows.blob" ? { id: `g${++next}` } : {},
    );
    send(window([], { open: [{ row: row(2, { open: true, body: {} }), bodyLen: 20 }] }));
    await host.blob("c", { rowId: 2 }, 8);
    send(blob("g1", 0, 20, 8, '{"text":', { open: true, gen: "a" }));
    // The body was set again: the second range is of another body, so neither is kept.
    await host.blob("c", { rowId: 2 }, 12, { start: 8 });
    send(blob("g2", 8, 16, 16, '"fresh"}', { open: true, gen: "b" }));
    expect(store.snapshot("c")!.bodies.size).toBe(0);
    // Started over from 0 in the new gen, the two ranges join.
    await host.blob("c", { rowId: 2 }, 8);
    send(blob("g3", 0, 16, 8, '{"text":', { open: true, gen: "b" }));
    await host.blob("c", { rowId: 2 }, 8, { start: 8 });
    send(blob("g4", 8, 16, 16, '"fresh"}', { open: true, gen: "b" }));
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
  ] as const)
    test(`an open refused (${name}) falls with its code and holds no sid`, async () => {
      const { host, store } = harness(() => error);
      expect(await host.open("chat-1")).toEqual({ fallen: code });
      expect(store.has("c")).toBe(false);
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
