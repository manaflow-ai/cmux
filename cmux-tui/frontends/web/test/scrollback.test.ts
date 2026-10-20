import { describe, expect, it } from "vitest";
import type { ReadScrollbackResult, RenderRow } from "cmux/raw";
import type { RenderGraphicsModel } from "../src/lib/renderModel";
import {
  createScrollbackWindow,
  latestScrollbackRequest,
  mergeScrollbackPage,
  nextScrollbackRequest,
  previousScrollbackRequest,
  projectRenderGraphicsToRows,
  refreshScrollbackRequest,
  reconcileScrollbackWindow,
  scrollbackAnchorDelta,
} from "../src/lib/scrollback";

function row(relative: number, text = String(relative)): RenderRow {
  return { row: relative, runs: [{ text, fg: null, bg: null, attrs: 0 }] };
}

function page(start: number, total: number, count: number, epoch = 1n): ReadScrollbackResult {
  return {
    start,
    total,
    epoch,
    rows: Array.from({ length: count }, (_, index) => row(index, `${start + index}`)),
  } as ReadScrollbackResult;
}

function historyGraphics(anchorRow: number): RenderGraphicsModel {
  return {
    generation: 1n,
    images: [{
      id: 9,
      generation: 1n,
      width: 1,
      height: 1,
      format: "rgb",
      data: "/wAA",
    }],
    placements: [{
      image_id: 9,
      placement_id: 3,
      ordinal: 0,
      x_offset: 0,
      y_offset: 0,
      source_x: 0,
      source_y: 0,
      source_width: 1,
      source_height: 1,
      columns: 1,
      rows: 2,
      grid_cols: 1,
      grid_rows: 2,
      pixel_width: 8,
      pixel_height: 32,
      viewport_col: 0,
      viewport_row: 0,
      viewport_visible: false,
      anchor_col: 2,
      anchor_row: anchorRow,
      z: -1,
    }],
  };
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
      epoch: 1n,
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

  it("refreshes the currently cached range without moving its anchor", () => {
    const cached = mergeScrollbackPage(createScrollbackWindow(300, 100, 250), page(200, 300, 100));
    const grown = reconcileScrollbackWindow(cached, 300, 340, false).window;

    expect(refreshScrollbackRequest(grown, 340)).toEqual({ start: 200, count: 100 });
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

  it("discards cached indexes when retained history changes at a fixed total", () => {
    const initial = mergeScrollbackPage(createScrollbackWindow(20, 10, 20), page(10, 20, 10, 1n));
    const reset = mergeScrollbackPage(initial, page(0, 20, 4, 2n));

    expect(reset.rows.map((candidate) => candidate.row)).toEqual([0, 1, 2, 3]);
    expect((reset as { epoch?: bigint }).epoch).toBe(2n);
  });

  it("projects absolute Kitty anchors onto cached history rows", () => {
    const projected = projectRenderGraphicsToRows(historyGraphics(7), [row(8), row(9)], 1n, 1n);

    expect(projected?.placements).toEqual([
      expect.objectContaining({
        viewport_col: 2,
        viewport_row: -1,
        viewport_visible: true,
      }),
    ]);
  });

  it("suppresses current Kitty graphics over cached rows from an older history epoch", () => {
    expect(projectRenderGraphicsToRows(historyGraphics(7), [row(7)], 2n, 1n)).toBeUndefined();
  });
});
