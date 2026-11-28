import { describe, expect, test } from "bun:test";
import { directClientStub } from "./support/directClientStub";
import type { EventRecord } from "../src/agent-session/acpmux/direct";

const event = (seq: number, text: string): EventRecord => ({
  sessionId: "replay",
  seq,
  at: seq,
  dir: "mux",
  kind: "status",
  msg: { text },
});

type Page = { events: EventRecord[]; hasMore: boolean; pageThrough?: number };

function clientWithPages(pages: (after: number) => Page) {
  const requests: { afterSeq: number; limit: number }[] = [];
  const client = directClientStub({
    typed: async (_method: string, params: { afterSeq: number; limit: number }) => {
      requests.push({ afterSeq: params.afterSeq, limit: params.limit });
      return pages(params.afterSeq);
    },
  });
  return { client, requests };
}

describe("recorded replay pagination", () => {
  test("keeps the first overlapping record and requests bounded pages", async () => {
    const { client, requests } = clientWithPages((after) =>
      after === 0
        ? { events: [event(1, "first"), event(2, "original")], hasMore: true, pageThrough: 2 }
        : { events: [event(2, "duplicate"), event(3, "third")], hasMore: false, pageThrough: 3 },
    );

    const events = await client.recordedEvents("replay");

    expect(requests).toEqual([
      { afterSeq: 0, limit: 400 },
      { afterSeq: 2, limit: 400 },
    ]);
    expect(events.map((record) => [record.seq, record.msg.text])).toEqual([
      [1, "first"],
      [2, "original"],
      [3, "third"],
    ]);
  });

  test("advances from the maximum sequence in an out-of-order page", async () => {
    const { client, requests } = clientWithPages((after) =>
      after === 0
        ? { events: [event(3, "third"), event(1, "first"), event(2, "second")], hasMore: true }
        : { events: [], hasMore: false, pageThrough: 3 },
    );

    await expect(client.recordedEvents("replay")).resolves.toHaveLength(3);
    expect(requests.map((request) => request.afterSeq)).toEqual([0, 3]);
  });

  test("continues through an empty filtered page when its watermark advances", async () => {
    const { client, requests } = clientWithPages((after) =>
      after === 0
        ? { events: [], hasMore: true, pageThrough: 5 }
        : { events: [event(6, "six")], hasMore: false, pageThrough: 6 },
    );

    await expect(client.recordedEvents("replay")).resolves.toEqual([event(6, "six")]);
    expect(requests.map((request) => request.afterSeq)).toEqual([0, 5]);
  });

  test("fails instead of silently truncating a stalled cursor", async () => {
    const { client } = clientWithPages(() => ({ events: [], hasMore: true, pageThrough: 0 }));

    await expect(client.recordedEvents("replay")).rejects.toThrow("journal_replay_cursor_stalled");
  });
});
