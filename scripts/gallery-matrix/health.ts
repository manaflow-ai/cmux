#!/usr/bin/env bun
// Gallery health: every gallery state must render. A state is broken when its stage errors (a
// fixture that cannot find its control fails the mount), never reports ready, the renderer dies, or
// its play throws (it cannot find or reach the state it describes, or fails its own assertion). A
// stage that draws nothing is not broken by itself: some states are empty on purpose. Long frames
// and motion are the matrix's findings, not this check's; layout shift is this check's (below).
//
// A case broken on the first run is rendered twice more; only a case broken every time counts.
// broken-allowlist.json names known broken states (`entry#variant`) with the reason each is
// waiting. A broken state that is not on it fails the check; a listed state that now renders is
// printed so its line can go.
//
// Each state must also say it is ready within its budget of renderer CPU time, not wall time
// (ready-budgets.ts, ready-budgets.json): a
// state past its budget's margin is rendered again with the broken ones, and fails only if its
// fastest run is still past it. A state well under its budget is printed so its row can come down.
//
// And each state must not shift more than its row in shift-baseline.json (shift-baseline.ts): its
// load and play steps, measured from the browser's layout-shift entries and from the tracked rows'
// boxes frame by frame. A state whose row is 0 fails on any shift; a state with no row only warns.
// A state that shifted is rendered again with the others, and fails only if it shifts every time.
//
// And each state must keep the design specs' geometry rules its row in invariant-baseline.json
// keeps (invariant-baseline.ts, webviews/src/gallery/invariants.ts): one icon column, icons on
// their line, gap tokens, menu label columns, row heights and widths. A violation the row does not
// list fails, when every run shows it; a state with no row only warns.
//
// And each state must make no layout move the layout-motion contract does not declare
// (schemas/layout-motion/contract.json, undeclared-baseline.ts): a box that drew in one place and then
// moved or resized on no event its surface allows. A state over its row in undeclared-baseline.json fails,
// a state with no row on its first undeclared move, when every run shows it.
//
// The first render runs --concurrency cases at once (default: one per CPU), each worker with its
// own browser: rendered one at a time, a shard's ~1,400 cases took ~23 minutes. Budgets are CPU
// time, so a busy runner does not stretch them. The renders again (the retries) run one at a time,
// so a state that broke, ran slow or shifted only because its neighbours loaded the runner is
// judged again on a quiet one.
//
//   CMUX_GALLERY_IN_VM=1 bun health.ts --manifest m.json --gallery-dir ../../webviews/dist/gallery
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { appendFileSync } from "node:fs";
import { availableParallelism } from "node:os";
import { join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { type Timing, BUDGETS_PATH, fastest, lowerable, overBudget, readBudgets, readyTimes } from "./ready-budgets";
import { type Engine, type MatrixCase, parseManifest, runLocal, shardCases } from "./runner";
import { INVARIANT_BASELINE_PATH, type InvariantResult, everyRun, invariantSummary, invariantsOf, judgeInvariants, readInvariantBaseline } from "./invariant-baseline";
import { SHIFT_BASELINE_PATH, type ShiftResult, judgeShift, least, limit as shiftLimit, readShiftBaseline, shiftScores, shiftSummary } from "./shift-baseline";
import { UNDECLARED_BASELINE_PATH, type UndeclaredResult, judgeUndeclared, leastCount, readUndeclaredBaseline, undeclaredCounts, undeclaredSummary } from "./undeclared-baseline";

export type HealthResult = {
  id: string;
  params?: Record<string, unknown>;
  ready?: string | null;
  /** Navigation start to the stage's first ready report (runner.ts). */
  readyMs?: number | null;
  error?: string;
  play?: ({ status?: string; error?: string; motion?: { status?: string; problems?: string[] } | null } & ShiftResult["play"]) | null;
  load?: ShiftResult["load"];
  invariants?: InvariantResult["invariants"];
};

/** Play errors (frame/playRunner.ts) that mean the state was never reached; they are their own label. */
const UNREACHED = /no element for|waitFor did not hold/;

/** Why a rendered case is broken, or null when it rendered. */
export function brokenReason(result: HealthResult): string | null {
  if (result.error) return `did not render: ${result.error}`;
  if (result.ready === "error") return "the stage reported an error";
  if (result.ready !== "1") return "never reported ready";
  // runPlay (frame/playRunner.ts) sets `error` only when the play threw: a missing element, a wait
  // that never held, or the play's own assertion. Each means the stage does not show the state it
  // describes, whatever the status says. A play that finished with failing quality steps (layout
  // shift, long frames) has no `error`, and one that threw its own motion probe's problem
  // (motionEvidence.ts) failed on motion: both are the matrix's findings, not a broken state.
  const play = result.play;
  if (play && play.error !== undefined && play.error !== null) {
    const error = String(play.error);
    const first = error.split("\n")[0].trim();
    if (UNREACHED.test(first)) return first;
    if (play.motion?.status === "fail" && play.motion.problems?.includes(error)) return null;
    return first ? `play threw: ${first}` : "play threw with no message";
  }
  return null;
}

/** The allowlist's key: a state, whatever theme, width or engine showed it. */
export const stateKey = (result: { params?: Record<string, unknown> }): string =>
  `${String(result.params?.entry ?? "")}#${String(result.params?.variant ?? "")}`;

/**
 * The shard's cases, split by state: every case of a state lands in the shard its state's FNV-1a hash
 * names, whatever cases come before it. The split by position (shardCases, `--shard-by index`) moved
 * every state to another shard whenever one case was added or removed ahead of it, so `health (8)` was a
 * different set of states at each commit: a post-merge bisect probe judged leg 8 at its commit by states
 * that were never red at the batch (the red one was in another leg there), and a standing red hopped legs
 * from batch to batch and was a "new" red again each time (batch run 46040477174: legs 6, 8, 14 and 15 red,
 * each on a state the base replay did not share). Keyed by state, a leg holds the same states at any commit
 * with the same shard count, and a state's themes and widths render (and retry) in one shard.
 */
export function shardStates<T extends { params?: Record<string, unknown> }>(cases: T[], shardCount: number, shardIndex: number): T[] {
  if (!Number.isInteger(shardCount) || shardCount < 1) throw new Error("shardCount must be a positive integer");
  if (!Number.isInteger(shardIndex) || shardIndex < 0 || shardIndex >= shardCount) throw new Error("shardIndex must be within shardCount");
  return cases.filter((item) => stateShard(stateKey(item), shardCount) === shardIndex);
}

export function stateShard(state: string, shardCount: number): number {
  let hash = 0x811c9dc5;
  for (const byte of new TextEncoder().encode(state)) hash = Math.imul(hash ^ byte, 0x01000193) >>> 0;
  return hash % shardCount;
}

export type Verdict = {
  /** Broken states the allowlist does not name: the check fails on these. */
  fresh: { state: string; reason: string }[];
  /** Broken states the allowlist names. */
  known: { state: string; reason: string }[];
  /** Listed states this run rendered: their allowlist lines can go. */
  fixed: string[];
};

/** Splits this run's broken states against the allowlist. Only states the run covered count as fixed. */
export function judge(ran: Iterable<string>, broken: Map<string, string>, allowlist: Record<string, string>): Verdict {
  const fresh: Verdict["fresh"] = [];
  const known: Verdict["known"] = [];
  for (const [state, reason] of [...broken].sort(([a], [b]) => a.localeCompare(b)))
    (state in allowlist ? known : fresh).push({ state, reason });
  const fixed = [...new Set(ran)].filter((state) => state in allowlist && !broken.has(state)).sort();
  return { fresh, known, fixed };
}

/** Broken states of a run: state key to the first reason seen. */
export function brokenStates(results: HealthResult[]): Map<string, string> {
  const broken = new Map<string, string>();
  for (const result of results) {
    const reason = brokenReason(result);
    if (reason && !broken.has(stateKey(result))) broken.set(stateKey(result), reason);
  }
  return broken;
}

export function summary(verdict: Verdict, cases: number): string {
  const lines = [`Gallery health: ${cases} cases; ${verdict.fresh.length} newly broken state(s), ${verdict.known.length} on the allowlist.`];
  if (verdict.fresh.length) {
    lines.push("", "Broken (fix the state, or add it to scripts/gallery-matrix/broken-allowlist.json with why):");
    for (const { state, reason } of verdict.fresh) lines.push(`- ${state}: ${reason}`);
  }
  if (verdict.fixed.length) {
    lines.push("", "Rendered now; remove from broken-allowlist.json:");
    for (const state of verdict.fixed) lines.push(`- ${state}`);
  }
  return lines.join("\n");
}

/** States over their ready-time budget fail; states well under it can lower their rows. */
export function budgetSummary(slow: Timing[], lower: Timing[]): string {
  const lines: string[] = [];
  if (slow.length) {
    lines.push("", "Slower than the ready-time budget on every run (make the state faster; see scripts/gallery-matrix/ready-budgets.ts):");
    for (const { state, ms, budget } of slow) lines.push(`- ${state}: ${ms} ms, budget ${budget} ms`);
  }
  if (lower.length) {
    lines.push("", "Faster than the budget; lower its row in ready-budgets.json:");
    for (const { state, ms, budget } of lower) lines.push(`- ${state}: ${budget} -> ${ms} ms`);
  }
  return lines.join("\n");
}

async function main(): Promise<void> {
  const { values } = parseArgs({
    options: {
      manifest: { type: "string" },
      "gallery-dir": { type: "string" },
      "output-dir": { type: "string", default: "gallery-health-output" },
      allowlist: { type: "string", default: join(import.meta.dir, "broken-allowlist.json") },
      budgets: { type: "string", default: BUDGETS_PATH },
      "shift-baseline": { type: "string", default: SHIFT_BASELINE_PATH },
      "undeclared-baseline": { type: "string", default: UNDECLARED_BASELINE_PATH },
      "invariant-baseline": { type: "string", default: INVARIANT_BASELINE_PATH },
      engines: { type: "string", default: "chromium" },
      retries: { type: "string", default: "2" },
      "shard-count": { type: "string", default: "1" },
      "shard-index": { type: "string", default: "0" },
      // state (shardStates: a leg is the same states at every commit) or index (shardCases, by position).
      "shard-by": { type: "string", default: "state" },
      concurrency: { type: "string", default: String(availableParallelism()) },
    },
  });
  if (!values.manifest || !values["gallery-dir"]) throw new Error("--manifest and --gallery-dir are required");
  // Same rule as runner.ts: browsers run only in a VM or on CI, never on a developer laptop.
  if (process.env.CMUX_GALLERY_IN_VM !== "1") throw new Error("gallery health renders only on CI or a VM (CMUX_GALLERY_IN_VM=1)");
  const engines = values.engines.split(",").filter(Boolean) as Engine[];
  const allowlist = JSON.parse(await readFile(values.allowlist, "utf8")) as Record<string, string>;
  const budgets = readBudgets(values.budgets);
  const shiftBaseline = readShiftBaseline(values["shift-baseline"]);
  const undeclaredBaseline = readUndeclaredBaseline(values["undeclared-baseline"]);
  const invariantBaseline = readInvariantBaseline(values["invariant-baseline"]);
  const all = parseManifest(JSON.parse(await readFile(values.manifest, "utf8")));
  if (values["shard-by"] !== "state" && values["shard-by"] !== "index") throw new Error("--shard-by is state or index");
  const cases = (values["shard-by"] === "index" ? shardCases : shardStates)(all, Number(values["shard-count"]), Number(values["shard-index"]));
  const outputDir = resolve(values["output-dir"]);
  await mkdir(outputDir, { recursive: true });
  const concurrency = Number(values.concurrency);
  if (!Number.isInteger(concurrency) || concurrency < 1) throw new Error("--concurrency must be a positive integer");
  const run = (manifest: string, attempt: number) =>
    runLocal({ manifest, galleryDir: values["gallery-dir"]!, outputDir: join(outputDir, `attempt-${attempt}`), threshold: 0, engines, shardCount: 1, shardIndex: 0, concurrency: attempt === 0 ? concurrency : 1 });

  const shard = join(outputDir, "shard.json");
  await writeFile(shard, JSON.stringify(cases));
  let results: HealthResult[];
  try {
    results = (await run(shard, 0)) as HealthResult[];
  } catch (error) {
    // The matrix itself could not run (browser launch, manifest): say so in the verdict file too.
    const message = `gallery health could not render: ${error instanceof Error ? error.message : String(error)}`;
    await writeFile(join(outputDir, "health.json"), `${JSON.stringify({ error: message }, null, 2)}\n`);
    throw new Error(message);
  }
  let broken = brokenStates(results);
  const timings = [readyTimes(results)];
  const slowStates = () => new Set(overBudget(fastest(timings), budgets).map(({ state }) => state));
  let slow = slowStates();
  const shiftRuns = [shiftScores(results)];
  const shiftingStates = () =>
    new Set(
      [...least(shiftRuns)]
        .filter(([state, { score }]) => state in shiftBaseline.states && score > shiftLimit(shiftBaseline.states[state]!))
        .map(([state]) => state),
    );
  let shifting = shiftingStates();
  const undeclaredRuns = [undeclaredCounts(results as UndeclaredResult[])];
  const movingStates = () => new Set(judgeUndeclared(leastCount(undeclaredRuns), undeclaredBaseline).moved.map(({ state }) => state));
  let moving = movingStates();
  const invariantRuns = [invariantsOf(results)];
  const breakingStates = () =>
    new Set(judgeInvariants(everyRun(invariantRuns), invariantBaseline).broke.map(({ state }) => state));
  let breaking = breakingStates();
  for (
    let attempt = 1;
    attempt <= Number(values.retries) && (broken.size || slow.size || shifting.size || breaking.size || moving.size);
    attempt++
  ) {
    // Render again only the cases of states still broken, slow or shifting; a state stays broken
    // only if it breaks again, slow only if it is slow again, and shifting only if it shifts again.
    const retried = new Set([...broken.keys(), ...slow, ...shifting, ...breaking, ...moving]);
    const again: MatrixCase[] = cases.filter((item) => retried.has(stateKey(item)));
    const manifest = join(outputDir, `retry-${attempt}.json`);
    await writeFile(manifest, JSON.stringify(again));
    results = (await run(manifest, attempt)) as HealthResult[];
    const still = brokenStates(results);
    broken = new Map([...broken].filter(([state]) => still.has(state)));
    timings.push(readyTimes(results));
    slow = slowStates();
    shiftRuns.push(shiftScores(results));
    shifting = shiftingStates();
    undeclaredRuns.push(undeclaredCounts(results as UndeclaredResult[]));
    moving = movingStates();
    invariantRuns.push(invariantsOf(results));
    breaking = breakingStates();
  }
  // runLocal sets a failing exit code for quality findings; this check judges only broken states.
  process.exitCode = 0;
  const verdict = judge(cases.map(stateKey), broken, allowlist);
  // A broken state answers to the allowlist, not to its budget.
  const best = new Map([...fastest(timings)].filter(([state]) => !broken.has(state)));
  const over = overBudget(best, budgets);
  const lower = lowerable(best, budgets);
  // A broken state answers to the allowlist, not to its shift baseline.
  const shift = judgeShift(new Map([...least(shiftRuns)].filter(([state]) => !broken.has(state))), shiftBaseline);
  const undeclared = judgeUndeclared(new Map([...leastCount(undeclaredRuns)].filter(([state]) => !broken.has(state))), undeclaredBaseline);
  const geometry = judgeInvariants(
    new Map([...everyRun(invariantRuns)].filter(([state]) => !broken.has(state))),
    invariantBaseline,
  );
  const text = [summary(verdict, cases.length), budgetSummary(over, lower), shiftSummary(shift), undeclaredSummary(undeclared), invariantSummary(geometry)]
    .filter(Boolean)
    .join("\n");
  await writeFile(
    join(outputDir, "health.json"),
    `${JSON.stringify({ ...verdict, slow: over, lower, shifted: shift.shifted, unbaselined: shift.unbaselined, shiftLower: shift.lower, undeclared: undeclared.moved, undeclaredLower: undeclared.lower, geometry: geometry.broke, geometryUnlisted: geometry.unlisted, geometryMended: geometry.mended }, null, 2)}\n`,
  );
  console.log(text);
  if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${text}\n`);
  if (verdict.fresh.length || over.length || shift.shifted.length || undeclared.moved.length || geometry.broke.length) process.exitCode = 1;
}

if (import.meta.main) await main();
