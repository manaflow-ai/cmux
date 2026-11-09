// The report turn-transition-jumps.test.ts prints and checks: for each transition of a scripted
// turn (conversation/scriptedTurn.ts TRANSITION_TURNS), how far each row already drawn moved in one
// 120 Hz frame, from the rows browser/send-stream-motion.harness.tsx sampled (`?rows=1`). Leo,
// 2026-11-07: "the jumps are jarring. We want to minimize the jumps."
//
// Per transition window (each named step's first WINDOW_FRAMES frames, up to the next step):
// - `readingPx`: the most any row the reader already saw (in view in the frame before: the reply,
//   the rows above it) moved in a frame, and the row;
// - `livePx`: the most the running turn's live line, or a row under the reply's newest row (the
//   turn's footer), moved in a frame;
// - `composerPx`: the most the composer card's top moved;
// - `jumpFrames`: frames in which any of those moved more than JUMP_PX;
// - `popIns`: rows that came into view at full ink in their first frame (no fade);
// - `reflows`: frames in which a row moved or resized with nothing new drawn and no motion playing
//   (after an animation ended).
// A frame in which no row came, went or changed but a reply and the live line (the reply's text
// growing, or the chase bringing it home) is the stream's own motion, which send-stream-motion.test.ts holds: it counts in `streamPx`
// only, so a block the reply lands in a window is not taken for the transition; in those frames the
// rows under the reply count by the smaller of their move on screen and against its text (one
// that moves with the text, or holds still as the text moves, does not jump).
import type { RowSample, Sample } from "../browser/send-stream-motion.harness";

/// A move of more than this in one 120 Hz frame reads as a jump: a third of a line
/// (sendStreamMotionReport.ts JUMP_PX).
export const JUMP_PX = 7.5;
/// The running turn's live line (turns.ts LIVE_THINKING).
export const LIVE_LINE = "thinking-live";
/// The reply's rows' ids start with this (scriptedTurn.ts SCRIPTED_ANSWER_ID).
const ANSWER = "live-answer";
/// The turn's prompt (scriptedTurn.ts SCRIPTED_PROMPT_ID).
const PROMPT = "live-user";
/// A transition's window: 40 frames from its step's first frame, 333 ms at 120 Hz.
export const WINDOW_FRAMES = 40;

const r1 = (value: number) => Math.round(value * 10) / 10;

export type WindowReport = {
  step: string;
  frames: number;
  readingPx: number;
  readingRow?: string;
  livePx: number;
  composerPx: number;
  jumpFrames: number;
  popIns: string[];
  reflows: number;
  worstPx: number;
  /// The most the reading rows moved in a frame of the stream's own growth in the window.
  streamPx: number;
  /// Those frames.
  streamFrames: number;
};

/// The report for each step in `steps` (a step that never ran reports nothing).
export function transitionReport(samples: Sample[], steps: readonly string[]): WindowReport[] {
  const out: WindowReport[] = [];
  const seen = new Set<string>();
  // Rows seen before each frame (a row that left the mounted window and came back is no arrival).
  const seenBefore: Set<string>[] = samples.map((sample) => {
    const before = new Set(seen);
    for (const row of sample.rows ?? []) seen.add(row.id);
    return before;
  });
  for (const step of steps) {
    const first = samples.findIndex((sample) => sample.phase === step);
    if (first < 1) continue;
    const report: WindowReport = {
      step,
      frames: 0,
      readingPx: 0,
      livePx: 0,
      composerPx: 0,
      jumpFrames: 0,
      popIns: [],
      reflows: 0,
      worstPx: 0,
      streamPx: 0,
      streamFrames: 0,
    };
    // Up to the next step, so each window holds only its own step's frames.
    let end = first;
    while (end < Math.min(samples.length, first + WINDOW_FRAMES) && samples[end]!.phase === step) end += 1;
    for (let index = first; index < end; index += 1) {
      const before = samples[index - 1]!;
      const now = samples[index]!;
      report.frames += 1;
      const was = new Map<string, RowSample>((before.rows ?? []).map((row) => [row.id, row]));
      let reading = 0;
      let readingRow: string | undefined;
      let live = 0;
      /// The same rows' move on screen and against the reply's text, the smaller.
      let tail = 0;
      /// The rows under the reply's newest row (the live line, a footer): pushed down as it grows.
      const answers = (now.rows ?? []).filter((row) => row.id.startsWith(ANSWER));
      const replyEnd = answers.length ? Math.max(...answers.map((row) => row.top + row.height)) : Infinity;
      // How far the text moved this frame: the first reply row seen in both frames, else the prompt.
      const text = answers.find((row) => was.has(row.id)) ?? (now.rows ?? []).find((row) => row.id === PROMPT);
      const textMove = text && was.has(text.id) ? text.top - was.get(text.id)!.top : 0;
      let changed = false;
      /// A row other than a reply and the live line came, went, or changed its words or height.
      let other = false;
      for (const row of now.rows ?? []) {
        const old = was.get(row.id);
        if (!old) {
          changed = true;
          // A row the window mounts out of view draws nothing.
          if (row.inView) other = true;
          if (row.inView && !seenBefore[index]!.has(row.id) && row.opacity >= 0.9 && row.height > 4)
            report.popIns.push(row.id);
          continue;
        }
        if (old.text !== row.text) changed = true;
        if (
          (old.text !== row.text || Math.abs(old.height - row.height) > 0.5) &&
          row.id !== LIVE_LINE &&
          !row.id.startsWith(ANSWER)
        )
          other = true;
        // A row the reader saw last frame, wherever it went (a move out of view is a move too).
        if (!old.inView) continue;
        const moved = Math.abs(row.top - old.top);
        if (row.id === LIVE_LINE || row.top >= replyEnd - 0.5) {
          live = Math.max(live, moved);
          // A row that moves with the text, or holds still while the text moves, does not jump.
          tail = Math.max(tail, Math.min(moved, Math.abs(row.top - old.top - textMove)));
        } else if (moved > reading) {
          reading = moved;
          readingRow = row.id;
        }
      }
      for (const row of before.rows ?? [])
        if (!(now.rows ?? []).some((next) => next.id === row.id)) {
          changed = true;
          if (row.inView) other = true;
        }

      const composer = Math.abs((now.composer ?? 0) - (before.composer ?? 0));
      // Nothing new and nothing playing, yet something moved: a reflow after the motion ended.
      const still = (sample: Sample) =>
        Math.abs(sample.lag) < 0.01 && !(sample.rows ?? []).some((row) => row.animating);
      if (!changed && now.length === before.length && still(before) && still(now) && Math.max(reading, live) > 0.5)
        report.reflows += 1;
      // Only the reply's text grew, or the chase brings it home: the stream's own motion for the
      // reply and the rows above it. The rows under the reply still count: they move by its growth.
      if (!other && composer < 0.5) {
        report.streamFrames += 1;
        report.streamPx = Math.max(report.streamPx, r1(reading));
        reading = 0;
        live = tail;
      }
      if (reading > report.readingPx) {
        report.readingPx = r1(reading);
        report.readingRow = readingRow;
      }
      report.livePx = Math.max(report.livePx, r1(live));
      report.composerPx = Math.max(report.composerPx, r1(composer));
      if (Math.max(reading, live, composer) > JUMP_PX) report.jumpFrames += 1;
    }
    report.worstPx = Math.max(report.readingPx, report.livePx, report.composerPx);
    out.push(report);
  }
  return out;
}
