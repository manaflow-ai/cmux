// The prompt rail's hover wave as numbers (model.ts): every shape peaks at 1 on the pointer, falls
// smoothly to rest at its reach, and never steps; the grow-in follows the rail's spring; the follow
// reaches a still pointer and stops.
import { describe, expect, test } from "bun:test";
import {
  type ZipMotion,
  ZIP_HOVER_MS,
  ZIP_MS,
  ZIP_RELEASE_MS,
  zipRetarget,
  zipSettled,
  zipStep,
  zipValue,
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

  describe("zipper", () => {
    const lengths = (values: Map<number, number>, from: number, to: number) =>
      Array.from({ length: to - from + 1 }, (_, at) => Math.round(tickLength(values.get(from + at) ?? 0) * 100) / 100);

    test("settles on the reference's lengths by whole rows from the hovered row", () => {
      const motions = new Map<number, ZipMotion>();
      zipRetarget(motions, 10, 30, 0);
      expect(lengths(zipStep(motions, 10, 1000), 5, 15)).toEqual([6, 6, 10, 14, 20, 26, 20, 14, 10, 6, 6]);
      expect(zipSettled(motions, 1000)).toBe(true);
    });

    test("a row change starts each changed tick from where it is; the hovered one is longest every frame", () => {
      const motions = new Map<number, ZipMotion>();
      zipRetarget(motions, 10, 30, 0);
      // Mid-ease, the pointer moves on two rows.
      zipRetarget(motions, 12, 30, 1000);
      // Tick 10 still draws its full length on the move's own instant, so tick 12 takes its own at once.
      const start = zipStep(motions, 12, 1000);
      expect(start.get(10)).toBeCloseTo(1, 6);
      expect(start.get(12)).toBe(1);
      for (let t = 1000 + 1000 / 60; t <= 1000 + ZIP_MS; t += 1000 / 60) {
        const values = zipStep(motions, 12, t);
        const hovered = values.get(12)!;
        for (const [index, value] of values) if (index !== 12) expect(value).toBeLessThan(hovered);
      }
      expect(zipSettled(motions, 1000 + ZIP_MS)).toBe(true);
    });

    test("a sweep keeps the bump whole: the rows ahead of the pointer grow as fast as it arrives", () => {
      // Leo, 2026-11-04: "the missing chunks of the wave bother me". A sweep down a row every 16 ms:
      // each frame, the hovered row's neighbours on both sides are already most of their way up, so no
      // hole opens between the hovered tick and the rows it moves onto.
      const motions = new Map<number, ZipMotion>();
      const frame = 1000 / 60;
      let now = 0;
      for (let row = 10; row <= 30; row += 1, now += frame) {
        zipRetarget(motions, row, 60, now);
        const values = zipStep(motions, row, now + frame);
        // One frame in, the row ahead has at least half its length (0.7) and the next at least a third
        // of its (0.4): over ZIP_MS they had 30% and 18%.
        expect(values.get(row + 1)!).toBeGreaterThan(0.7 * 0.5);
        expect(values.get(row + 2)!).toBeGreaterThan(0.4 * 0.33);
        // Shrinking ticks behind the pointer keep the zipper's tail and never outgrow the hovered one.
        for (const [index, value] of values) if (index !== row) expect(value).toBeLessThan(values.get(row)!);
      }
    });

    test("a tick already heading to its target keeps its own motion", () => {
      const motions = new Map<number, ZipMotion>();
      zipRetarget(motions, 10, 30, 0);
      const tick13 = motions.get(13)!;
      // From 10 to 11, tick 13's target goes 0.2 to 0.4; tick 7's (0.2 to 0) changes; tick 14 starts.
      zipRetarget(motions, 11, 30, 40);
      expect(motions.get(13)).not.toBe(tick13);
      expect(motions.get(13)!.from).toBeCloseTo(zipValue(tick13, 40), 6);
      const tick12 = motions.get(12)!;
      zipRetarget(motions, 11, 30, 50);
      expect(motions.get(12)).toBe(tick12);
    });

    test("the hovered tick grows quickly on arrival, and release shrinks every tick over the ceiling", () => {
      const motions = new Map<number, ZipMotion>();
      zipRetarget(motions, 10, 30, 0);
      expect(motions.get(10)!.ms).toBe(ZIP_HOVER_MS);
      // Its neighbours grow over the same quick step; only shrinking ticks take ZIP_MS.
      expect(motions.get(11)!.ms).toBe(ZIP_HOVER_MS);
      zipStep(motions, 10, 1000);
      zipRetarget(motions, undefined, 30, 1000);
      for (const motion of motions.values()) expect(motion).toMatchObject({ to: 0, ms: ZIP_RELEASE_MS });
      let last = 1;
      for (let t = 1000; t <= 1000 + ZIP_RELEASE_MS; t += 1000 / 60) {
        const value = zipStep(motions, undefined, t).get(10)!;
        expect(value).toBeLessThanOrEqual(last);
        last = value;
      }
      expect(last).toBeLessThan(0.001);
      expect(zipStep(motions, undefined, 1000 + ZIP_RELEASE_MS).get(10)).toBe(0);
      // Halfway through, still an eighth of the way up (not a drop in one frame).
      expect(zipValue(motions.get(10)!, 1000 + ZIP_RELEASE_MS / 2)).toBeGreaterThan(0.1);
    });
  });
});
