import { expect, test } from "bun:test";
import { caseScore, judgeShift, least, limit, lowered, shiftScores, shiftSummary } from "./shift-baseline";

const result = (entry: string, variant: string, load: number, steps: number[] = [], ready = "1") => ({
  params: { entry, variant },
  ready,
  load: { layoutShift: 0, boxShift: load, boxMoves: [] },
  play: { steps: steps.map((boxShift, index) => ({ step: `click ${index}`, layoutShift: 0, boxShift })) },
});

test("a case's score is its load plus each step, the larger measure of each", () => {
  expect(caseScore({ load: { layoutShift: 0.01, boxShift: 0.002 }, play: { steps: [{ layoutShift: 0, boxShift: 0.03 }] } })).toBe(0.04);
  expect(caseScore({})).toBe(0);
});

test("a state's score is its worst case; a state with an unready case has none", () => {
  const scores = shiftScores([result("a", "x", 0), result("a", "x", 0.02), result("b", "y", 0.5, [], "error"), result("b", "y", 0)]);
  expect([...scores].map(([state, { score }]) => [state, score])).toEqual([["a#x", 0.02]]);
});

test("a zero row fails on any shift past rounding, a non-zero row past its margin, a new state only warns", () => {
  const scores = least([
    shiftScores([result("zero", "a", 0.003), result("moving", "b", 0.05), result("new", "c", 0.2), result("still", "d", 0)]),
  ]);
  const found = judgeShift(scores, { states: { "zero#a": 0, "moving#b": 0.045, "still#d": 0 } });
  expect(found.shifted.map(({ state }) => state)).toEqual(["zero#a"]);
  expect(found.unbaselined.map(({ state }) => state)).toEqual(["new#c"]);
  expect(limit(0)).toBeLessThan(0.0003);
  expect(shiftSummary(found)).toContain("zero#a: shift 0.0030, baseline 0");
});

test("a shift only one run saw is noise: the least score across runs counts", () => {
  const best = least([shiftScores([result("a", "x", 0.01)]), shiftScores([result("a", "x", 0)])]);
  expect(best.get("a#x")?.score).toBe(0);
});

test("rows only go down; --add writes rows for new states", () => {
  const next = lowered({ states: { "a#x": 0.05, "b#y": 0 } }, new Map([["a#x", 0.02], ["b#y", 0.3], ["c#z", 0.00001]]), true);
  expect(next.states).toEqual({ "a#x": 0.02, "b#y": 0, "c#z": 0 });
});
