import { describe, expect, test } from "bun:test";
import { marginalRatio, marginals, ratioInterval } from "../bench/ladderRatio";

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
