// A busy runner can't make a timing row regress by accident (bench/hostLoad.ts): the web UI suite divides a bench's
// ms rows by the host's contention factor, and leaves every row that is not a time, and every row on an idle host, as
// measured.
import { describe, expect, test } from "bun:test";
import { contentionFactor, MAX_FACTOR, normalizeRows, spinRatio } from "../bench/hostLoad";

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
