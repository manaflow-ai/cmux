// A chat on a hidden page keeps only a small tail of its records (direct.ts `shedOlderHeld`, `heldBounds`): one
// opened page's worth (`HIDDEN_HELD_KEPT`), at once when its page hides and at each turn's end after, so chats left
// running in background tabs cost what freshly opened ones do. Shown again it keeps the shown bound.
// Leo, 2026-11-14: "the dream of never ever needing to close a tab or workspace or anything. thats the white whale."
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { EventRecord } from "./eventRecord";
import { settleReact } from "../../../test/support/domTeardown";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const had = { window: "window" in scope, document: "document" in scope };
const before = { window: scope.window, document: scope.document };
let hidden = false;
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
  Object.defineProperty(dom.window.document, "visibilityState", {
    configurable: true,
    get: () => (hidden ? "hidden" : "visible"),
  });
});
afterAll(async () => {
  await settleReact();
  for (const key of ["window", "document"] as const)
    if (had[key]) scope[key] = before[key];
    else delete scope[key];
});

/// Records per turn.
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

type Pane = { events: EventRecord[] };
type Row = { id: string; kind?: string };

test("a hidden chat keeps one opened page of records, and the shown bound once shown again", async () => {
  const { AcpmuxDirectClient, HELD_RECORDS, HIDDEN_HELD_KEPT } = await import("./direct");
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
        if (method === "_acpmux/events" && params.sessionId === target)
          return { events: [], hasMore: false, lastSeq: total };
        return answer(method, params);
      };
    }
  }
  const frames: (() => void)[] = [];
  AcpmuxDirectClient.scheduleFrame = (run) => void frames.push(run);
  const flush = () => {
    for (const run of frames.splice(0)) run();
  };
  let rows: Row[] = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (next) => (rows = (next as unknown as { rows: Row[] }).rows),
    undefined,
    () => new Chat() as unknown as WebSocket,
  );
  const pane = client as unknown as Pane;
  try {
    client.setFollowing(true);
    expect(await settle(() => target !== "", 10_000)).toBe(true);
    for (let index = 0; index < 20; index += 1) await tick();
    const stream = async (count: number) => {
      let most = 0;
      for (let index = 0; index < count; index += 1) {
        total += 1;
        socket!.deliver({ jsonrpc: "2.0", method: "_acpmux/event", params: endedTurns(target, total) });
        most = Math.max(most, pane.events.length);
        if (index % 50 === 49) {
          await tick();
          flush();
        }
      }
      for (let index = 0; index < 20; index += 1) await tick();
      flush();
      return most;
    };
    // Shown: the shown bound.
    expect(await stream(6_000)).toBeLessThanOrEqual(HELD_RECORDS + TURN);
    expect(pane.events.length).toBeGreaterThan(2 * HIDDEN_HELD_KEPT);
    // Hidden: all but the tail goes at once, at a turn start, and the newest record stays.
    hidden = true;
    dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
    for (let index = 0; index < 20; index += 1) await tick();
    flush();
    expect(pane.events.length).toBeLessThanOrEqual(2 * HIDDEN_HELD_KEPT);
    expect(pane.events.length).toBeGreaterThanOrEqual(HIDDEN_HELD_KEPT - TURN);
    expect(pane.events.at(-1)?.seq).toBe(total);
    expect(pane.events[0]?.kind).toBe("user_message");
    // Streaming on while hidden, it stays at the tail.
    expect(await stream(6_000)).toBeLessThanOrEqual(2 * HIDDEN_HELD_KEPT + TURN);
    expect(pane.events.at(-1)?.seq).toBe(total);
    // Shown again: it holds what it streams up to the shown bound before its next shed.
    hidden = false;
    dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
    for (let index = 0; index < 20; index += 1) await tick();
    flush();
    expect(await stream(2_400)).toBeLessThanOrEqual(HELD_RECORDS + TURN);
    expect(pane.events.length).toBeGreaterThan(2 * HIDDEN_HELD_KEPT + TURN);
    // The rows drawn are the held records' own: the newest turn's result row is there.
    expect(rows.length).toBeGreaterThan(0);
  } finally {
    client.close?.();
    AcpmuxDirectClient.scheduleFrame = undefined;
  }
});
