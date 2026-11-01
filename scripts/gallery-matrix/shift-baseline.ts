#!/usr/bin/env bun
// Layout-shift baselines: how much each gallery state may shift, opening it and through its play
// steps (Leo, 2026-11-01: "how about like the apparatuses for improving ui verification? let's
// examine what we can do better for our workflows"). The stage measures the shift
// (webviews/src/gallery/shift.ts and play.ts): the browser's layout-shift entries and the tracked
// rows' boxes frame by frame, which also see a bottom-pinned transcript scrolling its rows away. A
// state's score is its load plus each step, the larger of the two measures for each, and the worst
// case of the state (widths, engines) in a run.
//
// shift-baseline.json holds a row for every measured state. Gallery health fails a state whose
// row is 0 the moment it shifts, and a state past its non-zero row by its margin, so the PR that
// adds a shift is the one that is caught. A state with no row yet (a new entry) only warns. Rows
// only go down: a run that finds a state under its row prints the lower value, and
//
//   bun shift-baseline.ts --from <downloaded gallery-health-* artifacts>
//
// lowers every row the run beat. It never raises a row; `--add` writes rows for states that have
// none, the run's scores, a change the PR diff shows.
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";

export type ShiftBaseline = { states: Record<string, number> };

type StepLike = { layoutShift?: number; boxShift?: number; boxMoves?: { label: string; dx: number; dy: number }[]; step?: string };
export type ShiftResult = {
  params?: Record<string, unknown>;
  ready?: string | null;
  load?: { layoutShift?: number; boxShift?: number; boxMoves?: { label: string; dx: number; dy: number }[] } | null;
  play?: { steps?: StepLike[] } | null;
};

export const SHIFT_BASELINE_PATH = join(import.meta.dir, "shift-baseline.json");

/** A zero row fails past this: under it is rounding no one sees (a 2 px nudge of one row scores about 2e-4). */
export const ZERO_SLACK = 0.0001;

/** A non-zero row fails past a quarter again plus 0.001: frame timing varies run to run. */
export const limit = (row: number): number => (row === 0 ? ZERO_SLACK : row * 1.25 + 0.001);

const round = (value: number) => Math.round(value * 1e5) / 1e5;
const larger = (phase: { layoutShift?: number; boxShift?: number } | null | undefined) =>
  Math.max(phase?.layoutShift ?? 0, phase?.boxShift ?? 0);

const stateOf = (result: { params?: Record<string, unknown> }): string =>
  `${String(result.params?.entry ?? "")}#${String(result.params?.variant ?? "")}`;

/** One case's score: its load plus each play step. */
export function caseScore(result: ShiftResult): number {
  return round(larger(result.load) + (result.play?.steps ?? []).reduce((sum, step) => sum + larger(step), 0));
}

/** What moved, for the red's message: the biggest phases' first moves. */
export function caseMoves(result: ShiftResult): string[] {
  const phases = [
    { name: "load", phase: result.load },
    ...(result.play?.steps ?? []).map((step) => ({ name: step.step ?? "step", phase: step })),
  ].filter(({ phase }) => larger(phase) > 0);
  return phases.slice(0, 3).map(({ name, phase }) => {
    const moves = (phase?.boxMoves ?? []).slice(0, 2).map((move) => `${move.label} [${move.dx} ${move.dy}]`);
    return `${name}: ${larger(phase).toFixed(4)}${moves.length ? ` (${moves.join(", ")})` : ""}`;
  });
}

/** Each state's score in one run: the worst of its cases. A state with a case that never got ready has none. */
export function shiftScores(results: ShiftResult[]): Map<string, { score: number; moves: string[] }> {
  const scores = new Map<string, { score: number; moves: string[] }>();
  const unready = new Set<string>();
  for (const result of results) {
    const state = stateOf(result);
    if (result.ready !== "1") {
      unready.add(state);
      continue;
    }
    const score = caseScore(result);
    const seen = scores.get(state);
    if (!seen || score > seen.score) scores.set(state, { score, moves: caseMoves(result) });
  }
  for (const state of unready) scores.delete(state);
  return scores;
}

/** The least each state shifted across runs: a shift every run is the page's, one run's is noise. */
export function least(runs: Map<string, { score: number; moves: string[] }>[]): Map<string, { score: number; moves: string[] }> {
  const best = new Map<string, { score: number; moves: string[] }>();
  for (const scores of runs)
    for (const [state, value] of scores) if (!best.has(state) || value.score < best.get(state)!.score) best.set(state, value);
  return best;
}

export type ShiftFinding = { state: string; score: number; baseline: number; moves: string[] };

