import { describe, expect, it } from "vitest";
import type {
  RenderCursor,
  RenderDeltaEvent,
  RenderGraphics,
  RenderRow,
  RenderStateEvent,
} from "cmux/browser";
import { applyDelta, applySnapshot } from "../src/lib/renderModel";

const cursor: RenderCursor = {
  x: 1,
  y: 0,
  style: "block",
  blink: true,
  visible: true,
  color: null,
};

function row(index: number, text: string): RenderRow {
  return { row: index, runs: [{ text, fg: null, bg: null, attrs: 0 }] };
}

const graphics: RenderGraphics = {
  generation: 4,
  images: [{
    id: 9,
    generation: 2,
    width: 1,
    height: 1,
    format: "rgba",
    data: "/wAA/w==",
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
    rows: 1,
    grid_cols: 1,
    grid_rows: 1,
    pixel_width: 8,
    pixel_height: 16,
    viewport_col: 1,
    viewport_row: 0,
    viewport_visible: true,
    z: 0,
  }],
};

function snapshot(
  rows: RenderRow[] = [row(0, "one"), row(1, "two")],
  renderGraphics: RenderGraphics | undefined = graphics,
): RenderStateEvent {
  return {
    event: "render-state",
    surface: 7,
    size: { cols: 3, rows: 2 },
    cursor,
    default_fg: "#eeeeee",
    default_bg: "#111111",
    scrollback_rows: 12,
    rows,
    graphics: renderGraphics,
  };
}

function delta(overrides: Partial<RenderDeltaEvent> = {}): RenderDeltaEvent {
  return {
    event: "render-delta",
    surface: 7,
    cursor,
    full: false,
    rows: [],
    ...overrides,
  };
}

describe("render model", () => {
  it("indexes snapshot and dirty rows by row number even when events list them out of order", () => {
    const initial = applySnapshot(snapshot([row(1, "two"), row(0, "one")]));
    const updated = applyDelta(initial, delta({ rows: [row(1, "TWO"), row(0, "ONE")] }));

    expect(initial.rows.map((candidate) => candidate.runs[0]?.text)).toEqual(["one", "two"]);
    expect(updated.rows.map((candidate) => candidate.runs[0]?.text)).toEqual(["ONE", "TWO"]);
  });

  it("ignores invalid row indexes and deltas buffered for another surface", () => {
    const initial = applySnapshot(snapshot());
    const invalidRows = applyDelta(initial, delta({ rows: [row(-1, "bad"), row(8, "bad")] }));
    const staleSurface = applyDelta(initial, delta({ surface: 99, rows: [row(0, "stale")] }));

    expect(invalidRows.rows.map((candidate) => candidate.runs[0]?.text)).toEqual(["one", "two"]);
    expect(staleSurface).toBe(initial);
  });

  it("treats a resize as a full viewport replacement", () => {
    const initial = applySnapshot(snapshot());
    const resized = applyDelta(initial, delta({
      full: true,
      size: { cols: 4, rows: 3 },
      rows: [row(2, "new2"), row(0, "new0"), row(1, "new1")],
      scrollback_rows: 20,
    }));

    expect(resized.size).toEqual({ cols: 4, rows: 3 });
    expect(resized.rows.map((candidate) => candidate.runs[0]?.text)).toEqual(["new0", "new1", "new2"]);
    expect(resized.scrollbackRows).toBe(20);
  });

  it("replaces all rows for a full repaint without a resize", () => {
    const initial = applySnapshot(snapshot());
    const replaced = applyDelta(initial, delta({ full: true, rows: [row(0, "new")] }));

    expect(replaced.rows[0]?.runs[0]?.text).toBe("new");
    expect(replaced.rows[1]?.runs).toEqual([]);
  });

  it("updates cursor and defaults without copying the row array", () => {
    const initial = applySnapshot(snapshot());
    const updated = applyDelta(initial, delta({
      cursor: { ...cursor, x: 2, style: "bar", visible: false },
      default_bg: "#222222",
    }));

    expect(updated.rows).toBe(initial.rows);
    expect(updated.cursor).toMatchObject({ x: 2, style: "bar", visible: false });
    expect(updated.defaultBg).toBe("#222222");
  });

  it("applies image pixels and authoritative placements from snapshots and deltas", () => {
    const initial = applySnapshot(snapshot());
    const moved = applyDelta(initial, delta({
      graphics: {
        generation: 4,
        placements: [{ ...graphics.placements[0], viewport_col: 2 }],
      },
    }));
    const replaced = applyDelta(moved, delta({
      graphics: {
        generation: 5,
        images: [{
          ...graphics.images![0],
          generation: 3,
          data: "AAD//w==",
        }],
        placements: [{ ...graphics.placements[0], viewport_col: 3 }],
      },
    }));

    expect(initial.graphics.images[0]?.data).toBe("/wAA/w==");
    expect(moved.graphics.images).toBe(initial.graphics.images);
    expect(moved.graphics.placements[0]?.viewport_col).toBe(2);
    expect(replaced.graphics.images[0]).toMatchObject({ generation: 3, data: "AAD//w==" });
    expect(replaced.graphics.placements[0]?.viewport_col).toBe(3);
  });

  it("removes images and placements only when a graphics update says they are gone", () => {
    const initial = applySnapshot(snapshot());
    const textOnly = applyDelta(initial, delta({ rows: [row(0, "text")] }));
    const removed = applyDelta(textOnly, delta({
      graphics: { generation: 5, images: [], placements: [] },
    }));

    expect(textOnly.graphics).toBe(initial.graphics);
    expect(textOnly.rows[0]?.runs[0]?.text).toBe("text");
    expect(removed.graphics.images).toEqual([]);
    expect(removed.graphics.placements).toEqual([]);
  });

  it("starts with empty graphics when attached to an older additive protocol server", () => {
    expect(applySnapshot(snapshot(undefined, undefined)).graphics).toEqual({
      generation: 0,
      images: [],
      placements: [],
    });
  });
});
