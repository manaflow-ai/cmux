// The judge of the reply's motion at a turn's end (support/replyMotion.ts), on frames the browser
// test has drawn and on the ones it must refuse.
import { expect, test } from "bun:test";
import { replyMotionProblems } from "./support/replyMotion";

/// Where the reply sits on each frame, from the steps between frames.
const placed = (steps: number[], from = 300) => steps.reduce((at, step) => [...at, at.at(-1)! + step], [from]);

test("the fold's eased move and a reply that stays put pass", () => {
  // The bottom route as the fleet draws it (TURN_END_REPLY bottom): 93px over three frames.
  expect(replyMotionProblems(placed([0, 0, -27, -54, -12, 0, 0, 0]))).toEqual([]);
  expect(replyMotionProblems(placed([0, 0, 0, 0, 0]))).toEqual([]);
});

test("a reply that ends where it started never steps on the way", () => {
  // There and back in two frames, and a 6px jump: under the 8px a move needs to be judged as one.
  expect(replyMotionProblems(placed([0, 40, -40, 0]))).toHaveLength(1);
  expect(replyMotionProblems(placed([0, -6, 0, 0]))).toHaveLength(1);
});

test("a move in one frame, or past its place and back, fails", () => {
  expect(replyMotionProblems(placed([0, -90, 0, 0]))).not.toEqual([]);
  expect(replyMotionProblems(placed([-30, -40, -40, 20]))).toContain("went past its place and back");
});
