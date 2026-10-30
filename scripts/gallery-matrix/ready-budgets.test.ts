import { expect, test } from "bun:test";
import { budgetSummary } from "./health";
import { type Budgets, fastest, formatBudgets, limit, lowerable, lowered, overBudget, readBudgets, readyTimes } from "./ready-budgets";

const budgets: Budgets = { default: 1000, states: { "slow.entry#open": 4000, "slow.entry#closed": 3000 } };
const result = (entry: string, variant: string, readyMs: number | null, ready = "1") => ({ params: { entry, variant }, ready, readyMs });

test("a state's time is its slowest case in a run; a state with an unready case has none", () => {
  const times = readyTimes([
    result("ui.select", "open", 300),
    result("ui.select", "open", 450),
    result("ui.menu", "open", 900, "error"),
    result("ui.list", "empty", null),
    result("ui.tabs", "wide", 200),
    result("ui.tabs", "wide", null, "error"),
  ]);
  expect(times).toEqual(new Map([["ui.select#open", 450]]));
});

test("a state fails only when its fastest run is past its budget's margin", () => {
  expect(limit(1000)).toBe(2000);
  const runs = [
    new Map([
      ["ui.select#open", 2600],
      ["slow.entry#open", 7000],
    ]),
    new Map([["ui.select#open", 1900]]),
  ];
  // ui.select (default 1000, limit 2000) was fast once; slow.entry#open (4000, limit 6500) never was.
  expect(overBudget(fastest(runs), budgets)).toEqual([{ state: "slow.entry#open", ms: 7000, budget: 4000 }]);
});

test("rows a run beats by a fifth are printed with the lower value", () => {
  const times = new Map([
    ["slow.entry#open", 3150],
    ["slow.entry#closed", 2700],
    ["ui.select#open", 200],
  ]);
  const lower = lowerable(times, budgets);
  expect(lower).toEqual([{ state: "slow.entry#open", ms: 3200, budget: 4000 }]);
  expect(budgetSummary([], lower)).toContain("- slow.entry#open: 4000 -> 3200 ms");
  expect(budgetSummary([{ state: "x#y", ms: 9000, budget: 1000 }], [])).toContain("- x#y: 9000 ms, budget 1000 ms");
});

test("updating lowers rows and never raises one; a row at the default goes", () => {
  const times = new Map([
    ["slow.entry#open", 5200],
    ["slow.entry#closed", 640],
    ["new.entry#open", 2500],
  ]);
  expect(lowered(budgets, times)).toEqual({ default: 1000, states: { "slow.entry#open": 4000 } });
  // --add writes a row for a slow state that had none: a raise the diff shows.
  expect(lowered(budgets, times, true).states["new.entry#open"]).toBe(2500);
});

test("the budgets file parses, and every row is over the default and in tenths of a second", () => {
  const file = readBudgets();
  expect(formatBudgets(JSON.parse(formatBudgets(file)) as Budgets)).toBe(formatBudgets(file));
  for (const [state, ms] of Object.entries(file.states)) {
    expect(state).toMatch(/^[\w.-]+#[\w.-]+$/);
    expect(ms).toBeGreaterThan(file.default);
    expect(ms % 100).toBe(0);
  }
});
