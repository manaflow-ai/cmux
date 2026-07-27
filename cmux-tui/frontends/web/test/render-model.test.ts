import { describe, expect, it } from "vitest";
import type { RenderCursor, RenderDeltaEvent, RenderRow, RenderStateEvent } from "cmux/browser";
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

function snapshot(rows: RenderRow[] = [row(0, "one"), row(1, "two")]): RenderStateEvent {
  return {
    event: "render-state",
    surface: 7,
    size: { cols: 3, rows: 2 },
    cursor,
    default_fg: "#eeeeee",
    default_bg: "#111111",
    scrollback_rows: 12,
    rows,
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
});
