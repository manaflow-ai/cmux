import { describe, expect, test } from "bun:test";

import { bucketPercentile, mergeHistograms, sumDrops, type StoredHistogramReport } from "../scripts/hang-reports/histograms";

function report(version: string, day: string, histograms: StoredHistogramReport["histograms"], launches: StoredHistogramReport["launches"] = []): StoredHistogramReport {
  return { schema: 3, day, app: { version }, histograms, launches };
}

describe("hang report field histograms", () => {
  test("merges per name, app version and day, with earlier launches under their own version", () => {
    const merged = mergeHistograms([
      report("0.71.0", "2026-10-23", [{ name: "main.turn", unit: "microseconds", buckets: [[5, 2], [9, 1]], count: 3, sum: 30, max: 20 }], [
        { app: { version: "0.70.9" }, histograms: [{ name: "main.turn", unit: "microseconds", buckets: [[5, 4]], count: 4, sum: 10, max: 3 }] },
      ]),
      report("0.71.0", "2026-10-23", [{ name: "main.turn", unit: "microseconds", buckets: [[5, 1], [13, 1]], count: 2, sum: 70, max: 64 }]),
      report("0.71.0", "2026-10-24", [{ name: "main.turn", unit: "microseconds", buckets: [[5, 1]], count: 1, sum: 2, max: 2 }]),
      { schema: 2, day: "2026-10-23", app: { version: "0.71.0" } },
    ]);
    expect(merged.map((entry) => [entry.name, entry.version, entry.day, entry.sections, entry.count, entry.max])).toEqual([
      ["main.turn", "0.70.9", "2026-10-23", 1, 4, 3],
      ["main.turn", "0.71.0", "2026-10-23", 2, 5, 64],
      ["main.turn", "0.71.0", "2026-10-24", 1, 1, 2],
    ]);
    expect(merged[1]!.buckets).toEqual([[5, 3], [9, 1], [13, 1]]);
    expect(merged[1]!.sum).toBe(100);
  });

  test("interpolates percentiles inside log-linear buckets and never passes the max", () => {
    // Bucket 5 is [2, 2.5), bucket 9 is [4, 5), bucket 13 is [8, 10).
    const buckets: Array<[number, number]> = [[5, 50], [9, 40], [13, 10]];
    expect(bucketPercentile("main.turn", buckets, 9.5, 0.5)).toBe(2.5);
    expect(bucketPercentile("main.turn", buckets, 9.5, 0.7)).toBe(4.5);
    expect(bucketPercentile("main.turn", buckets, 9.5, 0.95)).toBe(9);
    expect(bucketPercentile("main.turn", buckets, 9.5, 0.99)).toBe(9.5);
  });

  test("the overflow bucket ends at the merged max, and linear buckets are one value wide", () => {
    expect(bucketPercentile("smoothness.dropped_pct.motion", [[0, 90], [10, 10]], 10, 0.95)).toBe(10);
    expect(bucketPercentile("smoothness.dropped_pct.motion", [[0, 90], [101, 10]], 140, 0.95)).toBe(120.5);
  });

  test("gives Chromium buckets, unknown names and empty histograms no percentiles", () => {
    expect(bucketPercentile("chromium.Stability.Counts2", [[3, 4]], 9, 0.5)).toBeNull();
    expect(bucketPercentile("not.in_catalog", [[3, 4]], 9, 0.5)).toBeNull();
    expect(bucketPercentile("main.turn", [], 0, 0.5)).toBeNull();
    const [merged] = mergeHistograms([report("0.71.0", "2026-10-23", [{ name: "chromium.Stability.Counts2", unit: "chromium", buckets: [[3, 4]], count: 4, sum: 12, max: 3 }])]);
    expect(merged).toMatchObject({ unit: "chromium", count: 4, p50: null, p95: null, p99: null });
  });

  test("sums the drop counts ingest stored", () => {
    expect(sumDrops([
      { unknownHistograms: 2, mismatchedHistograms: 1, unknownStabilityKeys: 0 },
      undefined,
      { unknownHistograms: 1, mismatchedHistograms: 0, unknownStabilityKeys: 4 },
    ])).toEqual({ unknownHistograms: 3, mismatchedHistograms: 1, unknownStabilityKeys: 4 });
  });
});
