import { describe, expect, test } from "bun:test";
import { applyHeightChanges, geometryFromHeights } from "./conversationGeometry";
import { placeRowsIndexed } from "./model";

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

  test("placeRowsIndexed accepts a bounded changed-index batch", () => {
    const estimate = geometryFromHeights([12, 12, 12, 12, 12]);
    const placed = placeRowsIndexed(estimate, [
      { index: 1, height: 20 },
      { index: 3, height: 4 },
    ]);
    expect(placed.totalHeight).toBe(60);
    expect(placed.topAt(2)).toBe(32);
    expect(placed.topAt(4)).toBe(48);
    expect(estimate.totalHeight).toBe(60);
    expect(placed).not.toBe(estimate);
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
