import { describe, expect, test } from "bun:test";
import {
  AcpmuxPerf,
  droppedFrames,
  FrameRing,
  frameStats,
  intervalsOf,
  isBlank,
  median,
  percentile,
  typingSummary,
} from "./perf";

describe("acpmux perf stats", () => {
  test("percentile index is round((n - 1) * p), as the native pane computes it", () => {
    const sorted = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    expect(percentile(sorted, 0.5)).toBe(6); // round(4.5) = 5
    expect(percentile(sorted, 0.95)).toBe(10); // round(8.55) = 9
    expect(percentile(sorted, 0)).toBe(1);
    expect(percentile(sorted, 1)).toBe(10);
    expect(percentile([], 0.5)).toBe(0);
    expect(median([30, 10, 20])).toBe(20);
  });

  test("dropped frames count whole missed intervals against the nominal one", () => {
    expect(droppedFrames([16.7, 16.6, 16.7], 16.67)).toBe(0);
    // 33 ms is one missed frame, 50 ms two, 24 ms rounds down to none.
    expect(droppedFrames([33.3, 50, 24], 16.67)).toBe(3);
    expect(droppedFrames([33.3], 0)).toBe(0);
  });

  test("frame stats from timestamps match the native fling_stats shape", () => {
    const timestamps = [0, 16, 32, 48, 80, 96];
    expect(intervalsOf(timestamps)).toEqual([16, 16, 16, 32, 16]);
    expect(frameStats(timestamps, 16)).toEqual({
      frames: 6,
      nominal_ms: 16,
      p50_ms: 16,
      p95_ms: 32,
      p99_ms: 32,
      max_ms: 32,
      dropped_frames: 1,
    });
  });

  test("blank when the viewport extends past the mounted rows", () => {
    expect(isBlank(100, 900, 200, 400, 5000)).toBe(false);
    expect(isBlank(300, 900, 200, 400, 5000)).toBe(true);
    expect(isBlank(100, 500, 200, 400, 5000)).toBe(true);
    // The viewport is clipped to the content.
    expect(isBlank(0, 300, 0, 400, 300)).toBe(false);
  });

  test("the frame ring keeps the newest samples, oldest first", () => {
    const ring = new FrameRing(3);
    for (let index = 1; index <= 5; index += 1) ring.push(index * 10, index, 1, index === 5);
    expect(ring.size).toBe(3);
    expect(ring.samples()).toEqual([
      { interval: 30, layout: 3, react: 1, other: 26, blank: false },
      { interval: 40, layout: 4, react: 1, other: 35, blank: false },
      { interval: 50, layout: 5, react: 1, other: 44, blank: true },
    ]);
  });

  test("the recorder attributes layout and render time to the frame they fall in", async () => {
    const perf = new AcpmuxPerf();
    perf.enable(undefined);
    perf.resetFrames();
    perf.markFrame(0, false);
    perf.addLayout(2);
    perf.commit(5, 2, 0, 800, 3);
    perf.markFrame(16, true);
    perf.markFrame(33, false);
    const stats = perf.stats(true);
    expect(stats.frames).toBe(2);
    expect(stats.blank_frames).toBe(1);
    expect(stats.samples).toEqual([
      { interval_ms: 16, layout_ms: 2, react_ms: 3, other_ms: 11, blank: true },
      { interval_ms: 17, layout_ms: 0, react_ms: 0, other_ms: 17, blank: false },
    ]);
    const commit = perf.nextCommit();
    perf.commit(1, 0, 0, 0, 42);
    expect(await commit).toBe(42);
    expect(await perf.nextCommit(1)).toBeUndefined();
  });

  test("typing summary reports p50, p95 and max per stage", () => {
    expect(
      typingSummary([
        { frame: 4, paint: 9 },
        { frame: 2, paint: 7 },
        { frame: 6, paint: 12 },
      ]),
    ).toEqual({
      keys: 3,
      to_frame: { p50_ms: 4, p95_ms: 6, max_ms: 6 },
      to_paint: { p50_ms: 9, p95_ms: 12, max_ms: 12 },
    });
  });

  test("agent latency keeps the first token mark and reports composer readiness", () => {
    const perf = new AcpmuxPerf();
    perf.markAgent("handshakeStart");
    perf.markAgent("handshakeReady");
    perf.markAgent("composerReady");
    perf.markAgent("firstToken");
    const first = perf.agentLatency().first_token_ms;
    perf.markAgent("firstToken");
    expect(perf.agentLatency().first_token_ms).toBe(first);
    expect(perf.agentLatency()).toHaveProperty("composer_ready_ms");
  });
});
