// The drop that centres a line's capitals on its line box (composerTextCenter.ts, cmux#51039).
import { expect, test } from "bun:test";
import { capCenterDrop } from "../src/agent-session/acpmux/composerTextCenter";

test("a line drops by the distance between its capitals' middle and its centre", () => {
  // 14 px text in a 22.75 px line: the baseline 17.13 px down, capitals 10 px tall, so their middle
  // sits at 12.13 and the line's centre at 11.375: the line rises 0.755 px.
  expect(capCenterDrop({ lineHeight: 22.75, baseline: 17.13, capHeight: 10 })).toBeCloseTo(-0.755, 3);
  // Capitals already on the centre stay put.
  expect(capCenterDrop({ lineHeight: 20, baseline: 15, capHeight: 10 })).toBe(0);
});
