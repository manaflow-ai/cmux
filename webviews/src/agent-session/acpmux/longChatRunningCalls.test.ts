// A running turn of tool calls that never ends (chat-100k-flat.bench.ts's running_x1: a reply chunk with no
// messageId, a command's call and its completed update, step after step) holds a bounded number of records and rows,
// as one whose messages carry ids does (longChatNeverEnding.test.ts).
// Leo, 2026-11-14: "the bigger question is of memory and cpu staying flat on infinite chats. i obviously dont mean
// infinite at once, but the dream of never ever needing to close a tab or workspace or anything. thats the white
// whale."
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { EventRecord } from "./direct";
import type { AcpmuxRow } from "./model";
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

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const settle = async (done: () => boolean, ms: number) => {
  const deadline = performance.now() + ms;
  while (!done() && performance.now() < deadline) await tick();
  return done();
};

const update = (sessionId: string, seq: number, u: Record<string, unknown>): EventRecord =>
  ({
    sessionId,
    seq,
    at: 1_700_000_000_000 + seq * 10,
    dir: "in",
    kind: u.sessionUpdate,
    msg: { method: "session/update", params: { sessionId: "agent-1", update: u } },
  }) as EventRecord;

/// The bench's running turn: its prompt and start, then per step a reply chunk, a call and its completed update.
function recordAt(sessionId: string, seq: number): EventRecord {
  const at = 1_700_000_000_000 + seq * 10;
  if (seq === 1) return { sessionId, seq, at, dir: "mux", kind: "user_message", msg: { text: "Coordinate the lanes" } };
  if (seq === 2) return { sessionId, seq, at, dir: "mux", kind: "turn_started", msg: {} };
  const step = Math.floor((seq - 3) / 3) + 1;
  const phase = (seq - 3) % 3;
  if (phase === 0)
    return update(sessionId, seq, {
      sessionUpdate: "agent_message_chunk",
      content: { type: "text", text: `Running step ${step}: checking the lane. ` },
    });
  if (phase === 1)
    return update(sessionId, seq, {
      sessionUpdate: "tool_call",
      toolCallId: `run-${step}`,
      title: `glaeda-gh status pr ${step}`,
      kind: "execute",
      status: "in_progress",
      rawInput: { command: `glaeda-gh status pr ${step}` },
    });
  return update(sessionId, seq, {
    sessionUpdate: "tool_call_update",
    toolCallId: `run-${step}`,
    status: "completed",
    content: [{ type: "content", content: { type: "text", text: `checks SUCCESS: ${step} passed` } }],
  });
}

/// A chat opened empty, then `count` records of one never-ending turn streamed into it live.
async function streamed(count: number, following: boolean, onFlush?: (snapshot: { rows: AcpmuxRow[] }) => void) {
  const { AcpmuxDirectClient, HELD_RECORDS } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  let target = "";
  let total = 0;
  let socket: { deliver: (message: unknown) => void } | undefined;
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
          return { ...result, events: [], hasMore: false, lastSeq: 0, pageThrough: 0, turnOpener: null };
        }
        // An older page: the newest records before `beforeSeq`, as acpmux pages them.
        if (method === "_acpmux/events" && params.sessionId === target && params.beforeSeq !== undefined) {
          const limit = Number(params.limit ?? 400);
          // A prompt read (`fetchTurnOpener`) asks for prompts only; a page asks for the "transcript", every record here.
          const kinds: string[] | undefined = params.kinds?.includes("transcript") ? undefined : params.kinds;
          const events: EventRecord[] = [];
          for (let seq = params.beforeSeq - 1; seq >= 1 && events.length < limit; seq -= 1) {
            const event = recordAt(target, seq);
            if (!kinds || kinds.includes(event.kind)) events.unshift(event);
          }
          return { events, hasMore: (events[0]?.seq ?? 1) > 1, lastSeq: total };
        }
        if (method === "_acpmux/events" && params.sessionId === target) {
          const events: EventRecord[] = [];
          for (let seq = Number(params.afterSeq ?? 0) + 1; seq <= total && events.length < 5_000; seq += 1)
            events.push(recordAt(target, seq));
          return { events, hasMore: false, lastSeq: total };
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
  let snapshot: { rows: { kind: string; text?: string }[]; canLoadOlder?: boolean; historyFrom?: number } = {
    rows: [],
  };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (next) => (snapshot = next as unknown as typeof snapshot),
    undefined,
    () => new Chat() as unknown as WebSocket,
  );
  const events = () => (client as unknown as { events: EventRecord[] }).events;
  client.setFollowing(following);
  expect(await settle(() => target !== "", 10_000)).toBe(true);
  for (let index = 0; index < 20; index += 1) await tick();
  let most = 0;
  for (let index = 0; index < count; index += 1) {
    total += 1;
    socket!.deliver({ jsonrpc: "2.0", method: "_acpmux/event", params: recordAt(target, total) });
    most = Math.max(most, events().length);
    if (index % 50 === 49) {
      await tick();
      flush();
      onFlush?.(snapshot as unknown as { rows: AcpmuxRow[] });
    }
  }
  for (let index = 0; index < 20; index += 1) await tick();
  flush();
  // Delivered records apply a tick later: the last ones count too.
  most = Math.max(most, events().length);
  return {
    client,
    events,
    snapshot: () => snapshot,
    most,
    total,
    HELD_RECORDS,
    flush,
    cleanup: () => {
      client.close?.();
      AcpmuxDirectClient.scheduleFrame = undefined;
    },
  };
}

