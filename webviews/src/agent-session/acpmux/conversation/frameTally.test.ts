import { describe, expect, it } from "bun:test";

import { BUCKETS, FLUSH_MS, FrameTally } from "./frameTally";

function harness() {
  const timers: { callback: () => void; ms: number }[] = [];
  const sent: Record<string, unknown>[] = [];
  const tally = new FrameTally((callback, ms) => timers.push({ callback, ms }));
  return { tally, timers, sent, send: async (params: Record<string, unknown>) => void sent.push(params) };
}

describe("frame tally", () => {
  it("buckets each gap by 0.1 ms, a 60 Hz frame in 16.6-16.7 and a long one in the overflow", () => {
    const { tally } = harness();
    for (const gap of [1000 / 60, 1000 / 60, 33.4, 250, 0, -1, 6000, Number.NaN]) tally.note(gap);
    expect(tally.held()).toEqual([
      [166, 2],
      [334, 1],
      [BUCKETS, 1],
    ]);
  });

  it("sends nothing and sets no timer until a client is attached and a frame comes", async () => {
    const { tally, timers, sent, send } = harness();
    tally.attach(send);
    expect(timers).toHaveLength(0);
    tally.note(16.7);
    tally.note(16.6);
    expect(timers).toHaveLength(1);
    expect(timers[0]!.ms).toBe(FLUSH_MS);
    timers[0]!.callback();
    await Promise.resolve();
    expect(sent).toEqual([
      {
        op: "tally",
        bucketMs: 0.1,
        gaps: [
          [166, 1],
          [167, 1],
        ],
      },
    ]);
    expect(tally.held()).toEqual([]);
    // Empty after the flush: no further timer until the next frame.
    expect(timers).toHaveLength(1);
  });

  it("holds frames noted before the client connects and sends them once it does", () => {
    const { tally, timers, sent, send } = harness();
    tally.note(20);
    expect(timers).toHaveLength(0);
    tally.attach(send);
    expect(timers).toHaveLength(1);
    timers[0]!.callback();
    expect(sent).toHaveLength(1);
  });

  it("stops for good after 30 failed sends in a row", async () => {
    const timers: (() => void)[] = [];
    let calls = 0;
    const tally = new FrameTally((callback) => timers.push(callback));
    tally.attach(async () => {
      calls += 1;
      throw new Error("gone");
    });
    for (let round = 0; round < 40; round += 1) {
      tally.note(16.6);
      timers.shift()?.();
      await Promise.resolve();
      await Promise.resolve();
    }
    expect(calls).toBe(30);
    tally.note(16.6);
    expect(tally.held()).toEqual([]);
  });
});
