// l10n-allow-file: transcript fixtures.
// Leo, 2026-11-12, on a "/compact" in his chat: "why was a /compact sent into your chat?", "i didnt
// send it myself", "we should not get into this state". acpmux's "Compact Before the Cache Expires"
// timer (cmux-tui hub/cache_compact.rs) sends `/compact` as its own prompt (provenance kind
// `cache_compact`), and the pane drew it as his own bubble. acpmux's own prompts never draw as the
// person's: the timer's draws no bubble and its compaction's note says why it ran.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../test/support/domTeardown";
import type { EventRecord } from "./direct";

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

// Bounded by turns of the event loop, not wall time: a loaded runner is slower, never red.
const settle = async (done: () => boolean) => {
  for (let turns = 0; !done(); turns += 1) {
    if (turns > 20_000) throw new Error(`never settled: ${done.toString()}`);
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
};

const at = (seq: number) => 1_700_000_000_000 + seq * 10;
const mux = (sessionId: string, seq: number, kind: string, msg: Record<string, unknown> = {}) =>
  ({ sessionId, seq, at: at(seq), dir: "mux", kind, msg }) as EventRecord;
const update = (sessionId: string, seq: number, body: Record<string, unknown>) =>
  ({
    sessionId,
    seq,
    at: at(seq),
    dir: "in",
    kind: String(body.sessionUpdate),
    msg: { method: "session/update", params: { sessionId, update: body } },
  }) as EventRecord;

type Row = {
  id: string;
  kind: string;
  text?: string;
  incoming?: { kind: string; message?: { name?: string } };
  compaction?: { state: string; reason?: string };
};

/// The rows of a chat whose history `history` writes, drawn as the pane draws it on attach.
async function drawn(history: (sessionId: string) => EventRecord[]): Promise<Row[]> {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  class Chat extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const self = this as unknown as { answer: (method: string, params: any) => Promise<unknown> };
      const answer = self.answer.bind(this);
      self.answer = async (method, params) => {
        if (method !== "_acpmux/attach") return answer(method, params);
        const result = (await answer(method, params)) as Record<string, unknown>;
        const events = history(params.sessionId);
        const lastSeq = events.at(-1)?.seq ?? 0;
        return { ...result, events, hasMore: false, lastSeq, pageThrough: lastSeq, turnOpener: null };
      };
    }
  }
  let rows: Row[] = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => (rows = snapshot.rows as Row[]),
    undefined,
    () => new Chat() as unknown as WebSocket,
  );
  await settle(() => rows.some((row) => row.kind === "compaction"));
  client.close();
  return rows;
}

const turn = (sessionId: string, seq: number, text: string, provenance?: Record<string, unknown>) => [
  mux(sessionId, seq, "user_message", {
    text,
    promptId: `p-${seq}`,
    turnId: `t-${seq}`,
    ...(provenance ? { _meta: { provenance } } : {}),
  }),
  mux(sessionId, seq + 1, "turn_started", { turnId: `t-${seq}` }),
];

test("the cache timer's /compact draws no bubble, and its compaction says it ran before the cache expired", async () => {
  const rows = await drawn((s) => [
    ...turn(s, 1, "Fix the sidebar"),
    update(s, 3, { sessionUpdate: "agent_message_chunk", messageId: "m1", content: { type: "text", text: "Fixed." } }),
    mux(s, 4, "turn_result", { status: "completed", turnId: "t-1" }),
    ...turn(s, 5, "/compact", { kind: "cache_compact" }),
    update(s, 7, { sessionUpdate: "compaction", state: "running" }),
    update(s, 8, { sessionUpdate: "compaction", state: "completed", preTokens: 412_000, postTokens: 31_000 }),
    mux(s, 9, "turn_result", { status: "completed", turnId: "t-5" }),
  ]);
  const prompts = rows.filter((row) => row.kind === "user" && row.incoming?.kind !== "hidden");
  expect(prompts.map((row) => row.text)).toEqual(["Fix the sidebar"]);
  const notes = rows.filter((row) => row.kind === "compaction");
  expect(notes).toHaveLength(1);
  expect(notes[0]!.compaction).toMatchObject({ state: "completed", reason: "cache_expiry" });
});

test("the person's own /compact stays theirs, and its compaction names no reason", async () => {
  const rows = await drawn((s) => [
    ...turn(s, 1, "/compact"),
    update(s, 3, { sessionUpdate: "compaction", state: "running" }),
    update(s, 4, { sessionUpdate: "compaction", state: "completed", preTokens: 412_000, postTokens: 31_000 }),
    mux(s, 5, "turn_result", { status: "completed", turnId: "t-1" }),
  ]);
  const prompts = rows.filter((row) => row.kind === "user" && row.incoming?.kind !== "hidden");
  expect(prompts.map((row) => row.text)).toEqual(["/compact"]);
  const notes = rows.filter((row) => row.kind === "compaction");
  expect(notes).toHaveLength(1);
  expect(notes[0]!.compaction?.reason).toBeUndefined();
});
