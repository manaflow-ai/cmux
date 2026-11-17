// A running turn of tool calls that never ends (chat-100k-flat.bench.ts's running_x1: a reply chunk with no
// messageId, a command's call and its completed update, step after step) holds a bounded number of records and rows,
// as one whose messages carry ids does (longChatNeverEnding.test.ts).
// Leo, 2026-11-14: "the bigger question is of memory and cpu staying flat on infinite chats. i obviously dont mean
// infinite at once, but the dream of never ever needing to close a tab or workspace or anything. thats the white
// whale."
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

test("a running turn of calls holds a bounded number of records and rows", async () => {
  const sizes: Record<number, { events: number; rows: number; most: number }> = {};
  for (const count of [6_000, 24_000]) {
    const chat = await streamed(count, true);
    try {
      const held = chat.events();
      sizes[count] = { events: held.length, rows: chat.snapshot().rows.length, most: chat.most };
      console.log(
        `running-calls streamed=${count} retained_events=${held.length} max_events=${chat.most} ` +
          `rows=${chat.snapshot().rows.length}`,
      );
      expect(held.at(-1)!.seq).toBe(chat.total);
    } finally {
      chat.cleanup();
    }
  }
  const large = sizes[24_000]!;
  expect(large.most).toBeLessThanOrEqual(6_000);
  expect(large.rows).toBeLessThanOrEqual(sizes[6_000]!.rows * 1.2);
}, 600_000);
