import { expect, test } from "bun:test";
import { typingSummary } from "./perf";

const samples = [
  { frame: 4.123, paint: 9.876 },
  { frame: 6.5, paint: 12.25 },
];

test("the typing summary keeps its keys and adds no samples unless asked", () => {
  const summary = typingSummary(samples);
  expect(Object.keys(summary).sort()).toEqual(["keys", "to_frame", "to_paint"]);
  expect(summary.keys).toBe(2);
});

test("raw adds every key's times, oldest first, for the bench's result-v1 samples", () => {
  expect(typingSummary(samples, true).samples).toEqual([
    { to_frame_ms: 4.12, to_paint_ms: 9.88 },
    { to_frame_ms: 6.5, to_paint_ms: 12.25 },
  ]);
  expect(typingSummary([], true).samples).toEqual([]);
});
