// The report tool-toggle-motion.test.ts prints and checks: for each click of the tool-toggle turn
// (conversation/scriptedTurn.ts TOGGLE_CLICKS), how the clicked line, the rows over it and the rows
// under it moved on each 120 Hz frame while the reply streamed on, from the rows
// browser/send-stream-motion.harness.tsx sampled (`?rows=1`). Leo, 2026-11-06: "things clash with
// other things with animations going haywire ... a bunch of things which i think are just way too
// discontinuous and also way too jittery/sensitive. and it's just slow."
//
// A toggle is one state transition: the line the reader clicked stays on its pixel, the rows over it
// hold still, the details open or close in one motion, and the rows under it ride on the details' foot
// in the same frames. Per click window (from the click's frame to the next click, at most
// WINDOW_FRAMES):
// - `anchorPx`: the most the clicked line, or a row over it in view, moved in a frame after the
//   click's own (a jump of the whole view: a chase snapped home, a hold put back a frame late);
// - `clickFramePx`: the same in the click's own frame. On the wall clock under load a streamed commit
//   can land after the last painted frame and before the click, so the click's frame paints the
//   stream's own step (every row over the line moving with it, the details still shut); the toggle
//   holds the line from where that left it, as the reader's input is handled before that frame paints;
//   on the frames' clock it is 0;
// - `tearPx`: the most the row under the call moved apart from the call row's foot in a frame (rows
//   placed a frame late, a second motion on top of the fold);
// - `edgePx`: the most the call row's foot moved in a frame (the fold's own motion);
// - `reversals`: frames whose foot turned back while it moved (two motions fighting);
// - `restMs`: from the click to the last frame the foot or the row under it moved;
// - `firstShare`: on an open, the details' drawn height in the click's first frame as a share of
//   their height at rest (1: they popped in whole).
import type { Sample } from "../browser/send-stream-motion.harness";

/// The tool-toggle turn's call row (scriptedTurn.ts `playToggle`) and the row the reply streams under it.
const CALL_ROW = "live-activity-1";
const UNDER_ROW = "live-answer-2";
/// A click's window: up to 60 frames (500 ms at 120 Hz), and never past the next click.
export const WINDOW_FRAMES = 60;
/// A move this small is no move: rounding between layout and the drawn box.
const STILL_PX = 0.5;

const r1 = (value: number) => Math.round(value * 10) / 10;

export type ToggleWindow = {
  step: string;
  frames: number;
  open: boolean;
  anchorPx: number;
  clickFramePx: number;
  tearPx: number;
  edgePx: number;
  reversals: number;
  restMs: number;
  firstShare?: number;
};

/// The report for each click in `steps` (one that never ran reports nothing).
export function toggleReport(samples: Sample[], steps: readonly string[]): ToggleWindow[] {
  const out: ToggleWindow[] = [];
  for (const step of steps) {
    const first = samples.findIndex((sample) => sample.phase === step);
    if (first < 1) continue;
    let end = first;
    while (end < Math.min(samples.length, first + WINDOW_FRAMES) && samples[end]!.phase === step) end += 1;
    const report: ToggleWindow = {
      step,
      frames: end - first,
      open: Boolean(samples[end - 1]?.line?.open),
      anchorPx: 0,
      clickFramePx: 0,
      tearPx: 0,
      edgePx: 0,
      reversals: 0,
      restMs: 0,
    };
    let lastMove = samples[first]!.eventAt;
    let direction = 0;
    for (let index = first; index < end; index += 1) {
      const before = samples[index - 1]!;
      const now = samples[index]!;
      const row = (sample: Sample, id: string) => sample.rows?.find((each) => each.id === id);
      const call = row(now, CALL_ROW);
      const callWas = row(before, CALL_ROW);
      if (!call || !callWas || !now.line || !before.line) continue;
      // The clicked line and every row over it the reader saw last frame.
      let anchor = Math.abs(now.line.top - before.line.top);
      for (const was of before.rows ?? []) {
        if (!was.inView || was.top >= callWas.top - STILL_PX) continue;
        const is = row(now, was.id);
        if (is) anchor = Math.max(anchor, Math.abs(is.top - was.top));
      }
      if (index === first) report.clickFramePx = r1(anchor);
      else report.anchorPx = Math.max(report.anchorPx, r1(anchor));
      const foot = call.top + call.height - (callWas.top + callWas.height);
      report.edgePx = Math.max(report.edgePx, r1(Math.abs(foot)));
      const under = row(now, UNDER_ROW);
      const underWas = row(before, UNDER_ROW);
      const underMoved = under && underWas ? under.top - underWas.top : 0;
      if (under && underWas && underWas.inView)
        report.tearPx = Math.max(report.tearPx, r1(Math.abs(underMoved - foot)));
      if (Math.abs(foot) > STILL_PX || Math.abs(underMoved) > STILL_PX || anchor > STILL_PX) lastMove = now.t;
      // A foot that turns back mid-motion, from the frame after the click's (whose move may be the
      // stream's step before the click, `clickFramePx`).
      if (Math.abs(foot) > STILL_PX && index > first) {
        const sign = Math.sign(foot);
        if (direction !== 0 && sign !== direction) report.reversals += 1;
        direction = sign;
      }
      if (index === first && now.line.open && !before.line.open) {
        // The details' height at rest: the window's last frame.
        const rest = samples[end - 1]!.line?.body ?? 0;
        report.firstShare = rest > 0 ? Math.round((now.line.body / rest) * 100) / 100 : undefined;
      }
    }
    report.restMs = Math.max(0, Math.round(lastMove - samples[first]!.eventAt));
    out.push(report);
  }
  return out;
}
