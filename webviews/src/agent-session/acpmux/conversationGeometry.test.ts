import { describe, expect, test } from "bun:test";
import {
  applyHeightChanges,
  fromFirstRow,
  geometryFromArrays,
  geometryFromHeights,
  geometryFromIndex,
} from "./conversationGeometry";

describe("indexed conversation geometry", () => {
  test("exposes prefix accessors without a materialized tops array", () => {
    const geometry = geometryFromHeights([10, 0, 5, 7]);
    expect(geometry.count).toBe(4);
    expect(geometry.totalHeight).toBe(22);
    expect([0, 1, 2, 3, 4].map((index) => geometry.topAt(index))).toEqual([0, 10, 10, 15, 22]);
    expect([0, 1, 2, 3].map((index) => geometry.heightAt(index))).toEqual([10, 0, 5, 7]);
    expect(geometry.upperBoundTop(10)).toBe(3);
  });

  test("changes only measured rows and preserves the old anchor snapshot", () => {
    const before = geometryFromHeights(new Float64Array(256).fill(20));
    const after = applyHeightChanges(before, [
      { index: 64, height: 37 },
      { index: 190, height: 4 },
    ]);
    expect(before.heightAt(64)).toBe(20);
    expect(before.topAt(190)).toBe(3_800);
    expect(after.heightAt(64)).toBe(37);
    expect(after.heightAt(190)).toBe(4);
    expect(after.topAt(190)).toBe(3_817);
    expect(after.totalHeight).toBe(5_121);
  });

  test("array geometry answers the same queries as indexed geometry", () => {
    const heights = [12, 0, 12, 4, 0, 12];
    const indexed = geometryFromHeights(heights);
    const tops = Float64Array.from({ length: heights.length }, (_, index) => indexed.topAt(index));
    const arrays = geometryFromArrays(tops, heights, indexed.totalHeight, 5);
    for (let index = 0; index <= heights.length; index += 1) {
      expect(arrays.topAt(index)).toBe(indexed.topAt(index) + 5);
      expect(arrays.gapAt(index)).toBe(0);
    }
    for (const target of [-1, 0, 5, 11, 17, 29, 40, 45])
      expect(arrays.upperBoundTop(target + 5)).toBe(indexed.upperBoundTop(target));
    const seen: number[] = [];
    arrays.scan(1, 4, (index, top) => void seen.push(index, top));
    expect(seen).toEqual([1, 17, 2, 17, 3, 29]);
  });

  test("ignores invalid changes without shifting row identity", () => {
    const before = geometryFromHeights([8, 9, 10]);
    const after = applyHeightChanges(before, [
      { index: 1, height: Number.NaN },
      { index: 9, height: 100 },
      { index: 2.5, height: 100 },
    ]);
    expect(after).toBe(before);
    expect(after.count).toBe(3);
    expect(after.topAt(2)).toBe(17);
  });
});

describe("fromFirstRow", () => {
  test("an indexed geometry's tops from its first row are the same numbers whatever room is above it", () => {
    const index = geometryFromHeights([10.1, 0.2, 5.3, 7.7]).index;
    const at = (origin: number) => {
      const places = fromFirstRow(geometryFromIndex(index, origin), origin);
      return [0, 1, 2, 3].map((row) => places.topAt(row));
    };
    const rest = at(0);
    // Rooms whose sums round: `origin + top - origin` would differ from `top` in the last bit.
    for (const origin of [0.1, 0.3, 1234.5678, 98765.4321]) expect(at(origin)).toEqual(rest);
  });
  test("an estimate's arrays take the room off", () => {
    const places = fromFirstRow(geometryFromArrays([0, 10, 20], [10, 10, 5], 25, 100), 100);
    expect([0, 1, 2].map((row) => places.topAt(row))).toEqual([0, 10, 20]);
    expect(places.heightAt(2)).toBe(5);
  });
});
