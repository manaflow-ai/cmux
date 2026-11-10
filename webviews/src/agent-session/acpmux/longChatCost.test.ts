// A pane left open on a long, busy chat (Leo, 2026-11-09: a coordinator past 1.37M events, its
// page at up to 125% CPU and 1.5-3.2 GB: "im not properly seeing your messages") paid for each
// repaired turn and each lag read in proportion to every record it held: both drew the chat again
// from all of them. Interaction cost stays constant as a chat grows: this feeds the real client a
// held history of `SMALL` and of `LARGE` records, streams the same live records into each (some
// dropped, as a busy acpmux drops a slow client's chunks, then repaired by the turn's end or a lag
// read), and checks that the work per live record is the same at both sizes.
//
// LONG_CHAT_LARGE=1000000 bun test src/agent-session/acpmux/longChatCost.test.ts prints the numbers
// at a million held records (the default keeps CI quick).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { EventRecord } from "./direct";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const had = { window: "window" in scope, document: "document" in scope };
const before = { window: scope.window, document: scope.document };
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  for (const key of ["window", "document"] as const)
    if (had[key]) scope[key] = before[key];
    else delete scope[key];
});

const SMALL = 10_000;
const LARGE = Number(process.env.LONG_CHAT_LARGE ?? 200_000);
/// The chat's whole log, of which the pane holds the newest `held`.
const TOTAL = 1_400_000;
const LIVE = 1_000;
/// The records an attach answers with (direct.ts `sendAttach`'s limit).
const ATTACH = 400;
/// Records per turn: a prompt, its start, text chunks and tool calls, its result.
const TURN = 200;

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const settle = async (done: () => boolean, ms: number) => {
  const deadline = performance.now() + ms;
  while (!done() && performance.now() < deadline) await tick();
  return done();
};

/// Record `seq` of a chat whose turns are `TURN` records long.
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

type Mode = "stream" | "repair" | "lag";

