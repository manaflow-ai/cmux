// The files list's "+N -N" counts draw in tabular figures (file-tree-stats.ts, SVG text with
// font-variant-numeric: tabular-nums), right-aligned in a symbol as wide as the counts measure.
// They were measured in the font's proportional figures, where a "1" is narrow, so a count with
// ones ("+14 -14") got a symbol too narrow for its tabular text and lost its "+" on the left
// (diff viewer before shots, 2026-11-20). Every digit now measures as wide as the widest one.
import { expect, test } from "bun:test";
import { fileTreeStatsDecoration, type MeasureText } from "../src/file-tree-stats";

// A proportional font: "1" is narrow, every other digit is as wide as "0".
const proportional: MeasureText = (text) =>
  text.split("").reduce((width, char) => width + (char === "1" ? 3 : char === " " ? 3 : 7), 0);
const titles = { additions: "Added", deletions: "Removed" };
const width = (added: number, deleted: number) =>
  fileTreeStatsDecoration({ added, deleted }, titles, proportional)!.icon.width;

test("counts of the same length get the same width, ones or not", () => {
  expect(width(14, 14)).toBe(width(88, 88));
  expect(width(11, 0)).toBe(width(80, 0));
  expect(width(0, 1)).toBe(width(0, 9));
});

test("a longer count is still wider", () => {
  expect(width(140, 0)).toBeGreaterThan(width(14, 0));
});
