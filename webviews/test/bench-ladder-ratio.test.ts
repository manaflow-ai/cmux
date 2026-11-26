import { describe, expect, test } from "bun:test";
import { marginalRatio, marginals } from "../bench/ladderRatio";

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
  // The CPU readings carry each rung's standard error (the spread of its 5 s windows over sqrt(n)).
  test("a low span that reads 0 within its noise is no denominator (chats cpu 114 / 68 / 117 +- 30 ms/s)", () => {
    // Plain rule: -1.15 then 0.98 per chat reads 0.98 / 0.5 = 1.96, the noise of two GC phases divided.
    expect(marginalRatio("cpu_window_ms_per_s", [10, 50, 100], [114, 68, 117])).toBeCloseTo(1.96, 2);
    expect(marginalRatio("cpu_window_ms_per_s", [10, 50, 100], [114, 68, 117], [30, 30, 30])).toBeLessThanOrEqual(1);
  });
  test("growth under two standard errors reads at most flat (tabs cpu 54 / 54 / 90 +- 15 ms/s)", () => {
    expect(marginalRatio("cpu_ms_per_s", [10, 50, 100], [54, 54, 90])).toBeCloseTo(0.72 / 0.5, 2);
    expect(marginalRatio("cpu_ms_per_s", [10, 50, 100], [54, 54, 90], [15, 15, 15])).toBeLessThanOrEqual(1);
  });
  test("a measured growth still reads above flat: GC in step with the heap is a real cost", () => {
    // 1 ms/s per chat to 50, then 3 ms/s per chat to 100, each rung read to +- 2 ms/s.
    expect(marginalRatio("cpu_window_ms_per_s", [10, 50, 100], [60, 100, 250], [2, 2, 2])).toBeCloseTo(3, 6);
  });
  test("a measured flat cost reads flat with or without its error", () => {
    expect(marginalRatio("cpu_window_ms_per_s", [10, 50, 100], [60, 100, 150], [2, 2, 2])).toBeCloseTo(1, 6);
  });
  test("the low marginal is divided by at least two of its own standard errors", () => {
    // low 0.25 +- 0.8 per item, high 3 per item with a growth past its bound: 3 / (2 x 0.8).
    const se = [22.6, 22.6, 2];
    const { lowSe } = marginals([10, 50, 100], [60, 70, 220], se);
    expect(marginalRatio("cpu_window_ms_per_s", [10, 50, 100], [60, 70, 220], se)).toBeCloseTo(3 / (2 * lowSe), 6);
  });
  test("the middle rung counts in both marginals' growth error", () => {
    const { growthSe } = marginals([10, 50, 100], [0, 0, 0], [0, 10, 0]);
    expect(growthSe).toBeCloseTo(10 * (1 / 40 + 1 / 50), 9);
  });
});
