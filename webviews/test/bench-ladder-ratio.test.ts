import { describe, expect, test } from "bun:test";
import { cycleRate, interpolate, majorGcEnds, marginalRatio, marginals, ratioInterval } from "../bench/ladderRatio";

describe("sim-ladder marginal ratio", () => {
  test("a constant cost per item reads flat", () => {
    expect(marginalRatio("pss_mb", [1, 10, 100], [100, 190, 1090])).toBeCloseTo(1, 6);
  });
  test("a per-item cost that grows with the count reads above 1", () => {
    // 10 MB per item to 10, then 20 MB per item to 100.
    expect(marginalRatio("pss_mb", [1, 10, 100], [100, 190, 1990])).toBeCloseTo(2, 6);
  });
  test("both marginals under the noise floor read flat", () => {
    expect(marginalRatio("cpu_ms_per_s", [1, 10, 100], [30, 30, 31])).toBe(1);
  });
  test("a zero low marginal is divided by the floor, not by zero", () => {
    expect(marginalRatio("cpu_ms_per_s", [1, 10, 100], [30, 30, 120])).toBeCloseTo(1 / 0.5, 6);
  });
  test("a GC burst over the whole window reads far above flat (hq#21290: 52, 46, 1337 ms/s)", () => {
    expect(marginalRatio("cpu_window_ms_per_s", [1, 10, 100], [52, 46, 1337])).toBeGreaterThan(20);
  });
  test("heap after a full collection is judged per chat (42, 259, 1853 MB)", () => {
    expect(marginalRatio("heap_mb", [1, 10, 100], [42, 259, 1853])).toBeCloseTo(17.71 / 24.11, 2);
  });
  test("frame p95 is the top rung against the middle, never under one frame", () => {
    expect(marginalRatio("frame_p95_ms", [1, 10, 100], [16, 10, 33.4])).toBeCloseTo(2, 2);
  });
  // The CPU readings carry each rung's standard error (the spread of its 5 s windows over sqrt(n)): the interval is
  // printed beside the ratio and never changes it.
  test("a ratio two noises made keeps its number, and its interval shows it (114 / 68 / 117 +- 30 ms/s)", () => {
    const values = [114, 68, 117];
    expect(marginalRatio("cpu_window_ms_per_s", [10, 50, 100], values)).toBeCloseTo(0.98 / 0.5, 2);
    const ci = ratioInterval("cpu_window_ms_per_s", [10, 50, 100], values, [30, 30, 30]);
    expect(ci.lo).toBeLessThan(1);
    expect(ci.hi).toBeGreaterThan(1.96);
    expect(ci.lo).toBeLessThanOrEqual(1.96);
  });
  test("a measured growth reads above flat with an interval above flat: GC in step with the heap is a real cost", () => {
    // 1 ms/s per chat to 50, then 3 ms/s per chat to 100, each rung read to +- 2 ms/s.
    const values = [60, 100, 250];
    expect(marginalRatio("cpu_window_ms_per_s", [10, 50, 100], values)).toBeCloseTo(3, 6);
    const ci = ratioInterval("cpu_window_ms_per_s", [10, 50, 100], values, [2, 2, 2]);
    expect(ci.lo).toBeGreaterThan(2);
    expect(ci.hi).toBeLessThan(4);
  });
  test("the interval's ends use the same floor as the ratio", () => {
    // low 0 +- 0.1 per item: every corner divides by FLOOR (0.5).
    const ci = ratioInterval("cpu_window_ms_per_s", [10, 50, 100], [60, 60, 110], [1.4, 1.4, 1.4]);
    expect(ci.floor).toBe(0.5);
    expect(ci.lo).toBeCloseTo((1 - (2 * Math.hypot(1.4, 1.4)) / 50) / 0.5, 6);
    expect(ci.hi).toBeCloseTo((1 + (2 * Math.hypot(1.4, 1.4)) / 50) / 0.5, 6);
  });
  test("each marginal's error comes from its two rungs", () => {
    const m = marginals([10, 50, 100], [0, 0, 0], [3, 4, 0]);
    expect(m.lowSe).toBeCloseTo(5 / 40, 9);
    expect(m.highSe).toBeCloseTo(4 / 50, 9);
  });
});

