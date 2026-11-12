// The parked-reader stillness test's reading of its painted frames (streaming-parked-still.test.ts),
// kept apart from the browser so its own check (streaming-parked-still-settle.test.ts) runs anywhere.

/// One painted frame: its time, the offset and how far it rests from the end, the view's edges, how
/// many wheel events the page had seen when it was read, whether the scroller's scroll had ended since
/// the last of them, how many of the app's wheel glides had started and whether one was still under
/// way, and the screen top of each row and reply block in view.
export type Sample = {
  t: number;
  top: number;
  fromEnd: number;
  wheels: number;
  ended: boolean;
  glides: number;
  gliding: boolean;
  /// The follow motion's translate on the thread, px: rows drawn off their layout by it.
  lag: number;
  view: [number, number];
  items: Record<string, number>;
};
/// An item that moved apart from the scroll, or vanished in view, between two painted frames.
type Event = { t: number; key: string; kind: "moved" | "vanished"; px?: number; scrolled: number };

/// How many painted frames the view must hold still after the reader's scroll ends before it counts
/// as parked (half a second at 60 Hz; the reply streams on for several seconds after the wheel).
export const PARKED_FRAMES = 30;

const round = (value: number) => Math.round(value * 100) / 100;

/// How far the picture scrolled from `before` to `now`, toward the end positive: the move most of
/// the items drawn in both frames share (the middle one), so one item moving on its own cannot pass
/// for the scroll. With no item in both, the offset less the follow motion's translate.
export function pictureScroll(before: Sample, now: Sample) {
  const moves = Object.keys(before.items)
    .filter((key) => key in now.items)
    .map((key) => before.items[key]! - now.items[key]!)
    .sort((a, b) => a - b);
  if (moves.length > 0) return moves[Math.floor(moves.length / 2)]!;
  return now.top - before.top - (now.lag - before.lag);
}

/// What moved apart from the scroll in `samples`, and how often the picture scrolled.
export function stillness(samples: Sample[]) {
  const events: Event[] = [];
  let offsetMoves = 0;
  /// Scrolls toward the end, or after the reader's scroll has settled: not the reader's.
  const unprompted: { t: number; px: number }[] = [];
  /// Scrolls, either way, after the reader's scroll has settled.
  const late: { t: number; px: number }[] = [];
  let blockFrames = 0;
  const wheels = samples.at(-1)?.wheels ?? 0;
  // The frame the reader's first wheel event acted on: the last one read before the page saw it
  // (paintedFrames.ts runs a painted frame's read before any input event's handlers). Frames before
  // it are of the followed view, the reader's input still on its way to the page.
  const from = Math.max(0, samples.findIndex((sample) => sample.wheels > 0) - 1);
  // The reader's last wheel event: the first frame read after it (its glide, if the app eases it,
  // starts in its handler, so that frame counts the glide too).
  const last = samples.findIndex((sample) => sample.wheels === wheels);
  const glidesBefore = samples[last - 1]?.glides ?? 0;
  // Their scroll has ended at the first frame after it with no wheel glide under way, and either a
  // glide that started for it and has ended (the app's own word), or none and the browser's
  // `scrollend` for the scroll it ran itself. Any scroll from there on is not the reader's.
  const found =
    last < 0
      ? -1
      : samples.findIndex(
          (sample, index) => index >= last && !sample.gliding && (sample.glides > glidesBefore || sample.ended),
        );
  const settled = found < 0 ? undefined : found;
  // The frames read after it, and how far the offset moved in the first PARKED_FRAMES of them.
  const parked = settled === undefined ? 0 : samples.length - 1 - settled;
  let parkedTop = 0;
  if (settled !== undefined)
    for (const sample of samples.slice(settled + 1, settled + 1 + PARKED_FRAMES))
      parkedTop = Math.max(parkedTop, Math.abs(sample.top - samples[settled]!.top));
  // And how far the picture drifted from where it settled, over every frame after it: the sum of each
  // frame's scroll, at its furthest. A drift under half a pixel a frame never shows in `late`, and past
  // the first PARKED_FRAMES nothing else read it: 30 frames held, then 0.25 px a frame for 109 frames
  // (27 px) read as parked (review of #41454 F1). The picture's scroll, not the offset: the quiet fold
  // of a held chase into the offset (VirtualTranscript `settleHeldFollowMotion`) moves nothing on screen.
  let drift = 0;
  let parkedDrift = 0;
  if (settled !== undefined)
    for (let index = settled + 1; index < samples.length; index += 1) {
      drift += pictureScroll(samples[index - 1]!, samples[index]!);
      parkedDrift = Math.max(parkedDrift, Math.abs(drift));
    }
  const t0 = samples[from]?.t ?? 0;
  for (let index = from + 1; index < samples.length; index += 1) {
    const before = samples[index - 1]!;
    const now = samples[index]!;
    const scrolled = pictureScroll(before, now);
    const t = Math.round(now.t - t0);
    if (Object.keys(now.items).some((key) => key.startsWith("block:"))) blockFrames += 1;
    if (Math.abs(scrolled) > 0.5) {
      offsetMoves += 1;
      const after = settled !== undefined && index > settled;
      if (after) late.push({ t, px: round(scrolled) });
      if (after || scrolled > 0) unprompted.push({ t, px: round(scrolled) });
    }
    for (const [key, top] of Object.entries(before.items)) {
      const expected = top - scrolled;
      if (!(key in now.items)) {
        if (expected > now.view[0] + 2 && expected < now.view[1] - 2)
          events.push({ t, key, kind: "vanished", scrolled: round(scrolled) });
        continue;
      }
      const px = now.items[key]! - expected;
      if (Math.abs(px) > 0.5) events.push({ t, key, kind: "moved", px: round(px), scrolled: round(scrolled) });
    }
  }
  return {
    frames: samples.length - from,
    blockFrames,
    offsetMoves,
    fromEnd: round(samples.at(-1)?.fromEnd ?? 0),
    wheels,
    settled: settled === undefined ? undefined : Math.round(samples[settled]!.t - t0),
    parked,
    parkedTop: round(parkedTop),
    parkedDrift: round(parkedDrift),
    unprompted: unprompted.slice(0, 16),
    late: late.slice(0, 16),
    events: events.length,
    first: events.slice(0, 16),
  };
}

/// The reader's scroll came to rest and then held: it ended, PARKED_FRAMES frames at least followed,
/// the offset held through them, the picture drifted no more than half a pixel in all from where it
/// settled to the last frame, and nothing scrolled after it ended.
export function parkedAfterScroll(report: ReturnType<typeof stillness>) {
  return {
    settled: report.settled !== undefined,
    parked: report.parked >= PARKED_FRAMES,
    still: report.parkedTop <= 0.5 && report.parkedDrift <= 0.5,
    late: report.late,
  };
}
export const PARKED = { settled: true, parked: true, still: true, late: [] };
