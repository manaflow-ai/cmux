// l10n-allow-file: test fixtures.
// A forward replay seek (a frame of playback) folds only the events it adds: its cost must not
// grow with the log. Counted, not timed: how many log entries one seek reads.
import { describe, expect, test } from "bun:test";
import { AcpmuxDirectClient, replayIndexAfter, type EventRecord } from "../direct";
import { continueSeq, replayTimeline } from "./timeline";

function log(turns: number): EventRecord[] {
  const events: EventRecord[] = [];
  let seq = 0;
  let at = Date.UTC(2026, 10, 19);
  const push = (dir: string, kind: string, msg: Record<string, unknown>) =>
    events.push({ sessionId: "s", seq: ++seq, at: (at += 100), dir, kind, msg });
  for (let turn = 0; turn < turns; turn += 1) {
    push("mux", "user_message", { text: `prompt ${turn}` });
    push("in", "agent_message_chunk", {
      method: "session/update",
      params: { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `reply ${turn}` } } },
    });
    push("mux", "turn_result", { status: "completed" });
  }
  return events;
}

/// Counts the reads of `events`' entries by index while `run` runs.
function reads(events: EventRecord[], run: () => void): number {
  let count = 0;
  const counted = new Proxy(events, {
    get(target, key, receiver) {
      if (typeof key === "string" && /^\d+$/.test(key)) count += 1;
      return Reflect.get(target, key, receiver);
    },
  });
  run.call(counted);
  return count;
}

describe("replay seek cost", () => {
  test("the resume point is a binary search of the sorted log", () => {
    const events = log(10);
    expect(replayIndexAfter(events, 0)).toBe(0);
    expect(replayIndexAfter(events, 5)).toBe(5);
    expect(replayIndexAfter(events, 30)).toBe(30);
    expect(replayIndexAfter(events, 99)).toBe(30);
    const big = log(100_000);
    expect(
      reads(big, function (this: EventRecord[]) {
        replayIndexAfter(this, 150_000);
      }),
    ).toBeLessThanOrEqual(20);
  });

  test("a frame of playback reads the events it adds, whatever the log's length", () => {
    for (const turns of [1_000, 30_000]) {
      const client = AcpmuxDirectClient.replay("s", log(turns), () => undefined);
      const middle = turns * 3 * 0.5;
      client.seekReplay(middle);
      // One frame forward, three events.
      const held = (client as unknown as { events: EventRecord[] }).events;
      const count = reads(held, function (this: EventRecord[]) {
        (client as unknown as { events: EventRecord[] }).events = this;
        client.seekReplay(middle + 3);
      });
      (client as unknown as { events: EventRecord[] }).events = held;
      // A binary search (log2 of 90,000 is under 17) plus the events folded and the one past them.
      expect(count).toBeLessThanOrEqual(24);
    }
  });

  test("Continue from here finds its turn without walking every turn", () => {
    const timeline = replayTimeline(log(5));
    expect(continueSeq(timeline, -1)).toBeUndefined();
    expect(continueSeq(timeline, timeline.duration)).toBe(15);
    const second = timeline.turnEnds[1]!;
    expect(continueSeq(timeline, second.time)).toBe(second.seq);
    expect(continueSeq(timeline, second.time - 1)).toBe(timeline.turnEnds[0]!.seq);
  });
});
