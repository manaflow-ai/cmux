// Measured verdicts on a feel trace (trace.ts): numbers, not screenshots. Pure: no browser, no page;
// feel-verdicts.test.ts checks each on made-up traces.
//
// - follow: during a drag, does the dragged edge stay where the hand grabbed it (1:1 from the grab
//   point), frame by frame, with no jump, and stay put when the hand lets go?
// - still: does a click that is not a drag leave every box and state as it was?
// - flips: how many times a state changed (a detent crossed back and forth: hysteresis).
// - snap: did a value land on one of its detents?
// - churn: how often a live text swaps its words and its width, per second.
// - continuity: does an animation move once, one way, with no frame that pops?
import { edgeOf, pointerOn, type Box, type Edge, type FeelFrame, type FeelTrace } from "./trace";

/** One verdict: what was measured, against what limit. */
export type Verdict = { check: string; pass: boolean; measured: string; limit: string };

const round = (value: number) => Math.round(value * 10) / 10;
/** A measured number at the precision its limit needs: a layout shift of 0.013 against 0.01 reads 0.013,
 *  never "0". */
const shown = (value: number, limit: number) =>
  Math.abs(limit) > 0 && Math.abs(limit) < 1 ? Number(value.toPrecision(2)) : round(value);

function percentile(values: number[], p: number): number {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))]!;
}

export type FollowOptions = {
  /** The tracked box whose edge the hand drags. */
  box: string;
  edge: Edge;
  /** The most the hand may move before the control starts to follow (its drag slop). Within it the
   *  edge may rest or already follow; past it, it must be where 1:1 puts it, with no catch-up jump. */
  slop?: number;
  /** The edge's travel limits (page px), where it may stop while the hand goes on. Unknown: the
   *  edge's own extremes in the trace. */
  bounds?: [number, number];
  /** Snap-along rests the control may settle on (page px, in the edge's own axis), and how close to one
   *  the hand must be for it to settle there. A frame counts as on the hand when it is 1:1 from the
   *  grab point or resting on the rest that 1:1 is within `within` of, so a control that snaps along its
   *  lines and one that follows exactly both pass; anything else is off the hand. */
  detents?: { at: number[]; within: number };
};

export type FollowReport = {
  /** Frames with the button held. */
  frames: number;
  /** Whether the edge's last position after release is on one of `detents` (within 1 px). */
  releaseLanded: boolean;
  /** The edge's offset from the pointer at the grab. */
  grabOffset: number;
  /** The largest distance (px) between the edge and where 1:1 from the grab point puts it, allowing
   *  one frame of lag (the pointer of the frame before). */
  maxError: number;
  p95Error: number;
  /** Frames where the edge lagged the pointer by more than 2 px but matched the frame before. */
  lagFrames: number;
  /** Frames where the edge moved more than `jumpPx` beyond what the hand moved. */
  jumps: { t: number; by: number }[];
  /** How far the edge moved after the hand let go (it should stay where it was let go, or move once
   *  to a detent). */
  releaseMove: number;
  /** Edge travel over the hand's travel along the axis (1: it went everywhere the hand did). */
  coverage: number;
};

const clamp = (value: number, [lo, hi]: [number, number]) => Math.min(Math.max(value, lo), hi);

