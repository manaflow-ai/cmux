// A chat left open lets go of its oldest held records (direct.ts `shedOlderHeld`) without folding again the ones it
// keeps: the records and the rows only they drew leave from the old end in place (`dropHeldRun`), O(what leaves), so
// a key typed while the chat streams never waits behind a 20-40 ms refold of the held window. These stream a turn
// that never ends and a chat of ended turns past `HELD_RECORDS`, count the rebuilds, and compare the rows the sheds
// left with a full rebuild of the same records.
// Leo, 2026-11-16: "but typing under load is not good enough". Leo, 2026-11-14: "the dream is infinite chats of
// infinite length with flat or no growth in cpu/memory/even disk".
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

/// Records per message in the turn that never ends: its streamed chunks, then a tool call with a streamed output.
const MESSAGE = 25;
/// Records per turn in the chat of ended turns.
const TURN = 120;
const OUTPUT = "x".repeat(200);

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const settle = async (done: () => boolean, ms: number) => {
  const deadline = performance.now() + ms;
  while (!done() && performance.now() < deadline) await tick();
  return done();
};

function inbound(sessionId: string, seq: number, update: Record<string, unknown>, meta?: Record<string, unknown>) {
  return {
    sessionId,
    seq,
    at: 1_700_000_000_000 + seq * 10,
    dir: "in",
    kind: update.sessionUpdate,
    msg: { method: "session/update", params: { sessionId, update, ...(meta ? { _meta: { acpmux: meta } } : {}) } },
  } as EventRecord;
}
const mux = (sessionId: string, seq: number, kind: string, msg: Record<string, unknown> = {}) =>
  ({ sessionId, seq, at: 1_700_000_000_000 + seq * 10, dir: "mux", kind, msg }) as EventRecord;
const say = (sessionId: string, seq: number, messageId: string) =>
  inbound(sessionId, seq, {
    sessionUpdate: "agent_message_chunk",
    messageId,
    content: { type: "text", text: `w${seq} ` },
  });
const call = (sessionId: string, seq: number, id: string, status?: string, output?: string) =>
  inbound(sessionId, seq, {
    sessionUpdate: status === "start" ? "tool_call" : "tool_call_update",
    toolCallId: id,
    ...(status === "start" ? { kind: "execute", title: `run ${id}`, status: "in_progress" } : {}),
    ...(status && status !== "start" ? { status } : {}),
    ...(output ? { content: [{ type: "content", content: { type: "text", text: output } }] } : {}),
  });

/// One turn that never ends: its prompt, its start, a subagent that says it runs and never says more, a subagent
/// that runs and ends, messages and tool calls forever, a steer into the running turn now and then, and now and
/// then a call that runs long, its output streamed while the turn goes on around it.
function neverEnding(sessionId: string, seq: number): EventRecord {
  if (seq === 1) return mux(sessionId, seq, "user_message", { text: "coordinate" });
  if (seq === 2) return mux(sessionId, seq, "turn_started");
  if (seq === 3)
    return inbound(
      sessionId,
      seq,
      { sessionUpdate: "subagent_progress" },
      { subagents: [{ id: "stale", parent: null, name: "Stale helper", state: "running" }] },
    );
  if (seq % 1_500 === 7)
    return inbound(
      sessionId,
      seq,
      { sessionUpdate: "subagent_progress" },
      { subagents: [{ id: `helper-${seq}`, parent: null, name: `Helper ${seq}`, state: "running" }] },
    );
  if (seq % 1_500 === 57)
    return inbound(
      sessionId,
      seq,
      { sessionUpdate: "subagent_progress" },
      { subagents: [{ id: `helper-${seq - 50}`, parent: null, name: `Helper ${seq - 50}`, state: "completed" }] },
    );
  // A call that runs long: started, streamed into every 100 records while messages go on, ended 600 later.
  const long = Math.floor(seq / 2_000);
  if (seq % 2_000 === 11) return call(sessionId, seq, `long${long}`, "start");
  if (seq % 2_000 > 11 && seq % 2_000 < 611 && seq % 100 === 11)
    return call(sessionId, seq, `long${long}`, undefined, `${OUTPUT} long ${seq}`);
  if (seq % 2_000 === 611) return call(sessionId, seq, `long${long}`, "completed", `${OUTPUT} long done`);
  const phase = seq % MESSAGE;
  const message = Math.floor(seq / MESSAGE);
  if (phase === 0 && message % 40 === 0)
    return mux(sessionId, seq, "user_message", { text: `steer ${seq}`, steer: true });
  if (phase === MESSAGE - 3) return call(sessionId, seq, `t${message}`, "start");
  if (phase === MESSAGE - 2) return call(sessionId, seq, `t${message}`, undefined, `${OUTPUT} ${message}`);
  if (phase === MESSAGE - 1) return call(sessionId, seq, `t${message}`, "completed", `${OUTPUT} ${message}`);
  return say(sessionId, seq, `m${message}`);
}

/// A chat of ended turns: each a prompt, its start, messages and tool calls, its result.
function endedTurns(sessionId: string, seq: number): EventRecord {
  const phase = seq % TURN;
  if (phase === 1) return mux(sessionId, seq, "user_message", { text: `turn ${seq}` });
  if (phase === 2) return mux(sessionId, seq, "turn_started");
  if (phase === 0) return mux(sessionId, seq, "turn_result", { status: "completed" });
  if (phase % 20 === 5) return call(sessionId, seq, `c${seq}`, "start");
  if (phase % 20 === 6) return call(sessionId, seq, `c${seq - 1}`, undefined, `${OUTPUT} ${seq}`);
  if (phase % 20 === 7) return call(sessionId, seq, `c${seq - 2}`, "completed", `${OUTPUT} ${seq}`);
  return say(sessionId, seq, `m${Math.floor(seq / 20)}`);
}

