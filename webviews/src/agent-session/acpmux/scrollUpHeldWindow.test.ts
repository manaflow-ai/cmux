// While a reader scrolls up a long chat, what the pane holds stays bounded (direct.ts `shedNewerHeld`): each older
// page that folds in at the top lets go of the newest held records far below the view, so held records and rows, and
// the work of each page, are the same at page 200 as at page 1. Scrolling back down reads the newer pages again
// (`loadNewer`), every row back in order, and Jump to latest shows the true latest rows, live ones heard while
// scrolled up included. Leo, 2026-11-14: "the dream is infinite chats of infinite length with flat or no growth in
// cpu/memory/even disk".
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { EventRecord } from "./direct";
import { settleReact } from "../../../test/support/domTeardown";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const had = { window: "window" in scope, document: "document" in scope };
const before = { window: scope.window, document: scope.document };
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(async () => {
  await settleReact();
  for (const key of ["window", "document"] as const)
    if (had[key]) scope[key] = before[key];
    else delete scope[key];
});

/// Records per turn, the records a page serves (smaller than the client's ask, as a byte cap ends one), how many
/// older pages the reader scrolls up through, and the records the chat holds past them.
const TURN = 60;
const PAGE = 120;
const PAGES = 200;
const TOTAL = PAGE * PAGES + 2_400;
/// The rows the pane reports within three screens of the view, from the end the reader is at.
const NEAR = 30;
const OUTPUT = "x".repeat(120);

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const settle = async (done: () => boolean, ms: number) => {
  const deadline = performance.now() + ms;
  while (!done() && performance.now() < deadline) await tick();
  return done();
};

function inbound(sessionId: string, seq: number, update: Record<string, unknown>) {
  return {
    sessionId,
    seq,
    at: 1_700_000_000_000 + seq * 10,
    dir: "in",
    kind: update.sessionUpdate,
    msg: { method: "session/update", params: { sessionId, update } },
  } as EventRecord;
}
const mux = (sessionId: string, seq: number, kind: string, msg: Record<string, unknown> = {}) =>
  ({ sessionId, seq, at: 1_700_000_000_000 + seq * 10, dir: "mux", kind, msg }) as EventRecord;

/// A chat of ended turns: each a prompt naming its turn, its start, messages and tool calls, its result.
function recordAt(sessionId: string, seq: number): EventRecord {
  const phase = seq % TURN;
  if (phase === 1) return mux(sessionId, seq, "user_message", { text: `turn ${Math.floor(seq / TURN)}` });
  if (phase === 2) return mux(sessionId, seq, "turn_started");
  if (phase === 0) return mux(sessionId, seq, "turn_result", { status: "completed" });
  if (phase % 20 === 5)
    return inbound(sessionId, seq, {
      sessionUpdate: "tool_call",
      toolCallId: `c${seq}`,
      kind: "execute",
      title: `run ${seq}`,
      status: "in_progress",
    });
  if (phase % 20 === 6)
    return inbound(sessionId, seq, {
      sessionUpdate: "tool_call_update",
      toolCallId: `c${seq - 1}`,
      status: "completed",
      content: [{ type: "content", content: { type: "text", text: `${OUTPUT} ${seq}` } }],
    });
  return inbound(sessionId, seq, {
    sessionUpdate: "agent_message_chunk",
    messageId: `m${Math.floor(seq / 20)}`,
    content: { type: "text", text: `w${seq} ` },
  });
}

type Row = { id: string; kind: string; text?: string };
type Snapshot = { rows: Row[]; canLoadOlder: boolean; canLoadNewer?: boolean };
type Pane = {
  events: EventRecord[];
  rows: Map<string, unknown>;
  reduce: (event: EventRecord) => void;
};
type Client = {
  setFollowing(following: boolean): void;
  setViewRows?(first: string | undefined, last: string | undefined): void;
  loadOlder(through?: number, fill?: boolean, rising?: boolean): Promise<void>;
  loadNewer?(): Promise<void>;
  close(): void;
};

