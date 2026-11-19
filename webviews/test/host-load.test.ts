// A busy runner can't make a timing row regress by accident (bench/hostLoad.ts): the web UI suite divides a bench's
// ms rows by the host's contention factor, and leaves every row that is not a time, and every row on an idle host, as
// measured.
import { describe, expect, test } from "bun:test";
import {
  contentionFactor,
  hostSpeed,
  MAX_FACTOR,
  normalizeRows,
  speedProbe,
  spinRatio,
  stampSpeed,
} from "../bench/hostLoad";

describe("hostLoad contentionFactor", () => {
  test("the median spin ratio, at least 1, at most MAX_FACTOR", () => {
    expect(contentionFactor([1.01, 0.98, 1.0])).toBe(1);
    expect(contentionFactor([2.1, 1.9, 2.0, 30])).toBe(2.05);
    expect(contentionFactor([50, 60, 70])).toBe(MAX_FACTOR);
    expect(contentionFactor([])).toBe(1);
    expect(contentionFactor([Number.NaN])).toBe(1);
  });

  test("a spin on this host gets about its own wall time in CPU", () => {
    // Shared CI hosts can be busy: only check the ratio is a sane number, not that the host is idle.
    const ratio = spinRatio(10);
    // An overloaded runner can starve the spin far past MAX_FACTOR (contentionFactor clamps it), so no upper bound.
    expect(Number.isFinite(ratio)).toBe(true);
    expect(ratio).toBeGreaterThan(0.5);
  });
});

describe("hostLoad normalizeRows", () => {
  const rows = [
    { name: "chat_open.latest", p50: 400, p95: 600, target: 1000 },
    { name: "chat_open.settled", p95: 300, unit: "ms" },
    { name: "ui_stability.cls", p95: 0.2, unit: "score", target: 0 },
    { name: "delta_renders.rows", p95: 4, unit: "count" },
    { name: "chat_switch.unread.idle_cpu_ms", p95: 3, target: 5, clock: "cpu" as const },
  ];

  test("a busy host's ms rows are scaled to the idle host's, with the measured p95 kept", () => {
    expect(normalizeRows(rows, 2)).toEqual([
      { name: "chat_open.latest", p50: 200, p95: 300, target: 1000, raw_p95: 600, load: 2 },
      { name: "chat_open.settled", p95: 150, unit: "ms", raw_p95: 300, load: 2 },
      { name: "ui_stability.cls", p95: 0.2, unit: "score", target: 0 },
      { name: "delta_renders.rows", p95: 4, unit: "count" },
      { name: "chat_switch.unread.idle_cpu_ms", p95: 3, target: 5, clock: "cpu" },
    ]);
  });

  test("an idle host leaves every row as measured", () => {
    expect(normalizeRows(rows, 1)).toEqual(rows);
  });
});

// A slow runner can't either (cmux#24569): the spin reads 1 on a host that runs the same code 2x slower, so the suite
// also times a fixed canary and stamps each time row with it; the perf cron judges a row only against values from a
// runner about as fast.
describe("hostLoad host speed", () => {
  test("the median canary sample, walk plus work, and 0 when not known", () => {
    expect(
      hostSpeed([
        { walk: 10, work: 5 },
        { walk: 30, work: 20 },
        { walk: 12, work: 6.0004 },
      ]),
    ).toBe(18);
    expect(
      hostSpeed([
        { walk: 10, work: 5 },
        { walk: 12, work: 5 },
      ]),
    ).toBe(16);
    expect(hostSpeed([])).toBe(0);
    expect(hostSpeed([{ walk: Number.NaN, work: 1 }])).toBe(0);
  });

  test("the canary takes time on this host", () => {
    const samples = speedProbe(2);
    expect(samples).toHaveLength(2);
    for (const sample of samples) {
      expect(sample.walk).toBeGreaterThan(0);
      expect(sample.work).toBeGreaterThan(0);
    }
  });

  test("time rows carry the speed, wall and CPU alike; counts and an unknown speed do not", () => {
    const rows = [
      { name: "chat_open.latest", p95: 600 },
      { name: "chat_switch.unread.idle_cpu_ms", p95: 3, clock: "cpu" as const },
      { name: "delta_renders.rows", p95: 4, unit: "count" },
    ];
    expect(stampSpeed(rows, 21.5)).toEqual([
      { name: "chat_open.latest", p95: 600, speed: 21.5 },
      { name: "chat_switch.unread.idle_cpu_ms", p95: 3, clock: "cpu", speed: 21.5 },
      { name: "delta_renders.rows", p95: 4, unit: "count" },
    ]);
    expect(stampSpeed(rows, 0)).toEqual(rows);
  });
});
