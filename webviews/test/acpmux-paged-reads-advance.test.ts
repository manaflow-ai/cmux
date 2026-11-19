// l10n-allow-file: fixture IDs and comments are not shipped UI.
// A paged read of a chat's records ends on a page that says `hasMore` but holds nothing past its
// cursor: it does not ask for the same page again forever (Leo, 2026-11-16: "the dream is infinite
// chats of infinite length with flat or no growth in cpu/memory/even disk"). fetchMissedEvents'
// case is in agent-pane-remote-resync-frames.test.ts; the session list's follow is in
// agent-session-pager-follow.test.ts.
import { expect, test } from "bun:test";
import { directClientStub } from "./support/directClientStub";

const record = (seq: number) => ({ sessionId: "s", seq, at: seq, dir: "in", kind: "agent_message_chunk", msg: {} });

test("the turn repair read fails on a page that says more but holds nothing past its cursor, and says why", async () => {
  const asked: number[] = [];
  const logged: string[] = [];
  const client = directClientStub<{
    readTurnRecords(sessionId: string, generation: number, afterSeq: number, endSeq: number): Promise<unknown[]>;
  }>({
    selectedSessionId: "s",
    selectionGeneration: 1,
    wire: { lifecycle: (event: string) => logged.push(event) },
    // Every page answers the record at the cursor again and says there are more.
    typed: async (_method: string, params: { afterSeq: number }) => {
      asked.push(params.afterSeq);
      if (asked.length > 5) throw new Error("read the same page again and again");
      return { events: [record(params.afterSeq)], hasMore: true };
    },
  });
  // A failure, so repairTurns retries it on its bounded delays; it never resolves as a complete read.
  await expect(client.readTurnRecords("s", 1, 10, 20)).rejects.toThrow("said more but held nothing past it");
  expect(asked).toEqual([10]);
  expect(logged).toEqual(["turn repair read stalled"]);
});

test("the turn repair read still pages on while each page moves its cursor", async () => {
  const asked: number[] = [];
  const client = directClientStub<{
    readTurnRecords(sessionId: string, generation: number, afterSeq: number, endSeq: number): Promise<unknown[]>;
  }>({
    selectedSessionId: "s",
    selectionGeneration: 1,
    typed: async (_method: string, params: { afterSeq: number }) => {
      asked.push(params.afterSeq);
      const next = params.afterSeq + 1;
      return { events: [record(next)], hasMore: next < 13 };
    },
  });
  const stored = await client.readTurnRecords("s", 1, 10, 20);
  expect(asked).toEqual([10, 11, 12]);
  expect(stored).toHaveLength(3);
});
