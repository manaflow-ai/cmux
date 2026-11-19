// l10n-allow-file: synthetic frames for the parked-reader settle rule.
// The parked-reader stillness test (streaming-parked-still.test.ts) settles the reader's scroll on the
// wheel glide's end, or the browser's scrollend, and then requires the view to hold for PARKED_FRAMES
// frames. A scroll that never stops must never read as parked, however its events fall (review of
// #40918 F1: 100 frames still moving were read as settled).
import { expect, test } from "bun:test";
import { PARKED, PARKED_FRAMES, parkedAfterScroll, stillness, type Sample } from "./support/parkedStill";

test("a scroll still moving at the last frame, or after scrollend, never reads as parked", () => {
  const frame = (index: number, top: number, at: Partial<Sample>): Sample => ({
    t: index * 16,
    top,
    fromEnd: 2000,
    wheels: 1,
    ended: false,
    glides: 0,
    gliding: false,
    lag: 0,
    view: [0, 600],
    items: { "row:a": 1000 - top, "row:b": 1400 - top },
    ...at,
  });
  const run = (count: number, at: (index: number) => [number, Partial<Sample>]) => [
    frame(0, 1000, { wheels: 0 }),
    ...Array.from({ length: count }, (_, index) => {
      const [top, rest] = at(index + 1);
      return frame(index + 1, top, rest);
    }),
  ];
  // The app's glide never ends: 100 frames, all moving, `scrollend` seen after the first write.
  const gliding = run(100, (index) => [1000 - index, { glides: 1, gliding: true, ended: index > 1 }]);
  expect(parkedAfterScroll(stillness(gliding))).not.toEqual(PARKED);
  expect(stillness(gliding).settled).toBeUndefined();
  // A scroll the browser runs that goes on after its first `scrollend` (the replay F1 passed).
  const native = run(100, (index) => [1000 - index, { ended: index > 1 }]);
  expect(parkedAfterScroll(stillness(native))).not.toEqual(PARKED);
  // The glide ends only at the last frame read: no parked frames after it.
  const lastFrame = run(100, (index) => [1000 - index, { glides: 1, gliding: index < 100, ended: true }]);
  expect(parkedAfterScroll(stillness(lastFrame))).not.toEqual(PARKED);
  // The offset creeps after the glide ends, under half a pixel of picture a frame each time.
  const creeping = run(60, (index) => [
    index <= 10 ? 1000 - 4 * index : 960 - 0.1 * (index - 10),
    { glides: 1, gliding: index <= 10, ended: true },
  ]);
  expect(parkedAfterScroll(stillness(creeping))).not.toEqual(PARKED);
  // The view holds PARKED_FRAMES frames after the glide ends, then drifts a quarter pixel a frame for
  // 109 frames (27 px): no frame scrolls past half a pixel, and the first PARKED_FRAMES held, but the
  // picture moved (review of #41454 F1).
  const drifting = run(150, (index) => [
    index <= 10 ? 1000 - 4 * index : index <= 11 + PARKED_FRAMES ? 960 : 960 - 0.25 * (index - 11 - PARKED_FRAMES),
    { glides: 1, gliding: index <= 10, ended: true },
  ]);
  expect(stillness(drifting).late).toEqual([]);
  expect(stillness(drifting).parkedTop).toBe(0);
  expect(stillness(drifting).parkedDrift).toBeCloseTo(0.25 * (150 - 11 - PARKED_FRAMES), 1);
  expect(parkedAfterScroll(stillness(drifting))).not.toEqual(PARKED);
  // And the scroll that does come to rest: ten eased frames, then the view holds.
  const resting = run(60, (index) => [
    index <= 10 ? 1000 - 4 * index : 960,
    { glides: 1, gliding: index <= 10, ended: true },
  ]);
  expect(parkedAfterScroll(stillness(resting))).toEqual(PARKED);
});
