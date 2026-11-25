import { expect, test } from "bun:test";
import { typingSummary } from "../src/agent-session/acpmux/perf";

test("typing retains the slow tail and detached raw samples for native dispatch joins", () => {
  const samples = Array.from({ length: 500 }, (_, index) => ({
    key: "a",
    frame: 5,
    paint: index >= 490 ? 80 : 7,
    listener: 1,
    work: 3,
    paint_epoch_ms: 100000 + index * 20,
  }));
  const stats = typingSummary(samples);
  expect(stats.to_paint.p95_ms).toBe(7);
  expect(stats.to_paint.p99_ms).toBe(80);
  expect(stats.samples).toHaveLength(500);
  samples[0]!.paint = 99;
  expect(stats.samples[0]!.paint).toBe(7);
  expect(stats.samples[0]!.paint_epoch_ms).toBe(100000);
});
