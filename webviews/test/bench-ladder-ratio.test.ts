import { describe, expect, test } from "bun:test";
import { marginalRatio } from "../bench/ladderRatio";

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
});