/** How the dragged edge followed the pointer. */
export function follow(trace: FeelTrace, options: FollowOptions, jumpPx = 4): FollowReport {
  const { box, edge, slop = 0 } = options;
  const down = trace.events.find((event) => event.type === "pointerdown");
  const up = trace.events.find((event) => event.type === "pointerup" && (!down || event.t > down.t));
  const at = (frame: FeelFrame) => (frame.boxes[box] ? edgeOf(frame.boxes[box]!, edge) : undefined);
  const empty: FollowReport = {
    frames: 0,
    grabOffset: 0,
    maxError: 0,
    p95Error: 0,
    lagFrames: 0,
    jumps: [],
    releaseMove: 0,
    releaseLanded: false,
    coverage: 0,
  };
  if (!down) return empty;
  const p0 = edge === "top" || edge === "bottom" ? down.y : down.x;
  const before = [...trace.frames].reverse().find((frame) => frame.t <= down.t && at(frame) !== undefined);
  const e0 = before ? at(before)! : undefined;
  if (e0 === undefined) return empty;
  const held = trace.frames.filter(
    (frame) => frame.t > down.t && (!up || frame.t <= up.t) && frame.pointer && at(frame) !== undefined,
  );
  const seen = held.map((frame) => at(frame)!);
  const bounds = options.bounds ?? [Math.min(e0, ...seen), Math.max(e0, ...seen)];
  const wanted = (pointer: number) => clamp(e0 + pointer - p0, bounds);
  /** Within the slop the edge may still rest where it was grabbed. */
  const resting = (ask: number) => Math.abs(ask - e0) < slop;
  /** Where a snap-along control rests for an ask: the detent within reach of it, else the ask. */
  const rested = (ask: number) => {
    const near = options.detents?.at.find((at) => Math.abs(at - ask) <= options.detents!.within);
    return near ?? ask;
  };
  /** How far `edge` is from an ask, as 1:1 or as a snap-along rest, whichever is nearer. */
  const off = (edgeAt: number, ask: number) =>
    Math.min(Math.abs(edgeAt - ask), Math.abs(edgeAt - rested(ask)), resting(ask) ? Math.abs(edgeAt - e0) : Infinity);
  const errors: number[] = [];
  const jumps: FollowReport["jumps"] = [];
  let lagFrames = 0;
  let previousPointer = p0;
  let previousEdge = e0;
  let previousWanted = wanted(p0);
  for (const [i, frame] of held.entries()) {
    const pointer = pointerOn(frame.pointer!, edge);
    const now = wanted(pointer);
    const lagged = wanted(previousPointer);
    const edgeNow = seen[i]!;
    const error = Math.min(off(edgeNow, now), off(edgeNow, lagged));
    if (off(edgeNow, now) > 2 && off(edgeNow, lagged) <= 2) lagFrames++;
    errors.push(error);
    // A jump: the edge moved further in one frame than the hand asked of it, by more than jumpPx
    // (a frame of lag forgiven: the edge may land this frame on last frame's ask).
    const by = Math.min(
      Math.abs(edgeNow - previousEdge - (now - previousWanted)),
      Math.abs(edgeNow - previousEdge - (rested(now) - rested(previousWanted))),
      off(edgeNow, lagged),
      // Leaving the slop, a control that rested catches up to the hand: that is the slop, not a jump.
      resting(previousWanted) ? off(edgeNow, now) : Infinity,
    );
    if (by > jumpPx) jumps.push({ t: frame.t, by: round(by) });
    previousPointer = pointer;
    previousEdge = edgeNow;
    previousWanted = now;
  }
  const after = up ? trace.frames.filter((frame) => frame.t > up.t && at(frame) !== undefined) : [];
  const released = held.length > 0 ? seen[seen.length - 1]! : e0;
  const releaseMove = after.reduce((most, frame) => Math.max(most, Math.abs(at(frame)! - released)), 0);
  const last = after.length > 0 ? at(after[after.length - 1]!)! : released;
  const releaseLanded = (options.detents?.at ?? []).some((at) => Math.abs(at - last) <= 1);
  const pointers = held.map((frame) => pointerOn(frame.pointer!, edge));
  const handTravel = travel([p0, ...pointers]);
  return {
    frames: held.length,
    grabOffset: round(e0 - p0),
    maxError: round(Math.max(0, ...errors)),
    p95Error: round(percentile(errors, 95)),
    lagFrames,
    jumps,
    releaseMove: round(releaseMove),
    releaseLanded,
    coverage: handTravel === 0 ? 1 : round(travel([e0, ...seen]) / handTravel),
  };
}

/** The total distance a sequence of positions covers. */
export function travel(values: number[]): number {
  let total = 0;
  for (let i = 1; i < values.length; i++) total += Math.abs(values[i]! - values[i - 1]!);
  return total;
}

export type StillReport = {
  /** Each box's largest move (any side, px) from its first frame. */
  moved: Record<string, number>;
  /** Each state's values in order, once per change. */
  changed: Record<string, (string | null)[]>;
  shift: number;
};

/** What moved and changed over the trace (for a gesture that should change nothing). */
export function still(trace: FeelTrace): StillReport {
  const moved: Record<string, number> = {};
  const changed: Record<string, (string | null)[]> = {};
  const first = trace.frames[0];
  if (!first) return { moved, changed, shift: 0 };
  const sides = (box: Box | null) => (box ? [box.x, box.y, box.x + box.w, box.y + box.h] : undefined);
  for (const name of Object.keys(first.boxes)) {
    const start = sides(first.boxes[name]!);
    let most = 0;
    for (const frame of trace.frames) {
      const now = sides(frame.boxes[name]!);
      if (!start || !now) {
        if (!start !== !now) most = Infinity;
        continue;
      }
      for (let i = 0; i < 4; i++) most = Math.max(most, Math.abs(now[i]! - start[i]!));
    }
    moved[name] = round(most);
  }
  for (const name of Object.keys(first.states)) changed[name] = values(trace, name);
  return { moved, changed, shift: trace.frames.reduce((sum, frame) => sum + frame.shift, 0) };
}

/** A state's values over the trace, once per change. */
export function values(trace: FeelTrace, state: string): (string | null)[] {
  const out: (string | null)[] = [];
  for (const frame of trace.frames) {
    const value = frame.states[state] ?? null;
    if (out.length === 0 || out[out.length - 1] !== value) out.push(value);
  }
  return out;
}

/** How many times a state changed. */
export function flips(trace: FeelTrace, state: string): number {
  return Math.max(0, values(trace, state).length - 1);
}

/** How far `value` is from its nearest detent. */
export function snapDistance(value: number, detents: number[]): number {
  return round(Math.min(...detents.map((detent) => Math.abs(value - detent))));
}