type Snapshot = { rows: Record<string, unknown>[]; subagentViews?: Record<string, unknown[]> };
type Pane = {
  events: EventRecord[];
  rebuild: (changedFrom?: number) => void;
  emit: () => void;
};

/// A chat opened empty, then `count` records of `recordAt` streamed into it live while it follows its latest row;
/// every rebuild of its rows in that time is counted.
async function streamed(recordAt: (sessionId: string, seq: number) => EventRecord, count: number) {
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
        if (method === "_acpmux/events" && params.sessionId === target && params.beforeSeq !== undefined) {
          const limit = Number(params.limit ?? 400);
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
  let snapshot: Snapshot = { rows: [] };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (next) => (snapshot = next as unknown as Snapshot),
    undefined,
    () => new Chat() as unknown as WebSocket,
  );
  const pane = client as unknown as Pane;
  let rebuilds = 0;
  const rebuild = pane.rebuild.bind(client);
  pane.rebuild = (changedFrom) => {
    rebuilds += 1;
    rebuild(changedFrom);
  };
  client.setFollowing(true);
  expect(await settle(() => target !== "", 10_000)).toBe(true);
  for (let index = 0; index < 20; index += 1) await tick();
  const rebuildsBefore = rebuilds;
  let sheds = 0;
  let oldest = 1;
  for (let index = 0; index < count; index += 1) {
    total += 1;
    socket!.deliver({ jsonrpc: "2.0", method: "_acpmux/event", params: recordAt(target, total) });
    if (index % 50 === 49) {
      await tick();
      flush();
      const first = pane.events[0]?.seq ?? 1;
      if (first > oldest) sheds += 1;
      oldest = first;
    }
  }
  for (let index = 0; index < 20; index += 1) await tick();
  flush();
  if ((pane.events[0]?.seq ?? 1) > oldest) sheds += 1;
  return {
    pane,
    snapshot: () => snapshot,
    flush,
    total,
    sheds,
    rebuilds: () => rebuilds - rebuildsBefore,
    HELD_RECORDS,
    cleanup: () => {
      client.close?.();
      AcpmuxDirectClient.scheduleFrame = undefined;
    },
  };
}

/// What a row draws: every field but its version, which counts the writes a live fold and a refold make
/// differently (a refold reads a streamed call's thinned records), the frame a rebuild hands on, and the start of
/// the turn a reply ran in (`turnStartedAtMs`): a refold that starts inside a turn never reads its `turn_started`
/// record and dates none of its replies, where the rows a shed keeps go on saying when their turn began, as they
/// did on screen before it.
const drawn = (snapshot: Snapshot) =>
  snapshot.rows.map((row) => {
    const {
      version: _version,
      frame: _frame,
      turnStartedAtMs: _turnStartedAtMs,
      ...rest
    } = row as Record<string, unknown>;
    return JSON.stringify(rest);
  });

test("a turn that never ends, streamed past HELD_RECORDS, sheds its oldest records with no rebuild", async () => {
  const chat = await streamed(neverEnding, 16_000);
  try {
    // It shed, more than once, and holds no more than the budget.
    expect(chat.sheds).toBeGreaterThan(1);
    expect(chat.pane.events.length).toBeLessThanOrEqual(chat.HELD_RECORDS);
    expect(chat.pane.events.at(-1)!.seq).toBe(chat.total);
    console.log(`never-ending-turn streamed=${chat.total} sheds=${chat.sheds} rebuilds=${chat.rebuilds()}`);
    expect(chat.rebuilds()).toBe(0);
  } finally {
    chat.cleanup();
  }
}, 300_000);

test("the rows a turn that never ends keeps after its sheds are what a full rebuild of its records draws", async () => {
  const chat = await streamed(neverEnding, 16_000);
  try {
    expect(chat.sheds).toBeGreaterThan(1);
    const shed = chat.snapshot();
    const text = shed.rows.map((row) => String(row.text ?? "")).join(" ");
    expect(text).toContain("coordinate");
    chat.pane.rebuild();
    chat.pane.emit();
    chat.flush();
    const whole = chat.snapshot();
    expect(drawn(shed)).toEqual(drawn(whole));
    expect(Object.keys(shed.subagentViews ?? {}).sort()).toEqual(Object.keys(whole.subagentViews ?? {}).sort());
  } finally {
    chat.cleanup();
  }
}, 300_000);

test("the rows a chat of ended turns keeps after its sheds are what a full rebuild of its records draws", async () => {
  const chat = await streamed(endedTurns, 12_000);
  try {
    expect(chat.sheds).toBeGreaterThan(1);
    expect(chat.pane.events.length).toBeLessThanOrEqual(chat.HELD_RECORDS);
    const shed = chat.snapshot();
    chat.pane.rebuild();
    chat.pane.emit();
    chat.flush();
    expect(drawn(shed)).toEqual(drawn(chat.snapshot()));
  } finally {
    chat.cleanup();
  }
}, 300_000);
