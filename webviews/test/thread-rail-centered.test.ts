// The prompt rail's middle is the view's middle at every prompt count (model.ts railFitTop; Lucas,
// 2026-11-17: the rail is "always vertically aligned, and is on the vertical center of the screen").
// The shipped `fit-480` drew a short chat's rail at the top of its 480 px slot, above the middle.
import { expect, test } from "bun:test";
import {
  DEFAULT_RAIL_HEIGHT,
  RAIL_HEIGHTS,
  railFitTop,
  railHeight,
  railRoom,
  ROW_PITCH,
} from "../src/agent-session/acpmux/threadMinimap/model";

const config = RAIL_HEIGHTS[DEFAULT_RAIL_HEIGHT];
const middle = (count: number, view: number, foot = view) => {
  const height = railHeight(count, view, view, foot, 1, config);
  return railFitTop(height, view, foot, config) + height / 2;
};

test("the rail's middle is the view's middle for 3, 13, 36 and 48 prompts", () => {
  for (const count of [3, 13, 36, 48]) expect(Math.abs(middle(count, 800) - 400)).toBeLessThanOrEqual(1);
});

test("a chat past 48 prompts keeps the 480 px rail on the view's middle", () => {
  const height = railHeight(70, 800, 800, 800, 1, config);
  expect(height).toBe(48 * ROW_PITCH);
  expect(railFitTop(height, 800, 800, config)).toBe(160);
});

test("a stack that leaves the middle no room moves the rail only as far as it takes to clear it", () => {
  // A 620 px view with the stack's top at 520: a 36-prompt rail centered on 310 would end at 490,
  // inside the room, so it stays centered; a 48-prompt rail moves up just enough to end above it.
  expect(Math.abs(middle(36, 620, 520) - 310)).toBeLessThanOrEqual(1);
  const height = railHeight(48, 620, 620, 520, 1, config);
  const top = railFitTop(height, 620, 520, config);
  expect(top + height).toBeLessThanOrEqual(railRoom(620, 520).bottom);
  expect(top + height).toBeGreaterThanOrEqual(railRoom(620, 520).bottom - 1);
});
