#!/usr/bin/env bun
// Undeclared layout moves: the gallery's gate on the layout-motion contract
// (schemas/layout-motion/contract.json). Leo, 2026-11-18: "I was thinking we'd be able to calculate each
// beforehand everything that would move and just go ok well nothing else usually should and the things that
// move we only expect at certain times etc ... Fundamentally".
//
// The stage judges every load and play step (webviews/src/layout/motionJudge.ts): a box that drew in one
// place and then moved or resized, with no declared event its surface allows, is an undeclared move. A
// state's count is the boxes that made one, its load plus each step, the worst case of the state (widths,
// engines) in a run, and the least over gallery health's retries (a move every retry is the page's).
//
// Gallery health fails a state whose count is over its row in undeclared-baseline.json, and a state with no
// row that makes any undeclared move: a new state starts at zero. A row above zero is a known move still to
// fix; its `issue` names the cmuxterm-hq issue that tracks it. Rows only go down:
//
//   bun undeclared-baseline.ts --from <downloaded gallery-health-* artifacts>
//
// lowers every row the runs beat (scored by the worst run, so a flaky state keeps a row over its flakes)
// and drops rows that reach zero. `--add --issue URL` writes rows for states with none, the way the
// contract was first seeded.
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";

export type UndeclaredRow = { count: number; issue: string };
export type UndeclaredBaseline = { $comment?: string; states: Record<string, UndeclaredRow> };

type Move = { label: string; surface?: string; frame?: number; dx: number; dy: number; dw?: number; dh?: number };
type Phase = { undeclared?: number; undeclaredMoves?: Move[]; step?: string } | null | undefined;
export type UndeclaredResult = {
  params?: Record<string, unknown>;
  ready?: string | null;
  load?: Phase;
  play?: { steps?: Phase[] } | null;
};
export type Count = { count: number; moves: string[] };

export const UNDECLARED_BASELINE_PATH = join(import.meta.dir, "undeclared-baseline.json");

const stateOf = (result: { params?: Record<string, unknown> }): string =>
  `${String(result.params?.entry ?? "")}#${String(result.params?.variant ?? "")}`;

const describe = (name: string, phase: Phase): string => {
  const moves = (phase?.undeclaredMoves ?? [])
    .slice(0, 2)
    .map((move) => `${move.label} [${move.dx} ${move.dy} ${move.dw ?? 0} ${move.dh ?? 0}]${move.frame === undefined ? "" : ` @f${move.frame}`}`);
  return `${name}: ${phase?.undeclared ?? 0}${moves.length ? ` (${moves.join(", ")})` : ""}`;
};

/** One case's count: its load plus each play step, and what moved in the first phases that moved. */
export function caseCount(result: UndeclaredResult): Count {
  const phases = [
    { name: "load", phase: result.load },
    ...(result.play?.steps ?? []).map((phase) => ({ name: phase?.step ?? "step", phase })),
  ];
  const count = phases.reduce((sum, { phase }) => sum + (phase?.undeclared ?? 0), 0);
  const moves = phases.filter(({ phase }) => (phase?.undeclared ?? 0) > 0).slice(0, 3);
  return { count, moves: moves.map(({ name, phase }) => describe(name, phase)) };
}

/** Each state's count in one run: the worst of its cases. A state with a case that never got ready has none. */
export function undeclaredCounts(results: UndeclaredResult[]): Map<string, Count> {
  const counts = new Map<string, Count>();
  const unready = new Set<string>();
  for (const result of results) {
    const state = stateOf(result);
    if (result.ready !== "1") {
      unready.add(state);
      continue;
    }
    const counted = caseCount(result);
    const seen = counts.get(state);
    if (!seen || counted.count > seen.count) counts.set(state, counted);
  }
  for (const state of unready) counts.delete(state);
  return counts;
}

/** The least each state moved across runs (retries): a move every run is the page's. */
export function leastCount(runs: Map<string, Count>[]): Map<string, Count> {
  const best = new Map<string, Count>();
  for (const counts of runs)
    for (const [state, value] of counts) if (!best.has(state) || value.count < best.get(state)!.count) best.set(state, value);
  return best;
}

/** The most each state moved across runs: rows are written from this. */
export function mostCount(runs: Map<string, Count>[]): Map<string, Count> {
  const worst = new Map<string, Count>();
  for (const counts of runs)
    for (const [state, value] of counts) if (!worst.has(state) || value.count > worst.get(state)!.count) worst.set(state, value);
  return worst;
}

