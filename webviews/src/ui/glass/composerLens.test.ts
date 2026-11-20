import { beforeEach, describe, expect, test } from "bun:test";
import {
  buildLensField,
  composerLensMap,
  composerLensStats,
  LENS_OPTICS,
  lensMapKey,
  peakShift,
  resetComposerLensCache,
  snellShift,
} from "./composerLens";

// A document with no canvas: the map's URL is "", the build still counts.
const doc = { createElement: () => ({}) } as unknown as Document;

describe("composer lens map", () => {
  beforeEach(() => resetComposerLensCache());

  test("the bezel pulls inward, hardest near the rim, and lets go by its inner edge", () => {
    const peak = peakShift();
    expect(peak).toBeGreaterThan(4);
    expect(peak).toBeLessThan(16);
    expect(snellShift(2)).toBeGreaterThan(snellShift(10));
    expect(snellShift(LENS_OPTICS.bezel)).toBe(0);
    expect(snellShift(LENS_OPTICS.bezel - 0.5)).toBeLessThan(0.2);
  });

  test("the field is neutral in the middle and points inward at each edge", () => {
    const field = buildLensField(200, 60, 1, 18);
    const at = (x: number, y: number) => [
      ...field.data.slice((y * field.width + x) * 4, (y * field.width + x) * 4 + 2),
    ];
    expect(at(100, 30)).toEqual([128, 128]);
    // Left edge: pulled right (red over 128); right edge: pulled left; top: pulled down.
    expect(at(2, 30)[0]!).toBeGreaterThan(160);
    expect(at(197, 30)[0]!).toBeLessThan(96);
    expect(at(100, 2)[1]!).toBeGreaterThan(160);
  });

  test("the field is in device pixels: the key and the map size follow the ratio", () => {
    expect(buildLensField(200, 60, 2, 18).width).toBe(400);
    expect(lensMapKey(200, 60, 2, 18)).not.toBe(lensMapKey(200, 60, 1, 18));
    expect(lensMapKey(200.2, 59.8, 2, 18)).toBe(lensMapKey(200, 60, 2, 18));
  });

  test("one build per key: a repeat is a cache hit", () => {
    composerLensMap(doc, 320, 56, 2, 18);
    composerLensMap(doc, 320, 56, 2, 18);
    composerLensMap(doc, 320, 56, 2, 18);
    expect(composerLensStats).toEqual({ builds: 1, hits: 2 });
    composerLensMap(doc, 320, 76, 2, 18);
    expect(composerLensStats.builds).toBe(2);
  });
});
