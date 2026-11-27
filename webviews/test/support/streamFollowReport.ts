// The report stream-follow-smooth.test.ts prints for each follow-motion arm (Leo, 2026-11-22: "the
// animation or whatever for when im at the bottom and the text is streaming to be a bit jarring ...
// it's just not great design to have the jolts. esp in tandem with how aggressively we're folding
// claude code chats. it's not smooth."). From the frames browser/send-stream-motion.harness.tsx
// sampled, one per display frame: how often and how far the scroll offset and the text the reader
// reads (the newest reply row, where it paints) jump from one frame to the next.
import type { Sample } from "../browser/send-stream-motion.harness";

/// A frame-to-frame move past this reads as a jolt at 60 Hz: half a line (22.75 px at the chat font),
/// 680 px/s, past any speed a reader follows text at.
export const JOLT_PX = 11.5;

const r2 = (value: number) => Math.round(value * 100) / 100;
const pct = (values: number[], p: number) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))]! : 0;
};

export type Moves = {
  /// Frames that moved past the threshold, per second of the run.
  joltsPerS: number;
  /// The most one frame moved, px.
  maxPx: number;
  /// 95 in 100 moving frames moved no more than this, px.
  p95Px: number;
  /// How much the per-frame move changed from one frame to the next (a speed change), p95, px: a
  /// steady drift reads near 0, a surge per chunk high.
  jerkP95Px: number;
};

/// `deltas`: each frame's move (px, signed); `seconds`: the run's length.
export function moves(deltas: number[], seconds: number, threshold = JOLT_PX): Moves {
  const moving = deltas.filter((delta) => Math.abs(delta) > 0.25).map(Math.abs);
  const jerks = deltas.slice(1).map((delta, index) => Math.abs(delta - deltas[index]!));
  return {
    joltsPerS: r2(seconds > 0 ? deltas.filter((delta) => Math.abs(delta) > threshold).length / seconds : 0),
    maxPx: r2(Math.max(0, ...deltas.map(Math.abs))),
    p95Px: r2(pct(moving, 0.95)),
    jerkP95Px: r2(
      pct(
        jerks.filter((jerk) => jerk > 0.25),
        0.95,
      ),
    ),
  };
}

export type StreamFollowReport = ReturnType<typeof streamFollowReport>;

/// The frames from the turn's first step to the end of its settle window. `scroll`: the scroll offset
/// frame to frame. `reader`: the newest reply row's top where it paints (its scroll, the follow
/// motion's translate and any fold above it), between frames that drew the same row. `byPhase`: the
/// reader's largest move in each step. `tail`: where the newest line ends over the composer (px,
/// negative under it), p5 and p95: how far the text the reader reads wanders.
export function streamFollowReport(samples: Sample[], threshold = JOLT_PX) {
  const run = samples.filter((sample) => sample.phase !== "idle");
  const seconds = run.length > 1 ? (run.at(-1)!.t - run[0]!.t) / 1000 : 0;
  const scroll: number[] = [];
  const reader: number[] = [];
  const byPhase: Record<string, number> = {};
  for (let index = 1; index < run.length; index += 1) {
    const before = run[index - 1]!;
    const after = run[index]!;
    scroll.push(after.scrollTop - before.scrollTop);
    // A new reply row is new text, not a move: the reader's eye goes to it.
    const move = before.reader && after.reader?.id === before.reader.id ? after.reader.top - before.reader.top : 0;
    reader.push(move);
    byPhase[after.phase] = r2(Math.max(byPhase[after.phase] ?? 0, Math.abs(move)));
  }
  const tails = run.map((sample) => sample.tail).filter(Number.isFinite);
  return {
    frames: run.length,
    seconds: r2(seconds),
    scroll: moves(scroll, seconds, threshold),
    reader: moves(reader, seconds, threshold),
    tail: { p5: r2(pct(tails, 0.05)), p95: r2(pct(tails, 0.95)) },
    byPhase,
  };
}
