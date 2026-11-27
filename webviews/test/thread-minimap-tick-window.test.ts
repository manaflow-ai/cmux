// The rows the compact rail draws (tickWindow.ts): the list's view and some past each edge, the
// rows focus or the card need, and the end of the list for an offset past it.
import { expect, test } from "bun:test";
import { TICK_OVERSCAN, tickOverscan, tickRanges } from "../src/agent-session/acpmux/threadMinimap/tickWindow";

test("the window is the list's view with the overscan, plus each kept row", () => {
  // A 300 px view is 30 rows: TICK_OVERSCAN past each edge, its ends on steps of 6 rows.
  expect(tickOverscan(30)).toBe(TICK_OVERSCAN);
  expect(tickRanges(2000, 10_000, 300)).toEqual([[984, 1044]]);
  expect(tickRanges(2000, 0, 300, [1500, undefined, 5])).toEqual([
    [0, 42],
    [1500, 1501],
  ]);
  expect(tickRanges(0, 0, 300)).toEqual([]);
});

test("a tall view draws a quarter of itself past each edge, a short one at least TICK_OVERSCAN", () => {
  expect(tickOverscan(80)).toBe(20);
  expect(tickOverscan(4)).toBe(TICK_OVERSCAN);
  const [[first, last]] = tickRanges(2000, 10_000, 40) as [[number, number]];
  expect(first).toBeLessThanOrEqual(1000 - TICK_OVERSCAN);
  expect(last).toBeGreaterThanOrEqual(1004 + TICK_OVERSCAN);
});

test("every offset draws its view with the full overscan past both edges, and the window moves in steps", () => {
  const height = 640;
  const rows = height / 10;
  const overscan = tickOverscan(rows);
  let moves = 0;
  let was = "";
  for (let top = 0; top <= 30_000 - height; top += 3) {
    const [[first, last]] = tickRanges(3000, top, height) as [[number, number]];
    expect(first).toBeLessThanOrEqual(Math.max(0, Math.floor(top / 10) - overscan));
    expect(last).toBeGreaterThanOrEqual(Math.min(3000, Math.ceil((top + height) / 10) + overscan));
    const key = `${first} ${last}`;
    if (key !== was) moves += 1;
    was = key;
  }
  // Each end moves once per step of half the overscan (8 rows), not once per row (2,936 rows
  // scrolled): at most twice per step, a quarter of once per row.
  expect(moves).toBeLessThanOrEqual(Math.ceil((2 * 2936) / Math.ceil(overscan / 2)) + 2);
  expect(moves).toBeLessThan(2936 / 2);
});

test("an offset past the list's end (a shorter chat in the same rail) still draws its rows", () => {
  expect(tickRanges(5, 19_700, 300)).toEqual([[0, 5]]);
  expect(tickRanges(100, 19_700, 300)).toEqual([[54, 100]]);
});
