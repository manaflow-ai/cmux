// The prompt rail's hover wave as numbers (model.ts): every shape peaks at 1 on the pointer, falls
// smoothly to rest at its reach, and never steps; the grow-in follows the rail's spring; the follow
// reaches a still pointer and stops.
import { describe, expect, test } from "bun:test";
import {
  tickLength,
  waveAmplitude,
  waveFollow,
  WAVE_IN_MS,
  waveProgress,
  WAVE_SHAPES,
} from "../src/agent-session/acpmux/threadMinimap/model";

describe("hover wave model", () => {
  for (const [name, shape] of Object.entries(WAVE_SHAPES)) {
    test(`${name}: 1 on the pointer, 0 at its reach, and no step between`, () => {
      expect(waveProgress(shape, 10, 10.5)).toBeCloseTo(1, 6);
      expect(waveProgress(shape, 10, 10.5 + shape.reach)).toBe(0);
      expect(waveProgress(shape, 10, 10.5 - shape.reach - 0.3)).toBe(0);
      // A tenth of a pixel of pointer travel (a hundredth of a row) moves no tick more than 0.1 px.
      let largest = 0;
      for (let focus = 4; focus < 17; focus += 0.01) {
        const step = Math.abs(
          tickLength(waveProgress(shape, 10, focus + 0.01)) - tickLength(waveProgress(shape, 10, focus)),
        );
        largest = Math.max(largest, step);
      }
      expect(largest).toBeLessThan(0.1);
      // Falls off the further the pointer is.
      expect(waveProgress(shape, 10, 11.5)).toBeLessThan(waveProgress(shape, 10, 11));
      expect(waveProgress(shape, 10, 12.5)).toBeLessThan(waveProgress(shape, 10, 11.5));
    });
  }

  test("cosine-4 keeps the stepped reach: rest four rows away", () => {
    const shape = WAVE_SHAPES["cosine-4"];
    expect(tickLength(waveProgress(shape, 10, 13.5))).toBeGreaterThan(6.5);
    expect(tickLength(waveProgress(shape, 10, 14.5))).toBeCloseTo(6, 2);
  });

  test("the grow-in runs the rail's spring over the micro step", () => {
    expect(waveAmplitude(0)).toBe(0);
    expect(waveAmplitude(WAVE_IN_MS * 0.1)).toBeCloseTo(0.398, 3);
    expect(waveAmplitude(WAVE_IN_MS * 0.7)).toBeCloseTo(1.008, 3);
    expect(waveAmplitude(WAVE_IN_MS)).toBe(1);
    expect(waveAmplitude(WAVE_IN_MS * 4)).toBe(1);
  });

  test("the follow eases toward a still pointer and lands on it", () => {
    let focus = 0;
    let frames = 0;
    while (focus !== 10 && frames < 100) {
      focus = waveFollow(focus, 10, 1000 / 60);
      frames += 1;
    }
    expect(focus).toBe(10);
    // About 12 frames at 60 Hz for ten rows: it lands, so its loop stops.
    expect(frames).toBeLessThan(20);
    // A longer frame goes further, never past the pointer.
    expect(waveFollow(0, 10, 50)).toBeGreaterThan(waveFollow(0, 10, 16));
    expect(waveFollow(0, 10, 1000)).toBe(10);
  });
});
