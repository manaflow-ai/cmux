import { expect, test } from "bun:test";
import { directClientStub } from "./support/directClientStub";

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
