// The rows the compact rail draws (tickWindow.ts): the list's view and some past each edge, the
// rows focus or the card need, and the end of the list for an offset past it.
import { expect, test } from "bun:test";
import { TICK_OVERSCAN, tickRanges } from "../src/agent-session/acpmux/threadMinimap/tickWindow";

test("the window is the list's view with the overscan, plus each kept row", () => {
  expect(tickRanges(2000, 10_000, 300)).toEqual([[1000 - TICK_OVERSCAN, 1030 + TICK_OVERSCAN]]);
  expect(tickRanges(2000, 0, 300, [1500, undefined, 5])).toEqual([
    [0, 30 + TICK_OVERSCAN],
    [1500, 1501],
  ]);
  expect(tickRanges(0, 0, 300)).toEqual([]);
});

test("an offset past the list's end (a shorter chat in the same rail) still draws its rows", () => {
  expect(tickRanges(5, 19_700, 300)).toEqual([[0, 5]]);
  expect(tickRanges(100, 19_700, 300)).toEqual([[70 - TICK_OVERSCAN, 100]]);
});
