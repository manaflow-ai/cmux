import { expect, test } from "bun:test";
import { RAIL_SCROLLS_ATTRIBUTE, railOwnsWheel } from "./railWheel";

// A wheel over the rail's hover strip, or over a rail that fits its prompts, reaches the transcript:
// the reveal-intent change (railIntent.ts) and the text-press guard add no wheel owner.
const over = (closest: (selector: string) => unknown, type = "wheel") =>
  ({ type, target: { closest } }) as unknown as Event;

test("a wheel over a rail that fits its prompts or the strip is the transcript's", () => {
  expect(railOwnsWheel(over(() => null))).toBe(false);
});

test("a wheel over an overflowing rail list is the rail's", () => {
  expect(railOwnsWheel(over((selector) => (selector === `[${RAIL_SCROLLS_ATTRIBUTE}]` ? {} : null)))).toBe(true);
});

test("other events are never the rail's wheel", () => {
  expect(railOwnsWheel(over(() => ({}), "pointermove"))).toBe(false);
});
