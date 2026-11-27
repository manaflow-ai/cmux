import { expect, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  UNDECLARED_BASELINE_PATH,
  caseCount,
  judgeUndeclared,
  leastCount,
  loweredUndeclared,
  mostCount,
  readUndeclaredBaseline,
  undeclaredCounts,
  undeclaredSummary,
} from "./undeclared-baseline";

const ISSUE = "https://github.com/manaflow-ai/cmuxterm-hq/issues/1";
const move = { label: "div.cv-row[row r1]", dx: 0, dy: 16, dw: 0, dh: 0 };
const result = (entry: string, variant: string, load: number, steps: number[] = [], ready = "1") => ({
  params: { entry, variant },
  ready,
  load: { undeclared: load, undeclaredMoves: load ? [move] : [] },
  play: { steps: steps.map((undeclared, index) => ({ step: `click ${index}`, undeclared, undeclaredMoves: [move] })) },
});

test("a case's count is its load plus each step, with what moved first", () => {
  const counted = caseCount(result("a", "x", 1, [0, 2]));
  expect(counted.count).toBe(3);
  expect(counted.moves).toEqual([
    "load: 1 (div.cv-row[row r1] [0 16 0 0])",
    "click 1: 2 (div.cv-row[row r1] [0 16 0 0])",
  ]);
  expect(caseCount({}).count).toBe(0);
});

test("a state's count is its worst case; a state with an unready case has none", () => {
  const counts = undeclaredCounts([result("a", "x", 0), result("a", "x", 2), result("b", "y", 5, [], "error"), result("b", "y", 0)]);
  expect([...counts].map(([state, { count }]) => [state, count])).toEqual([["a#x", 2]]);
});

test("a state with no row fails on its first undeclared move; a row fails only past its count", () => {
  const counts = leastCount([
    undeclaredCounts([result("new", "a", 1), result("known", "b", 3), result("fixed", "c", 0), result("still", "d", 0)]),
  ]);
  const found = judgeUndeclared(counts, { states: { "known#b": { count: 3, issue: ISSUE }, "fixed#c": { count: 2, issue: ISSUE } } });
  expect(found.moved.map(({ state }) => state)).toEqual(["new#a"]);
  expect(found.lower.map(({ state, count }) => [state, count])).toEqual([["fixed#c", 0]]);
  expect(undeclaredSummary(found)).toContain("new#a: 1 undeclared (baseline 0)");
});

test("a move every retry shows is the page's; one retry's is noise", () => {
  const first = undeclaredCounts([result("flaky", "a", 2), result("real", "b", 1)]);
  const again = undeclaredCounts([result("flaky", "a", 0), result("real", "b", 1)]);
  expect([...leastCount([first, again])].map(([state, { count }]) => [state, count])).toEqual([
    ["flaky#a", 0],
    ["real#b", 1],
  ]);
  expect(mostCount([first, again]).get("flaky#a")?.count).toBe(2);
});

test("rows only go down, rows at zero go, and --add seeds rows with their issue", () => {
  const baseline = { states: { "a#x": { count: 4, issue: ISSUE }, "b#y": { count: 1, issue: ISSUE } } };
  const next = loweredUndeclared(baseline, new Map([["a#x", 6], ["b#y", 0], ["c#z", 2], ["d#w", 0]]), { issue: ISSUE });
  expect(next.states).toEqual({ "a#x": { count: 4, issue: ISSUE }, "c#z": { count: 2, issue: ISSUE } });
  expect(loweredUndeclared(baseline, new Map([["c#z", 2]])).states).toEqual(baseline.states);
});

test("the baseline file reads, and a row with no issue or a zero count is refused", () => {
  expect(readUndeclaredBaseline(UNDECLARED_BASELINE_PATH).states).toBeDefined();
  const dir = mkdtempSync(join(tmpdir(), "undeclared-"));
  const bad = join(dir, "bad.json");
  writeFileSync(bad, JSON.stringify({ states: { "a#x": { count: 2, issue: "soon" } } }));
  expect(() => readUndeclaredBaseline(bad)).toThrow("issue URL");
  writeFileSync(bad, JSON.stringify({ states: { "a#x": { count: 0, issue: ISSUE } } }));
  expect(() => readUndeclaredBaseline(bad)).toThrow("count above 0");
});
