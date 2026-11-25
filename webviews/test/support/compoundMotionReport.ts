// The motion map's numbers for one compound-motion run (compound-motion.test.ts): from the frame
// before the scenario's event, the row under the viewport's middle (the anchor) is followed frame by
// frame. Its moves split into phases: runs of moving frames (more than MOVING_PX in a frame), broken
// by a still frame or a turn of direction. One cohesive motion is one phase; Leo's "one-two" is two.
import type { Sample } from "../browser/compound-motion.harness";

/// A frame moves the anchor when it shifts it more than this, px.
export const MOVING_PX = 0.25;

export type Phase = { frames: number; direction: 1 | -1; medianPx: number; maxPx: number; px: number };
export type RunReport = {
  anchor: string;
  /// Frames in the window (the event's first frame to the window's end).
  frames: number;
  phases: Phase[];
  /// The anchor's net move over the window, px (positive: down).
  net: number;
  /// Every frame's move summed, px.
  travel: number;
  /// The largest move in one frame, px.
  maxJump: number;
  /// The frames from the event to the anchor's last move.
  settleFrames: number;
  /// The toggled call's line read open in the window (the fold cases' click landed).
  opened: boolean;
  /// The latest row's bottom against the viewport's bottom in the case's last frame, px (where it ends).
  endGap: number;
};

const median = (values: readonly number[]) => {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle]! : (sorted[middle - 1]! + sorted[middle]!) / 2;
};

const endGap = (sample: Sample) => {
  const last = [...sample.rows].sort((a, b) => b.top + b.height - (a.top + a.height))[0];
  return last ? sample.bottom - (last.top + last.height) : 0;
};

export function analyzeRun(samples: readonly Sample[], step: string, windowFrames: number): RunReport | undefined {
  const event = samples.findIndex((sample) => sample.phase === step);
  if (event < 1) return undefined;
  const before = samples[event - 1]!;
  const under =
    before.rows.find((row) => row.top <= before.middle && row.top + row.height >= before.middle) ??
    [...before.rows].sort((a, b) => Math.abs(a.top - before.middle) - Math.abs(b.top - before.middle))[0];
  if (!under) return undefined;
  const tops: number[] = [under.top];
  for (const sample of samples.slice(event, event + windowFrames))
    tops.push(sample.rows.find((row) => row.id === under.id)?.top ?? tops.at(-1)!);
  const deltas = tops.slice(1).map((top, index) => top - tops[index]!);
  const phases: Phase[] = [];
  let current: number[] = [];
  const close = () => {
    if (current.length === 0) return;
    const sizes = current.map(Math.abs);
    phases.push({
      frames: current.length,
      direction: current[0]! > 0 ? 1 : -1,
      medianPx: median(sizes),
      maxPx: Math.max(...sizes),
      px: current.reduce((sum, value) => sum + value, 0),
    });
    current = [];
  };
  let lastMove = -1;
  deltas.forEach((delta, index) => {
    if (Math.abs(delta) <= MOVING_PX) {
      close();
      return;
    }
    lastMove = index;
    if (current.length > 0 && Math.sign(current[0]!) !== Math.sign(delta)) close();
    current.push(delta);
  });
  close();
  return {
    anchor: under.id,
    frames: deltas.length,
    phases,
    net: tops.at(-1)! - tops[0]!,
    travel: deltas.reduce((sum, value) => sum + Math.abs(value), 0),
    maxJump: Math.max(0, ...deltas.map(Math.abs)),
    settleFrames: lastMove + 1,
    opened: samples.slice(event, event + windowFrames).some((sample) => sample.opened),
    endGap: endGap(samples.at(-1)!),
  };
}

export type CaseReport = {
  runs: number;
  /// Medians over the runs.
  phases: number;
  movingFrames: number;
  maxJump: number;
  net: number;
  travel: number;
  settleFrames: number;
  /// Every run's toggled line opened.
  opened: boolean;
  endGap: number;
  /// The median run's phases, for the map ("frames x median px/frame").
  shape: string;
};

export function summarize(runs: readonly RunReport[]): CaseReport {
  const pick = (read: (run: RunReport) => number) => median(runs.map(read));
  const phases = pick((run) => run.phases.length);
  const typical = runs.find((run) => run.phases.length === phases) ?? runs[0];
  return {
    runs: runs.length,
    phases,
    movingFrames: pick((run) => run.phases.reduce((sum, phase) => sum + phase.frames, 0)),
    maxJump: pick((run) => run.maxJump),
    net: pick((run) => run.net),
    travel: pick((run) => run.travel),
    settleFrames: pick((run) => run.settleFrames),
    opened: runs.every((run) => run.opened),
    endGap: pick((run) => run.endGap),
    shape:
      typical?.phases
        .map(
          (phase) =>
            `${phase.direction > 0 ? "v" : "^"}${phase.frames}f@${phase.medianPx.toFixed(1)}(max ${phase.maxPx.toFixed(1)})`,
        )
        .join(" ") || "still",
  };
}
