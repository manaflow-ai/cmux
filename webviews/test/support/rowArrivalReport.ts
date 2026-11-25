// The report row-arrival-settle.test.ts prints and checks: for a row that arrives in a running turn
// (conversation/scriptedTurn.ts ARRIVAL_TURNS), how long from the event to everything at rest, from
// the frames browser/send-stream-motion.harness.tsx sampled (`?rows=1`). Leo, 2026-11-09: "the tool
// call shifting the chat animation and stuff is just too slow ... thinking, tool calls, etc...
// cannot lag nor can they take long", and "the animations end to end need to just resolve faster".
//
// In the `arrive` step's frames (the view rested before it, and nothing else lands in it):
// - `firstMs`: from the event to the first frame anything drawn changed (a row, the thread's offset);
// - `moveMs`: from the event to the last frame a row or the thread moved (final layout as drawn);
// - `restMs`: from the event to the last frame anything changed or a finite animation ran (a move, a
//   fade, a glide): everything at rest;
// - `bursts`: separate stretches of motion (two or more idle frames between them): a motion chained
//   after another, or a settle step after the main move, makes more than one;
// - `worstPx`: the most a row in view moved in one frame;
// - `started`: animations started for the arrival (the work it costs), `mounted`: rows mounted.
import type { Sample } from "../browser/send-stream-motion.harness";

/// One 120 Hz frame, ms.
export const FRAME_MS = 1000 / 120;

export type ArrivalReport = {
  firstMs: number;
  moveMs: number;
  restMs: number;
  bursts: number;
  worstPx: number;
  started: number;
  mounted: number;
  frames: number;
};

const r1 = (value: number) => Math.round(value * 10) / 10;

/// The report for the frames of `step` (the `arrive` step by default); undefined when it never ran.
export function arrivalReport(samples: Sample[], step = "arrive"): ArrivalReport | undefined {
  const first = samples.findIndex((sample) => sample.phase === step);
  if (first < 1) return undefined;
  let end = first;
  while (end < samples.length && samples[end]!.phase === step) end += 1;
  const eventAt = samples[first]!.eventAt;
  let firstChange: number | undefined;
  let lastMove: number | undefined;
  let lastBusy: number | undefined;
  let bursts = 0;
  let idle = Number.POSITIVE_INFINITY;
  let worst = 0;
  for (let index = first; index < end; index += 1) {
    const before = samples[index - 1]!;
    const now = samples[index]!;
    const was = new Map((before.rows ?? []).map((row) => [row.id, row]));
    let moved = Math.abs(now.lag - before.lag) > 0.1 || Math.abs(now.top - before.top) > 0.5;
    let changed = moved;
    for (const row of now.rows ?? []) {
      const old = was.get(row.id);
      if (!old) {
        if (row.inView) changed = true;
        continue;
      }
      if (!old.inView && !row.inView) continue;
      const shift = Math.abs(row.top - old.top);
      if (shift > 0.5 || Math.abs(row.height - old.height) > 0.5) moved = changed = true;
      if (old.inView) worst = Math.max(worst, shift);
      if (Math.abs(row.opacity - old.opacity) > 0.01) changed = true;
    }
    const busy = changed || now.animations > 0;
    if (changed && firstChange === undefined) firstChange = index;
    if (moved) lastMove = index;
    if (busy) {
      if (idle >= 2) bursts += 1;
      idle = 0;
      lastBusy = index;
    } else idle += 1;
  }
  const at = (index: number | undefined) => (index === undefined ? 0 : r1(samples[index]!.t - eventAt));
  return {
    firstMs: at(firstChange),
    moveMs: at(lastMove),
    restMs: at(lastBusy),
    bursts,
    worstPx: r1(worst),
    started: samples[end - 1]!.started - samples[first - 1]!.started,
    mounted: (samples[first]!.rows ?? []).length,
    frames: end - first,
  };
}
