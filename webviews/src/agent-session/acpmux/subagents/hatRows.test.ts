// The composer hat's rows (hatRows.ts) and each chat's hat (trayFoldMemory.ts): a drag down from its
// top bar takes whole rows away and stops at one, past it rubber-bands and, let go past half a row,
// hides to the pull tab; a drag up from the pull tab brings rows back one at a time; a click on the
// top bar goes between one row and the last height it had open; the state is per chat.
import { afterEach, describe, expect, test } from "bun:test";
import {
  type HatDrag,
  hatBand,
  hatDragAt,
  hatDragEnd,
  HAT_DEFAULT_ROWS,
  HAT_FOLDED,
  hatMaxRows,
  hatReducer,
  type HatState,
  rowsForHeight,
  shownRows,
} from "./hatRows";
import {
  dispatchHat,
  hatStateFor,
  rememberTrayOpen,
  resetTrayOpenMemory,
  setHatState,
  trayOpenFor,
} from "./trayFoldMemory";

const ROW = 28;
const bar = (startRows: number, maxRows = 8): HatDrag => ({ origin: "bar", startRows, rowHeight: ROW, maxRows });
const pill = (maxRows = 8): HatDrag => ({ origin: "pill", startRows: 0, rowHeight: ROW, maxRows });
const rows = (n: number, last?: number): HatState =>
  last === undefined
    ? { view: { kind: "rows", rows: n } }
    : { view: { kind: "rows", rows: n }, lastExpandedRows: last };

describe("a drag down from the top bar", () => {
  test("takes away whole rows: every height it reaches is a whole row", () => {
    const drag = bar(6);
    for (let down = 0; down <= 5 * ROW; down += 3) {
      const at = hatDragAt(drag, down);
      expect(Number.isInteger(at.rows)).toBe(true);
      expect(at.rows).toBe(Math.max(1, Math.round(6 - down / ROW)));
      expect(at.band).toBe(0);
    }
  });

  test("snaps at one row: down to it, it stays there before the band gives", () => {
    const drag = bar(3);
    expect(hatDragAt(drag, 2 * ROW).rows).toBe(1);
    expect(hatDragAt(drag, 2 * ROW).band).toBe(0);
    expect(hatDragAt(drag, 2 * ROW + 10).rows).toBe(1);
    // Let go at one row: one row, not hidden.
    expect(hatDragEnd(drag, 2 * ROW)).toBe(1);
  });

  test("past one row it rubber-bands: it gives less than the pointer moves, never a whole row", () => {
    const drag = bar(1);
    let last = 0;
    for (const down of [4, 10, 20, 40, 80, 200, 1000]) {
      const at = hatDragAt(drag, down);
      expect(at.rows).toBe(1);
      expect(at.past).toBeCloseTo(down);
      expect(at.band).toBeGreaterThan(last);
      expect(at.band).toBeLessThan(down);
      expect(at.band).toBeLessThan(ROW);
      last = at.band;
    }
    expect(hatBand(0, ROW)).toBe(0);
    expect(hatBand(-5, ROW)).toBe(0);
  });

  test("let go past about half a row beyond the one row, it hides; short of it, it stays at one row", () => {
    const drag = bar(1);
    expect(hatDragEnd(drag, ROW / 2 - 1)).toBe(1);
    expect(hatDragEnd(drag, ROW / 2)).toBe(0);
    expect(hatDragEnd(drag, 3 * ROW)).toBe(0);
    // From five rows: four rows down to one, then half a row more.
    expect(hatDragEnd(bar(5), 4 * ROW + ROW / 2 - 1)).toBe(1);
    expect(hatDragEnd(bar(5), 4 * ROW + ROW / 2)).toBe(0);
  });

  test("up, it adds whole rows to as many as the hat has, never more", () => {
    expect(hatDragAt(bar(2, 5), -ROW).rows).toBe(3);
    expect(hatDragAt(bar(2, 5), -10 * ROW).rows).toBe(5);
    // A height kept from a hat with more lines starts from what this one has.
    expect(hatDragAt(bar(9, 4), ROW).rows).toBe(3);
  });
});

describe("a drag up from the pull tab", () => {
  test("restores rows one at a time, and never goes below hidden", () => {
    const drag = pill(6);
    const seen: number[] = [];
    for (let up = 0; up <= 8 * ROW; up += 4) {
      const at = hatDragAt(drag, -up);
      expect(at.band).toBe(0);
      if (seen.at(-1) !== at.rows) seen.push(at.rows);
    }
    expect(seen).toEqual([0, 1, 2, 3, 4, 5, 6]);
    expect(hatDragAt(drag, 3 * ROW).rows).toBe(0);
    expect(hatDragEnd(drag, -ROW / 4)).toBe(0);
    expect(hatDragEnd(drag, -2 * ROW)).toBe(2);
  });
});

