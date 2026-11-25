// The composer hat's `summary` steps (traySummaryFit.ts; Leo, 2026-11-23: "x subagents running y
// commands running etc with full text when you have space and it gradually shrinks when there is
// none... and have it not shift too much"): widths in, step out.
import { expect, test } from "bun:test";
import {
  fitSummaryLevel,
  nextSummaryLevel,
  SUMMARY_HYSTERESIS_PX,
  summaryLevelWidth,
  summaryStep,
  type SummaryWidths,
} from "./traySummaryFit";

// "2 subagents running" / "2 subagents" / "2", then "1 command running" / "1 command" / "1".
const two: SummaryWidths = {
  kinds: [
    { long: 140, short: 90, count: 26 },
    { long: 130, short: 80, count: 26 },
  ],
  separator: 14,
  gap: 12,
  more: 24,
};
// Five kinds, each 26 px as a count.
const five: SummaryWidths = {
  kinds: Array.from({ length: 5 }, () => ({ long: 120, short: 70, count: 26 })),
  separator: 14,
  gap: 12,
  more: 24,
};
// A lone subagent: its name, "1 subagent running", "1 subagent", "1".
const lone: SummaryWidths = {
  kinds: [{ named: 220, long: 130, short: 80, count: 26 }],
  separator: 14,
  gap: 12,
  more: 24,
};

test("each step's width: the forms of every kind, then the separators or gaps", () => {
  expect(summaryLevelWidth(two, 1)).toBe(140 + 14 + 130);
  expect(summaryLevelWidth(two, 2)).toBe(90 + 14 + 80);
  expect(summaryLevelWidth(two, 3)).toBe(26 + 12 + 26);
  // One kind folded: the first kind, a gap and the "+N".
  expect(summaryLevelWidth(two, 4)).toBe(26 + 12 + 24);
});

test("the richest step that fits, the whole line together", () => {
  expect(summaryStep(two, 400).step).toEqual({ form: "long", shown: 2 });
  expect(summaryStep(two, 284).step).toEqual({ form: "long", shown: 2 });
  expect(summaryStep(two, 283).step).toEqual({ form: "short", shown: 2 });
  expect(summaryStep(two, 184).step).toEqual({ form: "short", shown: 2 });
  expect(summaryStep(two, 183).step).toEqual({ form: "count", shown: 2 });
  expect(summaryStep(two, 64).step).toEqual({ form: "count", shown: 2 });
});

test("past the count line, trailing kinds fold into +N, one kind always stays", () => {
  // 5 counts: 5 * 26 + 4 * 12 = 178.
  expect(summaryStep(five, 178).step).toEqual({ form: "count", shown: 5 });
  // Four and +N: 4 * 26 + 3 * 12 + 12 + 24 = 176.
  expect(summaryStep(five, 177).step).toEqual({ form: "count", shown: 4 });
  expect(summaryStep(five, 100).step).toEqual({ form: "count", shown: 2 });
  expect(summaryStep(five, 10).step).toEqual({ form: "count", shown: 1 });
});

test("a lone item reads its name when it fits, then its words, never a bare 1 while words fit", () => {
  expect(summaryStep(lone, 300).step.form).toBe("named");
  expect(summaryStep(lone, 200).step.form).toBe("long");
  expect(summaryStep(lone, 100).step.form).toBe("short");
  expect(summaryStep(lone, 60).step.form).toBe("count");
  // Two kinds never take the named step.
  expect(fitSummaryLevel(two, 10_000)).toBe(1);
});

test("an unmeasured box (0 px) draws the richest step", () => {
  expect(summaryStep(lone, 0).step.form).toBe("named");
  expect(summaryStep(two, 0).step.form).toBe("long");
});

test("hysteresis: it degrades at once, and grows back only with room to spare", () => {
  // At the long/short boundary (284), a box that wobbles a few px never flaps.
  let level = nextSummaryLevel(two, 284, undefined);
  expect(level).toBe(1);
  level = nextSummaryLevel(two, 283, level);
  expect(level).toBe(2);
  for (const width of [284, 286, 290, 284 + SUMMARY_HYSTERESIS_PX - 1]) {
    expect(nextSummaryLevel(two, width, level)).toBe(2);
  }
  expect(nextSummaryLevel(two, 284 + SUMMARY_HYSTERESIS_PX, level)).toBe(1);
  // A steady width holds its step.
  expect(nextSummaryLevel(two, 250, 2)).toBe(2);
  // A big jump skips steps both ways.
  expect(nextSummaryLevel(two, 70, 1)).toBe(3);
  expect(nextSummaryLevel(two, 1000, 3)).toBe(1);
});

test("a held step clamps when the kinds change under it", () => {
  // Five kinds folded to one (level 7), then only two kinds: the most it can fold is one.
  expect(nextSummaryLevel(two, 10, 7)).toBe(4);
  // A named step held when a second kind joins becomes long, if long fits.
  expect(nextSummaryLevel(two, 400, 0)).toBe(1);
});