/// The JS heap after a collection (bun's `Bun.gc`).
const collect = () => (globalThis as { Bun?: { gc?: (sync: boolean) => void } }).Bun?.gc?.(true);

/// Streams `count` records of the running turn while drawing it as the pane does (App.tsx): its turns shaped on the
/// last snapshot's (turns.ts `turnViewFrom`, which keeps a reply a refresh left out, and whose running turn keeps its
/// rows' objects by id) and the thread rail's turns (threadMinimap/model.ts `minimapTurns`, whose cards keep a
/// contribution per row). Returns how many of the rows drawn for the first `early` records are still alive once the
/// turn went far past them, the rows drawn against the rows the chat holds, and the rail's card entries for the turn.
async function drawnWhileRunning(count: number, early: number) {
  const { turnViewFrom } = await import("./conversation/turns");
  const { minimapTurns, cardEntries } = await import("./threadMinimap/model");
  const earlyRows: WeakRef<AcpmuxRow>[] = [];
  const folds = new Set<string>();
  let view: ReturnType<typeof turnViewFrom> | undefined;
  let rail: ReturnType<typeof minimapTurns> | undefined;
  let prompt: AcpmuxRow | undefined;
  let records = 0;
  let held = 0;
  const chat = await streamed(count, true, (snapshot) => {
    records += 50;
    const { rows, heldFromAt } = snapshot as { rows: AcpmuxRow[]; heldFromAt?: number };
    view = turnViewFrom(rows, folds, { working: true, now: 1_700_000_000_000 + records * 10, heldFromAt }, view);
    rail = minimapTurns(view.rows, "s", rail);
    prompt = view.rows.find((row) => row.kind === "user") ?? prompt;
    held = rows.length;
    if (records <= early) for (const row of view.rows) if (row.kind !== "user") earlyRows.push(new WeakRef(row));
  });
  try {
    const shown = new Set(view!.rows.map((row) => row.id));
    const drawn = view!.rows.length;
    view = undefined;
    rail = undefined;
    collect();
    const alive = earlyRows.filter((ref) => {
      const row = ref.deref();
      return row !== undefined && !shown.has(row.id);
    }).length;
    return { alive, early: earlyRows.length, drawn, held, cards: prompt ? cardEntries(prompt) : 0 };
  } finally {
    chat.cleanup();
  }
}

test("a running turn of calls holds a bounded number of records and rows", async () => {
  const sizes: Record<number, { events: number; rows: number; most: number }> = {};
  for (const count of [6_000, 24_000]) {
    const chat = await streamed(count, true);
    try {
      const held = chat.events();
      sizes[count] = { events: held.length, rows: chat.snapshot().rows.length, most: chat.most };
      expect(held.at(-1)!.seq).toBe(chat.total);
    } finally {
      chat.cleanup();
    }
  }
  expect(sizes[24_000]!.most).toBeLessThanOrEqual(6_000);
  expect(sizes[24_000]!.rows).toBeLessThanOrEqual(sizes[6_000]!.rows * 1.2);
}, 600_000);

// The rows the pane drew for the turn's oldest records, which the chat let go of, are let go of by the view too: the
// running turn's rows by id (turns.ts `steadyLiveRows`) and the rail's card contributions (`cardStates`) kept every
// row the turn ever drew, and with it each row's entries in the caches keyed by row (chat-100k-flat running_x1: a
// 100k-record running turn held about 40 MB more renderer heap than an empty chat, growing with the turn).
test("a running turn's view lets go of the rows that left it", async () => {
  const result = await drawnWhileRunning(24_000, 3_000);
  console.log(
    `running-view streamed=24000 early_rows=${result.early} early_rows_alive=${result.alive} drawn=${result.drawn} ` +
      `held=${result.held} rail_cards=${result.cards}`,
  );
  expect(result.early).toBeGreaterThan(500);
  // The view draws what the chat holds, not every reply the turn streamed.
  expect(result.drawn).toBeLessThanOrEqual(2 * result.held + 16);
  expect(result.alive).toBe(0);
  expect(result.cards).toBeLessThanOrEqual(2 * result.drawn + 16);
}, 600_000);