describe("the reducer", () => {
  test("a click on the top bar goes between one row and the last height it had open", () => {
    let state = HAT_FOLDED;
    state = hatReducer(state, { type: "toggle", fallback: HAT_DEFAULT_ROWS });
    expect(shownRows(state)).toBe(HAT_DEFAULT_ROWS);
    state = hatReducer(rows(3, 3), { type: "toggle", fallback: HAT_DEFAULT_ROWS });
    expect(state).toEqual(rows(1, 3));
    state = hatReducer(state, { type: "toggle", fallback: HAT_DEFAULT_ROWS });
    expect(state).toEqual(rows(3, 3));
  });

  test("a drag's rows become the last height it had open; one row and hidden keep it", () => {
    let state = hatReducer(rows(6), { type: "drag", rows: 4 });
    expect(state).toEqual(rows(4, 4));
    state = hatReducer(state, { type: "drag", rows: 1 });
    expect(state).toEqual(rows(1, 4));
    state = hatReducer(state, { type: "drag", rows: 0 });
    expect(state).toEqual({ view: { kind: "hidden" }, lastExpandedRows: 4 });
  });

  test("lastExpandedRows survives a hide: a restore opened goes back to it", () => {
    let state = hatReducer(rows(5, 5), { type: "hide" });
    expect(state.view.kind).toBe("hidden");
    expect(state.lastExpandedRows).toBe(5);
    expect(hatReducer(state, { type: "show", open: true, fallback: HAT_DEFAULT_ROWS })).toEqual(rows(5, 5));
    expect(hatReducer(state, { type: "show", open: false, fallback: HAT_DEFAULT_ROWS })).toEqual(rows(1, 5));
    // Hidden, then brought back a row at a time from the pull tab, then a click: the old height.
    state = hatReducer(state, { type: "drag", rows: 1 });
    expect(hatReducer(state, { type: "toggle", fallback: HAT_DEFAULT_ROWS })).toEqual(rows(5, 5));
  });

  test("the arrow keys step one row, between one row and the most it takes; never hide", () => {
    expect(hatReducer(rows(2, 2), { type: "step", by: 1, max: 4 })).toEqual(rows(3, 3));
    expect(hatReducer(rows(4, 4), { type: "step", by: 1, max: 4 })).toEqual(rows(4, 4));
    expect(hatReducer(rows(2, 2), { type: "step", by: -1, max: 4 })).toEqual(rows(1, 2));
    expect(hatReducer(rows(1, 2), { type: "step", by: -1, max: 4 })).toEqual(rows(1, 2));
    // Six rows kept on a hat with three lines: down steps from the four it draws.
    expect(hatReducer(rows(6, 6), { type: "step", by: -1, max: 4 })).toEqual(rows(3, 3));
    const hidden: HatState = { view: { kind: "hidden" } };
    expect(hatReducer(hidden, { type: "step", by: 1, max: 4 })).toBe(hidden);
  });

  test("the rim's double-click forgets the height: open, it takes the default five lines", () => {
    expect(hatReducer(rows(3, 3), { type: "reset" })).toEqual(rows(HAT_DEFAULT_ROWS));
    expect(hatReducer(rows(1, 3), { type: "reset" })).toEqual(rows(1));
  });

  test("a change that changes nothing keeps the same state", () => {
    const state = rows(3, 3);
    expect(hatReducer(state, { type: "drag", rows: 3 })).toBe(state);
    expect(hatReducer(state, { type: "open", open: true, fallback: 6 })).toBe(state);
  });

  test("the most rows, and a dragged height in rows", () => {
    expect(hatMaxRows(7, ROW, 1000, 0.7)).toBe(8);
    expect(hatMaxRows(7, ROW, 200, 0.7)).toBe(5);
    expect(hatMaxRows(0, ROW, 1000, 0.7)).toBe(1);
    expect(rowsForHeight(undefined, ROW)).toBeUndefined();
    expect(rowsForHeight(56, ROW)).toBe(3);
    expect(rowsForHeight(10, ROW)).toBe(2);
  });
});

describe("each chat's hat", () => {
  afterEach(() => resetTrayOpenMemory());

  test("is its own: a change in one chat leaves another as it was", () => {
    dispatchHat("chat-a", { type: "drag", rows: 4 });
    dispatchHat("chat-b", { type: "hide" });
    expect(hatStateFor("chat-a")).toEqual(rows(4, 4));
    expect(hatStateFor("chat-b").view.kind).toBe("hidden");
    expect(hatStateFor("chat-c")).toEqual(HAT_FOLDED);
    expect(trayOpenFor("chat-a")).toBe(true);
    expect(trayOpenFor("chat-c")).toBeUndefined();
  });

  test("the pull tab's click brings a hidden hat back folded, or open at its last height", () => {
    setHatState("chat-a", { view: { kind: "hidden" }, lastExpandedRows: 3 });
    rememberTrayOpen("chat-a", false);
    expect(hatStateFor("chat-a")).toEqual(rows(1, 3));
    setHatState("chat-a", { view: { kind: "hidden" }, lastExpandedRows: 3 });
    rememberTrayOpen("chat-a", true);
    expect(hatStateFor("chat-a")).toEqual(rows(3, 3));
  });

  test("rememberTrayOpen opens to the last height, folding keeps it", () => {
    rememberTrayOpen("chat-a", true);
    expect(hatStateFor("chat-a")).toEqual(rows(HAT_DEFAULT_ROWS, HAT_DEFAULT_ROWS));
    dispatchHat("chat-a", { type: "drag", rows: 3 });
    rememberTrayOpen("chat-a", false);
    expect(hatStateFor("chat-a")).toEqual(rows(1, 3));
    rememberTrayOpen("chat-a", true);
    expect(hatStateFor("chat-a")).toEqual(rows(3, 3));
  });
});