export type ChurnReport = {
  seconds: number;
  /** Times the words changed, and per second. */
  swaps: number;
  swapsPerSecond: number;
  /** Frames the drawn width changed by more than half a px, per second, and how far it went in all. */
  widthChangesPerSecond: number;
  widthTravelPerSecond: number;
  /** The largest width change in one frame. */
  maxWidthStep: number;
  distinct: number;
  /** The shortest time (ms) a text stayed up between two swaps: how long a reader gets with a line
   *  (Infinity with under two swaps). */
  shortestHold: number;
  /** The first 24 swaps: when, and to what (for the report and a person reading it). */
  timeline: { t: number; text: string | null }[];
};

/** How a live text churns. */
export function churn(trace: FeelTrace, text: string): ChurnReport {
  const samples = trace.frames.map((frame) => ({ t: frame.t, sample: frame.texts[text] ?? null }));
  const span = samples.length > 1 ? (samples[samples.length - 1]!.t - samples[0]!.t) / 1000 : 0;
  let swaps = 0;
  let widthChanges = 0;
  let widthTravel = 0;
  let maxWidthStep = 0;
  const distinct = new Set<string>();
  let lastSwap: number | undefined;
  let shortestHold = Number.POSITIVE_INFINITY;
  const timeline: ChurnReport["timeline"] = [];
  for (let i = 0; i < samples.length; i++) {
    const now = samples[i]!.sample;
    if (now) distinct.add(now.text);
    if (i === 0) continue;
    const was = samples[i - 1]!.sample;
    if ((was?.text ?? null) !== (now?.text ?? null)) {
      swaps++;
      if (lastSwap !== undefined) shortestHold = Math.min(shortestHold, samples[i]!.t - lastSwap);
      lastSwap = samples[i]!.t;
      if (timeline.length < 24) timeline.push({ t: round(samples[i]!.t - samples[0]!.t), text: now?.text ?? null });
    }
    const step = Math.abs((now?.width ?? 0) - (was?.width ?? 0));
    if (step > 0.5) widthChanges++;
    widthTravel += step;
    maxWidthStep = Math.max(maxWidthStep, step);
  }
  const per = (count: number) => (span > 0 ? round(count / span) : 0);
  return {
    seconds: round(span),
    swaps,
    swapsPerSecond: per(swaps),
    widthChangesPerSecond: per(widthChanges),
    widthTravelPerSecond: per(widthTravel),
    maxWidthStep: round(maxWidthStep),
    distinct: distinct.size,
    shortestHold: round(shortestHold),
    timeline,
  };
}

export type ContinuityReport = {
  /** Separate runs of motion (a run ends after `restFrames` still frames): 1 is one movement. */
  moves: number;
  /** Times the motion turned back. */
  reversals: number;
  /** The largest step in one frame, and its share of the whole travel. */
  maxStep: number;
  maxStepShare: number;
  travel: number;
};

/** How an edge moved over the trace, as one animation should: once, one way, no pop. */
export function continuity(trace: FeelTrace, box: string, edge: Edge, restFrames = 3): ContinuityReport {
  const positions = trace.frames
    .map((frame) => (frame.boxes[box] ? edgeOf(frame.boxes[box]!, edge) : undefined))
    .filter((value): value is number => value !== undefined);
  let moves = 0;
  let reversals = 0;
  let maxStep = 0;
  let stillFor = Infinity;
  let direction = 0;
  for (let i = 1; i < positions.length; i++) {
    const step = positions[i]! - positions[i - 1]!;
    if (Math.abs(step) <= 0.5) {
      stillFor++;
      continue;
    }
    if (stillFor >= restFrames) {
      moves++;
      direction = 0;
    }
    stillFor = 0;
    const sign = Math.sign(step);
    if (direction !== 0 && sign !== direction) reversals++;
    direction = sign;
    maxStep = Math.max(maxStep, Math.abs(step));
  }
  const total = travel(positions);
  return {
    moves,
    reversals,
    maxStep: round(maxStep),
    maxStepShare: total === 0 ? 0 : round(maxStep / total),
    travel: round(total),
  };
}

/** Collects verdicts for one component's report. */
export class Verdicts {
  readonly list: Verdict[] = [];
  /** The checks known red on this base (stage.ts `known` with `checks`): expectPass lets these fail. */
  known: readonly string[] = [];
  /** Records `measured <= limit`. */
  atMost(check: string, measured: number, limit: number, unit = "") {
    this.list.push({
      check,
      pass: measured <= limit,
      measured: `${shown(measured, limit)}${unit}`,
      limit: `≤ ${limit}${unit}`,
    });
  }
  /** Records `measured >= limit`. */
  atLeast(check: string, measured: number, limit: number, unit = "") {
    this.list.push({
      check,
      pass: measured >= limit,
      measured: `${shown(measured, limit)}${unit}`,
      limit: `≥ ${limit}${unit}`,
    });
  }
  /** Records `measured === expected`. */
  equals(check: string, measured: unknown, expected: unknown) {
    const a = JSON.stringify(measured);
    const b = JSON.stringify(expected);
    this.list.push({ check, pass: a === b, measured: a, limit: `= ${b}` });
  }
  get failed(): Verdict[] {
    return this.list.filter((verdict) => !verdict.pass);
  }
}
