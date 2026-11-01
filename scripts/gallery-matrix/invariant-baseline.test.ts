import { expect, test } from "bun:test";
import { everyRun, invariantSummary, invariantsOf, judgeInvariants, shrunk } from "./invariant-baseline";

const v = (key: string) => ({ rule: key.split(":")[0]!, key, detail: key });
const result = (entry: string, variant: string, keys: string[] | null, ready = "1") => ({
  params: { entry, variant },
  ready,
  invariants: keys === null ? null : keys.map(v),
});

test("a state's violations join across its cases; an unready case or a checker without the gate measured nothing", () => {
  const states = invariantsOf([
    result("a", "x", ["icon-column:row 1"]),
    result("a", "x", ["menu-fit:Model"]),
    result("b", "y", [], "error"),
    result("c", "z", null),
  ]);
  expect([...states.keys()]).toEqual(["a#x"]);
  expect([...states.get("a#x")!.keys()]).toEqual(["icon-column:row 1", "menu-fit:Model"]);
});

test("a violation not in the state's row fails; listed ones are known; a state with no row warns", () => {
  const states = invariantsOf([result("a", "x", ["icon-column:row 1", "gap-token:row 1 -> row 2"]), result("n", "w", ["menu-fit:M"])]);
  const found = judgeInvariants(states, { states: { "a#x": ["gap-token:row 1 -> row 2", "menu-row:gone"] } });
  expect(found.broke.map(({ state, violations }) => [state, violations.map(({ key }) => key)])).toEqual([["a#x", ["icon-column:row 1"]]]);
  expect(found.unlisted.map(({ state }) => state)).toEqual(["n#w"]);
  expect(found.mended).toEqual([{ state: "a#x", keys: ["menu-row:gone"] }]);
  expect(invariantSummary(found)).toContain("[icon-column] icon-column:row 1");
});

test("only a violation every run shows counts", () => {
  const first = invariantsOf([result("a", "x", ["icon-column:row 1", "center-line:row 2"])]);
  const second = invariantsOf([result("a", "x", ["icon-column:row 1"])]);
  expect([...everyRun([first, second]).get("a#x")!.keys()]).toEqual(["icon-column:row 1"]);
});

test("rows only shrink; --add writes rows for new states", () => {
  const states = invariantsOf([result("a", "x", []), result("b", "y", ["menu-fit:M"])]);
  expect(shrunk({ states: { "a#x": ["icon-column:row 1"] } }, states, true).states).toEqual({ "a#x": [], "b#y": ["menu-fit:M"] });
});
