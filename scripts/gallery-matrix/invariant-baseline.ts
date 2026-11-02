#!/usr/bin/env bun
// Geometry baselines: the design specs' rules each gallery state already breaks
// (webviews/src/gallery/invariants.ts reads them from the DOM). Leo, 2026-11-01: "how about like
// the apparatuses for improving ui verification? let's examine what we can do better for our
// workflows", after a nightly with rows spaced off the scale, a reply off the tool icon column and
// a picker too wide, none of which review caught from screenshots.
//
// invariant-baseline.json holds, for every measured state, the violation keys it had when its row
// was written (most rows are empty). Gallery health fails a state that breaks a rule its row does
// not list, so the PR that moves a row off its column is the one that is caught. A state with no
// row yet (a new entry) only warns. A violation counts only when every run of the state shows it.
// Rows only shrink: a run that no longer shows a listed violation prints it, and
//
//   bun invariant-baseline.ts --from <downloaded gallery-health-* artifacts>
//
// drops every listed violation the run did not show. It never adds one to a row; `--add` writes
// rows for states that have none, from the run, a change the PR diff shows.
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";

export type Violation = { rule: string; key: string; detail: string };
export type InvariantBaseline = { states: Record<string, string[]> };
export type InvariantResult = { params?: Record<string, unknown>; ready?: string | null; invariants?: Violation[] | null };

export const INVARIANT_BASELINE_PATH = join(import.meta.dir, "invariant-baseline.json");

const stateOf = (result: { params?: Record<string, unknown> }): string =>
  `${String(result.params?.entry ?? "")}#${String(result.params?.variant ?? "")}`;

/** Each measured state's violations in one run, by key, across its cases (widths, schemes, engines). */
export function invariantsOf(results: InvariantResult[]): Map<string, Map<string, Violation>> {
  const states = new Map<string, Map<string, Violation>>();
  const unread = new Set<string>();
  for (const result of results) {
    const state = stateOf(result);
    // A stage that never got ready, or from a checker before this gate, measured nothing.
    if (result.ready !== "1" || !Array.isArray(result.invariants)) {
      unread.add(state);
      continue;
    }
    const found = states.get(state) ?? new Map<string, Violation>();
    for (const violation of result.invariants) if (!found.has(violation.key)) found.set(violation.key, violation);
    states.set(state, found);
  }
  for (const state of unread) states.delete(state);
  return states;
}

/** The violations every run showed: one run's is noise (a font still swapping in). */
export function everyRun(runs: Map<string, Map<string, Violation>>[]): Map<string, Map<string, Violation>> {
  const kept = new Map<string, Map<string, Violation>>();
  for (const [state, first] of runs[0] ?? []) {
    const later = runs.slice(1).map((run) => run.get(state));
    kept.set(state, new Map([...first].filter(([key]) => later.every((found) => !found || found.has(key)))));
  }
  return kept;
}

export type InvariantFinding = { state: string; violations: Violation[] };

export function readInvariantBaseline(path = INVARIANT_BASELINE_PATH): InvariantBaseline {
  const parsed = JSON.parse(readFileSync(path, "utf8")) as Partial<InvariantBaseline>;
  if (!parsed.states || typeof parsed.states !== "object") throw new Error(`${path}: no "states" object`);
  return { states: parsed.states };
}

/** New violations (the check fails on these), states with no row (it warns), and listed ones now gone. */
export function judgeInvariants(
  states: Map<string, Map<string, Violation>>,
  baseline: InvariantBaseline,
): { broke: InvariantFinding[]; unlisted: InvariantFinding[]; mended: { state: string; keys: string[] }[] } {
  const broke: InvariantFinding[] = [];
  const unlisted: InvariantFinding[] = [];
  const mended: { state: string; keys: string[] }[] = [];
  for (const [state, found] of [...states].sort(([a], [b]) => a.localeCompare(b))) {
    const row = baseline.states[state];
    if (row === undefined) {
      unlisted.push({ state, violations: [...found.values()] });
      continue;
    }
    const known = new Set(row);
    const fresh = [...found.values()].filter(({ key }) => !known.has(key));
    if (fresh.length) broke.push({ state, violations: fresh });
    const gone = row.filter((key) => !found.has(key));
    if (gone.length) mended.push({ state, keys: gone });
  }
  return { broke, unlisted, mended };
}

export function invariantSummary(found: ReturnType<typeof judgeInvariants>): string {
  const lines: string[] = [];
  if (found.broke.length) {
    lines.push("", "Geometry rules broken (design/*.md; see webviews/src/gallery/invariants.ts):");
    for (const { state, violations } of found.broke)
      for (const { detail, rule } of violations) lines.push(`- ${state}: [${rule}] ${detail}`);
  }
  const breaking = found.unlisted.filter(({ violations }) => violations.length);
  if (found.unlisted.length) {
    lines.push("", `No geometry baseline yet for ${found.unlisted.length} state(s) (a warning; add rows with \`bun invariant-baseline.ts --from <artifacts> --add\`)${breaking.length ? ", these break a rule:" : "."}`);
    for (const { state, violations } of breaking)
      for (const { detail, rule } of violations.slice(0, 4)) lines.push(`- ${state}: [${rule}] ${detail}`);
  }
  if (found.mended.length) {
    lines.push("", "Mended; drop from invariant-baseline.json:");
    for (const { state, keys } of found.mended) lines.push(`- ${state}: ${keys.join(", ")}`);
  }
  return lines.join("\n");
}

/** The baseline with every violation the run no longer showed dropped; `add` writes rows for new states. */
export function shrunk(baseline: InvariantBaseline, states: Map<string, Map<string, Violation>>, add = false): InvariantBaseline {
  const next: Record<string, string[]> = {};
  for (const [state, row] of Object.entries(baseline.states)) {
    const found = states.get(state);
    next[state] = found ? row.filter((key) => found.has(key)) : row;
  }
  if (add) for (const [state, found] of states) if (!(state in next)) next[state] = [...found.keys()].sort();
  return { states: Object.fromEntries(Object.entries(next).sort(([a], [b]) => a.localeCompare(b))) };
}

function resultsUnder(dir: string): InvariantResult[][] {
  const runs: InvariantResult[][] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true, recursive: true })) {
    if (!entry.isFile() || entry.name !== "results.json") continue;
    const parent = (entry as { parentPath?: string; path?: string }).parentPath ?? (entry as { path?: string }).path ?? dir;
    runs.push(JSON.parse(readFileSync(join(parent, entry.name), "utf8")) as InvariantResult[]);
  }
  return runs;
}

if (import.meta.main) {
  const { values } = parseArgs({ options: { from: { type: "string" }, add: { type: "boolean", default: false }, baseline: { type: "string", default: INVARIANT_BASELINE_PATH } } });
  if (!values.from) throw new Error("--from <dir of gallery-health artifacts> is required");
  // A state's violations across every downloaded run (shards render disjoint states; attempts the same).
  const merged = new Map<string, Map<string, Violation>>();
  for (const run of resultsUnder(values.from).map(invariantsOf))
    for (const [state, found] of run) merged.set(state, new Map([...(merged.get(state) ?? []), ...found]));
  const next = shrunk(readInvariantBaseline(values.baseline), merged, values.add);
  writeFileSync(values.baseline, `${JSON.stringify(next, null, 2)}\n`);
  const rows = Object.values(next.states);
  console.log(`${rows.length} rows (${rows.filter((row) => row.length).length} with listed violations) in ${values.baseline}`);
}