/// A chat of TOTAL records opened on its tail, the reader scrolled away from the latest row.
async function openLongChat() {
  const { AcpmuxDirectClient, OrderedRows, HELD_RECORDS } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  let target = "";
  let total = TOTAL;
  const reads = { older: 0, newer: 0 };
  let socket: { deliver: (message: unknown) => void } | undefined;
  const range = (from: number, to: number) => {
    const events: EventRecord[] = [];
    for (let seq = from; seq <= to; seq += 1) events.push(recordAt(target, seq));
    return events;
  };
  class Chat extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      socket = this as unknown as typeof socket;
      const self = this as unknown as { answer: (method: string, params: any) => Promise<unknown> };
      const answer = self.answer.bind(this);
      self.answer = async (method, params) => {
        if (method === "_acpmux/attach") {
          const result = (await answer(method, params)) as Record<string, unknown>;
          target = params.sessionId;
          // The tail: the newest records from a turn start, as acpmux opens a chat.
          const from = Math.floor((total - 400) / TURN) * TURN + 1;
          return {
            ...result,
            events: range(from, total),
            hasMore: true,
            lastSeq: total,
            pageThrough: total,
            turnOpener: null,
          };
        }
        if (method === "_acpmux/events" && params.sessionId === target && params.promptIndex === true)
          return { events: [], hasMore: false, lastSeq: total };
        if (method === "_acpmux/events" && params.sessionId === target && params.beforeSeq !== undefined) {
          reads.older += 1;
          const to = Math.min(total, params.beforeSeq - 1);
          const from = Math.max(1, to - Math.min(PAGE, Number(params.limit ?? PAGE)) + 1);
          return { events: range(from, to), hasMore: from > 1, lastSeq: total };
        }
        if (method === "_acpmux/events" && params.sessionId === target) {
          reads.newer += 1;
          const from = Number(params.afterSeq ?? 0) + 1;
          const to = Math.min(total, from + Math.min(PAGE, Number(params.limit ?? PAGE)) - 1);
          return { events: range(from, to), hasMore: to < total, lastSeq: total };
        }
        return answer(method, params);
      };
    }
  }
  const frames: (() => void)[] = [];
  AcpmuxDirectClient.scheduleFrame = (run) => void frames.push(run);
  const flush = () => {
    for (const run of frames.splice(0)) run();
  };
  let snapshot: Snapshot = { rows: [], canLoadOlder: false };
  const client = (await AcpmuxDirectClient.connect(
    mockHost,
    (next) => (snapshot = next as unknown as Snapshot),
    undefined,
    () => new Chat() as unknown as WebSocket,
  )) as unknown as Client;
  const pane = client as unknown as Pane;
  let reduced = 0;
  const reduce = pane.reduce.bind(client);
  pane.reduce = (event) => {
    reduced += 1;
    reduce(event);
  };
  expect(await settle(() => target !== "" && snapshot.rows.length > 0, 10_000)).toBe(true);
  for (let index = 0; index < 20; index += 1) await tick();
  flush();
  client.setFollowing(false);
  /// The pane's report of the rows near the view: the reader at the top of the held rows, or at their foot.
  const view = (at: "top" | "foot") => {
    flush();
    const rows = snapshot.rows;
    if (at === "top") client.setViewRows?.(rows[0]?.id, rows[Math.min(NEAR, rows.length - 1)]?.id);
    else client.setViewRows?.(rows[Math.max(0, rows.length - 1 - NEAR)]?.id, rows.at(-1)?.id);
  };
  const live = (count: number) => {
    for (let index = 0; index < count; index += 1) {
      total += 1;
      socket!.deliver({ jsonrpc: "2.0", method: "_acpmux/event", params: recordAt(target, total) });
    }
  };
  return {
    client,
    pane,
    snapshot: () => snapshot,
    flush,
    view,
    live,
    reads,
    total: () => total,
    reduced: () => reduced,
    sorts: () => OrderedRows.sorts,
    HELD_RECORDS,
    cleanup: () => {
      client.close();
      AcpmuxDirectClient.scheduleFrame = undefined;
    },
  };
}

const turnOf = (row: Row) => Number(/^turn (\d+)/.exec(row.text ?? "")?.[1] ?? NaN);
const turns = (rows: readonly Row[]) => rows.filter((row) => row.kind === "user").map(turnOf);

/// Scrolls up PAGES older pages, the pane reporting the rows near the top before each; per page: records and rows
/// held, records folded, whole sorts.
async function scrollUp(chat: Awaited<ReturnType<typeof openLongChat>>) {
  const pages: { events: number; rows: number; reduced: number; sorts: number }[] = [];
  for (let page = 0; page < PAGES && chat.snapshot().canLoadOlder; page += 1) {
    chat.view("top");
    const reduced = chat.reduced();
    const sorts = chat.sorts();
    await chat.client.loadOlder(undefined, false, true);
    chat.flush();
    pages.push({
      events: chat.pane.events.length,
      rows: chat.pane.rows.size,
      reduced: chat.reduced() - reduced,
      sorts: chat.sorts() - sorts,
    });
  }
  return pages;
}

const mean = (values: number[]) => values.reduce((sum, value) => sum + value, 0) / Math.max(1, values.length);

