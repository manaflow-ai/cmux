import { expect, test } from "bun:test";
import { directClientStub } from "./support/directClientStub";
import { readThroughOf } from "../src/agent-session/acpmux/conversation/readThroughState";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

type SeenClient = {
  markSeenRows(session: string, rows: readonly Partial<AcpmuxRow>[], beforeSeq?: number): void;
  markSeenThrough(session: string, seq: number): void;
  seenOnReturn(session: string): void;
  onScreen?: { sessionId: string; seq: number };
  cursor?: { sessionId: string; seq: number | null };
  closed: boolean;
  viewSync: Promise<void>;
};

test("a blocked viewport revokes the candidate saved for focus return", async () => {
  const sessionId = "unseen-gap";
  const sent: number[] = [];
  const client = directClientStub<SeenClient>({
    selectedSessionId: sessionId,
    cursor: { sessionId, seq: 2 },
    onScreen: { sessionId, seq: 20 },
    viewSync: Promise.resolve(),
    typed: async (_method: string, params: { seq: number }) => {
      sent.push(params.seq);
      return { readThrough: params.seq };
    },
  });
  client.markSeenRows(sessionId, []);
  client.seenOnReturn(sessionId);
  await client.viewSync;
  expect(client.onScreen).toBeUndefined();
  expect(sent).toEqual([]);
  // Moving back to older rows also replaces, rather than retains, the idle high-water mark.
  client.onScreen = { sessionId, seq: 20 };
  client.markSeenRows(sessionId, [{ id: "older", seq: 1 }]);
  expect(client.onScreen).toEqual({ sessionId, seq: 1 });
});

test("first-open rows establish a cursor and streamed events cannot skip unseen rows below", async () => {
  const sessionId = "first-open-stream";
  const sent: number[] = [];
  const client = directClientStub<SeenClient>({
    selectedSessionId: sessionId,
    cursor: { sessionId, seq: null },
    viewSync: Promise.resolve(),
    rows: { seqOf: () => 30 },
    typed: async (_method: string, params: { seq: number }) => {
      sent.push(params.seq);
      return { readThrough: params.seq };
    },
  });
  client.markSeenRows(sessionId, [{ id: "streaming", seq: 3 }], 20);
  await client.viewSync;
  expect(sent).toEqual([19]);
  expect(readThroughOf(sessionId)).toBe(19);
  client.markSeenRows(sessionId, [{ id: "streaming", seq: 3 }]);
  await client.viewSync;
  expect(sent).toEqual([19, 30]);
  expect(client.cursor).toEqual({ sessionId, seq: 30 });
  client.markSeenRows(sessionId, [{ id: "folded", seq: 4, messageRun: { through: 40 } as AcpmuxRow["messageRun"] }]);
  await client.viewSync;
  expect(sent).toEqual([19, 30, 40]);
});

for (const persisted of [undefined, 2]) {
  for (const failure of ["rejected", "cancelled"] as const) {
    test(`${failure} seen request restores ${persisted ?? "no"} published cursor`, async () => {
      const sessionId = `seen-${failure}-${persisted ?? "none"}`;
      let calls = 0;
      const client = directClientStub<SeenClient>({
        selectedSessionId: sessionId,
        cursor: { sessionId, seq: persisted ?? null },
        viewSync: Promise.resolve(),
        typed: async () => {
          calls += 1;
          throw new Error("connection dropped");
        },
      });
      client.markSeenThrough(sessionId, 20);
      expect(readThroughOf(sessionId)).toBe(20);
      if (failure === "cancelled") client.closed = true;
      await client.viewSync;
      expect(calls).toBe(failure === "cancelled" ? 0 : 1);
      expect(readThroughOf(sessionId)).toBe(persisted);
    });
  }
}

test("returning publishes the New line before advancing readThrough, and dropping it clears the recap", async () => {
  const sessionId = "coord";
  const sent: Array<[string, Record<string, unknown>]> = [];
  const client = directClientStub<{
    markSeen(session: string): void;
    markSeenThrough(session: string, seq: number): void;
    viewSync: Promise<void>;
  }>({
    selectedSessionId: sessionId,
    shownToAcpmux: { sessionId, visible: true, attending: true },
    cursor: { sessionId, seq: 2 },
    onScreen: { sessionId, seq: 4 },
    viewSync: Promise.resolve(),
    rows: { turnsAfter: (seq: number) => (seq === 2 ? 1 : 0) },
    placeSince() {},
    typed: async (method: string, params: Record<string, unknown>) => {
      sent.push([method, params]);
      return { readThrough: params.seq };
    },
  });
  client.markSeen(sessionId);
  await client.viewSync;
  expect(sent).toEqual([
    ["_acpmux/view", { sessionId, visible: true, attending: true, cutoverSeq: 2 }],
    ["_acpmux/seen", { sessionId, seq: 4 }],
  ]);
  client.markSeenThrough(sessionId, 5);
  await client.viewSync;
  expect(sent.slice(2)).toEqual([["_acpmux/seen", { sessionId, seq: 5 }]]);
  client.markSeen(sessionId);
  await client.viewSync;
  expect(sent.at(-1)).toEqual(["_acpmux/view", { sessionId, visible: true, attending: true }]);
});
