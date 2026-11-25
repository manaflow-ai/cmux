// The PERF_ROW lines of composer-typing.bench.ts's load modes: an invalid load prints only its invalid row, never a
// timing row, and a valid one prints p95/p99 against its report-only budgets.
import { describe, expect, test } from "bun:test";
import { composerTypingRows } from "../bench/composerTypingRows";

const load = (over: Record<string, unknown>) => ({
  engine: "webkit",
  mode: "L1",
  requested_rows: 60,
  valid: true,
  to_paint_p95: 12.5,
  to_paint_p99: 30,
  budget_p95_ms: 16,
  budget_p99_ms: 33,
  samples: [{ paint: 4 }, { paint: 6 }, { paint: 8 }],
  ...over,
});

describe("composerTypingRows", () => {
  test("a valid load prints its invalid=0 row and paint p95/p99 against the budgets", () => {
    expect(composerTypingRows([load({})])).toEqual([
      { name: "composer_typing.l1.webkit.rows60.invalid", p50: 0, p95: 0, unit: "count", target: 0, floor: 0.5 },
      { name: "composer_typing.l1.webkit.rows60.to_paint", p50: 6, p95: 12.5, target: 16 },
      { name: "composer_typing.l1.webkit.rows60.to_paint_p99", p50: 30, p95: 30, target: 33 },
    ]);
  });

  test("the p50 reads the key's frame's paint where the page reported it, else the after-frame proxy", () => {
    const samples = [{ paint: 40, painted: 5 }, { paint: 50, painted: 7 }, { paint: 9 }];
    const rows = composerTypingRows([load({ samples })]);
    expect(rows.find((row) => row.name.endsWith(".to_paint"))?.p50).toBe(7);
  });

  test("an invalid load prints no timing row, so it never reads as fast", () => {
    const rows = composerTypingRows([load({ valid: false, to_paint_p95: 1, to_paint_p99: 1 })]);
    expect(rows.map((row) => [row.name, row.p95])).toEqual([["composer_typing.l1.webkit.rows60.invalid", 1]]);
  });

  test("a valid load without finite percentiles prints no timing row", () => {
    const rows = composerTypingRows([load({ mode: "L3", to_paint_p99: null })]);
    expect(rows.map((row) => row.name)).toEqual(["composer_typing.l3.webkit.rows60.invalid"]);
  });

  test("legacy idle/stream rows carry no load receipt and print nothing", () => {
    expect(composerTypingRows([{ engine: "chromium", mode: "idle", to_frame_p95: 3 }])).toEqual([]);
  });

  test("every row name is one perfRow accepts and none ends in a refresh-judged suffix", () => {
    for (const row of composerTypingRows([load({}), load({ engine: "chromium", mode: "L2" })])) {
      expect(row.name).toMatch(/^[a-z0-9_]+(\.[a-z0-9_-]+)*$/);
      expect(row.name).not.toMatch(/\.(frame|missed|dropped)$/);
    }
  });
});
