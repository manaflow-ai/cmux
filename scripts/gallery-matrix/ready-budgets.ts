#!/usr/bin/env bun
// Ready-time budgets: how long each gallery state may take, from navigation start, to say it is ready
// (mount, play and settle; runner.ts records `readyMs`). Gallery health fails a state that takes more
// than its budget by the margin on every run, so a state that gets slower is caught in the PR that
// slowed it. ready-budgets.json holds a default and a row for each state slower than the default.
// Rows only go down: a run that finds a state well under its row prints the lower value, and
//
//   bun ready-budgets.ts --from <downloaded gallery-health-* artifacts>
//
// lowers every row the run beat (and drops rows that fall to the default). It never raises a row;
// `--add` adds rows for states over the default that have none, a raise the PR diff shows.
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";

export type Budgets = { default: number; states: Record<string, number> };
export type ReadyResult = { params?: Record<string, unknown>; ready?: string | null; readyMs?: number | null };

export const BUDGETS_PATH = join(import.meta.dir, "ready-budgets.json");

/** A state fails only past its budget by half again plus half a second: CI runners vary run to run. */
export const limit = (budget: number): number => Math.round(budget * 1.5 + 500);

/** Budgets are whole tenths of a second. */
export const roundUp = (ms: number): number => Math.ceil(ms / 100) * 100;

export const budgetOf = (budgets: Budgets, state: string): number => budgets.states[state] ?? budgets.default;

const stateOf = (result: ReadyResult): string =>
  `${String(result.params?.entry ?? "")}#${String(result.params?.variant ?? "")}`;

/**
 * Each state's time in one run: the slowest of its cases (a state may render at several widths). A
 * state with a case that never got ready has no time in that run, so a fast case cannot stand in for it.
 */
export function readyTimes(results: ReadyResult[]): Map<string, number> {
  const times = new Map<string, number>();
  const unready = new Set<string>();
  for (const result of results) {
    const state = stateOf(result);
    if (result.ready !== "1" || typeof result.readyMs !== "number") unready.add(state);
    else times.set(state, Math.max(times.get(state) ?? 0, result.readyMs));
  }
  for (const state of unready) times.delete(state);
  return times;
}

/** The fastest time each state took across runs: a slow run is noise, a state slow every time is not. */
export function fastest(runs: Map<string, number>[]): Map<string, number> {
  const best = new Map<string, number>();
  for (const times of runs)
    for (const [state, ms] of times) best.set(state, Math.min(best.get(state) ?? Infinity, ms));
  return best;
}

export type Timing = { state: string; ms: number; budget: number };

/** States past their budget's limit. */
export function overBudget(times: Map<string, number>, budgets: Budgets): Timing[] {
  return [...times]
    .map(([state, ms]) => ({ state, ms, budget: budgetOf(budgets, state) }))
    .filter(({ ms, budget }) => ms > limit(budget))
    .sort((a, b) => a.state.localeCompare(b.state));
}

/** Rows a run beat by a fifth or more: their budget can come down to `ms` (rounded up). */
export function lowerable(times: Map<string, number>, budgets: Budgets): Timing[] {
  return [...times]
    .filter(([state]) => state in budgets.states)
    .map(([state, ms]) => ({ state, ms: roundUp(ms), budget: budgets.states[state]! }))
    .filter(({ ms, budget }) => ms <= budget * 0.8)
    .sort((a, b) => a.state.localeCompare(b.state));
}

/** Budgets lowered to what the run measured; rows never rise, and a row at or under the default goes. */
export function lowered(budgets: Budgets, times: Map<string, number>, add = false): Budgets {
  const states: Record<string, number> = {};
  for (const [state, budget] of Object.entries(budgets.states)) {
    const ms = times.get(state);
    const next = ms === undefined ? budget : Math.min(budget, roundUp(ms));
    if (next > budgets.default) states[state] = next;
  }
  if (add)
    for (const [state, ms] of times) if (!(state in states) && roundUp(ms) > budgets.default) states[state] = roundUp(ms);
  const sorted = Object.fromEntries(Object.entries(states).sort(([a], [b]) => a.localeCompare(b)));
  return { default: budgets.default, states: sorted };
}

export const readBudgets = (path = BUDGETS_PATH): Budgets => JSON.parse(readFileSync(path, "utf8")) as Budgets;

export const formatBudgets = (budgets: Budgets): string =>
  `{\n  "default": ${budgets.default},\n  "states": {\n${Object.entries(budgets.states)
    .map(([state, ms]) => `    ${JSON.stringify(state)}: ${ms}`)
    .join(",\n")}\n  }\n}\n`;

/** Every results.json under a directory (the gallery-health-* artifacts hold one per attempt). */
function resultFiles(dir: string): string[] {
  return readdirSync(dir, { recursive: true, encoding: "utf8" })
    .filter((path) => path === "results.json" || path.endsWith("/results.json"))
    .map((path) => join(dir, path));
}

function main(): void {
  const { values } = parseArgs({
    options: { from: { type: "string" }, budgets: { type: "string", default: BUDGETS_PATH }, add: { type: "boolean", default: false } },
  });
  if (!values.from) throw new Error("--from <dir with the gallery health runs' results.json> is required");
  const runs = resultFiles(values.from).map((file) => readyTimes(JSON.parse(readFileSync(file, "utf8")) as ReadyResult[]));
  if (!runs.length) throw new Error(`no results.json under ${values.from}`);
  const before = readBudgets(values.budgets);
  const after = lowered(before, fastest(runs), values.add);
  writeFileSync(values.budgets, formatBudgets(after));
  const changed = new Set([...Object.keys(before.states), ...Object.keys(after.states)]);
  for (const state of [...changed].sort())
    if (before.states[state] !== after.states[state])
      console.log(`${state}: ${before.states[state] ?? `default ${before.default}`} -> ${after.states[state] ?? `default ${after.default}`}`);
}

if (import.meta.main) main();
