// A live record that is not a row's stream (a subagent's progress, a task note, a status) named its own kind in the
// snapshot's `connection`, so the frame after it read as a changed snapshot and the next thought or reply chunk fell
// through every row-local bypass (liveThought.ts, streamingRow.ts) to a whole-pane draw. On the recorded lane session
// (test/fixtures/chat-sim/replay-lane-session.ndjson) 528 such records sit between 2,176 streamed chunks.
// Leo (rulebook): "Root-fix anything slow, stalling, uncached, growing".
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { AcpmuxSnapshot } from "./model";
import type { EventRecord } from "./direct";
import { recordReason, sameButRows, sameLink } from "./liveToolOutput";
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

test("a live record's kind is not a link state; the client's own reasons are", () => {
  for (const kind of [
    "agent_thought_chunk",
    "subagent_progress",
    "claude.system.task_progress",
    "session_info_update",
    "status",
    "response",
  ])
    expect(recordReason(kind)).toBe(true);
  for (const reason of [
    "connected",
    "disconnected",
    "attached",
    "failed",
    "debug",
    "session changed",
    "waiting: daemon",
  ])
    expect(recordReason(reason)).toBe(false);
  expect(sameLink("subagent_progress", "agent_thought_chunk")).toBe(true);
  expect(sameLink("status", "claude.system.task_progress")).toBe(true);
  expect(sameLink("agent_thought_chunk", "disconnected")).toBe(false);
  expect(sameLink("connecting: daemon", "agent_thought_chunk")).toBe(false);
  expect(sameLink("attached", "tool_call")).toBe(false);
  expect(sameLink("failed", "connected")).toBe(false);
});

const SESSION_TURN = "t-live";
const at = (seq: number) => 1_700_000_000_000 + seq * 10;
const inbound = (sessionId: string, seq: number, update: Record<string, unknown>) =>
  ({
    sessionId,
    seq,
    at: at(seq),
    dir: "in",
    kind: update.sessionUpdate,
    msg: { method: "session/update", params: { sessionId, update } },
  }) as EventRecord;
const mux = (sessionId: string, seq: number, kind: string, msg: Record<string, unknown> = {}) =>
  ({ sessionId, seq, at: at(seq), dir: "mux", kind, msg }) as EventRecord;
const thought = (sessionId: string, seq: number, text: string) =>
  inbound(sessionId, seq, { sessionUpdate: "agent_thought_chunk", content: { type: "text", text } });
const progress = (sessionId: string, seq: number) =>
  inbound(sessionId, seq, {
    sessionUpdate: "subagent_progress",
    agentId: "helper",
    subagentSessionId: "helper-session",
    elapsedMs: seq * 100,
    tokens: seq,
    toolUses: 1,
  });

test("records of one frame draw once, in order, and the chunk after a non-stream record keeps the row fast path", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { forgetTail } = await import("./tailCache");
  forgetTail(mockHost.sessionId!);
  let target = "";
  const running = { status: "running", indicator: "working", turn: { turnId: SESSION_TURN, startedAt: at(2) } };
  let socket: { deliver: (message: unknown) => void } | undefined;
  class Chat extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      socket = this as unknown as typeof socket;
      const self = this as unknown as { answer: (method: string, params: any) => Promise<unknown> };
      const answer = self.answer.bind(this);
      self.answer = async (method, params) => {
        if (method === "_acpmux/attach") {
          const result = (await answer(method, params)) as Record<string, any>;
          target = params.sessionId;
          return {
            ...result,
            session: { ...result.session, ...running },
            events: [],
            hasMore: false,
            lastSeq: 0,
            pageThrough: 0,
            turnOpener: null,
          };
        }
        if (method === "_acpmux/events" && params.sessionId === target)
          return { events: [], hasMore: false, lastSeq: 0 };
        return answer(method, params);
      };
    }
  }
  const frames: (() => void)[] = [];
  AcpmuxDirectClient.scheduleFrame = (run) => void frames.push(run);
  const snapshots: AcpmuxSnapshot[] = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot: AcpmuxSnapshot) => void snapshots.push(snapshot),
    undefined,
    () => new Chat() as unknown as WebSocket,
  );
  const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
  try {
    client.setFollowing(true);
    for (let index = 0; index < 400 && !target; index += 1) await tick();
    expect(target).not.toBe("");
    for (let index = 0; index < 20; index += 1) await tick();
    let seq = 0;
    const deliver = (record: (sessionId: string, seq: number) => EventRecord) => {
      seq += 1;
      socket!.deliver({ jsonrpc: "2.0", method: "_acpmux/event", params: record(target, seq) });
    };
    // The socket hands records on in a task of their own: wait for them, then run the frame.
    const landed = async () => {
      for (let index = 0; index < 5; index += 1) await tick();
    };
    const flush = () => {
      for (const run of frames.splice(0)) run();
    };
    deliver((id, n) => mux(id, n, "user_message", { text: "go", promptId: "p-live" }));
    deliver((id, n) => mux(id, n, "turn_started", { promptId: "p-live", turnId: SESSION_TURN }));
    deliver((id, n) => thought(id, n, "a"));
    await landed();
    flush();

    // One frame: thought chunks with a subagent's progress between them.
    const drawn = snapshots.length;
    deliver((id, n) => thought(id, n, "b"));
    deliver(progress);
    deliver((id, n) => thought(id, n, "c"));
    deliver(progress);
    await landed();
    expect(snapshots.length).toBe(drawn);
    flush();
    expect(snapshots.length).toBe(drawn + 1);
    const framed = snapshots.at(-1)!;
    const thoughts = (snapshot: AcpmuxSnapshot) =>
      snapshot.rows
        .flatMap((row) => (row as { items?: { kind: string; text?: string }[] }).items ?? [])
        .filter((item) => item.kind === "thought")
        .map((item) => item.text)
        .join("");
    // Every chunk of the frame, in the order it came: none dropped, none reordered by the progress between.
    expect(thoughts(framed)).toBe("abc");

    // The next frame is one thought chunk: only its row changed, though the frame before ended on a progress record.
    deliver((id, n) => thought(id, n, "d"));
    await landed();
    flush();
    expect(snapshots.length).toBe(drawn + 2);
    const next = snapshots.at(-1)!;
    expect(framed.connection).toBe("subagent_progress");
    expect(next.connection).toBe("agent_thought_chunk");
    expect(thoughts(next)).toBe("abcd");
    expect(sameButRows(framed, next)).toBe(true);
  } finally {
    client.close?.();
    AcpmuxDirectClient.scheduleFrame = undefined;
  }
});