test("scrolling up 200 older pages: held records and rows stay bounded, and each page's work is flat", async () => {
  const chat = await openLongChat();
  try {
    const pages = await scrollUp(chat);
    expect(pages.length).toBe(PAGES);
    const early = pages.slice(0, 20);
    const late = pages.slice(-20);
    const worst = {
      events: Math.max(...pages.map((page) => page.events)),
      rows: Math.max(...pages.map((p) => p.rows)),
    };
    console.log(
      `scroll-up pages=${pages.length} heldEvents first=${pages[0]!.events} max=${worst.events} last=${pages.at(-1)!.events}` +
        ` heldRows first=${pages[0]!.rows} max=${worst.rows} last=${pages.at(-1)!.rows}` +
        ` reducedPerPage early=${mean(early.map((p) => p.reduced)).toFixed(0)} late=${mean(late.map((p) => p.reduced)).toFixed(0)}` +
        ` sortsPerPage early=${mean(early.map((p) => p.sorts)).toFixed(2)} late=${mean(late.map((p) => p.sorts)).toFixed(2)}`,
    );
    // Held records: never past the shed's threshold and one page.
    expect(worst.events).toBeLessThanOrEqual(chat.HELD_RECORDS + 2 * PAGE);
    // Held rows: the late pages hold no more than the window between its kept size and its threshold, twice the
    // rows it held when it first passed the kept size.
    const filled = pages.find((page) => page.events > chat.HELD_RECORDS / 2) ?? pages.at(-1)!;
    expect(Math.max(...late.map((p) => p.rows))).toBeLessThanOrEqual(2.5 * filled.rows);
    // Each page's work: the records folded and the whole sorts, late as early.
    expect(mean(late.map((p) => p.reduced))).toBeLessThanOrEqual(2 * mean(early.map((p) => p.reduced)) + PAGE);
    expect(mean(late.map((p) => p.sorts))).toBeLessThanOrEqual(2 * mean(early.map((p) => p.sorts)) + 1);
    // The reader's rows, at the top, are the chat's turns in order.
    const held = turns(chat.snapshot().rows);
    held.forEach((turn, index) => index > 0 && expect(turn).toBe(held[index - 1]! + 1));
  } finally {
    chat.cleanup();
  }
}, 600_000);

test("scrolling back down reads the newer pages again: every row back in order, held rows still bounded", async () => {
  const chat = await openLongChat();
  try {
    await scrollUp(chat);
    expect(chat.snapshot().canLoadNewer).toBe(true);
    const top = turns(chat.snapshot().rows)[0]!;
    // Every turn the reader passes on the way down, in the order first seen.
    const seen: number[] = [];
    const note = () => {
      for (const turn of turns(chat.snapshot().rows)) if (turn > (seen.at(-1) ?? -Infinity)) seen.push(turn);
    };
    note();
    let worst = 0;
    for (let page = 0; page < 4 * PAGES && chat.snapshot().canLoadNewer; page += 1) {
      chat.view("foot");
      await chat.client.loadNewer!();
      chat.flush();
      note();
      worst = Math.max(worst, chat.pane.events.length);
    }
    console.log(`scroll-down newerReads=${chat.reads.newer} heldEventsMax=${worst} turns=${top}..${seen.at(-1)}`);
    expect(chat.snapshot().canLoadNewer).toBeFalsy();
    expect(worst).toBeLessThanOrEqual(chat.HELD_RECORDS + 2 * PAGE);
    const last = Math.floor((chat.total() - 1) / TURN);
    expect(seen.length).toBe(last - top + 1);
    seen.forEach((turn, index) => expect(turn).toBe(top + index));
    // Back at the tail, the chat holds live records again.
    chat.live(TURN);
    await settle(() => turns(chat.snapshot().rows).at(-1) === Math.floor((chat.total() - 1) / TURN), 5_000);
    chat.flush();
    expect(turns(chat.snapshot().rows).at(-1)).toBe(Math.floor((chat.total() - 1) / TURN));
  } finally {
    chat.cleanup();
  }
}, 600_000);

test("Jump to latest while scrolled far up shows the true latest rows, live ones heard meanwhile included", async () => {
  const chat = await openLongChat();
  try {
    await scrollUp(chat);
    const held = chat.pane.events.length;
    // Two turns run live while the reader is far up: they are owed, not held after the gap.
    chat.live(2 * TURN);
    for (let index = 0; index < 20; index += 1) await tick();
    chat.flush();
    expect(chat.pane.events.length).toBe(held);
    expect(turns(chat.snapshot().rows).at(-1)!).toBeLessThan(Math.floor((chat.total() - 1) / TURN) - 100);
    // Jump to latest: the transcript follows its latest row again.
    chat.client.setFollowing(true);
    const latest = Math.floor((chat.total() - 1) / TURN);
    const shown = await settle(() => {
      chat.flush();
      return turns(chat.snapshot().rows).at(-1) === latest;
    }, 10_000);
    expect(shown).toBe(true);
    expect(chat.snapshot().canLoadNewer).toBeFalsy();
    const tail = turns(chat.snapshot().rows);
    tail.forEach((turn, index) => index > 0 && expect(turn).toBe(tail[index - 1]! + 1));
  } finally {
    chat.cleanup();
  }
}, 600_000);
