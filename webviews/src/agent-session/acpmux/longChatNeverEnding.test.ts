// A chat left open on a turn that never ends (a coordinator's: prompts and messages keep arriving into one running
// turn) holds a bounded number of records, as one at a turn's end does (direct.ts `shedOlderHeld`). It sheds on a
// count budget, not only at a `turn_result`, at a record no row spans inside the turn, keeping that turn's prompt as
// the opener a page that starts mid-turn is drawn with; a subagent left "running" whose start is older than the
// budget does not pin the cut. Scrolling up reads what left as any older page.
// Leo, 2026-11-12: "even if a chat is long, there should be no percievable difference". Leo, 2026-11-14: "the dream
// is infinite chats of infinite length with flat or no growth in cpu/memory/even disk".
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

/// Records per message: its streamed chunks, then a tool call with a streamed output.
const MESSAGE = 25;
/// A tool call's streamed output, as acpmux sends it whole with each update.
const OUTPUT = "x".repeat(400);

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

/// One turn that never ends: its prompt, its start, a subagent that says it runs and never says more, then
/// messages and tool calls forever, with a steer into the running turn now and then.
function recordAt(sessionId: string, seq: number): EventRecord {
  const at = 1_700_000_000_000 + seq * 10;
  if (seq === 1) return { sessionId, seq, at, dir: "mux", kind: "user_message", msg: { text: "coordinate" } };
  if (seq === 2) return { sessionId, seq, at, dir: "mux", kind: "turn_started", msg: {} };
  if (seq === 3)
    return inbound(
      sessionId,
      seq,
      { sessionUpdate: "subagent_progress" },
      { subagents: [{ id: "stale", parent: null, name: "Stale helper", state: "running" }] },
    );
  const phase = seq % MESSAGE;
  const message = Math.floor(seq / MESSAGE);
  if (phase === 0 && message % 40 === 0)
    return { sessionId, seq, at, dir: "mux", kind: "user_message", msg: { text: `steer ${seq}`, steer: true } };
  if (phase === MESSAGE - 3)
    return inbound(sessionId, seq, {
      sessionUpdate: "tool_call",
      toolCallId: `t${message}`,
      kind: "execute",
      title: `run ${message}`,
      status: "in_progress",
    });
  if (phase === MESSAGE - 2 || phase === MESSAGE - 1)
    return inbound(sessionId, seq, {
      sessionUpdate: "tool_call_update",
      toolCallId: `t${message}`,
      ...(phase === MESSAGE - 1 ? { status: "completed" } : {}),
      content: [{ type: "content", content: { type: "text", text: `${OUTPUT} ${message}` } }],
    });
  return inbound(sessionId, seq, {
    sessionUpdate: "agent_message_chunk",
    messageId: `m${message}`,
    content: { type: "text", text: `w${seq} ` },
  });
}

/// A chat opened empty, then `count` records of one never-ending turn streamed into it live.
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

const retainedBytes = (events: readonly EventRecord[]) => {
  let bytes = 0;
  for (const event of events) bytes += JSON.stringify(event).length;
  return bytes;
};

/// The JS heap after a collection, in MB (bun's `Bun.gc`, else what the process reports).
const heapMb = () => {
  const bun = (globalThis as { Bun?: { gc?: (sync: boolean) => void } }).Bun;
  bun?.gc?.(true);
  return process.memoryUsage().heapUsed / 1e6;
};

test("a never-ending turn with a stale running subagent holds a bounded number of records", async () => {
  const sizes: Record<number, { events: number; bytes: number; heapMb: number; most: number }> = {};
  for (const count of [6_000, 24_000]) {
    const chat = await streamed(count, true);
    try {
      const held = chat.events();
      sizes[count] = { events: held.length, bytes: retainedBytes(held), heapMb: heapMb(), most: chat.most };
      // The before/after row this test reports (one harness): retained records, their bytes, the JS heap.
      console.log(
        `never-ending-turn streamed=${count} retained_events=${held.length} max_events=${chat.most} ` +
          `retained_bytes=${sizes[count]!.bytes} heap_mb=${sizes[count]!.heapMb.toFixed(1)}`,
      );
      expect(held.at(-1)!.seq).toBe(chat.total);
    } finally {
      chat.cleanup();
    }
  }
  const small = sizes[6_000]!;
  const large = sizes[24_000]!;
  // Bounded: four times the records streamed holds what one time does, near the budget.
  expect(large.most).toBeLessThanOrEqual(large.events + 2 * MESSAGE + 1_000);
  expect(large.events).toBeLessThanOrEqual(large.most);
  expect(large.most).toBeLessThanOrEqual(6_000);
  expect(large.bytes).toBeLessThanOrEqual(small.bytes * 1.2);
}, 600_000);

test("a never-ending turn sheds mid-turn, draws its newest words, and pages back what left", async () => {
  const chat = await streamed(16_000, true);
  try {
    const held = chat.events();
    expect(held.length).toBeLessThanOrEqual(chat.HELD_RECORDS);
    expect(held.at(-1)!.seq).toBe(chat.total);
    const text = () =>
      chat
        .snapshot()
        .rows.map((row) => row.text ?? "")
        .join(" ");
    // The turn's newest words are drawn; the turn's prompt still opens what is drawn.
    let newestWord = chat.total;
    while (recordAt("s", newestWord).kind !== "agent_message_chunk") newestWord -= 1;
    expect(text()).toContain(`w${newestWord} `);
    expect(text()).toContain("coordinate");
    expect(chat.snapshot().canLoadOlder).toBe(true);
    expect(chat.snapshot().historyFrom).toBe(held[0]!.seq);
    // Scrolling up reads the records that left back in, above the rows kept.
    const oldest = held[0]!.seq;
    let olderWord = oldest - 1;
    while (recordAt("s", olderWord).kind !== "agent_message_chunk") olderWord -= 1;
    expect(text()).not.toContain(`w${olderWord} `);
    await chat.client.loadOlder();
    for (let index = 0; index < 20; index += 1) await tick();
    chat.flush();
    expect(chat.events()[0]!.seq).toBeLessThan(oldest);
    expect(text()).toContain(`w${olderWord} `);
    expect(text()).toContain(`w${newestWord} `);
  } finally {
    chat.cleanup();
  }
}, 300_000);

test("a never-ending turn the reader scrolled up in keeps every record it holds", async () => {
  const chat = await streamed(6_000, false);
  try {
    expect(chat.events().length).toBe(6_000);
    expect(chat.events()[0]!.seq).toBe(1);
  } finally {
    chat.cleanup();
  }
}, 300_000);