export function readShiftBaseline(path = SHIFT_BASELINE_PATH): ShiftBaseline {
  const parsed = JSON.parse(readFileSync(path, "utf8")) as Partial<ShiftBaseline>;
  if (!parsed.states || typeof parsed.states !== "object") throw new Error(`${path}: no "states" object`);
  return { states: parsed.states };
}

/** States past their row's limit (the check fails on these), states with no row (it warns) and rows to lower. */
export function judgeShift(
  scores: Map<string, { score: number; moves: string[] }>,
  baseline: ShiftBaseline,
): { shifted: ShiftFinding[]; unbaselined: ShiftFinding[]; lower: ShiftFinding[] } {
  const shifted: ShiftFinding[] = [];
  const unbaselined: ShiftFinding[] = [];
  const lower: ShiftFinding[] = [];
  for (const [state, { score, moves }] of [...scores].sort(([a], [b]) => a.localeCompare(b))) {
    const row = baseline.states[state];
    if (row === undefined) unbaselined.push({ state, score, baseline: Number.NaN, moves });
    else if (score > limit(row)) shifted.push({ state, score, baseline: row, moves });
    else if (row > 0 && score < row * 0.8) lower.push({ state, score, baseline: row, moves });
  }
  return { shifted, unbaselined, lower };
}

export function shiftSummary(found: ReturnType<typeof judgeShift>): string {
  const lines: string[] = [];
  if (found.shifted.length) {
    lines.push("", "Layout shift past the state's baseline (a row that does not move must not move; see scripts/gallery-matrix/shift-baseline.ts):");
    for (const { state, score, baseline, moves } of found.shifted)
      lines.push(`- ${state}: shift ${score.toFixed(4)}, baseline ${baseline}${moves.length ? `; ${moves.join("; ")}` : ""}`);
  }
  const moving = found.unbaselined.filter(({ score }) => score > 0);
  if (found.unbaselined.length) {
    lines.push("", `No shift baseline yet for ${found.unbaselined.length} state(s) (a warning; add rows with \`bun shift-baseline.ts --from <artifacts> --add\`)${moving.length ? ", these shift:" : "."}`);
    for (const { state, score, moves } of moving) lines.push(`- ${state}: shift ${score.toFixed(4)}${moves.length ? `; ${moves.join("; ")}` : ""}`);
  }
  if (found.lower.length) {
    lines.push("", "Shifts less than its row; lower it in shift-baseline.json:");
    for (const { state, score, baseline } of found.lower) lines.push(`- ${state}: ${baseline} -> ${score}`);
  }
  return lines.join("\n");
}

/** The baseline lowered to a run's scores; rows never rise, and `add` writes rows for new states. */
export function lowered(baseline: ShiftBaseline, scores: Map<string, number>, add = false): ShiftBaseline {
  const states: Record<string, number> = {};
  for (const [state, row] of Object.entries(baseline.states)) {
    const score = scores.get(state);
    states[state] = score === undefined ? row : Math.min(row, score <= ZERO_SLACK ? 0 : score);
  }
  if (add) for (const [state, score] of scores) if (!(state in states)) states[state] = score <= ZERO_SLACK ? 0 : score;
  return { states: Object.fromEntries(Object.entries(states).sort(([a], [b]) => a.localeCompare(b))) };
}

/** Every results.json under `dir` (downloaded gallery-health-* artifacts, each with attempt-N folders). */
function resultsUnder(dir: string): ShiftResult[][] {
  const runs: ShiftResult[][] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true, recursive: true })) {
    if (!entry.isFile() || entry.name !== "results.json") continue;
    const parent = (entry as { parentPath?: string; path?: string }).parentPath ?? (entry as { path?: string }).path ?? dir;
    runs.push(JSON.parse(readFileSync(join(parent, entry.name), "utf8")) as ShiftResult[]);
  }
  return runs;
}

if (import.meta.main) {
  const { values } = parseArgs({ options: { from: { type: "string" }, add: { type: "boolean", default: false }, baseline: { type: "string", default: SHIFT_BASELINE_PATH } } });
  if (!values.from) throw new Error("--from <dir of gallery-health artifacts> is required");
  const scores = new Map([...least(resultsUnder(values.from).map(shiftScores))].map(([state, { score }]) => [state, score]));
  const next = lowered(readShiftBaseline(values.baseline), scores, values.add);
  writeFileSync(values.baseline, `${JSON.stringify(next, null, 2)}\n`);
  console.log(`${Object.keys(next.states).length} rows (${Object.values(next.states).filter((row) => row > 0).length} non-zero) in ${values.baseline}`);
}
