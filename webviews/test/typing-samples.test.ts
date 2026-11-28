import { expect, test } from "bun:test";
import { keyDroppedFrames, typingFrameInterval, typingSummary } from "../src/agent-session/acpmux/perf";

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

test("dropped frames: vsyncs a key waited past, and frames its own frame ran over", () => {
  const nominal = 1000 / 60;
  expect(keyDroppedFrames({ frame: 9, paint: 10, next_frame_ms: nominal }, nominal)).toBe(0);
  expect(keyDroppedFrames({ frame: 20, paint: 21, next_frame_ms: nominal }, nominal)).toBe(1);
  expect(keyDroppedFrames({ frame: 9, paint: 10, next_frame_ms: 3 * nominal }, nominal)).toBe(2);
  const keys = [8.3, 8.4, 8.3, 25, 8.3].map((next) => ({ frame: 5, paint: 6, next_frame_ms: next, chars: 5000 }));
  expect(typingFrameInterval(keys)).toBeCloseTo(8.3);
  expect(typingFrameInterval([{ frame: 5, paint: 6 }])).toBeCloseTo(nominal);
  // Under load every frame stretches: the count stays against a 60 Hz frame, not the stretched one.
  expect(typingFrameInterval([40, 45, 50].map((next) => ({ frame: 5, paint: 6, next_frame_ms: next })))).toBeCloseTo(
    nominal,
  );
  const stats = typingSummary(keys);
  expect(stats.frame_interval_ms).toBe(8.3);
  expect(stats.dropped_frames).toBe(2);
  expect(stats.keys_with_drops).toBe(1);
  expect(stats.max_chars).toBe(5000);
});
