import { expect, test } from "bun:test";
import { keyPresentation, settleThrough } from "./keyPresentation";
import { typingSummary } from "./perf";

test("a rounded presentation time brackets the key between its 4 ms step and its paint", () => {
  // Chromium 157, not cross-origin isolated: paint 2595.3, presented 2596.0 rounded up to 2600. The step's
  // floor (2596) lies after the paint: the floor is the step's.
  const step = keyPresentation({ paintTime: 2595.3, presentationTime: 2600 }, 2590, false);
  expect(step?.submitted).toBe(10);
  expect(step?.submittedFloor).toBe(6);
  // The frame's own paint, as the composer-typing bench reads `to_paint`.
  expect(step?.painted).toBeCloseTo(5.3, 6);
  // The paint lies after the step's floor: nothing is presented before its paint.
  const late = keyPresentation({ paintTime: 2597.2, presentationTime: 2600 }, 2590, false);
  expect(late?.submitted).toBe(10);
  expect(late?.submittedFloor).toBeCloseTo(7.2, 6);
});

test("a cross-origin isolated page reads the presentation time as is", () => {
  expect(keyPresentation({ paintTime: 2598.75, presentationTime: 2599.5 }, 2590, true)).toEqual({
    submitted: 9.5,
    submittedFloor: 9.5,
    painted: 8.75,
  });
});

test("an entry without a presentation time marks nothing; renderTime stands in for an older engine", () => {
  expect(keyPresentation({ paintTime: 2595 }, 2590, false)).toBeNull();
  expect(keyPresentation({ renderTime: 2600 }, 2590, false)).toEqual({ submitted: 10, submittedFloor: 6 });
});

test("the typing summary reports the submitted mark only for keys that have it", () => {
  const summary = typingSummary([
    { frame: 1, paint: 4, submitted: 8, submittedFloor: 5 },
    { frame: 1, paint: 5 },
  ]);
  expect(summary.submitted_keys).toBe(1);
  expect(summary.to_submitted.p95_ms).toBe(8);
  expect(summary.to_submitted_floor.p95_ms).toBe(5);
});

test("an entry settles its key and every key typed before it in the same frame", () => {
  const waiting = new Map([
    ["k0", 0],
    ["k1", 1],
    ["k2", 2],
  ]);
  expect(settleThrough(waiting, "k9")).toEqual([]);
  expect(settleThrough(waiting, "k1")).toEqual([0, 1]);
  expect([...waiting.keys()]).toEqual(["k2"]);
});
