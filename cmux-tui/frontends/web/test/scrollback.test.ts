import { describe, expect, it } from "vitest";
import type { ReadScrollbackResult, RenderRow } from "cmux/browser";
import {
  createScrollbackWindow,
  latestScrollbackRequest,
  mergeScrollbackPage,
  nextScrollbackRequest,
  previousScrollbackRequest,
  reconcileScrollbackWindow,
  scrollbackAnchorDelta,
} from "../src/lib/scrollback";

function row(relative: number, text = String(relative)): RenderRow {
  return { row: relative, runs: [{ text, fg: null, bg: null, attrs: 0 }] };
}

function page(start: number, total: number, count: number): ReadScrollbackResult {
  return { start, total, rows: Array.from({ length: count }, (_, index) => row(index, `${start + index}`)) };
}

describe("scrollback window", () => {
  it("requests the newest page first and older pages on demand", () => {
    const empty = createScrollbackWindow(300, 100, 250);
    expect(latestScrollbackRequest(empty)).toEqual({ start: 200, count: 100 });

    const latest = mergeScrollbackPage(empty, page(200, 300, 100));
    expect(previousScrollbackRequest(latest)).toEqual({ start: 100, count: 100 });
  });

  it("turns relative response rows into sorted absolute indexes", () => {
    const initial = createScrollbackWindow(20, 10, 20);
    const merged = mergeScrollbackPage(initial, {
      start: 10,
      total: 20,
      rows: [row(2, "twelve"), row(0, "ten")],
    });

    expect(merged.rows.map((candidate) => [candidate.row, candidate.runs[0]?.text])).toEqual([
      [10, "ten"],
      [12, "twelve"],
    ]);
  });

  it("keeps a bounded cache while prepending older pages", () => {
    const initial = createScrollbackWindow(400, 100, 150);
    const latest = mergeScrollbackPage(initial, page(300, 400, 100));
    const prepended = mergeScrollbackPage(latest, page(200, 400, 100));

    expect(prepended.rows).toHaveLength(150);
    expect(prepended.rows[0]?.row).toBe(200);
    expect(prepended.rows.at(-1)?.row).toBe(349);
    expect(scrollbackAnchorDelta(latest, prepended, "previous")).toBe(100);
  });

  it("keeps cached rows and their position when scrollback grows", () => {
    const cached = mergeScrollbackPage(createScrollbackWindow(300, 100, 250), page(200, 300, 100));
    const reconciled = reconcileScrollbackWindow(cached, 300, 340, false);

    expect(reconciled.invalidated).toBe(false);
    expect(reconciled.window.rows).toBe(cached.rows);
    expect(reconciled.window.total).toBe(340);
    expect(scrollbackAnchorDelta(cached, reconciled.window, "previous")).toBe(0);
    expect(nextScrollbackRequest(reconciled.window)).toEqual({ start: 300, count: 40 });
  });

  it("merges a page that observes growth before the render delta without dropping cached rows", () => {
    const cached = mergeScrollbackPage(createScrollbackWindow(300, 100, 250), page(200, 300, 100));
    const grown = mergeScrollbackPage(cached, page(300, 340, 40));

    expect(grown.total).toBe(340);
    expect(grown.rows[0]?.row).toBe(200);
    expect(grown.rows.at(-1)?.row).toBe(339);
  });

  it("invalidates cached indexes when scrollback shrinks", () => {
    const cached = mergeScrollbackPage(createScrollbackWindow(300, 100, 250), page(200, 300, 100));
    const reconciled = reconcileScrollbackWindow(cached, 300, 25, false);

    expect(reconciled.invalidated).toBe(true);
    expect(reconciled.window.total).toBe(25);
    expect(reconciled.window.rows).toEqual([]);
    expect(latestScrollbackRequest(reconciled.window)).toEqual({ start: 0, count: 25 });
  });

  it("invalidates cached indexes on resize reflow even when the total is unchanged", () => {
    const cached = mergeScrollbackPage(createScrollbackWindow(300, 100, 250), page(200, 300, 100));
    const reconciled = reconcileScrollbackWindow(cached, 300, 300, true);

    expect(reconciled.invalidated).toBe(true);
    expect(reconciled.window.rows).toEqual([]);
  });

  it("loads newer pages back to the live boundary after prepend eviction at the cap", () => {
    let cached = createScrollbackWindow(1_024, 128, 512);
    for (const start of [896, 768, 640, 512, 384, 256, 128, 0]) {
      cached = mergeScrollbackPage(cached, page(start, 1_024, 128));
    }

    expect(cached.rows[0]?.row).toBe(0);
    expect(cached.rows.at(-1)?.row).toBe(511);

    let newerPages = 0;
    for (let request = nextScrollbackRequest(cached); request !== null; request = nextScrollbackRequest(cached)) {
      const newer = mergeScrollbackPage(cached, page(request.start, 1_024, request.count));
      expect(scrollbackAnchorDelta(cached, newer, "next")).toBe(-128);
      cached = newer;
      newerPages += 1;
    }

    expect(newerPages).toBe(4);
    expect(cached.rows[0]?.row).toBe(512);
    expect(cached.rows.at(-1)?.row).toBe(1_023);
  });

  it("discards cached indexes when the server reports a different total", () => {
    const initial = mergeScrollbackPage(createScrollbackWindow(20, 10, 20), page(10, 20, 10));
    const reset = mergeScrollbackPage(initial, page(0, 4, 4));

    expect(reset.total).toBe(4);
    expect(reset.rows.map((candidate) => candidate.row)).toEqual([0, 1, 2, 3]);
    expect(previousScrollbackRequest(reset)).toBeNull();
  });
});
