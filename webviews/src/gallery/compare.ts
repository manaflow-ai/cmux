// The compare view's URL state (view `compare`): which arms of the entry's experiment show, how
// they are laid out, the replay speed, loop, the enlarged cell, the picked arm and the scripted
// step the cells rest at. With the gallery controls (env.ts) it is the whole view, so a copied
// link gives another person (or an agent) the exact view, and `compareSummary` says it in words.
//
// Keys (defaults are left out of the URL): arms=a,c,e (default: every arm), grid=auto|row|1|2|3,
// speed=0.1|0.25|0.5|1, loop=1, focus=<arm>, pick=<arm>, step=<0..steps>.
import { armIds, type Experiment } from "../experiments/experiment";
import type { GalleryExperiment } from "./format";

export const COMPARE_SPEEDS = [0.1, 0.25, 0.5, 1] as const;
export const COMPARE_GRIDS = ["auto", "row", "1", "2", "3"] as const;
export type CompareGrid = (typeof COMPARE_GRIDS)[number];

export type CompareState = {
  /** The arms shown, in URL order; empty is every arm. */
  arms: string[];
  grid: CompareGrid;
  /** Playback rate of every animation in the cells (1 is real time). */
  speed: number;
  loop: boolean;
  /** The enlarged cell's arm. */
  focus: string;
  /** The arm the viewer picked. */
  pick: string;
  /** The cells show the state after this many script steps (0: the setup state). */
  step: number;
};

export const DEFAULT_COMPARE: CompareState = {
  arms: [],
  grid: "auto",
  speed: 1,
  loop: false,
  focus: "",
  pick: "",
  step: 0,
};

const ARM = /^[a-z0-9]+(-[a-z0-9]+)*$/;

/** The compare keys a query names; anything missing or invalid keeps its default. */
export function readCompare(params: URLSearchParams): CompareState {
  const state: CompareState = { ...DEFAULT_COMPARE, arms: [] };
  const arms = (params.get("arms") ?? "").split(",").filter((arm) => ARM.test(arm));
  state.arms = [...new Set(arms)];
  const grid = params.get("grid");
  if ((COMPARE_GRIDS as readonly string[]).includes(grid ?? "")) state.grid = grid as CompareGrid;
  const speed = Number(params.get("speed"));
  if ((COMPARE_SPEEDS as readonly number[]).includes(speed)) state.speed = speed;
  state.loop = params.get("loop") === "1";
  for (const key of ["focus", "pick"] as const) {
    const value = params.get(key) ?? "";
    if (ARM.test(value)) state[key] = value;
  }
  const step = Number(params.get("step"));
  if (Number.isInteger(step) && step > 0 && step <= 50) state.step = step;
  return state;
}

/** Writes the compare keys into `params`, without the defaults. */
export function writeCompare(state: CompareState, params = new URLSearchParams()): URLSearchParams {
  for (const key of ["arms", "grid", "speed", "loop", "focus", "pick", "step"]) params.delete(key);
  if (state.arms.length) params.set("arms", state.arms.join(","));
  if (state.grid !== DEFAULT_COMPARE.grid) params.set("grid", state.grid);
  if (state.speed !== DEFAULT_COMPARE.speed) params.set("speed", String(state.speed));
  if (state.loop) params.set("loop", "1");
  if (state.focus) params.set("focus", state.focus);
  if (state.pick) params.set("pick", state.pick);
  if (state.step) params.set("step", String(state.step));
  return params;
}

/** The arms the view shows: the URL's that exist, in its order, else every arm. */
export function visibleArms(experiment: Experiment, state: CompareState): string[] {
  const all = armIds(experiment);
  const named = state.arms.filter((arm) => all.includes(arm));
  return named.length ? named : all;
}

/** The step the cells rest at, within the script. */
export const clampStep = (experiment: GalleryExperiment, step: number) =>
  Math.max(0, Math.min(step, experiment.script.length));

/** One line that says what the URL shows, for a chat message beside the link. */
export function compareSummary(
  entryId: string,
  variant: string,
  experiment: GalleryExperiment,
  state: CompareState,
  extra: { theme?: string; locale?: string; reducedMotion?: boolean } = {},
): string {
  const { definition } = experiment;
  const arms = visibleArms(definition, state);
  const step = clampStep(experiment, state.step);
  const parts = [
    `experiment ${definition.id}`,
    `entry ${entryId}/${variant}`,
    `arms ${arms.join(",")}`,
    `speed ${state.speed}x`,
    step ? `step ${step} of ${experiment.script.length} (${experiment.script[step - 1]!.name})` : "step 0 (start)",
  ];
  if (state.loop) parts.push("loop");
  if (state.focus && arms.includes(state.focus)) parts.push(`enlarged ${state.focus}`);
  if (extra.theme) parts.push(`theme ${extra.theme}`);
  if (extra.locale && extra.locale !== "en") parts.push(`locale ${extra.locale}`);
  if (extra.reducedMotion) parts.push("reduced motion");
  parts.push(state.pick ? `picked ${state.pick}` : "no pick");
  return parts.join(", ");
}

/** Frame-to-shell messages of a compare cell (frame/experimentRunner.ts). */
export type CompareFrameEvent =
  | { type: "cmux-exp"; event: "ready"; steps: number }
  | { type: "cmux-exp"; event: "step-done"; index: number; stats: StepStats }
  | { type: "cmux-exp"; event: "error"; message: string };

/** Shell-to-frame message: run one script step at a speed. */
export type CompareFrameCommand = { type: "cmux-exp"; op: "step"; index: number; speed: number };

/** What a cell measured while a step ran (in the viewer's own browser). */
export type StepStats = {
  /** Wall time from the input to the last animation's end, in ms (at the cell's speed). */
  durationMs: number;
  frames: number;
  p50: number;
  p95: number;
  max: number;
  over16: number;
  /** Largest `cmux-motion:*` performance measure in the step (the arm's planning), in ms. */
  planMs: number;
};

/** Percentiles of frame intervals (ms). */
export function frameStats(intervals: readonly number[]): Pick<StepStats, "frames" | "p50" | "p95" | "max" | "over16"> {
  if (!intervals.length) return { frames: 0, p50: 0, p95: 0, max: 0, over16: 0 };
  const sorted = [...intervals].sort((a, b) => a - b);
  const at = (q: number) => sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]!;
  const round = (value: number) => Math.round(value * 10) / 10;
  return {
    frames: sorted.length,
    p50: round(at(0.5)),
    p95: round(at(0.95)),
    max: round(sorted[sorted.length - 1]!),
    over16: sorted.filter((ms) => ms > 16.7).length,
  };
}
