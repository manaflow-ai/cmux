// Scrolling up a long chat (Leo, 2026-11-16: "how about speeding up the scrolling up of chats?", "as in i scroll
// up and it loads the shit"). Each older page folds above the held rows (direct.ts `foldOlder`). Every turn the
// page ends counts its time and calls back to its prompt (`turnTotals`), which read the held rows in order; each
// row the page had made since threw that order away, so a page of N turns sorted every row the chat held N times.
// On the 100k-row chat an older page took 0.2-1.8 s from ask to drawn (bench/transcript-scroll-up.bench.ts,
// FIXTURE=flat), most of it those sorts. This feeds the real client older pages and counts the sorts of every
// held row (`OrderedRows.sorts`) per page, and checks that the page's turns still carry their totals.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { EventRecord } from "./eventRecord";
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

/// The chat's whole log.
const TOTAL = 40_000;
/// The records an attach answers with.
const ATTACH = 400;
/// Records per turn: a prompt, its start, a tool call, reply chunks, its result.
const TURN = 20;
/// Older pages read.
const PAGES = 6;

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const settle = async (done: () => boolean, ms: number) => {
  const deadline = performance.now() + ms;
  while (!done() && performance.now() < deadline) await tick();
  return done();
};

/// Record `seq` of a chat whose turns are `TURN` records long, each with one tool call.
function recordAt(sessionId: string, seq: number): EventRecord {
  const at = 1_700_000_000_000 + seq * 1000;
  const phase = seq % TURN;
  if (phase === 1) return { sessionId, seq, at, dir: "mux", kind: "user_message", msg: { text: `turn ${seq}` } };
  if (phase === 2) return { sessionId, seq, at, dir: "mux", kind: "turn_started", msg: {} };
  if (phase === 0) return { sessionId, seq, at, dir: "mux", kind: "turn_result", msg: { status: "completed" } };
  const update =
    phase === 3
      ? { sessionUpdate: "tool_call", toolCallId: `t${seq}`, kind: "execute", title: `run ${seq}`, status: "completed" }
      : {
          sessionUpdate: "agent_message_chunk",
          messageId: `m${Math.floor(seq / TURN)}`,
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

test(`an older page sorts the held rows at most once, not once a turn`, async () => {
  const { AcpmuxDirectClient, OrderedRows } = await import("./direct");
  const sorts = OrderedRows as unknown as { sorts: number };
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  let target = "";
  class LongChat extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const self = this as unknown as { answer: (method: string, params: any) => Promise<unknown> };
      const answer = self.answer.bind(this);
      self.answer = async (method, params) => {
        if (method === "_acpmux/attach") {
          const result = (await answer(method, params)) as Record<string, unknown>;
          target = params.sessionId;
          const events: EventRecord[] = [];
          for (let seq = TOTAL - ATTACH + 1; seq <= TOTAL; seq += 1) events.push(recordAt(target, seq));
          return { ...result, events, hasMore: true, lastSeq: TOTAL, pageThrough: TOTAL, turnOpener: null };
        }
        if (method === "_acpmux/events" && params.sessionId === target && typeof params.beforeSeq === "number") {
          if (params.promptIndex === true) return { events: [], hasMore: false };
          const end = params.beforeSeq - 1;
          const start = Math.max(1, end - Number(params.limit ?? 400) + 1);
          const events: EventRecord[] = [];
          for (let seq = start; seq <= end; seq += 1) events.push(recordAt(target, seq));
          return { events, hasMore: start > 1, lastSeq: TOTAL };
        }
        return answer(method, params);
      };
    }
  }
  const frames: (() => void)[] = [];
  AcpmuxDirectClient.scheduleFrame = (run) => void frames.push(run);
  type Row = { kind: string; id: string; durationMs?: number; toolCount?: number };
  let rows: Row[] = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => (rows = (snapshot as unknown as { rows: Row[] }).rows ?? rows),
    undefined,
    () => new LongChat() as unknown as WebSocket,
  );
  const pane = client as unknown as {
    events: EventRecord[];
    loadOlder: (through?: number, fill?: boolean, rising?: boolean) => Promise<void>;
  };
  try {
    expect(await settle(() => target !== "" && pane.events.length >= ATTACH, 60_000)).toBe(true);
    for (let index = 0; index < 20; index += 1) await tick();
    const perPage: number[] = [];
    for (let page = 0; page < PAGES; page += 1) {
      const held = pane.events.length;
      const sortsBefore = sorts.sorts;
      await pane.loadOlder(undefined, false, true);
      perPage.push(sorts.sorts - sortsBefore);
      expect(pane.events.length).toBeGreaterThan(held);
    }
    for (const run of frames.splice(0)) run();
    console.log(`older-page-cost sorts per page ${JSON.stringify(perPage)} held ${pane.events.length}`);
    // A page of 100 turns sorted every held row about 100 times; merged in once, it sorts none of them.
    for (const count of perPage) expect(count).toBeLessThanOrEqual(1);
    // The page's turns still end with their time and calls, counted from their own prompts.
    const summaries = rows.filter((row) => row.kind === "turnSummary");
    expect(summaries.length).toBeGreaterThan(PAGES * 50);
    for (const row of summaries) {
      expect(row.toolCount).toBe(1);
      expect(row.durationMs).toBe((TURN - 1) * 1000);
    }
  } finally {
    client.close?.();
    AcpmuxDirectClient.scheduleFrame = undefined;
  }
}, 120_000);
