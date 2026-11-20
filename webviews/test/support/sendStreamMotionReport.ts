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
/// The most any row in view in the first frame, and still mounted in the second, moved where it
/// paints, px; undefined when either frame has no row samples or no such row. A row that leaves the
/// view counts by how far it moved: a jump that carries a row out of view is a jump the reader saw
/// (review of #41470 F1: a row 48.6 px out of view read as no move while another stayed covered).
function paintedMove(before: Sample, after: Sample): number | undefined {
  if (!before.rows || !after.rows) return undefined;
  const was = new Map(before.rows.filter((row) => row.inView).map((row) => [row.id, row.top]));
  let most: number | undefined;
  for (const row of after.rows) {
    const top = was.get(row.id);
    if (top !== undefined) most = Math.max(most ?? 0, Math.abs(row.top - top));
  }
  return most;
}

/// One frame of the turn's end, row by row: the thread's own shift (its box, scroll and translate),
/// and for each row in view in the first frame and still mounted in the second (in view or not, as
/// `paintedMove`) that shift plus the row's own move in the thread's layout
/// plus the change of the translate on it (the fold's offset). The sum is where the row paints: if the
/// fold's offsets stop covering the thread's shift, it is the shift. `undefined` without row samples.
function netMove(before: Sample, after: Sample): { threadPx: number; netPx: number; offsetPx: number } | undefined {
  if (!before.rows || !after.rows) return undefined;
  const was = new Map(before.rows.filter((row) => row.inView).map((row) => [row.id, row]));
  const shift = after.top - before.top;
  let netPx: number | undefined;
  let offsetPx = 0;
  for (const row of after.rows) {
    const prior = was.get(row.id);
    if (!prior || row.layoutTop === undefined || prior.layoutTop === undefined) continue;
    const offset = (row.offset ?? 0) - (prior.offset ?? 0);
    offsetPx = Math.max(offsetPx, Math.abs(offset));
    netPx = Math.max(netPx ?? 0, Math.abs(shift + (row.layoutTop - prior.layoutTop) + offset));
  }
  return netPx === undefined ? undefined : { threadPx: Math.abs(shift), netPx, offsetPx };
}

/// `trailPx`: the follow motion's trail bound (followChase.ts CHASE_MAX_TRAIL_LINES); `linePx`: a
/// line, the most a frame may move.
export function analyze(samples: Sample[], frameMs: number[], dropped: number, trailPx: number, linePx: number) {
  // A frame's move per 120 Hz slot: a frame drawn after one or more dropped slots shows the motion
  // of all of them, as a display does. A move the follow motion took no part in (its translate the
  // same) is one at once and counts whole however late.
  const moves = samples.slice(1).map((sample, index) => {
    const before = samples[index]!;
    // The turn's end: the fold (turnEndFold.ts) slides each row from where it was drawn to its new
    // place, so the thread's own box can jump while no row on screen does (the tools turn: the
    // thread 48.57 px, every row in view under 0.5 px). There the move is where the rows paint: the
    // most any row in view before the frame and still mounted moved (`?rows=1`), out of view too. A
    // thread jump the rows take with them moves every row by it and counts whole.
    const painted = sample.phase === "end" ? paintedMove(before, sample) : undefined;
    const moved = painted ?? Math.abs(sample.top - before.top);
    const slots = Math.max(1, Math.round((sample.t - before.t) / FRAME_MS));
    const atOnce = Math.abs(sample.lag - before.lag) < 0.01;
    const px = atOnce ? moved : moved / slots;
    // A frame of a catch-up: the trail is past its bound in this frame or the one before (the block
    // that put it there landing, or the chase bringing it back at up to a line a frame).
    const past = (lag: number) => Math.abs(lag) > trailPx + 0.5;
    const catchUp = past(before.lag) || past(sample.lag);
    return { phase: sample.phase, px, atOnce: atOnce && moved > 0.5, catchUp };
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
  const streamMoves = moves.filter((move) => move.phase === "stream" || move.phase === "segment");
  const streamed = streamMoves.map((move) => move.px);
  /// The stream's frames outside a catch-up: how it moves while it follows within the trail bound.
  const calm = streamMoves.filter((move) => !move.catchUp).map((move) => move.px);
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
  // The turn's end, frame by frame (`?rows=1`): how far the thread's own box shifted at most, how far
  // a fold's offset on a row moved to cover it, and the most any row in view moved with both summed.
  const turnEnd = { frames: 0, threadPx: 0, offsetPx: 0, netPx: 0 };
  samples.forEach((sample, index) => {
    if (index === 0 || sample.phase !== "end") return;
    const before = samples[index - 1]!;
    const net = netMove(before, sample);
    if (!net) return;
    // Per 120 Hz slot, as a frame's move above: a frame after dropped slots shows all of them.
    const slots =
      Math.abs(sample.lag - before.lag) < 0.01 ? 1 : Math.max(1, Math.round((sample.t - before.t) / FRAME_MS));
    net.netPx /= slots;
    turnEnd.frames += 1;
    turnEnd.threadPx = r2(Math.max(turnEnd.threadPx, net.threadPx));
    turnEnd.offsetPx = r2(Math.max(turnEnd.offsetPx, net.offsetPx));
    turnEnd.netPx = r2(Math.max(turnEnd.netPx, net.netPx));
  });
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
      /// The 95th percentile of the stream's moving frames outside a catch-up (`streamP95` counts
      /// those too: how many blocks land past the bound, up to a line a frame each, more than how
      /// the stream moves between them).
      streamCalmP95: r2(
        pct(
          calm.filter((px) => px > 0.01),
          0.95,
        ),
      ),
      /// The stream's frames in a catch-up, of all its moving frames.
      catchUpFrames: streamMoves.filter((move) => move.catchUp && move.px > 0.01).length,
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
    /// The turn's end with row samples: the thread's largest shift in a frame, the fold's largest
    /// offset change on a row, and the most a row in view moved with the two summed (where it paints).
    turnEnd,
    /// Once the turn is over the reply's newest line ends over the composer, in view: how far over.
    tailAtEnd: r2(samples.at(-1)?.tail ?? Number.NaN),
  };
}