export function readUndeclaredBaseline(path = UNDECLARED_BASELINE_PATH): UndeclaredBaseline {
  const parsed = JSON.parse(readFileSync(path, "utf8")) as Partial<UndeclaredBaseline>;
  if (!parsed.states || typeof parsed.states !== "object") throw new Error(`${path}: no "states" object`);
  for (const [state, row] of Object.entries(parsed.states))
    if (typeof row?.count !== "number" || row.count <= 0 || !/^https:\/\/github\.com\/\S+\/issues\/\d+$/.test(row.issue ?? ""))
      throw new Error(`${path}: ${state}: a row is a count above 0 and the issue URL that tracks it`);
  return parsed as UndeclaredBaseline;
}

export type UndeclaredFinding = { state: string; count: number; baseline: number; moves: string[] };

/** States over their row (the check fails on these, a state with no row included) and rows to lower. */
export function judgeUndeclared(
  counts: Map<string, Count>,
  baseline: UndeclaredBaseline,
): { moved: UndeclaredFinding[]; lower: UndeclaredFinding[] } {
  const moved: UndeclaredFinding[] = [];
  const lower: UndeclaredFinding[] = [];
  for (const [state, { count, moves }] of [...counts].sort(([a], [b]) => a.localeCompare(b))) {
    const row = baseline.states[state]?.count ?? 0;
    if (count > row) moved.push({ state, count, baseline: row, moves });
    else if (count < row) lower.push({ state, count, baseline: row, moves });
  }
  return { moved, lower };
}

export function undeclaredSummary(found: ReturnType<typeof judgeUndeclared>): string {
  const lines: string[] = [];
  if (found.moved.length) {
    lines.push(
      "",
      "Undeclared layout moves (a box moved on no event its surface declares; schemas/layout-motion/contract.json, scripts/gallery-matrix/undeclared-baseline.ts):",
    );
    for (const { state, count, baseline, moves } of found.moved)
      lines.push(`- ${state}: ${count} undeclared (baseline ${baseline})${moves.length ? `; ${moves.join("; ")}` : ""}`);
    lines.push(
      "Fix it: size the box before it mounts (Pretext, the record's size, a reserved slot), or declare the move where the code means it (declareMove, a play's ctx.declare) if its surface allows that event.",
    );
  }
  if (found.lower.length) {
    lines.push("", "Fewer undeclared moves than the row; lower it in undeclared-baseline.json (bun undeclared-baseline.ts --from <artifacts>):");
    for (const { state, count, baseline } of found.lower) lines.push(`- ${state}: ${baseline} -> ${count}`);
  }
  return lines.join("\n");
}

/** The baseline lowered to a run's counts; rows never rise, rows at zero go, and `add` writes rows for states with none. */
export function loweredUndeclared(
  baseline: UndeclaredBaseline,
  counts: Map<string, number>,
  add?: { issue: string },
): UndeclaredBaseline {
  const states: Record<string, UndeclaredRow> = {};
  for (const [state, row] of Object.entries(baseline.states)) {
    const count = Math.min(row.count, counts.get(state) ?? row.count);
    if (count > 0) states[state] = { ...row, count };
  }
  if (add) for (const [state, count] of counts) if (!(state in states) && !(state in baseline.states) && count > 0) states[state] = { count, issue: add.issue };
  return {
    ...(baseline.$comment ? { $comment: baseline.$comment } : {}),
    states: Object.fromEntries(Object.entries(states).sort(([a], [b]) => a.localeCompare(b))),
  };
}

function resultsUnder(dir: string): UndeclaredResult[][] {
  const runs: UndeclaredResult[][] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true, recursive: true })) {
    if (!entry.isFile() || entry.name !== "results.json") continue;
    const parent = (entry as { parentPath?: string; path?: string }).parentPath ?? (entry as { path?: string }).path ?? dir;
    runs.push(JSON.parse(readFileSync(join(parent, entry.name), "utf8")) as UndeclaredResult[]);
  }
  return runs;
}

if (import.meta.main) {
  const { values } = parseArgs({
    options: {
      from: { type: "string" },
      add: { type: "boolean", default: false },
      issue: { type: "string" },
      baseline: { type: "string", default: UNDECLARED_BASELINE_PATH },
    },
  });
  if (!values.from) throw new Error("--from <dir of gallery-health artifacts> is required");
  if (values.add && !values.issue) throw new Error("--add needs --issue <the cmuxterm-hq issue URL that tracks the rows>");
  const runs = resultsUnder(values.from).map(undeclaredCounts);
  const counts = new Map([...mostCount(runs)].map(([state, { count }]) => [state, count]));
  const next = loweredUndeclared(readUndeclaredBaseline(values.baseline), counts, values.add ? { issue: values.issue! } : undefined);
  writeFileSync(values.baseline, `${JSON.stringify(next, null, 2)}\n`);
  console.log(`${Object.keys(next.states).length} rows in ${values.baseline}`);
}
