import { expect, test } from "bun:test";
import {
  SLASH_MAX_VIEWPORT_PX,
  SLASH_OVERSCAN_ROWS,
  SLASH_ROW_PX,
  slashActiveAfterScroll,
  slashScrollForActive,
  slashViewport,
} from "./slashViewport";

function checked(total: number, active: number, scrollTop: number, viewportPx = SLASH_MAX_VIEWPORT_PX) {
  const view = slashViewport(total, scrollTop, viewportPx);
  const maxRows = Math.ceil(viewportPx / SLASH_ROW_PX) + 2 * SLASH_OVERSCAN_ROWS + 1;
  expect(view.start).toBeGreaterThanOrEqual(0);
  expect(view.end).toBeLessThanOrEqual(total);
  expect(view.end - view.start).toBeLessThanOrEqual(maxRows);
  expect(view.topSpace + (view.end - view.start) * SLASH_ROW_PX + view.bottomSpace).toBe(total * SLASH_ROW_PX);
  if (total) {
    expect(active).toBeGreaterThanOrEqual(view.start);
    expect(active).toBeLessThan(view.end);
  }
  return view;
}

test("5,000 commands: only a small set of options stays mounted during full keyboard traversal", () => {
  const total = 5000;
  let top = 0;
  checked(total, 0, top);
  for (let active = 1; active < total; active++) {
    top = slashScrollForActive(active, total, top);
    checked(total, active, top);
  }
  expect(top).toBeGreaterThan(100000);
  top = slashScrollForActive(0, total, top); // last -> first wrap
  expect(top).toBe(0);
  checked(total, 0, top);
});

test("keyboard crossing 39 to 40 and an ArrowUp wrap keep the active option in the DOM window", () => {
  let top = slashScrollForActive(39, 5000, 0);
  checked(5000, 39, top);
  top = slashScrollForActive(40, 5000, top);
  checked(5000, 40, top);
  top = slashScrollForActive(4999, 5000, top);
  checked(5000, 4999, top);
});

test("a wheel jump picks a visible row and preserves another selection already visible", () => {
  const view = slashViewport(5000, 2500 * SLASH_ROW_PX);
  const newActive = slashActiveAfterScroll(0, 5000, view);
  expect(newActive).toBe(view.firstVisible);
  expect(slashActiveAfterScroll(view.afterVisible - 1, 5000, view)).toBe(view.afterVisible - 1);
  checked(5000, newActive, view.scrollTop);
});

test("empty, singleton and short menus have valid bounds and full logical selection", () => {
  for (const total of [0, 1, 40]) {
    const view = slashViewport(total);
    expect(view.end).toBeLessThanOrEqual(total);
    if (total) checked(total, 0, 0);
    expect(slashActiveAfterScroll(0, total, view)).toBe(0);
  }
});

test("short panes and malformed scrolls do not create invalid offsets or excess DOM rows", () => {
  for (const total of [0, 1, 8, 5000]) {
    for (const scrollTop of [-500, 0, 1000, Number.POSITIVE_INFINITY, Number.NaN, 1e12]) {
      const view = slashViewport(total, scrollTop, 80);
      expect(view.start).toBeGreaterThanOrEqual(0);
      expect(view.end).toBeLessThanOrEqual(total);
      expect(view.end - view.start).toBeLessThanOrEqual(Math.ceil(80 / SLASH_ROW_PX) + 13);
      expect(Number.isFinite(view.scrollTop)).toBe(true);
      if (total) {
        const active = slashActiveAfterScroll(-1, total, view);
        expect(active).toBeGreaterThanOrEqual(view.start);
        expect(active).toBeLessThan(view.end);
      }
    }
  }
});

test("a changed query resetting the menu to its first row preserves selected-option accessibility", () => {
  for (const total of [5000, 1, 0, 15, 5000]) {
    const view = slashViewport(total, slashScrollForActive(0, total, 1e12));
    expect(view.start).toBe(0);
    if (total) expect(view.end).toBeGreaterThan(0);
  }
});
