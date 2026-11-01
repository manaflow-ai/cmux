import { expect, test } from "bun:test";
import { FOLLOW_BOTTOM_DEADBAND_PX, fadesBelow } from "../src/agent-session/acpmux/conversation/scrollAnchor";

// The band above the composer flickered on and off while nothing streamed: a reader resting at the
// end had the fade toggled by every sub-pixel move of the end (Leo, 2026-10-23: "that little bit
// above composer can flicker"). It shows only past follow's deadband, as Jump to latest does.
test("the transcript's bottom fade holds still within follow's deadband", () => {
  for (const below of [0, 0.5, 1, 2.5, FOLLOW_BOTTOM_DEADBAND_PX]) expect(fadesBelow(false, below)).toBe(false);
  expect(fadesBelow(false, FOLLOW_BOTTOM_DEADBAND_PX + 0.5)).toBe(true);
  expect(fadesBelow(false, 400)).toBe(true);
  // A followed reply never fades, however far its growth outruns the offset.
  expect(fadesBelow(true, 400)).toBe(false);
});