/// Opens a chat holding its newest `held` records, then streams `LIVE` more. In each 50, records
/// 10-19 that are agent updates never reach the pane (but with `stream`); with `lag`, acpmux then
/// says it lagged.
async function liveCost(held: number, mode: Mode) {
  const { AcpmuxDirectClient, OrderedRows } = await import("./direct");
  const sorts = OrderedRows as unknown as { sorts?: number };
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const proto = AcpmuxDirectClient.prototype as unknown as Record<string, (...args: unknown[]) => unknown>;
  const reduce = proto.reduce!;
  let reduced = 0;
  proto.reduce = function (this: unknown, ...args: unknown[]) {
    reduced += 1;
    return reduce.apply(this, args);
  };
  let target = "";
  let total = TOTAL;
  let lagReads = 0;
  let socket: { deliver: (message: unknown) => void } | undefined;
  class LongChat extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      socket = this as unknown as typeof socket;
      const self = this as unknown as { answer: (method: string, params: any) => Promise<unknown> };
      const answer = self.answer.bind(this);
      self.answer = async (method, params) => {
        if (method === "_acpmux/attach") {
          const result = (await answer(method, params)) as Record<string, unknown>;
          target = params.sessionId;
          const events: EventRecord[] = [];
          // The newest page, as an attach reads it; the rest of what the pane holds streamed in
          // while it stayed open (below).
          for (let seq = total - ATTACH + 1; seq <= total; seq += 1) events.push(recordAt(target, seq));
          return { ...result, events, hasMore: true, lastSeq: total, pageThrough: total, turnOpener: null };
        }
        if (method === "_acpmux/events" && params.sessionId === target && params.beforeSeq === undefined) {
          if (!Array.isArray(params.kinds)) lagReads += 1;
          const limit = Math.min(Number(params.limit ?? 5_000), 5_000);
          const events: EventRecord[] = [];
          for (let seq = Number(params.afterSeq ?? 0) + 1; seq <= total && events.length < limit; seq += 1)
            events.push(recordAt(target, seq));
          return { events, hasMore: events.length === limit };
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
  let rows: { kind: string; text?: string }[] = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => (rows = (snapshot as unknown as { rows: typeof rows }).rows ?? rows),
    undefined,
    () => new LongChat() as unknown as WebSocket,
  );
  const events = () => (client as unknown as { events: EventRecord[] }).events;
  try {
    expect(await settle(() => target !== "" && events().length >= ATTACH, 60_000)).toBe(true);
    for (let index = 0; index < 20; index += 1) await tick();
    // The records that streamed in while the pane stayed open on the chat, drawn once.
    const streamed: EventRecord[] = [];
    for (let seq = total - held + 1; seq <= total - ATTACH; seq += 1) streamed.push(recordAt(target, seq));
    const pane = client as unknown as { events: EventRecord[]; rebuild: () => void; emit: () => void };
    pane.events = streamed.concat(pane.events);
    pane.rebuild();
    pane.emit();
    for (let index = 0; index < 20; index += 1) await tick();
    flush();
    reduced = 0;
    lagReads = 0;
    const sortsBefore = sorts.sorts ?? 0;
    const started = performance.now();
    const dropped: number[] = [];
    for (let index = 0; index < LIVE; index += 1) {
      total += 1;
      const record = recordAt(target, total);
      if (mode !== "stream" && index % 50 >= 10 && index % 50 < 20 && record.dir === "in") dropped.push(total);
      else socket!.deliver({ jsonrpc: "2.0", method: "_acpmux/event", params: record });
      if (mode === "lag" && index % 50 === 20)
        socket!.deliver({ jsonrpc: "2.0", method: "_acpmux/lagged", params: { sessionIds: [target], dropped: 10 } });
      if (index % 8 === 7) {
        await tick();
        flush();
      }
    }
    // Every dropped record is read back and held.
    const holds = (seq: number) => {
      const held = events();
      let low = 0;
      let high = held.length;
      while (low < high) {
        const middle = (low + high) >>> 1;
        if (held[middle]!.seq < seq) low = middle + 1;
        else high = middle;
      }
      return held[low]?.seq === seq;
    };
    await settle(() => dropped.every(holds), 120_000);
    for (let index = 0; index < 20; index += 1) await tick();
    flush();
    const elapsed = performance.now() - started;
    const text = rows.map((row) => row.text ?? "").join(" ");
    return {
      held,
      mode,
      msPerRecord: elapsed / LIVE,
      reducedPerRecord: reduced / LIVE,
      wholeSorts: (sorts.sorts ?? 0) - sortsBefore,
      lagReads,
      repaired: dropped.every(holds),
      drawn: dropped
        .filter((seq) => recordAt(target, seq).kind === "agent_message_chunk")
        .every((seq) => text.includes(`w${seq} `)),
    };
  } finally {
    client.close?.();
    AcpmuxDirectClient.scheduleFrame = undefined;
    proto.reduce = reduce;
  }
}

for (const mode of ["stream", "repair", "lag"] as const)
  test(`a ${mode} costs the same per live record with ${SMALL} or ${LARGE} records held`, async () => {
    const small = await liveCost(SMALL, mode);
    const large = await liveCost(LARGE, mode);
    console.log(`long-chat-cost ${JSON.stringify(small)}`);
    console.log(`long-chat-cost ${JSON.stringify(large)}`);
    for (const result of [small, large]) {
      expect(result.repaired).toBe(true);
      // The repaired records are drawn, not only held.
      expect(result.drawn).toBe(true);
    }
    // Records folded per live record: the same at both sizes (a fold of every held record per
    // repair or lag made this grow with `held`, 20x from SMALL to LARGE).
    expect(large.reducedPerRecord).toBeLessThan(small.reducedPerRecord * 1.5 + 5);
    // Sorts of every row the chat holds: one per turn's end (`turnTotals`) and per dropped row
    // made the work per turn O(rows held) on top of the refold.
    expect(large.wholeSorts).toBeLessThanOrEqual(small.wholeSorts);
  }, 900_000);

test("lags heard while a lag read is out are read once it lands, not each on its own", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  let target = "";
  let reads = 0;
  let release: (() => void) | undefined;
  let socket: { deliver: (message: unknown) => void } | undefined;
  class Busy extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      socket = this as unknown as typeof socket;
      const self = this as unknown as { answer: (method: string, params: any) => Promise<unknown> };
      const answer = self.answer.bind(this);
      self.answer = async (method, params) => {
        if (method === "_acpmux/attach") target = params.sessionId;
        if (method === "_acpmux/events" && params.sessionId === target && target && !Array.isArray(params.kinds)) {
          reads += 1;
          // acpmux is busy: the first read answers only when the test says so.
          if (reads === 1) await new Promise<void>((resolve) => (release = resolve));
        }
        return answer(method, params);
      };
    }
  }
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => undefined,
    undefined,
    () => new Busy() as unknown as WebSocket,
  );
  try {
    await settle(
      () => target !== "" && (client as unknown as { attachedGeneration?: number }).attachedGeneration !== undefined,
      5_000,
    );
    for (let index = 0; index < 20; index += 1) await tick();
    for (let index = 0; index < 10; index += 1) {
      socket!.deliver({ jsonrpc: "2.0", method: "_acpmux/lagged", params: { sessionIds: [target], dropped: 1 } });
      await tick();
    }
    expect(await settle(() => release !== undefined, 2_000)).toBe(true);
    expect(reads).toBe(1);
    release!();
    await settle(() => reads >= 2, 2_000);
    for (let index = 0; index < 50; index += 1) await tick();
    // The read out, then one for every lag heard while it was.
    expect(reads).toBe(2);
  } finally {
    client.close?.();
  }
});

test("rebuildCut folds again from a turn start at or before both the window and the change", async () => {
  const { rebuildCut, REBUILD_WINDOW, mergeIntoHeld, firstHeldFrom } = await import("./direct");
  const held = Array.from({ length: REBUILD_WINDOW * 3 }, (_, index) => recordAt("s", index + 1));
  expect(rebuildCut(held.slice(0, REBUILD_WINDOW), 1)).toBe(0);
  const cut = rebuildCut(held, held.at(-1)!.seq);
  expect(held[cut]!.kind).toBe("user_message");
  expect(held.length - cut).toBeGreaterThanOrEqual(REBUILD_WINDOW);
  expect(held.length - cut).toBeLessThan(REBUILD_WINDOW + TURN);
  const early = rebuildCut(held, 1_234);
  expect(held[early]!.seq).toBeLessThanOrEqual(1_234);
  expect(held[early]!.kind).toBe("user_message");
  expect(firstHeldFrom(held, 1_234)).toBe(1_233);
  // A subagent still running since record 4,321 keeps its turn in the refold.
  const open = rebuildCut(held, held.at(-1)!.seq, held[4_320]!.at);
  expect(held[open]!.seq).toBeLessThanOrEqual(4_321);
  expect(held[open]!.kind).toBe("user_message");

  const events = [1, 2, 4, 7].map((seq) => recordAt("s", seq));
  mergeIntoHeld(events, [recordAt("s", 9), recordAt("s", 8)]);
  mergeIntoHeld(events, [recordAt("s", 5), recordAt("s", 3), recordAt("s", 4)]);
  expect(events.map((event) => event.seq)).toEqual([1, 2, 3, 4, 5, 7, 8, 9]);
});
