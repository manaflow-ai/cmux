import { describe, expect, test } from "bun:test";
import { FAILURE_CATEGORIES, percentile, summarize, validateRow } from "./score.mjs";

const row = (over) => ({
  task_id: "t", domain: "desktop", driver: "cua", level: "primitive", live: false,
  ok: true, steps: 1, wall_ms: 100, focus_preserved: true, latencies: {}, ...over,
});

describe("percentile", () => {
  test("nearest rank", () => {
    expect(percentile([5, 1, 3, 2, 4], 50)).toBe(3);
    expect(percentile([5, 1, 3, 2, 4], 95)).toBe(5);
    expect(percentile([7], 95)).toBe(7);
    expect(percentile([], 50)).toBeNull();
  });
});

describe("validateRow", () => {
  test("a passing row has no failure category", () => {
    expect(() => validateRow(row({ failure: "input" }))).toThrow(/passing row/);
  });
  test("a failing row needs a known category", () => {
    expect(() => validateRow(row({ ok: false }))).toThrow(/category/);
    expect(() => validateRow(row({ ok: false, failure: "flaky" }))).toThrow(/category/);
    for (const failure of FAILURE_CATEGORIES) expect(() => validateRow(row({ ok: false, failure }))).not.toThrow();
  });
  test("domain and level are closed sets", () => {
    expect(() => validateRow(row({ domain: "phone" }))).toThrow(/domain/);
    expect(() => validateRow(row({ level: "vibes" }))).toThrow(/level/);
  });
});

describe("summarize", () => {
  const rows = [
    row({ wall_ms: 100, latencies: { click: [80, 90], snapshot: [40] } }),
    row({ wall_ms: 300, ok: false, failure: "not_landed", focus_preserved: false, latencies: { click: [100] } }),
    row({ wall_ms: 200, latencies: { click: [70] } }),
    row({ wall_ms: 900, live: true, ok: false, failure: "timeout" }),
    row({ driver: "codex-cua", wall_ms: 400, steps: 3 }),
  ];
  const out = summarize(rows);

  test("groups by driver and domain, sorted", () => {
    expect(out.map((s) => `${s.driver}/${s.domain}`)).toEqual(["codex-cua/desktop", "cua/desktop"]);
  });

  test("scores only non-live rows and counts live rows apart", () => {
    const cua = out.find((s) => s.driver === "cua");
    expect(cua.n).toBe(3);
    expect(cua.success_rate).toBeCloseTo(2 / 3);
    expect(cua.live).toEqual({ n: 1, ok: 0 });
    expect(cua.failures).toEqual({ not_landed: 1 });
    expect(cua.focus_preserved_rate).toBeCloseTo(2 / 3);
    expect(cua.wall_ms).toEqual({ p50: 200, p95: 300 });
    expect(cua.median_steps).toBe(1);
  });

  test("pools primitive latencies across rows", () => {
    const cua = out.find((s) => s.driver === "cua");
    expect(cua.latency_ms.click).toEqual({ n: 4, p50: 80, p95: 100 });
    expect(cua.latency_ms.snapshot).toEqual({ n: 1, p50: 40, p95: 40 });
  });

  test("rejects invalid rows instead of scoring them", () => {
    expect(() => summarize([row({ ok: false })])).toThrow(/category/);
  });
});
