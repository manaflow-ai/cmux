import { describe, expect, test } from "bun:test";
import { curveRatios, godRows } from "../bench/god-length-curve.bench";

describe("god-length-curve", () => {
  test("reads the god rows' p95 from a replay's output", () => {
    const output = [
      "transcript-replay: god live",
      'PERF_ROW {"name":"transcript_replay.god.long.token_ms","p50":7,"p95":9,"unit":"ms"}',
      'PERF_ROW {"name":"transcript_replay.god.long.thought_ms","p50":5,"p95":6,"unit":"ms"}',
      'PERF_ROW {"name":"transcript_replay.god.long.heap_mb","p50":30,"p95":31,"unit":"MB"}',
      'PERF_ROW {"name":"transcript_replay.long.token_ms","p50":1,"p95":2,"unit":"ms"}',
      "PERF_ROW not json",
    ].join("\n");
    expect(godRows(output)).toEqual({ token_ms: 9, thought_ms: 6, heap_mb: 31 });
  });

  test("the curve's ratio is the longest replay over the shortest, whatever the order", () => {
    const { ratios, max } = curveRatios([
      { turns: 100000, rows: { token_ms: 11, thought_ms: 6, heap_mb: 33 } },
      { turns: 1000, rows: { token_ms: 10, thought_ms: 6, heap_mb: 30 } },
      { turns: 10000, rows: { token_ms: 50, thought_ms: 6, heap_mb: 31 } },
    ]);
    expect(ratios.token_ms).toBeCloseTo(1.1);
    expect(ratios.thought_ms).toBeCloseTo(1);
    expect(ratios.heap_mb).toBeCloseTo(1.1);
    expect(max).toBeCloseTo(1.1);
  });

  test("a metric missing at either end is left out", () => {
    const { ratios, max } = curveRatios([
      { turns: 1000, rows: { token_ms: 10 } },
      { turns: 100000, rows: { token_ms: 15, heap_mb: 30 } },
    ]);
    expect(ratios).toEqual({ token_ms: 1.5 });
    expect(max).toBeCloseTo(1.5);
  });
});

describe("transcript-replay TAIL=1", () => {
  test("opens at the last checkpoint's turn: every burst kind after it, its prompt included", async () => {
    const { tailStart } = await import("../bench/transcript-replay.bench");
    const { godLog } = await import("../bench/godFixture");
    const log = godLog("god", { turns: 40 });
    const from = tailStart(log);
    expect(from).toBeGreaterThan(0);
    expect(log.events[from - 1]!.kind).toBe("turn_result");
    const after = log.bursts.filter((burst) => burst.fromSeq >= log.events[from]!.seq);
    expect(new Set(after.map((burst) => burst.kind))).toEqual(new Set(log.bursts.map((burst) => burst.kind)));
    // Only the last checkpoint's: well under the whole log.
    expect(log.events.length - from).toBeLessThan(log.events.length / 4);
  });
});
