// A composer's `/` list beside its box (listPlacement.ts). David Beyer (2026-11-20): on New Tab, in
// a short window, the list stood above a box near the window's top and ran past the screen's edge
// (the host's native panel took it out of the window). The list opens on the side with room and
// takes no more than that room; only a pane too short for a few rows sends it to the panel.
import { expect, test } from "bun:test";
import { LIST_EDGE_PX, LIST_FLOOR_PX, LIST_GAP_PX, listPlacement } from "./listPlacement";

const margin = LIST_GAP_PX + LIST_EDGE_PX;

test("the chat composer at the pane's foot: above, at the list's whole height", () => {
  const placed = listPlacement({ top: 700, bottom: 750 }, 760, 296);
  expect(placed.side).toBe("above");
  expect(placed.room).toBe(700 - margin);
  expect(placed.escapes).toBe(false);
});

test("New Tab's box near the top of a short window: below, inside the window", () => {
  const placed = listPlacement({ top: 140, bottom: 190 }, 520, 296);
  expect(placed.side).toBe("below");
  expect(placed.room).toBe(520 - 190 - margin);
  expect(placed.escapes).toBe(false);
});

test("a list that fits above stays above even with more room below", () => {
  const placed = listPlacement({ top: 200, bottom: 250 }, 900, 120);
  expect(placed.side).toBe("above");
  expect(placed.escapes).toBe(false);
});

test("no side holds the whole list: the larger side, and the list scrolls in its room", () => {
  const placed = listPlacement({ top: 230, bottom: 280 }, 480, 296);
  expect(placed.side).toBe("above");
  expect(placed.room).toBe(230 - margin);
  expect(placed.room).toBeLessThan(296);
  expect(placed.escapes).toBe(false);
});

test("only a pane too short for a few rows sends the list to the native panel", () => {
  expect(listPlacement({ top: 60, bottom: 110 }, 200, 296).escapes).toBe(true);
  expect(listPlacement({ top: 60, bottom: 110 }, 200, 296).room).toBeLessThan(LIST_FLOOR_PX);
  // A one-row list fits the same short pane.
  expect(listPlacement({ top: 60, bottom: 110 }, 200, 36).escapes).toBe(false);
});

test("non-finite measurements never place the list past an edge", () => {
  const placed = listPlacement({ top: Number.NaN, bottom: Number.NaN }, Number.POSITIVE_INFINITY, Number.NaN);
  expect(placed.room).toBeGreaterThanOrEqual(0);
});
