// A reader scrolled up through a long chat holds a window of it, not every page they passed (direct.ts
// `shedNewerHeld`, `loadNewer`, `shedWindowTop`): scrolling up 1,000 older pages, the held records stay within
// `HELD_RECORDS + HELD_KEPT` and a page or two, the newest going as the oldest come; scrolling back down reads
// them again by afterSeq, letting the oldest go, until the rows reach the chat's end again. Before, every page
// passed stayed held (records, rows and their heights), so a 4 GB chat read upward held all of it.
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

/// Records per turn, and per page the stand-in serves: a page is one turn.
const TURN = 100;
const PAGES = 1_000;

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

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

test("a reader scrolling up 1,000 pages and back down holds a bounded window of records", async () => {
  const { AcpmuxDirectClient, HELD_RECORDS, HELD_KEPT } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const total = (PAGES + 20) * TURN;
  let target = "";
  const range = (from: number, to: number) => {
    const events: EventRecord[] = [];
    for (let seq = Math.max(1, from); seq <= Math.min(total, to); seq += 1) events.push(recordAt(target, seq));
    return events;
  };
  class Chat extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const self = this as unknown as { answer: (method: string, params: any) => Promise<unknown> };
      const answer = self.answer.bind(this);
      self.answer = async (method, params) => {
        if (method === "_acpmux/attach") {
          const result = (await answer(method, params)) as Record<string, unknown>;
          target = params.sessionId;
          return {
            ...result,
            events: range(total - TURN + 1, total),
            hasMore: true,
            lastSeq: total,
            pageThrough: total,
            turnOpener: null,
          };
        }
        if (method === "_acpmux/events" && params.sessionId === target) {
          const limit = Math.min(Number(params.limit ?? TURN), TURN);
          // Newest first before `beforeSeq`, as acpmux pages back.
          if (params.beforeSeq !== undefined) {
            const events = range(params.beforeSeq - limit, params.beforeSeq - 1);
            return { events, hasMore: (events[0]?.seq ?? 1) > 1, lastSeq: total };
          }
          const after = Number(params.afterSeq ?? 0);
          const events = range(after + 1, after + limit);
          return { events, hasMore: (events.at(-1)?.seq ?? total) < total, lastSeq: total };
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
  let snapshot: { rows: { id: string; kind: string; text?: string }[]; canLoadOlder?: boolean } = { rows: [] };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (next) => (snapshot = next as unknown as typeof snapshot),
    undefined,
    () => new Chat() as unknown as WebSocket,
  );
  const held = () => (client as unknown as { events: EventRecord[] }).events;
  const window = client as unknown as {
    readerView?: () => readonly string[] | null;
    loadNewer?: () => Promise<void>;
    hasNewerLeft?: () => boolean;
  };
  try {
    for (let index = 0; index < 200 && target === ""; index += 1) await tick();
    for (let index = 0; index < 40; index += 1) await tick();
    flush();
    expect(held().at(-1)?.seq).toBe(total);
    // The reader scrolls up: the view is at the held rows' top, where each older page lands above it.
    client.setFollowing(false);
    window.readerView = () => snapshot.rows.slice(0, 4).map((row) => row.id);
    const bound = HELD_RECORDS + HELD_KEPT + 2 * TURN;
    let most = 0;
    for (let page = 0; page < PAGES; page += 1) {
      await client.loadOlder(undefined, false, true);
      flush();
      most = Math.max(most, held().length);
    }
    // Every page passed came in above the reader, and the newest went.
    expect(held()[0]!.seq).toBeLessThanOrEqual(total - PAGES * TURN);
    expect(most).toBeLessThanOrEqual(bound);
    expect(snapshot.rows.length).toBeLessThan(bound);
    // The reader scrolls back down: the view is at the held rows' end, where each newer page lands below it.
    window.readerView = () => snapshot.rows.slice(-4).map((row) => row.id);
    for (let page = 0; page < 2 * PAGES && window.hasNewerLeft?.(); page += 1) {
      await window.loadNewer!();
      flush();
      most = Math.max(most, held().length);
    }
    expect(window.hasNewerLeft?.()).toBe(false);
    expect(held().at(-1)!.seq).toBe(total);
    expect(most).toBeLessThanOrEqual(bound);
    // The newest turn is drawn whole again, under the turns before it.
    const text = snapshot.rows.map((row) => row.text ?? "").join(" ");
    expect(text).toContain(`w${total - 5} `);
    expect(text).toContain(`w${total - TURN - 5} `);
  } finally {
    client.close?.();
    AcpmuxDirectClient.scheduleFrame = undefined;
  }
}, 600_000);
