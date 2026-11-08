// The report send-stream-motion.test.ts prints and checks: what each frame of a scripted turn moved
// the transcript, per 120 Hz slot, from the frames browser/send-stream-motion.harness.tsx sampled
// and the pacing support/frames120.ts measured.
import type { Sample } from "../browser/send-stream-motion.harness";
import { FRAME_MS } from "./frames120";

const pct = (values: number[], p: number) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))]! : 0;
};
const r2 = (value: number) => Math.round(value * 100) / 100;

export type MotionReport = ReturnType<typeof analyze>;

/// A move of more than this in one 120 Hz frame reads as a jump: a third of a line.
const JUMP_PX = 7.5;
/// `trailPx`: the follow motion's trail bound (followChase.ts CHASE_MAX_TRAIL_LINES); `linePx`: a
/// line, the most a frame may move.
export function analyze(samples: Sample[], frameMs: number[], dropped: number, trailPx: number, linePx: number) {
  // A frame's move per 120 Hz slot: a frame drawn after one or more dropped slots shows the motion
  // of all of them, as a display does. A move the follow motion took no part in (its translate the
  // same) is one at once and counts whole however late.
  const moves = samples.slice(1).map((sample, index) => {
    const before = samples[index]!;
    const moved = Math.abs(sample.top - before.top);
    const slots = Math.max(1, Math.round((sample.t - before.t) / FRAME_MS));
    const atOnce = Math.abs(sample.lag - before.lag) < 0.01;
    const px = atOnce ? moved : moved / slots;
    return { phase: sample.phase, px, atOnce: atOnce && moved > 0.5 };
  });
  // Each stretch the thread was drawn past the trail bound: from the first frame past it to the
  // first frame back within it (ms).
  const overBound: { ms: number; frames: number }[] = [];
  let since: { t: number; index: number } | undefined;
  samples.forEach((sample, index) => {
    const past = Math.abs(sample.lag) > trailPx + 0.5;
    if (past && since === undefined) since = { t: sample.t, index };
    if (!past && since !== undefined) {
      overBound.push({ ms: sample.t - since.t, frames: index - since.index });
      since = undefined;
    }
  });
  if (since !== undefined) overBound.push({ ms: Number.POSITIVE_INFINITY, frames: Number.POSITIVE_INFINITY });
  const of = (phase: string) => moves.filter((move) => move.phase === phase).map((move) => move.px);
  /// Per step of the turn: the largest move in a frame, the frames over JUMP_PX and their largest,
  /// and the moves at once (the follow motion took no part) with their largest.
  const byPhase: Record<string, { maxPx: number; jumps: number; atOnce: number; atOnceMaxPx: number }> = {};
  for (const move of moves) {
    const entry = (byPhase[move.phase] ??= { maxPx: 0, jumps: 0, atOnce: 0, atOnceMaxPx: 0 });
    entry.maxPx = r2(Math.max(entry.maxPx, move.px));
    if (move.px > JUMP_PX) entry.jumps += 1;
    if (move.atOnce) {
      entry.atOnce += 1;
      entry.atOnceMaxPx = r2(Math.max(entry.atOnceMaxPx, move.px));
    }
  }
  const all = moves.map((move) => move.px);
  const streamed = moves.filter((move) => move.phase === "stream" || move.phase === "segment").map((move) => move.px);
  // The stream's last growth, then the first frame from which the view rests at its end for good.
  let grew = 0;
  for (let index = 1; index < samples.length; index += 1)
    if (samples[index]!.length !== samples[index - 1]!.length) grew = index;
  // Where the followed view rests from the scroller's end (the room over the composer), as it lay
  // just before the turn's first words.
  let rest = samples.length;
  for (let index = samples.length - 1; index >= grew; index -= 1) {
    const sample = samples[index]!;
    if (Math.abs(sample.lag) > 0.01 || (index > 0 && Math.abs(sample.top - samples[index - 1]!.top) > 0.01)) break;
    rest = index;
  }
  const streaming = samples.filter((sample) => sample.phase === "stream" || sample.phase === "segment");
  const lags = streaming.map((sample) => sample.lag);
  return {
    frames: samples.length,
    dropped,
    frameMs: { p50: r2(pct(frameMs, 0.5)), p95: r2(pct(frameMs, 0.95)), max: r2(Math.max(0, ...frameMs)) },
    overBudget: frameMs.filter((ms) => ms > FRAME_MS).length,
    jumpPx: {
      send: r2(Math.max(0, ...of("send"), ...of("steer"))),
      stream: r2(Math.max(0, ...streamed)),
      streamP95: r2(
        pct(
          streamed.filter((px) => px > 0.01),
          0.95,
        ),
      ),
      after: r2(Math.max(0, ...of("after"))),
      max: r2(Math.max(0, ...all)),
    },
    /// Frames that moved the thread more than JUMP_PX, and moves at once of more than half a pixel.
    jumps: all.filter((px) => px > JUMP_PX).length,
    atOnce: moves.filter((move) => move.atOnce).length,
    byPhase,
    lagPx: { p50: r2(pct(lags, 0.5)), p95: r2(pct(lags, 0.95)), max: r2(Math.max(0, ...lags)) },
    /// The most the thread was drawn from its layout in any frame of the turn, any phase.
    trailMaxPx: r2(Math.max(0, ...samples.map((sample) => Math.abs(sample.lag)))),
    /// Frames moving more than a line, and the stretches past the trail bound: how many, the
    /// longest in drawn frames (from the first frame past it to the first frame back) and in ms.
    overLine: all.filter((px) => px > linePx + 0.01).length,
    overBound: {
      stretches: overBound.length,
      maxFrames: Math.max(0, ...overBound.map((stretch) => stretch.frames)),
      maxMs: r2(Math.max(0, ...overBound.map((stretch) => stretch.ms))),
    },
    /// Frames from the reply's last growth until nothing moves and the thread rests on its layout.
    restFramesAfterStream: rest - grew,
    restsAtEnd: rest < samples.length,
    /// Once the turn is over the reply's newest line ends over the composer, in view: how far over.
    tailAtEnd: r2(samples.at(-1)?.tail ?? Number.NaN),
  };
}
