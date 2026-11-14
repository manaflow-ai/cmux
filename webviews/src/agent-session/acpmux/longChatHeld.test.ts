// A chat left open holds what a chat just opened on its newest page holds (direct.ts `shedOlderHeld`): past
// `HELD_RECORDS` records, at a turn's end while the view follows its latest row, it lets go of its oldest
// records at a turn start, and scrolling up reads them again as any older page. Leo, 2026-11-12: "even if a chat
// is long, there should be no percievable difference" (bench/transcript-replay.bench.ts god log: 4.4x the heap
// of a small chat, 2.1-2.4x the work per streamed token).
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

/// Records per turn: a prompt, its start, text chunks and tool calls, its result.
const TURN = 100;

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const settle = async (done: () => boolean, ms: number) => {
  const deadline = performance.now() + ms;
  while (!done() && performance.now() < deadline) await tick();
  return done();
};

function recordAt(sessionId: string, seq: number): EventRecord {
  const at = 1_700_000_000_000 + seq * 10;
  const phase = seq % TURN;
  if (phase === 1) return { sessionId, seq, at, dir: "mux", kind: "user_message", msg: { text: `turn ${seq}` } };
  if (phase === 2) return { sessionId, seq, at, dir: "mux", kind: "turn_started", msg: {} };
  if (phase === 0) return { sessionId, seq, at, dir: "mux", kind: "turn_result", msg: { status: "completed" } };
  const update =
    phase % 20 === 5
      ? { sessionUpdate: "tool_call", toolCallId: `t${seq}`, kind: "execute", title: `run ${seq}`, status: "completed" }
      : {
          sessionUpdate: "agent_message_chunk",
          messageId: `m${Math.floor(seq / 20)}`,
          content: { type: "text", text: `w${seq} ` },
        };
  return {
    sessionId,
    seq,
    at,
    dir: "in",
    kind: update.sessionUpdate,
    msg: { method: "session/update", params: { sessionId, update } },
  } as EventRecord;
}

/// A chat opened empty, then `count` records streamed into it live; `following` is what the pane says.
async function streamed(count: number, following: boolean) {
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
          const events: EventRecord[] = [];
          for (let seq = Math.max(1, params.beforeSeq - limit); seq < params.beforeSeq; seq += 1)
            events.push(recordAt(target, seq));
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
    }
  }
  for (let index = 0; index < 20; index += 1) await tick();
  flush();
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

test("a chat followed at its latest row holds at most HELD_RECORDS records however long it streams", async () => {
  const chat = await streamed(32_000, true);
  try {
    const held = chat.events();
    // At most one turn past the bound before its end lets the oldest go.
    expect(chat.most).toBeLessThanOrEqual(chat.HELD_RECORDS + TURN);
    // What it kept starts at a turn start, and ends at the newest record.
    expect(held[0]!.kind).toBe("user_message");
    expect(held.at(-1)!.seq).toBe(chat.total);
    // The newest turn's words are drawn, and the chat can page back.
    const text = chat
      .snapshot()
      .rows.map((row) => row.text ?? "")
      .join(" ");
    expect(text).toContain(`w${chat.total - 5} `);
    expect(text).not.toContain(`w${held[0]!.seq - 5} `);
    expect(chat.snapshot().canLoadOlder).toBe(true);
    expect(chat.snapshot().historyFrom).toBe(held[0]!.seq);
    // Scrolling up reads the turns that left back in, above the rows kept.
    const oldest = held[0]!.seq;
    await chat.client.loadOlder();
    for (let index = 0; index < 20; index += 1) await tick();
    chat.flush();
    expect(chat.events()[0]!.seq).toBeLessThan(oldest);
    const after = chat
      .snapshot()
      .rows.map((row) => row.text ?? "")
      .join(" ");
    expect(after).toContain(`w${oldest - 5} `);
  } finally {
    chat.cleanup();
  }
}, 300_000);

test("a chat the reader scrolled up in keeps every record it holds", async () => {
  const chat = await streamed(12_000, false);
  try {
    expect(chat.events().length).toBe(12_000);
    expect(chat.events()[0]!.seq).toBe(1);
  } finally {
    chat.cleanup();
  }
}, 300_000);
