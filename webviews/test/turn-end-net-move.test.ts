// The turn's end in send-stream-motion.test.ts is read where the rows paint (`?rows=1`): the fold
// (turnEndFold.ts) slides each row from where it was drawn, so the thread's own box can shift by
// 48 px in a frame while no row on screen moves (the tools turn). This checks that the reading still
// catches a real jump: the same 48 px shift with no fold offset on the rows moves every row by it,
// and both the frame's move and the row-by-row net (shift + layout move + fold offset) fail the line
// bound. Leo, 2026-11-07: "the jumps are jarring. We want to minimize the jumps".
import { expect, test } from "bun:test";
import type { RowSample, Sample } from "./browser/send-stream-motion.harness";
import { analyze } from "./support/sendStreamMotionReport";
import { FRAME_MS } from "./support/frames120";

const LINE_PX = 22.75;
const MAX_FRAME_PX = LINE_PX + 1;

/// A row at `layoutTop` in the thread, drawn `offset` px from it, with the thread's box at `thread`.
const row = (id: string, thread: number, layoutTop: number, offset: number): RowSample => ({
  id,
  top: thread + layoutTop + offset,
  height: 40,
  opacity: 1,
  animating: offset !== 0,
  moving: offset !== 0,
  inView: true,
  text: id,
  layoutTop,
  offset,
});

/// A frame: the thread's box at `thread`, drawn `lag` px from its layout, and its rows.
const frame = (index: number, phase: string, thread: number, lag: number, rows: RowSample[]): Sample => ({
  t: index * FRAME_MS,
  phase,
  top: thread,
  lag,
  scrollTop: 0,
  fromEnd: 0,
  tail: 0,
  length: 100,
  rows,
  composer: 600,
  eventAt: 0,
  animations: 0,
  started: 0,
});

/// The turn ends: before it the thread is drawn back 14.6 px (the chase); in the frame it ends the
/// chase lets go and a line of work comes in between the two rows (34 px of layout), so the thread's
/// box moves up 48.6 px: the row above the new line with it, the row under it 14.6 px. `covered`: the
/// fold draws each row from where it was (its offset what the frame moved it).
function turnEnd(covered: boolean): Sample[] {
  const before = 1000;
  const after = before - 48.6;
  const rows = (thread: number, ended: boolean) => [
    row("reply", thread, 400, ended && covered ? 48.6 : 0),
    row("live", thread, ended ? 534 : 500, ended && covered ? 14.6 : 0),
  ];
  return [
    frame(0, "segment", before, 14.6, rows(before, false)),
    frame(1, "segment", before, 14.6, rows(before, false)),
    frame(2, "end", after, 0, rows(after, true)),
    frame(3, "end", after, 0, rows(after, true)),
    frame(4, "after", after, 0, rows(after, true)),
  ];
}

test("a turn end the fold covers reads as no move where the rows paint", () => {
  const report = analyze(turnEnd(true), [FRAME_MS], 0, 2 * LINE_PX, LINE_PX);
  expect(report.turnEnd.threadPx).toBeCloseTo(48.6, 1);
  expect(report.turnEnd.offsetPx).toBeCloseTo(48.6, 1);
  expect(report.turnEnd.netPx).toBeLessThan(0.5);
  expect(report.jumpPx.max).toBeLessThan(0.5);
});

test("the same shift with no fold offset is a jump, and both checks go red", () => {
  const report = analyze(turnEnd(false), [FRAME_MS], 0, 2 * LINE_PX, LINE_PX);
  expect(report.turnEnd.threadPx).toBeCloseTo(48.6, 1);
  expect(report.turnEnd.netPx).toBeGreaterThan(MAX_FRAME_PX);
  expect(report.jumpPx.max).toBeGreaterThan(MAX_FRAME_PX);
});

test("without row samples the turn end is read from the thread's box, as before", () => {
  const samples = turnEnd(true).map(({ rows: _rows, ...sample }) => sample);
  const report = analyze(samples, [FRAME_MS], 0, 2 * LINE_PX, LINE_PX);
  expect(report.turnEnd.frames).toBe(0);
  expect(report.jumpPx.max).toBeCloseTo(48.6, 1);
});

test("a row the turn end carries out of view counts, while another stays covered (#41470 F1)", () => {
  // The review's replay: the thread's box moves up 48.6 px. The reply row is covered by the fold (its
  // offset what the frame moved it) and holds still in view; the row above it is not covered and jumps
  // 48.6 px, out of the view's top. Read only among rows in view in both frames, both checks read 0.
  const before = 1000;
  const after = before - 48.6;
  const viewTop = 995;
  const rows = (thread: number, ended: boolean): RowSample[] => [
    { ...row("above", thread, 0, 0), inView: thread + 40 > viewTop },
    row("reply", thread, 400, ended ? 48.6 : 0),
  ];
  const samples = [
    frame(0, "segment", before, 14.6, rows(before, false)),
    frame(1, "segment", before, 14.6, rows(before, false)),
    frame(2, "end", after, 0, rows(after, true)),
    frame(3, "end", after, 0, rows(after, true)),
    frame(4, "after", after, 0, rows(after, true)),
  ];
  // The row above was in view before the frame and is not after it: the jump took it out.
  expect(samples[1]!.rows![0]!.inView).toBe(true);
  expect(samples[2]!.rows![0]!.inView).toBe(false);
  const report = analyze(samples, [FRAME_MS], 0, 2 * LINE_PX, LINE_PX);
  expect(report.turnEnd.netPx).toBeCloseTo(48.6, 1);
  expect(report.jumpPx.max).toBeCloseTo(48.6, 1);
  expect(report.turnEnd.netPx).toBeGreaterThan(MAX_FRAME_PX);
  expect(report.jumpPx.max).toBeGreaterThan(MAX_FRAME_PX);
});
