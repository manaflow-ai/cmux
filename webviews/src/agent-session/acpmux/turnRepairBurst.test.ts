// A burst of finished turns costs one repair read at a time, not one per turn (goal
// chats-flat-at-any-length). Each live `turn_result` reads its turn's stored records back
// (`checkFinishedTurn`). A chat grown live to 100k rows in the chat-100k-flat bench (2026-11-15)
// ended about 41,000 turns in a few seconds, and its page then sent 41,664 of those reads, queued
// behind the request budget and drained at about 1,400 a second through what should have been idle
// (cmux-ci run 43676687555): 16x an empty chat's idle renderer CPU.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../test/support/domTeardown";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: "window" in scope,
  document: "document" in scope,
  values: { window: scope.window, document: scope.document },
};
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(async () => {
  await settleReact();
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

const CHAT = "0190a000-0000-7000-8000-0000000b0a51";
const TURNS = 300;
/// Seq of turn `turn`'s (1-based) records: its prompt, a reply chunk, its end and its result.
const seqOf = (turn: number, step: number) => (turn - 1) * 4 + step + 1;
/// The reply chunk the pane missed live; the stored record brings it back.
const LOST = seqOf(7, 1);

type Rec = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: unknown };
const stored: Rec[] = [];
for (let turn = 1; turn <= TURNS; turn += 1) {
  const at = 1_794_700_000_000 + turn * 1_000;
  const turnId = `t${turn}`;
  stored.push(
    {
      sessionId: CHAT,
      seq: seqOf(turn, 0),
      at,
      dir: "mux",
      kind: "user_message",
      msg: { text: `Question ${turn}`, promptId: `p${turn}`, turnId },
    },
    {
      sessionId: CHAT,
      seq: seqOf(turn, 1),
      at,
      dir: "in",
      kind: "agent_message_chunk",
      msg: {
        method: "session/update",
        params: {
          sessionId: CHAT,
          update: {
            sessionUpdate: "agent_message_chunk",
            content: { type: "text", text: `Answer ${turn}.` },
            messageId: `m${turn}`,
          },
        },
      },
    },
    { sessionId: CHAT, seq: seqOf(turn, 2), at, dir: "mux", kind: "turn_end", msg: { turnId, stopReason: "end_turn" } },
    {
      sessionId: CHAT,
      seq: seqOf(turn, 3),
      at,
      dir: "mux",
      kind: "turn_result",
      msg: { status: "completed", promptId: `p${turn}`, turnId },
    },
  );
}

test("a burst of finished turns sends one repair read at a time, and the merged read still repairs every turn", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const held: (() => void)[] = [];
  const reads: { afterSeq: number }[] = [];
  class HeldHost extends MockAcpmuxSocket {
    override send(raw: string): void {
      const request = JSON.parse(raw) as { id?: number; method: string; params?: Record<string, unknown> };
      const params = request.params ?? {};
      if (request.method !== "_acpmux/events" || params.afterSeq === undefined || params.sessionId !== CHAT)
        return super.send(raw);
      const afterSeq = Number(params.afterSeq);
      const limit = Number(params.limit ?? 400);
      reads.push({ afterSeq });
      held.push(() => {
        const after = stored.filter((record) => record.seq > afterSeq);
        const events = after.slice(0, limit);
        this.onmessage?.({
          data: JSON.stringify({
            jsonrpc: "2.0",
            id: request.id,
            result: { events, hasMore: after.length > limit, lastSeq: stored.at(-1)!.seq },
          }),
        });
      });
    }
  }
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => undefined,
    undefined,
    () => new HeldHost() as unknown as WebSocket,
  );
  const flush = async () => {
    for (let turn = 0; turn < 20; turn += 1) await new Promise((resolve) => setTimeout(resolve, 0));
  };
  try {
    await flush();
    const internals = client as unknown as {
      events: Rec[];
      selectedSessionId?: string;
      checkFinishedTurn(sessionId: string, endSeq: number): void;
    };
    internals.selectedSessionId = CHAT;
    // The pane heard every turn live but the one chunk.
    internals.events = stored.filter((record) => record.seq !== LOST);
    // Every turn ends while the first one's repair read is still out.
    for (let turn = 1; turn <= TURNS; turn += 1) internals.checkFinishedTurn(CHAT, seqOf(turn, 3));
    await flush();
    const outAtOnce = held.length;
    // One per turn was up to the request budget's 48 at once, with the rest queued behind it.
    expect(outAtOnce).toBe(1);
    for (let answered = 0; held.length > 0 && answered < TURNS * 4; answered += 1) {
      held.shift()!();
      await flush();
    }
    console.error(`[turn-repair] ${TURNS} finished turns: ${reads.length} reads, ${outAtOnce} out at once`);
    // One read for the first turn, one for every turn that ended while it was out.
    expect(reads.length).toBeLessThanOrEqual(2);
    // The merged read starts where the first turn's ends, so it covers every later turn.
    expect(reads[1]?.afterSeq).toBe(seqOf(1, 3));
    expect(internals.events.some((record) => record.seq === LOST)).toBe(true);
  } finally {
    client.close?.();
  }
});
