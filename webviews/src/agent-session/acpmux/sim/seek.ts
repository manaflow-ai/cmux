// Seek for the chat simulator (sim/README.md "Start at the interesting part"): where a recording of a
// scenario starts. The steps before the start are applied at once (the reducer and turn view see every
// record, so the state there is exact, not a fast-forward), and the rest keep their recorded spacing.
import type { SimStep } from "./script";

export type SeekOptions = {
  /** Start this many ms of virtual time after the first step. */
  startAtMs?: number;
  /** Start at the first event step whose record seq is this one or later (a replay's `--from`/`--to` seqs). */
  seekToSeq?: number;
  /** With `seekToSeq`: start this many ms before that step, so the change is seen coming. */
  leadMs?: number;
};

export type SeekPlan = {
  /** Steps `0..start-1` are applied at once; playback begins at step `start`. */
  start: number;
  /** The virtual time playback begins at (absolute, as the steps' `at`). */
  startAt: number;
  /** Before step `start + i`, wait `delays[i]` ms of virtual time (the first counted from `startAt`). */
  delays: number[];
};

/** Splits `steps` at the seek: the prefix to apply at once and the remaining schedule. With no seek the
 *  prefix is empty and the schedule is the steps' own spacing. */
export function seekPlan(steps: readonly SimStep[], options: SeekOptions = {}): SeekPlan {
  const first = steps[0]?.at ?? 0;
  let startAt = first;
  if (options.seekToSeq !== undefined) {
    const target = steps.find((step) => step.type === "event" && step.seq >= options.seekToSeq!);
    startAt = (target?.at ?? steps.at(-1)?.at ?? first) - Math.max(0, options.leadMs ?? 0);
  } else if (options.startAtMs !== undefined) {
    startAt = first + options.startAtMs;
  }
  startAt = Math.max(first, startAt);
  let start = steps.findIndex((step) => step.at >= startAt);
  if (start < 0) start = steps.length;
  const delays: number[] = [];
  let lastAt = startAt;
  for (let index = start; index < steps.length; index += 1) {
    delays.push(steps[index]!.at - lastAt);
    lastAt = steps[index]!.at;
  }
  return { start, startAt, delays };
}

/** Seek flags from a command line: `--start-at S`, or `--seek-to-event SEQ [--lead S]` (seconds). */
export function seekFromArgs(value: (name: string) => string | undefined): SeekOptions | undefined {
  const seconds = (name: string) => (value(name) === undefined ? undefined : Number(value(name)) * 1000);
  const startAtMs = seconds("--start-at");
  const seq = value("--seek-to-event");
  if (startAtMs === undefined && seq === undefined) return undefined;
  if (seq !== undefined) return { seekToSeq: Number(seq), leadMs: seconds("--lead") ?? 0 };
  return { startAtMs };
}
