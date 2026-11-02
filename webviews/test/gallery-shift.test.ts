import { expect, test } from "bun:test";
import { judgeStep } from "../src/gallery/play";
import { REST_FRAMES, scoreBoxFrames, type BoxFrame, type BoxSample } from "../src/gallery/shift";

const viewport = { width: 800, height: 600 };
const row = (y: number, extra: Partial<BoxSample> = {}): BoxSample => ({
  box: { x: 0, y, width: 800, height: 40 },
  label: "div.cv-row",
  ...extra,
});
const frames = (...list: [number, BoxSample][][]): BoxFrame[] => list.map((entries) => new Map(entries));
/** A box that has held still long enough for its moves to count. */
const rested = (id: number, y: number, extra: Partial<BoxSample> = {}) =>
  Array.from({ length: REST_FRAMES + 1 }, () => [[id, row(y, extra)]] as [number, BoxSample][]);

test("a still page scores zero", () => {
  expect(scoreBoxFrames(frames(...rested(1, 100), [[1, row(100)]]), viewport).score).toBe(0);
});

test("a rested row that jumps scores like CLS: its share of the viewport times the move's share", () => {
  const shift = scoreBoxFrames(frames(...rested(1, 100), [[1, row(130)]]), viewport);
  // The union of before and after is 800 x 70 of 800 x 600; the move is 30 of 800.
  expect(shift.score).toBeCloseTo(((800 * 70) / (800 * 600)) * (30 / 800), 5);
  expect(shift.moves).toEqual([{ label: "div.cv-row", frame: REST_FRAMES + 1, dx: 0, dy: 30 }]);
});

test("a row still entering (not yet rested) does not count, a step's first frame has rested", () => {
  expect(scoreBoxFrames(frames([[1, row(104)]], [[1, row(100)]], [[1, row(100)]]), viewport).score).toBe(0);
  expect(
    scoreBoxFrames(frames([[1, row(104)]], [[1, row(100)]]), viewport, { restedAtStart: true }).score,
  ).toBeGreaterThan(0);
});

test("moves a scroller made count (the browser's CLS subtracts them): a bottom-pinned transcript scrolling up", () => {
  const shift = scoreBoxFrames(frames(...rested(1, 400), [[1, row(250)]]), viewport, { restedAtStart: true });
  expect(shift.score).toBeGreaterThan(0.01);
});

test("the target, and rows after it pushed straight down, are exempt; rows before it are not", () => {
  const target = { targeted: true };
  const after = { after: true };
  expect(scoreBoxFrames(frames(...rested(1, 100, target), [[1, row(140, target)]]), viewport).score).toBe(0);
  expect(scoreBoxFrames(frames(...rested(2, 300, after), [[2, row(380, after)]]), viewport).score).toBe(0);
  // Pushed up, or sideways, is still a shift.
  expect(scoreBoxFrames(frames(...rested(2, 300, after), [[2, row(220, after)]]), viewport).score).toBeGreaterThan(0);
  expect(scoreBoxFrames(frames(...rested(3, 50), [[3, row(10)]]), viewport).score).toBeGreaterThan(0);
});

test("a resize lets each box move once; a second move is a bounce", () => {
  const once = frames(...rested(1, 100), [[1, row(120)]], [[1, row(120)]]);
  expect(scoreBoxFrames(once, viewport, { firstMoveFree: true }).score).toBe(0);
  const bounce = frames(...rested(1, 100), [[1, row(120)]], [[1, row(100)]]);
  expect(scoreBoxFrames(bounce, viewport, { firstMoveFree: true }).score).toBeGreaterThan(0);
});

test("half-pixel rounding and boxes outside the viewport are not shift", () => {
  expect(scoreBoxFrames(frames(...rested(1, 100), [[1, row(100.4)]]), viewport).score).toBe(0);
  expect(scoreBoxFrames(frames(...rested(1, 700), [[1, row(760)]]), viewport).score).toBe(0);
});

// A wait is the page loading what it waits for (a header button arriving, a mention list opening):
// the play does not fail on it. Gallery health scores it against the state's shift baseline.
test("a wait step's shift and anchor moves do not fail the play; an action step's do", () => {
  const measured = {
    step: "s",
    settleMs: 10,
    anchorMoves: [{ anchor: "a", before: null, after: null, delta: 40 }],
    layoutShift: 0.01,
    shifts: [],
    boxShift: 0.01,
    boxMoves: [{ label: "div.ui-popup", frame: 3, dx: 0, dy: -32 }],
    longFrames: [],
    frameSource: "raf" as const,
  };
  expect(judgeStep({ ...measured, action: "wait" }).status).toBe("pass");
  expect(judgeStep({ ...measured, action: "click" }).status).toBe("fail");
});