describe("sim-ladder whole collection cycles", () => {
  // A heap that idles at 60 ms/s and pays a 1.3 s collection every 8 s: CPU sampled every 0.1 s.
  // A collection ends at offset + k * gcEvery: the cumulative CPU steps by gcMs there.
  const timeline = (seconds: number, gcEvery: number, gcMs: number, offset: number) => {
    const times: number[] = [];
    const values: number[] = [];
    for (let tenth = 0; tenth <= seconds * 10; tenth += 1) {
      const at = tenth / 10;
      const collections = Math.max(0, Math.floor((at - offset) / gcEvery + 1e-9) + (at >= offset ? 1 : 0) - 1);
      times.push(at);
      values.push(60 * at + gcMs * collections);
    }
    return { times, values };
  };
  test("a reading reads between samples linearly, and the end sample past either end", () => {
    expect(interpolate([0, 10], [0, 100], 2.5)).toBeCloseTo(25, 9);
    expect(interpolate([0, 10], [0, 100], -1)).toBe(0);
    expect(interpolate([0, 10], [0, 100], 11)).toBe(100);
  });
  test("whole cycles count every collection once, whatever the phase", () => {
    // The true rate: 60 + 1300 / 8 = 222.5 ms/s. Any phase reads it over whole cycles.
    for (const offset of [0, 2.3, 5.7]) {
      const { times, values } = timeline(60, 8, 1300, offset);
      const ends = [1, 2, 3, 4, 5].map((k) => offset + k * 8 + 0.05);
      const r = cycleRate(ends, times, values)!;
      expect(r.cycles).toBe(4);
      expect(r.rate).toBeCloseTo(222.5, 0);
      expect(r.se!).toBeLessThan(0.01);
    }
  });
  test("a fixed window does not: 20 s reads two or three collections by phase", () => {
    const { times, values } = timeline(60, 8, 1300, 0);
    const window = (from: number) => (interpolate(times, values, from + 20) - interpolate(times, values, from)) / 20;
    expect(window(0)).toBeLessThan(200);
    expect(window(7)).toBeGreaterThan(240);
  });
  test("cycles of uneven cost give an error; under two cycles none, under one no rate", () => {
    const times = [0, 10, 20, 30];
    const values = [0, 1000, 3000, 4000];
    const r = cycleRate([0, 10, 20, 30], times, values)!;
    expect(r.rate).toBeCloseTo(4000 / 30, 9);
    expect(r.se!).toBeGreaterThan(0);
    expect(cycleRate([0, 10], times, values)!.se).toBeNull();
    expect(cycleRate([5], times, values)).toBeNull();
  });
  test("collections are the largest heap's; ones close together are one episode", () => {
    const ends = majorGcEnds([
      { pid: 2, ts: 100, dur: 10, heapBefore: 5e6 },
      { pid: 1, ts: 300, dur: 50, heapBefore: 9e8 },
      { pid: 1, ts: 100, dur: 20, heapBefore: 8e8 },
      { pid: 1, ts: 340, dur: 30, heapBefore: 8e8 },
      { pid: 1, ts: 6_000_000, dur: 100_000, heapBefore: 8e8 },
      { pid: 1, ts: 6_700_000, dur: 100_000, heapBefore: 8e8 },
      { pid: 1, ts: 12_000_000, dur: 100_000, heapBefore: 8e8 },
    ]);
    expect(ends.pid).toBe(1);
    expect(ends.ends).toEqual([370, 6_800_000, 12_100_000]);
    expect(ends.heaps).toEqual([9e8, 8e8, 8e8]);
  });
});
